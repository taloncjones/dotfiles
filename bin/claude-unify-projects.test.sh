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
[ "$rc" -eq 0 ] && ok "merge: complete run exits 0 after backup" || bad "merge: complete run exits 0 after backup (rc=$rc)"
test -L "$base/work/projects" \
  && ok "merge: work projects swapped to symlink" || bad "merge: work projects swapped to symlink"
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

# --- merge mode: collisions, memory union, file-history ---
base="$(fixture)"
# duplicated session: work copy larger -> work wins
mkfile "$base/personal/projects/-p1/dup.jsonl" "short"
mkfile "$base/work/projects/-p1/dup.jsonl" "longer-content-wins"
mkfile "$base/personal/projects/-p1/dup/sidecar.txt" "personal-sidecar"
mkfile "$base/work/projects/-p1/dup/sidecar.txt" "work-sidecar"
mkfile "$base/personal/file-history/dup/cp1" "personal-fh"
mkfile "$base/work/file-history/dup/cp1" "work-fh"
# identical twins -> personal kept (distinguishable via their sidecars)
mkfile "$base/personal/projects/-p1/same.jsonl" "identical"
mkfile "$base/work/projects/-p1/same.jsonl" "identical"
mkfile "$base/personal/projects/-p1/same/tag.txt" "personal-side"
mkfile "$base/work/projects/-p1/same/tag.txt" "work-side"
# work-only session INSIDE an overlapping project dir: sidecar must survive
mkfile "$base/work/projects/-p1/wonly.jsonl" "work-only-session"
mkfile "$base/work/projects/-p1/wonly/state.txt" "work-only-sidecar"
# memory: distinct files union; same-name different content -> newer wins
mkfile "$base/personal/projects/-p1/memory/MEMORY.md" "# Memory Index

- [Alpha](alpha.md) - a
"
mkfile "$base/personal/projects/-p1/memory/alpha.md" "alpha"
mkfile "$base/work/projects/-p1/memory/MEMORY.md" "# Memory Index

- [Alpha](alpha.md) - a
- [Beta](beta.md) - b
"
mkfile "$base/work/projects/-p1/memory/beta.md" "beta"
mkfile "$base/work/projects/-p1/memory/alpha.md" "alpha-work-newer"
touch -t 203001010000 "$base/work/projects/-p1/memory/alpha.md"
# work-only project dir and file-history id
mkfile "$base/work/projects/-only/w1.jsonl" "work-only"
mkfile "$base/work/file-history/workonly/cp" "fh-work-only"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "merge: task-3 build exits 0 after tree merge" || bad "merge: task-3 build exits 0 after tree merge (rc=$rc)"
P="$base/personal/projects/-p1"
[ "$(cat "$P/dup.jsonl")" = "longer-content-wins" ] && ok "merge: larger jsonl wins" || bad "merge: larger jsonl wins"
[ "$(cat "$P/same/tag.txt")" = "personal-side" ] && ok "merge: identical twin keeps personal sidecar" || bad "merge: identical twin keeps personal sidecar"
[ "$(cat "$P/wonly/state.txt")" = "work-only-sidecar" ] && ok "merge: work-only session sidecar survives" || bad "merge: work-only session sidecar survives"
[ "$(cat "$P/dup/sidecar.txt")" = "work-sidecar" ] && ok "merge: sidecar follows winner" || bad "merge: sidecar follows winner"
[ "$(cat "$base/personal/file-history/dup/cp1")" = "work-fh" ] && ok "merge: file-history follows winner" || bad "merge: file-history follows winner"
[ "$(cat "$P/same.jsonl")" = "identical" ] && ok "merge: identical twin kept once" || bad "merge: identical twin kept once"
[ "$(cat "$P/memory/alpha.md")" = "alpha-work-newer" ] && ok "merge: newer memory fact wins" || bad "merge: newer memory fact wins"
test -f "$P/memory/alpha.md.conflict-personal.md" && ok "merge: losing memory fact preserved" || bad "merge: losing memory fact preserved"
[ "$(cat "$P/memory/beta.md")" = "beta" ] && ok "merge: work-only memory fact copied" || bad "merge: work-only memory fact copied"
grep -q 'Beta' "$P/memory/MEMORY.md" && ok "merge: MEMORY.md gained work-only line" || bad "merge: MEMORY.md gained work-only line"
[ "$(grep -c 'Alpha' "$P/memory/MEMORY.md")" = "1" ] && ok "merge: MEMORY.md lines deduped" || bad "merge: MEMORY.md lines deduped"
test -f "$P/memory/MEMORY.md.conflict-work.md" && ok "merge: work MEMORY.md preserved" || bad "merge: work MEMORY.md preserved"
test -f "$base/personal/projects/-only/w1.jsonl" && ok "merge: work-only project copied" || bad "merge: work-only project copied"
test -f "$base/personal/file-history/workonly/cp" && ok "merge: work-only file-history copied" || bad "merge: work-only file-history copied"
test -L "$base/work/projects" \
  && ok "merge: work projects swapped to symlink" || bad "merge: work projects swapped to symlink"
ls -d "$base/work/projects.premerge-"* >/dev/null 2>&1 \
  && ok "merge: premerge tree kept" || bad "merge: premerge tree kept"

# --- merge mode: swap guard + verify ---
base="$(fixture)"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkdir -p "$base/work/projects.premerge-20260101-000000"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "merge: stale premerge dir aborts" || bad "merge: stale premerge dir aborts"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "merge: aborted run leaves work tree untouched" || bad "merge: aborted run leaves work tree untouched"

base="$(fixture)"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkfile "$base/personal/projects/-p2/b.jsonl" "b"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1 \
  && ok "merge: verify passes on clean merge" || bad "merge: verify passes on clean merge"
test -f "$base/work/projects/-p2/b.jsonl" \
  && ok "verify: personal file reachable via work path" || bad "verify: personal file reachable via work path"
test -f "$base/work/projects/-p1/a.jsonl" \
  && ok "verify: work file reachable via work path post-swap" || bad "verify: work file reachable via work path post-swap"
run_link "$base" >/dev/null 2>&1 && ok "merge: link mode no-op after merge" || bad "merge: link mode no-op after merge"

# --- merge mode: swap rollback on mid-swap failure ---
# work/file-history is a live FOREIGN symlink: projects swaps first, then
# ensure_link refuses the foreign link, forcing rollback of projects.
base="$(fixture)"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkdir -p "$base/elsewhere"; touch "$base/elsewhere/x"
ln -s "$base/elsewhere" "$base/work/file-history"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "swap: mid-swap link failure exits nonzero" || bad "swap: mid-swap link failure exits nonzero"
test -d "$base/work/projects" && ! test -L "$base/work/projects" \
  && ok "swap: rollback restored work projects tree" || bad "swap: rollback restored work projects tree"
ls -d "$base/work/projects.premerge-"* >/dev/null 2>&1 \
  && bad "swap: rollback left no premerge dir" || ok "swap: rollback left no premerge dir"
test -f "$base/work/projects/-p1/a.jsonl" \
  && ok "swap: rolled-back tree content intact" || bad "swap: rolled-back tree content intact"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
