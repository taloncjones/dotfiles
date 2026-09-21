---
name: ship
description: Use when a branch or PR is implementation-complete and the user wants it taken through the explicit merge gate and cleanup.
---

# Ship

Ship completes implementation, tests, release-version work, one final
co-review, then asks for explicit merge permission. It never treats a comment
or a historical review as present-session authority.

## Target resolution

- A PR number or URL selects that PR.
- Otherwise use the current branch's open PR (`gh pr view`). If none exists,
  offer to create one under the existing PR rules.
- State the selected PR, target branch, and linked Jira ticket before work.
- If the PR is already merged, go directly to `post-merge` cleanup.

For a PR, verify that `origin` is its real base repository using the pulls REST
response and `git remote get-url origin`. A fork's `origin` cannot resolve the
target base. Stop if either identity is unavailable or mismatched.

## Steps

1. **Complete the change.** Make only authorized implementation changes. Use
   `review-change` for development feedback when useful; advisory feedback is
   not an automatic fix queue. Resolve concrete blockers and run the relevant
   tests before the final gate.

2. **Version work.** If the repository versions releases, make the authorized
   version change now and rerun affected tests. Do not change a version after
   final co-review. Skip when the repository has no release version.

3. **Final gate.** Invoke `co-review` once against the live PR target, with its
   real `baseRefName`. The active workflow retains the resulting report and its
   independently created expected-identity file. `CHANGES` returns concrete
   blockers to development. `INCOMPLETE` states the missing evidence. Do not
   auto-fix and relaunch a full gate. An explicitly user-invoked
   `co-review --fix` supplies its scoped repair authorization; existing
   development authorization also covers that handoff. It uses its own bounded
   coordinator policy, including one follow-up verification of repairs and
   affected contracts with evidenced carried coverage. Exhaustion stops ship
   and the outer development workflow. A changed head, diagnosis or resumed
   session cannot renew the allowance; only new explicit user direction after
   the stop can. Changed identity or interruption invalidates approval and is
   a stop, not permission to automatically launch another gate.

4. **Recheck gate evidence.** Immediately before presenting a merge-ready
   result, fetch live PR head, base branch, target base, and CI. The active
   report path and successfully finalized expected-identity path must both be
   present from this same uninterrupted workflow. Cleanup failure invalidates
   and removes the active expected identity, so it always requires a new gate.
   Read the expected file and stop unless its
   repository, PR number, head, base, base branch, and tree exactly equal the
   live values. Refresh its exact-head CI artifact and digest, then
   invoke `gate_report.py evaluate --report REPORT --expected EXPECTED`. The
   co-review snapshot has already been verified and cleaned; this step checks
   live source/PR identity and retained report artifacts, not a deleted manifest.
   A changed identity, failed evaluation, absent active files, or session interruption
   invalidates approval and stops this workflow. A fresh review needs the
   caller authorization described above; historical PR comments never resume
   this step.

5. **Merge gate (human).** Present the findings disposition, test results, CI
   state, version change, and active evaluator result.
   Name any stale-base artifact the gate refuted and quote the base tip SHA
   from its `evidence`; present recorded dispositions only, with no fresh
   reads, since the run ref is gone after finalize and `RUN_DIR` has no
   defined lifetime. Any outward post of a finding needs that recorded check
   first. Ask for explicit merge confirmation. Required human approvals
   remain separate from evaluator approval. On confirmation, squash merge with
   `gh pr merge --squash --match-head-commit <expected-head>` so the server
   refuses a moved head.

6. **Cleanup.** Invoke `post-merge`, then report remaining cleanup state.

## Notes

- Stop on a failed test, red or pending required CI, merge conflict, missing
  active report, missing human approval, or evaluator failure.
- `ship` authorizes the delivery workflow. The explicit step-5 confirmation
  authorizes the merge.
- Command-mode redesign, PR metadata automation, and `/ready` removal remain
  deferred to the separate shipping-workflow change.
