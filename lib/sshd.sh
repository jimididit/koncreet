#!/usr/bin/env bash
# SSH helpers: listen ports, key presence, non-root gate
# shellcheck shell=bash

# True if file has at least one non-comment, non-blank key line.
koncreet_has_working_key_file() {
  local f="$1"
  [[ -s "$f" ]] && grep -qvE '^\s*(#|$)' "$f"
}

# Home directory for a user.
koncreet_user_home() {
  getent passwd "$1" | cut -d: -f6
}

# authorized_keys path for a user.
koncreet_auth_keys_path() {
  local home
  home="$(koncreet_user_home "$1")"
  echo "${home}/.ssh/authorized_keys"
}

# Return 0 if user has a working authorized_keys entry.
koncreet_user_has_key() {
  local user="$1"
  local keys
  keys="$(koncreet_auth_keys_path "$user")"
  koncreet_has_working_key_file "$keys"
}

# Find a non-root user with a working SSH key. Prefer SUDO_USER, then scan /home.
# Prints the username; returns 1 if none found.
koncreet_find_nonroot_key_user() {
  local u="${SUDO_USER:-}"
  if [[ -n "$u" && "$u" != "root" ]] && id -u "$u" &>/dev/null; then
    if koncreet_user_has_key "$u"; then
      echo "$u"
      return 0
    fi
  fi
  local home user
  for home in /home/*; do
    [[ -d "$home" ]] || continue
    user="$(basename "$home")"
    [[ "$user" == "root" ]] && continue
    id -u "$user" &>/dev/null || continue
    if koncreet_user_has_key "$user"; then
      echo "$user"
      return 0
    fi
  done
  return 1
}

# Gate for PermitRootLogin no: must have a non-root account with a live key.
koncreet_ssh_harden_gate() {
  local user
  if user="$(koncreet_find_nonroot_key_user)"; then
    log_info "OK: non-root user '$user' has SSH key(s) — safe to disable root login."
    echo "$user"
    return 0
  fi
  log_error "NOT SAFE: no non-root user with a working authorized_keys found."
  log_error "Create a sudo user with an SSH key first (koncreet baseline apply --user NAME),"
  log_error "or: ssh-copy-id user@host — then re-run."
  return 1
}

# Collect SSH listen ports from sshd -T, config files, and systemd socket units.
# Prints unique port numbers, one per line. Defaults to 22 if none found.
koncreet_ssh_listen_ports() {
  local -A ports=()
  local p line

  # Effective config (best source when sshd is installed)
  if command -v sshd &>/dev/null; then
    while read -r line; do
      # sshd -T: "port 22" (may appear multiple times)
      if [[ "$line" =~ ^port[[:space:]]+([0-9]+)$ ]]; then
        ports["${BASH_REMATCH[1]}"]=1
      fi
    done < <(sshd -T 2>/dev/null || true)
  fi

  # Config files (fallback / additional)
  local f
  for f in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$f" ]] || continue
    while read -r line; do
      # strip comments
      line="${line%%#*}"
      if [[ "$line" =~ ^[[:space:]]*[Pp]ort[[:space:]]+([0-9]+) ]]; then
        ports["${BASH_REMATCH[1]}"]=1
      fi
    done <"$f"
  done

  # systemd socket ListenStream=
  for f in /lib/systemd/system/ssh.socket /usr/lib/systemd/system/ssh.socket \
           /etc/systemd/system/ssh.socket /etc/systemd/system/ssh.socket.d/*.conf; do
    [[ -f "$f" ]] || continue
    while read -r line; do
      line="${line%%#*}"
      if [[ "$line" =~ ListenStream=([0-9]+) ]]; then
        ports["${BASH_REMATCH[1]}"]=1
      elif [[ "$line" =~ ListenStream=\[.*\]:([0-9]+) ]]; then
        ports["${BASH_REMATCH[1]}"]=1
      elif [[ "$line" =~ ListenStream=.+:([0-9]+)$ ]]; then
        ports["${BASH_REMATCH[1]}"]=1
      fi
    done <"$f"
  done

  if [[ "${#ports[@]}" -eq 0 ]]; then
    echo 22
    return 0
  fi
  for p in "${!ports[@]}"; do
    echo "$p"
  done | sort -n
}
