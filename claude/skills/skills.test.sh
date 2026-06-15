#!/bin/sh
set -e

PASS=0
FAIL=0

assert() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- codex-task-review (single source of truth for the codex review mechanic) ---
assert "codex-task-review skill exists" \
    test -f claude/skills/codex-task-review/SKILL.md
assert "codex-task-review uses the review subcommand" \
    rg -q 'codex exec review --base' claude/skills/codex-task-review/SKILL.md
assert "codex-task-review forbids generic codex exec review" \
    rg -q 'NEVER .codex exec ' claude/skills/codex-task-review/SKILL.md
assert "codex-task-review captures base, never assumes main" \
    rg -q 'Never assume .main' claude/skills/codex-task-review/SKILL.md
assert "codex-task-review enforces empty-diff guard" \
    rg -q 'empty diff' claude/skills/codex-task-review/SKILL.md
assert "codex-task-review runs read-only" \
    rg -q 'sandbox_mode="read-only"' claude/skills/codex-task-review/SKILL.md

# --- tiered-orchestrate per-task Claude+Codex santa quality gate ---
assert "tiered-orchestrate has a quality gate" \
    rg -q -i 'quality gate' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate references codex-task-review" \
    rg -q 'codex-task-review' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate requires both reviewers to pass" \
    rg -q -i 'both must pass|both reviewers' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate captures BASE_SHA before edits" \
    rg -q 'BASE_SHA' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate enforces empty-diff guard via the skill" \
    rg -q -i 'empty-diff guard|empty diff' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate tags findings by source" \
    rg -q '\[both\]|claude_unique|codex_unique' claude/skills/tiered-orchestrate/SKILL.md
assert "tiered-orchestrate logs gate metrics" \
    rg -q 'codex-gate-metrics.log' claude/skills/tiered-orchestrate/SKILL.md

# --- co-review references the shared codex mechanic ---
assert "co-review references codex-task-review" \
    rg -q 'codex-task-review' claude/skills/co-review/SKILL.md

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
