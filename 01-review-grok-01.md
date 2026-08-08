# Root User Setup Script for Ubuntu
Created: 08/08/2026, 14:52:08
Last Updated: 08/08/2026, 14:52:10
---

### User

audit these three bash scripts for me. they are intended to be used to run on a fresh ubuntu server vm or vps. 
They are intended to be run in this order: setup root, setup SSH, setup user.
review the scripts and also just for reference the zshrc config is also attached
Document all your findings in a report and write it out in Markdown format

[setup-root.sh](https://upoevdcxa3.ufs.sh/f/IN4OjmY4wMHBrcm8kChxjTyvf3uhLn8IAOWa92F1NWx5bVBOT3N1pWfK09bmdxMJn)
[zshrc.ubuntu](https://upoevdcxa3.ufs.sh/f/IN4OjmY4wMHBGyyV4ic09PfvvMnexTjnXztssB0xartgpnIuDUokHMkLcPdvFZIFXR)
[setup-ssh.sh](https://upoevdcxa3.ufs.sh/f/IN4OjmY4wMHB2lh7lUmiJpQuU3BRuL7n0l1wMr2VDm0xRRbdCrFW5ZERuzM3Y8dUbrd)
[setup-user.sh](https://upoevdcxa3.ufs.sh/f/IN4OjmY4wMHBciqc0uIpjxytiS2cWVYLWmEwFCmz1S3Ua2FOFN7vj1ldBPLEpbQrg31)

---

### Assistant (grok-4.5)

<details>
<summary>Reasoning</summary>

The user wants me to audit three bash scripts for setting up a fresh Ubuntu server, plus a zshrc for reference. I need to write a comprehensive security and quality audit report in Markdown format.

</details>

# Security & Quality Audit Report

**Scripts reviewed:** `setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`  
**Reference config:** `~/.zshrc`  
**Target environment:** Fresh Ubuntu 24.04+ VM/VPS  
**Intended order:** root → SSH → user  

---

## Executive summary

These scripts are well-structured, carefully commented, and mostly idempotent. The three-step flow (create user → install host key + generate GitHub key → packages/dotfiles/hardening) is sound. Several issues are serious enough to fix before using these on a real VPS: **hardcoded default credentials**, a **command-injection risk in the ssh-agent helper**, **weak default proxy credentials**, and a few correctness / lockout edge cases.

Findings are ordered by severity within each section.

---

## Critical / high severity

### 1. Hardcoded default SSH key passphrase (credentials in source)

**Where:** `setup-ssh.sh`, `setup-user.sh`

```bash
DEFAULT_SSH_PASS="Ddld1019."
```

**Why it matters:** Anyone with the script (git history, paste, shared VPS image, backup) knows the default passphrase for the server’s GitHub deploy key. If the operator presses Enter at the prompt, the key is protected by a publicly known secret. That key is used to clone private dotfiles and may later be reused for other GitHub access.

**Recommendations:**
- Remove the default entirely; require an interactive passphrase (or empty only if explicitly chosen).
- Prefer generating a random passphrase and printing it once, or using an unencrypted key only in tightly controlled environments.
- Never commit real passphrases; use env vars or a secrets prompt with no default.
- Rotate any keys already created with this default.

---

### 2. SSH_ASKPASS helper is vulnerable to injection / broken quoting

**Where:** `setup-user.sh`

```bash
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$SSH_KEY_PASS" > "$SSH_ASKPASS_HELPER"
```

**Why it matters:** The passphrase is interpolated into a shell script as a double-quoted string. A passphrase containing `"`, `$`, `` ` ``, `\`, or newlines can:
- break the helper,
- cause `ssh-add` to fail silently/oddly, or
- in worst cases execute unintended shell content when the helper runs.

**Recommendations:**
- Prefer `SSH_ASKPASS` that reads from a restricted file or env without embedding the secret in script source, e.g. write the passphrase to a `0600` file and have the helper `cat` that file.
- Or use `setsid`/`ssh-add` patterns that avoid embedding secrets in generated scripts.
- Ensure the temp file is always `0600` and removed on all exit paths (`trap`).

---

### 3. Weak / default Squid proxy credentials

**Where:** `setup-user.sh` (optional Squid block)

```bash
SQUID_USER="${SQUID_USER:-johnfire}"
SQUID_PASS="${SQUID_PASS:-johnfire}"
```

**Why it matters:** Default username/password are trivial and embedded in the script. If the operator accepts defaults and opens `3128/tcp` in UFW, the proxy becomes an open relay for anyone who guesses `johnfire`/`johnfire` (or reads the script). Open proxies are abused for spam, scraping, and pivoting.

**Recommendations:**
- No default password; require a strong one or generate random credentials and display once.
- Prefer IP allowlisting alone, or auth + IP, not weak auth on a public port.
- Consider binding Squid to localhost or a private interface unless remote use is required.
- Document that `3128` exposure has real abuse risk.

---

### 4. Possible SSH lockout if host key step is skipped

**Where:** `setup-ssh.sh` + `setup-user.sh` hardening

- If the user pastes nothing or an invalid key, `setup-ssh.sh` continues with a warning.
- `setup-user.sh` then disables password auth and root login unconditionally.

**Why it matters:** You can lock yourself out of a cloud VPS if you only had password/console access and never installed a working host pubkey.

**Recommendations:**
- Before hardening, verify that `authorized_keys` is non-empty and contains at least one valid key line.
- Optionally test `ssh -o BatchMode=yes` from a known-good path (harder on-box).
- Refuse to disable `PasswordAuthentication` unless a flag like `--i-have-working-keys` is set, or require interactive confirmation that lists the keys about to be trusted.
- Keep cloud provider serial/console recovery in the runbook.

---

## Medium severity

### 5. `passwd` is interactive and not idempotent-friendly

**Where:** `setup-root.sh`

```bash
passwd "$NEW_USER"
```

**Notes:** Fine for a manual bootstrap, but:
- Fails in non-interactive automation.
- On re-run, always forces a password change even when the user already exists.
- No quality guidance (length/complexity); weak passwords remain possible while password auth is still on (until step 3).

**Recommendations:** Document that step 1 is interactive; optionally support `chpasswd` from a prompted secret for controlled automation; remind operators that password auth stays open until step 3 completes.

---

### 6. GitHub host key trust via `ssh-keyscan` only

**Where:** `setup-user.sh`

```bash
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null
```

**Why it matters:** TOFU (trust on first use) without pinning. On a compromised network/DNS, the first run could trust a malicious host key. Errors are swallowed (`2>/dev/null`), and keys are appended repeatedly on re-runs (noise/duplicates).

**Recommendations:**
- Pin GitHub’s published SSH key fingerprints (compare `ssh-keygen -lf` against [GitHub’s docs](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)).
- Deduplicate `known_hosts` or use a dedicated file.
- Don’t hide `ssh-keyscan` failures.

---

### 7. Squid config insertion is fragile

**Where:** `setup-user.sh`

- Locates first `^http_access deny all$` and splices rules above it.
- Fallback appends to the live conf with `>>` **without sudo** in one branch:

```bash
cat "$BLOCK_FILE" >> /etc/squid/squid.conf
echo "http_access deny all" >> /etc/squid/squid.conf
```

**Why it matters:**
- That fallback will fail for a normal sudo user (permission denied) or, if somehow writable, is unsafe.
- Ubuntu Squid packs many `http_access` lines; ordering mistakes can open broader access than intended (e.g. relative to manager/localnet rules).
- No `squid -k parse` validation before restart.

**Recommendations:**
- Always write via `sudo` / `install` like the main path.
- Use a drop-in under `/etc/squid/conf.d/` if supported by the package.
- Run `sudo squid -k parse` before restart; abort on failure.
- Review final `http_access` order explicitly in the report/docs.

---

### 8. UFW “allow SSH” may not match a non-default SSH port

**Where:** `setup-user.sh`

```bash
sudo ufw allow ssh
```

If sshd is later moved off 22, or the cloud security group ≠ UFW, operators can lock themselves out. Currently scripts don’t change the SSH port (good), but the optional firewall section should say so.

---

### 9. `sudo` password caching and long script runtime

Step 3 runs many `sudo` commands over a long period (apt upgrade, sshd, optional UFW/Squid). If `timestamp_timeout` expires mid-script, a later `sudo` can prompt unexpectedly; with `set -e`, a failed sudo aborts—possibly after partial sshd hardening.

**Recommendations:** `sudo -v` at start and a background `sudo -v` refresher with `trap` cleanup, or document that the operator should stay present.

---

### 10. Secrets visible in process list (minor/medium)

```bash
ssh-keygen ... -N "$SSH_KEY_PASS"
```

Passphrase may appear in `/proc/*/cmdline` for a short window. Prefer empty `-N` and immediate re-key, or tools that read the passphrase from a fd without argv.

---

## Low severity / correctness

### 11. Username regex vs. Linux realities

```bash
[[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
```

- Rejects uppercase (often desired).
- Allows names that can still be problematic (e.g. very long, or colliding with system users if someone chooses `sync`, `nobody`—partially mitigated because `useradd` would fail / exist).
- Does not cap length (login.defs often 32).

Also: `useradd -G sudo` sets **only** supplementary group `sudo` at creation time (primary group is still a new usergroup by default on Ubuntu—OK). Good that you re-check membership later.

---

### 12. `read ... || true` masks Ctrl-D / empty input edge cases

Used consistently so Ctrl-D doesn’t trip `set -e`. Combined with defaults, this is intentional—but it makes it easy to accept insecure defaults (passphrase, proxy password) by accident.

---

### 13. oh-my-zsh install pipes remote script to shell

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
```

Same trust model for fnm, vim-plug, plugin git clones. Standard for bootstrap scripts; supply-chain risk remains.

**Recommendations:** Pin commit hashes/tags where possible; consider packaging via apt where available; verify checksums for critical installers.

---

### 14. fnm install + symlink assumptions

```bash
curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
ln -sf "$HOME/.local/share/fnm/fnm" "$HOME/.local/bin/fnm"
```

Path is conventional but not guaranteed forever. If install layout changes, `set -e` will fail later at `fnm install`—acceptable, but a version pin would be more reproducible.

---

### 15. `chsh` without validating zsh is listed in `/etc/shells`

Usually fine after `apt install zsh`. If `chsh` fails, the script aborts before dotfiles—OK. Minor: no explicit “zsh is installed” check beyond apt.

---

### 16. Removing skel files before yadm clone

```bash
rm -f "$HOME/.zshrc" "$HOME/.bashrc" ...
```

Correct for avoiding yadm collisions. If clone fails after `rm`, the user is left without shell rc until fixed—error message already hints at this. Consider backing up to `*.pre-yadm` instead of hard delete.

---

### 17. yadm branch hard-coded to `main`

```bash
yadm clone -b main "$DOTFILES_REPO"
```

Fine if the repo uses `main`; fails otherwise.

---

### 18. Neovim `PlugInstall` headless

```bash
nvim +'PlugInstall --sync' +qall
```

Can hang or error on first-run plugin builds, missing shared libs, or interactive prompts. Consider `nvim --headless` if supported by their config.

---

### 19. sshd hardening drop-in

```bash
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
```

Solid baseline. Notes:
- Ubuntu may also need `KbdInteractiveAuthentication no` (and legacy `ChallengeResponseAuthentication no`) so password-like methods don’t remain available.
- `PasswordAuthentication no` in a drop-in usually overrides, but verify with `sshd -T | grep -i password`.
- Restart pattern for socket-activated ssh is reasonable; confirm on 24.04 that `ssh.socket` + `ssh.service` names match the image (some still use `sshd.service`).

---

### 20. `grep -qw sudo` for group membership

Works; `id -nG` is space-separated. Rare locale/`id` quirks only. Prefer:

```bash
id -nG "$NEW_USER" | tr ' ' '\n' | grep -qx sudo
```

---

### 21. `authorized_keys` creation race/permissions

You `touch` then append then `chown`/`chmod 600`. If `touch` created the file as root, there is a brief window before chown—negligible on a single-admin bootstrap. Creating with `install -m 600 -o user -g user` is cleaner.

Host key line matching is exact (`grep -qxF`)—good against duplicates; whitespace-different same keys could duplicate—low risk.

---

### 22. Public key validation is prefix-only

```bash
case "$HOST_PUB_KEY" in ssh-ed25519*|...)
```

Doesn’t validate key material/base64. Enough to stop accidents; not a security boundary.

---

### 23. Idempotency gaps

| Step | Behavior |
|------|----------|
| User exists | Skip create, still run `passwd` |
| SSH key exists | Keep key (won’t rotate passphrase) |
| yadm exists | `yadm pull` |
| Squid passwords exist | Keep old file (prompts for new pass ignored) |
| Squid auth already in conf | Skip update |
| apt | Re-runs upgrade every time |

Mostly good; document “password file kept” clearly so operators don’t think they reset the proxy password.

---

### 24. `set -euo pipefail` vs. pipelines

Good overall. A few commands intentionally ignore failure (`systemctl restart ssh.service 2>/dev/null || true`). Ensure that doesn’t hide real sshd failures—consider `sshd -t` before restart and `systemctl is-active` after.

---

## Privacy / operational issues

### 25. Identity leakage in reference `~/.zshrc`

```bash
gitzzacong() { ... email "61817066+zzacong@users.noreply.github.com"; }
gitibm() { ... email "zac.ong@ibm.com"; }
```

Not a bug in the setup scripts, but the dotfiles repo pulled by the scripts contains personal/work identity helpers. On a shared or customer VPS, that may be undesirable. Ensure the dotfiles repo is appropriate for every machine you run this on.

### 26. Hostname in SSH key comment

```bash
-C "$NEW_USER@$(hostname)"
```

Fine; just be aware comments appear in GitHub SSH key UI.

### 27. Apt upgrade on first boot

Full `apt-get upgrade -y` can take a long time, reboot-require kernels, and surprise on minimal images. Acceptable for a personal VPS bootstrap; less ideal for immutable/fleet images.

---

## Alignment with attached `~/.zshrc`

The user script roughly matches zshrc expectations:

| zshrc dependency | setup-user coverage |
|------------------|---------------------|
| oh-my-zsh + spaceship theme path | Yes (`spaceship-prompt/spaceship`) |
| plugins: fnm, z, autosuggestions, syntax-highlighting | Plugins cloned; `z` is OMZ built-in; fnm binary installed |
| `EDITOR=nvim`, bat theme, aliases | From yadm dotfiles (not written by script) |
| `fd` / `bat` names | Symlinks from fdfind/batcat |
| `lsof` (`runp`) | Installed |
| pnpm / corepack | Not installed system-wide; `corepackup` function expects node (fnm LTS provides corepack)—OK if user runs it later |
| pipx argcomplete | Optional; pipx not installed by script |
| yadm aliases | yadm installed + repo cloned |

**Gaps / mismatches:**
1. **spaceship theme:** OMZ expects `ZSH_THEME="spaceship"` **or** a symlink  
   `themes/spaceship.zsh-theme → spaceship-prompt/spaceship.zsh-theme`.  
   Setting `ZSH_THEME="spaceship-prompt/spaceship"` works with some OMZ versions but is less standard; the usual bootstrap creates the symlink. Confirm after first login that the prompt loads.
2. **fnm OMZ plugin:** Requires `fnm` on PATH before OMZ loads; you put `~/.local/bin` on PATH in zshrc *after* OMZ in the attached file—actually in the attached zshrc, `eval "$(fnm env)"` is in user config after OMZ, and the `fnm` plugin is in the plugins list. The plugin may need `fnm` available early; your explicit `eval "$(fnm env)"` later usually saves you. Worth testing on a clean VM.
3. **Node LTS only:** No automatic `corepack enable` / pnpm activate—by design if dotfiles don’t do it.
4. **zshrc comments** mention `fd` dependency—symlink handles it.

---

## Script-by-script notes

### `setup-root.sh`

**Strengths:** Root check, username validation, idempotent user create, sudo group repair, clear next-step UX.

**Fix list:**
- Remove any future temptation to add defaults for passwords in-repo.
- Optionally skip `passwd` if user exists and `--reset-password` not passed.
- Validate username length and reserved names.

### `setup-ssh.sh`

**Strengths:** Resolves home via `getent`, correct `.ssh` modes, authorized_keys hygiene, ed25519 keygen as the target user.

**Fix list:**
- Drop default passphrase (critical).
- Abort or force explicit “continue without host key” confirmation.
- Don’t print only the pubkey—also print fingerprint for GitHub cross-check.
- Ensure `known_hosts` isn’t required here (it isn’t)—good.

### `setup-user.sh`

**Strengths:** Noninteractive apt, clear sectioning, ssh-agent for passphrase-protected keys, skel cleanup for yadm, hardening last, optional UFW/Squid, reboot notice.

**Fix list:**
- ASKPASS hardening + `trap` cleanup (critical).
- Pre-hardening authorized_keys check (critical).
- Squid defaults + conf write fallback + `squid -k parse` (high/medium).
- `KbdInteractiveAuthentication no`.
- Pin GitHub host keys.
- spaceship symlink if needed.
- `sudo -v` keep-alive.

---

## Threat model summary

| Threat | Current posture |
|--------|-----------------|
| Brute-force SSH after full run | Good (keys only, MaxAuthTries 3) |
| Root SSH | Disabled at end of step 3 |
| Stolen bootstrap scripts | **Bad** — default key/proxy secrets in source |
| MITM on first GitHub SSH | Moderate (unverified keyscan) |
| MITM on curl \| sh installers | Accepted supply-chain risk |
| Open proxy abuse | **High** if Squid defaults + UFW 3128 |
| Operator lockout | **Real** if host pubkey skipped |
| Dotfiles private repo exposure | Depends on GitHub key scope/passphrase strength |

---

## Recommended immediate changes (priority order)

1. **Remove `DEFAULT_SSH_PASS` and Squid default password** (and rotate any deployed secrets/keys).
2. **Rewrite SSH_ASKPASS** so the passphrase is not embedded via string interpolation; add `trap 'rm -f ...' EXIT`.
3. **Refuse sshd password disable** if `authorized_keys` is empty/missing.
4. **Add `KbdInteractiveAuthentication no`** to the sshd drop-in; validate with `sshd -T`.
5. **Fix Squid fallback** to use sudo; validate config; no default creds; consider not opening 3128 globally.
6. **Pin/verify GitHub SSH host keys.**
7. **Confirm spaceship theme path/symlink** against the real OMZ version on 24.04.
8. **Add `sudo` keep-alive** for long step 3.
9. Optional: pin oh-my-zsh / fnm installer versions; backup skel files instead of `rm`; `sshd -t` before restart.

---

## Positive practices already in place

- `set -euo pipefail` consistently  
- Clear root-vs-user separation across three steps  
- Hardening **after** host key install and proven GitHub SSH (yadm clone)  
- Drop-in sshd config rather than editing main `sshd_config`  
- ed25519 keys; `chmod 700/600` on `.ssh`  
- Idempotent-ish clones and package steps  
- `DEBIAN_FRONTEND=noninteractive`  
- UFW allows SSH before enable  
- Useful operator messaging and ordered runbook  

---

## Suggested test plan (before production VPS)

1. Snapshot or use a throwaway VM.  
2. Run all three steps with **non-default** passphrases and a real host pubkey.  
3. Open a **second** SSH session before step 3 hardening; confirm key login still works after hardening.  
4. Confirm `sudo sshd -T | egrep 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'`.  
5. Fresh login: zsh, spaceship, `fd`, `bat`, `nvim`, `fnm`, `node`.  
6. Re-run each script; confirm no destructive surprises.  
7. If testing Squid: verify unauthorized IPs without password fail; with bad password fail; conf parses.  
8. Intentionally skip host key on a clone VM and confirm the script **stops** before disabling passwords (after you add that guard).

---

## Conclusion

The bootstrap design is thoughtful and above average for personal VPS setup scripts. **Do not use as-is on an internet-facing host** until hardcoded passphrases/proxy defaults are removed, the ASKPASS helper is fixed, and sshd hardening is gated on a verified `authorized_keys`. After those fixes—plus the medium-priority sshd/Squid/GitHub TOFU items—this is a solid personal Ubuntu 24.04 bootstrap chain consistent with the attached zshrc/dotfiles workflow.


---
