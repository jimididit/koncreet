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

# Return 0 if the user can run sudo: member of the sudo/admin group, or granted by sudoers.
koncreet_user_can_sudo() {
  local u="$1" g
  for g in $(id -nG "$u" 2>/dev/null); do
    [[ "$g" == "${KONCREET_SUDO_GROUP:-sudo}" || "$g" == "admin" ]] && return 0
  done
  command -v sudo &>/dev/null && sudo -l -U "$u" 2>/dev/null | grep -q 'may run the following'
}

# Find a non-root user with a working SSH key. Prefer SUDO_USER, then scan /home.
# With "sudo" as $1, the user must also be able to run sudo.
# Prints the username; returns 1 if none found.
koncreet_find_nonroot_key_user() {
  local need_sudo="${1:-}"
  local -a candidates=()
  local home u
  [[ -n "${SUDO_USER:-}" ]] && candidates+=("$SUDO_USER")
  for home in /home/*; do
    [[ -d "$home" ]] && candidates+=("$(basename "$home")")
  done
  for u in "${candidates[@]+"${candidates[@]}"}"; do
    [[ "$u" == "root" ]] && continue
    id -u "$u" &>/dev/null || continue
    koncreet_user_has_key "$u" || continue
    if [[ "$need_sudo" == "sudo" ]] && ! koncreet_user_can_sudo "$u"; then
      continue
    fi
    echo "$u"
    return 0
  done
  return 1
}

# Gate for PermitRootLogin no: must have a non-root account with a live key AND sudo,
# otherwise disabling root login leaves nobody who can administer the box over SSH.
koncreet_ssh_harden_gate() {
  local user
  if user="$(koncreet_find_nonroot_key_user sudo)"; then
    log_info "OK: '$user' has SSH key(s) and sudo - safe to disable root login."
    echo "$user"
    return 0
  fi
  if user="$(koncreet_find_nonroot_key_user)"; then
    log_error "NOT SAFE: '$user' has SSH keys but cannot use sudo - you would lose root access."
    log_error "Grant sudo first: koncreet baseline apply --user $user  (or: usermod -aG ${KONCREET_SUDO_GROUP:-sudo} $user)"
    return 1
  fi
  log_error "NOT SAFE: no non-root user with a working authorized_keys found."
  log_error "Create a sudo user with an SSH key first (koncreet baseline apply --user NAME),"
  log_error "or: ssh-copy-id user@host - then re-run."
  return 1
}

# True if $1 is an IPv4/IPv6 address, optionally with a /prefix.
koncreet_valid_ip() {
  local ip="${1:-}" o
  if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(/[0-9]{1,2})?$ ]]; then
    for o in "${BASH_REMATCH[@]:1:4}"; do
      (( 10#$o <= 255 )) || return 1
    done
    return 0
  fi
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]]
}

# Print the IP of the SSH client that started this session; returns 1 if unknown.
# sudo strips SSH_CONNECTION, so fall back to the environment of our ancestor
# processes (the login shell still has it), then to who -m.
koncreet_ssh_client_ip() {
  local ip pid="$$" var
  ip="${SSH_CONNECTION:-${SSH_CLIENT:-}}"
  ip="${ip%% *}"
  while [[ -z "$ip" && "$pid" -gt 1 && -r "/proc/$pid/status" ]]; do
    if [[ -r "/proc/$pid/environ" ]]; then
      var="$(tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -m1 -E '^SSH_(CONNECTION|CLIENT)=' || true)"
      ip="${var#*=}"
      ip="${ip%% *}"
    fi
    pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
    pid="${pid:-0}"
  done
  if [[ -z "$ip" ]]; then
    ip="$(who -m 2>/dev/null | sed -n 's/.*(\(.*\)).*/\1/p' || true)"
  fi
  koncreet_valid_ip "$ip" || return 1
  echo "$ip"
}

# Print the port of a systemd "ListenStream=" line: 22, 0.0.0.0:22 or [::]:22.
# Ubuntu 24.04 ships ListenStream=0.0.0.0:22, so never take the first number.
koncreet_listenstream_port() {
  local line="${1%%#*}"
  if [[ "$line" =~ ^[[:space:]]*ListenStream=[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
    echo "${BASH_REMATCH[1]}"
  elif [[ "$line" =~ ^[[:space:]]*ListenStream=.*:([0-9]+)[[:space:]]*$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    return 1
  fi
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
      if p="$(koncreet_listenstream_port "$line")"; then
        ports["$p"]=1
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
