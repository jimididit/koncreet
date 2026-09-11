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

koncreet_log() {
  local level="$1"; shift
  local msg="$*"
  local line
  line="$(_log_ts) [$level] $msg"
  if [[ "$KONCREET_VERBOSE" -eq 1 ]] || [[ "$level" != "DEBUG" ]]; then
    echo "$line" >&2
  fi
  local lp
  lp="$(koncreet_log_path)"
  # best-effort append; never fail the kit because logging failed
  { mkdir -p "$(dirname "$lp")" 2>/dev/null || true
    echo "$line" >>"$lp" 2>/dev/null || true
  }
}

log_info()  { koncreet_log INFO "$*"; }
log_warn()  { koncreet_log WARN "$*"; }
log_error() { koncreet_log ERROR "$*"; }
log_debug() { [[ "$KONCREET_VERBOSE" -eq 1 ]] && koncreet_log DEBUG "$*" || true; }

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
  read -r -p "$prompt" reply
  echo "${reply:-$default}"
}

confirm() {
  # Callers pass the question only; we always append [y/N].
  local prompt="${1:-Proceed?}"
  prompt="${prompt% }"; prompt="${prompt%\[y/N\]}"; prompt="${prompt%\[Y/n\]}"; prompt="${prompt% }"
  if [[ "$KONCREET_YES" -eq 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    return 1
  fi
  local reply
  read -r -p "${prompt} [y/N] " reply
  [[ "$reply" =~ ^[Yy] ]]
}

# Print planned action; skip real work when dry-run.
plan() {
  log_info "PLAN: $*"
}

run_cmd() {
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "$*"
    return 0
  fi
  log_info "RUN: $*"
  "$@"
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
  log_info "Wrote $dest"
}

backup_file() {
  local dest="$1"
  [[ -e "$dest" ]] || return 0
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "backup $dest -> ${dest}.koncreet.bak"
    return 0
  fi
  cp -a "$dest" "${dest}.koncreet.bak"
  log_info "Backed up $dest -> ${dest}.koncreet.bak"
}

# Validate a Linux username (POSIX-ish).
valid_username() {
  local u="$1"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] && [[ ${#u} -le 32 ]]
}

print_change_plan() {
  echo
  echo "=== Change plan ==="
  local line
  for line in "$@"; do
    echo "  - $line"
  done
  echo "==================="
  echo
}
