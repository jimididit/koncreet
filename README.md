# Koncreet

<p align="center">
  <img src="assets/banner.svg" alt="koncreet - first-hour server hardening" width="832" />
</p>

First-hour hardening for a fresh Linux VPS. Plain Bash, change plans before it touches anything, and defaults that try not to lock you out.

**Debian 12/13 and Ubuntu 22.04/24.04 only.**

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/jimididit/koncreet/main/install.sh | sudo bash
sudo koncreet
```

That drops the toolkit in `/opt/koncreet` and puts `koncreet` on your PATH. Prefer a release build once they exist:

```bash
curl -fsSL https://github.com/jimididit/koncreet/releases/latest/download/install.sh | sudo bash
```

Pin with `KONCREET_VERSION=0.1.0`. Or clone and run from the tree:

```bash
git clone https://github.com/jimididit/koncreet.git && cd koncreet
sudo ./koncreet
```

## What you get

| Module | |
|--------|--|
| **baseline** | Sudo user + SSH keys, safer sysctl, swap if missing, journald cap, timezone/NTP |
| **firewall** | ufw default-deny; your real SSH port(s) opened first |
| **fail2ban** | systemd backend; ufw bans when ufw is active |
| **updates** | Distro-correct unattended security updates; auto-reboot off unless you ask |
| **ssh** | Turns off password auth and root login only if a non-root user already has keys |

It will **not** do CIS/STIG, manage a fleet, or open MySQL/FTP to the world without `--public`.

## Usage

Interactive menu is the default. Every apply path prints a change plan first.

```bash
sudo koncreet status
sudo koncreet baseline apply --user deploy
sudo koncreet firewall apply https
sudo koncreet fail2ban apply ssh
sudo koncreet updates apply
sudo koncreet ssh check
sudo koncreet ssh apply
```

Config-driven run:

```bash
cp /opt/koncreet/share/koncreet.conf.example ./koncreet.conf
# edit, then:
sudo koncreet --dry-run apply -c ./koncreet.conf
sudo koncreet apply -c ./koncreet.conf --yes
```

Flags: `-n` dry-run, `-y` assume yes, `-c` config, `-v` verbose, `-V` version.

`sheriff` is an alias for `fail2ban`.

## If something goes wrong

Keep the session you hardened from open. Test a **new** SSH login before you disconnect.

| Problem | Fix |
|---------|-----|
| Can't SSH after harden | `sudo koncreet ssh undo` |
| Locked out by ufw | Console: `sudo ufw disable` |
| Banned by fail2ban | `sudo koncreet fail2ban unban YOUR.IP` |
| Need the new user password | `cat /root/USER.koncreet-password` |
| Forced password change fails | `chage -d $(date -I) USER` then reconnect with your key |
| Too many authentication failures | `ssh -o IdentitiesOnly=yes -i ~/.ssh/your_key user@host` |

Logs land in `/var/log/koncreet.log`. Overwritten files get a `*.koncreet.bak`.

## Config

Keys and defaults: [`share/koncreet.conf.example`](share/koncreet.conf.example).

## Development

```bash
bash tests/run.sh
shellcheck koncreet lib/*.sh modules/*.sh   # if you have shellcheck
```

Version is in [`VERSION`](VERSION). Tag releases as `v` + that number (CI builds the tarball).

## License

[MIT](LICENSE)
