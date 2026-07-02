#!/bin/sh
# pre-push.test.sh -- behavioral tests for the ECC-vendored pre-push hook.
# Runs the real hook against throwaway repos, feeding it the stdin ref lines
# git supplies (<local ref> <local sha> <remote ref> <remote sha>).
#
# The hook is a verification flow (lint/typecheck/test/build for Node
# projects), NOT a secret scanner. Node cases need node+npm (present in CI
# and dev containers); the suite self-SKIPs without them.

set -u

HOOK_SRC="$(pwd)/git/hooks/pre-push"
if [ ! -f "$HOOK_SRC" ]; then
    echo "FAIL: $HOOK_SRC not found (run from repo root)" >&2
    exit 2
fi
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "SKIP: node/npm not installed; the hook's Node verification path needs them"
    exit 0
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pre-push-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

ZERO_OID="$(printf '0%.0s' $(seq 1 40))"
FAKE_OLD="$(printf '1%.0s' $(seq 1 40))"
FAKE_NEW="$(printf '2%.0s' $(seq 1 40))"
PUSH_LINE="refs/heads/main $FAKE_NEW refs/heads/main $FAKE_OLD"
DELETE_LINE="refs/heads/gone $ZERO_OID refs/heads/gone $FAKE_OLD"

new_repo() {
    rm -rf "$TMP/repo"
    git init -q "$TMP/repo"
}

# run_hook <stdin-line> [env assignments...]
run_hook() {
    line="$1"; shift
    (cd "$TMP/repo" && printf '%s\n' "$line" \
        | ECC_SKIP_GIT_HOOKS=0 ECC_SKIP_PREPUSH=0 env "$@" "$HOOK_SRC" origin file:///dev/null) \
        >"$TMP/out" 2>&1
}

# 1. Repo with no recognized project files: skip, exit 0.
new_repo
if run_hook "$PUSH_LINE"; then
    pass "no supported checks exits 0"
else
    fail "no supported checks exits 0"
fi
if grep -q "No supported checks found" "$TMP/out"; then
    pass "skip path says so"
else
    fail "skip path says so"
fi

# 2. Node project with a failing lint script blocks the push.
new_repo
printf '{"name":"t","version":"1.0.0","scripts":{"lint":"exit 7"}}\n' >"$TMP/repo/package.json"
if run_hook "$PUSH_LINE"; then
    fail "failing node lint blocks push"
else
    pass "failing node lint blocks push"
fi
if grep -q "FAILED: lint failed" "$TMP/out"; then
    pass "failure names the failing script"
else
    fail "failure names the failing script"
fi

# 3. Node project with passing scripts passes and reports success.
new_repo
printf '{"name":"t","version":"1.0.0","scripts":{"lint":"true","test":"true"}}\n' >"$TMP/repo/package.json"
if run_hook "$PUSH_LINE"; then
    pass "passing node scripts exit 0"
else
    fail "passing node scripts exit 0"
fi
if grep -q "Verification checks passed" "$TMP/out"; then
    pass "success path says so"
else
    fail "success path says so"
fi

# 4. Branch-deletion-only pushes skip verification entirely (even when a
#    failing project is present).
new_repo
printf '{"name":"t","version":"1.0.0","scripts":{"lint":"exit 7"}}\n' >"$TMP/repo/package.json"
if run_hook "$DELETE_LINE"; then
    pass "delete-only push skips checks"
else
    fail "delete-only push skips checks"
fi

# 5. Bypass vars skip the flow.
new_repo
printf '{"name":"t","version":"1.0.0","scripts":{"lint":"exit 7"}}\n' >"$TMP/repo/package.json"
if run_hook "$PUSH_LINE" ECC_SKIP_PREPUSH=1; then
    pass "ECC_SKIP_PREPUSH=1 bypasses the flow"
else
    fail "ECC_SKIP_PREPUSH=1 bypasses the flow"
fi
if run_hook "$PUSH_LINE" ECC_SKIP_GIT_HOOKS=1; then
    pass "ECC_SKIP_GIT_HOOKS=1 bypasses the flow"
else
    fail "ECC_SKIP_GIT_HOOKS=1 bypasses the flow"
fi

# 6. Documented contract: the hook does NOT scan secrets (that is
#    pre-commit's job); a secret-shaped token in the tree does not block.
new_repo
printf 'sk-%s\n' "$(printf 'a%.0s' $(seq 1 24))" >"$TMP/repo/notes.txt"
if run_hook "$PUSH_LINE"; then
    pass "pre-push does not secret-scan (pre-commit's job)"
else
    fail "pre-push does not secret-scan (pre-commit's job)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
