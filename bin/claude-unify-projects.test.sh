#!/usr/bin/env bash
# Tests for bin/claude-unify-projects. Fixture trees only -- never live roots.
set -u
if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not installed; claude-unify-projects is a python3 script"
  exit 0
fi
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
test -d "$base/personal" && ! test -L "$base/personal" \
  && ok "merge: non-tty refusal leaves personal root a real dir" || bad "merge: non-tty refusal leaves personal root a real dir"
test -d "$base/work" && ! test -L "$base/work" \
  && ok "merge: non-tty refusal leaves work root a real dir" || bad "merge: non-tty refusal leaves work root a real dir"
[ "$(cat "$base/work/projects/-p1/s2.jsonl")" = "w" ] \
  && ok "merge: non-tty refusal leaves work tree content intact" || bad "merge: non-tty refusal leaves work tree content intact"

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
[ "$rc" -eq 0 ] && ok "merge: complete merge exits 0" || bad "merge: complete merge exits 0 (rc=$rc)"
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

# --- P1-1: personal-wins collision must not drop a work-only sidecar/file-history ---
base="$(fixture)"
mkfile "$base/personal/projects/-p1/dup2.jsonl" "personal-longer-content-wins-woo"
mkfile "$base/work/projects/-p1/dup2.jsonl" "work-short"
# work has a sidecar and a file-history entry that personal lacks entirely.
mkfile "$base/work/projects/-p1/dup2/state.txt" "worksidecar"
mkfile "$base/work/file-history/dup2/cp" "workfh"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "P1-1: personal-wins merge exits 0" || bad "P1-1: personal-wins merge exits 0 (rc=$rc)"
[ "$(cat "$base/personal/projects/-p1/dup2.jsonl")" = "personal-longer-content-wins-woo" ] \
  && ok "P1-1: personal transcript kept as winner" || bad "P1-1: personal transcript kept as winner"
[ "$(cat "$base/personal/projects/-p1/dup2/state.txt")" = "worksidecar" ] \
  && ok "P1-1: work-only sidecar copied despite personal winning the transcript" \
  || bad "P1-1: work-only sidecar copied despite personal winning the transcript"
[ "$(cat "$base/personal/file-history/dup2/cp")" = "workfh" ] \
  && ok "P1-1: work-only file-history copied despite personal winning the transcript" \
  || bad "P1-1: work-only file-history copied despite personal winning the transcript"

# --- P2-8: memory dir-vs-file collision must preserve the work subtree ---
base="$(fixture)"
mkfile "$base/personal/projects/-p1/keep.jsonl" "x"
mkfile "$base/personal/projects/-p1/memory/notes" "personal-file-content"
mkfile "$base/work/projects/-p1/memory/notes/detail.md" "work-nested-detail"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "P2-8: dir-vs-file memory collision verify passes" || bad "P2-8: dir-vs-file memory collision verify passes (rc=$rc)"
[ "$(cat "$base/personal/projects/-p1/memory/notes")" = "personal-file-content" ] \
  && ok "P2-8: personal memory file kept" || bad "P2-8: personal memory file kept"
[ "$(cat "$base/personal/projects/-p1/memory/notes.conflict-work/detail.md")" = "work-nested-detail" ] \
  && ok "P2-8: work memory subtree preserved as .conflict-work dir" \
  || bad "P2-8: work memory subtree preserved as .conflict-work dir"

# --- P1-2: half-migrated state (projects already unified, file-history real) ---
base="$(fixture)"
mkfile "$base/personal/projects/-p1/sess1.jsonl" "personal-data"
ln -s "$base/personal/projects" "$base/work/projects"
# Real work file-history with an id that also names an existing personal
# session dir, so a naive self-collision (from iterating the symlinked
# projects tree) would wrongly mark it as already-decided and skip it.
mkfile "$base/work/file-history/sess1/cp" "real-work-fh-content"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "P1-2: half-migrated merge exits 0" || bad "P1-2: half-migrated merge exits 0 (rc=$rc)"
[ "$(cat "$base/personal/file-history/sess1/cp")" = "real-work-fh-content" ] \
  && ok "P1-2: real work file-history content survives an already-symlinked projects tree" \
  || bad "P1-2: real work file-history content survives an already-symlinked projects tree"
test -L "$base/work/file-history" \
  && ok "P1-2: work file-history swapped to symlink" || bad "P1-2: work file-history swapped to symlink"
test -L "$base/work/projects" \
  && ok "P1-2: work projects symlink untouched" || bad "P1-2: work projects symlink untouched"

# --- P2-9: duplicate-set mismatch warns (and, with --yes, still proceeds) ---
base="$(fixture)"
mkfile "$base/work/projects/-only/w1.jsonl" "work-only"
mkdir -p "$base/backups"
out="$(run_link "$base" --merge --yes --backup-dir "$base/backups" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok "P2-9: proceeds past duplicate-set mismatch with --yes" \
  || bad "P2-9: proceeds past duplicate-set mismatch with --yes (rc=$rc)"
echo "$out" | grep -q "duplicate set differs from the reviewed snapshot" \
  && ok "P2-9: warns when the duplicate set differs from the reviewed snapshot" \
  || bad "P2-9: warns when the duplicate set differs from the reviewed snapshot"

# --- stale-purge: leftover .tmp-merge staging dir under personal/projects
# from an interrupted prior run must be purged BEFORE inventory/backup, not
# discovered mid-merge (which would inventory it, back it up, then delete it
# out from under a same-named live entry and false-fail verify after the swap).
base="$(fixture)"
mkfile "$base/personal/projects/-p1/real.jsonl" "real-data"
mkfile "$base/personal/projects/-p1/real.tmp-merge/leftover" "orphaned-staging-content"
mkfile "$base/work/projects/-p2/w1.jsonl" "work-only"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "stale-purge: run completes exit 0 with leftover staging present" \
  || bad "stale-purge: run completes exit 0 with leftover staging present (rc=$rc)"
test -e "$base/personal/projects/-p1/real.tmp-merge" \
  && bad "stale-purge: staging dir purged before merge" || ok "stale-purge: staging dir purged before merge"
[ "$(cat "$base/personal/projects/-p1/real.jsonl")" = "real-data" ] \
  && ok "stale-purge: real data alongside stale staging is intact" \
  || bad "stale-purge: real data alongside stale staging is intact"
test -f "$base/personal/projects/-p2/w1.jsonl" \
  && ok "stale-purge: unrelated merge work still completed" || bad "stale-purge: unrelated merge work still completed"

# --- half-migrated same-dir guard: file-history already unified (work-side
# symlink into personal), projects still real, with a work-wins duplicate
# whose file-history dir already lives in the canonical (personal) tree. The
# work-wins pair (w_fh/<sid> -> p_fh/<sid>) must not be staged when the
# file-history tree's plan is "skip" -- both paths resolve to the SAME
# canonical directory, and copy+rmtree+rename on it risks destroying it.
base="$(fixture)"
mkfile "$base/personal/file-history/dupfh/cp" "canonical-fh-content"
ln -s "$base/personal/file-history" "$base/work/file-history"
mkfile "$base/personal/projects/-p1/dupfh.jsonl" "short"
mkfile "$base/work/projects/-p1/dupfh.jsonl" "work-longer-transcript-content-wins"
mkdir -p "$base/backups"
# Capture the canonical dir's inode before merging: a same-dir staged
# copy+rmtree+rename would recreate this directory (new inode) even when
# content ends up byte-identical, so inode preservation is the strongest
# available "never touched" signal without literally killing the process
# mid-swap to reproduce the interruption itself.
inode_before="$(stat -f %i "$base/personal/file-history/dupfh" 2>/dev/null || stat -c %i "$base/personal/file-history/dupfh")"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "same-dir: half-migrated work-wins merge exits 0" \
  || bad "same-dir: half-migrated work-wins merge exits 0 (rc=$rc)"
[ "$(cat "$base/personal/file-history/dupfh/cp")" = "canonical-fh-content" ] \
  && ok "same-dir: canonical file-history content untouched by the same-dir pair" \
  || bad "same-dir: canonical file-history content untouched by the same-dir pair"
inode_after="$(stat -f %i "$base/personal/file-history/dupfh" 2>/dev/null || stat -c %i "$base/personal/file-history/dupfh")"
[ "$inode_before" = "$inode_after" ] \
  && ok "same-dir: canonical dir never recreated (inode unchanged, truly skipped not copy-restored)" \
  || bad "same-dir: canonical dir never recreated (inode unchanged, truly skipped not copy-restored)"
[ "$(cat "$base/personal/projects/-p1/dupfh.jsonl")" = "work-longer-transcript-content-wins" ] \
  && ok "same-dir: work transcript still won the collision" \
  || bad "same-dir: work transcript still won the collision"

# --- relative half-migrated symlink: final verify must resolve the symlink
# itself (not the raw readlink() text against the process CWD), so a valid
# RELATIVE work-side symlink into the personal tree doesn't false-fail.
base="$(fixture)"
mkfile "$base/personal/file-history/existing/cp" "canonical"
ln -s "../personal/file-history" "$base/work/file-history"
mkfile "$base/work/projects/-p1/a.jsonl" "a"
mkdir -p "$base/backups"
run_link "$base" --merge --yes --backup-dir "$base/backups" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "relative-symlink: half-migrated merge with relative fh symlink exits 0" \
  || bad "relative-symlink: half-migrated merge with relative fh symlink exits 0 (rc=$rc)"
[ "$(cat "$base/personal/file-history/existing/cp")" = "canonical" ] \
  && ok "relative-symlink: canonical file-history content intact" \
  || bad "relative-symlink: canonical file-history content intact"
test -L "$base/work/projects" \
  && ok "relative-symlink: projects swapped to symlink" || bad "relative-symlink: projects swapped to symlink"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
