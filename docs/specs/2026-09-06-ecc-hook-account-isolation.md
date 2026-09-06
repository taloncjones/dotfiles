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
| `pre:mcp-health-check`, `post:mcp-health-check` | mcp-health-check.js | reads `~/.claude.json`, `~/.claude/settings.json`; writes `~/.claude/mcp-health-cache.json` (`os.homedir`) | state read + write; probes the other account's MCP servers | yes | yes | `ECC_MCP_HEALTH_STATE_PATH`, `ECC_MCP_CONFIG_PATH` (literal paths) | exclude: the config-path knob cannot express the personal account's real `.claude.json`, which is the HOME-root file, not `~/.claude/.claude.json`; neither account declares an MCP server today, so nothing is lost |
| `stop:cost-tracker` | cost-tracker.js | `<data-home>/metrics/costs.jsonl` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `post:session-activity-tracker` | session-activity-tracker.js | `<data-home>/metrics/tool-usage.jsonl` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `post:ecc-metrics-bridge` | ecc-metrics-bridge.js | reads `<data-home>/metrics/costs.jsonl`; bridge file in `/tmp` keyed by session | state read | yes | yes (cost warnings computed from the other account's spend) | `ECC_AGENT_DATA_HOME` | scope |
| `stop:session-end` (Stop and SessionEnd) | session-end.js | `<data-home>/session-data` | state write | yes | yes (session summaries with project names) | `ECC_AGENT_DATA_HOME` | scope |
| `pre:compact` | pre-compact.js | `<data-home>/session-data` | state write | yes | yes | `ECC_AGENT_DATA_HOME` | scope |
| `session:start` | session-start.js (registered via session-start-bootstrap.js, which only resolves the plugin root and delegates to `run-with-flags.js session:start scripts/hooks/session-start.js`) | `<data-home>/session-data` (list, ensureDir); homunculus lease | state read/write | yes | yes for session-data | `ECC_AGENT_DATA_HOME` | scope |
| `stop:evaluate-session` | evaluate-session.js | `<data-home>/skills/learned` | state write | yes | already shared: `~/.claude*/skills` is one symlink into this repo for both accounts | `ECC_AGENT_DATA_HOME` | scoped in name only: the path moves under the account dir but both dirs' `skills` resolve to the same repo directory; the hermetic suite cannot assert non-sharing for this id and does not claim to |
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
2. Keep every hook that can be scoped enabled. Exclude only the five ids
   that have no usable scoping knob (three with none, two whose knob cannot
   express the personal account's file layout).
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
- `reconcile_claude_settings_file` (`install/common/claude-links.sh`) parses
  the template, and for the `env` dict only, replaces every occurrence of
  the token in each string value with the absolute path of the directory it
  is writing `settings.json` into (`os.path.dirname(os.path.abspath(dest))`),
  then serialises the result. Non-string values and every other top-level
  key are untouched. `env` stays template-owned: a hand-edited live `env` is
  replaced wholesale on the next reconcile, as today. Idempotent: two
  consecutive runs produce identical files.
- A reconciled `settings.json` must not contain the token.

New template `env` key (value shown before substitution):

| Key | Value | Scopes |
|---|---|---|
| `ECC_AGENT_DATA_HOME` | `{{CLAUDE_CONFIG_DIR}}` | `stop:cost-tracker`, `post:session-activity-tracker`, `post:ecc-metrics-bridge`, `stop:session-end`, `pre:compact`, `session:start`, `stop:evaluate-session` |

For the personal dir the substituted value is `~/.claude`, ECC's default, so
personal behaviour is unchanged. For the work dir, ECC state moves under
`~/.claude-work/{metrics,session-data,skills/learned}`. Existing personal
files are not migrated or touched.

The mcp-health-check knobs are not used. `ECC_MCP_CONFIG_PATH` is a literal
path list, and the personal account's user config is the HOME-root
`~/.claude.json` (Claude Code keeps `<CLAUDE_CONFIG_DIR>/.claude.json` only
when `CLAUDE_CONFIG_DIR` is set; `~/.claude/.claude.json` is a stub), so no
single template value resolves correctly for both dirs. The hook is excluded
instead (D2).

### D2. Exclusions

`ECC_DISABLED_HOOKS` becomes exactly this set (order stylistic; ECC parses a
set):

```
session-start:plan-canvas-sessions
stop:plan-canvas-pending
post:bash:command-log-audit
post:bash:command-log-cost
post:skill:track
pre:mcp-health-check
post:mcp-health-check
```

Loss accepted: the raw Bash command log (duplicated by Claude's own
transcripts), the cost log (duplicated by `metrics/costs.jsonl`), the
skill-run telemetry feeding ECC's skills dashboard, and MCP preflight
probes (no MCP server is declared in either account; if one is added later,
the hook can be re-enabled once upstream resolves its paths by config dir).

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
- Every hook is invoked through ECC's own gate: `run-with-flags.js <id>
  <script> <profiles>` for ids registered that way (`session:start` is
  driven at this delegated call; its bootstrap wrapper only resolves the
  plugin root), and `bash-hook-dispatcher.js post` for the two command-log
  ids, which exist only inside that dispatcher. `CLAUDE_PLUGIN_ROOT`,
  `ECC_HOOKS_ENABLED=true`, `ECC_HOOK_PROFILE=standard` are pinned so
  machine-level ECC settings cannot produce false results.
- Table-driven: one row per hook (id, script or dispatcher, profiles, event
  payload, expected write path). Plain shell functions; no mode flags.
- Assertions, for both fake accounts:
  - Excluded ids: no file appears under either fake config dir, exit 0.
    For `run-with-flags`-hosted ids stdout is the untouched payload; the
    Bash dispatcher may re-serialise, so only the file assertion applies to
    the two command-log ids.
  - Scoped ids under the work dir: the expected file appears under
    `home/.claude-work`; nothing appears under `home/.claude`.
  - Scoped ids under the personal dir: the expected file appears under
    `home/.claude`; nothing under `home/.claude-work`.
  - Controls (same fixture, template env removed): excluded ids write their
    file; scoped ids under the work dir write under `home/.claude`. A
    control that does not fail without the fix is a suite bug.
  - Flag gate: the seven excluded ids answer `no`; `stop:session-end`,
    `stop:cost-tracker`, `session:start`, `pre:bash:dispatcher`,
    `post:dispatcher:sync`, `pre:bash:gateguard-fact-force` answer `yes`.
- No network: the mcp-health-check fixture declares one server with no
  transport (neither `url`, `type`, nor `command`), which ECC reports as
  unsupported and caches as unhealthy without spawning or connecting. The
  assertion is on whether the cache file appears, not on server health.
- Registered in `bin/dotfiles-tests` after `plan-canvas-isolation.test.sh`.

### D4. Drift checks

- `claude/hooks/claude-hooks.test.sh`: the template check pins the exact
  seven-id set and `ECC_AGENT_DATA_HOME` with the literal token. The live
  `settings.json` check, per config dir, requires the seven ids (superset,
  as today) and requires `ECC_AGENT_DATA_HOME` to equal that config dir's
  absolute path (`abspath`, not `realpath`, matching reconcile). Any
  remaining token in a live `env` value is a FAIL.
- `install/claude-links.test.sh`: the link path delivers the substituted
  values into a scratch config dir; two consecutive runs converge; two
  different scratch dirs receive different values.

### D5. Documentation

CLAUDE.md's `ECC_DISABLED_HOOKS` bullet is rewritten to: the seven ids and
why; the token mechanism and `ECC_AGENT_DATA_HOME`; the two suites; the
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
five new exclusions and the token key can be removed.

## Acceptance criteria

Contract: `claude/contracts/td-2026-09-06-scope-every-ecc-hook-that-reads-the-home-config-di-contract.json`
(26 commands, all repo-local and hermetic; the isolation commands read the
installed ECC clone and SKIP-or-FAIL per their knob when it is absent).

| # | Criterion | Contract command(s) |
|---|---|---|
| AC1 | Template `ECC_DISABLED_HOOKS` parses to exactly the seven ids in D2 | `template-excludes-exactly-seven-ids` |
| AC2 | Template `env` has `ECC_AGENT_DATA_HOME` equal to the literal token, no MCP keys, and keeps the existing keys; template stays valid JSON | `template-has-token-key`, `template-keeps-existing-env-keys`, `template-is-valid-json` |
| AC3 | Reconcile substitutes the token with the absolute dest config dir in `env` values only; two runs converge; two dirs differ | `links-suite`, `reconcile-converges` |
| AC4 | No token remains in a reconciled file | `reconcile-leaves-no-token`, `links-suite` |
| AC5 | Live drift check passes on a reconciled dir and fails when a config dir lacks a new exclusion, has a foreign data home, or carries the raw token | `hooks-suite-passes-on-reconciled-dir`, `drift-fails-without-new-exclusion`, `drift-fails-on-foreign-data-home`, `drift-fails-on-unsubstituted-token` |
| AC6 | The five newly excluded ids (`post:bash:command-log-audit`, `post:bash:command-log-cost`, `post:skill:track`, `pre:mcp-health-check`, `post:mcp-health-check`) are inert under the template env; controls prove they write without it | `isolation-suite`, `isolation-suite-covers-every-planned-case`, `isolation-suite-fails-without-template-value` |
| AC7 | The scoped ids `stop:cost-tracker`, `post:session-activity-tracker`, `stop:session-end`, `pre:compact`, `session:start` write only under the account's own config dir; controls prove they write under `~/.claude` without the env (`post:ecc-metrics-bridge` is read-only and `stop:evaluate-session` is nominal, see the audit; neither is driven) | `isolation-suite`, `isolation-suite-covers-every-planned-case`, `isolation-suite-fails-without-data-home-key` |
| AC8 | TDD, dispatcher, GateGuard, and scoped ids stay enabled through the flag gate; the Plan Canvas suite still passes unmodified | `isolation-suite-covers-every-planned-case`, `canvas-suite-still-passes`, `canvas-suite-untouched` |
| AC9 | Suite SKIPs (exit 0) without ECC and FAILs with `ECC_HOOK_TEST_REQUIRE_ECC=1`; FAILs when the template lacks the exclusion or the data-home key | `isolation-suite-skips-without-ecc`, `isolation-suite-fails-without-template-value`, `isolation-suite-fails-without-data-home-key`, `new-suite-syntax` |
| AC10 | Suite registered in `bin/dotfiles-tests` | `runner-registers-suite` |
| AC11 | CLAUDE.md documents the seven ids, the token, `ECC_AGENT_DATA_HOME`, and both suites | `claude-md-documents-isolation` |
| AC12 | Existing suites still pass; changed files stay within scope; the parallel branch's paths and the Canvas suite are untouched; touched scripts parse; no emoji | `hooks-suite-sandboxed`, `changed-files-within-scope`, `no-parallel-branch-edits`, `canvas-suite-untouched`, `shell-syntax-of-touched-scripts`, `no-emoji-in-changed-files` |

## Assumptions and risks

- Settings `env` reaches hook subprocesses. ECC documents `ECC_DISABLED_HOOKS`
  as settable there and the GateGuard recovery text says the same; not
  live-proven in this repo. The hermetic suite proves the hooks' behaviour
  under the env, not Claude Code's delivery of it. A one-off live check
  (`printenv ECC_AGENT_DATA_HOME` from a work session) closes the gap after
  install.
- `ECC_AGENT_DATA_HOME` also redirects ECC CLI tools (sessions, memory)
  launched from a work session to `~/.claude-work`. This is the intent.
- Per-account user config location, confirmed on this machine: the
  personal account's `.claude.json` is `~/.claude.json` (HOME root) and the
  work account's is `~/.claude-work/.claude.json`. This is why no literal
  MCP config-path value can serve both dirs.
- `ECC_AGENT_DATA_HOME` also redirects `<data-home>/skills/learned`, which
  for both dirs is the same repo directory through the `skills` symlink;
  isolation for `stop:evaluate-session` is therefore nominal and outside
  Goal 1's guarantee.
- Upstream may rename ids or add new home-dir readers. The suite FAILs on a
  missing script (layout change) and the audit grep is one command to re-run.
- The personal dir's existing `~/.claude/bash-commands.log` and
  `cost-tracker.log` stop growing; they are not deleted.
