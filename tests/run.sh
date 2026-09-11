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

echo "== firewall sensitive gate =="
# shellcheck source=/dev/null
source "$ROOT/modules/firewall.sh"
# die() exits the shell — run checks in subshells
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

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
