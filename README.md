# Machine Bootstrap

Two provisioning flows, both converging on the same shell (zsh + oh-my-zsh + starship), editor (neovim + vim-plug), Node (fnm), and yadm-managed dotfiles:

- **[VPS flow](#vps-flow)** — a fresh Ubuntu VPS (24.04+), three scripts in order.
- **[Mac flow](#mac-flow)** — a new MacBook, one script after three manual prerequisites.

Everything user-level lives in `zzacong/dotfiles`, managed by yadm; this repo only *bootstraps* the machine.

## VPS flow

Turns a fresh Ubuntu VPS (24.04+) into a usable dev box. You run three scripts in order on the box: create a sudo user, wire up SSH keys, then install everything else — shell, editor, node, dotfiles — and lock SSH down.

```
setup-root.sh  →  setup-ssh.sh  →  setup-user.sh
(as root)         (as root)         (as the new user)
```

The whole thing is idempotent-ish and safe to re-run: everything checks before it changes, and the risky steps (turning off password SSH, cloning dotfiles over your shell files) are gated behind a confirmation and backed up first.

Each step fetches the script with `bash -c "$(curl -fsSL <url>)"`. That form keeps your terminal as the script's stdin, so the interactive prompts (usernames, SSH keys, passphrases, confirmations) work normally — unlike `curl … | bash`, where the prompts would read from the pipe instead.

## What you end up with

- A sudo-capable **new user** (default `zacong`) as your only login on the box
- Key-only SSH: your 1Password **host key** for logging in, forwarded to the box for the dotfiles clone — no private keys ever live on the server
- **zsh + oh-my-zsh** with autosuggestions, syntax highlighting, and the starship prompt
- **neovim** with vim-plug (plugins come from your dotfiles), **fd**, **bat**, **ripgrep**, **lf**, **yadm**
- **Node** (latest LTS) via **fnm**, with **pnpm** (brew on Mac, `npm i -g` on Linux)
- Optionally: UFW firewall and a Squid proxy
- Your **dotfiles** cloned from `git@github.com:zzacong/dotfiles.git` — everything user-level lives there, so this repo only *bootstraps* the box

## Prerequisites

- A fresh Ubuntu 24.04+ VPS you can log into as `root` (cloud providers give you a root shell or a sudo-capable default user — use `sudo bash` if you're not root yet)
- 1Password's SSH agent running on your host, holding a key whose public half is already on GitHub (Settings → SSH and GPG keys) — one key for both logging in and GitHub access
- Agent forwarding enabled for the VPS (`ssh -A`, or `ForwardAgent yes` in `~/.ssh/config`)

## Step 1 — create the user (as root)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-root.sh)"
```

**What it does:** asks for a username (default `zacong`), creates that sudo user with a home dir, and sets a temporary password. It refuses reserved system-account names and never silently reconfigures an existing account — it asks before resetting a password.

That password is temporary. It's the only way in until step 2 installs your host key, and it gets disabled in step 3.

## Step 2 — wire up SSH keys (as root)

Still as root on the box (you can't log in as the new user remotely yet):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-ssh.sh)"
```

**What it does:** installs your host machine's public key — you paste one line of your host's `ssh-add -L` output (your 1Password key), it's validated with `ssh-keygen -lf`, and written to the new user's `authorized_keys`. A valid key is *required*; without it you'd have no way in after password auth dies. Nothing is generated on the server: GitHub access in step 3 uses the same 1Password key forwarded from your host, whose public half is already on GitHub — there is no add-a-key-to-GitHub step.

Then from your laptop, log in WITH agent forwarding:

```bash
ssh -A zacong@<host-ip-or-name>
```

(or `ForwardAgent yes` for this host in `~/.ssh/config`).

## Step 3 — install packages, shell, dotfiles (as the new user)

Logged in as the new user via SSH with agent forwarding (`ssh -A` — without it the dotfiles clone has no GitHub credentials):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-user.sh)"
```

**What it does**, roughly in order:

1. **System packages** — `zsh neovim fd-find bat ripgrep lf yadm git curl lsof unzip python3` via sudo (you'll be asked for your password on the first sudo). Optionally a full `apt upgrade` first.
2. **Shell env** — oh-my-zsh (unattended), the custom plugins it doesn't bundle (zsh-completions, zsh-autosuggestions, you-should-use, fast-syntax-highlighting), zoxide, starship prompt (installed via its official script).
3. **Neovim** — vim-plug, plus symlinks `fdfind`→`fd` and `batcat`→`bat` (Ubuntu renames both even on 24.04).
4. **Node via fnm** — latest LTS, made the default.
5. **zsh as the default shell** — via `chsh`.
6. **Dotfiles (yadm bootstrap)** — backs up the **skel defaults** (`~/.zshrc`, `~/.bashrc`, …) into `~/.bootstrap-backup-*` rather than deleting them, so a failed clone leaves a usable shell. Verifies the **forwarded agent** (`$SSH_AUTH_SOCK` set, keys visible) and that GitHub accepts it as the account owning the dotfiles (never starts a local ssh-agent — that would hide the forwarded one), pre-seeds GitHub's pinned host key, then `yadm clone`s your dotfiles. Finally runs vim-plug against your `init.vim`.
7. **sshd hardening (the last mandatory step)** — writes the **hardening drop-in** `/etc/ssh/sshd_config.d/50-hardening.conf` (`PermitRootLogin no`, `PasswordAuthentication no`, key-only, `AllowUsers` scoped to you). It refuses to run if there's no key in `authorized_keys`, asks you to confirm key login works from a *second terminal*, validates with `sshd -t` before reloading, and handles socket-activated sshd.
8. **(Optional) UFW firewall** — deny incoming by default, allow outgoing; SSH always allowed first, optionally ports 80/443.
9. **(Optional) Squid proxy** — caching HTTP(S) proxy on port 3128, locked down with an htpasswd file (and optionally one whitelisted IP). Config is parse-validated before restart and inserted before Squid's default `deny all`. Available standalone as `setup-squid.sh` if you want to re-run or fix just the proxy config without redoing step 3.

If a reboot is pending (kernel update), it tells you.

## Mac flow

Turns a new MacBook into a usable dev box. Unlike the VPS there is no root/user/key split: the Mac is your own machine, so everything runs as your normal login. It happens rarely, but when it does the script is safe to re-run.

Three things the script cannot install itself. Do these first.

**1. Xcode Command Line Tools.** Homebrew needs the compiler toolchain:

```bash
xcode-select --install
```

Click Install in the dialog and wait for it to finish.

**2. Homebrew.** The official installer works on both Apple Silicon and Intel:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

If the installer tells you to add a `shellenv` line to your shell profile, put that line in your dotfiles, not `~/.zprofile`. The script moves the shell files Homebrew wrote aside when it clones the dotfiles, so a line left in `~/.zprofile` disappears.

**3. 1Password.** Install and sign in, turn on **Settings → Developer → SSH agent**, and make sure the key's public half is already on the GitHub account that owns the dotfiles. The script keeps no GitHub key of its own (ADR-0006), so this is its only credential.

Then run the script:

```bash
zsh -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-mac.sh)"
```

The Mac flow is **zsh, not bash**. A fresh Mac's `/bin/zsh` is always a recent 5.x, while its `/bin/bash` is frozen at 3.2 from 2007 until Homebrew replaces it, so zsh is the only guaranteed-modern interpreter. `zsh -c "$(curl …)"` also keeps your terminal as the script's stdin, same as the VPS flow's `bash -c`, so any prompts work.

**What it does**, in order. The first step is a preflight that asserts the three prerequisites above, so a missing one stops the script immediately rather than after it installs a batch of packages.

1. **Shell env:** oh-my-zsh (unattended), the custom plugins it doesn't bundle (zsh-completions, zsh-autosuggestions, you-should-use, fast-syntax-highlighting), and the starship prompt. zsh is already the default on macOS, so no `chsh` is needed.
2. **Brew formulae:** `neovim bat ripgrep fd lf yadm` (the VPS core) plus `git gh lazygit git-delta jq uv bun btop chafa glow fastfetch ffmpeg oha pipx pnpm fnm starship zoxide zig go azure-cli`. `git` upgrades the CLT's older build, and macOS ships the real `fd`/`bat` names, so no Ubuntu-style symlinks.
3. **Brew casks:** `font-caskaydia-cove-nerd-font font-geist-mono-nerd-font keycastr`. The fonts install per-user and keycastr is an app, so this batch needs no password.
4. **Neovim:** vim-plug, plus the undodir `init.vim` expects.
5. **Node via fnm:** installed through Homebrew, latest LTS made the default.
6. **Rust via rustup:** the official installer, run with `--no-modify-path` so it doesn't edit shell files. rustup still writes `~/.cargo/env`, which the dotfiles' `.zshrc` already sources.
7. **pipx apps:** `yt-dlp`.
8. **1Password SSH agent:** links `~/.1password/agent.sock` to the agent socket in 1Password's group container and writes `~/.ssh/config` with `IdentityAgent ~/.1password/agent.sock`. No key is generated on the Mac.
9. **Dotfiles (yadm bootstrap):** backs up the shell files the tools wrote, pre-seeds GitHub's pinned host key, proves the agent authenticates to GitHub, then `yadm clone`s your dotfiles.
10. **Git config:** sets `user.name`, `user.email`, delta as the pager, and `merge.conflictStyle = zdiff3`. These layer on top of the dotfiles' `.gitconfig`, so a tracked one there stays the base.
11. **pnpm global CLIs:** `@earendil-works/pi-coding-agent @opencode/cli @zzacong/fleet ccusage skills vercel`. This runs after the clone so a `~/.npmrc` from the dotfiles is available to private scoped packages. pnpm 10+ blocks dependency build scripts by default, so the install passes `--allow-build` for the four that have one — `@opencode/cli`'s postinstall is what unpacks its binary, and skipping it leaves a broken `opencode`.
12. **Neovim plugins:** runs vim-plug against the `init.vim` the clone brought in.
13. **BlackHole virtual audio device:** `blackhole-2ch` last, since it installs a system pkg. It asks for your password, and the device needs a reboot. Keeping it at the end means a declined password cannot abort the dotfiles and tooling steps.

## Coming back after three months

- **This repo is only the bootstrap.** Your shell, editor, aliases, and git config are not here — they're in `zzacong/dotfiles`, managed by yadm on the box (`yadm status`, `yadm push`). This repo is what you'd run on the *next* fresh VPS.
- **Don't skip steps.** Step 3 needs your 1Password agent forwarded (`ssh -A`) with its key already on the GitHub account owning the dotfiles — the pre-clone check fails fast otherwise. The scripts prompt and validate rather than assuming.
- **Anything you change on a box** (zshrc tweaks, new aliases, nvim plugins) belongs in the dotfiles repo, not here.
- Re-running any step is safe; the guardrails (validation, backups, second-terminal confirmations) exist so a mistake can't lock you out of the box.

## Repository layout

| File | Purpose |
|---|---|
| `setup-root.sh` | Step 1 (VPS) — create the sudo user (as root) |
| `setup-ssh.sh` | Step 2 (VPS) — host key install (as root) |
| `setup-user.sh` | Step 3 (VPS) — packages, shell, dotfiles, hardening, optional firewall/proxy (as new user) |
| `setup-squid.sh` | Standalone extract of setup-user.sh's optional Squid section, for re-running/fixing just the proxy config |
| `setup-mac.sh` | Mac — shell, brew formulae and casks, fnm/Node, rustup, pipx, 1Password agent, base git config, pnpm globals, dotfiles (as the user). Prerequisites: CLT, Homebrew, 1Password |
| `CONTEXT.md` | Shared vocabulary for the scripts (host key, forwarded agent, …) |
| `docs/adr/` | Design decision records (e.g. 1Password agent forwarding, the Mac agent policy) |
