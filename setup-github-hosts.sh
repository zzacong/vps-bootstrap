#!/bin/zsh
# ============================================================
# setup-github-hosts.sh  (add GitHub SSH host aliases on a Mac)
#
# Interactive wizard. For each identity it asks for a Host alias,
# HostName, User, and the public key line you paste from 1Password
# (the private half stays in 1Password), then writes a Host block to
# ~/.ssh/config. Run it on its own, or from setup-mac.sh (section 13):
#
#   zsh setup-github-hosts.sh
#   zsh -c "$(curl -fsSL https://raw.githubusercontent.com/zzacong/vps-bootstrap/main/setup-github-hosts.sh)"
#
# Blocks live between the BEGIN/END marker lines at the end of
# ~/.ssh/config. Hand-written blocks outside the markers are left
# alone, except github* blocks, which move inside on the next write.
# Every write keeps a timestamped backup of the old config. At the
# end, each alias added in this run gets an `ssh -T` check, which is
# reported only.
# ============================================================

set -euo pipefail

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
OP_AGENT_SOCK="$HOME/.config/1password/agent.sock"
BEGIN_MARK="# BEGIN vps-bootstrap github hosts"
END_MARK="# END vps-bootstrap github hosts"
HOST_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
USER_RE='^[A-Za-z0-9._-]+$'
# Key types OpenSSH accepts. ssh-keygen -lf below rejects anything malformed.
KEY_LINE_RE='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/=]+'

# Aliases added in this run, checked against GitHub at the end.
ADDED=()

# Temp files written during the run; removed on exit.
CLEANUP_FILES=()
cleanup() {
  local f
  for f in "${CLEANUP_FILES[@]}"; do
    rm -f "$f"
  done
}
trap cleanup EXIT

# ------------------------------------------------------------
# Preflight
# ------------------------------------------------------------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "setup-github-hosts.sh is for macOS only." >&2
  exit 1
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "Do NOT run this as root. Run it as your normal user." >&2
  exit 1
fi
if [ ! -t 0 ]; then
  echo "This wizard asks questions; run it in a terminal, not piped." >&2
  exit 1
fi
# The socket is 1Password's agent, linked by setup-mac.sh (section 7).
if [ ! -S "$OP_AGENT_SOCK" ]; then
  echo "1Password's SSH agent socket is missing: $OP_AGENT_SOCK" >&2
  echo "    Install and sign in to 1Password, enable Settings -> Developer -> SSH agent," >&2
  echo "    then re-run this wizard." >&2
  exit 1
fi
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
# setup-mac.sh (section 7) writes this line; without it ssh never asks 1Password.
if ! grep -qs "IdentityAgent" "$SSH_CONFIG"; then
  echo "    Warning: $SSH_CONFIG names no IdentityAgent, so ssh won't use 1Password." >&2
fi

# ------------------------------------------------------------
# Prompt helpers
# ------------------------------------------------------------
# ask PROMPT: reads one line into ANSWER. Ctrl-D cancels the run,
# so the wizard never loops forever on closed input.
typeset -g ANSWER=""
ask() {
  read -r "ANSWER?$1" || {
    print -u2 ""
    print -u2 "Cancelled, nothing written."
    exit 1
  }
}

# ask_valid PROMPT DEFAULT REGEX: asks until the answer (or DEFAULT
# when empty) matches REGEX. Leaves the value in ANSWER.
ask_valid() {
  while true; do
    ask "$1"
    ANSWER="${ANSWER:-$2}"
    [[ "$ANSWER" =~ $3 ]] && return 0
    echo "    Invalid value: $ANSWER" >&2
  done
}

# confirm PROMPT: yes only for y or yes. Default is no.
confirm() {
  ask "$1 (y/N): "
  [[ "$ANSWER" == [Yy]* ]]
}

# ------------------------------------------------------------
# Checks on the existing config and the pasted key
# ------------------------------------------------------------
# True when some Host line in ~/.ssh/config already names $1.
alias_in_config() {
  [ -f "$SSH_CONFIG" ] || return 1
  awk -v h="${1:l}" '
    tolower($1) == "host" { for (i = 2; i <= NF; i++) if (tolower($i) == h) found = 1 }
    END { exit !found }
  ' "$SSH_CONFIG"
}

# True when $1 is a public key line that ssh-keygen can parse.
valid_pub_key() {
  local tmp
  tmp="$(mktemp)"
  CLEANUP_FILES+=("$tmp")
  print -r -- "$1" > "$tmp"
  ssh-keygen -lf "$tmp" >/dev/null 2>&1
}

# True when the 1Password agent currently holds the key with base64
# blob $1. The socket is passed explicitly so this never uses another
# agent that happens to be in SSH_AUTH_SOCK.
agent_has_key() {
  local agent_keys
  agent_keys="$(SSH_AUTH_SOCK="$OP_AGENT_SOCK" ssh-add -L 2>/dev/null || true)"
  grep -qF -- "$1" <<< "$agent_keys"
}

# ------------------------------------------------------------
# Config writing
# ------------------------------------------------------------
# Host block for one identity. IdentityFile points at the .pub
# file, the same style as the existing blocks: ssh asks the agent
# to sign with the matching private key, which never leaves 1Password.
# host_block ALIAS HOSTNAME USER
host_block() {
  print -rl -- \
    "Host $1" \
    "  HostName $2" \
    "  User $3" \
    "  IdentityFile ~/.ssh/$1.pub" \
    "  IdentitiesOnly yes"
}

# awk program that rebuilds ~/.ssh/config in one pass. Variables:
#   beginMark / endMark : the managed-section marker lines
#   drop                : lowercase alias whose blocks are removed
#   addFile             : file holding the new block, appended last
# Blocks inside the markers stay in the managed section. A github*
# block outside them moves inside. Everything else keeps its place.
# Each block is printed trimmed, with one blank line after it, so a
# re-run gives the same file.
REBUILD_AWK='
function openBlock(man, head,   k, f, i) {
  n++; man_[n] = man; head_[n] = head; body_[n] = ""; names_[n] = ""
  if (head != "") {
    k = split(tolower(head), f)
    for (i = 2; i <= k; i++) names_[n] = names_[n] " " f[i]
  }
}
function hasDropped(i,   k, f, j) {
  k = split(names_[i], f)
  for (j = 1; j <= k; j++) if (f[j] in dropped) return 1
  return 0
}
function hasGithub(i,   k, f, j) {
  k = split(names_[i], f)
  for (j = 1; j <= k; j++) if (f[j] ~ /^github/) return 1
  return 0
}
function textOf(i,   s) {
  s = (head_[i] == "" ? "" : head_[i] "\n") body_[i]
  sub(/^\n+/, "", s)
  sub(/\n+$/, "", s)
  return s
}
BEGIN {
  n = 0
  openBlock(0, "")
  if (drop != "") dropped[drop] = 1
}
$0 == beginMark { man = 1; openBlock(1, ""); next }
$0 == endMark   { man = 0; openBlock(0, ""); next }
tolower($1) == "host" { openBlock(man, $0); next }
{ body_[n] = body_[n] $0 "\n" }
END {
  for (i = 0; i <= n; i++) {
    s = textOf(i)
    if (s == "") continue
    if (hasDropped(i)) continue
    if (man_[i] || hasGithub(i)) managed[++m] = s
    else outside[++o] = s
  }
  for (i = 1; i <= o; i++) print outside[i] "\n"
  print beginMark
  for (i = 1; i <= m; i++) print managed[i] "\n"
  while ((getline line < addFile) > 0) print line
  print endMark
}'

# write_config ALIAS HOSTNAME USER BLOCK: swaps ALIAS's old blocks for
# BLOCK in the managed section. Checks with ssh -G that ALIAS resolves
# to HOSTNAME and USER before touching the real file, and backs up the
# old one first.
write_config() {
  local block_file new_config source backup err resolved
  block_file="$(mktemp)"
  new_config="$(mktemp)"
  CLEANUP_FILES+=("$block_file" "$new_config")
  print -r -- "$4" > "$block_file"

  source="$SSH_CONFIG"
  [ -f "$source" ] || source=/dev/null
  awk -v beginMark="$BEGIN_MARK" -v endMark="$END_MARK" \
    -v drop="${1:l}" -v addFile="$block_file" \
    "$REBUILD_AWK" "$source" > "$new_config"

  if ! resolved="$(ssh -F "$new_config" -G "$1" 2>&1)"; then
    echo "    ssh rejects the new config, so nothing was written:" >&2
    echo "    $resolved" >&2
    return 1
  fi
  if ! grep -qxF "hostname $2" <<< "$resolved" || ! grep -qxF "user $3" <<< "$resolved"; then
    echo "    ssh resolves $1 differently than expected, so nothing was written." >&2
    return 1
  fi

  if [ -f "$SSH_CONFIG" ]; then
    # mktemp keeps names unique when two writes land in the same second.
    backup="$(mktemp "$SSH_CONFIG.bak.$(date +%Y%m%d-%H%M%S).XXXXXX")"
    cp -p "$SSH_CONFIG" "$backup"
    echo "    Backed up the old config to $backup"
  fi
  cat "$new_config" > "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  echo "    Wrote $SSH_CONFIG"
}

# ------------------------------------------------------------
# One identity
# ------------------------------------------------------------
# Asks for one identity, shows the block, and writes it on confirm.
# Returns 1 when nothing was written.
add_identity() {
  local host_alias host_name ssh_user pub blob key_file block
  local -a fields

  echo ""
  echo "### New GitHub identity ###"

  # Asks until the alias is free, or until the user agrees to replace the one in use.
  while true; do
    ask_valid "Host alias [github.com]: " "github.com" "$HOST_RE"
    host_alias="$ANSWER"
    alias_in_config "$host_alias" || break
    if confirm "    '$host_alias' already exists in $SSH_CONFIG. Replace it?"; then
      break
    fi
  done

  ask_valid "HostName [github.com]: " "github.com" "$HOST_RE"
  host_name="$ANSWER"
  ask_valid "User [git]: " "git" "$USER_RE"
  ssh_user="$ANSWER"

  # The key must parse and be visible to the 1Password agent.
  while true; do
    ask "Paste the public key line (starts with ssh-ed25519, ssh-rsa, or ecdsa-): "
    pub="$ANSWER"
    if [[ "$pub" =~ $KEY_LINE_RE ]] && valid_pub_key "$pub"; then
      fields=(${=pub})
      blob="$fields[2]"
      if agent_has_key "$blob"; then
        break
      fi
      echo "    That key isn't in 1Password's agent. Check that it's in 1Password, that 1Password is unlocked," >&2
      echo "    and that Settings -> Developer -> SSH agent is on. Then paste it again." >&2
    else
      echo "    Not a public key line. Copy the 'Public key' value from 1Password." >&2
    fi
  done

  key_file="$SSH_DIR/$host_alias.pub"
  if [ -e "$key_file" ] && [ "$(awk '{ print $2 }' "$key_file")" != "$blob" ]; then
    if ! confirm "    $key_file already holds a different key. Overwrite it?"; then
      echo "    Skipped $host_alias."
      return 1
    fi
  fi

  block="$(host_block "$host_alias" "$host_name" "$ssh_user")"
  echo ""
  echo "$block"
  echo ""
  if ! confirm "    Write this to $SSH_CONFIG?"; then
    echo "    Not written."
    return 1
  fi

  print -r -- "$pub" > "$key_file"
  chmod 600 "$key_file"
  write_config "$host_alias" "$host_name" "$ssh_user" "$block"
  ADDED+=("$host_alias")
}

# Runs `ssh -T` for each alias added in this run and reports the
# result. Nothing is changed based on it.
check_added() {
  local alias out user
  for alias in "${ADDED[@]}"; do
    out="$(ssh -F "$SSH_CONFIG" -o BatchMode=yes -o ConnectTimeout=10 -T "git@$alias" 2>&1 || true)"
    if [[ "$out" == *"successfully authenticated"* ]]; then
      user="$(print -r -- "$out" | sed -n 's/^Hi \([^!]*\)!.*/\1/p')"
      echo "    OK    git@$alias: authenticated as ${user:-unknown}"
    else
      echo "    FAIL  git@$alias: $out" >&2
    fi
  done
}

# ------------------------------------------------------------
# Main loop
# ------------------------------------------------------------
echo "### GitHub SSH identities -> $SSH_CONFIG ###"
while true; do
  add_identity || true
  confirm "Add another identity?" || break
done

if [ "${#ADDED[@]}" -gt 0 ]; then
  echo ""
  echo "### Checking GitHub SSH auth ###"
  check_added
fi
