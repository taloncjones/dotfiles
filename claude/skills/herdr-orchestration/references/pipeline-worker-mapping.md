# Pipeline worker mapping

Policy a director follows when dispatching a superpowers pipeline. The
model and effort columns are not read from this file: `claude/hooks/agent_runtime.py`
is authoritative for every model and effort named here, and the `policy document
matches the route table` case in `agent-runtime.test.sh` parses this file and
fails if it drifts. The step-to-role column IS bound in code -- by
`agent_runtime.PIPELINE_ROUTES`, resolved via `route --step` (see
`references/dispatch-mechanism.md`) -- so a pipeline dispatch derives its role
from the step rather than hand-picking one.

This describes the **native** path -- `agent_runtime.resolve_route` plus
`herdr_dispatch.launch`. It does **not** describe the legacy
`herdr_orch_core.py` path that `run-mech` and `run-think` use today, which runs
its own `ROLE_DEFAULTS` off `capabilities.json`, never calls `resolve_route`, and
serves `opus/high` where the native path now falls back to fable. Reconciling the two
is tracked separately.

## Step to worker

| Step                      | Role                 | Model / effort   | Runtime | Gate                                                       |
| ------------------------- | -------------------- | ---------------- | ------- | ---------------------------------------------------------- |
| isolated worktree         | dispatch harness     | --               | --      | auto                                                       |
| brainstorming             | planner              | opus/high        | Claude  | HUMAN                                                      |
| write spec                | planner              | opus/high        | Claude  | auto                                                       |
| codex-spec-review         | codex reviewer       | gpt-6-astra/high | Codex   | Codex, auto-resolve                                        |
| writing-plans             | planner              | opus/high        | Claude  | auto                                                       |
| plan-review               | plan_reviewer        | fable/medium     | Claude  | read-only sandbox, single pass                             |
| codex-plan-review         | codex plan_reviewer  | gpt-6-astra/high | Codex   | Codex, auto-resolve                                        |
| implement                 | implementation       | sonnet/medium    | Claude  | auto + per-task review                                     |
| implement, UX/UI override | codex implementation | gpt-6-astra/high | Codex   | fresh Claude review before commit                          |
| implementation review     | development_reviewer | sonnet/high      | Claude  | task-local advisory review; blockers return to development |
| voice pass (outward text) | codex voice          | gpt-6-astra/high | Codex   | auto, before the write                                     |
| co-review, Claude half    | reviewer             | opus/high        | Claude  | verify each finding                                        |
| co-review, skeptic        | skeptic              | opus/high        | Claude  | verify each finding                                        |
| co-review, Codex half     | codex reviewer       | gpt-6-astra/high | Codex   | verify each finding                                        |
| merge                     | gateway              | --               | --      | HUMAN                                                      |

The planner runs `opus/high` and falls back to fable at whichever quality-tier
floor applies -- `fable/medium` normally, `fable/high` under `difficulty=hard`.
fable/medium is opus/high's tier peer (fable needs one less effort step for
the same design quality), not a same-effort swap, so a fable fallback is never
actually weaker than the opus seat it replaces. One planning worker spans
brainstorm, spec and plan -- not three dispatches.

Plan review is the one review step that does not share the `reviewer` role.
`plan_reviewer` is `fable/medium` with an `opus/high` fallback (the two are
tier peers): fable's judgment is bought as a single bounded read-only pass
over a finished plan instead of as the seat that authors it. Spec review and
co-review stay `opus/high`.
`plan_reviewer` is in neither `CRITICAL_ROLES` nor `DIFFICULTY_ROLES`, so
`--risk critical` is refused on it; a plan that needs a heavier review is
escalated with a recorded `--config-json` `routes` override on `plan_reviewer`,
never by hand-picking `--role reviewer`.

Native Codex `implementation-review` resolves the same
`development_reviewer` role to `gpt-5.6-sol/high`. Dispatch this step through
`route --step implementation-review`; the Herd lifecycle continues to store
the task worker as `review`.

## Deviating from the defaults

Two axes raise effort within the role's chosen model. Neither lowers it. A
repo lowers effort through `config.json` `routes`, down to the tier of the
role's default model at `low` (`EFFORT_FLOOR`); a raising axis raises the
floor with it. Because the floor is a tier, the same override can trade the
model down at a higher effort (an opus role accepts `sonnet/medium`).

- `risk=critical` -- blast radius. Restricted to `development_reviewer`,
  `reviewer`, `skeptic`, `think`.
- `difficulty=hard` -- how much thinking the task needs. Available to `planner`,
  `implementation`, `development_reviewer`, `reviewer`, `skeptic`, `think`.
  Supplied explicitly through
  `--config-json`; the director may propose a level but a human confirms it,
  and the proposal is recorded alongside the outcome so the agreement rate is
  measurable before the confirmation step is retired.

Both axes apply on either runtime -- `resolve_route` resolves `difficulty` and
`risk=critical` the same way for Claude and Codex native routes, not just Claude.

Both raise `quality_floor` with the effort, so a fallback below the raised floor
is skipped rather than promoted, and exhaustion blocks at
`no-fallback-meets-quality-floor` instead of quietly serving less.

**Raise the dispatch timeout whenever you raise effort.** The measured failure
mode of high effort is a timeout, not worse reasoning: a fixed wall clock turns
extra thinking into a truncated run, and the symptom looks nothing like the
cause. A `difficulty=hard` dispatch needs more `--timeout-secs`, not just more
effort.

The ladder stops at `xhigh` deliberately. `max` exists but is unproven --
measured gaps against `xhigh` sit inside run variance -- and it is documented to
cause overthinking on structured-output tasks. The only place the ceiling binds
is a critical-risk reviewer, which is exactly where elaborated reasoning is
documented to increase misjudgment.

## Why these values, where the source design contradicted itself

The design note this table came from disagreed with itself in twelve places.
Each is resolved here, with the reason, so none is silently re-litigated.

1. **The planner is `opus/high`, and its fallback is fable at the tier floor.**
   Fable authoring loops are what exhausted a five-hour usage window on
   2026-09-21; opus authors the artifact and fable reviews it once. A
   quality-tier table (`CLAUDE_MODEL_TIER` in `agent_runtime.py`) makes fable
   and opus comparable by capability, not by effort label: fable/medium is
   opus/high's tier peer, so the fallback swaps at the tier-matching effort
   rather than the same literal label or a compensating `xhigh`.
2. **The fallback attaches to the planner role**, so it covers brainstorm, spec
   and plan alike. One worker spans all three and cannot hold two policies.
3. **Gateway effort is `medium`.** Shipped in PR #107. The open dial is closed by
   the merge.
4. **Where a value shipped, the shipped value wins** over any note still listing
   it as an open question. A merged commit outranks an open dial.
5. **Terra and Luna are never default-routed** in Claude-led work. They are
   reachable only as Astra's delegated implementers inside the Codex lane.
6. **`CODEX_ROUTES` gains only `plan_reviewer`, at Astra's existing value, and
   the UX/UI override is a config-level `routes` override at dispatch.** That
   keeps one role table rather than two, and it is already how the SKILL does
   it.
7. **Reviewer is `opus/high` by default**, rising to `xhigh` under
   `risk=critical` or `difficulty=hard`. Defaults and escalations are different
   statements about the same role.
8. **`planner` is deliberately not in `CRITICAL_ROLES`.** Risk is about blast
   radius; hard-plan escalation is what `difficulty=hard` is for.
9. **Superseded 2026-09-22.** The implementer ran at `high` since 2026-09-08
   (92c049a) to 2026-09-22; measured 2026-09-06..09, Sonnet implementers at `high`
   confabulated as often as not (todo
   `2026-09-08-lower-orchestrator-effort-floors-and-restore-impl`), so `high`
   bought cost, not reliability. Implementation now defaults to `medium`;
   planner and reviewers keep `high`.
10. **The voice pass is `gpt-6-astra/high`**, matching every other Astra row.
    Nothing argued for a different value; the source simply omitted it.
11. **Tier doctrine describes defaults, not exclusivity.** `opus` is the reviewer
    tier and also the gateway model at a lower effort. No role names a model
    version: every tier is a family alias, which resolves to that family's
    newest release.
12. **Skeptic is `opus/high`**, rising to `xhigh` under `risk=critical` or
    `difficulty=hard` -- the same as reviewer, which the source left unstated.
13. **A fallback candidate is filtered at the role's default quality tier, not
    the configured one.** A caller who overrides a role to a cheaper model or
    effort owns that choice; the fallback ladder still protects the role's
    own default floor, not the caller's lowered request.
