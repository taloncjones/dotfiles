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

assert "claude-plan-review skill exists" \
    test -f codex/skills/claude-plan-review/SKILL.md
assert "co-review skill exists" \
    test -f codex/skills/co-review/SKILL.md
assert "claude-plan-review invokes Claude reviewer" \
    rg -q 'claude' codex/skills/claude-plan-review/SKILL.md
assert "claude-plan-review uses valid no-tools flag" \
    rg -q -- '--tools ""' codex/skills/claude-plan-review/SKILL.md
assert "co-review mentions both reviewers" \
    rg -q 'Claude.*Codex|Codex.*Claude' codex/skills/co-review/SKILL.md
assert "co-review uses internal Codex session" \
    rg -q 'current Codex session' codex/skills/co-review/SKILL.md
assert "co-review does not spawn nested codex review" \
    rg -q 'Do not launch `codex review`' codex/skills/co-review/SKILL.md
assert "co-review uses Claude native code review" \
    rg -q 'claude -p "/code-review' codex/skills/co-review/SKILL.md
assert "installer links repo-managed codex skills" \
    rg -q 'codex/skills' install/common/link.sh
assert "installer keeps ~/.codex/skills as a real directory" \
    rg -q 'mkdir -p "\$HOME"/\.codex/skills' install/common/link.sh

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
