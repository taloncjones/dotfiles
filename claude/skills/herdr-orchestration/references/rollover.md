# Roll over to a new pane (SKILL.md section 1a)

4. `rollover: handed over to pane <p> ...` (exit 0): this session is fenced
   out. The verb stopped this session's watch; on a `watch:` line that says
   `unknown` or `not scanned`, TaskStop the watch task. Make
   `herdr pane close "$HERDR_PANE_ID"` your last tool call; it ends this
   Claude process. The transcript stays on disk.
5. `rollover: no ack ... this session keeps the lease (fence <n>)`: the new
   pane is closed and the marker removed. Use fence `<n>` from now on, say
   so in this turn's message, and retry later or ask the human.
6. `rollover: rollover in progress for pane <p>`: an earlier rollover is
   still waiting. Do not retry until it expires (two minutes); a retry then
   closes that pane and starts over.
7. `rollover: lease moved without a handover ack` or `owner: stale-fence`:
   this session no longer holds the lease. Stop its watch per section 1 step
   7 and run the section-1 preflight, which reports the holder.
   `rollover: carry notes not saved; this session keeps the lease`: the new pane
   is closed; fix `decisions.jsonl` and roll over again.

If the Bash call times out or is interrupted, run the same `rollover`
command again: it reports a handover that completed meanwhile, refuses
while the first attempt is still pending, and cleans up an expired one.

In the new pane, the `director_rollover` SessionStart hook runs the core's
`adopt-rollover`, which takes the lease through the marker (fence + 1, the
wake socket moves to the new process) and appends an `adopted` line to
`<slug>/rollover.jsonl`. Its `[INFO] herdr director rollover: lease handed
over from session <old> (pane <p>).` block is the new director's startup
report: follow its `Next:` line, act on its `carried:` lines, arm the
backstop (its `watch:` line says none exists), and run a section-4 check-in
before any dispatch. On a `[WARNING]` block, or no block, run the section-1
preflight; its `claim-owner` adopts through the same marker while it is
valid, and on `BUSY` stop and ask the human.

Every director start (`startup`, `resume`, `clear`, `compact`) also gets the
`[INFO] herdr decisions` block from the core's `decisions` verb; see
"Decisions log" in section 4.

A `/clear` or compaction in place still keeps the lease: the same hook runs
`resume-owner` and prints the `lease re-established in place` block. Nothing
types `/clear` or a resume line into any pane.
