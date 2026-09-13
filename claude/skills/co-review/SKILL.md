---
name: co-review
description: Freeze one code change, obtain independent Claude and Codex findings, then verify them before fixing.
---

# Co-Review

Set `REVIEW_SKILL_FILE` to this skill's absolute `SKILL.md` path supplied by
the skill loader. Resolve installed symlinks before using a helper. If the
loader supplies no path, the existing `DOTFILEDIR` is the fallback; never guess
from the target checkout or another account's skill directory.

```bash
REVIEW_ROOT=$(uv run --no-project python - "${REVIEW_SKILL_FILE:-}" "${DOTFILEDIR:-}" <<'PYROOT'
from pathlib import Path
import sys

source, fallback = sys.argv[1:]
if source and (not Path(source).is_absolute() or Path(source).name != "SKILL.md"):
    raise SystemExit("Use the absolute SKILL.md path supplied by the skill loader")
root = Path(source).resolve(strict=True).parents[3] if source else (
    Path(fallback).expanduser().resolve(strict=True) if fallback else None
)
required = ("claude/skills/co-review/scripts/review.py", "claude/hooks/agent_runtime.py")
if root is None or not all((root / name).is_file() for name in required):
    raise SystemExit("Installed review helpers are unavailable")
print(root)
PYROOT
) || exit 2
REVIEW_HELPER="$REVIEW_ROOT/claude/skills/co-review/scripts/review.py"
RUNNER="$REVIEW_ROOT/claude/hooks/agent_runtime.py"
```

Use this skill after implementation and before a merge. Both finders read one
frozen snapshot. Do not publish, comment, fetch, or modify the source checkout
during review preparation.

Before changing to the target repository, resolve the helper to an absolute
path. Never invoke a helper through a path relative to the target repository.

```bash
test -f "$REVIEW_HELPER" || { echo "co-review helper is unavailable" >&2; exit 2; }
# PR review: resolve the base from the PR's real target branch.
uv run --no-project python "$REVIEW_HELPER" prepare --repo "$REPO" --base-ref "$BASE_REF" \
  --output-dir "$REVIEW_OUTPUT" --include-untracked path/inspected-first
# Local / plan / no-PR review: pin an explicit base commit instead.
#   ... prepare --repo "$REPO" --base "$BASE" ...
```

For a PR review first confirm `origin` is the PR's base repository: compare
origin's real fetch URL (`git remote get-url origin`) to the base repo from the
pulls REST response (`gh api repos/{owner}/{repo}/pulls/<n> -q
.base.repo.full_name`; `baseRepository` is not a `pr view` field). On a fork PR
`origin` is the contributor's fork and resolving the base there is wrong; fetch
the verified target remote or stop. Then pass `--base-ref <baseRefName>` (the PR's target
branch from `gh pr view --json baseRefName`). The helper fetches that origin branch
read-only into an invocation-owned ref and diffs against the merge-base
(three-dot, matching GitHub "Files changed"), so a stale local base cannot
produce phantom findings for commits already on the target. Use `--base <sha>`
only for local or plan review with no PR target. The base-ref fetch is a read
that establishes the diff target; the no-mutate-source rule (do not publish,
comment, or modify the checkout during preparation) still holds -- the only ref
written is the invocation-owned `refs/co-review/*`, deleted before return.

Require explicit repository, base (`--base` XOR `--base-ref`), output directory,
and untracked paths. The helper captures the committed head plus staged and
unstaged changes through a temporary index, accepts only explicitly named
regular untracked paths, and rejects symlinks, private paths, inherited Git
routing, source drift, and tree mismatch. Its manifest pins
base/base_ref/base_ref_tip/head/tree, source identity, two worktrees,
scope/exclusions, and an ownership nonce.

```bash
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST"
```

An empty diff, helper failure, empty finder output, or malformed bounded output
is incomplete, never a clean review.

## Claude-led dispatch

The Claude half MUST be performed by a fresh Claude instance -- a dispatched
reviewer subagent or the `/code-review` flow that spawns fresh review agents --
pointed at `snapshot.claude_root`, which is based at the pinned base with the
reviewed tree applied to its index. The implementing or authoring session MUST
NOT review its own diff inline; "the diff is small, I'll just review it
myself" is exactly the biased self-review this gate exists to prevent. Give
the fresh reviewer only the round's defined inputs -- for a complete round the
frozen snapshot, the base, and the failure-class rubric
(`references/failure-classes.md` in this skill directory); for a scoped round
additionally the prior findings table and the fix diff -- never the authoring
session's rationalizations. It is the Claude half, not a substitute for
Codex. Controller disk-verification of a fix is not a substitute for either
half.

The independent Codex finder runs from `snapshot.codex_root` through the shared
runtime runner. It selects the policy model and effort and returns structured
runtime metadata; this skill never restates a route table.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<'EOF'
Review only the frozen change against the base commit named below. Probe
every failure class in the rubric appended below against this diff, then any
further issues. Report each actionable issue as severity, file:line, failure
scenario, and concrete fix. End with one verdict. Do not invoke skills,
partners, or external actions.
EOF
printf '\nBase: %s\n\n' "$BASE" >>"$PROMPT_FILE"
RUBRIC="$REVIEW_ROOT/claude/skills/co-review/references/failure-classes.md"
grep -q '^## Classes' "$RUBRIC" || { echo "rubric Classes heading missing" >&2; exit 2; }
sed -n '/^## Classes/,$p' "$RUBRIC" >>"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run --runtime codex --role reviewer --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

For a scoped round, build the prompt from the prior findings and the fix
diff instead (`$PREV_HEAD` is the previously reviewed head from the last
posted marker, `$HEAD` the newly frozen committed head this round reviews,
`$FINDINGS_FILE` the prior round's findings table saved locally; the diff
read from the source repository is a read, not a mutation):

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<'EOF'
Scoped re-review of the frozen change. For each prior finding listed below,
return ADDRESSED or NOT-ADDRESSED against the frozen tree with one line of
evidence. Then report any new actionable issue in the fix diff below ONLY,
as severity, file:line, failure scenario, and concrete fix. End with one
verdict. Do not invoke skills, partners, or external actions.
EOF
printf '\nPrior reviewed head: %s\nCurrent head: %s\n\nPrior findings:\n' \
  "$PREV_HEAD" "$HEAD" >>"$PROMPT_FILE"
cat "$FINDINGS_FILE" >>"$PROMPT_FILE"
printf '\nFix diff:\n' >>"$PROMPT_FILE"
git -C "$REPO" -c diff.external= diff --no-ext-diff --no-textconv \
  "$PREV_HEAD..$HEAD" >>"$PROMPT_FILE" || { echo "fix diff failed" >&2; exit 2; }
uv run --no-project python "$RUNNER" run --runtime codex --role reviewer --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Use the runner only; do not launch a generic or nested Codex CLI review. Pass
`--risk critical` only for explicitly critical review risk, never diff size.
Record requested route separately from runtime-reported model or effort; unknown
observation remains unknown. A failed, malformed, or unsupported result makes
the independent pass incomplete.

## Bounded attacker and skeptic

Run at most one attacker when frozen changed paths affect auth, authorization,
validation, permission, credentials, tokens, signatures, secrets, or a review
or guard hook. It states a concrete bypass scenario. Run at most one skeptic to
reproduce high-severity findings and mark each confirmed, disproved, or
uncertain. Resolve each fresh Codex role through `agent_runtime.resolve_route`
with role `reviewer` or `skeptic`; never select a model or effort ad hoc.

Merge only findings checked against the frozen files. Retain uncertain or
unsupported high-severity findings as unresolved and do not return a clean
verdict while a required finder or skeptic is incomplete. Apply confirmed fixes
within existing user authorization; otherwise ask before editing source files.
After all readers finish, remove only this run's snapshots:

```bash
uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"
```

Cleanup refuses foreign roots, marker mismatches, modified trees, ignored or
untracked snapshot files, and unexpected owned-output entries. Preserve the
snapshot if it refuses cleanup.

## Re-review loop

One pass is not a gate. Two round types:

- **Complete round**: freeze the committed head; both finders -- the fresh
  Claude reviewer and the Codex runner -- review the whole frozen diff,
  probing every class in `references/failure-classes.md`; plus any bounded
  attacker or skeptic required by the frozen paths; plus skeptic
  verification of high-severity findings. A round that leaves any required
  finder or verification incomplete cannot approve.
- **Scoped round**: freeze the committed head; both independent halves
  (fresh Claude reviewer AND Codex runner -- never only the half that
  raised a finding) receive the prior round's findings table and the
  fix diff since the last posted round (prior reviewed head to new
  head). Each half returns
  a per-finding verdict, ADDRESSED or NOT-ADDRESSED with one-line
  evidence, plus any new actionable findings in the fix diff only. Skip
  the attacker/skeptic unless a fix touched the sensitive paths that
  trigger them. For a trivial fix the fresh Claude pass may be a
  cheap-tier reviewer, but it must exist.

**Seat evidence rule.** Every seat in every round -- finder halves,
attacker, skeptic, scoped halves -- counts only when its runtime
artifact exists: the Codex runner's structured result (session id,
success status) or the dispatched Claude reviewer's agent result or
report file. In a Codex-led run (the codex/skills adapter reviews
in-session rather than through a nested runner), the Codex half's
evidence is that session's own bounded findings output plus its resolved
route metadata. A narrated dispatch with no artifact is not a dispatch. A
round claiming completion without an artifact for every required seat
is incomplete, never clean. Cite each seat's artifact (runner session
id or report path) in the round's comment.

Sequence:

0. **Pre-freeze self-audit.** Before round 1, the author walks
   `references/failure-classes.md` against their own diff and fixes what
   it catches. Not a review round; posts nothing.
1. **Round 1: complete round.** Any clean complete round -- round 1
   included -- terminates the loop with APPROVE (zero actionable
   findings, clean tree).
2. Post the round's comment first (findings table + marker,
   verdict=CHANGES) -- **before** committing any fix -- then apply
   confirmed fixes with verified repros, re-run the affected tests,
   commit and push.
3. **Scoped round** at the new committed head. Any NOT-ADDRESSED verdict
   or new finding: fix (repeating step 2's post-then-fix order) and run
   another scoped round. A clean scoped round advances to the final
   complete round.
4. **Final complete round** at the committed head. Zero actionable
   findings = APPROVE. Otherwise classify each finding per distinct
   defect (both halves reporting the same underlying defect is one
   finding):
   - **fix-regression** -- introduced by a fix commit. When provenance is
     disputed or cannot be established against the round-1 tree, classify
     as fix-regression. Fix it (repeating step 2's post-then-fix order),
     then return to step 3.
   - **new-surface** -- present since round 1; a rubric miss. Fix it
     (repeating step 2's post-then-fix order), and grow the rubric: in
     the rubric's own repository add or generalize the class in the same
     commit as the fix; from any other repository record the missed
     class and update the rubric as a separate authorized dotfiles
     change. Then return to step 3. New-surface findings never count
     toward divergence.

   **Divergence:** two complete rounds in one loop that each contain at
   least one fix-regression finding. Stop and escalate for a structural
   fix.

5. **Caps:** at most 3 complete rounds and at most 3 scoped rounds per
   PR. Print each round's type and actionable count. The cap check
   applies to the round about to start: a clean scoped round always
   advances to the final complete round while complete-round capacity
   remains, even with the scoped cap exhausted. Stop and escalate only
   when the next required round would exceed its own type's cap without
   APPROVE. Real bugs can persist across rounds: never hard-stop merely
   because a count failed to strictly decrease; the caps and the
   divergence rule are the only stop conditions.

A finding that reappears unfixed is still actionable -- not a dismissible
"duplicate". "Duplicate/non-actionable" means only: already fixed and
re-surfaced against old code, explicitly confirmed wontfix, or
out-of-scope for this change.

Worked examples (trace each against the sequence above):

- **Clean round 1:** complete round finds nothing, tree clean -> APPROVE.
  1 round.
- **Happy path:** round 1 (complete) finds 3 issues -> post, fix -> round
  2 (scoped) all ADDRESSED, no new findings -> round 3 (final complete)
  clean -> APPROVE. 3 rounds.
- **Scoped cap exhausted:** rounds 2-4 are scoped (a fix kept leaving one
  NOT-ADDRESSED); round 4 comes back clean. Scoped cap (3) is now spent,
  but the next required round is complete and only 1 complete round has
  run -> advance to the final complete round. Clean -> APPROVE.
- **Divergence:** final complete round finds a defect introduced by a fix
  (fix-regression #1) -> fix -> scoped round clean -> second final
  complete round finds another fix-introduced defect (fix-regression in a
  second complete round) -> divergence -> stop, escalate.

## Coworker PR review (`--comment`)

Use this mode to review someone else's PR and hand back a verdict, not to run
the own-PR loop above. No fixes are applied here -- the author writes the fix;
fixing a coworker's branch yourself is the own-PR loop against a local
checkout of it, not this mode.

Binding gate first: run

```bash
uv run --no-project python "$REVIEW_ROOT/claude/skills/co-review/scripts/repo_binding.py" \
  --repo "$REPO" --pr-url "$PR_URL"
```

A non-zero exit means `origin` does not bind to the PR's base (a fork or the
wrong remote) -- stop, or fetch the verified base remote before continuing.
The PR URL is the independent identity for this check; never derive it from
`origin`. The origin probe runs with `GIT_*` routing stripped so an inherited
`insteadOf` cannot make it disagree with the fetch that co-review `prepare`
performs.

Known limitation: the SSH resolution mirrors `git`'s connection via `ssh -G`
with the URL's user and port, but does not parse a repo-local
`core.sshCommand`. A `core.sshCommand` that rewrites the destination host is
outside this check's threat model (it requires control of the reviewer's own
git config); the binding assumes no such override.

Per-round output:

1. A findings table `| Severity | File:line | Issue | Blocking |` -- no `Fix`
   column, since the author writes the fix, not this review.
2. A visible `VERDICT: APPROVE` or `VERDICT: REQUEST CHANGES` line.
3. The hidden coworker marker from
   `claude/skills/co-review/scripts/coworker_review.py`'s `build_marker(...)`.

Compute the verdict with `coworker_review.verdict_from_findings(findings)`:
major/high/critical findings are blocking, minor/low/nit/advisory are
advisory, and an unrecognized severity fails closed to blocking. Fill each
row's `Blocking` column with `coworker_review.is_blocking(severity)`.

Re-review scope: read the latest trusted coworker marker with
`coworker_review.select_coworker_marker(comments, {gh_user})`; compute
`is_ancestor` via `git merge-base --is-ancestor <prev_sha> <new_head>`; then
call `coworker_review.decide_review_scope(prev_marker, new_head,
current_base_ref, current_base_ref_tip, is_ancestor)`. On `full`, re-diff the whole PR
(three-dot). On `incremental`, review `prev_head..new_head` and also re-check
every still-open prior finding against the new tree -- an incremental diff
alone can miss a finding whose surrounding code moved. The verdict always
gates on all currently-open blocking findings, not just the ones from this
round's diff.

This mode never emits the own-PR currency marker (`co-review: ...` from
"Review provenance marker" below). A coworker's PR is not your pr-ready gate.

## Review provenance marker

On every completed round, post one PR comment, by the authenticated `gh` user,
that is both human-readable and machine-parseable. Post it before committing the
round's fixes (per the "Re-review loop" order) so the marker's `sha` sits above
those fix commits on the timeline. Lead with a findings **table** (clearer than
bullets), then the hidden currency marker as its own unindented top-level line:

```markdown
### Co-review round <n>

| Severity | File:line       | Issue | Fix |
| -------- | --------------- | ----- | --- |
| HIGH     | path/file.py:42 | ...   | ... |

(or "No actionable findings." when the round is clean)

<!-- co-review: sha=<reviewed-head-sha> base=<resolved-merge-base> base_ref=<baseRefName> verdict=<APPROVE|CHANGES> round=<n> -->
```

`sha` is the frozen committed head, `base` the resolved merge-base from
`--base-ref`, `base_ref` the PR target branch, `verdict` APPROVE only on a
zero-actionable complete round.

**Emit APPROVE only for a snapshot that equals the committed head.** `prepare`
folds staged and unstaged changes into the reviewed tree, but the marker's `sha`
names the committed head -- so an uncommitted local fix could earn an APPROVE
whose `sha` still points at the buggy committed head, and the gate would pass for
content that was never on the PR. For a PR review, freeze with a **clean working
tree** and confirm `snapshot.codex_tree == source.source_tree` in the manifest
before posting APPROVE; never emit an APPROVE marker for a dirty snapshot whose
tree differs from its head.

The marker line must be exactly one per comment,
unindented, and outside the table/any code fence, so `scripts/pr_ready_gate.py`
accepts it -- the gate and `ship`'s resume rule parse the latest such marker by
comment creation instant and ignore quoted, fenced, indented, multiply-markered,
or other-author comments.

## Document reviews

Plan/spec review skills require an explicit document, task id, runtime, and the
same absolute helper. Artifact output is always private under the selected
account/repository/task payload root; an explicit output directory must be a
single direct launch subdirectory there. The helper records caller-selected task id, account
id, and repository id. The coordinator validates the digest and containment under the selected
account/repository/task payload root before accepting a planning milestone;
retain the helper metadata as provenance, not as an independent ownership proof. Plans live under
`docs/superpowers/plans/`; specs live under `docs/superpowers/specs/`.
