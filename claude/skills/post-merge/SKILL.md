---
name: post-merge
description: Use after a PR is merged to tear down its worktree/branch and sync its Jira ticket. Removes the merged branch's git worktree (handling submodule-bearing worktrees), deletes the local + lingering remote branch, sweeps co-review leftovers, then transitions the linked Jira issue to Done, assigns it to me, adds it to the current sprint, sets its epic, and posts a resolution comment. Propose-confirm-apply.
---

# Post-Merge Cleanup (worktree + branch + Jira)

Run this once a PR is merged. It does the teardown and Jira hygiene that a merge
leaves behind. Everything is **propose-confirm-apply**: gather state, show the
plan, get a yes, then act. Never destroy or transition before confirmation.

## Target resolution

- If a PR number/URL was passed, use it.
- Else use the PR for the current branch (`gh pr view --json ...`).
- **Confirm it is actually merged** (`state == "MERGED"`, `mergedAt` set). If it
  is not merged, stop and say so — this skill is teardown, not finishing. For
  unmerged work use `/done`.

```bash
gh pr view <n> --json number,state,mergedAt,headRefName,baseRefName,title,body,url
```

## Step 1 — Gather (read-only)

- **Branch + worktree:** `git worktree list` → find the worktree holding the
  PR's `headRefName`. Note its path and whether the working tree is clean
  (`git -C <wt> status --short`). Refuse to remove a dirty worktree without an
  explicit OK.
- **Self-teardown check:** is the session anchored INSIDE the worktree being
  removed? If so, the git half cannot finish from this session:
  worktree-isolation hooks block git aimed at the shared checkout, and
  removing your own cwd strands the shell mid-teardown.
  - Worktree created by `EnterWorktree` this session: plan the entire git half
    as `ExitWorktree(action: "remove")` — it deletes the directory AND the
    local branch and re-anchors the session. Only the remote-branch deletion
    (allowed in-session) and the Jira half remain.
  - Any other worktree: plan the remote-branch deletion in-session, and hand
    `git worktree prune` + `git branch -D` to the user, stated UP FRONT in the
    Step-2 proposal, to run OUTSIDE this session -- a plain terminal, or a
    session anchored at the main checkout. `!`-prefix does NOT work: it runs
    inside this session's shell, so the same isolation hook blocks it. Do NOT
    attempt them yourself and do NOT `rm -rf` the session's own cwd.
- **Remote branch:** `git ls-remote --heads origin <headRefName>` — GitHub
  auto-deletes the branch on merge in many repos, so this is often already gone.
- **Co-review leftovers (if you ran co-review):** `refs/coreview/<n>`,
  `/tmp/coreview-pr-<n>*` worktrees, temp verdict files.
- **Jira key:** scan the PR title, **body**, commit messages, and branch name
  for `[A-Z]+-\d+`. Bodies matter — squash-merge appends
  the PR description, so the key is often only there. If none found, skip the
  Jira half and say so.

## Step 2 — Propose

Show a concise plan: which worktree/branch get removed, whether the remote
branch needs deleting, what leftovers get swept, and — if a key was found — the
Jira issue's current status and the exact changes (→ Done, assignee, sprint,
epic, comment). Then confirm. Default is "do all".

## Step 3 — Apply teardown

Order matters: remote branch, then local branch, then the worktree LAST —
never delete the directory while anything still needs to run from it. If the
Step-1 self-teardown check fired, this whole block runs via `ExitWorktree` or
the user's `!` commands instead — skip straight to the parts it left you.

```bash
# Remote branch only if it lingered (usually already auto-deleted):
git ls-remote --heads origin "<headRefName>" | grep -q . \
  && git push origin --delete "<headRefName>"

# Local branch: -D, not -d. A squash-merged branch's commits are NOT ancestors
# of the base, so -d refuses ("not fully merged") even though the PR is merged.
# Only force-delete after Step 0 confirmed state == MERGED.
git branch -D "<headRefName>"

# Worktree removal, LAST. Plain `git worktree remove` FAILS on a worktree that
# contains submodules ("working trees containing submodules cannot be moved or
# removed"). Fall back to rm -rf + prune in that case.
git worktree remove "<wt>" 2>/dev/null \
  || { rm -rf "<wt>" && git worktree prune; }

# Co-review leftovers, if any:
git update-ref -d refs/coreview/<n> 2>/dev/null || true
git worktree remove --force /tmp/coreview-pr-<n>* 2>/dev/null || rm -rf /tmp/coreview-pr-<n>*
```

Do not touch worktrees for _other_ PRs. Verify after: the branch and worktree
no longer appear in `git branch --list` / `git worktree list`.

## Step 4 — Jira sync (if a key was found)

All via the Atlassian MCP. Read the per-project config from
`~/.claude/reconcile/projects.json` (the same config `reconcile`/`weekly` use):
`cloud_id` is the Jira cloudId, `jira_account_id` is my accountId,
`default_epic` is the epic to file under, and `sprint_board_name` /
`sprint_board_id` identify the team's sprint board. No config block → show the
discovered values and confirm before writing.

1. **Transition to Done.** `getTransitionsForJiraIssue`, then pick the
   transition whose `to.statusCategory.key == "done"` and name is `Done` (do not
   hardcode the transition id — it varies per project, so discover it). Skip if
   already in a done category.
2. **Assignee = me.** `editJiraIssue` `assignee: {accountId: <jira_account_id>}`
   (if not in config, resolve via `atlassianUserInfo` / `lookupJiraAccountId`).
3. **Sprint + epic — copy from a sibling, don't guess.** Different teams run
   different boards, so `openSprints()` across the whole project returns the
   wrong board's sprint. Instead read 1-2 of the user's _recent tickets in the
   same area_ (e.g. `key in (<recent siblings>)` or
   `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`)
   and copy:
   - `customfield_10020` → the entry with `state == "active"` (set the integer
     sprint id, e.g. `customfield_10020: 1234`).
   - `parent` → the shared epic key.
     The discovered epic should normally match `default_epic` (e.g. `PROJ-123`)
     and the active sprint should live on `sprint_board_name`
     (`sprint_board_id`, e.g. board id 42). If the area is ambiguous, show the
     discovered epic/sprint and confirm before writing.
     Apply in one `editJiraIssue`: `{assignee, customfield_10020, parent}`.
     Note: `editJiraIssue` echoes a huge editmeta blob — don't parse it; verify
     with a follow-up `getJiraIssue` on `[status, assignee, parent, customfield_10020]`.
4. **Resolution comment.** `addCommentToJiraIssue`, markdown. Reflect **current
   state** with the PR link and a one-line "what shipped" — not a changelog of
   internal commits. Keep the issue _description_ as the durable problem/solution
   spec; resolution events go in comments. No emojis.

## Notes

- Propose-confirm-apply. One pass, no loop.
- Teardown is destructive — confirm the worktree is clean and the PR is merged
  before removing anything.
- If only the git half or only the Jira half applies, do that half and say which
  you skipped.
- Sprint hygiene: a Done ticket outside the active sprint won't show in sprint
  reports — that's why step 4.3 adds it. Related: the `reconcile` skill does the
  same drift-fix across many tickets at once.
