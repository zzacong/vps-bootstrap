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
#     SKIP_INSTALL=1 bash setup-squid.sh
#
#   SQUID_IP      -> IP allowed without login (default: your SSH
#                    client IP)
#   SQUID_USER    -> proxy username (prompted if unset)
#   SQUID_PASS    -> proxy password (prompted if unset)
#   SKIP_INSTALL  -> 1 to skip apt install / systemctl enable
# ============================================================

set -euo pipefail

SKIP_INSTALL="${SKIP_INSTALL:-0}"
SQUID_CONF="/etc/squid/squid.conf"
SQUID_PASSWORDS="/etc/squid/passwords"
# Rules live in their own file rather than in squid.conf: stock
# squid.conf includes this directory before its `http_access deny
# all`, so the rules still apply, and squid's conffile stays
# unmodified, which is what stops `apt upgrade` prompting about it.
SQUID_CONF_DIR="/etc/squid/conf.d"
SQUID_RULES_FILE="$SQUID_CONF_DIR/20-vps-bootstrap.conf"

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

if [ ! -f "$SQUID_CONF" ]; then
  echo "$SQUID_CONF is missing; install squid first (or drop SKIP_INSTALL=1)." >&2
  exit 1
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
# Written by vps-bootstrap (setup-user.sh / setup-squid.sh), which
# rewrites this file on every run. It lives here instead of in
# squid.conf so the packaged conffile stays unmodified.
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
# 5. Write the rules file. squid.conf is only read, never edited,
#    so it stays a pristine conffile.
# ------------------------------------------------------------
# The include line is what makes the rules file live. Stock
# squid.conf ships it uncommented; if it is gone the rules would be
# silently ignored, which is worse than not writing them, so refuse
# instead of guessing.
if ! grep -qE "^include[[:space:]]+${SQUID_CONF_DIR}/" "$SQUID_CONF"; then
  echo "    $SQUID_CONF does not include $SQUID_CONF_DIR/; refusing to write rules squid would ignore." >&2
  echo "    Add 'include $SQUID_CONF_DIR/*.conf' above 'http_access deny all' and re-run." >&2
  exit 1
fi

# This file belongs to the scripts, so a re-run replaces it. The
# previous copy is kept beside squid.conf's own backups, outside
# conf.d so it can never be picked up by the include glob.
echo "### Writing $SQUID_RULES_FILE ###"
sudo install -d -m 0755 -o root -g root "$SQUID_CONF_DIR"
if [ -f "$SQUID_RULES_FILE" ]; then
  sudo cp "$SQUID_RULES_FILE" "/etc/squid/20-vps-bootstrap.conf.bak.$(date +%s)"
fi
SQUID_RULES_TMP="$(mktemp)"
printf '%s\n' "$SQUID_AUTH_RULES" > "$SQUID_RULES_TMP"
sudo install -m 0644 -o root -g root "$SQUID_RULES_TMP" "$SQUID_RULES_FILE"
rm -f "$SQUID_RULES_TMP"

cat "$SQUID_RULES_FILE"

# ------------------------------------------------------------
# 6. Parse-validate the config before restarting the daemon.
#    `squid -k parse` prints the real reason on failure, so it
#    is not suppressed.
# ------------------------------------------------------------
if ! sudo squid -k parse; then
  echo "    Invalid Squid configuration; NOT restarting squid. Check $SQUID_RULES_FILE." >&2
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
echo "    Config: $SQUID_RULES_FILE (included from $SQUID_CONF)"
echo "    Port: 3128"
echo "    Allowed IP: ${SQUID_IP:-none (password auth only)}"
echo "    Proxy user: $SQUID_USER"
