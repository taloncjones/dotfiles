#!/usr/bin/env bash
# claude-links.sh - Shared Claude Code config-dir linking functions
#
# Sourced (not executed) by install/common/link.sh for full machine installs
# and by bootstrap-cloud.sh for ephemeral cloud containers. Defines functions
# only; callers decide which config dirs to link.
#
# Requires: DOTFILEDIR must be set before calling the functions.

# Seed a machine-local file from a template, with defensive symlink + size guards.
# Why this exists: the destination is intended to be a real file (Claude/plugin
# installers write into it), but earlier dotfiles installs symlinked it to a repo
# path. If that repo moves or is deleted, the symlink dangles silently. Worse,
# if the symlink is intact, Claude CLI writes through the symlink and pollutes
# the dotfiles repo with machine-local state.
#   1. rm -f any pre-existing symlink at the destination. The [ -L ] guard
#      below is what protects real files — rm -f happily removes regular
#      files too; the only thing -f does is suppress "no such file" errors.
#   2. cp template if no regular file exists.
#   3. Warn if the existing file is suspiciously small (<50% of template size),
#      which usually means a prior corruption (e.g. Claude CLI rewrote the file
#      from scratch through a stale symlink, dropping plugin/hook config).
seed_machine_local_file() {
  local template="$1"
  local dest="$2"

  if [ -L "$dest" ]; then
    echo "[claude-links] Removing pre-existing symlink at $dest (machine-local file expected)"
    rm -f "$dest"
  fi

  if [ ! -f "$dest" ]; then
    cp "$template" "$dest"
    return
  fi

  local tmpl_size dest_size
  tmpl_size=$(wc -c <"$template" 2>/dev/null | tr -d ' ')
  dest_size=$(wc -c <"$dest" 2>/dev/null | tr -d ' ')
  if [ -n "$tmpl_size" ] && [ -n "$dest_size" ] && [ "$tmpl_size" -gt 0 ]; then
    if [ "$(( dest_size * 2 ))" -lt "$tmpl_size" ]; then
      echo "[claude-links] WARNING: $dest is ${dest_size}B but template is ${tmpl_size}B."
      echo "[claude-links]          Existing file may be corrupted (prior install wrote through a stale symlink)."
      echo "[claude-links]          Re-seed manually: rm $dest && cp $template $dest"
    fi
  fi
}

# Reconcile a machine-local settings.json with the tracked template.
#
# seed_machine_local_file copies the template only when the destination is
# ABSENT, so template changes never reach an existing settings.json on their
# own (seed-once design). This merge closes that gap and is safe to run on
# every install/update:
#   - template-owned keys (hooks, statusLine, permissions, env, ...) come from
#     the template -- template drift is reconciled away;
#   - plugin-installer-owned keys (enabledPlugins, extraKnownMarketplaces) are
#     unioned with live state winning on conflict, so nothing an installer
#     wrote is lost;
#   - keys the template does not define are preserved as-is.
# A corrupt/unparseable destination is rebuilt from the template. Idempotent.
# History: the merge logic originated in bootstrap-cloud.sh (910f2bc), which
# now delegates here; machines get the same treatment on every `update`.
# Usage: reconcile_claude_settings_file <template> <dest> [label]
reconcile_claude_settings_file() {
  local tmpl="$1"
  local dest="$2"
  local label="${3:-[claude-links]}"

  if [ ! -f "$tmpl" ]; then
    echo "$label WARNING: settings template missing at $tmpl; skipping reconcile." >&2
    return 1
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    echo "$label WARNING: python3 not on PATH; cannot reconcile settings.json." >&2
    echo "$label          Template changes must be merged into $dest by hand." >&2
    return 1
  fi

  RECONCILE_LABEL="$label" python3 - "$tmpl" "$dest" <<'PY'
import json, os, sys

label = os.environ.get("RECONCILE_LABEL", "[claude-links]")
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
print(label + " Reconciled settings.json (SessionStart: "
      + (", ".join(c for c in cmds if c) or "none") + ").")
PY
}

# Link the dotfiles-managed Claude Code assets into one config dir.
# Two config dirs share the same dotfiles-managed assets via symlinks:
#   ~/.claude       personal account (default; desktop app lands here)
#   ~/.claude-work  work account (selected by the claude() zsh wrapper under ~/Git/work)
# settings.json stays machine-local PER DIR (plugin installers write to it);
# both copies are drift-checked by claude/hooks/claude-hooks.test.sh.
# rm -rf first because ln -sf can't overwrite directory symlinks atomically.
link_claude_config_dir() {
  local cdir="${1:?link_claude_config_dir: config dir required}"

  mkdir -p "$cdir"

  # Sweep the retired interview symlink (its target was never tracked; public
  # clones would get a dangling link) and back up any REAL dir sitting where a
  # symlink belongs -- rm -rf on a real commands/agents/hooks dir would eat
  # user content that was never vendored into the repo.
  local d
  for d in commands agents hooks interview; do
    if [[ -d "$cdir/$d" && ! -L "$cdir/$d" ]]; then
      mv "$cdir/$d" "$cdir/$d.bak.$(date +%Y%m%d-%H%M%S)"
      echo "[claude-links] Backed up pre-existing $cdir/$d (real dir) before symlinking."
    fi
  done
  rm -rf "$cdir"/commands "$cdir"/agents "$cdir"/hooks "$cdir"/interview
  ln -sf "$DOTFILEDIR"/claude/CLAUDE.md "$cdir"/CLAUDE.md

  # Standing operating principles: the committed, model-agnostic discipline file
  # that CLAUDE.md @imports into every session.
  ln -sf "$DOTFILEDIR"/claude/operating-principles.md "$cdir"/operating-principles.md

  # Optional per-model audit deep-dives are local-only and gitignored (they hold
  # private session content). Link them only when present, so a public clone that
  # lacks them does not create dangling symlinks.
  local ref
  for ref in Fable5.md Opus4.md; do
    if [ -f "$DOTFILEDIR/claude/$ref" ]; then
      ln -sf "$DOTFILEDIR/claude/$ref" "$cdir/$ref"
    fi
  done

  # Rules: claude/rules is symlinked here as the single asset source. Claude
  # Code natively auto-loads every .md under ~/.claude/rules at launch (`paths:`
  # frontmatter scopes to matching files; none = every session). Only our own
  # always-on rules under claude/rules/shared/ are tracked; ECC rules vendoring
  # is RETIRED (2026-07-02) -- the upstream tree lives in the ECC marketplace
  # clone (~/.claude/plugins/marketplaces/ecc/rules/), and any language dirs
  # still sitting in claude/rules are pre-retirement leftovers that STILL
  # auto-load, flagged for removal by _ecc_legacy_rules_notice
  # (claude/rules/.gitignore keeps them uncommitted).
  # One-time migration: older machines have rules as a REAL directory (from a
  # blanket ECC install). Preserve it as a timestamped backup before replacing
  # it with the symlink, in case it holds hand-edited rules not yet saved.
  # Steady state it is already a symlink, which rm -rf drops by link only
  # (never recursing into the dotfiles target), so re-runs stay idempotent.
  if [[ -d "$cdir/rules" && ! -L "$cdir/rules" ]]; then
    mv "$cdir/rules" "$cdir/rules.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[claude-links] Backed up pre-existing $cdir/rules (real dir) before symlinking."
  fi
  rm -rf "$cdir"/rules
  ln -sfn "$DOTFILEDIR"/claude/rules "$cdir"/rules

  # Skills: whole-dir symlink into the dotfiles repo, but only PERSONAL skills
  # are version-controlled (see claude/skills/.gitignore, which whitelists
  # them). ECC marketplace skills and continuous-learning's generated
  # `learned/` live in the same dir untracked, and their installers keep
  # writing to this path through the symlink. Same real-dir -> symlink
  # migration as rules above.
  if [[ -d "$cdir/skills" && ! -L "$cdir/skills" ]]; then
    mv "$cdir/skills" "$cdir/skills.bak.$(date +%Y%m%d-%H%M%S)"
    echo "[claude-links] Backed up pre-existing $cdir/skills (real dir) before symlinking."
  fi
  rm -rf "$cdir"/skills
  ln -sfn "$DOTFILEDIR"/claude/skills "$cdir"/skills

  # settings.json is machine-local (plugin installers like GSD/ECC write to it).
  # Seed from template on first install, then reconcile template drift on every
  # run -- plugin-installer keys survive the merge (see reconcile_claude_settings_file).
  seed_machine_local_file "$DOTFILEDIR"/claude/settings.json.tmpl "$cdir"/settings.json
  reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$cdir"/settings.json || true
  ln -sf "$DOTFILEDIR"/claude/commands "$cdir"/commands
  ln -sf "$DOTFILEDIR"/claude/agents "$cdir"/agents
  ln -sf "$DOTFILEDIR"/claude/hooks "$cdir"/hooks

  # Statusline (referenced by statusLine.command in settings.json). Sweep the
  # stale statusline.sh symlink from earlier setups before linking the current one.
  rm -f "$cdir"/statusline.sh
  ln -sf "$DOTFILEDIR"/claude/statusline.js "$cdir"/statusline.js
}
