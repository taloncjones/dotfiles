# /switch - Switch between worktrees

List and switch Claude's working directory to a different worktree.

## Usage

- `/switch` - List worktrees and pick one
- `/switch <name>` - Switch to worktree matching name (partial match)

## Examples

```
/switch
/switch <topic>
/switch PROJ-123
/switch 2
```

## Instructions

**Step 1: Check for Atlassian plugin**

Try calling `getAccessibleAtlassianResources`:

- If successful: Jira integration is available
- If fails or no sites returned: Jira not available, skip Jira column

**Step 2: List worktrees with context**

```bash
git worktree list
```

For each worktree, gather:

- Path
- Branch name (or "detached HEAD" if no branch)
- Whether it's a PR review worktree (detached HEAD with `<repo>-pr<N>` folder naming)
- Jira key (extracted from branch, if present)
- Jira status (if Atlassian plugin available AND Jira key found)
- Uncommitted changes (`git -C <path> status --porcelain`)
- Commits ahead of main

Display as numbered table:

With Jira:

```
Worktrees:

| # | Directory                              | Branch                      | Jira                  | Changes |
|---|----------------------------------------|-----------------------------|-----------------------|---------|
| 1 | <repo>                                 | main                        | -                     | clean   |
| 2 | <repo>-<PROJ-N>-<topic-a>              | <user>/PROJ-123/<topic-a>   | PROJ-123 In Progress  | clean   |
| 3 | <repo>-<PROJ-N>-<topic-b>              | <user>/PROJ-124/<topic-b>   | PROJ-124 In Progress  | 2 files |
| 4 | myapp-infra-pr7                        | PR Review (detached)        | -                     | clean   |

Current: <repo> (main)

Enter number, name, or Jira key to switch:
```

For PR review worktrees (detached HEAD with `<repo>-pr<N>` naming pattern), display "PR Review (detached)" in the Branch column instead of a branch name.

Without Jira:

```
Worktrees:

| # | Directory                              | Branch                  | Changes |
|---|----------------------------------------|-------------------------|---------|
| 1 | <repo>                                 | main                    | clean   |
| 2 | <repo>-<topic-a>                       | <user>/<topic-a>        | clean   |
| 3 | <repo>-<topic-b>                       | <user>/<topic-b>        | 2 files |
| 4 | myapp-infra-pr7                        | PR Review (detached)    | clean   |

Current: <repo> (main)

Enter number or name to switch:
```

**Step 3: Match selection**

If argument provided, match against:

1. Worktree number (e.g., "2")
2. Directory name (partial match, e.g., "widget")
3. Branch name (partial match)
4. Jira key if present (e.g., "PROJ-123")

If no argument, prompt user to pick.

**Step 4: Switch working directory**

```bash
cd <worktree-path>
```

This changes Claude's working directory for subsequent commands.

**Step 5: Confirm switch and show context**

With Jira:

```
Switched to: ~/Git/work/<topic>

Branch: <user>/PROJ-123/<topic>
Jira:   PROJ-123 - <ticket summary> (In Progress)
        https://<site>.atlassian.net/browse/PROJ-123

Status: N commits ahead of main, working tree clean

Last commit: <scope>: <summary> (<time> ago)
```

Without Jira:

```
Switched to: ~/Git/work/<topic>

Branch: <user>/<topic>
Status: N commits ahead of main, working tree clean

Last commit: <scope>: <summary> (<time> ago)
```

---

Related commands:

- `/start` - create new worktree with optional Jira integration
- `/review-pr` - review a PR (creates detached HEAD worktree)
- `/status` - detailed status of current worktree
- `/done` - cleanup worktree after PR merge
