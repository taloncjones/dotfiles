---
name: co-review
description: Use to review a code change with Claude AND Codex in parallel, then resolve the findings. Runs the native /code-review (Claude) and codex exec (different model) on the same diff, merges and dedupes their findings tagged by source, and applies approved fixes. Targets a GitHub PR if given, else the local working diff.
---

# Co-Review (Claude + Codex in parallel)

Two independent reviewers on the same change: Claude (via the native
`/code-review`) and Codex (a different model). Different models miss different
things; running both and reconciling catches more than either alone. Then drive
resolution.

For reviewing an implementation _plan document_ (not code), use
`codex-plan-review` instead — that one is Codex-only because Superpowers already
gave the plan a Claude pass.

## Target resolution

- If the user passed a PR number/URL, review **that PR**.
- Otherwise review the **local working diff** (`git diff` for unstaged +
  `git diff --staged`; if both are empty, fall back to `git diff <base>...HEAD`
  for the current branch). State which target you chose in one line.

## Steps

Run the two reviews **in parallel** (issue both in one turn), then merge.

1. **Claude half — native `/code-review`, report mode.**
   - Invoke the built-in `/code-review` at `high` effort.
   - Do **not** pass `--fix` (we reconcile before changing anything). Pass
     `--comment` only in PR mode if the user wants it posted (see step 6).
   - Capture its findings from the result.
   - Note: native `ultra` is user-triggered and billed and cannot be launched
     programmatically — do not attempt it. `high` is the ceiling here.

2. **Codex half — `codex exec review`, built-in review prompt.**
   Use Codex's dedicated review subcommand against the change base. It has its
   own review prompt and **cannot take a custom prompt** (the two are mutually
   exclusive), so do NOT try to pipe a rubric in:

   ```bash
   # PR mode: `codex exec review` has NO PR/GitHub concept -- it only diffs the
   # current worktree against --base. So check the PR out into an isolated
   # worktree (this also keeps the shared tree free for the parallel Claude
   # half), review there against the PR's base branch, then clean up.
   # The worktree path MUST be unique per run (mktemp -u) -- a fixed path
   # collides with a concurrent or previously-killed run.
   WT=$(mktemp -u /tmp/coreview-pr-<n>.XXXXXX)
   git worktree add --detach "$WT" \
     || { git worktree prune && git worktree add --detach "$WT"; }
   ( cd "$WT" && gh pr checkout <n> \
       && codex exec review --base <pr-base-branch> \
            -c model_reasoning_effort="xhigh" \
            -c approval_policy="never" -c sandbox_mode="read-only" ) > "$WT.log" 2>&1
   git worktree remove --force "$WT"; git worktree prune
   # <pr-base-branch> = gh pr view <n> --json baseRefName -q .baseRefName

   # branch mode: review the current branch's committed work against its fork point
   LOG=$(mktemp /tmp/coreview-branch.XXXXXX)
   codex exec review --base <branch-the-work-forked-from> \
     -c model_reasoning_effort="xhigh" \
     -c approval_policy="never" -c sandbox_mode="read-only" > "$LOG" 2>&1
   ```

   - **ALWAYS use the `codex exec review` subcommand. NEVER invoke Codex
     generically** (`codex exec "review this diff..."`). A generic prompt makes
     Codex read its `AGENTS.md` and load its own `co-review` skill, which shells
     back out to `claude -p "/code-review"` — a Claude -> Codex -> Claude loop
     that re-runs the Claude pass you already did in step 1. The `review`
     subcommand uses a built-in prompt and loads no skills, so it cannot recurse.

   - `-c approval_policy="never" -c sandbox_mode="read-only"` keeps it
     non-interactive and side-effect-free (it only reads + reports).
   - For a purely local, uncommitted diff, commit to a scratch branch (or use
     the PR branch) first — `review --base` compares committed changes against
     the base.
   - Run the Codex review(s) in a detached git worktree per branch so they
     parallelize without branch-switching the shared tree under a running stack.
   - **Target parity:** in PR mode both halves must review the _same_ PR — the
     Claude half gets the PR ref via `/code-review <pr>`, the Codex half gets the
     PR head via the worktree checkout above. Do not let Codex fall back to the
     local branch while Claude reviews the PR.
   - **Read findings from the log file with the Read tool** — do not rely on
     Bash-captured stdout, which truncates on long reviews. Use the final
     `codex` message block (after the header, before `tokens used`); ignore
     MCP/network warning lines. Delete the log after extracting.
   - **Verify Codex's findings against the code before relaying** — it surfaces
     real bugs (this repo's failure mode is compile-green/runtime-red, the class
     static checks miss), but confirm each before acting.

3. **Merge.** Normalize both result sets into one list. Dedupe by
   `file:line + issue`. Tag each finding by source: `[both]` (both reviewers
   flagged it — highest signal), `[claude]`, or `[codex]`. Sort by severity,
   `[both]` first within a tier.

4. **Resolve (triage-first).** Present the merged list. Ask which to fix;
   **default is "fix all"**. Apply approved fixes to the working tree with Edit.
   Re-run the relevant tests/build to confirm.

5. **Re-review the fix commit (bounded).** Applying fixes can introduce new
   bugs the first pass never saw — a swallowed error, a changed return type a
   caller missed, a lifecycle leak in code you just added. When step 4 produced
   a **non-trivial** change (more than a few mechanical lines), run **one** more
   co-review pass scoped to just the fix:
   - Commit the fixes first (the PR branch is fine), then set the review base to
     the **pre-fix commit** so both halves see only the new diff. When the fix
     commit sits directly on the pushed head, Claude's `/code-review` (no arg)
     picks up `@{upstream}...HEAD` automatically; Codex uses
     `codex exec review --base <pre-fix-sha>`. Same base for both = parity.
   - Tell each finder the diff is a fix commit and its job is to catch
     regressions the fixes introduced, not to re-litigate the original change.
   - Resolve any new findings (step 4 again), then **stop**. Hard cap: **2
     passes total** (initial review + one re-review). Never start a third —
     diminishing returns, and subjective findings start to thrash.
   - **Skip entirely** when the fix was trivial (a one-line guard, a rename) or
     when step 4 changed nothing. This step is the single allowed loop; default
     to skipping unless the fix carried real risk.

6. **PR comment (optional, PR mode only).** If `--comment` was requested, post
   to the PR with `gh pr comment`. The comment reflects the PR's **current
   state**, not a changelog of what was found and fixed — delete any prior
   co-review comment first so a stale one doesn't linger. No emojis.
   - **Clean (no findings, or all findings resolved this pass):** post a short
     current-state note that names both reviewers and clears it for a human.
     This is the preferred shape when the PR ends clean:

     ```
     ### Co-review (Claude + Codex)

     Reviewed by Claude (`/code-review`, high effort) and Codex
     (`codex exec review`, xhigh effort) against `<base>`.

     No outstanding issues. Ready for human review.
     ```

   - **Findings remain (not fixed):** list them tagged `[both]/[claude]/[codex]`,
     sorted by severity, citing file:line — brief, one line each. Do not claim
     "ready for human review" while blocking issues are open.

   Either way, keep the public comment to current state; relay the detailed
   findings and any fixes to the user in chat, where the commits carry the
   detail.

## Notes

- Two reviewers, one merged report. Loop **at most once** — the bounded
  re-review in step 5 — then stop. Hard cap of 2 review passes total; default to
  a single pass unless the fix carried real risk.
- If the diff is empty, say so and stop.
