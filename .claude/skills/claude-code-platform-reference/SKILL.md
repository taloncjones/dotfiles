---
name: claude-code-platform-reference
description: Load when you need Claude Code PLATFORM mechanics as used by this repo -- config-dir resolution and CLAUDE_CONFIG_DIR, what lives in ~/.claude, settings.json precedence and key ownership, plugin/marketplace internals (installed_plugins.json, known_marketplaces.json, marketplace manifests, CLI verbs), hook events/matchers/exit codes, skills vs commands vs agents, CLAUDE.md @import, cloud-container env vars and launch ordering, statusline wiring. Trigger phrases - "how do plugins actually install", "where does settings.json come from", "what is CLAUDE_CONFIG_DIR", "why did my hook not fire", "what runs at session start", "what is installed_plugins.json". This is the factual reference; for step-by-step operations use dotfiles-run-and-operate, for env recreation use dotfiles-build-and-env, for proving state use dotfiles-verification-toolkit.
---

# Claude Code Platform Reference (as used in this repo)

Domain knowledge pack: how the Claude Code platform actually works underneath
this dotfiles repo. Every claim is grounded in a repo file (cited as path or
path:line) or a live inspection of the cloud container this was written in;
anything neither could prove is labeled **inferred-from-docs**. This is a
reference, not a runbook -- it tells you what the moving parts ARE so the
sibling runbooks make sense.

## When NOT to use this skill

| You want to...                                 | Use instead                    |
| ---------------------------------------------- | ------------------------------ |
| Run day-to-day plugin/update/repair operations | dotfiles-run-and-operate       |
| Rebuild a machine or cloud env from scratch    | dotfiles-build-and-env         |
| Prove a symlink/plugin/hook is actually live   | dotfiles-verification-toolkit  |
| Triage a broken session or failing hook        | dotfiles-debugging-playbook    |
| Know why a design decision was made            | dotfiles-architecture-contract |
| See the history of the cloud plugin saga       | dotfiles-failure-archaeology   |
| Look up an env var or flag default             | dotfiles-config-and-flags      |
| Improve the cloud-session story                | dotfiles-cloud-first-campaign  |

## Glossary (first use of every jargon term)

- **Config dir**: the directory Claude Code reads all user-level state from
  (settings, plugins, credentials). Default `~/.claude`; overridden by the
  `CLAUDE_CONFIG_DIR` env var.
- **Plugin**: an installable bundle of skills/commands/agents/hooks, identified
  as `name@marketplace` (e.g. `ecc@ecc`).
- **Marketplace**: a git repo that catalogs plugins via a
  `.claude-plugin/marketplace.json` manifest; registered per config dir.
- **Hook**: an external command Claude Code runs on lifecycle events
  (PreToolUse, PostToolUse, SessionStart, ...), registered in settings.json.
- **Skill**: a directory containing `SKILL.md` (YAML frontmatter: `name`,
  `description`); the description is the model-facing loading trigger.
- **Setup script**: the pre-launch shell field in a claude.ai/code cloud
  environment config; its disk writes are filesystem-snapshotted.

## Config-dir resolution and CLAUDE_CONFIG_DIR

`CLAUDE_CONFIG_DIR` selects the config dir; unset means `~/.claude`. This repo
runs TWO config dirs off one asset source:

| Dir              | Account                                             | Selected by                                              |
| ---------------- | --------------------------------------------------- | -------------------------------------------------------- |
| `~/.claude`      | personal (default; desktop app, unwrapped launches) | nothing -- the fallback                                  |
| `~/.claude-work` | work                                                | `claude()` zsh wrapper when `$PWD` is under `~/Git/work` |

Resolution logic lives in `_claude_config_dir` in `zsh/functions.zsh` (near
line 222): a pre-set `CLAUDE_CONFIG_DIR` always wins; `claude --personal`
forces `~/.claude` from a work dir; `claude-account` prints which dir a launch
from the cwd would use. Launch paths that bypass the wrapper (desktop app, IDE
extensions, `command claude`) land on the default -- `account_guard.py`
(SessionStart hook) warns when account and directory disagree
(claude/hooks/account_guard.py).

Both dirs are populated by `link_claude_config_dir` in
`install/common/claude-links.sh` -- symlinks into the repo for everything
except `settings.json`, which is machine-local per dir (see below).
Cloud containers get only `~/.claude` (personal); there is no `~/.claude-work`
story in cloud (open weak point, by design -- bootstrap-cloud.sh header).

## What lives in a config dir

Live-verified layout of `~/.claude` in a cloud container, 2026-07-02
(`ls -la ~/.claude`). "Managed" = symlinked by `link_claude_config_dir`
(install/common/claude-links.sh); "local" = machine-local real file/dir.

| Entry                                                  | Kind            | Points to / holds                                                                                                |
| ------------------------------------------------------ | --------------- | ---------------------------------------------------------------------------------------------------------------- |
| `CLAUDE.md`                                            | managed symlink | `claude/CLAUDE.md` -- global instructions, loaded every session                                                  |
| `operating-principles.md`                              | managed symlink | `claude/operating-principles.md` -- pulled in via `@import` (see below)                                          |
| `commands/`                                            | managed symlink | `claude/commands/` -- slash commands                                                                             |
| `agents/`                                              | managed symlink | `claude/agents/` -- subagent definitions                                                                         |
| `hooks/`                                               | managed symlink | `claude/hooks/` -- guard hook scripts                                                                            |
| `skills/`                                              | managed symlink | `claude/skills/` -- personal skills tracked, ECC/generated skills untracked (claude/skills/.gitignore whitelist) |
| `rules/`                                               | managed symlink | `claude/rules/` -- only `personal/` tracked; ECC language dirs vendored, untracked (claude/rules/.gitignore)     |
| `statusline.js`                                        | managed symlink | `claude/statusline.js`                                                                                           |
| `settings.json`                                        | LOCAL file      | seeded once from `claude/settings.json.tmpl`; plugin installers write into it                                    |
| `plugins/`                                             | LOCAL dir       | plugin state -- see next section                                                                                 |
| `projects/`, `sessions/`, `shell-snapshots/`, `tasks/` | LOCAL           | session/runtime state (platform-managed)                                                                         |

Note the defensive behavior in `link_claude_config_dir`: real (non-symlink)
`commands/agents/hooks/rules/skills` dirs are backed up as
`<name>.bak.<timestamp>` before symlinking, and `seed_machine_local_file`
removes a stale settings.json SYMLINK (write-through pollution risk) and warns
when the existing file is under half the template size (corruption signal) --
install/common/claude-links.sh:23-47.

## Settings files: precedence and which keys this repo uses where

Precedence chain, highest first (**inferred-from-docs** -- the repo cannot
prove ordering, only that both user and project layers are honored):
managed/enterprise policy > CLI flags > `.claude/settings.local.json`
(project, personal) > `.claude/settings.json` (project, committed) >
`<config-dir>/settings.json` (user).

What this repo puts in each layer (all repo-verified):

| File                                | Tracked?                        | Keys used                                                                                                                                                                     | Purpose                                                                                                                                                                                                               |
| ----------------------------------- | ------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `claude/settings.json.tmpl`         | yes                             | `env`, `permissions` (allow/deny/ask, `defaultMode`), `hooks` (PreToolUse, PostToolUse, SessionStart), `statusLine`, `enabledPlugins`, `extraKnownMarketplaces`, `mcpServers` | template for the USER settings.json in both config dirs                                                                                                                                                               |
| `<config-dir>/settings.json`        | no (machine-local)              | same as template plus whatever plugin installers write                                                                                                                        | seeded ONCE by `seed_machine_local_file`; template changes need manual merge on machines. Cloud reconciles automatically via `reconcile_claude_settings` (bootstrap-cloud.sh) -- open weak point that machines do not |
| `.claude/settings.json` (repo root) | yes                             | `enabledPlugins`, `extraKnownMarketplaces`, `hooks.SessionStart`                                                                                                              | PROJECT settings: declares ECC + Superpowers for native pre-launch install in cloud, plus the session-start.sh self-heal hook                                                                                         |
| `.claude/settings.local.json`       | gitignored (.gitignore:159-160) | none committed                                                                                                                                                                | per-machine personal overrides only                                                                                                                                                                                   |

`enabledPlugins` semantics: `true` per `name@marketplace` id enables the
plugin; `extraKnownMarketplaces` pins each marketplace to a git source URL so
the platform can install declared plugins natively at session start,
pre-launch (`.claude/settings.json`; rationale in repo CLAUDE.md "Cloud
sessions"). User-layer and project-layer plugin declarations are merged
(**inferred-from-docs** for exact merge rules; live container shows both
layers' plugins active).

## Plugin system mechanics

On-disk layout under `<config-dir>/plugins/`, live-verified 2026-07-02:

| Path                                      | Role                                                                                                                                                                                                                                                                 |
| ----------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `installed_plugins.json`                  | **GROUND TRUTH** of what is installed: per plugin id, `installPath`, `version`, `installedAt`, `gitCommitSha`. `claude plugins install` can exit 0 WITHOUT writing it -- never trust the exit code (bootstrap-cloud.sh `plugin_installed`, commits 722c653, f91d7d2) |
| `known_marketplaces.json`                 | registered marketplaces: source URL + `installLocation` + `lastUpdated`                                                                                                                                                                                              |
| `marketplaces/<name>/`                    | full git clone of the marketplace repo; its `.claude-plugin/marketplace.json` is the manifest the install resolver checks                                                                                                                                            |
| `cache/<marketplace>/<plugin>/<version>/` | the installed plugin content actually loaded at launch                                                                                                                                                                                                               |

Cold-start race (settled, commit 7cb28b7): a github-backed marketplace can be
REGISTERED but still mid-fetch, so `claude plugins install` no-ops with exit 0
because the manifest does not list the plugin yet. Plain git marketplaces
clone synchronously and win the race. `ensure_plugin` in bootstrap-cloud.sh
defeats this deterministically: wait for `marketplace_lists_plugin` (manifest
poll with `marketplace update` refreshes), then install, then verify against
installed_plugins.json, with backoff capped at 15s so retries fit the Setup
script budget (bootstrap-cloud.sh:59-172).

CLI verbs used by this repo (note the mixed singular/plural -- copy exactly):

```bash
claude plugin marketplace list
claude plugin marketplace add <git-url>
claude plugin marketplace update <name>
claude plugins list
claude plugins install <name@marketplace>
claude plugins update <name@marketplace>
claude plugins uninstall <name@marketplace>
```

(Sources: bootstrap-cloud.sh `ensure_plugin`; `ecc-install` /
`superpowers-install` in zsh/functions.zsh. The machine-path functions still
verify via `claude plugins list` grep rather than installed_plugins.json --
known open weak point; `ensure_plugin` is the gold standard.)

The two plugins this repo declares: `ecc@ecc` (marketplace
https://github.com/affaan-m/ECC.git) and
`superpowers@claude-plugins-official`
(https://github.com/anthropics/claude-plugins-official.git). Both registered
BY URL so the clone is synchronous -- the official marketplace's platform
default registration is async and absent during a pre-launch Setup script
(bootstrap-cloud.sh:49-55; machine path fixed the same way in
`superpowers-install`, commit 5b799dd, 2026-07-02).

## Hooks

Registration points, exit-code contract, and the full inventory.

**Exit-code semantics** (verified in every repo hook): exit 0 = allow /
no-op; exit 2 = block (PreToolUse prevents the tool call; PostToolUse
surfaces the violation to the model); anything raised inside a hook is caught
and exits 0 -- **fail-open by convention** so a broken hook never bricks a
session (e.g. claude/hooks/emoji_guard.py, final `sys.exit(0)` on exception;
same pattern in block_secrets.py, commit_guard.py). `protect_claude_md.py`
is warn-only: it only ever exits 0 with a warning payload.

**Where registered:**

1. USER layer -- `claude/settings.json.tmpl` `hooks` key (lands in each
   config dir's settings.json):

| Event        | Matcher                   | Hooks                                                                      |
| ------------ | ------------------------- | -------------------------------------------------------------------------- |
| PreToolUse   | `Bash`                    | commit_guard.py, no_ai_attribution_bash.py                                 |
| PreToolUse   | `Read\|Edit\|Write`       | block_secrets.py (segment-based matching since commit 52f807d, 2026-07-02) |
| PreToolUse   | `Edit\|Write`             | protect_claude_md.py (warn-only)                                           |
| PostToolUse  | `Edit\|Write`             | emoji_guard.py, no_ai_comments.py, format_files.py (prettier)              |
| PostToolUse  | `mcp__plugin_atlassian`   | cache_jira_url.py                                                          |
| SessionStart | `startup\|clear\|compact` | account_guard.py                                                           |

2. PROJECT layer -- `.claude/settings.json`:

| Event        | Matcher           | Hook                                                                                                           |
| ------------ | ----------------- | -------------------------------------------------------------------------------------------------------------- |
| SessionStart | `startup\|resume` | `$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh` (cloud self-heal; no-op unless `CLAUDE_CODE_REMOTE=true`) |

Matchers are regexes against the tool name (PreToolUse/PostToolUse) or the
session-start source (`startup`, `resume`, `clear`, `compact` are the values
this repo matches on). Hook commands referencing `~/.claude/hooks/...` work in
BOTH config dirs because `hooks/` is a symlink to the same repo dir in each.

Git hooks are a separate mechanism (git `core.hooksPath` ->
`~/.config/git/hooks` -> `git/hooks/`), not Claude Code hooks -- see
dotfiles-change-control.

## Skills vs commands vs agents

| Kind    | Location                        | File shape                                                                                                                        | Loaded when                                                                                                      |
| ------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Skill   | `claude/skills/<name>/SKILL.md` | YAML frontmatter, exactly `name` + `description`; description carries the triggers                                                | model loads it on-demand when the description matches the task (see claude/skills/ship/SKILL.md for house style) |
| Command | `claude/commands/<name>.md`     | frontmatter optional: `handoff.md`/`kickoff.md` carry a `description:` block, the other 20 are plain markdown; filename = `/name` | user types `/name`; body becomes the prompt                                                                      |
| Agent   | `claude/agents/<name>.md`       | YAML frontmatter `name` + `description` (multi-line ok; see claude/agents/bug-finder.md)                                          | dispatched as a subagent by name                                                                                 |

Plugins contribute their own skills/commands/agents/hooks from their cache
dir; those load only if the plugin is in installed_plugins.json AND enabled at
launch. The `claude/skills/.gitignore` whitelist means the skills dir on disk
mixes tracked personal skills with untracked ECC/generated ones -- check
`git ls-files claude/skills` before assuming a skill is version-controlled.

## CLAUDE.md and @import

`claude/CLAUDE.md` (symlinked to `<config-dir>/CLAUDE.md`) loads every
session. Its last line, `@operating-principles.md`, is an @import: Claude Code
inlines the referenced file (resolved relative to the importing file's
directory -- both are symlinks into `claude/`, so it resolves) into the
session context. This is how `claude/operating-principles.md` applies to every
session without being duplicated. Project CLAUDE.md (repo root) stacks on top
of the global one. Nothing auto-loads `~/.claude/rules/` -- CLAUDE.md never
references it; only some ECC skills read it (open question whether vendoring
is still needed; see dotfiles-architecture-contract).

## Cloud containers (claude.ai/code)

Env vars, verified in this container and in repo sources:

| Var                  | Value in cloud | Consumer                                                                             |
| -------------------- | -------------- | ------------------------------------------------------------------------------------ |
| `CLAUDE_CODE_REMOTE` | `true`         | gate in .claude/hooks/session-start.sh:16 -- makes the hook a no-op on real machines |
| `CLAUDE_PROJECT_DIR` | repo root      | hook command in .claude/settings.json; fallback logic session-start.sh:21            |

**Launch ordering is THE load-bearing fact** (root cause commit c1c4500):
plugins load at CLI launch. Anything that installs a plugin AFTER launch
(e.g. a SessionStart hook) is dark until the NEXT session. Hence two
placements:

1. PRIMARY -- pre-launch: `.claude/settings.json` declares
   `enabledPlugins` + `extraKnownMarketplaces`; the platform installs them
   natively before launch, so session 1 has them (design landed in commit
   8d4507f). Alternative pre-launch placement: the environment's Setup script
   field runs before launch, has roughly a 5-minute budget
   (bootstrap-cloud.sh:64), and its disk writes are filesystem-snapshotted --
   paid once, reused by later sessions (bootstrap-cloud.sh:21-28). Custom
   base images are unsupported; the snapshot is the equivalent.
2. SELF-HEAL -- post-launch: the SessionStart hook (matcher
   `startup|resume`) runs bootstrap-cloud.sh to relink assets, reattribute
   git identity (platform seeds `Claude <noreply@anthropic.com>`; never copy
   the 1Password signing block into a container -- `reattribute_git_identity`
   sets `commit.gpgsign false`), reconcile settings.json from the template
   (`reconcile_claude_settings` -- needed because installers create
   settings.json with only plugin keys, which skips the seed; commit 910f2bc),
   and re-ensure plugins for the NEXT session.

Session lifecycle sources this repo matches on: `startup` (new session),
`resume` (continued session), `clear` (/clear), `compact` (context
compaction). The self-heal runs on `startup|resume`; account_guard on
`startup|clear|compact`.

Cloud containers are personal-account only; `installed_plugins.json` in this
container shows `ecc@ecc` v2.0.0 and `superpowers@claude-plugins-official`
v6.1.0 installed at session start (versions are volatile -- see Provenance).

## Statusline

`statusLine` key in settings.json (from claude/settings.json.tmpl):
`{"type": "command", "command": "node ~/.claude/statusline.js"}`. The script
is symlinked by `link_claude_config_dir` (install/common/claude-links.sh:132),
which also sweeps a stale `statusline.sh` from earlier setups. Requires node
on PATH; bootstrap-cloud.sh warns (does not abort) when node is missing. The
statusline follows the session's anchored dir (`workspace.current_dir`), not
shell `cd` -- which is why worktrees must be entered via the native worktree
tool (claude/CLAUDE.md "Worktree Default").

## Provenance and maintenance

Written 2026-07-02 from repo state at commit 26eae6d and live inspection of
the authoring cloud container. Volatile facts and how to re-verify:

| Fact                                    | Re-verify with                                                                                                 |
| --------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| Config-dir routing logic                | `grep -n "_claude_config_dir" zsh/functions.zsh`                                                               |
| Symlink set per config dir              | `grep -n "ln -sf" install/common/claude-links.sh`                                                              |
| User-layer hook registrations           | `python3 -c "import json; print(json.dumps(json.load(open('claude/settings.json.tmpl'))['hooks'], indent=2))"` |
| Project-layer plugin declaration + hook | `cat .claude/settings.json`                                                                                    |
| Installed plugins + versions (live)     | `cat ~/.claude/plugins/installed_plugins.json`                                                                 |
| Registered marketplaces (live)          | `cat ~/.claude/plugins/known_marketplaces.json`                                                                |
| Marketplace manifest lists a plugin     | `grep '"name"' ~/.claude/plugins/marketplaces/<name>/.claude-plugin/marketplace.json`                          |
| Marketplace URLs (ECC, official)        | `grep -n "REPO_URL" bootstrap-cloud.sh`                                                                        |
| Retry budget / backoff cap              | `grep -n "PLUGIN_RETR" bootstrap-cloud.sh`                                                                     |
| Hook exit-code behavior                 | `grep -n "sys.exit" claude/hooks/<hook>.py`                                                                    |
| Hook script inventory                   | `ls claude/hooks/*.py`                                                                                         |
| Tracked vs untracked skills             | `git ls-files claude/skills` vs `ls claude/skills`                                                             |
| @import still present                   | `tail -1 claude/CLAUDE.md`                                                                                     |
| CLAUDE_CODE_REMOTE gate                 | `grep -n "CLAUDE_CODE_REMOTE" .claude/hooks/session-start.sh`                                                  |
| Statusline command                      | `grep -n "statusline" claude/settings.json.tmpl install/common/claude-links.sh`                                |
| Cited commits still exist               | `git show --stat -s c1c4500 8d4507f 7cb28b7 722c653 910f2bc 5b799dd 52f807d`                                   |

Dated/volatile: plugin versions (ecc 2.0.0, superpowers 6.1.0 on 2026-07-02);
the settings-precedence chain and enabledPlugins merge rules are
inferred-from-docs, not repo-proven -- re-check against current Claude Code
docs before relying on the exact ordering; the CLI verb spelling
(`claude plugin marketplace` vs `claude plugins`) tracks the installed CLI and
may change across releases (`claude plugin --help`).
