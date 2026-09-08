#!/bin/sh
# claude-account.test.sh -- behavioral tests for zsh/claude-account.zsh.
#
# Runs the real functions in zsh against a stub `claude` CLI that records the
# CLAUDE_CONFIG_DIR it received (distinguishing empty from unset) and its
# argv, in a sandbox HOME. Covers the spec's failure matrix: routing
# precedence, the never-empty invariant, and the snapshot case (wrapper
# defined, helper and vars stripped).

set -u
# Every case declares its routing context; the machine running the suite
# may itself be personal-only or inherit an account from an orchestrator.
unset CLAUDE_PERSONAL_ONLY CLAUDE_CONFIG_DIR CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR

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

# 1. The native default account requires an unset config variable; explicitly
# setting ~/.claude selects a separate authentication namespace in the CLI.
run_case "personal cwd uses native default account (config unset)" \
    "$SBHOME/elsewhere" "claude -p hi" "UNSET" "-p hi"

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

# 4. Non-empty env wins in unknown and work directories.
run_case "non-empty env wins from unknown cwd" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "non-empty env wins from work cwd" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
run_case "relative env value is normalized to absolute" \
    "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR=relcfg claude" "$SBHOME/elsewhere/relcfg"

# 5. Exported-empty env is consumed, never propagated.
run_case "exported-empty env treated as unset (personal cwd)" \
    "$SBHOME/elsewhere" "export CLAUDE_CONFIG_DIR=; claude" "UNSET"
run_case "exported-empty env treated as unset (work cwd)" \
    "$SBHOME/Git/work/proj" "export CLAUDE_CONFIG_DIR=; claude" "$SBHOME/.claude-work"

# 6. --personal overrides everything incl. custom env; flag not forwarded.
run_case "--personal beats custom env, flag filtered" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal -p hi" \
    "UNSET" "-p hi"
# Per spec, every argv element equal to --personal is the flag, even
# after -- (matches today's filter): it forces personal and is removed.
run_case "--personal after -- still forces personal and is filtered" \
    "$SBHOME/Git/work/proj" "claude -- --personal" "UNSET" "--"

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

# A personal-only machine must never launch through an inherited work or
# custom config, regardless of directory ownership.
run_case "personal-only machine routes work cwd to personal account" \
    "$SBHOME/Git/work/proj" "CLAUDE_PERSONAL_ONLY=1 claude" "UNSET"
run_case "personal-only machine overrides inherited work account" \
    "$SBHOME/Git/work/proj" \
    "CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "personal-only machine overrides custom account in unknown cwd" \
    "$SBHOME/elsewhere" \
    "CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "UNSET"
run_case "personal-only machine ignores alternate work config" \
    "$SBHOME/Git/work/proj" \
    "CLAUDE_PERSONAL_ONLY=1 CLAUDE_WORK_CONFIG_DIR=$SBHOME/custom claude" "UNSET"
run_case "personal-only flag zero preserves work routing" \
    "$SBHOME/Git/work/proj" "CLAUDE_PERSONAL_ONLY=0 claude" "$SBHOME/.claude-work"
run_case "explicit default config normalizes to the native personal account" \
    "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/.claude claude" "UNSET"
run_case "snapshot: personal-only machine remains personal without helper" \
    "$SBHOME/Git/work/proj" \
    "unfunction _claude_config_dir; unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR; CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" \
    "UNSET"

# Known personal ownership must win over inherited work/custom account
# settings. Use real Git repositories so external worktree routing depends
# on their canonical common directory, not a guessed worktree name.
PERSONAL="$SBHOME/Git/personal/proj"
PERSONAL_WT="$SBHOME/elsewhere/personal-worktree"
PERSONAL_WORK_WT="$SBHOME/Git/work/personal-worktree"
mkdir -p "$PERSONAL/nested" "$SBHOME/Git/personal-other"
git_fixture() {
    env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name=Test -c user.email=test@example.invalid "$@"
}
git_fixture init -q "$PERSONAL" || exit 2
git_fixture -C "$PERSONAL" commit -q --allow-empty -m fixture || exit 2
git_fixture -C "$PERSONAL" worktree add -q --detach "$PERSONAL_WT" || exit 2
git_fixture -C "$PERSONAL" worktree add -q --detach "$PERSONAL_WORK_WT" || exit 2
SEPARATE_WORK="$SBHOME/Git/personal/separate-work-metadata"
SEPARATE_EXTERNAL="$SBHOME/Git/personal/separate-external-metadata"
git_fixture init -q --separate-git-dir "$SBHOME/Git/work/personal-metadata.git" "$SEPARATE_WORK" || exit 2
git_fixture init -q --separate-git-dir "$SBHOME/external-personal-metadata.git" "$SEPARATE_EXTERNAL" || exit 2
mkdir -p "$PERSONAL_WT/nested"
ln -s "$PERSONAL" "$SBHOME/personal-shortcut"

run_case "personal repo overrides inherited work account" \
    "$PERSONAL" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "personal repo overrides inherited custom account" \
    "$PERSONAL" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "UNSET"
run_case "personal repo overrides inherited relative custom account" \
    "$PERSONAL" "CLAUDE_CONFIG_DIR=custom claude" "UNSET"
run_case "personal subdirectory overrides inherited work account" \
    "$PERSONAL/nested" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "symlink to personal repo overrides inherited work account" \
    "$SBHOME/personal-shortcut" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "external personal worktree overrides inherited work account" \
    "$PERSONAL_WT" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "external personal worktree subdirectory overrides custom account" \
    "$PERSONAL_WT/nested" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "UNSET"
run_case "personal worktree in work tree still uses personal account" \
    "$PERSONAL_WORK_WT" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "personal repo overrides overlapping work-tree setting" \
    "$PERSONAL" "CLAUDE_WORK_TREE=$SBHOME/Git claude" "UNSET"
run_case "inherited Git directory cannot mask personal ownership" \
    "$PERSONAL_WT" "GIT_DIR=$SBHOME/nonexistent CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "snapshot: personal root stays safe with helper and vars stripped" \
    "$PERSONAL" \
    "unfunction _claude_config_dir; unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR; CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" \
    "UNSET"
run_case "snapshot: external personal worktree stays safe with helper stripped" \
    "$PERSONAL_WT" \
    "unfunction _claude_config_dir; unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR; CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" \
    "UNSET"
run_case "personal path prefix requires a directory boundary" \
    "$SBHOME/Git/personal-other" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "$SBHOME/.claude-work"
run_case "personal checkout overrides separate Git metadata under work" \
    "$SEPARATE_WORK" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "personal checkout overrides separate Git metadata outside both trees" \
    "$SEPARATE_EXTERNAL" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
run_case "snapshot: personal checkout remains safe with separate work metadata" \
    "$SEPARATE_WORK" \
    "unfunction _claude_config_dir; CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"

# Git cannot recover the primary checkout path when it uses a separate Git
# directory and this linked checkout is external. Inherited work and custom
# routes must fail closed; an explicit personal request remains authorized.
SEPARATE_PRIMARY="$SBHOME/Git/personal/separate-primary"
SEPARATE_METADATA="$TMP/metadata/separate-primary.git"
SEPARATE_LINKED="$TMP/external-separate-linked"
mkdir -p "$(dirname "$SEPARATE_METADATA")"
git_fixture init -q --separate-git-dir "$SEPARATE_METADATA" "$SEPARATE_PRIMARY" || exit 2
git_fixture -C "$SEPARATE_PRIMARY" commit -q --allow-empty -m fixture || exit 2
git_fixture -C "$SEPARATE_PRIMARY" worktree add -q --detach "$SEPARATE_LINKED" || exit 2
run_refusal() {
    label="$1" cwd="$2" body="$3"
    rec="$TMP/rec"
    : > "$rec"
    out="$(RECORD="$rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
        zsh -c "cd '$cwd' && source '$REPO/$ACCT' && $body" 2>&1)"
    rc=$?
    if [ "$rc" = 2 ] && [ ! -s "$rec" ] && case "$out" in *ambiguous*) true;; *) false;; esac; then
        pass "$label"
    else
        fail "$label (status=$rc output='$out')"
    fi
}
run_refusal "external linked separate metadata refuses inherited work route" \
    "$SEPARATE_LINKED" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude"
run_refusal "external linked separate metadata refuses inherited custom route" \
    "$SEPARATE_LINKED" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude"
run_case "external linked separate metadata accepts explicit personal route" \
    "$SEPARATE_LINKED" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude --personal" "UNSET"

# Unsetting the child's config must not alter its parent shell's account.
out="$(RECORD="$TMP/rec" HOME="$SBHOME" PATH="$TMP/bin:$PATH" \
    zsh -c "cd '$PERSONAL' && source '$REPO/$ACCT' && export CLAUDE_CONFIG_DIR='$SBHOME/.claude-work'; claude; print -r -- \"\$CLAUDE_CONFIG_DIR\"")"
if [ "$out" = "$SBHOME/.claude-work" ]; then
    pass "personal launch preserves the parent shell's inherited work config"
else
    fail "personal launch preserves the parent shell's inherited work config (got '$out')"
fi

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
acct_case "claude-account: personal-only machine overrides work account" "$SBHOME/Git/work/proj" \
    "CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/.claude-work" "personal"
acct_case "claude-account: personal-only machine overrides unknown custom account" "$SBHOME/elsewhere" \
    "CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/custom" "personal"
acct_case "claude-account: personal repo overrides work label" "$PERSONAL" \
    "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work" "personal"
acct_case "claude-account: external personal worktree overrides work label" "$PERSONAL_WT" \
    "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work" "personal"
acct_case "claude-account: personal repo overrides overlapping work tree" "$PERSONAL" \
    "CLAUDE_WORK_TREE=$SBHOME/Git" "personal"
acct_case "claude-account: personal checkout overrides separate work metadata" "$SEPARATE_WORK" \
    "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work" "personal"
acct_case "claude-account: personal checkout overrides separate external metadata" "$SEPARATE_EXTERNAL" \
    "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work" "personal"

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
    run_mode "zsh $mode: personal-only machine overrides inherited work account" \
        "$mode" "$SBHOME/Git/work/proj" \
        "CLAUDE_PERSONAL_ONLY=1 CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
    run_mode "zsh $mode: personal repo overrides inherited work account" \
        "$mode" "$PERSONAL" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
    run_mode "zsh $mode: external personal worktree overrides inherited work account" \
        "$mode" "$PERSONAL_WT" "CLAUDE_CONFIG_DIR=$SBHOME/.claude-work claude" "UNSET"
    run_mode "zsh $mode: personal cwd routes to ~/.claude" \
        "$mode" "$SBHOME/elsewhere" "claude" "UNSET"
    run_mode "zsh $mode: work cwd routes to ~/.claude-work" \
        "$mode" "$SBHOME/Git/work/proj" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: symlinked work path routes to work" \
        "$mode" "$SBHOME/work-shortcut" "claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: non-empty env wins" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude" "$SBHOME/custom"
    run_mode "zsh $mode: exported-empty env consumed (work cwd)" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR= claude" "$SBHOME/.claude-work"
    run_mode "zsh $mode: exported-empty env consumed (personal cwd)" \
        "$mode" "$SBHOME/elsewhere" "CLAUDE_CONFIG_DIR= claude" "UNSET"
    run_mode "zsh $mode: --personal beats custom env" \
        "$mode" "$SBHOME/Git/work/proj" "CLAUDE_CONFIG_DIR=$SBHOME/custom claude --personal" "UNSET"
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
