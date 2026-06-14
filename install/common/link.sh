#!/usr/bin/env bash
# link.sh - Common symlinks shared between macOS and Linux
#
# Creates symlinks for ZSH, git, SSH, and Claude Code configuration.
# Sourced by platform-specific link.sh files after DOTFILEDIR is set.
#
# Requires: DOTFILEDIR must be set before sourcing this file.

set -e

if [[ -z "$DOTFILEDIR" ]]; then
  echo "ERROR: DOTFILEDIR not set. Cannot create symlinks."
  exit 1
fi

# Ensure required directories exist
mkdir -p "$HOME"/.config
mkdir -p "$HOME"/.ssh
# Repo-location convention dirs: git identity routing (includeIf in
# .gitconfig) and the claude() account wrapper both key off these paths.
mkdir -p "$HOME"/Git/personal "$HOME"/Git/work

# seed_machine_local_file + link_claude_config_dir live in claude-links.sh so
# bootstrap-cloud.sh can reuse them in ephemeral containers. Sourced early
# because the git/ssh sections below also seed machine-local files.
source "$DOTFILEDIR"/install/common/claude-links.sh

# ZSH configuration
echo "Setting up symbolic links for ZSH..."
ln -sf "$DOTFILEDIR"/zsh/.zprofile "$HOME"/.zprofile
ln -sf "$DOTFILEDIR"/zsh/.zshrc "$HOME"/.zshrc
ln -sf "$DOTFILEDIR"/zsh/aliases.zsh "$HOME"/.config/.aliases.zsh
ln -sf "$DOTFILEDIR"/zsh/functions.zsh "$HOME"/.config/.functions.zsh
ln -sf "$DOTFILEDIR"/zsh/.trippy.toml "$HOME"/.config/.trippy.toml

# Git configuration
echo "Setting up symbolic links for git..."
ln -sf "$DOTFILEDIR"/git/.gitconfig "$HOME"/.gitconfig
ln -sf "$DOTFILEDIR"/git/.stCommitMsg "$HOME"/.stCommitMsg
ln -sf "$DOTFILEDIR"/git/.gitignore_global "$HOME"/.gitignore_global
ln -sf "$DOTFILEDIR"/git/personal/.gitconfig-personal "$HOME"/.gitconfig-personal
# Work identity is machine-local (employer values never tracked): seeded from
# the template on first install, then owned by the machine. Run identity-setup
# to fill in the [user] block; until then git refuses to commit under
# ~/Git/work (user.useConfigOnly) instead of guessing.
seed_machine_local_file "$DOTFILEDIR"/git/work/.gitconfig-work.tmpl "$HOME"/.gitconfig-work
# Global git hooks dir (referenced by core.hooksPath in .gitconfig).
# rm -rf first because ln -sfn can replace a stale symlink but NOT an existing
# real directory — same atomicity reason as the Claude Code section below.
mkdir -p "$HOME"/.config/git
rm -rf "$HOME"/.config/git/hooks
ln -sfn "$DOTFILEDIR"/git/hooks "$HOME"/.config/git/hooks

# SSH configuration
echo "Setting up symbolic links for SSH..."
ln -sf "$DOTFILEDIR"/ssh/configs/config "$HOME"/.ssh/config
ln -sf "$DOTFILEDIR"/ssh/configs/personal/config_personal "$HOME"/.ssh/config_personal
ln -sf "$DOTFILEDIR"/ssh/configs/work/config_work "$HOME"/.ssh/config_work
ln -sf "$DOTFILEDIR"/ssh/keys/id_ed25519_personal.pub "$HOME"/.ssh/id_ed25519_personal.pub
# The work key's public half is machine-local (employer key never tracked):
# identity-setup writes ~/.ssh/id_ed25519_work.pub. Nothing to link here.

# 1Password SSH agent config: seed once, then machine-local (real vault/item
# names stay off the repo). 1Password reads a real file here, not a symlink.
mkdir -p "$HOME"/.config/1Password/ssh
seed_machine_local_file "$DOTFILEDIR"/ssh/configs/agent.toml "$HOME"/.config/1Password/ssh/agent.toml

# Claude Code configuration
# Structure: commands/ = slash commands, agents/ = subagent definitions, hooks/ = pre/post hooks
echo "Setting up symbolic links for Claude Code..."
link_claude_config_dir "$HOME"/.claude
link_claude_config_dir "$HOME"/.claude-work

# The Dockerized Claude sandbox (claude/sandbox/, bin/claude-sandbox) was
# retired along with GSD -- permission auto mode covers the same need. Sweep
# the launcher symlink and the sandbox config dir so `update` self-heals.
rm -f "$HOME"/bin/claude-sandbox
rm -rf "$HOME"/.claude/sandbox

# bin/ scripts
mkdir -p "$HOME"/bin
ln -sf "$DOTFILEDIR"/bin/dotfiles-repair "$HOME"/bin/dotfiles-repair
ln -sf "$DOTFILEDIR"/bin/setup-claude "$HOME"/bin/setup-claude
ln -sf "$DOTFILEDIR"/bin/identity-setup "$HOME"/bin/identity-setup
ln -sf "$DOTFILEDIR"/bin/identity-doctor "$HOME"/bin/identity-doctor

# Ghostty terminal configuration
echo "Setting up symbolic links for Ghostty..."
mkdir -p "$HOME"/.config/ghostty
ln -sf "$DOTFILEDIR"/ghostty/config "$HOME"/.config/ghostty/config

# Codex configuration
mkdir -p "$HOME"/.codex
ln -sf "$DOTFILEDIR"/codex/AGENTS.md "$HOME"/.codex/AGENTS.md
mkdir -p "$HOME"/.codex/skills
mkdir -p "$HOME"/.codex/agents
mkdir -p "$HOME"/.codex/hooks
ln -sf "$DOTFILEDIR"/codex/hooks/no_ai_attribution_bash.py "$HOME"/.codex/hooks/no_ai_attribution_bash.py
ln -sf "$DOTFILEDIR"/codex/hooks/block_secrets.py "$HOME"/.codex/hooks/block_secrets.py
ln -sf "$DOTFILEDIR"/codex/hooks/emoji_guard.py "$HOME"/.codex/hooks/emoji_guard.py
ln -sf "$DOTFILEDIR"/codex/hooks/no_ai_comments.py "$HOME"/.codex/hooks/no_ai_comments.py

if [ -d "$DOTFILEDIR"/codex/skills ]; then
  for codex_skill in "$DOTFILEDIR"/codex/skills/*; do
    [ -d "$codex_skill" ] || continue
    ln -sfn "$codex_skill" "$HOME"/.codex/skills/"$(basename "$codex_skill")"
  done
fi

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

  # Now: skip the additive "ensure hooks = true exists" steps when GSD's Codex
  # installer owns this file (it manages [features].hooks itself). Writing here
  # would race with the GSD installer and produce duplicate keys (TOML
  # validation then fails and aborts the GSD install).
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

ensure_codex_hooks_feature

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

codex_plugin_enabled() {
  local config="$1"
  local plugin="$2"
  local target="[plugins.\"$plugin\"]"

  awk -v target="$target" '
    $0 == target {
      in_plugin = 1
      next
    }
    in_plugin && /^\[.*\][[:space:]]*$/ {
      in_plugin = 0
      next
    }
    in_plugin && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
      found = 1
    }
    END {
      exit found ? 0 : 1
    }
  ' "$config"
}

dedupe_codex_superpowers_plugins() {
  local config="$HOME"/.codex/config.toml
  local tmp="$config.tmp.$$"

  [ -f "$config" ] || return
  codex_plugin_enabled "$config" "superpowers@openai-curated" || return 0
  codex_plugin_enabled "$config" "superpowers@claude-plugins-official" || return 0

  awk '
    /^\[plugins\."superpowers@claude-plugins-official"\][[:space:]]*$/ {
      in_official_superpowers = 1
      print
      next
    }
    /^\[.*\][[:space:]]*$/ {
      in_official_superpowers = 0
      print
      next
    }
    in_official_superpowers && /^[[:space:]]*enabled[[:space:]]*=[[:space:]]*true[[:space:]]*$/ {
      print "enabled = false"
      next
    }
    { print }
  ' "$config" >"$tmp"
  mv "$tmp" "$config"
}

dedupe_codex_superpowers_plugins

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
