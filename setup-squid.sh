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
#   SKIP_INSTALL=1 bash setup-squid.sh
#
#   SKIP_INSTALL -> 1 to skip apt install / systemctl enable
#
# There are no credential prompts and no env vars for one: the
# proxy is gated on the tailnet (Tailscale's 100.64.0.0/10), not
# on a username and password. Run setup-user.sh (or the Tailscale
# installer, then `sudo tailscale up`) if the node is not on the
# tailnet yet -- otherwise the rules below match nobody.
# ============================================================

set -euo pipefail

SKIP_INSTALL="${SKIP_INSTALL:-0}"
SQUID_CONF="/etc/squid/squid.conf"
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
    sudo apt-get install -y squid
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
# 2. Build the rules: tailnet sources in, everything else out.
#    A logged-out Tailscale node means no source in 100.64.0.0/10,
#    so the proxy denies everyone -- the failure direction is
#    closed, not open.
# ------------------------------------------------------------
SQUID_RULES=$(cat <<EOF
# Written by vps-bootstrap (setup-user.sh / setup-squid.sh), which
# rewrites this file on every run. It lives here instead of in
# squid.conf so the packaged conffile stays unmodified.
#
# Only your tailnet may use this proxy. 100.64.0.0/10 is the range
# Tailscale assigns, so this names every device on your tailnet and
# nothing on the public internet. It says nothing about WHICH
# tailnet, which is fine: ufw only admits these peers over
# tailscale0, so the packets are already authenticated WireGuard.
acl tailnet src 100.64.0.0/10
http_access allow tailnet
EOF
)

# ------------------------------------------------------------
# 3. Write the rules file. squid.conf is only read, never edited,
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
printf '%s\n' "$SQUID_RULES" > "$SQUID_RULES_TMP"
sudo install -m 0644 -o root -g root "$SQUID_RULES_TMP" "$SQUID_RULES_FILE"
rm -f "$SQUID_RULES_TMP"

cat "$SQUID_RULES_FILE"

# ------------------------------------------------------------
# 4. Parse-validate the config before restarting the daemon.
#    `squid -k parse` prints the real reason on failure, so it
#    is not suppressed.
# ------------------------------------------------------------
if ! sudo squid -k parse; then
  echo "    Invalid Squid configuration; NOT restarting squid. Check $SQUID_RULES_FILE." >&2
  exit 1
fi
sudo systemctl restart squid

# ------------------------------------------------------------
# 5. Report how 3128 is reachable. It needs no rule of its own:
#    setup-user.sh's firewall section allows the whole tailscale0
#    interface. Without that firewall the port is open to the
#    internet and the tailnet ACL is the only thing answering.
# ------------------------------------------------------------
if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "    UFW is active; 3128 is reachable only over tailscale0."
else
  echo "    NOTE: UFW is not active, so port 3128 is reachable from the internet."
  echo "          Only the tailnet ACL protects it (everything else gets 403)."
  echo "          Re-run with the firewall, or restrict 3128 yourself."
fi

echo "    Squid configured and running."
echo "    Config: $SQUID_RULES_FILE (included from $SQUID_CONF)"
echo "    Port: 3128, tailnet only"
if command -v tailscale >/dev/null 2>&1; then
  TAILSCALE_IP="$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)"
  if [ -n "$TAILSCALE_IP" ]; then
    echo "    Tailnet address: $TAILSCALE_IP (proxy: http://$TAILSCALE_IP:3128)"
  else
    echo "    Tailscale is installed but not logged in; run 'sudo tailscale up'."
  fi
fi
