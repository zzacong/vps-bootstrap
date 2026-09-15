# Machine Bootstrap Context

Provisioning a fresh machine into a usable dev box via two flows: the three-step VPS flow (`setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`) for a fresh Ubuntu host, plus `setup-squid.sh`, a standalone extract of setup-user.sh's optional Squid section used to re-run or fix just the proxy config; and the Mac flow (`setup-mac.sh`) for a new MacBook, which assumes three manual prerequisites (Command Line Tools, Homebrew, 1Password). Both converge on the same shell (zsh + oh-my-zsh + starship), editor (neovim + vim-plug), Node (fnm), and yadm-managed dotfiles.

## Language

### Shared

**Bootstrap**:
The provisioning flow that turns a fresh machine into a usable dev box: create a login, wire up SSH keys, then install packages/shell/dotfiles. Three scripts on a VPS; one script on a Mac.
_Avoid_: Setup, provisioning (too generic for the scripts)

**Host key**:
The 1Password-managed SSH keypair on the operator's own machine. On a VPS, one line of the host's `ssh-add -L` output is pasted into the new user's `authorized_keys` so password SSH can later be disabled. On a Mac, the same key authenticates the `yadm` dotfiles clone through 1Password's local agent (ADR-0006). Neither flow generates a key.
_Avoid_: Client key, Mac key, laptop key

**Passphrase**:
The secret protecting an SSH private key. No bootstrap script handles one: the VPS flow authenticates through the forwarded agent (ADR-0005) and the Mac flow through the local 1Password agent (ADR-0006). Both keys are 1Password-managed, so 1Password prompts for the passphrase when it needs it.
_Avoid_: Password, secret phrase

**Askpass helper**:
A throwaway executable that cats a 0600 temp file holding a passphrase, consumed by OpenSSH via `SSH_ASKPASS`. No script uses one anymore: ADR-0005 removed it from the VPS flow and ADR-0006 from the Mac flow. The term survives in those ADRs as the record of how generated keys were handled.
_Avoid_: Helper script, askpass script

**yadm bootstrap**:
The first `yadm clone` of `git@github.com:zzacong/dotfiles.git` on the machine, preceded by a backed-up move-aside of the default shell files the OS or oh-my-zsh write, so the clone doesn't collide.
_Avoid_: Dotfiles setup, yadm init

**Oh-my-zsh**:
The zsh plugin framework installed by the bootstrap scripts (its official curl installer, `--unattended`). The dotfiles' `.zshrc` sources `oh-my-zsh.sh` and loads whatever the `plugins=(...)` array names; plugins oh-my-zsh doesn't bundle are cloned by the scripts into `~/.oh-my-zsh/custom/plugins` before the dotfiles land.
_Avoid_: Plugin manager, shell framework

**Custom plugin**:
A zsh plugin that doesn't ship with oh-my-zsh and must be cloned into `~/.oh-my-zsh/custom/plugins` by the bootstrap scripts: zsh-completions, zsh-autosuggestions, zsh-you-should-use, fast-syntax-highlighting. Sits on the machine, not in the dotfiles repo.
_Avoid_: Third-party plugin, manual plugin

### VPS flow

**New user**:
The sudo-capable account created by `setup-root.sh` that becomes the operator's normal login on the box.
_Avoid_: Admin, admin user

**Forwarded agent**:
The host's 1Password SSH agent, visible on the VPS via `$SSH_AUTH_SOCK` when connected with `ssh -A` (or `ForwardAgent yes`). It is the VPS's only GitHub credential for the `yadm` dotfiles clone — no keypair is generated on the server, and no script-local ssh-agent may be started (it would overwrite `$SSH_AUTH_SOCK` and hide the forwarded agent). `setup-user.sh` asserts the agent is present, its keys visible, and GitHub accepts one as the dotfiles repo owner before cloning.
_Avoid_: Agent forwarding (the mechanism), SSH agent (ambiguous with a local one)

**Hardening drop-in**:
`/etc/ssh/sshd_config.d/50-hardening.conf`, the sshd config file that disables root and password login once key auth is proven.
_Avoid_: Hardening config, sshd config

**Skel defaults**:
The `/etc/skel` files (`~/.zshrc`, `~/.bashrc`, …) oh-my-zsh and the shell write on first login; backed up rather than deleted so a failed yadm clone leaves a usable shell.
_Avoid_: Default shell files, rc files

### Mac flow

**Command Line Tools**:
Apple's Xcode Command Line Tools, the compiler toolchain Homebrew requires. A manual prerequisite of the Mac flow: the operator runs `xcode-select --install` (a one-click GUI dialog) before the script, and the script's preflight asserts it is present.
_Avoid_: Xcode, CLT

**Manual prerequisite**:
A Mac-flow requirement the script does not install itself: Command Line Tools, Homebrew, and a signed-in 1Password with its SSH agent enabled. The README lists the commands; the script's preflight asserts each and exits with the command to run when one is missing.
_Avoid_: Dependency, requirement

**Agent socket link**:
`~/.1password/agent.sock`, a symlink `setup-mac.sh` creates to the SSH agent socket inside 1Password's macOS group container (`~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`), so `~/.ssh/config` can name the short, stable path. Needed because macOS sets `SSH_AUTH_SOCK` to its own agent rather than 1Password's (ADR-0006).
_Avoid_: Agent socket, ssh config entry
