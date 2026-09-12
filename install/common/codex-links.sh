#!/usr/bin/env bash
# codex-links.sh - Codex surface layer (symlinks, hook registrations, plugin
# reconcilers), extracted from install/common/link.sh so the full install and
# `update --ai` (install/common/ai-update.sh) share ONE step list.
# Sourced, never executed: defines link_codex_surfaces; the caller provides
# DOTFILEDIR and runs it after the Claude config dirs are linked.

# These are repo-owned workflows, shared from one maintained source. Native
# ECC and Superpowers plugin installations remain independent per runtime.
link_codex_path() {
  local source="$1"
  local destination="$2"
  if [ -e "$destination" ] && [ ! -L "$destination" ]; then
    echo "[WARNING] Preserving existing Codex path: $destination; skipping managed symlink." >&2
    return 0
  fi
  ln -sfn "$source" "$destination"
}

ensure_codex_hooks_feature() {
  local config="$HOME"/.codex/config.toml
  local tmp="$config.tmp.$$"

  # First: always clean up the legacy [features].codex_hooks key if present.
  # Codex emits a deprecation warning at startup until the legacy key is gone,
  # regardless of which installer owns the config. We branch on whether the
  # canonical `hooks = true` already exists alongside it (e.g. an older
  # dotfiles install wrote codex_hooks before GSD added hooks):
  #   - both keys present  -> delete the legacy codex_hooks line (a rename
  #                           would produce duplicate hooks=true, the exact
  #                           TOML duplicate-key error PR #20 fixed)
  #   - codex_hooks only   -> rename it to hooks (preserves intent)
  # Both branches are safe to run when GSD owns the file because neither adds
  # a new key.
  if [ -f "$config" ] && grep -q '^codex_hooks = true$' "$config"; then
    if grep -q '^hooks = true$' "$config"; then
      sed '/^codex_hooks = true$/d' "$config" >"$tmp"
    else
      sed 's/^codex_hooks = true$/hooks = true/' "$config" >"$tmp"
    fi
    mv "$tmp" "$config"
  fi

  # Now: skip the additive "ensure hooks = true exists" steps when a leftover
  # GSD manifest still owns this file ([features].hooks was GSD-managed). GSD
  # is retired with no install path; this guard only protects pre-retirement
  # machines until gsd-uninstall clears the manifest.
  if [ -f "$HOME"/.codex/gsd-file-manifest.json ]; then
    return
  fi

  if [ ! -f "$config" ]; then
    printf '[features]\nhooks = true\n' >"$config"
    return
  fi

  if grep -q '^hooks = true$' "$config"; then
    return
  fi

  if grep -qE '^\[features\][[:space:]]*$' "$config"; then
    awk '
      /^\[features\][[:space:]]*$/ {
        in_features = 1
        print
        print "hooks = true"
        next
      }
      /^\[.*\][[:space:]]*$/ {
        in_features = 0
        print
        next
      }
      in_features && /^[[:space:]]*hooks[[:space:]]*=/ {
        # Drop any pre-existing hooks key inside [features]; the canonical
        # hooks = true was already emitted right after the header.
        next
      }
      { print }
    ' "$config" >"$tmp"
    mv "$tmp" "$config"
    return
  fi

  printf '\n[features]\nhooks = true\n' >>"$config"
}

add_codex_hook() {
  local marker="$1"
  local matcher="$2"
  local command="$3"

  if grep -q "$marker" "$HOME"/.codex/config.toml; then
    return
  fi

  {
    printf '\n# Dotfiles-managed Codex hooks\n'
    printf '[[hooks.PreToolUse]]\n'
    printf 'matcher = "%s"\n\n' "$matcher"
    printf '[[hooks.PreToolUse.hooks]]\n'
    printf 'type = "command"\n'
    printf 'command = "\\"%s\\""\n' "$command"
  } >>"$HOME"/.codex/config.toml
}

link_codex_surfaces() {
  # Codex configuration
  # A retired local setup registered the Claude web bootstrap as a project-level
  # Codex SessionStart hook. In remote Codex sessions it tries to rewrite
  # ~/.claude from the workspace sandbox and fails with Operation not permitted.
  # Remove only that exact single-command legacy surface; leave every other
  # project hook manifest untouched.
  stale_codex_hook_manifest="$DOTFILEDIR/.codex/hooks.json"
  stale_codex_hook_script="$DOTFILEDIR/.codex/hooks/session-start.sh"
  if [ -f "$stale_codex_hook_manifest" ] && [ -f "$stale_codex_hook_script" ] &&
    grep -F -q '.codex/hooks/session-start.sh' "$stale_codex_hook_manifest" &&
    [ "$(grep -o -F '"command":' "$stale_codex_hook_manifest" | wc -l)" -eq 1 ] &&
    grep -F -q 'CLAUDE_CODE_REMOTE' "$stale_codex_hook_script" &&
    grep -F -q 'bootstrap-cloud.sh' "$stale_codex_hook_script"; then
    rm -f "$stale_codex_hook_manifest" "$stale_codex_hook_script"
  fi
  # Sweep the leftover dirs even when the files are already gone (some machines
  # were cleaned by hand): rmdir only ever removes empty dirs, so anything still
  # in use is untouched.
  rmdir "$DOTFILEDIR/.codex/hooks" "$DOTFILEDIR/.codex" 2>/dev/null || true

  mkdir -p "$HOME"/.codex
  ln -sf "$DOTFILEDIR"/codex/AGENTS.md "$HOME"/.codex/AGENTS.md
  mkdir -p "$HOME"/.codex/skills
  mkdir -p "$HOME"/.codex/agents
  mkdir -p "$HOME"/.codex/hooks
  ln -sf "$DOTFILEDIR"/codex/hooks/no_ai_attribution_bash.py "$HOME"/.codex/hooks/no_ai_attribution_bash.py
  ln -sf "$DOTFILEDIR"/codex/hooks/block_secrets.py "$HOME"/.codex/hooks/block_secrets.py
  ln -sf "$DOTFILEDIR"/codex/hooks/emoji_guard.py "$HOME"/.codex/hooks/emoji_guard.py
  ln -sf "$DOTFILEDIR"/codex/hooks/no_ai_comments.py "$HOME"/.codex/hooks/no_ai_comments.py
  ln -sf "$DOTFILEDIR"/claude/hooks/herdr_worktree_guard.py "$HOME"/.codex/hooks/herdr_worktree_guard.py
  ln -sf "$DOTFILEDIR"/claude/hooks/rm_guard.py "$HOME"/.codex/hooks/rm_guard.py
  ln -sf "$DOTFILEDIR"/codex/hooks/herdr_stop_gate.py "$HOME"/.codex/hooks/herdr_stop_gate.py

  link_codex_path "$DOTFILEDIR/codex/hooks/orch_edit_guard.py" "$HOME/.codex/hooks/orch_edit_guard.py"
  link_codex_path "$DOTFILEDIR/claude/hooks/git_remote_guard.py" "$HOME/.codex/hooks/git_remote_guard.py"

  for shared_skill in repo-recall post-merge todos handoff kickoff voice; do
    link_codex_path "$DOTFILEDIR/claude/skills/$shared_skill" "$HOME/.codex/skills/$shared_skill"
  done
  mkdir -p "$HOME/.codex/rules"
  link_codex_path "$DOTFILEDIR/claude/rules/personal/agent-lessons.md" "$HOME/.codex/rules/agent-lessons.md"

  if [ -d "$DOTFILEDIR"/codex/skills ]; then
    for codex_skill in "$DOTFILEDIR"/codex/skills/*; do
      [ -d "$codex_skill" ] || continue
      link_codex_path "$codex_skill" "$HOME"/.codex/skills/"$(basename "$codex_skill")"
    done
  fi

  # Retired model migration is restricted to exact known role snapshots and
  # their existing config mappings. Custom roles and unconfigured files survive.
  if command -v uv >/dev/null 2>&1; then
    uv run --python '>=3.11' --no-project --offline --no-cache python \
      "$DOTFILEDIR/install/common/codex-roles.py" --codex-home "$HOME/.codex" ||
      echo '[WARNING] Codex role migration failed; inspect existing role configuration.' >&2
  elif command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; then
    python3 "$DOTFILEDIR/install/common/codex-roles.py" --codex-home "$HOME/.codex" ||
      echo '[WARNING] Codex role migration failed; inspect existing role configuration.' >&2
  else
    echo '[WARNING] Codex role migration requires Python 3.11+ or uv.' >&2
  fi

  ensure_codex_hooks_feature

  add_codex_hook \
    'no_ai_attribution_bash.py' \
    'Bash|Shell|exec_command|shell_command|unified_exec' \
    "$HOME/.codex/hooks/no_ai_attribution_bash.py"

  add_codex_hook \
    'block_secrets.py' \
    'Read|Edit|Write|MultiEdit|apply_patch' \
    "$HOME/.codex/hooks/block_secrets.py"

  add_codex_hook \
    'emoji_guard.py' \
    'Edit|Write|MultiEdit|apply_patch' \
    "$HOME/.codex/hooks/emoji_guard.py"

  add_codex_hook \
    'no_ai_comments.py' \
    'Edit|Write|MultiEdit|apply_patch' \
    "$HOME/.codex/hooks/no_ai_comments.py"

  add_codex_hook \
    'herdr_worktree_guard.py' \
    'Bash|Shell|exec_command|shell_command|unified_exec' \
    "$HOME/.codex/hooks/herdr_worktree_guard.py"

  add_codex_hook \
    'rm_guard.py' \
    'Bash|Shell|exec_command|shell_command|unified_exec' \
    "$HOME/.codex/hooks/rm_guard.py"

  add_codex_hook \
    'orch_edit_guard.py' \
    'Edit|Write|MultiEdit|apply_patch|Bash|Shell|exec_command|shell_command|unified_exec' \
    "$HOME/.codex/hooks/orch_edit_guard.py"

  add_codex_hook \
    'git_remote_guard.py' \
    'Bash|Shell|shell|exec_command|shell_command|unified_exec|Edit|Write|MultiEdit|apply_patch' \
    "$HOME/.codex/hooks/git_remote_guard.py"

  # Stop has its own native event/output contract, separate from PreToolUse.
  # Preserve any existing custom registration of this adapter.
  if ! grep -Fq 'herdr_stop_gate.py' "$HOME/.codex/config.toml"; then
    {
      printf '\n# Dotfiles-managed Herd completion gate\n'
      printf '[[hooks.Stop]]\n\n[[hooks.Stop.hooks]]\n'
      printf 'type = "command"\n'
      printf 'command = "python3 \\"%s\\""\n' "$HOME/.codex/hooks/herdr_stop_gate.py"
    } >>"$HOME/.codex/config.toml"
  fi

  # Shared with claude-plugins.sh, which re-runs the dedupe after the managed
  # installs so a first install closes the duplicate-provider window in the same
  # cycle (this link-time run happens before the plugins exist on that path).
  source "$DOTFILEDIR"/install/common/codex-plugin-dedupe.sh

  reconcile_codex_workflow_plugins_for_install

  # Codex plugins are the canonical owner for ECC and Superpowers workflow
  # surfaces. The dotfiles only link repo-managed bridge skills above. Older
  # installs mirrored plugin skills and agent roles into ~/.codex directly,
  # creating duplicate skill entries such as both $brainstorming and
  # $superpowers:brainstorming for byte-identical content. The sweep below wipes
  # those stale standalone snapshots so `update` self-heals.
  find "$HOME"/.codex/skills -maxdepth 1 \
    \( -name 'ecc-*' -o -name 'superpowers-*' \) -exec rm -rf {} + 2>/dev/null || true
  find "$HOME"/.codex/agents -maxdepth 1 \
    \( -name 'ecc-*' -o -name 'superpowers-*' \) -exec rm -rf {} + 2>/dev/null || true
}
