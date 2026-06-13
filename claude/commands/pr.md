# /pr - Create a pull request

Create a pull request with proper formatting and optional Jira integration.

## Instructions

**Step 1: Gather context**

- Run `git status` to check for uncommitted changes
- Run `git log main..HEAD --oneline` to see commits to include
- Run `git diff main...HEAD --stat` to see files changed
- Check if behind main: `git rev-list --left-right --count origin/main...HEAD`

**Step 2: Pre-flight checks**

- If there are uncommitted changes, ask if user wants to commit first
- If branch is behind main, suggest running `/rebase` first to avoid merge conflicts
- If not on a feature branch, ask for branch name (suggest based on changes)

**Step 3: Push the branch**

```bash
git push -u origin <branch>
```

**Step 4: Get Jira base URL**

Get the Jira URL from (in order):

1. `$JIRA_URL` environment variable
2. `~/.claude/cache/jira-url` cache file
3. Atlassian plugin (`getAccessibleAtlassianResources`) if available

If none available, skip Jira linking.

**Step 5: Jira Integration (if available)**

If Jira is available:

**Determine Jira project (in priority order):**

1. Explicit key in branch: `user/PROJ-123/topic` -> use PROJ, link to PROJ-123 directly
2. Project segment in branch: `user/proj/topic` -> uppercase to PROJ
3. Ask user for project key, or skip

**Find matching ticket:**

- If Jira key found in branch, use it directly
- Otherwise, search for tickets in the project assigned to current user
- If matching ticket(s) found, ask to confirm linking
- If no ticket found, ask: skip or create new?

**Step 6: Check for existing PR**

- If exists, ask to update description
- If not, create new PR

**Step 7: Create/update PR**

With Jira link:

```bash
gh pr create --title "<scope>: <summary>" --body "$(cat <<'EOF'
## Summary
<1-3 bullets describing the change>

## Test plan
- [ ] <how to verify the change>

[PROJ-###]($JIRA_URL/browse/PROJ-###)
EOF
)"
```

Without Jira:

```bash
gh pr create --title "<scope>: <summary>" --body "$(cat <<'EOF'
## Summary
<1-3 bullets describing the change>

## Test plan
- [ ] <how to verify the change>
EOF
)"
```

**Step 8: Finalize**

- Use commit scope for title (e.g., `api:`, `test:`, `docs:`)
- Return the PR URL when done

---

Related commands:

- `/jira` - ticket operations (comment, transition)
- `/checks` - view CI status
- `/rebase` - sync with main before PR
- `/done` - cleanup after merge
