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

# Preflight: we need ssh-keygen, and sshd should actually be
# running, otherwise the key install below is pointless.
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

# Create ~/.ssh owned by the new user (not root), so ssh-keygen
# and the new user's later use of the key work without warnings.
install -d -o "$NEW_USER" -g "$USER_GROUP" -m 700 "$USER_HOME/.ssh"

# ------------------------------------------------------------
# 1. Install the host machine's public key
# ------------------------------------------------------------
# Paste the contents of ~/.ssh/id_ed25519.pub from your host
# machine (the laptop you'll be SSH-ing in from). This key is the
# only way back in once setup-user.sh disables password auth, so
# a valid key is REQUIRED -- do not continue without one.
echo "### Installing host machine's public key for $NEW_USER ###"
read -rp "    Paste your host machine's public key: " HOST_PUB_KEY || true

if [[ -z "$HOST_PUB_KEY" ]]; then
  echo "    A host public key is required; you'd otherwise have no way in as $NEW_USER." >&2
  exit 1
fi

# Validate that the paste really is a public key with ssh-keygen
# (a prefix match alone can't tell a base64 key from garbage).
HOST_KEY_CHECK="$(mktemp)"
printf '%s\n' "$HOST_PUB_KEY" > "$HOST_KEY_CHECK"
if ! ssh-keygen -lf "$HOST_KEY_CHECK" >/dev/null 2>&1; then
  rm -f "$HOST_KEY_CHECK"
  echo "    That doesn't look like a valid public key; re-run with a real one." >&2
  exit 1
fi
rm -f "$HOST_KEY_CHECK"

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

# ------------------------------------------------------------
# 2. Generate the new user's keypair (for GitHub)
# ------------------------------------------------------------
# The public half goes on GitHub so the setup-user.sh yadm
# clone works; the private half stays on this server. The key is
# protected with a passphrase you choose below -- no default, so
# it never lands in the script or in version control. setup-user.sh
# loads it into an ssh-agent so the yadm clone still runs
# unattended.
echo "### Generating SSH keypair for $NEW_USER ###"
if [ ! -f "$USER_HOME/.ssh/id_ed25519" ]; then
  # Prompt (silently) for the passphrase, twice to catch typos.
  # Empty is rejected: an unprotected key on a server is a risk.
  read -rsp "    Passphrase for the new SSH key (required): " SSH_KEY_PASS || true
  echo
  read -rsp "    Confirm passphrase: " SSH_KEY_PASS_CONFIRM || true
  echo
  if [ -z "$SSH_KEY_PASS" ]; then
    echo "    Passphrase cannot be empty." >&2
    exit 1
  fi
  if [[ "$SSH_KEY_PASS" != "$SSH_KEY_PASS_CONFIRM" ]]; then
    echo "    Passphrases do not match; re-run the script." >&2
    exit 1
  fi

  # Feed the passphrase via SSH_ASKPASS (see setup_askpass above)
  # so it never appears in `ps`. We generate as root and fix up
  # ownership afterwards, since `sudo -u` would strip the
  # SSH_ASKPASS variables from the environment.
  setup_askpass "$SSH_KEY_PASS"
  SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force \
    ssh-keygen -t ed25519 -C "$NEW_USER@$(hostname)" -f "$USER_HOME/.ssh/id_ed25519"
  chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh/id_ed25519" "$USER_HOME/.ssh/id_ed25519.pub"
else
  echo "    Key already exists, keeping it."
  # Validate the existing key is readable and fix up ownership
  # and permissions regardless.
  if ! ssh-keygen -lf "$USER_HOME/.ssh/id_ed25519" >/dev/null 2>&1; then
    echo "    Existing key at $USER_HOME/.ssh/id_ed25519 could not be read." >&2
    exit 1
  fi
  chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh/id_ed25519" "$USER_HOME/.ssh/id_ed25519.pub"
fi
chmod 600 "$USER_HOME/.ssh/id_ed25519"
[ -f "$USER_HOME/.ssh/id_ed25519.pub" ] && chmod 644 "$USER_HOME/.ssh/id_ed25519.pub"

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
echo "3. Optionally verify GitHub auth from the server now (once the key is on GitHub):"
echo "     ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com"
echo "4. Then run: bash setup-user.sh"

# Optional live check: confirms the GitHub key actually works
# before setup-user.sh depends on it for the yadm clone. Load the
# key into a throwaway agent first -- with BatchMode=yes ssh won't
# prompt for the passphrase, so an unloaded key would fail the test
# even when it's correct.
read -rp "    Test GitHub auth now? (y/N): " TEST_GH || true
if [[ "${TEST_GH,,}" == "y" ]]; then
  if [ -z "${SSH_KEY_PASS:-}" ]; then
    read -rsp "    SSH key passphrase (required): " SSH_KEY_PASS || true
    echo
  fi
  eval "$(ssh-agent -s)"
  setup_askpass "${SSH_KEY_PASS:-}"
  SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force ssh-add "$USER_HOME/.ssh/id_ed25519"
  # Capture the actual ssh output instead of piping it into grep:
  # the pipe would swallow the real error ("Permission denied
  # (publickey)" vs a network failure) and leave only a generic
  # "failed" message behind.
  GH_OUTPUT="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
  if printf '%s' "$GH_OUTPUT" | grep -qi "successfully authenticated"; then
    echo "    GitHub auth OK."
  else
    echo "    GitHub auth failed. Raw ssh output:" >&2
    printf '      %s\n' "$GH_OUTPUT" >&2
    echo "    Fix the key (is it pasted into GitHub, on the right account?) before running setup-user.sh." >&2
    ssh-agent -k >/dev/null 2>&1 || true
    exit 1
  fi
  ssh-agent -k >/dev/null 2>&1 || true
fi
