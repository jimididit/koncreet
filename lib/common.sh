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

# Show a message via lib/ui.sh when it is loaded, else as plain stderr.
# (Do not silence stderr here: the ui_* helpers print to stderr.)
_log_show() {
  local fn="$1" tag="$2"; shift 2
  if declare -F "$fn" >/dev/null; then
    "$fn" "$*"
  else
    echo "${tag}$*" >&2
  fi
}

koncreet_log() {
  local level="$1"; shift
  local msg="$*"
  _log_file "$level" "$msg"
  case "$level" in
    ERROR) _log_show ui_error "[ERROR] " "$msg" ;;
    WARN)  _log_show ui_warn "[WARN] " "$msg" ;;
    DEBUG)
      if [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then _log_show ui_muted "[DEBUG] " "$msg"; fi
      ;;
    INFO|*)
      # Prefer quiet structured UI from callers; INFO still shows as muted · line
      _log_show ui_info "[INFO] " "$msg"
      ;;
  esac
}

log_info()  { _log_file INFO "$*"; _log_show ui_info "" "$*"; }
log_warn()  { _log_file WARN "$*"; _log_show ui_warn "[WARN] " "$*"; }
log_error() { _log_file ERROR "$*"; _log_show ui_error "[ERROR] " "$*"; }
log_debug() {
  _log_file DEBUG "$*"
  if [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then _log_show ui_muted "" "$*"; fi
}
# Success line that also hits the log
log_ok() { _log_file INFO "$*"; _log_show ui_success "[OK] " "$*"; }

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
  _log_show ui_muted "" "PLAN: $*"
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
