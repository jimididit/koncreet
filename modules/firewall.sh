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

# Services that must not be opened publicly without --public
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
    log_info "UFW rules snapshotted to ${KONCREET_UFW_SNAPSHOT}.tgz"
  fi
}

firewall_undo() {
  if [[ ! -f "${KONCREET_UFW_SNAPSHOT}.tgz" ]]; then
    log_warn "No UFW snapshot found at ${KONCREET_UFW_SNAPSHOT}.tgz"
    log_info "To disable firewall: ufw disable"
    return 1
  fi
  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "restore ufw from ${KONCREET_UFW_SNAPSHOT}.tgz"
    return 0
  fi
  tar -xzf "${KONCREET_UFW_SNAPSHOT}.tgz" -C /
  ufw reload || true
  log_info "Restored UFW config from snapshot. Verify: ufw status verbose"
}

firewall_apply() {
  local requested="${1:-}"
  local public="${2:-0}"

  # Validate services first — abort on unknown (no silent skip)
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
        die "Service '$svc' opens sensitive ports publicly. Re-run with --public or set firewall_public=true in config."
      fi
    done
  fi

  pkg_install ufw
  firewall_snapshot

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ufw default deny incoming"
    plan "ufw default allow outgoing"
  else
    ufw default deny incoming
    ufw default allow outgoing
  fi

  local p
  while read -r p; do
    log_info "Allowing SSH on port ${p}/tcp"
    if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
      plan "ufw allow ${p}/tcp"
    else
      ufw allow "${p}/tcp"
    fi
  done < <(koncreet_ssh_listen_ports)

  for svc in "${wanted[@]+"${wanted[@]}"}"; do
    svc="${svc// /}"
    [[ -z "$svc" || "$svc" == "ssh" ]] && continue
    ports="${KONCREET_FW_SERVICES[$svc]}"
    local port
    for port in $ports; do
      log_info "Allowing $svc ($port)"
      if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
        plan "ufw allow $port"
      else
        ufw allow "$port"
      fi
    done
  done

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ufw --force enable"
  else
    ufw --force enable
    echo
    ufw status verbose
  fi
  log_info "Firewall done."
}

firewall_status() {
  echo "--- firewall ---"
  if command -v ufw &>/dev/null; then
    ufw status verbose 2>/dev/null || echo "ufw installed but status failed"
  else
    echo "ufw: not installed"
  fi
  echo "SSH listen ports detected:"
  koncreet_ssh_listen_ports | sed 's/^/  /'
}
