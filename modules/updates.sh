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
    ui_run_quiet "enable apt timers" systemctl enable apt-daily.timer apt-daily-upgrade.timer
    systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    log_ok "origins: $KONCREET_OS_FAMILY · auto-reboot=$auto_reboot ($reboot_hour)"
    ui_step_start "unattended-upgrade dry-run"
    local dry
    dry="$(unattended-upgrade --dry-run --debug 2>&1 || true)"
    echo "$dry" >>"$(koncreet_log_path)" 2>/dev/null || true
    if echo "$dry" | grep -qi 'No packages found that can be upgraded unattended'; then
      ui_step_ok "no pending unattended upgrades"
    else
      ui_step_ok "dry-run complete (see log)"
    fi
  fi
}

updates_status() {
  ui_header "updates"
  if [[ -f /etc/apt/apt.conf.d/52unattended-upgrades-local ]]; then
    ui_kv "policy" "52unattended-upgrades-local"
    local reb
    reb="$(grep -E 'Automatic-Reboot "' /etc/apt/apt.conf.d/52unattended-upgrades-local 2>/dev/null | head -1 | sed 's/.*"\(.*\)".*/\1/' || true)"
    ui_kv "auto-reboot" "${reb:-unknown}"
  else
    ui_kv "policy" "not applied"
  fi
  if systemctl is-enabled --quiet apt-daily-upgrade.timer 2>/dev/null; then
    ui_kv "timer" "apt-daily-upgrade enabled"
  else
    ui_kv "timer" "not enabled"
  fi
}
