# Glossary

Shared vocabulary for this repo. Prose in scripts and docs should use these words
and not their synonyms. Where a term collides with an established meaning
elsewhere, the *not to be confused with* line says which one this repo means.

## Structure

**Flow** — one of the two top-level provisioning paths: the **VPS flow** or the
**Mac flow**. Use "flow", never "pipeline", "profile", or "path".

**Step** — a numbered unit of a flow. The VPS flow has three steps
(`setup-root.sh`, `setup-ssh.sh`, `setup-user.sh`); the Mac flow has one.

*Not to be confused with* **section**: the `# N.` banner block inside a single
script. Scripts are navigated by section number, not by line number.

**Bootstrap** — this repo's entire job: take a bare machine to the point where the
dotfiles take over. It is explicitly not configuration management. Anything
user-level belongs in the dotfiles repo, so "add it to the bootstrap" is almost
always the wrong answer. The exception is the marker-delimited blocks a setup
script owns inside files the dotfiles do not track: the SSH config **marker
block**, the **fish hand-off**, and the **bash env block**. Re-running the flow is
what repairs them.

**Preflight** — validation that runs before any work: does the required tool
exist, is the user present, is sshd up, are the Mac prerequisites met. A preflight
fails fast; it never asks a question.

*Not to be confused with* **plan question**: every interactive choice in a flow,
asked up front in section 0 so the rest of the script runs unattended. Plan
questions decide; preflight validates.

**Hardening confirmation** — the one gate that deliberately stays late (section 6
of `setup-user.sh`), because it is a live safety check rather than a plan choice.

**Guardrail** — the family of protections that stops a mistake locking you out of
the box: validation, backups, `sshd -t` before reload, and the second-terminal
confirmation. "Idempotent" and "guarded" are not the same claim.

**Idempotent-ish** — safe to re-run, because every step checks before it changes.
The "-ish" is load-bearing: re-running does not guarantee *no* change, only that
changes are checked and the genuinely destructive ones (resetting an existing
password, overwriting shell startup files, disabling password auth) are gated
behind an explicit confirmation and a backup.

## Shells

**Login shell** — the shell the OS hands you when you log in: zsh on macOS, bash on
Ubuntu. Neither flow runs `chsh`, so this never changes. On macOS the dotfiles still
configure it (`~/.zshrc` + oh-my-zsh), so it stays usable; on Ubuntu it is stock,
which is the point.

**Interactive shell** — fish, the shell you actually type into. On the Mac the
terminal emulator starts it (Ghostty's `command`); on Ubuntu the **fish hand-off**
does. The bootstrap installs only the binary: `~/.config/fish` is dotfiles
territory.

**Fish hand-off** — the marker-delimited `exec fish` block `setup-user.sh` writes to
`~/.bash_profile`. bash reads that file instead of the skel `~/.profile` for login
shells, and an SSH session is a login shell, so every login lands in fish while
bash stays the login shell. `ssh host cmd` is not a login shell and never reads it,
so scp, rsync, and scripts stay bash. It also puts `~/.local/bin` on `PATH`, for the
fallback where fish is missing and bash has skipped the skel `~/.profile` that
would have.

**Bash env block** — the marker-delimited block `setup-user.sh` writes to
`~/.bashrc`, which is what interactive non-login bash reads: typing `bash` from
fish, a tmux window, `bash -i`. It puts `~/.local/bin` on `PATH` and runs
`eval "$(fnm env --use-on-cd --shell bash)"` for interactive shells — without
`fnm env` there is no node under bash at all, because node lives in
`~/.local/share/fnm` rather than in a directory on `PATH`.

Both shell blocks are bootstrap-owned, so a re-run updates them, and both use the
same marker pattern as the SSH config **marker block**.

## Credentials and SSH

**Host key** — your 1Password SSH key on the host machine, whose public half is
already on the GitHub account that owns the dotfiles. One key serves both SSH
login and GitHub access.

*Not to be confused with* a host key in the usual SSH sense, which is the server's
identity. This repo's "host key" always means your key on your host. When the
SSH-native meaning is intended, write **pinned host key**.

**Pinned host key** — the hardcoded `github.com` line the scripts append to
`~/.ssh/known_hosts` before the yadm clone, so the first connection authenticates
without a trust prompt. Written only if that exact line is absent.

**Forwarded agent** — the 1Password agent socket from your host, reached over
`ssh -A`. GitHub auth in both flows depends on it.

**Local agent** — an `ssh-agent` running on the target machine. The scripts never
start one: it would shadow the forwarded agent, and the GitHub probe would then
pass for the wrong reason.

**Mac credential policy** — neither flow keeps a GitHub key of its own. The
1Password agent is the only credential, which is why 1Password is a hard
prerequisite on the Mac rather than a convenience.

**Host alias** — a `Host` entry in `~/.ssh/config` beyond the default `github.com`,
covering an additional GitHub identity.

**Marker block** — the region of `~/.ssh/config` between the
`# BEGIN/END vps-bootstrap github hosts` lines, which `setup-github-hosts.sh`
owns. Existing `github*` blocks move inside on the next write; hand-written blocks
for other hosts are left alone.

## Filesystem and state

**Dotfiles** — `zzacong/dotfiles`, managed by yadm. Shell config (`.zshrc`, and
`~/.config/fish` in full), editor, aliases, and git config live there, not here. The
boundary rule: if it is user-level, it belongs in the dotfiles — the one exception
being the **fish hand-off**, which has to exist before the clone.

**yadm bootstrap** — the dotfiles clone performed late in a flow, distinct from
merely installing yadm. It backs up collisions first and is the step that proves
the forwarded agent authenticates to GitHub.

**Shell startup file** — a file in the home directory that a shell or installer
writes and the dotfiles also track: `.zshrc` on macOS (written by the oh-my-zsh
installer) and `.config/fish/config.fish` (written by fish on its first interactive
run). These are what the yadm bootstrap moves aside, because the clone would
otherwise collide with them and leave the file unmodified. Nothing on Ubuntu writes
one any more, so the VPS flow only needs it for a fish that ran before the clone or
a box from the zsh era.

*Not to be confused with* `/etc/skel`, whose contents `adduser` copies into a new
home (`~/.bashrc`, `~/.profile`, `~/.bash_logout` on Ubuntu). The dotfiles do not
track those, so they are left alone.

**Bootstrap backup** — `~/.bootstrap-backup-<timestamp>`, the directory **shell
startup files** move into during the yadm bootstrap. Its existence is what keeps a
failed clone from leaving you without a usable shell.

**Hardening drop-in** — `/etc/ssh/sshd_config.d/50-hardening.conf`: `PermitRootLogin
no`, `PasswordAuthentication no`, and `AllowUsers` scoped to you. A named file, not
"the sshd config" generally.
