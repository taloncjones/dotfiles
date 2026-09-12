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

Claude reviews `snapshot.claude_root` through its native `/code-review` flow.
That worktree is based at the pinned base and has the reviewed tree applied to
its index. It is the Claude half, not a substitute for Codex.

The independent Codex finder runs from `snapshot.codex_root` through the shared
runtime runner. It selects the policy model and effort and returns structured
runtime metadata; this skill never restates a route table.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-codex.XXXXXX")
cat >"$PROMPT_FILE" <<EOF
Review only the frozen change against base $BASE. Report each actionable issue
as severity, file:line, failure scenario, and concrete fix. End with one
verdict. Do not invoke skills, partners, or external actions.
EOF
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

One pass is not a gate. A **complete round** = freeze the committed head, run both
finders (Claude `/code-review` + the Codex runner), plus any bounded attacker or
skeptic required by the frozen paths, plus the skeptic verification of
high-severity findings. A round that leaves any required finder or verification
incomplete cannot approve (co-review's "incomplete, never a clean review" rule).

1. Run a complete round.
2. Post that round's comment first -- the verdict table plus the hidden marker at
   the reviewed head (see "Review provenance marker") -- **before** committing any
   fix for the round. Then apply confirmed fixes with verified repros, re-run the
   affected tests, and commit and push. Posting before the fix commits keeps the
   marker's `sha` (the reviewed head) above its own fixes on the PR timeline
   rather than buried beneath them.
3. Re-freeze the new committed head and run another complete round. Repeat.
4. Return **APPROVE** only when a complete round yields zero unresolved
   actionable findings. A finding that reappears unfixed is still actionable --
   not a dismissible "duplicate". "Duplicate/non-actionable" means only: already
   fixed and re-surfaced against old code, explicitly confirmed wontfix, or
   out-of-scope for this change.
5. Bound it: at most **5 complete rounds total** (the first round plus up to 4
   re-reviews). Print each round's actionable-finding count. Escalate -- stop and
   ask for a structural fix -- at the cap without APPROVE, or earlier when the
   only remaining findings are genuinely non-actionable. Do not hard-stop merely
   because a round's count failed to strictly decrease: real bugs can persist
   across rounds.

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
