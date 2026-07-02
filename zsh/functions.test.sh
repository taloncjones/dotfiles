#!/bin/sh
# functions.test.sh -- behavioral tests for the plugin ground-truth helpers in
# zsh/functions.zsh (_claude_plugin_installed / _claude_ensure_plugin).
#
# The helpers verify installs against <config-dir>/plugins/installed_plugins.json
# instead of trusting `claude` exit codes (ported from bootstrap-cloud.sh; the
# CLI can exit 0 without installing). Each behavioral case runs the real
# functions in zsh against a stub `claude` CLI and a sandbox config dir.
#
# Requires zsh; when absent (some containers), behavioral cases are skipped
# with a notice and only the static assertions run. CI installs zsh, so the
# full suite always runs there.

set -u

FUNCS=zsh/functions.zsh
if [ ! -f "$FUNCS" ]; then
    echo "FAIL: $FUNCS not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# --- static assertions (always run) ---
assert_grep() {
    label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

assert_grep "ecc-install goes through _claude_ensure_plugin" \
    grep -q '_claude_ensure_plugin "\$cfg_dir" "ecc@ecc"' "$FUNCS"
assert_grep "superpowers-install goes through _claude_ensure_plugin" \
    grep -q '_claude_ensure_plugin "\$cfg_dir" "superpowers@claude-plugins-official"' "$FUNCS"
assert_grep "install verification never greps CLI plugin listings" \
    sh -c "! grep -q 'plugins list' $FUNCS"
assert_grep "ensure helper verifies installed_plugins.json" \
    grep -q 'installed_plugins.json' "$FUNCS"

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed; behavioral cases run in CI (which installs zsh)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
    exit $?
fi

REPO="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# Stub CLIs. Each is a fake `claude` put first on PATH for one case.
# silent: every verb "succeeds" but writes nothing -- the exit-code lie.
mkdir -p "$TMP/stubs/silent"
cat >"$TMP/stubs/silent/claude" <<'EOF'
#!/bin/sh
exit 0
EOF

# unreachable: marketplace registration itself fails (network down).
mkdir -p "$TMP/stubs/unreachable"
cat >"$TMP/stubs/unreachable/claude" <<'EOF'
#!/bin/sh
case "$*" in
    *"marketplace add"*) echo "network error" >&2; exit 1 ;;
esac
exit 0
EOF

# good: writes the manifest on marketplace verbs and the install record on
# install, into the config dir the caller passed via CLAUDE_CONFIG_DIR.
mkdir -p "$TMP/stubs/good"
cat >"$TMP/stubs/good/claude" <<'EOF'
#!/bin/sh
cfg="${CLAUDE_CONFIG_DIR:?}"
case "$*" in
    *"marketplace add"*|*"marketplace update"*)
        mkdir -p "$cfg/plugins/marketplaces/ecc/.claude-plugin"
        printf '{"name": "ecc", "plugins": [{"name": "ecc"}]}\n' \
            > "$cfg/plugins/marketplaces/ecc/.claude-plugin/marketplace.json"
        ;;
    *"plugins install"*)
        mkdir -p "$cfg/plugins"
        printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' \
            > "$cfg/plugins/installed_plugins.json"
        ;;
esac
exit 0
EOF

# broken: any invocation fails loudly -- proves the caller never reached the CLI.
mkdir -p "$TMP/stubs/broken"
cat >"$TMP/stubs/broken/claude" <<'EOF'
#!/bin/sh
echo "claude should not have been invoked" >&2
exit 1
EOF
chmod +x "$TMP"/stubs/*/claude

# run_case <stub> <snippet>: source functions.zsh with claude OFF the PATH (so
# source-time update checks no-op), then put the stub first and eval the
# snippet with a fast retry budget. Output lands in $TMP/out.
run_case() {
    stub="$1"; snippet="$2"
    HOME="$TMP/home" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/$stub' /usr/bin /bin)
        CLAUDE_PLUGIN_RETRIES=2
        CLAUDE_PLUGIN_RETRY_DELAY=0
        $snippet
    " >"$TMP/out" 2>&1
}

# 1. Pre-recorded install short-circuits without ever invoking the CLI.
CFG="$TMP/cfg1"
mkdir -p "$CFG/plugins"
printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    pass "already-installed short-circuits on installed_plugins.json"
else
    fail "already-installed short-circuits on installed_plugins.json"
fi

# 2. The exit-code lie: every CLI verb exits 0 but nothing lands on disk.
#    The helper must fail closed and say so.
CFG="$TMP/cfg2"; mkdir -p "$CFG"
if run_case silent "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    fail "silent no-op install fails closed"
else
    pass "silent no-op install fails closed"
fi
if grep -q "not installed after" "$TMP/out"; then
    pass "silent no-op failure names the cause"
else
    fail "silent no-op failure names the cause"
fi

# 3. Unreachable marketplace: registration fails, helper returns non-zero.
CFG="$TMP/cfg3"; mkdir -p "$CFG"
if run_case unreachable "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    fail "unreachable marketplace returns non-zero"
else
    pass "unreachable marketplace returns non-zero"
fi
if grep -q "marketplace add failed" "$TMP/out"; then
    pass "unreachable marketplace says so"
else
    fail "unreachable marketplace says so"
fi

# 4. Healthy path: install writes the record, helper verifies and succeeds.
CFG="$TMP/cfg4"; mkdir -p "$CFG"
if run_case good "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    pass "verified install succeeds"
else
    fail "verified install succeeds"
fi
if grep -q "Installed ecc@ecc" "$TMP/out"; then
    pass "verified install reports [OK]"
else
    fail "verified install reports [OK]"
fi

# 5. _claude_plugin_installed ground truth: false without the record, true with it.
CFG="$TMP/cfg5"; mkdir -p "$CFG"
if run_case broken "_claude_plugin_installed '$CFG' ecc@ecc"; then
    fail "plugin_installed false when record missing"
else
    pass "plugin_installed false when record missing"
fi
mkdir -p "$CFG/plugins"
printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_plugin_installed '$CFG' ecc@ecc"; then
    pass "plugin_installed true when record present"
else
    fail "plugin_installed true when record present"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
