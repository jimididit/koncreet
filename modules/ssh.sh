#!/usr/bin/env bash
# ssh harden: check / apply / undo - non-root sudo+key gate required
# shellcheck shell=bash

# sshd keeps the FIRST value it reads for each keyword, and Debian/Ubuntu include
# sshd_config.d/*.conf in lexical order at the top of sshd_config. A 00- prefix
# makes our drop-in win over e.g. cloud-init's 50-cloud-init.conf.
KONCREET_SSH_DROPIN="/etc/ssh/sshd_config.d/00-koncreet.conf"
# Older koncreet drop-ins; removed on apply/undo.
KONCREET_SSH_LEGACY_DROPINS=(
  "/etc/ssh/sshd_config.d/99-koncreet.conf"
  "/etc/ssh/sshd_config.d/99-harden.conf"
)

# Settings that must be in effect after apply, as "sshd -T" keyword + value.
KONCREET_SSH_REQUIRED=(
  "passwordauthentication no"
  "permitrootlogin no"
  "kbdinteractiveauthentication no"
)

ssh_plan_lines() {
  printf '%s\n' \
    "Require non-root sudo user with authorized_keys before disabling root login" \
    "Write $KONCREET_SSH_DROPIN (PasswordAuthentication no, PermitRootLogin no, extras)" \
    "sshd -t, verify effective settings with sshd -T, then reload SSH unit"
}

# Read "sshd -T" output on stdin; print each required setting whose effective value differs.
koncreet_sshd_mismatches() {
  local out want key got
  out="$(cat)"
  for want in "${KONCREET_SSH_REQUIRED[@]}"; do
    key="${want%% *}"
    got="$(awk -v k="$key" '$1 == k { print $2; exit }' <<<"$out")"
    [[ "$got" == "${want#* }" ]] || echo "$key ${got:-unset} (want ${want#* })"
  done
}

# Print config lines outside our drop-in that set a required keyword to something
# other than "no", plus Match blocks (which can re-enable them per user/address).
ssh_conflicting_lines() {
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" && "$f" != "$KONCREET_SSH_DROPIN" ]] || continue
    awk -v f="$f" '
      { k = tolower($1); v = tolower($2) }
      k == "match" || ((k == "passwordauthentication" || k == "permitrootlogin" || k == "kbdinteractiveauthentication") && v != "no") {
        print f ":" FNR ":" $0
      }' "$f"
  done
}

# Put the drop-in back the way it was before this apply.
ssh_rollback_dropin() {
  local had_prev="${1:-0}"
  if [[ "$had_prev" -eq 1 && -f "${KONCREET_SSH_DROPIN}.koncreet.bak" ]]; then
    cp -a "${KONCREET_SSH_DROPIN}.koncreet.bak" "$KONCREET_SSH_DROPIN"
  else
    rm -f "$KONCREET_SSH_DROPIN"
  fi
}

# baseline stores the generated sudo password only under /root. Once root login is
# off, reading it needs sudo - which needs that password. Make sure it was saved.
ssh_confirm_sudo_password() {
  local user="$1"
  local passfile="/root/${user}.koncreet-password"
  [[ -f "$passfile" ]] || return 0
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "confirm the sudo password for $user ($passfile) is saved"
    return 0
  fi
  ui_warn "sudo for '$user' uses the password koncreet generated: $(cat "$passfile")"
  ui_muted "  it is only stored in $passfile, which you cannot read once root login is off"
  if ! confirm "Have you saved this password (or set your own with: passwd $user)?"; then
    die "Refusing to disable root login until the sudo password for $user is saved"
  fi
}

ssh_check() {
  local user
  if user="$(koncreet_ssh_harden_gate)"; then
    log_ok "safe to harden - '$user' has SSH keys and sudo"
    return 0
  fi
  return 1
}

ssh_apply() {
  local safe_user
  if ! safe_user="$(koncreet_ssh_harden_gate)"; then
    die "Refusing to disable password auth / root login"
  fi
  ssh_confirm_sudo_password "$safe_user"

  local had_prev=0
  [[ -f "$KONCREET_SSH_DROPIN" ]] && had_prev=1

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
    plan "sshd -t && verify sshd -T && reload SSH"
    local f
    for f in "${KONCREET_SSH_LEGACY_DROPINS[@]}"; do
      [[ -f "$f" ]] && plan "rm legacy $f"
    done
    ui_muted "Would harden SSH; test: ssh ${safe_user}@host"
    return 0
  fi

  ui_step_start "validate sshd config"
  if ! sshd -t 2>/dev/null; then
    ui_step_fail "sshd -t failed - rolling back"
    ssh_rollback_dropin "$had_prev"
    die "sshd rejected the config - nothing changed"
  fi
  ui_step_ok "sshd config valid"

  local -a bad=()
  mapfile -t bad < <(sshd -T 2>/dev/null | koncreet_sshd_mismatches)
  if [[ "${#bad[@]}" -gt 0 ]]; then
    ui_step_fail "other sshd config overrides koncreet - rolling back"
    local m line
    for m in "${bad[@]}"; do log_error "  effective: $m"; done
    log_error "sshd uses the first value it reads. Lines that may be winning:"
    while IFS= read -r line; do log_error "  $line"; done < <(ssh_conflicting_lines)
    ssh_rollback_dropin "$had_prev"
    die "Fix or remove those lines, then re-run: koncreet ssh apply"
  fi
  ui_step_ok "effective: password auth, keyboard-interactive, root login off"

  local f
  for f in "${KONCREET_SSH_LEGACY_DROPINS[@]}"; do
    [[ -f "$f" ]] || continue
    backup_file "$f"
    rm -f "$f"
    _log_file INFO "Removed legacy $f"
  done

  koncreet_ssh_reload
  log_ok "password auth + root login disabled"
  ui_warn "Keep this session open - test: ssh ${safe_user}@<host>  then: sudo -v"
  ui_muted "  if locked out: sudo koncreet ssh undo"
}

ssh_undo() {
  local f removed=0
  for f in "$KONCREET_SSH_DROPIN" "${KONCREET_SSH_LEGACY_DROPINS[@]}"; do
    [[ -f "$f" ]] || continue
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "rm $f"
    else
      backup_file "$f"
      rm -f "$f"
      log_ok "removed $f"
    fi
    removed=1
  done
  if [[ "$removed" -eq 0 ]]; then
    ui_skip "nothing to undo"
    return 0
  fi
  koncreet_ssh_reload
  [[ "$KONCREET_DRY_RUN" -eq 1 ]] || log_ok "SSH harden drop-in removed (package defaults apply)"
}

ssh_status() {
  ui_header "ssh"
  local f dropin="" legacy=0
  if [[ -f "$KONCREET_SSH_DROPIN" ]]; then
    dropin="$(basename "$KONCREET_SSH_DROPIN")"
  else
    for f in "${KONCREET_SSH_LEGACY_DROPINS[@]}"; do
      if [[ -f "$f" ]]; then
        dropin="legacy $(basename "$f")"
        legacy=1
        break
      fi
    done
  fi
  ui_kv "harden" "${dropin:-not applied}"

  local eff m
  if eff="$(sshd -T 2>/dev/null)"; then
    ui_kv "PasswordAuth" "$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$eff") (effective)"
    ui_kv "PermitRoot" "$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$eff") (effective)"
    if [[ -n "$dropin" ]]; then
      while IFS= read -r m; do
        [[ -n "$m" ]] && ui_warn "overridden: $m"
      done < <(koncreet_sshd_mismatches <<<"$eff")
    fi
  else
    ui_kv "effective" "unknown (sshd -T failed)"
  fi
  [[ "$legacy" -eq 1 ]] && ui_muted "  re-run: koncreet ssh apply  (moves to $(basename "$KONCREET_SSH_DROPIN"))"

  ui_kv "unit" "$(koncreet_ssh_unit)"
  ui_kv "ports" "$(koncreet_ssh_listen_ports | tr '\n' ' ' | sed 's/ $//')"
  local u
  if u="$(koncreet_find_nonroot_key_user sudo 2>/dev/null)"; then
    ui_kv "admin user" "$u (keys + sudo)"
  elif u="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    ui_kv "admin user" "NONE ($u has keys but no sudo)"
  else
    ui_kv "admin user" "NONE"
  fi
}
