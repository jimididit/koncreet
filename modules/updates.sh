#!/usr/bin/env bash
# unattended security updates - Debian vs Ubuntu origins
# shellcheck shell=bash

updates_plan_lines() {
  local auto_reboot="${1:-false}"
  local reboot_hour="${2:-04:00}"
  printf '%s\n' \
    "Install unattended-upgrades" \
    "Enable APT::Periodic daily refresh + unattended-upgrade" \
    "Write distro-correct origins policy for $KONCREET_OS_FAMILY" \
    "Automatic-Reboot=${auto_reboot} at ${reboot_hour}" \
    "Enable apt-daily timers; dry-run unattended-upgrade"
}

updates_apply() {
  local auto_reboot="${1:-false}"
  local reboot_hour="${2:-04:00}"

  # Normalize bool
  case "$auto_reboot" in
    true|True|TRUE|yes|Yes|1) auto_reboot="true" ;;
    *) auto_reboot="false" ;;
  esac

  if [[ "$auto_reboot" == "true" && "$KONCREET_YES" -ne 1 && -t 0 ]]; then
    if ! confirm "Enable automatic reboot for kernel updates at ${reboot_hour}?"; then
      auto_reboot="false"
    fi
  fi

  pkg_install unattended-upgrades

  write_file /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF

  local origins
  origins="$(koncreet_updates_origins_snippet)"

  # shellcheck disable=SC2086
  write_file /etc/apt/apt.conf.d/52unattended-upgrades-local <<EOF
// Managed by koncreet - site policy, keep separate from packaged defaults.

${origins}

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";

Unattended-Upgrade::Automatic-Reboot "${auto_reboot}";
Unattended-Upgrade::Automatic-Reboot-Time "${reboot_hour}";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF

  if [[ "$KONCREET_DRY_RUN" -eq 1 ]]; then
    plan "systemctl enable apt-daily.timer apt-daily-upgrade.timer"
    plan "unattended-upgrade --dry-run"
  else
    systemctl enable apt-daily.timer apt-daily-upgrade.timer
    systemctl start apt-daily.timer apt-daily-upgrade.timer
    log_info "Verifying configuration"
    apt-config dump 2>/dev/null | grep -E 'APT::Periodic::(Update-Package-Lists|Unattended-Upgrade)' || true
    systemctl list-timers --no-pager 'apt-daily*' || true
    echo
    log_info "Dry-run (no packages will change)"
    unattended-upgrade --dry-run --debug 2>&1 | tail -30 || true
  fi

  log_info "Updates done. Logs: /var/log/unattended-upgrades/"
  log_info "Automatic reboot: ${auto_reboot} (window ${reboot_hour})"
}

updates_status() {
  echo "--- updates ---"
  if [[ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]]; then
    echo "policy: /etc/apt/apt.conf.d/52unattended-upgrades-local present"
    grep -E 'Automatic-Reboot|Allowed-Origins|Origins-Pattern|distro_id|origin=' \
      /etc/apt/apt.conf.d/52unattended-upgrades-local 2>/dev/null | head -20 || true
  else
    echo "policy: not applied by koncreet"
  fi
  if systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
    echo "timer: apt-daily-upgrade enabled"
  else
    echo "timer: apt-daily-upgrade not enabled"
  fi
}
