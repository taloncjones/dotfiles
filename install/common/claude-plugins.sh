#!/usr/bin/env bash
set -euo pipefail

# claude-plugins.sh - Install/refresh Superpowers for Claude and Codex
#
# Runs on full install (install.sh) and on every `update` (which re-runs
# install.sh). Claude plugins are installed into both account config dirs;
# native Codex plugins are installed independently into CODEX_HOME.
#
# Why this exists: the upstream workflow repository remains independently
# owned, while these functions provide one lifecycle command for both agent
# runtimes.
#
# Implementation: superpowers-install is a zsh function in
# zsh/functions.zsh. We call it through non-interactive zsh so manual and
# bootstrap installs share one implementation.

# Resolve DOTFILEDIR when sourced standalone (install.sh already exports it).
if [ -z "${DOTFILEDIR:-}" ]; then
  SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  source "$SCRIPT_DIR/resolve_dotfiledir.sh"
fi

if ! command -v zsh >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: zsh not on PATH; skipping Superpowers install." >&2
elif ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: neither Claude nor Codex CLI is on PATH; skipping Superpowers install." >&2
else
  echo "[claude-plugins] Installing/refreshing Superpowers for Claude and Codex..."
  # Idempotent and safe to re-run on every update.
  DOTFILEDIR="$DOTFILEDIR" zsh -c '
    source "$DOTFILEDIR/zsh/functions.zsh"
    superpowers-install || superpowers_status=$?
    (( ${superpowers_status:-0} == 0 ))
  ' || echo "[claude-plugins] WARNING: Superpowers install reported an error (offline, or claude not logged in?)." >&2
fi

# The installs above may have just enabled the canonical dotfiles-workflows
# providers; re-run the dedupe so duplicate upstream entries are disabled in
# this same cycle. The link-time run (link.sh) happens before the installs and
# skips deduplication on a first install/migration, where the canonical
# providers do not exist yet.
source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"
reconcile_codex_workflow_plugins_for_install
