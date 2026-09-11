#!/usr/bin/env bash
# shared helpers: logging, confirm, dry-run, backup, ask
# shellcheck shell=bash

: "${KONCREET_ROOT:=}"
: "${KONCREET_DRY_RUN:=0}"
: "${KONCREET_YES:=0}"
: "${KONCREET_VERBOSE:=0}"
: "${KONCREET_CONFIG:=}"

# Log file: system path when root and not dry-run; else local.
koncreet_log_path() {
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]] || [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "${KONCREET_ROOT:-.}/koncreet.log"
  else
    echo "/var/log/koncreet.log"
  fi
}

_log_ts() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Append to log file only (no stdout).
_log_file() {
  local level="$1"; shift
  local line lp
  line="$(_log_ts) [$level] $*"
  lp="$(koncreet_log_path)"
  { mkdir -p "$(dirname "$lp")" 2>/dev/null || true
    echo "$line" >>"$lp" 2>/dev/null || true
  }
}

koncreet_log() {
  local level="$1"; shift
  local msg="$*"
  _log_file "$level" "$msg"
  case "$level" in
    ERROR) ui_error "$msg" 2>/dev/null || echo "[ERROR] $msg" >&2 ;;
    WARN)  ui_warn "$msg" 2>/dev/null || echo "[WARN] $msg" >&2 ;;
    DEBUG)
      [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]] && { ui_muted "$msg" 2>/dev/null || echo "[DEBUG] $msg" >&2; }
      ;;
    INFO|*)
      # Prefer quiet structured UI from callers; INFO still shows as muted · line
      ui_info "$msg" 2>/dev/null || echo "[INFO] $msg" >&2
      ;;
  esac
}

log_info()  { _log_file INFO "$*"; ui_info "$*" 2>/dev/null || echo "$*" >&2; }
log_warn()  { _log_file WARN "$*"; ui_warn "$*" 2>/dev/null || echo "[WARN] $*" >&2; }
log_error() { _log_file ERROR "$*"; ui_error "$*" 2>/dev/null || echo "[ERROR] $*" >&2; }
log_debug() {
  _log_file DEBUG "$*"
  [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]] && { ui_muted "$*" 2>/dev/null || true; }
}
# Success line that also hits the log
log_ok() { _log_file INFO "$*"; ui_success "$*" 2>/dev/null || echo "[OK] $*" >&2; }

die() {
  log_error "$*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo $0 $*"
  fi
}

ask() {
  local prompt="$1" default="${2:-}" reply
  if [[ "$KONCREET_YES" -eq 1 ]] && [[ -n "$default" ]]; then
    echo "$default"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    echo "$default"
    return 0
  fi
  if [[ "${KONCREET_UI_COLOR:-0}" -eq 1 ]]; then
    read -r -p "${UI_CYAN}${prompt}${UI_RESET}" reply
  else
    read -r -p "$prompt" reply
  fi
  echo "${reply:-$default}"
}

confirm() {
  local prompt="${1:-Proceed?}"
  prompt="${prompt% }"; prompt="${prompt%\[y/N\]}"; prompt="${prompt%\[Y/n\]}"; prompt="${prompt% }"
  if [[ "$KONCREET_YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local reply
  if [[ "${KONCREET_UI_COLOR:-0}" -eq 1 ]]; then
    read -r -p "${UI_CYAN}${prompt}${UI_RESET} ${UI_DIM}[y/N]${UI_RESET} " reply
  else
    read -r -p "${prompt} [y/N] " reply
  fi
  [[ "$reply" =~ ^[Yy] ]]
}

plan() {
  _log_file INFO "PLAN: $*"
  ui_muted "PLAN: $*" 2>/dev/null || echo "PLAN: $*" >&2
}

run_cmd() {
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "$*"
    return 0
  fi
  ui_run_quiet "$*" "$@"
}

# Write stdin to dest unless dry-run. Backs up existing file first.
write_file() {
  local dest="$1"
  local content
  content="$(cat)"
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "write $dest (${#content} bytes)"
    if [[ "$KONCREET_VERBOSE" -eq 1 ]]; then
      echo "----- begin $dest -----" >&2
      printf '%s' "$content" >&2
      echo >&2
      echo "----- end $dest -----" >&2
    fi
    return 0
  fi
  backup_file "$dest"
  mkdir -p "$(dirname "$dest")"
  printf '%s' "$content" >"$dest"
  _log_file INFO "Wrote $dest"
}

backup_file() {
  local dest="$1"
  [[ -e "$dest" ]] || return 0
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "backup $dest -> ${dest}.koncreet.bak"
    return 0
  fi
  cp -a "$dest" "${dest}.koncreet.bak"
  _log_file INFO "Backed up $dest -> ${dest}.koncreet.bak"
}

valid_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#u} -le 32 ]]
}

print_change_plan() {
  ui_change_plan "$@"
}
