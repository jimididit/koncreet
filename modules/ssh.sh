#!/usr/bin/env bash
# ssh harden: check / apply / undo — non-root key gate required
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
    echo "OK: '$user' can still log in with keys after hardening."
    return 0
  fi
  return 1
}

ssh_apply() {
  local safe_user
  if ! safe_user="$(koncreet_ssh_harden_gate)"; then
    if [[ "${SUDO_USER:-root}" == "root" || "${EUID:-0}" -eq 0 ]]; then
      log_error "You appear to be operating as root without a non-root key user."
      log_error "Run: koncreet baseline apply --user YOURNAME   then copy your key, then re-run ssh apply."
    fi
    die "Refusing to disable password auth / root login."
  fi

  write_file "$KONCREET_SSH_DROPIN" <<'EOF'
# Managed by koncreet — remove this file (or: koncreet ssh undo) to revert.
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "sshd -t && reload SSH"
    log_info "Would harden SSH; keep a session open and test: ssh ${safe_user}@host"
    return 0
  fi

  log_info "Validating sshd config"
  if ! sshd -t; then
    log_error "sshd -t failed — rolling back, nothing applied."
    rm -f "$KONCREET_SSH_DROPIN"
    exit 1
  fi

  koncreet_ssh_reload
  echo
  log_info "Done. Keep this session open and test a NEW connection:"
  echo "  ssh ${safe_user}@<this-host>"
  echo "If the new connection fails: sudo koncreet ssh undo"
}

ssh_undo() {
  if [[ ! -f "$KONCREET_SSH_DROPIN" ]]; then
    # also remove legacy drop-in from old harden-ssh.sh
    if [[ -f /etc/ssh/sshd_config.d/99-harden.conf ]]; then
      if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
        plan "rm /etc/ssh/sshd_config.d/99-harden.conf && reload"
        return 0
      fi
      rm -f /etc/ssh/sshd_config.d/99-harden.conf
      koncreet_ssh_reload
      log_info "Removed legacy 99-harden.conf"
      return 0
    fi
    log_info "Nothing to undo — $KONCREET_SSH_DROPIN does not exist."
    return 0
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "rm $KONCREET_SSH_DROPIN && reload SSH"
    return 0
  fi
  backup_file "$KONCREET_SSH_DROPIN"
  rm -f "$KONCREET_SSH_DROPIN"
  koncreet_ssh_reload
  log_info "Reverted: password auth and root login policy removed (package defaults apply)."
}

ssh_status() {
  echo "--- ssh ---"
  if [[ -f "$KONCREET_SSH_DROPIN" ]]; then
    echo "harden drop-in: $KONCREET_SSH_DROPIN present"
    grep -E '^(PasswordAuthentication|PermitRootLogin|MaxAuthTries|ClientAlive)' "$KONCREET_SSH_DROPIN" || true
  elif [[ -f /etc/ssh/sshd_config.d/99-harden.conf ]]; then
    echo "harden drop-in: legacy 99-harden.conf present"
  else
    echo "harden drop-in: not applied"
  fi
  echo "unit: $(koncreet_ssh_unit)"
  echo "listen ports:"
  koncreet_ssh_listen_ports | sed 's/^/  /'
  local u
  if u="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    echo "non-root key user: $u"
  else
    echo "non-root key user: NONE (unsafe to harden)"
  fi
}
