# /rebase - Smart git rebase

Rebase current branch with automatic stash management and conflict guidance.

## Usage

- `/rebase` - Rebase onto upstream tracking branch
- `/rebase main` - Rebase onto origin/main
- `/rebase <branch>` - Rebase onto origin/<branch>

## Workflow

**Step 1: Pre-flight checks**

```bash
# Check for existing rebase in progress
if [ -d .git/rebase-merge ] || [ -d .git/rebase-apply ]; then
    echo "Rebase already in progress. Run 'git rebase --continue' or '--abort'"
    exit 1
fi
```

**Step 2: Stash if needed**

```bash
# Stash uncommitted changes
if ! git diff --quiet || ! git diff --cached --quiet; then
    git stash push -m "auto-stash before rebase"
    STASHED=true
fi
```

**Step 3: Fetch and rebase**

```bash
git fetch origin

# Determine target branch
if [ -z "$1" ]; then
    TARGET=$(git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null)
else
    TARGET="origin/$1"
fi

git rebase "$TARGET"
```

**Step 4: Restore stash**

```bash
if [ "$STASHED" = true ]; then
    git stash pop
fi
```

**Step 5: Handle conflicts**
If rebase conflicts occur:

1. List conflicted files: `git diff --name-only --diff-filter=U`
2. For each file, explain the conflict
3. Offer to help resolve or provide commands:
   - `git rebase --continue` (after resolving)
   - `git rebase --abort` (to cancel)

**Step 6: Push after successful rebase**
If rebase completed successfully and branch has an upstream:

```
Rebase complete. Pushing with --force-with-lease...
```

```bash
git push --force-with-lease
```

Uses `--force-with-lease` (safer than `--force` - fails if remote has unexpected commits). User can decline at the git permission prompt if needed.

Always fetch before rebasing. Never proceed if rebase already in progress.

---

Related commands:

- `/status` - check branch state
- `/pr` - create/update PR
- `/checks` - view CI status after push
