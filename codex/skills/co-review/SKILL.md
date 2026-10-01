---
name: co-review
description: Freeze a finished change, collect two or four independent review seats by change class, and evaluate one fail-closed final-gate report.
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
PR number or claim `APPROVE`. Capture and hash the frozen diff and exact-head
CI payload as precondition artifacts:

```bash
git -C "$REPO" -c core.quotePath=true diff --no-color --no-ext-diff --no-textconv --no-renames --binary \
  "$BASE" "$CODEX_TREE" >"$RUN_DIR/frozen.diff" || exit 2
# A failed capture can leave a partial diff that classifies light; never use it.
CLASS=$(uv run --no-project python "$GATE_REPORT" classify --diff "$RUN_DIR/frozen.diff") || exit 2
# `co-review --full` sets CLASS=full here regardless of the classifier.
```

Write `CLASS` into the expected identity's `class` field before resolving any
route; set `report.class` to the same value.

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
# Full tier:
uv run --no-project python "$RUNNER" route --runtime claude --role reviewer --risk normal --provisional >"$RUN_DIR/claude.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role reviewer --risk normal --provisional >"$RUN_DIR/codex.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role skeptic --risk normal --provisional >"$RUN_DIR/breaker.route.json"
uv run --no-project python "$RUNNER" route --runtime codex --role skeptic --risk normal --provisional >"$RUN_DIR/verifier.route.json"
# Light tier: only the codex reviewer route and a Claude-runner verifier route.
uv run --no-project python "$RUNNER" route --runtime claude --role skeptic --risk normal --provisional >"$RUN_DIR/verifier.route.json"
```

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

Run `gate_report.py schema` before report assembly. Resolve each fresh seat
with the shared runner and `--provisional`; this records unknown availability
honestly and stops if the route is actually unavailable or unsupported.

Full tier only: Run four fresh, independent read-only 1200-second seats:
`claude` reviewer, `codex` reviewer, `breaker` skeptic, then `verifier`
skeptic after every finder artifact is complete.

The light tier runs `codex` and `verifier`: first the native `codex` reviewer
seat, then, after its artifact is complete, the verifier through the Claude
runner, so the light gate keeps one seat per model:

Delta tier: the `claude` reviewer seat and the verifier both run through the
Claude runner blocks below (the probe block already probes both roles for a
non-light class); no native Codex child runs.

Probe the Claude runner route before spending a seat on it; the Codex runtime
needs no probe, because the controller running this skill is that runtime.
The probe is a 60-second `Reply ok` run on `$CLAUDE_ROOT`, written under
`RUN_DIR`. The light tier probes the `skeptic` role (the verifier it will
launch); the full tier also probes the `reviewer` role (the `claude` seat). A
non-success probe stops co-review with the existing incomplete report,
quoting the probe's `status`, `observation` and `errors`. This is one
60-second shell call, within a Codex shell call's limit.

```bash
printf 'Reply ok\n' >"$RUN_DIR/probe.prompt"
nohup uv run --no-project python "$RUNNER" run \
  --runtime claude --role skeptic --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
  --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-skeptic.json" &
if [ "$CLASS" != "light" ]; then
  nohup uv run --no-project python "$RUNNER" run \
    --runtime claude --role reviewer --risk normal --provisional \
    --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 60 \
    --prompt-file "$RUN_DIR/probe.prompt" >"$RUN_DIR/probe-claude-reviewer.json" &
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

```bash
nohup uv run --no-project python "$RUNNER" run \
  --runtime claude --role skeptic --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 1200 \
  --prompt-file "$RUN_DIR/verifier.prompt" >"$RUN_DIR/verifier.runtime.json" 2>"$RUN_DIR/verifier.runtime.err" &
echo $! >"$RUN_DIR/verifier.pid"
```

Launch the Claude runner seat first (full tier: before spawning the native
seats), then check `$RUN_DIR/<seat>.runtime.json` in short shell calls
until it is non-empty or the 1200-second deadline passes; never hold one
shell call open in a blocking `wait`. `nohup` keeps the seat alive after the
launching call ends, and the runner leaves an inherited ignored SIGHUP alone.
At the deadline, only when the JSON is still empty and
`kill -0 "$(cat "$RUN_DIR/<seat>.pid")"` succeeds, send it SIGTERM; the
runner reaps the seat and writes a `runner-interrupted` result. Remove the
pid file once the seat is collected. An empty JSON is an incomplete seat.

The light verifier receives the one `codex` artifact path and digest and
every known blocker.

Every prompt includes the
extracted policy, frozen diff, manifest identity, the complete `## Classes`
section of the failure-class rubric, and
declared threat model. The verifier also receives finder artifact
paths/digests and known blockers. Save each runner JSON response as that seat's
nonempty artifact and preserve requested and observed route metadata. The
controller never stands in for a seat.

Full and delta tiers: the Claude seat uses the resolved original-account route
through the bounded runner and preserves its raw response as the `claude`
artifact:

```bash
nohup uv run --no-project python "$RUNNER" run \
  --runtime claude --role reviewer --risk normal --provisional \
  --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 1200 \
  --prompt-file "$RUN_DIR/claude.prompt" >"$RUN_DIR/claude.runtime.json" 2>"$RUN_DIR/claude.runtime.err" &
echo $! >"$RUN_DIR/claude.pid"
```

Launch this seat first, before spawning the native seats, then check
`$RUN_DIR/claude.runtime.json` the same way as the light verifier.

From Codex, the full tier's `codex`, `breaker`, and `verifier` seats and the
light tier's `codex` seat are fresh native children after route resolution;
the light `verifier` is the Claude runner call above. The native spawn API has
no timeout or sandbox
arguments: give each an explicit read-only, disposable-fixture task and use the
coordinator's 1200-second deadline to interrupt an unfinished child. Record its
actual completion artifact. Do not invoke `codex exec`, a generic `/code-review`
plugin, or a nested partner route. The Claude seat preserves the
original repository's account scope through the runner. Every seat is
adversarial and read-only; it uses only disposable fixtures and does not fix,
publish, comment, or merge.

For each native seat, build a complete rendered review packet from actual
frozen values, never placeholders: repository identity; `snapshot.codex_root`;
base, head, expected tree, and reviewed tree; frozen diff path and digest;
target repository/PR/base-branch identity; the extracted policy; full rubric;
declared threat model; and changed-symbol callers. State the requested finding
format (including concrete impact for any material allegation),
disposable-fixture/read-only limits, and permission to consult relevant
reference skills under the canonical policy. Require the reviewer to do the
review itself, without another review workflow, delegated reviewers, partners,
network actions, comments, fixes or merge actions.

Full tier: dispatch the `codex` reviewer and `breaker` through the native
`spawn_agent` API with `fork_turns: "none"`, `model` and `reasoning_effort`
taken from their exact parsed `RUNNER route` JSON. The resulting messages
contain the complete packet above and no controller history or other seat
output. Keep the returned handles. The existing Claude seat uses the same
full packet without either native report.

Light tier: dispatch only the `codex` reviewer through native `spawn_agent`
with the same packet rules.

Full tier: wait for Claude, Codex, and breaker to complete and collect their
actual native or runner results before continuing. The coordinator uses
`wait_agent` for each native handle and a 1200-second deadline; it uses
`interrupt_agent` only after a deadline. A failed, timed-out, empty, or
malformed completion stops as incomplete. Store each successful native completion as
the report-relative `<seat>.native.md` and record its digest; a runner seat
keeps its `.json` runner response.

The runner reports a usage-limit refusal (a result that opens with a notice
such as "You've hit your session limit") as `status: error`, with the notice
in `errors` and a null `result`, so its probe fails the probe check. The
evaluator re-reads every seat artifact: a `.json` artifact must be runner
JSON whose `status` is `success`, and no seat artifact may be a usage-limit
refusal. A limit-refused seat is not retried, because the limit holds until
its reset; the gate is `INCOMPLETE`.

Light tier: wait for the `codex` seat only, under the same deadline and
incomplete rules.

Full tier: only after those three artifacts and digests exist, render the
verifier packet. It includes the same full frozen-value packet, the named
Claude/Codex/breaker artifact paths and digests, and the expected known
blockers. Light tier: only after the `codex` artifact and digest exist,
render the verifier packet with that one artifact path and digest and the
expected known blockers, run it with the Claude runner command above, then
collect, validate, and hash its runner JSON under the same deadline rules. It
includes no other controller history. The full-tier verifier is dispatched
with native `spawn_agent`, `fork_turns: "none"`, and its parsed skeptic-route
`model` and `reasoning_effort`; then wait, collect, validate, and hash its
completion using the same deadline rules. The verifier independently tests
material claims, accounts for every blocker and reconciles the combined
coverage ledger. It does not start another unrestricted search.

Create `report.json` from the exact `gate_report.py schema` example. Fill all
fields from the verified manifest, independent expected identity, SHA-256
digests, frozen diff/CI artifact digests, findings, prior blocker
dispositions, and required coverage.

Fill the seat entries from the actual runtime artifacts for `CLASS`; the
light `verifier` entry records runtime `claude` and the `codex` entry records
runtime `codex`, as the evaluator requires. Paths are report relative. Do not
substitute coordinator prose for a missing or unsuccessful runtime
completion. Then verify, evaluate, and clean up:

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

Only `APPROVE` permits a merge-ready result. `CHANGES` returns concrete
blockers to development. `INCOMPLETE` reports missing evidence. Human approval
and explicit merge permission remain separate; cleanup refusal preserves the
snapshot.

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
The go is a typed message with a sentence saying `post it` (the last draft
shown), `post all` (every draft in that message) or `post <hash>`, with no
`not`, `n't`, `never` or `no` before the phrase and no closing `?`. Posting is never an `AskUserQuestion` option, recommended or not;
an `AskUserQuestion` answer is never a go. An approved draft stays approved
across later messages until it is posted. If an approved post fails, let
the Bash call return, read the PR, and post again only when the text is
absent; re-register it and tell the owner the earlier attempt failed and a
duplicate is possible.

In a herdr pane (`HERDR_ENV=1`) only a Claude hook turns a typed go into an
approved draft, so a gated post never reaches Codex. Leave the draft in
`RUN_DIR` and tell the owner it is ready to post.

Never reply to, resolve, or react to a reviewer thread on your own. Draft
any reply as above and wait for the go.

Edit the title or body of a PR this account authored without asking, and
print `[INFO] edited PR #<PR> body: <why>` in the same turn.
