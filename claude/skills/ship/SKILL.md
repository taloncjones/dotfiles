---
name: ship
description: Use when a branch or PR is implementation-complete and the user wants it taken all the way to merged-and-cleaned-up. Trigger on "ship this", "ship PR <n>", "take this to merge", "finish this PR off". Not for starting reviews alone (use co-review) or cleanup alone (use post-merge).
---

# Ship (review -> fix -> merge -> cleanup)

One command for the standard delivery arc. Chains existing skills; the only
human gate is the merge itself.

## Target resolution

- PR number/URL given: ship **that PR**.
- Otherwise: the current branch's open PR (`gh pr view`). No PR yet? Offer to
  create one first (per global PR rules), then continue.
- State the target, base branch, and linked Jira ticket (from branch name or PR
  body) in one line before starting.

## Resume (cheap re-runs)

Before step 1, check for a prior run: if the PR already carries a co-review
comment AND no commits have landed since it was posted, the review still
stands — skip step 1 and resume at step 2. Any newer commit invalidates the
comment; re-review.

PR already `MERGED` (run died between merge and cleanup)? Jump straight to
steps 5-6 — `post-merge` is propose-confirm-apply over observed state, so it
only proposes whatever cleanup is actually left.

## Steps

1. **Co-review.** Invoke the `co-review` skill on the target PR. Fix all
   approved findings with verified repros; re-run the affected tests after each
   fix. Push fixes.

2. **Verify.** Run the project's test suite locally, then wait for CI checks on
   the PR head to be green. Do not proceed on red or pending-forever checks —
   surface them instead.

3. **Version bump (if the project versions releases).** Default to a PATCH
   bump and fold the proposed version into the step-4 summary — the merge-gate
   confirmation covers both. Ask separately only if MINOR/MAJOR seems
   warranted. Skip silently if the repo has no version to bump.

4. **Merge gate (human).** Present a one-screen summary: findings fixed, test
   results, CI state, version change. Ask for explicit confirmation, then
   **squash-merge** via `gh pr merge --squash`.

   If branch protection requires an external approval that is not yet in, do
   not poll with model turns — start a zero-token background wait
   (`run_in_background`) and present the gate when it fires:

   ```bash
   until [ "$(gh pr view <n> --json reviewDecision -q .reviewDecision)" = "APPROVED" ]; do
     sleep 300
   done
   ```

   If the session ends before approval lands, a later `/ship <n>` picks up at
   step 2 via the resume rule above.

5. **Cleanup.** Invoke the `post-merge` skill: worktree teardown, local +
   remote branch deletion, Jira transition to Done, sprint/epic hygiene.

6. **Exit state.** Confirm clean: no leftover worktree, no stale branch, Jira
   reconciled. Report in 3 lines max.

## Notes

- Stop and report at the first hard failure (red tests, blocked CI, merge
  conflict). Do not auto-retry around a failing gate.
- Never merge without the step-4 confirmation, even if the user said "ship it"
  up front — "ship" authorizes the pipeline, the gate authorizes the merge.
- Follow-ups discovered but not fixed here: file Jira tickets, not todo files.
