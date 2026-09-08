#!/usr/bin/env bash
# todos.sh - file-based todo tracker (post-GSD).
#
# Stores one markdown file per todo under <repo>/.todos/{pending,completed}/,
# named YYYY-MM-DD-<slug>.md, and regenerates <repo>/.todos/TODO.md as a
# glance-able index of open items.
#
# Local by default: `init` (and the first `new`) add `.todos/` to the repo's
# git exclude file so todos never reach the remote. `share` removes that line
# for repos where you DO want the backlog committed (e.g. personal projects).
#
# Worktree-aware: the exclude file is resolved via `git rev-parse --git-path`,
# so it lands in the shared common gitdir and applies across all worktrees.
#
# Usage:
#   todos.sh init                       set up .todos/ (local-only)
#   todos.sh new "<title>" [--area A] [--file P]... [--depends-on REF]...   create a pending todo
#   todos.sh list [--all] [--offline]   list pending (--all adds completed; --offline skips gh)
#   todos.sh ready <exact-id> [--offline|--online]   read-only dependency verdict as JSON
#   todos.sh done <slug-or-substring>   move a todo pending -> completed
#   todos.sh depend <slug> REF...        add dependency refs (todo:<id> | branch:<name> | pr:<n>)
#   todos.sh index                      regenerate TODO.md
#   todos.sh share                      stop ignoring .todos/ (commit in this repo)
#   todos.sh path                       print the .todos/ directory path

set -euo pipefail

TODOS_DIRNAME=".todos"

today() { printf '%s\n' "${TODOS_TODAY:-$(date +%Y-%m-%d)}"; }

registry_file() { printf '%s\n' "${TODOS_REGISTRY:-$HOME/.claude/todos/repos.txt}"; }

validate_date() {
  # Strict zero-padded YYYY-MM-DD AND a real calendar date.
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  local out
  out=$(date -j -f "%Y-%m-%d" "$1" "+%Y-%m-%d" 2>/dev/null) \
    || out=$(date -d "$1" "+%Y-%m-%d" 2>/dev/null) \
    || return 1
  # Round-trip catches BSD date normalizing e.g. 2026-02-30 -> 2026-03-02.
  [ "$out" = "$1" ]
}

date_shift() {
  # date_shift <YYYY-MM-DD> <signed-int-days> -> shifted YYYY-MM-DD
  local base="$1" days="$2" rel
  case "$days" in -*) rel="$days" ;; *) rel="+$days" ;; esac
  date -j -v"${rel}d" -f "%Y-%m-%d" "$base" "+%Y-%m-%d" 2>/dev/null && return 0
  date -d "$base $rel days" "+%Y-%m-%d" 2>/dev/null
}

die() { printf 'todos: %s\n' "$1" >&2; exit 1; }

canon() { realpath "$1" 2>/dev/null || printf '%s' "$1"; }

repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "not inside a git repository"
}

exclude_file() {
  # Resolves to <common-gitdir>/info/exclude even inside a linked worktree.
  local p
  p=$(git rev-parse --git-path info/exclude 2>/dev/null) || die "cannot locate git exclude file"
  printf '%s\n' "$p"
}

slugify() {
  # lowercase, non-alnum -> '-', squeeze, trim, cap at 50 chars, re-trim.
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' '-' \
    | tr -s '-' \
    | sed -e 's/^-//' -e 's/-$//' \
    | cut -c1-50 \
    | sed -e 's/-$//'
}

frontmatter_value() {
  # frontmatter_value <key> <file> -> first matching value, trimmed, with any
  # surrounding YAML quotes stripped (GSD quoted titles containing colons).
  sed -n "s/^$1:[[:space:]]*//p" "$2" | head -1 \
    | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

problem_summary() {
  # First non-empty line under "## Problem", truncated for the index.
  # Stops at the next "## " section so an empty Problem yields no summary
  # (rather than grabbing the "## Solution" heading).
  awk '
    /^## Problem/ { f = 1; next }
    f && /^## /   { exit }
    f && NF       { print; exit }
  ' "$1" | cut -c1-140
}

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

deps_offline() {
  # True when no network may be used: TODOS_OFFLINE set, or DEPS_OFFLINE=1
  # set in-process (list --offline; regenerate_index always).
  [ -n "${TODOS_OFFLINE:-}" ] || [ "${DEPS_OFFLINE:-0}" = 1 ]
}

gh_state() {
  # gh_state <gh args...> -> MERGED|OPEN|CLOSED on stdout, or nothing.
  # Never fails: a missing binary, non-zero exit, or odd output all print nothing.
  local gh="${TODOS_GH:-gh}" out remaining
  deps_offline && return 0
  command -v "$gh" >/dev/null 2>&1 || return 0
  if [ -n "${DEPS_GH_DEADLINE:-}" ]; then
    # ready shares one bounded budget across all calls. Never fall back to an
    # unbounded call when coreutils timeout is absent (macOS uses gtimeout).
    [ -n "${DEPS_TIMEOUT:-}" ] || return 0
    remaining=$((DEPS_GH_DEADLINE - SECONDS))
    [ "$remaining" -gt 0 ] || return 0
    out=$("$DEPS_TIMEOUT" --kill-after=1 "${remaining}s" "$gh" "$@" 2>/dev/null) || return 0
  else
    out=$("$gh" "$@" 2>/dev/null) || return 0
  fi
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
  local ref="$1" root kind payload base bref st rc pending completed candidate
  root=$(repo_root)
  kind="${ref%%:*}"; payload="${ref#*:}"
  case "$kind" in
    todo)
      if [ "${DEPS_STRICT:-0}" = 1 ]; then
        pending="$root/$TODOS_DIRNAME/pending/$payload.md"
        completed="$root/$TODOS_DIRNAME/completed/$payload.md"
        for candidate in "$pending" "$completed"; do
          if [ -e "$candidate" ] || [ -L "$candidate" ]; then
            if [ ! -f "$candidate" ] || [ ! -r "$candidate" ] || [ -L "$candidate" ]; then
              printf 'unknown\n'; return 0
            fi
          fi
        done
        if [ -e "$pending" ] && [ -e "$completed" ]; then
          printf 'unknown\n'; return 0
        fi
      fi
      if   [ -e "$root/$TODOS_DIRNAME/completed/$payload.md" ]; then printf 'done\n'
      elif [ -e "$root/$TODOS_DIRNAME/pending/$payload.md" ];   then printf 'open\n'
      else printf 'missing\n'; fi ;;
    branch)
      base="${TODOS_BASE_REF:-origin/main}"
      case "$base" in ''|-*|*@\{*) printf 'unknown\n'; return 0 ;; esac
      if ! git rev-parse --verify --quiet --end-of-options "$base^{commit}" >/dev/null 2>&1; then
        printf 'unknown\n'; return 0
      fi
      if   git show-ref --verify --quiet "refs/remotes/origin/$payload"; then bref="refs/remotes/origin/$payload"
      elif git show-ref --verify --quiet "refs/heads/$payload";          then bref="refs/heads/$payload"
      else bref=""; fi
      if [ -n "$bref" ]; then
        # exit 0 ancestor, 1 not an ancestor, >1 git error. The `|| rc=$?`
        # shape is required: a bare failing command would trip set -e.
        rc=0; git merge-base --is-ancestor "$bref" "$base" 2>/dev/null || rc=$?
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
  # Refs never contain spaces (branch names, todo ids, PR numbers), so the
  # new items travel to awk space-joined: BSD awk rejects a newline in -v.
  for ref in "$@"; do
    printf '%s\n' "$existing" | grep -qxF -- "$ref" && continue
    case " $new " in *" $ref "*) continue ;; esac
    new="${new:+$new }$ref"
  done
  [ -n "$new" ] || return 0
  local tmp="$f.tmp.$$"
  awk -v items="$new" '
    BEGIN { cnt = split(items, arr, " ") }
    function emit(   i) { for (i = 1; i <= cnt; i++) print "  - " arr[i]; done = 1 }
    /^---$/ { n++; if (n == 2 && !done) { if (!have) print "depends_on:"; emit() } print; next }
    n == 1 && /^depends_on:/          { have = 1; inlist = 1; print; next }
    n == 1 && inlist && /^  - /       { print; next }
    n == 1 && inlist                  { inlist = 0; emit(); print; next }
    n == 1 && !have && !done && /^files:/ { print "depends_on:"; emit(); print; next }
    { print }
  ' "$f" >"$tmp" && mv "$tmp" "$f"
}

join_refs() {
  # stdin "<ref>\t<state>" lines -> "ref (state), ref (state)" when $1 is 1,
  # "ref, ref" when 0. No trailing newline; empty for empty input.
  awk -F'\t' -v states="$1" '
    { item = (states == 1) ? $1 " (" $2 ")" : $1
      out = (NR == 1) ? item : out ", " item }
    END { printf "%s", out }'
}

ensure_init() {
  local root pending completed
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  completed="$root/$TODOS_DIRNAME/completed"
  mkdir -p "$pending" "$completed"

  # Local-only default: add .todos/ to the repo's git exclude unless already
  # present and unless the user has opted into committing it (share removes it,
  # so we only add when neither the ignore line nor a committed marker exists).
  local excl
  excl=$(exclude_file)
  if ! grep -qxF "$TODOS_DIRNAME/" "$excl" 2>/dev/null; then
    # Don't re-add if the dir is already tracked (user committed it deliberately).
    if ! git ls-files --error-unmatch "$TODOS_DIRNAME" >/dev/null 2>&1; then
      printf '%s/\n' "$TODOS_DIRNAME" >>"$excl"
    fi
  fi
}

cmd_init() {
  ensure_init
  local root; root=$(repo_root)
  printf 'Initialized %s/%s/ (local-only; run `todos.sh share` to commit it here)\n' "$root" "$TODOS_DIRNAME"
}

cmd_new() {
  [ "$#" -ge 1 ] || die 'new requires a "<title>"'
  local title="$1"; shift
  local area="" due="" surface="" priority="" files=() deps_in=() deps=() ref d
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --area)        [ "$#" -ge 2 ] || die "--area needs a value"; area="$2"; shift 2 ;;
      --file)        [ "$#" -ge 2 ] || die "--file needs a value"; files+=("$2"); shift 2 ;;
      --due)         [ "$#" -ge 2 ] || die "--due needs a value"; due="$2"; shift 2 ;;
      --surface)     [ "$#" -ge 2 ] || die "--surface needs a value"; surface="$2"; shift 2 ;;
      --priority)    [ "$#" -ge 2 ] || die "--priority needs a value"; priority="$2"; shift 2 ;;
      --depends-on)  [ "$#" -ge 2 ] || die "--depends-on needs a value"; deps_in+=("$2"); shift 2 ;;
      *) die "unknown flag for new: $1" ;;
    esac
  done

  [ -z "$due" ]     || validate_date "$due"     || die "invalid --due (need calendar YYYY-MM-DD): $due"
  [ -z "$surface" ] || validate_date "$surface" || die "invalid --surface (need calendar YYYY-MM-DD): $surface"
  case "$priority" in ''|high|med|low) ;; *) die "invalid --priority (high|med|low): $priority" ;; esac

  if [ "${#deps_in[@]}" -gt 0 ]; then
    for d in "${deps_in[@]}"; do
      ref=$(prepare_ref "$d") || exit 1
      printf '%s\n' "${deps[@]:-}" | grep -qxF -- "$ref" && continue
      deps+=("$ref")
    done
  fi

  ensure_init
  local root pending completed slug date base cand file n
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  completed="$root/$TODOS_DIRNAME/completed"
  slug=$(slugify "$title")
  [ -n "$slug" ] || slug="todo"
  date=$(today)
  base="$date-$slug"
  # Avoid a name that collides with a pending OR a completed todo: reusing a
  # completed basename would let a later `done` overwrite that completed record.
  cand="$base"; n=2
  while [ -e "$pending/$cand.md" ] || [ -e "$completed/$cand.md" ]; do
    cand="$base-$n"; n=$((n + 1))
  done
  file="$pending/$cand.md"

  for ref in "${deps[@]:-}"; do
    [ "$ref" != "todo:$cand" ] || die "a todo cannot depend on itself"
  done

  {
    printf -- '---\n'
    printf 'created: %s\n' "$date"
    printf 'title: %s\n' "$title"
    [ -n "$area" ]     && printf 'area: %s\n' "$area"
    [ -n "$due" ]      && printf 'due: %s\n' "$due"
    [ -n "$surface" ]  && printf 'surface: %s\n' "$surface"
    [ -n "$priority" ] && printf 'priority: %s\n' "$priority"
    if [ "${#deps[@]}" -gt 0 ]; then
      printf 'depends_on:\n'
      for ref in "${deps[@]}"; do printf '  - %s\n' "$ref"; done
    fi
    printf 'files:\n'
    if [ "${#files[@]}" -gt 0 ]; then
      for f in "${files[@]}"; do printf '  - %s\n' "$f"; done
    fi
    printf -- '---\n\n'
    printf '## Problem\n\n\n\n'
    printf '## Solution\n\n\n'
  } >"$file"

  regenerate_index
  printf '%s\n' "$file"
}

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

ready_error() {
  jq -cn --arg task_id "$1" --arg error "$2" \
    '{ready:false,task_id:$task_id,dependencies:[],error:$error}'
  return 2
}

ready_frontmatter_valid() {
  # The existing resolver reads a contiguous block list. Reject shapes that
  # it would silently skip, rather than treating malformed dependencies as [].
  awk '
    NR == 1 && $0 != "---" { bad = 1; exit }
    /^---$/ { n++; if (n == 2) exit; next }
    n == 1 && /^depends_on:/ {
      if (seen++ || $0 !~ /^depends_on:[[:space:]]*(\[\])?[[:space:]]*$/) bad = 1
      f = 1; next
    }
    n == 1 && f && /^  - / {
      if ($0 ~ /^  - [[:space:]]*$/) bad = 1
      next
    }
    n == 1 && f {
      if ($0 !~ /^[a-zA-Z_][a-zA-Z_0-9]*:/) bad = 1
      f = 0
    }
    END { exit (bad || n != 2) }
  ' "$1"
}

cmd_ready() {
  # No initialization, index/registry access, temporary cache, or locks.
  local task_id="${1:-}" root target raw ref st result=0 dependencies='[]'
  local DEPS_OFFLINE=1 DEPS_STRICT=1 DEPS_CACHE='' DEPS_GH_DEADLINE='' DEPS_TIMEOUT=''
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' '{"ready":false,"task_id":null,"dependencies":[],"error":"jq_required"}'
    return 2
  }
  [[ "$task_id" =~ $TODO_ID_RE ]] && validate_date "${task_id:0:10}" \
    || { ready_error "$task_id" invalid_task_id; return 2; }
  shift
  if [ "$#" -gt 1 ]; then ready_error "$task_id" invalid_arguments; return 2; fi
  case "${1:---offline}" in
    --offline) ;;
    --online)
      DEPS_OFFLINE=0
      DEPS_GH_DEADLINE=$((SECONDS + 5))
      DEPS_TIMEOUT=$(command -v timeout || command -v gtimeout || true) ;;
    *) ready_error "$task_id" invalid_arguments; return 2 ;;
  esac
  root=$(git rev-parse --show-toplevel 2>/dev/null) \
    || { ready_error "$task_id" missing_repository; return 2; }
  target="$root/$TODOS_DIRNAME/pending/$task_id.md"
  if [ ! -f "$target" ] || [ ! -r "$target" ] || [ -L "$target" ] \
    || [ -e "$root/$TODOS_DIRNAME/completed/$task_id.md" ]; then
    ready_error "$task_id" missing_or_ambiguous_pending_task; return 2
  fi
  ready_frontmatter_valid "$target" \
    || { ready_error "$task_id" invalid_dependencies; return 2; }
  while IFS= read -r raw; do
    if ref=$(normalize_ref "$raw"); then st=$(resolve_cached "$ref" "$task_id")
    else ref="$raw"; st=invalid; fi
    case "$st" in done|merged) ;; *) result=3 ;; esac
    dependencies=$(jq -cn --argjson prior "$dependencies" --arg ref "$ref" --arg state "$st" \
      '$prior + [{ref:$ref,state:$state}]')
  done < <(depends_list "$target")
  jq -cn --arg task_id "$task_id" --argjson dependencies "$dependencies" --argjson status "$result" \
    '{ready:($status == 0),task_id:$task_id,dependencies:$dependencies}'
  return "$result"
}

cmd_done() {
  [ "$#" -ge 1 ] || die "done requires a slug or substring"
  local query="$1"
  local root pending completed
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  completed="$root/$TODOS_DIRNAME/completed"

  local f; f=$(find_pending "$query") || exit 1

  mkdir -p "$completed"
  mv "$f" "$completed/$(basename "$f")"
  regenerate_index
  printf 'done: %s\n' "$(basename "$f")"
}

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

regenerate_index() {
  local root pending index f title due priority created base summary key pw blocked unverified
  local DEPS_OFFLINE=1 DEPS_QUIET=1 DEPS_CACHE
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  index="$root/$TODOS_DIRNAME/TODO.md"
  [ -d "$pending" ] || return 0

  local data; data=$(mktemp); DEPS_CACHE=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$data' '$DEPS_CACHE'" RETURN
  for f in "$pending"/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    title=$(frontmatter_value title "$f"); title="${title:-$base}"
    due=$(frontmatter_value due "$f")
    priority=$(frontmatter_value priority "$f")
    created=$(frontmatter_value created "$f")
    summary=$(problem_summary "$f")
    blocked=$(blocked_refs "$f" | awk -F'\t' '$2 != "unknown"' | join_refs 0)
    unverified=$(blocked_refs "$f" | awk -F'\t' '$2 == "unknown"' | join_refs 0)
    case "$priority" in high) pw=0;; med) pw=1;; low) pw=2;; *) pw=3;; esac
    if [ -n "$due" ]; then key="0$due$pw"; else key="1$pw${created:-9999-99-99}"; fi
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$key" "$base" "$title" "$due" "$priority" "$blocked" "$unverified" "$summary" >>"$data"
  done

  local sep; sep=$(printf '\037')
  local tmp="$index.tmp.$$"
  {
    printf '# TODOs\n\n'
    printf 'Auto-generated from `.todos/pending/` by the todos skill. Do not edit by hand.\n\n'
    printf '## Open\n\n'
    if [ ! -s "$data" ]; then
      printf '_No open todos._\n'
    else
      local k b t d p bl uv s meta
      while IFS=$'\037' read -r k b t d p bl uv s; do
        meta=""
        [ -n "$d" ] && meta="$meta due $d"
        [ -n "$p" ] && meta="$meta [$p]"
        [ -n "$bl" ] && meta="$meta [blocked-on: $bl]"
        [ -n "$uv" ] && meta="$meta [unverified: $uv]"
        if [ -n "$s" ]; then
          printf -- '- [%s](./pending/%s)%s -- %s\n' "$t" "$b" "$meta" "$s"
        else
          printf -- '- [%s](./pending/%s)%s\n' "$t" "$b" "$meta"
        fi
      done < <(sort -t"$sep" -k1,1 "$data")
    fi
  } >"$tmp"
  mv "$tmp" "$index"
}

cmd_index() { regenerate_index; printf 'regenerated %s/%s/TODO.md\n' "$(repo_root)" "$TODOS_DIRNAME"; }

cmd_share() {
  local excl tmp root
  root=$(repo_root)
  excl=$(exclude_file)
  if [ -f "$excl" ] && grep -qxF "$TODOS_DIRNAME/" "$excl"; then
    tmp="$excl.tmp.$$"
    # `|| true`: when .todos/ is the only line, grep -v emits nothing and exits
    # 1 (no lines matched), which is success here — without this, set -e aborts
    # before the mv and `share` silently no-ops, leaking the temp file.
    grep -vxF "$TODOS_DIRNAME/" "$excl" >"$tmp" || true
    mv "$tmp" "$excl"
  fi
  printf '%s/ is no longer git-ignored in this repo; it will be committed when you `git add` it.\n' "$TODOS_DIRNAME"
}

cmd_path() { printf '%s/%s\n' "$(repo_root)" "$TODOS_DIRNAME"; }

# Emit one tab-separated row or nothing. Row: bucket \t pw \t sortkey \t name \t title \t when \t priority
process_todo() {
  local f="$1" name="$2" today="$3" soon_end="$4" stale_cut="$5"
  if [ ! -r "$f" ]; then
    printf 'todos: skipping unreadable todo: %s\n' "$f" >&2
    return 0
  fi
  local created due surface priority title
  created=$(frontmatter_value created "$f")
  title=$(frontmatter_value title "$f")
  due=$(frontmatter_value due "$f")
  surface=$(frontmatter_value surface "$f")
  priority=$(frontmatter_value priority "$f")

  if [ -z "$created" ] || [ -z "$title" ]; then
    printf 'todos: skipping malformed todo (missing created/title): %s\n' "$f" >&2
    return 0
  fi
  if ! validate_date "$created"; then
    printf 'todos: skipping todo with invalid created (%s): %s\n' "$created" "$f" >&2
    return 0
  fi
  if [ -n "$due" ] && ! validate_date "$due"; then
    printf 'todos: ignoring invalid due (%s) in %s\n' "$due" "$f" >&2; due=""
  fi
  if [ -n "$surface" ] && ! validate_date "$surface"; then
    printf 'todos: ignoring invalid surface (%s) in %s\n' "$surface" "$f" >&2; surface=""
  fi
  case "$priority" in high|med|low|'') ;;
    *) printf 'todos: ignoring invalid priority (%s) in %s\n' "$priority" "$f" >&2; priority="" ;;
  esac

  local pw; case "$priority" in high) pw=0;; med) pw=1;; low) pw=2;; *) pw=3;; esac

  if [ -n "$surface" ] && [[ "$surface" > "$today" ]]; then return 0; fi

  local bucket sortkey when
  if [ -n "$due" ] && [[ "$due" < "$today" ]]; then
    bucket=1; sortkey="$due"; when="due $due"
  elif [ -n "$due" ] && [ "$due" = "$today" ]; then
    bucket=2; sortkey="$due"; when="due today"
  elif [ -n "$surface" ] && [ "$surface" = "$today" ]; then
    bucket=2; sortkey="$today"; when="surface today"
  elif [ -n "$due" ] && [[ "$due" > "$today" ]] && ! [[ "$due" > "$soon_end" ]]; then
    bucket=3; sortkey="$due"; when="due $due"
  elif [ "$priority" = "high" ]; then
    bucket=4; sortkey="${due:-$created}"; when="${due:+due $due}"
  elif [ -z "$due" ] && ! [[ "$created" > "$stale_cut" ]]; then
    bucket=5; sortkey="$created"; when="created $created"
  else
    return 0
  fi

  printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$bucket" "$pw" "$sortkey" "$name" "$title" "$when" "$priority"
}

render_bucket() {
  local want="$1" header="$2" sorted="$3" cap="${4:-0}"
  local total shown=0 b pw sk name title when prio tag meta
  total=$(printf '%s\n' "$sorted" | awk -F'\037' -v b="$want" 'NF>=7 && $1==b' | grep -c . || true)
  [ "$total" -gt 0 ] || return 0
  printf '%s\n' "$header"
  while IFS=$'\037' read -r b pw sk name title when prio; do
    [ "$b" = "$want" ] || continue
    if [ "$cap" -gt 0 ] && [ "$shown" -ge "$cap" ]; then continue; fi
    tag=""; [ -n "$prio" ] && tag="  [$prio]"
    meta=""; [ -n "$when" ] && meta="  $when"
    printf '  %-14s %s%s%s\n' "$name" "$title" "$meta" "$tag"
    shown=$((shown+1))
  done <<INNER
$sorted
INNER
  if [ "$cap" -gt 0 ] && [ "$total" -gt "$cap" ]; then
    printf '  +%d more %s\n' "$((total-cap))" "$(printf '%s' "$header" | tr '[:upper:]' '[:lower:]')"
  fi
}

render_brief() {
  local rows="$1" today="$2" stale_cap="$3"
  if [ ! -s "$rows" ]; then printf 'Nothing time-relevant today.\n'; return 0; fi
  local sep sorted; sep=$(printf '\037')
  sorted=$(sort -t"$sep" -k1,1n -k2,2n -k3,3 "$rows")
  printf 'Brief -- %s\n\n' "$today"
  render_bucket 1 "Overdue"                 "$sorted"
  render_bucket 2 "Today"                   "$sorted"
  render_bucket 4 "Flagged (high priority)" "$sorted"
  render_bucket 3 "Due soon"                "$sorted"
  render_bucket 5 "Stale"                   "$sorted" "$stale_cap"
}

cmd_brief() {
  local soon=3 stale=14 stale_cap=5
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --soon)
        [ "$#" -ge 2 ] || die "--soon needs a value"
        case "$2" in ''|*[!0-9]*) die "--soon needs a non-negative integer: $2" ;; esac
        soon="$2"; shift 2 ;;
      --stale)
        [ "$#" -ge 2 ] || die "--stale needs a value"
        case "$2" in ''|*[!0-9]*) die "--stale needs a non-negative integer: $2" ;; esac
        stale="$2"; shift 2 ;;
      --stale-cap)
        [ "$#" -ge 2 ] || die "--stale-cap needs a value"
        case "$2" in ''|*[!0-9]*) die "--stale-cap needs a non-negative integer: $2" ;; esac
        stale_cap="$2"; shift 2 ;;
      *) die "unknown flag for brief: $1" ;;
    esac
  done

  local reg; reg=$(registry_file)
  if [ ! -s "$reg" ]; then
    printf 'No repos registered (run `todos.sh register`).\n'; return 0
  fi

  local td soon_end stale_cut
  td=$(today)
  soon_end=$(date_shift "$td" "$soon")
  stale_cut=$(date_shift "$td" "-$stale")

  local rows; rows=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$rows'" RETURN
  local line repo name pend f seen=""
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    repo=$(canon "$line")
    case "$seen" in *"|$repo|"*) continue ;; esac
    seen="$seen|$repo|"
    [ -d "$repo" ] || { printf 'todos: registered repo missing: %s\n' "$repo" >&2; continue; }
    pend="$repo/$TODOS_DIRNAME/pending"
    [ -d "$pend" ] || continue
    name=$(basename "$repo")
    for f in "$pend"/*.md; do
      [ -e "$f" ] || continue
      process_todo "$f" "$name" "$td" "$soon_end" "$stale_cut" >>"$rows"
    done
  done <"$reg"

  render_brief "$rows" "$td" "$stale_cap"
}

cmd_register() {
  local root; root=$(repo_root)          # dies for non-git
  root=$(canon "$root")
  local reg; reg=$(registry_file)
  mkdir -p "$(dirname "$reg")"; touch "$reg"
  local line
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    if [ "$(canon "$line")" = "$root" ]; then
      printf 'already registered: %s\n' "$root"; return 0
    fi
  done <"$reg"
  printf '%s\n' "$root" >>"$reg"
  printf 'registered: %s\n' "$root"
}

cmd_repos() {
  local reg; reg=$(registry_file)
  [ -s "$reg" ] || { printf 'No repos registered (run `todos.sh register`).\n'; return 0; }
  local line r
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    r=$(canon "$line")
    if [ -d "$r" ]; then printf '%s\n' "$r"; else printf '%s  (missing)\n' "$r"; fi
  done <"$reg"
}

main() {
  [ "$#" -ge 1 ] || die "usage: todos.sh {init|new|list|ready|done|depend|index|share|path|register|repos|brief|today} ..."
  local cmd="$1" ref; shift
  case "$cmd" in
    init)     cmd_init "$@" ;;
    new)      cmd_new "$@" ;;
    list)     cmd_list "$@" ;;
    ready)    cmd_ready "$@" ;;
    done)     cmd_done "$@" ;;
    depend)   cmd_depend "$@" ;;
    index)    cmd_index "$@" ;;
    share)    cmd_share "$@" ;;
    path)     cmd_path "$@" ;;
    today)    today ;;
    register) cmd_register "$@" ;;
    repos)    cmd_repos "$@" ;;
    brief)    cmd_brief "$@" ;;
    _validate_date) validate_date "${1:-}" ;;
    _date_shift) date_shift "${1:-}" "${2:-}" ;;
    _normalize_ref) normalize_ref "${1:-}" ;;
    _depends) depends_list "${1:-}" ;;
    _resolve) if ref=$(normalize_ref "${1:-}"); then resolve_ref "$ref"; else printf 'invalid\n'; fi ;;
    *)        die "unknown command: $cmd" ;;
  esac
}

main "$@"
