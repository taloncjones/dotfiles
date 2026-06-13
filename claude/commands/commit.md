# /commit - Create a commit with auto-detected scope

Create a well-formatted commit with automatic scope detection from changed files.

## Usage

- `/commit` - Auto-detect scope, prompt for summary
- `/commit <summary>` - Auto-detect scope, use provided summary
- `/commit <scope>: <summary>` - Use provided scope and summary

## Examples

```
/commit
/commit add rate limit tests
/commit api: add rate limit tests
```

## Instructions

**Step 1: Check for changes**

```bash
git branch --show-current
git status --porcelain
```

- If on `main` or `master`: Warn "You're on the main branch. Create a feature branch first?"
- If no changes: "Nothing to commit."
- If unstaged changes exist, proceed to analyze them

**Step 1b: Analyze change groupings**

If there are many changed files (>3-4), analyze whether they should be split into logical commits:

1. Group files by functional area (same directory, same feature, same scope)
2. Identify distinct changesets (e.g., "test changes" vs "source changes" vs "config changes")
3. If files naturally group into 2+ distinct commits, suggest splitting:

```
Found N changed files across multiple areas. Creating X commits:

Commit 1: <scope-a>: <summary>
  M  <path/to/file1>
  M  <path/to/file2>

Commit 2: <scope-b>: <summary>
  A  <path/to/file3>
  M  <path/to/file4>
```

Then proceed with commits in order. User can accept/decline at the git permission prompt, or interrupt to request different grouping.

**Step 2: Auto-detect scope from changed files**

Infer scope from file paths and context:

1. Check recent commits (`git log --oneline -20`) to learn the project's scope conventions
2. Identify the most meaningful directory component (e.g., `site/node-service/` -> `node-service`)
3. For nested paths, use context to pick the right level of specificity
4. Keep scopes short: 1-2 words, lowercase, hyphenated if needed
5. Common scope patterns: feature area, service name, tool name, `docs`, `ci`, `test`

If scope is ambiguous or uncertain:

- If commit history shows conflicting patterns for similar paths, ask user to pick
- If files span multiple scopes with no clear majority, ask user to pick
- Show the options found in history as suggestions

**Step 3: Determine summary**

If user provided `<scope>: <summary>`, use as-is.
If user provided just `<summary>`, prepend detected scope.
If no input, analyze the diff (`git diff --cached` or `git diff`) and generate a concise summary:

- Describe what changed, not how (e.g., "add rate limit tests" not "add new test file")
- Use imperative mood ("add", "fix", "remove", "update")
- Keep it under 50 characters

**Step 4: Validate commit message**

Rules (from CLAUDE.md):

- Format: `<scope>: <summary>`
- Max 75 characters total
- Imperative mood ("add" not "added", "fix" not "fixed")
- Lowercase scope
- No emojis
- No period at end
- No AI attribution

**Step 5: Show preview and create commit**

Show the commit summary and files, then immediately commit (no confirmation needed):

```
Commit:
  api: add rate limit tests

Files:
  M  test/api/fixtures.py
  A  test/tests/api/test_rate_limits.py
```

```bash
git add <files>  # if not already staged
git commit -m "<scope>: <summary>"
```

**Step 6: Report**

```
Committed: api: add rate limit tests
  2 files changed, 45 insertions(+)
```

---

Related commands:

- `/status` - check what's changed
- `/pr` - create PR after commits
- `/rebase` - sync with main
