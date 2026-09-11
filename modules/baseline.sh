#!/usr/bin/env bash
# baseline: sudo user, sysctl, swap, journald, optional timezone/timesync
# shellcheck shell=bash

baseline_plan_lines() {
  local user="${1:-}"
  local lines=()
  [[ -n "$user" ]] && lines+=("Create/ensure sudo user '$user' and copy SSH keys")
  lines+=("Write cloud-safer sysctl drop-in /etc/sysctl.d/99-koncreet.conf")
  lines+=("Ensure swapfile if none active (cap 2G)")
  lines+=("Cap journald SystemMaxUse=200M")
  if [[ -n "${KONCREET_TIMEZONE:-}" ]]; then
    lines+=("Set timezone to $KONCREET_TIMEZONE")
  fi
  lines+=("Ensure time sync (systemd-timesyncd or chrony)")
  printf '%s\n' "${lines[@]}"
}

baseline_apply() {
  local new_user="${1:-}"
  local timezone="${KONCREET_TIMEZONE:-}"

  if [[ -n "$new_user" ]]; then
    if ! valid_username "$new_user"; then
      die "Invalid username '$new_user' (use lowercase letters, digits, _, -; max 32)"
    fi
    if id -u "$new_user" &>/dev/null; then
      log_info "User '$new_user' already exists, skipping creation"
    else
      log_info "Creating user '$new_user'"
      if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
        useradd -m -s /bin/bash "$new_user"
        local pass passfile
        # Alphanumeric only — avoids /+ in base64 breaking copy-paste / PAM prompts
        pass="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
        echo "${new_user}:${pass}" | chpasswd
        passfile="/root/${new_user}.koncreet-password"
        umask 077
        printf '%s\n' "$pass" >"$passfile"
        chmod 600 "$passfile"
        if [[ -t 1 ]]; then
          echo "!! Generated sudo password for $new_user: $pass"
          echo "!! Also saved at $passfile (mode 0600). Change later with: passwd $new_user"
        else
          log_info "Password written to $passfile (mode 0600) - not a TTY"
        fi
      else
        plan "useradd -m -s /bin/bash $new_user && set sudo password"
      fi
    fi
    if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
      usermod -aG "${KONCREET_SUDO_GROUP:-sudo}" "$new_user"
    else
      plan "usermod -aG ${KONCREET_SUDO_GROUP:-sudo} $new_user"
    fi

    local src_keys="" cand
    for cand in "/home/${SUDO_USER:-}/.ssh/authorized_keys" "/root/.ssh/authorized_keys"; do
      if koncreet_has_working_key_file "$cand"; then
        src_keys="$cand"
        break
      fi
    done
    local new_home dest_keys
    new_home="$(koncreet_user_home "$new_user" 2>/dev/null || echo "/home/$new_user")"
    dest_keys="${new_home}/.ssh/authorized_keys"
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "ensure ${new_home}/.ssh and copy keys from ${src_keys:-none}"
    else
      mkdir -p "${new_home}/.ssh"
      if [[ -n "$src_keys" ]]; then
        # Copy if missing OR empty (fixes cp -n empty-key trap)
        if [[ ! -s "$dest_keys" ]]; then
          cp "$src_keys" "$dest_keys"
          log_info "Copied SSH key(s) from $src_keys"
        else
          log_info "authorized_keys already has content - leaving in place"
        fi
      else
        log_warn "No existing authorized_keys found to copy - add one before SSH hardening."
        [[ -f "$dest_keys" ]] || touch "$dest_keys"
      fi
      chmod 700 "${new_home}/.ssh"
      chmod 600 "$dest_keys"
      chown -R "${new_user}:${new_user}" "${new_home}/.ssh"

      # Never force-expire when keys exist: SSH key login + expired password
      # makes PAM demand a password change and can lock the new session out.
      if koncreet_has_working_key_file "$dest_keys"; then
        chage -d "$(date -I)" "$new_user" 2>/dev/null || chage -d -1 "$new_user" || true
        log_info "SSH keys present for $new_user — login with your key (password not expired)"
      else
        chage -d 0 "$new_user" || true
        log_warn "No SSH keys for $new_user — password expired; must change on first login"
      fi
    fi
  else
    log_info "No username given - skipping user creation"
  fi

  log_info "sysctl hardening (cloud-safer profile)"
  write_file /etc/sysctl.d/99-koncreet.conf <<'EOF'
# Managed by koncreet baseline
net.ipv4.tcp_syncookies = 1
# rp_filter=2 (loose) is safer on cloud/VPN multi-homed hosts than strict=1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
vm.swappiness = 10
EOF
  if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
    sysctl --system >/dev/null || log_warn "sysctl --system reported errors (some keys may be unavailable)"
  else
    plan "sysctl --system"
  fi

  log_info "Swap"
  if swapon --show 2>/dev/null | grep -q .; then
    log_info "Swap already active, skipping"
    swapon --show || true
  else
    local ram_mb swap_mb
    ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    swap_mb=$(( ram_mb < 2048 ? ram_mb : 2048 ))
    log_info "Creating ${swap_mb}M swapfile"
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "create /swapfile ${swap_mb}M and enable"
    else
      if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
      fi
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >>/etc/fstab
      fi
    fi
  fi

  log_info "Capping journald size"
  write_file /etc/systemd/journald.conf.d/99-koncreet-cap.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
    systemctl restart systemd-journald
  else
    plan "systemctl restart systemd-journald"
  fi

  if [[ -n "$timezone" ]]; then
    log_info "Setting timezone to $timezone"
    if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
      timedatectl set-timezone "$timezone" || log_warn "timedatectl set-timezone failed"
    else
      plan "timedatectl set-timezone $timezone"
    fi
  fi

  log_info "Ensuring time sync"
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ensure systemd-timesyncd or chrony active"
  else
    if systemctl list-unit-files systemd-timesyncd.service &>/dev/null; then
      systemctl enable --now systemd-timesyncd 2>/dev/null || true
    fi
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
      log_info "systemd-timesyncd is active"
    elif systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
      log_info "chrony is active"
    else
      pkg_install chrony || true
      systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || \
        log_warn "Could not start a time sync service - set one up manually"
    fi
  fi

  log_info "Baseline done."
}

baseline_status() {
  echo "--- baseline ---"
  if [[ -f /etc/sysctl.d/99-koncreet.conf ]]; then
    echo "sysctl: /etc/sysctl.d/99-koncreet.conf present"
  else
    echo "sysctl: not applied by koncreet"
  fi
  if swapon --show 2>/dev/null | grep -q .; then
    echo "swap: active"
  else
    echo "swap: none"
  fi
  if [[ -f /etc/systemd/journald.conf.d/99-koncreet-cap.conf ]]; then
    echo "journald: capped by koncreet"
  else
    echo "journald: no koncreet cap"
  fi
  if command -v timedatectl &>/dev/null; then
    timedatectl show -p Timezone --value 2>/dev/null | awk '{print "timezone: "$0}'
  fi
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    echo "timesync: systemd-timesyncd active"
  elif systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    echo "timesync: chrony active"
  else
    echo "timesync: unknown / inactive"
  fi
}
