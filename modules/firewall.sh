#!/usr/bin/env bash
# firewall: ufw default-deny with real SSH port detection
# shellcheck shell=bash

declare -A KONCREET_FW_SERVICES=(
  [http]="80/tcp"
  [https]="443/tcp"
  [nginx]="80/tcp 443/tcp"
  [apache]="80/tcp 443/tcp"
  [postfix]="25/tcp 587/tcp"
  [mysql]="3306/tcp"
  [vsftpd]="20/tcp 21/tcp"
)

declare -A KONCREET_FW_SENSITIVE=(
  [mysql]=1
  [vsftpd]=1
)

KONCREET_UFW_SNAPSHOT="/var/lib/koncreet/ufw.rules.before"

firewall_list_services() {
  echo "Supported services (SSH is always allowed automatically):"
  local s
  for s in "${!KONCREET_FW_SERVICES[@]}"; do
    if [[ -n "${KONCREET_FW_SENSITIVE[$s]:-}" ]]; then
      echo "  $s  (requires --public / firewall_public=true)"
    else
      echo "  $s"
    fi
  done | sort
}

firewall_plan_lines() {
  local requested="${1:-}"
  local public="${2:-0}"
  local lines=("Install ufw if needed" "Default deny incoming / allow outgoing")
  local p
  while read -r p; do
    lines+=("Allow SSH on ${p}/tcp")
  done < <(koncreet_ssh_listen_ports)
  if [[ -n "$requested" ]]; then
    lines+=("Open services: $requested (public=$public)")
  fi
  lines+=("Enable ufw (snapshot rules for undo)")
  printf '%s\n' "${lines[@]}"
}

firewall_snapshot() {
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "snapshot ufw rules to $KONCREET_UFW_SNAPSHOT"
    return 0
  fi
  mkdir -p "$(dirname "$KONCREET_UFW_SNAPSHOT")"
  if command -v ufw &>/dev/null; then
    ufw status numbered >"${KONCREET_UFW_SNAPSHOT}.status" 2>/dev/null || true
  fi
  if [[ -d /etc/ufw ]]; then
    tar -czf "${KONCREET_UFW_SNAPSHOT}.tgz" -C / etc/ufw 2>/dev/null || true
    _log_file INFO "UFW rules snapshotted to ${KONCREET_UFW_SNAPSHOT}.tgz"
  fi
}

firewall_undo() {
  if [[ ! -f "${KONCREET_UFW_SNAPSHOT}.tgz" ]]; then
    log_warn "No UFW snapshot at ${KONCREET_UFW_SNAPSHOT}.tgz"
    ui_muted "To disable firewall: ufw disable"
    return 1
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "restore ufw from ${KONCREET_UFW_SNAPSHOT}.tgz"
    return 0
  fi
  tar -xzf "${KONCREET_UFW_SNAPSHOT}.tgz" -C /
  ufw reload >/dev/null 2>&1 || true
  log_ok "UFW restored from snapshot"
}

firewall_apply() {
  local requested="${1:-}"
  local public="${2:-0}"

  local -a wanted=()
  local svc ports
  if [[ -n "$requested" ]]; then
    IFS=',' read -ra wanted <<<"$requested"
    for svc in "${wanted[@]}"; do
      svc="${svc// /}"
      [[ -z "$svc" || "$svc" == "ssh" ]] && continue
      if [[ -z "${KONCREET_FW_SERVICES[$svc]:-}" ]]; then
        die "Unknown firewall service '$svc'. Run: koncreet firewall list"
      fi
      if [[ -n "${KONCREET_FW_SENSITIVE[$svc]:-}" && "$public" -ne 1 ]]; then
        die "Service '$svc' opens sensitive ports publicly. Re-run with --public or set firewall_public=true."
      fi
    done
  fi

  pkg_install ufw
  firewall_snapshot

  local ssh_ports=()
  while read -r p; do ssh_ports+=("$p"); done < <(koncreet_ssh_listen_ports)

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ufw default deny incoming / allow outgoing"
    for p in "${ssh_ports[@]}"; do plan "ufw allow ${p}/tcp"; done
    plan "ufw --force enable"
    return 0
  fi

  ui_step_start "ufw default deny incoming"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in "${ssh_ports[@]}"; do
    ufw allow "${p}/tcp" >/dev/null
  done
  for svc in "${wanted[@]+"${wanted[@]}"}"; do
    svc="${svc// /}"
    [[ -z "$svc" || "$svc" == "ssh" ]] && continue
    ports="${KONCREET_FW_SERVICES[$svc]}"
    local port
    for port in $ports; do
      ufw allow "$port" >/dev/null
    done
  done
  ufw --force enable >/dev/null
  ui_step_ok "ufw deny-incoming; SSH :${ssh_ports[*]} allowed"
  if [[ -n "$requested" ]]; then
    log_ok "extra services: $requested"
  fi
}

firewall_status() {
  ui_header "firewall"
  if command -v ufw &>/dev/null; then
    local st
    st="$(ufw status 2>/dev/null | head -1 || echo unknown)"
    ui_kv "ufw" "$st"
    if [[ "${KONCREET_VERBOSE:-0}" -eq 1 ]]; then
      ufw status verbose 2>/dev/null | sed 's/^/  /' || true
    fi
  else
    ui_kv "ufw" "not installed"
  fi
  ui_kv "ssh ports" "$(koncreet_ssh_listen_ports | tr '\n' ' ' | sed 's/ $//')"
}
