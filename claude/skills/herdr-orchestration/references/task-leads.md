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
behalf.

## Reprompting a bound worker

`herdr_dispatch.py reprompt --binding <bid>` sends a second brief to the
worker a lead launched, with the lead's own `--session` and `--fence`. The
other flags are the launcher form's. The adapter validates the binding the
way `launch --binding` does, then requires the named launch to be the final
bound row (`workers[-1]`) of the lead's task record. Otherwise it refuses with
"named launch is not the final bound attempt; re-dispatch instead". A lead
repairs after review by re-dispatching an implement worker, not by
reprompting an earlier row.

The order is: read the row, probe the agent (`agent get`, idle or done), then
`reserve-reprompt` (appends a `starting` entry), deliver with no lock held,
then `enrich-reprompt` (records `delivered`, `uncertain` or
`delivered-unrecorded`). The adapter never writes a `leads/` record itself.

Exit codes:

- Adapter: `exit 0` with status `reprompted`, `uncertain` or
  `delivered-unrecorded`; `exit 2` with error JSON and a reason for any
  refusal (an invalid, unknown, revoked or foreign binding; a non-final row;
  a failed probe; an unresolved earlier entry).
- Core verbs (`reserve-reprompt`, `enrich-reprompt`): `exit 0` when written or
  a replayed no-op; `exit 2` refused, with `[X] <reason>` on stderr.

A launcher fence with `--binding` is refused by the lead-fence check, and a
lead fence without it is refused by the launcher owner check. Neither writes.

Recovery: an unresolved `starting` or `uncertain` entry blocks further
reprompts on that row and keeps its pane outstanding for teardown. Before
re-dispatching, end the prior worker. A re-dispatch into the same pane proves
the prior agent exited. A re-dispatch into another pane is the lead's
assertion that the prior pane's occupancy ended, so close that pane first. An
operator who terminated the pane passes `--descendants-terminated` to
teardown.

A reprompt after the worker's `emit-done` keeps its pane outstanding until a
later emit settles the new turn. A review worker cannot replace a verdict at
the same head with a different outcome: the core refuses with "a same-revision
review verdict cannot be replaced".

## Worker-side hooks

A worker a lead launched runs in the lead's workspace, so its pane differs
from the director row's pane. `herdr_stop_gate.py` finds the one claimed
binding whose final row names that workspace and pane and gates the stop
against the lead subtree. The refusal's emitter line carries `--binding`, and
a review line carries `--reviewed-base-sha` and `--reviewer-session`. A pane
with no match, or with several, is allowed silently. `scratch_policy.py`
audits the same worker's scratch allows to
`leads/<bid>/tasks/<task_id>.policy.jsonl`.

## Enabling task leads

Run these steps for one repository at a time, only on the owner's explicit go
for that repository.

1. Run `task-lead-status` and read `gate_enabled` and `admit`.
2. Get the owner's explicit go to enable task leads for this repository.
3. Run `activate-task-leads --repo-path <repo> --repo-slug <slug> --session <director session> --fence <director fence>`.
   Idempotent. Exit 0 means the record is written; exit 2 means a refusal
   (invalid slug, stale fence, wrong session, or a non-launcher owner) and
   nothing is written.
4. Confirm with `task-lead-status`: `gate_enabled` must read true.

The verb writes only this repository's gate record; repositories without a
record keep refusing. It admits no lead while the `SKILL.md` capability marker
is `0`; `admit` stays false until the marker reaches the required level.
`deactivate-task-leads` is the off switch.

Uncertain outcome: after an activation that did not exit zero, or whose result
you did not see, read `task-lead-status` first. If it reads
`gate_enabled: true`, stop. If it reads disabled or absent, run the verb again
only with a fresh go, because a deactivation may have landed in between and a
blind retry would undo it.

## When to use a task lead

A lead is for one task with several slices to coordinate on one branch. Small
independent tickets get plain parallel implement workers through the normal
kickoff: a lead adds a binding handshake and gains nothing there. A lead
never edits task files itself; even a one-line change goes to a bound worker.

## Dispatching a task lead (director side)

1. Preconditions: `task-lead-status` reads `gate_enabled: true`, `procedure: 1`
   and `admit: true` (see "Enabling task leads"). Plan and confirm the task as
   usual, then settle the plan row. Do not run `advance`; the lead replaces the
   launch.
2. Render the lead's prompt with `render-brief --phase lead` (template
   `brief-template.md`, blocks `brief:lead` and `brief:close-lead`). Launch it
   as the task's implement row: `herdr_dispatch.py launch --phase implement`
   with the printed `agent` as `--agent` and `brief_path` as `--prompt-file`.
   The block tells the lead to dispatch only: claim, `write-task --binding`,
   workers and reviewer through `launch --binding`, PR, and envelope. Never
   hand-write or append a lead section to another phase's brief; the implement
   Close forbids the PR a lead must open.
3. Handshake: the lead's first turn prints `lead-session $CLAUDE_CODE_SESSION_ID`
   and stops. The stop gate refuses that first stop; the lead does not emit.
   Read the line with `herdr pane read <lead pane> --source detection --lines 50`.
4. Run `issue-binding --task-id <task> --workspace-root <worktree>
   --expected-session <lead session>` with the launcher fence. Record the
   binding id.
5. Deliver the binding with the launcher form of `herdr_dispatch.py reprompt`
   on the lead's row, naming the binding id.
6. The lead runs `claim-owner --control-tier lead --binding <bid>`, writes the
   task record with `write-task --binding`, launches workers and reviewer with
   `launch --binding`, reprompts a worker for a later slice with `reprompt
   --binding`, pushes the branch and opens a draft PR, then calls
   `emit-artifacts` once with every file the director will quote (a later call
   replaces the manifest and drops the others), and `emit-envelope`. It closes
   its worker panes and emits its own launcher `emit-done` for the implement
   phase.
7. After that `emit-done`, read `leads/<bid>/envelope.json` and
   `artifacts.json`, and check each blob against its digest and size. Nobody
   moves the branch from here until step 8 succeeds.
8. Run `integrate-envelope --binding <bid> --base-sha <base> --head-sha <PR
   head>`, then `teardown-binding --binding <bid>`. The lead's manifest exists,
   so `--no-artifacts` is not needed; never `--prune` before the evidence is
   quoted.
9. Ship through the normal launcher review and ship gates. Nothing bridges an
   integrated envelope to them.

Constraints and recovery:

- `set-binding-status --status completed` is refused, because
  completed is reached only through integrate-envelope.
- `integrate-envelope` writes the consumption record, then the `completed`
  status. If it stops between them, re-run it with the same SHAs and the branch
  unmoved. `teardown-binding --abandon` is refused while a consumption record
  exists.
- A bound review row carries `review_base_sha`, copied from the task record by
  `reserve-dispatch`. When the record has no 40-hex `base_sha`, the reservation
  fails with "a review reservation requires a 40-hex base_sha on the task record",
  so the lead writes the base before launching a reviewer.
- A launcher reprompt entry left `starting` or `uncertain` is never resent and
  blocks later launcher reprompts of the lead. If the binding reads `claimed`,
  the lead holds it and the run continues; otherwise stop for the owner, who
  ends the lead and runs `teardown-binding --abandon` and `reconcile-leads`.

A lead that already coded the change itself (no bound implement or review
attempt, so `emit-envelope` refuses `pr_ready`): never hand-write the missing
attempts. This note holds only when the lead has no bound worker rows;
`teardown-binding` refuses on outstanding descendants. The lead emits its own
launcher `emit-done --phase implement` at the PR head. The director runs
`teardown-binding --binding <bid> --abandon`, which is allowed only while no
consumption record exists, then `reconcile-leads`. Both take the launcher's
`--session` and `--fence`. `reconcile-leads` without `--apply` is a dry run
that only reports; add `--apply` to change state. Then record the PR number on
the task record and run the normal review gate and ship gate. Re-run a step
only after reading its result: the done record, `inspect --binding <bid>`,
the binding status.

## Rolling back task leads

Step 0, before everything else -- restore handling: if rollback follows a
state restore of any kind, publish a disabled gate record and confirm the
verb exited zero before resuming any service.

1. Stop dispatching new leads. A human decision; nothing durable records it,
   so re-assert it by running step 2.
2. Run `deactivate-task-leads` with the same flags and exit codes as the
   activate verb. Idempotent; re-run it if interrupted, and
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
