# /pr-ready - Verify and finalize for review

Validate PR is complete, run tests, and post summary comments only if everything passes.

## Usage

- `/pr-ready` - Full validation and test run
- `/pr-ready --skip-tests` - Skip test execution, just validate metadata

(`/ready` is a kept alias for `/pr-ready`.)

## Instructions

**Step 0: Active final-gate report (blocking)**

This command accepts only an active co-review report and independently retained
expected identity from the coordinating workflow. They are not PR comments,
markers, or files reconstructed from historical data. If either is absent,
unreadable, or belongs to an interrupted session, **STOP**: report the missing
evidence and return control to the user. Do not run later steps, launch a
review, or post updates. This command cannot renew an exhausted repair
allowance; a new head or diagnosis does not authorize another cycle.
Co-review removes its coordinator-owned expected identity when snapshot cleanup
fails, so a cleanup-failed report is never active evidence for this command.

Resolve the installed co-review helper root, then use its evaluator. Before
evaluation, recheck the live PR's repository, number, full head, target branch,
resolved base, and CI. Compare each to the independently retained expected
identity. Refresh the active report's exact-head CI payload and digest, then
evaluate the report against that expected file:

```bash
test -f "$ACTIVE_CO_REVIEW_REPORT" && test -f "$EXPECTED_IDENTITY" || exit 2
GATE_REPORT="$REVIEW_ROOT/claude/skills/co-review/scripts/gate_report.py"
REVIEW_HELPER="$REVIEW_ROOT/claude/skills/co-review/scripts/review.py"
gh pr view --json number,headRefOid,baseRefName,statusCheckRollup > live-pr.json
# Resolve BASE_REPO from pulls REST .base.repo.full_name, normalize and compare
# it with origin's real fetch URL. Extract PR_NUMBER, HEAD, and BASE_REF from
# live-pr.json, then resolve BASE with review.py resolve-base for HEAD/BASE_REF.
TREE=$(git rev-parse "$HEAD^{tree}")
uv run --no-project python - "$EXPECTED_IDENTITY" "$BASE_REPO" "$PR_NUMBER" "$HEAD" "$BASE" "$BASE_REF" "$TREE" <<'PY'
import json
import sys

expected = json.load(open(sys.argv[1]))
actual = dict(zip(("repository", "pr_number", "head", "base", "base_ref", "tree"), sys.argv[2:]))
for key, value in actual.items():
    if expected.get(key) != (int(value) if key == "pr_number" else value):
        raise SystemExit(f"active identity changed: {key}")
PY
# Normalize statusCheckRollup into the strict CI envelope with the actual
# headRefOid, required check_runs/status_contexts arrays, and each returned
# check identity/status/conclusion or context identity/state. Refresh the
# report's exact-head CI artifact and recorded digest before evaluate.
uv run --no-project python "$GATE_REPORT" evaluate \
  --report "$ACTIVE_CO_REVIEW_REPORT" --expected "$EXPECTED_IDENTITY"
```

Only evaluator `APPROVE` permits the remaining readiness checks. Any mismatch,
missing active evidence, evaluator `CHANGES`/`INCOMPLETE`, or CI failure stops
and returns control to the user. Preserve the calling workflow's stop; do not
turn it into an automatic review request. Evaluator approval does not authorize a merge:
explicit user merge permission, required human approvals, current CI, and
server-side `--match-head-commit` remain separate gates.

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
- Update PR body with `gh pr edit` (in a herdr session the owner first types `edit the pr body`)

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
