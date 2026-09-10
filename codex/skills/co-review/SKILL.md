---
name: co-review
description: Freeze one code change and run independent Codex and Claude review before fixes.
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

Read the canonical Claude-led policy at the resolved absolute path
`$REVIEW_ROOT/claude/skills/co-review/SKILL.md`. It defines frozen snapshots,
artifact hashing, scope routing, attacker/skeptic bounds, and cleanup.

Use it to prepare and verify an explicit target. Review only
`snapshot.codex_root` with the manifest's pinned base/head/tree. Empty or error
output is incomplete. Do not select newest documents or inspect a moving source
checkout.

## Codex-led dispatch

Codex reviews the frozen Codex snapshot in this session. Use a supported native
fresh child only after resolving `agent_runtime.resolve_route("codex",
"reviewer")`; state its actual model and effort and give it an explicit
read-only, bounded findings task. Do not run `codex exec` or `codex exec review`
from this Codex skill: that would create a nested Codex review path.

The independent Claude half runs from `snapshot.claude_root` through native
`/code-review`, using the original repository's account scope from
`workflow_context.py`. A personal route unsets `CLAUDE_CONFIG_DIR`. Do not
derive account choice from a temporary worktree or preserve an unrelated
inherited account variable.

```bash
PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/co-review-claude.XXXXXX")
cat >"$PROMPT_FILE" <<EOF
/code-review the frozen change against base $BASE. Report each actionable issue
as severity, file:line, failure scenario, and concrete fix. End with one
verdict. Do not invoke co-review, another partner, or external actions.
EOF
uv run --no-project python "$RUNNER" run --runtime claude --role reviewer --risk normal \
  --provisional --cwd "$CLAUDE_ROOT" --sandbox read-only --timeout-secs 600 \
  --prompt-file "$PROMPT_FILE"
```

Add `--personal` only for a deliberate personal override. Use `--risk critical`
only for explicitly critical review risk, not diff size. Preserve unknown
observed model or effort as unknown, and treat malformed or failed output as
incomplete.

Run one attacker only for gate-like changes and at most one skeptic for
high-severity findings. Resolve each native child role through the shared route
policy. Verify findings against frozen files, then clean with
`uv run --no-project python "$REVIEW_HELPER" cleanup --manifest "$MANIFEST"`
after all reads. Retain uncertain or unsupported high-severity findings as
unresolved, prohibit a clean verdict while required review is incomplete, and
apply confirmed fixes within existing user authorization before asking anew.
