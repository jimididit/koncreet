#!/usr/bin/env bash
# Container smoke: doctor + dry-run plan on a supported image (no systemd/ufw required).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== smoke: version =="
./koncreet version

echo "== smoke: doctor (may warn without root/keys) =="
set +e
./koncreet doctor
doc_rc=$?
set -e
# doctor returns 1 only on FAILs; WARN-only is 0. Either is fine in CI images.
echo "doctor exit=$doc_rc"

echo "== smoke: dry-run apply =="
./koncreet --dry-run --yes apply -c share/koncreet.conf.example

echo "smoke ok"
