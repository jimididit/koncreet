#!/usr/bin/env bash
# koncreet doctor — apply-readiness checks (any OS; unsupported marked FAIL)
# shellcheck shell=bash

: "${KONCREET_DOCTOR_FAILS:=0}"
: "${KONCREET_DOCTOR_WARNS:=0}"

doctor_ok() { ui_success "$*"; }
doctor_warn() {
  KONCREET_DOCTOR_WARNS=$((KONCREET_DOCTOR_WARNS + 1))
  ui_warn "$*"
}
doctor_fail() {
  KONCREET_DOCTOR_FAILS=$((KONCREET_DOCTOR_FAILS + 1))
  ui_error "$*"
}

koncreet_os_is_supported() {
  koncreet_detect_os
  case "$KONCREET_OS_ID" in
    debian)
      case "$KONCREET_OS_VERSION" in
        12|12.*|13|13.*) return 0 ;;
      esac
      ;;
    ubuntu)
      case "$KONCREET_OS_VERSION" in
        22.04|24.04) return 0 ;;
      esac
      ;;
  esac
  return 1
}

cmd_doctor() {
  KONCREET_DOCTOR_FAILS=0
  KONCREET_DOCTOR_WARNS=0
  ui_header "koncreet doctor"
  ui_kv "version" "$(koncreet_version)"

  # --- OS ---
  koncreet_detect_os
  if koncreet_os_is_supported; then
    doctor_ok "OS ${KONCREET_OS_ID} ${KONCREET_OS_VERSION} supported"
  else
    doctor_fail "OS ${KONCREET_OS_ID:-unknown} ${KONCREET_OS_VERSION:-} not supported (need Debian 12/13 or Ubuntu 22.04/24.04)"
  fi

  # --- root (apply readiness) ---
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    doctor_ok "running as root (apply ready)"
  else
    doctor_warn "not root — install/version/doctor ok; apply needs: sudo koncreet …"
  fi

  # --- apt ---
  if command -v apt-get >/dev/null 2>&1; then
    doctor_ok "apt-get available"
    local locked=0
    if command -v fuser >/dev/null 2>&1; then
      if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
        || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        locked=1
      fi
    elif command -v lsof >/dev/null 2>&1; then
      if lsof /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        locked=1
      fi
    fi
    if [[ "$locked" -eq 1 ]]; then
      doctor_warn "apt lock held — wait for unattended-upgrades / another apt to finish"
    fi
  else
    doctor_fail "apt-get not found"
  fi

  # --- disk for swap ---
  local avail_kb
  avail_kb="$(df -Pk / 2>/dev/null | awk 'NR==2{print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -ge 524288 ]]; then
    doctor_ok "disk free on /: $((avail_kb / 1024))M (swap possible)"
  elif [[ -n "$avail_kb" ]]; then
    doctor_warn "low disk on /: $((avail_kb / 1024))M — swap creation may fail"
  else
    doctor_warn "could not read free disk on /"
  fi

  # --- SSH ---
  local unit ports
  unit="$(koncreet_ssh_unit 2>/dev/null || echo ssh)"
  ports="$(koncreet_ssh_listen_ports | tr '\n' ' ' | sed 's/ $//')"
  doctor_ok "SSH unit=${unit} ports=${ports:-22}"

  local key_user
  if key_user="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    doctor_ok "non-root key user: $key_user (SSH harden safe)"
  else
    doctor_warn "no non-root user with authorized_keys — run baseline before ssh apply"
  fi

  if [[ -f /etc/ssh/sshd_config.d/99-koncreet.conf ]]; then
    if command -v sshd >/dev/null 2>&1 && sshd -t 2>/dev/null; then
      doctor_ok "sshd -t ok (koncreet harden drop-in present)"
    else
      doctor_fail "sshd -t failed with 99-koncreet.conf present"
    fi
  fi

  # --- PATH install ---
  local link="/usr/local/bin/koncreet" resolved want
  want="$(readlink -f "${KONCREET_ROOT}/koncreet" 2>/dev/null || echo "${KONCREET_ROOT}/koncreet")"
  if [[ -L "$link" || -e "$link" ]]; then
    resolved="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ -n "$resolved" && "$resolved" == "$want" ]]; then
      doctor_ok "PATH: $link -> $resolved"
    else
      doctor_warn "PATH: $link -> ${resolved:-?} (expected $want)"
    fi
  else
    doctor_warn "not on PATH — run: sudo koncreet self-install (or re-run install.sh)"
  fi

  echo >&2
  if [[ "$KONCREET_DOCTOR_FAILS" -gt 0 ]]; then
    ui_error "doctor: ${KONCREET_DOCTOR_FAILS} fail(s), ${KONCREET_DOCTOR_WARNS} warn(s) — not apply-ready"
    return 1
  fi
  if [[ "$KONCREET_DOCTOR_WARNS" -gt 0 ]]; then
    ui_warn "doctor: 0 fails, ${KONCREET_DOCTOR_WARNS} warn(s) — review before apply"
    return 0
  fi
  ui_success "doctor: all clear"
  return 0
}
