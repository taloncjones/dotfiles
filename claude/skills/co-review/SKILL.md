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
     already picked in "Target resolution" above (PR head vs PR base; branch
     head vs fork point; or the local working tree vs HEAD), then materialize
     that head as **one durable frozen worktree** that every reviewer below
     reads — the Codex finder (step 2), the threat-model attacker (step 2.5),
     and the skeptics (step 3.5). One worktree per pass, provisioned here and
     torn down unconditionally in step 3.6 (on the clean/empty path, on early
     stop, and on any abort — never gated under step 3.5's skip-if-empty
     heading); the shared working tree is never
     committed or moved, so step 1's native `/code-review` still auto-detects
     the original diff directly. Provision it per mode (run in the shared
     tree):

     ```bash
     # Unique per run -- a fixed path collides with a concurrent/killed run.
     WT=$(mktemp -u /tmp/coreview-snap.XXXXXX)
     git worktree add --detach "$WT" HEAD \
       || { git worktree prune && git worktree add --detach "$WT" HEAD; }

     # PR mode: check the PR head out INTO $WT, detached -- no local PR branch is
     # ever created, so there is nothing extra to tear down in step 3.6 (and the
     # shared tree stays free for the parallel Claude half). Pin base + head so
     # the finders and skeptics all read the same commit even if the PR is pushed
     # to mid-review. gh pr checkout can FAIL (network/auth, or the PR ref is
     # unavailable) and leave $WT at the shared HEAD -- then Codex would silently
     # review the reviewer's own branch, not the PR. So resolve the PR head SHA
     # up front and refuse to proceed unless $WT is actually at it (fail loudly,
     # before any reviewer is dispatched).
     BASE_REF=$(gh pr view <n> --json baseRefName -q .baseRefName)
     PR_HEAD=$(gh pr view <n> --json headRefOid -q .headRefOid)
     ( cd "$WT" && gh pr checkout <n> --detach ) \
       || { echo "co-review: 'gh pr checkout <n> --detach' failed -- aborting, would review the wrong commit" >&2; exit 1; }
     SNAP_HEAD=$(git -C "$WT" rev-parse HEAD)
     [ "$SNAP_HEAD" = "$PR_HEAD" ] \
       || { echo "co-review: \$WT is at $SNAP_HEAD, not PR head $PR_HEAD -- aborting" >&2; exit 1; }
     # Pin the base to the merge-base SHA. A bare ref name ("main") may not
     # resolve inside $WT (codex would error -> read as "no findings" = silent
     # false-clean) or may have advanced past the fork point (wrong scope). The
     # fetch is guarded: on failure FETCH_HEAD can be stale (gh pr checkout
     # writes it), which would silently pin SNAP_BASE to the PR head and produce
     # a false-empty diff. Assumes `origin` is the PR's base repository (the
     # own-repo case this skill serves); a checkout whose origin is a fork of
     # the base repo is unsupported -- a same-named branch there could resolve
     # from the wrong repo.
     git -C "$WT" fetch origin "$BASE_REF" \
       || { echo "co-review: fetch of base '$BASE_REF' failed -- aborting" >&2; exit 1; }
     SNAP_BASE=$(git -C "$WT" merge-base FETCH_HEAD "$PR_HEAD") \
       && git -C "$WT" rev-parse --verify --quiet "$SNAP_BASE^{commit}" >/dev/null \
       || { echo "co-review: could not pin SNAP_BASE to a commit -- aborting" >&2; exit 1; }

     # branch mode (committed work, no PR): head is already committed.
     # checkout --detach can still fail (e.g. an untracked file already in $WT
     # collides with a tracked path at $SNAP_HEAD) and leave $WT at whatever
     # it was provisioned at -- verify it landed before dispatching anything.
     SNAP_HEAD=$(git rev-parse HEAD)
     git -C "$WT" checkout --detach "$SNAP_HEAD" \
       || { echo "co-review: checkout of $SNAP_HEAD into \$WT failed -- aborting, would review the wrong commit" >&2; exit 1; }
     [ "$(git -C "$WT" rev-parse HEAD)" = "$SNAP_HEAD" ] \
       || { echo "co-review: \$WT is at $(git -C "$WT" rev-parse HEAD), not $SNAP_HEAD -- aborting" >&2; exit 1; }
     # Pin the base to the merge-base SHA, computed against the pinned $SNAP_HEAD
     # -- never the shared tree's mutable HEAD, which another session can move
     # between commands.
     SNAP_BASE=$(git merge-base <branch-the-work-forked-from> "$SNAP_HEAD") \
       && git rev-parse --verify --quiet "$SNAP_BASE^{commit}" >/dev/null \
       || { echo "co-review: could not pin SNAP_BASE to a commit -- aborting" >&2; exit 1; }

     # local-uncommitted mode: the change is committed NOWHERE, so a plain
     # `worktree add --detach HEAD` gives a CLEAN checkout that omits it and
     # `review --base` then diffs empty (silent false-clean -- the bug this
     # fixes). Capture exactly the file set the Claude half reviews -- the paths
     # in `git diff HEAD` (staged + unstaged tracked changes, incl. staged new
     # files and deletions) -- into a snapshot commit WITHOUT touching the
     # shared HEAD or index, via a throwaway index. Untracked files are seen by
     # NEITHER half (see the warning below the block); this keeps [both] and
     # single-source attribution honest, and keeps machine-local untracked state
     # (e.g. hook-hydrated symlinks like .todos) out of the snapshot, where it
     # would abort the checkout below in every linked worktree.
     SNAP_BASE=$(git rev-parse HEAD)
     GIT_INDEX_FILE="$WT.idx" git read-tree HEAD \
       || { echo "co-review: read-tree failed -- aborting" >&2; exit 1; }
     # Enumerate into a guarded temp file -- not a blind pipe (a failed git diff
     # would degrade to an empty path list = false-clean) and not $(...)
     # (command substitution drops the NUL separators). Every plumbing step is
     # guarded: a partial xargs/write-tree failure would otherwise produce a
     # valid-looking but INCOMPLETE snapshot -- worse than a loud abort.
     git diff HEAD --name-only -z > "$WT.paths" \
       || { echo "co-review: diff enumeration failed -- aborting" >&2; exit 1; }
     GIT_INDEX_FILE="$WT.idx" xargs -0 -r git add -A -- < "$WT.paths" \
       || { echo "co-review: snapshot staging failed -- aborting" >&2; exit 1; }
     SNAP_TREE=$(GIT_INDEX_FILE="$WT.idx" git write-tree) \
       || { echo "co-review: write-tree failed -- aborting" >&2; exit 1; }
     rm -f "$WT.idx" "$WT.paths"
     SNAP_HEAD=$(git commit-tree "$SNAP_TREE" -p "$SNAP_BASE" -m "co-review snapshot") \
       || { echo "co-review: commit-tree failed -- aborting" >&2; exit 1; }
     # Same checkout-success guard as the other two modes: an untracked file
     # already sitting in $WT (e.g. an ignored symlink) can make this abort
     # and leave $WT at the pre-snapshot commit -- silently reviewing an
     # empty diff instead of failing loudly.
     git -C "$WT" checkout --detach "$SNAP_HEAD" \
       || { echo "co-review: checkout of $SNAP_HEAD into \$WT failed -- aborting, would review the wrong commit" >&2; exit 1; }
     [ "$(git -C "$WT" rev-parse HEAD)" = "$SNAP_HEAD" ] \
       || { echo "co-review: \$WT is at $(git -C "$WT" rev-parse HEAD), not $SNAP_HEAD -- aborting" >&2; exit 1; }
     ```

     `codex exec review --base "$SNAP_BASE"` run inside `$WT` (step 2) now sees
     the real change in every mode.
     In local-uncommitted mode, first check
     `git ls-files --others --exclude-standard`: when non-empty, warn that
     those untracked files are reviewed by NEITHER half -- name the count and
     tell the user to stage them to include them. This warning comes BEFORE the
     empty-diff guard so an untracked-only change still surfaces it instead of
     silently stopping. (A staged edit fully undone in the working tree nets to
     no change and is legitimately absent from the snapshot; the snapshot is
     the net worktree-vs-HEAD change.) Then run the mode-independent empty-diff
     guard before dispatching anything:
     `git -C "$WT" diff --quiet "$SNAP_BASE" "$SNAP_HEAD"`. Exit 0 = empty diff:
     tear down `$WT` per step 3.6, say so, and stop -- dispatch nothing (PR at
     its base, branch at its fork point, or nothing tracked changed locally).
     Exit 1 = a real diff: continue. Exit >1 = git error: tear down per step
     3.6 and abort loudly -- never treat an error as "different" or "empty".
     Every subagent dispatched below
     (step 2.5's attacker, step 3.5's skeptics) gets `$SNAP_BASE`/`$SNAP_HEAD`
     stated explicitly and is pointed at `$WT` with explicit read-only
     instructions — never "figure out the diff yourself," which risks a
     subagent inspecting a different or since-changed checkout.

   - Against that frozen diff, check each changed file's path,
     case-insensitive, for a whole path-segment match (a segment is text
     between `/`, `.`, `-`, or `_` — so this does not match `author` against
     `auth`, or `invalid` against `valid`) against: `auth`, `authorization`,
     `authentication`, `guard`, `gate`, `valid`, `validate`, `validator`,
     `validation`, `validators`, `permission`, `permissions`, `acl`, `verify`,
     `verification`, `credential`, `credentials`, `token`, `tokens`, `sign`,
     `signature`, `signatures`, `secret`, `secrets`, or a path under this
     repo's `claude/hooks/` whose filename contains `guard`, `review`, or
     `secret` (covers this repo's own `claude/hooks/block_secrets.py` and
     similar). Exclude any path under a `test`/`tests`/`spec`/`docs`/
     `examples` directory even if it matches (it exercises or documents a
     gate, it is not the gate). Example matches: `claude/hooks/commit_guard.py`,
     `src/auth/validator.py`, `src/permissions.ts`, `lib/tokens.go`. Example
     non-matches: `src/author_bio.py`, `tests/auth/test_login.py` (excluded
     by the `tests/` rule), `docs/signing-guide.md` (excluded by the `docs/`
     rule).
   - Record the **set of matched paths** (`gate_paths: {...}`); treat
     `gate_detected` as shorthand for "`gate_paths` is non-empty," not a
     separate value to track independently (one source of truth, so a future
     edit to the matching logic can't update one and silently leave the
     other stale). `gate_detected` gates step 2.5's attacker dispatch (probe
     the whole diff if any part of it is gate-like). `gate_paths` gates step
     3.5's per-finding escalation rule (escalate only a finding whose _own_
     file is in this set — a finding in an unrelated file elsewhere in the
     same diff does not escalate just because some other file in the diff
     happened to match).
   - Re-run this entire step independently on each review pass (initial pass
     and the bounded re-review in step 5), against that pass's own frozen
     diff — a fresh `gate_paths` each time.

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

   `codex exec review` has NO PR/GitHub concept — it only diffs the worktree
   it runs in against `--base`. Step 0 already put the reviewed code into the
   frozen worktree `$WT` and pinned `$SNAP_BASE` for every mode, so this step
   is one command run inside `$WT` — no per-mode branching, no worktree of its
   own to create or remove (step 0 owns `$WT`'s lifecycle; it is torn down
   in step 3.6, not here).

   ```bash
   CODEX_REVIEW_RUBRIC='Review adversarially. Prioritize runtime correctness, removed behavior, error handling, lifecycle and concurrency, auth and security boundaries, data or hardware safety, and missing regression tests. Report only actionable findings introduced by this diff; cite the file and line and explain a concrete failure scenario.'
   LOG=$(mktemp /tmp/coreview.XXXXXX)
   ( cd "$WT" && codex exec review --base "$SNAP_BASE" \
       -m gpt-5.6-sol -c model_reasoning_effort="high" \
       -c approval_policy="never" -c sandbox_mode="read-only" \
       "$CODEX_REVIEW_RUBRIC" ) > "$LOG" 2>&1
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
   - `review --base` only diffs **committed** changes, so a purely local
     uncommitted diff must already be captured into `$WT` as a commit — step 0
     does exactly that (its snapshot commit for local-uncommitted mode, the PR
     head for PR mode, the branch head for branch mode). This step never
     commits anything itself.
   - Codex runs inside step 0's frozen `$WT`, so it parallelizes with the
     Claude half without branch-switching the shared tree under a running stack.
   - **Target parity:** in PR mode both halves must review the _same_ PR — the
     Claude half gets the PR ref via `/code-review <pr>`, the Codex half reads
     the PR head that step 0 checked out into `$WT` and pinned as `$SNAP_HEAD`.
     Do not let Codex fall back to the local branch while Claude reviews the PR.
   - **Read findings from the log file with the Read tool** — do not rely on
     Bash-captured stdout, which truncates on long reviews. Use the final
     `codex` message block (after the header, before `tokens used`); ignore
     MCP/network warning lines. Delete the log after extracting.
   - **Verify Codex's findings against the code before relaying** — it surfaces
     real bugs (this repo's failure mode is compile-green/runtime-red, the class
     static checks miss), but confirm each before acting.

2.5. **Threat-model attacker (only if step 0's `gate_detected` is yes), run in
parallel with steps 1-2.** Dispatch one `Agent`-tool subagent (general-purpose,
fresh context) with: the full diff, step 0's frozen base/head
(`$SNAP_BASE`/`$SNAP_HEAD`, explicit, read-only) and the path to step 0's
frozen worktree `$WT` to Grep/Read the reviewed code from, and any governing
invariant the gate is meant to enforce —
pulled from the diff's own tests, docstrings, or comments, or an explicit
statement of intent if one exists in the task description. Its brief: never
invoke `codex exec` yourself, with or without a custom prompt — Bash access
does not exempt this subagent from the recursion hazard step 2 describes.

- If no governing invariant can be identified, stop and report
  `INCONCLUSIVE -- no stated policy to test against`. Do not guess intended
  behavior from the implementation and then "test" against that guess — an
  attack that only proves the implementation matches itself proves nothing.
- Otherwise, attempt at least 3 distinct concrete bypass vectors (specific
  call/input sequences) that would make the gate accept something the
  identified invariant says it should reject, where the gate's surface
  genuinely supports that many. For a narrow gate with fewer real distinct
  angles (e.g. a one-line permission check), attempt all of them and say
  explicitly how many distinct angles exist rather than padding the report
  with a contrived or near-duplicate vector to hit the count. Report each
  vector attempted and exactly what blocked it, or that it succeeded.
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
   reproduced by the attacker becomes `[claude+threat-model]`). If the
   composed finding's sources assigned it different severities, keep the
   higher (more severe) of the two — never silently keep a lower severity
   that understates a bypass's real impact. Any finding
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
code region, step 0's frozen base/head (`$SNAP_BASE`/`$SNAP_HEAD`, explicit,
read-only), and the path to step 0's frozen worktree `$WT` — a durable
checkout of the reviewed head that exists in **every** mode (PR head, branch
head, or the local-uncommitted snapshot commit), so the skeptic always has
real code to Grep/Read for callers, guards, tests, or contracts bearing on
the claim rather than defaulting to fail-closed for lack of a snapshot. Never
invoke `codex exec` yourself, with or without a custom prompt — Bash access
does not exempt this subagent from the recursion hazard step 2 describes.

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
returns `REFUTED` for a finding that meets _any_ of: tagged `[both]` (or any
composite tag including `threat-model`, per step 3); whose own file:line is
inside step 0's `gate_paths` set (not merely "somewhere in a diff that has a
gate-like file elsewhere"); or whose assigned severity is critical or high —
a single skeptic's say-so is not enough to silently demote a high-stakes
finding regardless of source or file. Dispatch 2 _additional_ independent
skeptics (3 verdicts total, none sees another's verdict). 2+ `REFUTED` ->
refuted; otherwise (including any fail-closed outcome) -> not refuted. This
bounds fan-out to at most 3 skeptic calls per finding, and only for findings
that are both refuted by the first pass and meet one of the three escalation
conditions.

Re-tier, do not delete: findings that survive (not refuted, single or
majority) sort first as today, by severity. Findings that are refuted sort
last, tagged `[refuted -- low confidence]` with the skeptic's one-line
rationale inline, also ordered by severity within that tier (same convention
as the survived tier, so a human skimming the refuted section can still find
the highest-severity suppressed finding first). Never silently dropped, and
never described as resolved or absent in chat or the PR comment.

Run this stage inside both the initial pass and the bounded re-review pass
(step 5) — it does not add a pass, it runs against whichever diff that
pass is reviewing.

3.6. **Tear down step 0's frozen worktree — unconditional finalization.** `$WT`
(and `$LOG`) must be removed on **every** exit path, not only when step 3.5
ran: the clean / empty-merge case where step 3.5 is skipped, the step-0
empty-diff early stop, and any error or abort anywhere in steps 0-3.5 (e.g.
step 0's PR-checkout guard exiting non-zero). `$WT` is a registered detached
worktree at a unique `mktemp -u` path, so a leaked one is **not** reaped by a
later run's `git worktree prune` (its directory still exists) — it lingers in
`git worktree list` and accumulates across runs. So treat this as finalization,
not a normal-path step: whichever exit path you reach, run the teardown once
before finishing.

```bash
git worktree remove --force "$WT"; git worktree prune; rm -f "$LOG"
```

The commands are safe to run even if a resource is already gone (`$LOG` may
never have been created if step 2 didn't run). Order still holds: `$WT` must
outlive the Codex finder (step 2), the attacker (step 2.5), and all skeptics
(step 3.5), which all read it — so on the normal path run this only after
step 3.5 has finished or been skipped, never before. Step 5's re-review re-runs
step 0 and provisions its own fresh `$WT` against the fix diff, so tearing this
one down here does not starve it.

4. **Resolve (triage-first).** Present the merged, tiered list: survived
   findings first, then any coverage note carried from the threat-model probe
   (step 2.5, folded in during step 3), then refuted findings last under a
   clear `[refuted -- low confidence]` heading. Ask which to fix; **default
   "fix all" applies to the survived tier only** — a refuted finding is fixed
   only if the human names it explicitly (e.g. "fix #N too"), since demotion
   already represents the skeptic's best-effort judgment that it's noise.
   Apply approved fixes to the working tree with Edit. Re-run the relevant
   tests/build to confirm. Track each finding's disposition (fixed / not
   fixed) as you go — step 5's carry-forward relies on this record, not on
   re-deriving it later.

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
     Using step 4's per-finding disposition record, carry every finding from
     pass 1 that is still not fixed (survived or refuted) into the final
     report in its existing tier; add pass 2's newly-found findings to the
     same two tiers. Before carrying a finding forward unchanged, check
     whether the fix commit touched the code its tier verdict relied on (the
     guard, caller, or contract a skeptic cited, or the invariant an attacker
     tested against) — if it did, reverify that finding against the pass-2
     snapshot instead of keeping the pass-1 tier automatically; a fix
     elsewhere in the diff can invalidate a prior refutation's evidence. The
     final report (step 4's re-presentation after pass 2, and step 6's PR
     comment) always reflects this union, not just pass 2's fresh merge — a
     finding is removed from the report only once it is actually fixed and
     verified, never merely because a later pass didn't re-flag it.
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
