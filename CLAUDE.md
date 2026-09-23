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
- `bin/zed-claude-agent` -> `~/bin/zed-claude-agent` -- launches the pinned Claude Code ACP adapter for one account (`personal`|`work`), resolving the account through `claude/skills/lib/workflow_context.py` and applying its `launch_env` (so personal launches with `CLAUDE_CONFIG_DIR` unset), with `ANTHROPIC_API_KEY` unset (tested by `bin/zed-claude-agent.test.sh`)
- `bin/herdr-zed-attach` -> `~/bin/herdr-zed-attach` -- run from a Zed Terminal Thread (`agent: new terminal thread`), resolves the herdr agent whose `cwd` or `foreground_cwd` is at or under the current git toplevel from `herdr agent list` and execs `herdr agent attach <pane_id>`; lists candidates on stderr and exits 1 (none) or 2 (several); an explicit pane ID or agent name argument bypasses resolution; no account routing because attaching joins an already-bound pane; the sidebar label does not follow the agent's title and `agent.terminal_init_command` stays unused (tested by `bin/herdr-zed-attach.test.sh`)
- `vscode/` -> VS Code settings/keybindings
- `zed/` -> `~/.config/zed/settings.json` (per-file link, vscode pattern; the link must target the MAIN checkout's `zed/settings.json`, never a worktree copy, because worktrees die at merge -- `update` after merge re-links it). The `agent_servers` block defines three Claude entries: `claude-personal`, `claude-work`, and `claude-acp`, a compat alias for the personal account that stays until every saved Zed space created under that name is migrated (Zed resolves saved spaces by agent name; removing the entry broke every saved space on 2026-09-19). Each entry launches `~/bin/zed-claude-agent <personal|work>` (linked from `bin/`) and unsets `ANTHROPIC_API_KEY` -- Zed's env values are passed literally, so account routing cannot live in this file; the command field IS tilde-expanded, which is why the wrapper does the work. The wrapper resolves the account through `claude/skills/lib/workflow_context.py`, the same provider the `claude()` shell wrapper uses, keyed on the project root Zed passes as the adapter's cwd, and applies the returned `launch_env`; when the resolved account disagrees with the entry's argument it exits 3 with a message instead of launching, which is how a work entry behaves on a machine with no work account. Never reintroduce a hardcoded account-to-directory map: setting `CLAUDE_CONFIG_DIR` selects a separate authentication namespace even when it names the default directory (every explicit value gets its own `Claude Code-credentials-<hash>` Keychain item), so the personal account MUST launch with it unset, as `workflow_context.py`'s own docstring requires. Pinning it to `$HOME/.claude` put every Zed thread in a namespace that had never been logged in, surfacing as `OAuth session expired and could not be refreshed` (2026-09-20). A machine-local `~/.claude/.credentials.json` is not the remedy: a copied token is a static snapshot that cannot rotate, so it expires again -- never commit credentials or put a token in this tracked file. `themes/`, `prompts/`, and the rest of `~/.config/zed/` stay machine-local.
- `claude/` -> `~/.claude/` AND `~/.claude-work/` (CLAUDE.md, commands, agents, hooks, skills, rules). Two config dirs, one asset source: `~/.claude` is the personal Claude account (default -- desktop app and unwrapped launches), `~/.claude-work` is the work account, selected by the `claude()` wrapper in `zsh/claude-account.zsh` whenever claude is launched under `~/Git/work` (`claude --personal` or a pre-set `CLAUDE_CONFIG_DIR` overrides; `claude-account` shows the routing). A linked worktree of a repo under `~/Git/work` (herdr, EnterWorktree, `.worktrees/`) routes to work too, resolved through the shared canonical repository/account provider; `account_guard.py` uses the same ownership metadata while permitting personal quota. Herd dispatch explicitly binds the selected account and runtime environment in the server-spawned pane, including unsetting the default personal Claude directory. Each dir keeps its own machine-local `settings.json` (seeded from the template; both drift-checked by `claude/hooks/claude-hooks.test.sh`) and its own plugin installs, though no plugin installs any more since the retired Superpowers install path (like the retired ECC's) is gone; `bootstrap` and every `update` run `install/common/claude-plugins.sh`, which now only keeps retired plugin copies disabled. `claude/agents/` is whitelist-tracked (committed `claude/agents/.gitignore`: everything ignored except named personas) because installers (historically the retired ECC full install) wrote vendored agent files into it through the symlink; `claude/agents/director.md` is the tracked `claude --agent director` entrypoint for the standing per-repo herdr director (the role's user-facing name; the `tier: "launcher"` schema value is unchanged).
- `claude/rules/` -> `~/.claude*/rules`. Claude Code natively auto-loads every `.md` under `~/.claude/rules/` at launch (verified live in a cloud session, 2026-07-02): files with a `paths:` frontmatter load only when matching files are in context, files without one load every session. Only our own always-on rules under `claude/rules/personal/` are tracked (e.g. `claude-prompting.md`, the cross-model model-tuning layer, and `team-roles.md`, the always-on director/lead/worker/reviewer contract; the dir serves both config dirs via the `claude/rules` symlink). Language dirs left in `claude/rules/` by the retired ECC rules vendoring are NOT inert -- they auto-load per the semantics above -- so delete any that remain (`claude/rules/.gitignore` keeps them uncommitted).
- `claude/operating-principles.md` -> `~/.claude*/` (both config dirs). `claude/CLAUDE.md` `@import`s it into every session as standing, model-agnostic engineering discipline. Linked by `link_claude_config_dir`. (Per-model audit deep-dives `Fable5.md`/`Opus4.md`, if present locally, are gitignored and never committed — they hold private session content.)
- `codex/` -> `~/.codex/` (AGENTS.md, hooks)
- `claude/settings.json.tmpl` is seeded to `~/.claude/settings.json` and `~/.claude-work/settings.json` on first install, then reconciled on every `update`/link run (`reconcile_claude_settings_file` in `install/common/claude-links.sh`): template-owned keys (hooks, statusLine, permissions, env, promptSuggestionEnabled) are reasserted, plugin-installer keys (`enabledPlugins`, `extraKnownMarketplaces`) are unioned with live state winning, retired plugins (`RETIRED_PLUGINS`) are forced off with their marketplaces and env keys swept, unknown keys preserved. The personal config always disables Atlassian; work config retains its existing choice. The files stay machine-local (installers write to them) — never symlink them.
- `bin/identity-setup` -> `~/bin/identity-setup` — interactive wizard writing `~/.gitconfig-work`, `~/.ssh/id_ed25519_work.pub`, `~/.ssh/config_local`
- `bin/identity-doctor` -> `~/bin/identity-doctor` — read-only chain verifier; also reachable as `git identity`
- `claude/hooks/account_guard.py` — SessionStart hook that warns when personal work uses a work account; work repositories allow either account (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/handoff_notice.py` -- SessionStart hook (`startup|clear|compact|resume`) that lists the saved handoff records for the session's repository and account with task ID, role, and first brief line, then hints `/kickoff <task>`. Advisory: silent and exit 0 on any failure; never selects or attaches a record and does not know whether a task is already being worked (registered in `settings.json.tmpl`; tested by `handoff-notice.test.sh`).
- `claude/hooks/director_rollover.py` -- SessionStart hook (`clear|compact`) that, under `HERDR_ENV=1` with payload `agent_type` director and a messaging socket, runs the core's `resume-owner`. It re-claims only a lease the shared owner record already names under this Claude process's pid; a fresh lease is adopted under the new session id with a fence bump when that pid is also an ancestor of the hook (the same process after `/clear`). It then injects an orientation block (fence, wake-watch liveness, next step) as additional context. Silent for any other session; always exits 0. The fenced `rollover` verb types `/clear` into `$HERDR_PANE_ID` so a director rolls over with one call (registered in `settings.json.tmpl`; tested by `director-rollover.test.sh`).
- `claude/hooks/herdr_worktree_guard.py` — PreToolUse Bash hook that denies `herdr worktree create` without `--cwd` (a bare create anchors to the herdr server's current repo, not yours); `worktree open` is not guarded (registered in `settings.json.tmpl`; drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/herdr_stop_gate.py` -- Stop hook for indexed implementation/review workers. Native completion must match the selected account, repository, and current launch/phase/commit; legacy completion keeps its launch-time check. A fresh stop receives one emit-record nudge, and an already-active stop cycle releases without another refusal. Reads state only and leaves other sessions untouched (registered in `settings.json.tmpl`; tested by `herdr-stop-gate.test.sh`).
- `claude/hooks/orch_edit_guard.py` -- PreToolUse guard for the orchestrator's Edit, Write, and Bash calls. It checks the shared owner binding, selected account, and live fence before refusing writes to tracked or unignored files in any git work tree; a fenced, short-lived `allow-edit` marker permits only a human-approved small edit and is budget-audited in `tasks/orch-edits.jsonl` (registered in `settings.json.tmpl`; tested by `orch-edit-guard.test.sh`).
- `claude/hooks/scratch_policy.py` -- PermissionRequest hook (Bash matcher) that answers a residual permission prompt with `allow` only when every segment is a plain `rm`/`rmdir` whose every target canonicalizes strictly under a throwaway root (the payload's `scratchpad_dir`, `$TMPDIR` or `/tmp` when it is unset, or a `tmp.*` mktemp entry directly under `/tmp`); wrappers, pipes, redirections, `..`, symlink escapes, globs through symlinks, `.git` targets, and checkouts at or under a shared temp root all yield no decision so the prompt proceeds; it never denies (`rm_guard.py` runs first as PreToolUse and its block suppresses the event); allows are audited to `tasks/<task_id>.policy.jsonl` only when the selected account and worker binding resolve safely; ambiguous or stale bindings skip the audit without changing the permission decision (registered in `settings.json.tmpl`; tested by `scratch-policy.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)
- `claude/hooks/git_remote_guard.py` -- PreToolUse hook (matcher `Bash|Edit|Write`) that, only when `HERDR_ENV=1`, denies git-metadata mutations aimed at a real checkout: `git remote remove|rm|set-url|rename|prune` and `git config` writes to `remote.*`, `core.*`, or a branch's `remote`/`merge`/`pushremote` (or `--global`/`--system`, `--git-dir`/`--work-tree`, `--edit`, an unresolvable key, or an unrecognized option) unless every possible working directory is a fixture repository under `$TMPDIR` or `/tmp` (never under HOME) whose git common dir is also under a temp root; `git branch -d|-D` and `git worktree remove` of another orchestrated task's branch or worktree (records under the herdr state root with status other than merged/failed/abandoned, read only; the session's own task is exempt); and Write/Edit, redirections, tee, cp, mv, truncate, or sed -i into `.git/config` or `.git/info/exclude` outside a temp root. Working directories are tracked as a set (a `cd` may be skipped, undone by a subshell, or fabricated by a quoted operator), so the incident shape `( cd "$repo" && git remote remove origin )` denies while `git -C <fixture> ...` allows. `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment overrides one segment after explicit user confirmation (registered in `settings.json.tmpl`; tested by `git-remote-guard.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)

**Codex plugin integration:**

ECC is retired (2026-09): the settings reconcile forces `ecc@ecc` off and prunes its env keys, the Codex dedupe disables its copies, and `ecc-uninstall` removes what is on disk, including legacy vendored agents and commands. Superpowers is retired too (2026-09), the same way: the settings reconcile forces `superpowers@claude-plugins-official` off, the Codex dedupe disables its copies (`superpowers@dotfiles-workflows`, `superpowers@openai-curated`), and `superpowers-uninstall` removes what is on disk. GateGuard's destructive-Bash gate went with ECC; the auto-mode classifier plus `rm_guard.py`, `push_guard.py`, and `git_remote_guard.py` remain. If a destructive git incident occurs, add template `ask` rules for the specific forms. Never copy a personal handoff into a work account's state. Full reconciliation mechanics (`codex-surfaces.py`, `codex-roles.py`, shared skill linking, `--focus` mode, restart caveats): load the `dotfiles-architecture-contract` skill.

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
