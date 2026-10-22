# Auto actions: re-run lost gates, repair confirmed blockers

The director does these without asking, reports each in its turn summary and
records a task decision note. A note is reporting only, never an authority
input. Read this file at SKILL.md section 5 (changes-requested path), section 6
(ship dispatch) and section 6a step 0 (`CHANGES`, `INCOMPLETE`).

## Loss classes (read fields on disk, never notes or transcript)

- Ship gate lost, seat failure: `merge-ready` reports `handoff_state:
  current`; the pinned handoff (`ship_launch_id` -> `ship.json`) has
  `verdict: INCOMPLETE`, `head_sha` equal to live HEAD and a full-tier report
  (a `delta` or `small` handoff stays with section 6 rule (c)); and every
  report reason is one of `seat <name> runner status is not success`,
  `seat <name> artifact is empty` or
  `seat <name> structured report is missing`. This covers a seat timeout, a seat with no output and host sleep.
  A quota stop never matches: the runner moves the notice into `errors`, and
  `gate_report` then adds `seat <name> result is a usage-limit refusal` beside
  the status reason, which makes the list mixed.
- Ship gate lost, gate worker died: a stopped run (a pinned ship launch with
  no `ship.json` whose agent is gone or idle).
- Review lost, deadline stop: `status: changes-requested`, `review_head_sha`
  equal to live HEAD, and the latest review row's `launch_id` in
  `retired_review_launch_ids`. This covers a reviewer that died or stalled
  and a host that slept.
- Not a loss: any other reason, a mixed reason list, a
  `seat <name> result is a usage-limit refusal` (a quota stop), a moved head,
  a gate with confirmed defects, and a task-local `review-change`
  `changes-requested` verdict (its latest review launch is not retired).
  These keep their existing handling.

## Re-run

Re-dispatch the same gate at the same head without asking:

- Ship, seat failure: `python3 "$DISPATCH" dispatch-gate ... --phase ship
  --infra-rerun`, with the `INCOMPLETE` pin left in place.
- Ship, gate worker died: the same command. The once-per-head stopped-run
  guard still applies; a second stop at that head is refused with
  `relaunch budget spent` and goes to the ask below.
- Review, deadline stop: `dispatch-gate ... --phase review --infra-rerun`
  with no director-side reset. The gate resets the stale verdict and counts
  the re-run in one write.

`dispatch-gate` allows at most twice per gate phase per head (counted in
`infra_reruns`) and refuses the third (exit 2, `infrastructure re-run budget spent`). It also
refuses an unflagged dispatch of that phase at that head until
`--owner-approved` is passed. Record the note from the result's
`infra_rerun` field: "automatic re-run <count> of 2, <phase> at <head>,
<loss class>". Never write `infra_reruns` by hand; carry it in every
`write-task` full-record write.

A refused ship dispatch that says `a ship agent may still be running` is not
a spent budget: wait for the next check-in.

Any other `INCOMPLETE` waits for a human re-gate request: then `write-task`
the record with `ship_launch_id: null` (every other field carried), and
section 6 dispatches afresh.

## Ask after a refusal

On `infrastructure re-run budget spent` or `relaunch budget spent`, ask once
with `AskUserQuestion`: "Re-run the <review|ship gate> at <head>
(Recommended)" and "Leave it". The answer authorizes exactly one dispatch in
the same turn; record it as an owner decision. A director resumed before that
dispatch asks again.

- Review: apply the stale-verdict reset (`status: completed`,
  `review_head_sha: null`, every other field carried), then
  `dispatch-gate --phase review --owner-approved`.
- Ship: `dispatch-gate --phase ship --owner-approved` as one command with the
  pin kept; the gate forces `tier=full` and settles the old pinned row.

## Repair

When the ship gate verdict is `CHANGES` (`merge-ready` reports
`handoff_state: current`, pinned handoff `verdict: CHANGES`, `head_sha` equal
to live HEAD), the co-review verifier confirmed the blockers. Write
`changes-requested` as section 6a step 0 says and dispatch the repair worker
without asking, then report it and record a note. Ask once, naming the
blocker and the decision or file, only when:

- a blocker's fix, as the gate report states it, contradicts a live recorded
  owner decision (the `[INFO] herdr decisions` block, or `decisions --all`
  when that block says older entries were omitted); or
- a blocker names a file outside the PR's scope: the files in
  `git diff --name-only <base_sha>...HEAD` in the task worktree plus the
  files in the File layout section of the PRD the task's `plan_artifacts`
  `spec` entry names.

After the repair, before section 5 dispatches the next review, run the scope
check again over `git diff --name-only <pinned ship.json head_sha>..HEAD`
whenever the pinned verdict is `CHANGES` and its `head_sha` differs from live
HEAD, and ask when any file is outside scope.

The exhausted `co-review --fix` budget rule (section 5) covers only that
budget. A herdr stop-after-gate ship run never spends it.

A task-local review `changes-requested` verdict (no verifier) keeps today's
handling.

## Asks that stay

A work-repository merge, a person-aimed post, a Jira write, a force push, a
lease takeover, a findings-digest mismatch, an unreproduced advisory, and a
task-local review `changes-requested` verdict.
