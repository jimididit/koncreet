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
      ui_skip "user $new_user already exists"
    else
      if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
        ui_step_start "creating user $new_user"
        useradd -m -s /bin/bash "$new_user"
        local pass passfile
        pass="$(openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24)"
        echo "${new_user}:${pass}" | chpasswd
        passfile="/root/${new_user}.koncreet-password"
        umask 077
        printf '%s\n' "$pass" >"$passfile"
        chmod 600 "$passfile"
        ui_step_ok "user $new_user created"
        ui_warn "sudo password: $pass"
        ui_muted "  saved at $passfile — change later with: passwd $new_user"
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
        if [[ ! -s "$dest_keys" ]]; then
          cp "$src_keys" "$dest_keys"
          log_ok "SSH keys copied from $src_keys"
        else
          ui_skip "authorized_keys already has content"
        fi
      else
        log_warn "No authorized_keys to copy — add one before SSH hardening"
        [[ -f "$dest_keys" ]] || touch "$dest_keys"
      fi
      chmod 700 "${new_home}/.ssh"
      chmod 600 "$dest_keys"
      chown -R "${new_user}:${new_user}" "${new_home}/.ssh"

      if koncreet_has_working_key_file "$dest_keys"; then
        chage -d "$(date -I)" "$new_user" 2>/dev/null || chage -d -1 "$new_user" || true
        log_ok "SSH keys ready for $new_user (password not expired)"
      else
        chage -d 0 "$new_user" || true
        log_warn "No SSH keys for $new_user — password expired on first login"
      fi
    fi
  else
    ui_skip "user creation (none requested)"
  fi

  write_file /etc/sysctl.d/99-koncreet.conf <<'EOF'
# Managed by koncreet baseline
net.ipv4.tcp_syncookies = 1
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
    sysctl --system >/dev/null 2>&1 || log_warn "sysctl --system reported errors (some keys may be unavailable)"
    log_ok "sysctl drop-in"
  else
    plan "sysctl --system"
  fi

  if swapon --show 2>/dev/null | grep -q .; then
    ui_skip "swap already active"
  else
    local ram_mb swap_mb
    ram_mb="$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)"
    swap_mb=$(( ram_mb < 2048 ? ram_mb : 2048 ))
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "create /swapfile ${swap_mb}M and enable"
    else
      ui_step_start "creating ${swap_mb}M swapfile"
      if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb" status=none
      fi
      chmod 600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >>/etc/fstab
      fi
      ui_step_ok "swapfile ${swap_mb}M"
    fi
  fi

  write_file /etc/systemd/journald.conf.d/99-koncreet-cap.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
  if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
    ui_run_quiet "journald cap 200M" systemctl restart systemd-journald
  else
    plan "systemctl restart systemd-journald"
  fi

  if [[ -n "$timezone" ]]; then
    if [[ "$KONCREET_DRY_RUN" -eq 0 ]]; then
      ui_run_quiet "timezone $timezone" timedatectl set-timezone "$timezone" || log_warn "timedatectl set-timezone failed"
    else
      plan "timedatectl set-timezone $timezone"
    fi
  fi

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ensure systemd-timesyncd or chrony active"
  else
    if systemctl list-unit-files systemd-timesyncd.service &>/dev/null; then
      systemctl enable --now systemd-timesyncd 2>/dev/null || true
    fi
    if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
      log_ok "timesync: systemd-timesyncd"
    elif systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
      log_ok "timesync: chrony"
    else
      pkg_install chrony || true
      systemctl enable --now chrony 2>/dev/null || systemctl enable --now chronyd 2>/dev/null || \
        log_warn "Could not start a time sync service"
    fi
  fi
}

baseline_status() {
  ui_header "baseline"
  if [[ -f /etc/sysctl.d/99-koncreet.conf ]]; then
    ui_kv "sysctl" "99-koncreet.conf"
  else
    ui_kv "sysctl" "not applied"
  fi
  if swapon --show 2>/dev/null | grep -q .; then
    ui_kv "swap" "active"
  else
    ui_kv "swap" "none"
  fi
  if [[ -f /etc/systemd/journald.conf.d/99-koncreet-cap.conf ]]; then
    ui_kv "journald" "capped 200M"
  else
    ui_kv "journald" "no koncreet cap"
  fi
  if command -v timedatectl &>/dev/null; then
    ui_kv "timezone" "$(timedatectl show -p Timezone --value 2>/dev/null || echo unknown)"
  fi
  if systemctl is-active --quiet systemd-timesyncd 2>/dev/null; then
    ui_kv "timesync" "systemd-timesyncd"
  elif systemctl is-active --quiet chrony 2>/dev/null || systemctl is-active --quiet chronyd 2>/dev/null; then
    ui_kv "timesync" "chrony"
  else
    ui_kv "timesync" "inactive"
  fi
}
