#!/usr/bin/env bash
# ============================================================
# setup-squid.sh
# Standalone Squid proxy setup, extracted from the squid section
# of setup-user.sh so the config-writing part can be tested in
# isolation (run as the new user, like setup-user.sh).
#
#   bash setup-squid.sh
#
# Env overrides for unattended / repeat testing:
#   SQUID_IP=1.2.3.4 SQUID_USER=foo SQUID_PASS=bar \
#     SKIP_INSTALL=1 FORCE=1 bash setup-squid.sh
#
#   SQUID_IP      -> IP allowed without login (default: your SSH
#                    client IP)
#   SQUID_USER    -> proxy username (prompted if unset)
#   SQUID_PASS    -> proxy password (prompted if unset)
#   SKIP_INSTALL  -> 1 to skip apt install / systemctl enable
#   FORCE         -> 1 to rewrite the rules block even if it is
#                    already present
# ============================================================

set -euo pipefail

SKIP_INSTALL="${SKIP_INSTALL:-0}"
FORCE="${FORCE:-0}"
SQUID_CONF="/etc/squid/squid.conf"
SQUID_PASSWORDS="/etc/squid/passwords"

# Same guard as setup-user.sh: this must run as the new user,
# not root, so sudo prompts work with the user's own account.
if [ "$(id -u)" -eq 0 ]; then
  echo "Do NOT run this as root. Log in as the new user first." >&2
  exit 1
fi
command -v sudo >/dev/null 2>&1 || {
  echo "Required command not found: sudo" >&2
  exit 1
}

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# 1. Install squid (skippable so config-only changes can be
#    tested without touching the package)
# ------------------------------------------------------------
if [ "$SKIP_INSTALL" != "1" ]; then
  if ! command -v squid >/dev/null 2>&1; then
    echo "### Installing Squid proxy ###"
    sudo apt-get update
    sudo apt-get install -y squid apache2-utils
  else
    echo "### squid already installed, skipping install ###"
  fi
  sudo systemctl enable --now squid
fi

# ------------------------------------------------------------
# 2. Gather the allowed IP and the proxy credentials
# ------------------------------------------------------------
SSH_CLIENT_IP="${SSH_CLIENT:-}"
SSH_CLIENT_IP="${SSH_CLIENT_IP%% *}"
if [ -z "${SQUID_IP:-}" ]; then
  read -rp "    IP allowed without login [${SSH_CLIENT_IP:-none}]: " SQUID_IP || true
fi
SQUID_IP="${SQUID_IP:-$SSH_CLIENT_IP}"

if [ -n "$SQUID_IP" ]; then
  if ! python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$SQUID_IP" 2>/dev/null; then
    echo "    Invalid IP address: $SQUID_IP" >&2
    exit 1
  fi
fi

if [ -z "${SQUID_USER:-}" ]; then
  read -rp "    Proxy username: " SQUID_USER || true
fi
if [ -z "$SQUID_USER" ]; then
  echo "    A proxy username is required." >&2
  exit 1
fi
if [ -z "${SQUID_PASS:-}" ]; then
  read -rsp "    Proxy password: " SQUID_PASS || true
  echo
  read -rsp "    Confirm proxy password: " SQUID_PASS_CONFIRM || true
  echo
  if [ -z "$SQUID_PASS" ] || [[ "$SQUID_PASS" != "$SQUID_PASS_CONFIRM" ]]; then
    echo "    Proxy password empty or does not match." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------
# 3. Write the htpasswd-format password file. The password is
#    fed on stdin (twice, as htpasswd asks for it twice) so it
#    never shows up on the command line.
# ------------------------------------------------------------
if [ -f "$SQUID_PASSWORDS" ]; then
  if sudo grep -q "^${SQUID_USER}:" "$SQUID_PASSWORDS"; then
    echo "    Password file exists and user $SQUID_USER is present; keeping it."
  else
    echo "    Password file exists but has no $SQUID_USER; adding the user."
    printf '%s\n%s\n' "$SQUID_PASS" "$SQUID_PASS" \
      | sudo htpasswd "$SQUID_PASSWORDS" "$SQUID_USER"
    sudo chown root:proxy "$SQUID_PASSWORDS"
    sudo chmod 640 "$SQUID_PASSWORDS"
  fi
else
  printf '%s\n%s\n' "$SQUID_PASS" "$SQUID_PASS" \
    | sudo htpasswd -c "$SQUID_PASSWORDS" "$SQUID_USER"
  sudo chown root:proxy "$SQUID_PASSWORDS"
  sudo chmod 640 "$SQUID_PASSWORDS"
  echo "    Wrote $SQUID_PASSWORDS for user $SQUID_USER."
fi

# ------------------------------------------------------------
# 4. Build the auth/allow rules block. The IP rule is only
#    emitted when an IP was actually given.
# ------------------------------------------------------------
IP_RULES=""
if [ -n "$SQUID_IP" ]; then
  IP_RULES="acl allowed_ip src ${SQUID_IP}
http_access allow allowed_ip"
fi
SQUID_AUTH_RULES=$(cat <<EOF
# --- Added by setup-squid.sh ---
auth_param basic program /usr/lib/squid/basic_ncsa_auth $SQUID_PASSWORDS
auth_param basic children 5
auth_param basic credentialsttl 2 hours
auth_param basic realm Squid Proxy
${IP_RULES}
acl auth_users proxy_auth REQUIRED
http_access allow auth_users
EOF
)

# ------------------------------------------------------------
# 5. Insert the rules before the default `http_access deny all`
#    anchor. The anchor search must not kill the script under
#    `set -e` when grep finds nothing -- hence the `|| true` --
#    so the missing-anchor guard below actually runs.
# ------------------------------------------------------------
# The stock squid.conf is the full documented file and contains
# commented `##auth_param basic program ...` and possibly
# `##acl auth_users ...` example lines, so grep'ing for either
# would falsely report "already done" and skip writing. Anchor
# the marker at column 0 so only the active generated line
# matches.
if ! grep -q "^acl auth_users proxy_auth REQUIRED" "$SQUID_CONF" || [ "$FORCE" = "1" ]; then
  echo "### Updating $SQUID_CONF ###"
  DENY_LINE=$(grep -n '^http_access deny all$' "$SQUID_CONF" | head -n1 | cut -d: -f1 || true)
  if [ -z "$DENY_LINE" ]; then
    echo "    Could not locate Squid's 'http_access deny all' anchor; refusing to edit." >&2
    echo "    Existing http_access lines in $SQUID_CONF:" >&2
    grep -n '^http_access' "$SQUID_CONF" >&2 || echo "    (none)" >&2
    exit 1
  fi
  echo "    Anchor 'http_access deny all' found at line $DENY_LINE."

  sudo cp "$SQUID_CONF" "$SQUID_CONF.bak.$(date +%s)"
  SQUID_BLOCK_FILE="$(mktemp)"
  SQUID_NEW_CONF="$(mktemp)"
  printf '%s\n' "$SQUID_AUTH_RULES" > "$SQUID_BLOCK_FILE"
  {
    sed -n "1,$((DENY_LINE - 1))p" "$SQUID_CONF"
    cat "$SQUID_BLOCK_FILE"
    sed -n "${DENY_LINE},\$p" "$SQUID_CONF"
  } > "$SQUID_NEW_CONF"
  sudo install -m 0644 -o root -g root "$SQUID_NEW_CONF" "$SQUID_CONF"
  rm -f "$SQUID_BLOCK_FILE" "$SQUID_NEW_CONF"
  echo "    Updated $SQUID_CONF (backup kept)."

  echo "    Resulting squid access rules:"
  grep -nE '^(http_access|auth_param|acl (auth_users|allowed_ip))' "$SQUID_CONF"
else
  echo "    Config already contains auth rules, skipping."
fi

# ------------------------------------------------------------
# 6. Parse-validate the config before restarting the daemon.
#    `squid -k parse` prints the real reason on failure, so it
#    is not suppressed.
# ------------------------------------------------------------
if ! sudo squid -k parse; then
  echo "    Invalid Squid configuration; NOT restarting squid. Check $SQUID_CONF." >&2
  exit 1
fi
sudo systemctl restart squid

# ------------------------------------------------------------
# 7. If UFW is active, open 3128.
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "    UFW is active; opening port 3128."
  sudo ufw allow 3128/tcp
fi

echo "    Squid configured and running."
echo "    Config: $SQUID_CONF"
echo "    Port: 3128"
echo "    Allowed IP: ${SQUID_IP:-none (password auth only)}"
echo "    Proxy user: $SQUID_USER"
