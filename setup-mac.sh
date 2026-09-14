#!/bin/zsh
# ============================================================
# setup-mac.sh  (new Mac bootstrap, single script)
# Run on a fresh MacBook, as the user you'll use day-to-day:
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-mac.sh)"
#
# Installs Xcode Command Line Tools + Homebrew, the shell env
# (zsh + oh-my-zsh + plugins + starship), a set of brew formulas,
# Node via fnm, and then yadm-clones the dotfiles.
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
# SSH URL, authenticated by the 1Password SSH agent set up in
# step 9; no key is generated on this Mac.
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

# One EXIT trap drives everything: removes the temp files the
# script writes. zsh's set -u is happy expanding an empty array,
# so no :- guard (bash would need it).
CLEANUP_FILES=()
cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

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
  # If the dialog is dismissed, `xcode-select -p` never resolves
  # and the loop would spin forever -- bail after 30 minutes with
  # a clear message instead.
  SECS=0
  until xcode-select -p >/dev/null 2>&1 && [ -d "$(xcode-select -p)" ]; do
    sleep 5
    SECS=$((SECS + 5))
    if [ "$SECS" -ge 1800 ]; then
      echo "    Timed out waiting for Xcode CLT after 30 minutes." >&2
      echo "    Run 'xcode-select --install' manually, then re-run this script." >&2
      exit 1
    fi
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
# 3. Shell environment: oh-my-zsh + plugins + starship
# ------------------------------------------------------------
# --unattended skips the interactive prompts and does NOT change
# the default shell (zsh is already the default on macOS, checked
# in step 8). The installer hard-exits 1 if ~/.oh-my-zsh already
# exists, so guard it like the plugin clones below to stay
# re-runnable. ZDOTDIR mirrors how the installer resolves $ZSH.
echo "### Installing oh-my-zsh ###"
ZSH_DIR="${ZDOTDIR:-$HOME}/.oh-my-zsh"
if [ ! -d "$ZSH_DIR" ]; then
  sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
else
  echo "    Already installed, skipping."
fi

# The plugins that don't ship with oh-my-zsh are cloned into its
# custom directory; oh-my-zsh loads any plugin there that the
# .zshrc lists by name. --depth=1 keeps each clone shallow and
# fast. Each clone is skipped if it already exists so the script
# is re-runnable.
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

echo "### Installing zsh-completions plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/zsh-completions" ]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-completions "$ZSH_CUSTOM_DIR/plugins/zsh-completions"
else
  echo "    Already cloned, skipping."
fi

echo "### Installing zsh-autosuggestions plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions" ]; then
  git clone --depth=1 https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"
else
  echo "    Already cloned, skipping."
fi

echo "### Installing zsh-you-should-use plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/you-should-use" ]; then
  git clone --depth=1 https://github.com/MichaelAquilina/zsh-you-should-use "$ZSH_CUSTOM_DIR/plugins/you-should-use"
else
  echo "    Already cloned, skipping."
fi

echo "### Installing fast-syntax-highlighting plugin ###"
if [ ! -d "$ZSH_CUSTOM_DIR/plugins/fast-syntax-highlighting" ]; then
  git clone --depth=1 https://github.com/zdharma-continuum/fast-syntax-highlighting "$ZSH_CUSTOM_DIR/plugins/fast-syntax-highlighting"
else
  echo "    Already cloned, skipping."
fi

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
  pnpm
  fnm
  starship
  zoxide
)
echo "### Installing brew formulas: ${FORMULAS[*]} ###"
brew install "${FORMULAS[@]}"

# Verify the installed binaries actually landed (Homebrew can
# rename or drop formulas in future releases). git-delta ships
# the `delta` binary.
echo "### Verifying installed commands ###"
MISSING=""
for command in nvim bat rg fd lf yadm gh lazygit delta jq uv bun btop chafa glow fastfetch ffmpeg mkcert oha pipx pnpm fnm starship zoxide; do
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
# ~/.zshrc lists the `fnm` plugin and pnpm, so node is needed.
# fnm comes from brew here (no curl installer + symlink dance
# like the VPS, where apt has no fnm). pnpm is installed via
# brew too -- not corepack, which newer Node LTS no longer ships.
echo "### Installing latest LTS Node via fnm ###"
eval "$(fnm env)"
fnm install --lts
fnm default lts-latest

# Put fnm's node on PATH for this shell and confirm node and
# pnpm actually work.
eval "$(fnm env)"
node --version
pnpm --version

# ------------------------------------------------------------
# 7. pipx apps (Python CLIs, each in its own venv)
# ------------------------------------------------------------
# pipx (from brew above) installs Python CLIs into ~/.local/pipx
# and exposes them on PATH via ~/.local/bin. rich-cli is
# deliberately not installed.
echo "### Installing pipx apps ###"
pipx install virtualenv
pipx install yt-dlp
# pipx exposes apps in ~/.local/bin, which the script's own
# non-interactive PATH won't include (that export lives in the
# dotfiles' .zshrc), so verify by file, not `command -v`.
for app in virtualenv yt-dlp; do
  if [ ! -x "$HOME/.local/bin/$app" ]; then
    echo "    Missing pipx app: $app" >&2
    exit 1
  fi
done

# ------------------------------------------------------------
# 8. Ensure zsh is the default shell
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
# 9. 1Password SSH agent (the GitHub credential)
# ------------------------------------------------------------
# Like the VPS flow, this Mac keeps no GitHub key of its own: the
# operator's 1Password key signs the dotfiles clone (ADR-0006).
# 1Password's agent listens on a socket inside the app's group
# container; ~/.1password/agent.sock is a stable short path to
# it, and ~/.ssh/config points IdentityAgent at that path. A
# fresh Mac has neither, so create both before the clone.
OP_AGENT_SOCK="$HOME/.1password/agent.sock"
OP_AGENT_TARGET="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"

# The group container only exists once 1Password has run, and the
# script does not install it: a licensed, signed-in app is not
# something a bootstrap can conjure. Fail here with instructions
# rather than at the clone with a bare publickey error.
if [ ! -d "$(dirname "$OP_AGENT_TARGET")" ]; then
  echo "1Password is not set up on this Mac." >&2
  echo "    Install and sign in to 1Password, then enable" >&2
  echo "    Settings -> Developer -> SSH agent, and re-run this script." >&2
  exit 1
fi

mkdir -p "$HOME/.1password"
if [ -L "$OP_AGENT_SOCK" ]; then
  # Re-point a stale link. A real file there is left alone: better
  # to warn than to clobber something put there on purpose.
  if [ "$(readlink "$OP_AGENT_SOCK")" != "$OP_AGENT_TARGET" ]; then
    echo "### Re-pointing $OP_AGENT_SOCK ###"
    ln -sfn "$OP_AGENT_TARGET" "$OP_AGENT_SOCK"
  fi
elif [ -e "$OP_AGENT_SOCK" ]; then
  echo "    $OP_AGENT_SOCK exists and is not a symlink; leaving it alone."
else
  echo "### Linking $OP_AGENT_SOCK to 1Password's agent socket ###"
  ln -s "$OP_AGENT_TARGET" "$OP_AGENT_SOCK"
fi

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
# macOS points SSH_AUTH_SOCK at its own agent, not 1Password's, so
# the config line is what routes ssh (and the git clone) to the
# 1Password key. The dotfiles don't track this file and the clone
# is what needs it, so pre-seed it; an existing file is only
# warned about, since it may carry hosts and options worth keeping.
if [ ! -f "$HOME/.ssh/config" ]; then
  echo "### Writing ~/.ssh/config (1Password SSH agent) ###"
  cat > "$HOME/.ssh/config" <<'EOF'
Host *
  IdentityAgent ~/.1password/agent.sock
EOF
  chmod 600 "$HOME/.ssh/config"
elif ! grep -q "IdentityAgent" "$HOME/.ssh/config"; then
  echo "    ~/.ssh/config exists but names no IdentityAgent; add:" >&2
  echo "      Host *" >&2
  echo "        IdentityAgent ~/.1password/agent.sock" >&2
else
  echo "    ~/.ssh/config already names an IdentityAgent; leaving it alone."
fi

# ------------------------------------------------------------
# 10. Dotfiles
# ------------------------------------------------------------
# yadm clones over SSH; pre-seed known_hosts so the first
# connection to github.com doesn't prompt for host confirmation
# and hang in a non-interactive context. Pin GitHub's published
# ed25519 host key (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
# instead of trusting unauthenticated `ssh-keyscan` output.
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
GITHUB_HOST_KEY="github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
# Add the pinned key only if that exact line is absent -- checking
# `ssh-keygen -F github.com` would skip even when the only entry
# is a stale or wrong key (e.g. an old RSA one).
if ! grep -qxF "$GITHUB_HOST_KEY" "$HOME/.ssh/known_hosts" 2>/dev/null; then
  echo "$GITHUB_HOST_KEY" >> "$HOME/.ssh/known_hosts"
fi
chmod 600 "$HOME/.ssh/known_hosts" 2>/dev/null || true

# Verify the key actually authenticates to GitHub before we rely
# on it for the yadm clone; a typo'd or not-yet-added key would
# otherwise surface as a confusing clone failure. GitHub always
# exits non-zero for `ssh -T` even on success, so check the
# banner text rather than the exit code.
echo "### Verifying GitHub SSH auth ###"
GITHUB_AUTH_OUTPUT="$(ssh -o BatchMode=yes -T git@github.com 2>&1 || true)"
if ! echo "$GITHUB_AUTH_OUTPUT" | grep -q "successfully authenticated"; then
  echo "    GitHub SSH auth failed via the 1Password agent." >&2
  echo "    Check that 1Password is running and unlocked with its SSH agent on" >&2
  echo "    (Settings -> Developer -> SSH agent), and that the key's public half" >&2
  echo "    is on the GitHub account owning $DOTFILES_REPO." >&2
  exit 1
fi
echo "    GitHub SSH auth OK."

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
  # Only a fresh bootstrap needs this: oh-my-zsh and Homebrew wrote
  # shell files (.zshrc, .zprofile) that would collide with (and
  # block) the clone. Move them aside so yadm's versions win without
  # destroying anything -- nothing is deleted, the originals stay in
  # $BACKUP_DIR. On a re-run this block is skipped because the shell
  # files are already yadm-managed (moving them would dirty the repo
  # and leave you without a .zshrc).
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

  if yadm clone -b main "$DOTFILES_REPO"; then
    echo "    Dotfiles cloned."
  else
    echo "    yadm clone failed (tracked file colliding with a shell default?); restore with:" >&2
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

echo ""
echo "### Final environment check ###"
for command in zsh nvim fd bat rg lf yadm gh fnm node npm pnpm starship; do
  if command -v "$command" >/dev/null 2>&1; then
    echo "    OK  $command"
  else
    echo "    MISSING $command" >&2
  fi
done
# oh-my-zsh is sourced from ~/.zshrc as a script, not a binary,
# so check for its directory.
if [ -d "$HOME/.oh-my-zsh" ]; then
  echo "    OK  oh-my-zsh"
else
  echo "    MISSING oh-my-zsh" >&2
fi
# zoxide is a brew formula, so it should be on PATH already.
if command -v zoxide >/dev/null 2>&1; then
  echo "    OK  zoxide"
else
  echo "    MISSING zoxide" >&2
fi
# pipx apps live in ~/.local/bin, which is added to PATH only by
# the dotfiles' .zshrc in an interactive shell.
for app in virtualenv yt-dlp; do
  if [ -x "$HOME/.local/bin/$app" ]; then
    echo "    OK  $app (pipx)"
  else
    echo "    MISSING $app" >&2
  fi
done

echo ""
echo "### New Mac setup done. Open a new Terminal window to start using zsh. ###"
if [ -n "${BACKUP_DIR:-}" ]; then
  echo "    Shell files backed up from the move-aside live in: $BACKUP_DIR"
fi
