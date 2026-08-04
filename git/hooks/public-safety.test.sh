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

git_grep_clean() {
    pattern="$1"
    shift

    if git grep -I -q -E "$pattern" -- "$@"; then
        return 1
    else
        status=$?
        [ "$status" -eq 1 ] || return 1
    fi

    if git grep --cached -I -q -E "$pattern" -- "$@"; then
        return 1
    else
        status=$?
        [ "$status" -eq 1 ]
    fi
}

assert "no tracked local backlog file" \
    sh -c "! git ls-files --error-unmatch todo.md"
assert "no tracked Superpowers planning artifacts" \
    sh -c "! git ls-files 'docs/superpowers/**' | grep -q ."
assert "no hardcoded local user paths" \
    git_grep_clean '/Users/talon' . ':(exclude)git/hooks/public-safety.test.sh'
assert "no high-confidence secrets in tracked content" \
    git_grep_clean 'BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY|PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|glpat-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{20,}|-----BEGIN AGE SECRET KEY-----' . ':(exclude)**/*.pub' ':(exclude)git/hooks/public-safety.test.sh'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
