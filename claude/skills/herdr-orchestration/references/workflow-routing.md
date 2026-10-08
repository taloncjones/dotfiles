# Worker panes and Workflow-tool routing (SKILL.md sections 7 and 8)

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
  Claude/Codex session) for sub-work -- that is director territory (own
  index entry, ownership, review independence). If a task genuinely needs an
  independent long-lived actor, it hands back for the director to
  decompose into a sibling task workspace, rather than growing a
  sub-director.

Rule of thumb: subagents for helpers, Workflow for in-turn fan-out,
self-managed panes for your own processes, agent panels for the
director only. See section 8's "Workflow-tool routing" subsection for
when a `Workflow` fan-out is the right substrate instead of a single
subagent.

## Workflow-tool routing (section 8)

**Workflow-tool routing.** The Claude Code `Workflow` tool runs scripted
multi-agent fan-outs. Substrate decision table:

| Need                                                                                                                                                        | Substrate        | Why                                                                               |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------------------------- |
| Work that must own a branch, worktree, task record, review, and merge gate                                                                                  | Pane worker      | The task lifecycle; only substrate with identity, provenance, completion records  |
| Human-designated mechanical task under caps with a spend ledger                                                                                             | `run-mech`       | Lifecycle plus headless caps and ledger                                           |
| One bounded judgment call for the director (Deep-think triggers)                                                                                            | `run-think`      | Read-only, structured answer, director-only                                       |
| In-turn fan-out inside one session: parallel reading, analysis, judging, review-then-verify, or bounded parallel mechanical slices of the caller's OWN task | `Workflow`       | Deterministic control flow over many subagents, results consumed in the same turn |
| A single helper read/search/analysis                                                                                                                        | `Agent` subagent | No orchestration needed                                                           |

A Workflow run is **in-turn helper work** (section 7's rule of thumb, at
scale). It has no workspace, no index entry, no record; it never
substitutes for a herdr phase or role -- the review gate always stays a
fresh `rev-<t>` agent running review-change, and the director never
dispatches a Workflow _instead of_ a worker. A Workflow launched by the
director is read-only (analysis, triage support, decomposition
drafting): the director authors no code and its Workflow agents write
nothing.

**Precedence with the user's standing order.** The global CLAUDE.md
(Default Skill Routing) says to orchestrate multi-task implementation with
the Workflow tool directly (planner/reviewer on the stronger model, workers
on cheaper models, per-task review). That order governs how a session
implements a multi-task PLAN; this skill governs the herdr task LIFECYCLE.
They compose: an `implement` worker executing its reviewed private plan may fan
the plan's tasks out over a Workflow (mutations under `isolation:
'worktree'`, results merged into its own branch by the worker), and that is
the standing order in action inside one herdr task. What the Workflow never
does is stand in for the herdr worker itself: no branch, record, contract
gate, or review of its own. Where the two documents seem to disagree, this
precedence rule wins.

Models and efforts inside a script are resolved BEFORE it is authored through
the native runtime policy, not the legacy wrapper table. Map planner/judge/
synthesizer to `planner`, reviewer/verifier to `reviewer`, implementer to
`implementation`, mechanical helpers to `mechanical`, and a deep judge to
`think`. Resolve each needed role for the selected runtime and retain its
readiness, model and effort in the brief's `## Routing` block. Claude Workflow
uses the supplied Claude aliases and effort fields; Codex native children use
Codex model and reasoning-effort fields. Do not run legacy `resolve-model`
or build a legacy capability map for native workers. An absent or unready role
is unavailable to the worker. The size guideline
(under 15 agents by default) holds unless the human raised it in the
instruction that opted in.

The Workflow tool runs only on explicit user opt-in. The grant this skill
relies on is the user's standing order in their global CLAUDE.md (Default
Skill Routing), reaffirmed for orchestrated dispatch: the director may
author Workflows while handling an orchestrated task, and a briefed worker
may author them inside its task, both within the default size guideline.
The brief carries the exact line `Workflow opt-in: granted by the user's
standing order (global CLAUDE.md, Default Skill Routing) for this
orchestrated task; default size guideline` (references/brief-template.md),
so a worker can trace the grant to the human's words rather than to the
director. A human may narrow it per task (`kick off <item> no-workflow`
-> the brief line reads `Workflow opt-in: withheld for this task`) or widen
the size in the kickoff instruction. Outside an orchestrated task (freeform
triage or status turns) the director uses Workflow only when the
current human instruction asks for that scale in its own words.

A Workflow returns to the session that launched it and stops there.
Completion is still commits + contract + `emit-done`; a Workflow agent
never runs a `$CORE` mutating verb, `emit-done`, or `emit-review` -- the
brief's ground rules say so in one line ("Workflow/subagent helpers never
call `herdr_orch_core.py`; only you emit the completion record"). Workflow
spend is untracked (interactive-class), and its transcripts live under the
calling session, not `STATE_ROOT`.
