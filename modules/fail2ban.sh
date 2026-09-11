#!/usr/bin/env bash
# fail2ban (sheriff): systemd backend, ufw banaction, jail.d drop-in
# shellcheck shell=bash

KONCREET_F2B_DROPIN="/etc/fail2ban/jail.d/99-koncreet.conf"

declare -A KONCREET_F2B_JAILS=(
  [ssh]="sshd"
  [nginx]="nginx-http-auth"
  [apache]="apache-auth"
  [postfix]="postfix"
  [vsftpd]="vsftpd"
  [mysql]="mysqld-auth"
)

declare -A KONCREET_F2B_HINTS=(
  [nginx]="/var/log/nginx/error.log"
  [apache]="/var/log/apache2/error.log"
  [postfix]="/var/log/mail.log"
  [vsftpd]="/var/log/vsftpd.log"
  [mysql]="/var/log/mysql/error.log"
)

fail2ban_list_services() {
  echo "Supported fail2ban services:"
  local s
  for s in "${!KONCREET_F2B_JAILS[@]}"; do echo "  $s"; done | sort
}

fail2ban_enabled_jails() {
  if command -v fail2ban-client &>/dev/null && fail2ban-client ping &>/dev/null; then
    fail2ban-client status 2>/dev/null \
      | awk -F: '/Jail list/{print $2}' \
      | tr ',' '\n' \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
      | grep -v '^$' \
      | sort -u
    return 0
  fi
  if [[ -f "$KONCREET_F2B_DROPIN" ]]; then
    awk '/^\[/ && $0 !~ /^\[DEFAULT\]/ { gsub(/[\[\]]/,""); print }' "$KONCREET_F2B_DROPIN" | sort -u
  fi
}

fail2ban_plan_lines() {
  local requested="${1:-ssh}"
  printf '%s\n' \
    "Install fail2ban" \
    "Write $KONCREET_F2B_DROPIN (backend=systemd, banaction=ufw if ufw active)" \
    "Enable jails for: $requested" \
    "Enable and restart fail2ban; verify sshd jail is running"
}

fail2ban_read_ignoreip() {
  local ignoreip=""
  if [[ -f "$KONCREET_F2B_DROPIN" ]]; then
    ignoreip="$(awk -F= '/^ignoreip[[:space:]]*=/{sub(/^[^=]*=[[:space:]]*/,""); print; exit}' "$KONCREET_F2B_DROPIN")"
  fi
  echo "$ignoreip"
}

fail2ban_apply() {
  local requested="${1:-ssh}"
  local bantime="${BANTIME:-1h}" findtime="${FINDTIME:-10m}" maxretry="${MAXRETRY:-5}"

  pkg_install fail2ban

  local -A all_jails=()
  local svc jail
  local -a wanted=()
  IFS=',' read -ra wanted <<<"$requested"
  for svc in "${wanted[@]}"; do
    svc="${svc// /}"
    [[ -z "$svc" ]] && continue
    jail="${KONCREET_F2B_JAILS[$svc]:-}"
    if [[ -z "$jail" ]]; then
      die "Unknown fail2ban service '$svc'. Run: koncreet fail2ban list"
    fi
    if [[ -n "${KONCREET_F2B_HINTS[$svc]:-}" && ! -e "${KONCREET_F2B_HINTS[$svc]}" ]]; then
      log_warn "$svc: ${KONCREET_F2B_HINTS[$svc]} not found - enabling jail '$jail' anyway"
    fi
    all_jails[$jail]=1
  done

  if [[ "${#all_jails[@]}" -eq 0 ]]; then
    die "No valid jails to enable"
  fi

  local need_sshd=0
  [[ -n "${all_jails[sshd]:-}" ]] && need_sshd=1

  local ignoreip
  ignoreip="$(fail2ban_read_ignoreip)"
  local my_ip="${SSH_CONNECTION%% *}"
  if [[ -n "$my_ip" ]] && ! grep -qw "$my_ip" <<<"$ignoreip"; then
    local add_wl=0
    if [[ "$KONCREET_YES" -eq 1 ]]; then
      add_wl=1
    elif [[ -t 0 && -t 1 ]]; then
      local reply
      reply="$(ask "Add your IP ($my_ip) to the fail2ban whitelist? [Y/n] " "Y")"
      [[ ! "$reply" =~ ^[Nn] ]] && add_wl=1
    fi
    [[ "$add_wl" -eq 1 ]] && ignoreip="${ignoreip:+$ignoreip }$my_ip"
  fi

  local ignore_final="127.0.0.1/8 ::1"
  local tok
  for tok in $ignoreip; do
    case "$tok" in
      127.0.0.1/8|::1|127.0.0.1) continue ;;
    esac
    if ! grep -qw "$tok" <<<"$ignore_final"; then
      ignore_final="$ignore_final $tok"
    fi
  done

  local banaction="iptables-multiport"
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
    banaction="ufw"
  fi

  local conf
  conf="[DEFAULT]
# Managed by koncreet - re-run koncreet fail2ban apply instead of hand-editing
bantime  = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
backend  = systemd
banaction = ${banaction}
ignoreip = ${ignore_final}
"
  for jail in "${!all_jails[@]}"; do
    conf+=$'\n'"[$jail]"$'\n'"enabled = true"$'\n'
  done

  printf '%s' "$conf" | write_file "$KONCREET_F2B_DROPIN"

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "systemctl enable --now fail2ban && restart"
    return 0
  fi

  ui_run_quiet "enable fail2ban" systemctl enable --now fail2ban
  ui_run_quiet "restart fail2ban" systemctl restart fail2ban
  sleep 1

  if [[ "$need_sshd" -eq 1 ]]; then
    if ! fail2ban-client status sshd &>/dev/null; then
      die "fail2ban sshd jail did not start. Check: journalctl -u fail2ban -e"
    fi
    log_ok "sshd jail running (banaction=$banaction)"
  fi
}

fail2ban_status() {
  ui_header "fail2ban"
  if ! command -v fail2ban-client &>/dev/null; then
    ui_kv "fail2ban" "not installed"
    return 0
  fi
  local jails banned
  jails="$(fail2ban_enabled_jails | tr '\n' ',' | sed 's/,$//')"
  banned="$(fail2ban-client status 2>/dev/null | awk -F: '/Currently banned/{print $2; exit}' | tr -d ' ')"
  ui_kv "jails" "${jails:-none}"
  ui_kv "banned" "${banned:-0}"
  if [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then
    local jail
    while read -r jail; do
      [[ -n "$jail" ]] || continue
      fail2ban-client status "$jail" 2>/dev/null | sed 's/^/  /' || true
    done < <(fail2ban_enabled_jails)
  fi
}

fail2ban_unban() {
  local ip="${1:?Usage: koncreet fail2ban unban <ip>}"
  local found=0 jail
  while read -r jail; do
    [[ -z "$jail" ]] && continue
    if fail2ban-client set "$jail" unbanip "$ip" &>/dev/null; then
      log_ok "unbanned $ip from $jail"
      found=1
    fi
  done < <(fail2ban_enabled_jails)
  [[ "$found" -eq 1 ]] || ui_skip "$ip was not banned"
}

fail2ban_whitelist() {
  local ip="${1:?Usage: koncreet fail2ban whitelist <ip>}"
  [[ -f "$KONCREET_F2B_DROPIN" ]] || die "No $KONCREET_F2B_DROPIN yet - run: koncreet fail2ban apply"
  local ignoreip
  ignoreip="$(fail2ban_read_ignoreip)"
  if grep -qw "$ip" <<<"$ignoreip"; then
    ui_skip "$ip already whitelisted"
    return 0
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "add $ip to ignoreip in $KONCREET_F2B_DROPIN"
    return 0
  fi
  if grep -q '^ignoreip' "$KONCREET_F2B_DROPIN"; then
    sed -i "s|^ignoreip.*|ignoreip = ${ignoreip} ${ip}|" "$KONCREET_F2B_DROPIN"
  else
    sed -i "/^\[DEFAULT\]/a ignoreip = 127.0.0.1/8 ::1 ${ip}" "$KONCREET_F2B_DROPIN"
  fi
  ui_run_quiet "reload fail2ban" systemctl restart fail2ban
  log_ok "whitelisted $ip"
}

fail2ban_undo() {
  if [[ ! -f "$KONCREET_F2B_DROPIN" ]]; then
    ui_skip "no fail2ban drop-in to remove"
    return 0
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "rm $KONCREET_F2B_DROPIN && systemctl restart fail2ban"
    return 0
  fi
  backup_file "$KONCREET_F2B_DROPIN"
  rm -f "$KONCREET_F2B_DROPIN"
  systemctl restart fail2ban 2>/dev/null || true
  log_ok "removed koncreet fail2ban drop-in"
}
