# Changelog

## Unreleased

## 0.2.5

- doctor: always checks the effective SSH settings with `sshd -T` when run as root, not only when a koncreet drop-in exists; with no drop-in and password/root login still on it warns with the live values and points to `sudo koncreet ssh apply` (so it no longer ends with "all clear"), and with no drop-in but everything already off it says so; Match blocks that re-enable password/root login are reported too
- doctor: the admin-user line now reads "ready for ssh apply" instead of "SSH harden ready", which looked like SSH was already hardened; as non-root it says SSH was not checked and points to `sudo koncreet doctor` (never calls sudo)
- ssh status: reports the same facts as doctor (not applied with the effective values, or already off without a koncreet drop-in, plus Match overrides)
- apply / menu "Run everything": when SSH hardening was requested but skipped by the pre-run safety check, the skip is now written to `/var/log/koncreet.log`, the final line says "Done - 1 module skipped (ssh)", and "Before you disconnect" lists "SSH is NOT hardened yet" with the `sudo koncreet ssh apply` step. When SSH hardening runs is unchanged
- baseline: the login MOTD warns while there is no koncreet SSH drop-in and `sshd -T` shows password/root login on (exits at once when the drop-in exists, caps `sshd -T` at 2 seconds, stays silent on errors); existing installs pick this up on the next `baseline apply`
- ssh: `ssh apply` no longer prints the sudo password koncreet generated. While that password is still the user's password (checked against `/etc/shadow` with an exact hash check, so a same-day `passwd` is caught), root login is only disabled when the run comes through sudo as that user: log in as the user, check `sudo -v`, then run `sudo koncreet ssh apply`. That proves key login, sudo rights and the password in one step. A run straight from a root session refuses, even with `--yes`, and `apply -c` / "Run everything" plan a SKIP with that reason instead. If the user already set their own password the run goes ahead and the stale `/root/USER.koncreet-password` is removed; after a successful run through sudo the file is removed too, so no plaintext copy stays on disk. `baseline` still shows the password once when it creates the user
- ssh: a user in the sudo group whose password is locked or unset (and no `NOPASSWD` rule) no longer passes the safety check, since sudo cannot work for them; the error and `doctor` say to run `passwd USER`
- doctor: when the generated password still has to be proven, the admin line says to log in as that user and run `sudo koncreet ssh apply`
- ssh: the Match and conflicting-line scans now follow `Include` lines in `sshd_config` (recursively), understand `Keyword=value`, and treat the old `ChallengeResponseAuthentication` name as keyboard-interactive; the port scan uses the same file list

## 0.2.4

- ssh: after apply, also fail closed when a `Match` block re-enables password/root/kbd-interactive auth (global `sshd -T` misses those); probe effective settings with `sshd -T -C` for root and the admin user
- firewall: refuse to enable ufw when SSH listen ports cannot be detected (no more silent default to port 22); dry-run still completes and plans the refuse (CI smoke images often have no sshd Port)
- baseline: restore umask after writing `/root/USER.koncreet-password`; `write_file` forces world-readable modes for `/etc` drop-ins so a tight umask cannot leave apt/sysctl/journald config root-only
- doctor: SSH harden readiness requires keys and sudo (same gate as `ssh apply`); checks `00-koncreet.conf` (and flags legacy `99-*`) and reports when `sshd -T` still shows password/root login on
- doctor: as non-root, warn when `/etc/ssh/sshd_config.d` is unreadable instead of skipping; never block on a sudo password prompt when probing sudoers (`sudo -n`); suggest `chmod` if older koncreet left `/etc` drop-ins root-only
- ssh: drop-in renamed to `00-koncreet.conf` so it wins over `50-cloud-init.conf` (sshd keeps the first value); `ssh apply` verifies effective settings with `sshd -T` and rolls back on override; `ssh status` shows effective values. Legacy `99-koncreet.conf` is migrated.
- ssh: hardening gate now requires the key user to have sudo, and asks you to confirm a koncreet-generated sudo password was saved before root login is disabled
- fail2ban: detect your SSH client IP under `sudo` (walks parent process environment, then `who -m`); warn when it can't; `whitelist` validates the IP
- firewall: parse Ubuntu 24.04 `ListenStream=0.0.0.0:22` as port 22 (was 0, which made `ufw allow` fail)
- Error/warning/info messages (including every `die`) were silently dropped from the terminal; they now print
- apply: SSH hardening is decided once before the run, so a plan that says "SKIP SSH harden" no longer hardens SSH after `baseline` creates the user in the same run
- CI: `tests/integration.sh` runs lockout scenarios against a real sshd, sudo and ufw rule parser on Debian 12/13 and Ubuntu 22.04/24.04
- dry-run: no longer asks the fail2ban whitelist question (shown as a `PLAN:` line instead), no longer prints the "Before you disconnect" checklist, and ends with "Dry-run done - nothing changed"
- log: dry-run as root logs to `/var/log/koncreet.log` (tagged `dry-run`) instead of `/opt/koncreet/koncreet.log`, which `install.sh` and `uninstall` delete; non-root runs log to `~/.local/state/koncreet/`
- Thanks @lord-helicon for [#2](https://github.com/jimididit/koncreet/pull/2) (SSH/sudo lockout and silent-failure fixes) and for reporting the doctor edge cases (unreadable `/etc/ssh`, non-blocking sudoers probe, root-only `/etc` mode hints)

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
- Menu "Run everything" only plans SSH harden when a key user exists
- PR CI (tests + shellcheck) and container smoke dry-run
- Release workflow runs tests before publishing

## 0.1.0

- First tagged toolkit: baseline, firewall, fail2ban, updates, ssh
