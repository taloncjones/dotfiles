---
name: co-review
description: Use to review a code change with Claude AND Codex in parallel, then resolve the findings. Runs the native /code-review (Claude) and codex exec (different model) on the same diff, merges and dedupes their findings tagged by source, runs a bounded adversarial-verify pass to separate real bugs from likely false positives, probes gate-like diffs (auth/validation/review gates) with a threat-model attacker, and applies approved fixes. Targets a GitHub PR if given, else the local working diff.
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

Freeze the review snapshot, run gate detection once, then the two finders
(and the attacker, if gate detection fired) in parallel, then merge and
verify.

0. **Freeze the snapshot, then run gate detection once, before dispatching
   anything.**
   - Resolve the exact base/head this pass reviews, using the same target
     already picked in "Target resolution" above (PR head vs PR base; or
     branch head vs fork point; or, for a purely local uncommitted diff,
     commit it to a scratch branch first — same requirement step 2 below
     already states for Codex, done here so it also covers steps 2.5 and
     3.5). Every subagent dispatched below (step 2.5's attacker, step 3.5's
     skeptics) gets this exact base/head range stated explicitly, with
     explicit read-only instructions — never "figure out the diff yourself,"
     which risks a subagent inspecting a different or since-changed checkout.
   - Against that frozen diff, check each changed file's path,
     case-insensitive, for a whole path-segment match (a segment is text
     between `/`, `.`, `-`, or `_` — so this does not match `author` against
     `auth`, or `invalid` against `valid`) against: `auth`, `guard`, `gate`,
     `valid`, `validate`, `validator`, `permission`, `acl`, `verify`,
     `verification`, `credential`, `token`, `sign`, `signature`, or a path
     under this repo's `claude/hooks/` whose filename contains `guard` or
     `review`. Exclude any path under a `test`/`tests`/`spec`/`docs`/
     `examples` directory even if it matches (it exercises or documents a
     gate, it is not the gate). Example matches: `claude/hooks/commit_guard.py`,
     `src/auth/validator.py`. Example non-matches: `src/author_bio.py`,
     `tests/auth/test_login.py` (excluded by the `tests/` rule),
     `docs/signing-guide.md` (excluded by the `docs/` rule).
   - Record **two** things, not just a boolean: whether _any_ changed file
     matched (`gate_detected: yes/no`), and the **set of matched paths**
     themselves (`gate_paths: {...}`). `gate_detected` gates step 2.5's
     attacker dispatch (probe the whole diff if any part of it is gate-like).
     `gate_paths` gates step 3.5's per-finding escalation rule (escalate only
     a finding whose _own_ file is in this set — a finding in an unrelated
     file elsewhere in the same diff does not escalate just because some
     other file in the diff happened to match).
   - Re-run this entire step independently on each review pass (initial pass
     and the bounded re-review in step 5), against that pass's own frozen
     diff — a fresh `gate_detected`/`gate_paths` each time.

1. **Claude half — native `/code-review`, report mode.**
   - Invoke the built-in `/code-review` at `high` effort.
   - Do **not** pass `--fix` (we reconcile before changing anything). Pass
     `--comment` only in PR mode if the user wants it posted (see step 6).
   - Capture its findings from the result.
   - Note: native `ultra` is user-triggered and billed and cannot be launched
     programmatically — do not attempt it. `high` is the ceiling here.

2. **Codex half — `codex exec review`, adversarial review prompt.**
   Use Codex's dedicated review subcommand against the change base. Pin the
   model and effort so a machine-level default change cannot silently alter the
   review. The current CLI accepts optional review instructions in addition to
   its built-in prompt, so give it one compact, correctness-focused rubric:

   ```bash
   # PR mode: `codex exec review` has NO PR/GitHub concept -- it only diffs the
   # current worktree against --base. So check the PR out into an isolated
   # worktree (this also keeps the shared tree free for the parallel Claude
   # half), review there against the PR's base branch, then clean up.
   # The worktree path MUST be unique per run (mktemp -u) -- a fixed path
   # collides with a concurrent or previously-killed run.
   CODEX_REVIEW_RUBRIC='Review adversarially. Prioritize runtime correctness, removed behavior, error handling, lifecycle and concurrency, auth and security boundaries, data or hardware safety, and missing regression tests. Report only actionable findings introduced by this diff; cite the file and line and explain a concrete failure scenario.'
   WT=$(mktemp -u /tmp/coreview-pr-<n>.XXXXXX)
   git worktree add --detach "$WT" \
     || { git worktree prune && git worktree add --detach "$WT"; }
   ( cd "$WT" && gh pr checkout <n> \
       && codex exec review --base <pr-base-branch> \
            -m gpt-5.6-sol -c model_reasoning_effort="high" \
            -c approval_policy="never" -c sandbox_mode="read-only" \
            "$CODEX_REVIEW_RUBRIC" ) > "$WT.log" 2>&1
   git worktree remove --force "$WT"; git worktree prune
   # <pr-base-branch> = gh pr view <n> --json baseRefName -q .baseRefName

   # branch mode: review the current branch's committed work against its fork point
   LOG=$(mktemp /tmp/coreview-branch.XXXXXX)
   codex exec review --base <branch-the-work-forked-from> \
     -m gpt-5.6-sol -c model_reasoning_effort="high" \
     -c approval_policy="never" -c sandbox_mode="read-only" \
     "$CODEX_REVIEW_RUBRIC" > "$LOG" 2>&1
   ```

   - Default to `gpt-5.6-sol` at `high`. Escalate Codex to `xhigh` only for
     high-risk changes involving auth/security, concurrency/lifecycle,
     migrations or destructive data handling, hardware safety, or a large
     cross-cutting diff (roughly 500+ changed lines or multiple packages).
     When escalating, substitute `xhigh` for `high` in the selected command and
     record the actual effort for step 6. Never select `max` or `ultra`
     automatically.

   - **ALWAYS use the `codex exec review` subcommand. NEVER invoke Codex
     generically** (`codex exec "review this diff..."`). A generic prompt makes
     Codex read its `AGENTS.md` and load its own `co-review` skill, which shells
     back out to `claude -p "/code-review"` — a Claude -> Codex -> Claude loop
     that re-runs the Claude pass you already did in step 1. The `review`
     subcommand uses a built-in prompt and loads no skills, so it cannot
     recurse. This is not theoretical: a generic `codex exec "<prompt>"` call
     reliably loads this repo's `AGENTS.md` and co-review skill regardless of
     `--ignore-user-config` or `--disable multi_agent`, and has been observed
     attempting the `claude -p` shell-out live (blocked only by that `claude`
     session being logged out in the test environment, not by anything in the
     CLI). The same constraint applies to steps 2.5 and 3.5 below — neither
     ever invokes `codex exec` with a custom prompt.

   - `-c approval_policy="never" -c sandbox_mode="read-only"` keeps it
     non-interactive and side-effect-free (it only reads + reports).
   - For a purely local, uncommitted diff, commit to a scratch branch (or use
     the PR branch) first — `review --base` compares committed changes against
     the base. (Step 0 already does this before gate detection, so this is
     already done by the time this step runs.)
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

2.5. **Threat-model attacker (only if step 0's `gate_detected` is yes), run in
parallel with steps 1-2.** Dispatch one `Agent`-tool subagent (general-purpose,
fresh context) with: the full diff, step 0's frozen base/head (explicit,
read-only), and any governing invariant the gate is meant to enforce —
pulled from the diff's own tests, docstrings, or comments, or an explicit
statement of intent if one exists in the task description. Its brief:

- If no governing invariant can be identified, stop and report
  `INCONCLUSIVE -- no stated policy to test against`. Do not guess intended
  behavior from the implementation and then "test" against that guess — an
  attack that only proves the implementation matches itself proves nothing.
- Otherwise, attempt at least 3 distinct concrete bypass vectors (specific
  call/input sequences) that would make the gate accept something the
  identified invariant says it should reject. Report each vector attempted
  and exactly what blocked it, or that it succeeded.
- Each vector that succeeds is reported as a separate bypass, with all of:
  a severity (critical/high/medium/low, the same scale the merged list
  sorts by in step 3), the file:line it enters at, the concrete sequence,
  the invariant it violates, and the evidence. Multiple successful vectors
  are multiple bypasses, not one — each gets its own severity and entry.

3. **Merge.** Normalize both finder result sets into one list. Dedupe by
   `file:line + issue`. Tag each finding by source: `[both]` (both reviewers
   flagged it independently — highest signal), `[claude]`, or `[codex]`. Sort
   by severity, `[both]` first within a tier.

   If step 2.5 ran and found successful bypasses, fold each in as a new
   finding tagged `[threat-model]`, carrying the severity it was assigned.
   If a `[threat-model]` finding dedupes against (same file:line + issue as)
   an existing `[claude]`/`[codex]`/`[both]` finding, compose the tag instead
   of adding a parallel entry (e.g. a `[claude]` finding independently
   reproduced by the attacker becomes `[claude+threat-model]`). Any finding
   whose tag includes `threat-model` qualifies for the escalation rule in
   step 3.5 the same as a plain `[both]` finding, regardless of whether its
   file is in step 0's `gate_paths` (the attacker already vetted it). If step
   2.5 returned `INCONCLUSIVE` or "no bypass found", that is not a finding —
   carry it forward as a one-line coverage note for step 4/6, worded
   distinctly ("probed, no bypass found (N vectors tried)" vs "probe
   inconclusive: no governing invariant identified").

3.5. **Adversarial-verify (skip if the merged list from step 3 is empty).**
For each merged finding, dispatch one `Agent`-tool skeptic subagent (fresh
context) with: the finding's file:line, description, source tag, the cited
code region, and step 0's frozen base/head (explicit, read-only), with
instructions to Grep/Read that snapshot for callers, guards, tests, or
contracts bearing on the claim.

Instruct the skeptic to _prove_ the finding is a false positive or
unreachable, using only these admissible evidence classes:

- a guard/check already in the code path that prevents the described input
  or state from occurring;
- no call site exists anywhere in the reviewed snapshot that can reach the
  flagged code with the described input (checked via Grep, not assumed);
- the described precondition is provably impossible given the surrounding
  type/contract.

Absence of a current caller does **not** refute a finding in an exported
API, public interface, CLI entry point, or hook/callback registered for
external invocation — "no live caller" only counts as evidence for
private/internal code. Burden of proof is on the skeptic: absent one of the
admissible evidence classes, the verdict defaults to `NOT-REFUTED`.

Each skeptic returns exactly `REFUTED` or `NOT-REFUTED` plus a one-line
rationale citing the specific evidence. A skeptic call that errors, times
out, or returns a non-conforming response counts as `NOT-REFUTED`
(fail-closed).

**Escalate to a 3-skeptic majority vote** only when the single skeptic
returns `REFUTED` for a finding that is _either_ tagged `[both]` (or any
composite tag including `threat-model`, per step 3) _or_ whose own
file:line is inside step 0's `gate_paths` set (not merely "somewhere in a
diff that has a gate-like file elsewhere"). Dispatch 2 _additional_
independent skeptics (3 verdicts total, none sees another's verdict). 2+
`REFUTED` -> refuted; otherwise (including any fail-closed outcome) -> not
refuted. This bounds fan-out to at most 3 skeptic calls per finding, and
only for findings that are both refuted by the first pass and meet one of
the two escalation conditions.

Re-tier, do not delete: findings that survive (not refuted, single or
majority) sort first as today. Findings that are refuted sort last, tagged
`[refuted -- low confidence]` with the skeptic's one-line rationale inline.
Never silently dropped, and never described as resolved or absent in chat
or the PR comment.

Run this stage inside both the initial pass and the bounded re-review pass
(step 5) — it does not add a pass, it runs against whichever diff that
pass is reviewing.

4. **Resolve (triage-first).** Present the merged, tiered list: survived
   findings first, then any coverage note from step 3.5's threat-model probe,
   then refuted findings last under a clear `[refuted -- low confidence]`
   heading. Ask which to fix; **default "fix all" applies to the survived tier
   only** — a refuted finding is fixed only if the human names it explicitly
   (e.g. "fix #N too"), since demotion already represents the skeptic's
   best-effort judgment that it's noise. Apply approved fixes to the working
   tree with Edit. Re-run the relevant tests/build to confirm.

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
   - Apply the Codex risk rule from step 2 to the fix diff independently. Do not
     inherit `xhigh` merely because the initial review used it.
   - Re-run step 0 (freeze + gate detection) against the fix-commit diff
     independently — a fix that touches gate-like paths gets step 2.5 and
     3.5's escalation rule again even if the original diff didn't, and vice
     versa. Steps 1-3.5 run again against just this fix diff.
   - **Carry forward pass 1's unresolved state.** Pass 2's own merge (step 3)
     only covers the fix-commit diff — it does not automatically re-surface
     pass 1's findings that were survived-but-not-fixed or refuted-but-not-fixed.
     Maintain a running current-state list across both passes: every finding
     from pass 1 that is still not fixed (survived or refuted) stays in its
     tier in the final report; pass 2's newly-found findings are added to the
     same two tiers. The final report (step 4's re-presentation after pass 2,
     and step 6's PR comment) always reflects this union, not just pass 2's
     fresh merge — a finding is removed from the report only once it is
     actually fixed and verified, never merely because a later pass didn't
     re-flag it.
   - Resolve any new findings (step 4 again), then **stop**. Hard cap: **2
     passes total** (initial review + one re-review). Never start a third —
     diminishing returns, and subjective findings start to thrash.
   - **Skip entirely** when the fix was trivial (a one-line guard, a rename) or
     when step 4 changed nothing. This step is the single allowed loop; default
     to skipping unless the fix carried real risk.

6. **PR comment (optional, PR mode only).** If `--comment` was requested, post
   to the PR with `gh pr comment`. The comment reflects the PR's **current
   state** — the union described in step 5 if a re-review ran, otherwise just
   pass 1's tiered list — not a changelog of what was found and fixed. Delete
   any prior co-review comment first so a stale one doesn't linger. No
   emojis.
   - **Clean, refuted tier empty (no findings, or all findings resolved/none
     refuted this pass):** post a short current-state note that names both
     reviewers and clears it for a human:

     ```
     ### Co-review (Claude + Codex)

     Reviewed by Claude (`/code-review`, high effort) and Codex
     (`codex exec review`, <codex-effort> effort) against `<base>`.

     No outstanding issues. Ready for human review.
     ```

   - **Clean survived tier, non-empty refuted tier:** do not claim "no
     outstanding issues" — that overclaims past what the skeptic pass
     established. Use instead:

     ```
     ### Co-review (Claude + Codex)

     Reviewed by Claude (`/code-review`, high effort) and Codex
     (`codex exec review`, <codex-effort> effort) against `<base>`.

     No high-confidence issues. <N> low-confidence finding(s) suppressed as
     likely false positives or unreachable (see chat). Ready for human review.
     ```

   - **Survived findings remain (not fixed):** list them tagged
     `[both]/[claude]/[codex]/[threat-model]` (or composite), sorted by
     severity, citing file:line — brief, one line each. Do not claim
     "ready for human review" while blocking issues are open. If the refuted
     tier is also non-empty, append the same one-line suppressed-count note
     used above.

   Either way, keep the public comment to current state; relay the detailed
   findings (including the full refuted tier with rationale) and any fixes to
   the user in chat, where the commits carry the detail.

## Notes

- Two reviewers plus a bounded skeptic/attacker pass, one merged and tiered
  report. Loop **at most once** — the bounded re-review in step 5 — then
  stop. Hard cap of 2 review passes total; default to a single pass unless the
  fix carried real risk.
- If the diff is empty, say so and stop.
- Adversarial-verify and the threat-model probe both run entirely on the
  Claude side (`Agent`-tool subagents), never via a custom-prompt `codex exec`
  call — see step 2's recursion note. `codex exec review --base` (step 2) is
  the only Codex invocation this skill ever makes.
