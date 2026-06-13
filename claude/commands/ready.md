# /ready - Verify and finalize for review

Validate PR is complete, run tests, and post summary comments only if everything passes.

## Usage

- `/ready` - Full validation and test run
- `/ready --skip-tests` - Skip test execution, just validate metadata

## Instructions

**Step 1: Verify PR exists**

```bash
gh pr view --json number,title,body,url
git branch --show-current | grep -oE '[A-Z]+-[0-9]+'  # Extract Jira key
```

If no PR exists, stop and suggest running `/pr` first.

**Step 2: Check for unpushed commits**

```bash
git rev-list @{upstream}..HEAD --count 2>/dev/null
```

If unpushed commits exist, warn and suggest pushing first. CI runs against the remote, so unpushed commits mean the PR checks are stale.

**Step 3: Validate PR metadata**

Check that PR has:

- [ ] Title follows `<scope>: <summary>` format
- [ ] Summary section with bullet points describing changes
- [ ] Test plan section with checkboxes
- [ ] Jira link at bottom (if Jira key in branch)

If any missing, suggest fixes but don't auto-edit.

**Step 4: Review Jira ticket (if applicable)**

Get Jira URL from `$JIRA_URL` or `~/.claude/cache/jira-url`.

If Jira key found:

1. Fetch ticket title and description
2. Compare against actual implementation in PR
3. Flag if Jira is outdated (e.g., scope changed, title doesn't match work done)
4. Suggest updates if needed, but don't auto-edit

**Step 5: Run tests**

Unless `--skip-tests` specified:

1. Identify test files related to changed code
2. Run pytest with appropriate flags
3. Capture results: passed, failed, skipped counts

**If any tests fail, STOP HERE.** Report failures but do NOT post comments.

**Step 6: Update PR test plan (if tests pass)**

- Parse existing test plan checkboxes from PR body
- Check off items that correspond to passing tests
- Add test results as checkbox items with pass/skip counts and relevant metrics (e.g., timing)
- Format: `- [x] \`test_file.py\` - X passed, Y skipped (notes)`
- Update PR body with `gh pr edit`

**Step 7: Post Jira comment (if tests pass)**

Only if Jira key exists and all tests pass. Keep it brief:

```markdown
Tests passing. Ready for review.
PR: <github-pr-url>
```

Do NOT duplicate the full changelog - PR is the source of truth.

**Step 8: Report**

```
## Ready for Review

PR: <url>
Jira: <url>

Validation:
  [x] All commits pushed (or: [!] N unpushed commits - push before marking ready)
  [x] PR title format
  [x] PR has summary
  [x] PR has test plan
  [x] Jira link present
  [x] Jira description current (or: [!] Jira may need update - <reason>)

Tests: X passed, Y skipped, 0 failed

Updates:
  [x] PR test plan checked off
  [x] Jira comment posted

Status: READY FOR REVIEW
```

## Notes

- NEVER post comments if tests fail - avoid cluttering comment history
- NEVER post PR comments - update PR body instead (comments are for review discussion)
- NEVER duplicate full changelog in Jira - just link to PR
- Check for existing "Ready for review" Jira comment before posting duplicate
- If tests require hardware, user can run `/ready --skip-tests` after manual verification
- Capture relevant metrics: timing (firmware flash), throughput (msg/s), counts

---

Related commands:

- `/pr` - Create pull request
- `/dev-review` - Code review before ready
- `/checks` - View CI status
- `/done` - Cleanup after merge
