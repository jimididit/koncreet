#!/usr/bin/env bash
# ssh harden: check / apply / undo - non-root key gate required
# shellcheck shell=bash

KONCREET_SSH_DROPIN="/etc/ssh/sshd_config.d/99-koncreet.conf"

ssh_plan_lines() {
  printf '%s\n' \
    "Require non-root user with authorized_keys before disabling root login" \
    "Write $KONCREET_SSH_DROPIN (PasswordAuthentication no, PermitRootLogin no, extras)" \
    "sshd -t then reload SSH unit"
}

ssh_check() {
  local user
  if user="$(koncreet_ssh_harden_gate)"; then
    log_ok "safe to harden - '$user' has SSH keys"
    return 0
  fi
  return 1
}

ssh_apply() {
  local safe_user
  if ! safe_user="$(koncreet_ssh_harden_gate)"; then
    if [[ "${SUDO_USER:-root}" == "root" || "${EUID:-0}" -eq 0 ]]; then
      log_error "Operating as root without a non-root key user"
      log_error "Run: koncreet baseline apply --user YOURNAME  then re-run ssh apply"
    fi
    die "Refusing to disable password auth / root login"
  fi

  write_file "$KONCREET_SSH_DROPIN" <<'EOF'
# Managed by koncreet - remove this file (or: koncreet ssh undo) to revert.
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "sshd -t && reload SSH"
    ui_muted "Would harden SSH; test: ssh ${safe_user}@host"
    return 0
  fi

  ui_step_start "validate sshd config"
  if ! sshd -t 2>/dev/null; then
    ui_step_fail "sshd -t failed - rolling back"
    rm -f "$KONCREET_SSH_DROPIN"
    exit 1
  fi
  ui_step_ok "sshd config valid"
  koncreet_ssh_reload
  log_ok "password auth + root login disabled"
  ui_warn "Keep this session open - test: ssh ${safe_user}@<host>"
  ui_muted "  if locked out: sudo koncreet ssh undo"
}

ssh_undo() {
  if [[ ! -f "$KONCREET_SSH_DROPIN" ]]; then
    if [[ -f /etc/ssh/sshd_config.d/99-harden.conf ]]; then
      if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
        plan "rm /etc/ssh/sshd_config.d/99-harden.conf && reload"
        return 0
      fi
      rm -f /etc/ssh/sshd_config.d/99-harden.conf
      koncreet_ssh_reload
      log_ok "removed legacy 99-harden.conf"
      return 0
    fi
    ui_skip "nothing to undo"
    return 0
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "rm $KONCREET_SSH_DROPIN && reload SSH"
    return 0
  fi
  backup_file "$KONCREET_SSH_DROPIN"
  rm -f "$KONCREET_SSH_DROPIN"
  koncreet_ssh_reload
  log_ok "SSH harden drop-in removed (package defaults apply)"
}

ssh_status() {
  ui_header "ssh"
  if [[ -f "$KONCREET_SSH_DROPIN" ]]; then
    ui_kv "harden" "99-koncreet.conf"
    ui_kv "PasswordAuth" "$(grep -E '^PasswordAuthentication' "$KONCREET_SSH_DROPIN" | awk '{print $2}')"
    ui_kv "PermitRoot" "$(grep -E '^PermitRootLogin' "$KONCREET_SSH_DROPIN" | awk '{print $2}')"
  elif [[ -f /etc/ssh/sshd_config.d/99-harden.conf ]]; then
    ui_kv "harden" "legacy 99-harden.conf"
  else
    ui_kv "harden" "not applied"
  fi
  ui_kv "unit" "$(koncreet_ssh_unit)"
  ui_kv "ports" "$(koncreet_ssh_listen_ports | tr '\n' ' ' | sed 's/ $//')"
  local u
  if u="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    ui_kv "key user" "$u"
  else
    ui_kv "key user" "NONE"
  fi
}
