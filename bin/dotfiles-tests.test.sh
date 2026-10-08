#!/bin/sh
# dotfiles-tests.test.sh -- the runner fails when a suite creates state-root entries.
set -u
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

REPO="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-tests-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SKEL="$TMP/skel"; HOMEDIR="$TMP/home"
mkdir -p "$SKEL/bin" "$HOMEDIR/.claude/herdr-orch"
cp "$REPO/bin/dotfiles-tests" "$SKEL/bin/dotfiles-tests"
cp "$REPO/bin/dotfiles-test-env" "$SKEL/bin/dotfiles-test-env"
chmod +x "$SKEL/bin/dotfiles-tests"
git -C "$SKEL" init -q
"$REPO/bin/dotfiles-tests" --list | while read -r interp path; do
    mkdir -p "$SKEL/$(dirname "$path")"
    printf '#!/bin/sh\nexit 0\n' >"$SKEL/$path"
done

run() { HOME="$HOMEDIR" CLAUDE_CONFIG_DIR= "$SKEL/bin/dotfiles-tests" >"$TMP/out" 2>&1; }

if run; then pass "all-stub run exits 0"; else fail "all-stub run exits 0"; cat "$TMP/out" >&2; fi

LEAKER=$(sed -n 's/^sh //p' "$SKEL/bin/dotfiles-tests" | sed -n '1p')
printf '#!/bin/sh\nmkdir -p "$HOME/.claude/herdr-orch/example-com-leak-00000000"\n' >"$SKEL/$LEAKER"
if run; then fail "a leaking suite fails the run"; else pass "a leaking suite fails the run"; fi
if grep -q 'example-com-leak-00000000' "$TMP/out"; then pass "the new entry is named"; else fail "the new entry is named"; fi

SPACED="$TMP/cfg dir"
mkdir -p "$SPACED/herdr-orch"
printf '#!/bin/sh\nmkdir -p "$CLAUDE_CONFIG_DIR/herdr-orch/example-com-leak-11111111"\n' >"$SKEL/$LEAKER"
if HOME="$HOMEDIR" CLAUDE_CONFIG_DIR="$SPACED" "$SKEL/bin/dotfiles-tests" >"$TMP/out" 2>&1; then
    fail "a leak under a CLAUDE_CONFIG_DIR with a space fails the run"
else
    pass "a leak under a CLAUDE_CONFIG_DIR with a space fails the run"
fi

# An op-env agent session's git overrides and pointers never reach a suite.
printf '#!/bin/sh\n[ -z "${GIT_CONFIG_SYSTEM:-}${GIT_CONFIG_COUNT:-}${GIT_CONFIG_KEY_0:-}${OP_ENV_FILE:-}" ]\n' >"$SKEL/$LEAKER"
if HOME="$HOMEDIR" CLAUDE_CONFIG_DIR= OP_ENV_ACTIVE=1 OP_ENV_FILE=/nonexistent/op.env \
    GIT_CONFIG_SYSTEM=/nonexistent/gitconfig GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=cat \
    "$SKEL/bin/dotfiles-tests" >"$TMP/out" 2>&1; then
    pass "an op-env session's git overrides never reach a suite"
else
    fail "an op-env session's git overrides never reach a suite"
fi

# An armed herdr pane never reaches a suite through the runner.
printf '#!/bin/sh\n[ -z "${HERDR_ENV:-}${HERDR_SOCKET_PATH:-}${BASH_ENV:-}${GH_TOKEN:-}" ] || exit 1\ncase ":$PATH:" in *herdr-shims*) exit 1 ;; esac\n' >"$SKEL/$LEAKER"
mkdir -p "$TMP/pane/bin/herdr-shims"
printf '#!/bin/sh\nexit 0\n' >"$TMP/pane/bin/herdr-shims/gh"
chmod +x "$TMP/pane/bin/herdr-shims/gh"
if HOME="$HOMEDIR" CLAUDE_CONFIG_DIR= HERDR_ENV=1 HERDR_SOCKET_PATH=/nonexistent/sock GH_TOKEN=fixture \
    BASH_ENV="$REPO/bin/herdr-shims/path.sh" PATH="$TMP/pane/bin/herdr-shims:$PATH" \
    "$SKEL/bin/dotfiles-tests" >"$TMP/out" 2>&1 && grep -q '^=== dotfiles-tests: ' "$TMP/out"; then
    pass "an armed herdr pane never reaches a suite through the runner"
else
    fail "an armed herdr pane never reaches a suite through the runner"
    cat "$TMP/out" >&2
fi
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
