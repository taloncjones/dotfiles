#!/bin/sh
# planning-skills.test.sh -- structural contract of the owned planning skills.
# codex-spec-review and codex-plan-review freeze and review what these skills
# produce, so the artifact paths and required sections are pinned here.

set -u

D=claude/skills
if [ ! -d "$D" ]; then
    echo "FAIL: $D not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
check() {
    label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
has() { grep -qF -- "$2" "$D/$1/SKILL.md"; }

ANCHOR='Never cite a symbol, file:line, test name, or count from memory or from a prior draft.'
ANCHOR_REF='the anchor rule in `writing-plans`'

for s in brainstorming writing-specs writing-plans; do
    check "$s frontmatter name matches its directory" \
        sh -c "sed -n '2p' '$D/$s/SKILL.md' | grep -qx 'name: $s'"
    check "$s has a one-line description" \
        sh -c "sed -n '3p' '$D/$s/SKILL.md' | grep -q '^description: .'"
    check "$s names no plugin-qualified skill" \
        sh -c "test -f '$D/$s/SKILL.md' && ! grep -q 'superpowers:' '$D/$s/SKILL.md'"
done

# writing-plans
check "writing-plans saves to the review-gate plans path" \
    has writing-plans 'docs/superpowers/plans/YYYY-MM-DD-<feature-name>.md'
check "writing-plans requires every header field" \
    sh -c "for f in '**Goal:**' '**Architecture:**' '**Tech Stack:**' '**Spec:**' '## Global Constraints' '## Review Focus'; do grep -qF -- \"\$f\" '$D/writing-plans/SKILL.md' || exit 1; done"
check "writing-plans requires a Mermaid diagram" \
    has writing-plans 'fenced block tagged `mermaid`'
check "writing-plans requires a recorded test baseline" \
    has writing-plans '## Test Baseline'
check "writing-plans requires the acceptance mapping table" \
    has writing-plans '## Acceptance Mapping'
check "writing-plans states the anchor rule" \
    has writing-plans "$ANCHOR"
check "writing-plans names the plan review for both runtimes" \
    sh -c "grep -qF '\`codex-plan-review\`' '$D/writing-plans/SKILL.md' && grep -qF '\`claude-plan-review\`' '$D/writing-plans/SKILL.md'"
check "writing-plans routes execution through this repo" \
    has writing-plans '`Workflow` tool'
check "writing-plans resolves the MAIN checkout" \
    has writing-plans 'git rev-parse --path-format=absolute --git-common-dir'
check "writing-plans freezes against the MAIN checkout" \
    has writing-plans 'review.py artifact --repo'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
