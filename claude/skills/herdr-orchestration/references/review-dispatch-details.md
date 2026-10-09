# Review dispatch details (SKILL.md section 5)

## Known stray stops (section 5)

Known stray stops: `co-review` and other helper sessions the reviewer spawns
inherit `HERDR_ENV` and `HERDR_WORKSPACE_ID` and appear with auto-derived
agent names. Headless children started through the shared bounded runner
carry `HERDR_BOUNDED_CHILD=1` and no pane identity; the stop gate allows
them before reading any state. Helpers in their own panes are released by
pane (`HERDR_PANE_ID` missing or different from the dispatched `pane_id`,
or, when a newer native row of another role follows the index role's row,
from that newest row's pane) and get no `emit-review` instruction. A
helper started interactively inside the reviewer's own pane keeps that
pane's identity, stays gated, and could emit: the reviewer must not spawn
one there. `run_headless`-launched one-shot workers (legacy mech, think)
are a separate case: they keep the inherited pane identity and are never
indexed by the stop gate regardless -- a legacy mech worker's own
`emit-done` call needs that inherited identity to be accepted as the
designated agent. Never read a helper's idle state as review completion,
and never accept a verdict from a pane other than the dispatched one (the
record's `emitter_pane_id` is the audit field; `emit-review` itself exits 3
for a foreign or missing pane).
A headless `--permission-mode plan` child is not write enforcement: it still
runs allowlisted Bash (for example `python3`) when a hook or prompt tells it
to, so only the bounded-child marker and the pane-bound emit guard keep a
helper from publishing.

## A worktree open during review (section 5 step 2)

(Should a `worktree open` ever be needed here despite the above,
it carries the same MANDATORY explicit `--cwd <repo_root>` and post-open
repo-anchor verification as section 2 step 5 -- the submodule-adjacency guard
applies to every `worktree create`/`open`, no exceptions.)

## Sized review deadline (section 5 step 3)

The active coordinator reads the review's `sized review deadline` from
`review-deadlines`: `deadline_secs` is the floor (900 s) plus the pinned
contract's summed `timeout_secs` plus 20 s per changed file, capped at the
ceiling (3600 s), and is the ceiling whenever an input cannot be read;
`hard_secs` adds a 600 s grace. Both are measured from this native row's
`started_ns`, keyed by `launch_id`, and recomputed on every call, so a
coordinator restart needs no extra state field. `config.json`
`review.deadline_floor_secs` / `review.deadline_ceiling_secs` override
the floor and ceiling.

## Review brief and emit-review rules (section 5 step 5)

current diff, intended behavior, and affected callers. It reports blockers,
advisories, and coverage gaps after safe reproductions where useful. It may
consult relevant reference skills as permitted by `review-change`; it
never applies fixes, launches another reviewer, posts externally, or runs
final co-review. `review-change` is herdr-agnostic; the herdr-specific
`emit-review` call lives in this brief. Render the brief (section 2 step 7)
with `--phase review`; the focus file names the intended behavior and what
to check.

`<findings_path>` is
`<account_payload>/herdr-orch/<slug>/artifacts/<task_id>/review-<launch_id>/findings.md`
(the same `<slug>` directory that holds `tasks/<task_id>.json`; a
review-specific launch directory that never collides with the plan-artifact
helper's); the rendered brief carries it. The reviewer creates the directory,
writes its report to a temporary name in that directory and renames it onto
`findings.md` (so a partial write is never the named file), and passes
exactly that path as `--findings-ref`. Content: blocking findings,
advisories, coverage gaps, reproduction evidence, or an explicit "no
findings" statement naming what was inspected. The report opens with a
three-line header (`Verdict: approved|changes-requested`, `Blocking: <n>`,
`Advisories: none` or titles joined by `; `); inside herdr an unbound
`emit-review` refuses a report whose header is missing or disagrees with
`--outcome` and `--blocking-count`. `emit-review` refuses a
`--findings-ref` that is not an absolute path under the orchestration state
root to a readable, non-blank regular file, refuses to emit without one
inside herdr, and pins the file's SHA-256 as `findings_sha256`. A findings
file inside the task worktree is refused by the verb. Then
`python3 "$CORE" emit-review --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent rev-<...> --reviewed-head-sha <sha> --outcome approved|changes-requested --blocking-count <n> --findings-ref <path> --launch-id <launch_id> --runtime <runtime> --pane-id <pane_id> --source-head-sha <launch_source_head>`
(`<n>` = count of actual blocking findings; incomplete or missing review
evidence emits `changes-requested` with `<n>` possibly zero and never emits
`approved`), then the review agent goes idle and hands back --
it does NOT run `/handoff`; `emit-review` is its only signal.
In the review phase the review agent and director never push or open PRs.
The verdict lands in
`tasks/<task_id>.review.json`, separate from the impl `.done.json`.

## Review deadline bound (section 5 step 6)

before reading a verdict. Resolve the latest `phase: review` native row and
require its task, workspace, launch, agent, pane, source HEAD, and
`review_head_sha` to match the dispatched attempt. Read its line from
`review-deadlines` (the check-in also prints `review-overdue` for it).
Before any interrupt, re-read `tasks/<task_id>.review.json`: an exact
accepted review record for this attempt means read that verdict below and
do not interrupt.

- `running`: nothing to do.
- `overdue` with the recorded agent `working`: tell the user the review is
  past its sized deadline and re-arm the timer; do not interrupt.
- `overdue` with the recorded agent idle or absent, or `expired`: interrupt
  only that agent: `herdr agent send-keys <recorded-agent> esc`, then
  `herdr agent prompt <recorded-agent> /exit --wait --timeout 10000`. Wait
  at most 10 seconds for that named agent; if it remains live, re-check the
  tuple and run `herdr pane close <recorded-pane>`. Never use
  `release-agent` as an interrupt and never close the workspace. Herd's
  interactive start timeout bounds startup, not a running agent turn;
  exact-pane close is the controller's available interruption. Confirm the
  agent settled (the recorded agent and pane are gone). If you cannot,
  report the detached-process risk, leave the task `review-dispatched`,
  and do not relaunch, reset, or surface readiness until reconciliation;
  the next check-in repeats `review-overdue`. Once settled, re-read the
  review record (a verdict that landed during the interrupt wins: an
  exact record for the stopped row is read as its verdict below and the
  row is not retired). Only with no exact record, use `$CORE write-task`
  to carry the full task record forward with `status: changes-requested`
  and the stopped row's `launch_id` appended to
  `retired_review_launch_ids` (a retired launch's verdict never
  correlates, whatever lands later), report `review incomplete: sized
review deadline, <launch_id>`, and never fabricate a review record,
  blocker count, or approval. A late sidecar cannot change that
  non-approved status.
- After that write, ask with `AskUserQuestion`:
  "Re-dispatch the review at <sha> (Recommended)" applies the
  stale-verdict reset (`status: completed`, `review_head_sha: null`) with
  `write-task` and continues with this section's dispatch; "Leave for
  repair" changes nothing. The answer is not stored: ask again whenever
  you report on a task that is `changes-requested` at an unchanged HEAD
  with no correlating record for its latest review row, until the human
  picks re-dispatch or the HEAD moves.
