#!/usr/bin/env bash
set -euo pipefail

# claude-plugins.sh - Install/refresh ECC and Superpowers for Claude and Codex
#
# Runs on full install (install.sh) and on every `update` (which re-runs
# install.sh). Claude plugins are installed into both account config dirs;
# native Codex plugins are installed independently into CODEX_HOME.
#
# Why this exists: the upstream workflow repositories remain independently
# owned, while these functions provide one lifecycle command for both agent
# runtimes. ECC's Codex package is staged as a self-contained native plugin;
# no Claude plugin files are shared with Codex.
#
# Implementation: ecc-install and superpowers-install are zsh functions in
# zsh/functions.zsh. We call them through non-interactive zsh so manual and
# bootstrap installs share one implementation. Runtime failures are reported
# independently and do not prevent the other plugin command from running.

# Resolve DOTFILEDIR when sourced standalone (install.sh already exports it).
if [ -z "${DOTFILEDIR:-}" ]; then
  SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  source "$SCRIPT_DIR/resolve_dotfiledir.sh"
fi

if ! command -v zsh >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: zsh not on PATH; skipping ECC/Superpowers install." >&2
elif ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
  echo "[claude-plugins] WARNING: neither Claude nor Codex CLI is on PATH; skipping ECC/Superpowers install." >&2
else
  echo "[claude-plugins] Installing/refreshing ECC + Superpowers for Claude and Codex..."
  # Both functions are idempotent and safe to re-run on every update.
  DOTFILEDIR="$DOTFILEDIR" zsh -c '
    source "$DOTFILEDIR/zsh/functions.zsh"
    ecc-install || ecc_status=$?
    superpowers-install || superpowers_status=$?
    (( ${ecc_status:-0} == 0 && ${superpowers_status:-0} == 0 ))
  ' || echo "[claude-plugins] WARNING: ECC/Superpowers install reported an error (offline, or claude not logged in?)." >&2
fi
