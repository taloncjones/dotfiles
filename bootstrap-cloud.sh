#!/usr/bin/env bash
# bootstrap-cloud.sh - Minimal Claude Code setup for ephemeral cloud containers
#
# Cloud sessions (claude.ai/code web, remote sandboxes) get a fresh container
# whose ~/.claude dies with it. This script recreates the dotfiles-managed
# Claude layer only: symlinked assets (CLAUDE.md, commands, agents, hooks,
# skills, rules, statusline; Superpowers is retired, so no plugin is
# installed here), and a settings.json reconciled from the template so the
# full dotfiles config
# (SessionStart orchestrator + account_guard hooks, statusLine, permissions,
# env) is present -- not just the keys the plugin installers write. It also
# reattributes git commits to the tracked personal identity, because the cloud
# platform defaults the author to "Claude <noreply@anthropic.com>" and the
# dotfiles rule is that commits are human-authored. It deliberately skips the
# rest of the machine-bound full install (brew, zsh, ssh, codex, macOS
# defaults) and the work config dir (~/.claude-work): cloud containers are
# single-account (personal) by design.
#
# Placement matters. Plugins load at Claude Code launch, so WHERE this runs
# decides whether they are usable on the FIRST session:
#
#   CANONICAL -- the cloud environment's Setup script field (claude.ai/code UI).
#     Runs BEFORE Claude Code launches and its disk writes (plugin cache +
#     installed_plugins.json + settings.json) are filesystem-snapshotted and
#     reused, so plugins are present at launch on session 1 and the install is
#     skipped on every later session. This is the only placement that makes
#     plugins available on the first session. Paste into the Setup script field:
#       git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
#       "$HOME/dotfiles/bootstrap-cloud.sh"
#
#   FALLBACK -- the repo SessionStart hook (.claude/hooks/session-start.sh).
#     Runs AFTER launch, so a plugin it installs is not usable until the NEXT
#     session. Kept as an idempotent self-heal for snapshot/cache expiry; it is
#     NOT a substitute for the Setup-script placement above.
#
# Custom base images are not supported by claude.ai/code; the Setup-script
# snapshot is the sanctioned equivalent of a pre-baked image.
#
# Flags:
#   --no-plugins   skip plugin installs (used by the smoke test; also useful offline)
#
# Idempotent: safe to run on every session start. Plugin failures warn but do
# not abort -- a half-bootstrapped session (assets without plugins) is still
# better than none.

set -euo pipefail

DOTFILEDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSONAL_GITCONFIG="$DOTFILEDIR/git/personal/.gitconfig-personal"
PLATFORM_DEFAULT_EMAIL="noreply@anthropic.com"

# Settings reconcile: the merge (template supplies the canonical dotfiles
# config; plugin-installer keys are unioned in so nothing the installers wrote
# is lost) lives in install/common/claude-links.sh as
# reconcile_claude_settings_file, shared with the machine link path so both
# environments get identical treatment. It matters here because in a cloud
# container the plugin installers create settings.json first -- writing just
# enabledPlugins/extraKnownMarketplaces -- so the seed-if-absent step is
# skipped and the dotfiles-managed keys (SessionStart orchestrator +
# account_guard hooks, statusLine, permissions, env) never land without the
# merge (910f2bc).
reconcile_claude_settings() {
  reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$HOME/.claude/settings.json" "[bootstrap-cloud]"
}

# Reattribute git commits to the tracked personal identity.
#
# Cloud containers seed git user.name/email to "Claude <noreply@anthropic.com>";
# the dotfiles rule is that commits are human-authored. Pull name + email ONLY
# from the tracked personal gitconfig -- never its signing block, whose
# commit.gpgsign via 1Password op-ssh-sign would make every commit fail in a
# container without 1Password. Only overrides the platform default: a real
# identity already set (e.g. by an includeIf in a mounted repo) is left alone.
reattribute_git_identity() {
  command -v git >/dev/null 2>&1 || return 0
  if [ ! -f "$PERSONAL_GITCONFIG" ]; then
    echo "[bootstrap-cloud] WARNING: $PERSONAL_GITCONFIG missing; leaving git identity as-is." >&2
    return 1
  fi

  local cur_email
  cur_email="$(git config --global user.email 2>/dev/null || true)"
  if [ -n "$cur_email" ] && [ "$cur_email" != "$PLATFORM_DEFAULT_EMAIL" ]; then
    return 0  # a real identity is already configured; do not clobber it
  fi

  local name email
  name="$(git config -f "$PERSONAL_GITCONFIG" user.name 2>/dev/null || true)"
  email="$(git config -f "$PERSONAL_GITCONFIG" user.email 2>/dev/null || true)"
  if [ -z "$name" ] || [ -z "$email" ]; then
    echo "[bootstrap-cloud] WARNING: personal name/email incomplete in $PERSONAL_GITCONFIG; identity unchanged." >&2
    return 1
  fi

  git config --global user.name "$name"
  git config --global user.email "$email"
  # Signing is unavailable in a container; make sure nothing forces it on.
  git config --global commit.gpgsign false
  echo "[bootstrap-cloud] Git author set to $name <$email> (was the platform default)."
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

reattribute_git_identity || true

# No plugin is installed in cloud sessions any more (Superpowers and ECC are retired).
# --no-plugins is still accepted for existing callers.
if [ "$NO_PLUGINS" -eq 1 ]; then
  echo "[bootstrap-cloud] --no-plugins: nothing to skip (no plugins are installed)."
fi

# Reconcile settings.json LAST so it captures whatever plugins ended up enabled
# and reasserts the dotfiles-managed config the installers do not write.
reconcile_claude_settings || true

# The reconciled hooks/statusLine need these at runtime; warn (do not abort) so a
# missing interpreter is visible rather than silently degrading the session.
command -v python3 >/dev/null 2>&1 \
  || echo "[bootstrap-cloud] WARNING: python3 not on PATH; SessionStart/guard hooks will not run." >&2
command -v node >/dev/null 2>&1 \
  || echo "[bootstrap-cloud] WARNING: node not on PATH; statusLine will not render." >&2

echo "[bootstrap-cloud] Done. Plugins and settings load with the NEXT session;"
echo "[bootstrap-cloud] an already-running session picks up skills/commands only."
