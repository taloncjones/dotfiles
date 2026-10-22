# Auto actions: re-run lost gates, repair confirmed blockers, doc-rule actions

The director does these without asking, reports each in its turn summary and
records a task decision note. A note is reporting only, never an authority
input. Read this file at SKILL.md section 2 (todo split), section 4
(contract gate), section 5 (changes-requested path), section 6 (ship
dispatch, carry-forward and delta) and section 6a step 0 (`CHANGES`,
`INCOMPLETE`).

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

## Doc-rule actions

Each action below reports in the turn summary and records a task decision
note (a decision note is reporting only, never an authority input). Write
the note before the action's first durable write, so a crash never leaves
an action without its note. Every action is safe to repeat: the re-pin
halts, the split resumes from its plan, `delta-class` is deterministic and
`dispatch-gate` refuses a live pinned agent, and the marker has its dedupe.

### Contract re-pin

Re-pin without asking only when all of these hold:

- (a) The task record's `plan_artifacts` has a `kind: spec` entry (a planned
  task). A fast-path or mech task keeps the ask.
- (b) The re-pin reason names evidence that the contract command, not the
  code, is wrong: a review findings file whose SHA-256 matches its
  completion record, a live recorded owner decision ID, or the section of
  the frozen PRD the command contradicts. With no such evidence, ask.
- (c) No agent is live for the task: the live `herdr agent list` poll shows
  no `working` or `blocked` agent from the task's `workers` rows. The status
  is `in-progress` (after a correlated `done.json`), `completed`, `reviewed`
  or `changes-requested`; never `review-dispatched`. Otherwise wait for the
  next check-in.

Then run these steps in order, in one turn:

1. `note-decision --task <task_id>`: "auto: contract re-pin at <head
   sha12> from <pinned sha12>: <command name>; evidence <reference>".
2. Edit `<worktree>/<contract_path>`.
3. `verify-contract ... --contract <contract_path> --allow-unpinned
   --validate-only` prints SHA-256 A. On a non-zero exit, restore the
   pinned frozen copy byte-for-byte and ask.
4. Freeze it: `review.py artifact --repo <worktree> --kind contract --path
   <contract_path> --task-id <task_id> --output-dir <parent directory of
   the frozen spec>`, which returns SHA-256 B. When B differs from A,
   restore the pinned frozen copy byte-for-byte and ask.
5. One full-record `write-task` with `contract_sha256: B`. When the status
   is `reviewed` or `changes-requested`, the same write applies the
   stale-verdict reset (`status: completed`, `review_head_sha: null`, every
   other field carried).
6. Run the contract gate (SKILL.md section 4), then dispatch the review as
   section 5 says.

Review coverage: the contract is never committed, so it is not in the git
diff. Whenever the directory of the frozen spec holds a frozen
`contract-*.json` whose SHA-256 differs from `contract_sha256`, the review
focus file lists every frozen contract copy there (path and SHA-256), names
the pinned one, includes `diff -u <copy> <pinned>` for each other copy, and
asks the reviewer to check the pinned contract against the PRD's acceptance
mapping: report a blocking finding when the pinned contract drops or weakens
a check the mapping requires. Label the other copies "not pinned"; a
difference alone is never a finding.

Halt and resume. The re-pin writes the new pin (step 5) before the next
pinned `verify-contract` run, so `verify-contract` exit 4 means the file
changed with no completed re-pin, including a re-pin interrupted between
steps 2 and 5. It stays an integrity halt: the director never re-pins on its
own to clear it. The halt report shows the worktree file's SHA-256, the
pin, and each frozen copy beside the frozen spec with its SHA-256, flagging
a copy that equals the worktree file. Ask once with `AskUserQuestion`:

- A frozen copy equals the worktree file (an interrupted re-pin past step
  4): "Finish the re-pin" and "Restore the pinned contract". Mark Finish
  "(Recommended)" only when a step-1 note "auto: contract re-pin ... from
  <current pin sha12>" exists for the task; otherwise recommend neither (the
  match may be an unvalidated planning draft). Finish first re-checks (c)
  (the `herdr agent list` poll and the status), then runs steps 3-6,
  requiring SHA-256 A to equal the matching copy's. "Restore the pinned
  contract" copies the pinned frozen copy back byte-for-byte.
- Otherwise: "Restore the pinned contract (Recommended)" and "Leave it
  halted".

### Todo split

When a raw todo's Solution names two or more independent mechanisms (each
could ship alone) and no live recorded owner decision sets that todo's
scope, split it without asking:

1. Resume: when the todo already has a `## Split plan` section, use it as
   written, never judge the split again, and go to step 4.
2. `note-decision --task <todo_id>`: "auto: split <todo_id> into <n>
   slices, plan in the todo".
3. Append a `## Split plan` section to the todo file with the Edit tool: the
   slice count n, and per slice a title and a one-line scope. Slice 1 is
   this todo ID. The Problem and Solution stay word for word.
4. For each slice k from 2 to n: reuse the todo whose title ends "(slice
   <k>/<n> of <todo_id>)", found with `todos.sh list --all` (pending or
   completed); otherwise run `todos.sh new "<title> (slice <k>/<n> of
   <todo_id>)" --area <area> --file <path>... --depends-on todo:<slice k-1
   id>`, which writes that title in the same write that creates the file.
   Then give it the Problem line "Slice <k> of <n> split from <todo_id>."
   plus the plan's scope, and write its ID into the plan's slice k line.
5. Dispatch the plan worker for slice 1 with a focus file that says to plan
   slice 1 of the todo's Split plan only.

Reversal: delete the follow-up todo files and the `## Split plan` section;
the original text was never changed.

### Delta round

On `delta-class` exit 0 (`references/ship-carry-forward.md`), dispatch the
delta round in every repository. Any other exit dispatches the full round as
usual. Before the dispatch, record a note "auto: delta round for PR #<n> at
<head sha12> (<stats>)" and report the PR, head, caps and `stats` in the
turn summary.

### Carry-forward marker

After the audit comment and the co-review dedupe, record a note "auto:
carry-forward marker attempt on PR #<n> at <head sha12>" and post the marker
without asking. The post guard decides: a personal repository needs no go,
and in a work repository the guard lets green evidence (an `APPROVE` marker
on a PR this account authored) through. Only after the comment call exits 0,
print `[INFO] posted co-review marker on #<n>: APPROVE`. A guard refusal
turns it into a gated post under `references/posting.md` and a second note:
"refused by post guard; gated under posting.md". Never decide authorship
yourself.

## Asks that stay

A work-repository merge, a person-aimed post, a Jira write, a force push, a
lease takeover, a findings-digest mismatch, an unreproduced advisory, a
task-local review `changes-requested` verdict, a contract re-pin on a
fast-path or mech task, a contract re-pin with no named evidence, a marker
the post guard refuses, and the `verify-contract` exit 4 integrity halt with
its resume ask (Contract re-pin).
