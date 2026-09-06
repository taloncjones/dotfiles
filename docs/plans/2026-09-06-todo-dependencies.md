# Todo Dependencies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give todos a machine-readable `depends_on:` list of todo, branch, and PR references; resolve each reference to a state from local git and, when online, `gh`; annotate blocked items in `todos.sh list` and `TODO.md`; set the field through `new --depends-on` and a new `depend` subcommand; backfill the eleven live todos that state a hard dependency in prose.

**Architecture:** Everything lands in the existing single script `claude/skills/todos/scripts/todos.sh` as small single-purpose functions grouped in one new `# --- dependencies ---` block: a normalizer (`normalize_ref`), a frontmatter reader (`depends_list`), a resolver with a per-invocation file cache (`resolve_ref`, `resolve_cached`), a renderer helper (`blocked_refs`), and a frontmatter writer (`add_depends`). `list` and `regenerate_index` call `blocked_refs`; `new` and the new `depend` command call the writer. Only `list` may reach the network; `regenerate_index` forces offline mode. Hidden `_` verbs expose the primitives to the test suite, following `_validate_date`.

**Tech Stack:** bash 3.2 (macOS `/usr/bin/env bash`; no associative arrays, no `mapfile`), POSIX `awk`/`sed`/`git`, optional `gh`; the existing `todos_test.sh` harness (`ok`/`bad`/`assert_eq`/`assert_contains`/`assert_status`, `mk_repo`, `mk_todo`).

**Spec:** `docs/specs/2026-09-06-todo-dependencies.md`

**Status:** branch-only document; dropped before merge together with the spec. The task contract at `claude/contracts/td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o-contract.json` stays.

## Global Constraints

- Files that may change (spec AC13): `claude/skills/todos/scripts/todos.sh`, `claude/skills/todos/scripts/tests/todos_test.sh`, `claude/skills/todos/SKILL.md`. Nothing under `claude/hooks/` or `claude/skills/herdr-orchestration/`.
- Canonical ref forms, verbatim (spec D1): `todo:<YYYY-MM-DD-slug>`, `branch:<name>`, `pr:<n>`. Shorthands accepted by the normalizer: `#85`, `85`, `todo:<x>.md`, bare `YYYY-MM-DD-<slug>`, bare value containing `/`.
- State tokens, verbatim (spec D3): `done`, `merged`, `open`, `closed`, `missing`, `unknown`, `invalid`, `self`. Satisfied means `done` or `merged`.
- Environment overrides (spec D3): `TODOS_OFFLINE` (non-empty means offline), `TODOS_GH` (default `gh`), `TODOS_BASE_REF` (default `origin/main`). `list --offline` is equivalent to `TODOS_OFFLINE=1`.
- `gh` commands, verbatim (spec D3): `gh pr view <n> --json state --jq .state`; `gh pr list --head <name> --state all --limit 1 --json state --jq '.[0].state'`. Stderr discarded; any failure is `unknown`.
- Rendering, verbatim (spec D4): `list` appends `  [blocked-on: <ref> (<state>), ...]` after the title; the index appends ` [blocked-on: <ref>, <ref>]` (determinately unsatisfied: `open`, `closed`, `missing`, `invalid`, `self`) then ` [unverified: <ref>, <ref>]` (`unknown`) after the priority tag and before ` -- summary`, each omitted when empty.
- Diagnostics, verbatim (spec D4): `todos: <basename>: invalid dependency ref '<value>'` and `todos: <basename>: depends on itself` on stderr, from `list` only; `index` is silent; exit stays 0.
- Branch resolution order (spec D3): ancestor of base gives `merged`; else online `gh pr list --head` MERGED/OPEN/CLOSED; else `open` when the ref exists, `unknown` when absent. `git merge-base --is-ancestor` exit above 1 gives `unknown`.
- Error messages, verbatim (spec D5): `todos: a todo cannot depend on itself`, `todos: depend requires at least one ref`.
- No network from `new`, `done`, `depend`, `index`. No `git fetch` anywhere.
- Bash 3.2 compatibility: no `declare -A`, no `mapfile`, no `${var,,}`, no `|&`.
- No emojis, no AI attribution, ASCII only in added lines, LF endings. Commit format `<scope>: <summary>`, imperative, under 75 chars. Every commit's suite run is green before committing.
- Test baseline (spec, 2026-09-06 at `41dd7a1`): `todos_test.sh` 60 passed, 0 failed. Task 5 records the final count.
- Tests are explicit top-to-bottom scripts (repo CLAUDE.md): setup, action, assert visible in each test function; share only the fixture builders and assert helpers.

## File Structure

| File | Responsibility |
|---|---|
| `claude/skills/todos/scripts/todos.sh` | New `# --- dependencies ---` block after `problem_summary`: `strip_value`, `normalize_ref`, `depends_list`, `gh_state`, `map_gh_state`, `resolve_ref`, `resolve_cached`, `blocked_refs`, `add_depends`, `find_pending`, `resolve_todo_payload`, `prepare_ref`. Changed callers: `list_dir`/`cmd_list` (annotation, `--offline`), `regenerate_index` (marker, offline), `cmd_new` (`--depends-on`), `cmd_done` (uses `find_pending`), new `cmd_depend`, `main` dispatch and usage line, header comment. |
| `claude/skills/todos/scripts/tests/todos_test.sh` | New fixture builders `mk_branch_repo`, `mk_gh_stub`, `mk_gh_sentinel`; new test functions appended before the final summary line, one per acceptance criterion. |
| `claude/skills/todos/SKILL.md` | `depends_on:` in the template, Commands rows, a Dependencies section, a Common Mistakes row. |
| `claude/contracts/td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o-contract.json` | Task contract (committed with this plan; run by the orchestrator at completion). |

Task order: 1 grammar and parsing, 2 resolver, 3 rendering, 4 writers, 5 docs, verification, backfill. Each task changes fewer than 300 lines and ends with a green suite and one commit.

## Acceptance criteria to contract mapping

| Spec AC | Contract command(s) |
|---|---|
| AC1 parse | `todos-suite`, `ac1-parse` (greps `ok   depends: parse block list`) |
| AC2 normalize | `todos-suite`, `ac2-normalize` (`ok   depends: normalize refs`) |
| AC3 resolve todo | `todos-suite`, `ac3-resolve-todo` (`ok   resolve: todo states`) |
| AC4 resolve branch | `todos-suite`, `ac4-resolve-branch` (`ok   resolve: branch states`) |
| AC5 resolve PR | `todos-suite`, `ac5-resolve-pr` (`ok   resolve: pr states via gh stub`, `ok   resolve: absent branch via gh stub`) |
| AC6 list rendering | `todos-suite`, `ac6-list` (`ok   list: blocked-on annotation`) |
| AC7 index marker, no network | `todos-suite`, `ac7-index` (`ok   index: blocked marker, no network`) |
| AC8 new flag | `todos-suite`, `ac8-new-flag` (`ok   new: --depends-on`) |
| AC9 depend command | `todos-suite`, `ac9-depend` (`ok   depend: add refs`, `ok   depend: refuses self-dependency`) |
| AC10 diagnostics | `todos-suite`, `ac10-diagnostics` (`ok   list: invalid and self refs warn`) |
| AC11 baseline | `todos-suite` (exit 0 and every new label present), `suite-grew` (at least 130 passed, 0 failed) |
| AC12 docs | `skill-doc-pins` (six strings, including `unverified` from D4) |
| AC13 scope and ASCII | `diff-scope`, `ascii-added-lines`, `no-attribution-in-added-lines`, `bash-syntax` |
| Backfill applied | manual: `todos.sh list --offline` read by the orchestrator or human (spec Verification outside the contract) |
| Online `pr:85 (merged)` | manual, one `todos.sh list` on this machine |

Each `acN-*` command runs the suite and greps for the labelled `ok` line, so a renamed or deleted check fails the contract even when the suite exits 0. Test labels are therefore part of the interface: use them verbatim.

---

### Task 1: Reference grammar and frontmatter parsing

**Files:**
- Modify: `claude/skills/todos/scripts/todos.sh` (insert the dependencies block after `problem_summary`, ending at line 89; add two hidden verbs in `main`, lines 470-486; extend the header usage comment, lines 15-24)
- Test: `claude/skills/todos/scripts/tests/todos_test.sh` (append before the final `printf '\n%d passed, %d failed\n'` line 469)

**Interfaces:**
- Produces: `strip_value` (stdin to stdout: trim whitespace, strip one pair of surrounding quotes); `normalize_ref <input>` (prints canonical ref, exit 1 when invalid); `depends_list <file>` (prints raw stripped items, one per line, empty when none); `TODO_ID_RE` (ERE string); hidden verbs `_normalize_ref <input>`, `_depends <file>`.
- Consumed by: Task 2 (`resolve_ref` splits the canonical form on the first `:`), Task 3 (`blocked_refs`), Task 4 (`add_depends`, `prepare_ref`).

- [ ] **Step 1: Write the failing tests**

Append before the final summary `printf` in `todos_test.sh`:

```bash
# --- dependencies ---

test_depends_parse() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" nokey <<'EOF'
---
created: 2026-05-01
title: No key
---
EOF
  mk_todo "$repo" emptykey <<'EOF'
---
created: 2026-05-01
title: Empty key
depends_on:
files:
---
EOF
  mk_todo "$repo" three <<'EOF'
---
created: 2026-05-01
title: Three items
depends_on:
  - todo:2026-05-01-first
  - "branch:talon/second"
  - 'pr:3'
files:
  - not/a/dep.py
---

## Problem

  - todo:2026-05-01-body-item-not-a-dep
EOF
  mk_todo "$repo" lastkey <<'EOF'
---
created: 2026-05-01
title: Last key
depends_on:
  - pr:9
---
  - pr:10
EOF
  local out
  out=$(cd "$repo" && bash "$TODOS" _depends .todos/pending/nokey.md)
  assert_eq "parse: missing key yields nothing" "$out" ""
  out=$(cd "$repo" && bash "$TODOS" _depends .todos/pending/emptykey.md)
  assert_eq "parse: empty key yields nothing" "$out" ""
  out=$(cd "$repo" && bash "$TODOS" _depends .todos/pending/three.md)
  assert_eq "parse: three items in order, quotes stripped, stops at next key" \
    "$out" "$(printf 'todo:2026-05-01-first\nbranch:talon/second\npr:3')"
  out=$(cd "$repo" && bash "$TODOS" _depends .todos/pending/lastkey.md)
  assert_eq "parse: stops at closing ---" "$out" "pr:9"
  ok "depends: parse block list"
  rm -rf "$repo"
}
test_depends_parse

test_depends_normalize() {
  assert_eq "normalize: #85"        "$(bash "$TODOS" _normalize_ref '#85')"  "pr:85"
  assert_eq "normalize: bare 85"    "$(bash "$TODOS" _normalize_ref 85)"     "pr:85"
  assert_eq "normalize: pr:85"      "$(bash "$TODOS" _normalize_ref pr:85)"  "pr:85"
  assert_eq "normalize: bare branch" "$(bash "$TODOS" _normalize_ref talon/x)"        "branch:talon/x"
  assert_eq "normalize: branch:"     "$(bash "$TODOS" _normalize_ref branch:talon/x) " "branch:talon/x "
  assert_eq "normalize: bare todo id" "$(bash "$TODOS" _normalize_ref 2026-05-01-some-slug)" "todo:2026-05-01-some-slug"
  assert_eq "normalize: todo: with .md" "$(bash "$TODOS" _normalize_ref todo:2026-05-01-some-slug.md)" "todo:2026-05-01-some-slug"
  assert_eq "normalize: bare id with .md" "$(bash "$TODOS" _normalize_ref 2026-05-01-some-slug.md)" "todo:2026-05-01-some-slug"
  assert_eq "normalize: quoted and padded" "$(bash "$TODOS" _normalize_ref '  "pr:7" ')" "pr:7"
  assert_status "normalize: pr:0 rejected"      1 bash "$TODOS" _normalize_ref pr:0
  assert_status "normalize: pr:abc rejected"    1 bash "$TODOS" _normalize_ref pr:abc
  assert_status "normalize: pr:007 rejected"    1 bash "$TODOS" _normalize_ref pr:007
  assert_status "normalize: bad branch rejected" 1 bash "$TODOS" _normalize_ref 'branch:bad..name'
  assert_status "normalize: leading dash rejected" 1 bash "$TODOS" _normalize_ref 'branch:-x'
  assert_status "normalize: reflog form rejected"  1 bash "$TODOS" _normalize_ref 'branch:a@{1}'
  assert_status "normalize: bare word rejected"  1 bash "$TODOS" _normalize_ref parity
  assert_status "normalize: todo: bad slug rejected" 1 bash "$TODOS" _normalize_ref 'todo:Not-A-Slug'
  assert_status "normalize: empty rejected"      1 bash "$TODOS" _normalize_ref ''
  ok "depends: normalize refs"
}
test_depends_normalize
```

Note the `ok "depends: ..."` summary line at the end of each function: it is the label the task contract greps for. Keep it verbatim.

- [ ] **Step 2: Run the suite to see the new checks fail**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: several `FAIL parse: ...` and `FAIL normalize: ...` lines (the hidden verbs are unknown commands, exit 1, empty stdout), and a final line with 60 passed and a non-zero failed count.

- [ ] **Step 3: Add the dependencies block to `todos.sh`**

Insert directly after the closing `}` of `problem_summary` (line 89):

```bash
# --- dependencies ---------------------------------------------------------
#
# A todo may declare `depends_on:` as a block list of refs in canonical form
#   todo:<YYYY-MM-DD-slug>   branch:<git branch name>   pr:<number>
# The normalizer also accepts the shorthands `#85`, `85`, `todo:<id>.md`, a
# bare `YYYY-MM-DD-<slug>`, and a bare value containing `/` (a branch).

TODO_ID_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]*[a-z0-9]$'

strip_value() {
  # stdin -> stdout: trim surrounding whitespace and one pair of quotes.
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

normalize_ref() {
  # normalize_ref <input> -> canonical ref on stdout; exit 1 when invalid.
  local in kind payload
  in=$(printf '%s' "$1" | strip_value)
  case "$in" in
    todo:*)   kind=todo;   payload="${in#todo:}" ;;
    branch:*) kind=branch; payload="${in#branch:}" ;;
    pr:*)     kind=pr;     payload="${in#pr:}" ;;
    '#'*)     kind=pr;     payload="${in#\#}" ;;
    */*)      kind=branch; payload="$in" ;;
    *)        kind="";     payload="$in" ;;
  esac
  if [ -z "$kind" ]; then
    case "$payload" in
      ''|*[!0-9]*) [[ "${payload%.md}" =~ $TODO_ID_RE ]] && kind=todo ;;
      *) kind=pr ;;
    esac
  fi
  [ -n "$kind" ] || return 1
  case "$kind" in
    todo)
      payload="${payload%.md}"
      [[ "$payload" =~ $TODO_ID_RE ]] || return 1 ;;
    branch)
      # git parses a leading dash as a flag and @{...} as reflog shorthand.
      case "$payload" in ''|-*|*@\{*) return 1 ;; esac
      git check-ref-format --branch "$payload" >/dev/null 2>&1 || return 1 ;;
    pr)
      case "$payload" in ''|*[!0-9]*|0*) return 1 ;; esac ;;
  esac
  printf '%s:%s\n' "$kind" "$payload"
}

depends_list() {
  # depends_list <file> -> the depends_on block items, stripped, one per line.
  # Reads only the first frontmatter block; stops at the first non-item line.
  awk '
    /^---$/                   { n++; if (n >= 2) exit; next }
    n == 1 && /^depends_on:/  { f = 1; next }
    n == 1 && f && /^  - /    { sub(/^  - /, ""); print; next }
    n == 1 && f               { f = 0 }
  ' "$1" | strip_value
}
```

Note: `sed` in `strip_value` runs per line of the awk output, so each item is trimmed and unquoted independently.

- [ ] **Step 4: Register the hidden verbs**

In `main`, after the `_date_shift` line add:

```bash
    _normalize_ref) normalize_ref "${1:-}" ;;
    _depends) depends_list "${1:-}" ;;
```

In the header usage comment (after the `todos.sh path` line) add nothing yet; Task 4 rewrites that comment once the user-facing commands exist.

- [ ] **Step 5: Run the suite to see it pass**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: no `FAIL` lines; final line `87 passed, 0 failed` (60 baseline plus 8 parse-group and 19 normalize-group checks; count the `ok` lines if the total differs and reconcile before committing).

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add claude/skills/todos/scripts/todos.sh claude/skills/todos/scripts/tests/todos_test.sh
git -C "$WT" commit -m "todos: Parse and normalize depends_on refs"
```

(`$WT` is the worktree path; the orchestrator's ground rules require `git -C`.)

---

### Task 2: Resolver with offline mode and gh stubbing

**Files:**
- Modify: `claude/skills/todos/scripts/todos.sh` (append to the dependencies block after `depends_list`; add `_resolve` to `main`)
- Test: `claude/skills/todos/scripts/tests/todos_test.sh` (append fixture builders after `mk_todo`, tests before the summary line)

**Interfaces:**
- Consumes: `normalize_ref`, `repo_root`, `TODOS_DIRNAME` (Task 1 and existing).
- Produces: `gh_state <gh-args...>` (prints MERGED/OPEN/CLOSED or nothing; never non-zero); `map_gh_state <token>`; `resolve_ref <canonical-ref>` (prints a state token, never `self`); `resolve_cached <canonical-ref> <self-basename>` (adds the `self` state and the per-invocation cache in `$DEPS_CACHE` when set); honours `DEPS_OFFLINE=1` as an in-process equivalent of `TODOS_OFFLINE`; hidden verb `_resolve <input>` (normalizes, then resolves; prints `invalid` for a bad input).
- Test fixtures: `mk_branch_repo` (echoes a repo path with `origin/main`, `merged-b` at an ancestor, `open-b` one commit ahead), `mk_gh_stub <path>` (writes an executable fake `gh`).

- [ ] **Step 1: Add the fixture builders to the test file**

After `mk_todo` in `todos_test.sh`:

```bash
# Repo with origin/main (via update-ref, no network), merged-b at an ancestor
# commit, and open-b one commit ahead. Echoes its path.
mk_branch_repo() {
  local d; d=$(mk_repo)
  ( cd "$d" \
    && git commit -q --allow-empty -m base \
    && git branch merged-b \
    && git update-ref refs/remotes/origin/main HEAD \
    && git checkout -q -b open-b \
    && git commit -q --allow-empty -m extra \
    && git checkout -q - ) >/dev/null 2>&1
  printf '%s' "$d"
}
# Fake gh. mk_gh_stub <path>: pr view 1/2/3 -> MERGED/OPEN/CLOSED, else exit 1;
# pr list --head merged-away or --head open-b -> MERGED, --head gone-open -> OPEN,
# else exit 1. Every invocation appends one line to <path>.calls.
mk_gh_stub() {
  cat >"$1" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$1.calls"
case "\$1 \$2" in
  "pr view") case "\$3" in 1) echo MERGED ;; 2) echo OPEN ;; 3) echo CLOSED ;; *) exit 1 ;; esac ;;
  "pr list") case " \$* " in *" --head merged-away "*|*" --head open-b "*) echo MERGED ;; *" --head gone-open "*) echo OPEN ;; *) exit 1 ;; esac ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1"
}
```

- [ ] **Step 2: Write the failing tests**

Append before the summary line:

```bash
test_resolve_todo() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-open-item <<'EOF'
---
created: 2026-05-01
title: Open item
---
EOF
  mkdir -p "$repo/.todos/completed"
  printf -- '---\ncreated: 2026-05-01\ntitle: Done item\n---\n' >"$repo/.todos/completed/2026-05-01-done-item.md"
  assert_eq "resolve: completed todo is done" \
    "$(cd "$repo" && bash "$TODOS" _resolve todo:2026-05-01-done-item)" "done"
  assert_eq "resolve: pending todo is open" \
    "$(cd "$repo" && bash "$TODOS" _resolve todo:2026-05-01-open-item)" "open"
  assert_eq "resolve: absent todo is missing" \
    "$(cd "$repo" && bash "$TODOS" _resolve todo:2026-05-01-nope)" "missing"
  assert_eq "resolve: bad input is invalid" \
    "$(cd "$repo" && bash "$TODOS" _resolve parity)" "invalid"
  ok "resolve: todo states"
  rm -rf "$repo"
}
test_resolve_todo

test_resolve_branch() {
  local repo; repo=$(mk_branch_repo)
  assert_eq "resolve: ancestor branch is merged" \
    "$(cd "$repo" && TODOS_OFFLINE=1 bash "$TODOS" _resolve branch:merged-b)" "merged"
  assert_eq "resolve: ahead branch is open" \
    "$(cd "$repo" && TODOS_OFFLINE=1 bash "$TODOS" _resolve branch:open-b)" "open"
  assert_eq "resolve: absent branch offline is unknown" \
    "$(cd "$repo" && TODOS_OFFLINE=1 bash "$TODOS" _resolve branch:absent-b)" "unknown"
  assert_eq "resolve: missing base ref is unknown" \
    "$(cd "$repo" && TODOS_OFFLINE=1 TODOS_BASE_REF=origin/nope bash "$TODOS" _resolve branch:merged-b)" "unknown"
  local stub; stub=$(mktemp); mk_gh_stub "$stub"
  assert_eq "resolve: present branch merged via gh" \
    "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve branch:open-b)" "merged"
  assert_eq "resolve: present branch unknown to gh stays open" \
    "$(cd "$repo" && git branch -q lonely-b open-b && TODOS_GH="$stub" bash "$TODOS" _resolve branch:lonely-b)" "open"
  assert_eq "resolve: remote-tracking ref preferred" \
    "$(cd "$repo" && git update-ref refs/remotes/origin/open-b refs/remotes/origin/main && TODOS_OFFLINE=1 bash "$TODOS" _resolve branch:open-b)" "merged"
  ok "resolve: branch states"
  rm -rf "$repo"; rm -f "$stub" "$stub.calls"
}
test_resolve_branch

test_resolve_pr() {
  local repo; repo=$(mk_branch_repo)
  local stub; stub=$(mktemp); mk_gh_stub "$stub"
  assert_eq "resolve: pr MERGED" "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve pr:1)" "merged"
  assert_eq "resolve: pr OPEN"   "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve pr:2)" "open"
  assert_eq "resolve: pr CLOSED" "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve pr:3)" "closed"
  assert_eq "resolve: pr gh failure is unknown" "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve pr:4)" "unknown"
  assert_eq "resolve: pr offline is unknown" "$(cd "$repo" && TODOS_OFFLINE=1 TODOS_GH="$stub" bash "$TODOS" _resolve pr:1)" "unknown"
  local errf; errf=$(mktemp)
  local out; out=$(cd "$repo" && TODOS_GH=/nonexistent/gh bash "$TODOS" _resolve pr:1 2>"$errf")
  assert_eq "resolve: pr missing gh is unknown" "$out" "unknown"
  assert_eq "resolve: pr missing gh is silent" "$(cat "$errf")" ""
  ok "resolve: pr states via gh stub"
  assert_eq "resolve: absent branch merged via gh" \
    "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve branch:merged-away)" "merged"
  assert_eq "resolve: absent branch open via gh" \
    "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve branch:gone-open)" "open"
  assert_eq "resolve: absent branch unknown to gh" \
    "$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" _resolve branch:never-heard)" "unknown"
  ok "resolve: absent branch via gh stub"
  rm -rf "$repo"; rm -f "$stub" "$stub.calls" "$errf"
}
test_resolve_pr
```

- [ ] **Step 3: Run the suite to see the new checks fail**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: `FAIL resolve: ...` lines (unknown command `_resolve`); baseline checks and Task 1 checks still `ok`.

- [ ] **Step 4: Add the resolver**

Append to the dependencies block after `depends_list`:

```bash
deps_offline() {
  # True when no network may be used: TODOS_OFFLINE set, or DEPS_OFFLINE=1
  # set in-process (list --offline; regenerate_index always).
  [ -n "${TODOS_OFFLINE:-}" ] || [ "${DEPS_OFFLINE:-0}" = 1 ]
}

gh_state() {
  # gh_state <gh args...> -> MERGED|OPEN|CLOSED on stdout, or nothing.
  # Never fails: a missing binary, non-zero exit, or odd output all print nothing.
  local gh="${TODOS_GH:-gh}" out
  deps_offline && return 0
  command -v "$gh" >/dev/null 2>&1 || return 0
  out=$("$gh" "$@" 2>/dev/null) || return 0
  case "$out" in MERGED|OPEN|CLOSED) printf '%s\n' "$out" ;; esac
  return 0
}

map_gh_state() {
  case "${1:-}" in
    MERGED) printf 'merged\n' ;;
    OPEN)   printf 'open\n' ;;
    CLOSED) printf 'closed\n' ;;
    *)      printf 'unknown\n' ;;
  esac
}

resolve_ref() {
  # resolve_ref <canonical-ref> -> state token (never `self`; see resolve_cached).
  local ref="$1" root kind payload base bref st rc
  root=$(repo_root)
  kind="${ref%%:*}"; payload="${ref#*:}"
  case "$kind" in
    todo)
      if   [ -e "$root/$TODOS_DIRNAME/completed/$payload.md" ]; then printf 'done\n'
      elif [ -e "$root/$TODOS_DIRNAME/pending/$payload.md" ];   then printf 'open\n'
      else printf 'missing\n'; fi ;;
    branch)
      base="${TODOS_BASE_REF:-origin/main}"
      if ! git rev-parse --verify --quiet "$base^{commit}" >/dev/null 2>&1; then
        printf 'unknown\n'; return 0
      fi
      if   git show-ref --verify --quiet "refs/remotes/origin/$payload"; then bref="refs/remotes/origin/$payload"
      elif git show-ref --verify --quiet "refs/heads/$payload";          then bref="refs/heads/$payload"
      else bref=""; fi
      if [ -n "$bref" ]; then
        # exit 0 ancestor, 1 not an ancestor, >1 git error.
        git merge-base --is-ancestor "$bref" "$base" 2>/dev/null; rc=$?
        [ "$rc" -eq 0 ] && { printf 'merged\n'; return 0; }
        [ "$rc" -le 1 ] || { printf 'unknown\n'; return 0; }
      fi
      # Squash merges never make the branch an ancestor; ask gh by head name.
      st=$(gh_state pr list --head "$payload" --state all --limit 1 --json state --jq '.[0].state')
      case "$st" in
        MERGED|OPEN|CLOSED) map_gh_state "$st" ;;
        *) if [ -n "$bref" ]; then printf 'open\n'; else printf 'unknown\n'; fi ;;
      esac ;;
    pr)
      st=$(gh_state pr view "$payload" --json state --jq .state)
      map_gh_state "$st" ;;
    *) printf 'invalid\n' ;;
  esac
}

resolve_cached() {
  # resolve_cached <canonical-ref> <self-basename> -> state token, adding
  # `self` and memoizing per invocation in the file $DEPS_CACHE when set
  # (bash 3.2 has no associative arrays).
  local ref="$1" self="$2" st
  [ "$ref" = "todo:$self" ] && { printf 'self\n'; return 0; }
  if [ -n "${DEPS_CACHE:-}" ] && [ -f "$DEPS_CACHE" ]; then
    st=$(awk -F'\t' -v r="$ref" '$1 == r { print $2; exit }' "$DEPS_CACHE")
    if [ -n "$st" ]; then printf '%s\n' "$st"; return 0; fi
  fi
  st=$(resolve_ref "$ref")
  [ -n "${DEPS_CACHE:-}" ] && printf '%s\t%s\n' "$ref" "$st" >>"$DEPS_CACHE"
  printf '%s\n' "$st"
}
```

- [ ] **Step 5: Register the hidden verb**

In `main`, after `_depends`:

```bash
    _resolve) if ref=$(normalize_ref "${1:-}"); then resolve_ref "$ref"; else printf 'invalid\n'; fi ;;
```

and declare `local cmd="$1" ref` on the existing `local cmd="$1"; shift` line (keep the `shift`).

- [ ] **Step 6: Run the suite to see it pass**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: no `FAIL`; total 87 plus 21 new checks (reconcile by counting `ok` lines if it differs).

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add claude/skills/todos/scripts/todos.sh claude/skills/todos/scripts/tests/todos_test.sh
git -C "$WT" commit -m "todos: Resolve dependency refs against todos, git, and gh"
```

---

### Task 3: Blocked-on rendering in list and the index

**Files:**
- Modify: `claude/skills/todos/scripts/todos.sh` (`list_dir` lines 178-193, `cmd_list` lines 195-201, `regenerate_index` lines 229-270; append `blocked_refs` to the dependencies block)
- Test: `claude/skills/todos/scripts/tests/todos_test.sh`

**Interfaces:**
- Consumes: `depends_list`, `normalize_ref`, `resolve_cached`, `DEPS_CACHE`, `DEPS_OFFLINE` (Tasks 1-2).
- Produces: `blocked_refs <file>` (prints one `<ref><TAB><state>` line per unsatisfied ref in file order, nothing when none; emits the D4 diagnostics on stderr unless `DEPS_QUIET=1`); `join_refs <with-states 0|1>` (stdin lines to a comma-separated string); `list_dir <dir> <label> <annotate 0|1>`; `cmd_list` accepting `--all` and `--offline` in any order; `regenerate_index` sets `DEPS_OFFLINE=1 DEPS_QUIET=1`.

- [ ] **Step 1: Write the failing tests**

Append before the summary line:

```bash
test_list_blocked_on() {
  local repo; repo=$(mk_branch_repo)
  mk_todo "$repo" 2026-05-01-satisfied <<'EOF'
---
created: 2026-05-01
title: Satisfied item
depends_on:
  - branch:merged-b
---
EOF
  mk_todo "$repo" 2026-05-01-oneblock <<'EOF'
---
created: 2026-05-01
title: One blocker
depends_on:
  - branch:open-b
---
EOF
  mk_todo "$repo" 2026-05-01-twoblock <<'EOF'
---
created: 2026-05-01
title: Two blockers
depends_on:
  - branch:merged-b
  - todo:2026-05-01-oneblock
  - pr:1
---
EOF
  mkdir -p "$repo/.todos/completed"
  printf -- '---\ncreated: 2026-05-01\ntitle: Done blocked\ndepends_on:\n  - pr:1\n---\n' >"$repo/.todos/completed/2026-05-01-doneblocked.md"
  local out
  out=$(cd "$repo" && bash "$TODOS" list --offline)
  assert_contains "list: one unsatisfied ref annotated" "$out" "One blocker  [blocked-on: branch:open-b (open)]"
  assert_contains "list: two unsatisfied refs in file order" "$out" \
    "Two blockers  [blocked-on: todo:2026-05-01-oneblock (open), pr:1 (unknown)]"
  case "$out" in *"Satisfied item  [blocked-on"*) bad "list: satisfied item plain" "annotated";; *) ok "list: satisfied item plain";; esac
  out=$(cd "$repo" && bash "$TODOS" list --offline --all)
  assert_contains "list: --offline --all lists completed" "$out" "completed:"
  case "$out" in *"Done blocked  [blocked-on"*) bad "list: completed never annotated" "annotated";; *) ok "list: completed never annotated";; esac
  out=$(cd "$repo" && TODOS_OFFLINE=1 bash "$TODOS" list --all --offline)
  assert_contains "list: --all --offline also accepted" "$out" "One blocker  [blocked-on"
  assert_status "list: unknown flag rejected" 1 bash -c '(cd "$1" && bash "$2" list --nope)' _ "$repo" "$TODOS"
  # online: a failing gh never aborts list; a shared ref is resolved once
  mk_todo "$repo" 2026-05-01-share-a <<'EOF'
---
created: 2026-05-01
title: Share a
depends_on:
  - pr:1
---
EOF
  mk_todo "$repo" 2026-05-01-share-b <<'EOF'
---
created: 2026-05-01
title: Share b
depends_on:
  - pr:1
---
EOF
  local stub; stub=$(mktemp); mk_gh_stub "$stub"
  out=$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" list); local rc=$?
  assert_eq "list: online exits 0" "$rc" "0"
  case "$out" in *"Two blockers  [blocked-on: todo:2026-05-01-oneblock (open)]"*) ok "list: online pr:1 merged drops from annotation";; *) bad "list: online pr:1 merged drops from annotation" "$out";; esac
  assert_eq "list: shared pr ref resolved once" "$(grep -c 'pr view 1 ' "$stub.calls")" "1"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$stub"
  out=$(cd "$repo" && TODOS_GH="$stub" bash "$TODOS" list); rc=$?
  assert_eq "list: failing gh still exits 0" "$rc" "0"
  assert_contains "list: failing gh renders unknown" "$out" "Share a  [blocked-on: pr:1 (unknown)]"
  ok "list: blocked-on annotation"
  rm -rf "$repo"; rm -f "$stub" "$stub.calls"
}
test_list_blocked_on

test_index_blocked_marker() {
  local repo; repo=$(mk_branch_repo)
  local stub; stub=$(mktemp)
  printf '#!/usr/bin/env bash\ntouch "%s.hit"\nexit 1\n' "$stub" >"$stub"; chmod +x "$stub"
  mk_todo "$repo" 2026-05-01-blocked <<'EOF'
---
created: 2026-05-01
title: Blocked item
priority: high
depends_on:
  - branch:open-b
  - pr:1
---

## Problem

Needs the branch.
EOF
  mk_todo "$repo" 2026-05-01-free <<'EOF'
---
created: 2026-05-01
title: Free item
depends_on:
  - branch:merged-b
---
EOF
  ( cd "$repo" && TODOS_TODAY=2026-06-08 TODOS_GH="$stub" bash "$TODOS" new "Fresh one" --priority low >/dev/null )
  local idx; idx=$(cat "$repo/.todos/TODO.md")
  assert_contains "index: blocked and unverified markers after priority" "$idx" \
    "[Blocked item](./pending/2026-05-01-blocked.md) [high] [blocked-on: branch:open-b] [unverified: pr:1] -- Needs the branch."
  case "$idx" in *"Free item](./pending/2026-05-01-free.md) [blocked-on"*|*"Free item](./pending/2026-05-01-free.md) [unverified"*) bad "index: satisfied item unmarked" "marked";; *) ok "index: satisfied item unmarked";; esac
  [ -e "$stub.hit" ] && bad "index: new never calls gh" "gh stub was invoked" || ok "index: new never calls gh"
  mk_todo "$repo" 2026-05-01-badref <<'EOF'
---
created: 2026-05-01
title: Bad ref elsewhere
depends_on:
  - parity
---
EOF
  local errf; errf=$(mktemp)
  ( cd "$repo" && bash "$TODOS" done 2026-05-01-free ) >/dev/null 2>"$errf"
  assert_eq "index: done is quiet about another todo's bad ref" "$(cat "$errf")" ""
  assert_contains "index: invalid ref still marked" "$(cat "$repo/.todos/TODO.md")" "[Bad ref elsewhere](./pending/2026-05-01-badref.md) [blocked-on: parity]"
  ok "index: blocked marker, no network"
  rm -rf "$repo"; rm -f "$stub" "$stub.hit" "$errf"
}
test_index_blocked_marker

test_list_invalid_and_self() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-selfref <<'EOF'
---
created: 2026-05-01
title: Self ref item
depends_on:
  - todo:2026-05-01-selfref
  - parity
---
EOF
  local errf; errf=$(mktemp)
  local out; out=$(cd "$repo" && bash "$TODOS" list --offline 2>"$errf"); local rc=$?
  local err; err=$(cat "$errf")
  assert_eq "list: exits 0 with bad refs" "$rc" "0"
  assert_contains "list: self rendered" "$out" "[blocked-on: todo:2026-05-01-selfref (self), parity (invalid)]"
  assert_contains "list: self warned" "$err" "todos: 2026-05-01-selfref: depends on itself"
  assert_contains "list: invalid warned" "$err" "todos: 2026-05-01-selfref: invalid dependency ref 'parity'"
  assert_eq "list: each warning once" "$(grep -c 'todos: 2026-05-01-selfref' "$errf")" "2"
  ok "list: invalid and self refs warn"
  rm -rf "$repo"; rm -f "$errf"
}
test_list_invalid_and_self
```

- [ ] **Step 2: Run the suite to see the new checks fail**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: `FAIL list: ...` and `FAIL index: ...` lines. `list --offline` currently prints the pending section ignoring the flag (`cmd_list` only looks at `$1`), so annotation checks fail on missing text and the `--nope` check fails because it exits 0.

- [ ] **Step 3: Add `blocked_refs`**

Append to the dependencies block after `resolve_cached`:

```bash
blocked_refs() {
  # blocked_refs <file> -> one "<ref>\t<state>" line per unsatisfied ref, in
  # file order; nothing when every dependency is satisfied or there are none.
  # Warns once per invalid/self ref on stderr unless DEPS_QUIET=1 (index).
  local f="$1" base raw ref st
  base=$(basename "$f" .md)
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    if ref=$(normalize_ref "$raw"); then
      st=$(resolve_cached "$ref" "$base")
    else
      ref="$raw"; st=invalid
    fi
    if [ "${DEPS_QUIET:-0}" != 1 ]; then
      case "$st" in
        invalid) printf "todos: %s: invalid dependency ref '%s'\n" "$base" "$raw" >&2 ;;
        self)    printf 'todos: %s: depends on itself\n' "$base" >&2 ;;
      esac
    fi
    case "$st" in done|merged) continue ;; esac
    printf '%s\t%s\n' "$ref" "$st"
  done < <(depends_list "$f")
}

join_refs() {
  # stdin "<ref>\t<state>" lines -> "ref (state), ref (state)" when $1 is 1,
  # "ref, ref" when 0. No trailing newline; empty for empty input.
  awk -F'\t' -v states="$1" '
    { item = (states == 1) ? $1 " (" $2 ")" : $1
      out = (NR == 1) ? item : out ", " item }
    END { printf "%s", out }'
}
```

- [ ] **Step 4: Annotate `list`**

Replace `list_dir` and `cmd_list` with:

```bash
list_dir() {
  # list_dir <dir> <label> <annotate 0|1>: annotate appends the blocked-on
  # suffix (pending only; completed items never resolve their dependencies).
  local dir="$1" label="$2" annotate="$3" f title blocked
  [ -d "$dir" ] || return 0
  local any=0
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    any=1; break
  done
  [ "$any" -eq 1 ] || return 0
  printf '%s:\n' "$label"
  for f in "$dir"/*.md; do
    [ -e "$f" ] || continue
    title=$(frontmatter_value title "$f")
    blocked=""
    [ "$annotate" = 1 ] && blocked=$(blocked_refs "$f" | join_refs 1)
    if [ -n "$blocked" ]; then
      printf '  %-44s %s  [blocked-on: %s]\n' "$(basename "$f")" "${title:-}" "$blocked"
    else
      printf '  %-44s %s\n' "$(basename "$f")" "${title:-}"
    fi
  done
}

cmd_list() {
  local all=0 DEPS_OFFLINE=0 DEPS_CACHE
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --all)     all=1; shift ;;
      --offline) DEPS_OFFLINE=1; shift ;;
      *) die "unknown flag for list: $1" ;;
    esac
  done
  DEPS_CACHE=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$DEPS_CACHE'" RETURN
  local root; root=$(repo_root)
  list_dir "$root/$TODOS_DIRNAME/pending" "pending" 1
  [ "$all" -eq 1 ] && list_dir "$root/$TODOS_DIRNAME/completed" "completed" 0
  return 0
}
```

`local DEPS_OFFLINE` and `local DEPS_CACHE` are visible to the callees because bash scopes `local` dynamically; nothing leaks past `cmd_list`. The final `return 0` keeps the exit status at 0 when `--all` is off (the `[ ... ] && ...` line otherwise returns 1 under `set -e` at the end of the function).

- [ ] **Step 5: Mark blocked items in the index**

In `regenerate_index`:

1. Change the `local` line to `local root pending index f title due priority created base summary key pw blocked unverified`, and add `local DEPS_OFFLINE=1 DEPS_QUIET=1 DEPS_CACHE` on the next line.
2. Replace `local data; data=$(mktemp); trap "rm -f '$data'" RETURN` with:

```bash
  local data; data=$(mktemp); DEPS_CACHE=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$data' '$DEPS_CACHE'" RETURN
```

3. After `summary=$(problem_summary "$f")` add:

```bash
    blocked=$(blocked_refs "$f" | awk -F'\t' '$2 != "unknown"' | join_refs 0)
    unverified=$(blocked_refs "$f" | awk -F'\t' '$2 == "unknown"' | join_refs 0)
```

   (Two passes over a cached resolver are cheap; the cache makes the second pass free of git and gh calls.)
4. Change the row `printf` to eight fields: `printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$key" "$base" "$title" "$due" "$priority" "$blocked" "$unverified" "$summary" >>"$data"`.
5. Change the reader to `local k b t d p bl uv s meta` and `while IFS=$'\037' read -r k b t d p bl uv s; do`, and after `[ -n "$p" ] && meta="$meta [$p]"` add:

```bash
        [ -n "$bl" ] && meta="$meta [blocked-on: $bl]"
        [ -n "$uv" ] && meta="$meta [unverified: $uv]"
```

The summary stays the last field so an embedded `\037` cannot occur before it; refs never contain one.

- [ ] **Step 6: Run the suite to see it pass**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: no `FAIL`. If `index: blocked and unverified markers after priority` fails on spacing, print the `TODO.md` line and align the expected string to the existing `meta` construction (` [high]` then ` [blocked-on: ...]` then ` [unverified: ...]` then ` -- `), not the other way round.

- [ ] **Step 7: Commit**

```bash
git -C "$WT" add claude/skills/todos/scripts/todos.sh claude/skills/todos/scripts/tests/todos_test.sh
git -C "$WT" commit -m "todos: Show blocked-on dependencies in list and the index"
```

---

### Task 4: Writers: `new --depends-on` and `depend`

**Files:**
- Modify: `claude/skills/todos/scripts/todos.sh` (`cmd_new` lines 116-176, `cmd_done` lines 203-227, `main`, header comment lines 15-24; append `add_depends`, `find_pending`, `resolve_todo_payload`, `prepare_ref` to the dependencies block)
- Test: `claude/skills/todos/scripts/tests/todos_test.sh`

**Interfaces:**
- Consumes: `normalize_ref`, `depends_list`, `regenerate_index`, `die`, `repo_root`.
- Produces: `find_pending <query>` (prints the unique pending path; exact basename first, then unique substring; dies otherwise); `resolve_todo_payload <query>` (prints the exact basename across pending and completed; dies otherwise); `prepare_ref <input>` (canonical ref ready to write, todo existence verified; dies otherwise); `add_depends <file> <ref>...` (atomic frontmatter rewrite, dedupes against normalized existing items); `cmd_depend`; `cmd_new --depends-on`.

- [ ] **Step 1: Write the failing tests**

Append before the summary line:

```bash
test_new_depends_on() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-let-auto-mode-decide <<'EOF'
---
created: 2026-05-01
title: Existing dep
---
EOF
  mk_todo "$repo" 2026-05-01-let-auto-mode-decide-2 <<'EOF'
---
created: 2026-05-01
title: Existing dep twin
---
EOF
  local f
  f=$( (cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "Needs things" --priority high \
        --depends-on '#85' --depends-on todo:2026-05-01-let-auto-mode-decide-2 \
        --depends-on talon/parity --depends-on pr:85 --file a.py) )
  local body; body=$(cat "$f")
  assert_contains "new: canonical list between priority and files" "$body" \
    "$(printf 'priority: high\ndepends_on:\n  - pr:85\n  - todo:2026-05-01-let-auto-mode-decide-2\n  - branch:talon/parity\nfiles:\n  - a.py')"
  assert_eq "new: refs deduped" "$(grep -c 'pr:85' "$f")" "1"
  f=$( (cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "Substring dep" --depends-on todo:decide-2) )
  assert_contains "new: unique substring stored as exact basename" "$(cat "$f")" "  - todo:2026-05-01-let-auto-mode-decide-2"
  local before; before=$(ls "$repo/.todos/pending" | wc -l | tr -d ' ')
  assert_status "new: invalid ref exits 1"     1 bash -c '(cd "$1" && bash "$2" new x --depends-on parity)' _ "$repo" "$TODOS"
  assert_status "new: unknown todo exits 1"    1 bash -c '(cd "$1" && bash "$2" new x --depends-on todo:2026-05-01-nope)' _ "$repo" "$TODOS"
  assert_status "new: ambiguous todo exits 1"  1 bash -c '(cd "$1" && bash "$2" new x --depends-on todo:let-auto-mode)' _ "$repo" "$TODOS"
  assert_status "new: dangling --depends-on"   1 bash -c '(cd "$1" && bash "$2" new x --depends-on)' _ "$repo" "$TODOS"
  assert_eq "new: failures write no file" "$(ls "$repo/.todos/pending" | wc -l | tr -d ' ')" "$before"
  ok "new: --depends-on"
  rm -rf "$repo"
}
test_new_depends_on

test_depend_add() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-target-one <<'EOF'
---
created: 2026-05-01
title: Target with files
area: x
files:
  - keep/me.py
---

## Problem

Body stays.
EOF
  mk_todo "$repo" 2026-05-01-target-two <<'EOF'
---
created: 2026-05-01
title: Target with list
depends_on:
  - pr:1
---
EOF
  mk_todo "$repo" 2026-05-01-target-three <<'EOF'
---
created: 2026-05-01
title: Target bare
---
EOF
  local out
  out=$(cd "$repo" && bash "$TODOS" depend target-one '#2' branch:talon/x)
  assert_eq "depend: prints the path" "$out" "$repo/.todos/pending/2026-05-01-target-one.md"
  local want; want=$(mktemp)
  cat >"$want" <<'EOF'
---
created: 2026-05-01
title: Target with files
area: x
depends_on:
  - pr:2
  - branch:talon/x
files:
  - keep/me.py
---

## Problem

Body stays.
EOF
  diff -u "$want" "$repo/.todos/pending/2026-05-01-target-one.md" >/dev/null \
    && ok "depend: key inserted before files, rest byte-identical" \
    || bad "depend: key inserted before files, rest byte-identical" "$(diff -u "$want" "$repo/.todos/pending/2026-05-01-target-one.md")"
  ( cd "$repo" && bash "$TODOS" depend target-two pr:1 '#3' pr:3 >/dev/null )
  assert_eq "depend: appends and dedupes" "$(cd "$repo" && bash "$TODOS" _depends .todos/pending/2026-05-01-target-two.md)" \
    "$(printf 'pr:1\npr:3')"
  ( cd "$repo" && bash "$TODOS" depend 2026-05-01-target-three pr:4 >/dev/null )
  assert_contains "depend: key before closing --- when no files" \
    "$(cat "$repo/.todos/pending/2026-05-01-target-three.md")" "$(printf 'title: Target bare\ndepends_on:\n  - pr:4\n---')"
  assert_contains "depend: index regenerated" "$(cat "$repo/.todos/TODO.md")" "[unverified: pr:2, branch:talon/x]"
  assert_status "depend: no refs exits 1"     1 bash -c '(cd "$1" && bash "$2" depend target-one)' _ "$repo" "$TODOS"
  assert_status "depend: ambiguous target"    1 bash -c '(cd "$1" && bash "$2" depend target pr:5)' _ "$repo" "$TODOS"
  assert_status "depend: invalid ref"         1 bash -c '(cd "$1" && bash "$2" depend target-one parity)' _ "$repo" "$TODOS"
  assert_status "depend: completed target refused" 1 bash -c '(mkdir -p "$1/.todos/completed" && printf -- "---\ncreated: 2026-05-01\ntitle: c\n---\n" >"$1/.todos/completed/2026-05-01-closed.md" && cd "$1" && bash "$2" depend closed pr:5)' _ "$repo" "$TODOS"
  ok "depend: add refs"
  rm -rf "$repo"; rm -f "$want"
}
test_depend_add

test_depend_self() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-loop-me <<'EOF'
---
created: 2026-05-01
title: Loop me
---
EOF
  local errf; errf=$(mktemp)
  ( cd "$repo" && bash "$TODOS" depend loop-me todo:2026-05-01-loop-me ) >/dev/null 2>"$errf"
  assert_eq "depend: self by exact basename exits 1" "$?" "1"
  assert_contains "depend: self message" "$(cat "$errf")" "todos: a todo cannot depend on itself"
  assert_status "depend: self by substring exits 1" 1 bash -c '(cd "$1" && bash "$2" depend loop-me todo:loop)' _ "$repo" "$TODOS"
  assert_status "depend: self by bare id exits 1"   1 bash -c '(cd "$1" && bash "$2" depend loop-me 2026-05-01-loop-me)' _ "$repo" "$TODOS"
  case "$(cat "$repo/.todos/pending/2026-05-01-loop-me.md")" in *depends_on*) bad "depend: self writes nothing" "wrote";; *) ok "depend: self writes nothing";; esac
  ok "depend: refuses self-dependency"
  rm -rf "$repo"; rm -f "$errf"
}
test_depend_self

test_done_still_matches() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-finish-me <<'EOF'
---
created: 2026-05-01
title: Finish me
---
EOF
  local out; out=$(cd "$repo" && bash "$TODOS" done finish)
  assert_eq "done: substring still moves the todo" "$out" "done: 2026-05-01-finish-me.md"
  [ -e "$repo/.todos/completed/2026-05-01-finish-me.md" ] && ok "done: file moved" || bad "done: file moved" "missing"
  rm -rf "$repo"
}
test_done_still_matches
```

- [ ] **Step 2: Run the suite to see the new checks fail**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: `FAIL new: ...` (unknown flag `--depends-on`), `FAIL depend: ...` (unknown command), `ok done: ...` (unchanged behaviour).

- [ ] **Step 3: Add the write-path helpers**

Append to the dependencies block after `blocked_refs`:

```bash
find_pending() {
  # find_pending <query> -> path of the unique pending todo whose basename is
  # exactly <query> (sans .md) or contains it; dies when none or ambiguous.
  local query="$1" root pending f matches=()
  root=$(repo_root); pending="$root/$TODOS_DIRNAME/pending"
  if [ -e "$pending/$query.md" ]; then printf '%s\n' "$pending/$query.md"; return 0; fi
  for f in "$pending"/*.md; do
    [ -e "$f" ] || continue
    case "$(basename "$f")" in *"$query"*) matches+=("$f") ;; esac
  done
  [ "${#matches[@]}" -gt 0 ] || die "no pending todo matches '$query'"
  if [ "${#matches[@]}" -gt 1 ]; then
    printf 'todos: ambiguous; matches:\n' >&2
    for f in "${matches[@]}"; do printf '  %s\n' "$(basename "$f")" >&2; done
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

resolve_todo_payload() {
  # resolve_todo_payload <query> -> exact basename of the unique pending or
  # completed todo matching <query> (exact first, then substring); dies otherwise.
  local q="$1" root dir f matches=()
  root=$(repo_root)
  for dir in pending completed; do
    [ -e "$root/$TODOS_DIRNAME/$dir/$q.md" ] && { printf '%s\n' "$q"; return 0; }
  done
  for dir in pending completed; do
    for f in "$root/$TODOS_DIRNAME/$dir"/*.md; do
      [ -e "$f" ] || continue
      case "$(basename "$f" .md)" in *"$q"*) matches+=("$(basename "$f" .md)") ;; esac
    done
  done
  [ "${#matches[@]}" -gt 0 ] || die "dependency names no todo: '$q'"
  [ "${#matches[@]}" -eq 1 ] || die "ambiguous todo dependency '$q' (${#matches[@]} matches)"
  printf '%s\n' "${matches[0]}"
}

prepare_ref() {
  # prepare_ref <input> -> canonical ref for writing. A todo: payload may be a
  # substring; the stored form is the exact basename, which must exist.
  local in="$1" q ref
  in=$(printf '%s' "$in" | strip_value)
  case "$in" in
    todo:*) q="${in#todo:}"; q="${q%.md}"; q=$(resolve_todo_payload "$q") || exit 1; in="todo:$q" ;;
  esac
  ref=$(normalize_ref "$in") || die "invalid dependency ref '$1' (use todo:<id>, branch:<name>, or pr:<n>)"
  case "$ref" in
    todo:*) resolve_todo_payload "${ref#todo:}" >/dev/null || exit 1 ;;
  esac
  printf '%s\n' "$ref"
}

add_depends() {
  # add_depends <file> <canonical-ref>... -> append refs not already present
  # to the frontmatter depends_on block (created before files:, or before the
  # closing --- when there is no files: key). Atomic via temp file + mv.
  local f="$1"; shift
  local existing new="" ref raw
  existing=$(depends_list "$f" | while IFS= read -r raw; do normalize_ref "$raw" || printf '%s\n' "$raw"; done)
  for ref in "$@"; do
    printf '%s\n' "$existing" | grep -qxF -- "$ref" && continue
    printf '%s\n' "$new"      | grep -qxF -- "$ref" && continue
    new="${new:+$new
}$ref"
  done
  [ -n "$new" ] || return 0
  local tmp="$f.tmp.$$"
  awk -v items="$new" '
    BEGIN { cnt = split(items, arr, "\n") }
    function emit(   i) { for (i = 1; i <= cnt; i++) print "  - " arr[i]; done = 1 }
    /^---$/ { n++; if (n == 2 && !done) emit(); print; next }
    n == 1 && /^depends_on:/          { have = 1; inlist = 1; print; next }
    n == 1 && inlist && /^  - /       { print; next }
    n == 1 && inlist                  { inlist = 0; emit(); print; next }
    n == 1 && !have && !done && /^files:/ { print "depends_on:"; emit(); print; next }
    { print }
  ' "$f" >"$tmp" && mv "$tmp" "$f"
}
```

Note the literal newline inside `new="${new:+$new` ... `}$ref"`: bash 3.2 joins with a real newline; `$'\n'` in a parameter expansion default would also work but reads worse.

- [ ] **Step 4: Wire `new`, `depend`, `done`, `main`**

In `cmd_new`:

1. Extend the locals: `local area="" due="" surface="" priority="" files=() deps_in=() deps=() ref d`.
2. Add a flag case: `--depends-on) [ "$#" -ge 2 ] || die "--depends-on needs a value"; deps_in+=("$2"); shift 2 ;;`.
3. After the priority validation and before `ensure_init`, validate and dedupe the refs:

```bash
  if [ "${#deps_in[@]}" -gt 0 ]; then
    for d in "${deps_in[@]}"; do
      ref=$(prepare_ref "$d") || exit 1
      printf '%s\n' "${deps[@]:-}" | grep -qxF -- "$ref" && continue
      deps+=("$ref")
    done
  fi
```

4. After `file="$pending/$cand.md"` add the self guard:

```bash
  for ref in "${deps[@]:-}"; do
    [ "$ref" != "todo:$cand" ] || die "a todo cannot depend on itself"
  done
```

5. In the frontmatter `printf` block, between the `priority` line and `printf 'files:\n'`:

```bash
    if [ "${#deps[@]}" -gt 0 ]; then
      printf 'depends_on:\n'
      for ref in "${deps[@]}"; do printf '  - %s\n' "$ref"; done
    fi
```

`"${deps[@]:-}"` is the bash 3.2 idiom for expanding a possibly-empty array under `set -u`; the `[ "$ref" != ... ]` guard is harmless for the empty string.

Add `cmd_depend` after `cmd_done`:

```bash
cmd_depend() {
  [ "$#" -ge 1 ] || die "depend requires a slug or substring"
  local query="$1"; shift
  [ "$#" -ge 1 ] || die "depend requires at least one ref"
  local target base refs=() ref d
  target=$(find_pending "$query") || exit 1
  base=$(basename "$target" .md)
  for d in "$@"; do
    ref=$(prepare_ref "$d") || exit 1
    [ "$ref" != "todo:$base" ] || die "a todo cannot depend on itself"
    refs+=("$ref")
  done
  add_depends "$target" "${refs[@]}"
  regenerate_index
  printf '%s\n' "$target"
}
```

Replace the matching loop in `cmd_done` (from `local matches=() f` through the ambiguity `exit 1`) with `local f; f=$(find_pending "$query") || exit 1`, and use `"$f"` in place of `"${matches[0]}"` in the `mv` and the final `printf`. Behaviour change: an exact basename now wins over substring ambiguity; the substring path is unchanged (covered by `done: substring still moves the todo`).

In `main`: add `depend)   cmd_depend "$@" ;;` after `done)`, and add `depend` to the usage string: `{init|new|list|done|depend|index|share|path|register|repos|brief|today}`.

Header comment: change the `new` line to `todos.sh new "<title>" [--area A] [--file P]... [--depends-on REF]...`, the `list` line to `todos.sh list [--all] [--offline]   list pending (--all adds completed; --offline skips gh)`, and add `todos.sh depend <slug> REF...        add dependency refs (todo:<id> | branch:<name> | pr:<n>)` after the `done` line.

- [ ] **Step 5: Run the suite to see it pass**

Run: `bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | grep -E 'FAIL|passed'`
Expected: no `FAIL`. If `depend: key inserted before files, rest byte-identical` fails, the `bad` line prints the unified diff; the usual culprit is `emit()` firing twice (`done` not set) or the `files:` rule matching after `have`.

- [ ] **Step 6: Commit**

```bash
git -C "$WT" add claude/skills/todos/scripts/todos.sh claude/skills/todos/scripts/tests/todos_test.sh
git -C "$WT" commit -m "todos: Add new --depends-on and the depend command"
```

---

### Task 5: SKILL.md, full verification, and the backfill

**Files:**
- Modify: `claude/skills/todos/SKILL.md` (template block lines 18-36, Commands table lines 61-75, Common Mistakes table lines 100-107; new section after "Time model & the brief")
- Run: `bin/dotfiles-tests`, the task contract, the backfill commands

**Interfaces:**
- Consumes: everything above. Produces the documentation the contract's `skill-doc-pins` command greps for: the strings `depends_on:`, `--depends-on`, `todos.sh depend`, `pr:85`, `TODOS_OFFLINE`, `unverified`.

- [ ] **Step 1: Document the field and commands**

In the todo file template (inside the fenced block after `priority: ...`), add:

```
depends_on:
  - todo:<YYYY-MM-DD-slug>      another todo (exact basename, no .md)
  - branch:<name>               a git branch, satisfied when merged into origin/main
  - pr:<number>                 a GitHub PR, satisfied when merged
```

In the Commands table, change the `new` row's command to
`todos.sh new "<title>" [--area A] [--file P]... [--depends-on REF]...`, change the `list` row to
`todos.sh list [--all] [--offline]` with description
`List pending todos with blocked-on annotations (--all adds completed; --offline skips gh)`,
and add after the `done` row:

| `todos.sh depend <slug-or-substring> REF...` | Add dependency refs to a pending todo (`todo:<id>`, `branch:<name>`, `pr:<n>`); re-indexes |

Add this section after "Time model & the brief":

```markdown
## Dependencies

`depends_on:` lists what must land before a todo is actionable. Each ref
resolves to one state:

| State     | Means                                              | Satisfied |
| --------- | -------------------------------------------------- | --------- |
| `done`    | the todo is in `completed/`                        | yes       |
| `merged`  | branch is an ancestor of `origin/main`, or gh says MERGED | yes |
| `open`    | todo pending; branch not merged; PR open           | no        |
| `closed`  | PR closed without merging                          | no        |
| `missing` | no such todo                                       | no        |
| `unknown` | offline, `gh` absent or failing, no local ref      | no        |
| `invalid` | ref does not parse                                 | no        |
| `self`    | a todo naming itself                               | no        |

`todos.sh list` shows unsatisfied refs as `[blocked-on: <ref> (<state>)]`.
`TODO.md` is resolved offline (todos and local git refs only): refs that
are determinately unsatisfied appear under `[blocked-on: ...]`, refs the
index cannot verify (PRs, absent branches) under `[unverified: ...]`.

Network rule: only `list` may call `gh`, and `list --offline` (or
`TODOS_OFFLINE=1`) disables that. `new`, `done`, `depend`, and `index`
never touch the network. There is no timeout on `gh`; if the network
hangs, use `--offline`.

Squash merges never make a branch an ancestor of `origin/main`, so a
branch ref resolves `merged` only through `gh` (`gh pr list --head`),
whether or not the branch still exists locally; offline it reads `open`
while the local ref exists and `unknown` once `post-merge` deletes it.
Prefer a `pr:` ref once the PR number is known. `TODOS_BASE_REF`
(default `origin/main`) and `TODOS_GH` (default `gh`) are overrides for
tests and unusual setups.

The orchestrator does not read this field yet; a later task gates
kickoff on it. Until then it is advisory: read the annotation before
starting work on a blocked todo. Removing a dependency is a hand edit of
the todo's frontmatter followed by `todos.sh index`.
```

Add a Common Mistakes row:

| Writing `#85` unquoted in `depends_on:` | `#` starts a YAML comment; the item reads as empty | Use `pr:85` (the script writes this form) |

- [ ] **Step 2: Run the doc pins and the whole suite**

Run:

```bash
for s in 'depends_on:' '--depends-on' 'todos.sh depend' 'pr:85' 'TODOS_OFFLINE' 'unverified'; do grep -qF -- "$s" claude/skills/todos/SKILL.md && echo "pin ok: $s" || echo "pin MISSING: $s"; done
bash claude/skills/todos/scripts/tests/todos_test.sh 2>&1 | tail -1
bin/dotfiles-tests 2>&1 | tail -5
```

Expected: six `pin ok` lines; the todos suite reports 0 failed with a total above 60; `bin/dotfiles-tests` ends green (it runs every suite in the repo, which the other suites do not touch).

- [ ] **Step 3: Run the task contract**

Run:

```bash
python3 "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py" verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o \
  --worktree "$WT" \
  --contract claude/contracts/td-2026-09-06-add-task-dependencies-to-todos-and-gate-dispatch-o-contract.json \
  --allow-unpinned
```

Expected: every command prints `ok <name> exit=0`, exit 0. A failing `acN-*` command names the acceptance criterion whose `ok` label is missing; a failing `diff-scope` names a file outside the allowed set.

- [ ] **Step 4: Commit the docs**

```bash
git -C "$WT" add claude/skills/todos/SKILL.md
git -C "$WT" commit -m "todos: Document depends_on, depend, and list --offline"
```

- [ ] **Step 5: Backfill the live backlog**

`.todos` inside the worktree is a symlink to the live backlog, so these commands edit the real files (machine-local, git-excluded; nothing to commit). Run from the worktree root:

```bash
T=claude/skills/todos/scripts/todos.sh
for slug in \
  2026-09-06-add-a-fast-path-that-skips-the-plan-phase-for-smal \
  2026-09-06-adopt-a-tiered-loop-judge-and-pausing-budget-count \
  2026-09-06-block-worker-stops-until-the-completion-record-exi \
  2026-09-06-cut-orchestrator-wake-noise-to-record-writes-only \
  2026-09-06-keep-workers-alive-through-machine-sleep-and-hung \
  2026-09-06-scale-review-effort-to-diff-size \
  2026-09-06-size-plan-tasks-to-one-review-sitting-and-a-contex \
  2026-09-06-stop-worker-stalls-on-scratch-cleanup-by-avoiding; do
  bash "$T" depend "$slug" branch:talon/claude-codex-parity
done
bash "$T" depend 2026-09-05-improve-herd-task-labels-and-orchestrator-layout-a branch:talon/claude-codex-parity pr:85
bash "$T" depend 2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat todo:2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking
bash "$T" depend 2026-09-05-add-codex-adapter-to-the-shared-herd-orchestrator \
  todo:2026-09-05-activate-reviewed-claude-and-codex-parity pr:85 \
  todo:2026-09-05-serialize-shared-herd-ownership-and-completion \
  todo:2026-09-05-unify-frozen-code-and-document-review-inputs \
  todo:2026-09-05-resolve-review-models-and-effort-explicitly
bash "$T" list --offline
```

Expected `list --offline` output: eleven annotated lines. The nine parity todos show `branch:talon/claude-codex-parity (open)` while the local ref exists; the labels todo also shows `pr:85 (unknown)`; the scratch-policy todo shows `todo:2026-09-05-let-auto-mode-decide-rm-commands-instead-of-asking (open)`; the adapter todo shows its four todo refs `(open)` and `pr:85 (unknown)`. The rm-permission todo may already be completed by the time this runs; then its ref reads `done` and disappears from the annotation, which is correct. If a `depend` call dies with `no pending todo matches`, the todo was completed or renamed since 2026-09-06: skip it and report which.

- [ ] **Step 6: Report**

State in the completion report: final suite count against the 60/0 baseline, the contract result, the eleven backfilled todos (or which were skipped and why), and that the online `pr:85 (merged)` check was not run by the worker (the contract is offline by design; a human runs `todos.sh list` once on this machine).

---

## Self-review

- Spec coverage: D1 (Task 1), D2 read (Task 1) and write (Task 4), D3 (Task 2), D4 (Task 3), D5 (Task 4), D6 (Task 5), Backfill (Task 5 step 5), AC1-AC13 (mapping table above).
- Names used across tasks: `strip_value`, `normalize_ref`, `depends_list`, `TODO_ID_RE` (Task 1); `deps_offline`, `gh_state`, `map_gh_state`, `resolve_ref`, `resolve_cached`, `DEPS_CACHE`, `DEPS_OFFLINE` (Task 2); `blocked_refs`, `join_refs`, `DEPS_QUIET`, `list_dir` third argument (Task 3); `find_pending`, `resolve_todo_payload`, `prepare_ref`, `add_depends`, `cmd_depend` (Task 4). Each later task's code calls them by these names.
- Test labels the contract greps for, verbatim: `depends: parse block list`, `depends: normalize refs`, `resolve: todo states`, `resolve: branch states`, `resolve: pr states via gh stub`, `resolve: absent branch via gh stub`, `list: blocked-on annotation`, `index: blocked marker, no network`, `new: --depends-on`, `depend: add refs`, `depend: refuses self-dependency`, `list: invalid and self refs warn`.
