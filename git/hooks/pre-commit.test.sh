#!/bin/sh
# pre-commit.test.sh -- behavioral tests for the ECC-vendored pre-commit hook.
# Runs the real hook against throwaway git repos with staged fixtures.
#
# Fixture "secrets" are CONSTRUCTED at runtime (string concatenation /
# printf repetition) so neither this file nor any diff of it ever contains a
# literal secret-shaped token -- the public-safety suite and the hook itself
# scan this repo's tree and staged lines.
#
# Requires git and rg (the hook's scanner; CI installs ripgrep).

set -u

HOOK_SRC="$(pwd)/git/hooks/pre-commit"
if [ ! -f "$HOOK_SRC" ]; then
    echo "FAIL: $HOOK_SRC not found (run from repo root)" >&2
    exit 2
fi
if ! command -v rg >/dev/null 2>&1; then
    echo "SKIP: rg not installed; the hook's scanner needs it (CI installs ripgrep)"
    exit 0
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pre-commit-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

new_repo() {
    rm -rf "$TMP/repo"
    git init -q "$TMP/repo"
    git -C "$TMP/repo" config user.email test@example.invalid
    git -C "$TMP/repo" config user.name "Test"
}

# run_hook [env assignments...]: run the real hook inside the fixture repo
# with the bypass vars explicitly OFF unless the case sets them.
run_hook() {
    (cd "$TMP/repo" && ECC_SKIP_GIT_HOOKS=0 ECC_SKIP_PRECOMMIT=0 env "$@" "$HOOK_SRC") \
        >"$TMP/out" 2>&1
}

# Runtime-constructed fixtures (never literal in this source).
OPENAI_LIKE="sk-$(printf 'a%.0s' $(seq 1 24))"
AWS_LIKE="AKIA$(printf 'A%.0s' $(seq 1 16))"
KEYBLOCK_LIKE='-----BEGIN PRIVATE'' KEY-----'
CRED_LIKE='pass''word = "hunter2hunter2hunter2"'

# 1. Staged OpenAI-style key blocks the commit and names the finding.
new_repo
printf 'key = %s\n' "$OPENAI_LIKE" >"$TMP/repo/config.py"
git -C "$TMP/repo" add config.py
if run_hook; then
    fail "staged OpenAI-style key blocks commit"
else
    pass "staged OpenAI-style key blocks commit"
fi
if grep -q "Potential secret detected (OpenAI key)" "$TMP/out"; then
    pass "block names the matched pattern"
else
    fail "block names the matched pattern"
fi

# 2. AWS-style access key blocks.
new_repo
printf 'aws = %s\n' "$AWS_LIKE" >"$TMP/repo/deploy.env.example"
git -C "$TMP/repo" add deploy.env.example
if run_hook; then
    fail "staged AWS-style key blocks commit"
else
    pass "staged AWS-style key blocks commit"
fi

# 3. Private-key block header blocks.
new_repo
printf '%s\n' "$KEYBLOCK_LIKE" >"$TMP/repo/notes.txt"
git -C "$TMP/repo" add notes.txt
if run_hook; then
    fail "staged private-key block header blocks commit"
else
    pass "staged private-key block header blocks commit"
fi

# 4. Generic credential assignment blocks.
new_repo
printf '%s\n' "$CRED_LIKE" >"$TMP/repo/settings.ini"
git -C "$TMP/repo" add settings.ini
if run_hook; then
    fail "staged generic credential assignment blocks commit"
else
    pass "staged generic credential assignment blocks commit"
fi

# 5. Clean staged content passes.
new_repo
printf 'plain content, nothing secret\n' >"$TMP/repo/README.txt"
git -C "$TMP/repo" add README.txt
if run_hook; then
    pass "clean staged content passes"
else
    fail "clean staged content passes"
fi

# 6. Lockfiles are skipped even when they contain a secret-shaped token.
new_repo
printf 'token %s\n' "$OPENAI_LIKE" >"$TMP/repo/package-lock.json"
git -C "$TMP/repo" add package-lock.json
if run_hook; then
    pass "lockfile contents are exempt"
else
    fail "lockfile contents are exempt"
fi

# 7. Bypass vars skip the scan (documented emergency escape).
new_repo
printf 'key = %s\n' "$OPENAI_LIKE" >"$TMP/repo/config.py"
git -C "$TMP/repo" add config.py
if run_hook ECC_SKIP_PRECOMMIT=1; then
    pass "ECC_SKIP_PRECOMMIT=1 bypasses the scan"
else
    fail "ECC_SKIP_PRECOMMIT=1 bypasses the scan"
fi
if run_hook ECC_SKIP_GIT_HOOKS=1; then
    pass "ECC_SKIP_GIT_HOOKS=1 bypasses the scan"
else
    fail "ECC_SKIP_GIT_HOOKS=1 bypasses the scan"
fi

# 8. Nothing staged passes trivially.
new_repo
if run_hook; then
    pass "empty index passes"
else
    fail "empty index passes"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
