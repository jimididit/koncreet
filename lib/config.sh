#!/usr/bin/env bash
# Parse key=value koncreet.conf (no shell eval)
# shellcheck shell=bash

# Defaults (exported as KONCREET_CFG_*)
koncreet_config_defaults() {
  KONCREET_CFG_MODULES="baseline,firewall,fail2ban,updates,ssh"
  KONCREET_CFG_USER=""
  KONCREET_CFG_FIREWALL_SERVICES=""
  KONCREET_CFG_FIREWALL_PORTS=""
  KONCREET_CFG_FAIL2BAN_SERVICES="ssh"
  KONCREET_CFG_SSH_HARDEN="true"
  KONCREET_CFG_AUTO_REBOOT="false"
  KONCREET_CFG_REBOOT_HOUR="04:00"
  KONCREET_CFG_FIREWALL_PUBLIC="false"
  KONCREET_CFG_TIMEZONE=""
  KONCREET_CFG_PUBKEY=""
  KONCREET_CFG_PUBKEY_FILE=""
}

koncreet_config_load() {
  local file="$1"
  koncreet_config_defaults
  [[ -n "$file" ]] || return 0
  [[ -f "$file" ]] || die "Config not found: $file"

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip CR, comments, blanks
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      die "Invalid config line: $line"
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    # strip optional quotes
    if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"; fi
    if [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    case "$key" in
      modules) KONCREET_CFG_MODULES="$val" ;;
      user) KONCREET_CFG_USER="$val" ;;
      firewall_services) KONCREET_CFG_FIREWALL_SERVICES="$val" ;;
      firewall_ports) KONCREET_CFG_FIREWALL_PORTS="$val" ;;
      fail2ban_services) KONCREET_CFG_FAIL2BAN_SERVICES="$val" ;;
      ssh_harden) KONCREET_CFG_SSH_HARDEN="$val" ;;
      auto_reboot) KONCREET_CFG_AUTO_REBOOT="$val" ;;
      reboot_hour) KONCREET_CFG_REBOOT_HOUR="$val" ;;
      firewall_public) KONCREET_CFG_FIREWALL_PUBLIC="$val" ;;
      timezone) KONCREET_CFG_TIMEZONE="$val" ;;
      pubkey) KONCREET_CFG_PUBKEY="$val" ;;
      pubkey_file) KONCREET_CFG_PUBKEY_FILE="$val" ;;
      *) die "Unknown config key: $key" ;;
    esac
  done <"$file"
  log_info "Loaded config $file"
}

# Export bool helpers
cfg_bool_true() {
  case "${1:-}" in
    true|True|TRUE|yes|Yes|1) return 0 ;;
    *) return 1 ;;
  esac
}
