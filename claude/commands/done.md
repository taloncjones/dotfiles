# /done - Finish work and clean up

Clean up after PR is merged: remove worktree, delete branch, optionally transition Jira to Done.

## Usage

- `/done` - Finish current work (from within the worktree)
- `/done <topic>` - Finish work for specific topic/ticket (from any directory)

## Instructions

**Step 1: Check for Atlassian plugin**

Try calling `getAccessibleAtlassianResources`:

- If successful: Jira integration is available
- If fails or no sites returned: Jira not available, skip Jira steps

**Step 2: Determine what to clean up**

If argument provided:

- If looks like Jira key (e.g., `PROJ-123`): find associated branch/worktree
- Otherwise treat as topic name and search worktrees

If no argument:

- Get current branch name
- Extract topic (and Jira key if present) from branch

**Step 3: Verify PR is merged**

```bash
gh pr view --json state,mergedAt
```

- If PR is merged: proceed
- If PR is open: ask "PR is still open. Close without merging?" (require explicit confirmation)
- If no PR exists: ask "No PR found. Continue with cleanup anyway?"

**Step 4: Transition Jira to Done (if available)**

If Jira is available AND branch contains a Jira key:

- Fetch ticket using `getJiraIssue`
- Get available transitions using `getTransitionsForJiraIssue`
- Find "Done" transition and execute using `transitionJiraIssue`
- Confirm: "PROJ-123 transitioned to Done"

If Jira not available: skip this step silently.

**Step 5: Navigate out of worktree**

If currently inside the worktree being deleted:

```bash
# Get the main worktree path
MAIN_WORKTREE=$(git worktree list | head -1 | awk '{print $1}')
cd "$MAIN_WORKTREE"
```

Tell user: "Changed directory to main worktree"

**Step 6: Remove worktree and branch**

```bash
# Get worktree path for this branch
WORKTREE_PATH=$(git worktree list | grep "$BRANCH_NAME" | awk '{print $1}')

# Remove worktree
git worktree remove "$WORKTREE_PATH"
```

If the worktree was on a **detached HEAD** (PR review worktree, e.g., `<repo>-pr<N>`):

- Skip branch deletion (there is no local branch to delete)
- Skip remote tracking prune (no remote branch was created)

Otherwise (normal branch worktree):

```bash
# Delete local branch
git branch -d "$BRANCH_NAME"

# Prune remote tracking branches
git fetch --prune
```

**Step 7: Report and show next steps**

PR review worktree (detached HEAD):

```
Cleaned up PR review: <repo>-pr<N>

[x] Worktree removed: ../<repo>-pr<N>

You're now in: /path/to/main/worktree (main branch)
```

With Jira:

```
Finished work on PROJ-123: <ticket summary>

[x] Jira transitioned to Done
[x] Worktree removed: ../<repo>-<PROJ-N>-<topic>
[x] Branch deleted: <user>/PROJ-123/<topic>
[x] Remote tracking pruned

You're now in: /path/to/main/worktree (main branch)
```

Without Jira:

```
Finished work: <topic>

[x] Worktree removed: ../<repo>-<topic>
[x] Branch deleted: <user>/<topic>
[x] Remote tracking pruned

You're now in: /path/to/main/worktree (main branch)
```

If other worktrees exist, list them:

```
Other active worktrees:
  ../<repo>-<topic-a> (<user>/<topic-a>)
  ../<repo>-<PROJ-N>-<topic-b> (<user>/PROJ-124/<topic-b>)

Use /switch to continue work, or /start for new work.
```

## Safety checks

- Never delete `main` or `master` branches
- Never remove the main worktree
- Require confirmation if PR is not merged
- Warn if there are uncommitted changes in the worktree

---

Related commands:

- `/status` - check if PR is merged first
- `/jira done` - just transition ticket (no cleanup)
- `/start` - begin new work
