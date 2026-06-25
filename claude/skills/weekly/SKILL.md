---
name: weekly
description: Compose my "Work Last Week / Work This Week" row for the weekly meeting Confluence page from my merged/open PRs and active Jira, and output it as a copyable block by default. Writes to my row only if I explicitly ask. Per-project config in ~/.claude/reconcile/projects.json.
---

# Weekly

Compose my weekly-meeting update and, by default, output it as a copyable block
for me to paste myself. **Never auto-write.** Write to my row only on an explicit
request ("write it to my row"); the page is often edited live during the meeting,
so copy-paste is the safe default.

## Steps

1. **Gather (deterministic):** `bash ~/.claude/skills/lib/work-state.sh --repo "$PWD"`
   → `{project, config, github:{merged,open,...}}`. No config → stop with the
   helper's message.
2. **Work Last Week** = `github.merged` grouped **Merged**, plus `github.open`
   grouped **In review**.
3. **Work This Week** = my active Jira (`status_in_flight`,
   `assignee = currentUser()`, capped at `jira_query_cap`, warn if truncated),
   bucketed into `config.group_buckets`:
   - PRs/tickets needing hardware/bench/UAT → first bucket.
   - other in-flight → "In progress".
   - tickets labeled/flagged non-MVP or Blocked → last bucket.
   - unmatched → "In progress" (fallback).
     The page's "Top of Mind" only **weights ordering / annotates** — never filters or drops.
4. **Find the page:** search `config.confluence_space` for a title matching
   `config.weekly_page_pattern` with `{date}` = the **Monday** of the current week,
   format `YYYY-MM-DD`, local timezone.
   - 0 matches → report and stop (page creation is out of scope).
   - > 1 match → abort; list candidates for the user to disambiguate.
   - Read the **prior** Monday's page for format AND de-dup; if absent, skip de-dup and warn.
5. **De-dup "already reported"** by identity precedence: (a) Jira key, (b)
   repo-qualified PR `<org>/<repo>#<n>`, (c) exact title. Collapse multiple PRs for
   one ticket; treat a reopened PR listed last week as reported; match prior-week
   plain-text entries too.
6. **Compose** each cell as a short **executive summary**, not a list of links.
   Lead each line with the _outcome / theme_ in plain language; put Jira keys as
   trailing references in parentheses — e.g. "Shipped test-stand tooling: event
   schema + scanner UX (PROJ-123, PROJ-124)." Collapse related tickets into one
   themed line. Cap **~3-4 bullets per column**; summarize rather than enumerate
   when there are more. **Ticket-reference style depends on whether the line
   summarizes the ticket:** in a summary line, render keys as **plain text**
   (`PROJ-123`) — no smart link; only when a line just _lists_ a ticket without
   summarizing it should the key be an inline Jira smart link.
7. **Output — copyable block by default.** Present the two cells as clean,
   paste-ready text (markdown bullets, plain-text Jira keys), clearly labeled
   **Work Last Week** / **Work This Week**. This is the default and final step —
   do **not** write to the page unless I explicitly ask ("write it to my row").
   Rationale: the page is frequently edited live during the meeting, and the
   Confluence HTML round-trip is fragile (formatters/whitespace), so pasting
   myself is safer and avoids clobbering concurrent edits.
8. **Opt-in write (only when I explicitly ask).** Write only my row; enforce,
   do not assume:
   - Locate my row by `config.me` in the Updates table; **abort if 0 or >1** match.
   - Splice only my two cells into the **raw** fetched page body (never a
     formatter-touched copy); **diff and assert no bytes change outside my row**
     before writing — abort if they do.
   - Capture the page version on read; if it changed on write (concurrent teammate
     edit), **abort and re-fetch** rather than overwrite.

## Notes

- Default output is copy-paste; only the opt-in write (step 8) touches Confluence.
- For the opt-in write: operate on the **raw fetched body**, not a formatter-
  touched staging file — HTML formatters silently rewrite other rows' whitespace,
  which would change bytes outside my row. Preserve every other row and all
  non-Updates content; never paste raw HTML into chat for review.
- Best-effort: MCP down → `Jira: unavailable`; `gh` down → `GitHub: unavailable`.
