# Event schema

Events are the audit trail and hint source for the task record's `status`
field, which is the authoritative value for display. Events never override
`status` directly -- they inform the transition the orchestrator makes
through `$CORE`.

## Event authorship

- **Hook-produced hints only** (written by `herdr_worker_status.py` via
  `append_event`, one writer per `<workspace>.events.jsonl`):
  - `stopped` -- Stop hook fired for an `impl`/`plan` role workspace.
  - `blocked` -- an approval/question Notification fired.
  - `review-stopped` -- Stop hook fired for a `review` role workspace.
- **Orchestrator-produced (authoritative)** -- appended by the orchestrator
  itself alongside a `write-task` status change, never by the hook:
  - `kickoff`
  - `phase-advanced`
  - `review-dispatched`
  - `completed`
  - `paused`
  - `failed`
  - `changes-requested`
  - `reviewed`
  - `abandoned`
  - `merged`

## Record shape (`v: 1`)

Each line of `<workspace>.events.jsonl` is one JSON object:

```json
{ "v": 1, "event": "stopped", "ts": "2026-08-26T12:00:00Z" }
```

Orchestrator-authored events may carry extra fields (e.g. `review_head_sha`
on `review-dispatched`) but always carry `v` and `event`.

## Fold rule

`$CORE status` folds each task's events (collected across every workspace
whose index resolves to that `task_id`) in chronological order (`ts`, then
`event` as a tie-breaker) to derive the reported status. Malformed or
truncated lines, and lines with an unknown `v`, are **skipped with a
counted warning, never a crash** -- a corrupted final line (e.g. a
partially-flushed append) does not take down the fold.

The task record's `status` field is the source of truth for display; the
event log is evidence and history, read on-demand for a check-in or an
audit, not authored by the hook as a status override.

## Transition evidence -> event -> status

See the SKILL.md "State transition table" for the authoritative mapping
from live evidence, through the emitted event, to the resulting `status`.
This file documents only the event vocabulary and fold semantics; the
transition table itself is reproduced verbatim in SKILL.md, section 9, and
must not drift from it.
