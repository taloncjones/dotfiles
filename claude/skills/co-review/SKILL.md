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
the fresh reviewer only the round's defined inputs -- the frozen snapshot, the
base, the failure-class rubric (`references/failure-classes.md` in this skill
directory), and the carried blockers when the previous round left any -- never
the authoring session's rationalizations. It is the Claude half, not a
substitute for Codex. Controller disk-verification of a fix is not a substitute
for either half.

Finder context is the diff, the call sites of every changed symbol, and the
repository conventions -- never a bare file, never a bare hunk. Finders report
severity, file:line, failure scenario, and concrete fix. They rule on nothing.

Decorrelate the two finder halves' reading order. Mechanism: from the frozen
diff's changed paths, build two reading-order lists -- one in natural diff
order (`git diff --name-only <base>` order), one grouped by subsystem
(directory or module grouping the orchestrator picks when freezing the round
and records in the round's comment). Append one list to each half's prompt as
"Read and probe the changed paths in this order". Both halves still read the
same frozen snapshot; only the prescribed traversal differs. Structured
reordering measurably changes which defects a reviewer finds; random shuffling
degrades reviewer accuracy and is not used. The attacker and the verification
seat receive no reading-order list.

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

When the previous round left blocking findings, append that worklist -- one
line each: severity, file:line, one-line summary -- to both halves' prompts
before dispatch, under the instruction "Report what you find about each of
these against the frozen tree; you discharge nothing."

Use the runner only; do not launch a generic or nested Codex CLI review. Pass
`--risk critical` only for explicitly critical review risk, never diff size.
Record requested route separately from runtime-reported model or effort; unknown
observation remains unknown. A failed, malformed, or unsupported result makes
the independent pass incomplete.

## Verification

Every finding passes one adversarial verification seat before it is posted.
Run at most one attacker alongside it when frozen changed paths affect auth,
authorization, validation, permission, credentials, tokens, signatures,
secrets, or a review or guard hook; it states a concrete bypass scenario.
Resolve each fresh Codex role through `agent_runtime.resolve_route` with role
`reviewer` or `skeptic` (the verification seat's runtime role); never select a
model or effort ad hoc.

A finding is CONFIRMED when the seat can construct a concrete failure path
reachable under some input or configuration that the frozen code permits.
Production occurrence is not required and must never be demanded: a feasible
exploit is confirmed whether or not the triggering data exists today.

A finding is REFUTED only when the seat disproves a premise against the frozen
tree by tracing an ENFORCING restriction along the reported failure path: code
in that tree forbids the configuration the finding needs, a guard refuses
first, or the cited path cannot execute. Naming the enforcing artifact is
required.

Enumeration is not enforcement. A registry, fixture or config file that lists
only one value proves what is listed, not that anything else is rejected. If a
second entry point accepts an unlisted value, the premise stands. A seat that
can find only an enumeration returns UNRESOLVED.

Missing context is neither. When the seat lacks a fact it needs, it retrieves
that fact from the frozen tree. If the fact is not determinable from the frozen
tree, the finding stays UNRESOLVED and is treated as confirmed for blocking
purposes. Absence of evidence is never refutation.

REFUTED findings are dropped outright: never recorded, never carried forward.
CONFIRMED and UNRESOLVED findings are posted.

Apply confirmed fixes within existing user authorization, after the round's
comment is posted (see Rounds and continuity); otherwise ask before editing
source files. After all readers finish, remove only this run's snapshots:

```bash
uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"
```

Cleanup refuses foreign roots, marker mismatches, modified trees, ignored or
untracked snapshot files, and unexpected owned-output entries. Preserve the
snapshot if it refuses cleanup.

## Blocking

Major, high and critical findings block. Minor, low, nit and advisory do not.
An unrecognized, missing, or seat-disputed severity blocks. An UNRESOLVED
finding blocks exactly as a CONFIRMED one of its severity does. The floor does
not vary by round in this slice.

## Rounds and continuity

A round is one full review of the current head; there are no round types and no
caps. Before round 1 the author walks `references/failure-classes.md` against
their own diff and fixes what it catches -- a self-audit, not a round, and it
posts nothing.

Every finding that was blocking in the previous round -- CONFIRMED or
UNRESOLVED alike -- is carried into the current round as a worklist. Finders
receive it as context and report on it, but finders discharge nothing.

Only the verification seat may discharge a carried blocker, and only on
frozen-tree evidence that the failure path is repaired or that a necessary
premise is now enforced against. This is the same authority and the same
evidence standard it applies to a fresh finding; a carried blocker is not a
second kind of thing.

A carried blocker stays blocking when its disposition is missing, unverified,
or disputed between seats. An incomplete review fails closed, exactly as
UNRESOLVED does. Continuity needs no bookkeeping file of its own: the PR
comment thread is the durable record and GitHub owns its persistence.

Findings that were never blocking are not carried; they are posted once. A
finding that reappears unfixed is still actionable, not a dismissible
"duplicate" -- that label means only: already fixed and re-surfaced against old
code, explicitly confirmed wontfix, or out-of-scope for this change.

Post the round's comment first (findings table + marker), **before** committing
any fix; then apply confirmed fixes with verified repros, re-run the affected
tests, commit, push, and run the next round at the new head. A round that
leaves no blocking finding ends the loop with APPROVE.

When a round's blocking findings cluster across more than one subsystem, the
round output MAY carry a `RECOMMEND SPLIT` line naming the seams; raise the
split question with the user immediately after that round and pause the loop on
their answer.

**Seat evidence rule.** Every seat -- both finder halves, the attacker, the
verification seat -- counts only when its runtime artifact exists: the Codex
runner's structured result (session id, success status) or the dispatched
Claude reviewer's agent result or report file. In a Codex-led run (the
codex/skills adapter reviews in-session rather than through a nested runner),
the Codex half's evidence is that session's own bounded findings output plus
its resolved route metadata. A narrated dispatch with no artifact is not a
dispatch, and a round claiming completion without an artifact for every
required seat is incomplete, never clean. Cite each seat's artifact (runner
session id or report path) in the round's comment.

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

On every completed round, post one comment, by the authenticated `gh` user,
carrying both the findings table and the marker. Post it before committing the
round's fixes so the marker's `sha` sits above those fix commits on the
timeline. Lead with the table (clearer than bullets), then the hidden currency
marker as its own unindented top-level line:

```markdown
### Co-review round <n>

| Severity | File:line       | Issue | Status | Fix |
| -------- | --------------- | ----- | ------ | --- |
| HIGH     | path/file.py:42 | ...   | open   | ... |

Seats: <runner session ids / report paths>. Grouping: <subsystem order>.

(Status is open, or RESOLVED for a carried blocker the verification seat
discharged this round; "No actionable findings." replaces the table when the
round is clean.)

<!-- co-review: sha=<head> base=<merge-base> base_ref=<branch> verdict=<APPROVE|CHANGES> round=<n> target_tip=<tip> -->
```

The `Seats:` line carries the seat-evidence rule's citations and the round's
subsystem grouping. It is gate-neutral: a top-level line that does not begin
with the marker prefix is ignored by the marker scanner, and the `|` table row
(or the clean sentence) already satisfies the gate's findings-body check.

The findings body is matched mechanically, not read. `pr_ready_gate.py` accepts
only an unindented top-level line that begins with `|`, or one equal to the
literal `No actionable findings.` byte for byte. Bolding that sentence,
dropping its period, indenting it, or rewording it fails the gate closed: it
reports a marker with no findings table, /pr-ready says re-run co-review, and
rerunning a clean round reproduces the same failure every time.

`sha` is the frozen committed head, `base` the resolved merge-base from
`--base-ref`, `base_ref` the PR target branch, `round` the count of prior
trusted markers on the PR plus one, and `verdict` APPROVE only when the round
leaves no blocking finding and no undischarged carried blocker.

`target_tip` is the target branch tip the review compared against, recorded for
the reader. It is the LAST field, after `round`: appending keeps every marker
written before this change parseable, and that order is the only one the gate's
regex accepts. The gate never compares `target_tip`, so an approval does not
expire when the target moves; a target change that breaks the PR is CI's job.

`pr_ready_gate.decide()` PASSes on a trusted marker with `verdict=APPROVE`,
`sha == head`, and matching base and base_ref. The latest trusted round comment
by creation instant governs, so a later CHANGES supersedes an earlier APPROVE
on the same head and a retried publish is benign -- the later copy carries the
same verdict for the same head. Selection happens BEFORE validation: the gate
picks the latest marker-bearing comment, then validates it. A malformed latest
comment -- a marker with no findings table, or unusable ordering metadata --
fails the gate closed. It is never skipped in favour of an older comment,
because skipping it would let a truncated CHANGES expose a superseded APPROVE.

The marker line must be exactly one per comment, unindented, and outside the
table and any code fence, so `scripts/pr_ready_gate.py` accepts it. A quoted,
fenced, indented or other-author marker is invisible to the gate; a latest
comment carrying more than one marker line fails the gate closed.

**Emit APPROVE only for a snapshot that equals the committed head.** `prepare`
folds staged and unstaged changes into the reviewed tree, but the marker's `sha`
names the committed head -- so an uncommitted local fix could earn an APPROVE
whose `sha` still points at the buggy committed head, and the gate would pass for
content that was never on the PR. For a PR review, freeze with a **clean working
tree** and confirm `snapshot.codex_tree == source.source_tree` in the manifest
before posting APPROVE; never emit an APPROVE marker for a dirty snapshot whose
tree differs from its head.

The merge enforces the reviewed head server-side, via
`gh pr merge --match-head-commit <the marker's sha>`. A local re-read before
merging is not sufficient: an ordinary push between the read and the merge call
would consume an unreviewed head. Gate PASS is not a durable licence to merge a
later head, and the server, not the client, enforces that.

An interrupted round that has not published its comment leaves no authority
behind: its snapshot and seat outputs are discarded and the round is rerun from
freeze. Nothing partial is reused, because REFUTED findings are deliberately
unrecorded and a partial round cannot be shown complete. Publication is the
only durable transition.

The gate stays binary. There is no acknowledged-with-known-issues state. To
merge past CHANGES a human merges deliberately, and that act is the record.

## Document reviews

Plan/spec review skills require an explicit document, task id, runtime, and the
same absolute helper. Artifact output is always private under the selected
account/repository/task payload root; an explicit output directory must be a
single direct launch subdirectory there. The helper records caller-selected task id, account
id, and repository id. The coordinator validates the digest and containment under the selected
account/repository/task payload root before accepting a planning milestone;
retain the helper metadata as provenance, not as an independent ownership proof. Plans live under
`docs/superpowers/plans/`; specs live under `docs/superpowers/specs/`.
