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

# --- merge mode: preflight + backup ---
mkfile() { mkdir -p "$(dirname "$1")"; printf '%s' "$2" > "$1"; }

base="$(fixture)"
mkfile "$base/personal/projects/-p1/s1.jsonl" "personal-s1"
mkfile "$base/work/projects/-p1/s2.jsonl" "work-s2"
mkfile "$base/work/file-history/u1/f1" "fh"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
# Task 2 build: backup happens, merge declares itself incomplete (rc=2) and
# the work tree is untouched. Task 4 Step 1 flips this to expect rc=0.
[ "$rc" -eq 2 ] && ok "merge: incomplete build exits 2 after backup" || bad "merge: incomplete build exits 2 after backup (rc=$rc)"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "merge: incomplete build leaves work tree untouched" || bad "merge: incomplete build leaves work tree untouched"
tarball="$(ls "$base/backups"/claude-projects-backup-*.tar.gz 2>/dev/null | head -1)"
[ -n "$tarball" ] && ok "merge: backup tar created" || bad "merge: backup tar created"
if [ -n "$tarball" ]; then
  perms="$(ls -l "$tarball" | cut -c1-10)"
  [ "$perms" = "-rw-------" ] && ok "merge: backup is 0600" || bad "merge: backup is 0600 ($perms)"
  tar -tzf "$tarball" | grep -q 'claude-work/projects/-p1/s2.jsonl' \
    && ok "merge: tar contains root-distinct paths" || bad "merge: tar contains root-distinct paths"
fi
inv="$(ls "$base/backups"/claude-projects-inventory-*.json 2>/dev/null | head -1)"
if [ -n "$inv" ] && python3 -c "import json; json.load(open('$inv'))" 2>/dev/null; then
  ok "merge: inventory json written"
else
  bad "merge: inventory json written"
fi

base="$(fixture)"
mkfile "$base/work/projects/-p1/s2.jsonl" "w"
run_link "$base" --merge --backup-dir "$base" </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "merge: refuses without --yes when stdin is not a tty" \
  || bad "merge: refuses without --yes when stdin is not a tty"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
