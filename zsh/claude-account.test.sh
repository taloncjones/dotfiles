#!/bin/sh
# claude-account.test.sh -- behavioral tests for zsh/claude-account.zsh.
#
# Runs the real functions in zsh against a stub `claude` CLI that records the
# CLAUDE_CONFIG_DIR it received (distinguishing empty from unset) and its
# argv, in a sandbox HOME. Covers the spec's failure matrix: routing
# precedence, the never-empty invariant, and the snapshot case (wrapper
# defined, helper and vars stripped).

set -u

ACCT=zsh/claude-account.zsh
if [ ! -f "$ACCT" ]; then
    echo "FAIL: $ACCT not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# --- static assertions (always run) ---
# Extract the claude() body, strip comments (the implementation comments
# reference the helper by name), then look for a real invocation.
if awk '/^function claude\(\)/,/^}/' "$ACCT" | sed 's/#.*//' | grep -q '_claude_config_dir'; then
    fail "wrapper is self-contained (no helper call in claude())"
else
    pass "wrapper is self-contained (no helper call in claude())"
fi
if grep -q 'CLAUDE_CONFIG_DIR="\$cfg" command claude' "$ACCT"; then
    pass "wrapper always injects an explicit config dir"
else
    fail "wrapper always injects an explicit config dir"
fi

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed; behavioral cases run in CI (which installs zsh)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
    exit $?
fi

REPO="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-account-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
# Canonicalize: the wrapper normalizes with :A, so expectations must be
# symlink-free paths (macOS mktemp returns /var/..., which :A rewrites
# to /private/var/...).
TMP="$(cd "$TMP" && pwd -P)"
SBHOME="$TMP/home"
mkdir -p "$SBHOME/Git/work/proj" "$SBHOME/elsewhere" "$TMP/bin"

# Stub claude: records the env value (or UNSET) and each argv element on
# its own line (boundary-preserving), exits 0.
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
{
    printf 'cfg=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}"
    for a in "$@"; do printf 'arg=%s\n' "$a"; done
} > "$RECORD"
exit 0
EOF
chmod +x "$TMP/bin/claude"

# run_case <label> <cwd> <zsh-body> <expected-cfg> [expected-argv]
# expected-argv is the space-joined argv (our expectations contain no
# spaces inside a single argument; per-arg lines remain in $RECORD).
# Sources claude-account.zsh directly (Task 2 adds .zshenv-driven modes).
run_case() {
    label="$1" cwd="$2" body="$3" want_cfg="$4" want_argv="${5-}"
    rec="$TMP/rec"
    : > "$rec"
    RECORD="$rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
        zsh -c "cd '$cwd' && source '$REPO/$ACCT' && $body" >/dev/null 2>&1
    got_cfg="$(sed -n 's/^cfg=//p' "$rec")"
    got_argv="$(sed -n 's/^arg=//p' "$rec" | tr '\n' ' ')"
    got_argv="${got_argv% }"
    if [ "$got_cfg" = "$want_cfg" ] && { [ -z "$want_argv" ] || [ "$got_argv" = "$want_argv" ]; }; then
        pass "$label"
    else
        fail "$label (cfg='$got_cfg' argv='$got_argv')"
    fi
}

# 1. Personal cwd, env unset: explicit personal dir injected.
run_case "personal cwd routes to ~/.claude (always-inject)" \
    "$SBHOME/elsewhere" "claude -p hi" "$SBHOME/.claude" "-p hi"

# 2. Work cwd, env unset: work dir injected.
run_case "work cwd routes to ~/.claude-work" \
    "$SBHOME/Git/work/proj" "claude" "$SBHOME/.claude-work"

# 3. Symlinked path INTO the work tree: cwd is a symlink outside the tree
# whose target is inside it; ${PWD:A} resolves to the real work-tree
# location, so it routes to work.
mkdir -p "$SBHOME/Git/work/real-proj"
ln -s "$SBHOME/Git/work/real-proj" "$SBHOME/work-shortcut"
run_case "symlinked path into work tree routes to work" \
    "$SBHOME/work-shortcut" "claude" "$SBHOME/.claude-work"

# 4. Non-empty env wins over cwd, from both cwds.
run_case "non-empty env wins from personal cwd" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "non-empty env wins from work cwd" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "relative env value is normalized to absolute" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=relcfg claude" "$SBHOME/elsewhere/relcfg"

# 5. Exported-empty env is consumed, never propagated.
run_case "exported-empty env treated as unset (personal cwd)" \
    "$SBHOME/elsewhere" "export CLAUDE_CONFIG_DIR=; claude" "$SBHOME/.claude"
run_case "exported-empty env treated as unset (work cwd)" \
    "$SBHOME/Git/work/proj" "export CLAUDE_CONFIG_DIR=; claude" "$SBHOME/.claude-work"

# 6. --personal overrides everything incl. custom env; flag not forwarded.
run_case "--personal beats custom env, flag filtered" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal -p hi" \
    "$SBHOME/.claude" "-p hi"
# Per spec, every argv element equal to --personal is the flag, even
# after -- (matches today's filter): it forces personal and is removed.
run_case "--personal after -- still forces personal and is filtered" \
    "$SBHOME/Git/work/proj" "claude -- --personal" "$SBHOME/.claude" "--"

# 7. Pre-set CLAUDE_WORK_* values are honored.
mkdir -p "$SBHOME/alt-tree/x"
run_case "pre-set CLAUDE_WORK_TREE/CONFIG_DIR are honored" \
    "$SBHOME/alt-tree/x" \
    "CLAUDE_WORK_TREE=$SBHOME/alt-tree CLAUDE_WORK_CONFIG_DIR=$SBHOME/.alt-work claude" \
    "$SBHOME/.alt-work"

# 8. Snapshot simulation: helper and vars stripped, wrapper still routes.
run_case "snapshot: helper+vars stripped, work cwd still routes" \
    "$SBHOME/Git/work/proj" \
    "unfunction _claude_config_dir; unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR; claude" \
    "$SBHOME/.claude-work"

# 9. Wrapper exit status passes through.
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
printf 'cfg=%s\nargv=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}" "$*" > "$RECORD"
exit 7
EOF
chmod +x "$TMP/bin/claude"
RECORD="$TMP/rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/elsewhere' && source '$REPO/$ACCT' && claude" >/dev/null 2>&1
rc=$?
if [ "$rc" = 7 ]; then
    pass "exit status passes through"
else
    fail "exit status passes through (got $rc, want 7)"
fi
# restore the recording stub
cat >"$TMP/bin/claude" <<'EOF'
#!/bin/sh
{
    printf 'cfg=%s\n' "${CLAUDE_CONFIG_DIR-UNSET}"
    printf 'argv=%s\n' "$*"
} > "$RECORD"
exit 0
EOF
chmod +x "$TMP/bin/claude"

# 10. claude-account labels.
acct_case() {
    label="$1" cwd="$2" envp="$3" want="$4"
    out="$(HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
        zsh -c "cd '$cwd' && source '$REPO/$ACCT' && $envp claude-account" 2>/dev/null)"
    case "$out" in
        "$want"*) pass "$label" ;;
        *) fail "$label (got '$out')" ;;
    esac
}
acct_case "claude-account: personal label" "$SBHOME/elsewhere" "" "personal"
acct_case "claude-account: work label" "$SBHOME/Git/work/proj" "" "work"
acct_case "claude-account: custom label" "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=$SBHOME/custom" "custom"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
