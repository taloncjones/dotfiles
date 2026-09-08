#!/bin/sh
# Exercise the installed .zshenv route against a recording Codex binary.
set -u
# Cases declare their machine policy independently of the launching shell.
unset CLAUDE_PERSONAL_ONLY

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed"
    exit 0
fi

REPO="$(pwd -P)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-account-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
SBHOME="$TMP/home"
PERSONAL="$SBHOME/Git/personal/project"
WORK="$SBHOME/Git/work/project"
UNKNOWN="$SBHOME/elsewhere"
POLICY='plugins."atlassian@claude-plugins-official".enabled=false'
PASS=0
FAIL=0
mkdir -p "$PERSONAL/nested" "$WORK" "$UNKNOWN" "$TMP/bin" "$TMP/zdot"
ln -s "$REPO/zsh/.zshenv" "$TMP/zdot/.zshenv"
ln -s "$PERSONAL" "$SBHOME/personal-shortcut"

cat > "$TMP/bin/codex" <<'EOF'
#!/bin/sh
printf '%s\0' "$@" > "$RECORD"
if [ "${TEST_CODEX_STDIO:-0}" = 1 ]; then
    cat
    printf 'codex stderr\n' >&2
fi
exit "${TEST_CODEX_STATUS:-0}"
EOF
chmod +x "$TMP/bin/codex"

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# Arguments are passed positionally, including spaces, empty strings and
# newlines. Compare NUL-delimited records to catch changed argv boundaries.
run_case() {
    label="$1" cwd="$2" personal="$3"
    shift 3
    if [ "$personal" = yes ]; then
        printf '%s\0' -c "$POLICY" "$@" > "$TMP/expected"
    else
        printf '%s\0' "$@" > "$TMP/expected"
    fi
    : > "$TMP/record"
    RECORD="$TMP/record" HOME="$SBHOME" ZDOTDIR="$TMP/zdot" \
        PATH="$TMP/bin:$PATH" CASE_CWD="$cwd" \
        zsh -c 'cd -- "$CASE_CWD" && codex "$@"' zsh "$@" \
        > "$TMP/stdout" 2> "$TMP/stderr"
    rc=$?
    if [ "$rc" = 0 ] && cmp -s "$TMP/expected" "$TMP/record" \
        && [ ! -s "$TMP/stdout" ] && [ ! -s "$TMP/stderr" ]; then
        pass "$label"
    else
        fail "$label (status $rc; recorded arguments follow)"
        tr '\000' '\n' < "$TMP/record" >&2
        cat "$TMP/stderr" >&2
    fi
}

run_case "personal directory disables Atlassian in noninteractive shells" "$PERSONAL" yes exec hi
run_case "work directory keeps original plugin policy" "$WORK" no exec hi
run_case "unknown directory keeps original plugin policy" "$UNKNOWN" no exec hi
CLAUDE_PERSONAL_ONLY=1 run_case "personal-only machine disables Atlassian in work directory" "$WORK" yes exec hi
CLAUDE_PERSONAL_ONLY=1 run_case "personal-only machine disables Atlassian in unknown directory" "$UNKNOWN" yes exec hi
CLAUDE_PERSONAL_ONLY=1 run_case "personal-only machine disables Atlassian for explicit work target" "$UNKNOWN" yes -C "$WORK" exec hi
CLAUDE_PERSONAL_ONLY=0 run_case "personal-only flag zero preserves work plugin policy" "$WORK" no exec hi
run_case "personal path prefix requires a directory boundary" "$SBHOME/Git" no --cd personal-other
run_case "symlink into personal tree gets personal policy" "$SBHOME/personal-shortcut" yes exec hi
run_case "-C personal target overrides work cwd" "$WORK" yes -C "$PERSONAL" exec hi
run_case "--cd work target overrides personal cwd" "$PERSONAL" no --cd "$WORK" exec hi
run_case "--cd= handles a personal target" "$WORK" yes "--cd=$PERSONAL" exec hi
run_case "attached -C handles a personal target" "$WORK" yes "-C$PERSONAL" exec hi
run_case "attached -C= handles a personal target" "$WORK" yes "-C=$PERSONAL" exec hi
run_case "relative --cd resolves against invocation cwd" "$WORK" yes --cd ../../personal/project exec hi
run_case "--cd after exec is honored" "$WORK" yes exec --cd "$PERSONAL" hi
run_case "-- ends directory option parsing" "$WORK" no exec -- -C "$PERSONAL"
run_case "prompt --cd= text after -- stays literal" "$PERSONAL" yes -- "--cd=$WORK"
run_case "other config and quoted argv are preserved" "$PERSONAL" yes \
    -c 'model="gpt-6-astra"' exec 'a prompt with spaces' '' 'line one
line two'

# Either personal checkout location or canonical ownership requires personal policy.
git_fixture() {
    env GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -c core.hooksPath=/dev/null -c commit.gpgsign=false \
        -c user.name=Test -c user.email=test@example.invalid "$@"
}
for repo in "$PERSONAL" "$WORK"; do
    git_fixture init -q "$repo" || exit 2
    git_fixture -C "$repo" commit -q --allow-empty -m fixture || exit 2
done
git_fixture -C "$PERSONAL" worktree add -q --detach "$UNKNOWN/personal-worktree" || exit 2
git_fixture -C "$WORK" worktree add -q --detach "$SBHOME/Git/personal/work-worktree" || exit 2
mkdir -p "$UNKNOWN/personal-worktree/nested"
run_case "personal repository subdirectory gets personal policy" "$PERSONAL/nested" yes exec hi
run_case "external personal worktree gets personal policy" "$UNKNOWN/personal-worktree" yes exec hi
run_case "external personal worktree subdirectory gets personal policy" "$UNKNOWN/personal-worktree/nested" yes exec hi
run_case "-C external personal worktree gets personal policy" "$WORK" yes -C "$UNKNOWN/personal-worktree" exec hi
run_case "work-owned worktree under personal gets personal policy" "$SBHOME/Git/personal/work-worktree" yes exec hi
SEPARATE_WORK="$SBHOME/Git/personal/separate-work-metadata"
SEPARATE_EXTERNAL="$SBHOME/Git/personal/separate-external-metadata"
git_fixture init -q --separate-git-dir "$SBHOME/Git/work/personal-metadata.git" "$SEPARATE_WORK" || exit 2
git_fixture init -q --separate-git-dir "$SBHOME/external-personal-metadata.git" "$SEPARATE_EXTERNAL" || exit 2
run_case "personal checkout with metadata under work disables Atlassian" "$SEPARATE_WORK" yes exec hi
run_case "personal checkout with external metadata disables Atlassian" "$SEPARATE_EXTERNAL" yes exec hi
run_case "-C personal checkout with work metadata disables Atlassian" "$WORK" yes -C "$SEPARATE_WORK" exec hi

SEPARATE_PRIMARY="$SBHOME/Git/personal/separate-primary"
SEPARATE_METADATA="$TMP/metadata/separate-primary.git"
SEPARATE_LINKED="$TMP/external-separate-linked"
mkdir -p "$(dirname "$SEPARATE_METADATA")"
git_fixture init -q --separate-git-dir "$SEPARATE_METADATA" "$SEPARATE_PRIMARY" || exit 2
git_fixture -C "$SEPARATE_PRIMARY" commit -q --allow-empty -m fixture || exit 2
git_fixture -C "$SEPARATE_PRIMARY" worktree add -q --detach "$SEPARATE_LINKED" || exit 2
run_refusal() {
    label="$1" cwd="$2"; shift 2
    : > "$TMP/record"
    out="$(RECORD="$TMP/record" HOME="$SBHOME" ZDOTDIR="$TMP/zdot" \
        PATH="$TMP/bin:$PATH" CASE_CWD="$cwd" \
        zsh -c 'cd -- "$CASE_CWD" && codex "$@"' zsh "$@" 2>&1)"
    rc=$?
    if [ "$rc" = 2 ] && [ ! -s "$TMP/record" ] && case "$out" in *ambiguous*) true;; *) false;; esac; then
        pass "$label"
    else
        fail "$label (status $rc; output=$out)"
    fi
}
run_refusal "external linked separate metadata refuses inherited work route" \
    "$SEPARATE_LINKED" exec hi
run_refusal "external linked separate metadata resolves effective -C before refusal" \
    "$WORK" -C "$SEPARATE_LINKED" exec hi
CLAUDE_PERSONAL_ONLY=1 run_case "external linked separate metadata accepts personal-only route" \
    "$SEPARATE_LINKED" yes exec hi

# A machine-wide personal decision must not depend on Git availability or probes.
mkdir -p "$TMP/probe-bin"
cat > "$TMP/probe-bin/git" <<'EOF'
#!/bin/sh
: > "$GIT_PROBE_RECORD"
exit 1
EOF
chmod +x "$TMP/probe-bin/git"
CLAUDE_PERSONAL_ONLY=1 GIT_PROBE_RECORD="$TMP/git-probed" PATH="$TMP/probe-bin:$PATH" \
    run_case "personal-only policy applies when Git is unavailable" "$WORK" yes exec hi
if [ ! -e "$TMP/git-probed" ]; then
    pass "personal-only policy skips Git probing"
else
    fail "personal-only policy skips Git probing"
fi

# The wrapper must not consume input or change binary output/status.
printf 'stdin survives\n' > "$TMP/input"
printf 'codex stderr\n' > "$TMP/expected-stderr"
printf '%s\0' -c "$POLICY" exec - > "$TMP/expected"
for personal_only in 0 1; do
    stdio_cwd="$PERSONAL"
    [ "$personal_only" = 0 ] || stdio_cwd="$WORK"
    RECORD="$TMP/record" HOME="$SBHOME" ZDOTDIR="$TMP/zdot" \
        PATH="$TMP/bin:$PATH" CASE_CWD="$stdio_cwd" \
        CLAUDE_PERSONAL_ONLY="$personal_only" TEST_CODEX_STDIO=1 TEST_CODEX_STATUS=7 \
        zsh -c 'cd -- "$CASE_CWD" && codex exec -' \
        < "$TMP/input" > "$TMP/stdout" 2> "$TMP/stderr"
    rc=$?
    if [ "$rc" = 7 ] && cmp -s "$TMP/input" "$TMP/stdout" \
        && cmp -s "$TMP/expected-stderr" "$TMP/stderr" \
        && cmp -s "$TMP/expected" "$TMP/record"; then
        pass "personal-only=$personal_only: policy preserves exit status and stdin/stdout/stderr"
    else
        fail "personal-only=$personal_only: policy preserves exit status and stdin/stdout/stderr"
    fi
done

out="$(HOME="$SBHOME" ZDOTDIR="$TMP/zdot" zsh -c true 2>&1)"
if [ -z "$out" ]; then
    pass ".zshenv stays silent"
else
    fail ".zshenv stays silent ($out)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
