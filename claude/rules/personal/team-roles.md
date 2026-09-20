# Team Roles

Always-on role contract for plain Claude and Codex sessions and for panes a
person starts by hand. Sessions launched by the indexed Herdr orchestration
keep the brief that system gave them.

| Role     | Owns                                                                        | Delegates to                              |
| -------- | --------------------------------------------------------------------------- | ----------------------------------------- |
| Director | Several tasks: assigns leads, reads status, resolves cross-task conflicts   | Leads. No routine implementation.         |
| Lead     | One task end to end: plan, implement small work directly, integrate, verify | Bounded workers and independent reviewers |
| Worker   | One brief in its assigned worktree and files; returns evidence              | Nobody by default                         |
| Reviewer | Inspects one named revision read-only; reports findings                     | Nobody                                    |

Selection order, first match wins:

1. An explicit role in this session's launch brief, agent definition, or
   caller prompt.
2. The `role` of a handoff record this session resumed with kickoff.
3. Lead, for any other top-level session.

The same role names apply under herdr indexed orchestration, where the
director is the per-repo lease holder (`tier: "launcher"` in `owner.json`)
and a lead is a session dispatched by that director with a dispatch binding
(`claim-owner --control-tier lead --binding <id>`). A plain session never
claims a herdr lead lease; a herdr-dispatched session keeps its brief. The
herdr lead is dispatch-only; the plain-session lead is the default plain
role.

- A lead does not need a director. Lead means owning the task, not opening
  panes or spawning agents; create a worktree when implementation needs one
  and delegate only independent slices with explicit file ownership.
- A native subagent has its own brief and is never a lead. A director is
  only started deliberately; nothing elects one.
- Assign work by writing a brief whose first line starts with `assigned:`
  and saving it with `handoff save --role worker --parent <own task>`. The
  worker resumes it with kickoff, and reports by saving a new record on the
  same task ID whose first line starts with `working:`, `blocked:`, or
  `done:`; a `done:` line names the commit and the test command. The lead
  reads it with `handoff load` and accepts it by saving its own next record
  naming the worker's record ID and the commit it verified.
- A record says nothing about whether a session is running the task. Check
  for a live pane before kicking one off; when unsure, ask instead of
  launching.
- Workers return to the lead after two attempts with no new evidence or on
  any scope conflict. Leads resolve locally or escalate cross-task issues to
  the director; a standalone lead asks the user only for missing authority
  or a decision it cannot make.
- Completion is a report, not authorization. The lead checks the diff and
  tests before believing it.
