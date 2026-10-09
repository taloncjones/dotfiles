# Jira status writeback (SKILL.md section 10)

## 10. Jira status writeback (Jira-kind tasks only)

The director keeps the ticket's Jira status in step with its own task
state, so `reconcile` has drift to fix at the source rather than after the
fact. It writes the status at two points it already owns, plus the existing
tail:

- **Kickoff** (`kind == "jira"`) -> transition the ticket to **In Progress**.
  Work actually starts here (worktree + worker spun up).
- **Review dispatch** -> transition to **In Review**. "In Review" means the
  moment the fresh reviewer worker is dispatched on the branch -- the
  director's own hook point -- NOT the human posting a PR (the
  director never posts PRs; if PR-posting is ever the desired trigger
  instead, that transition moves to the `ship`/PR flow, out of this loop).
- **Merge** -> **Done**, already handled by `/post-merge`.

Rules (these are outward-facing writes, so treat them carefully):

- **Existing authorization required.** A local task designation does not by itself
  authorize third-party writes; preserve any standing authorization already given.
- **Jira-kind only.** Bare repo todos (`td-...`) have no Jira status --
  skip.
- **Resolve the transition dynamically.** Names/IDs like "In Progress"/"In
  Review" are workflow-specific; use `getTransitionsForJiraIssue` and pick
  the offered transition, never a hard-coded id. If the target status is
  not reachable from the current one, no-op gracefully and note it -- do
  not force or error.
- **Idempotent.** If the ticket is already in the target status, do
  nothing.
- **Announced.** Surface each transition -- it is an outward mutation of the
  user's own assigned ticket, routine to automate at kickoff/review, but
  visible.
- A failed/absent transition never blocks the local task-state advance; the
  internal record moves regardless, and `reconcile` remains the backstop.
