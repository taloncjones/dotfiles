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

# ~/.zshenv is tracked (account routing must exist in non-interactive
# shells); a pre-existing machine-local file is migrated to ~/.zshenv.local.
# ln -sfn, not -sf: a foreign symlink pointing at a directory would
# otherwise be followed, planting the new link INSIDE that directory.
source "$DOTFILEDIR"/install/common/zshenv-migrate.sh
if migrate_home_zshenv "$HOME" "$DOTFILEDIR/zsh/.zshenv"; then
  ln -sfn "$DOTFILEDIR"/zsh/.zshenv "$HOME"/.zshenv
fi

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

# Cloudflare Access SSH stanza: seed once, then machine-local (the real
# zone never enters the repo). See README "Remote Access".
seed_machine_local_file "$DOTFILEDIR"/ssh/configs/config_cloudflared.tmpl "$HOME"/.ssh/config_cloudflared

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
ln -sf "$DOTFILEDIR"/bin/remote-access-doctor "$HOME"/bin/remote-access-doctor
ln -sf "$DOTFILEDIR"/bin/dotfiles-tests "$HOME"/bin/dotfiles-tests

# Ghostty terminal configuration
echo "Setting up symbolic links for Ghostty..."
mkdir -p "$HOME"/.config/ghostty
ln -sf "$DOTFILEDIR"/ghostty/config "$HOME"/.config/ghostty/config

# Codex configuration: surface layer shared with `update --ai`
# (install/common/ai-update.sh). Step list lives in codex-links.sh only.
source "$DOTFILEDIR"/install/common/codex-links.sh
link_codex_surfaces
