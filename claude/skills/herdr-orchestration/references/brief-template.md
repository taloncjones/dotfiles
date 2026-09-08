# Kickoff brief template

Sent to a freshly-launched worker (`impl-<t>`, or a phase-advanced
successor) after its pane is running and registered as an agent. Fill every
`<...>` placeholder from the task record and preflight state before sending;
never leave a placeholder unfilled. Resolve the core from the installed skill's
canonical source, not the task checkout or a guessed account hook directory.
The launch adapter appends current attempt context after reserving its launch
ID. Render `<core-command>` as `python3 "<absolute-core-path>"` only.
Render `<core-context>` as `--repo-path "<canonical-repo-root>" --runtime
<claude|codex>`, plus `--personal` only when that account override was selected.
Place this context AFTER the subcommand, as shown below; the CLI does not
accept these options before it. Use the same runtime as the current attempt,
and do not repeat or override it later in the command. Shell-quote each actual
argument individually, including paths and JSON. Choose one value from each
displayed alternative set; never emit a literal `|` or optional brackets.
Do not copy controller fence credentials to helpers.

All new worker emissions include the adapter's exact `--launch-id`, `--runtime`,
`--pane-id`, and `--source-head-sha`, as well as task/workspace. Source HEAD is
captured at launch; final HEAD is read after the worker's commits. These are
not interchangeable. Old or foreign attempts are rejected.

For a read-only Codex reviewer, authorize only its exact findings artifact and
core emission paths through normal approval. It may request that scoped
write; approval rejection means blocked. Do not edit reviewed source or relax
the sandbox to manufacture a completion record.

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

## Routing
Models and efforts were resolved by the native runtime adapter at launch.
Use the supplied model and effort for each authorized helper; a role listed
as unavailable may not be launched. Claude Workflow uses the supplied Claude
model aliases and effort fields; omit `effort` only for an explicit inherit. Codex uses
native child-agent model and reasoning-effort fields, never Claude aliases:
- plan: <model> / <effort|inherit>
- impl: <model> / <effort|inherit>
- review: <model> / <effort|inherit>
- mech: <model> / <effort|inherit>
- think: <model|unavailable> / <effort>
<workflow-opt-in-line>

Render exactly one opt-in line from actual user authorization:
`Workflow opt-in: granted by the user's standing order for this orchestrated task`
or `Workflow opt-in: withheld for this task`. For `no-workflow`, use withheld.
This applies to every variant, including mechanical work. Codex uses supported
native child agents under the user's delegation policy, not Claude Workflow.

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
- Workflow/subagent helpers never call `herdr_orch_core.py`; only you emit
  the completion record.
- Never merge, push directly to the default branch, or open a PR yourself.
- Follow the repo's own AGENTS.md/CLAUDE.md and native skill routing for how the work itself
  gets done (worktree/brainstorm/spec/plan/review pipeline as applicable).

## Close
When you finish, pause, or fail this phase:
1. Commit intended public code/contracts only. Keep private plans and state untracked.
2. Run
   `<core-command> verify-contract <core-context> --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path>`.
   You may use `--outcome completed` in the next step ONLY if it exits 0, or
   if it exits 5 (no contract pinned -- note "exit 5, no pin" in your close;
   the orchestrator decides whether its grandfather rule applies). On ANY
   other nonzero exit, emit `failed` or `paused` instead -- never
   `completed`.
3. Run:
   `<core-command> emit-done <core-context> --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase implement --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha> --launch-id <launch_id> --pane-id <pane_id> --source-head-sha <launch_source_head>`
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
a raw item (SKILL.md section 2). Same workspace/ground-rules framing --
including the `## Routing` block above -- the task section says to PRODUCE the
spec + plan (not implement), and the close emits phase `plan`:

```
You are `<agent-name>` planning task `<task_id>` in repo `<repo_slug>`.

## Task
<task_id>: <task title/summary, pulled from Jira or the todo record>

<task description / acceptance criteria, pulled from Jira or the todo body>

PRODUCE (do NOT implement yet) the repo's spec + plan for this task, following
its own pipeline: superpowers:brainstorming -> write spec to private `docs/superpowers/specs/` ->
independent spec review -> superpowers:writing-plans (plan to private `docs/superpowers/plans/`) ->
independent plan review. In Claude use codex-spec-review/codex-plan-review;
in Codex use claude-spec-review/claude-plan-review. Author the task's verification contract at
`claude/contracts/<task_id>-contract.json` alongside the plan: 1-32 commands, each
`{"name", "run"[, "timeout_secs" 1-3600]}`, that are falsifiable (a broken
implementation must fail at least one), repo-local, deterministic, and
worktree-safe (no STATE_ROOT writes, no machine-state mutation, no network,
no secret echo). Include in the plan a mapping table pairing each acceptance
criterion with its contract command (or an explicit "human-verify" entry).
Validate it --
`<core-command> verify-contract <core-context> --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path> --contract claude/contracts/<task_id>-contract.json --allow-unpinned --validate-only`
must exit 0. Commit only the public contract. Fold review findings back into
the private spec/plan. Freeze each with the co-review artifact helper under
`<account_payload>/artifacts/<task_id>/<launch_id>`, returning one spec and one
plan reference with path and SHA-256. Supply these as `plan_artifacts` in the
plan record; the controller records the same references in the task before
`confirm-plan`. Do NOT write implementation code.

## Close
When the private spec + plan are frozen and reviewed:
1. Commit intended public code/contracts only. Keep private plans and state untracked.
2. Run (note `--phase plan`):
   `<core-command> emit-done <core-context> --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase plan --plan-artifacts <artifact-list-json> --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha> --launch-id <launch_id> --pane-id <pane_id> --source-head-sha <launch_source_head>`
3. Then STOP and go idle -- hand back to the orchestrator. Do NOT run
   `/handoff`, do NOT author a resume brief, do NOT plan or start the
   implement slice, do NOT open a PR or merge. Your `emit-done` record is the
   ONLY completion signal; the orchestrator detects it on its next check-in
   and launches the implement worker.

Do not report completion any other way. The orchestrator advances to the
implement phase only on this `phase: plan` record.
```

## Mech brief variant (`mech-<t>`)

Codex mechanical runs use the runtime adapter's wall timeout. They do not
claim Claude USD/turn caps; unsupported limits block the launch. Retain the
same current-attempt and completion rules.

Legacy Claude `run-mech` variant: written to the `--brief-file` path and piped to `claude -p` as stdin by
`run-mech` itself (SKILL.md section 8, Mech launch) -- never sent via
`agent prompt`, since the worker runs headless. Fill every `<...>`
placeholder the same as the other variants, plus `<launch_id>` (the mech
dispatch's `launch_id`, also passed to `run-mech --launch-id`):

```
You are `<agent-name>` (launch `<launch_id>`) doing mechanical task `<task_id>` in repo `<repo_slug>`.

## Task
<task_id>: <title>

<body>

You are a Claude budget-capped mechanical worker: at most <max_turns> turns and
$<max_budget_usd>. Do only the mechanical task described. Do not brainstorm,
spec, or plan. If the task turns out to need design, commit what is safe and
emit `paused --reason needs_design`. Commit as you go.

## Workspace
- Branch: <branch>
- Worktree: <worktree_path>
- Base: <base_ref> @ <base_sha>   (launch base; your commits must land past it)
- Phase: implement

## Routing
Models and efforts were resolved by the orchestrator from one `routing-table`
snapshot at launch; use these aliases verbatim in any Workflow `agent()` call
(`effort` omitted where it says inherit); a role listed as unavailable may not
appear in a script you author:
- plan: <model> / <effort|inherit>
- impl: <model> / <effort|inherit>
- review: <model> / <effort|inherit>
- mech: <model> / <effort|inherit>
- think: <model|unavailable> / <effort>
<workflow-opt-in-line>

## Close
1. Commit intended public code/contracts only. Keep private plans and state untracked.
2. Run `<core-command> verify-contract <core-context> --repo-slug <repo_slug> --task-id <task_id> --worktree <worktree_path>`;
   `--outcome completed` only on exit 0 (or exit 5, noting "exit 5, no pin").
3. Run `<core-command> emit-done <core-context> --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --phase implement --outcome completed|failed|paused --head-sha <sha> --base-sha <base_sha> --launch-id <launch_id> --pane-id <pane_id> --source-head-sha <launch_source_head> [--reason needs_design|blocked_on_human|other]`
4. Stop. Never push, merge, open a PR, or run /handoff.
```

If the worker never runs `emit-done` (a genuinely stuck/hung headless
process, or a crash) -- or the wrapper's own subprocess call fails or times
out before the CLI can be invoked at all -- `run-mech` writes a guaranteed
completion record itself (`written_by: wrapper`) from the wrapper-observed
result (`reason: no_emit`/`timeout`/`error`/`max_turns`/`max_budget`), so
`done.json` always exists after a mech launch, worker-emitted or not.

## Reviewer brief variant (`rev-<t>`)

Sent instead of the above when dispatching review (section 5 of SKILL.md).
Same workspace/ground-rules framing -- including the `## Routing` block above,
rendered from the fresh native runtime routes resolved for this dispatch --
with the task section and close replaced:

```
You are `<agent-name>` reviewing task `<task_id>` in repo `<repo_slug>` at
HEAD `<review_head_sha>`.

## Task
Run the native `co-review` skill in REPORT-ONLY mode over frozen inputs for
this revision: both Claude and Codex finders, then bounded adversarial verification,
but do NOT apply fixes -- report only, so you never edit the branch you review
(fixing here would advance HEAD and loop review). You are a fresh agent in the
task's own worktree; that plus co-review's Codex model is the independence.
Classify every finding as blocking or advisory.

## Close
When review is complete:
1. Run (`--blocking-count` is the number of findings you classified as
   blocking; set `--outcome changes-requested` whenever it is non-zero):
   `<core-command> emit-review <core-context> --repo-slug <repo_slug> --task-id <task_id> --workspace <workspace_id> --agent <agent-name> --reviewed-head-sha <sha> --outcome approved|changes-requested --blocking-count <n> --findings-ref <path to full co-review output> --launch-id <launch_id> --pane-id <pane_id> --source-head-sha <launch_source_head>`
2. Then STOP and go idle -- hand back to the orchestrator. Do NOT run
   `/handoff`, do NOT author a resume brief, do NOT plan the next slice, do
   NOT apply fixes, push, merge, or open a PR. Your `emit-review` record is
   the ONLY signal; the orchestrator reads it on its next check-in and drives
   what comes next (re-dispatch on changes-requested, surface-for-merge on
   approved).

Never push, merge, or open a PR.
```

## Deep-think brief variant (`<think_id>`)

Written by the orchestrator, not sent via `agent prompt` -- the thinker runs
headless (`run-think`, SKILL.md section 8, Deep-think escalation), so this
is the input contract, not a chat brief. Fill every `<...>` placeholder and
write it to `STATE_ROOT/<slug>/think/<think_id>.question.md` before
launching. Five sections, in order:

```
You are `<think_id>`, a read-only advisor for the orchestrator of repo
`<repo_slug>`. You have Read/Glob/Grep only, at most `<max_turns>` turns
and $`<max_budget_usd>`. You cannot and must not change anything. Your only
output is the structured answer.

## Question
<one decision, phrased as a question>
Kind: <triage|decompose|incident|other>
Task: <task_id or none>

## Context
<inlined excerpts -- task records, todo bodies, transition evidence, the
ranked triage list -- and worktree-relative paths the advisor may read.
Inline what matters; paths are secondary. Never a fence token, socket path,
or credential.>

## Constraints
<what is fixed (existing gates, the human-merge rule, budget) and what is
out of bounds>

## Answer shape
Restate the output fields and ask for two to four options (unordered
alternatives; the `recommendation` field stands on its own and need not
name one of them), rationale grounded in the context, and open questions
only for what the context cannot settle.
```

The thinker's channel back is the structured answer only
(`<think_id>.answer.json`, `references/state-layout.md`); it never writes,
runs, or fetches. An attempt-2 retry (model-attributable failure only)
copies the parent's question byte-for-byte to `<think_id>-2.question.md`
rather than re-authoring it.
