# Audit: setup-root.sh, setup-ssh.sh, setup-user.sh (+ .zshrc, init.vim)

## 🔴 Critical bug: `systemctl restart ssh` won't reliably apply hardening on 24.04

Since Ubuntu 22.10+, `sshd` is **socket-activated**. On a fresh 24.04 box,
`ssh.socket` (not `ssh.service`) owns port 22, and `ssh.service` is only
spawned on-demand. `systemctl restart ssh` often works as a compat alias,
but the **config reload path is unreliable** — new settings can fail to
apply without a `daemon-reload` first (see LP #2069041).

**Fix:**

```diff
 sudo tee /etc/ssh/sshd_config.d/50-hardening.conf >/dev/null <<'EOF'
 PermitRootLogin no
 PasswordAuthentication no
 PubkeyAuthentication yes
 EOF
-sudo systemctl restart ssh
+sudo systemctl daemon-reload
+sudo systemctl restart ssh.socket
+sudo systemctl restart ssh.service 2>/dev/null || true
```

This matters most — right now you can't be fully sure `PasswordAuthentication`
is actually disabled.

---

## 🟠 Robustness gaps in `setup-user.sh`

1. **`.zshrc` PATH ordering bug** — the `fnm` check (`command -v fnm`) runs
   *before* `~/.local/bin` is added to `$PATH`. Since `fnm` only exists as a
   symlink there, this can silently fail on a fresh login shell. Move the
   "Add PATHs" block above the `fnm`/`pipx` checks.

2. **yadm clone can collide with skel files** — `useradd -m` populates
   `/etc/skel` files (`.bashrc`, `.profile`, `.bash_logout`). If your
   dotfiles repo tracks any of these, `yadm clone` refuses to overwrite them
   and fails — but the script doesn't check the exit code before running
   `PlugInstall`. Add explicit `rm -f` for tracked skel files, or check
   `yadm clone`'s exit status.

3. **No `known_hosts` entry for GitHub before `yadm clone`** — first SSH
   connection to `github.com` prompts for confirmation, which will hang in
   non-interactive contexts. Add before the clone:

   ```bash
   mkdir -p ~/.ssh
   ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
   ```

4. **`apt-get upgrade -y` without `DEBIAN_FRONTEND=noninteractive`** — can
   still trigger interactive dialogs (conffile prompts, `needrestart`).
   Add near the top of the script:

   ```bash
   export DEBIAN_FRONTEND=noninteractive
   ```

5. **fnm installer edits `.bashrc` by default** — `curl | bash` (no
   `--skip-shell`) appends an `eval "$(fnm env)"` block to `~/.bashrc`,
   which you don't manage. Use:

   ```bash
   curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
   ```

---

## 🟡 Minor / good-to-know

- `useradd -m -s /bin/bash -G sudo` with idempotent guards — fine as-is.
- `passwd` runs before key-based access exists — intentional bridging step,
  just worth a comment that password SSH login is possible until the final
  hardening step runs.
- Private key with **no passphrase** for GitHub (`setup-ssh.sh`) is a
  reasonable tradeoff for unattended `yadm`/git operations, but flag it as
  a security tradeoff — if the box is compromised, that key is usable
  without a passphrase.
- `PermitRootLogin no` + `PasswordAuthentication no` is a good baseline;
  consider also adding `MaxAuthTries 3` and `LoginGraceTime 20`.
- UFW/Squid sections are correctly gated and don't risk lockout (ssh
  allowed first; Squid stays loopback-only by default). No issues.
- **nvim config**: consistent with installed plugins (`vim-polyglot`,
  `commentary`, `fugitive`, `onehalf`, `lightline`). `undodir` matches the
  directory created in step 3. No bugs found.
- **`.zshrc`**: plugin order (`zsh-syntax-highlighting` last) is correct
  per upstream recommendation. Aliases, pnpm, and corepack setup are
  self-consistent with what `setup-user.sh` installs.

---

## Priority order to fix

1. `ssh.socket` restart/reload (real functional bug on 24.04)
2. PATH ordering before `fnm` check in `.zshrc`
3. `known_hosts` for `github.com` before yadm clone
4. `DEBIAN_FRONTEND=noninteractive` for unattended apt upgrade
5. `--skip-shell` for fnm installer (cosmetic)