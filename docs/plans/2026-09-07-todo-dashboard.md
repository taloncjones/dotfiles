# Todo Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `todos.sh dashboard`, which renders the repo's open todos (with resolved blocked-on state and herdr task status), recent completed todos, and an index of `.todos/research/` reports into one static HTML file under a machine-local state directory, plus a one-line orchestrator preflight step that regenerates it.

**Architecture:** `todos.sh` gains a two-line dispatch to a new stdlib-Python renderer, `todos_dashboard.py`, which parses todo frontmatter, calls the existing hidden `todos.sh` verbs (`_depends`, `_normalize_ref`, `_resolve`) for dependency state so there is one resolver, reads herdr task records read-only, and writes the page atomically. A new bash suite with a fixed fixture board covers every acceptance criterion; the todos skill doc gains the command and the research convention.

**Tech Stack:** bash (`todos.sh` dispatch, test suite in the repo's `ok`/`FAIL` style), Python 3 stdlib (`argparse`, `html`, `json`, `subprocess`, `pathlib`), markdown skill docs.

**Spec:** `docs/specs/2026-09-07-todo-dashboard.md`

**Status:** branch-only document; dropped before merge together with the spec. The task contract at `claude/contracts/td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc-contract.json` stays and is run by the orchestrator at completion.

## Global Constraints

- Files that may change or be created (spec Scope): `claude/skills/todos/scripts/todos.sh` (two added lines, none removed), `claude/skills/todos/scripts/todos_dashboard.py` (new), `claude/skills/todos/scripts/tests/todos_dashboard_test.sh` (new), `claude/skills/todos/SKILL.md`, `claude/skills/herdr-orchestration/SKILL.md` (exactly one added line, none removed), `bin/dotfiles-tests` (one `SUITES` line). The contract's `diff-scope`, `dispatch-thin`, and `orch-preflight-line` commands enforce this. `todos_test.sh` must not change.
- Command surface, verbatim (spec D1): `todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]`; env overrides `TODOS_DASHBOARD_DIR`, `TODOS_STATE_ROOT`, `TODOS_DASHBOARD_NOW`, `TODOS_DASHBOARD_TODOS_SH`; existing `TODOS_TODAY`, `TODOS_BASE_REF`, `TODOS_GH` pass through.
- Default output `${TODOS_DASHBOARD_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/dashboard}/<repo_slug>.html`; default state root `${TODOS_STATE_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/herdr-orch}`; task id `td-<todo basename>`.
- Never write under `.todos/` or the state root (guarded, exit 1); no `TODO.md` regeneration; no network unless `--online`; no JavaScript, no remote assets in the page.
- In-flight statuses, verbatim (spec D2): `kickoff`, `in-progress`, `blocked`, `review-dispatched`, `changes-requested`, `reviewed`.
- Design tokens verbatim from spec D5 (light `#f7f6f2 #1f2a24 #6b746e #2f6f5e #d9ddd7 #ebeae4`, semantic `#b3541e #3b6ea5 #8a6d1f`; dark `#171b19 #e8ece9 #9aa39d #7fbfa8 #2c332f #232927 #e0895a #7fa9d8 #d1b25a`).
- No emojis, no AI attribution, ASCII only in added lines, LF endings, `#!/usr/bin/env bash` for bash, stdlib-only Python. Commit format `<scope>: <summary>`, imperative, under 75 chars.
- Test baseline (spec, 2026-09-07 at `026f043`): `todos_test.sh` 162 passed, 0 failed. The new suite must report 0 failed with at least 85 checks (it reports 92 as written).
- Do not touch `.worktrees/claude-codex-parity`, `co-review`, the herdr brief template, or `claude/hooks/herdr_orch_core.py`.

## File Structure

| File | Responsibility |
|---|---|
| `claude/skills/todos/scripts/todos.sh` | Usage-comment line for `dashboard`; `main` case that execs the renderer. Nothing else. |
| `claude/skills/todos/scripts/todos_dashboard.py` | Argument parsing and path guard; repo slug; frontmatter and body parsing; `Resolver` (subprocess calls into `todos.sh`); herdr record reading with staleness rules; research index; HTML rendering with the D5 tokens; atomic write; optional open. |
| `claude/skills/todos/scripts/tests/todos_dashboard_test.sh` | Fixture board builder and thirteen test groups, one per acceptance area. |
| `claude/skills/todos/SKILL.md` | `dashboard` command row; new `## Dashboard` section; `## Research reports` convention section; `research/` line in the Layout block. |
| `claude/skills/herdr-orchestration/SKILL.md` | One bullet in section 1 preflight. |
| `bin/dotfiles-tests` | Register the suite. |
| `claude/contracts/td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc-contract.json` | Task contract (already committed with this plan). |

Task order: 1 wiring and the red suite, 2 the renderer (suite green), 3 docs and preflight line, 4 verification including the task contract.

## Acceptance criteria to contract mapping

Suite labels are the `ok   <label>` lines the contract's `dashboard-suite` command greps for.

| Spec AC | Contract command(s) |
|---|---|
| AC1 renders the fixture board | `dashboard-suite` (label `render: fixture board`), `render-smoke` |
| AC2 bad records do not abort | `dashboard-suite` (`render: fixture board`, checks `render: bad record unreadable`, `render: in-flight count`) |
| AC3 research index | `dashboard-suite` (`research: index`) |
| AC4 escaping | `dashboard-suite` (`render: fixture board`, checks `render: title escaped`, `render: no raw script tag`) |
| AC5 default path and slug | `dashboard-suite` (`slug: default path and repo slug`) |
| AC6 read-only | `dashboard-suite` (`read-only: state root and .todos untouched`), `render-smoke` (empty state root, no `TODO.md`) |
| AC7 empty board | `dashboard-suite` (`empty: board without .todos`) |
| AC8 flags | `dashboard-suite` (`flags: completed and usage errors`) |
| AC9 offline precedence | `dashboard-suite` (`offline: precedence`) |
| AC10 output guard | `dashboard-suite` (`guard: output path`) |
| AC11 failed write preserves the previous page | `dashboard-suite` (`write: failed write preserves the previous page`) |
| AC12 unreadable todo skipped | `dashboard-suite` (`unreadable: todo skipped`) |
| AC13 self, invalid, unreadable refs | `dashboard-suite` (`refs: self, invalid, and unreadable dependencies`) |
| AC14 dispatch is thin, `todos_test.sh` untouched and green | `dispatch-thin`, `todos-suite-baseline` |
| AC15 docs | `skill-doc-pins`, `orch-preflight-line` |
| AC16 registered suite | `suite-registered`, `dashboard-suite-size` |
| AC17 link boundaries | `dashboard-suite` (`links: boundaries`) |
| D3 visibility warning | `dashboard-suite` (`visibility: .todos exclusion warning`) |
| D4 no script, no remote asset | `render-smoke` |
| Scope, ASCII, attribution, syntax, stdlib-only | `diff-scope`, `ascii-added-lines`, `no-attribution-in-added-lines`, `syntax`, `stdlib-only` |
| D5 both colour schemes look right in a browser | human-verify (one look after Task 4) |
| D6 the orchestrator runs the preflight step | human-verify on the next orchestrated turn after merge |

---

### Task 1: Wire the dispatch, register the suite, and add the (red) suite

**Files:**
- Modify: `claude/skills/todos/scripts/todos.sh:23` (usage comment) and `:779` (the `path)` case in `main`)
- Modify: `bin/dotfiles-tests:41` (the `SUITES` block, after the `todos_test.sh` line)
- Create: `claude/skills/todos/scripts/tests/todos_dashboard_test.sh`

**Interfaces:**
- Produces: `todos.sh dashboard ARGS...` execs `python3 <script dir>/todos_dashboard.py ARGS...`; the suite expects `claude/hooks/herdr_orch_core.py` four directories up from the tests dir (`$HERE/../../../../hooks/`) and reads exit code and stderr of each render through two temp files (`rc`, `err`).

- [ ] **Step 1: Add the two lines to `todos.sh`**

After the usage-comment line

```
#   todos.sh path                       print the .todos/ directory path
```

add

```
#   todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]   render the HTML board
```

After the `main` case line

```
    path)     cmd_path "$@" ;;
```

add

```
    dashboard) exec python3 "$(dirname "${BASH_SOURCE[0]}")/todos_dashboard.py" "$@" ;;
```

Nothing else changes in the file. `git diff` must show `+2 -0`.

- [ ] **Step 2: Register the suite in `bin/dotfiles-tests`**

After the line `bash claude/skills/todos/scripts/tests/todos_test.sh` in the `SUITES` block add

```
bash claude/skills/todos/scripts/tests/todos_dashboard_test.sh
```

- [ ] **Step 3: Create the suite**

Write `claude/skills/todos/scripts/tests/todos_dashboard_test.sh` with exactly this content:

```bash
#!/usr/bin/env bash
# Test suite for `todos.sh dashboard` (todos_dashboard.py). Deterministic via
# TODOS_STATE_ROOT / TODOS_DASHBOARD_DIR / TODOS_DASHBOARD_NOW / TODOS_GH;
# never opens a browser or touches the network.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TODOS="$HERE/../todos.sh"
CORE="$HERE/../../../../hooks/herdr_orch_core.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "missing [$3]";; esac; }
assert_missing()  { case "$2" in *"$3"*) bad "$1" "found [$3]";; *) ok "$1";; esac; }
assert_file_has() { grep -qF -- "$3" "$2" && ok "$1" || bad "$1" "$2 missing [$3]"; }
assert_file_lacks() { grep -qF -- "$3" "$2" && bad "$1" "$2 has [$3]" || ok "$1"; }

canon_helper() { /usr/bin/env realpath "$1" 2>/dev/null || printf '%s' "$1"; }

# Throwaway repo: one commit, origin/main via update-ref (no network), an
# origin remote URL (never fetched), .todos/ excluded like `init` does.
mk_repo() {
  local d; d=$(mktemp -d); d=$(canon_helper "$d")
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m base \
    && git update-ref refs/remotes/origin/main HEAD \
    && git remote add origin git@github.com:Org/Repo.git \
    && printf '.todos/\n' >>.git/info/exclude ) >/dev/null 2>&1
  printf '%s' "$d"
}
mk_todo() { # mk_todo <repo> <pending|completed> <name>  (body on stdin)
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
# read them with `rc` and `err` after the capture.
RCF=$(mktemp); ERRF=$(mktemp)
render() {
  local repo="$1" sr="$2"; shift 2
  ( cd "$repo" && TODOS_STATE_ROOT="$sr" TODOS_DASHBOARD_NOW="2026-05-07 09:00" \
    TODOS_TODAY=2026-05-07 bash "$TODOS" dashboard "$@" 2>"$ERRF" )
  printf '%s' "$?" >"$RCF"
}
rc()  { cat "$RCF"; }
err() { cat "$ERRF"; }

# --- cases ---

test_render_fixture() {
  local repo sr f out
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; f="$repo/out/board.html"
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
  ok "render: fixture board"
  rm -rf "$repo" "$sr"
}
test_render_fixture

test_research_index() {
  local repo sr f
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; f="$repo/out/board.html"
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
  rm -rf "$repo" "$sr"
}
test_research_index

test_default_path_slug() {
  local repo sr out slug
  repo=$(mk_repo); sr=$(mktemp -d); slug=$(core_slug git@github.com:Org/Repo.git)
  out=$(TODOS_DASHBOARD_DIR="$repo/dash" render "$repo" "$sr")
  assert_eq "slug: default path matches core repo_slug" "$out" "$repo/dash/$slug.html"
  [ -f "$repo/dash/$slug.html" ] && ok "slug: file written" || bad "slug: file written" "missing"
  ( cd "$repo" && git remote remove origin ) >/dev/null 2>&1
  out=$(TODOS_DASHBOARD_DIR="$repo/dash" render "$repo" "$sr")
  case "$(basename "$out")" in local-*.html) ok "slug: no remote gives local-";; *) bad "slug: no remote gives local-" "$out";; esac
  ok "slug: default path and repo slug"
  rm -rf "$repo" "$sr"
}
test_default_path_slug

test_read_only() {
  local repo sr before after
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"
  before=$(cd "$sr" && find . -type f | sort | xargs shasum)
  render "$repo" "$sr" --out "$repo/out/board.html" >/dev/null
  after=$(cd "$sr" && find . -type f | sort | xargs shasum)
  assert_eq "read-only: state root untouched" "$after" "$before"
  [ -e "$repo/.todos/TODO.md" ] && bad "read-only: no TODO.md" "created" || ok "read-only: no TODO.md"
  ok "read-only: state root and .todos untouched"
  rm -rf "$repo" "$sr"
}
test_read_only

test_empty_board() {
  local repo sr f
  repo=$(mk_repo); sr=$(mktemp -d); f="$repo/out/board.html"
  render "$repo" "$sr" --out "$f" >/dev/null
  assert_eq "empty: exit 0" "$(rc)" "0"
  assert_file_has "empty: open" "$f" 'No open todos.'
  assert_file_has "empty: completed" "$f" 'Nothing completed yet.'
  assert_file_has "empty: research" "$f" 'No research reports.'
  ok "empty: board without .todos"
  rm -rf "$repo" "$sr"
}
test_empty_board

test_flags() {
  local repo sr f out
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; f="$repo/out/board.html"
  mk_todo "$repo" completed 2026-05-09-newer <<'EOF'
---
created: 2026-05-09
title: Newer completed
---
EOF
  render "$repo" "$sr" --out "$f" --completed 0 >/dev/null
  assert_file_lacks "flags: --completed 0 hides section" "$f" '<h2>Completed</h2>'
  render "$repo" "$sr" --out "$f" --completed 1 >/dev/null
  assert_eq "flags: --completed 1 shows one row" "$(grep -c 'data-todo="2026-05-0[39]-' "$f")" "1"
  assert_file_has "flags: --completed 1 keeps newest" "$f" 'data-todo="2026-05-09-newer"'
  out=$(render "$repo" "$sr" --out "$f" --completed -1)
  assert_eq "flags: negative completed exits 1" "$(rc)" "1"
  assert_eq "flags: negative completed prints nothing" "$out" ""
  assert_contains "flags: negative completed message" "$(err)" "todos: --completed"
  out=$(render "$repo" "$sr" --out "$f" --bogus)
  assert_eq "flags: unknown flag exits 1" "$(rc)" "1"
  assert_eq "flags: unknown flag prints nothing" "$out" ""
  assert_contains "flags: unknown flag message" "$(err)" "todos: "
  ok "flags: completed and usage errors"
  rm -rf "$repo" "$sr"
}
test_flags

test_offline_precedence() {
  local repo sr gh
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; gh="$repo/gh"; mk_gh_stub "$gh"
  TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/a.html" >/dev/null
  [ -e "$gh.calls" ] && bad "offline: default makes no gh call" "$(cat "$gh.calls")" || ok "offline: default makes no gh call"
  TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/b.html" --online >/dev/null
  [ -s "$gh.calls" ] && ok "offline: --online calls gh" || bad "offline: --online calls gh" "no calls"
  rm -f "$gh.calls"
  TODOS_OFFLINE=1 TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/c.html" --online >/dev/null
  [ -s "$gh.calls" ] && ok "offline: --online beats exported TODOS_OFFLINE" || bad "offline: --online beats exported TODOS_OFFLINE" "no calls"
  rm -f "$gh.calls"
  ( unset TODOS_OFFLINE; TODOS_GH="$gh" render "$repo" "$sr" --out "$repo/out/d.html" >/dev/null )
  [ -e "$gh.calls" ] && bad "offline: unset env still offline" "$(cat "$gh.calls")" || ok "offline: unset env still offline"
  ok "offline: precedence"
  rm -rf "$repo" "$sr"
}
test_offline_precedence

test_output_guard() {
  local repo sr slug out
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; slug=$(core_slug git@github.com:Org/Repo.git)
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
  rm -rf "$repo" "$sr"
}
test_output_guard

test_failed_write_preserves() {
  local repo sr f before after out
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; f="$repo/out/board.html"
  render "$repo" "$sr" --out "$f" >/dev/null
  before=$(shasum "$f")
  if [ "$(id -u)" = 0 ]; then
    ok "write: skipped as root"
  else
    chmod 555 "$repo/out"
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
  rm -rf "$repo" "$sr"
}
test_failed_write_preserves

test_unreadable_skipped() {
  local repo sr f
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"; f="$repo/out/board.html"
  if [ "$(id -u)" = 0 ]; then
    ok "unreadable: skipped as root"
  else
    chmod 000 "$repo/.todos/pending/2026-05-01-plain.md"
    render "$repo" "$sr" --out "$f" >/dev/null
    chmod 644 "$repo/.todos/pending/2026-05-01-plain.md"
    assert_eq "unreadable: exit 0" "$(rc)" "0"
    assert_contains "unreadable: warning" "$(err)" "skipping unreadable file"
    assert_file_lacks "unreadable: row omitted" "$f" 'data-todo="2026-05-01-plain"'
    assert_file_has "unreadable: other rows render" "$f" 'data-todo="2026-05-02-blocked"'
  fi
  ok "unreadable: todo skipped"
  rm -rf "$repo" "$sr"
}
test_unreadable_skipped

test_self_invalid_refs() {
  local repo sr f stub
  repo=$(mk_repo); sr=$(mktemp -d); f="$repo/out/board.html"
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
  rm -rf "$repo" "$sr"
}
test_self_invalid_refs

test_link_boundaries() {
  local repo sr f
  repo=$(mk_repo); sr=$(mktemp -d); f="$repo/out/board.html"
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
  rm -rf "$repo" "$sr"
}
test_link_boundaries

test_visibility_warning() {
  local repo sr
  repo=$(mk_repo); sr=$(mktemp -d); mk_board "$repo" "$sr"
  render "$repo" "$sr" --out "$repo/out/a.html" >/dev/null
  assert_missing "visibility: excluded repo is quiet" "$(err)" "neither git-ignored nor tracked"
  : >"$repo/.git/info/exclude"
  render "$repo" "$sr" --out "$repo/out/b.html" >/dev/null
  assert_eq "visibility: still exit 0" "$(rc)" "0"
  assert_contains "visibility: warns when not ignored" "$(err)" "neither git-ignored nor tracked"
  ok "visibility: .todos exclusion warning"
  rm -rf "$repo" "$sr"
}
test_visibility_warning

rm -f "$RCF" "$ERRF"
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

Then `chmod +x claude/skills/todos/scripts/tests/todos_dashboard_test.sh`.

- [ ] **Step 4: Run the suite to see it fail**

Run: `bash claude/skills/todos/scripts/tests/todos_dashboard_test.sh 2>&1 | tail -3`
Expected: many `FAIL` lines (the renderer does not exist yet, so every render exits non-zero and no HTML is written) and a last line of the form `N passed, M failed` with `M > 0`; exit code 1.

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | tail -1`
Expected: `162 passed, 0 failed` (the dispatch lines change nothing for existing verbs).

- [ ] **Step 5: Commit**

```bash
git add claude/skills/todos/scripts/todos.sh bin/dotfiles-tests claude/skills/todos/scripts/tests/todos_dashboard_test.sh
git commit -m "todos: Wire the dashboard dispatch and add its test suite"
```

---

### Task 2: The renderer

**Files:**
- Create: `claude/skills/todos/scripts/todos_dashboard.py`
- Test: `claude/skills/todos/scripts/tests/todos_dashboard_test.sh` (from Task 1)

**Interfaces:**
- Consumes: `todos.sh _depends <file>`, `todos.sh _normalize_ref <input>`, `todos.sh _resolve <ref>` (existing hidden verbs, cwd at the repo root, `TODOS_OFFLINE=1` in the child env unless `--online`).
- Produces: the module functions `repo_slug(remote_url, common_dir=None) -> str`, `frontmatter(text) -> (scalars: dict, lists: dict, body: str)`, `problem_summary(body) -> str`, `body_links(body) -> list[(label, url)]`, `class Resolver(root, online)` with `resolve_all(path, basename) -> list[(ref, state)]`, `herdr_status(tasks_dir, basename) -> dict | None`, `load_todo(...)`, `load_research(...)`, `render_page(...)`, and `main(argv=None) -> int`. On success stdout is the absolute output path only.

- [ ] **Step 1: Write the renderer**

Write `claude/skills/todos/scripts/todos_dashboard.py` with exactly this content (the file is the spec's D1-D5 made concrete; the docstrings name the spec rule each part implements):

```python
#!/usr/bin/env python3
"""todos_dashboard.py - render this repo's todo board to one HTML file.

Invoked as `todos.sh dashboard [--open] [--online] [--out PATH]
[--completed N]`; see claude/skills/todos/SKILL.md ("Dashboard").

Reads, never writes: .todos/{pending,completed,research}/ and the herdr
task records under TODOS_STATE_ROOT (default
${CLAUDE_CONFIG_DIR:-~/.claude}/herdr-orch). Dependency state comes from
todos.sh's own resolver (`_depends` / `_normalize_ref` / `_resolve`), so
there is one resolver. The only write is the output file, default
${TODOS_DASHBOARD_DIR:-${XDG_STATE_HOME:-~/.local/state}/dotfiles/dashboard}/<repo_slug>.html,
written to a sibling temp file and renamed into place.
"""
import argparse
import datetime
import hashlib
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
TODOS_SH = Path(os.environ.get("TODOS_DASHBOARD_TODOS_SH") or HERE / "todos.sh")
TODOS_DIRNAME = ".todos"
SUMMARY_LEN = 140
RESEARCH_SUMMARY_LEN = 200
MAX_LINKS = 5
DEFAULT_COMPLETED = 10
SATISFIED = ("done", "merged")
IN_FLIGHT_STATUSES = ("kickoff", "in-progress", "blocked", "review-dispatched",
                      "changes-requested", "reviewed")
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"']+")
PR_URL_RE = re.compile(r"^https?://github\.com/[^/]+/[^/]+/pull/(\d+)")
ARTIFACT_URL_RE = re.compile(r"^https?://claude\.ai/(code/)?artifacts/")
PRIORITY_WEIGHT = {"high": "0", "med": "1", "low": "2"}


def die(msg):
    print(f"todos: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"todos: {msg}", file=sys.stderr)


def esc(s):
    return html.escape(str(s), quote=True)


def safe_href(url):
    """Only http(s) URLs become links; anything else renders as text."""
    return url if re.match(r"^https?://", url) else ""


def git(args, cwd=None):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    return r.returncode, r.stdout.strip()


def repo_slug(remote_url, common_dir=None):
    # Mirrors herdr_orch_core.repo_slug (pinned by the dashboard test suite).
    if remote_url:
        u = remote_url.strip()
        u = re.sub(r"\.git\Z", "", u)
        u = re.sub(r"\A[a-z]+://", "", u)
        u = re.sub(r"\A[^@]+@", "", u)
        norm = re.sub(r"[^a-z0-9]+", "-", u.lower()).strip("-")
        h = hashlib.sha256(remote_url.strip().encode()).hexdigest()[:8]
        return f"{norm}-{h}"
    h = hashlib.sha256(str(Path(common_dir).resolve()).encode()).hexdigest()[:8]
    return f"local-{h}"


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def frontmatter(text):
    """Return (scalars, lists, body). Reads only the first --- block.

    scalars: first `key: value` per key, quotes stripped (frontmatter_value).
    lists: `key:` followed by `  - item` lines (depends_list / files).
    """
    lines = text.split("\n")
    scalars, lists, body_start = {}, {}, 0
    if lines and lines[0].strip() == "---":
        current = None
        i = 1
        while i < len(lines):
            line = lines[i]
            if line.strip() == "---":
                body_start = i + 1
                break
            if line.startswith("  - ") and current is not None:
                lists.setdefault(current, []).append(unquote(line[4:]))
            else:
                current = None
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$", line)
                if m:
                    key, val = m.group(1), m.group(2)
                    if val == "":
                        current = key
                        lists.setdefault(key, [])
                    else:
                        scalars.setdefault(key, unquote(val))
            i += 1
        else:
            body_start = len(lines)
    return scalars, lists, "\n".join(lines[body_start:])


def problem_summary(body):
    in_problem = False
    for line in body.split("\n"):
        if line.startswith("## Problem"):
            in_problem = True
            continue
        if in_problem and line.startswith("## "):
            return ""
        if in_problem and line.strip():
            return line.strip()[:SUMMARY_LEN]
    return ""


def first_body_line(body):
    for line in body.split("\n"):
        if line.strip():
            return line.strip()[:RESEARCH_SUMMARY_LEN]
    return ""


def body_links(body):
    seen, out = set(), []
    for m in URL_RE.finditer(body):
        url = m.group(0).rstrip(".,;")
        if url in seen:
            continue
        seen.add(url)
        pr = PR_URL_RE.match(url)
        if pr:
            label = f"PR #{pr.group(1)}"
        elif ARTIFACT_URL_RE.match(url):
            label = "artifact"
        else:
            label = re.sub(r"^https?://", "", url).split("/")[0]
        out.append((label, url))
        if len(out) >= MAX_LINKS:
            break
    return out


class Resolver:
    """One todos.sh call per distinct ref, results memoised for the run.

    Offline by default (TODOS_OFFLINE=1 in the child env); --online removes
    TODOS_OFFLINE from the child env even when the caller exported it.
    """

    def __init__(self, root, online):
        self.root = root
        self.env = dict(os.environ)
        if online:
            self.env.pop("TODOS_OFFLINE", None)
        else:
            self.env["TODOS_OFFLINE"] = "1"
        self.norm_cache, self.state_cache = {}, {}

    def _call(self, verb, arg):
        try:
            r = subprocess.run(["bash", str(TODOS_SH), verb, arg], cwd=self.root,
                               env=self.env, capture_output=True, text=True)
        except OSError:
            return 1, ""
        return r.returncode, r.stdout.strip()

    def depends(self, path):
        """-> (items, ok). ok is False when _depends itself failed."""
        rc, out = self._call("_depends", str(path))
        if rc != 0:
            return [], False
        return [l for l in out.split("\n") if l.strip()], True

    def normalize(self, raw):
        if raw not in self.norm_cache:
            rc, out = self._call("_normalize_ref", raw)
            self.norm_cache[raw] = out if rc == 0 and out else None
        return self.norm_cache[raw]

    def state(self, ref):
        if ref not in self.state_cache:
            rc, out = self._call("_resolve", ref)
            self.state_cache[ref] = out if rc == 0 and out else "unknown"
        return self.state_cache[ref]

    def resolve_all(self, path, basename):
        """-> list of (ref_text, state) in file order."""
        items, ok = self.depends(path)
        if not ok:
            return [("depends_on", "unreadable")]
        out = []
        for raw in items:
            ref = self.normalize(raw)
            if ref is None:
                out.append((raw, "invalid"))
            elif ref == f"todo:{basename}":
                out.append((ref, "self"))
            else:
                out.append((ref, self.state(ref)))
        return out


def read_json(path):
    """-> (dict|None, unreadable: bool). Missing file is (None, False)."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return None, False
    except (OSError, ValueError, UnicodeDecodeError):
        return None, True
    if not isinstance(data, dict):
        return None, True
    return data, False


def field(d, key):
    """String value of d[key] when it is a str or int; blank otherwise."""
    v = d.get(key)
    if isinstance(v, bool):
        return ""
    if isinstance(v, (str, int)):
        return str(v)
    return ""


def herdr_status(tasks_dir, basename):
    """Read-only view of tasks/td-<basename>.{json,review.json,done.json}.

    The task record is authoritative for status and the live worker. The
    review record is shown as-is only when its reviewed_head_sha equals the
    record's review_head_sha, else tagged stale; the done record only when
    its phase and agent both equal the live worker's (herdr reuses one
    workspace across phases, so workspace_id proves nothing), else stale.
    """
    task_id = f"td-{basename}"
    rec, bad = read_json(tasks_dir / f"{task_id}.json")
    if rec is None and not bad:
        return None
    st = {"task_id": task_id, "status": "", "phase": "", "role": "", "model": "",
          "agent": "", "workspace_id": "", "branch": "", "review_head_sha": "",
          "review_outcome": "", "review": "", "review_stale": False,
          "blocking_count": "", "findings_ref": "", "done_outcome": "",
          "done_phase": "", "done_stale": False, "unreadable": bad}
    if rec is not None:
        for k in ("status", "branch", "review_head_sha", "review_outcome"):
            st[k] = field(rec, k)
        workers = rec.get("workers")
        if isinstance(workers, list) and workers and isinstance(workers[-1], dict):
            w = workers[-1]
            for k in ("phase", "role", "model", "agent", "workspace_id"):
                st[k] = field(w, k)
    else:
        st["status"] = "unreadable"
    rev, bad = read_json(tasks_dir / f"{task_id}.review.json")
    if rev is not None:
        st["review"] = field(rev, "outcome")
        st["blocking_count"] = field(rev, "blocking_count")
        st["findings_ref"] = field(rev, "findings_ref")
        st["review_stale"] = not st["review_head_sha"] or field(rev, "reviewed_head_sha") != st["review_head_sha"]
    elif bad:
        st["review"] = "unreadable"
    done, bad = read_json(tasks_dir / f"{task_id}.done.json")
    if done is not None:
        st["done_outcome"] = field(done, "outcome")
        st["done_phase"] = field(done, "phase")
        st["done_stale"] = not (st["phase"] and st["agent"]
                                and field(done, "phase") == st["phase"]
                                and field(done, "agent") == st["agent"])
    elif bad:
        st["done_outcome"] = "unreadable"
    return st


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        warn(f"skipping unreadable file: {path} ({e.strerror})")
        return None


def load_todo(path, resolver, tasks_dir, pending):
    text = read_text(path)
    if text is None:
        return None
    scalars, lists, body = frontmatter(text)
    basename = path.stem
    t = {
        "basename": basename,
        "path": path,
        "title": scalars.get("title") or basename,
        "created": scalars.get("created", ""),
        "area": scalars.get("area", ""),
        "priority": scalars.get("priority", ""),
        "due": scalars.get("due", ""),
        "surface": scalars.get("surface", ""),
        "maturity": scalars.get("maturity", ""),
        "tier": scalars.get("tier", ""),
        "files": lists.get("files", []),
        "summary": problem_summary(body),
        "links": body_links(body),
        "deps": resolver.resolve_all(path, basename) if pending else [],
        "herdr": herdr_status(tasks_dir, basename),
    }
    t["blocked"] = any(state not in SATISFIED for _, state in t["deps"])
    h = t["herdr"]
    t["in_flight"] = bool(pending and h and h["status"] in IN_FLIGHT_STATUSES)
    return t


def load_dir(d, resolver, tasks_dir, pending):
    if not d.is_dir():
        return []
    out = []
    for p in sorted(d.glob("*.md")):
        t = load_todo(p, resolver, tasks_dir, pending)
        if t is not None:
            out.append(t)
    return out


def open_sort_key(t):
    pw = PRIORITY_WEIGHT.get(t["priority"], "3")
    if t["due"]:
        return ("0" + t["due"] + pw, t["basename"])
    return ("1" + pw + (t["created"] or "9999-99-99"), t["basename"])


def load_research(research_dir, known_basenames):
    entries = []
    if not research_dir.is_dir():
        return entries
    for p in sorted(research_dir.rglob("*.md")):
        text = read_text(p)
        if text is None:
            continue
        scalars, _, body = frontmatter(text)
        task = scalars.get("task", "")
        task_base = task[3:] if task.startswith("td-") else task
        entries.append({
            "rel": p.relative_to(research_dir).as_posix(),
            "path": p,
            "title": scalars.get("title") or p.name,
            "created": scalars.get("created", ""),
            "kind": scalars.get("kind", ""),
            "task": task,
            "task_anchor": task_base if task_base in known_basenames else "",
            "artifact": scalars.get("artifact", ""),
            "summary": first_body_line(body),
        })
    dated = [e for e in entries if e["created"]]
    undated = [e for e in entries if not e["created"]]
    dated.sort(key=lambda e: e["rel"])
    dated.sort(key=lambda e: e["created"], reverse=True)
    undated.sort(key=lambda e: e["rel"])
    return dated + undated


# --- rendering -------------------------------------------------------------

CSS = """
:root {
  --ground: #f7f6f2; --ink: #1f2a24; --muted: #6b746e; --accent: #2f6f5e;
  --rule: #d9ddd7; --blocked: #b3541e; --merged: #3b6ea5; --inflight: #8a6d1f;
  --chip: #ebeae4;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --ground: #171b19; --ink: #e8ece9; --muted: #9aa39d; --accent: #7fbfa8;
    --rule: #2c332f; --blocked: #e0895a; --merged: #7fa9d8; --inflight: #d1b25a;
    --chip: #232927;
  }
}
:root[data-theme="dark"] {
  --ground: #171b19; --ink: #e8ece9; --muted: #9aa39d; --accent: #7fbfa8;
  --rule: #2c332f; --blocked: #e0895a; --merged: #7fa9d8; --inflight: #d1b25a;
  --chip: #232927;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--ground); color: var(--ink);
  font: 15px/1.45 "Avenir Next", "Segoe UI", system-ui, sans-serif; }
main { max-width: 1200px; margin: 0 auto; padding: 32px 24px 64px; }
h1 { font-size: 26px; font-weight: 600; margin: 0 0 4px; text-wrap: balance; }
h2 { font-size: 13px; font-weight: 600; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--muted); margin: 40px 0 12px; }
.meta { color: var(--muted); font-variant-numeric: tabular-nums; }
.counts { display: flex; gap: 32px; margin: 16px 0 0; }
.counts b { font-size: 28px; font-weight: 600; font-variant-numeric: tabular-nums; }
.counts span { display: block; color: var(--muted); font-size: 13px;
  letter-spacing: 0.06em; text-transform: uppercase; }
.wrap { overflow-x: auto; }
table { border-collapse: collapse; width: 100%; }
th { text-align: left; font-size: 12px; letter-spacing: 0.06em; text-transform: uppercase;
  color: var(--muted); font-weight: 600; padding: 8px 12px; border-bottom: 1px solid var(--rule); }
td { padding: 10px 12px; border-bottom: 1px solid var(--rule); vertical-align: top; }
tr[data-state="blocked"] td:first-child { box-shadow: inset 3px 0 0 var(--blocked); }
.name { font-weight: 600; }
.mono { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 12.5px; }
.sub { color: var(--muted); font-size: 12.5px; }
.chips { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
.chip { display: inline-block; border-radius: 999px; padding: 1px 8px; font-size: 12px;
  background: var(--chip); color: var(--ink); }
.chip.prio-high { background: var(--blocked); color: var(--ground); }
.pill { display: inline-block; border-radius: 999px; padding: 1px 8px; font-size: 12px;
  font-weight: 600; color: var(--ground); background: var(--muted); }
.pill.merged { background: var(--merged); }
.pill.in-flight { background: var(--inflight); }
.pill.unreadable { background: var(--blocked); }
.dep { display: block; white-space: nowrap; }
.dep.ok { color: var(--muted); }
.dep.bad { color: var(--blocked); }
.dates { font-variant-numeric: tabular-nums; white-space: nowrap; }
a { color: var(--accent); }
a:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
.empty { color: var(--muted); font-style: italic; }
ul.research { list-style: none; padding: 0; margin: 0; }
ul.research li { padding: 12px 0; border-bottom: 1px solid var(--rule); }
"""


def chip(text, cls=""):
    return f'<span class="chip {cls}">{esc(text)}</span>' if text else ""


def render_herdr(h):
    if h is None:
        return ""
    status = h["status"]
    if status == "merged":
        cls = "merged"
    elif status == "unreadable":
        cls = "unreadable"
    elif status in IN_FLIGHT_STATUSES:
        cls = "in-flight"
    else:
        cls = "other"
    parts = [f'<span class="pill {cls}">{esc(status or "recorded")}</span>']
    line = " ".join(x for x in (h["phase"], h["role"], h["model"]) if x)
    if line:
        parts.append(f'<div class="sub">{esc(line)}</div>')
    if h["review"]:
        bc = f" ({esc(h['blocking_count'])} blocking)" if h["blocking_count"] != "" else ""
        stale = " (stale)" if h["review_stale"] and h["review"] != "unreadable" else ""
        parts.append(f'<div class="sub">review {esc(h["review"])}{bc}{stale}</div>')
    elif h["review_outcome"]:
        parts.append(f'<div class="sub">review {esc(h["review_outcome"])}</div>')
    if h["done_outcome"]:
        stale = " (stale)" if h["done_stale"] and h["done_outcome"] != "unreadable" else ""
        parts.append(f'<div class="sub">done {esc(h["done_outcome"])} {esc(h["done_phase"])}{stale}</div>')
    return "".join(parts)


def render_links(links):
    return " ".join(f'<a href="{esc(u)}">{esc(label)}</a>' for label, u in links)


def render_todo_cell(t):
    chips = [chip(t["area"]), chip(t["priority"], f"prio-{t['priority']}"),
             chip(t["maturity"]), chip(t["tier"])]
    chips = "".join(c for c in chips if c)
    out = [f'<div class="name">{esc(t["title"])}</div>',
           f'<div class="sub mono">{esc(t["basename"])}</div>']
    if t["summary"]:
        out.append(f'<div class="sub">{esc(t["summary"])}</div>')
    if chips:
        out.append(f'<div class="chips">{chips}</div>')
    return "".join(out)


def render_open(todos):
    if not todos:
        return '<p class="empty">No open todos.</p>'
    rows = []
    for t in todos:
        state = "blocked" if t["blocked"] else "open"
        status = t["herdr"]["status"] if t["herdr"] else ""
        deps = "".join(
            f'<span class="dep {"ok" if s in SATISFIED else "bad"} mono">{esc(r)} ({esc(s)})</span>'
            for r, s in t["deps"])
        dates = esc(t["created"]) + (f'<br>due {esc(t["due"])}' if t["due"] else "")
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-state="{state}" data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{dates}</td>'
            f'<td>{deps}</td><td>{render_herdr(t["herdr"])}</td>'
            f'<td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created / due</th>'
            '<th>Depends on</th><th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_completed(todos):
    if not todos:
        return '<p class="empty">Nothing completed yet.</p>'
    rows = []
    for t in todos:
        status = t["herdr"]["status"] if t["herdr"] else ""
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{esc(t["created"])}</td>'
            f'<td>{render_herdr(t["herdr"])}</td><td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created</th>'
            '<th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_research(entries):
    if not entries:
        return ('<p class="empty">No research reports. Save durable notes under '
                '.todos/research/ (see the todos skill).</p>')
    items = []
    for e in entries:
        bits = [f'<a href="{esc(e["path"].as_uri())}" class="name">{esc(e["title"])}</a>',
                f'<span class="meta"> {esc(e["created"] or "undated")}</span>']
        if e["kind"]:
            bits.append(" " + chip(e["kind"]))
        if e["task_anchor"]:
            bits.append(f' <a href="#todo-{esc(e["task_anchor"])}" class="mono">{esc(e["task"])}</a>')
        elif e["task"]:
            bits.append(f' <span class="mono">{esc(e["task"])}</span>')
        if e["artifact"]:
            href = safe_href(e["artifact"])
            if href:
                bits.append(f' <a href="{esc(href)}">artifact</a>')
            else:
                bits.append(f' <span class="sub">artifact: {esc(e["artifact"])}</span>')
        if e["summary"]:
            bits.append(f'<div class="sub">{esc(e["summary"])}</div>')
        items.append(f'<li data-research="{esc(e["rel"])}">{"".join(bits)}</li>')
    return '<ul class="research">' + "".join(items) + "</ul>"


def render_page(repo_name, branch, stamp, open_todos, completed, research, show_completed):
    n_open = len(open_todos)
    n_blocked = sum(1 for t in open_todos if t["blocked"])
    n_flight = sum(1 for t in open_todos if t["in_flight"])
    completed_html = ""
    if show_completed:
        completed_html = "<h2>Completed</h2>" + render_completed(completed)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(repo_name)} board</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>{esc(repo_name)} board</h1>
<div class="meta">generated {esc(stamp)} on <span class="mono">{esc(branch)}</span>.
Static page: rerun <span class="mono">todos.sh dashboard</span> and reload to refresh.</div>
<div class="counts">
<div><b data-count="open">{n_open}</b><span>open</span></div>
<div><b data-count="blocked">{n_blocked}</b><span>blocked</span></div>
<div><b data-count="in-flight">{n_flight}</b><span>in-flight</span></div>
</div>
<h2>Open</h2>
{render_open(open_todos)}
{completed_html}
<h2>Research</h2>
{render_research(research)}
</main>
</body>
</html>
"""


# --- main -------------------------------------------------------------------

def default_out_dir():
    d = os.environ.get("TODOS_DASHBOARD_DIR")
    if d:
        return Path(d)
    state = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(state) / "dotfiles" / "dashboard"


def default_state_root():
    d = os.environ.get("TODOS_STATE_ROOT")
    if d:
        return Path(d)
    cfg = os.environ.get("CLAUDE_CONFIG_DIR") or str(Path.home() / ".claude")
    return Path(cfg) / "herdr-orch"


def is_within(path, parent):
    """True when the real path of `path` is `parent` or inside it."""
    try:
        Path(os.path.realpath(path)).relative_to(Path(os.path.realpath(parent)))
        return True
    except ValueError:
        return False


def guard_out_path(out, protected):
    """Refuse to write under .todos/ or the state root, through symlinks too."""
    probe = out if out.exists() else out.parent
    for label, p in protected:
        if is_within(probe, p):
            die(f"refusing to write the dashboard under {label}: {out}")


def open_file(path):
    opener = "open" if sys.platform == "darwin" else "xdg-open"
    try:
        subprocess.Popen([opener, str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        warn(f"cannot open {path}: {opener} not available")


USAGE = "usage: todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]"


class Parser(argparse.ArgumentParser):
    def error(self, message):
        die(f"{message} ({USAGE})")


def parse_args(argv):
    p = Parser(prog="todos.sh dashboard", add_help=True)
    p.add_argument("--open", action="store_true")
    p.add_argument("--online", action="store_true")
    p.add_argument("--out")
    p.add_argument("--completed", type=int, default=DEFAULT_COMPLETED)
    args = p.parse_args(argv)
    if args.completed < 0:
        die("--completed needs a non-negative integer")
    return args


def visibility_warning(root):
    """Warn when .todos/ is neither git-ignored nor tracked (research would commit)."""
    rc, _ = git(["check-ignore", "-q", TODOS_DIRNAME], cwd=root)
    if rc == 0:
        return
    rc, out = git(["ls-files", "--", TODOS_DIRNAME], cwd=root)
    if rc == 0 and out:
        return
    warn(f"{TODOS_DIRNAME}/ is neither git-ignored nor tracked; run `todos.sh init` "
         "before saving research there")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    rc, root = git(["rev-parse", "--show-toplevel"])
    if rc != 0 or not root:
        die("not inside a git repository")
    root = Path(root)
    rc, remote = git(["remote", "get-url", "origin"], cwd=root)
    if rc != 0:
        remote = ""
    _, common = git(["rev-parse", "--git-common-dir"], cwd=root)
    slug = repo_slug(remote, common_dir=root / common if common else root)
    _, branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root)

    todos_dir = root / TODOS_DIRNAME
    state_root = default_state_root()
    tasks_dir = state_root / slug / "tasks"
    out = Path(args.out) if args.out else default_out_dir() / f"{slug}.html"
    out = out if out.is_absolute() else Path.cwd() / out
    guard_out_path(out, [(f"{TODOS_DIRNAME}/", todos_dir), ("the herdr state root", state_root)])

    if todos_dir.is_dir():
        visibility_warning(root)
    resolver = Resolver(root, args.online)
    pending = load_dir(todos_dir / "pending", resolver, tasks_dir, True)
    completed = load_dir(todos_dir / "completed", resolver, tasks_dir, False)
    pending.sort(key=open_sort_key)
    completed.sort(key=lambda t: (t["created"], t["basename"]), reverse=True)
    completed = completed[:args.completed]
    known = {t["basename"] for t in pending} | {t["basename"] for t in completed}
    research = load_research(todos_dir / "research", known)

    stamp = os.environ.get("TODOS_DASHBOARD_NOW") or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    page = render_page(root.name, branch, stamp, pending, completed, research, args.completed > 0)

    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        tmp = out.with_name(out.name + f".tmp.{os.getpid()}")
        tmp.write_text(page, encoding="utf-8")
        os.replace(tmp, out)
    except OSError as e:
        die(f"cannot write {out}: {e.strerror or e}")
    print(out)
    if args.open:
        open_file(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

Then `chmod +x claude/skills/todos/scripts/todos_dashboard.py`.

- [ ] **Step 2: Run the suite to see it pass**

Run: `bash claude/skills/todos/scripts/tests/todos_dashboard_test.sh 2>&1 | grep -v '^  ok'`
Expected: only the summary line `92 passed, 0 failed`; exit code 0.

If any check fails, fix the renderer, not the test: the test encodes the spec's acceptance strings verbatim.

- [ ] **Step 3: Confirm the invariants the contract checks**

Run: `python3 -m py_compile claude/skills/todos/scripts/todos_dashboard.py && bash -n claude/skills/todos/scripts/todos.sh && echo syntax-ok`
Expected: `syntax-ok`.

Run: `base=$(git merge-base origin/main HEAD); git diff "$base" --stat -- claude/skills/todos/scripts/todos.sh claude/skills/todos/scripts/tests/todos_test.sh`
Expected: `todos.sh | 2 +` and no line for `todos_test.sh`.

- [ ] **Step 4: One look at the page**

Run: `bash claude/skills/todos/scripts/todos.sh dashboard --open` from the worktree (this renders the real `.todos/` board to the default path and opens it). Look once in the browser, in both light and dark mode if the OS toggle is handy; expected: the header counts, the Open table with blocked rows striped, the Completed table, and the Research section (empty-state text unless `.todos/research/` exists). Do not iterate on visuals beyond a real defect (clipped column, unreadable text). Note in the commit message if anything was fixed from this look.

- [ ] **Step 5: Commit**

```bash
git add claude/skills/todos/scripts/todos_dashboard.py
git commit -m "todos: Add the dashboard renderer"
```

---

### Task 3: Documentation and the orchestrator preflight line

**Files:**
- Modify: `claude/skills/todos/SKILL.md` (Layout block near line 18, Commands table near line 90, new sections before `## Workflow` near line 144)
- Modify: `claude/skills/herdr-orchestration/SKILL.md` (section 1, step 3's bullet list, immediately before the line beginning `4. Load and validate`)

**Interfaces:**
- Produces: the doc strings the contract's `skill-doc-pins` command greps for: `todos.sh dashboard`, `--completed`, `.todos/research/`, `kind:`, `artifact:`, `task:`, `TODOS_DASHBOARD_DIR`, `TODOS_STATE_ROOT`, `todos.sh init`, `review-findings`.

- [ ] **Step 1: Update the Layout block in the todos skill**

Replace

```
<repo>/.todos/
  pending/     YYYY-MM-DD-<slug>.md    open items
  completed/   YYYY-MM-DD-<slug>.md    finished items
  TODO.md                             auto-generated index of pending/
```

with

```
<repo>/.todos/
  pending/     YYYY-MM-DD-<slug>.md    open items
  completed/   YYYY-MM-DD-<slug>.md    finished items
  research/    YYYY-MM-DD-<slug>.md    durable research reports (see "Research reports")
               <task_id>/*.md          per-task material (review findings)
  TODO.md                             auto-generated index of pending/
```

- [ ] **Step 2: Add the command row**

After the `todos.sh path` row in the Commands table add

```
| `todos.sh dashboard [--open] [--online] [--out PATH] [--completed N]`  | Render the HTML board (open todos, blocked-on state, herdr status, completed, research) to a machine-local file |
```

- [ ] **Step 3: Add the Dashboard and Research sections**

Insert before `## Workflow`:

```markdown
## Dashboard

`todos.sh dashboard` renders the whole board for the current repo into
one static HTML file and prints its path:
`${TODOS_DASHBOARD_DIR:-${XDG_STATE_HOME:-~/.local/state}/dotfiles/dashboard}/<repo_slug>.html`
(`<repo_slug>` is the herdr repo slug, so every worktree of a repo
shares one page). `--open` opens it (`open` on macOS, `xdg-open`
elsewhere); `--out PATH` writes elsewhere; `--completed N` sets how many
completed todos to show (default 10, 0 hides the section).

The page is inert: no script, no remote assets, no server. Regenerate
and reload the tab to refresh. For live refresh on a machine with
`fswatch`: `herdr pane run <pane> "fswatch -o .todos | xargs -n1 -I{} ~/.claude/skills/todos/scripts/todos.sh dashboard"`.

What each row shows:

- **Depends on**: every `depends_on` ref with its state, resolved by the
  same resolver as `list`. Offline by default (like `index`); `--online`
  lets it call `gh` and overrides an exported `TODOS_OFFLINE`.
- **Herdr**: the task record under
  `${TODOS_STATE_ROOT:-${CLAUDE_CONFIG_DIR:-~/.claude}/herdr-orch}/<repo_slug>/tasks/td-<basename>.json`
  when one exists: status pill, `phase role model`, the review verdict
  (tagged `(stale)` unless its `reviewed_head_sha` matches the record),
  and the done record (tagged `(stale)` unless its phase and agent match
  the live worker). Records are read only, never written. An unreadable
  record shows `unreadable`.
- **Links**: `http(s)` URLs from the body, GitHub PRs as `PR #n`,
  `claude.ai` artifacts as `artifact`.

The renderer never writes under `.todos/` or the state root (it refuses
such an output path), never regenerates `TODO.md`, and writes the page
atomically so a half-written file is never seen.

## Research reports

`.todos/research/` holds durable research the board should keep:
orchestrator field notes, studies, decision memos, and (future, written
by `post-merge`) per-task review findings under
`research/<task_id>/review-findings.md`. The dashboard indexes every
`*.md` under it, newest `created` first.

```markdown
---
created: 2026-09-06
title: Orchestrator field notes, 2026-09-06
kind: field-notes
task: 2026-09-06-render-a-local-dashboard-of-open-todos-and-researc
artifact: https://claude.ai/code/artifacts/...
---

One-paragraph summary, then the report body.
```

`created` and `title` are expected; `kind` (free text such as
`field-notes`, `review-findings`, `report`), `task` (a task id or todo
basename; links to that row when it is on the page), and `artifact`
(an `http(s)` URL; anything else is shown as text, never linked) are
optional. The first body line is the summary.

Visibility follows `.todos/`: it is git-ignored only after `todos.sh init`
(or the first `new`) has written the exclude line, so run `todos.sh init`
before saving research in a repo that has never used todos. The
dashboard warns when `.todos/` is neither ignored nor tracked. A repo
where `todos.sh share` was run commits research with the backlog.
```

- [ ] **Step 4: Add the preflight line to the orchestration skill**

In `claude/skills/herdr-orchestration/SKILL.md` section 1, step 3 is a bullet list that ends just before the line starting `4. Load and validate`. Add this single line as the last bullet of that list (one physical line, indented like its siblings with three spaces then `- `):

```
   - Regenerate the board with `bash ~/.claude/skills/todos/scripts/todos.sh dashboard` (add `--open` on the initial claim only); best-effort, a non-zero exit is noted in the turn summary and never blocks the action.
```

`git diff` for that file must show exactly `+1 -0`.

- [ ] **Step 5: Verify the doc pins**

Run: `for s in 'todos.sh dashboard' '--completed' '.todos/research/' 'kind:' 'artifact:' 'task:' 'TODOS_DASHBOARD_DIR' 'TODOS_STATE_ROOT' 'todos.sh init' 'review-findings'; do grep -qF -- "$s" claude/skills/todos/SKILL.md || echo "missing $s"; done; echo pins-checked`
Expected: only `pins-checked`.

Run: `base=$(git merge-base origin/main HEAD); git diff "$base" --numstat -- claude/skills/herdr-orchestration/SKILL.md`
Expected: `1	0	claude/skills/herdr-orchestration/SKILL.md`.

- [ ] **Step 6: Commit**

```bash
git add claude/skills/todos/SKILL.md claude/skills/herdr-orchestration/SKILL.md
git commit -m "todos: Document the dashboard and the research convention"
```

---

### Task 4: Verification

**Files:** none modified (fix-forward commits only if something fails).

- [ ] **Step 1: Run both todos suites and the registered runner entry**

Run: `bash claude/skills/todos/scripts/tests/todos_dashboard_test.sh 2>&1 | tail -1; bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | tail -1; sh bin/dotfiles-tests --list | grep todos_dashboard`
Expected: `92 passed, 0 failed`, `162 passed, 0 failed`, and the suite path.

- [ ] **Step 2: Run the task contract**

Run:

```bash
python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 --task-id td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc --worktree "$(pwd)" --contract claude/contracts/td-2026-09-06-render-a-local-dashboard-of-open-todos-and-researc-contract.json --allow-unpinned
```

Expected: one `ok <name> exit=0` line per command and exit 0. A `FAIL` line names the command to fix; fix forward and rerun.

- [ ] **Step 3: Full runner**

Run: `sh bin/dotfiles-tests 2>&1 | tail -3`
Expected: `dotfiles-tests: N suites passed, 0 failed` with N one higher than at the base commit.

- [ ] **Step 4: Human-verify items to name in the close**

State in the completion message: the one browser look from Task 2 step 4 (done or not, and what it showed), and that the orchestrator preflight step is unverified until the next orchestrated turn after merge.

## Review notes

- Spec review: Codex, two rounds (2026-09-07). Round 1 returned 12 findings, round 2 returned 5; all 17 were folded into the spec (see its "Decisions recorded"). Two rounds is the skill's cap; no usage limit was hit.
- Plan review: see the entry appended below after `codex-plan-review` runs.
- The renderer and the suite embedded above were exercised together in a scratchpad copy of the repo layout before this plan was written: 92 checks, 0 failed, on this machine (macOS, Python 3.14). They are pasted verbatim, so Task 2 step 2 is expected to be green on the first run; any divergence means a paste error, not a design gap.
