#!/usr/bin/env bash
set -euo pipefail

# claude-plugins.sh - post-link plugin reconciliation for Claude and Codex
#
# Runs on full install (install.sh) and on every `update --ai`. No plugin is
# installed here any more: Superpowers and ECC are retired. This step re-runs
# the Codex workflow dedupe so retired Codex plugin copies stay disabled.

# Resolve DOTFILEDIR when sourced standalone (install.sh already exports it).
if [ -z "${DOTFILEDIR:-}" ]; then
  SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
  source "$SCRIPT_DIR/resolve_dotfiledir.sh"
fi

source "$DOTFILEDIR/install/common/codex-plugin-dedupe.sh"
reconcile_codex_workflow_plugins_for_install
