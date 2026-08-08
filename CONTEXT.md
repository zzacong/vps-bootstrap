# VPS Bootstrap Context

Provisioning a fresh Ubuntu VPS into a usable dev box via three root-shell scripts (`setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`) and a reference `zshrc.ubuntu`.

## Language

**Bootstrap**:
The three-step provisioning flow: create a sudo user, wire up SSH keys, then install packages/shell/dotfiles on a fresh Ubuntu host.
_Avoid_: Setup, provisioning (too generic for the scripts)

**New user**:
The sudo-capable account created by `setup-root.sh` that becomes the operator's normal login on the box.
_Avoid_: Admin, admin user

**Host key**:
The SSH keypair on the operator's *laptop*, whose public half is pasted into the new user's `authorized_keys` so password SSH can later be disabled.
_Avoid_: Client key, laptop key

**GitHub deploy key**:
The ed25519 keypair generated *on the server* for the new user; its public half is added to GitHub so the `yadm` dotfiles clone over SSH works.
_Avoid_: Server key, repo key

**Passphrase**:
The secret protecting the GitHub deploy key, required (no default), confirmed twice, and delivered to ssh-keygen/ssh-add via an SSH_ASKPASS helper so it never appears in argv or script source.
_Avoid_: Password, secret phrase

**Hardening drop-in**:
`/etc/ssh/sshd_config.d/50-hardening.conf`, the sshd config file that disables root and password login once key auth is proven.
_Avoid_: Hardening config, sshd config

**Askpass helper**:
A throwaway executable that cats a 0600 temp file holding the passphrase, consumed by OpenSSH via `SSH_ASKPASS`.
_Avoid_: Helper script, askpass script

**yadm bootstrap**:
The first `yadm clone` of `git@github.com:zzacong/dotfiles.git` on the new user, preceded by a backed-up move-aside of `/etc/skel` files so the clone doesn't collide.
_Avoid_: Dotfiles setup, yadm init

**Skel defaults**:
The `/etc/skel` files (`~/.zshrc`, `~/.bashrc`, …) OH-MY-ZSH and the shell write on first login; backed up rather than deleted so a failed yadm clone leaves a usable shell.
_Avoid_: Default shell files, rc files
