#!/usr/bin/env bash
# ============================================================
# setup-ssh.sh  (step 2 of 3)
# Run as root on the fresh box -- you can't log in as the new
# user remotely yet, so this still runs as root:
#   bash setup-ssh.sh
#
# Installs your host machine's public key (from the 1Password
# SSH agent) into the new user's authorized_keys, so you can
# SSH in as them -- with agent forwarding (ssh -A).
#
# No keys are generated on this server. GitHub access for the
# yadm dotfiles clone in setup-user.sh uses the same 1Password
# key, forwarded from your host; its public half is already on
# GitHub.
# ============================================================

# Fail fast on any error, unset variable, or pipe failure.
set -euo pipefail

# Default username used if you just press Enter at the prompt.
DEFAULT_USER="zacong"

# Must run as root: we're editing another user's ~/.ssh.
if [ "$(id -u)" -ne 0 ]; then
  echo "Must be run as root: sudo bash setup-ssh.sh" >&2
  exit 1
fi

# The user must already exist (created by setup-root.sh).
read -rp "Username of the new user [${DEFAULT_USER}]: " NEW_USER || true
NEW_USER="${NEW_USER:-$DEFAULT_USER}"

# Same validation as setup-root.sh: reject anything that would
# break useradd or the later paths.
if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Invalid username: $NEW_USER (lowercase letters, digits, - and _ only)" >&2
  exit 1
fi

if ! id "$NEW_USER" &>/dev/null; then
  echo "User $NEW_USER does not exist. Run setup-root.sh first." >&2
  exit 1
fi

# Preflight: we need ssh-keygen to validate the pasted key, and
# sshd should actually be running, otherwise the key install
# below is pointless.
command -v ssh-keygen >/dev/null 2>&1 || {
  echo "ssh-keygen not found (openssh-client not installed)." >&2
  exit 1
}
if ! systemctl is-active --quiet ssh && ! systemctl is-active --quiet sshd; then
  echo "Warning: no active ssh/sshd service detected." >&2
fi

# Resolve the user's home dir (works with any path, not just /home).
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || USER_HOME="/home/$NEW_USER"

# Resolve the user's actual primary group instead of assuming it
# matches the username -- it won't for some existing accounts.
USER_GROUP="$(id -gn "$NEW_USER")"

# Create ~/.ssh owned by the new user (not root), so later SSH
# use by the new user works without warnings.
install -d -o "$NEW_USER" -g "$USER_GROUP" -m 700 "$USER_HOME/.ssh"

# ------------------------------------------------------------
# Install the host machine's public key
# ------------------------------------------------------------
# On your host machine (where the 1Password SSH agent runs),
# print your public key with:
#   ssh-add -L
# Paste one of those lines here. This key is the only way back
# in once setup-user.sh disables password auth, so a valid key
# is REQUIRED -- do not continue without one.
echo "### Installing host machine's public key for $NEW_USER ###"
echo "    (On your host: copy one line of 'ssh-add -L' output.)"
read -rp "    Paste your host machine's public key: " HOST_PUB_KEY || true

if [[ -z "$HOST_PUB_KEY" ]]; then
  echo "    A host public key is required; you'd otherwise have no way in as $NEW_USER." >&2
  exit 1
fi

# Validate that the paste really is a public key with ssh-keygen
# (a prefix match alone can't tell a base64 key from garbage).
HOST_KEY_CHECK="$(mktemp)"
trap 'rm -f "$HOST_KEY_CHECK"' EXIT
printf '%s\n' "$HOST_PUB_KEY" > "$HOST_KEY_CHECK"
if ! ssh-keygen -lf "$HOST_KEY_CHECK" >/dev/null 2>&1; then
  echo "    That doesn't look like a valid public key; re-run with a real one." >&2
  exit 1
fi

if ! grep -qxF "$HOST_PUB_KEY" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
  # install creates the file already owned by the new user with
  # 600, so there's no root-owned window before the chown.
  install -m 600 -o "$NEW_USER" -g "$USER_GROUP" /dev/null "$USER_HOME/.ssh/authorized_keys"
  echo "$HOST_PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
  echo "    Installed. You'll be able to SSH in as $NEW_USER."
else
  echo "    Already present, skipping."
fi
# Owner-only read/write so the key material can't be read by
# others (sshd also checks ownership to refuse untrusted keys).
chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

echo ""
echo "### Step 2 done. ###"
echo "No server-side key was generated: GitHub access uses your"
echo "1Password key forwarded from your host (its public half is"
echo "already on GitHub)."
echo ""
echo "From your host machine, log in as $NEW_USER WITH agent forwarding:"
echo "  ssh -A $NEW_USER@<host-ip-or-name>"
echo "(or set 'ForwardAgent yes' for this host in ~/.ssh/config)"
echo "Then run: bash setup-user.sh"
