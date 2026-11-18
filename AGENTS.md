# AGENTS.md

Bootstrap only: take a bare machine to where the dotfiles take over. Not configuration management. User-level config goes in the dotfiles repo (`zzacong/dotfiles`, yadm), except the marker blocks and the fish hand-off below.

## Vocabulary

Single-context glossary only: `GLOSSARY.md` at the repo root.

## When editing scripts

- Preflight validates and fails. It never prompts. New questions go in section 0 as plan questions.
- Anything destructive gets a confirmation and a backup.
- Own only marker-delimited blocks in files the dotfiles don't track. A re-run must update them.
- Don't start an `ssh-agent` on the target.
- Before adding user-level config here, check whether it belongs in the dotfiles.
- Keep comments in sync with the code.
