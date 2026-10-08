# Task leads: binding-scoped dispatch and rollback

## Lead dispatch through the adapter (section 8)

A lead passes `--binding <bid>` with its own session and fence; the adapter then
routes every record write through `reserve-dispatch` and `enrich-dispatch`
under the lead subtree instead of writing launcher-scope records (see "Lead
worker dispatch (binding-scoped)").

## Lead worker dispatch (binding-scoped)

Two steps, in this order. The bootstrap step is not optional: `launch --binding`
requires the bound task record to exist, and a missing record reads as absent
rather than empty.

1. `write-task --binding <bid> --task-id <t> --json '{...}'` with `workers`
   omitted or `[]`, creating the record. The record must carry `task_id`,
   `repo_slug`, `branch`, `worktree` (the lead's workspace root), and a 40-hex
   `base_sha`; before a review dispatch, also `review_head_sha` equal to the
   worktree's HEAD.
2. `herdr_dispatch.py launch --binding <bid>` with the lead's own `--session`
   and `--fence`, the existing pane/workspace, `--cwd` at the lead's workspace
   root, the phase (`plan|implement|review`), a unique agent name, the resolved
   route JSON, sandbox, and prompt file. Read `--help` for the current flags.

The adapter does what the four-step procedure used to ask of the lead by hand:
it validates the binding (claimed, naming this task, its `workspace_root` equal
to `--cwd`), reserves the attempt through `reserve-dispatch --binding` AFTER
the pane exists and BEFORE `agent start`, starts the agent, and records
readiness, prompt acceptance, and failure through `enrich-dispatch --binding`
with the full identity tuple on every call. It never writes a `leads/` record
itself. The worker's brief carries `--binding` on its emitter line; a review
brief also carries `--reviewed-base-sha` and tells the reviewer to append
`--reviewer-session`.

Reserving before the agent starts is what makes teardown safe: a `write-task`
refused afterwards cannot erase the row, so `outstanding_descendants` still
sees the pane and `teardown-binding --abandon` refuses instead of releasing the
lease over a live worker. A launch that fails after the reservation (for
example `agent start` refused) leaves the row at `status: launch_failed` and
its pane outstanding on purpose; re-dispatching appends a successor row, or an
operator passes `--descendants-terminated` after terminating the pane.

Cross-scope use fails closed before `agent start`: a launcher fence with
`--binding` is refused by the lead-fence check, and a lead fence without it is
refused by the launcher owner check. Neither writes a row.

Re-dispatch is another `launch --binding` call; the adapter mints a fresh
`launch_id` every time. Two repeats are handled by `reserve-dispatch`
differently. An exact repeat of the current row, while that attempt is
unsettled, is the crashed-lead retry: it succeeds and writes nothing, so one
pane is never counted twice. A repeat of any identity that a settlement record
already matches is refused, because it would arrive already settled and hide
the pane it names from teardown.

`inspect --binding <bid>` reads the bound attempt and its settlement record.
`emit-done --binding` and `emit-review --binding` require a live,
registry-corroborated lead lease, so a worker cannot settle on a dead lead's
behalf. `reprompt` has no bound form yet: a bound worker that needs a second
brief is re-dispatched or prompted by hand (follow-up todo). The worker-side
hooks (`herdr_stop_gate.py`, `scratch_policy.py`) still read launcher scope
only, so a bound worker's stop is not gated (follow-up todo).

## Rolling back task leads

Step 0, before everything else -- restore handling: if rollback follows a
state restore of any kind, publish a disabled gate record and confirm the
verb exited zero before resuming any service.

1. Stop dispatching new leads. A human decision; nothing durable records it,
   so re-assert it by running step 2.
2. Run `deactivate-task-leads`. Idempotent; re-run it if interrupted, and
   confirm the committed state with `task-lead-status`.
3. Settle or stop leads and descendants. If interrupted, re-run; outstanding
   work is re-reported by `outstanding_descendants`.
4. Run `teardown-binding` and `reconcile-leads`.
5. Verify a single owner and no lead occupancy. This is a read; re-run it as
   needed.
6. Downgrade components -- keep the last build that advertises capability `1`
   available and downgrade to it, never past it. Do not downgrade below
   capability `1`: below that level nothing enforces the gate, so quiescence
   would rest on a verification that has already gone stale.
