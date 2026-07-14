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
- `claude/` -> `~/.claude/` AND `~/.claude-work/` (CLAUDE.md, commands, agents, hooks, skills, rules). Two config dirs, one asset source: `~/.claude` is the personal Claude account (default -- desktop app and unwrapped launches), `~/.claude-work` is the work account, selected by the `claude()` wrapper in `zsh/functions.zsh` whenever claude is launched under `~/Git/work` (`claude --personal` or a pre-set `CLAUDE_CONFIG_DIR` overrides; `claude-account` shows the routing). Each dir keeps its own machine-local `settings.json` (seeded from the template; both drift-checked by `claude/hooks/claude-hooks.test.sh`) and its own plugin installs. `ecc-install` and `superpowers-install` maintain Claude and Codex independently; `bootstrap` and every `update` run both through `install/common/claude-plugins.sh`.
- `claude/rules/` -> `~/.claude*/rules`. Claude Code natively auto-loads every `.md` under `~/.claude/rules/` at launch (verified live in a cloud session, 2026-07-02): files with a `paths:` frontmatter load only when matching files are in context, files without one load every session. Only our own always-on rules under `claude/rules/personal/` are tracked (e.g. `claude-prompting.md`, the cross-model model-tuning layer; the dir serves both config dirs via the `claude/rules` symlink). ECC rules vendoring stays retired (2026-07-02): the full upstream tree ships in the ECC marketplace clone (`~/.claude/plugins/marketplaces/ecc/rules/`) wherever the plugin is installed — point on-demand consumers (e.g. ECC rules-distill's `RULES_DISTILL_DIR`) there; vendoring ECC's no-`paths:` `common/`/`web/` rules would inject generic/stale content into every session. Language dirs left in `claude/rules/` by older installs are NOT inert — they auto-load per the semantics above — so `ecc-install`/`ecc-update` flag them for removal (`claude/rules/.gitignore` keeps them uncommitted).
- `~/.claude-work/projects`, `~/.claude-work/file-history` -> symlinks to the same paths under `~/.claude` (unified session store: `/resume` and `/rewind` see every session from either config root). Created idempotently by `bin/claude-unify-projects` (link mode) on every install/update run; an existing machine with real work-side trees runs `claude-unify-projects --merge` ONCE (backs up both trees, merges with collision rules, swaps; no live sessions allowed). See `docs/specs/2026-07-14-unified-claude-session-store.md`.
- `claude/operating-principles.md` -> `~/.claude*/` (both config dirs). `claude/CLAUDE.md` `@import`s it into every session as standing, model-agnostic engineering discipline. Linked by `link_claude_config_dir`. (Per-model audit deep-dives `Fable5.md`/`Opus4.md`, if present locally, are gitignored and never committed — they hold private session content.)
- `codex/` -> `~/.codex/` (AGENTS.md, hooks)
- `claude/settings.json.tmpl` is seeded to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install, then reconciled on every `update`/link run (`reconcile_claude_settings_file` in `install/common/claude-links.sh`): template-owned keys (hooks, statusLine, permissions, env) are reasserted, plugin-installer keys (`enabledPlugins`, `extraKnownMarketplaces`) are unioned with live state winning, unknown keys preserved. The files stay machine-local (installers write to them) — never symlink them.
- `bin/identity-setup` -> `~/bin/identity-setup` — interactive wizard writing `~/.gitconfig-work`, `~/.ssh/id_ed25519_work.pub`, `~/.ssh/config_local`
- `bin/identity-doctor` -> `~/bin/identity-doctor` — read-only chain verifier; also reachable as `git identity`
- `claude/hooks/account_guard.py` — SessionStart hook that warns when the Claude account does not match the directory convention (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)

**Codex plugin integration:**

ECC and Superpowers use native, independent plugin installations in both runtimes. Claude installs `ecc@ecc` and `superpowers@claude-plugins-official` into both account config dirs. Codex stages self-contained copies from separate upstream checkouts under `~/.local/share/dotfiles/codex-workflows`, then installs `ecc@dotfiles-workflows` and `superpowers@dotfiles-workflows`. Never run ECC's `sync-ecc-to-codex.sh` on a dotfiles-managed machine: it mutates shared `AGENTS.md`, MCP, agent, and git-hook surfaces. `install/common/link.sh` continues to sweep stale direct skill/agent mirrors from older installs.

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
