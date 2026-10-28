# Away mode

Read when the owner sets `/afk`, when `next` prints an `away:` line, or when
the owner returns. Away mode keeps the director from opening an
`AskUserQuestion` prompt that nobody answers. An open prompt holds every peer
wake (the director handles none until it is answered), so one question stalls
every task. While the mode is on, each owner question goes to a durable queue,
the task that needs the owner waits, and the other tasks keep moving.

State lives in the repo state folder (`state-layout.md`: `away.json`,
`asks.jsonl`), so a rollover or compaction keeps the flag and the queue.
`$CORE` and the fenced flags are as in section 4; every verb below is fenced
and prints `owner: stale-fence` (exit 1, no write) under an old fence.

## Set and clear

- Set: `/afk`, or a launch with `director --afk` (preflight first, then
  `/afk`). Run `python3 "$CORE" away --repo-slug <slug> --session <id> --fence <fence> --on`.
  It prints `away: on since <ts>, <n> asks queued`. A repeat keeps the first
  `since`.
- Clear: `/back`, or the first owner chat message (a user turn that is not a
  `<cross-session-message>`, a task notification, a watch line or the
  rollover successor's launch prompt `resume director`, which is the
  automatic rollover and never the owner). Run
  `away ... --off` before anything else in that turn. It prints
  `away: off, <n> asks queued`, then one JSON line per live ask, oldest first,
  with `task_status`. A repeat lists the same asks.
- An `away:` line reading `unreadable (treated as on)` means `away.json` is
  damaged. Mode is on; `away --on` or `--off` rewrites it.

## While on

- Never call `AskUserQuestion`. Queue every owner question with
  `python3 "$CORE" queue-ask --repo-slug <slug> --session <id> --fence <fence> (--task <task-id> | --repo-wide) --question '<text>' [--option <label>]... [--recommend <label>]`.
  That includes a work-repo merge prompt, a gated post prompt and a
  budget-spent prompt: queued with options and a recommendation, never skipped.
  The question may run to 2000 characters over several lines: a gated post
  puts its full draft text in the question, unchanged, so the return batch
  shows it verbatim and the post guard accepts the answer.
  Then end the turn; do not wait.
- A check-in `next: ask` line becomes a printed `next: run ... queue-ask` line
  with `--action` and the template as the question. Run it as printed. A task
  whose ask is already queued prints `next: queued <id>` instead.
- A repeat `queue-ask` for a task prints `already queued`; a new check-in ask
  for a different action supersedes the old one. Repo-wide asks match by exact
  question text.
- Actions that already need no ask (personal-repo merges, verifier-confirmed
  repairs, infrastructure re-runs, automatic re-pins) proceed as today.

## Return batch

1. `away --off`, then `next`.
2. Drop stale asks without asking: `drop-ask --id <id> --reason stale`. An
   ask with a task is stale when its `task_status` is null or terminal, or its
   `action` is set and differs from the task's `action=` in this `next`. A
   repo-wide ask is never stale.
3. Withdraw an ask (`--reason withdrawn`) only when a live decision in the
   `[INFO] herdr decisions` block with the same scope (same task, or repo-wide
   for a repo-wide ask) already answers it. A retired decision never withdraws
   a fresh ask.
4. Ask the rest four per `AskUserQuestion` call, oldest first, recommendation
   first. Compose two to four options for a check-in ask (it carries none).
5. Record each answer at once:
   `answer-ask --id <id> --text '<decision>'`. It writes one decision that
   names its ask, which closes the ask.
6. Repeat `away --off` and the batch until it lists none, then handle the
   owner's message.

## Failure paths

- Lease change: only the current fence holder records an answer. If
  `answer-ask` prints `owner: stale-fence`, the answer is void; yield
  read-only (section 1) and let the new holder ask the live ask again.
- Draft lost: the post guard keys a draft to its session and prunes it after
  24 hours. After a rollover or a prune, the post guard refuses the answer
  and the director registers the draft again and re-drafts. Failing closed.
- Lost ask: a check-in ask lost mid-append reappears as a `queue-ask` line on
  the next `next`. A composed ask is regenerated when the director reaches the
  same decision point from task state. A rerun after lost output prints
  `already queued`.
- Answer given but not yet recorded when the session ends: the ask is still
  live and is asked again.
- Cleanup: files stay after `--off`; delete `away.json` and `asks.jsonl` by
  hand only with no director running.
