# Event schema

The task record's `status` field (written via `$CORE write-task`) is the
sole authoritative state -- the value the orchestrator reports and acts on.
`events.jsonl` is a hook-hints-only log: a secondary signal the orchestrator
reads during status/triage, never a status override and never itself the
authoritative record of a transition.

## Event authorship

Only the Stop/Notification hook (`herdr_worker_status.py`, via
`append_event`, one writer per `<workspace>.events.jsonl`) ever appends to
`events.jsonl`:

- `stopped` -- Stop hook fired for an `impl` role workspace.
- `blocked` -- an approval/question Notification fired.
- `review-stopped` -- Stop hook fired for a `review` role workspace.

No code appends `kickoff`, `phase-advanced`, `review-dispatched`,
`completed`, `paused`, `failed`, `changes-requested`, `reviewed`,
`abandoned`, or `merged` as log records. Those names appear only as the
"Event" column of the SKILL.md state transition table (section 9), where
each names the conceptual transition the orchestrator makes to `status` via
`$CORE write-task` -- not an emitted `events.jsonl` line. Adding a verb to
append them as real log records is a documented future option, out of scope
here.

The `$CORE watch` subcommand (orchestrator wake, SKILL.md section 1 step 6)
is a READER of `events.jsonl` and the `tasks/` sidecars: it emits only the
closed stdout vocabulary `signal` / `heartbeat` and never appends events.

After appending, the hook also pushes one wake line to the owning
orchestrator's inbox socket (`$CORE post_wake`, path from
`owner.json.messaging_socket`). The wake is not an event: it is written to no
herdr file, carries no authority, and the orchestrator treats it as a wake
trigger only. Claude Code persists the delivered line in the orchestrator's
own session transcript like any message; it holds only non-secret
operational metadata (`repo_slug`, workspace id, event name, timestamp,
nonce). The two steps fail independently: an `append_event` failure never
suppresses the push.

## Record shape (`v: 1`)

Each line of `<workspace>.events.jsonl` is one JSON object:

```json
{
  "v": 1,
  "ts": "2026-08-26T12:00:00Z",
  "workspace_id": "w1",
  "event": "stopped"
}
```

## Fold rule

`$CORE status` folds each task's hook-hint events (collected across every
workspace whose index resolves to that `task_id`) in chronological order
(`ts`, then `event` as a tie-breaker) to surface the latest hint (e.g.
`blocked`) alongside the task record's `status`. Malformed or truncated
lines, and lines with an unknown `v`, are **skipped with a counted warning,
never a crash** -- a corrupted final line (e.g. a partially-flushed append)
does not take down the fold. `fold_status`'s `authoritative` field folds
over the same `_AUTH` vocabulary for forward compatibility, but stays empty
today since nothing writes those events; `status` display always comes from
the task record, never from this fold.

## Transition evidence -> event -> status

See the SKILL.md "State transition table" (section 9) for the authoritative
mapping from live evidence, through the conceptual transition, to the
resulting `status` written by `$CORE write-task`. This file documents only
the hook-hint event vocabulary and fold semantics; the transition table's
"Event" column names transitions, not emitted log records, and must not
drift from SKILL.md section 9.
