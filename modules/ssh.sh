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
    "sshd -t, verify effective settings with sshd -T (global + Match criteria), then reload SSH unit"
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

# Same as koncreet_sshd_mismatches, as one line: "passwordauthentication yes, permitrootlogin yes".
koncreet_sshd_mismatch_summary() {
  koncreet_sshd_mismatches | sed 's/ (want .*)$//' | paste -sd, - | sed 's/,/, /g'
}

# The koncreet SSH drop-in that is in place (current name first, then legacy names).
koncreet_ssh_active_dropin() {
  local f
  for f in "$KONCREET_SSH_DROPIN" "${KONCREET_SSH_LEGACY_DROPINS[@]}"; do
    if [[ -f "$f" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

# awk prologue shared by the config scanners. Splits "Keyword value",
# "Keyword=value" and "Keyword = value" into lowercase k and v, ignoring
# comments and indentation. ChallengeResponseAuthentication is the old name
# for KbdInteractiveAuthentication and sshd still honours it.
KONCREET_SSHD_AWK_KV='
  {
    line = $0
    sub(/#.*/, "", line)
    sub(/^[ \t]+/, "", line)
    sub(/[ \t]*=[ \t]*/, " ", line)
    split(line, w, /[ \t]+/)
    k = tolower(w[1]); v = tolower(w[2]); gsub(/"/, "", v)
    if (k == "challengeresponseauthentication") k = "kbdinteractiveauthentication"
    auth = (k == "passwordauthentication" || k == "permitrootlogin" || k == "kbdinteractiveauthentication")
  }
'

# Match blocks can re-enable auth settings that a global "sshd -T" still reports as no,
# and the -C probes in ssh_apply only cover local connections. Print each Match header
# plus the lines under it that set a required keyword to something other than no.
# Scans the given files, or every file sshd reads (see koncreet_sshd_config_files).
ssh_match_auth_overrides() {
  local -a files=("$@")
  [[ "${#files[@]}" -gt 0 ]] || mapfile -t files < <(koncreet_sshd_config_files)
  local f
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    awk -v f="$f" "$KONCREET_SSHD_AWK_KV"'
      k == "match" { in_match = 1; hdr = $0; hl = FNR; next }
      in_match && auth && v != "no" {
        print f ":" hl ":" hdr
        print f ":" FNR ":" $0
      }' "$f"
  done
}

# Print config lines outside our drop-in that set a required keyword to something
# other than "no", plus Match blocks (which can re-enable them per user/address).
ssh_conflicting_lines() {
  local f
  while IFS= read -r f; do
    [[ -f "$f" && "$f" != "$KONCREET_SSH_DROPIN" ]] || continue
    awk -v f="$f" "$KONCREET_SSHD_AWK_KV"'
      k == "match" || (auth && v != "no") { print f ":" FNR ":" $0 }' "$f"
  done < <(koncreet_sshd_config_files)
}

# Run sshd -T (optionally with -C criteria). Print mismatches; return 1 if any.
ssh_collect_mismatches() {
  local label="$1"
  shift
  local -a bad=()
  local m
  mapfile -t bad < <(sshd -T "$@" 2>/dev/null | koncreet_sshd_mismatches)
  if [[ "${#bad[@]}" -eq 0 ]]; then
    return 0
  fi
  log_error "  [$label]"
  for m in "${bad[@]}"; do log_error "    effective: $m"; done
  return 1
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

# Is the password in the file koncreet generated still the user's password?
# Exit status: 0 = current (hash verified), 1 = stale (hash verified, differs),
# 2 = cannot tell, 3 = cannot verify the hash but /etc/shadow records a change on
# a later day than the file was written (a later baseline run's chage -d also
# bumps that date, so this alone is not proof). Needs root to read the shadow entry.
koncreet_passfile_state() {
  local user="$1" passfile="$2" entry hash lastchg got mday
  entry="$(getent shadow "$user" 2>/dev/null)" || return 2
  hash="$(cut -d: -f2 <<<"$entry")"
  lastchg="$(cut -d: -f3 <<<"$entry")"
  if [[ "$hash" == \$* ]] && command -v perl >/dev/null 2>&1; then
    # perl crypt() is libc crypt, so it understands yescrypt and sha512 hashes.
    # Values go through the environment, not argv, so ps cannot show them.
    got="$(KONCREET_PW="$(head -n1 "$passfile")" KONCREET_HASH="$hash" \
      perl -e 'my $h = crypt($ENV{KONCREET_PW}, $ENV{KONCREET_HASH}); print defined $h ? $h : ""' 2>/dev/null)"
    if [[ "$got" == "$hash" ]]; then
      return 0
    elif [[ "$got" == \$* && "${#got}" -gt 20 ]]; then
      return 1
    fi
  fi
  [[ "$lastchg" =~ ^[0-9]+$ ]] || return 2
  mday=$(( $(stat -c %Y "$passfile") / 86400 ))
  (( lastchg > mday )) && return 3
  return 2
}

# baseline stores the generated sudo password only under /root. Once root login is
# off, reading it needs sudo - which needs that password. Make sure it was saved.
ssh_confirm_sudo_password() {
  local user="$1"
  local passfile="/root/${user}.koncreet-password"
  [[ -f "$passfile" ]] || return 0
  local state=0
  koncreet_passfile_state "$user" "$passfile" || state=$?
  if [[ "$state" -eq 1 ]]; then
    # The user set their own password, so this file is only a misleading leftover.
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "remove $passfile ($user changed their password since koncreet generated it)"
      return 0
    fi
    rm -f "$passfile"
    log_warn "$passfile no longer matched $user's password (it was changed since koncreet generated it) - removed it"
    return 0
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "confirm the sudo password for $user ($passfile) is saved"
    return 0
  fi
  if [[ "$state" -eq 3 ]]; then
    ui_warn "sudo for '$user' may still use the password koncreet generated: $(cat "$passfile")"
    ui_muted "  /etc/shadow shows a password change after $passfile was written; if you set your own, delete that file"
  else
    ui_warn "sudo for '$user' uses the password koncreet generated: $(cat "$passfile")"
  fi
  ui_muted "  it is only stored in $passfile, which you cannot read once root login is off"
  if ! confirm "Have you saved this password (or set your own with: passwd $user)?"; then
    die "Refusing to disable root login until the sudo password for $user is saved"
  fi
}

# Why a multi-module run leaves SSH alone, and what to do next.
ssh_skip_reason() {
  echo "SSH harden - no non-root sudo user with SSH keys before this run. Once you can log in as that user and sudo, run: koncreet ssh apply"
}

# A run that was asked to harden SSH but could not. ui_skip only reaches the
# terminal, so also put it in the log where it can be found later.
ssh_note_skipped() {
  local reason
  reason="$(ssh_skip_reason)"
  ui_skip "$reason"
  _log_file WARN "SKIP $reason"
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

  local failed=0 line
  ssh_collect_mismatches "global" || failed=1
  # Global sshd -T ignores Match. Probe root and the admin user so a Match User
  # block cannot quietly re-enable password auth or root login.
  ssh_collect_mismatches "Match criteria user=root" -C "user=root,host=localhost,addr=127.0.0.1" || failed=1
  ssh_collect_mismatches "Match criteria user=${safe_user}" -C "user=${safe_user},host=localhost,addr=127.0.0.1" || failed=1

  local -a match_hits=()
  mapfile -t match_hits < <(ssh_match_auth_overrides)
  if [[ "${#match_hits[@]}" -gt 0 ]]; then
    failed=1
    log_error "  [Match block re-enables a required setting]"
    for line in "${match_hits[@]}"; do log_error "    $line"; done
  fi

  if [[ "$failed" -ne 0 ]]; then
    ui_step_fail "sshd effective config still allows password/root login - rolling back"
    log_error "sshd keeps the first global value, but Match can override per connection. Review:"
    while IFS= read -r line; do log_error "  $line"; done < <(ssh_conflicting_lines)
    ssh_rollback_dropin "$had_prev"
    die "Fix or remove those lines, then re-run: koncreet ssh apply"
  fi
  ui_step_ok "effective: password auth, keyboard-interactive, root login off (global + Match probes)"

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
  local dropin="" legacy=0
  if dropin="$(koncreet_ssh_active_dropin)"; then
    [[ "$dropin" != "$KONCREET_SSH_DROPIN" ]] && legacy=1
  else
    dropin=""
  fi
  if [[ "$legacy" -eq 1 ]]; then
    ui_kv "harden" "legacy $(basename "$dropin")"
  elif [[ -n "$dropin" ]]; then
    ui_kv "harden" "$(basename "$dropin")"
  else
    ui_kv "harden" "not applied"
  fi

  local eff m bad
  if eff="$(sshd -T 2>/dev/null)"; then
    ui_kv "PasswordAuth" "$(awk '$1 == "passwordauthentication" { print $2 }' <<<"$eff") (effective)"
    ui_kv "PermitRoot" "$(awk '$1 == "permitrootlogin" { print $2 }' <<<"$eff") (effective)"
    bad="$(koncreet_sshd_mismatch_summary <<<"$eff")"
    if [[ -n "$dropin" ]]; then
      while IFS= read -r m; do
        [[ -n "$m" ]] && ui_warn "overridden: $m"
      done < <(koncreet_sshd_mismatches <<<"$eff")
    elif [[ -n "$bad" ]]; then
      ui_warn "SSH hardening not applied: $bad - run: sudo koncreet ssh apply"
    else
      ui_muted "  password auth, keyboard-interactive and root login already off (no koncreet drop-in)"
    fi
    while IFS= read -r m; do
      [[ -n "$m" ]] && ui_warn "Match override: $m"
    done < <(ssh_match_auth_overrides)
  else
    ui_kv "effective" "unknown (sshd -T failed - run as root)"
  fi
  [[ "$legacy" -eq 1 ]] && ui_muted "  re-run: koncreet ssh apply  (moves to $(basename "$KONCREET_SSH_DROPIN"))"

  ui_kv "unit" "$(koncreet_ssh_unit)"
  local ports
  ports="$(koncreet_ssh_listen_ports 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
  ui_kv "ports" "${ports:-undetected}"
  local u
  if u="$(koncreet_find_nonroot_key_user sudo 2>/dev/null)"; then
    ui_kv "admin user" "$u (keys + sudo)"
  elif u="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    ui_kv "admin user" "NONE ($u has keys but no sudo)"
  else
    ui_kv "admin user" "NONE"
  fi
}
