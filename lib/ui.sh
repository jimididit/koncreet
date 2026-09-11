#!/usr/bin/env bash
# Terminal UI: colors, steps, spinner, quiet command runner
# shellcheck shell=bash

: "${KONCREET_UI_COLOR:=}"
: "${KONCREET_UI_SPINNER_PID:=}"
: "${KONCREET_UI_STEP_MSG:=}"
: "${KONCREET_UI_OVERALL_CUR:=0}"
: "${KONCREET_UI_OVERALL_MAX:=0}"
: "${KONCREET_UI_STARTED_AT:=}"

# ANSI (empty when color off)
UI_RESET="" UI_BOLD="" UI_DIM=""
UI_RED="" UI_GREEN="" UI_YELLOW="" UI_BLUE="" UI_CYAN="" UI_MAGENTA=""

ui_init() {
  KONCREET_UI_STARTED_AT="$(date +%s)"
  KONCREET_UI_COLOR=0
  if [[ -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" && -t 1 ]]; then
    KONCREET_UI_COLOR=1
    UI_RESET=$'\033[0m'
    UI_BOLD=$'\033[1m'
    UI_DIM=$'\033[2m'
    UI_RED=$'\033[31m'
    UI_GREEN=$'\033[32m'
    UI_YELLOW=$'\033[33m'
    UI_BLUE=$'\033[34m'
    UI_CYAN=$'\033[36m'
    UI_MAGENTA=$'\033[35m'
  fi
  # Ensure spinner is cleaned up on exit
  trap 'ui_spinner_stop 2>/dev/null || true' EXIT
}

ui_colorize() {
  local color="$1"; shift
  if [[ "${KONCREET_UI_COLOR:-0}" -eq 1 ]]; then
    printf '%s%s%s' "$color" "$*" "$UI_RESET"
  else
    printf '%s' "$*"
  fi
}

ui_is_tty() { [[ -t 1 ]]; }

ui_clear_line() {
  if ui_is_tty; then
    printf '\r\033[K' >&2
  fi
}

ui_banner() {
  local banner
  banner="$(cat <<'EOF'
 _                                  _
| | _____  _ __   ___ _ __ ___  ___| |_
| |/ / _ \| '_ \ / __| '__/ _ \/ _ \ __|
|   < (_) | | | | (__| | |  __/  __/ |_
|_|\_\___/|_| |_|\___|_|  \___|\___|\__|
EOF
)"
  printf '%s\n' "$(ui_colorize "$UI_CYAN$UI_BOLD" "$banner")"
  printf '%s\n' "$(ui_colorize "$UI_DIM" " first-hour server hardening")"
}

ui_header() {
  local title="$1"
  echo >&2
  printf '%s %s\n' "$(ui_colorize "$UI_BOLD$UI_CYAN" ">")" "$(ui_colorize "$UI_BOLD" "$title")" >&2
}

ui_section() { ui_header "$@"; }

ui_kv() {
  local key="$1" val="$2"
  printf '  %s %s\n' "$(ui_colorize "$UI_DIM" "$(printf '%-14s' "$key")")" "$val"
}

ui_info() {
  printf '  %s %s\n' "$(ui_colorize "$UI_BLUE" "·")" "$*" >&2
}

ui_success() {
  printf '  %s %s\n' "$(ui_colorize "$UI_GREEN$UI_BOLD" "[OK]")" "$*" >&2
}

ui_warn() {
  printf '  %s %s\n' "$(ui_colorize "$UI_YELLOW$UI_BOLD" "[WARN]")" "$*" >&2
}

ui_error() {
  printf '  %s %s\n' "$(ui_colorize "$UI_RED$UI_BOLD" "[FAIL]")" "$*" >&2
}

ui_skip() {
  printf '  %s %s\n' "$(ui_colorize "$UI_DIM" "[SKIP]")" "$*" >&2
}

ui_muted() {
  printf '%s\n' "$(ui_colorize "$UI_DIM" "$*")" >&2
}

# --- spinner / in-progress step ---

ui_spinner_stop() {
  if [[ -n "${KONCREET_UI_SPINNER_PID:-}" ]] && kill -0 "$KONCREET_UI_SPINNER_PID" 2>/dev/null; then
    kill "$KONCREET_UI_SPINNER_PID" 2>/dev/null || true
    wait "$KONCREET_UI_SPINNER_PID" 2>/dev/null || true
  fi
  KONCREET_UI_SPINNER_PID=""
  ui_clear_line
}

ui_step_start() {
  KONCREET_UI_STEP_MSG="$*"
  ui_spinner_stop
  if ! ui_is_tty || [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then
    printf '  %s %s\n' "$(ui_colorize "$UI_DIM" "...")" "$KONCREET_UI_STEP_MSG" >&2
    return 0
  fi
  (
    local frames=('|' '/' '-' '\') i=0
    while true; do
      printf '\r  %s %s' "$(ui_colorize "$UI_CYAN" "${frames[i]}")" "$KONCREET_UI_STEP_MSG" >&2
      printf '\033[K' >&2
      i=$(( (i + 1) % 4 ))
      sleep 0.1
    done
  ) &
  KONCREET_UI_SPINNER_PID=$!
  disown "$KONCREET_UI_SPINNER_PID" 2>/dev/null || true
}

ui_step_ok() {
  local msg="${*:-$KONCREET_UI_STEP_MSG}"
  ui_spinner_stop
  ui_success "$msg"
  KONCREET_UI_STEP_MSG=""
}

ui_step_fail() {
  local msg="${*:-$KONCREET_UI_STEP_MSG}"
  ui_spinner_stop
  ui_error "$msg"
  KONCREET_UI_STEP_MSG=""
}

ui_step_skip() {
  local msg="${*:-$KONCREET_UI_STEP_MSG}"
  ui_spinner_stop
  ui_skip "$msg"
  KONCREET_UI_STEP_MSG=""
}

# Overall progress for multi-module runs: " [2/5] Firewall"
ui_overall_init() {
  KONCREET_UI_OVERALL_CUR=0
  KONCREET_UI_OVERALL_MAX="${1:-0}"
}

ui_overall_next() {
  local label="$1"
  KONCREET_UI_OVERALL_CUR=$((KONCREET_UI_OVERALL_CUR + 1))
  if [[ "${KONCREET_UI_OVERALL_MAX:-0}" -gt 0 ]]; then
    ui_header "[${KONCREET_UI_OVERALL_CUR}/${KONCREET_UI_OVERALL_MAX}] $label"
  else
    ui_header "$label"
  fi
}

ui_done_summary() {
  local elapsed=0
  if [[ -n "${KONCREET_UI_STARTED_AT:-}" ]]; then
    elapsed=$(( $(date +%s) - KONCREET_UI_STARTED_AT ))
  fi
  local lp
  lp="$(koncreet_log_path 2>/dev/null || echo koncreet.log)"
  echo >&2
  printf '%s\n' "$(ui_colorize "$UI_GREEN$UI_BOLD" "Done")$(ui_colorize "$UI_DIM" " in ${elapsed}s · log: $lp")" >&2
}

# Change plan box
ui_change_plan() {
  echo >&2
  printf '%s\n' "$(ui_colorize "$UI_BOLD" "Change plan")" >&2
  printf '%s\n' "$(ui_colorize "$UI_DIM" "───────────")" >&2
  local line
  for line in "$@"; do
    printf '  %s %s\n' "$(ui_colorize "$UI_CYAN" "-")" "$line" >&2
  done
  printf '%s\n' "$(ui_colorize "$UI_DIM" "───────────")" >&2
  echo >&2
}

# Run a command quietly with spinner; log full output; show on failure or -v
# Usage: ui_run_quiet "label" command [args...]
ui_run_quiet() {
  local label="$1"; shift
  local logfile rc=0
  logfile="$(mktemp "${TMPDIR:-/tmp}/koncreet-cmd.XXXXXX")"

  if [[ "${KONCREET_DRY_RUN:-0}" -eq 1 ]]; then
    plan "$label: $*"
    rm -f "$logfile"
    return 0
  fi

  # Always append command banner to koncreet log
  {
    echo "---- $label ----"
    echo "+ $*"
  } >>"$(koncreet_log_path)" 2>/dev/null || true

  if [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then
    ui_info "$label"
    # if-wrapper avoids set -e / set +e option leaks into the caller
    if "$@" 2>&1 | tee -a "$(koncreet_log_path)"; then
      rc=0
    else
      rc=${PIPESTATUS[0]:-1}
    fi
    rm -f "$logfile"
    if [[ "$rc" -ne 0 ]]; then
      ui_error "$label"
      return "$rc"
    fi
    ui_success "$label"
    return 0
  fi

  ui_step_start "$label"
  if "$@" >"$logfile" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  cat "$logfile" >>"$(koncreet_log_path)" 2>/dev/null || true

  if [[ "$rc" -ne 0 ]]; then
    ui_step_fail "$label"
    ui_muted "── last output ──"
    tail -n 20 "$logfile" 2>/dev/null | while IFS= read -r line || [[ -n "$line" ]]; do
      printf '  %s\n' "$(ui_colorize "$UI_RED" "$line")" >&2
    done
    ui_muted "─────────────────"
    rm -f "$logfile"
    return "$rc"
  fi

  ui_step_ok "$label"
  rm -f "$logfile"
  return 0
}
