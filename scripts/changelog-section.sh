#!/usr/bin/env bash
# Print the CHANGELOG.md section for a semver (e.g. 0.2.4), without the ## heading.
# Usage: scripts/changelog-section.sh 0.2.4
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VER="${1:?usage: changelog-section.sh X.Y.Z}"
CHANGELOG="${ROOT}/CHANGELOG.md"
[[ -f "$CHANGELOG" ]] || { echo "missing CHANGELOG.md" >&2; exit 1; }

section="$(awk -v ver="$VER" '
  $0 == "## " ver { found = 1; next }
  found && /^## / { exit }
  found { print }
' "$CHANGELOG")"

# Fail if the section is missing or only whitespace
if [[ -z "${section//[[:space:]]/}" ]]; then
  echo "no CHANGELOG section for ${VER}" >&2
  exit 1
fi
printf '%s\n' "$section"
