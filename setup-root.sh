#!/usr/bin/env bash
# ============================================================
# setup-root.sh  (step 1 of 3)
# Run as root on a fresh Ubuntu box (24.04+):
#   bash setup-root.sh
#
# Creates a sudo user with its home dir and password. That's
# it -- everything else (SSH setup, packages, shell, dotfiles,
# firewall, proxy) runs in the later steps:
#   bash setup-ssh.sh    (step 2, still as root)
#   bash setup-user.sh   (step 3, as the new user)
# ============================================================

# Fail fast on any error, unset variable, or pipe failure.
set -euo pipefail

# Default username used if you just press Enter at the prompt.
DEFAULT_USER="zacong"

# This script must run as root: creating a user is a system
# operation. Bail out early with a clear message if not.
if [ "$(id -u)" -ne 0 ]; then
  echo "Must be run as root: sudo bash setup-root.sh" >&2
  exit 1
fi

# Ask for the username up front so every later step can use it.
# Pressing Enter falls back to $DEFAULT_USER. `|| true` keeps the
# script alive if you hit Ctrl-D at the prompt.
read -rp "Username for new sudo user [$DEFAULT_USER]: " NEW_USER || true
NEW_USER="${NEW_USER:-$DEFAULT_USER}"

# Reject anything that would break useradd or the later paths.
# useradd also enforces its own limits (max 32 chars, and it
# forbids some reserved names), so double-check the obvious ones.
if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || (( ${#NEW_USER} > 32 )); then
  echo "Invalid username: $NEW_USER (lowercase letters, digits, - and _ only, max 32 chars)" >&2
  exit 1
fi
# Refuse reserved system account names outright -- typing "root",
# "sync" or "nobody" here would otherwise hit a system account.
if [[ "$NEW_USER" == "root" ]] || \
   [[ "$NEW_USER" =~ ^(daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|nobody|nobody4|halt|shutdown|operator|systemd-.*|_.*)$ ]]; then
  echo "Refusing reserved system account name: $NEW_USER" >&2
  exit 1
fi

# ------------------------------------------------------------
# Create the user + password
# ------------------------------------------------------------
# -m       create a home directory
# -s bash  use bash as the initial shell (zsh comes later)
# -G sudo  add the user to the sudo group
# Never silently modify an existing account: resetting a
# password on an existing admin/service account without consent
# is dangerous. Ask first, and bail out if not confirmed.
echo "### Creating sudo user $NEW_USER ###"
if id "$NEW_USER" &>/dev/null; then
  # Refuse to operate on system accounts: typing "nobody" or
  # "sync" here would otherwise reset a system account's password.
  if [ "$(id -u "$NEW_USER")" -lt 1000 ]; then
    echo "Refusing: $NEW_USER is a system account (UID < 1000)." >&2
    exit 1
  fi
  echo "    User $NEW_USER already exists."
  read -rp "    Reset its password anyway? (y/N): " RESET_PASS || true
  if [[ "${RESET_PASS,,}" != "y" ]]; then
    echo "    Not changing anything. Re-run if you meant to touch this account." >&2
    exit 1
  fi
else
  useradd -m -s /bin/bash -G sudo "$NEW_USER"
fi

# Double-check the user actually landed in the sudo group and
# add them if not, so setup-user.sh can use sudo. Verify sudo is
# installed first: minimal images may not ship it.
if id -nG "$NEW_USER" | grep -qw sudo; then
  echo "    $NEW_USER is in the sudo group."
else
  command -v sudo >/dev/null 2>&1 || {
    echo "sudo is not installed; run: apt-get install -y sudo" >&2
    exit 1
  }
  usermod -aG sudo "$NEW_USER"
  echo "    Added $NEW_USER to the sudo group."
fi

# Set the user's password now. Password SSH login is still
# allowed at this point -- it's the only way in until
# setup-ssh.sh installs the host key and setup-user.sh runs
# the final sshd hardening step. Treat it as temporary: it will
# be disabled once key-only auth is confirmed.
echo "    Note: this password is TEMPORARY -- setup-user.sh disables password SSH login."
passwd "$NEW_USER"

echo ""
echo "### Part 1 done. ###"
echo "Next, still as root, run the SSH setup:"
echo "  bash setup-ssh.sh"
echo "Then, from your host machine, log in as $NEW_USER:"
echo "  ssh $NEW_USER@<host-ip-or-name>"
echo "And finally, run the user setup:"
echo "  bash setup-user.sh"
