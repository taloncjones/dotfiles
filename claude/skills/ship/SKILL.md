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

Before step 1, run the PR-ready currency gate. First verify `origin` is the PR's
base repository: read the base repo from the pulls REST response
(`gh api repos/{owner}/{repo}/pulls/<n> -q .base.repo.full_name` -- `baseRepository`
is not a `pr view` field) and compare it to origin's real fetch URL
(`git remote get-url origin`, normalized to owner/repo -- not `gh repo view`,
which honours `GH_REPO`). On a fork PR origin is the contributor's fork and
resolving the base there is wrong -- FAIL closed on mismatch or if either side is
unresolved. Fetch the PR's comments (`gh api --paginate --slurp
repos/{owner}/{repo}/issues/{number}/comments | jq '[.[][] | {author:
.user.login, created_at, id, body}]'` -- pipe to external `jq`, since `gh`
rejects `--slurp` with `-q`; `--slurp` wraps the per-page arrays so `.[][]`
flattens), resolve the target base (`review.py resolve-base --base-ref
<baseRefName> --head <headRefOid>`), and run `scripts/pr_ready_gate.py --comments
<file> --head <headRefOid> --base <resolved> --base-ref <baseRefName>
--trusted-author <pr-author> --trusted-author <gh-login>`. If it PASSes -- origin
is the base repo and the latest trusted marker has `verdict=APPROVE`, `sha ==
headRefOid`, `base == resolved base`, `base_ref == baseRefName` -- the review
stands; skip step 1 and resume at step 2. Any FAIL (base-repo mismatch, newer
commit, retarget, missing/CHANGES marker, or any lookup error -- the gate fails
closed) means re-review.

PR already `MERGED` (run died between merge and cleanup)? Jump straight to
steps 5-6 — `post-merge` is propose-confirm-apply over observed state, so it
only proposes whatever cleanup is actually left.

## Steps

1. **Co-review.** Invoke the `co-review` skill on the target PR and run its
   bounded re-review loop to APPROVE: fix all confirmed findings with verified
   repros, re-run affected tests, push, then re-freeze and re-review until a
   complete round is clean (cap 5 rounds; escalate if it does not converge).
   Compute the PR target with `gh pr view --json baseRefName` and pass
   `--base-ref <baseRefName>` so the review diffs against the real merge-base;
   warn if a supplied or local base diverges from the resolved target. Every PR
   review entrypoint resolves and verifies the target branch before trusting a
   marker -- never assume `origin` is the target without checking.

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
