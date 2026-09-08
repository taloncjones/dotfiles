---
name: claude-spec-review
description: Obtain a bounded independent Claude review of one explicit frozen specification.
---

# Claude Spec Review

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

Require an explicit spec path under `docs/superpowers/specs/`; never choose a
global or newest document. Freeze the selected document:

```bash
uv run --no-project python "$REVIEW_HELPER" artifact \
  --repo "$REPO" --kind spec --path "$SPEC_PATH" --task-id "$TASK_ID" \
  --runtime codex
```

Validate the returned absolute path and SHA-256, then set `FROZEN_SPEC`
and `FROZEN_SPEC_SHA256` from those validated fields. Dispatch only that copy.
Apply any deliberate `--personal` override to both artifact freezing and the
partner launch so they use the same account scope.

Resolve Claude account scope from the original repository through
`workflow_context.py account-scope`. Personal Claude requires an unset
`CLAUDE_CONFIG_DIR`; do not route from a temporary snapshot or inherited
environment. Request bounded severity, location, problem, fix, and verdict
output. Empty, error, or malformed output is incomplete.

Resolve model and effort through `agent_runtime.resolve_route("claude",
"reviewer")` through the shared runtime runner; do not duplicate a route table
in this skill.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/claude-spec-review.XXXXXX")
printf '%s\n' "/code-review frozen specification $FROZEN_SPEC with SHA-256 $FROZEN_SPEC_SHA256 for task $TASK_ID. Return severity, location, problem, concrete fix, and one verdict. Do not invoke co-review, another partner, or external actions." >"$PROMPT_FILE"
uv run --no-project python "$RUNNER" run \
  --runtime claude --role reviewer --risk normal --provisional \
  --cwd "$REPO" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Add `--personal` only for a deliberate personal override. Use `--risk critical`
only for explicit critical risk; preserve unknown observed metadata as unknown.

Verify findings against the frozen specification, report supported and
unresolved findings separately, and apply fixes within existing user
authorization before asking to edit the live document. Use at most one skeptic
verification round.
