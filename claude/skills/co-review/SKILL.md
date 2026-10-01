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
# `co-review --delta` may set CLASS=delta in "Delta tier" below, never by itself.
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

## Delta tier

`co-review --delta` asks for the delta round: the `claude` reviewer seat
and the `verifier`, both on Claude routes, scoped to a small follow-up
after a full APPROVE on this branch. The first round on a branch is always
full. The prior report and expected identity come with their SHA-256
digests from exactly one source: the pinned `ship.json` a herdr ship brief
names in `herdr-ship-prior-handoff:`, or this same uninterrupted workflow's
own retained full gate. Caps default to `MAX_FILES=5` and `MAX_LINES=150`;
a herdr brief's `herdr-ship-delta-caps: <files>/<lines>` replaces them.

After the snapshot verifies and before the expected identity exists, ask
for the recommendation. `HEAD` is the manifest's `source.head`:

```bash
DELTA=0
uv run --no-project python "$GATE_REPORT" delta-class --repo "$REPO" \
  --report "$PRIOR_REPORT" --expected "$PRIOR_EXPECTED" \
  --report-sha256 "$PRIOR_REPORT_SHA256" --expected-sha256 "$PRIOR_EXPECTED_SHA256" \
  --head "$HEAD" --max-files "$MAX_FILES" --max-lines "$MAX_LINES" \
  --diff-out "$RUN_DIR/delta.diff" >"$RUN_DIR/delta-class.json" && DELTA=1
```

`DELTA=0` recommends `full`: keep the classifier's `CLASS` and report the
recommendation's `reasons`. A herdr brief whose `herdr-ship-delta-head:`
differs from `$HEAD` also keeps it. Otherwise approve the delta once. A
personal repository (`claude/skills/lib/workflow_context.py account-scope
--cwd "$REPO" --runtime claude` reports `personal_repository` true)
proceeds. A work repository, or an unavailable `account-scope`, asks the
owner with `AskUserQuestion`, options "Delta round (Recommended)" and
"Full round", naming the PR, head, caps and the recommendation's `stats`.
A herdr brief line `herdr-ship-brief: tier=delta` is that approval. The
approval covers this head in this workflow only; "Full round" keeps
`CLASS`.

On approval set `CLASS=delta`, then write the prior full run and the anchor
proof into `RUN_DIR`, in this order after `delta.diff`:

```bash
PRIOR_FULL_REPORT=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["prior_report"])' "$RUN_DIR/delta-class.json") || exit 2
PRIOR_FULL_EXPECTED=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["prior_expected"])' "$RUN_DIR/delta-class.json") || exit 2
PRIOR_FULL_REPORT_SHA256=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["prior_report_sha256"])' "$RUN_DIR/delta-class.json") || exit 2
PRIOR_FULL_EXPECTED_SHA256=$(uv run --no-project python -c 'import json,sys; print(json.load(open(sys.argv[1]))["prior_expected_sha256"])' "$RUN_DIR/delta-class.json") || exit 2
uv run --no-project python "$GATE_REPORT" copy-prior --report "$PRIOR_FULL_REPORT" \
  --expected "$PRIOR_FULL_EXPECTED" --report-sha256 "$PRIOR_FULL_REPORT_SHA256" \
  --expected-sha256 "$PRIOR_FULL_EXPECTED_SHA256" --out "$RUN_DIR/prior" >"$RUN_DIR/prior.json" || exit 2
uv run --no-project python - "$RUN_DIR" <<'PY' || exit 2
import json
import sys
from pathlib import Path

run = Path(sys.argv[1])
record = json.loads((run / "delta-class.json").read_text())["carry_forward"]
if record is not None:
    (run / "carry-forward.json").write_text(json.dumps(record, sort_keys=True))
PY
```

Then write `class: "delta"` and `delta: {prior_run, prior_head,
anchor_head, max_files, max_lines}`, copied from `delta-class.json`,
into the expected identity before any seat runs. An interruption anywhere
in this sequence invalidates the run.

The report's `delta` block takes `prior_run`, `prior_head` and
`anchor_head` from `delta-class.json`; `prior_report` and `prior_expected`
from `prior.json`; `diff` = `delta.diff` and `carry_forward` =
`carry-forward.json` (null when absent), each with its SHA-256; and
`blast_radius` from the verifier's reconciliation. The `schema`
subcommand lists every field.

Each delta seat prompt adds `delta.diff` as the review scope with the
frozen diff as context, the prior report path and digest (its advisories
are carried by reference, not re-listed), and this instruction: report
`blast_radius: unbounded` when the change's effect cannot be bounded to
this delta, such as a constant, default, tolerance, or fixture value read
elsewhere. Coverage follows the policy's Follow-up evidence rules.

An evaluation carrying `escalate: "full"` ends the delta gate. In an
interactive workflow, start one fresh full gate (new `run_id`,
`CLASS=full`) on the same head; its verdict is final and never escalates.
A herdr ship launch runs exactly one gate: write `ship.json` with the delta
verdict and stop, and the director dispatches the full gate.

## Dispatch and collect seats

The full tier runs `claude`, `codex`, and `breaker`, then `verifier`. The
light tier runs `codex` and `verifier`: the `codex` reviewer command below,
then the verifier with that one finder artifact; skip `claude` and `breaker`.
The delta tier runs `claude` and `verifier`: the `claude` reviewer command
below, then the verifier with that one finder artifact; skip `codex` and
`breaker`. `SUBSTITUTE` never applies in the delta tier.

Probe every runner route the tier uses before spending seats. Each probe is a
60-second `Reply ok` run on that seat's route and snapshot root, written under
`RUN_DIR` (never the manifest output dir, which `cleanup` checks). The probes
run concurrently. Any non-success probe stops co-review with the existing
incomplete report, quoting the probe's `status`, `observation` and `errors`.
A failed probe never switches runtime on its own; see "Substitute a failed
Codex probe" below for the explicit, truthfully recorded operator decision
that can. A probe is never a seat artifact.

```bash
printf 'Reply ok\n' >"$RUN_DIR/probe.prompt"
if [ "$CLASS" != "delta" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime codex --role reviewer --risk normal --provisional \
    --cwd "$CODEX_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-codex-reviewer.json" &
fi
uv run --no-project python "$RUNNER" run \
  --runtime claude --role skeptic --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
  --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-skeptic.json" &
if [ "$CLASS" != "light" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime claude --role reviewer --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-reviewer.json" &
fi
if [ "$CLASS" = "full" ]; then
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

### Substitute a failed Codex probe

This is an explicit operator decision, made only when every failed probe is a
Codex probe and its errors show a quota, auth or availability failure. Any
failed Claude probe stops co-review, as always. A Codex seat that fails
after its own probe succeeded is not substituted: the gate is `INCOMPLETE`,
and a fresh gate's probe records the outage. The probe runs are never
repeated. Every gate needs its own Codex attempt, including a fresh gate
after an interruption and a `--fix` follow-up; never copy an attempt from
another `RUN_DIR`. `co-review --full` is not the fallback for a Codex outage;
the substitute rule applies in both tiers. `SUBSTITUTE` stays set for the
seat block below.

Set `SUBSTITUTE` to the literal, space-separated seats whose own Codex probe
failed on quota, auth or availability: `codex` when `probe-codex-reviewer.json`
failed, and (full tier) `breaker` when `probe-codex-skeptic.json` failed. Then
run the block below, which iterates a literal word list rather than
`$SUBSTITUTE` itself, because the coordinator's zsh does not word-split an
unquoted variable. A first pass refuses (exit 2), before anything moves, when
any member seat's probe is missing or already succeeded. A second pass moves
each member's probe out of the `probe-*` glob into its
`<seat>.codex-attempt.json` evidence file, then runs a 60-second `Reply ok`
probe on the Claude route to confirm it is available before the seat runs.

```bash
# SUBSTITUTE names exactly the seats whose own Codex probe failed on quota,
# auth or availability: "codex" and/or (full tier) "breaker". The literal
# word list keeps this loop the same in bash and zsh.
for seat in codex breaker; do
  case " $SUBSTITUTE " in *" $seat "*) ;; *) continue ;; esac
  case $seat in codex) role=reviewer ;; breaker) role=skeptic ;; esac
  uv run --no-project python -c 'import json,sys; sys.exit(json.load(open(sys.argv[1])).get("status") == "success")' \
    "$RUN_DIR/probe-codex-$role.json" || exit 2
done
for seat in codex breaker; do
  case " $SUBSTITUTE " in *" $seat "*) ;; *) continue ;; esac
  case $seat in codex) role=reviewer ;; breaker) role=skeptic ;; esac
  mv -- "$RUN_DIR/probe-codex-$role.json" "$RUN_DIR/$seat.codex-attempt.json" || exit 2
  uv run --no-project python "$RUNNER" run \
    --runtime claude --role "$role" --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/substitute-probe-$seat.json"
done
uv run --no-project python - "$RUN_DIR"/probe-*.json "$RUN_DIR"/substitute-probe-*.json <<'PY' || exit 2
import json
import sys

failed = []
for path in sys.argv[1:]:
    try:
        with open(path) as handle:
            status = json.load(handle).get("status")
    except (OSError, ValueError):
        status = "no runner JSON"
    if status != "success":
        failed.append(f"{path}: {status}")
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

The runner reports a usage-limit refusal (a result that opens with a notice
such as "You've hit your session limit") as `status: error`, with the notice
in `errors` and a null `result`, so its probe fails the probe check. The
evaluator re-reads every seat artifact: a `.json` artifact must be runner
JSON whose `status` is `success`, and no seat artifact may be a usage-limit
refusal. A limit-refused seat is not retried, because the limit holds until
its reset; the gate is `INCOMPLETE`.

```bash
RUBRIC="$REVIEW_ROOT/claude/skills/co-review/references/failure-classes.md"
grep -q '^## Classes' "$RUBRIC" || exit 2
SEATS="claude codex breaker verifier"
[ "$CLASS" = "light" ] && SEATS="codex verifier"
[ "$CLASS" = "delta" ] && SEATS="claude verifier"
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
# A Codex-routed seat runs on Claude only when the substitute block above
# named it in SUBSTITUTE; otherwise it takes its normal Codex route.
CODEX_SEAT_RUNTIME=codex CODEX_SEAT_ROOT=$CODEX_ROOT
case " ${SUBSTITUTE:-} " in *" codex "*) CODEX_SEAT_RUNTIME=claude CODEX_SEAT_ROOT=$CLAUDE_ROOT ;; esac
BREAKER_SEAT_RUNTIME=codex BREAKER_SEAT_ROOT=$CODEX_ROOT
case " ${SUBSTITUTE:-} " in *" breaker "*) BREAKER_SEAT_RUNTIME=claude BREAKER_SEAT_ROOT=$CLAUDE_ROOT ;; esac
# Light tier: only the codex reviewer seat. Full tier: also claude and breaker.
# Delta tier: only the claude reviewer seat.
if [ "$CLASS" != "delta" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime "$CODEX_SEAT_RUNTIME" --role reviewer --risk normal --provisional \
    --cwd "$CODEX_SEAT_ROOT" --sandbox read-only --timeout-secs 1200 \
    --prompt-file "$RUN_DIR/codex.prompt" >"$RUN_DIR/codex.runtime.json" &
fi
if [ "$CLASS" != "light" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime claude --role reviewer --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 1200 \
    --prompt-file "$RUN_DIR/claude.prompt" >"$RUN_DIR/claude.runtime.json" &
fi
if [ "$CLASS" = "full" ]; then
  uv run --no-project python "$RUNNER" run \
    --runtime "$BREAKER_SEAT_RUNTIME" --role skeptic --risk normal --provisional \
    --cwd "$BREAKER_SEAT_ROOT" --sandbox read-only --timeout-secs 1200 \
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
`codex`; delta: `claude`) and its digest is recorded, run the verifier with role `skeptic` and
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
unfinished behavior blocks only with a concrete material consequence. A
seat substituted from the block above keeps its seat name, records
`runtime: claude`, and carries `codex_substitute` with
`{"artifact": "<SEAT>.codex-attempt.json", "sha256": ...}` as `schema`
describes.

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

## Carry-forward

When the only commits since an APPROVE gate merge the target branch, the
verdict carries to the new head without seats. The prior report and
expected identity come with their SHA-256 digests from exactly one source:
the pinned herdr `ship.json`, or this same uninterrupted workflow's own
retained gate. Fetch the target, then run the proof:

```bash
git -C "$REPO" fetch origin "$BASE_REF" || exit 2
uv run --no-project python "$GATE_REPORT" carry-forward --repo "$REPO" \
  --report "$PRIOR_REPORT" --expected "$PRIOR_EXPECTED" \
  --report-sha256 "$PRIOR_REPORT_SHA256" --expected-sha256 "$PRIOR_EXPECTED_SHA256" \
  >"$RUN_DIR/carry-forward.json"
```

Exit 0 means every proof holds: no branch-authored commit since the gated
head, no merge-tree conflict anywhere in git's merge of the gated head with
the new base, and the head's whole tree byte-equal to that merge result. Exit 1 means the head needs a gate;
the record's `reasons` say why. The record grants nothing beyond naming the
prior run it extends.

On exit 0, post the record's `audit_comment` as ship step 5 does (dedupe on
`co-review-audit head=<head>`), then the carry-forward marker under the
Publish rules below. Its first line is
`<!-- co-review: sha=<head> base=<base> base_ref=<base_ref> verdict=APPROVE round=<n> tier=carry-forward prior_run=<prior_run> prior_sha=<prior_head> -->`,
its verdict line is
`Co-review verdict: APPROVE (carry-forward of <prior_run> at <prior_head>)`,
and the proof block from `audit_comment` follows. Before asking for the go,
skip the marker when any PR comment already has a line containing both
`<!-- co-review: sha=<head> ` and ` tier=carry-forward prior_run=<prior_run> `;
that read is for dedupe only, never authority.

## Publish

The only publishable item is one marker comment on the reviewed PR, for a PR
gate only -- never for a local no-PR review. A `--fix` coordinator publishes
at most once, after its final gate.

- `APPROVE`: post the marker without asking, run the supersede step, and
  print `[INFO] posted co-review marker on #<PR>: APPROVE` in the same turn.
- `CHANGES`: do not post. The marker stays in `RUN_DIR` and the report. If
  the owner asks for it on the PR, register it as a draft (below) and wait
  for the go.
- `INCOMPLETE`: never posted; the marker grammar has no such verdict.

The herdr post gate enforcing this is a momentum guardrail, not a security
boundary: it stops a well-meaning agent posting through `gh` as found on
PATH. In a work repository the gh shim lets an `APPROVE` marker through on a
PR this account authored and refuses it on anyone else's PR; supersede
deletes never need a go, and the shim runs a delete only on this account's
own co-review marker. A personal repository needs no go at all.

Marker comment shape: first line is the marker, then one verdict line, then
one line per blocker (`<id>: <title>`), nothing else. Marker fields: `sha` =
expected `head`, `base` = expected `base`, `base_ref` = expected `base_ref`,
`verdict` = evaluator verdict, `round` = 1 + the highest `round=` among our
own valid markers already on the PR (1 when none), `tier` = expected `class`; a delta marker adds `prior_run` = expected
`delta.prior_run` and `prior_sha` = expected `delta.prior_head`, in that order.
No `target_tip`. A carry-forward marker also carries its proof block after
the verdict line (see Carry-forward).

Before posting, read the PR's comments once (the `gh api --paginate --slurp`
call below, run before `gh pr comment`) and compute `round` from it.

```bash
gh pr comment "$PR" --body-file "$RUN_DIR/marker.md" || exit 2
gh api --paginate --slurp "repos/$OWNER/$REPO_NAME/issues/$PR/comments" >"$RUN_DIR/comments.json"
ME=$(gh api user --jq .login)
uv run --no-project python "$REVIEW_ROOT/claude/skills/co-review/scripts/pr_ready_gate.py" supersede \
  --comments "$RUN_DIR/comments.json" --author "$ME" --expect-marker "$MARKER_LINE"
# Delete each printed id with its own call; no loop, no $(...):
# gh api -X DELETE "repos/$OWNER/$REPO_NAME/issues/comments/<id>"
```

Only on the comment's exit 0 does the supersede step run. If supersede did
not finish, re-read the comments and rerun only the supersede step. If `gh
pr comment` did not exit 0, let that Bash call return first, then read the
comments: post again only when the marker is absent.

A draft is the owner's view of one gated post. When the shim refuses a post
(a `CHANGES` marker the owner asked for, or a marker on a PR this account did
not author), register it with the exact argv it names:

```bash
python3 ~/.claude/hooks/pr_post_guard.py draft -- gh pr comment "$PR" --body-file "$RUN_DIR/marker.md"
```

Show the printed `draft <hash>` line and the body in chat and end the turn.
The go is a typed message saying `post it` (the last draft shown), `post
all` (every draft in that message) or `post <hash>`, not negated and not a
question. Posting is never an `AskUserQuestion` option, recommended or not;
an `AskUserQuestion` answer is never a go. An approved draft stays approved
across later messages until it is posted. If an approved post fails, let
the Bash call return, read the PR, and post again only when the text is
absent; re-register it and tell the owner the earlier attempt failed and a
duplicate is possible.

Never reply to, resolve, or react to a reviewer thread on your own. Draft
any reply as above and wait for the go.

Edit the title or body of a PR this account authored without asking, and
print `[INFO] edited PR #<PR> body: <why>` in the same turn.
