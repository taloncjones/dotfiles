#!/bin/zsh
# .zshenv -- read by EVERY zsh: interactive, login, and non-interactive.
# Keep this file tiny and silent (zero output on success, no external
# commands); heavier setup belongs in .zprofile / .zshrc.

# Machine-local additions. The installer migrates a pre-existing
# hand-managed ~/.zshenv here (install/common/zshenv-migrate.sh).
[[ -f "$HOME/.zshenv.local" && -r "$HOME/.zshenv.local" ]] && \
    source "$HOME/.zshenv.local"

# Claude account routing must exist in all shell modes: zsh -lc / zsh -c
# never read .zshrc, and headless probes and orchestrator dispatches run
# there (unrouted launches have hit login screens and dumped config trees
# into the cwd). Resolve the repo through this file's own symlink; a
# missing or unreadable target degrades to a silent no-op
# (symlink-audit.sh flags it).
_dotfiles_zshenv="${${(%):-%N}:A}"
[[ -f "${_dotfiles_zshenv:h}/claude-account.zsh" && -r "${_dotfiles_zshenv:h}/claude-account.zsh" ]] && \
    source "${_dotfiles_zshenv:h}/claude-account.zsh"
unset _dotfiles_zshenv
