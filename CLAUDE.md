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

**Cloud sessions:** claude.ai/code containers are ephemeral. The Claude layer is
restored two ways, both first-session-safe (no next-session lag):

- **Plugins** — the repo's committed `.claude/settings.json` declares ECC +
  Superpowers in `enabledPlugins` and pins both marketplaces by git URL in
  `extraKnownMarketplaces`. The platform installs declared plugins natively at
  session start (pre-launch, from the cloned repo), so they are live on session 1
  with zero per-environment config. This is the primary mechanism.
- **Assets, settings, git identity** — the repo SessionStart hook
  (`.claude/hooks/session-start.sh`, gated on `CLAUDE_CODE_REMOTE`, matcher
  `startup|resume`) runs `bootstrap-cloud.sh` to symlink the `~/.claude` assets,
  reconcile `settings.json` from the template, and set the personal git author.
  It also self-heals the plugin install if the native declaration is ever missed.

Optional belt-and-suspenders (e.g. a repo that does NOT commit the declaration,
or to pre-snapshot a slow install): paste this into the cloud environment's
**Setup script** field — pre-launch and filesystem-snapshotted; the repo is
public, so no GitHub grant is needed:

```bash
git clone https://github.com/taloncjones/dotfiles "$HOME/dotfiles" 2>/dev/null || git -C "$HOME/dotfiles" pull
"$HOME/dotfiles/bootstrap-cloud.sh"
```

Placement is load-bearing: plugins load at Claude Code launch, so only pre-launch
placements (the native `.claude/settings.json` declaration, or the Setup script)
make them usable on session 1. The SessionStart hook runs _after_ launch, so a
plugin it installs is not usable until the NEXT session — which is why it is the
self-heal, not the primary path. Custom base images are unsupported; the snapshot
is the equivalent.

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
- `claude/` -> `~/.claude/` AND `~/.claude-work/` (CLAUDE.md, commands, agents, hooks, skills, rules). Two config dirs, one asset source: `~/.claude` is the personal Claude account (default -- desktop app and unwrapped launches), `~/.claude-work` is the work account, selected by the `claude()` wrapper in `zsh/functions.zsh` whenever claude is launched under `~/Git/work` (`claude --personal` or a pre-set `CLAUDE_CONFIG_DIR` overrides; `claude-account` shows the routing). Each dir keeps its own machine-local `settings.json` (seeded from the template; both drift-checked by `claude/hooks/claude-hooks.test.sh`) and its own plugin installs (`ecc-install`/`superpowers-install` maintain both). `bootstrap` (and every `update`, which re-runs `install.sh`) runs both via `install/common/claude-plugins.sh`, so a fresh machine gets the ECC + Superpowers plugins automatically.
- `claude/rules/` -> `~/.claude*/rules`. Claude Code natively auto-loads every `.md` under `~/.claude/rules/` at launch; files with a `paths:` frontmatter load only when matching files are open, files without one load every session. Only our own rules under `claude/rules/shared/` are tracked. The ECC language dirs (`cpp/ python/ rust/ typescript/`) are installer-managed and **untracked** (`claude/rules/.gitignore`): `ecc-install`/`ecc-update` re-vendor them from the ECC repo via `cp -R`, so they are reproducible and never committed — same model as ECC skills/commands/hooks. They each carry `paths:` frontmatter, so they cost nothing until you edit that language. ECC's `common/` and `web/` rules are deliberately **not** vendored: they have no `paths:` field and would load into every session, and much of that content is generic or stale for the current model — our own always-on, model-tuned guidance lives in `claude/rules/shared/` (e.g. `claude-prompting.md`) instead. Vendored languages are set by `ECC_VENDOR_LANGS` in `zsh/functions.zsh`; `ecc-sync-rules` prunes retired dirs on the next sync. This is why bootstrap installs ECC: a fresh clone has no language rules until it runs.
- `claude/operating-principles.md` -> `~/.claude*/` (both config dirs). `claude/CLAUDE.md` `@import`s it into every session as standing, model-agnostic engineering discipline. Linked by `link_claude_config_dir`. (Per-model audit deep-dives `Fable5.md`/`Opus4.md`, if present locally, are gitignored and never committed — they hold private session content.)
- `codex/` -> `~/.codex/` (AGENTS.md, hooks)
- `claude/settings.json.tmpl` is copied to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install only — those files are machine-local because plugin installers (ECC) write to them. Update the template by hand and re-merge into existing machines manually.
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
