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

assert "no tracked local backlog file" \
    sh -c "! git ls-files --error-unmatch todo.md"
assert "no hardcoded local user paths" \
    sh -c "! rg -q --hidden --glob '!.git/**' --glob '!git/hooks/public-safety.test.sh' '/Users/talon' ."
assert "no high-confidence secrets in current tree" \
    sh -c "! rg -q --hidden --glob '!.git/**' --glob '!**/*.pub' --glob '!**/__pycache__/**' --glob '!**/*.pyc' --glob '!git/hooks/public-safety.test.sh' 'BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY|PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|glpat-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{20,}|-----BEGIN AGE SECRET KEY-----' ."

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
