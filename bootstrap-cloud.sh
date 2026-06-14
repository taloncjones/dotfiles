#!/usr/bin/env bash
# bootstrap-cloud.sh - Minimal Claude Code setup for ephemeral cloud containers
#
# Cloud sessions (claude.ai/code web, remote sandboxes) get a fresh container
# whose ~/.claude dies with it. This script recreates the dotfiles-managed
# Claude layer only: symlinked assets (CLAUDE.md, commands, agents, hooks,
# skills, rules, statusline), the ECC and Superpowers plugins, and a
# settings.json reconciled from the template so the full dotfiles config
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
ECC_REPO_URL="https://github.com/affaan-m/ECC.git"
PERSONAL_GITCONFIG="$DOTFILEDIR/git/personal/.gitconfig-personal"
PLATFORM_DEFAULT_EMAIL="noreply@anthropic.com"
INSTALLED_PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
# Generous on purpose. The github-backed official marketplace warms its first
# fetch asynchronously and can take 70s+ on a cold container -- longer than a
# 5-retry budget (2+4+8+16 = 30s) survives, which is exactly how superpowers
# lost the race while ECC's synchronous git marketplace won it. 8 retries with
# exponential backoff (2+4+8+16+32+64 = ~126s) outlasts that warmup. This cost
# is paid once: in the canonical Setup-script placement (see header) the install
# runs pre-launch and the result is filesystem-snapshotted, so later sessions
# skip it entirely.
PLUGIN_RETRIES=8

# True iff the plugin id (name@marketplace) is recorded in installed_plugins.json.
# This file is the on-disk ground truth: `claude plugins install` can exit 0
# without writing it (see ensure_plugin), so the exit status alone is a lie.
plugin_installed() {
  local plugin_id="$1"
  [ -f "$INSTALLED_PLUGINS_JSON" ] || return 1
  grep -q "$plugin_id" "$INSTALLED_PLUGINS_JSON"
}

# True iff the marketplace's on-disk manifest declares the plugin. The manifest
# (.claude-plugin/marketplace.json) is the resolver's source of truth: a
# github-backed marketplace can be registered but still mid-fetch on a cold
# container, and `claude plugins install` then no-ops with exit 0 because the
# plugin is not yet listed. Waiting on this condition turns that blind timed
# race into a deterministic wait.
marketplace_lists_plugin() {
  local plugin_name="$1" marketplace="$2"
  local manifest="$HOME/.claude/plugins/marketplaces/$marketplace/.claude-plugin/marketplace.json"
  [ -f "$manifest" ] || return 1
  grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${plugin_name}\"" "$manifest"
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
# We first WAIT for the marketplace manifest to actually list the plugin (the
# condition the install resolver checks), refreshing the cache to force warmup,
# then install and verify against installed_plugins.json instead of trusting the
# exit code.
ensure_plugin() {
  local plugin_id="$1" marketplace="$2" add_url="${3:-}"
  local plugin_name="${plugin_id%@*}"

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

  # Phase 1: wait until the marketplace manifest lists the plugin. This is the
  # cold-start race the github-backed official marketplace loses: it is
  # registered but its first fetch has not landed, so install no-ops. Polling
  # the manifest (refreshing between checks) is deterministic, not a blind timer.
  local attempt=1 delay=2
  while ! marketplace_lists_plugin "$plugin_name" "$marketplace"; do
    claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
    marketplace_lists_plugin "$plugin_name" "$marketplace" && break
    if [ "$attempt" -ge "$PLUGIN_RETRIES" ]; then
      echo "[bootstrap-cloud] WARNING: $marketplace manifest never listed" \
           "$plugin_name after $PLUGIN_RETRIES refreshes; installing anyway." >&2
      break
    fi
    echo "[bootstrap-cloud] $marketplace manifest not warm yet" \
         "(attempt $attempt/$PLUGIN_RETRIES); retrying in ${delay}s..." >&2
    sleep "$delay"
    delay=$(( delay * 2 ))
    attempt=$(( attempt + 1 ))
  done

  # Phase 2: install and verify it actually landed in installed_plugins.json.
  attempt=1; delay=2
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

# Reconcile ~/.claude/settings.json with the dotfiles template.
#
# seed_machine_local_file (the linking step) only copies the template when the
# destination is ABSENT. In a cloud container the plugin installers create
# settings.json first -- writing just enabledPlugins/extraKnownMarketplaces --
# so the seed is skipped and the dotfiles-managed keys (the SessionStart
# orchestrator + account_guard hooks, statusLine, permissions, env) never land.
# The result is a session that has the plugins but none of the dotfiles
# behaviour. We run AFTER the installs and merge: the template supplies the
# canonical dotfiles config, while the plugin-installer keys are unioned in so
# nothing the installers wrote is lost. Idempotent.
reconcile_claude_settings() {
  local tmpl="$DOTFILEDIR/claude/settings.json.tmpl"
  local dest="$HOME/.claude/settings.json"

  if [ ! -f "$tmpl" ]; then
    echo "[bootstrap-cloud] WARNING: settings template missing at $tmpl; skipping reconcile." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[bootstrap-cloud] WARNING: python3 not on PATH; cannot reconcile settings.json." >&2
    echo "[bootstrap-cloud]          Orchestrator/account-guard hooks may be absent this session." >&2
    return 1
  fi

  python3 - "$tmpl" "$dest" <<'PY'
import json, os, sys

tmpl_path, dest_path = sys.argv[1], sys.argv[2]
with open(tmpl_path) as fh:
    tmpl = json.load(fh)

dest = {}
if os.path.isfile(dest_path) and os.path.getsize(dest_path):
    try:
        with open(dest_path) as fh:
            dest = json.load(fh)
    except json.JSONDecodeError:
        dest = {}  # corrupt/partial -- the template rebuild below is authoritative

# Keys the plugin installers own: union them so installed plugins/marketplaces
# survive (live state wins on conflict). Everything else comes from the template.
PLUGIN_KEYS = ("enabledPlugins", "extraKnownMarketplaces")
result = dict(tmpl)
for key in PLUGIN_KEYS:
    merged = dict(tmpl.get(key, {}))
    merged.update(dest.get(key, {}))
    if merged:
        result[key] = merged

# Preserve any platform/installer keys the template does not define.
for key, value in dest.items():
    if key not in result:
        result[key] = value

os.makedirs(os.path.dirname(dest_path), exist_ok=True)
with open(dest_path, "w") as fh:
    json.dump(result, fh, indent=2)
    fh.write("\n")

ss = result.get("hooks", {}).get("SessionStart", [])
cmds = [os.path.basename(h.get("command", "")) for grp in ss for h in grp.get("hooks", [])]
print("[bootstrap-cloud] Reconciled settings.json (SessionStart: "
      + (", ".join(c for c in cmds if c) or "none") + ").")
PY
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
