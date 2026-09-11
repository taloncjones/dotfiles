---
name: herdr-orchestration
description: Use when Codex is asked to contribute UI/UX direction, bounded UI implementation, prose, or independent review to a Claude-led Herd task. This installed compatibility entrypoint points to the canonical shared workflow; it does not make Codex the Herd controller.
---

# Codex Herd compatibility entrypoint

Claude is the default Herd controller, planner, and general implementer. Codex
contributes UI/UX direction and bounded UI implementation, prose/voice, and
independent review. The Claude implementation worker retains task, commit, and
lifecycle ownership.

Read `claude/skills/herdr-orchestration/SKILL.md` in the same dotfiles checkout
for the canonical Claude-led workflow and the bounded specialist dispatch
recipe. Resolve that source through this installed skill rather than the user's
project cwd:

```bash
SKILL_FILE="${CODEX_HOME:-$HOME/.codex}/skills/herdr-orchestration/SKILL.md"
SKILL_DIR="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True).parent)' "$SKILL_FILE")" || exit 2
ORCH_SOURCE_ROOT="$(cd "$SKILL_DIR/../../.." && pwd)"
SHARED_SKILL="$ORCH_SOURCE_ROOT/claude/skills/herdr-orchestration/SKILL.md"
```

For bounded implementation, accept only the assigned UI files and tests; return
a result to the Claude worker. Do not claim Herd ownership, commit, or emit a
lifecycle record. A fresh independent Claude review is required for Codex UI
edits before the Claude worker accepts them.

Normal standalone Codex CLI use remains the user's choice. Shared compatibility
APIs remain installed. A Codex-driven Herd controller is not supported and is not
a goal - Codex participates only as a bounded specialist (UX/UI, prose/voice,
independent review).
