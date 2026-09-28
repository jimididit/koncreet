# Changelog

## Unreleased

- ssh: drop-in renamed to `00-koncreet.conf` so it wins over `50-cloud-init.conf` (sshd keeps the first value); `ssh apply` verifies effective settings with `sshd -T` and rolls back on override; `ssh status` shows effective values. Legacy `99-koncreet.conf` is migrated.
- ssh: hardening gate now requires the key user to have sudo, and asks you to confirm a koncreet-generated sudo password was saved before root login is disabled
- fail2ban: detect your SSH client IP under `sudo` (walks parent process environment, then `who -m`); warn when it can't; `whitelist` validates the IP
- firewall: parse Ubuntu 24.04 `ListenStream=0.0.0.0:22` as port 22 (was 0, which made `ufw allow` fail)
- Error/warning/info messages (including every `die`) were silently dropped from the terminal; they now print
- apply: SSH hardening is decided once before the run, so a plan that says "SKIP SSH harden" no longer hardens SSH after `baseline` creates the user in the same run

## 0.2.3

- fail2ban: tolerate unset SSH_CONNECTION under `set -u` (CI dry-run / non-SSH shells)

## 0.2.2

- CI: ShellCheck fails on errors only (sourced CFG_* vars trip SC2034 across files)

## 0.2.1

- Mark `koncreet` / `install.sh` executable in git; run version tests via `bash` for CI

## 0.2.0

- `koncreet doctor` - apply-readiness checks
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
