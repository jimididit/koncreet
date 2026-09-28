#!/usr/bin/env bash
# koncreet doctor - apply-readiness checks (any OS; unsupported marked FAIL)
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
    doctor_warn "not root - install/version/doctor ok; apply needs: sudo koncreet …"
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
      doctor_warn "apt lock held - wait for unattended-upgrades / another apt to finish"
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
    doctor_warn "low disk on /: $((avail_kb / 1024))M - swap creation may fail"
  else
    doctor_warn "could not read free disk on /"
  fi

  # --- SSH ---
  local unit ports
  unit="$(koncreet_ssh_unit 2>/dev/null || echo ssh)"
  ports="$(koncreet_ssh_listen_ports 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)"
  if [[ -n "$ports" ]]; then
    doctor_ok "SSH unit=${unit} ports=${ports}"
  else
    doctor_warn "SSH unit=${unit} but listen port undetected (firewall apply will refuse)"
  fi

  local key_user dropin="" sshd_d="/etc/ssh/sshd_config.d"
  if key_user="$(koncreet_find_nonroot_key_user sudo 2>/dev/null)"; then
    doctor_ok "SSH harden ready: '$key_user' has keys and sudo"
  elif key_user="$(koncreet_find_nonroot_key_user 2>/dev/null)"; then
    doctor_warn "'$key_user' has SSH keys but no sudo - ssh apply will refuse until: usermod -aG ${KONCREET_SUDO_GROUP:-sudo} $key_user"
  else
    doctor_warn "no non-root user with authorized_keys - run baseline before ssh apply"
  fi

  # Some images make /etc/ssh mode 750; non-root doctor must not silently skip.
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! { [[ -r "$sshd_d" && -x "$sshd_d" ]]; }; then
    doctor_warn "cannot read $sshd_d as $(id -un) - run: sudo koncreet doctor"
  else
    if [[ -f "$sshd_d/00-koncreet.conf" ]]; then
      dropin="$sshd_d/00-koncreet.conf"
    elif [[ -f "$sshd_d/99-koncreet.conf" ]]; then
      dropin="$sshd_d/99-koncreet.conf"
      doctor_warn "legacy 99-koncreet.conf present - re-run: koncreet ssh apply"
    elif [[ -f "$sshd_d/99-harden.conf" ]]; then
      dropin="$sshd_d/99-harden.conf"
      doctor_warn "legacy 99-harden.conf present - re-run: koncreet ssh apply"
    fi
    if [[ -n "$dropin" ]]; then
      if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        doctor_warn "SSH drop-in $(basename "$dropin") present - run: sudo koncreet doctor (to verify effective settings)"
      elif command -v sshd >/dev/null 2>&1; then
        if ! sshd -t 2>/dev/null; then
          doctor_fail "sshd -t failed with $(basename "$dropin") present"
        else
          local -a bad=()
          mapfile -t bad < <(sshd -T 2>/dev/null | koncreet_sshd_mismatches)
          if [[ "${#bad[@]}" -gt 0 ]]; then
            doctor_warn "SSH harden not fully in effect: ${bad[*]} (see: koncreet ssh status)"
          else
            doctor_ok "sshd -t ok; password auth + root login off ($(basename "$dropin"))"
          fi
        fi
      fi
    fi
  fi

  # Older runs could leave koncreet /etc drop-ins root-only; point at a one-shot fix.
  local -a private_files=() private_dirs=()
  local f mode
  for f in /etc/sysctl.d/99-koncreet.conf /etc/systemd/journald.conf.d/99-koncreet-cap.conf \
    /etc/logrotate.d/koncreet /etc/fail2ban/jail.d/99-koncreet.conf \
    /etc/apt/apt.conf.d/20auto-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local; do
    [[ -f "$f" ]] || continue
    mode="$(stat -c '%a' "$f" 2>/dev/null)" || continue
    (( 8#$mode & 8#004 )) || private_files+=("$f")
  done
  f=/etc/systemd/journald.conf.d
  if [[ -d "$f" ]] && mode="$(stat -c '%a' "$f" 2>/dev/null)"; then
    (( (8#$mode & 8#005) == 8#005 )) || private_dirs+=("$f")
  fi
  if [[ "${#private_files[@]}" -gt 0 || "${#private_dirs[@]}" -gt 0 ]]; then
    doctor_warn "koncreet wrote /etc files that are not world-readable (non-root apt tools may warn)"
    [[ "${#private_files[@]}" -gt 0 ]] && ui_muted "    sudo chmod 644 ${private_files[*]}"
    [[ "${#private_dirs[@]}" -gt 0 ]] && ui_muted "    sudo chmod 755 ${private_dirs[*]}"
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
    doctor_warn "not on PATH - run: sudo koncreet self-install (or re-run install.sh)"
  fi

  echo >&2
  if [[ "$KONCREET_DOCTOR_FAILS" -gt 0 ]]; then
    ui_error "doctor: ${KONCREET_DOCTOR_FAILS} fail(s), ${KONCREET_DOCTOR_WARNS} warn(s) - not apply-ready"
    return 1
  fi
  if [[ "$KONCREET_DOCTOR_WARNS" -gt 0 ]]; then
    ui_warn "doctor: 0 fails, ${KONCREET_DOCTOR_WARNS} warn(s) - review before apply"
    return 0
  fi
  ui_success "doctor: all clear"
  return 0
}
