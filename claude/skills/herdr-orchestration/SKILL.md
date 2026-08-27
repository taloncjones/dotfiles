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
4. Load and validate `config.json` (schema in references/state-layout.md).
   Missing or invalid config refuses mutating actions with a concrete
   message; triage/status still work read-only where possible.

## 2. Kickoff (human designates) -- idempotent, ownership-tracked

**Initial phase** is explicit: default `implement` (the common case -- the
item already has a plan) starts an `impl-<...>` worker; `--phase plan`
instead starts a `plan-<...>` worker as the first phase. The steps below
read "impl" as "the initial-phase worker".

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
   flag gates cleanup on failure (step 8).
5. `herdr worktree create` (or `worktree open` if adopting); parse the
   `.result` for the new `HERDR_WORKSPACE_ID` and worktree path -- never
   derive them. Label the workspace `<task_id>`.
6. Write state through the core CLI, not by hand:
   - `$CORE write-task --repo-slug <slug> --session <id> --fence <fence> --task-id <task_id> --json '<task record, status "kickoff">'`
   - `$CORE write-index --repo-slug <slug> --session <id> --fence <fence> --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "impl"}'`
7. **Launch the worker on its pinned model** via the argv-safe pane-split
   path -- see section 8, Model launch. Send the kickoff brief (template in
   references/brief-template.md), filled with `task_id`, worktree path,
   branch, and phase.
8. Append the `kickoff` event and set `status: in-progress` (via a follow-up
   `write-task` call under the same fence). **Jira writeback** (kind ==
   `"jira"` only): transition the ticket to In Progress -- see section 10.
9. **Partial-failure/crash:** on any failure during steps 3-7, clean up only
   resources this attempt created (`created_by_this_orch: true`); never
   delete adopted/pre-existing resources.

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
Correlate three independent facts, all keyed to the same `task_id`/
`workspace_id`:

1. A `tasks/<task_id>.done.json` with `outcome: completed` whose `head_sha`
   and `base_sha` match the task record.
2. Live git: the branch's HEAD equals that `head_sha` and is ahead of
   `base_sha`.
3. Live `herdr agent` state consistent with a finished worker.

An unmatched, stale, or missing `done.json`, or a HEAD that disagrees, is
never completion.

Report per-task status, workspace, latest note, and recommended next action.

## 5. Review dispatch (on confirmed `completed`) -- per revision, at most one

Guard: `$CORE status` reports `completed` and no review has been dispatched
for the current HEAD (the `should_dispatch_review` check inside `$CORE`
compares the recorded `review_head_sha` against live HEAD -- rely on it,
never re-derive the guard by hand).

1. Verify: branch exists, HEAD is ahead of base, worktree is clean. Capture
   the HEAD SHA as the intended `review_head_sha`.
2. `herdr worktree open` a fresh workspace on the branch, label
   `review:<task_id>`. `$CORE write-index ... --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "review"}'`.
   Do not resume the implementer while review is pending.
3. Start a unique `rev-<...>` agent on the reviewer model (section 8,
   argv-safe launch). **Only after the agent successfully starts**, commit
   the dispatch: `$CORE write-task ... --json '<record with review_head_sha, status "review-dispatched">'`
   and append the `review-dispatched` event. On start failure, clean up the
   review workspace/index and leave the task at `completed` (retryable) --
   never leave a half-dispatched state.
4. **Jira writeback** (kind == `"jira"` only): on successful dispatch,
   transition the ticket to In Review -- see section 10.
5. Prompt the reviewer to run `/co-review` against the branch, then
   `$CORE emit-review --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent rev-<...> --reviewed-head-sha <sha> --outcome approved|changes-requested --findings-ref <path>`,
   then `/handoff`. Reviewer and orchestrator never push or open PRs.
6. At the next check-in, read the reviewer's completion record:
   - blocking findings -> `status: changes-requested`, event
     `changes-requested`, surface the findings; a subsequent implementer
     push to a new HEAD clears the dispatch guard so a fresh review runs
     against the new `review_head_sha`.
   - none blocking -> `status: reviewed`, event `reviewed`.

## 6. Surface for merge (human gate) -- only on `reviewed`

Only a task at `status: reviewed` with `review_head_sha` == current HEAD is
surfaced as merge-ready: "`<task_id>` reviewed clean @ `<sha>`. Ready for
your review and merge." `changes-requested` is never surfaced as
merge-ready. Merge, `/ship`, `/post-merge` remain human actions; `/post-merge`
sets `merged`.

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

| Role / phase            | Preference (first available wins) | Effort     | Notes                                                                                             |
| ----------------------- | --------------------------------- | ---------- | ------------------------------------------------------------------------------------------------- |
| Orchestrator            | fable -> opus                     | low/med    | routine coordination; model set at session launch (advisory, not enforceable via `agent start`)   |
| Planner / architect     | fable -> opus                     | high/xhigh | hardest design reasoning                                                                          |
| Implementation worker   | sonnet -> opus                    | default    | cheap execution                                                                                   |
| Reviewer (`/co-review`) | opus -> sonnet                    | high       | deliberate cross-model diversity vs a Fable planner/impl; `/co-review` adds Codex as a third view |

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
3. `herdr pane report-agent <pane_id> --name <agent-name> ...` to register
   the pane as a tracked agent.

Do **not** use `herdr agent start`'s trailing `-- <argv>` passthrough to pin
a model -- it is unreliable across herdr versions (0.7.5+ made `--kind` a
closed whitelist; herdr-swarm and herdr-conductor both avoid it). The
pane-split path above is the single launch mechanism for every role.

Confirm the launched model via `herdr agent read` (or equivalent) on the
worker's first turn, and **fail visibly** rather than let the wrong model
run silently.

## 9. State transition table (authoritative)

| From                          | Evidence / trigger                                                             | Event                       | To                | Terminal? |
| ----------------------------- | ------------------------------------------------------------------------------ | --------------------------- | ----------------- | --------- |
| (none)                        | human kickoff, resources created                                               | `kickoff`                   | in-progress       | no        |
| in-progress                   | hook `blocked` + live `blocked`                                                | `blocked`                   | blocked           | no        |
| blocked                       | live no longer blocked                                                         | (recheck)                   | in-progress       | no        |
| in-progress/blocked           | correlated `done.json` completed + git ahead                                   | `completed`                 | completed         | no        |
| in-progress/blocked           | Stop hint + no done.json + no commits                                          | `paused`                    | in-progress       | no        |
| in-progress/blocked           | Stop hint + `outcome: failed` or errored, no usable branch                     | `failed`                    | failed            | yes       |
| in-progress/blocked/completed | workspace+worktree gone, no completion                                         | `abandoned`                 | abandoned         | yes       |
| completed                     | human/orch dispatch (guard: not already dispatched for this `review_head_sha`) | `review-dispatched`         | review-dispatched | no        |
| review-dispatched             | reviewer done, findings = blocking                                             | `changes-requested`         | changes-requested | no        |
| review-dispatched             | reviewer done, findings = none blocking                                        | `reviewed`                  | reviewed          | no        |
| changes-requested             | implementer pushes new HEAD (new `head_sha`)                                   | (re-kickoff impl or resume) | in-progress       | no        |
| reviewed                      | human merges; `/post-merge`                                                    | `merged`                    | merged            | yes       |

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
