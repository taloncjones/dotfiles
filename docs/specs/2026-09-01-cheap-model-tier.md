# Budget-capped cheap-model tier for mechanical worker tasks

Task: `td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical`
Base: origin/main @ 8a377cc (verification contracts merged, #78)
Status: spec (branch-only; dropped before merge per repo convention)

## Problem

Model routing in herdr-orchestration stops at `sonnet` for the implement
role. Mechanical work (lint sweeps, test babysitting, doc updates, CI-log
triage) burns Sonnet tokens; no worker has a turn or dollar ceiling, so a
runaway worker has no guardrail; and spend is invisible to the orchestrator
and the human.

## Goals

1. A `mech` worker role that resolves haiku-first through the existing
   deterministic resolver (`resolve-model` + `capabilities.json`).
2. Mech workers launch with hard turn and dollar caps.
3. Per-task spend is recorded machine-locally and cumulative spend is
   surfaced by `status`.
4. Every existing gate (contract pin, contract gate, review, post-rebase
   merge check) applies to mech tasks unchanged.

## Non-goals

- Automatic tier selection. A human designates a task as mech; the
  orchestrator never infers "this looks mechanical".
- Automatic escalation from mech to impl on a cap hit. The orchestrator
  surfaces the cap hit and the spend; the human decides.
- Spend tracking for interactive (non-mech) workers. Interactive `claude`
  sessions expose no structured cost record; their spend stays untracked
  and is reported as such.
- Repo-wide or daily spend ceilings. Per-launch caps plus visible
  cumulative spend are the guardrail; a global ceiling is a later slice.
- Effort tuning (`--effort`) for mech workers.

## Verified facts the design rests on

Confirmed live on this machine (Claude Code 2.1.258, herdr 0.8.2,
2026-09-01):

- `--max-budget-usd <amount>` and `--max-turns <n>` are accepted only with
  `-p/--print`. There is no cap for an interactive session.
- `claude -p --output-format json` returns one result object carrying
  `subtype` (`success`, `error_max_turns`, `error_max_budget_usd`,
  `error_during_execution`), `is_error`, `num_turns`, `total_cost_usd`,
  `duration_ms`, `session_id`, and `errors[]`. A budget hit on the first
  turn returned `subtype: error_max_budget_usd`, `num_turns: 1`,
  `total_cost_usd: 0.058`.
- `herdr agent list`/`agent get` carry no model field and (per SKILL.md
  section 8) registration is pane-based. Whether herdr registers a
  print-mode `claude` as an agent is NOT verified; the design does not
  depend on it (see Liveness).

Assumed, to be verified during implementation (listed in the plan as a
live check, not a unit test): Stop hooks fire in print mode with the pane's
inherited `HERDR_ENV`/`HERDR_WORKSPACE_ID`, so the worker-status hook still
appends `stopped` and pushes a wake. If they do not, the spend-ledger
append (which the watch also observes) is the wake, so nothing is lost.

## Design

### 1. Role and model resolution

- `ROLE_DEFAULTS` gains `"mech": ("haiku", "sonnet")`.
- `CAP_MODELS` becomes `("fable", "opus", "sonnet", "haiku")`.
  `capabilities.json` must carry exactly these four aliases, each boolean.
  A three-alias map written by an older session fails validation, which
  `resolve-model` already reports as exit 3 (absent/stale) and the
  section-1 preflight re-probes. No migration.
- The section-1 probe writes `haiku: true` by default alongside
  `opus`/`sonnet` (the strong-model probe stays fable-only). A failed mech
  launch attributable to the model flips `haiku` off via the existing
  `disable-model` (which accepts the new alias).
- `config.json` `models.mech` may override the list under the same
  validation rules as the other roles (list of known aliases, non-empty).
- The SKILL.md section-8 routing table gains a row:
  `Mechanical worker (mech) | haiku -> sonnet | default | human-designated
  mechanical work, headless, turn+budget capped`.

### 2. Designation and maturity

A kickoff is a mech kickoff only when the human says so ("kick off X as
mech", optionally with caps) or the todo's frontmatter carries
`tier: mech`. Jira-kind tasks are designated only by kickoff instruction.

A mech item is never treated as raw: it skips the plan phase (the human's
designation IS the judgment that no design is needed) and dispatches
straight to `phase: implement`, `role: mech`. It still requires a committed
contract at `claude/contracts/<task_id>-contract.json` and goes through the
section-2 "Contract pinning" steps unchanged.

Contract source for a mech item, in order:

1. Already committed on the base or branch: use it.
2. Else, if `config.json` carries `mech.contract_commands` (1-32 entries in
   the contract command shape), the orchestrator writes
   `claude/contracts/<task_id>-contract.json` with `v: 1`, the task id,
   and those commands verbatim, and commits it on the fresh task branch
   (`<task_id>: Add mech contract`) BEFORE the pin/launch steps. This is
   the only commit the orchestrator ever authors; it happens inside the
   section-2 step 3-6 window so step 9's failure cleanup covers it.
3. Else refuse with a concrete message: "mech kickoff needs a committed
   contract or `mech.contract_commands` in config; kick off as raw instead".

### 3. Caps and config

`config.json` gains an optional `mech` object:

```json
"mech": {
  "max_turns": 40,
  "max_budget_usd": 2.0,
  "timeout_secs": 1800,
  "contract_commands": [
    {"name": "core-unit-suite", "run": "sh claude/hooks/herdr-orch.test.sh", "timeout_secs": 600}
  ]
}
```

Defaults when absent: `max_turns 40`, `max_budget_usd 2.0`,
`timeout_secs 1800`, no `contract_commands`. Validation (read by
`mech-caps`, below): `max_turns` integer 1-500; `max_budget_usd` number
> 0 and <= 50; `timeout_secs` integer 60-14400; `contract_commands`, when
present, validates with the same rules as a contract's `commands` array.
A malformed `mech` block refuses mech kickoff (exit 5 from `mech-caps`)
rather than silently reverting to defaults, matching the `models` rule.

A kickoff instruction may override `max_turns`/`max_budget_usd` for that
launch within the same bounds. The effective caps are recorded on the
launch (ledger line) and in the `workers[]` entry.

New read-only verb `python3 "$CORE" mech-caps --repo-slug <slug>
[--max-turns N] [--max-budget-usd X]` prints the effective caps as one
JSON object `{max_turns, max_budget_usd, timeout_secs}` (config merged
with overrides) or exits 5 on invalid config/override. The skill never
computes caps by hand.

### 4. Launch: headless, wrapped by the core

Mech workers run in print mode because the caps exist only there. The
orchestrator does not launch `claude` directly; it launches a core wrapper
in the workspace's own root pane (same pane rule as section 8):

```
herdr pane run <pane_id> "python3 $CORE run-mech --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent mech-<t> --model $MODEL --worktree <worktree_path> --base-sha <base_sha> --brief-file <STATE_ROOT>/<slug>/tasks/<task_id>.brief.md --max-turns <N> --max-budget-usd <X> --timeout-secs <T>"
```

A plain invocation, no shell metacharacters. `$MODEL` comes from
`resolve-model --role mech` with the same nonzero-exit rules as every
other role. The brief file is written by the orchestrator under
`STATE_ROOT/<slug>/tasks/` (machine-local prose, not state JSON; never in
the worktree) and must be contained in `STATE_ROOT`.

`run-mech`:

1. Validates args (`--agent` matches `mech-[a-z0-9-]*`, caps within bounds,
   brief file readable and contained in `STATE_ROOT`, `--worktree` an
   existing directory, `--base-sha` 40 hex).
2. Runs `claude --model <M> --permission-mode auto --name <agent> -p
   --output-format json --max-turns <N> --max-budget-usd <X>` with the
   brief on stdin, cwd = `--worktree` (must be an existing directory;
   the pane cwd is not trusted), environment inherited, wall-clock limit `--timeout-secs` (kill on expiry).
3. Parses the single result object from stdout. Appends ONE line to
   `tasks/<task_id>.spend.jsonl` (schema in section 6). Unparseable or
   missing output yields a line with `subtype: "unparseable"` (or
   `"timeout"`), `total_cost_usd: null`, `num_turns: null`.
4. Guarantees a completion record. If `tasks/<task_id>.done.json` is
   absent, or its `agent`/`workspace_id` do not equal this launch's, the
   worker did not emit its own record; the wrapper writes one with the
   same shape `emit-done` produces, `phase: implement`, `head_sha` =
   `git rev-parse HEAD` in the worktree, `base_sha` from `--base-sha`,
   plus a new optional field `reason`:
   - `error_max_turns` -> `outcome: paused`, `reason: max_turns`
   - `error_max_budget_usd` -> `outcome: paused`, `reason: max_budget`
   - `success` with no record -> `outcome: paused`, `reason: no_emit`
   - `timeout` -> `outcome: paused`, `reason: timeout`
   - `error_during_execution`, `unparseable`, nonzero exit with no result
     -> `outcome: failed`, `reason: error`
   A worker-written record is never overwritten.
5. Exits 0 whenever the ledger line was written, regardless of worker
   outcome; nonzero only for wrapper-level failures (bad args, `claude`
   not found, ledger unwritable).

The brief is the new mech variant in `brief-template.md`: implement-brief
framing plus "you are a budget-capped mechanical worker: N turns, $X;
do only the mechanical task described; do not brainstorm, spec, or plan;
if the task turns out to need design, commit what is safe, emit `paused`,
and say why". Its close is the implement close (verify-contract, then
`emit-done --phase implement`).

State publication follows section 2 step 7 unchanged: the `workers[]`
entry carries `role: "mech"`, `phase: "implement"`, `model`,
`peer_name: null` (a print-mode session is not subscribable; no
`ListAgents` discovery), `created_by_this_orch`, `started`, and the
effective `caps: {max_turns, max_budget_usd, timeout_secs}`. The reverse
index role stays `impl` (the hook classes a mech Stop as `stopped`,
exactly like a plan worker).

### 5. Liveness and check-in

Section 4's live-state table gets a mech rule that replaces the
`herdr agent` poll for `role: mech` workers, because herdr registration
of a print-mode process is unverified:

| Ledger state for the live launch (matching `workspace_id` + `agent`, `ts` >= `started`) | Action |
| --- | --- |
| no ledger line yet, wrapper pane alive | in-progress |
| no ledger line, wrapper pane gone | `abandoned` if never completed (same as the absent row) |
| ledger line present | run the completion correlation; `done.json` is guaranteed |

Correlation is the existing one: `confirm-completion` (with the same
`--workspace` provenance check), the git-ahead check, the phase gate, and
the contract gate. A `paused` record with a `reason` is reported as
"paused: <reason>, spent $X over N turns" with two recommended next
actions, in order: re-kickoff as mech with raised caps, or resume on the
`impl` role. `failed` is handled by the section-9 table unchanged.

`WATCH_DIRS["tasks"]` gains `.spend.jsonl`, so a ledger append wakes the
watch even if the Stop hook never fires in print mode.

### 6. Spend ledger and status

`tasks/<task_id>.spend.jsonl` is the per-task spend record: append-only,
one line per mech launch, written only by `run-mech` (one writer per
launch; launches for one task are sequential because the task has one
workspace). It is the authoritative spend source, the way `done.json` is
the authoritative completion source; the task record does NOT duplicate
spend (no orchestrator read-modify-write, no carry-forward rule).

```json
{
  "v": 1,
  "task_id": "td-x",
  "workspace_id": "w1",
  "agent": "mech-td-x",
  "role": "mech",
  "model": "haiku",
  "subtype": "success",
  "is_error": false,
  "num_turns": 17,
  "total_cost_usd": 0.42,
  "duration_ms": 184000,
  "max_turns": 40,
  "max_budget_usd": 2.0,
  "timeout_secs": 1800,
  "session_id": "<uuid>",
  "ts": "2026-09-01T20:00:00Z"
}
```

`status` output per task gains
`"spend": {"usd": <sum>, "turns": <sum>, "launches": <count>}` (zeros
when no ledger exists) and the top-level object gains
`"_totals": {"usd", "turns", "launches", "untracked_workers": <count of
workers[] entries whose role is not mech>}`. `_totals` cannot collide
with a task id (task ids start alphanumeric). Malformed ledger lines and
lines with `total_cost_usd: null` are skipped for the sums but counted
in `launches`, mirroring the events fold. The skill's section-4 report
line includes the per-task spend and the section-1 status summary
includes `_totals`.

### 7. Review, merge, Jira

Unchanged. A mech `completed` runs the contract gate, dispatches co-review
on the `review` role, and takes the post-rebase merge check. Jira
writeback rules apply by task kind, not by role.

## Acceptance criteria

AC1. `resolve-model --role mech` prints `haiku` when the map has
`haiku: true`, `sonnet` when only sonnet survives, exit 4 when neither,
exit 5 on a malformed `models.mech`.
AC2. `write-capabilities` rejects a map missing `haiku`; `disable-model
--model haiku` flips it.
AC3. `mech-caps` prints defaults with no config block, merges a valid
config block, applies in-bounds overrides, exits 5 on any out-of-bounds or
malformed value.
AC4. `run-mech` with a fake `claude` on PATH: success + worker-written
`done.json` -> ledger line, record untouched; `error_max_turns` and
`error_max_budget_usd` without a record -> ledger line + `paused` record
with the matching `reason`; `success` without a record -> `paused`/
`no_emit`; `error_during_execution` -> `failed`/`error`; unparseable
stdout -> `subtype: unparseable`, null cost, `failed`; timeout ->
`subtype: timeout`, `paused`/`timeout`; a stale `done.json` from another
agent is replaced, a matching one is never overwritten.
AC5. `run-mech` refuses a brief path outside `STATE_ROOT`, a non-`mech-`
agent name, out-of-bounds caps, and a non-40-hex base sha.
AC6. `status` sums a ledger with valid, malformed, and null-cost lines
into `spend` and `_totals` as specified; a task with no ledger reports
zeros; `untracked_workers` counts non-mech workers.
AC7. `watch_scan` includes `.spend.jsonl` under `tasks/`.
AC8. `validate_contract` accepts a contract generated from
`mech.contract_commands`; the walkthrough suite drives a mech kickoff
(contract generated + committed on a fresh branch, pin computed,
`run-mech` invoked through the fake herdr `pane run`, ledger + record
land, `status` reports spend).
AC9. SKILL.md (sections 1, 2, 4, 8, 9), `state-layout.md`,
`brief-template.md`, and `event-schema.md` describe the mech role,
ledger, caps, and liveness rule; the existing docs drift checks pass.
AC10 (human-verify, live): a real mech launch through herdr on this repo
produces a Stop-hook `stopped` event or, failing that, a ledger-driven
wake; the section-4 check-in reaches `completed` or `paused` without
manual intervention.

## Open risks

- Print-mode `claude` under `--permission-mode auto` may still block on a
  permission prompt; the worker-status hook's `blocked` event covers it,
  and `--timeout-secs` bounds the wait.
- The `total_cost_usd` figure is Claude Code's own estimate; treat it as
  advisory for budgeting, not billing.
