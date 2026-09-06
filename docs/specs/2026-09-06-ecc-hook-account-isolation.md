# ECC hook account isolation

Task: td-2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di
Branch: talon/td-2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di/ecc-hook-isolation
Status: spec (branch-only; dropped before merge)

## Problem

PR #86 switched off ECC's two Plan Canvas hooks because they key their state
on `~/.claude` regardless of `CLAUDE_CONFIG_DIR`. Its review noted the class
is wider: other installed ECC hook scripts resolve paths through
`os.homedir()` or `$HOME`. On this dual-account machine (`~/.claude` personal,
`~/.claude-work` work, one shared `$HOME`) any such hook reads or writes
personal state from a work session, or the reverse.

The exclusion in `claude/settings.json.tmpl` covers exactly two ids. This spec
covers the rest of the class for ECC 2.2.1 as installed.

## Audit (read-only, ECC 2.2.1, `scripts/hooks/` and the libs they import)

Method: grep the installed marketplace clone for `os.homedir()`, `~/.claude`,
`process.env.HOME`, and the shared helpers `getClaudeDir` /
`getSessionsDir` / `getAgentDataHome`; map every hit to the hook id that
runs it (from `hooks/hooks.json` and the three dispatchers); classify.
"On" means enabled under the `standard` profile ECC defaults to. Ids with no
profile list fall back to `standard,strict` (`hook-flags.js:parseProfiles`).

| Hook id | Script | Path it resolves | Class | On | Leaks across accounts | Upstream knob | Disposition |
|---|---|---|---|---|---|---|---|
| `session-start:plan-canvas-sessions` | plan-canvas-sessions.js | `~/.claude/plan-canvas` (`os.homedir`) | state read | yes | yes | `ECC_PLAN_CANVAS_STATE_DIR` | excluded by PR #86; unchanged |
| `stop:plan-canvas-pending` | plan-canvas-pending.js | same, plus Canvas server | state read/write | yes | yes | same | excluded by PR #86; unchanged |
| `post:bash:command-log-audit` | post-bash-command-log.js | `~/.claude/bash-commands.log` (`os.homedir`) | state write | yes (no profile list) | yes: every Bash command of a work session lands in the personal dir (5.4 MB live) | none | exclude |
| `post:bash:command-log-cost` | post-bash-command-log.js | `~/.claude/cost-tracker.log` (`os.homedir`) | state write | yes (no profile list) | yes (5.6 MB live); redundant with `stop:cost-tracker` metrics | none | exclude |
| `post:skill:track` | skill-run-tracker.js | `~/.claude/state/skill-runs.jsonl` (`os.homedir`) | state write | yes | yes (skill ids and outcomes) | none (`homeDir` option only, not env) | exclude |
| `pre:mcp-health-check`, `post:mcp-health-check` | mcp-health-check.js | reads `~/.claude.json`, `~/.claude/settings.json`; writes `~/.claude/mcp-health-cache.json` (`os.homedir`) | state read + write; probes the other account's MCP servers | yes | yes | `ECC_MCP_HEALTH_STATE_PATH`, `ECC_MCP_CONFIG_PATH` | scope via knobs |
| `stop:cost-tracker` | cost-tracker.js | `<data-home>/metrics/costs.jsonl` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `post:session-activity-tracker` | session-activity-tracker.js | `<data-home>/metrics/tool-usage.jsonl` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `post:ecc-metrics-bridge` | ecc-metrics-bridge.js | reads `<data-home>/metrics/costs.jsonl`; bridge file in `/tmp` keyed by session | state read | yes | yes (cost warnings computed from the other account's spend) | `ECC_AGENT_DATA_HOME` | scope |
| `stop:session-end` (Stop and SessionEnd) | session-end.js | `<data-home>/session-data` | state write | yes | yes (session summaries with project names) | `ECC_AGENT_DATA_HOME` | scope |
| `pre:compact` | pre-compact.js | `<data-home>/session-data` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `session:start` | session-start.js | `<data-home>/session-data` (list, ensureDir); homunculus lease | state read/write | yes | yes for session-data | `ECC_AGENT_DATA_HOME` | scope |
| `stop:evaluate-session` | evaluate-session.js | `<data-home>/skills/learned` | state write | yes | already shared: `~/.claude*/skills` is one symlink into this repo for both accounts | `ECC_AGENT_DATA_HOME` | scope; symlink sharing is pre-existing and out of scope |
| `pre:bash:gateguard-fact-force`, `pre:edit-write:gateguard-fact-force` | gateguard-fact-force.js | `$HOME/.gateguard/state-<session>.json` | state read/write, session-keyed, 30 min expiry | yes | no (HOME-level, not config-dir; keyed by session id) | `GATEGUARD_STATE_DIR` | keep; document |
| `stop:format-typecheck` | stop-format-typecheck.js | `~/.claude/plugins` (skip-list guard) | path guard, no state | yes | no state; guard misses `~/.claude-work/plugins` clones | none | keep; upstream nit |
| statusline (`ecc-statusline.js`) | | `CLAUDE_CONFIG_DIR` or `~/.claude` | display | n/a | no (already config-dir aware) | n/a | keep |
| `pre:observe`, `post:observe:continuous-learning`, `session:end:marker`, `session:start` lease | observer-sessions.js | `~/.local/share/ecc-homunculus` (XDG data dir) | state | yes | shared by XDG design, not a config-dir path | `XDG_DATA_HOME` (would move every XDG app) | out of class; document |
| `pre:governance-capture`, `post:governance-capture` | governance-capture.js | stderr only | display | yes | no | n/a | keep |
| all other registered ids | | cwd, transcript path, or `/tmp` keyed by session | display or cwd-scoped | | no | | keep |
| `cursor-session-env.js` | | agent-data-home | | not registered for Claude | n/a | | n/a |

`<data-home>` is `getClaudeDir()` in `scripts/lib/utils.js`, which returns
`ECC_AGENT_DATA_HOME` when set (absolute or `~`-expanded), else
`$HOME/.claude`. It never consults `CLAUDE_CONFIG_DIR`.

## Goals

1. No ECC hook enabled by the template reads or writes state under the other
   account's config dir. A work session touches only `~/.claude-work`; a
   personal session only `~/.claude`.
2. Keep every hook that can be scoped enabled. Exclude only the three ids
   that have no scoping knob.
3. Prove it hermetically: a test suite drives the installed hook scripts
   under a fake `$HOME` with two fake config dirs and asserts where state
   lands. Falsifiable controls show the same hooks leak without the fix.
4. Leave a re-check path for the next ECC upgrade: the audit table above,
   the suite, and the drift checks.

## Non-goals

- Modifying the ECC plugin clone. The upstream fix is proposed, not applied
  locally.
- Scoping the homunculus (XDG) store, GateGuard state, or the shared
  `skills/learned` symlink target.
- Changing the ECC hook profile, `ECC_HOOKS_ENABLED`, or any TDD or
  dispatcher id.
- Replacing `plan-canvas-isolation.test.sh`. It stays as is; the new suite
  covers the hooks this spec adds.

## Design

### D1. Per-account env values via a template token

Claude Code applies the settings `env` block to every session and its hook
subprocesses, on every launch path (desktop app, the `claude()` wrapper,
orchestrator workers that set `CLAUDE_CONFIG_DIR` directly, cloud
containers). Claude Code does not expand variables inside `env` values, and
the two config dirs are seeded from one template, so a per-dir value needs a
substitution step. Exporting the values from the zsh wrapper instead was
rejected: it misses every launch that bypasses the wrapper.

- The template gains a placeholder token `{{CLAUDE_CONFIG_DIR}}` in `env`
  string values. Exact token, no other substitutions.
- `reconcile_claude_settings_file` (`install/common/claude-links.sh`)
  replaces every occurrence of the token in `env` string values with the
  absolute path of the directory it is writing `settings.json` into
  (`os.path.dirname(os.path.abspath(dest))`). Only `env` values are
  substituted. Idempotent: two consecutive runs produce identical files.
- A reconciled `settings.json` must not contain the token.

New template `env` keys (values shown before substitution):

| Key | Value | Scopes |
|---|---|---|
| `ECC_AGENT_DATA_HOME` | `{{CLAUDE_CONFIG_DIR}}` | cost-tracker, session-activity-tracker, ecc-metrics-bridge, session-end, pre-compact, session:start, evaluate-session |
| `ECC_MCP_HEALTH_STATE_PATH` | `{{CLAUDE_CONFIG_DIR}}/mcp-health-cache.json` | mcp-health-check cache |
| `ECC_MCP_CONFIG_PATH` | `.claude.json:.claude/settings.json:{{CLAUDE_CONFIG_DIR}}/.claude.json:{{CLAUDE_CONFIG_DIR}}/settings.json` | mcp-health-check config search; relative entries resolve against the hook cwd (`path.resolve`), reproducing ECC's default list with the config dir substituted |

For the personal dir the substituted values equal ECC's defaults, so
personal behaviour is unchanged. For the work dir, ECC state moves under
`~/.claude-work/{metrics,session-data,mcp-health-cache.json}`. Existing
personal files are not migrated or touched.

`ECC_MCP_CONFIG_PATH` uses `:` as the separator (`path.delimiter` on macOS
and Linux; Windows is unsupported by these dotfiles).

### D2. Exclusions

`ECC_DISABLED_HOOKS` becomes exactly this set (order stylistic; ECC parses a
set):

```
session-start:plan-canvas-sessions
stop:plan-canvas-pending
post:bash:command-log-audit
post:bash:command-log-cost
post:skill:track
```

Loss accepted: the raw Bash command log (duplicated by Claude's own
transcripts), the cost log (duplicated by `metrics/costs.jsonl`), and the
skill-run telemetry feeding ECC's skills dashboard.

### D3. Hermetic isolation suite `claude/hooks/ecc-hook-isolation.test.sh`

Generalises `plan-canvas-isolation.test.sh`:

- Same preamble: run from repo root, SKIP (exit 0) without node, python3, or
  an installed ECC clone; `ECC_HOOK_TEST_REQUIRE_ECC=1` turns SKIP into FAIL;
  `ECC_PLUGIN_ROOT` overrides root discovery. FAIL (exit 1) when the ECC
  layout lacks a script the table names.
- Fixture: `mktemp -d` holding a fake `$HOME` with `home/.claude` (personal)
  and `home/.claude-work` (work). The real `~/.claude*` are never read or
  written. The template `env` is read from `claude/settings.json.tmpl` and
  the token substituted for the fake dir under test, exactly as reconcile
  would.
- Every hook is invoked through ECC's own gate
  (`run-with-flags.js <id> <script> <profiles>` or the relevant dispatcher
  for dispatcher-hosted ids) with `CLAUDE_PLUGIN_ROOT`, `ECC_HOOKS_ENABLED=true`,
  `ECC_HOOK_PROFILE=standard` pinned, so machine-level ECC settings cannot
  produce false results.
- Table-driven: one row per hook (id, script or dispatcher, profiles, event
  payload, expected write path). Plain shell functions; no mode flags.
- Assertions, for both fake accounts:
  - Excluded ids: stdout is the untouched payload; no file appears under
    either fake config dir.
  - Scoped ids under the work dir: the expected file appears under
    `home/.claude-work`; nothing appears under `home/.claude`.
  - Scoped ids under the personal dir: the expected file appears under
    `home/.claude`; nothing under `home/.claude-work`.
  - Controls (same fixture, template env removed): excluded ids write their
    file; scoped ids under the work dir write under `home/.claude`. A
    control that does not fail without the fix is a suite bug.
  - Flag gate: the five excluded ids answer `no`; `stop:session-end`,
    `pre:bash:dispatcher`, `post:dispatcher:sync`,
    `pre:bash:gateguard-fact-force` answer `yes`.
- No network: the mcp-health-check fixture configures at most one server
  whose transport cannot leave the machine (a nonexistent command or a
  loopback URL on a closed port). The assertion is on where the cache file
  lands, not on server health.
- Registered in `bin/dotfiles-tests` after `plan-canvas-isolation.test.sh`.

### D4. Drift checks

- `claude/hooks/claude-hooks.test.sh`: the template check pins the exact
  five-id set and the three new keys with the literal token. The live
  `settings.json` check, per config dir, requires the five ids (superset, as
  today) and requires `ECC_AGENT_DATA_HOME` to equal that config dir's
  absolute path and the two MCP keys to equal the substituted template
  values. Any remaining token in a live file is a FAIL.
- `install/claude-links.test.sh`: the link path delivers the substituted
  values into a scratch config dir; two consecutive runs converge; two
  different scratch dirs receive different values.

### D5. Documentation

CLAUDE.md's `ECC_DISABLED_HOOKS` bullet is rewritten to: the five ids and
why; the token mechanism and the three env keys; the two suites; the
remove-when-upstream condition. The audit table lives in this spec (branch-only)
and in the task's completion note; the suite header carries a one-paragraph
summary so the next ECC upgrade can re-run the grep and compare.

### D6. Upstream

Draft (in the completion note, not filed automatically; filing needs an
explicit go) an ECC issue proposing: a shared `resolveClaudeConfigDir()`
(`CLAUDE_CONFIG_DIR` else `~/.claude`) used by plan-canvas,
mcp-health-check, post-bash-command-log, skill-run-tracker, and the
format-typecheck plugin-clone guard; and `getDefaultClaudeAgentDataHome`
defaulting to `CLAUDE_CONFIG_DIR` when set. Once merged and installed, the
three new exclusions and the three env keys can be removed.

## Acceptance criteria

| # | Criterion | Verified by |
|---|---|---|
| AC1 | Template `ECC_DISABLED_HOOKS` parses to exactly the five ids in D2 | template check (contract `template-excludes-exactly-five-ids`) |
| AC2 | Template `env` has the three keys of D1 with the literal token, and keeps the existing keys | contract `template-has-token-keys`, `template-keeps-existing-env-keys` |
| AC3 | Reconcile substitutes the token with the absolute dest config dir in `env` values only; two runs converge; two dirs differ | `install/claude-links.test.sh` (contract `links-suite`) |
| AC4 | No token remains in a reconciled file | `links-suite`; contract `reconcile-leaves-no-token` |
| AC5 | Live drift check fails when a config dir lacks a new exclusion or has a data home that is not its own path | contract `drift-fails-without-new-exclusion`, `drift-fails-on-foreign-data-home` |
| AC6 | Excluded hooks are inert under the template env; controls prove they write without it | `ecc-hook-isolation.test.sh` (contract `isolation-suite`) |
| AC7 | Scoped hooks write only under the account's own config dir; controls prove they write under `~/.claude` without the env | `isolation-suite` |
| AC8 | TDD, dispatcher, and GateGuard ids stay enabled through the flag gate | `isolation-suite`; `plan-canvas-isolation.test.sh` |
| AC9 | Suite SKIPs (exit 0) without ECC and FAILs with `ECC_HOOK_TEST_REQUIRE_ECC=1`; FAILs when the template lacks the exclusion | contract `isolation-suite-skips-without-ecc`, `isolation-suite-fails-without-template-value` |
| AC10 | Suite registered in `bin/dotfiles-tests` | contract `runner-registers-suite` |
| AC11 | CLAUDE.md documents the five ids, the token, the three keys, and both suites | contract `claude-md-documents-isolation` |
| AC12 | Existing suites still pass; changed files stay within scope (no edits to the parallel branch's paths); the ECC clone is untouched by the repo diff | contract `hooks-suite-sandboxed`, `changed-files-within-scope`, `no-parallel-branch-edits` |

## Assumptions and risks

- Settings `env` reaches hook subprocesses. ECC documents `ECC_DISABLED_HOOKS`
  as settable there and the GateGuard recovery text says the same; not
  live-proven in this repo. The hermetic suite proves the hooks' behaviour
  under the env, not Claude Code's delivery of it. A one-off live check
  (`printenv ECC_AGENT_DATA_HOME` from a work session) closes the gap after
  install.
- `ECC_AGENT_DATA_HOME` also redirects ECC CLI tools (sessions, memory)
  launched from a work session to `~/.claude-work`. This is the intent.
- Relative entries in `ECC_MCP_CONFIG_PATH` depend on hooks running with the
  session cwd. Claude Code documents this; the suite pins it.
- Upstream may rename ids or add new home-dir readers. The suite FAILs on a
  missing script (layout change) and the audit grep is one command to re-run.
- The personal dir's existing `~/.claude/bash-commands.log` and
  `cost-tracker.log` stop growing; they are not deleted.
