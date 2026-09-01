# Kickoff brief template

Sent to a freshly-launched worker (`impl-<t>`, or a phase-advanced
successor) after its pane is running and registered as an agent. Fill every
`<...>` placeholder from the task record and preflight state before sending;
never leave a placeholder unfilled. The worker runs in its own shell with no
`$CORE` var defined, so its close commands spell out the full
`python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py` path --
the same config dir (and thus `STATE_ROOT`) the orchestrator used.

```
You are `<agent-name>` working task `<task_id>` in repo `<repo_slug>`.

## Task
<task_id>: <task title/summary, pulled from Jira or the todo record>

<task description / acceptance criteria, pulled from Jira or the todo body>

## Workspace
- Branch: <branch>
- Worktree: <worktree_path>
- Base: <base_ref> @ <base_sha>
- Phase: implement

## Ground rules
- This is your own workspace -- commit as you go, don't leave uncommitted
  work at a stop.
- You may create Herdr panes in this workspace for your own persistent
  side-processes (test-watcher, dev server, log tail) via `pane split`/
  `pane run`. You own their lifecycle: close everything you opened before
  you finish or hand off. Do not use `agent start` -- spawning another
  agent panel is orchestrator territory, not yours. If the task genuinely
  needs an independent long-lived actor, hand back to the orchestrator to
  decompose it into a sibling task.
- Never merge, push directly to the default branch, or open a PR yourself.
- Follow the repo's own CLAUDE.md and skill routing for how the work itself
  gets done (worktree/brainstorm/spec/plan/review pipeline as applicable).

## Close
When you finish, pause, or fail this phase:
1. Commit all work.
2. Run
   `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path>`.
   You may use `--outcome completed` in the next step ONLY if it exits 0, or
   if it exits 5 (no contract pinned -- note "exit 5, no pin" in your close;
   the orchestrator decides whether its grandfather rule applies). On ANY
   other nonzero exit, emit `failed` or `paused` instead -- never
   `completed`.
3. Run:
   `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-done --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase implement --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha>`
4. Then STOP and go idle -- hand back to the orchestrator. Do NOT run
   `/handoff`, do NOT author a resume brief, do NOT plan the next slice, do
   NOT open a PR or merge. Your `emit-done` record is the ONLY completion
   signal; the orchestrator detects it on its next check-in and drives what
   comes next (review dispatch, phase advance, surface-for-merge).

Do not report completion any other way -- the orchestrator only recognizes
this record.
```

## Plan-phase brief variant (`plan-<t>`, raw items only)

Sent instead of the implement brief when kickoff dispatches a `plan` worker for
a raw item (SKILL.md section 2). Same workspace/ground-rules framing; the task
section says to PRODUCE the spec + plan (not implement), and the close emits
phase `plan`:

```
You are `<agent-name>` planning task `<task_id>` in repo `<repo_slug>`.

## Task
<task_id>: <task title/summary, pulled from Jira or the todo record>

<task description / acceptance criteria, pulled from Jira or the todo body>

PRODUCE (do NOT implement yet) the repo's spec + plan for this task, following
its own pipeline: superpowers:brainstorming -> write spec to `docs/specs/` ->
codex-spec-review -> superpowers:writing-plans (plan to `docs/plans/`) ->
codex-plan-review. Author the task's verification contract at
`docs/plans/<task_id>-contract.json` alongside the plan: 1-32 commands, each
`{"name", "run"[, "timeout_secs" 1-3600]}`, that are falsifiable (a broken
implementation must fail at least one), repo-local, deterministic, and
worktree-safe (no STATE_ROOT writes, no machine-state mutation, no network,
no secret echo). Include in the plan a mapping table pairing each acceptance
criterion with its contract command (or an explicit "human-verify" entry).
Validate it --
`python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path> --contract docs/plans/<task_id>-contract.json --allow-unpinned --validate-only`
must exit 0 -- and commit it with the plan (`git add -f`). Fold review findings back into the spec/plan, then commit
the spec + plan. Do NOT write implementation code -- a separate implement
worker picks up from your committed plan next.

## Close
When the spec + plan are committed and reviewed:
1. Commit all work.
2. Run (note `--phase plan`):
   `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-done --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase plan --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha>`
3. Then STOP and go idle -- hand back to the orchestrator. Do NOT run
   `/handoff`, do NOT author a resume brief, do NOT plan or start the
   implement slice, do NOT open a PR or merge. Your `emit-done` record is the
   ONLY completion signal; the orchestrator detects it on its next check-in
   and launches the implement worker.

Do not report completion any other way. The orchestrator advances to the
implement phase only on this `phase: plan` record.
```

## Reviewer brief variant (`rev-<t>`)

Sent instead of the above when dispatching review (section 5 of SKILL.md).
Same workspace/ground-rules framing, with the task section and close
replaced:

```
You are `<agent-name>` reviewing task `<task_id>` in repo `<repo_slug>` at
HEAD `<review_head_sha>`.

## Task
Run `co-review` in REPORT-ONLY mode against this branch: both finders (Claude
`/code-review` + Codex `codex exec review`) plus the adversarial-verify stage,
but do NOT apply fixes -- report only, so you never edit the branch you review
(fixing here would advance HEAD and loop review). You are a fresh agent in the
task's own worktree; that plus co-review's Codex model is the independence.
Classify every finding as blocking or advisory.

## Close
When review is complete:
1. Run (`--blocking-count` is the number of findings you classified as
   blocking; set `--outcome changes-requested` whenever it is non-zero):
   `python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py emit-review --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --reviewed-head-sha <sha> --outcome approved|changes-requested --blocking-count <n> --findings-ref <path to full co-review output>`
2. Then STOP and go idle -- hand back to the orchestrator. Do NOT run
   `/handoff`, do NOT author a resume brief, do NOT plan the next slice, do
   NOT apply fixes, push, merge, or open a PR. Your `emit-review` record is
   the ONLY signal; the orchestrator reads it on its next check-in and drives
   what comes next (re-dispatch on changes-requested, surface-for-merge on
   approved).

Never push, merge, or open a PR.
```
