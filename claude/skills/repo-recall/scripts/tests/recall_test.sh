#!/usr/bin/env bash
# Test suite for recall.py. Isolated via HOME / CLAUDE_* env pointed at mktemp dirs.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECALL="$HERE/../recall.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] contains [$3]";; *) ok "$1";; esac; }
assert_file()    { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }
assert_no_file() { if [ -e "$2" ]; then bad "$1" "unexpected $2"; else ok "$1"; fi; }

# Fresh isolated environment per test: HOME, config dirs, work tree.
setup_env() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/Git/work" "$HOME/Git/personal"
  export CLAUDE_WORK_TREE="$HOME/Git/work"
  export CLAUDE_WORK_CONFIG_DIR="$HOME/.claude-work"
  unset CLAUDE_CONFIG_DIR RECALL_EXTRA_GLOBS RECALL_FORCE_NO_FTS5
}
# mk_repo <dir>: git init a repo at dir; echoes resolved path.
mk_repo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t )
  /usr/bin/env realpath "$1"
}
# recall <repo> args...: run recall.py from inside repo, capture stdout in OUT,
# stderr in ERR, exit code in RC.
recall() {
  local repo="$1"; shift
  OUT=$(cd "$repo" && python3 "$RECALL" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}
# repo_id <repo> / mem_dir <config_dir> <repo>: paths derived by the script itself.
repo_id() { python3 "$RECALL" --repo-id "$1"; }
mem_dir() { printf '%s/projects/%s/memory' "$1" "$(python3 "$RECALL" --slug "$2")"; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

echo "== unit tests"
python3 "$HERE/test_recall_units.py" -q 2>&1 | tail -3
[ "${PIPESTATUS[0]}" = 0 ] && ok "unit tests" || bad "unit tests" "see above"

echo "== task 1: probe, routing, git detection"
test_outside_git_exits_3() {
  setup_env; mkdir -p "$SANDBOX/plain"
  recall "$SANDBOX/plain" search foo
  assert_eq "search outside git exits 3" "$RC" 3
  recall "$SANDBOX/plain" status
  assert_eq "status outside git exits 3" "$RC" 3
}
test_no_fts5_exits_5() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  RECALL_FORCE_NO_FTS5=1 recall "$r" search foo
  assert_eq "no fts5 exits 5" "$RC" 5
  assert_contains "no fts5 names the fix" "$ERR" "FTS5"
}
test_routing_personal() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  recall "$r" status
  assert_eq "status exits 0" "$RC" 0
  assert_contains "status prints personal config dir" "$OUT" "$HOME/.claude"
  assert_no_file "personal never creates work dir" "$HOME/.claude-work"
}
test_routing_work_creates_dir() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/work/r")
  recall "$r" status
  assert_contains "work tree routes to work config dir" "$OUT" "$HOME/.claude-work"
  assert_file "work config dir created" "$HOME/.claude-work/recall"
  assert_eq "work config dir mode 700" "$(file_mode "$HOME/.claude-work")" 700
  assert_eq "recall dir mode 700" "$(file_mode "$HOME/.claude-work/recall")" 700
  assert_no_file "work never touches personal recall dir" "$HOME/.claude/recall"
}
test_routing_override() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/work/r")
  CLAUDE_CONFIG_DIR="$SANDBOX/custom" recall "$r" status
  assert_contains "CLAUDE_CONFIG_DIR overrides" "$OUT" "$SANDBOX/custom"
}
test_index_inside_repo_exits_6() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  CLAUDE_CONFIG_DIR="$r/.claude" recall "$r" status
  assert_eq "index inside repo exits 6" "$RC" 6
}
test_usage_and_help() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  recall "$r" --help
  assert_eq "help exits 0" "$RC" 0
  recall "$r" bogus
  assert_eq "unknown command exits 64" "$RC" 64
  assert_eq "usage error is one line" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 1
  local direct; direct=$("$RECALL" --slug /tmp/x 2>/dev/null); local drc=$?
  assert_eq "script is directly executable" "$drc" 0
  assert_eq "direct invocation works" "$direct" "-tmp-x"
}
test_outside_git_exits_3
test_no_fts5_exits_5
test_routing_personal
test_routing_work_creates_dir
test_routing_override
test_index_inside_repo_exits_6
test_usage_and_help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
