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
CONTEXT="$HERE/../../../lib/workflow_context.py"

# A developer's own overrides must not leak into the fixtures.
unset TODOS_DASHBOARD_DIR TODOS_STATE_ROOT TODOS_DASHBOARD_TODOS_SH TODOS_DASHBOARD_OPENER \
      TODOS_OFFLINE TODOS_GH TODOS_BASE_REF XDG_STATE_HOME CODEX_HOME \
      CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY CLAUDE_WORK_CONFIG_DIR CLAUDE_WORK_TREE \
      ORCH_RUNTIME HERDR_PERSONAL
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

mk_repo_at() { # mk_repo_at <empty-dir>
  local d="$1"
  guard_fixture "$(dirname "$d")"
  mkdir "$d" || refuse "cannot create fixture repo $d"
  { git -C "$d" init -q \
    && git -C "$d" config user.email t@t && git -C "$d" config user.name t \
    && git -C "$d" config commit.gpgsign false && git -C "$d" config core.hooksPath /dev/null \
    && git -C "$d" commit -q --allow-empty -m base \
    && git -C "$d" update-ref refs/remotes/origin/main HEAD \
    && git -C "$d" remote add origin git@github.com:Org/Repo.git \
    && mkdir -p "$d/.git/info" && printf '.todos/\n' >>"$d/.git/info/exclude"; } >/dev/null 2>&1 \
    || refuse "cannot build fixture repo in $d"
}

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
path_uri() { # path_uri <path> -> file:// URI, percent-encoded like Path.as_uri()
  python3 -c 'import sys; from pathlib import Path; print(Path(sys.argv[1]).as_uri())' "$1"
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

render_scoped() { # render_scoped <repo> <home> <xdg-state> [dashboard args...]
  local repo="$1" home="$2" xdg="$3"; shift 3
  guard_fixture "$repo"; guard_fixture "$home"; guard_fixture "$xdg"
  (
    cd "$repo" || exit 2
    unset CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY CLAUDE_WORK_CONFIG_DIR
    export HOME="$home" CODEX_HOME="$home/.codex" XDG_STATE_HOME="$xdg" \
           CLAUDE_WORK_TREE="$home/Git/work" TODOS_DASHBOARD_NOW="2026-05-07 09:00" \
           TODOS_TODAY=2026-05-07
    bash "$TODOS" dashboard "$@" 2>"$ERRF"
  )
  printf '%s' "$?" >"$RCF"
}

scope_account_id() { # scope_account_id <repo> <home> [--personal]
  local repo="$1" home="$2"; shift 2
  local scope
  scope=$( (
    unset CLAUDE_CONFIG_DIR CLAUDE_PERSONAL_ONLY CLAUDE_WORK_CONFIG_DIR
    HOME="$home" CODEX_HOME="$home/.codex" CLAUDE_WORK_TREE="$home/Git/work" \
      python3 "$CONTEXT" account-scope --cwd "$repo" --runtime codex "$@"
  ) ) || return 1
  python3 -c 'import json,sys; print(json.loads(sys.argv[1])["account_id"])' "$scope"
}

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
  assert_file_lacks "render: no filter form" "$f" 'class="filters"'
  assert_file_lacks "render: no match count" "$f" 'data-match'
  assert_file_lacks "render: no copy chips" "$f" 'data-copy'
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

test_account_scoped_state_and_output() {
  local home repo xdg slug personal_tasks work_tasks work_id personal_id out work_page personal_page
  home=$(mk_dir) || exit 2; mkdir -p "$home/Git/work" "$home/.claude" "$home/.claude-work"
  repo="$home/Git/work/repo"; mk_repo_at "$repo"
  xdg=$(mk_dir) || exit 2; slug=$(core_slug git@github.com:Org/Repo.git)
  mk_todo "$repo" pending 2026-05-01-account <<'EOF'
---
created: 2026-05-01
title: Account-scoped todo
---
EOF
  personal_tasks="$home/.claude/herdr-orch/$slug/tasks"
  work_tasks="$home/.claude-work/herdr-orch/$slug/tasks"
  mkdir -p "$personal_tasks" "$work_tasks"
  printf '{"status":"personal-only","workers":[]}' >"$personal_tasks/td-2026-05-01-account.json"
  printf '{"status":"in-progress","workers":[]}' >"$work_tasks/td-2026-05-01-account.json"
  work_id=$(scope_account_id "$repo" "$home") || refuse "cannot resolve work account id"
  personal_id=$(scope_account_id "$repo" "$home" --personal) || refuse "cannot resolve personal account id"

  out=$(render_scoped "$repo" "$home" "$xdg" --runtime codex)
  assert_eq "account: work Codex dashboard exits 0" "$(rc)" "0"
  work_page="$xdg/dotfiles/dashboard/$work_id/$slug.html"
  assert_eq "account: work default output is account-partitioned" "$out" "$work_page"
  assert_file_has "account: work Codex reads only work state" "$work_page" 'data-task-status="in-progress"'
  assert_file_lacks "account: work Codex does not read personal state" "$work_page" 'personal-only'

  out=$(render_scoped "$repo" "$home" "$xdg" --runtime codex --personal)
  assert_eq "account: personal override dashboard exits 0" "$(rc)" "0"
  personal_page="$xdg/dotfiles/dashboard/$personal_id/$slug.html"
  assert_eq "account: personal override uses a separate output" "$out" "$personal_page"
  assert_file_has "account: personal override reads personal state" "$personal_page" 'data-task-status="personal-only"'
  assert_file_lacks "account: personal output stays distinct from work output" "$personal_page" 'in-progress'

  out=$( (
    export HERDR_PERSONAL=1
    render_scoped "$repo" "$home" "$xdg" --runtime codex
  ) )
  assert_eq "account: bound personal dashboard exits 0" "$(rc)" "0"
  assert_eq "account: bound personal keeps personal output" "$out" "$personal_page"
  assert_file_has "account: bound personal reads personal state" "$personal_page" 'data-task-status="personal-only"'
  ok "account: Codex work and deliberate personal scopes stay isolated"
  rm_fixture "$home" "$xdg"
}
test_account_scoped_state_and_output

test_inherited_git_location_is_ignored() {
  local home work foreign xdg slug work_id tasks out page
  home=$(mk_dir) || exit 2
  mkdir -p "$home/Git/work" "$home/Git/personal" "$home/.claude" "$home/.claude-work"
  work="$home/Git/work/active"; foreign="$home/Git/personal/foreign"
  mk_repo_at "$work"; mk_repo_at "$foreign"
  xdg=$(mk_dir) || exit 2; slug=$(core_slug git@github.com:Org/Repo.git)
  mk_todo "$work" pending 2026-05-02-local <<'EOF'
---
created: 2026-05-02
title: Local checkout wins
---
EOF
  tasks="$home/.claude-work/herdr-orch/$slug/tasks"; mkdir -p "$tasks"
  printf '{"status":"in-progress","workers":[]}' >"$tasks/td-2026-05-02-local.json"
  work_id=$(scope_account_id "$work" "$home") || refuse "cannot resolve work account id"

  out=$( (
    export GIT_DIR="$foreign/.git" GIT_WORK_TREE="$foreign"
    render_scoped "$work" "$home" "$xdg" --runtime codex
  ) )
  assert_eq "account: inherited Git location dashboard exits 0" "$(rc)" "0"
  page="$xdg/dotfiles/dashboard/$work_id/$slug.html"
  assert_eq "account: inherited Git location keeps current checkout output" "$out" "$page"
  assert_file_has "account: inherited Git location keeps work state" "$page" 'data-task-status="in-progress"'
  rm_fixture "$home" "$xdg"
}
test_inherited_git_location_is_ignored

test_default_scope_rejects_cross_account_tasks_symlink() {
  local home repo xdg slug work_tasks personal_tasks work_id out page
  home=$(mk_dir) || exit 2; mkdir -p "$home/Git/work" "$home/.claude" "$home/.claude-work"
  repo="$home/Git/work/repo"; mk_repo_at "$repo"
  xdg=$(mk_dir) || exit 2; slug=$(core_slug git@github.com:Org/Repo.git)
  mk_todo "$repo" pending 2026-05-03-scoped <<'EOF'
---
created: 2026-05-03
title: Scoped task state
---
EOF
  personal_tasks="$home/.claude/herdr-orch/$slug/tasks"; mkdir -p "$personal_tasks"
  printf '{"status":"private-personal-marker","workers":[]}' >"$personal_tasks/td-2026-05-03-scoped.json"
  work_tasks="$home/.claude-work/herdr-orch/$slug/tasks"; mkdir -p "$(dirname "$work_tasks")"
  ln -s "$personal_tasks" "$work_tasks" || refuse "cannot plant cross-account tasks symlink"
  work_id=$(scope_account_id "$repo" "$home") || refuse "cannot resolve work account id"

  out=$(render_scoped "$repo" "$home" "$xdg" --runtime codex)
  assert_eq "account: task symlink dashboard exits 0" "$(rc)" "0"
  page="$xdg/dotfiles/dashboard/$work_id/$slug.html"
  assert_eq "account: task symlink keeps work output" "$out" "$page"
  assert_file_lacks "account: task symlink never reads personal state" "$page" 'private-personal-marker'
  rm_fixture "$home" "$xdg"
}
test_default_scope_rejects_cross_account_tasks_symlink

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
  assert_file_lacks "empty: no done lane" "$f" 'data-bucket="done"'
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
  assert_file_lacks "flags: --completed 0 hides the done lane" "$f" 'data-bucket="done"'
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

test_symlink_at_out() {
  local repo sr outside out
  # A symlink AT the --out path itself (not a symlinked directory earlier in
  # the path): os.replace() swaps the name `out` refers to, not wherever the
  # symlink currently points, so the guard must key off the name's own
  # location, never the symlink's target.
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"
  outside=$(mk_dir) || exit 2
  printf 'pre-existing outside content\n' >"$outside/target.html"
  mkdir -p "$repo/.todos"
  guard_fixture "$repo/.todos"
  ln -s "$outside/target.html" "$repo/.todos/board.html"
  out=$(render "$repo" "$sr" --out "$repo/.todos/board.html")
  assert_eq "guard: symlink at out exits 1" "$(rc)" "1"
  assert_contains "guard: symlink at out message" "$(err)" "refusing to write"
  assert_eq "guard: symlink at out outside target untouched" "$(cat "$outside/target.html")" "pre-existing outside content"
  [ -L "$repo/.todos/board.html" ] && ok "guard: symlink at out left in place" || bad "guard: symlink at out left in place" "symlink replaced"
  out=$(render "$repo" "$sr" --out "$repo/.todos")
  assert_eq "guard: --out naming .todos itself exits 1" "$(rc)" "1"
  [ -d "$repo/.todos" ] && ok "guard: .todos stays a directory" || bad "guard: .todos stays a directory" "clobbered"
  ok "guard: symlink at the out path itself"
  rm_fixture "$repo" "$sr" "$outside"
}
test_symlink_at_out

test_symlinked_protected_root() {
  local repo sr real out parent link_sr
  # A protected root that is ITSELF a symlink (the routine worktree case):
  # resolving it to its target and comparing only the resolved form misses
  # the root's own unresolved name, which is exactly the name --out can
  # target directly. Both .todos and the state root must refuse this.
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; real=$(mk_dir) || exit 2
  guard_fixture "$repo"
  ln -s "$real" "$repo/.todos"
  out=$(render "$repo" "$sr" --out "$repo/.todos")
  assert_eq "guard: --out naming a symlinked .todos exits 1" "$(rc)" "1"
  assert_contains "guard: symlinked .todos message" "$(err)" "refusing to write"
  [ -L "$repo/.todos" ] && ok "guard: symlinked .todos left in place" || bad "guard: symlinked .todos left in place" "symlink replaced"
  [ -d "$real" ] && ok "guard: .todos symlink target untouched" || bad "guard: .todos symlink target untouched" "target removed"
  rm_fixture "$repo" "$sr" "$real"

  parent=$(mk_dir) || exit 2; real=$(mk_dir) || exit 2
  guard_fixture "$parent"
  ln -s "$real" "$parent/state"
  link_sr="$parent/state"
  repo=$(mk_repo) || exit 2
  out=$(render "$repo" "$link_sr" --out "$link_sr")
  assert_eq "guard: --out naming a symlinked state root exits 1" "$(rc)" "1"
  assert_contains "guard: symlinked state root message" "$(err)" "refusing to write"
  [ -L "$link_sr" ] && ok "guard: symlinked state root left in place" || bad "guard: symlinked state root left in place" "symlink replaced"
  [ -d "$real" ] && ok "guard: state root symlink target untouched" || bad "guard: state root symlink target untouched" "target removed"
  rm_fixture "$repo" "$parent" "$real"

  # A normal, unprotected --out must still succeed -- the tightened guard
  # must not overreach into ordinary writes.
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; mk_board "$repo" "$sr"
  out=$(render "$repo" "$sr" --out "$repo/out/normal.html")
  assert_eq "guard: normal --out still exits 0" "$(rc)" "0"
  [ -f "$repo/out/normal.html" ] && ok "guard: normal --out still writes" || bad "guard: normal --out still writes" "missing"
  rm_fixture "$repo" "$sr"

  ok "guard: symlinked protected root named directly via --out"
}
test_symlinked_protected_root

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

test_symlinked_todos() {
  local repo sr real f
  # A whole-directory symlinked .todos/ (maintenance-worktree convention):
  # research links must resolve through it to the persistent real path, and
  # the visibility warning must not fire against the symlink name itself.
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; real=$(mk_dir) || exit 2
  f="$repo/out/board.html"
  mkdir -p "$real/research"
  cat >"$real/research/2026-05-01-note.md" <<'EOF'
---
created: 2026-05-01
title: Symlinked note
---

Summary.
EOF
  guard_fixture "$repo"
  ln -s "$real" "$repo/.todos"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "symlinked-todos: exit 0" "$(rc)" "0"
  assert_file_has "symlinked-todos: research entry present" "$f" 'data-research="2026-05-01-note.md"'
  assert_file_lacks "symlinked-todos: link does not embed the worktree path" "$f" "$repo/.todos"
  assert_file_has "symlinked-todos: link resolves to the real target" "$f" "href=\"$(path_uri "$(cd "$real" && pwd -P)/research/2026-05-01-note.md")\""
  ok "symlinked-todos: research links resolve through the symlink"
  rm_fixture "$repo" "$sr" "$real"

  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2
  # A target outside any repo entirely: nothing there can ever be committed,
  # so the exclusion warning must stay silent regardless of exclude state.
  real=$(mk_dir) || exit 2
  guard_fixture "$repo"; rm -rf "$repo/.todos" 2>/dev/null; ln -s "$real" "$repo/.todos"
  guard_fixture "$repo"; : >"$repo/.git/info/exclude"
  render "$repo" "$sr" --out "$repo/out/c.html" >/dev/null
  assert_eq "symlinked-todos: outside-repo exit 0" "$(rc)" "0"
  assert_missing "symlinked-todos: outside-repo target is quiet" "$(err)" "neither git-ignored nor tracked"
  ok "symlinked-todos: symlink target outside the repo suppresses the warning"
  rm_fixture "$repo" "$sr" "$real"
}
test_symlinked_todos

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
  assert_file_has "frontmatter: title falls back to basename" "$f" '<span class="card-title">2026-05-01-dup</span>'
  assert_file_has "frontmatter: first area wins" "$f" '>first<'
  assert_file_lacks "frontmatter: second area ignored" "$f" '>second<'
  ok "frontmatter: first occurrence wins"
  rm_fixture "$repo" "$sr"
}
test_frontmatter_first_match

test_status_buckets() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-ready <<'EOF'
---
created: 2026-05-01
title: Ready item
---
EOF
  mk_todo "$repo" pending 2026-05-02-waiting <<'EOF'
---
created: 2026-05-02
title: Waiting item
status: waiting
---
EOF
  mk_todo "$repo" pending 2026-05-03-someday <<'EOF'
---
created: 2026-05-03
title: Someday item
status: someday
---
EOF
  mk_todo "$repo" pending 2026-05-04-blocked-waiting <<'EOF'
---
created: 2026-05-04
title: Blocked but marked waiting
status: waiting
depends_on:
  - todo:2026-05-01-ready
---
EOF
  mk_todo "$repo" pending 2026-05-05-bogus-status <<'EOF'
---
created: 2026-05-05
title: Unrecognized status
status: yolo
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "status: exit 0" "$(rc)" "0"
  assert_file_has "status: ready heading" "$f" '<h2 data-bucket="ready">Ready'
  assert_file_has "status: waiting heading" "$f" '<h2 data-bucket="waiting">Waiting'
  assert_file_has "status: someday heading" "$f" '<h2 data-bucket="someday">Someday'
  assert_file_has "status: ready item in ready bucket" "$f" 'data-todo="2026-05-01-ready" data-state="open"'
  assert_file_has "status: waiting item row" "$f" 'data-todo="2026-05-02-waiting" data-state="open"'
  assert_file_has "status: someday item row" "$f" 'data-todo="2026-05-03-someday" data-state="open"'
  assert_file_has "status: someday collapses via details" "$f" '<details class="lane" id="lane-someday"><summary><h2 data-bucket="someday">'
  assert_file_has "status: unrecognized status falls back to ready" "$f" 'data-todo="2026-05-05-bogus-status" data-state="open"'
  assert_file_has "status: waiting count tile" "$f" 'data-count="waiting">1<'
  assert_file_has "status: someday count tile" "$f" 'data-count="someday">1<'
  ok "status: exit 0 and bucket headings"
  rm_fixture "$repo" "$sr"

  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-target <<'EOF'
---
created: 2026-05-01
title: Target
---
EOF
  mk_todo "$repo" pending 2026-05-02-precedence <<'EOF'
---
created: 2026-05-02
title: Blocked wins over waiting
status: waiting
depends_on:
  - todo:2026-05-01-target
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_has "status: blocked overrides waiting status" "$f" '<h2 data-bucket="blocked">Blocked'
  assert_file_has "status: precedence row is blocked" "$f" 'data-todo="2026-05-02-precedence" data-state="blocked"'
  assert_file_lacks "status: precedence row not also in waiting" "$f" 'data-bucket="waiting"'
  ok "status: computed state overrides manual status"
  rm_fixture "$repo" "$sr"

  # A herdr status of completed means implementation already happened
  # (review/merge pending); such a todo must not be offered in Ready for
  # fresh pickup, even if the author also marked it someday. The second
  # todo below uses in-progress -- the real persisted status herdr writes
  # for a paused/phase-advanced task, per its transition table -- rather
  # than a "paused" record herdr never actually produces.
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  local slug tasks
  slug=$(core_slug git@github.com:Org/Repo.git); tasks="$sr/$slug/tasks"; mkdir -p "$tasks"
  mk_todo "$repo" pending 2026-05-01-completed-not-merged <<'EOF'
---
created: 2026-05-01
title: Completed, review pending
status: someday
---
EOF
  printf '{"status":"completed","workers":[{"phase":"implement","agent":"impl-a"}]}' \
    >"$tasks/td-2026-05-01-completed-not-merged.json"
  mk_todo "$repo" pending 2026-05-02-in-progress <<'EOF'
---
created: 2026-05-02
title: In progress
status: waiting
---
EOF
  printf '{"status":"in-progress","workers":[{"phase":"implement","agent":"impl-b"}]}' \
    >"$tasks/td-2026-05-02-in-progress.json"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_file_has "status: completed status sorts in-flight, not ready" "$f" \
    'data-todo="2026-05-01-completed-not-merged" data-state="open" data-task-status="completed"'
  assert_file_lacks "status: completed status is not someday despite the field" "$f" \
    'id="lane-someday"'
  assert_file_has "status: in-progress status sorts in-flight despite waiting field" "$f" \
    'data-todo="2026-05-02-in-progress" data-state="open" data-task-status="in-progress"'
  assert_file_has "status: in-flight heading covers both" "$f" '<h2 data-bucket="in-flight">In flight <span class="bucket-count">2</span></h2>'
  ok "status: herdr status overrides Ready and Someday/Waiting"
  rm_fixture "$repo" "$sr"
}
test_status_buckets

test_prd_rows() {
  local repo sr f
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-08-render-me <<'EOF'
---
created: 2026-05-08
title: Render me
priority: low
---

Preamble line.

## Problem

First line
continues with `code <b>` and **bold** and [docs](https://example.com/a?b=1&c=2).
See https://example.com/x.

- top item
  - nested item
1. numbered
   continuation

### Sub heading

```sh
echo "<tag>"
## not a section
```

| a | b |
| - | - |

<script>alert(1)</script> <img src=x onerror=y> [x](javascript:alert(1)) _not_italic_

## Solution

Fix it.
EOF
  mk_todo "$repo" completed 2026-05-06-shipped <<'EOF'
---
created: 2026-05-06
title: Shipped
---

## Problem

Done and dusted.
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "prd: exit 0" "$(rc)" "0"
  assert_file_has "prd: open todo gets a modal" "$f" \
    '<div class="modal" id="todo-2026-05-08-render-me" data-modal="2026-05-08-render-me" role="dialog" aria-labelledby="title-2026-05-08-render-me"><a class="backdrop" href="#board" tabindex="-1" aria-hidden="true"></a><article class="sheet" tabindex="-1">'
  assert_file_has "prd: completed todo gets a modal" "$f" \
    '<div class="modal" id="todo-2026-05-06-shipped" data-modal="2026-05-06-shipped" role="dialog"'
  assert_file_has "prd: preamble and section heading open the modal body" "$f" '<div class="prd"><p>Preamble line.</p><h4>Problem</h4>'
  assert_file_has "prd: paragraph join, inline code, bold, link, bare URL" "$f" \
    '<p>First line continues with <code>code &lt;b&gt;</code> and <strong>bold</strong> and <a href="https://example.com/a?b=1&amp;c=2">docs</a>. See <a href="https://example.com/x">https://example.com/x</a>.</p>'
  assert_file_has "prd: flattened list with depth and literal number" "$f" \
    '<ul class="md"><li class="d0">top item</li><li class="d1">nested item</li><li class="d0"><span class="num">1.</span> numbered continuation</li></ul>'
  assert_file_has "prd: sub heading" "$f" '<h5>Sub heading</h5>'
  assert_file_has "prd: fenced block is escaped pre" "$f" '<pre>echo &quot;&lt;tag&gt;&quot;'
  assert_file_lacks "prd: heading inside a fence is not a section" "$f" '<h4>not a section</h4>'
  assert_file_has "prd: table is pre" "$f" '<pre>| a | b |'
  assert_file_has "prd: hostile text escaped" "$f" \
    '<p>&lt;script&gt;alert(1)&lt;/script&gt; &lt;img src=x onerror=y&gt; [x](javascript:alert(1)) _not_italic_</p>'
  assert_file_lacks "prd: no img tag" "$f" '<img'
  assert_file_lacks "prd: no javascript href" "$f" 'href="javascript'
  assert_file_lacks "prd: no italic" "$f" '<em>'
  assert_file_has "prd: completed body rendered" "$f" '<h4>Problem</h4><p>Done and dusted.</p>'
  assert_file_lacks "prd: static page has no script" "$f" '<script'
  assert_file_lacks "prd: static page has no form" "$f" '<form'
  if grep -qiE '<link|<iframe|@import|url\(|<script| on[a-z]+="' "$f"; then bad "prd: inert page" "script, link, iframe, import, url(), or on*= handler"; else ok "prd: inert page"; fi
  rm_fixture "$repo" "$sr"
}
test_prd_rows

test_card_summary() {
  local out
  out=$(python3 - "$HERE/.." <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from todos_dashboard import card_summary
cases = [
    ("---\ntitle: t\n---\n\n## Problem\n\nThe `x` tool from [PR](https://e.com/1)\nis **hard** to use. Second sentence.\n",
     "The x tool from PR is hard to use."),
    ("## Problem\n\n```sh\nfenced\n```\n\nAfter the fence. More.\n", "After the fence."),
    ("## Problem\n\nLead line:\n- item one\n", "Lead line:"),
    ("## Problem\n\nversion 1.2 ships e.g. today. Next.\n", "version 1.2 ships e.g. today."),
    ("## Solution\n\nNo problem section.\n", ""),
    ("```\n## Problem\n```\n\n## Problem\n\nReal one.\n", "Real one."),
]
for text, want in cases:
    got = card_summary(text)
    print("ok" if got == want else f"FAIL want {want!r} got {got!r}")
long = card_summary("## Problem\n\n" + " ".join(["word"] * 70) + ".\n")
print("ok" if len(long) <= 220 and long.endswith("word...") else f"FAIL long {long!r}")
PY
)
  assert_eq "summary: first sentence, fences, lists, abbreviations, missing, fenced heading, cap" "$out" "ok
ok
ok
ok
ok
ok
ok"
}
test_card_summary

test_herdr_lookup() {
  local d out
  d=$(mk_dir) || exit 2
  printf '{"status":"in-progress","workers":[{"phase":"plan","agent":"a"}]}' >"$d/2026-05-01-x.json"
  printf '{"status":"merged"}' >"$d/td-2026-05-01-x.json"
  printf '{"status":"reviewed"}' >"$d/td-2026-05-02-y.json"
  out=$(python3 - "$HERE/.." "$d" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from todos_dashboard import herdr_status
d = Path(sys.argv[2])
for b in ("2026-05-01-x", "2026-05-02-y", "2026-05-03-z"):
    h = herdr_status(d, b)
    print(b, "none" if h is None else f'{h["task_id"]}|{h["status"]}|{h["phase"]}')
PY
)
  assert_eq "herdr lookup: bare id first, td- fallback, none" "$out" "2026-05-01-x 2026-05-01-x|in-progress|plan
2026-05-02-y td-2026-05-02-y|reviewed|
2026-05-03-z none"
  rm_fixture "$d"
}
test_herdr_lookup

# between <file> <start> <end> -> the text from start up to (not including) end
between() {
  python3 -c 'import sys; t = open(sys.argv[1]).read(); a = t.index(sys.argv[2]); print(t[a:t.index(sys.argv[3], a)])' "$1" "$2" "$3"
}

test_cards() {
  local repo sr f main modal long
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  mk_todo "$repo" pending 2026-05-01-summary <<'EOF'
---
created: 2026-05-01
title: Summary card
---

## Problem

The `todos.sh serve` board from [PR #237](https://github.com/Org/Repo/pull/237)
is **hard** to scan. Secondzebra sentence stays in the modal.

## Solution

Solutionyak text.
EOF
  long=$(python3 -c 'print(" ".join(["word"] * 70) + ".")')
  mk_todo "$repo" pending 2026-05-02-long <<EOF
---
created: 2026-05-02
title: Long summary
---

## Problem

$long
EOF
  mk_todo "$repo" pending 2026-05-03-later <<'EOF'
---
created: 2026-05-03
title: Someday card
status: someday
---
EOF
  mk_todo "$repo" completed 2026-05-04-done <<'EOF'
---
created: 2026-05-04
title: Done card
---
EOF
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "cards: exit 0" "$(rc)" "0"
  main=$(between "$f" '<main>' '</main>')
  assert_contains "cards: card links to its modal" "$main" \
    '<li><a class="card" href="#todo-2026-05-01-summary" data-todo="2026-05-01-summary" data-state="open" data-task-status=""><span class="card-title">Summary card</span>'
  assert_contains "cards: summary is the first sentence, markup stripped" "$main" \
    '<span class="card-summary">The todos.sh serve board from PR #237 is hard to scan.</span>'
  assert_missing "cards: no second sentence on the board" "$main" 'Secondzebra'
  assert_missing "cards: no Solution text on the board" "$main" 'Solutionyak'
  modal=$(between "$f" '<div class="modal" id="todo-2026-05-01-summary"' '</article></div>')
  assert_contains "cards: modal holds the second sentence" "$modal" 'Secondzebra'
  assert_contains "cards: modal holds the Solution" "$modal" 'Solutionyak'
  assert_eq "cards: long summary cut to at most 220 with the suffix" "$(printf '%s' "$main" | python3 -c '
import re, sys
s = re.search(r"data-todo=\"2026-05-02-long\".*?card-summary\">([^<]*)<", sys.stdin.read()).group(1)
print(len(s) <= 220, s.endswith("word..."))')" "True True"
  assert_eq "cards: lanes in order ready, someday, done, then research" "$(python3 - "$f" <<'PY'
import sys
t = open(sys.argv[1]).read()
keys = ['data-bucket="ready"', 'data-bucket="someday"', 'data-bucket="done"', 'id="research"']
pos = [t.find(k) for k in keys]
print(-1 not in pos and pos == sorted(pos))
PY
)" "True"
  assert_file_has "cards: someday lane collapsed" "$f" '<details class="lane" id="lane-someday"><summary>'
  assert_file_has "cards: done lane collapsed by default" "$f" \
    '<details class="lane" id="lane-done"><summary><h2 data-bucket="done">Recently done <span class="bucket-count">1</span></h2>'
  assert_file_has "cards: completed card has no data-state" "$f" \
    '<a class="card" href="#todo-2026-05-04-done" data-todo="2026-05-04-done" data-task-status="">'
  assert_file_has "cards: count pill links to its lane" "$f" '<a href="#lane-ready"><b data-count="ready">2</b> ready</a>'
  assert_file_lacks "cards: no element is the #board target" "$f" 'id="board"'
  assert_file_has "cards: modal shown by :target" "$f" '.modal:target { display: block; }'
  assert_file_has "cards: page stops scrolling under a modal" "$f" 'body:has(.modal:target) { overflow: hidden; }'
  assert_file_has "cards: modal text wraps long tokens" "$f" '.prd, .facts { overflow-wrap: anywhere; }'
  assert_file_has "theme: light tokens" "$f" '--ground: #f4f5f7;'
  assert_file_has "theme: dark tokens" "$f" '--ground: #1d2125;'
  assert_file_has "theme: dark tokens apply to an explicit choice" "$f" ':root[data-theme="dark"] {'
  assert_file_has "theme: dark tokens follow the OS unless light is chosen" "$f" ':root:not([data-theme="light"]) {'
  assert_file_has "theme: lane colours the cards" "$f" '#lane-blocked { --lane: var(--blocked); }'
  assert_file_lacks "theme: static page has no toggle" "$f" 'class="theme"'
  assert_file_lacks "theme: placeholder fully substituted" "$f" '@@DARK@@'
  rm_fixture "$repo" "$sr"
}
test_cards

test_badges_and_facts() {
  local repo sr f main slug tasks
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  slug=$(core_slug git@github.com:Org/Repo.git); tasks="$sr/$slug/tasks"; mkdir -p "$tasks"
  mk_todo "$repo" pending 2026-05-01-prio <<'EOF'
---
created: 2026-05-01
title: Odd priority
priority: medium
area: store
due: 2026-05-01
files:
  - claude/x.py
---
EOF
  mk_todo "$repo" pending 2026-05-02-due <<'EOF'
---
created: 2026-05-02
title: Due later
priority: high
due: 2026-06-01
---
EOF
  mk_todo "$repo" pending 2026-05-03-surface <<'EOF'
---
created: 2026-05-03
title: Surfaces later
surface: 2026-06-01
---
EOF
  mk_todo "$repo" pending 2026-05-04-past <<'EOF'
---
created: 2026-05-04
title: Surfaced already
surface: 2026-05-01
---
EOF
  mk_todo "$repo" pending 2026-05-05-two-deps <<'EOF'
---
created: 2026-05-05
title: Two deps
depends_on:
  - todo:2026-05-01-prio
  - todo:2026-05-02-due
---
EOF
  mk_todo "$repo" completed 2026-04-30-shipped <<'EOF'
---
created: 2026-04-30
title: Shipped
---
EOF
  mk_todo "$repo" pending 2026-05-06-met <<'EOF'
---
created: 2026-05-06
title: Deps met
depends_on:
  - todo:2026-04-30-shipped
---
EOF
  mk_todo "$repo" pending 2026-05-07-flying <<'EOF'
---
created: 2026-05-07
title: Flying
---
EOF
  printf '{"status":"in-progress","workers":[{"phase":"implement","agent":"impl-a"}]}' >"$tasks/2026-05-07-flying.json"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "badges: exit 0" "$(rc)" "0"
  main=$(between "$f" '<main>' '</main>')
  assert_contains "badges: unknown priority is prio-other" "$main" '<span class="badge prio-other">medium</span>'
  assert_contains "badges: area" "$main" '<span class="badge area">store</span>'
  assert_contains "badges: due before today is overdue" "$main" '<span class="badge overdue">due 2026-05-01</span>'
  assert_contains "badges: due after today" "$main" '<span class="badge due">due 2026-06-01</span>'
  assert_contains "badges: high priority" "$main" '<span class="badge prio-high">high</span>'
  assert_contains "badges: future surface date" "$main" '<span class="badge surface">surfaces 2026-06-01</span>'
  assert_missing "badges: past surface date has no badge" "$main" 'surfaces 2026-05-01'
  assert_contains "badges: unmet dependencies" "$main" '<span class="badge blocked">blocked by 2</span>'
  assert_contains "badges: met dependencies" "$main" '<span class="badge deps-ok">1 deps met</span>'
  assert_contains "badges: in flight with phase" "$main" '<span class="badge in-flight">in flight - implement</span>'
  assert_contains "badges: high priority card edge" "$main" 'data-todo="2026-05-02-due" data-state="open" data-task-status="" data-priority="high">'
  assert_file_has "facts: todo dependency links to its modal" "$f" '<a href="#todo-2026-05-01-prio">todo:2026-05-01-prio (open)</a>'
  assert_file_has "facts: files listed" "$f" '<h3>Files</h3><ul><li class="mono">claude/x.py</li></ul>'
  assert_file_has "facts: static page shows the id" "$f" '<h3>Id</h3><div class="mono">2026-05-01-prio</div>'
  assert_file_has "facts: dates" "$f" '<h3>Dates</h3><ul><li>created 2026-05-01</li><li>due 2026-05-01</li></ul>'
  rm_fixture "$repo" "$sr"
}
test_badges_and_facts

test_bare_id_record() {
  local repo sr f slug tasks
  repo=$(mk_repo) || exit 2; sr=$(mk_dir) || exit 2; f="$repo/out/board.html"
  slug=$(core_slug git@github.com:Org/Repo.git); tasks="$sr/$slug/tasks"; mkdir -p "$tasks"
  mk_todo "$repo" pending 2026-05-01-bare <<'EOF'
---
created: 2026-05-01
title: Bare record
---
EOF
  mk_todo "$repo" pending 2026-05-02-both <<'EOF'
---
created: 2026-05-02
title: Both records
---
EOF
  mk_todo "$repo" pending 2026-05-03-ready <<'EOF'
---
created: 2026-05-03
title: Ready
---
EOF
  printf '{"status":"in-progress","workers":[{"phase":"plan","agent":"plan-a"}]}' >"$tasks/2026-05-01-bare.json"
  printf '{"status":"review-dispatched","workers":[{"phase":"review","agent":"rev-a"}]}' >"$tasks/2026-05-02-both.json"
  printf '{"status":"merged","workers":[{"phase":"review","agent":"rev-a"}]}' >"$tasks/td-2026-05-02-both.json"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "bare id: exit 0" "$(rc)" "0"
  assert_file_has "bare id: record read without the td- prefix" "$f" \
    'data-todo="2026-05-01-bare" data-state="open" data-task-status="in-progress"'
  assert_file_has "bare id: wins over a td- record" "$f" \
    'data-todo="2026-05-02-both" data-state="open" data-task-status="review-dispatched"'
  assert_file_has "bare id: both sort in flight" "$f" '<h2 data-bucket="in-flight">In flight <span class="bucket-count">2</span></h2>'
  assert_eq "bare id: in flight lane comes before ready" "$(python3 - "$f" <<'PY'
import sys
t = open(sys.argv[1]).read()
print(0 <= t.find('data-bucket="in-flight"') < t.find('data-bucket="ready"'))
PY
)" "True"
  rm_fixture "$repo" "$sr"
}
test_bare_id_record

test_theme_toggle_without_storage() {
  if ! command -v node >/dev/null 2>&1; then
    ok "theme toggle without storage: skipped, node not installed"
    return
  fi
  local out
  out=$(SCRIPTS="$HERE/.." python3 - <<'PY' | node - 2>&1
import json, os, sys
sys.path.insert(0, os.environ["SCRIPTS"])
import todos_dashboard as board
print("var BOARD_JS = " + json.dumps(board.BOARD_JS) + ";")
print(r"""
var attrs = {};
var toggle = { textContent: "" };
var listeners = [];
global.localStorage = {
  getItem: function () { throw new Error("blocked"); },
  setItem: function () { throw new Error("blocked"); },
};
global.document = {
  documentElement: {
    setAttribute: function (k, v) { attrs[k] = v; },
    removeAttribute: function (k) { delete attrs[k]; },
    getAttribute: function (k) { return k in attrs ? attrs[k] : null; },
  },
  querySelector: function (sel) { return sel === "button.theme" ? toggle : null; },
  addEventListener: function (type, fn) { if (type === "click") listeners.push(fn); },
  getElementById: function () { return null; },
};
global.location = { hash: "", pathname: "/", search: "", replace: function () {} };
global.history = { replaceState: function () {} };
global.window = global;
global.addEventListener = function () {};
global.navigator = {};
eval(BOARD_JS);
var click = { target: { closest: function (s) { return s === "button.theme" ? {} : null; } } };
var seen = [];
for (var i = 0; i < 3; i++) {
  listeners.forEach(function (fn) { fn(click); });
  seen.push(attrs["data-theme"] || "system");
}
console.log(seen.join(" "));
""")
PY
)
  assert_eq "theme toggle without storage: cycles light, dark, system" "$out" "light dark system"
}
test_theme_toggle_without_storage

rm -f "$RCF" "$ERRF"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
