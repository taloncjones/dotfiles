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

echo "== task 4: index"
# seed_repo <repo> <config_dir>: docs, todo, handoff, finding, memory (+ MEMORY.md index).
seed_repo() {
  local r="$1" cfg="$2"
  mkdir -p "$r/docs/specs" "$r/docs/findings" "$r/.claude/handoffs" "$r/.todos/pending"
  printf '# Widget spec\n\nThe widget frobnicates gizmos.\n\n## Decision\n\nWe chose the frobnicator over the gizmo mangler.\n' > "$r/docs/specs/widget.md"
  printf -- '---\ntitle: Fix the mangler\npriority: high\n---\n\n## Problem\n\nMangler leaks memory.\n' > "$r/.todos/pending/2026-01-01-fix-mangler.md"
  printf '# Handoff\n\nNext slice: wire the frobnicator to the widget bus. The decision is pending.\n' > "$r/.claude/handoffs/latest.md"
  printf 'finding: mangler leak reproduced under load\n' > "$r/docs/findings/leak.txt"
  local mem; mem=$(mem_dir "$cfg" "$r")
  mkdir -p "$mem"; printf '# Memory\n\nUser prefers the frobnicator naming.\n' > "$mem/naming.md"
  printf 'index\n' > "$mem/MEMORY.md"
}
db_path() { printf '%s/recall/%s/index.db' "$1" "$(repo_id "$2")"; }
hold_lock() { # hold_lock <db> <seconds>: background writer holding BEGIN IMMEDIATE
  python3 - "$1" "$2" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); c.execute("BEGIN IMMEDIATE"); time.sleep(float(sys.argv[2]))
PY
  LOCK_PID=$!; sleep 0.5
}
test_index_builds_and_reports() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  assert_eq "index exits 0" "$RC" 0
  assert_contains "index summary counts files" "$OUT" "indexed 5 files (+5 ~0 -0)"
  local db; db=$(db_path "$HOME/.claude" "$r")
  assert_file "index file exists" "$db"
  assert_eq "index file mode 600" "$(file_mode "$db")" 600
  assert_eq "index dir mode 700" "$(file_mode "$(dirname "$db")")" 700
  recall "$r" index
  assert_contains "second index is a no-op" "$OUT" "(+0 ~0 -0)"
}
test_index_incremental() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  sleep 1; printf '\n## Addendum\n\nNew paragraph.\n' >> "$r/docs/specs/widget.md"
  unlink "$r/docs/findings/leak.txt"
  printf '# New\n\nfresh doc\n' > "$r/docs/new.md"
  recall "$r" index
  assert_contains "incremental counts +1 ~1 -1" "$OUT" "(+1 ~1 -1)"
  head -c $((1024*1024+1)) /dev/zero | tr '\0' 'x' > "$r/docs/new.md"
  recall "$r" index
  assert_contains "oversized file removed" "$OUT" "(+0 ~0 -1)"
  printf '\xff\xfe not utf8\n' > "$r/docs/bad.md"
  recall "$r" index
  assert_contains "non-utf8 skipped with warning" "$ERR" "skipping docs/bad.md"
  RECALL_EXTRA_GLOBS="docs/specs/*.md" recall "$r" index
  assert_contains "kind change re-indexes the file" "$OUT" "(+0 ~1 -0)"
  local kind; kind=$(python3 -c "import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute(\"SELECT kind FROM files WHERE display='docs/specs/widget.md'\").fetchone()[0])" "$(db_path "$HOME/.claude" "$r")")
  assert_eq "kind change lands in the index" "$kind" extra
  recall "$r" index --full
  assert_contains "full rebuild reindexes all" "$OUT" "(+4 ~0 -0)"
}
test_index_no_sources_and_git_clean() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/empty")
  local before; before=$(cd "$r" && git status --porcelain)
  recall "$r" index
  assert_eq "index with no sources exits 0" "$RC" 0
  assert_contains "index with no sources says so" "$OUT" "indexed 0 files"
  recall "$r" status
  recall "$r" search anything
  local after; after=$(cd "$r" && git status --porcelain)
  assert_eq "index, status and search leave git status unchanged" "$after" "$before"
}
test_index_corrupt_quarantined() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  local db; db=$(db_path "$HOME/.claude" "$r")
  printf 'garbage garbage garbage' > "$db"
  recall "$r" index
  assert_eq "corrupt index rebuild exits 0" "$RC" 0
  assert_contains "corrupt index warned" "$ERR" "corrupt"
  assert_file "corrupt index quarantined" "$db.corrupt"
  assert_contains "corrupt index rebuilt fully" "$OUT" "(+5 ~0 -0)"
}
test_index_schema_mismatch_rebuilds() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  local db; db=$(db_path "$HOME/.claude" "$r")
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE meta SET value='0' WHERE key='schema_version'\"); c.commit()" "$db"
  recall "$r" index
  assert_contains "schema mismatch warns" "$ERR" "schema"
  assert_contains "schema mismatch rebuilds" "$OUT" "(+5 ~0 -0)"
}
test_index_locked_exits_7() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  hold_lock "$(db_path "$HOME/.claude" "$r")" 6
  RECALL_BUSY_TIMEOUT_MS=500 recall "$r" index
  assert_eq "locked index exits 7" "$RC" 7
  wait "$LOCK_PID"
}
test_index_builds_and_reports
test_index_incremental
test_index_no_sources_and_git_clean
test_index_corrupt_quarantined
test_index_schema_mismatch_rebuilds
test_index_locked_exits_7

echo "== task 5: search"
test_search_hits_and_ranking() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search frobnicator
  assert_eq "search hit exits 0" "$RC" 0
  assert_contains "search prints anchor" "$OUT" "docs/specs/widget.md:"
  assert_contains "search prints kind" "$OUT" "[docs]"
  assert_contains "refresh summary on stderr" "$ERR" "indexed 5 files"
  assert_not_contains "refresh summary not on stdout" "$OUT" "indexed"
  recall "$r" search --json decision
  local first; first=$(printf '%s\n' "$OUT" | head -1)
  assert_contains "heading match outranks the body-only match in the handoff" "$first" '"line": 5'
  assert_contains "body-only match is still returned" "$OUT" '.claude/handoffs/latest.md'
  assert_contains "json carries display path" "$first" '"path": "docs/specs/widget.md"'
  assert_contains "heading-only match is highlighted in snippet" "$first" '>>Decision<<'
  recall "$r" search "gizmo mangler"
  assert_eq "quoted multi-word query is split into AND terms" "$RC" 0
  RECALL_EXTRA_GLOBS="docs/specs/*.md" recall "$r" search --json frobnicates
  assert_contains "kind change is visible through search" "$OUT" '"kind": "extra"'
  printf '# Same\n\nzebra text\n' > "$r/docs/tie-b.md"; printf '# Same\n\nzebra text\n' > "$r/docs/tie-a.md"
  recall "$r" search --json zebra
  assert_contains "ties order by display path" "$(printf '%s\n' "$OUT" | head -1)" '"path": "docs/tie-a.md"'
  recall "$r" search mangler --kind todos
  assert_contains "kind filter keeps todos" "$OUT" ".todos/pending/2026-01-01-fix-mangler.md"
  assert_not_contains "kind filter drops findings" "$OUT" "leak.txt"
  recall "$r" search naming
  assert_contains "memory hit shows tilde path" "$OUT" "~/.claude/projects/"
  recall "$r" search zzzznotthere
  assert_eq "no hits exits 1" "$RC" 1
}
test_search_no_sources_exits_2() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/empty")
  recall "$r" search anything
  assert_eq "no sources exits 2" "$RC" 2
  assert_contains "no sources names locations" "$ERR" "docs/"
}
test_search_query_contract() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search 'widget"' '(spec' 'fro*'
  if [ "$RC" = 0 ] || [ "$RC" = 1 ]; then ok "default mode never errors on syntax"; else bad "default mode never errors on syntax" "exit $RC"; fi
  recall "$r" search --raw 'widget OR ('
  assert_eq "raw parse error exits 4" "$RC" 4
  recall "$r" search --raw '"unterminated'
  assert_eq "raw unterminated string exits 4" "$RC" 4
  recall "$r" search --raw 'nosuchcol:widget'
  assert_eq "raw unknown column exits 4" "$RC" 4
  recall "$r" search --raw 'frob* OR mangler'
  assert_eq "raw operators work" "$RC" 0
  recall "$r" search --limit 0 widget
  assert_eq "limit 0 exits 64" "$RC" 64
  recall "$r" search --kind bogus widget
  assert_eq "unknown kind exits 64" "$RC" 64
  recall "$r" search '   '
  assert_eq "blank query exits 64" "$RC" 64
}
test_search_refresh_and_no_refresh() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search --no-refresh widget
  assert_eq "no-refresh without index exits 7" "$RC" 7
  recall "$r" index
  printf '# Later\n\nquux appears now\n' > "$r/docs/later.md"
  recall "$r" search --no-refresh quux
  assert_eq "no-refresh does not see new file" "$RC" 1
  recall "$r" search quux
  assert_eq "search refreshes and finds new file" "$RC" 0
}
test_search_json_pure_stdout() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  printf '# Extra\n\nwidget again\n' > "$r/docs/extra.md"
  recall "$r" search --json widget
  if printf '%s\n' "$OUT" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]'; then
    ok "json stdout is pure JSONL after refresh"; else bad "json stdout is pure JSONL after refresh" "$OUT"; fi
}
test_search_isolation_sentinels() {
  setup_env
  local p; p=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$p" "$HOME/.claude"
  local w; w=$(mk_repo "$HOME/Git/work/r"); seed_repo "$w" "$HOME/.claude-work"
  printf '# P\n\npersonalsentinel\n' > "$(mem_dir "$HOME/.claude" "$p")/p.md"
  printf '# W\n\nworksentinel\n' > "$(mem_dir "$HOME/.claude-work" "$w")/w.md"
  recall "$w" search personalsentinel
  assert_eq "work search never sees personal memory" "$RC" 1
  recall "$p" search worksentinel
  assert_eq "personal search never sees work memory" "$RC" 1
  recall "$w" search worksentinel
  assert_eq "work search sees work memory" "$RC" 0
  assert_no_file "personal recall dir untouched by work" "$HOME/.claude/recall/$(repo_id "$w")"
}
test_search_worktree_sees_main_memory() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  ( cd "$r" && git add -A && git commit -qm init && git worktree add -q "$SANDBOX/wt" -b wt )
  local wt; wt=$(/usr/bin/env realpath "$SANDBOX/wt")
  recall "$wt" search naming
  assert_eq "worktree finds main checkout memory" "$RC" 0
  assert_file "worktree has its own index" "$(db_path "$HOME/.claude" "$wt")"
}
test_search_locked_degrades() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  hold_lock "$(db_path "$HOME/.claude" "$r")" 6
  RECALL_BUSY_TIMEOUT_MS=500 recall "$r" search widget
  assert_eq "locked search still answers" "$RC" 0
  assert_contains "locked search warns" "$ERR" "locked"
  wait "$LOCK_PID"
}
test_search_hits_and_ranking
test_search_no_sources_exits_2
test_search_query_contract
test_search_refresh_and_no_refresh
test_search_json_pure_stdout
test_search_isolation_sentinels
test_search_worktree_sees_main_memory
test_search_locked_degrades

echo "== task 6: status"
test_status_reports_counts() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  recall "$r" status
  assert_eq "status exits 0" "$RC" 0
  assert_contains "status shows schema version" "$OUT" "schema: 1"
  assert_contains "status shows script version" "$OUT" "version: 1"
  assert_contains "status shows docs count" "$OUT" "docs: 1 files"
  assert_contains "status shows memory count" "$OUT" "memory: 1 files"
  assert_contains "status shows last index" "$OUT" "last index: 20"
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE meta SET value='0' WHERE key='schema_version'\"); c.commit()" "$(db_path "$HOME/.claude" "$r")"
  recall "$r" status
  assert_contains "status after schema mismatch rebuilds first" "$OUT" "docs: 1 files"
  assert_contains "status after schema mismatch warns" "$ERR" "schema"
}
test_status_all_outside_git_and_corrupt() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  mkdir -p "$HOME/.claude/recall/bogus-000000000000"; printf 'junk' > "$HOME/.claude/recall/bogus-000000000000/index.db"
  mkdir -p "$SANDBOX/plain"
  recall "$SANDBOX/plain" status --all
  assert_eq "status --all works outside git" "$RC" 0
  assert_contains "status --all lists live index" "$OUT" "$r"
  assert_contains "status --all flags corrupt" "$OUT" "corrupt"
  assert_file "status --all never quarantines" "$HOME/.claude/recall/bogus-000000000000/index.db"
  assert_no_file "status --all never rebuilds" "$HOME/.claude/recall/bogus-000000000000/index.db.corrupt"
}
test_status_reports_counts
test_status_all_outside_git_and_corrupt

echo "== task 7: eval"
test_eval_metrics_and_grouping() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  cat > "$r/docs/recall-eval.jsonl" <<'EOF'
{"q": "frobnicator decision", "expect": ["docs/specs/widget.md#Decision"], "note": "hit", "added": "2026-01-02"}
{"q": "why does the mangler leak", "expect": ["docs/nonexistent.md"], "note": "missing-source", "added": "2026-01-02"}
{"q": "widget frobnicates gizmos", "expect": ["docs/specs/widget.md"], "note": "missing-source", "added": "2026-01-02"}
EOF
  recall "$r" eval
  assert_eq "eval exits 0" "$RC" 0
  assert_contains "eval header has version" "$OUT" "version 1"
  assert_contains "eval recall@5 is 0.33 (missing-source always misses)" "$OUT" "recall@5 0.33"
  assert_contains "eval MRR line" "$OUT" "MRR "
  assert_contains "eval groups miss by note" "$OUT" "misses [missing-source]"
}
test_eval_rejects_invalid() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  printf '{"q": "a", "expect": ["docs/nope.md"], "note": "hit", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "unindexed expected path exits 8" "$RC" 8
  printf 'not json\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "malformed line exits 8" "$RC" 8
  printf '{"q": "a", "expect": ["docs/specs/widget.md"], "note": "weird", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "unknown note exits 8" "$RC" 8
  assert_not_contains "invalid run prints no metrics" "$OUT" "recall@5"
  printf '{"q": "a", "expect": null, "note": "hit", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "null expect exits 8 without traceback" "$RC" 8
  assert_not_contains "null expect gives no traceback" "$ERR" "Traceback"
  printf '{"q": "a", "expect": ["docs/specs/widget.md"], "note": "hit", "added": "yesterday"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "bad added date exits 8" "$RC" 8
}
test_eval_add() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" eval add "frobnicator naming" --expect "docs/specs/widget.md" --note paraphrase
  assert_eq "eval add exits 0" "$RC" 0
  assert_contains "eval add wrote the query" "$(cat "$r/docs/recall-eval.jsonl")" '"q": "frobnicator naming"'
  recall "$r" eval add "frobnicator naming" --expect "docs/specs/widget.md"
  assert_eq "eval add refuses duplicate q" "$RC" 8
  assert_eq "duplicate not appended" "$(wc -l < "$r/docs/recall-eval.jsonl" | tr -d ' ')" 1
  recall "$r" eval add "gone" --expect "docs/nope.md"
  assert_eq "eval add refuses unindexed path" "$RC" 8
  recall "$r" eval add "gone" --expect "docs/nope.md" --note missing-source
  assert_eq "eval add allows missing-source" "$RC" 0
}
test_eval_metrics_and_grouping
test_eval_rejects_invalid
test_eval_add

echo "== task 8: kinds through the cli"
test_cli_kinds_extra_and_findings() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  mkdir -p "$r/notes"; printf 'extra glob content xyzzy\n' > "$r/notes/n.txt"
  RECALL_EXTRA_GLOBS="notes/*.txt" recall "$r" search --json xyzzy
  assert_contains "extra glob indexed as extra" "$OUT" '"kind": "extra"'
  recall "$r" search --json reproduced
  assert_contains "findings txt indexed as findings" "$OUT" '"kind": "findings"'
  recall "$r" search --json "widget bus"
  assert_contains "handoffs indexed" "$OUT" '"kind": "handoffs"'
  RECALL_EXTRA_GLOBS="../outside/*.md" recall "$r" search widget
  assert_contains "escaping extra glob rejected with warning" "$ERR" "rejected"
}
test_cli_kinds_extra_and_findings

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
