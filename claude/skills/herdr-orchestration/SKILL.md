---
name: herdr-orchestration
description: Use to run a standing per-repo orchestrator over Herdr that turns a designated Jira ticket or repo todo into a briefed worker session in a worktree workspace, tracks it through a hook-fed event log, and dispatches an independent reviewer before handing back for merge. Trigger when the user says "kick off <TASK>", "what's queued", "status", or asks the orchestrator to supervise delegated work. Requires HERDR_ENV=1.
---

# herdr-orchestration

A per-repo orchestrator over Herdr. It turns a designated work item into a
briefed worker in a worktree-backed workspace, tracks the worker through a
hook-fed event log plus worker-emitted completion records, and -- once it
confirms real completion -- dispatches an independent reviewer before handing
back to the human for merge. One standing orchestrator per repo.

This skill is a **thin caller**. All state mutation goes through the tested
core CLI; the skill never hand-writes state JSON.

```
CORE="python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py"
```

Every `$CORE` subcommand that mutates state (`write-task`, `write-index`)
takes the current `--session`/`--fence` from the ownership claim below and
aborts if the fence is stale. `emit-done`/`emit-review` are called by
**workers**, not the orchestrator -- see references/brief-template.md.

Full schemas: `references/state-layout.md`. Event vocabulary and fold rule:
`references/event-schema.md`. Kickoff brief template: `references/brief-template.md`.

## 1. Preflight (every orchestrator action)

1. Assert `HERDR_ENV=1` is set in the environment; if not, stop -- this skill
   only runs inside a Herdr-managed session.
2. Compute `repo_slug` from `git remote get-url origin` (see
   references/state-layout.md for the normalization rule); ensure
   `STATE_ROOT/<repo_slug>/` exists.
3. Claim/refresh ownership:
   - `$CORE claim-owner --repo-slug <slug> --session <id> --host <host> --pid <pid>`
     -> prints a `fence` token on success, or `BUSY` (exit 1) if another
     session holds a live claim. On `BUSY`, yield to read-only status/triage
     and offer the user an explicit takeover; do not mutate state.
   - On every subsequent turn this session acts in the repo, call
     `$CORE refresh-owner --repo-slug <slug> --session <id> --fence <fence>`
     to keep the heartbeat alive.
   - Fencing otherwise happens implicitly inside `write-task`/`write-index`
     (each aborts under a stale fence); before a multi-call sequence like
     kickoff, the orchestrator may proactively call
     `$CORE check-fence --repo-slug <slug> --session <id> --fence <fence>`
     to fail fast rather than partway through.
4. Load and validate `config.json` (schema in references/state-layout.md).
   Missing or invalid config refuses mutating actions with a concrete
   message; triage/status still work read-only where possible.

## 2. Kickoff (human designates) -- idempotent, ownership-tracked

Kickoff always starts an `impl-<...>` implement worker: the item already has
a plan, and any planning it still needs happens inside that worker under the
repo's own pipeline. The steps below call it "the worker".

1. Resolve the item (Jira MCP for a ticket key, the todos skill for a bare
   todo) -> `task_id`. Abort if unresolved.
2. **Idempotency:** `$CORE status --repo-slug <slug>` plus a check of
   `tasks/<task_id>.json`. Existing record + live worker -> refuse, report,
   offer to focus the existing workspace. Existing record + worker gone ->
   offer resume or cleanup. No record -> proceed.
3. Resolve `base_ref` (`config.default_base`, else `origin/<default>`),
   `git fetch`, record the resulting `base_sha`. If offline, warn and require
   explicit confirmation before proceeding on a stale base.
4. **Adopt vs create, with ownership tracking:** if the branch/worktree
   already exists, verify it belongs to this task (branch name matches
   `<user>/<task_id>/<slug>`) before adopting, and mark it
   `created_by_this_orch: false`. Otherwise create it and mark `true`. This
   flag gates cleanup on failure (step 9).
5. `herdr worktree create` (or `worktree open` if adopting); parse the
   `.result` for the new `HERDR_WORKSPACE_ID` and worktree path -- never
   derive them. Label the workspace `<task_id>`.
6. **Launch the worker on its pinned model** via the argv-safe pane-split
   path -- see section 8, Model launch. Send the kickoff brief (template in
   references/brief-template.md), filled with `task_id`, worktree path,
   branch, and phase (`implement`).
7. **Publish state only after the worker is launched** -- so a failed launch
   leaves no stale task/index to unwind (no rollback verb needed). Write
   through the core CLI, not by hand:
   - `$CORE write-task --repo-slug <slug> --session <id> --fence <fence> --task-id <task_id> --json '<task record, status "in-progress">'`
   - `$CORE write-index --repo-slug <slug> --session <id> --fence <fence> --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "impl"}'`
     The task record's `status` field is the authoritative kickoff record;
     `events.jsonl` is hook-owned (worker lifecycle hints only, see
     references/event-schema.md) -- the orchestrator does not write to it.
8. **Jira writeback** (kind == `"jira"` only): transition the ticket to In
   Progress -- see section 10.
9. **Partial-failure/crash:** on any failure during steps 3-6, clean up only
   resources this attempt created (`created_by_this_orch: true`); never
   delete adopted/pre-existing resources. A launch that fails at step 6 has
   published no task/index, so nothing needs unwinding there; a crash in the
   narrow launch-to-publish gap leaves a running worker with no record, which
   the next status/triage poll surfaces via live `herdr agent list` for
   cleanup -- preferred over a stale record that would block re-kickoff.

## 3. Triage (advisory only -- read-only)

Creates no task/worktree/agent/index/record.

1. Inputs: Jira active sprint (JQL) plus repo epic(s) from `config.epics`,
   plus open todos. Exclude anything already an active task.
2. Deterministic ranking: in-sprint (Jira priority, then key ascending) ->
   epic backlog order (the epic's child order) -> todos (by todo id). Ties
   break by `task_id`.
3. Missing data: no sprint -> fall back to epic backlog; Jira unreachable ->
   todos only, and say so.
4. Report the ranked list. If the eligible count exceeds `config.soft_cap`,
   note it -- advisory only, never a hard cap.

## 4. Status (check-in; turn-driven) -- full live-state reconciliation

`$CORE status --repo-slug <slug>` folds the per-workspace event logs into
per-task status. Reconcile that against a live `herdr agent list` /
`herdr workspace list` poll for each task's current worker:

| Live worker state                 | Action                                                                                                                                     |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| `working`                         | report in-progress                                                                                                                         |
| `blocked`                         | status `blocked`; recommend focusing the workspace                                                                                         |
| `idle`/`done`                     | run the completion correlation (below); set `completed`/`paused`/`failed` accordingly -- **never** report success from `idle`/`done` alone |
| `unknown`                         | report unknown; do not advance status                                                                                                      |
| absent (agent+worktree both gone) | `abandoned`, if never completed                                                                                                            |

**Completion is orchestrator-confirmed, never inferred from `done`.**
Correlate these independent facts, all keyed to the same `task_id`/
`workspace_id`:

1. Resolve live HEAD in the task's worktree: `git rev-parse HEAD`.
2. Live git ancestry: that HEAD is ahead of the task record's `base_sha`
   (the orchestrator checks this itself -- it is not part of `$CORE`).
3. `$CORE confirm-completion --repo-slug <slug> --task-id <task_id> --head-sha <sha>`
   (exit 0/1) -- correlates `tasks/<task_id>.done.json` (`outcome: completed`,
   matching `head_sha`/`base_sha`) against the task record and the live HEAD
   passed in. Never re-derive this correlation by hand.
4. Live `herdr agent` state consistent with a finished worker.

An unmatched, stale, or missing `done.json`, a HEAD that disagrees, or a
`confirm-completion` exit 1, is never completion.

**Stale review verdicts self-heal here (single rule).** A review state
(`review-dispatched`, `reviewed`, or `changes-requested`) is honored only
while its recorded `review_head_sha` equals current HEAD. If HEAD has advanced
past it -- the branch moved during or after review, at any moment including
just before a merge -- the verdict is stale: reset the task to `completed`
(or `in-progress` if the new HEAD is not a confirmed-complete revision) AND
clear `review_head_sha` to `null`. Clearing the marker is what lets
`should-dispatch-review` re-fire for the new HEAD (it compares
`review_head_sha` against live HEAD, so a leftover value equal to HEAD would
wrongly suppress the re-dispatch). This one rule recovers every "branch
advanced" case from whichever review state the task was in, so no review state
is ever permanently stranded -- the next check-in corrects it.

Re-dispatch always goes through section 5's dispatch preflight, which stops any
reviewer still running on the task before starting a new one -- so a stale
reset never leaves two reviewers racing the unfenced
`tasks/<task_id>.done.json`. Known limitation (single-user-unreachable): two
reviewer workers alive at once on one task would still race that write
(last-writer-wins); the preflight removes the only extra writer this loop
creates, and the merge gate's three-SHA correlation (section 6) is the
backstop. Revisit only if review ever runs multi-worker.

Report per-task status, workspace, latest note, and recommended next action.

## 5. Review dispatch (on confirmed `completed`) -- per revision, at most one

Guard: `$CORE status` reports `completed` and
`$CORE should-dispatch-review --repo-slug <slug> --task-id <task_id> --head-sha <sha>`
exits 0 (`<sha>` is live HEAD via `git rev-parse HEAD`) -- it compares the
recorded `review_head_sha` against the HEAD passed in; a stale/matching HEAD
exits 1. Rely on this verb, never re-derive the guard by hand.

**Dispatch preflight (no concurrent reviewers).** Before starting a reviewer,
reconcile live `herdr agent`/workspace state for this task and stop/close any
reviewer already running on it -- there must be exactly zero live reviewers
before you start one. This covers both a re-dispatch after the section-4
stale-verdict reset and an orphan reviewer left running by a crash in the
launch-to-publish gap (step 3), where the task can still read `completed`.
Because `emit-review` is unfenced (last-writer-wins on
`tasks/<task_id>.done.json`), a single live reviewer is the invariant that
keeps the recorded verdict trustworthy.

1. Verify: branch exists, HEAD is ahead of base, worktree is clean. Capture
   the HEAD SHA as the intended `review_head_sha`.
2. `herdr worktree open` a fresh workspace on the branch, label
   `review:<task_id>`. `$CORE write-index ... --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "review"}'`.
   Do not resume the implementer while review is pending.
3. Start a unique `rev-<...>` agent on the reviewer model (section 8,
   argv-safe launch). **Only after the agent successfully starts**, commit
   the dispatch: `$CORE write-task ... --json '<record with review_head_sha, status "review-dispatched">'`.
   This task-record `status` transition is the authoritative dispatch
   record -- `events.jsonl` is hook-owned (worker lifecycle hints only) and
   the orchestrator does not write to it. On start failure, clean up the
   review workspace/index and leave the task at `completed` (retryable) --
   never leave a half-dispatched state.
4. **Jira writeback** (kind == `"jira"` only): on successful dispatch,
   transition the ticket to In Review -- see section 10.
5. Prompt the reviewer to run report-only `/code-review` (no `--fix`, no
   `--comment`) against the branch -- NOT `/co-review`, which fixes findings
   by default and would edit the very branch under review, destroying review
   independence -- then
   `$CORE emit-review --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent rev-<...> --reviewed-head-sha <sha> --outcome approved|changes-requested --findings-ref <path>`,
   then `/handoff`. Reviewer and orchestrator never push or open PRs.
6. At the next check-in, read the reviewer's completion record. First confirm
   it covers the dispatched revision: the reviewer's `reviewed_head_sha` must
   equal both the dispatched `review_head_sha` and current HEAD. If any
   disagree (the branch advanced, or the reviewer logged the wrong SHA), the
   verdict is stale -- do **not** record it; apply the section-4 stale-verdict
   rule (reset to `completed`/`in-progress` and clear `review_head_sha`) so a
   fresh review dispatches. Only when all three SHAs agree:
   - blocking findings -> `status: changes-requested`, event
     `changes-requested`, surface the findings; a subsequent implementer
     push to a new HEAD clears the dispatch guard so a fresh review runs
     against the new `review_head_sha`.
   - none blocking -> `status: reviewed`, event `reviewed`.

## 6. Surface for merge (human gate) -- only on `reviewed`

A task is surfaced as merge-ready only when `status: reviewed` AND
`$CORE confirm-review --repo-slug <slug> --task-id <task_id> --head-sha <sha>`
exits 0 (`<sha>` is live HEAD via `git rev-parse HEAD`). That verb ties three
SHAs together -- the task record's dispatched `review_head_sha`, the review
`done.json`'s `reviewed_head_sha`, and live HEAD must all equal `<sha>` (with
`phase == "review"` and `outcome == "approved"`) -- so a branch advance after
dispatch never clears the gate against an unreviewed revision, even if the
reviewer logged the new live SHA rather than the one it actually reviewed.
Rely on the verb, never re-derive the check by hand.

Surface: "`<task_id>` reviewed clean @ `<sha>`. Ready for your review and
merge." `changes-requested` is never surfaced as merge-ready. Merge, `/ship`,
`/post-merge` remain human actions; `/post-merge` sets `merged`.

## 7. Worker-created panes (self-managed)

A task worker does not weigh subagent-vs-panel every time. The standing
rule:

- **Default:** use subagents for in-turn helper work (reading, searching,
  analysis, bounded parallel slices). No decision needed.
- **Allowed without asking, if self-managed:** a worker MAY create Herdr
  **panes** in its own workspace for persistent side-_processes_ it needs
  during the task -- e.g. a test-watcher, a dev/sim server, a log tail, a
  scratch shell (`pane split`/`pane run`, not `agent start`). Condition: it
  owns their lifecycle. It created them, so it closes them; it must not
  orphan any pane past its own completion/handoff -- "no panes I created
  left running" is on the completion checklist.
- **Not the worker's job:** spawning a persistent **agent** panel (another
  Claude/Codex session) for sub-work -- that is orchestrator territory (own
  index entry, ownership, review independence). If a task genuinely needs an
  independent long-lived actor, it hands back for the orchestrator to
  decompose into a sibling task workspace, rather than growing a
  sub-orchestrator.

Rule of thumb: subagents for helpers, self-managed panes for your own
processes, agent panels for the orchestrator only.

## 8. Model routing

Each role has an ordered model preference, resolved against the models the
current account/CLI actually offers. First available wins; `config.json`
may override any role's list.

| Role / phase              | Preference (first available wins) | Effort  | Notes                                                                                               |
| ------------------------- | --------------------------------- | ------- | --------------------------------------------------------------------------------------------------- |
| Orchestrator              | fable -> opus                     | low/med | routine coordination; model set at session launch (advisory, not enforceable via `agent start`)     |
| Implementation worker     | sonnet -> opus                    | default | cheap execution                                                                                     |
| Reviewer (`/code-review`) | opus -> sonnet                    | high    | report-only `/code-review` (no `--fix`); Opus reviewer gives model diversity vs a Fable/Sonnet impl |

Fallback scaffolding: when Fable is unavailable (enterprise account, usage
exhausted, or the current session is already Opus), fall back to Opus and
set `thinking: adaptive`, relying on the design's explicit worker fan-out
plus the codex spec/plan/co-review gates as the compensation for Opus
standing in for Fable. This is a fully supported operating mode, not a
degraded one.

Fable operating notes: configure an Opus fallback on `stop_reason: refusal`
for every Fable role (safety classifiers can trip on benign work); never
prompt Fable to transcribe its own reasoning (status/triage and design docs
are work product / external state, which is safe).

**Model launch (argv-safe, single path).** ALWAYS build the slot explicitly:

1. `herdr pane split --cwd <worktree> --no-focus` -> read `.result.pane.pane_id`.
2. `herdr pane run <pane_id> "claude --model <model> <flags>"` -- `<model>`
   comes from the config allowlist; keep the command a plain `claude`
   invocation with no shell metacharacters.
3. Register the pane as a tracked agent -- resolve the exact flags against
   live `herdr pane report-agent --help` (it needs `--source`, `--agent`,
   `--state`, and the `<pane_id>`); values are workflow-specific. Note:
   `herdr pane run "claude ..."` may let herdr natively detect the claude
   agent from the pane process, making an explicit `report-agent` call
   unnecessary -- confirm which applies at first use rather than treating
   `report-agent` as an unconditional step.

Do **not** use `herdr agent start`'s trailing `-- <argv>` passthrough to pin
a model -- it is unreliable across herdr versions (0.7.5+ made `--kind` a
closed whitelist; herdr-swarm and herdr-conductor both avoid it). The
pane-split path above is the single launch mechanism for every role.

Confirm the launched model via `herdr agent read` (or equivalent) on the
worker's first turn, and **fail visibly** rather than let the wrong model
run silently.

## 9. State transition table (authoritative)

The "Event" column below names the conceptual transition, not an emitted
`events.jsonl` record -- `events.jsonl` carries only hook hints
(`stopped`/`blocked`/`review-stopped`, see references/event-schema.md). Each
row's transition is committed solely by a `$CORE write-task` call that sets
the new `status`; that write is the authoritative record.

| From                                         | Evidence / trigger                                                             | Event                                          | To                    | Terminal? |
| -------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------- | --------------------- | --------- |
| (none)                                       | human kickoff, resources created                                               | `kickoff`                                      | in-progress           | no        |
| in-progress                                  | hook `blocked` + live `blocked`                                                | `blocked`                                      | blocked               | no        |
| blocked                                      | live no longer blocked                                                         | (recheck)                                      | in-progress           | no        |
| in-progress/blocked                          | correlated `done.json` completed + git ahead                                   | `completed`                                    | completed             | no        |
| in-progress/blocked                          | Stop hint + no done.json + no commits                                          | `paused`                                       | in-progress           | no        |
| in-progress/blocked                          | Stop hint + `outcome: failed` or errored, no usable branch                     | `failed`                                       | failed                | yes       |
| in-progress/blocked/completed                | workspace+worktree gone, no completion                                         | `abandoned`                                    | abandoned             | yes       |
| completed                                    | human/orch dispatch (guard: not already dispatched for this `review_head_sha`) | `review-dispatched`                            | review-dispatched     | no        |
| review-dispatched                            | reviewer done (reviewed HEAD == dispatched == live), findings = blocking       | `changes-requested`                            | changes-requested     | no        |
| review-dispatched                            | reviewer done (reviewed HEAD == dispatched == live), findings = none blocking  | `reviewed`                                     | reviewed              | no        |
| review-dispatched/reviewed/changes-requested | recorded `review_head_sha` != live HEAD (branch advanced any time)             | (stale: clear `review_head_sha`, re-correlate) | completed/in-progress | no        |
| changes-requested                            | implementer pushes new HEAD (new `head_sha`)                                   | (re-kickoff impl or resume)                    | in-progress           | no        |
| reviewed                                     | human merges; `/post-merge`                                                    | `merged`                                       | merged                | yes       |

`blocked` is a durable status here (the hint `blocked` drives it); there is
no overlap between `failed` (errored, no usable branch) and `abandoned`
(workspace disappeared without completion) -- the evidence columns are
disjoint.

## 10. Jira status writeback (Jira-kind tasks only)

The orchestrator keeps the ticket's Jira status in step with its own task
state, so `reconcile` has drift to fix at the source rather than after the
fact. It writes the status at two points it already owns, plus the existing
tail:

- **Kickoff** (`kind == "jira"`) -> transition the ticket to **In Progress**.
  Work actually starts here (worktree + worker spun up).
- **Review dispatch** -> transition to **In Review**. "In Review" means the
  moment the fresh reviewer worker is dispatched on the branch -- the
  orchestrator's own hook point -- NOT the human posting a PR (the
  orchestrator never posts PRs; if PR-posting is ever the desired trigger
  instead, that transition moves to the `ship`/PR flow, out of this loop).
- **Merge** -> **Done**, already handled by `/post-merge`.

Rules (these are outward-facing writes, so treat them carefully):

- **Jira-kind only.** Bare repo todos (`td-...`) have no Jira status --
  skip.
- **Resolve the transition dynamically.** Names/IDs like "In Progress"/"In
  Review" are workflow-specific; use `getTransitionsForJiraIssue` and pick
  the offered transition, never a hard-coded id. If the target status is
  not reachable from the current one, no-op gracefully and note it -- do
  not force or error.
- **Idempotent.** If the ticket is already in the target status, do
  nothing.
- **Announced.** Surface each transition -- it is an outward mutation of the
  user's own assigned ticket, routine to automate at kickoff/review, but
  visible.
- A failed/absent transition never blocks the local task-state advance; the
  internal record moves regardless, and `reconcile` remains the backstop.

## Safety

- The orchestrator never merges, pushes, or opens a PR. Merge/`/ship`/
  `/post-merge` remain explicit human actions.
- All state is machine-local under `STATE_ROOT` (`references/state-layout.md`);
  nothing under it is ever git-tracked, and no marker is written into any
  worktree.
- Do not run `herdr integration install` (personal or work account) -- it
  mutates `settings.json` outside the template and writes through symlinks
  that `reconcile_claude_settings_file` will wipe on the next `update`.
