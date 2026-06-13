---
name: weekly
description: Compose and (with confirmation) write my "Work Last Week / Work This Week" row on the weekly meeting Confluence page, from my merged/open PRs and active Jira. Edits only my row, never others. Per-project config in ~/.claude/reconcile/projects.json.
---

# Weekly

Compose my weekly-meeting update and write only my row. **Never auto-write**;
propose → confirm → write.

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
6. **Compose** the two cells as bare inline Jira smart links (titles auto-import;
   minimal notes). **Propose** them.
7. **Confirm → write only my row.** Enforce, do not assume:
   - Locate my row by `config.me` in the Updates table; **abort if 0 or >1** match.
   - Edit only my two cells; **diff the rendered body and assert no bytes change
     outside my row** before writing — abort if they do.
   - Capture the page version on read; if it changed on write (concurrent teammate
     edit), **abort and re-fetch** rather than overwrite.

## Notes

- HTML round-trip edit; preserve every other row and all non-Updates content.
- Best-effort: MCP down → `Jira: unavailable`; `gh` down → `GitHub: unavailable`.
