# Pipeline worker mapping

Policy an orchestrator follows when dispatching a superpowers pipeline. It is
not a table any code reads: `claude/hooks/agent_runtime.py` is authoritative for
every model and effort named here, and the `policy document matches the route
table` case in `agent-runtime.test.sh` parses this file and fails if it drifts.

This describes the **native** path -- `agent_runtime.resolve_route` plus
`herdr_dispatch.launch`. It does **not** describe the legacy
`herdr_orch_core.py` path that `run-mech` and `run-think` use today, which runs
its own `ROLE_DEFAULTS` off `capabilities.json`, never calls `resolve_route`, and
serves `opus/high` where the native path serves `opus/xhigh`. Reconciling the two
is tracked separately.

## Step to worker

| Step                      | Role                 | Model / effort   | Runtime | Gate                              |
| ------------------------- | -------------------- | ---------------- | ------- | --------------------------------- |
| isolated worktree         | dispatch harness     | --               | --      | auto                              |
| brainstorming             | planner              | fable/high       | Claude  | HUMAN                             |
| write spec                | planner              | fable/high       | Claude  | auto                              |
| codex-spec-review         | codex reviewer       | gpt-6-astra/high | Codex   | Codex, auto-resolve               |
| writing-plans             | planner              | fable/high       | Claude  | auto                              |
| codex-plan-review         | codex reviewer       | gpt-6-astra/high | Codex   | Codex, auto-resolve               |
| implement                 | implementation       | sonnet/high      | Claude  | auto + per-task review            |
| implement, UX/UI override | codex implementation | gpt-6-astra/high | Codex   | fresh Claude review before commit |
| implementation review     | reviewer             | opus/high        | Claude  | auto, blocks on findings          |
| voice pass (outward text) | codex voice          | gpt-6-astra/high | Codex   | auto, before the write            |
| co-review, Claude half    | reviewer             | opus/high        | Claude  | verify each finding               |
| co-review, skeptic        | skeptic              | opus/high        | Claude  | verify each finding               |
| co-review, Codex half     | codex reviewer       | gpt-6-astra/high | Codex   | verify each finding               |
| merge                     | gateway              | --               | --      | HUMAN                             |

The planner's `fable/high` carries a configured `opus/xhigh` fallback for when
fable is unavailable. One planning worker spans brainstorm, spec and plan --
not three dispatches.

## Deviating from the defaults

Two axes raise effort within the role's chosen model. Neither lowers it.

- `risk=critical` -- blast radius. Restricted to `reviewer`, `skeptic`, `think`.
- `difficulty=hard` -- how much thinking the task needs. Available to `planner`,
  `implementation`, `reviewer`, `skeptic`, `think`. Supplied explicitly through
  `--config-json`; the orchestrator may propose a level but a human confirms it,
  and the proposal is recorded alongside the outcome so the agreement rate is
  measurable before the confirmation step is retired.

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

1. **Planner fallback is `opus/xhigh`, not `opus/high`.** Shipped in PR #108 and
   live in `CLAUDE_FALLBACKS`. Losing the top tier is compensated, not absorbed.
2. **The fallback attaches to the planner role**, so it covers brainstorm, spec
   and plan alike. One worker spans all three and cannot hold two policies.
3. **Gateway effort is `medium`.** Shipped in PR #107. The open dial is closed by
   the merge.
4. **Where a value shipped, the shipped value wins** over any note still listing
   it as an open question. A merged commit outranks an open dial.
5. **Terra and Luna are never default-routed** in Claude-led work. They are
   reachable only as Astra's delegated implementers inside the Codex lane.
6. **`CODEX_ROUTES` is unchanged; the UX/UI override is a config-level `routes`
   override at dispatch.** That keeps one role table rather than two, and it is
   already how the SKILL does it.
7. **Reviewer is `opus/high` by default**, rising to `xhigh` under
   `risk=critical` or `difficulty=hard`. Defaults and escalations are different
   statements about the same role.
8. **`planner` is deliberately not in `CRITICAL_ROLES`.** Risk is about blast
   radius; hard-plan escalation is what `difficulty=hard` is for.
9. **High effort is not reserved to planner and reviewer.** The implementer runs
   at `high` too. The doctrine is about keeping high effort off the _gateway_.
10. **The voice pass is `gpt-6-astra/high`**, matching every other Astra row.
    Nothing argued for a different value; the source simply omitted it.
11. **Tier doctrine describes defaults, not exclusivity.** `opus` is the reviewer
    tier and also the gateway model at a lower effort. The `opus` alias resolves
    to Opus 5 in both.
12. **Skeptic is `opus/high`**, rising to `xhigh` under `risk=critical` or
    `difficulty=hard` -- the same as reviewer, which the source left unstated.
