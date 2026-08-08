# Root User Setup Script for Ubuntu
Created: 08/08/2026, 14:47:01
Last Updated: 08/08/2026, 14:47:32
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

### Assistant (gpt-5.6-luna)

<details>
<summary>Reasoning</summary>

**Reviewing Squid Configuration**

I'm examining the Squid configuration file at `/etc/squid/squid.conf`. It likely contains `http_access deny all`, possibly with comments. I should think about whether to append my rules after the existing `http_access deny all` line. If it’s already denying all, then those new rules might never get executed. I'll need to ensure that I'm following the right process to avoid breaking things. It seems like a bit of a puzzle!**Resolving script setup issues**

I'm noticing a script ordering issue while setting up SSH. It looks like I need to generate a key and add it to GitHub, but I also have to consider that there’s an existing password reset involved. I need to make sure the steps are in the right order to avoid confusion. Overall, I want to ensure everything is set up smoothly for the SSH configuration without any hiccups!**Evaluating security concerns**

I’m thinking about potential security weaknesses related to SSH and symlinks on a fresh server. If an authorized file is a symlink attack, it could be a risk for the root user despite it being okay generally. I wonder if I should disable root `passwd` and how user selection happens without confirmation. There's also a clipboard issue and no TTY reading to consider. I need to compile this into a markdown report.
</details>

# Audit Report: Ubuntu VPS Bootstrap Scripts

## Scope

This audit covers:

1. `setup-root.sh`
2. `setup-ssh.sh`
3. `setup-user.sh`
4. The supplied `~/.zshrc`

The scripts are intended to run in this order:

```text
setup-root.sh
setup-ssh.sh
setup-user.sh
```

The audit considers security, reliability, idempotency, portability across Ubuntu 24.04+ systems, and operational recovery.

## Executive summary

The overall structure is sensible, and the ordering is mostly appropriate:

- Create the user first.
- Install the host SSH key before disabling password authentication.
- Configure the user environment afterward.
- Harden SSH near the end.

However, I would not run these scripts unchanged on an Internet-facing VPS. The most important issues are:

### Critical or high-risk issues

1. **Hardcoded SSH key passphrase**
   - The same default private-key passphrase is embedded in two scripts.
   - Anyone who obtains the scripts can potentially unlock generated private keys.
   - The passphrase should be removed from source control and entered interactively.

2. **Hardcoded and weak Squid credentials**
   - The default proxy username and password are embedded in the script.
   - The proxy can potentially be exposed to the public Internet.
   - Opening port `3128/tcp` globally with UFW is especially risky.

3. **SSH hardening is not validated before restart**
   - The script writes an SSH configuration and immediately restarts SSH.
   - It does not run `sshd -t` or verify the effective configuration.
   - A syntax error or unexpected existing configuration could cause loss of access.

4. **Password authentication may not actually be fully disabled**
   - `KbdInteractiveAuthentication` is not disabled.
   - Depending on PAM and the existing SSH configuration, password-like interactive authentication may remain available.

5. **Unsafe SSH host-key acquisition**
   - `ssh-keyscan github.com` is used without independently verifying GitHub's host key.
   - A DNS, routing, or interception attack could cause the server to trust a malicious host key.

6. **The Squid configuration can fail open operationally**
   - If the expected `http_access deny all` anchor is absent, the generated allow rules are appended after existing rules.
   - Earlier deny rules may therefore prevent authentication from working.
   - The script also accepts insufficiently validated IP input.

7. **`setup-user.sh` can terminate unexpectedly when not run through SSH**
   - With `set -u`, this line fails if `SSH_CLIENT` is unset:

     ```bash
     SSH_CLIENT_IP="${SSH_CLIENT%% *}"
     ```

## Severity guide

| Severity | Meaning |
|---|---|
| Critical | Could expose credentials, create an open service, or cause serious compromise |
| High | Could lock out the administrator or materially weaken security |
| Medium | Reliability, portability, or security issue requiring attention |
| Low | Minor maintainability or usability issue |

---

# 1. Findings applying to all scripts

## 1.1 No transaction or recovery strategy

All scripts use:

```bash
set -euo pipefail
```

This is useful, but it also means a failure halfway through can leave the server partially configured.

Examples:

- The user is created, but the SSH key installation fails.
- Packages are upgraded, but shell setup fails.
- SSH is hardened, but the firewall configuration fails.
- The dotfiles clone changes several files before a later command fails.

The scripts are partly idempotent, but not consistently so.

### Recommendation

Add:

- Clear phase markers.
- Explicit validation before destructive changes.
- A cleanup trap for temporary files and agents.
- A final status summary.
- An explicit recovery section in the output.

For critical changes such as SSH hardening:

1. Write the configuration.
2. Validate it.
3. Inspect the effective configuration.
4. Reload rather than restart where possible.
5. Test a second login.
6. Only then disable password authentication.

---

## 1.2 External downloads are trusted without verification

The scripts download and execute content directly from the Internet:

```bash
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
```

They also download:

- `vim-plug`
- The `fnm` installer
- Multiple Git repositories
- GitHub host keys

HTTPS protects against some network attacks, but it does not protect against:

- A compromised upstream repository.
- A compromised GitHub account.
- A changed branch or mutable installer.
- A compromised CDN or certificate authority.

### Recommendation

For a security-sensitive bootstrap:

- Pin releases or commit hashes.
- Verify checksums or signatures where available.
- Avoid executing an unreviewed script directly from `curl`.
- Prefer Ubuntu packages where they are sufficiently current.
- Consider storing reviewed installers in a controlled repository.

---

## 1.3 The scripts assume the invoking user has a normal primary group

Several commands use:

```bash
"$NEW_USER:$NEW_USER"
```

This is normally correct for users created by `useradd`, but it is not guaranteed for an existing user. An existing account could have:

- A different primary group.
- A group name that does not match the username.
- A nonstandard home directory.

### Recommendation

Resolve the actual primary group:

```bash
USER_GROUP="$(id -gn "$NEW_USER")"
```

Then use:

```bash
chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh"
```

---

# 2. Audit of `setup-root.sh`

## 2.1 Resetting an existing user's password is dangerous

The script says it is idempotent, but it always runs:

```bash
passwd "$NEW_USER"
```

If the username already exists, the script resets that account's password without confirmation.

This could accidentally modify:

- An existing administrator.
- A service account.
- A user with an important password-based recovery method.

### Severity: High

### Recommendation

Either reject existing users:

```bash
if id "$NEW_USER" >/dev/null 2>&1; then
  echo "User already exists; refusing to modify it." >&2
  exit 1
fi
```

Or ask explicitly whether the password should be changed.

---

## 2.2 Existing system users are not distinguished from normal users

The validation only confirms that the account exists or can be created. It does not verify:

- UID range.
- Login shell.
- Home directory.
- Whether the account is a service account.
- Whether it is already an administrator.

### Severity: Medium

### Recommendation

For a new-user bootstrap, refuse existing accounts unless explicitly approved. At minimum, display:

```bash
id "$NEW_USER"
getent passwd "$NEW_USER"
```

and ask for confirmation before changing it.

---

## 2.3 Username validation is reasonable but incomplete

This validation is generally safe:

```bash
[[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]
```

However, it does not enforce:

- A maximum length.
- That the name is not `root`.
- That the username is not a reserved or unsuitable system account.

Ubuntu's account-name limits may also be more restrictive than the regular expression.

### Recommendation

Use `useradd --badname` only deliberately, not as a workaround. Consider rejecting reserved names and checking the platform's account-name constraints.

---

## 2.4 No explicit password quality or non-empty check

`passwd` handles password entry interactively, but the script does not ensure the account receives a strong password or that password setup succeeds in a useful way for unattended execution.

This is less important if password authentication is reliably disabled later, but the password exists during the initial setup period.

### Recommendation

- Explain that the password is temporary.
- Require a strong password.
- Disable password authentication as soon as key-based login is confirmed.
- Consider locking the password after key-only access is verified:

```bash
passwd -l "$NEW_USER"
```

Only do this after confirming that sudo and SSH key access work.

---

## 2.5 No check that sudo is installed and functional

The script adds the user to the `sudo` group but does not verify:

```bash
sudo -u "$NEW_USER" sudo -n true
```

A fresh Ubuntu installation normally includes sudo, but minimal images may not.

### Recommendation

Check for the package and verify group membership after starting a new login session. Group membership changes do not affect an already-running session.

---

## 2.6 User-facing next steps are ambiguous

The final message says:

```text
Then log out, log in as $NEW_USER from your host machine
```

But `setup-ssh.sh` must be run before that, and it must be run as root. The sequence should explicitly say:

1. Run `setup-root.sh` as root.
2. Run `setup-ssh.sh` as root.
3. Add the generated GitHub key.
4. Test host-to-server SSH login in a second terminal.
5. Log in as the new user.
6. Run `setup-user.sh`.

---

# 3. Audit of `setup-ssh.sh`

## 3.1 Hardcoded SSH key passphrase

This is the most serious issue in the script:

```bash
DEFAULT_SSH_PASS="..."
```

The same default appears in `setup-user.sh`.

The passphrase is:

- Stored in plaintext in the script.
- Displayed in the prompt.
- Reused across servers unless overridden.
- Potentially committed to version control.
- Embedded into a temporary askpass helper later.

### Severity: Critical

### Recommendation

Do not provide a default passphrase in the script. Prompt without displaying a default:

```bash
read -rsp "Passphrase for the new SSH key: " SSH_KEY_PASS
echo
```

Prompt twice and verify both entries match:

```bash
read -rsp "Passphrase: " SSH_KEY_PASS
echo
read -rsp "Confirm passphrase: " SSH_KEY_PASS_CONFIRM
echo

if [[ "$SSH_KEY_PASS" != "$SSH_KEY_PASS_CONFIRM" ]]; then
  echo "Passphrases do not match." >&2
  exit 1
fi
```

If the supplied passphrase has ever been used on a real system, rotate it.

---

## 3.2 Host public-key validation only checks the prefix

The validation accepts any line beginning with a recognized key type:

```bash
ssh-ed25519*
ssh-rsa*
ecdsa-sha2-*
```

This does not verify that the remainder is a valid base64-encoded public key.

### Severity: Medium

### Recommendation

Validate using `ssh-keygen`:

```bash
if ! printf '%s\n' "$HOST_PUB_KEY" | ssh-keygen -lf - >/dev/null 2>&1; then
  echo "Invalid SSH public key." >&2
  exit 1
fi
```

Depending on the OpenSSH version, parsing from standard input may require a temporary file. A robust approach is:

```bash
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT

printf '%s\n' "$HOST_PUB_KEY" >"$KEY_FILE"

if ! ssh-keygen -lf "$KEY_FILE" >/dev/null 2>&1; then
  echo "Invalid SSH public key." >&2
  exit 1
fi
```

---

## 3.3 The script permits continuing without a host key

If no host key is pasted, the script continues:

```bash
echo "No key pasted; you'll need another way in"
```

The next step eventually disables password authentication. If no alternate access method exists, this can lock out the user.

### Severity: High

### Recommendation

For an Internet-facing system, fail rather than continue:

```bash
if [[ -z "$HOST_PUB_KEY" ]]; then
  echo "A host public key is required." >&2
  exit 1
fi
```

If password-based recovery is intentionally supported, require an explicit confirmation before allowing the omission.

---

## 3.4 Existing private keys are not fully checked

If the key exists, the script keeps it:

```bash
if [ ! -f "$USER_HOME/.ssh/id_ed25519" ]; then
  ...
else
  echo "Key already exists, keeping it."
fi
```

It does not verify:

- Ownership.
- Permissions.
- Corresponding public key.
- Whether it is actually an Ed25519 key.
- Whether it is encrypted.
- Whether it belongs to the intended user.

### Severity: Medium

### Recommendation

Validate an existing key:

```bash
stat -c '%U %a' "$USER_HOME/.ssh/id_ed25519"
ssh-keygen -y -f "$USER_HOME/.ssh/id_ed25519" >/dev/null
```

Ensure:

```bash
chown "$NEW_USER:$USER_GROUP" "$USER_HOME/.ssh/id_ed25519"
chmod 600 "$USER_HOME/.ssh/id_ed25519"
chmod 644 "$USER_HOME/.ssh/id_ed25519.pub"
```

---

## 3.5 The key is generated before GitHub access is confirmed

The script generates the key and prints it, but does not verify that:

- The key was successfully added to GitHub.
- GitHub accepts the key.
- The key is not already registered elsewhere.

The later script assumes that the key works.

### Recommendation

After the user adds the key to GitHub, test explicitly:

```bash
sudo -u "$NEW_USER" ssh \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=yes \
  -T git@github.com
```

GitHub commonly exits with status 1 even on successful authentication, so inspect the output rather than relying only on the exit status.

---

## 3.6 No validation of the SSH daemon before the later hardening step

The script does not verify that:

- SSH is installed.
- `sshd` is running.
- The user's SSH directory is accepted by the daemon.
- The configured `AuthorizedKeysFile` matches the assumed path.

Ubuntu defaults normally match the script's assumptions, but images can differ.

### Recommendation

Check:

```bash
sshd -T | grep -Ei 'authorizedkeysfile|pubkeyauthentication'
systemctl is-active --quiet ssh
```

---

## 3.7 The script prints sensitive key material to the terminal

Printing the public key is necessary, but terminal scrollback, session recording, and logs may retain it. This is not generally a serious secret because public keys are not confidential, but operationally it is worth noting.

The private key is not printed, which is correct.

---

## 3.8 `chown "$NEW_USER:$NEW_USER"` may fail for existing accounts

As discussed earlier, the primary group may not match the username.

### Recommendation

Use the actual primary group.

---

# 4. Audit of `setup-user.sh`

## 4.1 `SSH_CLIENT` is unsafe under `set -u`

This line fails if the script is run locally or through a session where `SSH_CLIENT` is absent:

```bash
SSH_CLIENT_IP="${SSH_CLIENT%% *}"
```

Because the script uses `set -u`, an unset variable is an error.

### Severity: Medium

### Fix

```bash
SSH_CLIENT_IP="${SSH_CLIENT:-}"
SSH_CLIENT_IP="${SSH_CLIENT_IP%% *}"
```

Or more directly:

```bash
SSH_CLIENT_IP="${SSH_CLIENT%% *}" 2>/dev/null || SSH_CLIENT_IP=""
```

The first version is clearer.

---

## 4.2 SSH hardening is not syntax-checked

The script writes:

```bash
sudo tee /etc/ssh/sshd_config.d/50-hardening.conf
```

and then immediately restarts SSH.

There is no:

```bash
sshd -t
```

A malformed configuration can interrupt future logins. Existing configuration files can also contain conflicting directives.

### Severity: Critical

### Recommendation

Write the file, validate it, and only reload after successful validation:

```bash
sudo sshd -t
```

Prefer checking the effective settings too:

```bash
sudo sshd -T | grep -Ei \
  'permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication'
```

A safer pattern is:

```bash
sudo install -m 0644 /dev/stdin \
  /etc/ssh/sshd_config.d/50-hardening.conf <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
EOF

if ! sudo sshd -t; then
  echo "sshd configuration is invalid; restoring previous state." >&2
  exit 1
fi

sudo systemctl reload ssh
```

Before disabling password authentication, open a second terminal and verify key login.

---

## 4.3 `KbdInteractiveAuthentication` is not disabled

The script sets:

```text
PasswordAuthentication no
```

but omits:

```text
KbdInteractiveAuthentication no
```

SSH authentication methods vary by Ubuntu release, PAM configuration, and existing drop-ins. Password authentication through keyboard-interactive PAM may still be possible.

### Severity: High

### Recommendation

Include:

```text
KbdInteractiveAuthentication no
```

If maximum restriction is intended, also review:

```text
UsePAM yes
AuthenticationMethods publickey
```

Be careful with `AuthenticationMethods`, because it can interact with existing MFA or PAM configuration.

---

## 4.4 SSH configuration precedence is not verified

OpenSSH generally uses the first obtained value for many settings. A `50-hardening.conf` file may not override a value already set in an earlier included file.

The script assumes that the drop-in will always win.

### Severity: High

### Recommendation

Inspect the effective configuration:

```bash
sudo sshd -T | grep -E \
  '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication) '
```

If deterministic precedence is required, remove conflicting directives or use a clearly controlled configuration strategy.

---

## 4.5 Restarting `ssh.socket` may not be portable

The script assumes:

```bash
sudo systemctl restart ssh.socket
```

Ubuntu installations may use socket activation, but this should not be assumed blindly across:

- Different Ubuntu images.
- Older releases.
- Cloud provider images.
- Systems where socket activation has been disabled.

With `set -e`, a missing unit can terminate the script.

### Recommendation

Detect the service layout:

```bash
if systemctl list-unit-files ssh.socket >/dev/null 2>&1 &&
  systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
  sudo systemctl reload ssh.socket
else
  sudo systemctl reload ssh
fi
```

In practice, reloading the SSH service is usually preferable to restarting it.

---

## 4.6 No backup of the SSH configuration

The script creates a drop-in but does not back it up or record the previous effective configuration.

### Recommendation

Create a timestamped backup or make the drop-in easy to remove:

```bash
sudo cp -a /etc/ssh/sshd_config.d/50-hardening.conf \
  "/etc/ssh/50-hardening.conf.backup.$(date +%s)" 2>/dev/null || true
```

Also print a rollback command.

---

## 4.7 No second-session lockout test

The comments state that the key has been confirmed, but the script only proves that the GitHub key works. That does not prove that the host machine's key works for the server.

### Severity: Critical

### Recommendation

The script should not disable password login automatically unless the operator confirms that a second SSH session succeeded.

A safer workflow:

1. Install the host public key.
2. Print a command to test it.
3. Require explicit confirmation.
4. Only then write and activate the SSH hardening configuration.

---

## 4.8 Removing shell startup files is unnecessarily destructive

The script deletes:

```bash
rm -f "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" \
  "$HOME/.profile" "$HOME/.bash_logout"
```

This can destroy:

- Existing user customizations.
- Provider-specific environment setup.
- Cloud-init configuration.
- PATH changes.
- Recovery aliases.
- Shell initialization required by tools.

It is also unnecessary for avoiding yadm conflicts. Yadm can handle tracked files, or the files can be backed up.

### Severity: High

### Recommendation

Back up instead:

```bash
BACKUP_DIR="$HOME/.bootstrap-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

for file in .zshrc .bashrc .bash_profile .profile .bash_logout; do
  if [[ -e "$HOME/$file" ]]; then
    cp -a "$HOME/$file" "$BACKUP_DIR/$file"
  fi
done
```

Do not delete `.profile` before confirming that the dotfiles clone contains a replacement.

---

## 4.9 `ssh-keyscan` is not authenticated

The script runs:

```bash
ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts"
```

This prevents an interactive prompt but does not establish that the returned key belongs to GitHub.

### Severity: High

### Recommendation

Use a trusted, pinned GitHub host key obtained from a secure source. At minimum, compare the fingerprint against GitHub's published fingerprints before installing it.

Also avoid appending duplicate entries on reruns:

```bash
ssh-keygen -F github.com >/dev/null ||
  ssh-keyscan -t ed25519 github.com >>"$HOME/.ssh/known_hosts"
```

---

## 4.10 Temporary SSH askpass helper can leak the passphrase

The script creates a temporary shell script containing the private-key passphrase:

```bash
printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$SSH_KEY_PASS" > "$SSH_ASKPASS_HELPER"
```

Problems include:

- The passphrase is stored in a file.
- The file is not created with an explicitly restrictive mode.
- There is no cleanup trap if `ssh-add` fails.
- The passphrase is inserted into shell source code.
- Quotes, backslashes, command substitutions, and other shell characters can change the generated script's behavior.
- The agent is not killed after use.
- The passphrase remains in the shell variable for the rest of the script.

### Severity: High

### Recommendation

Avoid embedding secrets in generated shell code. Prefer:

- An interactive `ssh-add`.
- A user-managed persistent agent.
- A secure desktop/keyring agent.
- A carefully isolated helper created with `mktemp` and restrictive permissions.

If a temporary helper is unavoidable:

```bash
SSH_ASKPASS_HELPER="$(mktemp)"
chmod 700 "$SSH_ASKPASS_HELPER"

cleanup() {
  rm -f "$SSH_ASKPASS_HELPER"
  if [[ -n "${SSH_AGENT_PID:-}" ]]; then
    ssh-agent -k >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT
```

However, the helper still needs safe secret handling. The preferred solution is to let `ssh-add` prompt interactively.

---

## 4.11 The SSH agent is not cleaned up

The script starts an agent:

```bash
eval "$(ssh-agent -s)"
```

but never runs:

```bash
ssh-agent -k
```

This leaves an agent process running after the script exits.

### Severity: Medium

### Recommendation

Use a cleanup trap and stop the agent when the clone is complete, unless the agent is intentionally meant to persist for the user's shell sessions.

---

## 4.12 `fnm` installation is not verified

The script assumes the installer produces:

```text
$HOME/.local/share/fnm/fnm
```

and then creates:

```bash
ln -sf "$HOME/.local/share/fnm/fnm" "$HOME/.local/bin/fnm"
```

If the installer changes its layout or fails silently, the symlink can point to a nonexistent file.

### Recommendation

Verify both the installer result and the command:

```bash
test -x "$HOME/.local/share/fnm/fnm"
"$HOME/.local/share/fnm/fnm" --version
```

Also consider using the official package or a pinned release rather than an installer fetched from the network.

---

## 4.13 Node is installed but may not be selected as the default

The script runs:

```bash
fnm install --lts
```

Depending on `fnm` behavior and shell initialization, the installed LTS version may not become the default version for every future shell.

### Recommendation

Explicitly set the default:

```bash
fnm default "$(fnm list | awk '/lts/ {print $2; exit}')"
```

Or use the documented `fnm default` syntax for the selected version.

Then verify in a fresh shell:

```bash
zsh -lic 'node --version && npm --version'
```

---

## 4.14 `corepack` is not explicitly installed or verified

The `.zshrc` defines:

```bash
corepackup() {
  corepack enable pnpm
  corepack prepare pnpm@latest --activate
}
```

Modern Node distributions have changed Corepack behavior, and `corepack prepare` may be deprecated or behave differently across versions.

### Recommendation

Verify:

```bash
corepack --version
node --version
```

Consider using the currently documented Corepack workflow or installing pnpm through its official method. Do not automatically activate `pnpm@latest` in a reproducible server bootstrap unless that is intentional.

---

## 4.15 `fd` and `bat` symlink creation can fail unexpectedly

The script uses:

```bash
command -v fd >/dev/null 2>&1 ||
  ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
```

If `fdfind` is absent, the command substitution produces an empty path and `ln` fails. Because of `set -e`, the setup stops.

The same applies to `batcat`.

### Recommendation

Check explicitly:

```bash
if ! command -v fd >/dev/null 2>&1; then
  if command -v fdfind >/dev/null 2>&1; then
    ln -sf "$(command -v fdfind)" "$HOME/.local/bin/fd"
  else
    echo "fd/fdfind was not installed." >&2
    exit 1
  fi
fi
```

Repeat for `bat` and `batcat`.

---

## 4.16 Package names and binary names are assumed

The comments state that Ubuntu 24.04 provides:

- `fd-find`
- `bat`
- `lf`
- `yadm`

These are generally reasonable assumptions, but minimal images and future releases may differ.

### Recommendation

After installation, verify required commands:

```bash
for command in zsh nvim fdfind batcat rg lf yadm git curl lsof unzip; do
  command -v "$command" >/dev/null ||
    echo "Missing command: $command" >&2
done
```

---

## 4.17 Full `apt-get upgrade` may be undesirable during bootstrap

Running:

```bash
sudo apt-get upgrade -y
```

can:

- Upgrade a large number of packages.
- Trigger a kernel update.
- Require a reboot.
- Change system behavior unexpectedly.
- Take a long time.
- Fail due to held packages or package conflicts.

### Recommendation

Make the upgrade optional, or separate it from the initial bootstrap:

```bash
sudo apt-get update
sudo apt-get install -y ...
```

If a full upgrade is desired, state clearly that a reboot may be required and verify service health afterward.

---

## 4.18 No reboot handling after kernel or libc upgrades

The script detects `/var/run/reboot-required`, but only prints a message. That is reasonable, but users should also be told that the current running kernel and services may not match installed packages.

### Recommendation

Print:

- Whether a reboot is recommended.
- A reboot command.
- A reminder to confirm SSH access after reboot.

---

## 4.19 `yadm pull` is not safe for local modifications

On reruns:

```bash
yadm pull
```

can fail or merge unexpectedly if tracked files have been changed locally.

The script does not explain whether local changes should be preserved, discarded, or committed.

### Recommendation

Before pulling:

```bash
yadm status
```

Then either:

- Abort if there are local changes.
- Stash them.
- Ask the operator how to proceed.

---

## 4.20 Dotfiles are trusted with full installation privileges

The dotfiles repository controls:

- `.zshrc`
- Neovim configuration
- Potential shell functions and aliases
- Potential yadm bootstrap behavior

A compromised or modified dotfiles repository could execute code when the user starts a shell or launches Neovim.

### Severity: High

### Recommendation

- Pin or review the repository revision.
- Verify the GitHub account and SSH host key.
- Avoid automatic bootstrap execution from unreviewed dotfiles.
- Consider cloning first, reviewing, and then applying files.

---

## 4.21 No verification that the cloned repository is the expected repository

The script assumes:

```bash
DOTFILES_REPO="git@github.com:zzacong/dotfiles.git"
```

but does not verify the remote URL after cloning.

### Recommendation

Verify:

```bash
yadm remote -v
```

and optionally verify the expected repository owner and commit.

---

# 5. Squid-specific audit

The optional Squid section deserves separate attention because a proxy exposed to the Internet can become a serious abuse and security problem.

## 5.1 Hardcoded default proxy credentials

The script contains default values for:

- Proxy username.
- Proxy password.

These should not be present in the source.

### Severity: Critical

### Recommendation

Prompt for both values without showing defaults. Require a sufficiently strong password.

---

## 5.2 UFW opens Squid to the entire Internet

The script runs:

```bash
sudo ufw allow 3128/tcp
```

This allows connections to port 3128 from any source address, subject to Squid authentication.

Even with authentication, a public proxy is a high-value target and may be abused through:

- Credential guessing.
- Vulnerable proxy software.
- SSRF-like access.
- Excessive bandwidth use.
- Reputation damage.
- Denial-of-service attempts.

### Severity: Critical

### Recommendation

Restrict the firewall rule to a known source IP:

```bash
sudo ufw allow from "$SQUID_IP" to any port 3128 proto tcp
```

If the source IP is unknown or dynamic, strongly consider using:

- SSH port forwarding.
- A VPN such as WireGuard.
- A private network.
- A cloud security-group rule.
- Tailscale or another authenticated overlay network.

Do not expose Squid publicly unless there is a strong operational reason.

---

## 5.3 IP input is not validated

The supplied IP is inserted directly into Squid configuration:

```bash
IP_RULES="acl allowed_ip src ${SQUID_IP}
http_access allow allowed_ip"
```

An invalid value can break Squid configuration. Although `read -r` reads one line, spaces and malformed input can still generate unintended configuration.

### Recommendation

Validate IPv4 or IPv6 using a parser. For example, use Python or a dedicated utility rather than a fragile regular expression.

At minimum:

```bash
if [[ -n "$SQUID_IP" ]] &&
  ! python3 - "$SQUID_IP" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
then
  echo "Invalid IP address." >&2
  exit 1
fi
```

CIDR ranges should be handled separately and explicitly.

---

## 5.4 Squid configuration is not validated before restart

The script modifies `/etc/squid/squid.conf` and immediately restarts Squid:

```bash
sudo systemctl restart squid
```

There is no `squid -k parse`.

### Severity: High

### Recommendation

Validate before restarting:

```bash
if ! sudo squid -k parse; then
  echo "Invalid Squid configuration; restoring backup." >&2
  sudo cp /etc/squid/squid.conf.bak /etc/squid/squid.conf
  exit 1
fi

sudo systemctl restart squid
```

---

## 5.5 The fallback insertion path can place allow rules too late

If no exact line matching this is found:

```text
http_access deny all
```

the script appends the allow block and then appends another deny rule.

If an earlier deny rule already exists, the new allow rules may never be reached.

The comment says the script will still work, but that is not guaranteed.

### Recommendation

Fail rather than silently produce a potentially nonfunctional configuration:

```bash
if [[ -z "$DENY_LINE" ]]; then
  echo "Could not locate Squid's deny-all anchor." >&2
  exit 1
fi
```

Alternatively, generate a complete controlled configuration instead of editing the distribution file with line-number insertion.

---

## 5.6 Existing password file may not contain the requested user

If `/etc/squid/passwords` exists, the script prints:

```text
Password file already exists, keeping it.
```

It does not verify that the requested user exists in that file or that the supplied password matches.

### Recommendation

Check:

```bash
sudo grep -q "^${SQUID_USER}:" /etc/squid/passwords
```

If absent, add the user or ask the operator whether to replace the file.

---

## 5.7 No explicit destination and method restrictions

The generated rules allow authenticated users broadly. The effective safety depends heavily on the distribution's default ACLs.

### Recommendation

Explicitly define and verify:

- Allowed destination ports.
- Allowed HTTP methods.
- CONNECT destinations.
- Private address blocking.
- Localhost blocking.
- Metadata endpoint blocking.
- Maximum request and connection limits.

A proxy should not allow access to private network ranges or cloud metadata endpoints unless that is explicitly required.

---

## 5.8 No service hardening or resource limits

The script enables Squid but does not configure:

- Resource limits.
- Access logging review.
- Log rotation verification.
- Maximum object/request sizes.
- Connection limits.
- Fail2ban or equivalent controls.
- Monitoring.

### Recommendation

At minimum, monitor:

```bash
sudo journalctl -u squid
sudo tail -f /var/log/squid/access.log
```

and establish a plan for abuse detection and log retention.

---

# 6. Audit of `.zshrc`

The `.zshrc` is generally functional, but several details deserve attention.

## 6.1 `zsh-syntax-highlighting` should remain last

The current plugin list places it last:

```zsh
plugins=(
  fnm
  z
  zsh-autosuggestions
  zsh-syntax-highlighting
)
```

That is correct. This ordering should be preserved because syntax highlighting should normally load after other plugins.

---

## 6.2 The `fnm` Oh My Zsh plugin may be redundant

The configuration includes:

```zsh
plugins=(
  fnm
)
```

and separately:

```zsh
if command -v "fnm" &> /dev/null; then
  eval "$(fnm env)"
fi
```

This may initialize `fnm` more than once, depending on the Oh My Zsh plugin implementation.

### Recommendation

Choose one initialization method. The explicit block is easier to understand and control. If retaining the plugin, verify that it does not duplicate `fnm env`.

---

## 6.3 `fnm env` may not support automatic directory switching

The configuration has:

```zsh
# eval "$(fnm env --use-on-cd)"
```

This is intentionally disabled. Consequently, `.nvmrc` or `.node-version` files may not be selected automatically when changing directories.

### Recommendation

Enable it if automatic project-version switching is desired:

```zsh
eval "$(fnm env --use-on-cd)"
```

---

## 6.4 Git aliases that accept arguments are better as functions

For example:

```zsh
alias gac="git add . && git commit -m"
```

This works for simple cases, but aliases are not ideal for argument handling, quoting, or error reporting.

### Recommendation

Use functions:

```zsh
gac() {
  git add . && git commit -m "$*"
}
```

Similarly, aliases such as `gpu` and `gpuh` may be clearer as functions if they need flexible arguments.

---

## 6.5 `gac` stages all files, including unintended files

```zsh
git add .
```

can stage:

- Secrets.
- Build output.
- Environment files.
- Temporary files.
- Large generated artifacts.

### Recommendation

Prefer deliberate staging, or at least consider:

```zsh
git add -A
```

with a review step before committing. The alias is convenient but potentially dangerous.

---

## 6.6 `grh` is a destructive alias

```zsh
alias grh="git reset --hard"
```

This is convenient but can destroy uncommitted work. A safer name or confirmation wrapper would reduce accidental use.

---

## 6.7 `MANPAGER` assumes `col` and `bat` are available

```zsh
export MANPAGER="sh -c 'col -bx | bat -l man -p'"
```

If `col` or `bat` is missing, viewing a man page fails.

### Recommendation

Use a conditional setup:

```zsh
if command -v bat >/dev/null 2>&1 &&
  command -v col >/dev/null 2>&1; then
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
fi
```

---

## 6.8 `BAT_THEME` may not exist in all bat versions

```zsh
export BAT_THEME="Coldark-Dark"
```

If the installed bat version does not include that theme, bat may fall back or warn.

### Recommendation

Verify:

```bash
bat --list-themes | grep -Fx 'Coldark-Dark'
```

---

## 6.9 `register-python-argcomplete` output is evaluated as shell code

```zsh
eval "$(register-python-argcomplete pipx)"
```

This is normal for argcomplete, but it executes generated shell code. Ensure the executable is trusted and comes from the expected package installation.

---

## 6.10 No interactive-shell guard

The file is intended for zsh interactive use, so this is not necessarily a problem. However, if it is sourced in unusual contexts, commands such as `eval`, plugin loading, or prompt setup can affect noninteractive shells.

### Recommendation

Optionally add:

```zsh
[[ -o interactive ]] || return
```

Only do this if the file is never expected to configure noninteractive zsh sessions.

---

## 6.11 Aliases are not available to scripts

All the Git, pnpm, and navigation shortcuts are interactive conveniences. They will not be available to shell scripts, cron jobs, or noninteractive SSH commands.

This is expected, but functions or scripts may be preferable for anything intended for automation.

---

# 7. Recommended revised execution flow

A safer operational flow would be:

## Step 1: Create the account

- Refuse to modify an existing account unless explicitly confirmed.
- Create the user and sudo membership.
- Set a temporary strong password.
- Verify the account and home directory.

## Step 2: Install and verify the host key

- Require a valid host public key.
- Validate it with `ssh-keygen`.
- Install it with correct ownership and permissions.
- Confirm that SSH is running.
- Generate the GitHub key using a passphrase entered interactively.
- Do not use a hardcoded passphrase.
- Print the public key.
- Ask the operator to add it to GitHub.
- Test GitHub authentication.

## Step 3: Log in using the host key

Before running the user setup, open a second terminal and verify:

```bash
ssh -o PasswordAuthentication=no user@server
```

Do not proceed until this works.

## Step 4: Install user software

- Avoid deleting existing shell files.
- Back them up instead.
- Install packages and verify expected commands.
- Pin or verify downloaded installers.
- Configure Node and pnpm.
- Clone dotfiles after verifying GitHub's host key.
- Review or verify the dotfiles revision.

## Step 5: Harden SSH

- Write the drop-in.
- Run `sshd -t`.
- Check effective values with `sshd -T`.
- Reload SSH instead of restarting where possible.
- Keep the existing session open.
- Verify a new key-only login.

Recommended hardening settings include:

```text
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
LoginGraceTime 20
```

## Step 6: Configure the firewall

- Install UFW before using it.
- Allow SSH first.
- Restrict application ports to known source IPs where possible.
- Avoid opening Squid globally.

## Step 7: Configure Squid only if necessary

- Prefer a VPN or SSH tunnel.
- Validate all IP and username inputs.
- Use strong, unique credentials.
- Generate a complete known-good configuration.
- Run `squid -k parse`.
- Restrict access at both the firewall and Squid layers.

---

# 8. Suggested preflight checks

Each script should perform appropriate checks before making changes.

```bash
require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Required command not found: $1" >&2
    exit 1
  }
}
```

For the user setup:

```bash
require_command sudo
require_command apt-get
require_command curl
require_command ssh
require_command ssh-keyscan
```

For SSH hardening:

```bash
sudo sshd -t
sudo sshd -T
```

For Squid:

```bash
sudo squid -k parse
```

For the final environment:

```bash
zsh -lic '
  command -v zsh
  command -v nvim
  command -v fd
  command -v bat
  command -v fnm
  command -v node
  command -v yadm
'
```

---

# 9. Priority remediation list

## Must fix before production use

1. Remove the hardcoded SSH passphrase.
2. Remove the hardcoded Squid username and password.
3. Require and validate the host SSH public key.
4. Add `KbdInteractiveAuthentication no`.
5. Run `sshd -t` before reloading or restarting SSH.
6. Require confirmation of a successful second SSH login before disabling passwords.
7. Fix the unset `SSH_CLIENT` problem.
8. Validate Squid configuration with `squid -k parse`.
9. Do not open port 3128 globally.
10. Verify GitHub's host key instead of trusting unauthenticated `ssh-keyscan` output.
11. Stop deleting existing shell startup files; back them up instead.
12. Add cleanup traps for temporary files and the SSH agent.

## Should fix soon

1. Validate existing user accounts before changing them.
2. Resolve the actual primary group instead of assuming `$USER:$USER`.
3. Verify installed commands after apt operations.
4. Make `fnm` installation and default-version selection explicit.
5. Improve yadm rerun behavior when local changes exist.
6. Pin or verify downloaded third-party installers.
7. Add input validation for Squid IP addresses and usernames.
8. Improve SSH configuration precedence handling.
9. Avoid a full `apt-get upgrade` unless explicitly requested.
10. Add backups and rollback instructions.

## Nice to improve

1. Convert complex aliases into shell functions.
2. Add an interactive-shell guard to `.zshrc`.
3. Validate the configured bat theme.
4. Make `MANPAGER` conditional.
5. Add a final health-check summary.
6. Document provider-specific requirements such as cloud firewall rules and reboot behavior.

---

# Overall assessment

The scripts are a useful personal bootstrap starting point, but they currently combine several high-risk behaviors:

- Secret material embedded in scripts.
- Automatic SSH lockout changes without configuration validation.
- Destructive removal of user files.
- Unauthenticated host-key acquisition.
- Optional deployment of a potentially public proxy.
- Incomplete idempotency and input validation.

After the critical issues are addressed, the scripts can be made suitable for a fresh Ubuntu VPS. The SSH hardening and Squid sections deserve the most attention because mistakes there can either lock you out of the server or expose a network service to the Internet.


---
