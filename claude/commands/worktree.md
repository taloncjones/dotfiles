# /worktree - Git worktree management

Create and manage git worktrees for parallel development.

## Usage

- `/worktree` - Create new worktree with auto-generated name
- `/worktree <name>` - Create worktree with specific branch name
- `/worktree for pr <url-or-shorthand>` - Create worktree for PR review
- `/worktree for <PROJ-N>` - Create worktree for Jira ticket
- `/worktree list` - List existing worktrees
- `/worktree remove <name>` - Remove a worktree

## Naming Convention

All worktree commands (`/worktree`, `/start`, `/review-pr`, `/done`, `/switch`) follow this naming convention for the worktree folder:

| Context     | Folder name               | Example                      |
| ----------- | ------------------------- | ---------------------------- |
| PR review   | `<repo>-pr<N>`            | `myapp-infra-pr7`            |
| Jira ticket | `<repo>-<PROJ-N>-<topic>` | `myapp-PROJ-123-add-widget`  |
| Topic only  | `<repo>-<topic>`          | `myapp-feature-tests`        |
| No context  | `<repo>-worktree<N>`      | `myapp-worktree1` (fallback) |

## Create Worktree

**Step 1: Fetch latest**

```bash
git fetch origin
```

**Step 2: Determine default branch**

```bash
DEFAULT_BRANCH=$(git remote show origin 2>/dev/null | grep "HEAD branch" | cut -d: -f2 | xargs)
if [ -z "$DEFAULT_BRANCH" ]; then
    if git branch -r | grep -q "origin/main"; then
        DEFAULT_BRANCH="main"
    else
        DEFAULT_BRANCH="master"
    fi
fi
```

**Step 3: Determine repo name**

```bash
REPO_NAME=$(basename "$(git rev-parse --show-toplevel)")
```

**Step 4: Determine name and mode**

If argument starts with `for pr`:

- Parse the PR reference (URL, `owner/repo#N`, or just `N`)
- Extract repo name and PR number
- `FOLDER_NAME="<repo>-pr<N>"` (e.g., `myapp-infra-pr7`)
- Fetch PR head SHA: `gh pr view <N> --repo <owner>/<repo> --json headRefOid -q .headRefOid`
- Mode: **detached HEAD** on PR commit

If argument starts with `for` followed by a Jira key (e.g., `for PROJ-123`):

- Extract the Jira key
- Fetch ticket summary if Atlassian plugin available, slugify into topic
- `FOLDER_NAME="${REPO_NAME}-<PROJ-N>-<topic>"` (e.g., `myapp-PROJ-123-add-widget`)
- `BRANCH_NAME="<user>/<PROJ-N>/<topic>"` per branch convention
- Mode: **tracking branch**

If argument is a plain name:

- `FOLDER_NAME="${REPO_NAME}-<name>"`
- `BRANCH_NAME="<name>"`
- Mode: **tracking branch**

If no argument (fallback):

```bash
# Find next available worktree number
HIGHEST=$(git worktree list | grep -oE "${REPO_NAME}-worktree[0-9]+" | sed "s/${REPO_NAME}-worktree//" | sort -n | tail -1)
NEXT=$((${HIGHEST:-0} + 1))
FOLDER_NAME="${REPO_NAME}-worktree$NEXT"
BRANCH_NAME="worktree$NEXT"
```

Mode: **tracking branch**

**Step 4: Create worktree**

For **detached HEAD** mode (PR review):

```bash
WORKTREE_PATH="../$FOLDER_NAME"
git worktree add --detach "$WORKTREE_PATH" <HEAD_SHA>
```

For **tracking branch** mode:

```bash
WORKTREE_PATH="../$FOLDER_NAME"
git worktree add --track -b "$BRANCH_NAME" "$WORKTREE_PATH" "origin/$DEFAULT_BRANCH"
```

**Step 5: Report**

For PR review:

```
Created worktree at: ../<repo>-pr<N>
Detached HEAD at: <HEAD_SHA_SHORT>
cd ../<repo>-pr<N> to start reviewing
```

For Jira ticket:

```
Created worktree at: ../<repo>-<PROJ-N>-<topic>
Branch: <user>/<PROJ-N>/<topic> (tracking origin/main)
cd ../<repo>-<PROJ-N>-<topic> to start working
```

For plain name / fallback:

```
Created worktree at: ../<repo>-<name>
Branch: <name> (tracking origin/main)
cd ../<repo>-<name> to start working
```

## List Worktrees

```bash
git worktree list
```

## Remove Worktree

```bash
git worktree remove <path>
git branch -d <branch>  # if branch should also be deleted
```

Worktrees allow working on multiple branches simultaneously without stashing or committing incomplete work.

---

Related commands:

- `/start` - Task-based worktree creation with optional Jira (recommended)
- `/done` - cleanup worktree after PR merge
