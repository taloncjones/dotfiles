#!/bin/sh
# herdr-zed-attach.test.sh - drive bin/herdr-zed-attach through a stub herdr
# and a stub git on a private PATH. No herdr server, no real HOME reads, no
# network. python3 comes from /usr/bin:/bin.
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

# expect_rc <rc> <cmd...>: true when the command exits with exactly <rc>.
expect_rc() {
    want="$1"
    shift
    rc=0
    "$@" || rc=$?
    [ "$rc" -eq "$want" ]
}

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO/bin/herdr-zed-attach"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# mktemp on macOS answers through a symlink (/var -> /private/var). REAL is
# the canonical spelling, so fixtures can present either form.
REAL="$(cd "$WORK" && pwd -P)"

mkdir -p "$WORK/bin" "$WORK/nobin" "$WORK/main/sub" "$WORK/wt-a/sub" "$WORK/elsewhere"
ln -s "$WORK/main" "$WORK/link-main"
ARGV="$WORK/argv"

# Stub herdr: records argv, answers `agent list` from STUB_LIST_JSON with
# STUB_LIST_RC, and accepts `agent attach` without attaching.
cat > "$WORK/bin/herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB_ARGV_OUT"
case "$1 $2" in
"agent list")
    printf '%s' "$STUB_LIST_JSON"
    exit "${STUB_LIST_RC:-0}"
    ;;
"agent attach")
    exit 0
    ;;
esac
exit 99
EOF
chmod +x "$WORK/bin/herdr"

# Stub git: prints STUB_TOPLEVEL for rev-parse --show-toplevel, or exits 128
# like git does outside a repository when STUB_TOPLEVEL is empty.
cat > "$WORK/bin/git" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "rev-parse --show-toplevel" ] && [ -n "${STUB_TOPLEVEL:-}" ]; then
    printf '%s\n' "$STUB_TOPLEVEL"
    exit 0
fi
exit 128
EOF
chmod +x "$WORK/bin/git"
cp "$WORK/bin/git" "$WORK/nobin/git"

# agent <pane> <name-or-empty> <cwd> <foreground_cwd> <status> <title>: one
# agent object in the herdr 0.9.1 shape; name is omitted when empty, as it
# is for the standing director pane.
agent() {
    if [ -n "$2" ]; then
        printf '{"pane_id":"%s","name":"%s","agent":"claude","cwd":"%s","foreground_cwd":"%s","agent_status":"%s","terminal_title_stripped":"%s","workspace_id":"w1"}' "$1" "$2" "$3" "$4" "$5" "$6"
    else
        printf '{"pane_id":"%s","agent":"claude","cwd":"%s","foreground_cwd":"%s","agent_status":"%s","terminal_title_stripped":"%s","workspace_id":"w1"}' "$1" "$3" "$4" "$5" "$6"
    fi
}

# listing [agent-json...]: the full `agent list` stdout document.
listing() {
    body=""
    for a in "$@"; do
        body="$body${body:+,}$a"
    done
    printf '{"id":"cli:agent:list","result":{"agents":[%s],"type":"agent_list"}}' "$body"
}

DIRECTOR="$(agent w1:p1 "" "$WORK/main" "$WORK/main" working director)"
WORKER_A="$(agent w2:p1 w-a "$WORK/wt-a" "$WORK/wt-a" working "Worker A")"
WORKER_B="$(agent w3:p1 w-b "$WORK/main" "$WORK/main/sub" idle "Worker B")"
ROAMER="$(agent w4:p1 roamer "$WORK/elsewhere" "$WORK/wt-a/sub" working Roamer)"

# run_attach <cwd> <toplevel> <bindir> <out-prefix> [args...]: runs the script
# from <cwd> on the stub PATH; stdout to <prefix>.out, stderr to <prefix>.err.
run_attach() {
    cwd="$1"
    top="$2"
    bindir="$3"
    prefix="$4"
    shift 4
    : > "$ARGV"
    (cd "$cwd" && STUB_ARGV_OUT="$ARGV" STUB_TOPLEVEL="$top" \
        PATH="$bindir:/usr/bin:/bin" bash "$SCRIPT" "$@" > "$prefix.out" 2> "$prefix.err")
}

set_listing() {
    STUB_LIST_JSON="$1"
    export STUB_LIST_JSON
}

# 1. single match by cwd equal to the root
set_listing "$(listing "$DIRECTOR" "$WORKER_A")"
assert "attach: single match by cwd exits 0" run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c1"
assert "attach: single match execs agent attach with the pane id" grep -qx 'agent attach w1:p1' "$ARGV"

# 2. single match by foreground_cwd under the root while cwd is elsewhere
set_listing "$(listing "$DIRECTOR" "$ROAMER")"
assert "attach: foreground_cwd under the root matches" run_attach "$WORK/wt-a" "$WORK/wt-a" "$WORK/bin" "$WORK/c2"
assert "attach: foreground_cwd match attaches that pane" grep -qx 'agent attach w4:p1' "$ARGV"

# 3. sibling worktree isolation
set_listing "$(listing "$DIRECTOR" "$WORKER_A")"
assert "attach: worktree root exits 0 with its own worker" run_attach "$WORK/wt-a" "$WORK/wt-a" "$WORK/bin" "$WORK/c3"
assert "attach: worktree root attaches the worker, not the director" grep -qx 'agent attach w2:p1' "$ARGV"

# 4. $PWD in a subdirectory resolves through the git toplevel
assert "attach: subdirectory cwd resolves through the toplevel" run_attach "$WORK/main/sub" "$WORK/main" "$WORK/bin" "$WORK/c4"
assert "attach: subdirectory cwd attaches the director" grep -qx 'agent attach w1:p1' "$ARGV"

# 5. root reached through a symlink matches an agent listed canonically
CANON_DIRECTOR="$(agent w1:p1 "" "$REAL/main" "$REAL/main" working director)"
set_listing "$(listing "$CANON_DIRECTOR" "$WORKER_A")"
assert "attach: symlinked root matches the canonical path" run_attach "$WORK/link-main" "$WORK/link-main" "$WORK/bin" "$WORK/c5"
assert "attach: symlinked root attaches the director" grep -qx 'agent attach w1:p1' "$ARGV"

# 6. zero matches: exit 1, root named, every live agent listed, no attach
set_listing "$(listing "$DIRECTOR" "$WORKER_A")"
assert "attach: no match exits 1" expect_rc 1 run_attach "$WORK/elsewhere" "$WORK/elsewhere" "$WORK/bin" "$WORK/c6"
assert "attach: no match names the canonical root" grep -qF "no herdr agent runs under $REAL/elsewhere" "$WORK/c6.err"
assert "attach: no match lists every live agent" sh -c "grep -q '^w1:p1' '$WORK/c6.err' && grep -q '^w2:p1' '$WORK/c6.err'"
assert "attach: no match never attaches" sh -c "! grep -q 'agent attach' '$ARGV'"

# 7. zero live agents
set_listing "$(listing)"
assert "attach: no live agents exits 1" expect_rc 1 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c7"
assert "attach: no live agents prints the placeholder line" grep -qx '(no live herdr agents)' "$WORK/c7.err"

# 8. two matches: exit 2, only the matching panes listed, no attach
set_listing "$(listing "$DIRECTOR" "$WORKER_B" "$WORKER_A")"
assert "attach: two matches exit 2" expect_rc 2 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c8"
assert "attach: two matches name the count and root" grep -qF "2 herdr agents run under $REAL/main; pass one as the target:" "$WORK/c8.err"
assert "attach: two matches list both matching panes" sh -c "grep -q '^w1:p1' '$WORK/c8.err' && grep -q '^w3:p1' '$WORK/c8.err'"
assert "attach: two matches omit the non-matching pane" sh -c "! grep -q '^w2:p1' '$WORK/c8.err'"
assert "attach: two matches never attach" sh -c "! grep -q 'agent attach' '$ARGV'"

# 9. explicit target skips the listing
set_listing "$(listing "$DIRECTOR")"
assert "attach: explicit target exits 0" run_attach "$WORK/elsewhere" "" "$WORK/bin" "$WORK/c9" w9:p9
assert "attach: explicit target execs agent attach with it" grep -qx 'agent attach w9:p9' "$ARGV"
assert "attach: explicit target never lists" sh -c "! grep -q 'agent list' '$ARGV'"

# 10. listing labels: director falls back to its title, worker shows its name
assert "attach: listing labels a nameless director by title" grep -qF "$(printf 'w1:p1\tdirector\tworking\t')" "$WORK/c6.err"
assert "attach: listing labels a worker by name" grep -qF "$(printf 'w2:p1\tw-a\tworking\t')" "$WORK/c6.err"

# 11. herdr missing from PATH
assert "attach: herdr missing exits 3" expect_rc 3 run_attach "$WORK/main" "$WORK/main" "$WORK/nobin" "$WORK/c11"
assert "attach: herdr missing says so" grep -qF 'herdr is not on PATH' "$WORK/c11.err"

# 12. agent list exits non-zero
set_listing "$(listing "$DIRECTOR")"
STUB_LIST_RC=7
export STUB_LIST_RC
assert "attach: agent list failure exits 3" expect_rc 3 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c12"
assert "attach: agent list failure says so" grep -qF 'herdr agent list failed' "$WORK/c12.err"
unset STUB_LIST_RC

# 13. agent list prints something unreadable
set_listing 'not json'
assert "attach: non-JSON listing exits 3" expect_rc 3 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c13"
assert "attach: non-JSON listing says so" grep -qF 'herdr agent list failed' "$WORK/c13.err"
set_listing '{"id":"cli:agent:list","result":{"type":"agent_list"}}'
assert "attach: listing without an agents list exits 3" expect_rc 3 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c13b"

# 14. unknown option
set_listing "$(listing "$DIRECTOR")"
assert "attach: unknown option exits 4" expect_rc 4 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c14" --bogus
assert "attach: unknown option prints usage on stderr" grep -q '^usage:' "$WORK/c14.err"

# 15. two positional arguments
assert "attach: two targets exit 4" expect_rc 4 run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c15" w1:p1 w2:p1
assert "attach: two targets never attach" sh -c "! grep -q 'agent attach' '$ARGV'"

# 16. --help
assert "attach: --help exits 0" run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c16" --help
assert "attach: --help prints usage on stdout" grep -q '^usage:' "$WORK/c16.out"
assert "attach: --help never calls herdr" sh -c "! test -s '$ARGV'"

# 17. outside any repository the root is $PWD
set_listing "$(listing "$DIRECTOR" "$WORKER_A")"
assert "attach: outside a repository falls back to PWD" run_attach "$WORK/wt-a" "" "$WORK/bin" "$WORK/c17"
assert "attach: PWD fallback attaches the worker" grep -qx 'agent attach w2:p1' "$ARGV"

# 18. duplicate pane ids collapse to one match
set_listing "$(listing "$DIRECTOR" "$DIRECTOR")"
assert "attach: duplicate pane ids are one match" run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c18"
assert "attach: duplicate pane ids attach once" grep -qx 'agent attach w1:p1' "$ARGV"

# 19. --help anywhere wins over an earlier argument error
assert "attach: --help after a bad option exits 0" run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c19" --bogus --help
assert "attach: --help after a bad option prints usage on stdout" grep -q '^usage:' "$WORK/c19.out"
assert "attach: --help after two targets exits 0" run_attach "$WORK/main" "$WORK/main" "$WORK/bin" "$WORK/c19b" w1:p1 w2:p1 --help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
