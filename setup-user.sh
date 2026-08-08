#!/usr/bin/env bash
# ============================================================
# setup-user.sh  (step 3 of 3)
# Run as the new sudo user created by setup-root.sh (whose SSH
# key was set up by setup-ssh.sh):
#   bash setup-user.sh
#
# Installs packages (via sudo), shell env, nvim, Node via fnm,
# dotfiles, and optionally the firewall and a Squid proxy.
# sshd hardening is the last mandatory step so your host
# machine's SSH key is confirmed working before password auth
# is disabled.
# ============================================================

# Fail fast on any error, unset variable, or pipe failure.
set -euo pipefail

# The dotfiles repo is cloned with yadm near the end. It is an
# SSH URL; the new user's key was generated and its public half
# added to GitHub by setup-ssh.sh.
DOTFILES_REPO="git@github.com:zzacong/dotfiles.git"

# Default passphrase for the GitHub SSH key -- must match what
# setup-ssh.sh used, or was chosen when the key was generated.
DEFAULT_SSH_PASS="Ddld1019."

# This whole script must run as the new user, not root,
# otherwise everything gets installed into /root instead.
if [ "$(id -u)" -eq 0 ]; then
  echo "Do NOT run this as root. Log in as the new user first." >&2
  exit 1
fi

# Keep apt fully non-interactive so conffile and needrestart
# prompts can't hang an unattended run.
export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------
# 1. System packages (via sudo)
# ------------------------------------------------------------
# The new user has sudo rights, so the apt work now lives here
# instead of setup-root.sh. You'll be asked for your password
# on the first sudo command.
#   fd-find / bat  -> Ubuntu still renames these to fdfind /
#                     batcat even on 24.04 (handled in step 3)
#   lf             -> available since Ubuntu 23.04
#   lsof           -> used by the `runp` alias in ~/.zshrc
#   unzip          -> required by the fnm installer (step 4)
echo "### Updating and upgrading apt packages ###"
sudo apt-get update
sudo apt-get upgrade -y

echo "### Installing zsh, neovim, fd-find, bat, ripgrep, lf, yadm ###"
sudo apt-get install -y --no-install-recommends \
  zsh neovim fd-find bat ripgrep lf yadm git curl lsof unzip

# ------------------------------------------------------------
# 2. Shell environment: oh-my-zsh + plugins + theme
# ------------------------------------------------------------
# --unattended skips the interactive prompts and does NOT
# change the default shell (we do that explicitly in step 5).
echo "### Installing oh-my-zsh ###"
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# The plugins are cloned into oh-my-zsh's custom directory.
# --depth=1 keeps the clone shallow and fast. Each clone is
# skipped if it already exists so the script is re-runnable.
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

echo "### Installing zsh-autosuggestions plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions" ]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"
else
  echo "    Already cloned, skipping."
fi

echo "### Installing zsh-syntax-highlighting plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting" ]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-syntax-highlighting.git "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting"
else
  echo "    Already cloned, skipping."
fi

echo "### Installing spaceship prompt ###"
if [ ! -d "$ZSH_CUSTOM_DIR/themes/spaceship-prompt" ]; then
  git clone --depth=1 https://github.com/spaceship-prompt/spaceship-prompt.git "$ZSH_CUSTOM_DIR/themes/spaceship-prompt"
else
  echo "    Already cloned, skipping."
fi

# ------------------------------------------------------------
# 3. Neovim: vim-plug + renamed binary symlinks + undodir
# ------------------------------------------------------------
# vim-plug: the standard plugin manager for (n)vim.
echo "### Installing vim-plug for neovim ###"
curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim" --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# init.vim sets `undodir` here; make sure it exists or nvim
# errors on every undo write.
mkdir -p "$HOME/.local/share/nvim/undodir"

# Ubuntu still ships fd-find as `fdfind` and bat as `batcat`
# even on 24.04 (both renamed to avoid a name clash). Symlink
# them to the expected names, but only if the real binary isn't
# already on PATH -- so this section is a no-op on any future
# release that does ship proper `fd`/`bat`.
echo "### Ensuring fd/bat commands exist in ~/.local/bin ###"
mkdir -p "$HOME/.local/bin"
command -v fd  >/dev/null 2>&1 || ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
command -v bat >/dev/null 2>&1 || ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"

# ------------------------------------------------------------
# 4. Node via fnm (node version manager)
# ------------------------------------------------------------
# ~/.zshrc lists the `fnm` plugin and the `corepackup`/pnpm
# helpers, so node is needed. fnm installs to
# ~/.local/share/fnm; symlink it into ~/.local/bin (which
# ~/.zshrc already puts on PATH) and grab the latest LTS node.
# --skip-shell stops the installer from appending its own
# `eval "$(fnm env)"` block to ~/.bashrc, which we don't manage.
echo "### Installing fnm and latest LTS Node ###"
curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
mkdir -p "$HOME/.local/bin"
ln -sf "$HOME/.local/share/fnm/fnm" "$HOME/.local/bin/fnm"
"$HOME/.local/bin/fnm" install --lts

# ------------------------------------------------------------
# 5. Make zsh the default shell
# ------------------------------------------------------------
# Prompts for your password. command -v is safer/portable
# than `which`.
echo "### Changing default shell to zsh ###"
chsh -s "$(command -v zsh)"

# ------------------------------------------------------------
# 6. Dotfiles
# ------------------------------------------------------------
# setup-ssh.sh already generated ~/.ssh/id_ed25519 and its
# public half is on GitHub, so the clone below works. Guard in
# case this script was run without setup-ssh.sh.
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  echo "### No SSH key found; generating one ###"
  mkdir -p "$HOME/.ssh"
  # Owner-only rwx on the dir so ssh doesn't warn "unprotected
  # private key file" and no other user can list its contents.
  chmod 700 "$HOME/.ssh"
  read -rsp "    Passphrase for the new SSH key [$DEFAULT_SSH_PASS]: " SSH_KEY_PASS || true
  SSH_KEY_PASS="${SSH_KEY_PASS:-$DEFAULT_SSH_PASS}"
  echo
  ssh-keygen -t ed25519 -N "$SSH_KEY_PASS" -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519"
  echo "    Add this public key to GitHub:"
  cat "$HOME/.ssh/id_ed25519.pub"
  read -rp "    Press Enter once it's added to GitHub: " _IGNORED || true
fi

# The key has a passphrase by default, so load it into an
# ssh-agent (spawned just for this script) before the yadm
# clone below, otherwise the first SSH connection to github.com
# would prompt for the passphrase and hang. The agent only lives
# as long as this script does.
echo "### Loading SSH key into ssh-agent ###"
eval "$(ssh-agent -s)"
if [ -z "${SSH_KEY_PASS:-}" ]; then
  read -rsp "    SSH key passphrase [$DEFAULT_SSH_PASS]: " SSH_KEY_PASS || true
  SSH_KEY_PASS="${SSH_KEY_PASS:-$DEFAULT_SSH_PASS}"
  echo
fi
SSH_ASKPASS_HELPER="$(mktemp)"
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$SSH_KEY_PASS" > "$SSH_ASKPASS_HELPER"
# Make the helper executable so ssh-add can run it as a program
# (SSH_ASKPASS expects a path to an executable).
chmod +x "$SSH_ASKPASS_HELPER"
SSH_ASKPASS="$SSH_ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force ssh-add "$HOME/.ssh/id_ed25519"
rm -f "$SSH_ASKPASS_HELPER"

# oh-my-zsh wrote a default .zshrc; remove it so yadm's version
# from the dotfiles repo takes over without conflict. The other
# /etc/skel files (.bashrc, .profile, .bash_logout) can also
# collide with files tracked in the dotfiles repo, so clear them
# too -- zsh is the default shell, so bash's files go unused.
echo "### Removing default shell files that could collide with yadm ###"
rm -f "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile" "$HOME/.bash_logout"

# yadm clones over SSH; pre-seed known_hosts so the first
# connection to github.com doesn't prompt for host confirmation
# and hang in a non-interactive context.
mkdir -p "$HOME/.ssh"
# Same owner-only rwx as above: keep ssh happy and the dir
# private for the keys it will hold.
chmod 700 "$HOME/.ssh"
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null

echo "### Cloning dotfiles with yadm ###"
if [ -d "$HOME/.config/yadm/repo.git" ]; then
  echo "    yadm already bootstrapped; pulling latest instead."
  yadm pull
elif yadm clone -b main "$DOTFILES_REPO"; then
  echo "    Dotfiles cloned."
else
  echo "    yadm clone failed (tracked file colliding with a skel default?); fix and re-run." >&2
  exit 1
fi

# Install the plugins listed in ~/.config/nvim/init.vim. This
# needs init.vim to exist (from the yadm clone just above).
echo "### Installing neovim plugins via vim-plug ###"
if [ -f "$HOME/.config/nvim/init.vim" ]; then
  nvim +'PlugInstall --sync' +qall
else
  echo "    No ~/.config/nvim/init.vim found; skipping PlugInstall."
fi

# ------------------------------------------------------------
# 7. sshd hardening (LAST mandatory step, so keys work first)
# ------------------------------------------------------------
# No root login, key-only authentication. Uses a drop-in file
# (included by Ubuntu's default sshd_config). By now your host
# machine's key is already in authorized_keys (setup-ssh.sh)
# and the yadm clone just proved the GitHub key works, so
# disabling password auth can't lock you out.
echo "### Hardening sshd (no root login, key-only auth) ###"
sudo tee /etc/ssh/sshd_config.d/50-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
EOF

# sshd is socket-activated on Ubuntu 22.10+: ssh.socket owns
# port 22 and ssh.service is only spawned on demand. Reload the
# daemon first so the new drop-in config is picked up, then
# restart the socket (and the service if it happens to be up).
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket
sudo systemctl restart ssh.service 2>/dev/null || true

# ------------------------------------------------------------
# 8. (Optional) UFW firewall
# ------------------------------------------------------------
# Firewall setup is opt-in: deny all incoming by default, allow
# outgoing, then explicitly open the ports you need. ssh is
# always allowed first so you can't lock yourself out.
read -rp "Set up the UFW firewall? (y/N): " SETUP_UFW || true
if [[ "${SETUP_UFW,,}" == "y" ]]; then
  echo "### Setting up UFW firewall ###"
  sudo apt-get install -y ufw
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh

  read -rp "    Also allow HTTP/HTTPS (ports 80, 443)? (y/N): " ALLOW_WEB || true
  if [[ "${ALLOW_WEB,,}" == "y" ]]; then
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
  fi

  # --force skips ufw's "this may disrupt existing connections"
  # prompt. SSH is already allowed above, so it's safe.
  sudo ufw --force enable
  sudo ufw status verbose
fi

# ------------------------------------------------------------
# 9. (Optional) Squid proxy
# ------------------------------------------------------------
# Squid is a caching HTTP/HTTPS proxy. Install is opt-in. The
# config is tightened to allow two ways in: from a single IP you
# name, and/or with a username/password (an htpasswd-style file
# checked by squid's basic_ncsa_auth helper). Rules are inserted
# before the default `http_access deny all` so they take effect.
read -rp "Also install the Squid proxy server? (y/N): " INSTALL_SQUID || true
if [[ "${INSTALL_SQUID,,}" == "y" ]]; then
  echo "### Installing Squid proxy ###"
  sudo apt-get install -y squid apache2-utils
  sudo systemctl enable --now squid

  # The IP that may use the proxy without logging in. Defaults to
  # the address you're SSH-ing in from (auto-detected).
  SSH_CLIENT_IP="${SSH_CLIENT%% *}"
  read -rp "    IP allowed without login [${SSH_CLIENT_IP:-none}]: " SQUID_IP || true
  SQUID_IP="${SQUID_IP:-$SSH_CLIENT_IP}"

  read -rp "    Proxy username [johnfire]: " SQUID_USER || true
  SQUID_USER="${SQUID_USER:-johnfire}"
  read -rsp "    Proxy password [johnfire]: " SQUID_PASS || true
  SQUID_PASS="${SQUID_PASS:-johnfire}"
  echo

  # htpasswd-format password file consumed by basic_ncsa_auth.
  # The password is fed on stdin (twice, as htpasswd asks for it
  # twice) so it never shows up on the command line.
  if [ -f /etc/squid/passwords ]; then
    echo "    Password file already exists, keeping it."
  else
    printf '%s\n%s\n' "$SQUID_PASS" "$SQUID_PASS" \
      | sudo htpasswd -c /etc/squid/passwords "$SQUID_USER"
    # Give the squid worker user (proxy) read access to the
    # password file while keeping it out of the hands of other
    # system users (root owns it, proxy group can read, 640).
    sudo chown root:proxy /etc/squid/passwords
    sudo chmod 640 /etc/squid/passwords
    echo "    Wrote /etc/squid/passwords for user $SQUID_USER."
  fi

  # Build the auth/allow block. The IP rule is only emitted when
  # an IP was actually given (otherwise it's password-only).
  IP_RULES=""
  if [ -n "$SQUID_IP" ]; then
    IP_RULES="acl allowed_ip src ${SQUID_IP}
http_access allow allowed_ip"
  fi
  SQUID_AUTH_RULES=$(cat <<EOF
# --- Added by setup-user.sh ---
auth_param basic program /usr/lib/squid/basic_ncsa_auth /etc/squid/passwords
auth_param basic children 5
auth_param basic credentialsttl 2 hours
auth_param basic realm Squid Proxy
${IP_RULES}
acl auth_users proxy_auth REQUIRED
http_access allow auth_users
EOF
)

  if ! grep -q "auth_param basic program" /etc/squid/squid.conf; then
    sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.bak

    # Insert the rules immediately before the default
    # `http_access deny all` line (the last matching rule), so
    # they actually take effect. Compose the new file from parts
    # rather than sed -i so no in-place weirdness with newlines.
    BLOCK_FILE="$(mktemp)"
    NEW_CONF="$(mktemp)"
    printf '%s\n' "$SQUID_AUTH_RULES" > "$BLOCK_FILE"
    DENY_LINE=$(grep -n '^http_access deny all$' /etc/squid/squid.conf | head -n1 | cut -d: -f1)
    if [ -n "$DENY_LINE" ]; then
      {
        sed -n "1,$((DENY_LINE - 1))p" /etc/squid/squid.conf
        cat "$BLOCK_FILE"
        sed -n "${DENY_LINE},\$p" /etc/squid/squid.conf
      } > "$NEW_CONF"
      sudo install -m 0644 -o root -g root "$NEW_CONF" /etc/squid/squid.conf
    else
      # No deny-all line to anchor on (unexpected); append and
      # make sure we still end with a blanket deny.
      cat "$BLOCK_FILE" >> /etc/squid/squid.conf
      echo "http_access deny all" >> /etc/squid/squid.conf
    fi
    rm -f "$BLOCK_FILE" "$NEW_CONF"
    echo "    Updated /etc/squid/squid.conf (backup at squid.conf.bak)."
  else
    echo "    Config already contains auth rules, skipping."
  fi

  sudo systemctl restart squid

  # If UFW was enabled earlier, port 3128 must be opened for the
  # proxy to be reachable from anywhere but localhost.
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "    UFW is active; opening port 3128."
    sudo ufw allow 3128/tcp
  fi

  echo "    Squid configured and running."
  echo "    Config: /etc/squid/squid.conf"
  echo "    Port: 3128"
  echo "    Allowed IP: ${SQUID_IP:-none (password auth only)}"
  echo "    Proxy user: $SQUID_USER"
fi

echo ""
echo "### Step 3 done. Log out and back in to start using zsh. ###"
if [ -f /var/run/reboot-required ]; then
  echo "A reboot is required (kernel was updated): sudo reboot"
fi
