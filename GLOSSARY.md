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
always the wrong answer.

**Preflight** — validation that runs before any work: does the required tool
exist, is the user present, is sshd up, are the Mac prerequisites met. A preflight
fails fast; it never asks a question.

*Not to be confused with* **plan question**: every interactive choice in a flow,
asked up front in section 0 so the rest of the script runs unattended. Plan
questions decide; preflight validates.

**Hardening confirmation** — the one gate that deliberately stays late (section 7
of `setup-user.sh`), because it is a live safety check rather than a plan choice.

**Guardrail** — the family of protections that stops a mistake locking you out of
the box: validation, backups, `sshd -t` before reload, and the second-terminal
confirmation. "Idempotent" and "guarded" are not the same claim.

**Idempotent-ish** — safe to re-run, because every step checks before it changes.
The "-ish" is load-bearing: re-running does not guarantee *no* change, only that
changes are checked and the genuinely destructive ones (resetting an existing
password, overwriting skel defaults, disabling password auth) are gated behind an
explicit confirmation and a backup.

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

**Dotfiles** — `zzacong/dotfiles`, managed by yadm. Shell, editor, aliases, and git
config live there, not here. The boundary rule: if it is user-level, it belongs in
the dotfiles.

**yadm bootstrap** — the dotfiles clone performed late in a flow, distinct from
merely installing yadm. It backs up collisions first and is the step that proves
the forwarded agent authenticates to GitHub.

**Skel default** — a file Ubuntu ships in `/etc/skel` (typically `~/.zshrc`,
`~/.bashrc`, `~/.profile`) that the dotfiles also track. These collide with the
clone and are moved aside, never deleted.

**Bootstrap backup** — `~/.bootstrap-backup-<timestamp>`, the directory skel
defaults move into during the yadm bootstrap. Its existence is what keeps a failed
clone from leaving you without a usable shell.

**Hardening drop-in** — `/etc/ssh/sshd_config.d/50-hardening.conf`: `PermitRootLogin
no`, `PasswordAuthentication no`, and `AllowUsers` scoped to you. A named file, not
"the sshd config" generally.
