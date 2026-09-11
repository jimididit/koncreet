#!/usr/bin/env bash
# Install koncreet without git. Safe to re-run (updates in place).
#
#   curl -fsSL https://raw.githubusercontent.com/jimididit/koncreet/main/install.sh | sudo bash
#
# Or pin a release:
#   curl -fsSL https://github.com/jimididit/koncreet/releases/latest/download/install.sh | sudo bash
#   KONCREET_VERSION=0.1.0 curl -fsSL ... | sudo bash
#
# Env:
#   KONCREET_VERSION   semver (e.g. 0.1.0) or "latest" (default)
#   KONCREET_INSTALL_DIR  install root (default /opt/koncreet)
set -euo pipefail

REPO="${KONCREET_REPO:-jimididit/koncreet}"
DEST="${KONCREET_INSTALL_DIR:-/opt/koncreet}"
VERSION="${KONCREET_VERSION:-latest}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "Run as root: curl -fsSL … | sudo bash" >&2
  exit 1
fi

download() {
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url"
  else
    echo "Need curl or wget" >&2
    exit 1
  fi
}

url_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSIL "$url" >/dev/null 2>&1
  else
    wget --spider -q "$url" 2>/dev/null
  fi
}

echo "koncreet installer → $DEST (version=$VERSION)"

ARCHIVE="$TMP/koncreet.tar.gz"
FETCHED=""

if [[ "$VERSION" == "latest" ]]; then
  RELEASE_URL="https://github.com/${REPO}/releases/latest/download/koncreet.tar.gz"
  if url_ok "$RELEASE_URL"; then
    echo "Downloading latest release…"
    download "$RELEASE_URL" "$ARCHIVE"
    FETCHED="release:latest"
  else
    echo "No GitHub release asset yet - falling back to main branch archive…"
    download "https://github.com/${REPO}/archive/refs/heads/main.tar.gz" "$ARCHIVE"
    FETCHED="branch:main"
  fi
else
  VER="${VERSION#v}"
  RELEASE_URL="https://github.com/${REPO}/releases/download/v${VER}/koncreet.tar.gz"
  TAG_URL="https://github.com/${REPO}/archive/refs/tags/v${VER}.tar.gz"
  if url_ok "$RELEASE_URL"; then
    echo "Downloading release v${VER}…"
    download "$RELEASE_URL" "$ARCHIVE"
    FETCHED="release:v${VER}"
  elif url_ok "$TAG_URL"; then
    echo "Downloading tag archive v${VER}…"
    download "$TAG_URL" "$ARCHIVE"
    FETCHED="tag:v${VER}"
  else
    echo "Could not find version ${VER} (tried release asset and tag archive)" >&2
    exit 1
  fi
fi

mkdir -p "$TMP/extract"
tar -xzf "$ARCHIVE" -C "$TMP/extract"

# Release tarball is rooted at ./koncreet/... ; GitHub source archives use koncreet-<ref>/
SRC="$(find "$TMP/extract" -maxdepth 3 -type f -name koncreet | head -n1)"
if [[ -z "$SRC" ]]; then
  echo "Archive did not contain a koncreet entrypoint" >&2
  exit 1
fi
SRC_ROOT="$(cd "$(dirname "$SRC")" && pwd)"
[[ -f "$SRC_ROOT/VERSION" ]] || { echo "Archive missing VERSION" >&2; exit 1; }
[[ -d "$SRC_ROOT/lib" ]] || { echo "Archive missing lib/" >&2; exit 1; }

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
mkdir -p "$DEST"
# Copy tree (keep VERSION, lib, modules, share, assets)
cp -a "$SRC_ROOT"/. "$DEST"/
chmod +x "$DEST/koncreet"

echo "Installed from $FETCHED"
"$DEST/koncreet" version
# --yes: curl|bash has no TTY, so confirm() would skip replacing an old symlink
"$DEST/koncreet" --yes self-install

if [[ ! -x /usr/local/bin/koncreet ]]; then
  mkdir -p /usr/local/bin
  ln -sfn "$DEST/koncreet" /usr/local/bin/koncreet
  echo "Linked /usr/local/bin/koncreet -> $DEST/koncreet"
fi

if ! command -v koncreet >/dev/null 2>&1 && [[ ! -x /usr/local/bin/koncreet ]]; then
  echo "PATH link missing. Run: sudo $DEST/koncreet --yes self-install" >&2
  exit 1
fi

echo
echo "Ready. Run:  sudo koncreet"
echo "Upgrade later with the same one-liner (reinstalls into $DEST)."
