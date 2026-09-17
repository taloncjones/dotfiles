---
name: co-review
description: Freeze one code change, obtain independent Claude and Codex findings, then verify them before fixing.
---

# Co-Review

Freeze one change, take two independent reads of it, post the verdict, fix what
blocks. Use it after implementation and before a merge.

## What this review is for

Three questions, in this order:

1. **Is the code sound?** Does it do what it is meant to do, on the paths
   ordinary use reaches.
2. **Does it match what it says?** Docstrings, skill prose, docs and tests
   describing the same behaviour the code has.
3. **Do the callers still work?** Every call site of every changed symbol, and
   every other consumer of a shared thing the diff touches.

Those three block. Everything else is advisory: report it once, in one line,
and move on. A review that returns only advisory findings is a clean review.

## Threat model

The only caller of this repository's tooling is us, running it on our own
machines against our own repositories. Do not review for adversarial input,
privilege escalation, multi-tenant isolation, secret exfiltration or hostile
local configuration unless the frozen diff genuinely crosses a trust boundary:
untrusted network input, credentials, another account's data, or a repository
we do not control.

A failure that requires the operator to work against their own tool -- deleting
their own blocking comment, hand-editing a marker into nonsense, setting a
config nobody sets -- is not a finding. Say so in one line and drop it.

## Resolve the helper

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

Resolve the helper to an absolute path before changing to the target
repository. Never invoke it through a path relative to that repository.

## Freeze

Both readers read one frozen snapshot. Do not publish, comment, or modify the
source checkout during preparation.

```bash
test -f "$REVIEW_HELPER" || { echo "co-review helper is unavailable" >&2; exit 2; }
# PR review: resolve the base from the PR's real target branch.
uv run --no-project python "$REVIEW_HELPER" prepare --repo "$REPO" --base-ref "$BASE_REF" \
  --output-dir "$REVIEW_OUTPUT"
# Local / plan / no-PR review: pin an explicit base commit instead.
#   ... prepare --repo "$REPO" --base "$BASE" ...
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST"
```

For a PR, first confirm `origin` is the PR's base repository: compare
`git remote get-url origin` to `gh api repos/{owner}/{repo}/pulls/<n> -q
.base.repo.full_name`. On a fork PR `origin` is the contributor's fork and
resolving the base there is wrong; fetch the verified target remote or stop.
Then pass `--base-ref <baseRefName>`. The helper fetches that origin branch
read-only and diffs against the merge-base (three-dot, matching GitHub "Files
changed"), so a stale local base cannot invent findings for commits already on
the target. Use `--base <sha>` only when there is no PR.

An empty diff, a helper failure, or empty reader output is an incomplete
review, never a clean one.

## Preconditions

Run these before dispatching any seat. They are facts rather than judgments,
they cost nothing, and a model is the wrong tool for noticing them.

```bash
git -C "$REPO" diff "$BASE"..."$HEAD" >"$REVIEW_OUTPUT/diff.txt"
gh pr view "$PR" --json headRefOid,statusCheckRollup >"$REVIEW_OUTPUT/checks.json"
uv run --no-project python "$REVIEW_ROOT/claude/skills/co-review/scripts/preconditions.py" \
  --head "$HEAD" --diff-file "$REVIEW_OUTPUT/diff.txt" \
  --checks "$REVIEW_OUTPUT/checks.json"
```

Two checks: CI green for exactly this head, since a green run on an older
commit is not a green run on this one; and no provisional marker -- `TEMP`,
`TODO`, `FIXME`, `XXX`, `HACK`, `revert before merge` -- introduced by the
diff's added lines. Omit `--checks` when there is no PR; the CI check then
records itself as skipped rather than passing.

**A failure does not stop the round.** Reviewing red or half-finished code is
legitimate, and often the fastest way to learn why it is red. Report the result
at the top of the round comment and carry on. What a failure forbids is the
approval: `approve_allowed: false` makes the round's verdict CHANGES whatever
the seats report.

## Two reads

The Claude half MUST be a fresh Claude instance -- a dispatched reviewer
subagent -- pointed at `snapshot.claude_root`. The implementing session MUST
NOT review its own diff; "it's a small diff, I'll just read it myself" is the
biased self-review this gate exists to prevent. Give the reviewer the frozen
snapshot, the base, the three questions, the threat model, and the checklist in
`references/failure-classes.md` -- never the authoring session's reasoning
about why the change is fine.

Reader context is the diff, the call sites of every changed symbol, and the
repository's conventions. Never a bare file, never a bare hunk.

Decorrelate the two halves' reading order: give one half the changed paths in
natural diff order and the other the same paths grouped by subsystem. Record
the grouping in the round's comment.

Both halves dispatch with role `finder`, which the runner resolves to model
and effort. A finder reports what it sees and rules on nothing, so it does not
need the `reviewer` tier; this skill does not restate the route table. The
Codex half runs from `snapshot.codex_root`. Dispatch the Claude half through
the runner too when its effort matters -- an in-session subagent inherits the
controller's effort and never consults the route table.

```bash
uv run --no-project python "$RUNNER" run --runtime codex --role finder --risk normal \
  --provisional --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Use the runner only; never a nested Codex CLI review. Pass `--risk critical`
only for genuinely critical review risk, never for diff size. A failed or
malformed result makes that half incomplete.

**Seat evidence.** A seat counts only when its artifact exists: the runner's
structured result, or the dispatched reviewer's returned report. A narrated
dispatch is not a dispatch. Cite each seat in the round's comment.

## Blocking

A finding blocks when it is one of the three questions above: the code does not
work on a path ordinary use reaches, the code contradicts its own
documentation or tests, or a caller is broken. Nothing else blocks.

## Verification

Verify only the findings that would block; advisory findings are posted as
reported. One seat is enough, dispatched fresh through the runner with role
`skeptic`.

The finding justifies itself. It survives when the seat can state a concrete
failure path that ordinary use reaches. It is dropped when the path needs a
configuration nobody runs, an operator working against their own tool, or a
premise the seat cannot establish from the frozen tree. Ties go to dropping,
and a dropped finding is not recorded and not carried.

**That tie-breaker covers findings only. It never covers coverage.** Dropping a
marginal finding keeps rounds short; declaring ground clear on thin evidence is
how a gate lies to you. When a caller, contract or consumer lives outside the
frozen tree -- an unpopulated submodule, a service reached over the network,
real hardware -- report it as NOT DETERMINABLE FROM THE FROZEN TREE and name
what you could not see. Never as a pass. A reviewer that cannot check something
says so rather than inferring the answer from a test fake or a lone fixture,
because a fake proves only what the fake does.

Run an attacker seat only when the frozen diff crosses a trust boundary as
defined under Threat model. That is the exception, not the default.

## Rounds

A round is one full review of the current head. Post the round's comment
first, then apply the confirmed fixes, re-run the affected tests, commit, push,
and run the next round at the new head if anything blocked. A round that
leaves nothing blocking ends the loop with APPROVE.

Blocking findings are fixed, not tracked. The next round reads the new head and
either finds the problem again or does not, so there is no carried-blocker
bookkeeping and no separate continuity file. The PR thread is the record.

Before round 1 the author reads `references/failure-classes.md` against their
own diff and fixes what it catches. That is a self-audit, not a round, and it
posts nothing.

If rounds keep finding new unrelated problems rather than converging, stop and
say so: that is a signal the change is too large or the review scope is too
broad, and it is a question for the human, not another round.

## Round comment and provenance marker

On every completed round, post one comment as the authenticated `gh` user,
carrying the findings table and the marker, before committing that round's
fixes.

```markdown
### Co-review round <n>

| Severity | File:line       | Issue | Blocking | Fix |
| -------- | --------------- | ----- | -------- | --- |
| MAJOR    | path/file.py:42 | ...   | yes      | ... |

Seats: <runner session ids / report paths>. Grouping: <subsystem order>.

<!-- co-review: sha=<head> base=<merge-base> base_ref=<branch> verdict=<APPROVE|CHANGES> round=<n> target_tip=<tip> -->
```

`sha` is the frozen committed head, `base` the merge-base resolved from
`--base-ref`, `base_ref` the PR target branch, `round` a human-readable label,
`target_tip` the target branch tip compared against, and `verdict` APPROVE only
when nothing blocks and the preconditions allowed it. `target_tip` is the LAST field; that order is the only one
the gate's regex accepts.

`pr_ready_gate.decide()` PASSes on a trusted marker with `verdict=APPROVE`,
`sha == head`, and matching base and base_ref. The latest trusted round comment
governs, so a later CHANGES supersedes an earlier APPROVE on the same head.

The findings body is matched mechanically, not read. The gate accepts only a
top-level line beginning with `|`, or one equal to the literal
`No actionable findings.` byte for byte. Indenting it four spaces or a tab puts
it in a code block and it stops counting; bolding it, rewording it, or dropping
its period fails the gate closed. The marker must be exactly one per comment,
unindented, and outside the table and any code fence.

**Emit APPROVE only for a snapshot that equals the committed head.** `prepare`
folds staged and unstaged changes into the reviewed tree while the marker's
`sha` names the committed head, so freeze a PR review with a clean working tree
and confirm `snapshot.codex_tree == source.source_tree` in the manifest before
posting APPROVE.

Merging enforces the reviewed head server-side via
`gh pr merge --match-head-commit <the marker's sha>`. A local re-read before
merging is not sufficient. Gate PASS is not a durable licence to merge a later
head.

An interrupted round that has not published its comment leaves no authority
behind: rerun it from freeze. Publication is the only durable transition.

The gate stays binary. To merge past CHANGES a human merges deliberately, and
that act is the record.

## Cleanup

After both readers finish, remove only this run's snapshots:

```bash
uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"
```

Cleanup refuses foreign roots, marker mismatches, modified trees, and
unexpected owned-output entries. Preserve the snapshot if it refuses.

## Coworker PR review (`--comment`)

Reviewing someone else's PR, handing back a verdict. No fixes are applied here;
the author writes the fix. The same three questions and the same threat model
apply.

Binding gate first:

```bash
uv run --no-project python "$REVIEW_ROOT/claude/skills/co-review/scripts/repo_binding.py" \
  --repo "$REPO" --pr-url "$PR_URL"
```

A non-zero exit means `origin` does not bind to the PR's base -- stop, or fetch
the verified base remote. The PR URL is the independent identity for this
check; never derive it from `origin`.

Output per round: a findings table `| Severity | File:line | Issue | Blocking |`
with no `Fix` column, a visible `VERDICT: APPROVE` or
`VERDICT: REQUEST CHANGES` line, and the hidden coworker marker from
`scripts/coworker_review.py`'s `build_marker(...)`. Compute the verdict with
`verdict_from_findings(findings)` and fill `Blocking` with
`is_blocking(severity)`.

For a re-review, read the latest trusted coworker marker with
`select_coworker_marker(comments, {gh_user})`, compute `is_ancestor` via
`git merge-base --is-ancestor <prev_sha> <new_head>`, and call
`decide_review_scope(...)`. On `full`, re-diff the whole PR three-dot. On
`incremental`, review `prev_head..new_head` and re-check every still-open prior
finding against the new tree. The verdict gates on all currently-open blocking
findings.

This mode never emits the own-PR currency marker. A coworker's PR is not your
pr-ready gate.

## Document reviews

Plan and spec review skills require an explicit document, task id, runtime, and
the same absolute helper. Artifact output is always private under the selected
account/repository/task payload root. Plans live under
`docs/superpowers/plans/`; specs under `docs/superpowers/specs/`.
