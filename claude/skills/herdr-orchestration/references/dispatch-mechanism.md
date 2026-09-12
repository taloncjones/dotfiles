# Dispatch mechanism (gateway operating guidance)

How the gateway chooses a dispatch target, gates dispatched work, incorporates
review feedback, and keeps context cache-cheap. Model and effort per role are
authoritative in `claude/hooks/agent_runtime.py`; the step-to-role binding is
authoritative in its `PIPELINE_ROUTES`. The per-step model/effort table lives in
`references/pipeline-worker-mapping.md`.

## Resolve routes by step

Resolve a pipeline dispatch's route by step, so the role is derived rather than
hand-picked:

```
python3 "$RUNTIME" route --step <step> --runtime <claude|codex>
```

`--step` looks the step up in `agent_runtime.PIPELINE_ROUTES` (brainstorming ->
planner -> fable/high, implement -> implementation -> sonnet/high, and so on) and
resolves model/effort through the same `resolve_route` as `--role`. `--step` and
`--role` are mutually exclusive; exactly one is required; an unknown step is a
hard error.

Guarantee and its limit: `--step` fixes the DEFAULT step -> role -> model/effort
mapping, and the `pipeline steps bind to policy routes` conformance case in
`agent-runtime.test.sh` fails if that default drifts (so planning cannot silently
become `sonnet`, nor every step collapse onto `fable`). It is a convention, not a
hard runtime constraint: `--role` remains available for non-pipeline dispatches,
and an explicit `--config-json` `routes` override still lets a caller send a role
to a different model -- that is the caller's deliberate, recorded choice, exactly
as `resolve_route` already treats overrides. Dispatch pipeline steps through
`--step` and do not hand-pick a role for a pipeline step.

## Dispatch selector (Herd vs Workflow)

| Mechanism     | Use for                                              | Shape                                                                    |
| ------------- | ---------------------------------------------------- | ------------------------------------------------------------------------ |
| Herd worker   | A durable, PR-sized slice                            | Worktree-backed, cross-session, human merge gate                         |
| Workflow tool | In-session parallel fan-out of independent sub-tasks | Tiered (fable/opus judges, sonnet workers), Claude-only, per-task review |

- Reach for a Herd worker when the unit is a shippable PR that needs worktree
  isolation, cross-session durability, and a human merge gate.
- Reach for the Workflow tool for independent sub-tasks WITHIN an already-planned
  slice. It sits behind its own opt-in/size gate; workers edit in isolated
  worktrees respecting the orch/edit guards. A Workflow does NOT re-run
  brainstorm/spec per task -- the superpowers pipeline gates wrap it, once,
  upstream. There is no Codex Workflow API; Workflow is Claude-only.

## Gate policy for dispatched work

Default for dispatched Herd work (not just `/goal`):

- Brainstorm design-direction: HUMAN gate.
- spec -> codex-spec-review -> writing-plans -> codex-plan-review -> implement ->
  per-task/co-review: Codex is the review gate, findings auto-resolved.
- Merge: HUMAN gate (fresh go).
- Interaction: gateway relay, a single channel. The worker surfaces
  questions/status to the gateway; the human talks only to the gateway, which
  relays. The worker stays isolated; the gateway context stays small.

Under `/goal` autonomous mode the two HUMAN gates convert to status-surfaced
Codex/auto gates (per the global CLAUDE.md autonomous-mode rule): run the Codex
reviews, resolve findings autonomously, and proceed, surfacing a brief status at
each gate rather than blocking.

## Same-worker review incorporation

codex-spec-review / codex-plan-review findings return to the SAME still-alive
planning worker as an appended turn, never a fresh worker -- independence lives
in the reviewer's different model family; incorporation needs the author's intent
context.

1. Pass 1: the planner either revises for a finding, or disputes it with a
   recorded rationale (auditable).
2. The reviewer then dispositions the revised, re-frozen artifact: it confirms
   each claimed fix and accepts or rejects each dispute rationale. The planner
   cannot close a reviewer finding on its own rationale; only reviewer
   disposition closes it.
3. Iteration cap = 2 incorporation passes total. A full scoped re-review (not
   just disposition) is triggered only by a "substantial revision" -- a change
   that alters a requirement, an interface, or the artifact's section structure,
   not a wording/typo fix.
4. Stop: DONE when every finding is fixed-and-confirmed or dispute-accepted by
   the reviewer. If any finding is unresolved after the cap, or the reviewer
   raises a NEW finding that cannot be resolved within the cap, the outcome is
   BLOCKED/ESCALATED to the human gate -- never silent completion.

Keep the planning worker alive (idle) across its review and deliver the findings
as an appended turn to that live worker; teardown+resume from a handoff degrades
to the fresh-worker weakness and is a fallback only.

A dedicated, fence-checked dispatch primitive for "append a turn to a named live
worker" is shipped as `herdr_dispatch reprompt` (CLI subcommand):
`reprompt --repo-slug --task-id --session --workspace-id --launch-id --phase
--cwd --prompt-file --fence [--runtime --prompt-timeout-ms --personal]`. It
validates the worktree/task context, targets the worker by `launch_id` (not the
latest attempt), and holds the owner fence across re-validating that the target
is still the current attempt for its phase AND delivering acceptance, so no
superseding attempt or ownership transfer can slip in between. It requires the
live agent idle on its recorded pane. Delivery is classified so an incorporation
turn is never double-delivered: confirmed rejection (only a provable
pre-acceptance failure, retry-safe), uncertain (timeout, nonzero exit, or
ambiguous reply -- never auto-resent), delivered, or delivered-unrecorded
(accepted but the record write failed -- never resent).

Best-effort limitation: reprompt cannot prove the LIVE agent is the same process
generation as the recorded launch -- a worker restarted under the same
name/pane/runtime passes the checks. Closing this needs herdr to expose an
immutable session/process-generation id (same missing-capability class as the
unsupported native `wake()` queue); the return payload carries
`observation: "session-identity-not-exposed-by-herdr"`. Where the primitive is
unavailable, run the incorporation loop above by hand through the dispatch
surface and treat cross-session teardown+resume as the fallback.

## Cache economics

- Append, never rebuild: relay findings as a new turn to the live worker; never
  re-onboard to incorporate. This rides the runtime's AUTOMATIC prefix caching
  (both Claude and Codex) -- there is no `cache_control`/TTL knob on the launch
  path (`agent_runtime.launch_argv` threads only model/effort/permission-mode and
  reasoning-effort), and none is needed.
- Stable system/skill prefix across workers; put volatile bits (timestamps,
  launch ids, changing tool lists) at the TAIL. `herdr_dispatch._lifecycle_prompt`
  already appends lifecycle context after the stable prompt, preserving the
  shared prefix.
- Idle-across-review: lean on the default cache TTL. If a review overruns it,
  accept one cache re-write; never keep-alive ping to stay warm (pure waste).
- Same-worker incorporation is the cheap path precisely because it appends to a
  warm cache instead of rebuilding context in a fresh worker.
