#!/usr/bin/env bash
# session-start.sh - Bootstrap the Claude layer for dotfiles web sessions.
#
# Claude Code on the web spins up a fresh, ephemeral container per environment.
# This SessionStart hook runs the repo's own bootstrap-cloud.sh so that working
# on the dotfiles repo from the web gets the same Claude layer a cloud setup
# script would provide: symlinked assets plus the ECC and Superpowers plugins.
#
# Web-only: a normal machine install already manages ~/.claude via symlinks, so
# this is a no-op off the remote container (guarded by CLAUDE_CODE_REMOTE).
# Synchronous and idempotent: safe to run on every session start.

set -euo pipefail

# Only run in Claude Code on the web; do nothing on a developer's real machine.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# CLAUDE_PROJECT_DIR is the repo root; fall back to this script's location.
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

"$PROJECT_DIR/bootstrap-cloud.sh"
