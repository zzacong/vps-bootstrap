# Machine Bootstrap Context

Provisioning a fresh machine into a usable dev box via two flows: the three-step VPS flow (`setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`) for a fresh Ubuntu host, plus `setup-squid.sh`, a standalone extract of setup-user.sh's optional Squid section used to re-run or fix just the proxy config; and the single-script Mac flow (`setup-mac.sh`) for a new MacBook. Both converge on the same shell (zsh + oh-my-zsh + starship), editor (neovim + vim-plug), Node (fnm), and yadm-managed dotfiles.

## Language

### Shared

**Bootstrap**:
The provisioning flow that turns a fresh machine into a usable dev box: create a login, wire up SSH keys, then install packages/shell/dotfiles. Three scripts on a VPS; one script on a Mac.
_Avoid_: Setup, provisioning (too generic for the scripts)

**Host key**:
The SSH keypair on the operator's own machine (laptop or Mac). On a VPS, its public half is pasted into the new user's `authorized_keys` so password SSH can later be disabled. On a fresh Mac, the key is generated *on the Mac*, its public half is added to GitHub so the yadm dotfiles clone works, and its passphrase is stored in the Keychain.
_Avoid_: Client key, Mac key, laptop key

**Passphrase**:
The secret protecting an SSH private key, required (no default), confirmed twice, and delivered to ssh-keygen/ssh-add via an SSH_ASKPASS helper so it never appears in argv or script source. Whether it persists is a per-key policy: the GitHub deploy key's passphrase is never stored (ADR-0001), the Mac host key's is stored in the Keychain (ADR-0002).
_Avoid_: Password, secret phrase

**Askpass helper**:
A throwaway executable that cats a 0600 temp file holding a passphrase, consumed by OpenSSH via `SSH_ASKPASS`.
_Avoid_: Helper script, askpass script

**yadm bootstrap**:
The first `yadm clone` of `git@github.com:zzacong/dotfiles.git` on the machine, preceded by a backed-up move-aside of the default shell files the OS or oh-my-zsh write, so the clone doesn't collide.
_Avoid_: Dotfiles setup, yadm init

### VPS flow

**New user**:
The sudo-capable account created by `setup-root.sh` that becomes the operator's normal login on the box.
_Avoid_: Admin, admin user

**GitHub deploy key**:
The ed25519 keypair generated *on the server* for the new user; its public half is added to GitHub so the `yadm` dotfiles clone over SSH works.
_Avoid_: Server key, repo key

**Hardening drop-in**:
`/etc/ssh/sshd_config.d/50-hardening.conf`, the sshd config file that disables root and password login once key auth is proven.
_Avoid_: Hardening config, sshd config

**Skel defaults**:
The `/etc/skel` files (`~/.zshrc`, `~/.bashrc`, …) OH-MY-ZSH and the shell write on first login; backed up rather than deleted so a failed yadm clone leaves a usable shell.
_Avoid_: Default shell files, rc files

### Mac flow

**Command Line Tools**:
Apple's Xcode Command Line Tools, the compiler toolchain Homebrew requires; installed via a one-click GUI dialog (`xcode-select --install`) before Homebrew.
_Avoid_: Xcode, CLT
