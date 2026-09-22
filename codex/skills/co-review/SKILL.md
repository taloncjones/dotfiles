---
name: co-review
description: Freeze a finished change, collect four independent review seats, and evaluate one fail-closed final-gate report.
---

# Co-Review

This Codex adapter follows the canonical gate extracted from
`claude/skills/co-review/gate-policy.md`. It is a final gate, not an advisory
development review. It produces one report and stops; use `review-change` for
development feedback. The canonical policy's bounded `co-review --fix`
coordinator is the sole exception: an explicit user invocation supplies its
scoped repair authorization, and existing development authorization also covers
that handoff.

Use plain `co-review` for this one read-only gate. `--fix` names the bounded
coordinator invocation; it is not an option for `review.py` or
`gate_report.py`. Follow the canonical policy to validate a reusable current
`CHANGES` report, repair only confirmed blockers in one separate implementer
batch, run regression tests and one independent `review-change`, and then run
one follow-up verification on the repaired head using the canonical
carried-coverage rules. All outcomes stop the entire calling workflow; only
new explicit user direction after a stop can authorize another cycle. It never
auto-edits advisory findings, recurses, or converts incomplete or stale
evidence into a repair budget.

Resolve this installed adapter and its helpers before entering the target
repository. Never resolve paths relative to the repository being reviewed.

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
required = (
    "claude/skills/co-review/scripts/review.py",
    "claude/skills/co-review/scripts/gate_report.py",
    "claude/hooks/agent_runtime.py",
)
if root is None or not all((root / name).is_file() for name in required):
    raise SystemExit("Installed final-gate helpers are unavailable")
print(root)
PYROOT
) || exit 2
REVIEW_HELPER="$REVIEW_ROOT/claude/skills/co-review/scripts/review.py"
GATE_REPORT="$REVIEW_ROOT/claude/skills/co-review/scripts/gate_report.py"
RUNNER="$REVIEW_ROOT/claude/hooks/agent_runtime.py"
```

The `policy` and `schema` commands are authoritative. Do not embed another
policy, infer an approval from comments, or continue if policy extraction or
schema inspection fails.

The coordinator independently creates and retains a fresh expected-identity JSON
separate from the report before the snapshot. It gets repository, PR number, full head,
full base, base branch, committed tree, and CI for the actual target. Verify
that the PR target repository is the fetch target before resolving `--base-ref`.
Prepare and verify one frozen snapshot with `review.py prepare` and
`review.py verify`; a dirty source is still frozen for findings, but a committed
tree mismatch makes approval incomplete. A local no-PR review cannot fabricate a
PR number or claim `APPROVE`. Capture and hash the frozen added-line diff and
exact-head CI payload as precondition artifacts.

Use an empty helper-owned `SNAPSHOT_DIR` only for `review.py prepare` output and
parse `MANIFEST` from that command's JSON result. Keep the expected identity,
prompts, native completion artifacts, frozen diff, normalized CI envelope, and
`report.json` in `RUN_DIR`. This lets `review.py cleanup --manifest` remove only
the verified snapshots while retaining the active gate evidence.

For a follow-up, also supply each seat the retained initial report and actual
artifact paths/digests, prior head/base/tree, repair delta and affected callers.
Follow the canonical Follow-up evidence section: inspect affected contracts,
identify invalidated prior coverage, and cite evidence for carried entries.
The full frozen change remains available as context; it is not an instruction
to restart an unrestricted search. The current report binds the current tree
and CI; prior evidence cannot supply current approval authority. A full review
required by scope/coverage changes stops for a new user decision.

Load the canonical material into the active report directory, then resolve each
seat before launch. A route that is unavailable or unsupported stops the gate.

```bash
POLICY=$(uv run --no-project python "$GATE_REPORT" policy --section POLICY) || exit 2
uv run --no-project python "$GATE_REPORT" schema >"$RUN_DIR/gate-schema.json" || exit 2
uv run --no-project python "$RUNNER" route --runtime claude --role reviewer --risk normal --provisional >"$RUN_DIR/claude.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role reviewer --risk normal --provisional >"$RUN_DIR/codex.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role skeptic --risk normal --provisional >"$RUN_DIR/breaker.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role skeptic --risk normal --provisional >"$RUN_DIR/verifier.route.json"
```

Export `RUN_ID` from that file so later steps name the run without re-reading
the report:

```bash
RUN_ID=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["run_id"])' "$EXPECTED_IDENTITY") || exit 2
```

Compute the changed-file set and pin the base tip before any seat starts:

Compute the changed-file set from the verified manifest, never from the
caller: it is the three-dot change, and `--no-renames` lists both sides of a
rename. For a PR, cross-check GitHub's list one-directionally (every PR path
must be in the frozen set; the frozen set may be larger because `prepare`
folds local work into the snapshot) and check head identity directly. Then
resolve the base tip exactly once and pin it for the run.

```bash
# co-review-changed-files:start
: "${REPO:?}" "${RUN_DIR:?}" "${MANIFEST:?}" "${RUN_ID:?}" "${REVIEW_HELPER:?}"
read -r BASE SNAPSHOT_HEAD HEAD <<EOF2
$(uv run --no-project python -c 'import json,sys; m=json.load(open(sys.argv[1])); print(m["source"]["base"], m["snapshot"]["snapshot_head"], m["source"]["head"])' "$MANIFEST")
EOF2
[ -n "$BASE" ] && [ -n "$SNAPSHOT_HEAD" ] && [ -n "$HEAD" ] || exit 2
git -C "$REPO" diff --name-only --no-renames -z "$BASE" "$SNAPSHOT_HEAD" >"$RUN_DIR/changed-files.nul" || exit 2
tr '\0' '\n' <"$RUN_DIR/changed-files.nul" >"$RUN_DIR/changed-files.raw" || exit 2
rm -f -- "$RUN_DIR/changed-files.nul"
LC_ALL=C sort "$RUN_DIR/changed-files.raw" >"$RUN_DIR/changed-files.txt" || exit 2
[ -s "$RUN_DIR/changed-files.txt" ] || exit 2
rm -f -- "$RUN_DIR/changed-files.raw" "$RUN_DIR/base-context.json.tmp"
# Exactly one resolve-base per run: a second fetch could return a newer tip
# and the seats would judge one finding against two different bases.
[ ! -e "$RUN_DIR/base-context.json" ] || exit 2
# A PR gate is keyed on BASE_REF (prepare ran with --base-ref) and must name
# its PR; a local review has neither. Any other pairing is a caller error.
if [ -n "${BASE_REF:-}" ]; then
  : "${PR_NUMBER:?}"
  gh pr view "$PR_NUMBER" --json headRefOid,changedFiles,files >"$RUN_DIR/pr-files.json" || exit 2
  uv run --no-project python - "$RUN_DIR/pr-files.json" "$RUN_DIR/changed-files.txt" "$HEAD" <<'PY' || exit 2
import json, sys
pr = json.load(open(sys.argv[1]))
frozen = set(open(sys.argv[2]).read().splitlines())
if pr["headRefOid"] != sys.argv[3]:
    raise SystemExit("PR head is not the frozen source head")
listed = {f["path"] for f in pr["files"]}
if pr["changedFiles"] > len(listed):
    print(f"warning: provider listed {len(listed)} of {pr['changedFiles']} files; containment checked on the listed subset", file=sys.stderr)
missing = sorted(listed - frozen)
if missing:
    raise SystemExit("PR paths absent from the frozen change:\n" + "\n".join(missing))
extra = sorted(frozen - listed)
if extra and pr["changedFiles"] <= len(listed):
    print("frozen paths beyond the PR (local work in the snapshot):\n" + "\n".join(extra), file=sys.stderr)
PY
  uv run --no-project python "$REVIEW_HELPER" resolve-base \
    --repo "$REPO" --base-ref "$BASE_REF" --head "$HEAD" >"$RUN_DIR/resolve-base.json" || exit 2
  uv run --no-project python - "$RUN_DIR/resolve-base.json" "$BASE" "$RUN_ID" "$RUN_DIR/base-context.json" <<'PY' || exit 2
import datetime, json, os, sys
resolved = json.load(open(sys.argv[1]))
if resolved["base"] != sys.argv[2]:
    raise SystemExit("merge-base moved since prepare; the frozen inputs are stale")
resolved["run_ref"] = f"refs/co-review-run/{sys.argv[3]}"
resolved["resolved_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
tmp = sys.argv[4] + ".tmp"
with open(tmp, "x") as out:
    json.dump(resolved, out, sort_keys=True)
    out.flush()
    os.fsync(out.fileno())
os.replace(tmp, sys.argv[4])
PY
  BASE_TIP=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["base_ref_tip"])' "$RUN_DIR/base-context.json") || exit 2
  git -C "$REPO" update-ref "refs/co-review-run/${RUN_ID}" "${BASE_TIP}" || exit 2
else
  [ -z "${PR_NUMBER:-}" ] || exit 2
  # Local --base review: no remote tip. Unchanged-path claims are merge-base content.
  printf '{"base": "%s", "base_ref": null, "base_ref_tip": null, "run_ref": null, "resolved_at": "%s"}\n' \
    "$BASE" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$RUN_DIR/base-context.json.tmp" || exit 2
  mv "$RUN_DIR/base-context.json.tmp" "$RUN_DIR/base-context.json" || exit 2
fi
# co-review-changed-files:end
```

Each nonzero exit here is `INCOMPLETE`. A failed manifest read leaves `read`
returning 0 with empty variables, and a pipeline's status is its last
command's, so the block checks the three values, writes the diff before
sorting, and refuses an empty set: an empty changed-file set would refute
every finding. The PR path is keyed on `BASE_REF` and requires `PR_NUMBER`;
the `else` branch is the local no-PR review and refuses a stray `PR_NUMBER`.

| Stop                                                                    | Durable evidence that survives                                                                                                                       | Who can destroy it                | Recovery                                                                                                                                                                   |
| ----------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Merge-base moved since prepare                                          | `RUN_DIR`, manifest, snapshot worktrees                                                                                                              | `review.py cleanup`, the operator | Run cleanup, then a fresh gate: new `run_id`, new prepare. Policy already voids a run whose base changed.                                                                  |
| PR head is not the frozen head, or PR paths missing from the frozen set | same                                                                                                                                                 | same                              | The snapshot froze the wrong head or the PR moved. Fresh gate against the live PR head.                                                                                    |
| `resolve-base` fails (offline, fork origin, no merge-base)              | same                                                                                                                                                 | same                              | Retry once. Still failing: `INCOMPLETE`; a PR gate never falls back to snapshot content for unchanged paths. Only `--base` local reviews use the labelled merge-base mode. |
| Crash between `resolve-base` and prompt writing                         | `base-context.json` is written to `.tmp` and moved into place with `os.replace`, so it is either absent or complete; a stale `.tmp` is removed first | same                              | Absent: run the block again (the guard permits it). Present: reuse it; do not resolve again.                                                                               |
| Crash between seats or before the provenance check                      | `base-context.json`, `changed-files.txt`, the run ref                                                                                                | same                              | Reuse the files. The run ref keeps the tip readable until finalize.                                                                                                        |
| Interruption after finalize deleted the run ref                         | finding `evidence` and `snapshot_integrity` name the tip; objects may be pruned                                                                      | `git gc`, the operator            | Ship step 5 presents the recorded dispositions and evidence; no fresh reads. A later reader that cannot `git show` the tip records an evidence gap.                        |

Run `gate_report.py schema` before report assembly. Resolve each fresh seat
with the shared runner and `--provisional`; this records unknown availability
honestly and stops if the route is actually unavailable or unsupported. Run four
fresh, independent read-only 600-second seats:
`claude` reviewer, `codex` reviewer, `breaker` skeptic, then `verifier` skeptic
after the first three artifacts are complete. Every prompt includes the
extracted policy, frozen diff, manifest identity, the complete `## Classes`
section of the failure-class rubric, and
declared threat model. The verifier also receives first-seat artifact
paths/digests and known blockers. Save each runner JSON response as that seat's
nonempty artifact and preserve requested and observed route metadata. The
controller never stands in for a seat.

The Claude seat uses the resolved original-account route through the bounded
runner and preserves its raw response as the `claude` artifact:

```bash
uv run --no-project python "$RUNNER" run \
  --runtime claude --role reviewer --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$RUN_DIR/claude.prompt" >"$RUN_DIR/claude.runtime.json"
```

From Codex, the `codex`, `breaker`, and `verifier` seats are fresh native
children after route resolution. The native spawn API has no timeout or sandbox
arguments: give each an explicit read-only, disposable-fixture task and use the
coordinator's 600-second deadline to interrupt an unfinished child. Record its
actual completion artifact. Do not invoke `codex exec`, a generic `/code-review`
plugin, or a nested partner route. The Claude seat preserves the
original repository's account scope through the runner. Every seat is
adversarial and read-only; it uses only disposable fixtures and does not fix,
publish, comment, or merge.

For each native seat, build a complete rendered review packet from actual
frozen values, never placeholders: repository identity; `snapshot.codex_root`;
base, head, expected tree, and reviewed tree; frozen diff path and digest;
target repository/PR/base-branch identity; the extracted policy; full rubric;
declared threat model; and changed-symbol callers; the contents of
`RUN_DIR/changed-files.txt` (verified non-empty before use; a missing or
empty file is `INCOMPLETE`, never a dispatch with a blank changed-file set)
and `RUN_DIR/base-context.json`; and the read form
`git -C <seat root> show <base_ref_tip>:<path>` for any path outside the
changed-file set. A finding that says this change touched a path outside that
set is a stale-base artifact the seat discards. State the requested finding
format (including concrete impact for any material allegation),
disposable-fixture/read-only limits, and permission to consult relevant
reference skills under the canonical policy. Require the reviewer to do the
review itself, without another review workflow, delegated reviewers, partners,
network actions, comments, fixes or merge actions.

Dispatch the `codex` reviewer and `breaker` through the native `spawn_agent`
API with `fork_turns: "none"`, `model` and `reasoning_effort` taken from their
exact parsed `RUNNER route` JSON. The resulting messages contain the complete
packet above and no controller history or other seat output. Keep the returned
handles. The existing Claude seat uses the same full packet without either
native report.

Wait for Claude, Codex, and breaker to complete and collect their actual native
or runner results before continuing. The coordinator uses `wait_agent` for each
native handle and a 600-second deadline; it uses `interrupt_agent` only after a
deadline. A failed, timed-out, empty, or malformed completion stops as
incomplete. Store each successful completion as its named report-relative
artifact and record its digest.

Only after those three artifacts and digests exist, render the verifier packet.
It includes the same full frozen-value packet, the named Claude/Codex/breaker
artifact paths and digests, and the expected known blockers. It includes no
other controller history. Dispatch the verifier with native `spawn_agent`,
`fork_turns: "none"`, and its parsed skeptic-route `model` and
`reasoning_effort`; then wait, collect, validate, and hash its completion using
the same deadline rules. The verifier independently tests material claims,
accounts for every blocker and reconciles the combined coverage ledger. It
does not start another unrestricted search.

Before writing `findings`, check every seat finding's provenance against
`RUN_DIR/changed-files.txt` and `RUN_DIR/base-context.json` (never a fresh
`resolve-base`). A finding that asserts this change added, modified, deleted,
or reverted a path outside the changed-file set is a stale-base artifact:
keep its ID and severity, set `disposition: refuted`, and put the
changed-file set check in `evidence`. For every other finding read the cited
content from the snapshot head tree (changed path) or
`git -C "$REPO" show <base_ref_tip>:<path>` (unchanged path) and record what
was read together with the tip SHA; a failed read is an evidence gap on that
finding. Set `snapshot_integrity` to name how many stale-base artifacts were
refuted and the tip SHA they were checked against (the report schema has no
tip field, so evidence strings are where the tip survives). A
deletion or reversion claim is the riskiest shape; new added lines verified
in the head tree are the safe shape.

Create `report.json` from the exact `gate_report.py schema` example. Fill all
fields from the verified manifest, independent expected identity, actual four
runtime artifacts and SHA-256 digests, frozen diff/CI artifact digests,
findings, prior blocker dispositions, and required coverage. Paths are report
relative. Do not substitute coordinator prose for a missing or unsuccessful
runtime completion. Then verify, evaluate, and clean up:

```bash
# co-review-finalize:start
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST" || exit 2
if uv run --no-project python "$GATE_REPORT" evaluate \
  --report "$RUN_DIR/report.json" --expected "$EXPECTED_IDENTITY" \
  >"$RUN_DIR/evaluation.json"; then
  evaluation_status=0
else
  evaluation_status=$?
fi
if uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST" \
  >"$RUN_DIR/cleanup.json"; then
  cleanup_status=0
else
  cleanup_status=$?
fi
if [ "$cleanup_status" -ne 0 ]; then
  rm -f -- "$EXPECTED_IDENTITY"
  printf '%s\n' '{"verdict":"INCOMPLETE","approve_allowed":false,"reasons":["snapshot cleanup failed; evidence preserved"]}' >&2
  exit 2
fi
if [ -z "${REPO:-}" ] || [ -z "${RUN_ID:-}" ] \
  || ! git -C "$REPO" update-ref -d "refs/co-review-run/${RUN_ID}"; then
  rm -f -- "$EXPECTED_IDENTITY"
  printf '%s\n' '{"verdict":"INCOMPLETE","approve_allowed":false,"reasons":["run ref removal failed; evidence preserved"]}' >&2
  exit 2
fi
cat "$RUN_DIR/evaluation.json"
exit "$evaluation_status"
# co-review-finalize:end
```

This marked block finalizes one plain gate only. A `--fix` coordinator runs it
as a per-gate subprocess, retains its structured evaluation and cleanup output,
and validates them before proceeding. A nonzero exit is not permission to
ignore an evaluator, verification, or cleanup failure.

Only `APPROVE` permits a merge-ready result. `CHANGES` returns concrete
blockers to development. `INCOMPLETE` reports missing evidence. Human approval
and explicit merge permission remain separate; cleanup refusal preserves the
snapshot.
