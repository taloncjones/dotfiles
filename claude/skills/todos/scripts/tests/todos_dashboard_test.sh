#!/usr/bin/env bash
# Test suite for `todos.sh dashboard` (todos_dashboard.py). Deterministic via
# TODOS_STATE_ROOT / TODOS_DASHBOARD_DIR / TODOS_DASHBOARD_NOW / TODOS_GH;
# never opens a browser or touches the network.
#
# Fixture safety (standing rule, see the plan's review notes): every helper
# that mutates, removes, or cds into a fixture first passes the path through
# guard_fixture, which refuses an empty value, a non-directory, anything
# outside the temp root, and anything inside the checkout that holds this
# suite. A bare `cd ""` succeeds in place, so an empty fixture variable once
# ran a git mutation against the real repo; the guard makes that exit 2.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TODOS="$HERE/../todos.sh"
CORE="$HERE/../../../../hooks/herdr_orch_core.py"

# A developer's own overrides must not leak into the fixtures.
unset TODOS_DASHBOARD_DIR TODOS_STATE_ROOT TODOS_DASHBOARD_TODOS_SH TODOS_DASHBOARD_OPENER \
      TODOS_OFFLINE TODOS_GH TODOS_BASE_REF XDG_STATE_HOME
# Fixture commits must not run the user's hooks, templates, or signing.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TEMPLATE_DIR=""

canon_helper() { /usr/bin/env realpath "$1" 2>/dev/null || printf '%s' "$1"; }

FIXTURE_ROOT=$(canon_helper "${TMPDIR:-/tmp}")
SUITE_REPO=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$HERE")
SUITE_REPO=$(canon_helper "$SUITE_REPO")

refuse() { printf 'todos_dashboard_test: %s\n' "$1" >&2; exit 2; }

# guard_fixture <path>: non-empty, an existing directory, under the temp root
# (or /tmp), and never inside the checkout that holds this suite.
guard_fixture() {
  local p="${1:-}" real
  [ -n "$p" ] || refuse "empty fixture path"
  [ -d "$p" ] || refuse "fixture is not a directory: $p"
  real=$(canon_helper "$p")
  case "$real" in
    "$FIXTURE_ROOT"/*|/tmp/*|/private/tmp/*) ;;
    *) refuse "fixture outside the temp root: $p" ;;
  esac
  case "$real" in
    "$SUITE_REPO"|"$SUITE_REPO"/*) refuse "fixture inside the suite checkout: $p" ;;
  esac
}
# rm_fixture <dir>...: guarded recursive removal of fixture directories.
rm_fixture() { local p; for p in "$@"; do guard_fixture "$p"; rm -rf "$p"; done; }
# mk_dir: a guarded fresh temp directory (state roots, output dirs).
mk_dir() { local d; d=$(mktemp -d) || refuse "mktemp failed"; d=$(canon_helper "$d"); guard_fixture "$d"; printf '%s' "$d"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing [$3]";; esac; }
assert_missing()  { case "$2" in *"$3"*) bad "$1" "found [$3]";; *) ok "$1";; esac; }
assert_file_has() { grep -qF -- "$3" "$2" && ok "$1" || bad "$1" "$2 missing [$3]"; }
assert_file_lacks() { grep -qF -- "$3" "$2" && bad "$1" "$2 has [$3]" || ok "$1"; }

# Throwaway repo: one commit, origin/main via update-ref (no network), an
# origin remote URL (never fetched), .todos/ excluded like `init` does. Every
# git call names the fixture with -C; nothing here cds anywhere.
mk_repo_base() {
  local d; d=$(mk_dir) || exit 2
  { git -C "$d" init -q \
    && git -C "$d" config user.email t@t && git -C "$d" config user.name t \
    && git -C "$d" config commit.gpgsign false && git -C "$d" config core.hooksPath /dev/null \
    && git -C "$d" commit -q --allow-empty -m base \
    && git -C "$d" update-ref refs/remotes/origin/main HEAD \
    && mkdir -p "$d/.git/info" && printf '.todos/\n' >>"$d/.git/info/exclude"; } >/dev/null 2>&1 \
    || refuse "cannot build a fixture repo in $d"
  printf '%s' "$d"
}
mk_repo() {
  local d; d=$(mk_repo_base) || exit 2
  git -C "$d" remote add origin git@github.com:Org/Repo.git >/dev/null 2>&1 \
    || refuse "cannot add the fixture remote in $d"
  printf '%s' "$d"
}
# Same fixture without any remote: the no-remote case is a fresh repo, never a
# mutation of an existing one.
mk_repo_no_remote() { mk_repo_base; }

mk_todo() { # mk_todo <repo> <pending|completed> <name>  (body on stdin)
  guard_fixture "$1"
  mkdir -p "$1/.todos/$2"; cat >"$1/.todos/$2/$3.md"
}
core_slug() { # core_slug <remote-url> -> slug per herdr_orch_core.repo_slug
  python3 -c '
import importlib.util, sys
s = importlib.util.spec_from_file_location("c", sys.argv[1])
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.repo_slug(sys.argv[2]))' "$CORE" "$1"
}
# Fake gh: pr view 7 -> OPEN, else exit 1; appends every call to <path>.calls.
mk_gh_stub() {
  guard_fixture "$(dirname "$1")"
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1.calls"
case "\$1 \$2 \$3" in "pr view 7") echo OPEN ;; *) exit 1 ;; esac
EOF
  chmod +x "$1"
}

# The spec's fixture set (D7). mk_board <repo> <state_root>
mk_board() {
  local repo="$1" sr="$2" slug tasks
  guard_fixture "$repo"; guard_fixture "$sr"
  slug=$(core_slug git@github.com:Org/Repo.git); tasks="$sr/$slug/tasks"; mkdir -p "$tasks"
  mk_todo "$repo" pending 2026-05-01-plain <<'EOF'
---
created: 2026-05-01
title: Plain todo
area: todos
priority: med
files:
---

## Problem

A plain problem line. See [PR](https://github.com/Org/Repo/pull/12). Notes: https://claude.ai/code/artifacts/abc.

## Solution
EOF
  mk_todo "$repo" pending 2026-05-02-blocked <<'EOF'
---
created: 2026-05-02
title: Blocked todo
priority: high
depends_on:
  - todo:2026-05-01-plain
  - pr:7
files:
---

## Problem

Blocked.
EOF
  mk_todo "$repo" completed 2026-05-03-merged <<'EOF'
---
created: 2026-05-03
title: Merged todo
---
EOF
  mk_todo "$repo" pending 2026-05-04-in-flight <<'EOF'
---
created: 2026-05-04
title: In flight
---
EOF
  mk_todo "$repo" pending 2026-05-05-bad-record <<'EOF'
---
created: 2026-05-05
title: <script>alert(1)</script>
---
EOF
  mkdir -p "$repo/.todos/research/td-x"
  cat >"$repo/.todos/research/2026-05-06-notes.md" <<'EOF'
---
created: 2026-05-06
title: Field notes
kind: field-notes
task: td-2026-05-01-plain
artifact: https://claude.ai/code/artifacts/x
---

Summary line of the notes.
EOF
  cat >"$repo/.todos/research/td-x/review-findings.md" <<'EOF'
---
created: 2026-05-02
title: Review findings
kind: review-findings
artifact: javascript:alert(1)
---

Findings body.
EOF
  printf '{"v":1,"status":"merged","review_head_sha":"abc","workers":[{"phase":"review","role":"review","model":"opus","agent":"rev-a"}]}' >"$tasks/td-2026-05-03-merged.json"
  printf '{"outcome":"approved","blocking_count":0,"reviewed_head_sha":"abc"}' >"$tasks/td-2026-05-03-merged.review.json"
  printf '{"status":"in-progress","workers":[{"phase":"implement","role":"impl","model":"sonnet","agent":"impl-a"}]}' >"$tasks/td-2026-05-04-in-flight.json"
  printf '{"outcome":"completed","phase":"plan","agent":"plan-a"}' >"$tasks/td-2026-05-04-in-flight.done.json"
  printf '{not json' >"$tasks/td-2026-05-05-bad-record.json"
}

# render <repo> <state_root> [args...] -> stdout of the command. Because a
# caller captures it with $(...), exit code and stderr travel through files:
# read them with `rc` and `err` after the capture. The cd happens only after
# the guard, inside a subshell, and fails the subshell rather than falling
# through to the caller's directory.
RCF=$(mktemp); ERRF=$(mktemp)
render() {
  local repo="$1" sr="$2"; shift 2
  guard_fixture "$repo"; guard_fixture "$sr"
  ( cd "$repo" || exit 2; TODOS_STATE_ROOT="$sr" TODOS_DASHBOARD_NOW="2026-05-07 09:00" \
    TODOS_TODAY=2026-05-07 bash "$TODOS" dashboard "$@" 2>"$ERRF" )
  printf '%s' "$?" >"$RCF"
}
rc()  { cat "$RCF"; }
err() { cat "$ERRF"; }

# --- cases ---

test_guard() {
  local out
  out=$(guard_fixture "" 2>&1); assert_eq "guard: empty path exits 2" "$?" "2"
  out=$(guard_fixture "$SUITE_REPO" 2>&1); assert_eq "guard: suite checkout refused" "$?" "2"
  out=$(guard_fixture "$HERE/no-such-dir" 2>&1); assert_eq "guard: missing dir refused" "$?" "2"
  local d; d=$(mk_dir) || exit 2
  out=$(guard_fixture "$d" 2>&1); assert_eq "guard: temp dir accepted" "$?" "0"
  rm_fixture "$d"
  ok "guard: fixture paths"
}
test_guard

test_render_fixture() {
  local repo sr f out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  out=$(render "$repo" "$sr" --out "$f")
  assert_eq "render: exit 0" "$(rc)" "0"
  assert_eq "render: prints the path" "$out" "$f"
  assert_file_has "render: blocked row" "$f" 'data-todo="2026-05-02-blocked" data-state="blocked"'
  assert_file_has "render: blocked lists open todo" "$f" 'todo:2026-05-01-plain (open)'
  assert_file_has "render: blocked lists unknown pr" "$f" 'pr:7 (unknown)'
  assert_file_has "render: plain row open" "$f" 'data-todo="2026-05-01-plain" data-state="open"'
  assert_file_has "render: PR link label" "$f" '>PR #12<'
  assert_file_has "render: artifact link label" "$f" '>artifact<'
  assert_file_has "render: merged completed row" "$f" 'data-todo="2026-05-03-merged" data-task-status="merged"'
  assert_file_has "render: review verdict" "$f" 'review approved (0 blocking)</div>'
  assert_file_has "render: in-flight row" "$f" 'data-todo="2026-05-04-in-flight" data-state="open" data-task-status="in-progress"'
  assert_file_has "render: in-flight phase" "$f" 'implement impl sonnet'
  assert_file_has "render: stale done record" "$f" 'done completed plan (stale)'
  assert_file_has "render: open count" "$f" 'data-count="open">4<'
  assert_file_has "render: blocked count" "$f" 'data-count="blocked">1<'
  assert_file_has "render: in-flight count" "$f" 'data-count="in-flight">1<'
  assert_file_has "render: bad record unreadable" "$f" 'data-todo="2026-05-05-bad-record" data-state="open" data-task-status="unreadable"'
  assert_file_has "render: title escaped" "$f" '&lt;script&gt;alert(1)&lt;/script&gt;'
  assert_file_lacks "render: no raw script tag" "$f" '<script'
  assert_file_has "render: stamp" "$f" 'generated 2026-05-07 09:00'
  if grep -qiE '<link|<iframe|@import|url\(|<script| on[a-z]+="' "$f"; then bad "render: inert page" "script, link, iframe, import, url(), or on*= handler"; else ok "render: inert page"; fi
  ok "render: fixture board"
  rm_fixture "$repo" "$sr"
}
test_render_fixture

test_research_index() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_has "research: notes entry" "$f" 'data-research="2026-05-06-notes.md"'
  assert_file_has "research: findings entry" "$f" 'data-research="td-x/review-findings.md"'
  assert_file_has "research: kind chip" "$f" '>field-notes<'
  assert_file_has "research: artifact href" "$f" 'href="https://claude.ai/code/artifacts/x"'
  assert_file_has "research: task anchor" "$f" 'href="#todo-2026-05-01-plain"'
  assert_file_has "research: unsafe artifact as text" "$f" 'artifact: javascript:alert(1)'
  assert_file_lacks "research: no javascript href" "$f" 'href="javascript:'
  local first; first=$(grep -o 'data-research="[^"]*"' "$f" | head -1)
  assert_eq "research: newest first" "$first" 'data-research="2026-05-06-notes.md"'
  ok "research: index"
  rm_fixture "$repo" "$sr"
}
test_research_index

test_default_path_slug() {
  local repo bare sr out slug
  repo=$(mk_repo) || exit 2; bare=$(mk_repo_no_remote) || exit 2; sr=$(mk_dir) || exit 2
  slug=$(core_slug git@github.com:Org/Repo.git)
  out=$(TODOS_DASHBOARD_DIR="$repo/dash" render "$repo" "$sr")
  assert_eq "slug: default path matches core repo_slug" "$out" "$repo/dash/$slug.html"
  [ -f "$repo/dash/$slug.html" ] && ok "slug: file written" || bad "slug: file written" "missing"
  assert_eq "slug: no-remote fixture really has no remote" "$(git -C "$bare" remote)" ""
  out=$(TODOS_DASHBOARD_DIR="$bare/dash" render "$bare" "$sr")
  case "$(basename "$out")" in local-*.html) ok "slug: no remote gives local-";; *) bad "slug: no remote gives local-" "$out";; esac
  ok "slug: default path and repo slug"
  rm_fixture "$repo" "$bare" "$sr"
}
test_default_path_slug

test_read_only() {
  local repo sr before after
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"
  before=$(cd "$sr" && find . -type f | sort | xargs shasum)
  render "$repo" "$sr" --out "$repo/out/board.html" >/dev/null
  after=$(cd "$sr" && find . -type f | sort | xargs shasum)
  assert_eq "read-only: state root untouched" "$after" "$before"
  [ -e "$repo/.todos/TODO.md" ] && bad "read-only: no TODO.md" "created" || ok "read-only: no TODO.md"
  ok "read-only: state root and .todos untouched"
  rm_fixture "$repo" "$sr"
}
test_read_only

test_empty_board() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "empty: exit 0" "$(rc)" "0"
  assert_file_has "empty: open" "$f" 'No open todos.'
  assert_file_has "empty: completed" "$f" 'Nothing completed yet.'
  assert_file_has "empty: research" "$f" 'No research reports.'
  ok "empty: board without .todos"
  rm_fixture "$repo" "$sr"
}
test_empty_board

test_flags() {
  local repo sr f out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  mk_todo "$repo" completed 2026-05-09-newer <<'EOF'
---
created: 2026-05-09
title: Newer completed
---
EOF
  render "$repo" "$sr" --out "$f" --completed 0 >/dev/null
  assert_file_lacks "flags: --completed 0 hides section" "$f" '<h2>Completed</h2>'
  render "$repo" "$sr" --out "$f" --completed 1 >/dev/null
  assert_eq "flags: --completed 1 shows one row" "$(grep -o 'data-todo="2026-05-0[39]-[a-z-]*"' "$f" | wc -l | tr -d ' ')" "1"
  assert_file_has "flags: --completed 1 keeps newest" "$f" 'data-todo="2026-05-09-newer"'
  assert_file_lacks "flags: --completed 1 drops older" "$f" 'data-todo="2026-05-03-merged"'
  out=$(render "$repo" "$sr" --out "$f" --completed -1)
  assert_eq "flags: negative completed exits 1" "$(rc)" "1"
  assert_eq "flags: negative completed prints nothing" "$out" ""
  assert_contains "flags: negative completed message" "$(err)" "todos: --completed"
  out=$(render "$repo" "$sr" --out "$f" --bogus)
  assert_eq "flags: unknown flag exits 1" "$(rc)" "1"
  assert_eq "flags: unknown flag prints nothing" "$out" ""
  assert_contains "flags: unknown flag message" "$(err)" "todos: "
  ok "flags: completed and usage errors"
  rm_fixture "$repo" "$sr"
}
test_flags

test_offline_precedence() {
  local repo sr gh
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; gh="$repo/gh"; mk_gh_stub "$gh"
  TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/a.html" >/dev/null
  [ -e "$gh.calls" ] && bad "offline: default makes no gh call" "$(cat "$gh.calls")" || ok "offline: default makes no gh call"
  TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/b.html" --online >/dev/null
  [ -s "$gh.calls" ] && ok "offline: --online calls gh" || bad "offline: --online calls gh" "no calls"
  guard_fixture "$repo"; rm -f "$gh.calls"
  TODOS_OFFLINE=1 TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/c.html" --online >/dev/null
  [ -s "$gh.calls" ] && ok "offline: --online beats exported TODOS_OFFLINE" || bad "offline: --online beats exported TODOS_OFFLINE" "no calls"
  guard_fixture "$repo"; rm -f "$gh.calls"
  ( unset TODOS_OFFLINE; TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/d.html" >/dev/null )
  [ -e "$gh.calls" ] && bad "offline: unset env still offline" "$(cat "$gh.calls")" || ok "offline: unset env still offline"
  ok "offline: precedence"
  rm_fixture "$repo" "$sr"
}
test_offline_precedence

test_output_guard() {
  local repo sr slug out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; slug=$(core_slug git@github.com:Org/Repo.git)
  out=$(render "$repo" "$sr" --out "$repo/.todos/x.html")
  assert_eq "guard: .todos exits 1" "$(rc)" "1"
  assert_contains "guard: .todos message" "$(err)" "refusing to write"
  [ -e "$repo/.todos/x.html" ] && bad "guard: .todos nothing written" "written" || ok "guard: .todos nothing written"
  out=$(render "$repo" "$sr" --out "$sr/$slug/x.html")
  assert_eq "guard: state root exits 1" "$(rc)" "1"
  [ -e "$sr/$slug/x.html" ] && bad "guard: state root nothing written" "written" || ok "guard: state root nothing written"
  out=$(TODOS_DASHBOARD_DIR="$repo/.todos" render "$repo" "$sr")
  assert_eq "guard: TODOS_DASHBOARD_DIR under .todos exits 1" "$(rc)" "1"
  assert_eq "guard: nothing on stdout" "$out" ""
  ok "guard: output path"
  rm_fixture "$repo" "$sr"
}
test_output_guard

test_failed_write_preserves() {
  local repo sr f before after out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  render "$repo" "$sr" --out "$f" >/dev/null
  before=$(shasum "$f")
  if [ "$(id -u)" = 0 ]; then
    ok "write: skipped as root"
  else
    guard_fixture "$repo/out"; chmod 555 "$repo/out"
    out=$(render "$repo" "$sr" --out "$f")
    chmod 755 "$repo/out"
    assert_eq "write: failed render exits 1" "$(rc)" "1"
    assert_eq "write: failed render prints nothing" "$out" ""
    assert_contains "write: failed render message" "$(err)" "cannot write"
    after=$(shasum "$f")
    assert_eq "write: previous page preserved" "$after" "$before"
    [ -n "$(ls "$repo/out" | grep '\.tmp\.')" ] && bad "write: no temp left" "temp file" || ok "write: no temp left"
  fi
  ok "write: failed write preserves the previous page"
  rm_fixture "$repo" "$sr"
}
test_failed_write_preserves

test_unreadable_skipped() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  if [ "$(id -u)" = 0 ]; then
    ok "unreadable: skipped as root"
  else
    guard_fixture "$repo"; chmod 000 "$repo/.todos/pending/2026-05-01-plain.md"
    render "$repo" "$sr" --out "$f" >/dev/null
    chmod 644 "$repo/.todos/pending/2026-05-01-plain.md"
    assert_eq "unreadable: exit 0" "$(rc)" "0"
    assert_contains "unreadable: warning" "$(err)" "skipping unreadable file"
    assert_file_lacks "unreadable: row omitted" "$f" 'data-todo="2026-05-01-plain"'
    assert_file_has "unreadable: other rows render" "$f" 'data-todo="2026-05-02-blocked"'
  fi
  ok "unreadable: todo skipped"
  rm_fixture "$repo" "$sr"
}
test_unreadable_skipped

test_self_invalid_refs() {
  local repo sr f stub
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-loop <<'EOF'
---
created: 2026-05-01
title: Loop
depends_on:
  - todo:2026-05-01-loop.md
  - not a ref!
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_has "refs: self" "$f" 'todo:2026-05-01-loop (self)'
  assert_file_has "refs: invalid" "$f" 'not a ref! (invalid)'
  assert_file_has "refs: blocked" "$f" 'data-todo="2026-05-01-loop" data-state="blocked"'
  stub="$repo/todos-stub.sh"
  guard_fixture "$repo"
  cat >"$stub" <<EOF
#!/usr/bin/env bash
[ "\$1" = _depends ] && exit 1
exec bash "$TODOS" "\$@"
EOF
  chmod +x "$stub"
  TODOS_DASHBOARD_TODOS_SH="$stub" render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "refs: depends failure exit 0" "$(rc)" "0"
  assert_file_has "refs: depends failure shown" "$f" 'depends_on (unreadable)'
  assert_file_has "refs: depends failure blocks" "$f" 'data-todo="2026-05-01-loop" data-state="blocked"'
  ok "refs: self, invalid, and unreadable dependencies"
  rm_fixture "$repo" "$sr"
}
test_self_invalid_refs

test_link_boundaries() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-links <<'EOF'
---
created: 2026-05-01
title: Links
---

## Problem

[PR](https://github.com/o/r/pull/12). And https://x.test/a.
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_has "links: PR url clean" "$f" 'href="https://github.com/o/r/pull/12"'
  assert_file_has "links: host label" "$f" '>x.test<'
  assert_file_lacks "links: no trailing paren" "$f" 'pull/12)"'
  assert_file_lacks "links: no trailing dot" "$f" 'x.test/a."'
  ok "links: boundaries"
  rm_fixture "$repo" "$sr"
}
test_link_boundaries

test_visibility_warning() {
  local repo sr
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"
  render "$repo" "$sr" --out "$repo/out/a.html" >/dev/null
  assert_missing "visibility: excluded repo is quiet" "$(err)" "neither git-ignored nor tracked"
  guard_fixture "$repo"; : >"$repo/.git/info/exclude"
  render "$repo" "$sr" --out "$repo/out/b.html" >/dev/null
  assert_eq "visibility: still exit 0" "$(rc)" "0"
  assert_contains "visibility: warns when not ignored" "$(err)" "neither git-ignored nor tracked"
  ok "visibility: .todos exclusion warning"
  rm_fixture "$repo" "$sr"
}
test_visibility_warning

test_attribute_injection() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-inject <<'EOF'
---
created: 2026-05-01
title: Inject
priority: x" onclick="alert(1)
area: y" onmouseover="alert(2)
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "inject: exit 0" "$(rc)" "0"
  assert_file_lacks "inject: no onclick attribute" "$f" ' onclick="'
  assert_file_lacks "inject: no onmouseover attribute" "$f" ' onmouseover="'
  if grep -qE ' on[a-z]+="' "$f"; then bad "inject: no event attributes at all" "on*= attribute present"; else ok "inject: no event attributes at all"; fi
  assert_file_has "inject: priority escaped as text" "$f" 'x&quot; onclick=&quot;alert(1)'
  ok "inject: frontmatter values never become attributes"
  rm_fixture "$repo" "$sr"
}
test_attribute_injection

test_symlink_guard() {
  local repo sr out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"
  guard_fixture "$repo"; ln -s "$repo/.todos" "$repo/alias"
  out=$(render "$repo" "$sr" --out "$repo/alias/x.html")
  assert_eq "symlink guard: exits 1" "$(rc)" "1"
  assert_contains "symlink guard: message" "$(err)" "refusing to write"
  [ -e "$repo/.todos/x.html" ] && bad "symlink guard: nothing written" "written" || ok "symlink guard: nothing written"
  ok "symlink guard: output path through a symlink into .todos"
  rm_fixture "$repo" "$sr"
}
test_symlink_guard

test_opener_failure() {
  local repo sr f out
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"; f="$repo/out/board.html"
  out=$(TODOS_DASHBOARD_OPENER="$repo/no-such-opener" render "$repo" "$sr" --out "$f" --open)
  assert_eq "opener: exit 0 when opener is missing" "$(rc)" "0"
  assert_eq "opener: stdout is the path only" "$out" "$f"
  assert_contains "opener: warning on stderr" "$(err)" "cannot open"
  ok "opener: missing opener is a warning"
  rm_fixture "$repo" "$sr"
}
test_opener_failure

test_record_shapes() {
  local repo sr f slug tasks
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  slug=$(core_slug git@github.com:Org/Repo.git); tasks="$sr/$slug/tasks"; mkdir -p "$tasks"
  mk_todo "$repo" pending 2026-05-01-empty-review <<'EOF'
---
created: 2026-05-01
title: Empty review record
---
EOF
  printf '{"status":"reviewed","review_outcome":"approved","review_head_sha":"abc","workers":[{"phase":"review","agent":"rev-a"}]}' >"$tasks/td-2026-05-01-empty-review.json"
  printf '{}' >"$tasks/td-2026-05-01-empty-review.review.json"
  mk_todo "$repo" pending 2026-05-02-null-fields <<'EOF'
---
created: 2026-05-02
title: Null fields
---
EOF
  printf '{"status":null,"workers":"nope","review_outcome":["x"]}' >"$tasks/td-2026-05-02-null-fields.json"
  mk_todo "$repo" pending 2026-05-03-stale-review <<'EOF'
---
created: 2026-05-03
title: Stale review
---
EOF
  printf '{"status":"in-progress","review_head_sha":"new","workers":[{"phase":"implement","agent":"impl-a"}]}' >"$tasks/td-2026-05-03-stale-review.json"
  printf '{"outcome":"approved","blocking_count":0,"reviewed_head_sha":"old"}' >"$tasks/td-2026-05-03-stale-review.review.json"
  printf '{"outcome":"completed","phase":"implement","agent":"impl-a"}' >"$tasks/td-2026-05-03-stale-review.done.json"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "records: exit 0" "$(rc)" "0"
  assert_file_has "records: empty review record shows unknown" "$f" 'review unknown'
  assert_file_lacks "records: empty review record hides task review_outcome" "$f" 'review approved</div>'
  assert_file_has "records: null status is recorded" "$f" 'data-todo="2026-05-02-null-fields" data-state="open" data-task-status=""'
  assert_file_has "records: stale review tagged" "$f" 'review approved (0 blocking) (stale)'
  assert_file_has "records: fresh done record untagged" "$f" 'done completed implement</div>'
  assert_file_has "records: in-flight count ignores null status" "$f" 'data-count="in-flight">2<'
  ok "records: empty, null, and stale record shapes"
  rm_fixture "$repo" "$sr"
}
test_record_shapes

test_frontmatter_first_match() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-dup <<'EOF'
---
created: 2026-05-01
title:
title: later
area: first
area: second
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_lacks "frontmatter: blank first title wins" "$f" '>later<'
  assert_file_has "frontmatter: title falls back to basename" "$f" '<div class="name">2026-05-01-dup</div>'
  assert_file_has "frontmatter: first area wins" "$f" '>first<'
  assert_file_lacks "frontmatter: second area ignored" "$f" '>second<'
  ok "frontmatter: first occurrence wins"
  rm_fixture "$repo" "$sr"
}
test_frontmatter_first_match

rm -f "$RCF" "$ERRF"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
