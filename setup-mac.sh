#!/bin/zsh
# ============================================================
# setup-mac.sh  (new Mac bootstrap: packages, shell, dotfiles)
#
# Assumes the manual prerequisites from the README are done:
#   1. Xcode Command Line Tools  (xcode-select --install)
#   2. Homebrew                  (the official installer)
#   3. 1Password installed, signed in, with
#      Settings -> Developer -> SSH agent enabled, holding a key
#      whose public half is on the GitHub account that owns the
#      dotfiles.
# The script asserts all three up front and prints the exact
# command to run when one is missing.
#
# Run on a fresh MacBook, as the user you'll use day-to-day:
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-mac.sh)"
#
# Installs the shell env (zsh + oh-my-zsh + plugins + starship),
# brew formulae and casks, Node via fnm, Rust via rustup, pipx
# apps, and then yadm-clones the dotfiles.
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
# SSH URL, authenticated by the 1Password SSH agent checked in
# the preflight; no key is generated on this Mac.
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
# 0. Preflight: the manual prerequisites
# ------------------------------------------------------------
# Everything below assumes these three are done. Check them here
# so the script fails in the first second, not after installing
# twenty formulas.
#
# Command Line Tools provide git and the compiler toolchain.
if ! xcode-select -p >/dev/null 2>&1 || [ ! -d "$(xcode-select -p)" ]; then
  echo "Xcode Command Line Tools are not installed." >&2
  echo "    Run: xcode-select --install" >&2
  echo "    Click Install in the dialog, wait for it to finish, then re-run this script." >&2
  exit 1
fi
require_command git

# Homebrew: /opt/homebrew on Apple Silicon, /usr/local on Intel.
if [ -x /opt/homebrew/bin/brew ]; then
  HOMEBREW_PREFIX=/opt/homebrew
elif [ -x /usr/local/bin/brew ]; then
  HOMEBREW_PREFIX=/usr/local
else
  echo "Homebrew is not installed." >&2
  echo "    Run:" >&2
  echo '      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"' >&2
  echo "    then re-run this script." >&2
  exit 1
fi
# Put brew on PATH for the rest of this script's shell.
eval "$("$HOMEBREW_PREFIX/bin/brew" shellenv)"

# 1Password's agent socket lives in its group container, which only
# exists once the app has run. A licensed, signed-in app is not
# something a bootstrap can install, so check for the container and
# fail with the checklist rather than at the clone with a bare
# publickey error.
OP_AGENT_SOCK="$HOME/.1password/agent.sock"
OP_AGENT_TARGET="$HOME/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"
if [ ! -d "$(dirname "$OP_AGENT_TARGET")" ]; then
  echo "1Password is not set up on this Mac." >&2
  echo "    Install and sign in to 1Password, then enable" >&2
  echo "    Settings -> Developer -> SSH agent, holding a key whose public half" >&2
  echo "    is on the GitHub account owning $DOTFILES_REPO. Re-run when done." >&2
  exit 1
fi

# ------------------------------------------------------------
# 1. Shell environment: oh-my-zsh + plugins + starship
# ------------------------------------------------------------
# --unattended skips the interactive prompts and does NOT change
# the default shell (zsh is already the default on macOS, checked
# in step 7). The installer hard-exits 1 if the target directory
# already exists, so guard it to stay re-runnable.
#
# Mirror the installer's own resolution so the guard and the
# install agree: with ZDOTDIR set (and not $HOME) oh-my-zsh goes
# to $ZDOTDIR/ohmyzsh, otherwise $ZSH or $HOME/.oh-my-zsh. This
# matters because --unattended sets OVERWRITE_CONFIRMATION=no, so
# a guard that misses re-runs the installer and replaces the
# dotfiles' .zshrc with the stock template without asking.
echo "### Installing oh-my-zsh ###"
if [ -n "${ZDOTDIR:-}" ] && [ "$ZDOTDIR" != "$HOME" ]; then
  ZSH_DIR="${ZSH:-$ZDOTDIR/ohmyzsh}"
else
  ZSH_DIR="${ZSH:-$HOME/.oh-my-zsh}"
fi
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
ZSH_CUSTOM_DIR="${ZSH_CUSTOM:-$ZSH_DIR/custom}"

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
# 2. Brew formulae and casks
# ------------------------------------------------------------
# The core set mirrors the VPS flow (editor, pager tools, lf,
# yadm for dotfiles) plus the extra tools this machine actually
# uses day-to-day. git is here to upgrade a tool macOS already
# has: the CLT's build lags Homebrew's by several minor versions,
# and brew's PATH wins from here on. macOS ships the real
# `fd`/`bat` names, so no symlink dance like Ubuntu's fdfind/batcat.
FORMULAS=(
  neovim
  bat
  ripgrep
  fd
  lf
  yadm
  git
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
  oha
  pipx
  pnpm
  fnm
  starship
  zoxide
  zig
  go
  azure-cli
)
echo "### Installing brew formulas: ${FORMULAS[*]} ###"
brew install "${FORMULAS[@]}"

# Verify the installed binaries actually landed (Homebrew can
# rename or drop formulas in future releases). git-delta ships
# the `delta` binary, azure-cli ships `az`.
echo "### Verifying installed commands ###"
MISSING=""
for cmd in nvim bat rg fd lf yadm git gh lazygit delta jq uv bun btop chafa glow fastfetch ffmpeg oha pipx pnpm fnm starship zoxide zig go az; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "    Missing command: $cmd" >&2
    MISSING="$MISSING $cmd"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the brew install, then re-run." >&2
  exit 1
fi

# The two Nerd Fonts cover the terminal and nvim statusline; keycastr
# is the keystroke overlay; blackhole-2ch is a virtual audio device.
# Fonts install per-user, keycastr is an app, and blackhole-2ch
# installs a system pkg, so it asks for your password and needs a
# reboot before the device appears.
CASKS=(
  font-caskaydia-cove-nerd-font
  font-geist-mono-nerd-font
  keycastr
  blackhole-2ch
)
echo "### Installing brew casks: ${CASKS[*]} ###"
brew install --cask "${CASKS[@]}"

# Casks install apps, fonts, and drivers rather than commands, so
# verify against brew's own record instead of `command -v`.
echo "### Verifying installed casks ###"
MISSING=""
for cask in "${CASKS[@]}"; do
  if ! brew list --cask "$cask" >/dev/null 2>&1; then
    echo "    Missing cask: $cask" >&2
    MISSING="$MISSING $cask"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the brew install, then re-run." >&2
  exit 1
fi

# ------------------------------------------------------------
# 3. Neovim: vim-plug + undodir
# ------------------------------------------------------------
# vim-plug: the standard plugin manager for (n)vim.
echo "### Installing vim-plug for neovim ###"
curl -fLo "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/site/autoload/plug.vim" --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# init.vim sets `undodir` here; make sure it exists or nvim
# errors on every undo write.
mkdir -p "$HOME/.local/share/nvim/undodir"

# ------------------------------------------------------------
# 4. Node via fnm (node version manager, via Homebrew)
# ------------------------------------------------------------
# ~/.zshrc lists the `fnm` plugin and pnpm, so node is needed.
# fnm comes from brew here (no curl installer + symlink dance
# like the VPS, where apt has no fnm). pnpm is installed via
# brew too -- not corepack, which newer Node LTS no longer ships.
echo "### Installing latest LTS Node via fnm ###"
eval "$(fnm env)"
fnm install --lts
fnm default lts-latest

# Put fnm's node on PATH for this shell and confirm node actually
# works. pnpm is validated by the brew formula check above.
eval "$(fnm env)"
node --version

# ------------------------------------------------------------
# 5. Rust via rustup
# ------------------------------------------------------------
# The official installer from https://rust-lang.org/tools/install/.
# -y answers the confirmation prompt. --no-modify-path leaves shell
# files alone (rustup would otherwise edit ~/.zshenv), keeping the
# dotfiles the only owner of shell config; the dotfiles must source
# `$HOME/.cargo/env` so cargo is on PATH in future shells.
if [ -x "$HOME/.cargo/bin/rustup" ]; then
  echo "### Rust already installed, skipping ###"
else
  echo "### Installing Rust via rustup ###"
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
fi
# Put cargo on PATH for this shell so the check below works.
if [ -f "$HOME/.cargo/env" ]; then
  . "$HOME/.cargo/env"
fi
MISSING=""
for cmd in cargo rustc; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "    Missing command: $cmd -- check the rustup install." >&2
    MISSING="$MISSING $cmd"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the rust install, then re-run." >&2
  exit 1
fi

# ------------------------------------------------------------
# 6. pipx apps (Python CLIs, each in its own venv)
# ------------------------------------------------------------
# pipx (from brew above) installs Python CLIs into ~/.local/pipx
# and exposes them on PATH via ~/.local/bin.
echo "### Installing pipx apps ###"
pipx install yt-dlp
# pipx exposes apps in ~/.local/bin, which the script's own
# non-interactive PATH won't include (that export lives in the
# dotfiles' .zshrc), so verify by file, not `command -v`.
for app in yt-dlp; do
  if [ ! -x "$HOME/.local/bin/$app" ]; then
    echo "    Missing pipx app: $app" >&2
    exit 1
  fi
done

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
# 8. 1Password SSH agent (the GitHub credential)
# ------------------------------------------------------------
# Like the VPS flow, this Mac keeps no GitHub key of its own: the
# operator's 1Password key signs the dotfiles clone (ADR-0006).
# 1Password's agent listens on a socket inside the app's group
# container; ~/.1password/agent.sock is a stable short path to
# it, and ~/.ssh/config points IdentityAgent at that path. A
# fresh Mac has neither, so create both before the clone. The
# container itself was asserted in the preflight.
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
# 9. Dotfiles
# ------------------------------------------------------------
# yadm clones over SSH; pre-seed known_hosts so the first
# connection to github.com doesn't prompt for host confirmation
# and hang in a non-interactive context. Pin GitHub's published
# ed25519 host key (https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
# instead of trusting unauthenticated `ssh-keyscan` output.
# $HOME/.ssh was created (mode 700) in step 8.
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

# ------------------------------------------------------------
# 10. Git config (baseline)
# ------------------------------------------------------------
# Runs after the yadm clone so a .gitconfig from the dotfiles is
# already the base and these values layer on top. `git config
# --global` is idempotent and leaves settings not named here
# untouched, so a re-run changes nothing once the values match.
# delta comes from the git-delta formula in step 2.
echo "### Writing baseline git config ###"
git config --global user.name "zzacong"
git config --global user.email "61817066+zzacong@users.noreply.github.com"
git config --global core.pager "delta"
git config --global interactive.diffFilter "delta --color-only"
git config --global delta.navigate "true"
git config --global merge.conflictStyle "zdiff3"

MISSING=""
for setting in \
  "user.name=zzacong" \
  "user.email=61817066+zzacong@users.noreply.github.com" \
  "core.pager=delta" \
  "interactive.diffFilter=delta --color-only" \
  "delta.navigate=true" \
  "merge.conflictStyle=zdiff3"; do
  key="${setting%%=*}"
  expected="${setting#*=}"
  if [ "$(git config --global --get "$key")" != "$expected" ]; then
    echo "    Unexpected value for $key" >&2
    MISSING="$MISSING $key"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Wrong git config:$MISSING -- check 'git config --global --list'." >&2
  exit 1
fi

# ------------------------------------------------------------
# 11. pnpm global CLIs
# ------------------------------------------------------------
# Runs after the yadm clone so a ~/.npmrc from the dotfiles is
# already in place for private scoped packages. pnpm is from brew
# and node from fnm, both installed above.
PNPM_GLOBALS=(
  @earendil-works/pi-coding-agent
  @opencode/cli
  @zzacong/fleet
  ccusage
  skills
  vercel
)
echo "### Installing pnpm global packages: ${PNPM_GLOBALS[*]} ###"
pnpm add -g "${PNPM_GLOBALS[@]}"

# pnpm's global bin dir is not on this shell's PATH (the dotfiles
# export it for interactive shells), so verify against pnpm's own
# installed list rather than `command -v`.
echo "### Verifying pnpm global packages ###"
PNPM_GLOBAL_LIST="$(pnpm list -g --depth 0 2>/dev/null || true)"
MISSING=""
for pkg in "${PNPM_GLOBALS[@]}"; do
  if ! printf '%s\n' "$PNPM_GLOBAL_LIST" | grep -qF "$pkg"; then
    echo "    Missing global package: $pkg" >&2
    MISSING="$MISSING $pkg"
  fi
done
if [ -n "$MISSING" ]; then
  echo "    Missing:$MISSING -- fix the pnpm install, then re-run." >&2
  exit 1
fi

# ------------------------------------------------------------
# 12. Neovim plugins
# ------------------------------------------------------------
# Install the plugins listed in ~/.config/nvim/init.vim. This
# needs init.vim to exist (from the yadm clone above).
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
for cmd in zsh nvim fd bat rg lf yadm gh fnm node npm pnpm starship zoxide zig go az cargo rustc; do
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "    OK  $cmd"
  else
    echo "    MISSING $cmd" >&2
  fi
done
# oh-my-zsh is sourced from ~/.zshrc as a script, not a binary,
# so check for its directory.
if [ -d "$ZSH_DIR" ]; then
  echo "    OK  oh-my-zsh"
else
  echo "    MISSING oh-my-zsh" >&2
fi
# pipx apps live in ~/.local/bin, which is added to PATH only by
# the dotfiles' .zshrc in an interactive shell.
for app in yt-dlp; do
  if [ -x "$HOME/.local/bin/$app" ]; then
    echo "    OK  $app (pipx)"
  else
    echo "    MISSING $app" >&2
  fi
done

echo ""
echo "### New Mac setup done. Open a new Terminal window to start using zsh. ###"
echo "    blackhole-2ch installs a virtual audio device; reboot before using it."
if [ -n "${BACKUP_DIR:-}" ]; then
  echo "    Shell files backed up from the move-aside live in: $BACKUP_DIR"
fi
