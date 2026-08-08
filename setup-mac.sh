#!/bin/zsh
# ============================================================
# setup-mac.sh  (new Mac bootstrap, single script)
# Run on a fresh MacBook, as the user you'll use day-to-day:
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-mac.sh)"
#
# Installs Xcode Command Line Tools + Homebrew, the shell env
# (zsh + oh-my-zsh + plugins + spaceship), a set of brew
# formulas, Node via fnm, and then yadm-clones the dotfiles.
# Unlike the VPS flow this is one script: a Mac is your own
# machine, logged in as yourself, so there's no separate user /
# key / user-install split.
#
# This script is zsh, not bash: macOS ships a recent zsh (5.x)
# but its /bin/bash is frozen at 3.2 (2007) until Homebrew
# installs a modern one. So zsh is the only guaranteed-modern
# interpreter on a fresh Mac. Same principle as the VPS flow,
# which uses bash because Ubuntu's bash is modern.
# ============================================================

# Fail fast on any error, unset variable, or pipe failure.
set -euo pipefail

# The dotfiles repo is cloned with yadm near the end. It is an
# SSH URL; the host key generated below is added to GitHub first
# so the clone works.
DOTFILES_REPO="git@github.com:zzacong/dotfiles.git"

# This script is macOS-only.
if [ "$(uname -s)" != "Darwin" ]; then
  echo "setup-mac.sh is for macOS only." >&2
  exit 1
fi

# Don't run as root: everything installs into your home dir, and
# Homebrew explicitly refuses to run as root.
if [ "$(id -u)" -eq 0 ]; then
  echo "Do NOT run this as root. Run it as your normal user." >&2
  exit 1
fi

# ------------------------------------------------------------
# Cleanup + helper plumbing
# ------------------------------------------------------------
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}
require_command curl

# One EXIT trap drives everything: removes the temp files that
# hold the SSH passphrase and stops the script-local ssh-agent
# so the decrypted private key doesn't linger in memory.
# zsh's set -u is happy expanding an empty array, so no :- guard
# (bash would need it).
CLEANUP_FILES=()
cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
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

# ------------------------------------------------------------
# 1. Xcode Command Line Tools
# ------------------------------------------------------------
# Homebrew needs the CLT (a compiler toolchain); a fresh Mac has
# neither. `xcode-select --install` pops a one-click GUI dialog;
# we wait until the tools are actually present before continuing.
if xcode-select -p >/dev/null 2>&1 && [ -d "$(xcode-select -p)" ]; then
  echo "### Xcode Command Line Tools already installed ###"
else
  echo "### Installing Xcode Command Line Tools ###"
  echo "    A dialog will appear -- click Install."
  xcode-select --install >/dev/null 2>&1 || true
  until xcode-select -p >/dev/null 2>&1 && [ -d "$(xcode-select -p)" ]; do
    sleep 5
  done
  echo "    Xcode CLT installed."
fi

# The CLT provides git; curl ships with macOS.
require_command git

# ------------------------------------------------------------
# 2. Homebrew
# ------------------------------------------------------------
# NONINTERACTIVE=1 keeps the installer from pausing. brew lands
# in /opt/homebrew on Apple Silicon and /usr/local on Intel.
if [ -x /opt/homebrew/bin/brew ] || [ -x /usr/local/bin/brew ]; then
  echo "### Homebrew already installed ###"
else
  echo "### Installing Homebrew ###"
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

if [ -x /opt/homebrew/bin/brew ]; then
  HOMEBREW_PREFIX=/opt/homebrew
elif [ -x /usr/local/bin/brew ]; then
  HOMEBREW_PREFIX=/usr/local
else
  echo "    Homebrew install failed; brew not found." >&2
  exit 1
fi
# Put brew on PATH for the rest of this script's shell.
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

# ------------------------------------------------------------
# 3. Shell environment: oh-my-zsh + plugins + theme
# ------------------------------------------------------------
# --unattended skips the interactive prompts and does NOT change
# the default shell (zsh is already the default on macOS, checked
# in step 7).
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

# OMZ resolves `ZSH_THEME="spaceship"` against
# themes/spaceship.zsh-theme; the spaceship repo ships one, so
# link it into the themes dir.
ln -sf "$ZSH_CUSTOM_DIR/themes/spaceship-prompt/spaceship.zsh-theme" \
  "$ZSH_CUSTOM_DIR/themes/spaceship.zsh-theme"

# ------------------------------------------------------------
# 4. Brew formulas
# ------------------------------------------------------------
# The core set mirrors the VPS flow (editor, pager tools, lf,
# yadm for dotfiles) plus the extra tools this machine actually
# uses day-to-day. macOS ships the real `fd`/`bat` names, so no
# symlink dance like Ubuntu's fdfind/batcat.
FORMULAS=(
  neovim
  bat
  ripgrep
  fd
  lf
  yadm
  gh
  lazygit
  git-delta
  jq
  uv
  bun
  btop
  chafa
  glow
  fastfetch
  ffmpeg
  mkcert
  oha
  pipx
  fnm
)
echo "### Installing brew formulas: ${FORMULAS[*]} ###"
brew install "${FORMULAS[@]}"

# Verify the installed binaries actually landed (Homebrew can
# rename or drop formulas in future releases). git-delta ships
# the `delta` binary.
echo "### Verifying installed commands ###"
MISSING=""
for command in nvim bat rg fd lf yadm gh lazygit delta jq uv bun btop chafa glow fastfetch ffmpeg mkcert oha pipx fnm; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "    Missing command: $command" >&2
    MISSING="$MISSING $command"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the brew install, then re-run." >&2
  exit 1
fi

# ------------------------------------------------------------
# 5. Neovim: vim-plug + undodir
# ------------------------------------------------------------
# vim-plug: the standard plugin manager for (n)vim.
echo "### Installing vim-plug for neovim ###"
curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim" --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# init.vim sets `undodir` here; make sure it exists or nvim
# errors on every undo write.
mkdir -p "$HOME/.local/share/nvim/undodir"

# ------------------------------------------------------------
# 6. Node via fnm (node version manager, via Homebrew)
# ------------------------------------------------------------
# ~/.zshrc lists the `fnm` plugin and the `corepackup`/pnpm
# helpers, so node is needed. fnm comes from brew here (no curl
# installer + symlink dance like the VPS, where apt has no fnm).
echo "### Installing latest LTS Node via fnm ###"
eval "$(fnm env)"
fnm install --lts
fnm default lts-latest

# Put fnm's node on PATH for this shell and confirm node and
# corepack actually work.
eval "$(fnm env)"
node --version
corepack --version

# ------------------------------------------------------------
# 7. Ensure zsh is the default shell
# ------------------------------------------------------------
# zsh is the default login shell on macOS since Catalina, so this
# is normally a no-op -- the guard exists for older/odd setups.
echo "### Ensuring zsh is the default shell ###"
if [ "$SHELL" != "$(command -v zsh)" ]; then
  echo "    Changing default shell to zsh (you may be asked for your password)."
  chsh -s "$(command -v zsh)"
else
  echo "    Already zsh."
fi

# ------------------------------------------------------------
# 8. Host key (generated on this Mac, added to GitHub)
# ------------------------------------------------------------
# Unlike the VPS there is no deploy key: the operator's own key
# lives on the Mac and its public half is added to GitHub so the
# dotfiles clone works. Its passphrase is stored in the Keychain
# (via --apple-use-keychain) so it survives reboots -- see
# docs/adr/0002-mac-host-key-keychain-policy.md.
if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
  echo "### No SSH key found; generating one ###"
  mkdir -p "$HOME/.ssh"
  # Owner-only rwx on the dir so ssh doesn't warn "unprotected
  # private key file" and no other user can list its contents.
  chmod 700 "$HOME/.ssh"
  read -rs "SSH_KEY_PASS?    Passphrase for the new SSH key (required): " || true
  echo
  read -rs "SSH_KEY_PASS_CONFIRM?    Confirm passphrase: " || true
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
  read "_IGNORED?    Press Enter once it's added to GitHub: " || true
else
  echo "    SSH key already exists; reusing it."
  read -rs "SSH_KEY_PASS?    Passphrase for ~/.ssh/id_ed25519 (required): " || true
  echo
  if [ -z "$SSH_KEY_PASS" ]; then
    echo "    Passphrase cannot be empty." >&2
    exit 1
  fi
fi

# The key has a passphrase, so load it into an ssh-agent
# (spawned just for this script, killed on exit by the trap
# above) and store the passphrase in the Keychain, before the
# yadm clone below -- otherwise the first SSH connection to
# github.com would prompt for the passphrase and hang.
echo "### Loading SSH key into ssh-agent + Keychain ###"
eval "$(ssh-agent -s)"
setup_askpass "$SSH_KEY_PASS"
if ssh-add -l >/dev/null 2>&1 && ssh-add -l 2>/dev/null | grep -q id_ed25519; then
  echo "    Key already loaded."
else
  SSH_ASKPASS="$ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force \
    ssh-add --apple-use-keychain "$HOME/.ssh/id_ed25519"
fi

# ------------------------------------------------------------
# 9. Dotfiles
# ------------------------------------------------------------
# oh-my-zsh wrote a default .zshrc (and Homebrew may have written
# .zprofile); back up every shell file we might collide with and
# move them aside so yadm's versions win without destroying
# anything. Nothing is deleted -- the originals are recoverable
# from $BACKUP_DIR.
echo "### Moving existing shell files out of the way (backed up) ###"
BACKUP_DIR="$HOME/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
for file in .zshrc .zprofile .zshenv .zlogin .bashrc .bash_profile .profile .bash_logout; do
  if [ -e "$HOME/$file" ]; then
    mv "$HOME/$file" "$BACKUP_DIR/$file"
  fi
done
if [ "$(ls -A "$BACKUP_DIR" 2>/dev/null)" ]; then
  echo "    Backed up to $BACKUP_DIR"
else
  rmdir "$BACKUP_DIR"
fi

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
if [ -d "$HOME/.config/yadm/repo.git" ]; then
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
elif yadm clone -b main "$DOTFILES_REPO"; then
  echo "    Dotfiles cloned."
else
  echo "    yadm clone failed (tracked file colliding with a shell default?); restore with:" >&2
  echo "      cp -a ${BACKUP_DIR:-?}/. \$HOME/" >&2
  exit 1
fi

# Homebrew's installer writes `eval "$(brew shellenv)"` to
# ~/.zprofile; the move-aside above may have hidden it. If the
# dotfiles don't track a .zprofile that sets brew up, re-add it
# so a fresh login shell still finds brew.
if ! grep -q 'brew shellenv' "$HOME/.zprofile" 2>/dev/null; then
  echo 'eval "$('"$HOMEBREW_PREFIX"'/bin/brew shellenv)"' >> "$HOME/.zprofile"
  echo "    Added brew shellenv to ~/.zprofile."
fi

# Install the plugins listed in ~/.config/nvim/init.vim. This
# needs init.vim to exist (from the yadm clone just above).
echo "### Installing neovim plugins via vim-plug ###"
if [ -f "$HOME/.config/nvim/init.vim" ]; then
  nvim --headless +'PlugInstall --sync' +qa
else
  echo "    No ~/.config/nvim/init.vim found; skipping PlugInstall."
fi

echo ""
echo "### Final environment check ###"
for command in zsh nvim fd bat rg lf yadm gh fnm node npm corepack; do
  if command -v "$command" >/dev/null 2>&1; then
    echo "    OK  $command"
  else
    echo "    MISSING $command" >&2
  fi
done

echo ""
echo "### New Mac setup done. Open a new Terminal window to start using zsh. ###"
echo "    Shell files backed up from the move-aside live in: $BACKUP_DIR"
