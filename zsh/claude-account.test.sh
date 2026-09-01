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

# --- shell-mode matrix: wrapper defined via .zshenv in -lc / -c / -ic ---
# ZDOTDIR sandbox mirrors the installed layout: $ZDOTDIR/.zshenv is a
# symlink to the repo file, so the sibling-path resolution is exercised.
ZDIR="$TMP/zdot"
mkdir -p "$ZDIR"
ln -s "$REPO/zsh/.zshenv" "$ZDIR/.zshenv"

# run_mode <label> <zsh-flags> <cwd> <zsh-body> <expected-cfg>
run_mode() {
    label="$1" flags="$2" cwd="$3" body="$4" want_cfg="$5"
    rec="$TMP/rec"
    : > "$rec"
    RECORD="$rec" HOME="$SBHOME" ZDOTDIR="$ZDIR" PATH="$TMP/bin:$PATH" \
        zsh "$flags" "cd '$cwd' && $body" >/dev/null 2>&1
    got_cfg="$(sed -n 's/^cfg=//p' "$rec")"
    if [ "$got_cfg" = "$want_cfg" ]; then
        pass "$label"
    else
        fail "$label (cfg='$got_cfg')"
    fi
}

# The full precedence ladder per startup mode (spec: matrix rows apply to
# every shell mode). Reuses the sandbox dirs and work-shortcut symlink
# created by the Task 1 cases.
for mode in "-lc" "-c" "-ic"; do
    run_mode "zsh $mode: personal cwd routes to ~/.claude" \
        "$mode" "$SBHOME/elsewhere" "claude" "$SBHOME/.claude"
    run_mode "zsh $mode: work cwd routes to ~/.claude-work" \
        "$mode" "$SBHOME/Git/work/proj" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: symlinked work path routes to work" \
        "$mode" "$SBHOME/work-shortcut" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: non-empty env wins" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
    run_mode "zsh $mode: exported-empty env consumed (work cwd)" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR= claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: exported-empty env consumed (personal cwd)" \
        "$mode" "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR= claude" "$SBHOME/.claude"
    run_mode "zsh $mode: --personal beats custom env" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal" "$SBHOME/.claude"
done

# .zshenv contract: silent on success, no external commands.
out="$(HOME="$SBHOME" ZDOTDIR="$ZDIR" zsh -c 'true' 2>&1)"
if [ -z "$out" ]; then
    pass ".zshenv is silent on startup"
else
    fail ".zshenv is silent on startup (got: $out)"
fi
if grep -vE '^[[:space:]]*#|^[[:space:]]*$' zsh/.zshenv | grep -qE '\$\(|`'; then
    fail ".zshenv runs no external commands (no command substitution)"
else
    pass ".zshenv runs no external commands (no command substitution)"
fi

# Degraded state 1: dangling ~/.zshenv symlink is a silent no-op.
ZBROKEN="$TMP/zdot-broken"
mkdir -p "$ZBROKEN"
ln -s "$TMP/nonexistent/.zshenv" "$ZBROKEN/.zshenv"
out="$(HOME="$SBHOME" ZDOTDIR="$ZBROKEN" zsh -c 'true' 2>&1)"
if [ -z "$out" ]; then
    pass "broken .zshenv link degrades to silent no-op"
else
    fail "broken .zshenv link degrades to silent no-op (got: $out)"
fi

# Degraded state 2: the tracked .zshenv runs but its sibling
# claude-account.zsh is missing -> silent, and claude falls through to
# the bare binary (stub sees no injected value).
ZDEG="$TMP/zdot-degraded"
mkdir -p "$ZDEG/zsh-copy"
cp "$REPO/zsh/.zshenv" "$ZDEG/zsh-copy/.zshenv"
ln -s "$ZDEG/zsh-copy/.zshenv" "$ZDEG/.zshenv"
: > "$TMP/rec"
out="$(RECORD="$TMP/rec" HOME="$SBHOME" ZDOTDIR="$ZDEG" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/Git/work/proj' && claude" 2>&1)"
got_cfg="$(sed -n 's/^cfg=//p' "$TMP/rec")"
if [ -z "$out" ] && [ "$got_cfg" = "UNSET" ]; then
    pass "missing sibling: silent no-op, bare binary runs"
else
    fail "missing sibling: silent no-op, bare binary runs (out='$out' cfg='$got_cfg')"
fi

# Degraded state 3: unreadable sibling -> same silent no-op (-r guard).
cp "$REPO/zsh/claude-account.zsh" "$ZDEG/zsh-copy/claude-account.zsh"
chmod 000 "$ZDEG/zsh-copy/claude-account.zsh"
: > "$TMP/rec"
out="$(RECORD="$TMP/rec" HOME="$SBHOME" ZDOTDIR="$ZDEG" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$SBHOME/Git/work/proj' && claude" 2>&1)"
got_cfg="$(sed -n 's/^cfg=//p' "$TMP/rec")"
chmod 644 "$ZDEG/zsh-copy/claude-account.zsh"
if [ -z "$out" ] && [ "$got_cfg" = "UNSET" ]; then
    pass "unreadable sibling: silent no-op, bare binary runs"
else
    fail "unreadable sibling: silent no-op, bare binary runs (out='$out' cfg='$got_cfg')"
fi

# ~/.zshenv.local is sourced when present.
echo 'export ZSHENV_LOCAL_MARK=1' > "$SBHOME/.zshenv.local"
val="$(HOME="$SBHOME" ZDOTDIR="$ZDIR" zsh -c 'echo "${ZSHENV_LOCAL_MARK:-missing}"' 2>/dev/null)"
rm -f "$SBHOME/.zshenv.local"
if [ "$val" = "1" ]; then
    pass ".zshenv sources ~/.zshenv.local"
else
    fail ".zshenv sources ~/.zshenv.local (got '$val')"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
