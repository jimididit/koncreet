# Changelog

## 0.2.2

- CI: ShellCheck fails on errors only (sourced CFG_* vars trip SC2034 across files)

## 0.2.1

- Mark `koncreet` / `install.sh` executable in git; run version tests via `bash` for CI

## 0.2.0

- `koncreet doctor` — apply-readiness checks
- Post-apply checklist after `apply` / Run everything
- Baseline: `--pubkey` / `--pubkey-file`, `baseline undo`, logrotate + MOTD
- Firewall: custom `N/tcp` / `N/udp` and `firewall_ports=` config
- `koncreet uninstall [--purge]`
- Menu “Run everything” only plans SSH harden when a key user exists
- PR CI (tests + shellcheck) and container smoke dry-run
- Release workflow runs tests before publishing

## 0.1.0

- First tagged toolkit: baseline, firewall, fail2ban, updates, ssh
- curl install to `/opt/koncreet` + PATH symlink
- Compact terminal UI, config apply, self-install
