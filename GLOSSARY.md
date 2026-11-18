# Glossary

Use these terms in scripts, comments, and docs, and avoid the synonyms noted with each one.

**Flow**: either the VPS flow (`setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`) or the Mac flow (`setup-mac.sh`). Don't call it a "pipeline", "profile", or "path".

**Step**: a numbered unit of a flow. Don't confuse it with a **section**, the `# N.` banner inside a script. Navigate scripts by section number.

**Plan question**: an interactive choice asked up front in section 0, so the rest of the run is unattended.

**Preflight**: validation before any work. It fails fast and never asks a question.

**Hardening confirmation**: the one late gate, in section 6 of `setup-user.sh`. It is a live safety check.

**Guardrail**: the family of protections against lockout: validation, backups, `sshd -t` before reload, and the second-terminal confirmation.

**Idempotent-ish**: re-running checks before changing anything. Destructive changes, such as resetting a password, overwriting shell startup files, or disabling password auth, need confirmation and a backup. Don't call the scripts "idempotent".

**Login shell**: zsh on macOS and bash on Ubuntu. Neither flow runs `chsh`.

**Interactive shell**: fish. The bootstrap installs only the binary; `~/.config/fish` belongs to the dotfiles.

**Host key**: your 1Password SSH key on the host machine. One key serves both SSH login and GitHub. For the SSH-native meaning, write **pinned host key**.

**Pinned host key**: the hardcoded `github.com` line appended to `~/.ssh/known_hosts` before the yadm clone. It is written only if absent.

**Forwarded agent**: the 1Password agent socket reached over `ssh -A`. GitHub auth in both flows depends on it.

**yadm bootstrap**: the late dotfiles clone. It backs up colliding files first and proves the forwarded agent authenticates to GitHub.

**Shell startup file**: `.zshrc` on macOS or `.config/fish/config.fish`. The yadm bootstrap moves these aside. Don't confuse them with the `/etc/skel` files (`~/.bashrc`, `~/.profile`), which the dotfiles don't track.

**Bootstrap backup**: `~/.bootstrap-backup-<timestamp>`, where shell startup files go during the yadm bootstrap.

**Hardening drop-in**: `/etc/ssh/sshd_config.d/50-hardening.conf`.

**Squid rules file**: `/etc/squid/conf.d/20-vps-bootstrap.conf`. Two rules: `acl tailnet src 100.64.0.0/10` and `http_access allow tailnet`. Squid's own `squid.conf` is a packaged conffile and is never edited, so `apt upgrade` never asks about it.

**Tailnet**: the private Tailscale network this box joins, addressed out of `100.64.0.0/10`. It is the only thing the Squid rules file lets through, and the intended way in once port 22 is closed. Don't call it a "VPN" or a "Tailscale network".

**Tailscale hand-off**: the `sudo tailscale up` the scripts print after installing Tailscale, and never run. The node is installed but logged out until you do it, which is why the proxy denies everyone in the meantime.

**Mac credential policy**: neither flow keeps a GitHub key of its own. The 1Password agent is the only credential.
