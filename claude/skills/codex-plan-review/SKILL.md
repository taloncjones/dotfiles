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

Resolve the independent Codex reviewer model and effort with
the shared runtime runner:

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codex-plan-review.XXXXXX")
printf '%s\n' "Review only frozen plan $FROZEN_PLAN with SHA-256 $FROZEN_PLAN_SHA256 for task $TASK_ID. Return severity, location, failure scenario, concrete fix, and one verdict. Do not invoke skills, partners, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime codex --role reviewer --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Use `--risk critical` only for explicit critical risk. A Codex-led skill uses
its current session or a native child and never invokes another Codex CLI review
recursively. Record requested route separately from unknown observed metadata.

Verify findings against the frozen plan, merge duplicates, and retain uncertain
findings as unresolved. Apply fixes within existing user authorization;
otherwise ask before editing the live document. Keep one review and at most one
skeptic verification round; do not seek recursive review approval.
