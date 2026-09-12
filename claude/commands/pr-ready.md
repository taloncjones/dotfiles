# /pr-ready - Verify and finalize for review

Validate PR is complete, run tests, and post summary comments only if everything passes.

## Usage

- `/pr-ready` - Full validation and test run
- `/pr-ready --skip-tests` - Skip test execution, just validate metadata

(`/ready` is a kept alias for `/pr-ready`.)

## Instructions

**Step 0: Co-review currency gate (blocking)**

The branch is not ready unless its latest co-review is APPROVE and current. Run
the gate before anything else:

```bash
set -o pipefail
gh pr view --json number,headRefOid,baseRefName,author
gh api user -q .login                          # authenticated reviewer identity
# Bind the review to the PR's REAL target repo. `baseRepository` is not a
# pr-view field; read it from the pulls REST response, and compare it to
# origin's actual fetch URL (not `gh repo view`, which honours GH_REPO / the
# default repo and can lie). On a fork PR origin is the contributor's fork, so
# resolving --base-ref there is wrong -> fail closed on mismatch or if either
# side is unresolved.
base_repo=$(gh api "repos/{owner}/{repo}/pulls/<number>" -q .base.repo.full_name)
origin_repo=$(git remote get-url origin)   # normalize to owner/repo:
#   strip any ssh host alias/user@host prefix and trailing .git, lowercase-compare
[ -n "$base_repo" ] && [ "$origin_repo_normalized" = "$base_repo" ] || STOP
# --slurp gives one array PER PAGE wrapped in an outer array; pipe to external
# jq to flatten (gh rejects --slurp together with -q/--jq).
gh api --paginate --slurp repos/{owner}/{repo}/issues/{number}/comments \
  | jq '[.[][] | {author: .user.login, created_at, id, body}]' > comments.json
uv run --no-project python <co-review>/scripts/review.py resolve-base \
  --repo "$PWD" --base-ref <baseRefName> --head <headRefOid>   # -> {base}
uv run --no-project python <co-review>/scripts/pr_ready_gate.py \
  --comments comments.json --head <headRefOid> --base <resolved-base> \
  --base-ref <baseRefName> \
  --trusted-author <pr-author-login> --trusted-author <gh-login>
```

PASS requires origin's real fetch URL == the PR base repository, and the latest
trusted marker `verdict=APPROVE`, `sha == headRefOid`, `base == resolved base`,
and `base_ref == baseRefName`. On FAIL (base-repo mismatch/unresolved, stale
head, retarget, missing/CHANGES marker, or ANY lookup/API error -- the gate
fails closed), **STOP**: report "re-run co-review" and do not run the steps below
or post any Jira/PR-body updates.

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
- `co-review` skill - Claude + Codex review before ready
- `/checks` - View CI status
- `/done` - Cleanup after merge
