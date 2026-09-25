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

# link_claude_config_dir tolerates a failed sweep and reconcile (|| true)
# because the full install must not die half-way on a machine without
# python3. The scoped path exists precisely to deliver template changes and
# finish plugin retirements, so here a step that cannot run IS a failure.
# The sweep's failure is deferred so the reconcile and Codex steps still run.
sweep_status=0
sweep_retired_claude_plugins "$HOME"/.claude "[ai-update]" || sweep_status=1
sweep_retired_claude_plugins "$HOME"/.claude-work "[ai-update]" || sweep_status=1
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$HOME"/.claude/settings.json "[ai-update]"
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$HOME"/.claude-work/settings.json "[ai-update]"

echo "[ai-update] Reconciling Codex surfaces..."
source "$DOTFILEDIR"/install/common/codex-links.sh
link_codex_surfaces

echo "[ai-update] Refreshing plugins..."
source "$DOTFILEDIR"/install/common/claude-plugins.sh

if [ "$sweep_status" -ne 0 ]; then
  echo "[ai-update] [X] retired plugin sweep incomplete; see the [X] lines above"
  exit 1
fi
echo "[ai-update] Done."
