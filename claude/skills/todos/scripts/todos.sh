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
#   todos.sh new "<title>" [--area A] [--file P]...   create a pending todo
#   todos.sh list [--all]               list pending (--all also lists completed)
#   todos.sh done <slug-or-substring>   move a todo pending -> completed
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
  local area="" due="" surface="" priority="" files=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --area)     [ "$#" -ge 2 ] || die "--area needs a value"; area="$2"; shift 2 ;;
      --file)     [ "$#" -ge 2 ] || die "--file needs a value"; files+=("$2"); shift 2 ;;
      --due)      [ "$#" -ge 2 ] || die "--due needs a value"; due="$2"; shift 2 ;;
      --surface)  [ "$#" -ge 2 ] || die "--surface needs a value"; surface="$2"; shift 2 ;;
      --priority) [ "$#" -ge 2 ] || die "--priority needs a value"; priority="$2"; shift 2 ;;
      *) die "unknown flag for new: $1" ;;
    esac
  done

  [ -z "$due" ]     || validate_date "$due"     || die "invalid --due (need calendar YYYY-MM-DD): $due"
  [ -z "$surface" ] || validate_date "$surface" || die "invalid --surface (need calendar YYYY-MM-DD): $surface"
  case "$priority" in ''|high|med|low) ;; *) die "invalid --priority (high|med|low): $priority" ;; esac

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

  {
    printf -- '---\n'
    printf 'created: %s\n' "$date"
    printf 'title: %s\n' "$title"
    [ -n "$area" ]     && printf 'area: %s\n' "$area"
    [ -n "$due" ]      && printf 'due: %s\n' "$due"
    [ -n "$surface" ]  && printf 'surface: %s\n' "$surface"
    [ -n "$priority" ] && printf 'priority: %s\n' "$priority"
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
  local dir="$1" label="$2" f title
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
    printf '  %-44s %s\n' "$(basename "$f")" "${title:-}"
  done
}

cmd_list() {
  local all=0
  [ "${1:-}" = "--all" ] && all=1
  local root; root=$(repo_root)
  list_dir "$root/$TODOS_DIRNAME/pending" "pending"
  [ "$all" -eq 1 ] && list_dir "$root/$TODOS_DIRNAME/completed" "completed"
}

cmd_done() {
  [ "$#" -ge 1 ] || die "done requires a slug or substring"
  local query="$1"
  local root pending completed
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  completed="$root/$TODOS_DIRNAME/completed"

  local matches=() f
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

  mkdir -p "$completed"
  mv "${matches[0]}" "$completed/$(basename "${matches[0]}")"
  regenerate_index
  printf 'done: %s\n' "$(basename "${matches[0]}")"
}

regenerate_index() {
  local root pending index f title due priority created base summary key pw
  root=$(repo_root)
  pending="$root/$TODOS_DIRNAME/pending"
  index="$root/$TODOS_DIRNAME/TODO.md"
  [ -d "$pending" ] || return 0

  local data; data=$(mktemp); trap "rm -f '$data'" RETURN
  for f in "$pending"/*.md; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    title=$(frontmatter_value title "$f"); title="${title:-$base}"
    due=$(frontmatter_value due "$f")
    priority=$(frontmatter_value priority "$f")
    created=$(frontmatter_value created "$f")
    summary=$(problem_summary "$f")
    case "$priority" in high) pw=0;; med) pw=1;; low) pw=2;; *) pw=3;; esac
    if [ -n "$due" ]; then key="0$due$pw"; else key="1$pw${created:-9999-99-99}"; fi
    printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$key" "$base" "$title" "$due" "$priority" "$summary" >>"$data"
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
      local k b t d p s meta
      while IFS=$'\037' read -r k b t d p s; do
        meta=""
        [ -n "$d" ] && meta="$meta due $d"
        [ -n "$p" ] && meta="$meta [$p]"
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
  [ "$#" -ge 1 ] || die "usage: todos.sh {init|new|list|done|index|share|path|register|repos|brief|today} ..."
  local cmd="$1"; shift
  case "$cmd" in
    init)     cmd_init "$@" ;;
    new)      cmd_new "$@" ;;
    list)     cmd_list "$@" ;;
    done)     cmd_done "$@" ;;
    index)    cmd_index "$@" ;;
    share)    cmd_share "$@" ;;
    path)     cmd_path "$@" ;;
    today)    today ;;
    register) cmd_register "$@" ;;
    repos)    cmd_repos "$@" ;;
    brief)    cmd_brief "$@" ;;
    _validate_date) validate_date "${1:-}" ;;
    _date_shift) date_shift "${1:-}" "${2:-}" ;;
    *)        die "unknown command: $cmd" ;;
  esac
}

main "$@"
