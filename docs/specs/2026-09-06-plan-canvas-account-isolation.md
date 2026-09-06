# Isolate ECC Plan Canvas state across accounts

Task: td-2026-09-05-isolate-ecc-plan-canvas-state-across-accounts
Branch: talon/td-2026-09-05-isolate-ecc-plan-canvas-state-across-accounts/plan-canvas-isolation
Status: spec (branch-only document; dropped before merge)

## Summary

ECC 2.2.1 ships two Plan Canvas hooks that read a state directory shared by
every Claude account on the machine. On a dual-account machine (`~/.claude`
personal, `~/.claude-work` work) the work account can see personal Canvas
sessions and receive personal browser feedback. Neither account has Canvas
state today, so no disclosure has happened, but the exposure must be closed
before Canvas is used here.

Decision: disable exactly the two Plan Canvas hooks through the
dotfiles-managed settings template, and prove it with tests. Account-scoped
Canvas state is deferred to an upstream ECC change.

## Problem

Findings from the installed ECC marketplace clone
(`~/.claude/plugins/marketplaces/ecc`, version 2.2.1; the per-account plugin
caches at `plugins/cache/ecc/ecc/2.2.1` under both config dirs carry the same
`hooks/hooks.json`, verified by diffing hook ids):

| Component | File | State dir resolution | Behavior |
|---|---|---|---|
| SessionStart hook `session-start:plan-canvas-sessions` | `scripts/hooks/plan-canvas-sessions.js` | `ECC_PLAN_CANVAS_STATE_DIR`, else `os.homedir()/.claude/plan-canvas` | Prints every open session's artifact path (up to 5) into the new session's context, with no cwd scoping. |
| Stop hook `stop:plan-canvas-pending` | `scripts/hooks/plan-canvas-pending.js` | same | Drains undelivered feedback for sessions whose artifact is under the hook cwd (or all, with `ECC_PLAN_CANVAS_STOP_SCOPE=all`), blocks the stop, and hands the feedback text to the agent. Drains through the server on the port recorded in `server.json`, else by rewriting `sessions.json` directly. |
| Canvas CLI | `scripts/plan-canvas.js` | same, passed to the spawned server | Reuses whatever server answers on the port, regardless of which state dir that server was started with. |
| Canvas server and session store | `scripts/lib/plan-canvas/server.js`, `sessions.js` | same; port from `ECC_PLAN_CANVAS_PORT`, default 4517 | One loopback server per port owns `sessions.json` while running. No state migration code exists in 2.2.1. State files are written with default permissions under the state dir. |

Consequences on this machine:

- Both accounts resolve the same `~/.claude/plan-canvas` because `CLAUDE_CONFIG_DIR` is not consulted anywhere in the Canvas code.
- SessionStart under the work account enumerates personal artifact paths from any repo.
- Stop under the work account, in a repo the personal account also reviewed, delivers the personal feedback text to the work session and blocks the work stop.
- Even with per-account state dirs, the single default port means the CLI of one account would attach to the other account's server.

Both hooks run through ECC's flag gate (`scripts/hooks/run-with-flags.js` and
`scripts/lib/hook-flags.js`): a hook id listed in `ECC_DISABLED_HOOKS`
(comma-separated, case-insensitive) is skipped with stdin passed through. The
Stop hook's inline launcher in `hooks.json` invokes the same gate with the same
id, so both ids are disable-able by that one variable. ECC's own recovery hint
on this machine already points at `ECC_DISABLED_HOOKS` for hook opt-outs.

## Options considered

1. **Disable the two hooks via `ECC_DISABLED_HOOKS` in the settings template env** (chosen).
   One static value, identical for both accounts. The template's `env` key is
   template-owned: `reconcile_claude_settings_file` reasserts it wholesale on
   every `update`, so both config dirs receive it without per-dir logic.
   Cost: the hook-driven Canvas delivery is off for both accounts until
   upstream scopes state by config dir. The Canvas CLI `await` loop still
   works when a user runs it deliberately.
2. **Account-scoped state dir via `ECC_PLAN_CANVAS_STATE_DIR`** (rejected for this task).
   The template cannot express a per-config-dir value, and the platform does
   not expand variables inside settings `env`. Delivering it would need the
   `claude()` wrapper to export the override plus a per-account
   `ECC_PLAN_CANVAS_PORT` to avoid the shared-port cross-attach, and would
   leave unwrapped or IDE launches of the work account uncovered. That
   touches the reconcile code a parallel branch is editing and is larger than
   the exposure warrants while Canvas is unused here.
3. **Patch the vendored clone** (rejected). Plugin caches are ECC-owned and
   overwritten on update.

Follow-up outside this task: an upstream ECC change defaulting the state dir
under the active config dir and namespacing the server port. Record as a repo
todo, not a ticket, when implementation lands.

## Requirements

R1. `claude/settings.json.tmpl` `env` carries
`"ECC_DISABLED_HOOKS": "session-start:plan-canvas-sessions,stop:plan-canvas-pending"`.
The value is the complete exclusion list. No other ECC hook id appears in it
(the template holds no exclusions today, in either live settings file, so
nothing existing is dropped).

R2. Every other template env key is preserved unchanged
(`ANTHROPIC_DEFAULT_OPUS_MODEL`, `CLAUDE_CODE_DISABLE_TELEMETRY`,
`ECC_CONTEXT_MONITOR_COST_WARNINGS`).

R3. After `update` (that is, after `reconcile_claude_settings_file`) both live
settings files carry the value from R1. Two consecutive reconcile runs produce
byte-identical output.

R4. The settings drift test (`claude/hooks/claude-hooks.test.sh`) asserts,
statically from the template, that the exclusion list is exactly the two ids,
and, against each live settings file that exists, that its `env` contains both
ids. Machines that missed an update fail visibly, matching the existing hook
and permissions drift checks.

R5. A hermetic behavioral test proves the isolation against the installed ECC
scripts using a fake state dir and a fake home, never the real
`~/.claude/plan-canvas`. It is a repo test file run by the verification
contract, and by `bin/dotfiles-tests` with a SKIP when no ECC clone is
installed (CI has none). Scenarios, each run under a fake personal config dir
and a fake work config dir:

- personal-to-work isolation: pending personal feedback for an artifact under
  the hook cwd, Stop hook runs with the template env, output is stdin
  pass-through with no `block` decision and no feedback text;
- same repo under both accounts: as above with `CLAUDE_CONFIG_DIR` pointing at
  each fake config dir in turn; both silent;
- unrelated repo: pending feedback for an artifact outside the cwd; silent
  with and without the template env (the hook's own cwd scoping);
- concurrent feedback: two open sessions with pending items; still silent;
- SessionStart enumeration: open sessions present, SessionStart hook runs with
  the template env, prints nothing;
- falsifiability: the same fixture without `ECC_DISABLED_HOOKS` produces the
  `block` decision (Stop) and the session listing (SessionStart), proving the
  fixture is live and the exclusion is what silences it;
- collateral hooks stay enabled: with the template env, ECC's
  `check-hook-enabled.js` answers `yes` for `stop:session-end`,
  `pre:bash:dispatcher`, and `post:dispatcher:sync`, and `no` for the two
  Canvas ids;
- the fixture's `sessions.json` is byte-identical after every silent run (no
  drain, no migration of personal content).

R6. No vendored file under any `plugins/` cache or marketplace clone is
modified. No file outside the repo is written by the tests or the contract.

R7. Legitimate personal Canvas use in a work repo is unchanged in the only path
that still exists: the deliberate `plan-canvas await` CLI loop. The spec records
that hook-driven delivery is off for both accounts; this is a documentation
requirement (CLAUDE.md note next to the ECC plugin description), not a test.

R8. The change is confined to `claude/settings.json.tmpl`,
`claude/hooks/claude-hooks.test.sh`, `install/claude-links.test.sh`, one new
test file under `claude/hooks/`, `bin/dotfiles-tests`, and `CLAUDE.md`. It does
not touch `zsh/functions.zsh` or `install/common/claude-links.sh`, which a
parallel branch is editing.

## Acceptance criteria

AC1. Template env contains exactly the two Canvas hook ids in
`ECC_DISABLED_HOOKS` and the three pre-existing keys with their current values.
AC2. Reconcile into a scratch config dir yields the value; a second reconcile
is byte-identical.
AC3. Drift test passes on a reconciled machine and fails when a live env lacks
either id (demonstrated against a scratch settings file).
AC4. Behavioral fixture: Stop and SessionStart hooks are silent under both fake
accounts for cwd-scoped, unrelated-repo, and concurrent-feedback cases, and the
fixture state file is unchanged afterward.
AC5. Behavioral fixture without the exclusion blocks and enumerates
(falsifiable control).
AC6. Non-Canvas ECC hook ids remain enabled under the template env.
AC7. `git status` of the plugin caches and marketplace clone is unchanged by
the implementation and its tests, and `bin/dotfiles-tests` passes in full.
AC8. CLAUDE.md documents the exclusion, why it exists, and the condition for
removing it (upstream ECC scoping state by config dir).

## Out of scope

- Per-account Canvas state dirs and ports (upstream follow-up).
- The Codex ECC package, which does not ship these hooks.
- Any change to the `claude()` wrapper or the reconcile function.
- Migrating or deleting existing Canvas state (none exists on this machine;
  the tests never touch the real state dir).

## Risks

- The platform must export settings `env` to hook processes. This is the
  same mechanism the template already relies on for
  `ECC_CONTEXT_MONITOR_COST_WARNINGS` and is confirmed by ECC's own opt-out
  hint. The behavioral test injects the env directly, so the live-session
  path is verified by a human check: from a Claude Bash tool call under each
  account, `check-hook-enabled.js stop:plan-canvas-pending` prints `no`.
- A future ECC release could rename the hook ids. The drift test pins the ids
  against the template only; the behavioral test resolves the installed ECC
  root and fails loudly if the scripts move, which is the desired signal.
