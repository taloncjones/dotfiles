---
name: brief
description: Use for a forward-looking morning brief - what to focus on today. Aggregates time-relevant todos across all registered repos and joins them with PRs awaiting your action and your active Jira tickets. Trigger on "morning brief", "what's on today", "daily brief", "what should I work on".
---

# Brief

A forward-looking daily brief. It joins three sources into one prioritized,
de-duplicated view:

1. Time-relevant todos (deterministic) - from the `todos` skill.
2. PRs awaiting your action - via `gh`.
3. Active Jira - via the Atlassian MCP.

Each source is best-effort and independent: if one is unavailable, say so and
continue. The todo half is the always-present core.

## Steps

### 1. Todos (always)

Run the deterministic aggregator:

```
~/.claude/skills/todos/scripts/todos.sh brief
```

This prints buckets: Overdue, Today, Flagged (high priority), Due soon, Stale.
If it prints "No repos registered", tell the user to run `todos.sh register`
inside each repo they want included, then stop (nothing to join).

### 2. GitHub PRs (best-effort)

Two separate groups - do not conflate them:

- Awaiting my review: `gh search prs --review-requested=@me --state=open --json repository,number,title,url`
- My open PRs (in flight): `gh search prs --author=@me --state=open --json repository,number,title,url,isDraft`

If `gh` errors or is unauthenticated, emit `GitHub: unavailable` and continue.

### 3. Jira (best-effort)

Via the Atlassian MCP, run JQL:

```
assignee = currentUser() AND statusCategory != Done ORDER BY priority DESC, updated DESC
```

Cap at 20 results; note if truncated. This intentionally includes backlog/
blocked work. If the MCP is unavailable, emit `Jira: unavailable` and continue.

### 4. Synthesize

Print one brief in this order: Overdue -> Today -> Flagged (high priority) ->
Awaiting my review -> My open PRs -> Active Jira -> Due soon -> Stale, with
`high` todos at the top of their bucket.

De-duplicate (todo is primary):

- Detect Jira keys in a todo's title/body with `\b[A-Z][A-Z0-9]+-[0-9]+\b`.
- Detect PRs as `#<n>` or a `github.com/<org>/<repo>/pull/<n>` URL; qualify a
  bare `#<n>` with the todo's own repo (`<org>/<repo>#<n>`).
- If a todo references a PR/Jira that also appears in the live results, render
  one line under the todo's bucket and append the live PR/Jira status; remove
  those items from the standalone PR/Jira sections.
- The todo's date-driven bucket decides position; live status is annotation only.

Example collapsed line:
`acme-widgets  Confirm PR #42 on bench  due 2026-06-06 [high]  -  PR acme/widgets#42 (open, review pending)  -  PROJ-123 (In Progress)`

## Notes

- Read-only. The brief never writes todos and never mirrors Jira into `.todos/`.
- Delivery is on-demand only. There is no scheduled/push variant; a future cron
  job could call this skill unchanged.
