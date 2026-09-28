#!/usr/bin/env bash
# Integration tests against a real sshd, sudo and ufw rule parser.
# DESTRUCTIVE: creates users and rewrites /etc/ssh. Run only in a throwaway
# Debian/Ubuntu container as root, e.g.:
#   docker run --rm -v "$PWD":/k -w /k -e KONCREET_INTEGRATION_OK=1 ubuntu:24.04 bash tests/integration.sh
# Containers have no systemd, so systemctl/timedatectl/swapon are stubbed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

if [[ "${KONCREET_INTEGRATION_OK:-0}" != "1" ]]; then
  echo "Refusing: this test rewrites /etc/ssh and creates users." >&2
  echo "Run it in a throwaway container with KONCREET_INTEGRATION_OK=1." >&2
  exit 2
fi
[[ "${EUID:-$(id -u)}" -eq 0 ]] || { echo "Run as root" >&2; exit 2; }

ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

export NO_COLOR=1 DEBIAN_FRONTEND=noninteractive
if ! command -v sshd >/dev/null || ! command -v sudo >/dev/null || ! command -v ufw >/dev/null \
  || ! command -v openssl >/dev/null; then
  apt-get update -qq >/dev/null
  apt-get install -y -qq openssh-server sudo ufw openssl >/dev/null
fi
mkdir -p /run/sshd
ssh-keygen -A >/dev/null

STUBS="$(mktemp -d)"
for c in systemctl timedatectl; do
  printf '#!/bin/sh\nexit 0\n' >"$STUBS/$c"
done
# pretend swap is active so baseline does not try swapon in a container
printf '#!/bin/sh\necho "/swapfile file 1G 0B -2"\n' >"$STUBS/swapon"
chmod +x "$STUBS"/*
export PATH="$STUBS:$PATH"

DROPIN_DIR=/etc/ssh/sshd_config.d
DROPIN="$DROPIN_DIR/00-koncreet.conf"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialHere me@laptop"
koncreet() { bash "$ROOT/koncreet" "$@"; }
# True if no koncreet SSH drop-in exists under any name (old or new).
no_dropin() { ! compgen -G "$DROPIN_DIR/*koncreet*.conf" >/dev/null; }
effective() { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { print $2; exit }'; }

reset_ssh() {
  rm -f "$DROPIN_DIR"/*koncreet* "$DROPIN_DIR"/00-aaa.conf "$DROPIN_DIR"/50-cloud-init.conf
}
make_user() {  # make_user NAME [sudo]
  userdel -r "$1" >/dev/null 2>&1 || true
  useradd -m -s /bin/bash "$1"
  [[ "${2:-}" == "sudo" ]] && usermod -aG sudo "$1"
  mkdir -p "/home/$1/.ssh"
  echo "$KEY" >"/home/$1/.ssh/authorized_keys"
}

echo "== cloud-init override loses to 00-koncreet.conf =="
reset_ssh
make_user deploy sudo
echo 'PasswordAuthentication yes' >"$DROPIN_DIR/50-cloud-init.conf"
check "ssh apply succeeds" koncreet --yes ssh apply >/dev/null 2>&1
check "effective passwordauthentication no" [ "$(effective passwordauthentication)" = "no" ]
check "effective permitrootlogin no" [ "$(effective permitrootlogin)" = "no" ]
check "ssh status shows effective value" \
  bash -c "bash '$ROOT/koncreet' ssh status 2>&1 | grep -q 'PasswordAuth *no (effective)'"

echo "== earlier override is refused and rolled back =="
reset_ssh
echo 'PasswordAuthentication yes' >"$DROPIN_DIR/00-aaa.conf"
out="$(koncreet --yes ssh apply 2>&1)"; rc=$?
check "ssh apply fails" [ "$rc" -ne 0 ]
check "drop-in rolled back" no_dropin
check "names the overriding file" grep -q '00-aaa.conf:1:PasswordAuthentication yes' <<<"$out"

echo "== legacy 99-koncreet.conf is migrated =="
reset_ssh
printf 'PasswordAuthentication no\n' >"$DROPIN_DIR/99-koncreet.conf"
check "ssh apply succeeds" koncreet --yes ssh apply >/dev/null 2>&1
check "new drop-in written" [ -f "$DROPIN" ]
check "legacy drop-in removed" [ ! -e "$DROPIN_DIR/99-koncreet.conf" ]

echo "== key user without sudo is refused =="
reset_ssh
make_user deploy
out="$(koncreet --yes ssh apply 2>&1)"; rc=$?
check "ssh apply fails" [ "$rc" -ne 0 ]
check "no drop-in written" no_dropin
check "explains missing sudo" grep -q "has SSH keys but cannot use sudo" <<<"$out"

echo "== generated sudo password must be confirmed =="
reset_ssh
make_user deploy sudo
echo 'GeneratedPass123' >/root/deploy.koncreet-password
( cd "$ROOT" && source lib/common.sh && source lib/ui.sh && ui_init && source modules/ssh.sh \
  && KONCREET_YES=0 KONCREET_DRY_RUN=0 ssh_confirm_sudo_password deploy </dev/null ) >/dev/null 2>&1
check "no tty and no --yes refuses" [ "$?" -eq 1 ]
out="$(koncreet --yes ssh apply 2>&1)"
check "--yes shows the password" grep -q "GeneratedPass123" <<<"$out"
rm -f /root/deploy.koncreet-password

echo "== SSH client IP is found under sudo =="
got="$(SSH_CONNECTION='198.51.100.7 51234 10.0.0.2 22' bash -c \
  "sudo bash -c 'source \"$ROOT/lib/sshd.sh\"; echo \"[\${SSH_CONNECTION:-}]\"; koncreet_ssh_client_ip'; true")"
check "sudo strips SSH_CONNECTION" grep -qx '\[\]' <<<"$got"
check "ip still detected" grep -qx '198.51.100.7' <<<"$got"

echo "== SSH listen ports are valid ufw rules =="
mapfile -t ports < <(cd "$ROOT" && bash -c 'source lib/common.sh; source lib/sshd.sh; koncreet_ssh_listen_ports')
check "port 22 detected" grep -qx 22 < <(printf '%s\n' "${ports[@]}")
check "no port 0" bash -c "! printf '%s\n' ${ports[*]} | grep -qx 0"
for p in "${ports[@]}"; do
  check "ufw accepts ${p}/tcp" bash -c "ufw --dry-run allow ${p}/tcp >/dev/null 2>&1"
done

echo "== apply -c: plan SKIP means SSH is not hardened =="
reset_ssh
userdel -r deploy >/dev/null 2>&1 || true
rm -f /root/deploy.koncreet-password
mkdir -p /root/.ssh
echo "$KEY" >/root/.ssh/authorized_keys
CONF="$(mktemp)"
printf 'modules=baseline,ssh\nuser=deploy\nssh_harden=true\n' >"$CONF"
out="$(koncreet --yes apply -c "$CONF" 2>&1)"
check "plan says SKIP" grep -q -- '- SKIP SSH harden' <<<"$out"
check "first run does not harden" no_dropin
check "baseline created deploy with sudo" bash -c "id -nG deploy | grep -qw sudo"
out="$(koncreet --yes apply -c "$CONF" 2>&1)"
check "second run hardens" [ -f "$DROPIN" ]
check "second run counts SSH as a step" grep -q '\[2/2\] SSH hardening' <<<"$out"
rm -f "$CONF"

echo "== dry-run asks nothing, changes nothing, logs outside the tree =="
reset_ssh
rm -f "$ROOT/koncreet.log"
: >/var/log/koncreet.log
# script(1) gives the run a real TTY, which is when the whitelist question used to appear
out="$(SSH_CONNECTION='198.51.100.7 51234 10.0.0.2 22' script -qec \
  "bash '$ROOT/koncreet' --dry-run apply -c '$ROOT/share/koncreet.conf.example'" /dev/null </dev/null 2>&1)"
check "no whitelist question" bash -c "! grep -q 'Add your IP' <<<\"\$1\"" _ "$out"
check "whitelist shown as a plan line" grep -q 'PLAN: ask to add your IP (198.51.100.7)' <<<"$out"
check "no 'Before you disconnect' checklist" bash -c "! grep -q 'Before you disconnect' <<<\"\$1\"" _ "$out"
check "says nothing changed" grep -q 'Dry-run done - nothing changed' <<<"$out"
check "no drop-in written" no_dropin
check "no log inside the install tree" [ ! -e "$ROOT/koncreet.log" ]
check "log tagged dry-run in /var/log" grep -q '\[INFO dry-run\] PLAN:' /var/log/koncreet.log

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
