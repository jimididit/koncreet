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

# True if token looks like 8080/tcp or 53/udp
firewall_is_port_spec() {
  [[ "${1:-}" =~ ^[0-9]{1,5}/(tcp|udp)$ ]]
}

firewall_validate_port_spec() {
  local spec="$1"
  firewall_is_port_spec "$spec" || die "Invalid port spec '$spec' (use N/tcp or N/udp, e.g. 8080/tcp)"
  local num="${spec%%/*}"
  if [[ "$num" -lt 1 || "$num" -gt 65535 ]]; then
    die "Port out of range in '$spec'"
  fi
}

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
  echo "Custom ports: pass N/tcp or N/udp (e.g. 8080/tcp) or set firewall_ports= in config"
}

firewall_plan_lines() {
  local requested="${1:-}"
  local public="${2:-0}"
  local extra_ports="${3:-}"
  local lines=("Install ufw if needed" "Default deny incoming / allow outgoing")
  local p
  while read -r p; do
    lines+=("Allow SSH on ${p}/tcp")
  done < <(koncreet_ssh_listen_ports)
  if [[ -n "$requested" ]]; then
    lines+=("Open services: $requested (public=$public)")
  fi
  if [[ -n "$extra_ports" ]]; then
    lines+=("Open custom ports: $extra_ports")
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

# Parse comma-separated services and/or N/tcp specs into named services + port list.
# Sets global arrays: _fw_services _fw_ports
firewall_parse_request() {
  local requested="${1:-}"
  _fw_services=()
  _fw_ports=()
  local tok
  local -a wanted=()
  [[ -z "$requested" ]] && return 0
  IFS=',' read -ra wanted <<<"$requested"
  for tok in "${wanted[@]}"; do
    tok="${tok// /}"
    [[ -z "$tok" || "$tok" == "ssh" ]] && continue
    if firewall_is_port_spec "$tok"; then
      firewall_validate_port_spec "$tok"
      _fw_ports+=("$tok")
    elif [[ "$tok" =~ ^[0-9]+$ ]]; then
      die "Bare port '$tok' needs a proto — use ${tok}/tcp or ${tok}/udp"
    elif [[ -z "${KONCREET_FW_SERVICES[$tok]:-}" ]]; then
      die "Unknown firewall service '$tok'. Run: koncreet firewall list"
    else
      _fw_services+=("$tok")
    fi
  done
}

firewall_apply() {
  local requested="${1:-}"
  local public="${2:-0}"
  local extra_ports="${3:-}"

  firewall_parse_request "$requested"
  local -a named=("${_fw_services[@]+"${_fw_services[@]}"}")
  local -a ports_extra=("${_fw_ports[@]+"${_fw_ports[@]}"}")

  # config firewall_ports=
  local tok
  local -a from_cfg=()
  if [[ -n "$extra_ports" ]]; then
    IFS=',' read -ra from_cfg <<<"$extra_ports"
    for tok in "${from_cfg[@]}"; do
      tok="${tok// /}"
      [[ -z "$tok" ]] && continue
      firewall_validate_port_spec "$tok"
      ports_extra+=("$tok")
    done
  fi

  local svc
  for svc in "${named[@]+"${named[@]}"}"; do
    if [[ -n "${KONCREET_FW_SENSITIVE[$svc]:-}" && "$public" -ne 1 ]]; then
      die "Service '$svc' opens sensitive ports publicly. Re-run with --public or set firewall_public=true."
    fi
  done

  pkg_install ufw
  firewall_snapshot

  local ssh_ports=()
  while read -r p; do ssh_ports+=("$p"); done < <(koncreet_ssh_listen_ports)

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "ufw default deny incoming / allow outgoing"
    for p in "${ssh_ports[@]}"; do plan "ufw allow ${p}/tcp"; done
    for svc in "${named[@]+"${named[@]}"}"; do
      local port
      for port in ${KONCREET_FW_SERVICES[$svc]}; do plan "ufw allow $port"; done
    done
    for p in "${ports_extra[@]+"${ports_extra[@]}"}"; do plan "ufw allow $p"; done
    plan "ufw --force enable"
    return 0
  fi

  ui_step_start "ufw default deny incoming"
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in "${ssh_ports[@]}"; do
    ufw allow "${p}/tcp" >/dev/null
  done
  for svc in "${named[@]+"${named[@]}"}"; do
    local port
    for port in ${KONCREET_FW_SERVICES[$svc]}; do
      ufw allow "$port" >/dev/null
    done
  done
  for p in "${ports_extra[@]+"${ports_extra[@]}"}"; do
    ufw allow "$p" >/dev/null
  done
  ufw --force enable >/dev/null
  ui_step_ok "ufw deny-incoming; SSH :${ssh_ports[*]} allowed"
  if [[ -n "$requested" || -n "$extra_ports" ]]; then
    log_ok "extra: services=${requested:-none} ports=${extra_ports:-none}"
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
