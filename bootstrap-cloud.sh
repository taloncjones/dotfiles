#!/usr/bin/env bash
# bootstrap-cloud.sh - Minimal Claude Code setup for ephemeral cloud containers
#
# Cloud sessions (claude.ai/code web, remote sandboxes) get a fresh container
# whose ~/.claude dies with it. This script recreates the dotfiles-managed
# Claude layer only: symlinked assets (CLAUDE.md, commands, agents, hooks,
# skills, rules, statusline) plus a seeded settings.json, then installs the
# ECC and Superpowers plugins. It deliberately skips everything machine-bound
# in the full install (brew, zsh, ssh, git identity, codex, macOS defaults).
#
# Usage (cloud environment setup script or repo SessionStart hook):
#   git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || true
#   "$HOME/dotfiles/bootstrap-cloud.sh"
#
# Flags:
#   --no-plugins   skip plugin installs (used by the smoke test; also useful offline)
#
# Idempotent: safe to run on every session start. Plugin failures warn but do
# not abort -- a half-bootstrapped session (assets without plugins) is still
# better than none.

set -euo pipefail

DOTFILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ECC_REPO_URL="https://github.com/affaan-m/ECC.git"

NO_PLUGINS=0
for arg in "$@"; do
  case "$arg" in
    --no-plugins) NO_PLUGINS=1 ;;
    *) echo "[bootstrap-cloud] Unknown argument: $arg (supported: --no-plugins)" >&2; exit 2 ;;
  esac
done

source "$DOTFILEDIR/install/common/claude-links.sh"

echo "[bootstrap-cloud] Linking Claude assets into $HOME/.claude..."
link_claude_config_dir "$HOME/.claude"

if [ "$NO_PLUGINS" -eq 1 ]; then
  echo "[bootstrap-cloud] Skipping plugin installs (--no-plugins)."
elif ! command -v claude >/dev/null 2>&1; then
  echo "[bootstrap-cloud] WARNING: claude CLI not on PATH; skipping plugin installs." >&2
else
  echo "[bootstrap-cloud] Ensuring plugin marketplaces + installs..."
  if ! claude plugin marketplace list 2>/dev/null | grep -qiw ecc; then
    claude plugin marketplace add "$ECC_REPO_URL" \
      || echo "[bootstrap-cloud] WARNING: ECC marketplace add failed (offline?)" >&2
  fi
  if ! claude plugins list 2>/dev/null | grep -q "ecc@ecc"; then
    claude plugins install ecc@ecc \
      || echo "[bootstrap-cloud] WARNING: ECC plugin install failed" >&2
  fi
  if ! claude plugins list 2>/dev/null | grep -q "superpowers@claude-plugins-official"; then
    claude plugins install superpowers@claude-plugins-official \
      || echo "[bootstrap-cloud] WARNING: Superpowers plugin install failed" >&2
  fi
fi

echo "[bootstrap-cloud] Done. Plugins and settings load with the NEXT session;"
echo "[bootstrap-cloud] an already-running session picks up skills/commands only."
