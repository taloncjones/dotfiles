#!/usr/bin/env bash
# exocortex.sh - wire the private exocortex todo store into the personal scope.
#
#   exocortex.sh install                 clone if reachable, move .todos aside,
#                                        link it into the store, import it
#   exocortex.sh resolve --cwd DIR       print the clone path when DIR and the
#                                        environment are personal; exit 3 if not
#   exocortex.sh seed --decisions-from FILE [--date YYYY-MM-DD]   first commit
#
# Personal scope only. Nothing under claude/, codex/, zsh/, bin/ or git/ may
# name this store: work sessions load those files. See install-layout.md.
set -u

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../.." && pwd)"
CONTEXT_PY="$REPO_ROOT/claude/skills/lib/workflow_context.py"
TODOS_SH="$REPO_ROOT/claude/skills/todos/scripts/todos.sh"
HELPER_PY="$HERE/exocortex.py"
EXO_DIR="$HOME/Git/personal/exocortex"
EXO_KEY=dotfiles
STORE_SUBDIR="repos/$EXO_KEY/.todos"
DEFAULT_REMOTE="git@github.com:taloncjones/exocortex.git"

say()  { printf '[exocortex] %s\n' "$1"; }
warn() { printf '[exocortex] WARNING: %s\n' "$1" >&2; }
skip() { say "skip: $1"; exit 0; }
die()  { printf '[exocortex] ERROR: %s\n' "$1" >&2; exit 1; }
canon() { realpath "$1" 2>/dev/null || printf '%s' "$1"; }

remote_url() {
  local r="${EXOCORTEX_REMOTE:-}"
  if [ -n "$r" ]; then
    case "$r" in /*) if [ -d "$r" ]; then printf '%s\n' "$r"; return; fi ;; esac
    warn "ignoring EXOCORTEX_REMOTE (only an existing local directory is accepted)"
  fi
  printf '%s\n' "$DEFAULT_REMOTE"
}

personal_env() {
  local cfg="${CLAUDE_CONFIG_DIR:-}"
  [ -z "$cfg" ] || [ "$(canon "$cfg")" = "$(canon "$HOME/.claude")" ]
}

personal_scope() {
  # personal_scope <dir>: the environment and <dir>'s repository are personal.
  personal_env || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 "$CONTEXT_PY" account-scope --cwd "$1" --runtime claude 2>/dev/null \
    | python3 -c 'import json, sys
d = json.load(sys.stdin)
sys.exit(0 if d.get("kind") == "personal" and d.get("personal_repository") is True else 1)' 2>/dev/null
}

net_git() {
  # net_git <git args...>: a bounded, non-interactive network git call.
  local to
  to=$(command -v timeout || command -v gtimeout || true)
  if [ -n "$to" ]; then
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=5" \
      "$to" --kill-after=2 10s git "$@"
  else
    GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh} -o BatchMode=yes -o ConnectTimeout=5" \
      git "$@"
  fi
}

is_primary() {
  local c; c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$(canon "$c")" = "$(canon "$1/.git")" ]
}

clean_stale_clones() {
  local d pid
  for d in "$HOME/Git/personal"/.exocortex.clone.*; do
    [ -d "$d" ] || continue
    pid="${d##*.}"
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null && continue
    rm -rf "$d"
  done
}

lone_seed() {
  # The clone holds only its own `exocortex: seed` commit, on a branch.
  git -C "$EXO_DIR" symbolic-ref -q HEAD >/dev/null \
    && [ "$(git -C "$EXO_DIR" rev-list --count HEAD)" = 1 ] \
    && [ "$(git -C "$EXO_DIR" log -1 --format=%s)" = "exocortex: seed" ]
}

refresh_empty_clone() {
  # A clone of an empty remote: check out the remote branch once one exists.
  local branch
  net_git -C "$EXO_DIR" fetch --quiet origin >/dev/null 2>&1 || true
  branch=main
  git -C "$EXO_DIR" rev-parse --verify --quiet refs/remotes/origin/main >/dev/null || \
    branch=$(git -C "$EXO_DIR" for-each-ref --format='%(refname:lstrip=3)' refs/remotes/origin | grep -v '^HEAD$' | head -1)
  [ -n "$branch" ] || skip "store has no commits; run seed"
  git -C "$EXO_DIR" checkout --quiet -B "$branch" --track "origin/$branch" >/dev/null 2>&1 \
    || skip "untracked files in $EXO_DIR (leftover seed output) block the checkout of origin/$branch; remove them, or the commit-less clone, and rerun install"
}

ensure_clone() {
  local url tmp
  url=$(remote_url)
  clean_stale_clones
  if [ -e "$EXO_DIR" ] && [ ! -d "$EXO_DIR/.git" ]; then skip "$EXO_DIR exists but is not a git clone"; fi
  if [ ! -d "$EXO_DIR/.git" ]; then
    net_git ls-remote "$url" >/dev/null 2>&1 || skip "remote unreachable"
    tmp="$HOME/Git/personal/.exocortex.clone.$$"
    net_git clone --quiet "$url" "$tmp" >/dev/null 2>&1 || { rm -rf "$tmp"; skip "clone failed"; }
    python3 "$HELPER_PY" rename "$tmp" "$EXO_DIR" || { rm -rf "$tmp"; skip "$EXO_DIR appeared during the clone"; }
    say "cloned $url"
  fi
  [ "$(git -C "$EXO_DIR" remote get-url origin 2>/dev/null)" = "$url" ] || skip "$EXO_DIR origin is not $url"
  git -C "$EXO_DIR" config todos.store true
  git -C "$EXO_DIR" rev-parse --verify --quiet HEAD >/dev/null || refresh_empty_clone
  if ! git -C "$EXO_DIR" rev-parse --verify --quiet '@{u}' >/dev/null 2>&1; then
    lone_seed && skip "seed was not pushed; run seed"
    skip "store HEAD has no upstream (detached or tracking lost); fix in $EXO_DIR"
  fi
}

audit_links() {
  local real l
  real=$(canon "$EXO_DIR")
  { find -P "$HOME/.claude-work" -type l 2>/dev/null
    for l in "$HOME"/Git/work/*/.todos; do [ -L "$l" ] && printf '%s\n' "$l"; done
  } | while IFS= read -r l; do
    case "$(canon "$l")" in "$real"|"$real"/*) warn "$l links into $EXO_DIR" ;; esac
  done
}

import_backups() {
  local state="$1" d pid rc
  [ -d "$state" ] || return 0
  for d in "$state"/*; do
    [ -d "$d" ] || continue
    case "$d" in *.imported) continue ;; esac
    if [ ! -d "$d/todos" ]; then
      pid="${d##*-}"
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      kill -0 "$pid" 2>/dev/null || rmdir "$d" 2>/dev/null || true
      continue
    fi
    rc=0; (cd "$DOTFILEDIR" && bash "$TODOS_SH" import "$d/todos") >/dev/null || rc=$?
    if [ "$rc" -eq 0 ]; then
      python3 "$HELPER_PY" rename "$d" "$d.imported" && say "imported $d"
    else
      warn "import of $d failed (exit $rc); kept for the next run"
    fi
  done
}

link_and_import() {
  local todos="$DOTFILEDIR/.todos" store="$EXO_DIR/$STORE_SUBDIR" state backup
  state="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/todos-import"
  if [ -L "$todos" ]; then
    [ "$(readlink "$todos")" = "$store" ] || skip ".todos links elsewhere ($(readlink "$todos"))"
  elif [ -d "$todos" ]; then
    mkdir -p "$state"
    backup="$state/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir "$backup" || skip "cannot create $backup"
    if ! python3 "$HELPER_PY" rename "$todos" "$backup/todos"; then
      rmdir "$backup" 2>/dev/null || true
      skip "cannot move .todos to $backup (another volume?)"
    fi
    say "moved .todos to $backup/todos"
  elif [ -e "$todos" ]; then
    skip ".todos is neither a directory nor a link"
  fi
  mkdir -p "$store/pending" "$store/completed"
  if [ ! -L "$todos" ]; then
    python3 "$HELPER_PY" link "$store" "$todos" || skip ".todos reappeared; rerun install"
    say "linked .todos -> $store"
  fi
  import_backups "$state"
}

cmd_resolve() {
  [ "${1:-}" = --cwd ] && [ -n "${2:-}" ] || die "usage: exocortex.sh resolve --cwd DIR"
  personal_scope "$2" || exit 3
  printf '%s\n' "$EXO_DIR"
}

cmd_install() {
  DOTFILEDIR="${DOTFILEDIR:-$REPO_ROOT}"
  [ -z "${CLAUDE_CODE_REMOTE:-}" ] || skip "cloud container"
  personal_scope "$DOTFILEDIR" || skip "$DOTFILEDIR is not in the personal scope"
  is_primary "$DOTFILEDIR" || skip "$DOTFILEDIR is not the primary checkout"
  ensure_clone
  audit_links
  link_and_import
}

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  *) die "usage: exocortex.sh {install|resolve --cwd DIR|seed --decisions-from FILE [--date YYYY-MM-DD]}" ;;
esac
