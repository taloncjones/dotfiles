# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Personal dotfiles for macOS and Linux. Manages shell config, git, SSH, VS Code settings, and Claude Code configuration via symlinks.

## Commands

```bash
./bootstrap.sh              # Full install (or ./install/install.sh directly)
./bootstrap-cloud.sh        # Claude-only setup for ephemeral cloud containers
update                      # Update dotfiles and dependencies (alias)
reload                      # Reload ZSH config (alias)
setup-claude                # Add CLAUDE.md/.claude to .git/info/exclude in any repo
```

**Cloud sessions:** claude.ai/code containers are ephemeral; persist the Claude
layer by adding this to the cloud environment's setup script (requires the
GitHub grant to include this repo):

```bash
git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
"$HOME/dotfiles/bootstrap-cloud.sh"
```

## Architecture

**Install flow:** `bootstrap.sh` -> `install/install.sh` -> platform-specific scripts

- `install/macos/macos.sh` - Homebrew, Brewfile, VS Code extensions, Xcode CLI
- `install/linux/linux.sh` - apt packages, Linuxbrew
- `install/{macos,linux}/link.sh` - Create symlinks
- `install/macos/defaults.sh` - macOS system preferences
- `install/common/zsh.sh` - Set Homebrew ZSH as default shell

**Symlink targets:**

- `zsh/` -> `~/.zshrc`, `~/.zprofile`
- `git/` -> `~/.gitconfig` (no `[user]` block; identity comes from `includeIf` only — `useConfigOnly` makes git refuse to commit outside `~/Git/personal` and `~/Git/work`)
- `git/personal/.gitconfig-personal` -> `~/.gitconfig-personal` (tracked)
- `git/work/.gitconfig-work.tmpl` seeded to `~/.gitconfig-work` on first install (machine-local; run `identity-setup` to populate employer values)
- `ssh/configs/config` -> `~/.ssh/config` (Includes `~/.ssh/config_local` first, then personal/work sub-configs; no global `ForwardAgent`)
- `ssh/configs/agent.toml` seeded to `~/.config/1Password/ssh/agent.toml` on first install (machine-local)
- `ssh/keys/id_ed25519_personal.pub` -> `~/.ssh/id_ed25519_personal.pub`; work key (`~/.ssh/id_ed25519_work.pub`) is machine-local, written by `identity-setup`
- `vscode/` -> VS Code settings/keybindings
- `claude/` -> `~/.claude/` AND `~/.claude-work/` (CLAUDE.md, commands, agents, hooks, skills, rules). Two config dirs, one asset source: `~/.claude` is the personal Claude account (default -- desktop app and unwrapped launches), `~/.claude-work` is the work account, selected by the `claude()` wrapper in `zsh/functions.zsh` whenever claude is launched under `~/Git/work` (`claude --personal` or a pre-set `CLAUDE_CONFIG_DIR` overrides; `claude-account` shows the routing). Each dir keeps its own machine-local `settings.json` (seeded from the template; both drift-checked by `claude/hooks/claude-hooks.test.sh`) and its own plugin installs (`ecc-install`/`superpowers-install` maintain both).
- `codex/` -> `~/.codex/` (AGENTS.md, hooks)
- `claude/settings.json.tmpl` is copied to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install only — those files are machine-local because plugin installers (ECC) write to them. Update the template by hand and re-merge into existing machines manually.
- `claude/orchestrator.conf` sets `PLANNER_MODEL` (valid: `fable`, `opus`, `sonnet`, `haiku`) for the tiered orchestration SessionStart hook (`claude/hooks/tiered_orchestrator.py`), which injects the standing rule routing substantial tasks through the `tiered-orchestrate` skill. Missing conf falls back to `opus` with a visible warning; an invalid value disables orchestration loudly. Swap the planner model by editing the conf — one line, one commit. The hook entry lives in `settings.json.tmpl`; existing machines must hand-merge it, and the settings-drift check in `claude/hooks/claude-hooks.test.sh` fails until the merge is done.
- `bin/identity-setup` -> `~/bin/identity-setup` — interactive wizard writing `~/.gitconfig-work`, `~/.ssh/id_ed25519_work.pub`, `~/.ssh/config_local`
- `bin/identity-doctor` -> `~/bin/identity-doctor` — read-only chain verifier; also reachable as `git identity`
- `claude/hooks/account_guard.py` — SessionStart hook that warns when the Claude account does not match the directory convention (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)

**Codex plugin integration:**

ECC and Superpowers are installed as Claude Code plugins; the dotfiles does NOT mirror or sync their assets into `~/.codex/`. Do not run ECC's `sync-ecc-to-codex.sh` on a dotfiles-managed machine — it would overwrite `core.hooksPath` (orphaning the dotfiles `post-checkout` hook), write through the `~/.codex/AGENTS.md` symlink into this repo, and leave nameless agent role files at `~/.codex/agents/` that codex 0.130+ warns about. `install/common/link.sh` sweeps any leftover `~/.codex/{skills,agents}/{ecc,superpowers}-*` from older mirror code on every `update`.

**ZSH structure:**

- `zsh/.zshrc` - Main config, sources other files
- `zsh/aliases.zsh` - Platform-conditional aliases
- `zsh/functions.zsh` - Shell functions
- `zsh/scripts/` - Modular utilities (airpods, cheat, geoip, info)
- `zsh/theme.zsh` - Custom prompt theme

## Code Standards

- No spaces in filenames
- Unix LF line endings
- Use `uv` for Python (not pip/poetry)
- Shell scripts: `#!/usr/bin/env bash` or `#!/bin/zsh`
- Platform detection: `if [[ $(uname) == "Darwin" ]]; then`

## Commits

Format: `<scope>: <summary>` (imperative mood, <75 chars)

Examples: `zsh: Add geoip lookup function`, `install: Fix Brewfile path`

## Adding Packages

CLI tools (all platforms): `install/common/Brewfile.rb`
macOS apps: `install/macos/Brewfile.rb`
