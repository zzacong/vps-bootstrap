# Root User Setup Script for Ubuntu
Created: 08/08/2026, 14:51:51
Last Updated: 08/08/2026, 14:51:52
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

### Assistant (claude-sonnet-5)

<details>
<summary>Reasoning</summary>

I'm going through these shell scripts to identify security vulnerabilities, bugs, and logic issues. Starting with setup-root.sh, I see it uses proper error handling with `set -euo pipefail` and has reasonable username validation, but I'm noticing a critical problem: there's a hardcoded default password being used across multiple scripts that needs to be addressed.

Moving into setup-ssh.sh, I'm finding several security concerns. The script properly validates that it runs as root and checks user existence, but there's a significant issue with how it handles the SSH key passphrase—passing it directly to ssh-keygen via command line argument means it's visible in the process list to other users on the system, which is a real vulnerability. Combined with the hardcoded default passphrase problem, this is a major finding.

In setup-user.sh, the same default passphrase exposure issue appears multiple times, and the script displays the literal default password in the prompt text every time it runs, which means it gets logged in terminal history and scrollback. The rest of the setup looks reasonable—it runs as the new user, uses noninteractive mode for package management, installs the expected dependencies for the zshrc configuration, and handles the oh-my-zsh and plugin setup idempotently.

There's a minor inefficiency where fnm reinstalls even if already present, and the SSH key generation logic has a flaw: if the key was already created by setup-ssh.sh, the SSH_KEY_PASS variable won't be set, but the script later tries to use it anyway with a fallback read prompt that again exposes the default password.

The SSH_ASKPASS_HELPER creates a temporary file with the plaintext passphrase (using mktemp which defaults to 600 permissions, so it's not world-readable, though there's a brief race condition before chmod +x runs). The script then deletes existing shell config files like ~/.zshrc and ~/.bashrc to replace them with dotfiles. The setup script validates SSH key access by requiring successful login as the new user before proceeding, which confirms the host key is properly configured. For Squid, the SSH_CLIENT environment variable might not be available in non-SSH sessions, so it falls back to "none" - acceptable. The default password "johnfire" is hardcoded and displayed in the prompt, same issue as before with credentials shown to the user. The heredoc variable expansion looks correct, but there's a bigger security concern: the scripts display default passwords in prompts, which means they get logged in terminal history and any recording tools. More critically, they hardcode the same weak passphrase "Ddld1019." across multiple scripts for both SSH keys and authentication, which is a major vulnerability if these scripts are ever shared or stored in a repository—users who just press enter during setup end up with a known password instead of being forced to create their own.

Additionally, passing the passphrase via the `-N` flag to ssh-keygen exposes it briefly in the process list to other local users; using SSH_ASKPASS or interactive input would be safer. The same password exposure issue affects the squid configuration, and while the interactive `passwd` command in setup-root.sh works fine for manual runs, it could hang if executed non-interactively through automation.

Home directory permissions default to 750 on Ubuntu after useradd, which is appropriate. When reading the host's public key via `read -rp`, the entire line including spaces gets captured correctly into a single variable, and the grep validation with `-qxF` properly matches the full key. The setup still needs to verify that the key doesn't already exist before adding it.

There are a few edge cases worth noting: ssh-keygen could fail if the key file exists partially, and setup-ssh.sh accepts NEW_USER input without validating its format like setup-root.sh does, which could allow injection of unusual usernames. The host key verification step lacks an explicit safety check—it just assumes the documented manual process worked, though adding a validation like confirming at least one valid authorized_keys entry exists before disabling password auth would be safer. The shell change command is idempotent so it runs fine repeatedly, and the Squid configuration handles empty rules gracefully. There's also a consistency issue where `DEFAULT_SSH_PASS` serves dual purposes as both the SSH key passphrase default and a privacy concern in prompts. The setup-ssh.sh script validates against deprecated key types like ssh-dss, which OpenSSH already rejects by default, so it's not a real concern. The zshrc configuration aliases vi to nvim and sets up the spaceship-prompt theme, which aligns with the expected oh-my-zsh directory structure. The EDITOR variable is set to nvim, which requires nvim to be installed. The corepack enable pnpm syntax is valid for newer versions. There's a potential redundancy with the fnm plugin—the oh-my-zsh fnm plugin might already be calling fnm env, so the manual eval statement could be duplicating that initialization.

The PATH exports look reasonable with deduplication checks for PNPM_HOME, but reloading the zshrc file causes PATH entries to accumulate without deduplication—each source adds duplicates. This could be fixed with typeset -U path or a conditional check. Also missing are symlink handlers for fd-find and bat in the zshrc configuration.

Looking at the security side, variable quoting looks solid throughout—usermod and id commands properly quote the NEW_USER variable, and the setup-ssh.sh script handles HOST_PUB_KEY safely within case pattern matching without needing quotes on the variable side.

The main security issues I'm flagging are the hardcoded default passphrase baked into multiple scripts (risky if this dotfiles repo ends up public), echoing that secret in prompts, and passing the passphrase as a CLI argument to ssh-keygen where it's visible to other local users via ps. The read -rsp approach does protect against bash history logging since it suppresses echoing, though there's no explicit history disabling mentioned.

But there's a critical bug with the temporary SSH_ASKPASS_HELPER file: if ssh-add fails for any reason, the set -e flag causes the script to exit immediately before reaching the cleanup rm command, leaving the plaintext passphrase sitting in /tmp indefinitely. I should use a trap handler to guarantee the temp file gets deleted even on error. The template file created via mktemp also has similar cleanup concerns depending on TMPDIR permissions.

Looking at the sshd_config hardening settings now - the heredoc syntax is correct with quoted EOF to prevent variable expansion, and the MaxAuthTries and LoginGraceTime values are reasonable. One thing I notice is there's no AllowUsers directive to restrict SSH access to just the new user, which would be a good additional hardening step since PermitRootLogin is already disabled. The UFW firewall rules are being set up next.

For the UFW configuration, SSH on port 22 is allowed from anywhere without IP restrictions - I should note that while this is functional, restricting it to known good IPs would be tighter security if that's feasible. Similarly, the Squid proxy on port 3128 is opened to all sources at the firewall level even though Squid itself has IP-based ACLs and password authentication. The Squid config shows that if an IP is in the allowed list, it bypasses authentication entirely since that rule comes before the auth requirement - so there's a defense-in-depth opportunity to restrict the firewall rule to specific IPs if they're known.

The password file for Squid's htpasswd is only created if it doesn't already exist, so rerunning the script won't update the password - just a behavior to document. Also, the setup script installs UFW even though it's typically pre-installed on Ubuntu Server, but that's harmless.

The prompt for UFW setup only accepts "y" as input, not the full word "yes" - a minor UX quirk. The overall structure and logic are solid with good comments throughout. The getent command to retrieve the user's home directory works fine if it succeeds, and the quoting around paths like the zsh plugins directory is handled correctly.

There's a security consideration with setup-ssh.sh: the ssh-keygen command passes the passphrase via the -N flag in the command arguments, which means it's briefly visible in the process list when spawned as root via sudo -u. On a single-owner VPS this is low risk, but it's worth noting as a hardening point. Also, since DEFAULT_SSH_PASS is reused across both setup-ssh.sh and setup-user.sh, a user hitting enter twice would end up with the same weak passphrase for both key generations. Given that the repo references github.com/zzacong/dotfiles and mentions the specific default user "zacong", there's a question about whether this is intended to be public on GitHub.

If these scripts were ever committed to a public repository with the hardcoded password included, that's a critical security incident. The password "Ddld1019." looks like a real personal password with complexity (contains a dot and digits), which is concerning if it's been shared in this conversation or committed anywhere publicly. I need to flag this as the top priority finding and recommend immediate password rotation, since sharing actual production secrets in scripts is a severe risk.

Looking at the consistency between the scripts, the division of labor makes sense—setup-root.sh handles user and password creation while setup-ssh.sh creates the .ssh directory as root. The sudoers configuration is also appropriate since the sudo group typically requires a password for apt operations. The conditional check using `-eq 0` for root verification is fine stylistically.

I notice there's no explicit trap handler for cleaning up temporary files, which would be a good addition. More importantly, I'm spotting a potential bug in the SSH key setup logic—there's a check for whether the key exists, and if not, it prompts for a passphrase and generates the key. But then later it tries to load the key into ssh-agent and checks if the passphrase variable is set, except there's a typo where it reads into `SSH_KEY_PAS` instead of `SSH_KEY_PASS`, which would cause the passphrase to not be found when needed.

The flow itself is logically sound for the normal case where the key already exists from a prior setup, but the ssh-agent process spawned during the script will persist as a background process even after the script exits—just killing the shell environment won't terminate it, so there should be an explicit cleanup or trap handler to kill the agent process.

Also need to verify that nvim's plugin installation command will work, since it depends on vim-plug being properly initialized in the config and having internet access to fetch the plugins.

Checking the dependency ordering: the fd/bat symlink setup runs independently before the Node/fnm section, so that's fine. The apt package list doesn't include things like htop or wget, but those aren't required by the zshrc configuration. Git is already listed in the packages, and since the package install happens before the oh-my-zsh plugin cloning step, the ordering is correct—git will be available when needed.

Yadm also requires git, which is already handled. Curl is in the apt list for the oh-my-zsh installer script, and unzip is there for the fnm binary extraction. The package names for bat and fd-find are correct for Ubuntu. Now I'm organizing all the findings into a structured markdown report with sections for severity levels and a per-file breakdown.

I'm identifying critical issues: the hardcoded default passphrase "Ddld1019." appears in both setup-ssh.sh and setup-user.sh, which is a serious secret exposure risk if this script ends up in any repository. The passphrase is also echoed in plaintext prompts, exposing it to terminal logs, screen recordings, and session history.

Beyond that, there are several high-severity problems: the ssh-agent process spawned during setup never gets terminated, leaving the decrypted private key sitting in memory indefinitely; the passphrase gets passed directly as a CLI argument to ssh-keygen where it's momentarily visible to other local users through process listings; and if ssh-add fails, the temporary file containing the plaintext passphrase isn't cleaned up before the script exits, leaving the secret on disk.

On the medium side, the setup accepts deprecated DSA keys without validation, there's no automated check that SSH authentication actually works before password login gets disabled (relying entirely on manual operator steps), and the firewall rules for SSH and Squid are completely unrestricted rather than scoped to specific source IPs.

There's also no `AllowUsers` or `AllowGroups` directive in the SSH hardening config, so any local account could attempt key-based authentication, and the `NEW_USER` input validation is inconsistent between scripts — setup-ssh.sh doesn't validate it the way setup-root.sh does, which is a minor defense-in-depth gap.

On the informational side, `~/.zshrc` unconditionally appends to `$PATH` without deduplication, so repeated sourcing creates duplicate entries; the oh-my-zsh `fnm` plugin and manual `eval` block might double-initialize fnm (harmless but redundant); and setup-user.sh reruns fnm installation and key generation every time instead of checking if they already exist like other steps do. The Squid password and config changes are only applied once, which is fine but worth noting.
</details>

# Security & Correctness Audit — `setup-root.sh` / `setup-ssh.sh` / `setup-user.sh` / `.zshrc`

## ⚠️ Immediate Action Required

**`DEFAULT_SSH_PASS="Ddld1019."` appears hardcoded in both `setup-ssh.sh` and `setup-user.sh`.** This looks like a real password, not a placeholder. It has now been:
- Written into plaintext script source (likely committed to your dotfiles/setup repo).
- Pasted into this conversation.

**Rotate this password/passphrase immediately** wherever it's used, and never hardcode real secrets as script defaults — see Finding #1 below for the fix.

---

## Critical

### 1. Hardcoded default secret shared across scripts
`setup-ssh.sh` and `setup-user.sh` both define:
```bash
DEFAULT_SSH_PASS="Ddld1019."
```
If this file ever lives in a repo (private or public), the secret is permanently compromised (git history). It also means every box you provision with the default gets the *same* weak, known passphrase protecting the GitHub deploy key.

**Fix:** remove the default entirely. Require an explicit passphrase (or explicitly support an empty/no-passphrase key if that's the real intent) instead of silently falling back to a known string:
```bash
read -rsp "    Passphrase for the new SSH key (required): " SSH_KEY_PASS
[ -n "$SSH_KEY_PASS" ] || { echo "Passphrase cannot be empty" >&2; exit 1; }
```

### 2. Default password echoed in cleartext to the terminal
Every prompt that shows the default reveals it verbatim:
```bash
read -rsp "    Passphrase for the new SSH key [$DEFAULT_SSH_PASS]: " ...
read -rp  "    Proxy password [johnfire]: " ...
```
Even though `-s` suppresses echoing of *user input*, the bracketed default text is printed as part of the prompt string itself — visible in terminal scrollback, screen recordings/shares, tmux logs, CI logs, etc. This defeats the purpose of using `-s` at all.

**Fix:** never print real secrets in a prompt; use a generic placeholder (`[press Enter for a random passphrase]`) or generate a random one with `openssl rand -base64 24` when the user doesn't supply one, then display *that* once so it can be recorded securely.

---

## High

### 3. Orphaned `ssh-agent` left running with the private key loaded
```bash
eval "$(ssh-agent -s)"
...
ssh-add "$HOME/.ssh/id_ed25519"
```
The comment claims "the agent only lives as long as this script does," but that's not true — `ssh-agent -s` daemonizes itself; it isn't a child of the script's shell and isn't killed when the script exits. This leaves a background agent holding the decrypted private key in memory indefinitely.

**Fix:**
```bash
trap 'kill "$SSH_AGENT_PID" 2>/dev/null || true' EXIT
```
right after `eval "$(ssh-agent -s)"`.

### 4. Passphrase passed as a CLI argument to `ssh-keygen`
```bash
sudo -u "$NEW_USER" ssh-keygen -t ed25519 -N "$SSH_KEY_PASS" ...
```
Command-line arguments are visible (briefly) to any other local user via `ps aux` / `/proc/<pid>/cmdline`. Low risk on a single-tenant VPS, but avoidable — use the same `SSH_ASKPASS` technique already used later for `ssh-add`, or `ssh-keygen`'s support for reading from a file descriptor.

### 5. Plaintext passphrase file not cleaned up on failure
```bash
SSH_ASKPASS="$SSH_ASKPASS_HELPER" SSH_ASKPASS_REQUIRE=force ssh-add "$HOME/.ssh/id_ed25519"
rm -f "$SSH_ASKPASS_HELPER"
```
Under `set -euo pipefail`, if `ssh-add` fails (e.g. wrong passphrase), the script exits immediately and **never reaches the `rm -f`**, leaving a file containing the plaintext passphrase sitting in `/tmp`.

**Fix:**
```bash
trap 'rm -f "$SSH_ASKPASS_HELPER"' EXIT
```
set immediately after creating the helper file.

---

## Medium

### 6. Legacy/insecure key type accepted
`setup-ssh.sh`'s validation allows `ssh-dss*` (DSA) as a valid pasted public key. DSA is deprecated and disabled by default in modern OpenSSH — drop it from the accepted pattern list.

### 7. No automated proof that key-based login works before disabling password auth
Step 7 of `setup-user.sh` disables `PasswordAuthentication` based purely on the *comment's assumption* that you already logged in as the new user over SSH (true if you followed the documented flow exactly). There's no in-script check. A safer approach: verify `authorized_keys` is non-empty and/or prompt for explicit confirmation ("Have you successfully logged in via SSH key? [y/N]") before writing the hardening drop-in.

### 8. Firewall rules are unrestricted by source IP
```bash
sudo ufw allow ssh
...
sudo ufw allow 3128/tcp
```
Both open to `0.0.0.0/0`. Squid already has IP/password ACLs, but defense-in-depth would scope the UFW rule too, e.g. `sudo ufw allow from "$SSH_CLIENT_IP" to any port 22`.

### 9. No `AllowUsers`/`AllowGroups` in the sshd hardening drop-in
Only `PermitRootLogin no` / `PasswordAuthentication no` are set. Any other local account with an authorized key (now or in future) can still authenticate. Consider adding `AllowUsers "$NEW_USER"` to the drop-in.

### 10. Inconsistent username validation
`setup-root.sh` validates `NEW_USER` against a regex; `setup-ssh.sh` takes the same kind of input but doesn't validate it before using it in `getent`/`id`/paths. Low risk (bad input just fails those lookups), but add the same regex check for consistency and clearer error messages.

---

## Low / Informational

### 11. `PATH` grows on every `~/.zshrc` reload
```bash
export PATH="/usr/local/sbin:$PATH"
export PATH="$PATH:$HOME/.local/bin"
```
Unlike the `PNPM_HOME` block (which checks for duplicates via `case ":$PATH:" in ...`), these two lines have no dedup guard, so sourcing `~/.zshrc` repeatedly (e.g. via the `reload` alias) keeps appending duplicates. Use `typeset -U path` near the top of the file, or wrap these in the same dedup pattern.

### 12. Possible double-initialization of `fnm`
The `fnm` oh-my-zsh plugin is loaded **and** `~/.zshrc` separately runs `eval "$(fnm env)"`. Depending on the plugin's own implementation this may run `fnm env` twice per shell start. Harmless but redundant — pick one.

### 13. No idempotency guard for the fnm installer
Most steps in `setup-user.sh` check "already exists, skipping" — the `fnm` install step doesn't:
```bash
curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell
```
Re-running the script always re-downloads/reinstalls. Not harmful, just inconsistent with the rest of the script's style.

### 14. Squid config/password changes are silently skipped on re-run
```bash
if [ -f /etc/squid/passwords ]; then
  echo "    Password file already exists, keeping it."
```
If you re-run the script intending to change the proxy password/IP, nothing happens. Fine as documented behavior, but worth a one-line note in the prompt ("re-run has no effect if already configured — edit /etc/squid manually to change").

### 15. UFW prompt only accepts `y`, not `yes`
Minor UX nit — not a bug, but user-friendliness could be improved with a case-insensitive `^y(es)?$` match.

---

## Things Done Well

- Consistent `set -euo pipefail` and clear "must run as root/must NOT run as root" guards at the top of each script.
- Good re-run safety almost everywhere (existence checks before `useradd`, `git clone`, key generation, yadm bootstrap, etc.).
- Sensible staged design that deliberately keeps password auth enabled until the SSH key path and dotfiles clone are both proven to work — this genuinely prevents most lockout scenarios.
- Uses an `sshd_config.d/` drop-in rather than editing the main `sshd_config` — clean and reversible.
- `squid.conf` is backed up before modification, and the auth block is inserted via line-anchored splicing rather than a risky `sed -i`.
- Correct, minimal `chown`/`chmod` discipline on all `.ssh` material.
- `DEBIAN_FRONTEND=noninteractive` correctly prevents apt from hanging on conffile prompts during unattended runs.

---

## Priority Summary

| Priority | Finding |
|---|---|
| 🔴 Critical | Hardcoded real secret in scripts (#1), secret echoed in prompts (#2) |
| 🟠 High | Orphaned ssh-agent (#3), passphrase visible via `ps` (#4), askpass temp file leak on failure (#5) |
| 🟡 Medium | DSA key acceptance (#6), no verification before disabling password auth (#7), unrestricted firewall rules (#8), missing `AllowUsers` (#9), unvalidated username input (#10) |
| ⚪ Low | PATH dedup (#11), fnm double-init (#12), missing idempotency guard (#13), silent skip on Squid re-run (#14), UFW prompt UX (#15) |


---
