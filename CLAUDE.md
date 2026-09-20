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

- `zsh/` -> `~/.zshrc`, `~/.zprofile`, `~/.zshenv` (`.zshenv` sources both account wrappers so Claude routing and Codex's personal-repository Atlassian exclusion work in non-interactive shells; machine-local additions live in `~/.zshenv.local`, migrated there from a pre-existing `~/.zshenv` by `install/common/zshenv-migrate.sh`)
- `git/` -> `~/.gitconfig` (no `[user]` block; identity comes from `includeIf` only — `useConfigOnly` makes git refuse to commit outside `~/Git/personal` and `~/Git/work`)
- `git/personal/.gitconfig-personal` -> `~/.gitconfig-personal` (tracked)
- `git/work/.gitconfig-work.tmpl` seeded to `~/.gitconfig-work` on first install (machine-local; run `identity-setup` to populate employer values)
- `ssh/configs/config` -> `~/.ssh/config` (Includes `~/.ssh/config_local` first, then personal/work sub-configs; no global `ForwardAgent`)
- `ssh/configs/agent.toml` seeded to `~/.config/1Password/ssh/agent.toml` on first install (machine-local)
- `ssh/keys/id_ed25519_personal.pub` -> `~/.ssh/id_ed25519_personal.pub`; work key (`~/.ssh/id_ed25519_work.pub`) is machine-local, written by `identity-setup`. `~/.ssh/id_ed25519_git_fallback` (machine-local, never tracked) is an optional GitHub-only on-disk key listed second in `config_personal` so git-over-SSH keeps working while the 1Password vault is locked (the agent serves no keys when locked); ssh skips it where absent
- `ssh/configs/config_cloudflared.tmpl` seeded to `~/.ssh/config_cloudflared` on first install (machine-local; the real zone is edited there, the template keeps the inert `*.ssh.example.com` placeholder). Included from `ssh/configs/config` after `config_local`. Client side of Cloudflare Access SSH; host-side tunnel, Access app, and sshd are a manual runbook in README "Remote Access", never installer-driven.
- `bin/remote-access-doctor` -> `~/bin/remote-access-doctor` -- read-only checker for the Cloudflare Access SSH client stanza and host role (tested by `bin/remote-access-doctor.test.sh`)
- `bin/zed-claude-agent` -> `~/bin/zed-claude-agent` -- launches the pinned Claude Code ACP adapter for one account (`personal`|`work`) with `CLAUDE_CONFIG_DIR` derived from `$HOME` and `ANTHROPIC_API_KEY` unset (tested by `bin/zed-claude-agent.test.sh`)
- `vscode/` -> VS Code settings/keybindings
- `zed/` -> `~/.config/zed/settings.json` (per-file link, vscode pattern; the link must target the MAIN checkout's `zed/settings.json`, never a worktree copy, because worktrees die at merge -- `update` after merge re-links it). The `agent_servers` block defines three Claude entries: `claude-personal`, `claude-work`, and `claude-acp`, a compat alias for the personal account that stays until every saved Zed space created under that name is migrated (Zed resolves saved spaces by agent name; removing the entry broke every saved space on 2026-09-19). Each entry launches `~/bin/zed-claude-agent <personal|work>` (linked from `bin/`), which pins `CLAUDE_CONFIG_DIR` from `$HOME` and unsets `ANTHROPIC_API_KEY` -- Zed's env values are passed literally, so a pin in this file would hardcode a machine path into this public repo; the command field IS tilde-expanded, which is why the pin lives in the wrapper instead. Never add an unpinned Claude entry: it launches with empty `CLAUDE_CONFIG_DIR`, which resolves to the personal account even in a work repo (live-confirmed 2026-09-19). Subscription auth for the Zed-spawned `node` adapter needs a machine-local `~/.claude/.credentials.json` (the adapter is not on the Keychain item's ACL; the `claude` CLI is) -- never commit credentials or put a token in this tracked file. `themes/`, `prompts/`, and the rest of `~/.config/zed/` stay machine-local.
- `claude/` -> `~/.claude/` AND `~/.claude-work/` (CLAUDE.md, commands, agents, hooks, skills, rules). Two config dirs, one asset source: `~/.claude` is the personal Claude account (default -- desktop app and unwrapped launches), `~/.claude-work` is the work account, selected by the `claude()` wrapper in `zsh/claude-account.zsh` whenever claude is launched under `~/Git/work` (`claude --personal` or a pre-set `CLAUDE_CONFIG_DIR` overrides; `claude-account` shows the routing). A linked worktree of a repo under `~/Git/work` (herdr, EnterWorktree, `.worktrees/`) routes to work too, resolved through the shared canonical repository/account provider; `account_guard.py` uses the same ownership metadata while permitting personal quota. Herd dispatch explicitly binds the selected account and runtime environment in the server-spawned pane, including unsetting the default personal Claude directory. Each dir keeps its own machine-local `settings.json` (seeded from the template; both drift-checked by `claude/hooks/claude-hooks.test.sh`) and its own plugin installs. `ecc-install` and `superpowers-install` maintain Claude and Codex independently; `bootstrap` and every `update` run both through `install/common/claude-plugins.sh`.
- `claude/rules/` -> `~/.claude*/rules`. Claude Code natively auto-loads every `.md` under `~/.claude/rules/` at launch (verified live in a cloud session, 2026-07-02): files with a `paths:` frontmatter load only when matching files are in context, files without one load every session. Only our own always-on rules under `claude/rules/personal/` are tracked (e.g. `claude-prompting.md`, the cross-model model-tuning layer; the dir serves both config dirs via the `claude/rules` symlink). ECC rules vendoring stays retired (2026-07-02): the full upstream tree ships in the ECC marketplace clone (`~/.claude/plugins/marketplaces/ecc/rules/`) wherever the plugin is installed — point on-demand consumers (e.g. ECC rules-distill's `RULES_DISTILL_DIR`) there; vendoring ECC's no-`paths:` `common/`/`web/` rules would inject generic/stale content into every session. Language dirs left in `claude/rules/` by older installs are NOT inert — they auto-load per the semantics above — so `ecc-install`/`ecc-update` flag them for removal (`claude/rules/.gitignore` keeps them uncommitted).
- `claude/operating-principles.md` -> `~/.claude*/` (both config dirs). `claude/CLAUDE.md` `@import`s it into every session as standing, model-agnostic engineering discipline. Linked by `link_claude_config_dir`. (Per-model audit deep-dives `Fable5.md`/`Opus4.md`, if present locally, are gitignored and never committed — they hold private session content.)
- `codex/` -> `~/.codex/` (AGENTS.md, hooks)
- `claude/settings.json.tmpl` is seeded to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install, then reconciled on every `update`/link run (`reconcile_claude_settings_file` in `install/common/claude-links.sh`): template-owned keys (hooks, statusLine, permissions, env) are reasserted, plugin-installer keys (`enabledPlugins`, `extraKnownMarketplaces`) are unioned with live state winning, unknown keys preserved. The personal config always disables Atlassian; work config retains its existing choice. The files stay machine-local (installers write to them) — never symlink them.
- `bin/identity-setup` -> `~/bin/identity-setup` — interactive wizard writing `~/.gitconfig-work`, `~/.ssh/id_ed25519_work.pub`, `~/.ssh/config_local`
- `bin/identity-doctor` -> `~/bin/identity-doctor` — read-only chain verifier; also reachable as `git identity`
- `claude/hooks/account_guard.py` — SessionStart hook that warns when personal work uses a work account; work repositories allow either account (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/herdr_worktree_guard.py` — PreToolUse Bash hook that denies `herdr worktree create` without `--cwd` (a bare create anchors to the herdr server's current repo, not yours); `worktree open` is not guarded (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/herdr_stop_gate.py` -- Stop hook for indexed implementation/review workers. Native completion must match the selected account, repository, and current launch/phase/commit; legacy completion keeps its launch-time check. A fresh stop receives one emit-record nudge, and an already-active stop cycle releases without another refusal. Reads state only and leaves other sessions untouched (registered in `settings.json.tmpl`; tested by `herdr-stop-gate.test.sh`).
- `claude/hooks/orch_edit_guard.py` -- PreToolUse guard for the orchestrator's Edit, Write, and Bash calls. It checks the shared owner binding, selected account, and live fence before refusing writes to tracked or unignored files in any git work tree; a fenced, short-lived `allow-edit` marker permits only a human-approved small edit and is budget-audited in `tasks/orch-edits.jsonl` (registered in `settings.json.tmpl`; tested by `orch-edit-guard.test.sh`).
- `claude/hooks/scratch_policy.py` -- PermissionRequest hook (Bash matcher) that answers a residual permission prompt with `allow` only when every segment is a plain `rm`/`rmdir` whose every target canonicalizes strictly under a throwaway root (the payload's `scratchpad_dir`, `$TMPDIR` or `/tmp` when it is unset, or a `tmp.*` mktemp entry directly under `/tmp`); wrappers, pipes, redirections, `..`, symlink escapes, globs through symlinks, `.git` targets, and checkouts at or under a shared temp root all yield no decision so the prompt proceeds; it never denies (`rm_guard.py` runs first as PreToolUse and its block suppresses the event); allows are audited to `tasks/<task_id>.policy.jsonl` only when the selected account and worker binding resolve safely; ambiguous or stale bindings skip the audit without changing the permission decision (registered in `settings.json.tmpl`; tested by `scratch-policy.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/git_remote_guard.py` -- PreToolUse hook (matcher `Bash|Edit|Write`) that, only when `HERDR_ENV=1`, denies git-metadata mutations aimed at a real checkout: `git remote remove|rm|set-url|rename|prune` and `git config` writes to `remote.*`, `core.*`, or a branch's `remote`/`merge`/`pushremote` (or `--global`/`--system`, `--git-dir`/`--work-tree`, `--edit`, an unresolvable key, or an unrecognized option) unless every possible working directory is a fixture repository under `$TMPDIR` or `/tmp` (never under HOME) whose git common dir is also under a temp root; `git branch -d|-D` and `git worktree remove` of another orchestrated task's branch or worktree (records under the herdr state root with status other than merged/failed/abandoned, read only; the session's own task is exempt); and Write/Edit, redirections, tee, cp, mv, truncate, or sed -i into `.git/config` or `.git/info/exclude` outside a temp root. Working directories are tracked as a set (a `cd` may be skipped, undone by a subshell, or fabricated by a quoted operator), so the incident shape `( cd "$repo" && git remote remove origin )` denies while `git -C <fixture> ...` allows. `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment overrides one segment after explicit user confirmation (registered in `settings.json.tmpl`; tested by `git-remote-guard.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)
- **ECC account isolation.** ECC 2.2.1 resolves several hook state paths through `os.homedir()` or `$HOME/.claude` and never consults `CLAUDE_CONFIG_DIR`, so on this dual-account machine a work session would read or write personal state (and the reverse). `claude/settings.json.tmpl` `env` handles the class two ways, for BOTH accounts. (1) `ECC_DISABLED_HOOKS` switches off the seven ids that have no usable scoping knob: the two Plan Canvas hooks (`session-start:plan-canvas-sessions`, `stop:plan-canvas-pending`; Canvas state and server port are keyed on `~/.claude/plan-canvas`, the deliberate `plan-canvas await` CLI loop is unaffected), the two Bash command logs (`post:bash:command-log-audit`, `post:bash:command-log-cost`; they append every command to `~/.claude/*.log`), `post:skill:track` (`~/.claude/state/skill-runs.jsonl`), and the MCP preflight probes (`pre:mcp-health-check`, `post:mcp-health-check`; they read `~/.claude.json` and `~/.claude/settings.json` and cache under `~/.claude`, and their path knobs are literal, so no template value can name the personal account's HOME-root `.claude.json` and the work account's `~/.claude-work/.claude.json` at once; neither account declares an MCP server). (2) Hooks that honour `ECC_AGENT_DATA_HOME` stay enabled and are scoped per account (metrics, session-data, learned skills): the template value is the literal token `{{CLAUDE_CONFIG_DIR}}`, and `reconcile_claude_settings_file` replaces it, in `env` string values only, with the absolute config dir it writes into, so the personal file resolves to `~/.claude` (ECC's default, unchanged behaviour) and the work file to `~/.claude-work`. Proven hermetically by `claude/hooks/ecc-hook-isolation.test.sh` (the five newer exclusions and the scoped hooks, with leak controls) and `claude/hooks/plan-canvas-isolation.test.sh` (Canvas); both SKIP where ECC is not installed. Template and live values are drift-checked by `claude-hooks.test.sh` and the link path by `install/claude-links.test.sh`. Not scoped, by design: GateGuard state (`~/.gateguard`, session-keyed), the homunculus store (`~/.local/share/ecc-homunculus`, XDG), and `skills/learned` (one symlink into this repo for both dirs, so its scoping is nominal). Remove each exclusion and the token key once upstream ECC resolves that path through `CLAUDE_CONFIG_DIR`; re-audit after an ECC upgrade with the grep described in the suite header.
- **GateGuard tuning.** ECC's GateGuard fact-forcing hook has three gates: a once-per-session routine-Bash gate, a first-touch Edit/Write gate per file, and a destructive-Bash gate (`rm -rf`, `git reset --hard`, `git clean -f`, `git commit --amend`, SQL `drop table`/`truncate`, `dd if=`, ...). The template `env` sets `GATEGUARD_BASH_ROUTINE_DISABLED=1` and `GATEGUARD_EXEMPT_GLOBS=/**` (an absolute glob: since ECC 2.2.2 a relative glob is scoped to the project root, while an absolute one matches every path, which is the intent), which turn off the first two for BOTH accounts and leave the third running; the destructive gate is kept because this repo's own hooks cover only force pushes (`push_guard.py`) and catastrophic `rm` targets (`rm_guard.py`), not the rest of that set. Do not reach for `ECC_GATEGUARD=off` or add `pre:bash:gateguard-fact-force` to `ECC_DISABLED_HOOKS`: both kill the destructive gate too (the routine and destructive Bash paths share one hook id). Rollback is a value flip in the template (`"0"` and `""`), not a line deletion, because `reconcile_claude_settings_file` merges `env` with existing keys surviving; sessions pick the change up at their next launch. Proven hermetically by `claude/hooks/gateguard-tuning.test.sh` (SKIPs where ECC is not installed); values pinned by `claude-hooks.test.sh`. The knobs exist from ECC 2.2.x; a stale project-scope `ecc@ecc` record (linked-worktree sessions resolve to the main checkout's record) loads an older copy that ignores them silently, so `claude-hooks.test.sh` also fails when a loadable record's hook lacks the knobs -- `claude plugin list` shows scope and version, and `claude plugin update ecc@ecc --scope project` run from the main checkout refreshes it.

**Codex plugin integration:**

ECC and Superpowers use native, independent plugin installations in both runtimes (Claude: `ecc@ecc` + `superpowers@claude-plugins-official` in both account config dirs; Codex: self-contained staged copies installed as `*@dotfiles-workflows`). Never run ECC's `sync-ecc-to-codex.sh` on a dotfiles-managed machine: it mutates shared `AGENTS.md`, MCP, agent, and git-hook surfaces. Never copy a personal handoff into a work account's state. Full reconciliation mechanics (`codex-surfaces.py`, `codex-roles.py`, shared skill linking, staging provenance, `--focus` mode, restart caveats): load the `dotfiles-architecture-contract` skill.

**Herdr (agent terminal multiplexer):**

Installed via the common Brewfile; usage is opt-in per machine (`herdr` to
start/attach, `herdr server stop` to stop). Never run
`herdr integration install claude` (or `codex`) on a dotfiles-managed machine:
it writes `herdr-agent-state.sh` through the `~/.claude*/hooks` symlink into
this repo and adds hook entries to `settings.json` that
`reconcile_claude_settings_file` wipes on the next `update` (hooks are a
template-owned key) and the settings drift check flags meanwhile. Herdr's
agent-state detection works without the integration (screen manifest); if the
integration is ever wanted, it needs the installer-owned pattern (post-reconcile
idempotent install step) plus a gitignore entry for the generated script.

## Code Standards

- Shell scripts: `#!/usr/bin/env bash` or `#!/bin/zsh`
- Platform detection: `if [[ $(uname) == "Darwin" ]]; then`

## Commits

Format: `<scope>: <summary>` (imperative mood, <75 chars)

Examples: `zsh: Add geoip lookup function`, `install: Fix Brewfile path`
