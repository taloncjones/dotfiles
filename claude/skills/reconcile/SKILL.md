---
name: reconcile
description: Reconcile my git/PR reality against Jira and fix tracking drift (untracked PRs, stale statuses, sprint hygiene) with propose-confirm-apply. Use when tidying my tracked work, before a sprint boundary, or when asked "what needs cleanup/action". Per-project config in ~/.claude/reconcile/projects.json.
---

# Reconcile

Surface and (with confirmation) fix drift between my PRs and Jira for the current
project. **Never auto-apply.** Propose → confirm (batched where low-risk) → apply.

## Steps

1. **Gather (deterministic):** `bash ~/.claude/skills/lib/work-state.sh --repo "$PWD"`
   → JSON `{project, config, github:{merged,open,truncated,gh_ok,partial,errors}}`.
   Open PRs carry `body`, `mergeable`, and `statusCheckRollup` (used by the
   detections below).
   - No config block → print the helper's "no project config" message and stop.
   - `gh_ok:false` → print `GitHub: unavailable` and continue with Jira-only checks.
   - `partial:true` → name each `errors[]` `{repo,source}` and **block mutations for
     every GitHub-derived category** (untracked-PR, review-ready, merged→transition);
     Jira-only categories may still apply. Never treat a failed repo as "no PRs".
2. **Pull Jira** via Atlassian MCP (`searchJiraIssuesUsingJql`, `config.cloud_id`),
   **one capped query per finding category**, each with
   `maxResults = config.jira_query_cap`. Queries (status names come from config, never hardcoded):

   | Finding category                   | JQL (skeleton)                                                                                                             |
   | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------- |
   | merged→transition, in-flight-no-PR | `assignee = currentUser() AND project IN (allowed_jira_projects) AND statusCategory != Done`                               |
   | review-ready PR on blocked/todo    | `key IN (<keys referenced by open PRs>) AND status IN (status_blocked, status_todo)`                                       |
   | sprint-rolled To-Do                | `assignee = currentUser() AND status IN (status_todo) AND project IN (allowed_jira_projects)` (then sprint-history filter) |
   | terminal-in-active-sprint          | `project IN (allowed_jira_projects) AND status IN (status_done) AND sprint IN openSprints() AND assignee = currentUser()`  |

   **Truncation rule:** a query is truncated when returned issue count
   `>= jira_query_cap` (or the response's `total` exceeds what was returned). On
   truncation, warn and **block every mutation whose finding category depends on
   that query** — never act on a partial result.

3. **Reconcile** into findings; each maps to exactly one action bucket:

   | Finding                                | Detection                                                                              | Bucket                       |
   | -------------------------------------- | -------------------------------------------------------------------------------------- | ---------------------------- |
   | Merged PR, ticket not in `status_done` | PR mergedAt set; ticket status ∉ done                                                  | transition                   |
   | Review-ready PR on blocked/todo ticket | PR not draft AND checks not failing AND not merge-conflicted AND ticket ∈ blocked/todo | transition or needs-reviewer |
   | In-flight ticket, no live PR           | ticket ∈ in_flight; no open/merged PR references its key                               | needs-info (report only)     |
   | Untracked PR                           | open PR; no key from `allowed_jira_projects` in branch/title/body                      | backfill-ticket              |
   | Sprint-rolled To-Do                    | ticket ∈ todo; in ≥ `groom_sprint_threshold` distinct past sprints, untouched          | sprint-groom                 |
   | Terminal ticket in active sprint       | ticket ∈ done AND in the active sprint                                                 | sprint-groom (remove)        |

   Jira-key regex `\b[A-Z][A-Z0-9]+-\d+\b`, filtered to `allowed_jira_projects`
   (monorepo-safe). "Review-ready" = non-draft AND not failing-checks AND not
   merge-conflicted; reviewer/approval state is annotation only. Read status
   category names from config (`status_done`, `status_in_flight`,
   `status_blocked`, `status_todo`) — never hardcode workflow names.

4. **Local-only stale-worktree check (report-only):** for each `git worktree list`
   entry, mark "stale" only if its branch is merged into `origin/<default_base>`,
   the worktree is clean, and HEAD is not detached; otherwise list as "review
   manually". **Never delete in v1.**
5. **Present triage** grouped by action: close · transition · sprint-groom ·
   needs-reviewer · needs-info · backfill-ticket — recommendation per item.
6. **Confirm → apply.** Allowed mutations and their gates (do not exceed this set):

   | Mutation               | Required evidence                                                                                                                                                | No-op when missing      |
   | ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------- |
   | Transition ticket      | merged PR confirmed AND target transition offered by `getTransitionsForJiraIssue`                                                                                | skip + report           |
   | Add to active sprint   | exactly ONE active sprint on `board_id` AND `customfield_10020` in editmeta                                                                                      | skip + report           |
   | Create backfill ticket | untracked PR title/body; created in `jira_project`; sprint rule if non-To-Do; **title per `## Jira` in global CLAUDE.md (exec-summary, plain-language outcome)** | confirm each            |
   | Remove from sprint     | ticket terminal or todo-rolled; sprint membership read                                                                                                           | skip if no sprint field |
   | Create issue link      | both keys resolve                                                                                                                                                | skip if either missing  |

   **Sprint rule:** a ticket set to In Progress/In Review/Done must carry the
   single active sprint. No active sprint / multiple / closed-or-wrong board /
   missing `customfield_10020` / cross-project / already in another active sprint →
   **skip with an explicit reason**. Never mutate when required evidence is missing
   or the source query was truncated. All actions run as the authenticated CLI user.

## Notes

- Best-effort: MCP down → print `Jira: unavailable`, run only the GitHub/worktree half.
