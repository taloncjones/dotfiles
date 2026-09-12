#!/usr/bin/env bash
# ai-update.sh - Scoped update for the Claude/Codex layer only.
#
# Invoked by `update --ai` (zsh/functions.zsh). Refreshes symlinks, reconciles
# settings.json from the template, and runs the plugin + Codex reconcilers.
# Deliberately skips everything machine-bound: brew, VS Code, oh-my-zsh, ssh,
# git identity, macOS defaults. Needs no sudo. Idempotent.
#
# Step ownership: the Claude config-dir steps live in claude-links.sh and the
# Codex surface steps in codex-links.sh; install.sh/link.sh run the same
# functions, so the step list exists in exactly one place.
set -euo pipefail

SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$SCRIPT_DIR/resolve_dotfiledir.sh"

source "$DOTFILEDIR"/install/common/claude-links.sh
echo "[ai-update] Linking Claude config dirs..."
link_claude_config_dir "$HOME"/.claude
link_claude_config_dir "$HOME"/.claude-work

# link_claude_config_dir tolerates a failed reconcile (|| true) because the
# full install must not die half-way on a machine without python3. The scoped
# path exists precisely to deliver template changes, so here a reconcile that
# cannot run IS a failure: re-run it strictly (idempotent) for both dirs.
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$HOME"/.claude/settings.json "[ai-update]"
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$HOME"/.claude-work/settings.json "[ai-update]"

echo "[ai-update] Reconciling Codex surfaces..."
source "$DOTFILEDIR"/install/common/codex-links.sh
link_codex_surfaces

echo "[ai-update] Refreshing plugins..."
source "$DOTFILEDIR"/install/common/claude-plugins.sh

echo "[ai-update] Done."
