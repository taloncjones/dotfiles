---
name: co-review
description: Freeze a finished change, collect two or four independent review seats by change class, and evaluate one fail-closed final-gate report.
---

# Co-Review

This is a final gate for a finished PR or explicitly pinned local change. It
produces one `APPROVE`, `CHANGES`, or `INCOMPLETE` report and stops. Development
reviews use `review-change`; this skill neither fixes findings nor starts a
repeat review loop. The canonical policy's bounded `co-review --fix` coordinator
is the sole exception: an explicit user invocation supplies its scoped repair
authorization, and existing development authorization also covers that handoff.

Use plain `co-review` for this one read-only gate. `--fix` names the bounded
coordinator invocation; it is not an option for `review.py` or
`gate_report.py`. The coordinator may begin with this fresh gate or validate a
current finalized `CHANGES` report as the policy requires. It hands only
confirmed blockers to one separate implementer batch, requires regression tests
and one independent `review-change` review, then runs one follow-up verification
on the repaired head using the canonical carried-coverage rules. All outcomes
stop the entire calling workflow; only new explicit user direction after a
stop can authorize another cycle. Do not use it for advisory edits,
recursive repairs, redesign, a stale report, or an incomplete result.

Resolve this installed skill first. The helper path is never relative to the
repository under review.

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

`policy` and `schema` are the sole policy and report-schema sources. A missing
anchor, malformed schema, or command error is `INCOMPLETE`; do not copy a
fallback policy into this adapter.

## Freeze and bind the invocation

The coordinator creates an expected identity before preparing the snapshot and
retains it independently in `RUN_DIR`, separate from the report. It obtains PR repository, number, head,
base branch, base SHA, and CI from the live PR. For a PR, confirm that `origin`
is the target repository before using `--base-ref`; a fork's `origin` is not a
valid target source. A local no-PR review may return `CHANGES` or `INCOMPLETE`
but cannot claim PR readiness or `APPROVE`; it cannot fabricate a PR number.
The expected JSON must match the output shape printed by `gate_report.py schema`,
includes a fresh `run_id`, and supplies `known_blockers` as an empty list when
there are none.

Do not read historical comments or markers for authority. Record a dirty source
checkout, but still freeze it for findings; equality of the committed expected
tree and reviewed tree is required later for approval. `SNAPSHOT_DIR` is empty
and reserved only for `review.py`; `RUN_DIR` holds prompts, runtime results,
diff, CI, expected identity, and report. Prepare and verify one snapshot:

```bash
POLICY=$(uv run --no-project python "$GATE_REPORT" policy --section POLICY) || exit 2
uv run --no-project python "$GATE_REPORT" schema >"$RUN_DIR/gate-schema.json" || exit 2
git -C "$REPO" status --porcelain >"$RUN_DIR/source-status.txt"
uv run --no-project python "$REVIEW_HELPER" prepare \
  --repo "$REPO" --base-ref "$BASE_REF" --output-dir "$SNAPSHOT_DIR" >"$RUN_DIR/prepare.json"
# Local no-PR review uses `--base "$BASE"` instead of `--base-ref`.
# Parse the returned JSON's `manifest` field; do not assume its filename.
MANIFEST=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["manifest"])' "$RUN_DIR/prepare.json")
uv run --no-project python "$REVIEW_HELPER" verify --manifest "$MANIFEST"
```

Read `source.base`, `source.head`, `source.repo_id`, `source.source_tree`,
`snapshot.codex_root`, `snapshot.claude_root`, and `snapshot.codex_tree` from
the verified manifest. `source.source_tree` binds `expected.tree` and
`snapshot.codex_tree` binds `report.reviewed_tree`; their mismatch is incomplete
for approval, not an early review abort. Capture the frozen diff and CI JSON
response for that exact expected head:

```bash
git -C "$REPO" -c core.quotePath=true diff --no-color --no-ext-diff --no-textconv --no-renames --binary \
  "$BASE" "$CODEX_TREE" >"$RUN_DIR/frozen.diff" || exit 2
# A failed capture can leave a partial diff that classifies light; never use it.
CLASS=$(uv run --no-project python "$GATE_REPORT" classify --diff "$RUN_DIR/frozen.diff") || exit 2
# `co-review --full` sets CLASS=full here regardless of the classifier.
```

Both artifacts live inside `RUN_DIR`, are hashed after capture, and are
referenced by the report's `preconditions` fields defined by `schema`. Write
`CLASS` into the expected identity's `class` field before any seat runs.

For a follow-up, also supply each seat the retained initial report and actual
artifact paths/digests, prior head/base/tree, repair delta and affected callers.
Follow the canonical Follow-up evidence section: inspect affected contracts,
identify invalidated prior coverage, and cite evidence for carried entries.
The full frozen change remains available as context; it is not an instruction
to restart an unrestricted search. The current report binds the current tree
and CI; prior evidence cannot supply current approval authority. A full review
required by scope/coverage changes stops for a new user decision.

## Dispatch and collect seats

The full tier runs `claude`, `codex`, and `breaker`, then `verifier`. The
light tier runs `codex` and `verifier`: the `codex` reviewer command below,
then the verifier with that one finder artifact; skip `claude` and `breaker`.

Probe every runner route the tier uses before spending seats. Each probe is a
60-second `Reply ok` run on that seat's route and snapshot root, written under
`RUN_DIR` (never the manifest output dir, which `cleanup` checks). The probes
run concurrently. Any non-success probe stops co-review with the existing
incomplete report, quoting the probe's `status`, `observation` and `errors`.
A failed probe never switches runtime on its own; a substitute seat is an
explicit, truthfully recorded operator decision. A probe is never a seat
artifact.

```bash
printf 'Reply ok\n' >"$RUN_DIR/probe.prompt"
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 60 \
  --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json" &
uv run --no-project python "$RUNNER" run \
  --runtime claude --role skeptic --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
  --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-skeptic.json" &
if [ "$CLASS" != "light" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime claude --role reviewer --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-reviewer.json" &
  uv run --no-project python "$RUNNER" run \
    --runtime codex --role skeptic --risk normal --provisional \
    --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-skeptic.json" &
fi
wait
uv run --no-project python - "$RUN_DIR"/probe-*.json <<'PY' || exit 2
import json
import sys

failed = []
for path in sys.argv[1:]:
    try:
        with open(path) as handle:
            result = json.load(handle)
    except (OSError, ValueError):
        failed.append(f"{path}: no runner JSON")
        continue
    if result.get("status") != "success":
        failed.append(f"{path}: {result.get('status')} {result.get('observation')} {result.get('errors')}")
if failed:
    print("\n".join(failed))
    sys.exit(1)
PY
```

Save the exact `POLICY`, frozen diff, and the complete `## Classes` section of
`$REVIEW_ROOT/claude/skills/co-review/references/failure-classes.md`, manifest
identity, expected identity, and declared threat model in each prompt. The
finder prompts are independent. Each requests structured findings with a
stable ID, severity, disposition, scenario, evidence, concrete material impact,
coverage evidence or gap, and a verdict. A runtime result is an artifact only when the runner
returns a genuine successful completion; preserve requested and observed route
metadata from that result.

```bash
RUBRIC="$REVIEW_ROOT/claude/skills/co-review/references/failure-classes.md"
grep -q '^## Classes' "$RUBRIC" || exit 2
SEATS="claude codex breaker verifier"
[ "$CLASS" = "light" ] && SEATS="codex verifier"
for seat in $SEATS; do
  sed -n '/^## Classes/,$p' "$RUBRIC" >>"$RUN_DIR/$seat.prompt"
done
```

Seats run concurrently for up to 1200 seconds each, beyond a foreground
command limit: a Claude coordinator runs each seat block with the Bash
tool's `run_in_background` and waits for its completion notification (or a
Monitor until-loop on the runtime JSON files) before continuing. Worst case is
about 41 minutes: probes, finders, then the verifier.

```bash
# Light tier: only the codex reviewer seat. Full tier: also claude and breaker.
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 1200 \
  --prompt-file "$RUN_DIR/codex.prompt" >"$RUN_DIR/codex.runtime.json" &
if [ "$CLASS" != "light" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime claude --role reviewer --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 1200 \
    --prompt-file "$RUN_DIR/claude.prompt" >"$RUN_DIR/claude.runtime.json" &
  uv run --no-project python "$RUNNER" run \
    --runtime codex --role skeptic --risk normal --provisional \
    --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 1200 \
    --prompt-file "$RUN_DIR/breaker.prompt" >"$RUN_DIR/breaker.runtime.json" &
fi
wait
```

The Claude invocation preserves the original repository's selected account;
the runtime runner resolves it rather than an inherited snapshot account. A
Codex-led controller creates a native fresh Codex seat through this runner and
does not use a nested generic CLI review. Every prompt permits relevant
reference skills under the canonical policy and requires the reviewer to do
the review itself. It must not launch another review workflow, delegate
reviewers, invoke a partner, post feedback, fix code, or act outside disposable
fixtures.

After every finder artifact exists (full: `claude`, `codex`, `breaker`; light:
`codex`) and its digest is recorded, run the verifier with role `skeptic` and
the same frozen snapshot. Its prompt also contains the finder artifact
paths/digests and all known blockers; it tests their material claims
independently, accounts for each blocker and reconciles the combined coverage
ledger. It does not start another unrestricted search. Do not give current
finder reports to the finder seats; the retained initial baseline is shared
only for follow-up verification.

```bash
uv run --no-project python "$RUNNER" run \
  --runtime claude --role skeptic --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 1200 \
  --prompt-file "$RUN_DIR/verifier.prompt" >"$RUN_DIR/verifier.runtime.json" &
wait
```

The selected reviewer/skeptic runtime for each seat is resolved by the shared
runner. For explicitly critical risk, set only that seat's `--risk critical`.
An unknown observed model or effort stays unknown; no completion, empty output,
failed runner result, bad digest, or missing seat is an incomplete report.

## Assemble, evaluate, and clean up

The Claude snapshot root is the base commit plus the frozen patch applied
with `git apply --index`, so its staged diff is by design. Cleanup refuses a
root holding any other untracked, ignored or staged path and names up to five
of them; remove what a seat left (for example a stray cache) or re-run from a
fresh `prepare`.

Run `gate_report.py schema` now and start `RUN_DIR/report.json` from its exact
example.
Fill it from the manifest, expected identity, raw runtime artifacts, their
SHA-256 digests, the frozen diff/CI artifact digests, and only actual findings
and coverage. Keep every path report-relative. Populate the `seats` entries
for `CLASS` (`schema` lists `light_seats` and `full_seats`) and set
`report.class` to `CLASS`; put their raw runtime JSON paths and observed
metadata in the fields named by the schema. Never replace a
failed runtime result with coordinator prose. Token presence is advisory context;
unfinished behavior blocks only with a concrete material consequence.

Verify once more before evaluating. The expected file remains the independent
current-workflow authority; it is never copied from the report.

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
cat "$RUN_DIR/evaluation.json"
exit "$evaluation_status"
# co-review-finalize:end
```

This marked block finalizes one plain gate only. A `--fix` coordinator runs it
as a per-gate subprocess, retains its structured evaluation and cleanup output,
and validates them before proceeding. A nonzero exit is not permission to
ignore an evaluator, verification, or cleanup failure.

Only evaluator `APPROVE` exits zero. `CHANGES` returns concrete blockers to
development. `INCOMPLETE` reports missing or invalid evidence. Required human
approvals and explicit merge permission are separate. Cleanup refusal preserves
the snapshot and is reported; no source checkout is modified during the gate.
