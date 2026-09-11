#!/usr/bin/env bash
# OS detection, package install, sudo group, SSH unit, firewall backend
# shellcheck shell=bash

: "${KONCREET_OS_ID:=}"
: "${KONCREET_OS_VERSION:=}"
: "${KONCREET_OS_FAMILY:=}"
: "${KONCREET_SUDO_GROUP:=sudo}"
: "${KONCREET_SSH_UNIT:=}"
: "${KONCREET_FIREWALL:=ufw}"
: "${KONCREET_PKG:=apt}"

koncreet_detect_os() {
  local id="" version="" like=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    version="${VERSION_ID:-}"
    like="${ID_LIKE:-}"
  fi

  KONCREET_OS_ID="$id"
  KONCREET_OS_VERSION="$version"

  case "$id" in
    debian)
      KONCREET_OS_FAMILY="debian"
      ;;
    ubuntu)
      KONCREET_OS_FAMILY="ubuntu"
      ;;
    *)
      if [[ " $like " == *" debian "* ]] || [[ " $like " == *" ubuntu "* ]]; then
        # treat derivatives as debian-family for package tools; still refuse unsupported
        KONCREET_OS_FAMILY="unknown"
      else
        KONCREET_OS_FAMILY="unknown"
      fi
      ;;
  esac

  KONCREET_SUDO_GROUP="sudo"
  KONCREET_PKG="apt"
  KONCREET_FIREWALL="ufw"
}

koncreet_require_supported_os() {
  koncreet_detect_os
  local ok=0
  case "$KONCREET_OS_ID" in
    debian)
      case "$KONCREET_OS_VERSION" in
        12|12.*|13|13.*) ok=1 ;;
      esac
      ;;
    ubuntu)
      case "$KONCREET_OS_VERSION" in
        22.04|24.04) ok=1 ;;
      esac
      ;;
  esac
  if [[ "$ok" -ne 1 ]]; then
    log_error "Unsupported OS: ${KONCREET_OS_ID:-unknown} ${KONCREET_OS_VERSION:-}"
    log_error "Koncreet supports Debian 12/13 and Ubuntu 22.04/24.04 only."
    log_error "Refuse rather than half-apply on ${KONCREET_OS_ID:-unknown}."
    exit 2
  fi
  log_info "OS: $KONCREET_OS_ID $KONCREET_OS_VERSION (family=$KONCREET_OS_FAMILY)"
}

pkg_install() {
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "apt-get install -y $*"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y "$@"
}

# Resolve OpenSSH server systemd unit name.
koncreet_ssh_unit() {
  if [[ -n "$KONCREET_SSH_UNIT" ]]; then
    echo "$KONCREET_SSH_UNIT"
    return 0
  fi
  local u
  for u in ssh.service sshd.service; do
    if systemctl cat "$u" &>/dev/null; then
      KONCREET_SSH_UNIT="$u"
      echo "$u"
      return 0
    fi
  done
  # fall back — Debian/Ubuntu typically ship ssh.service
  KONCREET_SSH_UNIT="ssh.service"
  echo "$KONCREET_SSH_UNIT"
}

koncreet_ssh_reload() {
  local unit
  unit="$(koncreet_ssh_unit)"
  if systemctl is-active --quiet ssh.socket 2>/dev/null || systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    log_info "ssh.socket is present — using reload-or-restart on $unit"
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "systemctl reload-or-restart $unit"
    return 0
  fi
  systemctl reload-or-restart "$unit"
}

# Return Debian Origins-Pattern or Ubuntu Allowed-Origins snippet body (apt conf).
koncreet_updates_origins_snippet() {
  if [[ -z "${KONCREET_OS_FAMILY:-}" ]]; then
    koncreet_detect_os
  fi
  case "$KONCREET_OS_FAMILY" in
    debian)
      cat <<'EOF'
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=${distro_codename},label=Debian";
    "origin=Debian,codename=${distro_codename},label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
    "origin=Debian,codename=${distro_codename}-updates";
};
EOF
      ;;
    ubuntu)
      cat <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
EOF
      ;;
    *)
      die "No update origin policy for OS family: $KONCREET_OS_FAMILY"
      ;;
  esac
}
