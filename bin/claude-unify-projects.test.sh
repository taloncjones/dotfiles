#!/usr/bin/env bash
# Tests for bin/claude-unify-projects. Fixture trees only -- never live roots.
set -u
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
UNIFY="$SCRIPT_DIR/claude-unify-projects"
pass=0; fail=0
ok()   { echo "[OK] $1"; pass=$((pass+1)); }
bad()  { echo "[X] $1"; fail=$((fail+1)); }
check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}
fixture() { # fresh personal/work roots; echoes base dir
  local base; base="$(mktemp -d)"
  mkdir -p "$base/personal" "$base/work"
  echo "$base"
}
run_link() { # run_link <base> [extra args...]
  local base="$1"; shift
  python3 "$UNIFY" --personal-root "$base/personal" --work-root "$base/work" "$@"
}

# --- link mode ---
base="$(fixture)"
run_link "$base" >/dev/null 2>&1
check "link: absent work trees become symlinks" test -L "$base/work/projects"
check "link: file-history linked too" test -L "$base/work/file-history"
check "link: canonical dirs created" test -d "$base/personal/projects"
[ "$(readlink "$base/work/projects")" = "$base/personal/projects" ] \
  && ok "link: symlink targets personal root" || bad "link: symlink targets personal root"
run_link "$base" >/dev/null 2>&1 && ok "link: rerun is a no-op (exit 0)" || bad "link: rerun is a no-op (exit 0)"

base="$(fixture)"
mkdir -p "$base/work/projects"           # empty real dir -> converted
run_link "$base" >/dev/null 2>&1
check "link: empty real dir converted" test -L "$base/work/projects"

base="$(fixture)"
mkdir -p "$base/work/projects/-x"; touch "$base/work/projects/-x/a.jsonl"
run_link "$base" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "link: non-empty dir exits non-zero" || bad "link: non-empty dir exits non-zero"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "link: non-empty dir untouched" || bad "link: non-empty dir untouched"

base="$(fixture)"
ln -s "$base/nowhere" "$base/work/projects"   # dangling -> replaced
run_link "$base" >/dev/null 2>&1
[ "$(readlink "$base/work/projects")" = "$base/personal/projects" ] \
  && ok "link: dangling symlink replaced" || bad "link: dangling symlink replaced"

base="$(fixture)"
mkdir -p "$base/elsewhere"; ln -s "$base/elsewhere" "$base/work/projects"
run_link "$base" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(readlink "$base/work/projects")" = "$base/elsewhere" ] \
  && ok "link: foreign live symlink skipped with warning" || bad "link: foreign live symlink skipped with warning"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
