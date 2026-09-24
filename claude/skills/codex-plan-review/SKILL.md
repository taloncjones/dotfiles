---
name: codex-plan-review
description: Obtain a bounded independent Codex review of one explicit frozen implementation plan.
---

# Codex Plan Review

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

Use after a plan is complete and before implementation. Require an explicit
plan path under `docs/superpowers/plans/`; never select a newest file.

Freeze it before dispatch:

```bash
uv run --no-project python "$REVIEW_HELPER" artifact \
  --repo "$REPO" --kind plan --path "$PLAN_PATH" --task-id "$TASK_ID" \
  --runtime claude --output-dir "$OUTPUT_DIR"
```

Set `FROZEN_PLAN` and `FROZEN_PLAN_SHA256` from the returned path and
SHA-256 fields after validating them. Apply any deliberate `--personal`
override to both artifact freezing and partner launch.

Validate the returned absolute path and SHA-256, then give Codex only that
frozen file and bounded optional repository context. Request severity, location,
failure scenario, concrete fix, and one verdict. Empty output, an execution
error, or a response without the required verdict is incomplete, never approval.

## Class and round cap

Set `ARTIFACT_CLASS` to `advisory` when the caller says the artifacts are
workflow prose with no durable write or authority transition of their own;
otherwise it stays `behavior`. Set `PLAN_MAX_ROUNDS` from this table unless
the kickoff instruction names a higher cap; nothing else raises it. The spec
review uses its own `SPEC_MAX_ROUNDS`, so one shell running both reviews
never carries the spec cap into the plan review.

| Skill             | Default max Codex rounds | Raised by                    |
| ----------------- | ------------------------ | ---------------------------- |
| codex-plan-review | 2                        | the kickoff instruction only |

A round is one runner call, whatever its outcome; the skeptic verification
round counts. Record every call, failed or empty ones included, as its own
row in the plan's revision notes (round, frozen SHA-256, verdict or failure,
input tokens), so a restart counts rows and never resets the cap. Stop at
the cap. After a complete last call (findings plus one verdict), fold the
fixes you accept, list every still-open finding with its disposition in the
plan's revision notes, and proceed, unless a finding rated critical or high
is still open. That, or an incomplete last call (timeout, empty, malformed,
no verdict), blocks the caller; a herdr plan worker emits
`--outcome paused`.

Flag an oversized scope as a finding: a plan that as a whole introduces
more than one evidence model (one set of durable artifacts consulted for
an authority decision) or more than three new multi-write sequences (2+
durable writes that must survive interruption between them) is a
slice-splitting signal; plans with no durable-write behavior are exempt.

## Round 1: the full frozen plan

Resolve the independent Codex reviewer model and effort with
the shared runtime runner:

```bash
ARTIFACT_CLASS="${ARTIFACT_CLASS:-behavior}"
PLAN_MAX_ROUNDS="${PLAN_MAX_ROUNDS:-2}"
FOCUS=""
if [ "$ARTIFACT_CLASS" = advisory ]; then
  FOCUS="These are advisory workflow-prose artifacts with no durable write or authority transition of their own. Report defects that would make an implementer do the wrong thing; return style, rigor, and hardening suggestions as severity low."
fi
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-plan-review.XXXXXX")
printf '%s\n' "Round 1 of $PLAN_MAX_ROUNDS. $FOCUS Review only frozen plan $FROZEN_PLAN with SHA-256 $FROZEN_PLAN_SHA256 for task $TASK_ID. Flag an oversized scope as a finding: a plan that as a whole introduces more than one evidence model (one set of durable artifacts consulted for an authority decision) or more than three new multi-write sequences (2+ durable writes that must survive interruption between them) is a slice-splitting signal; plans with no durable-write behavior are exempt. Return severity, location, failure scenario, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --step plan-review --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

## Round k: the diff since the previous round

After folding fixes, freeze the revised plan with the same artifact command
and the same `OUTPUT_DIR`, set `FROZEN_PLAN` and `FROZEN_PLAN_SHA256` from
the new result, set `PREVIOUS_FROZEN_PLAN` to the frozen path the previous
call reviewed, and set `ROUND` to the next call number from the revision
note rows. Write `$OPEN_FINDINGS` by hand: each prior finding still open,
with its disposition (fixed in the diff, disputed with a reason, or accepted
residual).

```bash
ROUND_DIFF="$OUTPUT_DIR/plan-round-$ROUND.diff"
OPEN_FINDINGS="$OUTPUT_DIR/plan-open-findings-$ROUND.md"
DIFF_STATUS=0
diff -u "$PREVIOUS_FROZEN_PLAN" "$FROZEN_PLAN" >"$ROUND_DIFF" || DIFF_STATUS=$?
[ "$DIFF_STATUS" -le 1 ] || exit 2
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-plan-review.XXXXXX")
printf '%s\n' "Round $ROUND of $PLAN_MAX_ROUNDS. $FOCUS Review only frozen plan $FROZEN_PLAN with SHA-256 $FROZEN_PLAN_SHA256 for task $TASK_ID, and within it only the changes in unified diff $ROUND_DIFF since the previous round. For each open finding in $OPEN_FINDINGS return CLOSED or STILL-OPEN with a reason. Read the full plan only for sections the diff or a finding cites. Raise a new finding only on changed text or on a defect that blocks an open finding's fix. Return severity, location, failure scenario, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --step plan-review --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

The plan-review seat refuses `--risk critical` and `difficulty`; escalate a
plan that needs a heavier review with a recorded `--config-json` `routes`
override on `plan_reviewer` (for example `{"model": "opus", "effort":
"xhigh"}`). A Codex-led skill uses its current session or a native child and
never invokes another Codex CLI review recursively. Record requested route
separately from unknown observed metadata.

Verify findings against the frozen plan, merge duplicates, and retain uncertain
findings as unresolved. Apply fixes within existing user authorization;
otherwise ask before editing the live document. Keep at most one skeptic
verification round inside the cap; do not seek recursive review approval.
