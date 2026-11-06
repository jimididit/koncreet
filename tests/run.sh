#!/usr/bin/env bash
# Minimal test runner (no bats required). Exit 0 on success.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (got='$got' want='$want')"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local name="$1"
  shift
  if "$@" &>/dev/null; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@" &>/dev/null; then
    echo "  FAIL: $name (expected failure)"
    FAIL=$((FAIL + 1))
  else
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  fi
}

echo "== config parser =="
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT/lib/config.sh"
TMP="$(mktemp)"
cat >"$TMP" <<'EOF'
# comment
modules=baseline,ssh
user=deploy
firewall_public=true
auto_reboot=false
reboot_hour=03:30
EOF
koncreet_config_load "$TMP"
assert_eq "$KONCREET_CFG_MODULES" "baseline,ssh" "modules"
assert_eq "$KONCREET_CFG_USER" "deploy" "user"
assert_ok "firewall_public true" cfg_bool_true "$KONCREET_CFG_FIREWALL_PUBLIC"
assert_fail "auto_reboot false" cfg_bool_true "$KONCREET_CFG_AUTO_REBOOT"
assert_eq "$KONCREET_CFG_REBOOT_HOUR" "03:30" "reboot_hour"
rm -f "$TMP"

echo "== unknown config key =="
TMP="$(mktemp)"
echo "bogus=1" >"$TMP"
if ( koncreet_config_load "$TMP" ) 2>/dev/null; then
  echo "  FAIL: should reject unknown key"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: rejects unknown key"
  PASS=$((PASS + 1))
fi
rm -f "$TMP"

echo "== username validation =="
assert_ok "valid deploy" valid_username deploy
assert_ok "valid a1_b" valid_username a1_b
assert_fail "invalid Root" valid_username Root
assert_fail "invalid has space" valid_username "bad user"
assert_fail "invalid starts digit" valid_username 1abc

echo "== OS family / updates origins =="
# shellcheck source=/dev/null
source "$ROOT/lib/os.sh"
KONCREET_OS_FAMILY=debian
snippet="$(koncreet_updates_origins_snippet)"
assert_ok "debian has Origins-Pattern" grep -q 'Origins-Pattern' <<<"$snippet"
assert_ok "debian has Debian-Security" grep -q 'Debian-Security' <<<"$snippet"
assert_fail "debian should not use Allowed-Origins block alone" grep -q 'Allowed-Origins' <<<"$snippet"

KONCREET_OS_FAMILY=ubuntu
snippet="$(koncreet_updates_origins_snippet)"
assert_ok "ubuntu has Allowed-Origins" grep -q 'Allowed-Origins' <<<"$snippet"
assert_ok "ubuntu has -security" grep -q 'distro_codename}-security' <<<"$snippet"
assert_fail "ubuntu should not use Debian origin=" grep -q 'origin=Debian' <<<"$snippet"

echo "== SSH key file helper =="
# shellcheck source=/dev/null
source "$ROOT/lib/sshd.sh"
EMPTY="$(mktemp)"
: >"$EMPTY"
assert_fail "empty key file" koncreet_has_working_key_file "$EMPTY"
echo "# comment only" >"$EMPTY"
assert_fail "comment-only key file" koncreet_has_working_key_file "$EMPTY"
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialHere user@host" >"$EMPTY"
assert_ok "real-looking key file" koncreet_has_working_key_file "$EMPTY"
rm -f "$EMPTY"

echo "== SSH port parse from fixture =="
FIX="$ROOT/tests/fixtures/sshd_config_sample"
ports="$(
  # mini reimplementation using same regex as lib against fixture
  declare -A P=()
  while read -r line; do
    line="${line%%#*}"
    if [[ "$line" =~ ^[[:space:]]*[Pp]ort[[:space:]]+([0-9]+) ]]; then
      P["${BASH_REMATCH[1]}"]=1
    fi
  done <"$FIX"
  for p in "${!P[@]}"; do echo "$p"; done | sort -n | tr '\n' ' '
)"
ports="${ports%" "}"
assert_eq "$ports" "2222" "fixture Port 2222"

echo "== ssh.socket ListenStream parse =="
assert_eq "$(koncreet_listenstream_port 'ListenStream=22')" "22" "bare port"
assert_eq "$(koncreet_listenstream_port 'ListenStream=0.0.0.0:22')" "22" "ubuntu 24.04 ipv4 form (not 0)"
assert_eq "$(koncreet_listenstream_port 'ListenStream=[::]:2222')" "2222" "ipv6 form"
assert_fail "empty reset line" koncreet_listenstream_port 'ListenStream='
assert_fail "commented out" koncreet_listenstream_port '#ListenStream=22'
# Contract: when no ports are found, koncreet_ssh_listen_ports returns 1 and prints
# nothing (firewall apply refuses). Defaulting to 22 was removed on purpose.

echo "== firewall sensitive gate =="
# shellcheck source=/dev/null
source "$ROOT/modules/firewall.sh"
# die() exits the shell - run checks in subshells
KONCREET_DRY_RUN=1
if ( firewall_apply "ngnix" 0 ) 2>/dev/null; then
  echo "  FAIL: unknown service should abort"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: unknown service aborts"
  PASS=$((PASS + 1))
fi
if ( firewall_apply "mysql" 0 ) 2>/dev/null; then
  echo "  FAIL: mysql without public should abort"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: mysql without --public aborts"
  PASS=$((PASS + 1))
fi
assert_ok "port spec 8080/tcp" firewall_is_port_spec "8080/tcp"
assert_fail "bare port not a spec" firewall_is_port_spec "8080"
if ( firewall_apply "8080" 0 ) 2>/dev/null; then
  echo "  FAIL: bare port should abort"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: bare port aborts"
  PASS=$((PASS + 1))
fi
if ( KONCREET_DRY_RUN=1
     koncreet_ssh_listen_ports() { echo 22; }
     firewall_apply "8080/tcp" 0 ) 2>/dev/null; then
  echo "  PASS: custom port dry-run"
  PASS=$((PASS + 1))
else
  echo "  FAIL: custom port dry-run"
  FAIL=$((FAIL + 1))
fi
# No detected SSH ports: live apply must refuse; dry-run plans the refuse and exits 0.
if ( KONCREET_DRY_RUN=1
     koncreet_ssh_listen_ports() { return 1; }
     firewall_apply "" 0 ) 2>/dev/null; then
  echo "  PASS: dry-run with empty SSH ports plans refuse"
  PASS=$((PASS + 1))
else
  echo "  FAIL: dry-run with empty SSH ports should not die"
  FAIL=$((FAIL + 1))
fi
if ( KONCREET_DRY_RUN=0
     koncreet_ssh_listen_ports() { return 1; }
     firewall_apply "" 0 ) 2>/dev/null; then
  echo "  FAIL: live apply with empty SSH ports should refuse"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: live apply with empty SSH ports refuses"
  PASS=$((PASS + 1))
fi

echo "== config pubkey / firewall_ports =="
# shellcheck source=/dev/null
source "$ROOT/lib/config.sh"
TMP="$(mktemp)"
cat >"$TMP" <<'EOF'
modules=baseline
user=deploy
pubkey_file=/tmp/fake.pub
firewall_ports=8080/tcp
EOF
koncreet_config_load "$TMP"
assert_eq "$KONCREET_CFG_PUBKEY_FILE" "/tmp/fake.pub" "pubkey_file"
assert_eq "$KONCREET_CFG_FIREWALL_PORTS" "8080/tcp" "firewall_ports"
rm -f "$TMP"

echo "== UI / NO_COLOR =="
# shellcheck source=/dev/null
source "$ROOT/lib/ui.sh"
NO_COLOR=1
ui_init
assert_eq "${KONCREET_UI_COLOR}" "0" "NO_COLOR disables color"
unset NO_COLOR
# Force non-TTY path: color stays off when TERM=dumb
TERM=dumb ui_init
assert_eq "${KONCREET_UI_COLOR}" "0" "TERM=dumb disables color"

echo "== version file =="
ver="$(tr -d '[:space:]' <"$ROOT/VERSION")"
assert_ok "VERSION is semver-ish" bash -c "[[ '$ver' =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]"
out="$(bash "$ROOT/koncreet" version 2>/dev/null | head -n1 || true)"
assert_eq "$out" "koncreet $ver" "koncreet version output"

echo "== log path =="
KONCREET_ROOT="$ROOT"
lp="$(KONCREET_DRY_RUN=1 koncreet_log_path)"
assert_ok "dry-run log is not inside the install tree" bash -c "[[ '$lp' != '$ROOT'/* ]]"
assert_eq "$(KONCREET_DRY_RUN=1 koncreet_log_path)" "$(KONCREET_DRY_RUN=0 koncreet_log_path)" "dry-run uses the normal log path"

echo "== ui_run_quiet exit codes =="
KONCREET_ROOT="$ROOT"
KONCREET_DRY_RUN=0
KONCREET_VERBOSE=0
NO_COLOR=1
ui_init
# success
if ui_run_quiet "true" true >/dev/null 2>&1; then
  echo "  PASS: ui_run_quiet success"
  PASS=$((PASS + 1))
else
  echo "  FAIL: ui_run_quiet success"
  FAIL=$((FAIL + 1))
fi
# failure preserves non-zero
set +e
ui_run_quiet "false" false >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "1" "ui_run_quiet preserves failure exit"

echo "== sshd effective-config check =="
# shellcheck source=/dev/null
source "$ROOT/modules/ssh.sh"
good=$'port 22\npasswordauthentication no\npermitrootlogin no\nkbdinteractiveauthentication no'
assert_eq "$(koncreet_sshd_mismatches <<<"$good")" "" "all required settings effective"
overridden="${good/passwordauthentication no/passwordauthentication yes}"
got="$(koncreet_sshd_mismatches <<<"$overridden")"
assert_eq "$got" "passwordauthentication yes (want no)" "cloud-init style override detected"
assert_eq "$(koncreet_sshd_mismatches </dev/null | wc -l | tr -d ' ')" "3" "no sshd -T output fails closed"
assert_eq "$(basename "$KONCREET_SSH_DROPIN")" "00-koncreet.conf" "drop-in sorts before 50-cloud-init.conf"

two_on=$'port 22\npasswordauthentication yes\npermitrootlogin yes\nkbdinteractiveauthentication no'
assert_eq "$(koncreet_sshd_mismatch_summary <<<"$two_on")" "passwordauthentication yes, permitrootlogin yes" "mismatch summary"
assert_eq "$(koncreet_sshd_mismatch_summary <<<"$good")" "" "mismatch summary empty when hardened"

echo "== Match override scan =="
MFIX="$ROOT/tests/fixtures/sshd_match_overrides.conf"
got="$(ssh_match_auth_overrides "$MFIX")"
assert_ok "Match Address block is flagged" grep -q ':7:    PasswordAuthentication yes' <<<"$got"
assert_ok "Match Address header is shown" grep -q ':6:Match Address 203.0.113.0/24' <<<"$got"
assert_ok "lowercase 'match all' with Keyword=value is flagged" grep -q ':10:  permitrootlogin=Yes' <<<"$got"
assert_ok "MATCH + tab + ChallengeResponseAuthentication alias is flagged" grep -q ':13:.ChallengeResponseAuthentication yes' <<<"$got"
assert_fail "block that keeps 'no' is not flagged" grep -q 'Match User safe' <<<"$got"
assert_fail "global lines are not flagged" grep -qE ':(2|3):' <<<"$got"
match_tmp="$(mktemp)"
printf '%s\n' 'PasswordAuthentication yes' 'PermitRootLogin no' >"$match_tmp"
assert_eq "$(ssh_match_auth_overrides "$match_tmp")" "" "file without Match has no overrides"
rm -f "$match_tmp"

echo "== sshd Include following =="
inc="$(mktemp -d)"
mkdir -p "$inc/sshd_config.d" "$inc/extra" "$inc/rel.d"
printf '%s\n' "Include $inc/sshd_config.d/*.conf" "include $inc/extra/*.conf" 'Include rel.d/*.conf' >"$inc/sshd_config"
echo 'Port 22' >"$inc/sshd_config.d/a.conf"
echo 'Port 2200' >"$inc/extra/b.conf"
printf '%s\n' 'Include nested.conf' >"$inc/rel.d/c.conf"
printf '%s\n' 'Match all' '  PasswordAuthentication yes' >"$inc/nested.conf"
files="$(KONCREET_SSHD_CONFIG="$inc/sshd_config" koncreet_sshd_config_files)"
assert_ok "main file listed" grep -qx "$inc/sshd_config" <<<"$files"
assert_ok "stock drop-in listed" grep -qx "$inc/sshd_config.d/a.conf" <<<"$files"
assert_ok "absolute Include listed" grep -qx "$inc/extra/b.conf" <<<"$files"
assert_ok "relative Include listed" grep -qx "$inc/rel.d/c.conf" <<<"$files"
assert_ok "nested Include listed" grep -qx "$inc/nested.conf" <<<"$files"
assert_eq "$(sort <<<"$files" | uniq -d)" "" "no file listed twice"
got="$(KONCREET_SSHD_CONFIG="$inc/sshd_config" ssh_match_auth_overrides)"
assert_ok "Match in a nested Include is flagged" grep -q "nested.conf:2:  PasswordAuthentication yes" <<<"$got"
rm -rf "$inc"

echo "== sudo gate =="
assert_ok "sudo group member" bash -c "source '$ROOT/lib/sshd.sh'; id() { echo 'deploy sudo'; }; koncreet_user_can_sudo deploy"
assert_ok "admin group member" bash -c "source '$ROOT/lib/sshd.sh'; id() { echo 'ubuntu adm admin'; }; koncreet_user_can_sudo ubuntu"
assert_ok "sudoers grant" bash -c "source '$ROOT/lib/sshd.sh'; id() { echo 'ops ops'; }; sudo() { echo 'User ops may run the following commands on h:'; }; koncreet_user_can_sudo ops"
assert_fail "no sudo" bash -c "source '$ROOT/lib/sshd.sh'; id() { echo 'git git'; }; sudo() { echo 'User git is not allowed to run sudo on h.'; }; koncreet_user_can_sudo git"

echo "== client IP detection =="
assert_ok "valid ipv4" koncreet_valid_ip 203.0.113.5
assert_ok "valid ipv4 cidr" koncreet_valid_ip 10.0.0.0/8
assert_ok "valid ipv6" koncreet_valid_ip 2001:db8::1
assert_fail "octet > 255" koncreet_valid_ip 203.0.113.256
assert_fail "hostname" koncreet_valid_ip example.com
assert_fail "sed metachar" koncreet_valid_ip '1.2.3.4|x'
assert_fail "empty" koncreet_valid_ip ""
assert_eq "$(SSH_CONNECTION='203.0.113.5 51234 10.0.0.2 22' koncreet_ssh_client_ip)" "203.0.113.5" "ip from SSH_CONNECTION"
assert_eq "$(SSH_CONNECTION='' SSH_CLIENT='2001:db8::7 51234 22' koncreet_ssh_client_ip)" "2001:db8::7" "ip from SSH_CLIENT"

echo "== fail2ban ignoreip matching =="
# shellcheck source=/dev/null
source "$ROOT/modules/fail2ban.sh"
assert_ok "exact entry listed" fail2ban_ip_listed 1.2.3.4 "127.0.0.1/8 ::1 1.2.3.4"
assert_fail "prefix of another entry" fail2ban_ip_listed 1.2.3.4 "127.0.0.1/8 1.2.3.45"
assert_fail "dots are not wildcards" fail2ban_ip_listed 1.2.3.4 "1x2x3x4"

echo "== doctor / ssh status: effective SSH state =="
# shellcheck source=/dev/null
source "$ROOT/lib/doctor.sh"
SSHD_T_ON=$'port 22\npasswordauthentication yes\npermitrootlogin yes\nkbdinteractiveauthentication no'
SSHD_T_OFF=$'port 22\npasswordauthentication no\npermitrootlogin no\nkbdinteractiveauthentication no'
# ssh_state_case FUNC SSHD_T_OUTPUT ROOT(0/1) [drop-in file names...]
# Runs doctor_ssh_hardening or ssh_status against a fake sshd and a temp sshd_config.d.
ssh_state_case() {
  local fn="$1" sshd_t="$2" as_root="$3"
  shift 3
  (
    d="$(mktemp -d)"
    mkdir -p "$d/sshd_config.d"
    : >"$d/sshd_config"
    for f in "$@"; do echo "PasswordAuthentication no" >"$d/sshd_config.d/$f"; done
    KONCREET_SSHD_CONFIG="$d/sshd_config"
    KONCREET_SSH_DROPIN="$d/sshd_config.d/00-koncreet.conf"
    KONCREET_SSH_LEGACY_DROPINS=("$d/sshd_config.d/99-koncreet.conf" "$d/sshd_config.d/99-harden.conf")
    koncreet_is_root() { [[ "$as_root" -eq 1 ]]; }
    sshd() { [[ "$1" == "-T" ]] && printf '%s\n' "$sshd_t"; return 0; }
    sudo() { echo "SUDO WAS CALLED"; return 1; }
    koncreet_find_nonroot_key_user() { echo newadmin; }
    koncreet_ssh_listen_ports() { echo 22; }
    koncreet_ssh_unit() { echo ssh.service; }
    KONCREET_DOCTOR_WARNS=0
    "$fn"
    echo "WARNS=$KONCREET_DOCTOR_WARNS"
    rm -rf "$d"
  ) 2>&1
}
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_ON" 1)"
assert_ok "doctor: no drop-in + password/root on warns with effective values" \
  grep -q 'SSH hardening not applied: passwordauthentication yes, permitrootlogin yes - run: sudo koncreet ssh apply' <<<"$out"
assert_fail "doctor: no drop-in + on is not all clear (warn counted)" grep -q '^WARNS=0$' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_OFF" 1)"
assert_ok "doctor: no drop-in + all off is OK" grep -q 'already off (no koncreet drop-in)' <<<"$out"
assert_ok "doctor: no drop-in + all off adds no warning" grep -q '^WARNS=0$' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_OFF" 1 00-koncreet.conf)"
assert_ok "doctor: drop-in + all off is OK" grep -q 'password auth + root login off (00-koncreet.conf)' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_ON" 1 00-koncreet.conf)"
assert_ok "doctor: drop-in + overridden warns" grep -q 'SSH harden not fully in effect: passwordauthentication yes' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_OFF" 1 99-hardening.conf)"
assert_ok "doctor: hand-made 99-hardening.conf is not called a koncreet drop-in" grep -q 'already off (no koncreet drop-in)' <<<"$out"
assert_fail "doctor: hand-made 99-hardening.conf is not called legacy" grep -q 'legacy' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_ON" 0)"
assert_ok "doctor as non-root points at sudo koncreet doctor" grep -q 'SSH hardening not checked as .* - run: sudo koncreet doctor' <<<"$out"
assert_fail "doctor as non-root never calls sudo" grep -q 'SUDO WAS CALLED' <<<"$out"
out="$(ssh_state_case ssh_status "$SSHD_T_ON" 1)"
assert_ok "status agrees: not applied + same values" \
  grep -q 'SSH hardening not applied: passwordauthentication yes, permitrootlogin yes - run: sudo koncreet ssh apply' <<<"$out"
out="$(ssh_state_case ssh_status "$SSHD_T_OFF" 1 00-koncreet.conf)"
assert_ok "status agrees: drop-in shown" grep -q 'harden *00-koncreet.conf' <<<"$out"
assert_fail "status agrees: no warning when hardened" grep -q '\[WARN\]' <<<"$out"
out="$(ssh_state_case doctor_ssh_hardening "$SSHD_T_ON" 1 99-koncreet.conf)"
assert_ok "doctor: legacy drop-in still named" grep -q 'legacy 99-koncreet.conf present' <<<"$out"

echo "== SSH skip is logged and reminded =="
skip_log="$(mktemp)"
( koncreet_log_path() { echo "$skip_log"; }; ssh_note_skipped ) >/dev/null 2>&1
assert_ok "skip reason goes to the log" grep -q '\[WARN\] SKIP SSH harden - no non-root sudo user' "$skip_log"
rm -f "$skip_log"
out="$(KONCREET_DRY_RUN=0 ui_post_apply_checklist newadmin 1 2>&1)"
assert_ok "checklist: SSH not hardened step" grep -q 'SSH is NOT hardened yet' <<<"$out"
assert_ok "checklist: names the user and the command" \
  grep -q 'log in as newadmin and run sudo -v, run: sudo koncreet ssh apply' <<<"$out"
out="$(KONCREET_DRY_RUN=0 ui_post_apply_checklist newadmin 0 2>&1)"
assert_fail "checklist: no SSH step when not skipped" grep -q 'NOT hardened' <<<"$out"
out="$(KONCREET_DRY_RUN=1 ui_post_apply_checklist newadmin 1 2>&1)"
assert_eq "$out" "" "checklist: dry-run prints nothing"
out="$(KONCREET_DRY_RUN=0 ui_done_summary ssh 2>&1)"
assert_ok "done line counts the skipped module" grep -q 'Done - 1 module skipped (ssh)' <<<"$out"
out="$(KONCREET_DRY_RUN=0 ui_done_summary 2>&1)"
assert_ok "done line without skips" grep -qE '^Done in ' <<<"$out"

echo "== generated password file freshness =="
pw_dir="$(mktemp -d)"
pw_file="$pw_dir/deploy.koncreet-password"
echo 's3cret' >"$pw_file"
touch -d '2026-01-10 12:00:00' "$pw_file"
pw_day=$(( $(stat -c %Y "$pw_file") / 86400 ))
pw_state() {  # pw_state SHADOW_HASH LASTCHG_DAY
  local h="$1" day="$2"
  ( getent() { echo "deploy:$h:$day:0:99999:7:::"; }; koncreet_passfile_state deploy "$pw_file" ) || return $?
}
# Hash check is exact (catches a same-day passwd), but needs a libc crypt with sha512.
sha="$(KP=s3cret perl -e 'my $h = crypt($ENV{KP}, q($6$koncreet$)); print defined $h ? $h : ""' 2>/dev/null || true)"
if [[ "$sha" == '$6$koncreet$'* ]]; then
  rc=0; pw_state "$sha" "$pw_day" || rc=$?
  assert_eq "$rc" "0" "password file matches the shadow hash: current"
  other="$(KP=changed perl -e 'print crypt($ENV{KP}, q($6$koncreet$))')"
  rc=0; pw_state "$other" "$pw_day" || rc=$?
  assert_eq "$rc" "1" "password changed the same day: stale"
else
  echo "  SKIP: perl crypt has no sha512 here; hash checks run in CI"
fi
rc=0; pw_state '!' "$((pw_day + 3))" || rc=$?
assert_eq "$rc" "3" "unverifiable hash + later shadow change: possibly stale"
rc=0; pw_state '!' "$pw_day" || rc=$?
assert_eq "$rc" "2" "unverifiable hash + no later change: unknown (keep prompting)"
rm -rf "$pw_dir"

echo "== login MOTD warns while SSH is not hardened =="
# shellcheck source=/dev/null
source "$ROOT/modules/baseline.sh"
motd_dir="$(mktemp -d)"
mkdir -p "$motd_dir/bin"
printf '#!/bin/sh\nshift\nexec "$@"\n' >"$motd_dir/bin/timeout"
printf '#!/bin/sh\nprintf "%%s\\n" "passwordauthentication yes" "permitrootlogin yes"\n' >"$motd_dir/bin/sshd"
chmod +x "$motd_dir/bin/timeout" "$motd_dir/bin/sshd"
(
  KONCREET_DRY_RUN=0
  KONCREET_MOTD="$motd_dir/99-koncreet"
  KONCREET_SSH_DROPIN="$motd_dir/00-koncreet.conf"
  koncreet_log_path() { echo "$motd_dir/log"; }
  baseline_write_motd
) >/dev/null 2>&1
out="$(PATH="$motd_dir/bin:$PATH" sh "$motd_dir/99-koncreet")"
assert_ok "MOTD warns with no drop-in and password login on" grep -q 'SSH password or root login is still on' <<<"$out"
touch "$motd_dir/00-koncreet.conf"
out="$(PATH="$motd_dir/bin:$PATH" sh "$motd_dir/99-koncreet")"
assert_fail "MOTD is quiet once the drop-in exists" grep -q 'still on' <<<"$out"
rm -f "$motd_dir/00-koncreet.conf" "$motd_dir/bin/sshd"
out="$(PATH="$motd_dir/bin:$PATH" sh "$motd_dir/99-koncreet"; echo "rc=$?")"
assert_ok "MOTD without sshd exits 0" grep -q 'rc=0' <<<"$out"
rm -rf "$motd_dir"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
