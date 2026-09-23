# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Personal dotfiles for macOS and Linux. Manages shell config, git, SSH, VS Code settings, and Claude Code configuration via symlinks.

## Commands

```bash
./bootstrap.sh              # Full install (or ./install/install.sh directly)
./bootstrap-cloud.sh        # Claude-only setup for ephemeral cloud containers
update                      # Update dotfiles and dependencies (alias)
update --ai                 # Refresh only the Claude/Codex layer (no sudo/brew/vscode)
reload                      # Reload ZSH config (alias)
setup-claude                # Add CLAUDE.md/.claude to .git/info/exclude in any repo
```

**Cloud sessions:** claude.ai/code containers are ephemeral. No plugin is
declared or installed in a cloud session any more (Superpowers is retired,
2026-09, like ECC). The repo SessionStart hook
(`.claude/hooks/session-start.sh`, gated on `CLAUDE_CODE_REMOTE`, matcher
`startup|resume`) runs `bootstrap-cloud.sh` to symlink the `~/.claude` assets,
reconcile `settings.json` from the template, and set the personal git author.

Optional belt-and-suspenders (e.g. to pre-snapshot the install): paste this
into the cloud environment's **Setup script** field — pre-launch and
filesystem-snapshotted; the repo is public, so no GitHub grant is needed:

```bash
git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
"$HOME/dotfiles/bootstrap-cloud.sh"
```

Custom base images are unsupported; the snapshot is the equivalent.

## Architecture

Install flow, symlink and seed targets, the hook catalogue, and the Codex
plugin and Herdr notes live in
`.claude/skills/dotfiles-architecture-contract/references/install-layout.md`.
Read it before changing any of them, and update it in the same change.

- `settings.json` is seeded and reconciled from `claude/settings.json.tmpl`, never symlinked.
- `claude/agents/` is whitelist-tracked; installers must not write into it.
- Personal Claude launches keep `CLAUDE_CONFIG_DIR` unset; never hardcode an account-to-directory map.
- Never run `herdr integration install claude` (or `codex`) on a dotfiles-managed machine.
- Never commit credentials or copy a token into a tracked file.

## Code Standards

- Shell scripts: `#!/usr/bin/env bash` or `#!/bin/zsh`
- Platform detection: `if [[ $(uname) == "Darwin" ]]; then`

## Commits

Format: `<scope>: <summary>` (imperative mood, <75 chars)

Examples: `zsh: Add geoip lookup function`, `install: Fix Brewfile path`
