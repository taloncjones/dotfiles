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
external dependencies. Require bounded severity/location/problem/fix output
and one verdict. Empty, malformed, or failed output is incomplete.

Resolve the independent Codex reviewer model and effort with
the shared runtime runner:

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-spec-review.XXXXXX")
printf '%s\n' "Review only frozen specification $FROZEN_SPEC with SHA-256 $FROZEN_SPEC_SHA256 for task $TASK_ID. Return severity, location, problem, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Use `--risk critical` only for explicit critical risk. For a Codex-led review,
use the current session or a supported native child; never invoke another Codex
CLI review recursively. Verify findings against the frozen document, retain
uncertain findings as unresolved, and apply fixes within existing user
authorization before asking to change source. Use no more than one skeptic
verification round.
