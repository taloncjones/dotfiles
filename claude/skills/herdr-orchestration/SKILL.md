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
# zsh does NOT word-split an unquoted variable, so a bare `python3 "$CORE" claim-owner`
# runs a command literally named "python3 .../herdr_orch_core.py" and fails.
# Store only the PATH and always call it as: python3 "$CORE" <subcommand> ...
CORE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py"
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
   - `python3 "$CORE" claim-owner --repo-slug <slug> --session <id> --host <host> --pid <pid>`
     -> prints a `fence` token on success, or `BUSY` (exit 1) if another
     session holds a live claim. On `BUSY`, yield to read-only status/triage
     and offer the user an explicit takeover; do not mutate state.
   - **On the initial claim only** (not on refresh), label THIS session's own
     workspace so the Herdr UI shows the standing orchestrator, not a bare
     name: `herdr workspace rename "$HERDR_WORKSPACE_ID" "orch:<repo>"`
     (`<repo>` = short repo name, e.g. `orch:dotfiles`). Idempotent -- skip if
     the workspace label already equals it (`herdr workspace get
"$HERDR_WORKSPACE_ID"` -> `.result.workspace.label`). This is display-only
     Herdr state, never repo/worktree state; a worker's own workspace is
     labelled `<task_id>` at `worktree create` (section 2), so no worker is
     ever left as a generic "Worker N".
   - On every subsequent turn this session acts in the repo, call
     `python3 "$CORE" refresh-owner --repo-slug <slug> --session <id> --fence <fence>`
     to keep the heartbeat alive.
   - Fencing otherwise happens implicitly inside `write-task`/`write-index`
     (each aborts under a stale fence); before a multi-call sequence like
     kickoff, the orchestrator may proactively call
     `python3 "$CORE" check-fence --repo-slug <slug> --session <id> --fence <fence>`
     to fail fast rather than partway through.
4. Load and validate `config.json` (schema in references/state-layout.md).
   Missing or invalid config refuses mutating actions with a concrete
   message; triage/status still work read-only where possible.
5. **Strong-model availability (startup discovery, after config validation).**
   Model selection for every worker launch is deterministic (`resolve-model`,
   section 8), driven by a session-stamped `capabilities.json`. Refresh it only
   when stale: if `resolve-model` exits 3 (map absent, or its `session_id` !=
   this session -- i.e. a restart or `/clear`) for a role this turn, re-probe
   the strong model headlessly and record the result:
   - `PROBE_JSON="$(claude --model fable -p 'Reply with the single word: ok' --output-format json </dev/null)"`
   - `CLS="$(python3 "$CORE" classify-probe --repo-slug <slug> --model fable --json "$PROBE_JSON")"`
   - `available`/`unavailable` -> write the map (opus/sonnet default true):
     `python3 "$CORE" write-capabilities --repo-slug <slug> --session <id> --fence <fence> --json '{"v":1,"session_id":"<id>","available":{"fable":<true|false>,"opus":true,"sonnet":true}}'`
   - `indeterminate` (no `claude`, network error, other status, unparseable) ->
     write NO map; ABORT launches this turn and surface it -- never assume.
     A non-owner (claim returned `BUSY`) never probes or writes -- it is
     read-only. The map is machine-local (`references/state-layout.md`), never
     committed.

## 2. Kickoff (human designates) -- idempotent, ownership-tracked

Kickoff dispatches a worker whose **phase and model depend on plan-maturity**,
so brainstorm/spec/plan judgment is never delegated to the cheap impl model:

- **Plan-ready item** -- a refined Jira ticket, or a task that already has a
  committed `docs/specs/` spec and `docs/plans/` plan: dispatch an `implement`
  worker directly, on the model `resolve-model --role impl` returns (default
  `sonnet -> opus`; section 8).
- **Raw item** -- a bare todo/handoff with no spec/plan: dispatch a `plan`
  worker on the model `resolve-model --role plan` returns (the **strong**
  planning model, default `fable -> opus`; section 8) first. It runs the
  repo's brainstorm -> spec -> codex-spec-review -> plan -> codex-plan-review
  pipeline, commits the spec + plan, and emits completion as phase `plan`. On
  confirmed plan completion the orchestrator advances the same task/branch to
  its `implement` phase (impl-role model, section 2a).

Maturity check: a Jira ticket in a refined/ready state, or an existing committed
spec+plan for the task, is plan-ready; anything else is raw. When unsure, treat
it as raw -- an extra plan phase is cheap insurance against a cheap model making
design decisions.

The steps below call the dispatched worker "the worker"; they apply to whichever
phase is launched (`plan` for a raw item, else `implement`), with the
phase-appropriate brief (references/brief-template.md) and model.

1. Resolve the item (Jira MCP for a ticket key, the todos skill for a bare
   todo) -> `task_id`. Abort if unresolved.
2. **Idempotency:** `python3 "$CORE" status --repo-slug <slug>` plus a check of
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
5. **`herdr worktree create --cwd <repo_root>`** (or `worktree open --cwd
<repo_root>` if adopting) -- the explicit `--cwd` is MANDATORY, never a bare
   path. Resolve `<repo_root>` first as the intended repo's top level:
   `REPO_ROOT="$(git -C <path-in-repo> rev-parse --show-toplevel)"`.
   **Why (submodule-adjacency mis-anchor):** when the target path sits inside or
   beside a git submodule, a bare `worktree create` can anchor the new worktree
   to the SUBMODULE instead of the intended repo -- incident 2026-08-28, rw-bess:
   a `BESS-2334` create defaulted to the `rw-test-infrastructure` submodule
   (`repo_root: .../rw-test-infrastructure`) because several active workspaces
   lived there, risking a ticket's work built in the wrong repo. Explicit
   `--cwd <repo_root>` pins the anchor.
   Parse the `.result` for the new `HERDR_WORKSPACE_ID` and worktree path --
   never derive them. **Then verify the anchor before doing anything else:** read
   `.result...repo_root` / `.result...repo_name` and confirm they equal the
   intended `<repo_root>` (and its basename). On a mismatch the create
   mis-anchored -- do NOT launch a worker; **unwind** the stray resources
   (remove the empty worktree: `herdr worktree remove --workspace <ws_id>`, and
   delete the stray branch: `git -C <mis-anchored repo_root> branch -D <branch>`),
   then surface the mismatch and stop. Only a verified-correct anchor proceeds.
   Label the workspace `<task_id>`.
6. **Launch the worker on its pinned model** into the new workspace's own pane
   -- see section 8, Model launch. Send the kickoff brief (template in
   references/brief-template.md), filled with `task_id`, worktree path,
   branch, and phase (`plan` for a raw item, else `implement`).
7. **Publish state only after the worker is launched** -- so a failed launch
   leaves no stale task/index to unwind (no rollback verb needed). Write
   through the core CLI, not by hand:
   - `python3 "$CORE" write-task --repo-slug <slug> --session <id> --fence <fence> --task-id <task_id> --json '<task record, status "in-progress">'`
   - `python3 "$CORE" write-index --repo-slug <slug> --session <id> --fence <fence> --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "impl"}'`
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

## 2a. Phase advancement (plan -> implement) -- raw items only

A `plan` worker's confirmed completion advances the SAME task to its implement
phase; it never marks the task `completed` and never dispatches review.

1. **Plan completion is not task completion.** When a `done.json` correlates
   (via `confirm-completion`, section 4) AND its `phase` is `plan`, that is a
   plan milestone. Never set status `completed` off a `phase: plan` record --
   task completion and review dispatch (sections 4-5) fire ONLY on a
   `phase: implement` record. The orchestrator knows which phase is live from
   the task record's latest `workers[]` entry; the `done.json.phase` must match
   it.
2. **Verify the plan landed:** spec + plan committed on the branch (HEAD ahead
   of `base_sha`), worktree clean.
3. **Advance in place.** Reuse the same worktree/branch (the committed spec+plan
   live there). After the plan worker hands off (idle/exited), launch an
   `implement` worker in that workspace's own pane on the model
   `resolve-model --role impl` returns (section 8 launch; impl default
   `sonnet -> opus`) with the implement brief. Append a new `workers[]` entry
   (`role: impl`, `phase: implement`, `model` = that resolved alias,
   `created_by_this_orch: true`) via `write-task`; status stays `in-progress`.
   The plan worker's
   `done.json` is later overwritten by the implement worker's -- expected; only
   the implement record drives completion.
4. A plan phase that emits `outcome: failed`/`paused` is handled exactly like an
   implement-phase failure/pause (section 9) -- no implement worker is launched.

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

`python3 "$CORE" status --repo-slug <slug>` folds the per-workspace event logs into
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
3. `python3 "$CORE" confirm-completion --repo-slug <slug> --task-id <task_id> --workspace <impl_ws> --head-sha <sha>`
   (exit 0/1) -- correlates `tasks/<task_id>.done.json` (`outcome: completed`,
   matching `head_sha`/`base_sha`, and `workspace_id` == the dispatched impl
   workspace) against the task record and the live HEAD passed in. The
   `--workspace` provenance check rejects a record from a foreign or older
   worker. Never re-derive this correlation by hand.
4. Live `herdr agent` state consistent with a finished worker.
5. **Phase gate:** the correlated `done.json`'s `phase` is `implement` (the
   final phase). A `phase: plan` record is a plan milestone -- run section 2a
   phase advancement, never `completed`/review. `confirm-completion` does not
   itself check phase; the orchestrator gates on it here, matching the live
   worker's `workers[]` phase.

An unmatched, stale, or missing `done.json`, a HEAD that disagrees, or a
`confirm-completion` exit 1, is never completion.

**Stale review verdicts self-heal here (single rule).** A review state
(`review-dispatched`, `reviewed`, or `changes-requested`) is honored only
while its recorded `review_head_sha` equals current HEAD. If HEAD has advanced
past it -- the branch moved during or after review, at any moment including
just before a merge -- the verdict is stale. Recover it in three steps:
(a) if a review agent for this task is still running, **stop it** (exit/kill the
`rev-<...>` agent -- `herdr pane release-agent`, or `/exit` to its pane; do
**not** `herdr workspace close`, which would tear down the shared task worktree),
since the review is now moot -- do this on every stale reset, whether it lands on
`completed` or `in-progress`, because a reset to `in-progress` will not
re-dispatch and so cannot rely on section 5's dispatch preflight to stop it;
(b) reset the task to `completed` (or `in-progress` if the new HEAD is not a
confirmed-complete revision); (c) clear `review_head_sha` to `null`. Clearing
the marker is what lets `should-dispatch-review` re-fire for the new HEAD (it
compares `review_head_sha` against live HEAD, so a leftover value equal to HEAD
would wrongly suppress the re-dispatch). This recovers every "branch advanced"
case from whichever review state the task was in, so no review state is ever
permanently stranded -- the next check-in corrects it.

Because review runs in the task's own workspace (section 5), stopping the review
agent leaves the workspace and its `role: review` index entry intact for the
re-dispatch -- nothing is orphaned. Known limitation (single-user-unreachable):
two review agents alive at once in one workspace would race the unfenced
`tasks/<task_id>.review.json` write (last-writer-wins); stopping the prior agent
on every reset, plus section 5's dispatch preflight, removes the only extra
writer this loop creates, and the merge gate's provenance + three-SHA
correlation (section 6) is the backstop.

Report per-task status, workspace, latest note, and recommended next action.

## 5. Review dispatch (on confirmed `completed`) -- per revision, at most one

The review runs **in the task's own worktree**, not a separate workspace. git
allows only one worktree per branch, so a second workspace on the branch is
impossible (`herdr worktree open` just re-attaches to the impl workspace); and
`co-review` already spins up independent Claude (`/code-review`) and Codex
(`codex exec review`) contexts, so a separate reviewer workspace would duplicate
what co-review provides. Independence comes from a **fresh review agent** (clean
context, distinct from the impl session) plus co-review's Codex model, run
**report-only** so the gate never edits its own subject.

Guard: `python3 "$CORE" status` reports `completed` and
`python3 "$CORE" should-dispatch-review --repo-slug <slug> --task-id <task_id> --head-sha <sha>`
exits 0 (`<sha>` is live HEAD via `git rev-parse HEAD`) -- it compares the
recorded `review_head_sha` against the HEAD passed in; a stale/matching HEAD
exits 1. Rely on this verb, never re-derive the guard by hand.

**Reviewer-dispatch preflight (one review agent at a time).** Reconcile live
`herdr agent` state for this task's workspace and stop any `rev-<...>` agent
already running in it (exit/kill the agent -- do **not** `herdr workspace close`,
which would tear down the shared task worktree). There must be zero live review
agents before you start one. Because `emit-review` is unfenced (last-writer-wins
on `tasks/<task_id>.review.json`), a single live review agent is the invariant
that keeps the recorded verdict trustworthy.

1. Verify: branch exists, HEAD is ahead of base, worktree is clean. Capture the
   HEAD SHA as the intended `review_head_sha`.
2. **Reuse the task's own worktree/workspace** (`<ws_id>`, the impl phase's).
   The impl agent has handed off; free its root pane (send it `/exit`, or launch
   in a fresh self-owned `pane split`) and start the review agent there -- no
   `worktree open`, no new workspace. Do not resume the implementer while review
   is pending. (Should a `worktree open` ever be needed here despite the above,
   it carries the same MANDATORY explicit `--cwd <repo_root>` and post-open
   repo-anchor verification as section 2 step 5 -- the submodule-adjacency guard
   applies to every `worktree create`/`open`, no exceptions.)
3. Start a unique `rev-<...>` agent on the reviewer model (section 8 launch) in
   the task workspace. **Only after the agent successfully starts**, publish
   state under the fence, both writes together:
   `python3 "$CORE" write-index ... --workspace <ws_id> --json '{"task_id": "<task_id>", "repo_slug": "<slug>", "role": "review"}'`
   (this overwrites the same workspace's `role: impl` entry -- expected; the impl
   `done.json` completion was already confirmed, and the role now reflects the
   live phase so the monitoring hook classes a review Stop as `review-stopped`)
   and
   `python3 "$CORE" write-task ... --json '<record with review_head_sha, status "review-dispatched">'`.
   The task-record `status` transition is the authoritative dispatch record. On
   start failure, nothing was published: leave the task at `completed`
   (retryable).
4. **Jira writeback** (kind == `"jira"` only): on successful dispatch,
   transition the ticket to In Review -- see section 10.
5. Prompt the review agent to run **`co-review` in report-only mode** against the
   branch -- both finders (Claude `/code-review` + Codex `codex exec review`)
   plus the adversarial-verify stage, but **no fix application**: report only, so
   the gate never edits the branch it reviews and cannot trigger a fix ->
   re-review loop. (`co-review` stays herdr-agnostic -- the herdr-specific
   `emit-review` call lives in this brief, not in the skill; if invoked outside a
   Herdr session the review agent just runs co-review and reports.) Then
   `python3 "$CORE" emit-review --repo-slug <slug> --task-id <task_id> --workspace <ws_id> --agent rev-<...> --reviewed-head-sha <sha> --outcome approved|changes-requested --blocking-count <n> --findings-ref <path>`
   (`<n>` = count of blocking findings; the merge gate rejects any non-zero
   count even under `approved`), then the review agent goes idle and hands
   back -- it does NOT run `/handoff`; `emit-review` is its only signal. Review
   agent and orchestrator never push or open PRs. The verdict lands in
   `tasks/<task_id>.review.json`, separate from the impl `.done.json`.
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
`python3 "$CORE" confirm-review --repo-slug <slug> --task-id <task_id> --workspace <review_ws> --head-sha <sha>`
exits 0 (`<sha>` is live HEAD via `git rev-parse HEAD`). That verb reads
`tasks/<task_id>.review.json` and passes only when ALL hold: `outcome ==
"approved"`; `blocking_count` is 0; the record's `workspace_id` equals the
dispatched review workspace (provenance); and the task record's dispatched
`review_head_sha`, the review record's `reviewed_head_sha`, and live HEAD all
equal `<sha>`. So an approved-with-blocking verdict, a foreign worker's record,
or a branch advance after dispatch (even one where the reviewer logged the new
live SHA) never clears the gate. Rely on the verb, never re-derive the check by
hand.

**Vibe-audit gate for grown resolutions.** co-review (section 5) gates the diff
for BUGS; it does not check whether the change stayed honest to its plan. When a
task reached `reviewed` only after a review-resolution cycle whose fixes grew
beyond trivial -- new scope, new files/functions, chat-directed changes, not a
one-line fix -- run `vibe-audit` on the resolution before surfacing merge-ready:
those commits skipped brainstorm/spec/plan, which is exactly vibe-audit's domain
(verified beliefs + test coverage, not bug-finding, so it complements rather than
repeats co-review). A failing vibe-audit blocks the surface (the task stays
`reviewed` but not merge-ready) and its findings feed a fix pass (a new HEAD ->
fresh co-review); a clean vibe-audit, or a resolution trivial enough never to
trigger it, clears the gate. Planned work that never grew past its plan needs no
vibe-audit -- its front-pipeline gates already ran. `vibe-audit` is
herdr-agnostic; the orchestrator just invokes it here as the last gate.

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
current account actually offers -- deterministically, via
`python3 "$CORE" resolve-model --role <plan|impl|review>` (canonical defaults in
the core; `config.json` `models` may override any role's list under the same
`plan`/`impl`/`review` keys). First available wins. Availability comes from the
session-stamped `capabilities.json` the section-1 probe writes; the orchestrator
never picks a worker model by judgment. The `Orchestrator` row below is
advisory only -- its model is fixed when this session launched and is NOT
resolved by `resolve-model` (the resolver has no `orchestrator` role).

| Role / phase             | Preference (first available wins) | Effort  | Notes                                                                                                                                                 |
| ------------------------ | --------------------------------- | ------- | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| Orchestrator             | fable -> opus                     | low/med | routine coordination; model set at session launch (advisory, not enforceable via `agent start`)                                                       |
| Planning worker (`plan`) | fable -> opus                     | high    | raw items only: brainstorm/spec/plan on the strong model so design judgment is never delegated to the cheap impl worker; skipped for plan-ready items |
| Implementation worker    | sonnet -> opus                    | default | cheap execution of an existing plan                                                                                                                   |
| Reviewer (co-review)     | opus -> sonnet                    | high    | co-review report-only (Claude `/code-review` + Codex) in the task worktree, fresh agent; Opus Claude-half adds model diversity vs a Sonnet impl       |

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

**Model launch** (validated live against herdr 0.8.2). Launch into the new
workspace's OWN pane -- `worktree create`/`worktree open` returns it at
`.result.root_pane.pane_id`, already in the new workspace with the worktree as
its cwd (the result also carries `.result.workspace.workspace_id` and
`.result.tab`). Do **not** `herdr pane split`: a split defaults to the CURRENT
(orchestrator's) workspace, so the worker would inherit the wrong
`HERDR_WORKSPACE_ID` and its hook events would never match the published index.

Launch the worker -- always pinning its model -- in that root pane:

1. `<pane_id>` = `.result.root_pane.pane_id` from the create/open result.
2. **Resolve the role's model deterministically -- never pick it by judgment,
   never use `--fallback-model`:**
   `MODEL="$(python3 "$CORE" resolve-model --repo-slug <slug> --role <plan|impl|review> --session <id>)"`
   Treat a nonzero exit as a hard stop, not a default: exit 3 -> re-probe
   (section 1 step 5) then retry; exit 4 -> surface "no available model for
   <role>" and halt; exit 5 -> surface the config/role error and halt. Never
   launch on empty output. Then
   `herdr pane run <pane_id> "claude --model $MODEL --permission-mode auto"`.
   Use `--permission-mode auto`, **not** `--dangerously-skip-permissions`: an
   auto-mode orchestrator's classifier BLOCKS spawning a skip-permissions
   worker. Keep it a plain `claude` invocation with no shell metacharacters.
   **Never** `claude --model fable --fallback-model opus`: `--fallback-model`
   fires only on overload, not on an account restriction, and silently lands on
   the account default (Sonnet) -- the rw-bess incident, 2026-08-28. The
   persisted `workers[]` `model` field records this resolved `$MODEL`, never a
   hard-coded constant.
3. Registration is normally automatic -- `pane run "claude ..."` lets herdr
   natively detect the agent (it appears in `herdr agent list` within a second
   or two). If it does not, `herdr pane report-agent <pane_id>` registers it --
   this verb takes **no** `--kind` flag (`--kind` belongs to `agent start`).

Do **not** use `herdr agent start` to launch the worker: its `-- <argv>`
passthrough for pinning a model is unreliable across herdr versions (0.7.5+
made `--kind` a closed whitelist), and unlike `pane run` in the worktree's root
pane it does not create or target the correct pane.

Submit the brief and confirm the worker started working in one call:
`herdr agent prompt <pane_id> "<brief>" --wait --until working --timeout 60000`
(`working` is a valid `--until` status; `--timeout` guards the 5s
`agent_prompt_stalled` and indefinite-wait edges).

**Verify-after-launch (D4 self-heal, best-effort backstop -- fails safe).** The
PRIMARY availability guarantee is the section-1 headless probe (`claude -p
--output-format json` -> reliable structured JSON). This D4 backstop only tries
to catch an interactive pane that silently DOWNGRADED after a clean probe; when
it cannot read the running model it does NOT guess -- it fails closed (abort +
surface), so a weak read never advances a launch on inference.

Read the running model as early as possible, before the banner scrolls off:
immediately after `pane run "claude ..."`, and no later than right after
`agent prompt --until working`, via `herdr agent read` / `herdr pane read`,
capturing the `Claude Code v...` banner line that names the model. Retry the
read within a short bounded window (a few reads over a few seconds); the banner
is transient, so a single late read is unreliable -- that unreliability is the
incident this section fixes (2026-08-28, BESS-2334: the banner had scrolled off,
the model line was unreadable, and the launch wrongly PROCEEDED ON INFERENCE).
herdr 0.8.2 exposes NO structural model field on `agent list` / `agent get`
(verified 2026-08-28: the agent record carries `agent` / `agent_status` / `cwd`
/ `pane_id` / `terminal_title` and no model), so the banner is the only source;
if a future herdr adds a launched-model field to `agent get` / `agent list`,
prefer that structured field over scraping the banner.

Classify the read:

- **DOWNGRADE** (running model != requested `$MODEL`) or a model-attributable
  launch failure -> mark the REQUESTED alias unavailable (never the observed
  one, never re-enable another) with an atomic downward-only flip:
  `python3 "$CORE" disable-model --repo-slug <slug> --session <id> --fence <fence> --model <requested-alias>`.
  Confirm the wrong worker is terminated, then re-run `resolve-model` and
  relaunch on the next survivor. Cap relaunch attempts per dispatch at 2, then
  surface failure -- do not loop.
- **INFRASTRUCTURE-INDETERMINATE** (pane didn't start, herdr error, or the model
  banner is not readable within the bounded window -- no model signal) -> do NOT
  disable any model and NEVER infer the model ("the probe fell back to Sonnet, so
  it's probably Sonnet" is exactly the forbidden inference); abort and surface.
  This is not availability data.

Downward-only within a session; upward recovery waits for the next startup
re-probe (section 1 step 5). Headless `-p` (the probe) errors on an unavailable
model, but an interactive pane launch can silently DOWNGRADE to Sonnet -- which
is exactly what this backstop catches when the banner is readable, and fails
closed (abort) when it is not.

## 9. State transition table (authoritative)

The "Event" column below names the conceptual transition, not an emitted
`events.jsonl` record -- `events.jsonl` carries only hook hints
(`stopped`/`blocked`/`review-stopped`, see references/event-schema.md). Each
row's transition is committed solely by a `python3 "$CORE" write-task` call that sets
the new `status`; that write is the authoritative record.

| From                                         | Evidence / trigger                                                             | Event                                          | To                      | Terminal? |
| -------------------------------------------- | ------------------------------------------------------------------------------ | ---------------------------------------------- | ----------------------- | --------- |
| (none)                                       | kickoff (raw item -> plan phase; plan-ready -> implement)                      | `kickoff`                                      | in-progress             | no        |
| in-progress                                  | hook `blocked` + live `blocked`                                                | `blocked`                                      | blocked                 | no        |
| blocked                                      | live no longer blocked                                                         | (recheck)                                      | in-progress             | no        |
| in-progress (plan phase)                     | correlated `done.json` `phase: plan` completed + git ahead                     | `phase-advance` (launch implement, section 2a) | in-progress (implement) | no        |
| in-progress/blocked (implement)              | correlated `done.json` `phase: implement` completed + git ahead                | `completed`                                    | completed               | no        |
| in-progress/blocked                          | Stop hint + no done.json + no commits                                          | `paused`                                       | in-progress             | no        |
| in-progress/blocked                          | Stop hint + `outcome: failed` or errored, no usable branch                     | `failed`                                       | failed                  | yes       |
| in-progress/blocked/completed                | workspace+worktree gone, no completion                                         | `abandoned`                                    | abandoned               | yes       |
| completed                                    | human/orch dispatch (guard: not already dispatched for this `review_head_sha`) | `review-dispatched`                            | review-dispatched       | no        |
| review-dispatched                            | reviewer done (reviewed HEAD == dispatched == live), findings = blocking       | `changes-requested`                            | changes-requested       | no        |
| review-dispatched                            | reviewer done (reviewed HEAD == dispatched == live), findings = none blocking  | `reviewed`                                     | reviewed                | no        |
| review-dispatched/reviewed/changes-requested | recorded `review_head_sha` != live HEAD (branch advanced any time)             | (stale: clear `review_head_sha`, re-correlate) | completed/in-progress   | no        |
| changes-requested                            | implementer pushes new HEAD (new `head_sha`)                                   | (re-kickoff impl or resume)                    | in-progress             | no        |
| reviewed                                     | human merges; `/post-merge`                                                    | `merged`                                       | merged                  | yes       |

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
