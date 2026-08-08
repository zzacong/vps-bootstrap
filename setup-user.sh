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
# Cleanup + helper plumbing
# ------------------------------------------------------------
# Bail out up front if a required tool is missing, instead of
# discovering it halfway through.
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}
require_command sudo
require_command apt-get
require_command curl
require_command ssh
require_command ssh-keygen

# One EXIT trap drives everything: removes the temp files that
# hold the SSH passphrase, kills the sudo keep-alive loop, and
# stops the script-local ssh-agent so the decrypted private key
# doesn't linger in memory after the script ends.
CLEANUP_FILES=()
SUDO_KEEPALIVE_PID=""
cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]:-}"; do
    rm -f "$f"
  done
  if [ -n "$SUDO_KEEPALIVE_PID" ]; then
    kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
  fi
  if [ -n "${SSH_AGENT_PID:-}" ]; then
    kill "$SSH_AGENT_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Feed a passphrase to ssh-keygen/ssh-add via SSH_ASKPASS so it
# never appears on a command line or gets interpolated into script
# source: the secret lives in a 0600 temp file that a tiny helper
# cats on demand. OpenSSH >= 8.4 honours SSH_ASKPASS_REQUIRE=force.
setup_askpass() {
  local helper passfile
  helper="$(mktemp)"
  passfile="$(mktemp)"
  chmod 600 "$passfile"
  printf '%s' "$1" > "$passfile"
  printf '#!/bin/sh\ncat "%s"\n' "$passfile" > "$helper"
  chmod 700 "$helper"
  CLEANUP_FILES+=("$helper" "$passfile")
  ASKPASS_HELPER="$helper"
}

# The long run below calls sudo many times; keep the credential
# timestamp fresh so a later sudo can't suddenly prompt (or fail
# under `set -e`) mid-script. The trap above kills it on exit.
sudo -v
(
  while :; do
    sudo -n true || exit 0
    sleep 60
  done
) &
SUDO_KEEPALIVE_PID=$!

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
#   python3        -> used to validate the optional Squid IP
echo "### Updating apt packages ###"
sudo apt-get update

# A full upgrade is optional: it can pull in a kernel update and
# force a reboot, and it's slow. Ask instead of doing it blindly.
read -rp "Run a full 'sudo apt-get upgrade'? (y/N): " RUN_UPGRADE || true
if [[ "${RUN_UPGRADE,,}" =~ ^y(es)?$ ]]; then
  sudo apt-get upgrade -y
fi

echo "### Installing zsh, neovim, fd-find, bat, ripgrep, lf, yadm ###"
sudo apt-get install -y --no-install-recommends \
  zsh neovim fd-find bat ripgrep lf yadm git curl lsof unzip python3

# Verify the packages actually landed (minimal images and future
# releases can rename or drop them).
echo "### Verifying installed commands ###"
MISSING=""
for command in zsh nvim fdfind batcat rg lf yadm git curl lsof unzip python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "    Missing command: $command" >&2
    MISSING="$MISSING $command"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the apt install, then re-run." >&2
  exit 1
fi

# ------------------------------------------------------------
# 2. Shell environment: oh-my-zsh + plugins + theme
# ------------------------------------------------------------
# --unattended skips the interactive prompts and does NOT
# change the default shell (we do that explicitly in step 5).
echo "### Installing oh-my-zsh ###"
ZSH_DIR="${ZDOTDIR:-$HOME}/.oh-my-zsh"
if [ ! -d "$ZSH_DIR" ]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  echo "    Already installed, skipping."
fi

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

# OMZ resolves `ZSH_THEME="spaceship"` against
# themes/spaceship.zsh-theme; the spaceship repo ships one, so
# link it into the themes dir.
ln -sf "$ZSH_CUSTOM_DIR/themes/spaceship-prompt/spaceship.zsh-theme" \
  "$ZSH_CUSTOM_DIR/themes/spaceship.zsh-theme"

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
if ! command -v fd >/dev/null 2>&1; then
  if command -v fdfind >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  else
    echo "    fd/fdfind was not installed." >&2
    exit 1
  fi
fi
if ! command -v bat >/dev/null 2>&1; then
  if command -v batcat >/dev/null 2>&1; then
    ln -sf "$(command -v batcat)" "$HOME/.local/bin/bat"
  else
    echo "    bat/batcat was not installed." >&2
    exit 1
  fi
fi

# ------------------------------------------------------------
# 4. Node via fnm (node version manager)
# ------------------------------------------------------------
# ~/.zshrc lists the `fnm` plugin and pnpm, so node is needed.
# fnm installs to ~/.local/share/fnm; symlink it into
# ~/.local/bin (which ~/.zshrc already puts on PATH) and grab
# the latest LTS node. --skip-shell stops the installer from
# appending its own `eval "$(fnm env)"` block to ~/.bashrc,
# which we don't manage.
echo "### Installing fnm and latest LTS Node ###"
if [ ! -x "$HOME/.local/bin/fnm" ]; then
  curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
  mkdir -p "$HOME/.local/bin"
  ln -sf "$HOME/.local/share/fnm/fnm" "$HOME/.local/bin/fnm"
  if ! test -x "$HOME/.local/bin/fnm"; then
    echo "    fnm install failed; binary missing at ~/.local/share/fnm/fnm." >&2
    exit 1
  fi
else
  echo "    fnm already installed, skipping download."
fi
"$HOME/.local/bin/fnm" install --lts
"$HOME/.local/bin/fnm" default lts-latest

# Put fnm's node on PATH for this shell and confirm node actually
# works (setup-user.sh relies on node later).
eval "$("$HOME/.local/bin/fnm" env)"
node --version

# pnpm: the standalone installer (the preferred method on Linux)
# is used rather than corepack, which newer Node LTS no longer
# ships. It installs to $PNPM_HOME/bin (a cmd-shim that resolves
# its real binary relative to that dir, so it must NOT be
# symlinked elsewhere) and appends a PATH block to the shell rc
# it detects; we keep our own PATH story instead -- the dotfiles'
# .zshrc exports PNPM_HOME and puts $PNPM_HOME/bin on PATH -- so
# just export it into this script's shell for the checks below.
# Install is opt-in: pnpm's binary is ~30MB and a disk-tight VPS
# may not have room, so ask first (skipped entirely when already
# installed, so re-runs stay hands-free).
echo "### Installing pnpm ###"
export PNPM_HOME="$HOME/.local/share/pnpm"
export PATH="$PNPM_HOME/bin:$PATH"
if [ -x "$PNPM_HOME/bin/pnpm" ]; then
  echo "    pnpm already installed, skipping download."
  pnpm --version
else
  read -rp "    Install pnpm? (y/N): " INSTALL_PNPM || true
  if [[ "${INSTALL_PNPM,,}" =~ ^y(es)?$ ]]; then
    curl -fsSL https://get.pnpm.io/install.sh | sh -
    if [ ! -x "$PNPM_HOME/bin/pnpm" ]; then
      echo "    pnpm install failed; binary missing at $PNPM_HOME/bin/pnpm." >&2
      exit 1
    fi
    pnpm --version
  else
    echo "    Skipping pnpm install."
  fi
fi

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
  read -rsp "    Passphrase for the new SSH key (required): " SSH_KEY_PASS || true
  echo
  read -rsp "    Confirm passphrase: " SSH_KEY_PASS_CONFIRM || true
  echo
  if [ -z "$SSH_KEY_PASS" ]; then
    echo "    Passphrase cannot be empty." >&2
    exit 1
  fi
  if [[ "$SSH_KEY_PASS" != "$SSH_KEY_PASS_CONFIRM" ]]; then
    echo "    Passphrases do not match." >&2
    exit 1
  fi
  setup_askpass "$SSH_KEY_PASS"
  SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force \
    ssh-keygen -t ed25519 -C "$(whoami)@$(hostname)" -f "$HOME/.ssh/id_ed25519"
  echo "    Add this public key to GitHub:"
  cat "$HOME/.ssh/id_ed25519.pub"
  read -rp "    Press Enter once it's added to GitHub: " _IGNORED || true
fi

# The key has a passphrase, so load it into an ssh-agent
# (spawned just for this script, killed on exit by the trap
# above) before the yadm clone below, otherwise the first SSH
# connection to github.com would prompt for the passphrase and
# hang.
echo "### Loading SSH key into ssh-agent ###"
eval "$(ssh-agent -s)"
if [ -z "${SSH_KEY_PASS:-}" ]; then
  read -rsp "    SSH key passphrase (required): " SSH_KEY_PASS || true
  echo
  if [ -z "$SSH_KEY_PASS" ]; then
    echo "    Passphrase cannot be empty." >&2
    exit 1
  fi
fi
setup_askpass "$SSH_KEY_PASS"
SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force ssh-add "$HOME/.ssh/id_ed25519"

# yadm clones over SSH; pre-seed known_hosts so the first
# connection to github.com doesn't prompt for host confirmation
# and hang in a non-interactive context. Pin GitHub's published
# ed25519 host key (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
# instead of trusting unauthenticated `ssh-keyscan` output.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
GITHUB_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
if ! ssh-keygen -F github.com >/dev/null 2>&1; then
  echo "$GITHUB_HOST_KEY" >> "$HOME/.ssh/known_hosts"
fi
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

echo "### Cloning dotfiles with yadm ###"
# yadm 3.x keeps its bare repo under XDG data (~/.local/share/yadm),
# while older versions used ~/.config/yadm. Check the real location
# so a re-run doesn't try to clone over an existing repo.
YADM_REPO_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/yadm/repo.git"
if [ ! -d "$YADM_REPO_DIR" ]; then
  YADM_REPO_DIR="$HOME/.config/yadm/repo.git"
fi

if [ -d "$YADM_REPO_DIR" ]; then
  echo "    yadm already bootstrapped."
  # Verify the remote is the repo we expect, and refuse to pull
  # over uncommitted local changes (yadm pull would fail or merge
  # in unpredictable ways).
  if ! yadm remote -v 2>/dev/null | grep -q "git@github.com:zzacong/dotfiles.git"; then
    echo "    Warning: yadm remote is not $DOTFILES_REPO; check with 'yadm remote -v'." >&2
  fi
  if [ -n "$(yadm status --porcelain 2>/dev/null)" ]; then
    echo "    Local yadm changes exist; NOT pulling. Review with 'yadm status'." >&2
  else
    yadm pull
    echo "    Pulled latest."
  fi
else
  # Only a fresh bootstrap needs this: oh-my-zsh and the skel
  # defaults wrote shell files that would collide with (and block)
  # the clone. Move them aside so yadm's versions win without
  # destroying anything -- nothing is deleted, the originals stay
  # in $BACKUP_DIR. On a re-run this block is skipped because the
  # shell files are already yadm-managed (moving them would dirty
  # the repo and leave you without a .zshrc).
  echo "### Moving existing shell files out of the way (backed up) ###"
  BACKUP_DIR="$HOME/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for file in .zshrc .bashrc .bash_profile .profile .bash_logout; do
    if [ -e "$HOME/$file" ]; then
      mv "$HOME/$file" "$BACKUP_DIR/$file"
    fi
  done
  if [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    echo "    Backed up to $BACKUP_DIR"
  else
    rmdir "$BACKUP_DIR"
  fi

  if yadm clone -b main "$DOTFILES_REPO"; then
    echo "    Dotfiles cloned."
  else
    echo "    yadm clone failed (tracked file colliding with a skel default?); restore with:" >&2
    echo "      cp -a ${BACKUP_DIR:-?}/. \$HOME/" >&2
    exit 1
  fi
fi

# Install the plugins listed in ~/.config/nvim/init.vim. This
# needs init.vim to exist (from the yadm clone just above).
echo "### Installing neovim plugins via vim-plug ###"
if [ -f "$HOME/.config/nvim/init.vim" ]; then
  # Chicken-and-egg: init.vim is sourced at startup, before
  # vim-plug has installed anything, so a colorscheme that ships
  # in a plugin (onehalfdark comes from sonph/onehalf) errors out
  # with E185 on the very first run. Source init.vim from a
  # throwaway vimrc with errors silenced so the whole file is
  # registered and PlugInstall can finish; the next normal nvim
  # session then finds the theme. Any real config error still
  # surfaces when nvim is opened normally.
  PLUG_VIMRC="$(mktemp)"
  CLEANUP_FILES+=("$PLUG_VIMRC")
  printf 'silent! source %s\n' "$HOME/.config/nvim/init.vim" > "$PLUG_VIMRC"
  nvim --headless -u "$PLUG_VIMRC" +'PlugInstall --sync' +qa
else
  echo "    No ~/.config/nvim/init.vim found; skipping PlugInstall."
fi

# ------------------------------------------------------------
# 7. sshd hardening (LAST mandatory step, so keys work first)
# ------------------------------------------------------------
# No root login, key-only authentication. Uses a drop-in file
# (included by Ubuntu's default sshd_config). Before touching
# sshd we require proof that key login works: a verified
# authorized_keys, and the operator's own confirmation from a
# second terminal -- that's the only real proof password auth can
# be turned off without locking anyone out.
echo "### Hardening sshd (no root login, key-only auth) ###"

# Gate on a verified key: if no key is installed, disabling
# password auth would lock you out of a cloud VPS that has no
# other way in.
if [ ! -s "$HOME/.ssh/authorized_keys" ]; then
  echo "    No keys in ~/.ssh/authorized_keys -- refusing to disable password auth." >&2
  echo "    Run setup-ssh.sh (as root) to install your host machine's key, then re-run this script." >&2
  exit 1
fi

HARDENING_FILE=/etc/ssh/sshd_config.d/50-hardening.conf
if grep -q "PasswordAuthentication no" "$HARDENING_FILE" 2>/dev/null; then
  echo "    Already hardened, skipping."
else
  read -rp "    Have you confirmed key login works in a SECOND terminal? (y/N): " CONFIRM_KEY_LOGIN || true
  if [[ "${CONFIRM_KEY_LOGIN,,}" =~ ^y(es)?$ ]]; then
    # Back up any previous hardening drop-in before replacing it.
    if [ -f "$HARDENING_FILE" ]; then
      sudo cp -a "$HARDENING_FILE" "$HARDENING_FILE.bak.$(date +%s)" 2>/dev/null || true
    fi

    # Restrict sshd to this user so no other local account with
    # an authorized key (now or in future) can authenticate.
    sudo tee "$HARDENING_FILE" >/dev/null <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers $USER
MaxAuthTries 3
LoginGraceTime 20
EOF

    # Validate the syntax BEFORE touching the running daemon. A
    # bad drop-in here is the fastest way to lose access to the box.
    if ! sudo sshd -t; then
      echo "    sshd configuration is INVALID; NOT reloading ssh. Fix $HARDENING_FILE." >&2
      exit 1
    fi

    # Show the effective values (a drop-in only wins if nothing
    # earlier set the same directive first).
    echo "    Effective settings:"
    sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) ' | sed 's/^/      /'

    # Ubuntu 22.10+ runs sshd under socket activation (ssh.socket):
    # socket units don't support `reload`, so restart the socket to
    # regenerate the listener (systemd re-reads sshd_config for it),
    # and restart the daemon too so a running sshd picks up the new
    # auth settings -- existing sessions are reparented, not killed.
    # Detect the layout rather than assume. On classic (non-socket)
    # installs a plain reload is enough and avoids dropping the
    # listener.
    if systemctl list-unit-files ssh.socket >/dev/null 2>&1 &&
      systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
      sudo systemctl daemon-reload
      sudo systemctl restart ssh.socket
      sudo systemctl restart ssh.service 2>/dev/null || true
    else
      sudo systemctl reload ssh
    fi
    echo "    sshd reloaded with hardened config."
  else
    echo "    Skipping sshd hardening. Re-run once key login is confirmed." >&2
    echo "    Test it first: ssh -o PasswordAuthentication=no $USER@<host>" >&2
  fi
fi

# ------------------------------------------------------------
# 8. (Optional) UFW firewall
# ------------------------------------------------------------
# Firewall setup is opt-in: deny all incoming by default, allow
# outgoing, then explicitly open the ports you need. ssh is
# always allowed first so you can't lock yourself out. SSH is
# left open to anywhere -- the hardening step disables password
# auth and restricts sshd to this user, so the firewall isn't
# the security boundary for port 22 (and an IP-scoped rule could
# lock you out when your source IP changes).
read -rp "Set up the UFW firewall? (y/N): " SETUP_UFW || true
if [[ "${SETUP_UFW,,}" =~ ^y(es)?$ ]]; then
  echo "### Setting up UFW firewall ###"
  sudo apt-get install -y ufw
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh

  read -rp "    Also allow HTTP/HTTPS (ports 80, 443)? (y/N): " ALLOW_WEB || true
  if [[ "${ALLOW_WEB,,}" =~ ^y(es)?$ ]]; then
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
if [[ "${INSTALL_SQUID,,}" =~ ^y(es)?$ ]]; then
  echo "### Installing Squid proxy ###"
  sudo apt-get install -y squid apache2-utils
  sudo systemctl enable --now squid

  # The IP that may use the proxy without logging in. Defaults to
  # the address you're SSH-ing in from (auto-detected). SSH_CLIENT
  # is only set inside an SSH session, so guard against it being
  # unset (it would fail under `set -u`).
  SSH_CLIENT_IP="${SSH_CLIENT:-}"
  SSH_CLIENT_IP="${SSH_CLIENT_IP%% *}"
  read -rp "    IP allowed without login [${SSH_CLIENT_IP:-none}]: " SQUID_IP || true
  SQUID_IP="${SQUID_IP:-$SSH_CLIENT_IP}"

  # Validate the IP with Python's ipaddress parser before it lands
  # in squid.conf. A single host is expected (no CIDR here).
  if [ -n "$SQUID_IP" ]; then
    if ! python3 -c 'import ipaddress, sys; ipaddress.ip_address(sys.argv[1])' "$SQUID_IP" 2>/dev/null; then
      echo "    Invalid IP address: $SQUID_IP" >&2
      exit 1
    fi
  fi

  # No hardcoded credentials: require a username and a non-empty
  # password, entered twice to catch typos.
  read -rp "    Proxy username: " SQUID_USER || true
  if [ -z "$SQUID_USER" ]; then
    echo "    A proxy username is required." >&2
    exit 1
  fi
  read -rsp "    Proxy password: " SQUID_PASS || true
  echo
  read -rsp "    Confirm proxy password: " SQUID_PASS_CONFIRM || true
  echo
  if [ -z "$SQUID_PASS" ] || [[ "$SQUID_PASS" != "$SQUID_PASS_CONFIRM" ]]; then
    echo "    Proxy password empty or does not match." >&2
    exit 1
  fi

  # htpasswd-format password file consumed by basic_ncsa_auth.
  # The password is fed on stdin (twice, as htpasswd asks for it
  # twice) so it never shows up on the command line.
  if [ -f /etc/squid/passwords ]; then
    if sudo grep -q "^${SQUID_USER}:" /etc/squid/passwords; then
      echo "    Password file exists and user $SQUID_USER is present; keeping it."
    else
      echo "    Password file exists but has no $SQUID_USER; adding the user."
      printf '%s\n%s\n' "$SQUID_PASS" "$SQUID_PASS" \
        | sudo htpasswd /etc/squid/passwords "$SQUID_USER"
      sudo chown root:proxy /etc/squid/passwords
      sudo chmod 640 /etc/squid/passwords
    fi
  else
    printf '%s\n%s\n' "$SQUID_PASS" "$SQUID_PASS" \
      | sudo htpasswd -c /etc/squid/passwords "$SQUID_USER"
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

  # The stock squid.conf is the full documented file and contains
  # commented `##auth_param basic program ...` and possibly
  # `##acl auth_users ...` example lines, so grep'ing for either
  # would falsely report "already done" and skip writing. Anchor
  # the marker at column 0 so only the active generated line
  # matches.
  if ! grep -q "^acl auth_users proxy_auth REQUIRED" /etc/squid/squid.conf; then
    # The allow rules must be inserted before the default
    # `http_access deny all` line, otherwise they never fire. If
    # that anchor is missing, refuse to edit rather than guess -- a
    # silently nonfunctional proxy config is worse than none.
    # `|| true` keeps `set -e` from killing the script when grep
    # finds nothing, so the missing-anchor guard below runs and
    # actually prints why it refused to edit.
    DENY_LINE=$(grep -n '^http_access deny all$' /etc/squid/squid.conf | head -n1 | cut -d: -f1 || true)
    if [ -z "$DENY_LINE" ]; then
      echo "    Could not locate Squid's 'http_access deny all' anchor; refusing to edit." >&2
      echo "    Existing http_access lines:" >&2
      grep -n '^http_access' /etc/squid/squid.conf >&2 || echo "    (none)" >&2
      exit 1
    fi

    sudo cp /etc/squid/squid.conf "/etc/squid/squid.conf.bak.$(date +%s)"
    SQUID_BLOCK_FILE="$(mktemp)"
    SQUID_NEW_CONF="$(mktemp)"
    CLEANUP_FILES+=("$SQUID_BLOCK_FILE" "$SQUID_NEW_CONF")
    printf '%s\n' "$SQUID_AUTH_RULES" > "$SQUID_BLOCK_FILE"
    # Insert the rules immediately before the deny-all line.
    # Compose the new file from parts rather than sed -i so no
    # in-place weirdness with newlines.
    {
      sed -n "1,$((DENY_LINE - 1))p" /etc/squid/squid.conf
      cat "$SQUID_BLOCK_FILE"
      sed -n "${DENY_LINE},\$p" /etc/squid/squid.conf
    } > "$SQUID_NEW_CONF"
    sudo install -m 0644 -o root -g root "$SQUID_NEW_CONF" /etc/squid/squid.conf
    echo "    Updated /etc/squid/squid.conf (backup kept)."
  else
    echo "    Config already contains auth rules, skipping."
  fi

  # Parse-validate the config before restarting the daemon.
  if ! sudo squid -k parse; then
    echo "    Invalid Squid configuration; NOT restarting squid. Check /etc/squid/squid.conf." >&2
    exit 1
  fi
  sudo systemctl restart squid

  # If UFW is active, open 3128. Squid requires a username/password
  # (except the explicitly allowed IP above), so the firewall isn't
  # the gate -- auth is -- and the port can stay open to anywhere.
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
echo "### Final environment check ###"
for command in zsh nvim fd bat fnm node npm pnpm yadm; do
  if command -v "$command" >/dev/null 2>&1; then
    echo "    OK  $command"
  else
    echo "    MISSING $command" >&2
  fi
done

echo ""
echo "### Step 3 done. Log out and back in to start using zsh. ###"
if [ -f /var/run/reboot-required ]; then
  echo "A reboot is recommended (kernel or core libraries were updated):"
  echo "  sudo reboot"
  echo "After rebooting, confirm you can still SSH in before relying on the server."
fi
