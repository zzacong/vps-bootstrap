# 0007-mac-manual-prerequisites

The Mac flow moves Xcode Command Line Tools and Homebrew out of `setup-mac.sh` and into README prerequisites, alongside 1Password. The operator installs all three by hand; `setup-mac.sh` opens with a preflight that asserts each one and prints the command to run when one is missing. Everything after that stays in the script: the shell env (oh-my-zsh, plugins, starship), brew formulae and casks, neovim/vim-plug, Node via fnm, Rust via rustup, pipx apps, the 1Password agent socket link, the yadm dotfiles clone, and the pnpm global CLIs.

CLT and Homebrew were already one-shot steps that run once per laptop and produce little script logic. Command Line Tools install behind a GUI dialog, so the script could only poll `xcode-select -p` in a loop with a timeout; the Homebrew installer is a single command. Carrying both meant the script owned a wait loop and an install branch for work that never repeats on that machine. Moving them out makes the script's job "install the repeatable toolchain and the dotfiles," and makes the boundary consistent with ADR-0006, which already treats 1Password as something a bootstrap cannot install. This reverses the original "Mac flow is one script" framing.

The trade-off is more manual setup before the script runs: three installs instead of one command. In exchange, a missing prerequisite fails in the first second with the exact command to run, rather than after the script has installed a batch of formulas and stopped at the 1Password check.

Consequences:

- 1Password's prerequisite (ADR-0006) is now one of three. The preflight prints the specific checklist for whichever one is missing.
- The README owns the CLT and Homebrew commands. The script never installs either.
- A Homebrew `shellenv` line must live in the dotfiles rather than `~/.zprofile`, because the dotfiles clone moves the shell files aside.
- Rust installs with `--no-modify-path` for the same reason: rustup would otherwise edit `~/.zshenv`. The dotfiles must source `$HOME/.cargo/env`.
