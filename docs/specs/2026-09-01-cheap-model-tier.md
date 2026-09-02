# Budget-capped cheap-model tier for mechanical worker tasks

Task: `td-2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical`
Base: origin/main @ 8a377cc (verification contracts merged, #78)
Status: spec, revision 2 after Codex spec review (branch-only; dropped
before merge per repo convention)

## Problem

Model routing in herdr-orchestration stops at `sonnet` for the implement
role. Mechanical work (lint sweeps, test babysitting, doc updates, CI-log
triage) burns Sonnet tokens; no worker has a turn or dollar ceiling, so a
runaway worker has no guardrail; and spend is invisible to the orchestrator
and the human.

## Goals

1. A `mech` worker role that resolves haiku-first through the existing
   deterministic resolver (`resolve-model` + `capabilities.json`).
2. Mech workers launch with turn and dollar caps enforced by the Claude
   Code CLI between turns (see "Cap semantics").
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
  and `status` counts them as untracked launches.
- Repo-wide or daily spend ceilings, and ledger retention/rotation.
  Per-launch caps plus visible cumulative spend are the guardrail.
- Effort tuning (`--effort`) for mech workers.
- Cheap models for the `plan`/`impl`/`review` roles. `haiku` is a
  mech-only alias (section 1).

## Verified facts the design rests on

Confirmed live on this machine (Claude Code 2.1.258, herdr 0.8.2,
2026-09-01):

- `--max-budget-usd <amount>` and `--max-turns <n>` are accepted only with
  `-p/--print`. There is no cap for an interactive session.
- `claude -p --output-format json` returns one result object carrying
  `subtype` (`success`, `error_max_turns`, `error_max_budget_usd`,
  `error_during_execution`), `is_error`, `num_turns`, `total_cost_usd`,
  `duration_ms`, `session_id`, `errors[]`, and `modelUsage` (an object
  keyed by the full model id actually used). A budget hit on the first
  turn returned `subtype: error_max_budget_usd`, `num_turns: 1`,
  `total_cost_usd: 0.058` -- the cap is checked after a turn completes,
  so overshoot is bounded by one turn.
- `herdr agent list`/`agent get` carry no model field and (per SKILL.md
  section 8) registration is pane-based. Whether herdr registers a
  print-mode `claude` as an agent is NOT verified; the design does not
  depend on it (section 5).

Assumed, to be verified during implementation as a live check (AC10),
not a unit test: Stop and Notification hooks fire in print mode with the
pane's inherited `HERDR_ENV`/`HERDR_WORKSPACE_ID`. Nothing below depends
on them: the ledger writes (section 6) are watched and are the wake.

### Cap semantics

"Capped" means: the CLI stops starting new turns once `num_turns` reaches
`max_turns` or its cost estimate reaches `max_budget_usd`, and reports the
hit as a result `subtype`. Overshoot is at most the cost of the turn in
flight. `total_cost_usd` is the CLI's own estimate, used for budgeting and
reporting, never for billing. The wrapper's wall-clock `timeout_secs` is
the third, outer bound.

## Design

### 1. Role and model resolution

- `ROLE_DEFAULTS` gains `"mech": ("haiku", "sonnet")`.
- `CAP_MODELS` becomes `("fable", "opus", "sonnet", "haiku")`.
  `capabilities.json` must carry exactly these four aliases, each boolean.
  A three-alias map written by an older session fails validation, which
  `resolve-model` already reports as exit 3 (absent/stale) and the
  section-1 preflight re-probes. No migration.
- Per-role allowed aliases: `plan`/`impl`/`review` overrides may name only
  `fable`/`opus`/`sonnet`; `mech` may name any of the four. `haiku` in a
  non-mech override makes `role_preference` return None (exit 5), the
  same fail-closed rule as an unknown token.
- The section-1 probe writes `haiku: true` by default alongside
  `opus`/`sonnet` (the strong-model probe stays fable-only).
  `disable-model` accepts the new alias.
- The SKILL.md section-8 routing table gains a row:
  `Mechanical worker (mech) | haiku -> sonnet | default | human-designated
  mechanical work, headless, turn+budget capped`.
- Agent name: `agent_name("mech", task_id)` -- the canonical constraints
  (`mech-<t>`, `[a-z0-9-]`, whole name <= 32 chars, `-2`/`-3` on
  collision). Display label `mech:<task_id>`.

### 2. Designation, caps input, and maturity

Designation forms, fail-closed (anything else is not a mech kickoff):

- Kickoff instruction: `kick off <item> as mech` optionally followed by
  `max-turns <int>` and/or `budget <number>` (e.g. `... as mech max-turns
  60 budget 3`). Applies to todo and Jira items.
- Todo frontmatter: `tier: mech`, optionally `mech_max_turns: <int>` and
  `mech_max_budget_usd: <number>`.

Precedence: instruction values override frontmatter values, field by
field. An override that fails `mech-caps` validation (section 3) refuses
the kickoff with the verb's message; the orchestrator never clamps.

A mech item is never treated as raw: it skips the plan phase (the human's
designation IS the judgment that no design is needed) and dispatches
straight to `phase: implement`, `role: mech`. It still requires a committed
contract at `claude/contracts/<task_id>-contract.json` and goes through the
section-2 "Contract pinning" steps unchanged.

Contract source for a mech item, in order:

1. Committed at the branch HEAD (or the base, for a fresh branch): use it.
   An invalid committed contract refuses the kickoff (existing rule).
2. Else, if `config.json` carries `mech.contract_commands`, the
   orchestrator writes `claude/contracts/<task_id>-contract.json` with
   `v: 1`, the task id, and those commands verbatim (through a core verb,
   `mech-contract --base-sha <sha>`, which itself refuses unless the
   worktree is clean and HEAD equals the given base), and commits it on
   the task branch as `<task_id>: Add mech contract`. Generation is
   allowed only when the worktree is clean AND either the branch was
   created by this kickoff or the adopted branch's HEAD equals `base_sha`;
   a dirty or already-diverged adopted branch refuses instead (nothing is
   written). This is the only commit the orchestrator ever authors; it
   happens inside the section-2 step 3-6 window so step 9's failure
   cleanup covers it.
3. Else refuse: "mech kickoff needs a committed contract or
   `mech.contract_commands` in config; kick off as raw instead".

**Launch base.** After any generated-contract commit, the task record's
`base_sha` is set to the post-commit HEAD (the launch base), not the
original `origin/<default>` SHA. `base_ref` still names the ref. Every
existing "ahead of base" check (`confirm-completion`, the section-4 git
ancestry check, `emit-done --base-sha`) therefore requires real worker
commits beyond the contract; a contract-only branch can never complete.

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
`timeout_secs 1800`, no `contract_commands`. Validation: `max_turns`
integer 1-500; `max_budget_usd` finite number > 0 and <= 50;
`timeout_secs` integer 60-14400; `contract_commands`, when present,
validates with the contract `commands` rules (1-32, unique names, no
unknown keys). Booleans are not numbers. A malformed `mech` block or an
unknown key refuses mech kickoff (exit 5 from `mech-caps`) rather than
silently reverting to defaults, matching the `models` rule.

New read-only verb `python3 "$CORE" mech-caps --repo-slug <slug>
[--max-turns N] [--max-budget-usd X]` prints the effective caps as one
JSON object `{"max_turns", "max_budget_usd", "timeout_secs"}` (config
merged with overrides, overrides validated against the same bounds) or
exits 5 with a concrete message. The skill never computes caps by hand.

### 4. Launch: headless, wrapped by the core

Mech workers run in print mode because the caps exist only there. The
orchestrator does not launch `claude` directly; it launches a core wrapper
in the workspace's own root pane (same pane rule as section 8):

```
herdr pane run <pane_id> "python3 $CORE run-mech --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent <agent> --launch-id <launch_id> --model $MODEL --worktree <worktree_path> --base-sha <base_sha> --brief-file <brief_path> --max-turns <N> --max-budget-usd <X> --timeout-secs <T>"
```

**Shell-safety contract.** Every interpolated value must match
`[A-Za-z0-9_./+:@-]+` (no whitespace, no shell metacharacters). The
orchestrator checks this before `pane run` and refuses the launch with
the offending value named; `run-mech` re-validates its own args and
exits 2 on a violation. Worktree paths already use the `+` encoding;
`STATE_ROOT` paths are under the config dir.

`launch_id` is minted by the orchestrator as `<agent>-<YYYYMMDDTHHMMSSZ>`
(UTC start time) and is the per-launch provenance key: it appears in the
`workers[]` entry, in both ledger lines, in a wrapper-written completion
record, and in the brief (so a worker-written `emit-done --launch-id`
carries it too). `$MODEL` comes from `resolve-model --role mech` with the
same nonzero-exit rules as every other role. The brief file is written by
the orchestrator to `STATE_ROOT/<slug>/tasks/<task_id>.brief.md`
(machine-local prose, not state JSON; never in the worktree).

`run-mech`, in order:

1. Validate args: repo slug, task id, workspace id, `--agent` equal to
   `agent_name("mech", task_id)` or one of its `-2`..`-9` collision
   variants, `--launch-id` prefixed by the agent name, caps within
   section-3 bounds, `--brief-file` a regular file contained in
   `STATE_ROOT` that is read in full here, `--worktree` an existing
   directory that `git rev-parse --git-dir` accepts, `--base-sha` 40 hex,
   shell-safety on every value. Any failure: exit 2, nothing written.
2. Append the `start` ledger line (section 6). Failure: exit 2.
3. Run `claude --model <M> --permission-mode auto --name <agent> -p
   --output-format json --max-turns <N> --max-budget-usd <X>` with the
   brief on stdin, cwd `--worktree`, environment inherited, in its own
   process group; on `--timeout-secs` expiry kill the group and treat the
   result as `timeout`.
4. Parse the last JSON object on stdout with `type == "result"`. Missing
   or unparseable -> `subtype: "unparseable"`; killed -> `"timeout"`.
   `models_used` = keys of `modelUsage` (empty when absent). `downgrade`
   = true when `models_used` is non-empty and none of its ids contains
   the requested alias as a substring (the alias-to-family rule; the
   fable/opus/sonnet/haiku aliases are each substrings of their family's
   model ids).
5. Determine the completion record. A worker-written
   `tasks/<task_id>.done.json` counts as this launch's when its
   `workspace_id`, `agent` match and either its `launch_id` equals this
   launch or (no `launch_id`) its `ts` >= this launch's start `ts`. Such a
   record is never overwritten, even when the CLI result reports a cap
   hit (the record plus the contract gate govern; the ledger still shows
   the cap). Otherwise the wrapper writes one with the `emit-done` shape,
   `phase: implement`, `launch_id`, `head_sha` = `git rev-parse HEAD` in
   the worktree, `base_sha` from `--base-sha`, `dirty` = whether
   `git status --porcelain` is non-empty, and `reason`:
   - `error_max_turns` -> `paused`, `max_turns`
   - `error_max_budget_usd` -> `paused`, `max_budget`
   - `timeout` -> `paused`, `timeout`
   - `success` with no record -> `paused`, `no_emit`
   - `error_during_execution`, `unparseable`, nonzero exit without a
     result -> `paused`, `error` when the branch is usable (HEAD !=
     `base_sha` and not dirty); else `failed`, `error`.
   If git cannot report HEAD or status in the worktree, no record is
   fabricated (`record_written_by: none`, `git_ok: false` on the `end`
   line). Any such failure, or an unwritable record file: exit 3 after
   still attempting step 6.
6. Append the `end` ledger line. Failure: exit 3.
7. Exit 0 only when steps 2, 5, and 6 all succeeded. The exit code is
   informational for the pane; the orchestrator reads state, not the
   exit code.

`emit-done` gains two optional flags: `--launch-id <id>` and `--reason
<token>`, `reason` in `max_turns|max_budget|timeout|no_emit|error|
needs_design|blocked_on_human|other`. `done.json` may carry `launch_id`,
`reason`, and `dirty` as optional fields; readers ignore unknown fields.

**Within-role fallback.** After `run-mech` returns, the orchestrator reads
the `end` ledger line. Its `model_attributable` flag (computed by the
wrapper: `downgrade: true`, or `subtype: error_during_execution` whose
persisted `errors[]` text mentions the requested model alias or "model")
marks a model-attributable failure: `disable-model --model <requested alias>`,
re-run `resolve-model --role mech`, and relaunch once with a fresh
`launch_id` on the survivor (a new `workers[]` entry; the failed launch's
ledger lines stay for accounting, its completion record is superseded by
the fresh launch's provenance). Cap: 2 attempts per dispatch, then
surface, exactly as section 8. There is no banner read in print mode;
`models_used` is the structural model signal.

The brief is the new mech variant in `brief-template.md`: implement-brief
framing plus "you are a budget-capped mechanical worker: N turns, $X;
do only the mechanical task described; do not brainstorm, spec, or plan;
if the task turns out to need design, commit what is safe, emit `paused
--reason needs_design`". Its close is the implement close (verify-contract,
then `emit-done --phase implement --launch-id <launch_id>`).

State publication follows section 2 step 7 unchanged: the `workers[]`
entry carries `role: "mech"`, `phase: "implement"`, `model`, `launch_id`,
`peer_name: null` (a print-mode session is not subscribable; no
`ListAgents` discovery), `created_by_this_orch`, `started`, and
`caps: {max_turns, max_budget_usd, timeout_secs}`. The reverse index role
stays `impl` (the hook classes a mech Stop as `stopped`, exactly like a
plan worker).

### 5. Liveness, correlation, and relaunch

For `role: mech` workers the section-4 `herdr agent` poll is replaced by
the ledger (the live launch = the latest `workers[]` entry's `launch_id`):

| Ledger state for the live `launch_id` | Action |
| --- | --- |
| no `start` line | launch never began: report; if the task record predates the launch by more than a minute, treat as a failed launch (relaunch is the human's call) |
| `start` without `end`, start age <= `timeout_secs` + 120s | in-progress (or `blocked` on a hook `blocked` hint) |
| `start` without `end`, older than that | wrapper lost: report `paused: wrapper_lost`; status stays `in-progress`; no auto-relaunch |
| `end` present | correlate the completion record (below) |

The existing `abandoned` rule (workspace AND worktree gone, never
completed) is unchanged and still applies to mech tasks.

Correlation on `end`: read `done.json`; it must carry this task id, the
live workspace, the live agent, and the live `launch_id` (or, lacking one,
a `ts` >= the start line). Then by outcome:

- `completed` -> `confirm-completion`, the git-ahead check against the
  (launch) `base_sha`, the phase gate, and the contract gate, unchanged.
- `paused` -> status stays `in-progress` (the existing paused row);
  report "paused: <reason or none>, spent $X over N turns of cap N/$Y"
  with two recommended actions in order: relaunch as mech with raised
  caps, or resume on the `impl` role.
- `failed` -> status `failed` (terminal, existing row). The wrapper only
  writes `failed` when the branch is not usable; a worker-written
  `failed` is taken as-is.

No transition here depends on a Stop hint.

**Mech relaunch** is the existing "record exists + worker gone -> resume"
path: allowed only when the live launch has an `end` line (or is wrapper
lost) and status is `in-progress`/`blocked`. It mints a new `launch_id`,
appends a `workers[]` entry (caps from the new instruction/frontmatter
through `mech-caps`), and launches `run-mech` again in the same workspace
with `base_sha` unchanged. Earlier ledger lines remain and keep counting
toward the task's spend; the earlier completion record is superseded by
provenance. Kickoff idempotency (refuse when a live worker exists) is
unchanged: a `start` without `end` inside the timeout window is "live".

**Orphans.** A `start`/`end` line or completion record whose task has no
primary `tasks/<task_id>.json` (a crash in the launch-to-publish gap) is
listed by `status` under `_orphans: [<task_id>, ...]` for human cleanup;
never auto-adopted, never auto-relaunched.

**Blocked headless worker.** A Notification hook `blocked` hint sets
status `blocked` as today. A print-mode worker cannot be unblocked
interactively; the wall-clock timeout ends it (`paused: timeout`), and
the report recommends relaunching with a brief that pre-answers the
prompt or on the `impl` role.

### 6. Spend ledger and status

`tasks/<task_id>.spend.jsonl` is the per-task spend record: append-only,
written only by `run-mech` (one writer per launch; a task's launches are
sequential because it has one workspace). It is the authoritative spend
source, the way `done.json` is the authoritative completion source; the
task record does NOT duplicate spend (no orchestrator read-modify-write).
`WATCH_DIRS["tasks"]` gains `.spend.jsonl` so every append wakes the
watch.

Two line kinds, both `v: 1`:

```json
{"v":1,"kind":"start","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"mech-td-x-20260901T200000Z","role":"mech","model":"haiku","max_turns":40,"max_budget_usd":2.0,"timeout_secs":1800,"ts":"2026-09-01T20:00:00Z"}
{"v":1,"kind":"end","task_id":"td-x","workspace_id":"w1","agent":"mech-td-x","launch_id":"mech-td-x-20260901T200000Z","subtype":"success","is_error":false,"num_turns":17,"total_cost_usd":0.42,"duration_ms":184000,"models_used":["claude-haiku-4-5-20251001"],"downgrade":false,"errors":[],"model_attributable":false,"record_written_by":"worker","git_ok":true,"exit_code":0,"session_id":"<uuid>","ts":"2026-09-01T20:03:04Z"}
```

Accepted-line rules for the `status` fold: a JSON object with `v == 1`
(int, not bool), `kind` in `start|end`, `task_id` equal to the file's
task id, non-blank `launch_id`; `end` lines additionally need both keys `num_turns`
(a non-negative finite int or null) and `total_cost_usd` (a non-negative
finite number or null) present (booleans rejected). Anything else (truncated line,
wrong task, unknown kind, negative or NaN numbers) is skipped and counted
in `skipped_lines`. Unknown `subtype` values are accepted verbatim.

`status` per task gains:

```json
"spend": {"usd": 0.42, "turns": 17, "launches": 1, "unknown_cost_launches": 0, "skipped_lines": 0}
```

`launches` = count of accepted `start` lines; `usd` = sum of
`total_cost_usd` over accepted `end` lines where it is non-null, rounded
to 4 decimals; `turns` = sum of non-null `num_turns`;
`unknown_cost_launches` = accepted `end` lines with null cost. A task with
no ledger reports all zeros. The top-level object gains `_totals` (same
five fields summed over every task record under `tasks/`, all statuses,
no retention window) plus `untracked_launches` = the count of `workers[]`
entries across all task records whose `role` is not `mech` (interactive
launches with no cost data), and `_orphans` (section 5). `_totals` and
`_orphans` cannot collide with a task id (task ids start alphanumeric).

The section-4 report line includes the per-task `spend` and the status
summary includes `_totals`.

### 7. Review, merge, Jira

Unchanged. A mech `completed` runs the contract gate, dispatches co-review
on the `review` role, and takes the post-rebase merge check. Jira
writeback rules apply by task kind, not by role.

## Acceptance criteria

AC1. `resolve-model --role mech` prints `haiku` when the map has
`haiku: true`, `sonnet` when only sonnet survives, exit 4 when neither,
exit 5 on a malformed `models.mech`; `haiku` inside `models.plan`,
`models.impl`, or `models.review` -> exit 5.
AC2. `write-capabilities` rejects a map missing `haiku` or carrying only
three aliases; `disable-model --model haiku` flips it.
AC3. `mech-caps` prints the documented defaults with no `mech` block,
merges a valid block, applies in-bounds overrides, and exits 5 on each of:
out-of-bounds value, boolean-as-number, unknown key, malformed
`contract_commands`, out-of-bounds override.
AC4. `run-mech` against a fake `claude` on PATH that records its argv,
stdin, and cwd to a file and emits canned JSON: (a) success + fresh
worker-written record -> `start`+`end` lines, record untouched,
`record_written_by: worker`, exit 0; the fake saw exactly the documented
argv (model, permission mode, name, `-p`, output format, both caps), the
brief on stdin, and cwd == worktree; (b) `error_max_turns` and
`error_max_budget_usd` with no record -> `paused` records with reasons
`max_turns`/`max_budget`; (c) `success` without a record -> `paused`/
`no_emit`; (d) `error_during_execution` with HEAD ahead and clean ->
`paused`/`error`, with HEAD == base -> `failed`/`error`, with a dirty
tree -> `failed`/`error`; (e) unparseable stdout -> `subtype:
unparseable`, null cost, `failed` (HEAD == base); (f) a fake that sleeps
past `--timeout-secs` -> `subtype: timeout`, `paused`/`timeout`, and the
fake's process is gone afterwards (its pid no longer exists); (g) a stale
record from a different `launch_id` is replaced, a record with the live
`launch_id` is kept even when the result is a cap hit; (h) `modelUsage`
keyed by a sonnet id under `--model haiku` -> `downgrade: true`; (i) an
unwritable `done.json` target -> exit 3 with the `end` line still
appended.
AC5. `run-mech` exits 2 and writes nothing for: a brief outside
`STATE_ROOT`, a non-canonical agent name (`mech-`, 33+ chars, uppercase),
a `launch_id` not prefixed by the agent, out-of-bounds caps, a non-40-hex
base sha, a non-git worktree, and any arg containing whitespace or a
shell metacharacter.
AC6. `status` over a fixture ledger of: one valid start+end pair
(0.42 usd, 17 turns), one start+end with null cost and 3 turns, one
truncated line, one end line for a different task id, one `end` with a
boolean cost -> `spend: {usd: 0.42, turns: 20, launches: 2,
unknown_cost_launches: 1, skipped_lines: 3}`; a task with no ledger
reports zeros; `_totals` sums two such tasks; `untracked_launches` counts
non-mech `workers[]` entries across records; a ledger with no primary
record appears in `_orphans`.
AC7. `watch_scan` includes `.spend.jsonl` under `tasks/`.
AC8. `emit-done --launch-id --reason` round-trips into `done.json`;
`--reason` outside the token set is rejected; `agent_name("mech", ...)`
obeys the canonical constraints.
AC9. The walkthrough suite drives a mech kickoff end to end with the fake
herdr and fake claude: contract generated from config and committed on a
fresh branch, `base_sha` == post-contract HEAD, pin computed, shell-safety
check applied, `run-mech` invoked through `pane run`, ledger + record
land, `status` reports spend; then a second (relaunch) sequence appends a
second `workers[]` entry and doubles `launches`; then a contract-only
branch (no worker commit) with a `completed` record fails
`confirm-completion`.
AC10. SKILL.md (sections 1, 2, 4, 8, 9), `state-layout.md`,
`brief-template.md`, and `event-schema.md` describe the mech role,
designation forms, ledger, caps, liveness rule, and relaunch; the existing
docs drift checks pass.
AC11 (human-verify, live): a real mech launch through herdr on this repo
reaches `completed` or `paused` at the next check-in without manual
intervention, and the transcript shows whether the Stop hook fired in
print mode (recorded in the plan's close as confirmed or not).
