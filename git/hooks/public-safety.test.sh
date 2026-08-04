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

# Self-test: prove the scanner detects plants before trusting its green runs.
# The staged-only case guards the index-scan fix -- content staged but
# overwritten in the working tree must still be caught via --cached.
git_grep_clean_detects_plants() {
    tmp_repo="$(mktemp -d)" || return 1
    (
        cd "$tmp_repo" || exit 1
        export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
        git init -q . || exit 1
        echo "plant tracked_marker_zz" > tracked.txt
        git add tracked.txt || exit 1
        git -c user.email=t@example.invalid -c user.name=t commit -qm seed || exit 1
        echo "plant staged_marker_zz" > staged.txt
        git add staged.txt || exit 1
        echo "clean working copy" > staged.txt
        ! git_grep_clean 'tracked_marker_zz' . || exit 1
        ! git_grep_clean 'staged_marker_zz' . || exit 1
        git_grep_clean 'absent_marker_zz' . || exit 1
    )
    result=$?
    rm -rf "$tmp_repo"
    return "$result"
}

assert "scanner self-test catches tracked and staged-only plants" \
    git_grep_clean_detects_plants
assert "no tracked local backlog file" \
    sh -c "! git ls-files --error-unmatch todo.md"
assert "no tracked planning artifacts" \
    sh -c "! git ls-files 'docs/superpowers/**' 'docs/plans/**' 'docs/specs/**' | grep -q ."
assert "no hardcoded local user paths" \
    git_grep_clean '/Users/talon' . ':(exclude)git/hooks/public-safety.test.sh'
assert "no high-confidence secrets in tracked content" \
    git_grep_clean 'BEGIN (RSA|DSA|EC|OPENSSH|PGP) PRIVATE KEY|PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|sk-[A-Za-z0-9_-]{20,}|sk-proj-[A-Za-z0-9_-]+|github_pat_[A-Za-z0-9_]+|gh[pousr]_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]+|glpat-[A-Za-z0-9_-]{20,}|AIza[A-Za-z0-9_-]{20,}|-----BEGIN AGE SECRET KEY-----' . ':(exclude)**/*.pub' ':(exclude)git/hooks/public-safety.test.sh'

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
