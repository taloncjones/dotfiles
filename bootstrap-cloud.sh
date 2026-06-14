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
INSTALLED_PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
PLUGIN_RETRIES=5

# True iff the plugin id (name@marketplace) is recorded in installed_plugins.json.
# This file is the on-disk ground truth: `claude plugins install` can exit 0
# without writing it (see ensure_plugin), so the exit status alone is a lie.
plugin_installed() {
  local plugin_id="$1"
  [ -f "$INSTALLED_PLUGINS_JSON" ] || return 1
  grep -q "$plugin_id" "$INSTALLED_PLUGINS_JSON"
}

# Deterministically install one plugin and PROVE it landed.
#   $1 plugin id          e.g. superpowers@claude-plugins-official
#   $2 marketplace name   e.g. claude-plugins-official
#   $3 marketplace add url (optional; for marketplaces not pre-bundled, e.g. ECC)
#
# Why the retry loop: on a cold container the github-backed official marketplace
# may not have finished its first network fetch, so `plugins install` resolves
# the plugin to "nothing to do" and exits 0 WITHOUT installing -- the silent
# failure this script exists to defeat. ECC's plain git marketplace clones
# synchronously and usually wins the race, which is why it appeared to "work."
# A later SessionStart:resume succeeded only because the cache had since warmed.
# We refresh the marketplace before every attempt to force that warmup, then
# verify against installed_plugins.json instead of trusting the exit code.
ensure_plugin() {
  local plugin_id="$1" marketplace="$2" add_url="${3:-}"

  if plugin_installed "$plugin_id"; then
    echo "[bootstrap-cloud] OK: $plugin_id already installed."
    return 0
  fi

  # Register the marketplace if missing (idempotent). Pre-bundled marketplaces
  # (no add_url) are assumed present; a missing one surfaces via the retries.
  if ! claude plugin marketplace list 2>/dev/null | grep -qiw "$marketplace"; then
    if [ -n "$add_url" ]; then
      claude plugin marketplace add "$add_url" \
        || echo "[bootstrap-cloud] WARNING: marketplace add for $marketplace failed (offline?)" >&2
    else
      echo "[bootstrap-cloud] WARNING: marketplace $marketplace not registered and no add URL known." >&2
    fi
  fi

  local attempt=1 delay=2
  while [ "$attempt" -le "$PLUGIN_RETRIES" ]; do
    # Warm/refresh the marketplace cache before each install attempt.
    claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
    claude plugins install "$plugin_id" >/dev/null 2>&1 || true

    if plugin_installed "$plugin_id"; then
      echo "[bootstrap-cloud] OK: installed $plugin_id (attempt $attempt/$PLUGIN_RETRIES)."
      return 0
    fi

    if [ "$attempt" -lt "$PLUGIN_RETRIES" ]; then
      echo "[bootstrap-cloud] $plugin_id not in installed_plugins.json yet" \
           "(attempt $attempt/$PLUGIN_RETRIES); retrying in ${delay}s..." >&2
      sleep "$delay"
      delay=$(( delay * 2 ))
    fi
    attempt=$(( attempt + 1 ))
  done

  echo "[bootstrap-cloud] !! FAILED: $plugin_id not installed after $PLUGIN_RETRIES attempts." >&2
  echo "[bootstrap-cloud] !! Its skills/commands are UNAVAILABLE this session." >&2
  echo "[bootstrap-cloud] !! Recover with: claude plugins install $plugin_id" >&2
  return 1
}

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
  # Both plugins go through the same verify-then-retry path so neither can fail
  # silently. ECC ships its own git marketplace (added by URL); superpowers lives
  # in the pre-bundled official github marketplace.
  plugin_status=0
  ensure_plugin "ecc@ecc" "ecc" "$ECC_REPO_URL" || plugin_status=1
  ensure_plugin "superpowers@claude-plugins-official" "claude-plugins-official" || plugin_status=1
  if [ "$plugin_status" -ne 0 ]; then
    echo "[bootstrap-cloud] WARNING: one or more plugins did not install; see FAILED lines above." >&2
  fi
fi

echo "[bootstrap-cloud] Done. Plugins and settings load with the NEXT session;"
echo "[bootstrap-cloud] an already-running session picks up skills/commands only."
