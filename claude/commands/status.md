# /status - Check current work status

Quick overview of current branch, optional Jira ticket, and PR status.

## Usage

- `/status` - Show status of current worktree/branch

## Instructions

**Step 1: Check for Atlassian plugin**

Try calling `getAccessibleAtlassianResources`:

- If successful: Jira integration is available
- If fails or no sites returned: Jira not available, skip Jira section

**Step 2: Gather git and worktree context**

```bash
# Current branch
git branch --show-current

# Current worktree and list of all worktrees
git worktree list

# Commits ahead/behind main
git rev-list --left-right --count origin/main...HEAD

# Check if branch is pushed and up to date with remote
git rev-parse --abbrev-ref @{upstream} 2>/dev/null
git rev-list @{upstream}..HEAD --count 2>/dev/null  # unpushed commits
```

Show worktree context if multiple worktrees exist:

```
Worktree: <topic> (1 of 3)
```

**Step 3: Extract Jira ticket from branch (if Jira available)**

Parse branch name for Jira key pattern (e.g., `<user>/<PROJ-###>/topic` -> `PROJ-###`)

If Jira key found AND Jira is available:

- Fetch ticket details using `getJiraIssue`
- Get ticket summary and status

**Step 4: Check PR status**

```bash
gh pr view --json number,title,state,url,mergedAt,mergeable 2>/dev/null
```

**Step 5: Display status**

With Jira:

```
Branch:   <user>/<PROJ-###>/<topic>
          N commits ahead of main, M behind

Jira:     PROJ-123 - <ticket summary>
          Status: In Progress
          https://<site>.atlassian.net/browse/PROJ-123

PR:       #<number> - <scope>: <summary>
          Status: Open (mergeable)
          https://github.com/<org>/<repo>/pull/<number>
```

Without Jira:

```
Branch:   <user>/<topic>
          N commits ahead of main, M behind

PR:       #<number> - <scope>: <summary>
          Status: Open (mergeable)
          https://github.com/<org>/<repo>/pull/<number>
```

**Step 6: Show warnings and suggestions**

Show relevant warnings/suggestions (no prompts, just info):

- If uncommitted changes: "Uncommitted changes - use /commit"
- If branch is behind main: "Branch is M commits behind main - use /rebase"
- If branch is not pushed: "Branch not pushed"
- If branch has unpushed commits: "N commits not pushed - CI is running against stale code"
- If PR is merged: "PR merged - use /done to clean up"
- If PR has conflicts: "PR has conflicts - use /rebase"
- If Jira available and still "To Do": "Jira still To Do - use /jira progress"

---

Related commands:

- `/jira` - ticket operations (comment, transition, assign)
- `/checks` - detailed CI status
- `/rebase` - sync with main
- `/pr` - create pull request
- `/done` - cleanup after merge
