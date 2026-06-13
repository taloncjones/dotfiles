# /checks - View CI status

Show CI/check status for the current branch's PR.

## Usage

- `/checks` - Show CI status for current PR
- `/checks --watch` - Watch until checks complete

## Examples

```
/checks
/checks --watch
```

## Instructions

**Step 1: Get PR for current branch**

```bash
gh pr view --json number,title,url,statusCheckRollup,mergeable,mergeStateStatus
```

If no PR exists, show: "No PR found for this branch. Run /pr to create one."

**Step 2: Display check status**

```
PR #<number>: <scope>: <summary>

Checks:
  [OK] build (Xm Ys)
  [OK] lint (Xm Ys)
  [FAIL] test (Xm Ys)
  [PENDING] deploy-preview

Overall: N failing, M pending, X passed
Mergeable: No (checks failing)

https://github.com/<org>/<repo>/pull/<number>/checks
```

Use text status indicators (per global CLAUDE.md - no emojis):

- `[OK]` - passed
- `[FAIL]` - failed
- `[PENDING]` - in progress
- `[SKIP]` - skipped

**Step 3: If `--watch` flag**

- Poll every 30 seconds until all checks complete
- Show updated status on each poll
- Notify when complete: "All checks passed!" or "Checks failed: <list>"

**Step 4: Offer actions based on status**

If checks failing:

- Show link to failed check logs

If checks passed and PR is mergeable:

- Show: "Checks passed. Ready to merge."

---

Related commands:

- `/status` - overall work status
- `/pr` - create/update PR
- `/test` - run tests locally
- `/lint` - run linters locally
