---
name: codex-spec-review
description: Obtain a bounded independent Codex review of one explicit frozen specification.
---

# Codex Spec Review

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

Use after a specification is complete and before planning. Require an explicit
spec path under `docs/superpowers/specs/`; never select a newest file.

```bash
uv run --no-project python "$REVIEW_HELPER" artifact \
  --repo "$REPO" --kind spec --path "$SPEC_PATH" --task-id "$TASK_ID" \
  --runtime claude --output-dir "$OUTPUT_DIR"
```

Set `FROZEN_SPEC` and `FROZEN_SPEC_SHA256` from the returned path and
SHA-256 fields after validating them. Apply any deliberate `--personal`
override to both artifact freezing and partner launch.

Validate the returned absolute path and SHA-256 before dispatch. Review the
frozen specification for ambiguity, contradictory requirements, missing
acceptance criteria, boundary cases, scope, security, privacy, rollback, and
external dependencies.

## Class and round cap

Set `ARTIFACT_CLASS` to `advisory` when the caller says the artifacts are
workflow prose with no durable write or authority transition of their own;
otherwise it stays `behavior`. Set `SPEC_MAX_ROUNDS` from this table unless
the kickoff instruction names a higher cap; nothing else raises it. The plan
review uses its own `PLAN_MAX_ROUNDS`, so one shell running both reviews
never carries the spec cap into the plan review.

| Skill             | Default max Codex rounds | Raised by                    |
| ----------------- | ------------------------ | ---------------------------- |
| codex-spec-review | 4                        | the kickoff instruction only |

A round is one runner call, whatever its outcome; the skeptic verification
round counts. Record every call, failed or empty ones included, as its own
row in the spec's revision history (round, frozen SHA-256, verdict or
failure, input tokens), so a restart counts rows and never resets the cap.
Stop at the cap. After a complete last call (findings plus one verdict), fold
the fixes you accept, list every still-open finding with its disposition in
the spec's accepted residuals, and proceed, unless a finding rated critical
or high is still open. That, or an incomplete last call (timeout, empty,
malformed, no verdict), blocks the caller; a herdr plan worker emits
`--outcome paused`.

For `behavior`, probe recovery semantics explicitly: independently enumerate
the interruption windows the design's durable writes and authority
transitions imply -- including windows the specification never mentions --
and for each require the spec to name the durable evidence that survives it,
every actor that can destroy or rewrite that evidence, and the recovery
behavior; missing coverage is a finding, whether or not the spec claims
crash survival. For `advisory`, skip that probe and ask for style, rigor,
and hardening suggestions as non-blocking; record them as accepted
residuals. Either class flags an oversized scope as a finding: a
specification that as a whole introduces more than one evidence model (one
set of durable artifacts consulted for an authority decision) or more than
three new multi-write sequences (2+ durable writes that must survive
interruption between them) is a slice-splitting signal; specifications with
no durable-write behavior are exempt.

Require bounded severity/location/problem/fix output and one verdict.
Empty, malformed, or failed output is incomplete.

## Round 1: the full frozen specification

Resolve the independent Codex reviewer model and effort with
the shared runtime runner:

```bash
ARTIFACT_CLASS="${ARTIFACT_CLASS:-behavior}"
SPEC_MAX_ROUNDS="${SPEC_MAX_ROUNDS:-4}"
if [ "$ARTIFACT_CLASS" = advisory ]; then
  FOCUS="These are advisory workflow-prose artifacts with no durable write or authority transition of their own. Report defects that would make an implementer do the wrong thing; return style, rigor, and hardening suggestions as severity low."
else
  FOCUS="Probe recovery semantics: independently enumerate the interruption windows the design's durable writes and authority transitions imply, including windows the specification never mentions, and for each require the spec to name the durable evidence that survives it, every actor that can destroy or rewrite that evidence, and the recovery behavior; missing coverage is a finding, whether or not the spec claims crash survival."
fi
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-spec-review.XXXXXX")
printf '%s\n' "Round ${ROUND:-1} of $SPEC_MAX_ROUNDS. $FOCUS Review only frozen specification $FROZEN_SPEC with SHA-256 $FROZEN_SPEC_SHA256 for task $TASK_ID. Flag an oversized scope as a finding: a specification that as a whole introduces more than one evidence model (one set of durable artifacts consulted for an authority decision) or more than three new multi-write sequences (2+ durable writes that must survive interruption between them) is a slice-splitting signal; specifications with no durable-write behavior are exempt. Return severity, location, problem, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

## Round k: the diff since the previous round

After folding fixes, freeze the revised spec with the same artifact command
and the same `OUTPUT_DIR`, set `FROZEN_SPEC` and `FROZEN_SPEC_SHA256` from
the new result, set `PREVIOUS_FROZEN_SPEC` to the frozen path the previous
call reviewed, and set `ROUND` to the next call number from the revision
history rows. Write `$OPEN_FINDINGS` by hand: each prior finding still open,
with its disposition (fixed in the diff, disputed with a reason, or accepted
residual).

```bash
ROUND_DIFF="$OUTPUT_DIR/spec-round-$ROUND.diff"
OPEN_FINDINGS="$OUTPUT_DIR/spec-open-findings-$ROUND.md"
DIFF_STATUS=0
diff -u "$PREVIOUS_FROZEN_SPEC" "$FROZEN_SPEC" >"$ROUND_DIFF" || DIFF_STATUS=$?
[ "$DIFF_STATUS" -le 1 ] || exit 2
ARTIFACT_CLASS="${ARTIFACT_CLASS:-behavior}"
SPEC_MAX_ROUNDS="${SPEC_MAX_ROUNDS:-4}"
if [ "$ARTIFACT_CLASS" = advisory ]; then
  FOCUS="These are advisory workflow-prose artifacts; return style, rigor, and hardening suggestions as severity low."
else
  FOCUS="Apply the recovery-semantics probe to durable writes and authority transitions the diff adds or changes."
fi
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-spec-review.XXXXXX")
printf '%s\n' "Round $ROUND of $SPEC_MAX_ROUNDS. $FOCUS Review only frozen specification $FROZEN_SPEC with SHA-256 $FROZEN_SPEC_SHA256 for task $TASK_ID, and within it only the changes in unified diff $ROUND_DIFF since the previous round. For each open finding in $OPEN_FINDINGS return CLOSED or STILL-OPEN with a reason. Read the full specification only for sections the diff or a finding cites. Raise a new finding only on changed text or on a defect that blocks an open finding's fix. Return severity, location, problem, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

When the previous frozen copy is unavailable, `diff -u` exits 2 and the
block above stops before reaching Codex. In that case, rerun the round 1
full-document prompt above with `ROUND` set to this call's number (it
renders as `Round $ROUND of $SPEC_MAX_ROUNDS` via the `${ROUND:-1}`
substitution); that call still counts toward the cap.

Use `--risk critical` only for explicit critical risk. For a Codex-led review,
use the current session or a supported native child; never invoke another Codex
CLI review recursively. Verify findings against the frozen document, retain
uncertain findings as unresolved, and apply fixes within existing user
authorization before asking to change source. Use no more than one skeptic
verification round.
