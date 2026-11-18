#!/usr/bin/env bash
# ============================================================
# setup-user.sh  (step 3 of 3)
# Run as the new sudo user created by setup-root.sh (whose SSH
# key was set up by setup-ssh.sh):
#   bash setup-user.sh
#
# Installs packages (via sudo), Tailscale, fish, nvim, Node via
# fnm, dotfiles, and optionally the firewall and a Squid proxy.
# sshd hardening is the last mandatory step so your host
# machine's SSH key is confirmed working before password auth
# is disabled.
# No private keys ever live on this box: GitHub access uses the
# 1Password SSH agent forwarded from your host (connect with ssh -A).
# ============================================================

# Fail fast on any error, unset variable, or pipe failure.
set -euo pipefail

# The dotfiles repo is cloned with yadm near the end. It is an
# SSH URL; auth comes from the forwarded 1Password agent, whose
# public half is already on GitHub -- no key is generated on
# this server.
DOTFILES_REPO="git@github.com:zzacong/dotfiles.git"

# This whole script must run as the new user, not root,
# otherwise everything gets installed into /root instead.
if [ "$(id -u)" -eq 0 ]; then
  echo "Do NOT run this as root. Log in as the new user first." >&2
  exit 1
fi

# Resolve the login name from the system, not $USER: $USER can be
# unset (env -i) or stale (su / sudo -u without env reset), and this
# value lands in sshd's AllowUsers -- a wrong name locks you out.
CURRENT_USER="$(id -un)"

# Keep apt fully non-interactive so conffile and needrestart
# prompts can't hang an unattended run.
export DEBIAN_FRONTEND=noninteractive

# ~/.local/bin holds the fd/bat symlinks, zoxide, and fnm, but a
# non-login bash may not have it on PATH yet. Export it now so
# `command -v` checks (and the final environment check) see them.
export PATH="$HOME/.local/bin:$PATH"

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
require_command ssh-add
require_command ssh-keygen

# One EXIT trap drives everything: removes temp files and kills
# the sudo keep-alive loop. No script-local ssh-agent is started:
# GitHub auth uses the forwarded 1Password agent ($SSH_AUTH_SOCK),
# which must be left alone -- never overwrite it with eval $(ssh-agent).
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
}
trap cleanup EXIT

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
# 0. Preflight: ask everything up front
# ------------------------------------------------------------
# All plan questions live here so the rest of the script runs
# without stopping. The sshd hardening confirmation stays in
# section 6: it is a live safety check, not a plan choice.
echo "### Configuration (asked up front, then runs unattended) ###"
RUN_UPGRADE=""
SETUP_UFW=""
INSTALL_SQUID=""

read -rp "Run a full 'sudo apt-get upgrade'? (y/N): " RUN_UPGRADE || true

read -rp "Set up the UFW firewall? (y/N): " SETUP_UFW || true

# The proxy needs no credentials to collect any more: it is gated
# on the tailnet, which is a fact about the network rather than an
# answer to a question.
read -rp "Also install the Squid proxy server? (y/N): " INSTALL_SQUID || true

echo "    upgrade: ${RUN_UPGRADE:-n}"
echo "    ufw: ${SETUP_UFW:-n}"
echo "    squid: ${INSTALL_SQUID:-n}"

# ------------------------------------------------------------
# 1. System packages (via sudo)
# ------------------------------------------------------------
# The new user has sudo rights, so the apt work now lives here
# instead of setup-root.sh. You'll be asked for your password
# on the first sudo command.
#   fd-find / bat  -> Ubuntu still renames these to fdfind /
#                     batcat even on 24.04 (handled in step 3)
#   lf             -> available since Ubuntu 23.04
#   lsof           -> used by the `runp` function in the fish config
#   unzip          -> required by the fnm installer (step 4)
#   python3        -> not used by this script; kept because tools
#                     in the dotfiles expect it to exist
echo "### Updating apt packages ###"
sudo apt-get update

# A full upgrade is optional: it can pull in a kernel update and
# force a reboot, and it's slow. Answered up front in section 0.
if [[ "${RUN_UPGRADE,,}" =~ ^y(es)?$ ]]; then
  sudo apt-get upgrade -y
fi

echo "### Installing fish, neovim, fd-find, bat, ripgrep, lf, yadm ###"
sudo apt-get install -y --no-install-recommends \
  fish neovim fd-find bat ripgrep lf yadm git curl lsof unzip python3

# Verify the packages actually landed (minimal images and future
# releases can rename or drop them).
echo "### Verifying installed commands ###"
MISSING=""
for command in fish nvim fdfind batcat rg lf yadm git curl lsof unzip python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "    Missing command: $command" >&2
    MISSING="$MISSING $command"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the apt install, then re-run." >&2
  exit 1
fi

# Tailscale is not in that list because Ubuntu does not package it:
# the official installer adds the apt repo and keyring, then installs
# the package. Skipped when the binary is already there so a re-run
# leaves the repo alone.
if ! command -v tailscale >/dev/null 2>&1; then
  echo "### Installing Tailscale ###"
  curl -fsSL https://tailscale.com/install.sh | sh
else
  echo "### tailscale already installed, skipping install ###"
fi
# The deb starts tailscaled, but a re-run after `systemctl disable`
# should put it back, and enable --now is idempotent either way.
sudo systemctl enable --now tailscaled

# The node is up but logged out: tailscale0 carries no traffic until
# you authenticate. Printing the command instead of running it keeps
# the run unattended and keeps an auth key out of the transcript.
# `tailscale ip` asks the daemon, so it needs sudo.
TAILSCALE_IP="$(sudo tailscale ip -4 2>/dev/null | head -n1 || true)"
if [ -n "$TAILSCALE_IP" ]; then
  echo "    Tailscale logged in as $TAILSCALE_IP."
else
  echo "    Tailscale installed but not logged in. Run this next:"
  echo "      sudo tailscale up"
  echo "    (no --ssh: sshd stays the only way in. Confirm with 'tailscale status'.)"
fi

# ------------------------------------------------------------
# 2. Shell tools: zoxide, starship, and the bash startup blocks
# ------------------------------------------------------------
# fish is the shell you type into; it came with the packages in
# step 1. The login shell stays bash -- Ubuntu's default -- so
# nothing here runs chsh. Instead, marker-delimited blocks in
# ~/.bash_profile (fish hand-off) and ~/.bashrc (bash env) set up
# the two bash entry points, while `ssh host cmd` stays untouched.
# zoxide and starship below are consumed by the dotfiles' fish
# config, which calls `zoxide init fish` and `starship init fish`.

echo "### Installing zoxide ###"
# Zoxide is installed via its official script (the apt package
# lags the releases). It lands in ~/.local/bin, which the
# dotfiles' fish config puts on PATH.
if [ ! -x "$HOME/.local/bin/zoxide" ]; then
  curl -fsSL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
else
  echo "    Already installed, skipping."
fi

echo "### Installing starship prompt ###"
# Starship is installed via its official script (apt has no
# starship). It lands in /usr/local/bin, escalating via sudo
# since that dir is root-owned; -y skips the confirmation prompt.
# The config (~/.config/starship.toml) is tracked in the yadm
# dotfiles, so the binary is all this step needs to provide.
if ! command -v starship >/dev/null 2>&1; then
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y
else
  echo "    Already installed, skipping."
fi

# Write a marker-delimited block into a startup file, once. A
# re-run is a no-op, and anything else already in the file is left
# as it was. Both blocks below are bootstrap-owned (neither file is
# in the dotfiles), so re-running this script updates them.
write_block() {
  local file="$1" begin="$2"
  shift 2
  if [ -f "$file" ] && grep -qF "$begin" "$file"; then
    echo "    $(basename "$file"): block already present, skipping."
    return 0
  fi
  if [ -s "$file" ]; then
    printf '\n' >> "$file"
  fi
  printf '%s\n' "$begin" "$@" >> "$file"
  echo "    $(basename "$file"): block added."
}

# bash reads ~/.bash_profile instead of the skel ~/.profile for login
# shells, and an SSH session is exactly that -- so this block turns
# every login into fish without touching /etc/passwd. `ssh host cmd`
# is not a login shell, so scp, rsync, and scripts stay bash. The
# PATH line is for the fallback where fish is missing: bash skips the
# skel ~/.profile here, and that is what normally puts ~/.local/bin
# on PATH.
echo "### Writing the fish hand-off into ~/.bash_profile ###"
write_block "$HOME/.bash_profile" "# BEGIN vps-bootstrap fish hand-off" \
  '# Hand interactive logins (SSH) to fish; bash stays the login shell.' \
  'PATH="$HOME/.local/bin:$PATH"' \
  'if [[ $- == *i* ]] && command -v fish >/dev/null 2>&1; then' \
  '  exec fish' \
  'fi' \
  "# END vps-bootstrap fish hand-off"

# ~/.bashrc is what interactive non-login bash reads: typing `bash`
# from fish, a tmux window, `bash -i`. That is the bash you land in
# on purpose, and `fnm env` is what puts the active node version's
# bin dir on PATH -- without it there is no node under bash at all
# (node lives in ~/.local/share/fnm, not ~/.local/bin). The
# interactive guard keeps `ssh host cmd` from paying for it.
echo "### Writing the bash env block into ~/.bashrc ###"
write_block "$HOME/.bashrc" "# BEGIN vps-bootstrap bash env" \
  '# fnm-managed node for bash sessions (fish has its own config).' \
  'case ":$PATH:" in' \
  '  *":$HOME/.local/bin:"*) ;;' \
  '  *) PATH="$HOME/.local/bin:$PATH" ;;' \
  'esac' \
  'if [[ $- == *i* ]] && command -v fnm >/dev/null 2>&1; then' \
  '  eval "$(fnm env --use-on-cd --shell bash)"' \
  'fi' \
  "# END vps-bootstrap bash env"

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
# The dotfiles' fish config runs `fnm env` and uses pnpm, so node
# is needed. fnm installs to ~/.local/share/fnm; symlink it into
# ~/.local/bin (which the fish config already puts on PATH) and
# grab the latest LTS node. --skip-shell stops the installer from
# appending its own `eval "$(fnm env)"` block to ~/.bashrc, which
# we don't manage.
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

# pnpm: installed via `npm i -g` (npm comes from fnm's node,
# so pnpm lands in node's global prefix on PATH). The standalone
# installer (get.pnpm.io) is not used, and corepack is not used
# either -- newer Node LTS no longer ships it.
echo "### Installing pnpm ###"
if command -v pnpm >/dev/null 2>&1; then
  echo "    pnpm already installed, skipping."
  pnpm --version
else
  npm i -g pnpm
  if ! command -v pnpm >/dev/null 2>&1; then
    echo "    pnpm install failed; binary not on PATH." >&2
    exit 1
  fi
  pnpm --version
fi

# ------------------------------------------------------------
# 5. Dotfiles
# ------------------------------------------------------------
# No keys are generated on this box. GitHub auth comes from the
# 1Password SSH agent forwarded from your host -- you must have
# connected with `ssh -A` (or ForwardAgent yes). Do NOT start a
# local ssh-agent here: it would overwrite $SSH_AUTH_SOCK and
# hide the forwarded agent.
echo "### Checking forwarded 1Password agent ###"
if [ -z "${SSH_AUTH_SOCK:-}" ]; then
  echo "    No forwarded agent (SSH_AUTH_SOCK is unset)." >&2
  echo "    Log out and reconnect with: ssh -A $CURRENT_USER@<host>" >&2
  exit 1
fi
if ! ssh-add -L >/dev/null 2>&1; then
  echo "    Forwarded agent has no keys (ssh-add -L failed)." >&2
  echo "    Check 1Password's SSH agent on your host, then reconnect with: ssh -A $CURRENT_USER@<host>" >&2
  exit 1
fi
echo "    Forwarded keys visible:"
# Guarded: the agent could vanish between the check above and
# here, and pipefail + set -e would otherwise exit silently.
# The GitHub probe below reports clearly if keys are gone.
ssh-add -l 2>/dev/null | sed 's/^/      /' || true

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

# Fail fast if GitHub rejects the forwarded key, before yadm
# depends on it below. BatchMode keeps ssh from prompting.
echo "### Testing GitHub auth via forwarded agent ###"
GH_OUTPUT="$(ssh -o BatchMode=yes -T git@github.com 2>&1 || true)"
# The repo URL already names its owner, so derive the expected
# GitHub user from it: with several keys in the agent, ssh offers
# each in turn and GitHub answers as the first one it accepts --
# which may be a valid login on the wrong account, lacking access
# to this repo. Showing who won turns that into a clear error
# instead of a confusing yadm clone failure.
REPO_OWNER="${DOTFILES_REPO#git@github.com:}"
REPO_OWNER="${REPO_OWNER%%/*}"
if printf '%s' "$GH_OUTPUT" | grep -qi "successfully authenticated"; then
  printf '%s\n' "$GH_OUTPUT" | head -n1 | sed 's/^/      /'
  if printf '%s' "$GH_OUTPUT" | grep -qi "Hi ${REPO_OWNER}!"; then
    echo "    GitHub auth OK as ${REPO_OWNER} via forwarded agent."
  else
    echo "    Authenticated, but NOT as ${REPO_OWNER} (owner of $DOTFILES_REPO)." >&2
    echo "    Move the key for ${REPO_OWNER} first in 1Password, or add a forwarded key to that account." >&2
    exit 1
  fi
else
  echo "    GitHub auth failed. Raw ssh output:" >&2
  printf '      %s\n' "$GH_OUTPUT" >&2
  echo "    Is this 1Password public key on the right GitHub account?" >&2
  exit 1
fi

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
  if ! yadm remote -v 2>/dev/null | grep -qF "$DOTFILES_REPO"; then
    echo "    Warning: yadm remote is not $DOTFILES_REPO; check with 'yadm remote -v'." >&2
  fi
  if [ -n "$(yadm status --porcelain 2>/dev/null)" ]; then
    echo "    Local yadm changes exist; NOT pulling. Review with 'yadm status'." >&2
  else
    yadm pull
    echo "    Pulled latest."
  fi
else
  # Only a fresh bootstrap needs this, and only for the one shell
  # startup file the Linux dotfiles track: ~/.config/fish/config.fish.
  # Nothing here writes it (there is no zsh and no oh-my-zsh on this
  # flow), but a fish that ran before the clone would have left its
  # own default config there, and that would collide with (and
  # block) the clone. Move it aside so yadm's version wins without
  # destroying anything -- nothing is deleted, the original stays in
  # $BACKUP_DIR. Files the dotfiles do not track (.bashrc, .profile,
  # ~/.zshrc) are left alone: the clone never replaces them, and
  # ~/.bash_profile is the fish hand-off this script wrote in step 2.
  # On a re-run this block is skipped because the file is already
  # yadm-managed (moving it would dirty the repo and leave you
  # without a fish config).
  echo "### Moving existing shell startup files out of the way (backed up) ###"
  BACKUP_DIR="$HOME/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  FISH_CONFIG="$HOME/.config/fish/config.fish"
  if [ -e "$FISH_CONFIG" ]; then
    mkdir -p "$BACKUP_DIR/.config/fish"
    mv "$FISH_CONFIG" "$BACKUP_DIR/.config/fish/config.fish"
  fi
  if [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
    echo "    Backed up to $BACKUP_DIR"
  else
    rmdir "$BACKUP_DIR"
  fi

  if yadm clone -b main "$DOTFILES_REPO"; then
    echo "    Dotfiles cloned."
  else
    echo "    yadm clone failed (tracked file colliding with a shell startup file?); restore with:" >&2
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
# 6. sshd hardening (LAST mandatory step, so keys work first)
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
if grep -q "^PasswordAuthentication no" "$HARDENING_FILE" 2>/dev/null; then
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
AllowUsers $CURRENT_USER
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
    echo "    Test it first: ssh -o PasswordAuthentication=no $CURRENT_USER@<host>" >&2
  fi
fi

# ------------------------------------------------------------
# 7. (Optional) UFW firewall
# ------------------------------------------------------------
# Firewall setup is opt-in: deny all incoming by default, allow
# outgoing, then explicitly open what you need. Two rules only:
# ssh, and the whole tailscale0 interface. Nothing is opened to the
# public internet for the proxy -- port 3128 rides in on the
# tailnet rule -- and no 80/443 rule exists at all.
#
# ssh is allowed from anywhere because tailscale0 exists but
# carries nothing yet: the node is installed, not authenticated.
# Closing 22 here would leave a box you cannot log in to until you
# finish `tailscale up`, with only the provider console as a way
# back. The hint at the end of this section removes it once tailnet
# ssh is proven. Answered up front in section 0.
if [[ "${SETUP_UFW,,}" =~ ^y(es)?$ ]]; then
  echo "### Setting up UFW firewall ###"
  sudo apt-get install -y ufw
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow ssh

  # Interface rules are accepted before the interface exists (ufw
  # matches on the name), so this survives being added pre-login.
  sudo ufw allow in on tailscale0

  # --force skips ufw's "this may disrupt existing connections"
  # prompt. SSH is already allowed above, so it's safe.
  sudo ufw --force enable
  sudo ufw status verbose

  # Deliberately a printed command, never an action: deleting this
  # rule over the connection that rule admits is a lockout waiting
  # to happen. Verify from a second terminal first.
  echo ""
  echo "    Port 22 is still open to the world. To close it, first prove"
  echo "    tailnet ssh works (from a SECOND terminal):"
  echo "      ssh $(id -un)@${TAILSCALE_IP:-<tailnet-ip>} true"
  echo "    then:"
  echo "      sudo ufw delete allow ssh"
fi

# ------------------------------------------------------------
# 8. (Optional) Squid proxy
# ------------------------------------------------------------
# Squid is a caching HTTP/HTTPS proxy reachable only from your
# tailnet: the rules allow Tailscale's 100.64.0.0/10 source range
# and deny everything else, with no username or password to keep.
# That works because ufw lets every packet on tailscale0 in, and
# squid only sees 100.x sources on that interface.
#
# The rules go in their own file under /etc/squid/conf.d, which
# stock squid.conf includes just before its `http_access deny all`,
# so they take effect while squid.conf itself is never edited -- an
# untouched conffile is what keeps `apt upgrade` from asking about
# it. Placement matters twice: the stock denies are read BEFORE the
# include, so tailnet clients still cannot CONNECT outside
# SSL_ports, reach the box's own localhost services, or use the
# cache manager. The include is checked below before writing.
# Install choice was collected up front in section 0.
if [[ "${INSTALL_SQUID,,}" =~ ^y(es)?$ ]]; then
  echo "### Installing Squid proxy ###"
  sudo apt-get install -y squid
  sudo systemctl enable --now squid

  SQUID_CONF_DIR="/etc/squid/conf.d"
  SQUID_RULES_FILE="$SQUID_CONF_DIR/20-vps-bootstrap.conf"

  # The include line is what makes the rules file live. Stock
  # squid.conf ships it uncommented; if it is gone the rules would
  # be silently ignored, which is worse than not writing them, so
  # refuse instead of guessing.
  if ! grep -qE "^include[[:space:]]+${SQUID_CONF_DIR}/" /etc/squid/squid.conf; then
    echo "    /etc/squid/squid.conf does not include $SQUID_CONF_DIR/; refusing to write rules squid would ignore." >&2
    echo "    Add 'include $SQUID_CONF_DIR/*.conf' above 'http_access deny all' and re-run." >&2
    exit 1
  fi

  # Two rules, no auth_param. A logged-out node means no source in
  # 100.64.0.0/10, so the proxy denies everyone -- the failure
  # direction is closed, not open.
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

  # This file belongs to the scripts, so a re-run replaces it. The
  # previous copy is kept beside squid.conf's own backups, outside
  # conf.d so it can never be picked up by the include glob.
  sudo install -d -m 0755 -o root -g root "$SQUID_CONF_DIR"
  if [ -f "$SQUID_RULES_FILE" ]; then
    sudo cp "$SQUID_RULES_FILE" "/etc/squid/20-vps-bootstrap.conf.bak.$(date +%s)"
  fi
  SQUID_RULES_TMP="$(mktemp)"
  CLEANUP_FILES+=("$SQUID_RULES_TMP")
  printf '%s\n' "$SQUID_RULES" > "$SQUID_RULES_TMP"
  sudo install -m 0644 -o root -g root "$SQUID_RULES_TMP" "$SQUID_RULES_FILE"
  echo "    Wrote $SQUID_RULES_FILE."

  # Parse-validate the config before restarting the daemon.
  if ! sudo squid -k parse; then
    echo "    Invalid Squid configuration; NOT restarting squid. Check $SQUID_RULES_FILE." >&2
    exit 1
  fi
  sudo systemctl restart squid

  # 3128 needs no rule of its own: traffic arrives on tailscale0,
  # which section 7 already allows wholesale. Without that firewall
  # the port is reachable from the internet, and the tailnet ACL is
  # the only thing answering -- worth saying out loud once.
  if command -v ufw >/dev/null 2>&1 && sudo ufw status 2>/dev/null | grep -q "Status: active"; then
    echo "    UFW is active; 3128 is reachable only over tailscale0."
  else
    echo "    NOTE: UFW is not active, so port 3128 is reachable from the internet."
    echo "          Only the tailnet ACL protects it (everything else gets 403)."
    echo "          Re-run with the firewall, or restrict 3128 yourself."
  fi

  echo "    Squid configured and running."
  echo "    Config: $SQUID_RULES_FILE"
  echo "    Port: 3128, tailnet only (http://${TAILSCALE_IP:-<tailnet-ip>}:3128)"
fi

echo ""
echo "### Final environment check ###"
for command in fish nvim fd bat fnm node npm pnpm yadm starship; do
  if command -v "$command" >/dev/null 2>&1; then
    echo "    OK  $command"
  else
    echo "    MISSING $command" >&2
  fi
done
# The startup blocks are what make an SSH login land in fish and
# give bash a fnm-managed node, so check the markers rather than
# trusting the writes.
if grep -qF "# BEGIN vps-bootstrap fish hand-off" "$HOME/.bash_profile" 2>/dev/null; then
  echo "    OK  fish hand-off"
else
  echo "    MISSING fish hand-off in ~/.bash_profile" >&2
fi
if grep -qF "# BEGIN vps-bootstrap bash env" "$HOME/.bashrc" 2>/dev/null; then
  echo "    OK  bash env (fnm)"
else
  echo "    MISSING bash env block in ~/.bashrc" >&2
fi
# zoxide lands in ~/.local/bin, which is on PATH only after the
# dotfiles' fish config loads, so check for the file directly.
if [ -x "$HOME/.local/bin/zoxide" ]; then
  echo "    OK  zoxide"
else
  echo "    MISSING zoxide" >&2
fi
# Being logged out is a normal state for a freshly bootstrapped box,
# not a failure, so it gets a reminder rather than a MISSING line.
if [ -n "$TAILSCALE_IP" ]; then
  echo "    OK  tailscale ($TAILSCALE_IP)"
else
  echo "    LOGGED OUT  tailscale -- run 'sudo tailscale up'" >&2
fi

# Repeated from section 7: it is the only follow-up that can lock
# you out if done early, so it gets said twice.
if [[ "${SETUP_UFW,,}" =~ ^y(es)?$ ]]; then
  echo ""
  echo "### UFW: port 22 is still open to the world ###"
  echo "Once tailnet ssh works from a SECOND terminal:"
  echo "  ssh $CURRENT_USER@${TAILSCALE_IP:-<tailnet-ip>} true"
  echo "  sudo ufw delete allow ssh"
fi

echo ""
echo "### Step 3 done. Log out and back in to start using fish (bash stays the login shell). ###"
if [ -f /var/run/reboot-required ]; then
  echo "A reboot is recommended (kernel or core libraries were updated):"
  echo "  sudo reboot"
  echo "After rebooting, confirm you can still SSH in before relying on the server."
fi
