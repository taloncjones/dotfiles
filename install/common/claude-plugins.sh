#!/usr/bin/env bash
set -euo pipefail

# claude-plugins.sh - Install/refresh the ECC and Superpowers Claude Code plugins
#
# Runs on full install (install.sh) and on every `update` (which re-runs
# install.sh). Both target plugins are global-only and installed into BOTH
# Claude config dirs (~/.claude and ~/.claude-work) by the underlying functions.
#
# Why this exists: ECC's language rules are NOT tracked in this repo (see
# claude/rules/.gitignore) -- they are installer-managed, re-vendored from the
# ECC repo by ecc-install/ecc-update. A fresh clone therefore has no rules until
# ECC is installed, so the install must do it. This makes the dotfiles
# self-contained again without committing third-party rule content.
#
# Implementation: ecc-install and superpowers-install are zsh functions in
# zsh/functions.zsh (self-contained, needing only $DOTFILEDIR). We call them via
# a non-interactive zsh rather than duplicating ~80 lines of marketplace/plugin
# logic in bash -- single source of truth, no drift. Failures warn but never
# abort the install: a machine with assets but no plugins is still usable, and
# plugin installs commonly fail offline or before `claude` login.

# Resolve DOTFILEDIR when sourced standalone (install.sh already exports it).
if [ -z "${DOTFILEDIR:-}" ]; then
  SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  source "$SCRIPT_DIR/resolve_dotfiledir.sh"
fi

if ! command -v claude >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: claude CLI not on PATH; skipping ECC/Superpowers install." >&2
elif ! command -v zsh >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: zsh not on PATH; skipping ECC/Superpowers install." >&2
else
  echo "[claude-plugins] Installing/refreshing ECC + Superpowers plugins (both config dirs)..."
  # ecc-install also clones/pulls the ECC repo and re-vendors rules; both
  # functions are idempotent and safe to re-run on every update.
  DOTFILEDIR="$DOTFILEDIR" zsh -c '
    source "$DOTFILEDIR/zsh/functions.zsh"
    ecc-install
    superpowers-install
  ' || echo "[claude-plugins] WARNING: ECC/Superpowers install reported an error (offline, or claude not logged in?)." >&2
fi
