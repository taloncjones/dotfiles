#!/bin/sh
# dotfiles-test-env.test.sh -- the wrapper scrubs an armed herdr pane and keeps the rest.
set -u
PASS=0; FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

REPO="$(pwd)"
WRAP="$REPO/bin/dotfiles-test-env"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-test-env-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
SHIM="$TMP/pane/bin/herdr-shims"
mkdir -p "$SHIM" "$TMP/cwd"
printf '#!/bin/sh\nexit 0\n' >"$SHIM/gh"
chmod +x "$SHIM/gh"

out=$(HERDR_ENV=1 HERDR_PANE_ID=w0:p1 HERDR_SOCKET_PATH=/nonexistent/sock HERDR_BIN_PATH=/nonexistent/herdr \
    HERDR_TEST_NOVEL=1 WORKFLOW_PERSONAL_ACCOUNT=1 CLAUDE_PERSONAL_ONLY=1 CODEX_HOME=/nonexistent/codex \
    BASH_ENV="$REPO/bin/herdr-shims/path.sh" GH_TOKEN=fixture GITHUB_TOKEN=fixture GH_ENTERPRISE_TOKEN=fixture \
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=cat OP_ENV_FILE=/nonexistent/op.env \
    PATH="$SHIM:$PATH:$SHIM/" "$WRAP" /bin/sh -c '
        env | grep -Eo "^(HERDR_[A-Za-z0-9_]*|BASH_ENV|WORKFLOW_PERSONAL_ACCOUNT|CLAUDE_PERSONAL_ONLY|CODEX_HOME|GH_TOKEN|GITHUB_TOKEN|GH_ENTERPRISE_TOKEN|GIT_CONFIG_[A-Z0-9_]*|OP_ENV_FILE)="
        printf "%s\n" "$PATH" | tr : "\n" | grep herdr-shims
        echo END')
if [ "$out" = END ]; then
    pass "an armed pane's vars and shim PATH entries never reach the command"
else
    fail "an armed pane's vars and shim PATH entries never reach the command: $out"
fi

CWD="$(cd "$TMP/cwd" && pwd -P)"
exp="/fixture/home|/fixture/tmp|/fixture/cfg|keep-me|n1 i1 r1 e1 s1 p1|[:/fixture/a:/fixture/b::/usr/bin:/bin:]|$CWD"
out=$(cd "$TMP/cwd" && HOME=/fixture/home TMPDIR=/fixture/tmp CLAUDE_CONFIG_DIR=/fixture/cfg TEST_KEEP=keep-me \
    name=n1 i=i1 path_rest=r1 path_entry=e1 scrubbed_path=s1 path_started=p1 \
    PATH=":/fixture/a:/fixture/x/bin/herdr-shims:/fixture/b::/usr/bin:/bin:/fixture/y/bin/herdr-shims/:" \
    "$WRAP" /bin/sh -c 'printf "%s|%s|%s|%s|%s %s %s %s %s %s|[%s]|%s\n" "$HOME" "$TMPDIR" "$CLAUDE_CONFIG_DIR" "$TEST_KEEP" \
        "$name" "$i" "$path_rest" "$path_entry" "$scrubbed_path" "$path_started" "$PATH" "$(pwd -P)"')
if [ "$out" = "$exp" ]; then
    pass "HOME, TMPDIR, CLAUDE_CONFIG_DIR, other vars, the rest of PATH and the cwd are kept"
else
    fail "HOME, TMPDIR, CLAUDE_CONFIG_DIR, other vars, the rest of PATH and the cwd are kept: $out"
fi

out=$(printf 'hello\n' | "$WRAP" /bin/sh -c 'read l; printf "got:%s\n" "$l"; exit 7'); rc=$?
if [ "$rc" = 7 ] && [ "$out" = "got:hello" ]; then
    pass "stdin and the exit status pass through"
else
    fail "stdin and the exit status pass through: rc=$rc out=$out"
fi

err=$("$WRAP" 2>&1 >/dev/null); rc=$?
if [ "$rc" = 2 ] && printf '%s\n' "$err" | grep -q 'usage:'; then
    pass "no command prints usage and exits 2"
else
    fail "no command prints usage and exits 2: rc=$rc err=$err"
fi

out=$(HERDR_ENV=1 bash -c '. "$1"; printf "%s|%s\n" "${HERDR_ENV-unset}" "$*"' _ "$WRAP" --list); rc=$?
if [ "$rc" = 0 ] && [ "$out" = "unset|$WRAP --list" ]; then
    pass "sourcing scrubs the caller and returns without exec"
else
    fail "sourcing scrubs the caller and returns without exec: rc=$rc out=$out"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
