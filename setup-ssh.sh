#!/usr/bin/env bash
# ============================================================
# setup-ssh.sh  (step 2 of 3)
# Run as root on the fresh box -- you can't log in as the new
# user remotely yet, so this still runs as root:
#   bash setup-ssh.sh
#
# 1. Installs your host machine's public key into the new
#    user's authorized_keys, so you can SSH in as them.
# 2. Generates a fresh keypair for the new user and prints the
#    public key for you to paste into GitHub -- the yadm
#    dotfiles clone in setup-user.sh uses it.
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

# The passphrase is fed to ssh-keygen via SSH_ASKPASS so it never
# shows up on a command line or gets interpolated into script
# source: it lives in a 0600 temp file that a tiny helper cats on
# demand. Both are removed on every exit path.
ASKPASS_CLEANUP=()
setup_askpass() {
  local helper passfile
  helper="$(mktemp)"
  passfile="$(mktemp)"
  chmod 600 "$passfile"
  printf '%s' "$1" > "$passfile"
  printf '#!/bin/sh\ncat "%s"\n' "$passfile" > "$helper"
  chmod 700 "$helper"
  ASKPASS_CLEANUP+=("$helper" "$passfile")
  ASKPASS_HELPER="$helper"
}
cleanup_askpass() {
  local f
  for f in "${ASKPASS_CLEANUP[@]:-}"; do
    rm -f "$f"
  done
}
trap cleanup_askpass EXIT

# The user must already exist (created by setup-root.sh).
read -rp "Username of the new user [${DEFAULT_USER}]: " NEW_USER || true
NEW_USER="${NEW_USER:-$DEFAULT_USER}"

if ! id "$NEW_USER" &>/dev/null; then
  echo "User $NEW_USER does not exist. Run setup-root.sh first." >&2
  exit 1
fi

# Resolve the user's home dir (works with any path, not just /home).
USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
[ -n "$USER_HOME" ] || USER_HOME="/home/$NEW_USER"

# Create ~/.ssh owned by the new user (not root), so ssh-keygen
# and the new user's later use of the key work without warnings.
install -d -o "$NEW_USER" -g "$NEW_USER" -m 700 "$USER_HOME/.ssh"

# ------------------------------------------------------------
# 1. Install the host machine's public key
# ------------------------------------------------------------
# Paste the contents of ~/.ssh/id_ed25519.pub from your host
# machine (the laptop you'll be SSH-ing in from).
echo "### Installing host machine's public key for $NEW_USER ###"
read -rp "    Paste your host machine's public key: " HOST_PUB_KEY || true

if [ -n "$HOST_PUB_KEY" ]; then
  case "$HOST_PUB_KEY" in
    ssh-ed25519*|ssh-rsa*|ecdsa-sha2-*|ssh-dss*|sk-ssh-ed25519*|sk-ecdsa-sha2-*)
      if ! grep -qxF "$HOST_PUB_KEY" "$USER_HOME/.ssh/authorized_keys" 2>/dev/null; then
        # install creates the file already owned by the new user with
        # 600, so there's no root-owned window before the chown.
        install -m 600 -o "$NEW_USER" -g "$NEW_USER" /dev/null "$USER_HOME/.ssh/authorized_keys"
        echo "$HOST_PUB_KEY" >> "$USER_HOME/.ssh/authorized_keys"
        echo "    Installed. You'll be able to SSH in as $NEW_USER."
      else
        echo "    Already present, skipping."
      fi
      ;;
    *)
      echo "    That doesn't look like a public key; skipping." >&2
      ;;
  esac
else
  echo "    No key pasted; you'll need another way in as $NEW_USER." >&2
  read -rp "    Continue anyway? setup-user.sh will refuse to disable password auth until a key is installed. (y/N): " CONTINUE_NO_KEY || true
  if [[ "${CONTINUE_NO_KEY,,}" != "y" ]]; then
    echo "    Aborting." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------
# 2. Generate the new user's keypair (for GitHub)
# ------------------------------------------------------------
# The public half goes on GitHub so the setup-user.sh yadm
# clone works; the private half stays on this server. The key is
# protected with a passphrase by default (prompted below) --
# setup-user.sh loads it into an ssh-agent so the yadm clone
# still runs unattended.
echo "### Generating SSH keypair for $NEW_USER ###"
if [ ! -f "$USER_HOME/.ssh/id_ed25519" ]; then
  # Prompt (silently) for the passphrase. Empty input generates a
  # random one and prints it once, so the key is never left with a
  # default or empty passphrase.
  read -rsp "    Passphrase for the new SSH key (empty = generate a random one): " SSH_KEY_PASS || true
  echo
  if [ -z "$SSH_KEY_PASS" ]; then
    SSH_KEY_PASS="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
    echo "    Generated passphrase (save it -- you'll need it for setup-user.sh):"
    echo "    $SSH_KEY_PASS"
  fi

  # Feed the passphrase via SSH_ASKPASS (see setup_askpass above) so
  # it never appears in `ps`. Run ssh-keygen as root and fix up
  # ownership afterwards, since sudo -u would strip SSH_ASKPASS.
  setup_askpass "$SSH_KEY_PASS"
  SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force ssh-keygen -t ed25519 \
    -C "$NEW_USER@$(hostname)" -f "$USER_HOME/.ssh/id_ed25519"
  chown "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh/id_ed25519" "$USER_HOME/.ssh/id_ed25519.pub"
else
  echo "    Key already exists, keeping it."
fi

echo ""
echo "    Add this public key to GitHub (Settings > SSH and GPG keys):"
echo ""
cat "$USER_HOME/.ssh/id_ed25519.pub"
echo ""
echo "    Fingerprint (for GitHub cross-check):"
ssh-keygen -lf "$USER_HOME/.ssh/id_ed25519.pub"
echo ""
echo "### Step 2 done. ###"
echo "1. Paste the public key above into GitHub."
echo "2. From your host machine, log in as $NEW_USER:"
echo "     ssh $NEW_USER@<host-ip-or-name>"
echo "3. Then run: bash setup-user.sh"
