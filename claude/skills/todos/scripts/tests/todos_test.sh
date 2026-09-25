#!/usr/bin/env bash
# Test suite for todos.sh. Deterministic via TODOS_TODAY / TODOS_REGISTRY.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TODOS="$HERE/../todos.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_status() { # name expected_code cmd...
  local n="$1" want="$2"; shift 2
  "$@" >/dev/null 2>&1; local got=$?
  [ "$got" = "$want" ] && ok "$n" || bad "$n" "expected exit $want got $got"; }

canon_helper() { /usr/bin/env realpath "$1" 2>/dev/null || printf '%s' "$1"; }

# Make a throwaway git repo with a .todos backlog; echoes its path.
# Canonicalized so it matches what `git rev-parse --show-toplevel` reports
# (macOS TMPDIR is a symlink into /private; git resolves it, mktemp doesn't).
mk_repo() {
  local d; d=$(mktemp -d)
  d=$(canon_helper "$d")
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  printf '%s' "$d"
}
# Write a pending todo file from stdin. mk_todo <repo> <name>
mk_todo() {
  local repo="$1" name="$2"
  mkdir -p "$repo/.todos/pending"
  cat >"$repo/.todos/pending/$name.md"
}

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

# --- cases ---
test_today_override() {
  local out; out=$(TODOS_TODAY=2026-06-08 bash "$TODOS" today)
  assert_eq "today honors TODOS_TODAY" "$out" "2026-06-08"
}

test_today_override

test_validate_date() {
  assert_status "valid date accepted" 0 bash "$TODOS" _validate_date 2026-02-28
  assert_status "leap day accepted"   0 bash "$TODOS" _validate_date 2024-02-29
  assert_status "feb 30 rejected"     1 bash "$TODOS" _validate_date 2026-02-30
  assert_status "month 99 rejected"   1 bash "$TODOS" _validate_date 2026-99-99
  assert_status "unpadded rejected"   1 bash "$TODOS" _validate_date 2026-6-9
  assert_status "garbage rejected"    1 bash "$TODOS" _validate_date nope
}
test_validate_date

test_date_shift() {
  assert_eq "shift +3"   "$(bash "$TODOS" _date_shift 2026-06-08 3)"   2026-06-11
  assert_eq "shift -14"  "$(bash "$TODOS" _date_shift 2026-06-08 -14)" 2026-05-25
  assert_eq "month roll" "$(bash "$TODOS" _date_shift 2026-06-30 3)"   2026-07-03
  assert_eq "year roll"  "$(bash "$TODOS" _date_shift 2026-01-01 -1)"  2025-12-31
}
test_date_shift

test_new_fields() {
  local repo; repo=$(mk_repo)
  local f
  f=$( (cd "$repo" && bash "$TODOS" new "Bench check" --area eol \
          --due 2026-06-09 --surface 2026-06-08 --priority high) )
  assert_contains "writes due"      "$(cat "$f")" "due: 2026-06-09"
  assert_contains "writes surface"  "$(cat "$f")" "surface: 2026-06-08"
  assert_contains "writes priority" "$(cat "$f")" "priority: high"
  assert_status "bad due rejected"      1 bash -lc "cd '$repo' && bash '$TODOS' new x --due 2026-02-30" || true
  rm -rf "$repo"
}
test_new_fields

# C1: priority is OPTIONAL at the tool level (compat). new without --priority must succeed and write NO priority line.
test_new_priority_optional() {
  local repo; repo=$(mk_repo)
  local f; f=$( (cd "$repo" && bash "$TODOS" new "No prio") )
  assert_contains "created without priority" "$(cat "$f")" "title: No prio"
  case "$(cat "$f")" in *"priority:"*) bad "no priority line when omitted" "found priority:";; *) ok "no priority line when omitted";; esac
  rm -rf "$repo"
}
test_new_priority_optional

# C3: a value flag with no value must error cleanly (not a cryptic set -e abort).
test_new_dangling_flag() {
  local repo; repo=$(mk_repo)
  assert_status "dangling --due errors" 1 bash -c '(cd "$1" && bash "$2" new x --due)' _ "$repo" "$TODOS"
  assert_status "bad priority rejected"  1 bash -c '(cd "$1" && bash "$2" new x --priority urgent)' _ "$repo" "$TODOS"
  rm -rf "$repo"
}
test_new_dangling_flag

test_registry() {
  local reg; reg=$(mktemp); rm -f "$reg"   # path that does not exist yet
  local repo; repo=$(mk_repo)
  local root; root=$(canon_helper "$repo")

  ( cd "$repo" && TODOS_REGISTRY="$reg" bash "$TODOS" register ) >/dev/null
  ( cd "$repo" && TODOS_REGISTRY="$reg" bash "$TODOS" register ) >/dev/null  # idempotent
  local count; count=$(grep -c . "$reg")
  assert_eq "register de-dups" "$count" "1"

  local listed; listed=$(TODOS_REGISTRY="$reg" bash "$TODOS" repos)
  assert_contains "repos lists root" "$listed" "$root"

  local nongit; nongit=$(mktemp -d)
  ( cd "$nongit" && TODOS_REGISTRY="$reg" bash "$TODOS" register ) >/dev/null 2>&1
  assert_eq "register refuses non-git" "$?" "1"

  printf '/no/such/path/xyz\n' >>"$reg"
  local warned; warned=$(TODOS_REGISTRY="$reg" bash "$TODOS" repos)
  assert_contains "repos warns missing" "$warned" "(missing)"

  rm -rf "$repo" "$nongit"; rm -f "$reg"
}
test_registry

test_brief_buckets() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo)
  printf '%s\n' "$(canon_helper "$repo")" >"$reg"

  mk_todo "$repo" overdue <<'EOF'
---
created: 2026-05-01
title: Overdue item
due: 2026-06-06
priority: high
---
EOF
  mk_todo "$repo" duetoday <<'EOF'
---
created: 2026-05-01
title: Due today item
due: 2026-06-08
---
EOF
  mk_todo "$repo" soon <<'EOF'
---
created: 2026-05-01
title: Soon item
due: 2026-06-11
---
EOF
  mk_todo "$repo" toosoon <<'EOF'
---
created: 2026-05-01
title: Beyond soon item
due: 2026-06-30
---
EOF
  mk_todo "$repo" deferredhigh <<'EOF'
---
created: 2026-05-01
title: Deferred high item
surface: 2026-06-20
priority: high
---
EOF
  mk_todo "$repo" stale <<'EOF'
---
created: 2026-05-01
title: Stale undated item
---
EOF
  mk_todo "$repo" freshundated <<'EOF'
---
created: 2026-06-07
title: Fresh undated item
---
EOF

  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  assert_contains "overdue shown"   "$out" "Overdue item"
  assert_contains "due-today shown" "$out" "Due today item"
  assert_contains "soon shown"      "$out" "Soon item"
  assert_contains "stale shown"     "$out" "Stale undated item"
  case "$out" in *"Beyond soon item"*) bad "beyond-soon hidden" "leaked";; *) ok "beyond-soon hidden";; esac
  case "$out" in *"Deferred high item"*) bad "deferred-high hidden" "leaked";; *) ok "deferred-high hidden";; esac
  case "$out" in *"Fresh undated item"*) bad "fresh-undated hidden" "leaked";; *) ok "fresh-undated hidden";; esac

  local o s t
  o=$(printf '%s\n' "$out" | grep -n '^Overdue'  | head -1 | cut -d: -f1)
  s=$(printf '%s\n' "$out" | grep -n '^Due soon' | head -1 | cut -d: -f1)
  t=$(printf '%s\n' "$out" | grep -n '^Stale'    | head -1 | cut -d: -f1)
  { [ -n "$o" ] && [ -n "$s" ] && [ -n "$t" ] && [ "$o" -lt "$s" ] && [ "$s" -lt "$t" ]; } \
    && ok "section order" || bad "section order" "o=$o s=$s t=$t"

  rm -rf "$repo"; rm -f "$reg"
}
test_brief_buckets

test_brief_empty() {
  local reg; reg=$(mktemp)   # exists but empty
  local out; out=$(TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  assert_contains "empty registry msg" "$out" "No repos registered"
  rm -f "$reg"
}
test_brief_empty

test_brief_priority_tag() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  mk_todo "$repo" flaggedundated <<'EOF'
---
created: 2026-05-01
title: Flagged undated item
priority: high
---
EOF
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  assert_contains "flagged item keeps [high] tag" "$out" "Flagged undated item  [high]"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_priority_tag

test_brief_stale_cap_and_malformed() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo)
  printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  local i
  for i in 1 2 3 4 5 6 7; do
    mk_todo "$repo" "stale$i" <<EOF
---
created: 2026-04-0$i
title: Stale number $i
---
EOF
  done
  mk_todo "$repo" broken <<'EOF'
just some text, no frontmatter
EOF
  local errf; errf=$(mktemp)
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief 2>"$errf")
  local err; err=$(cat "$errf"); rm -f "$errf"
  assert_contains "stale cap note" "$out" "+2 more stale"
  local n; n=$(printf '%s\n' "$out" | grep -c 'Stale number ')
  assert_eq "stale capped at 5" "$n" "5"
  assert_contains "malformed warned" "$err" "skipping malformed"
  case "$out" in *"Stale number 1"*) ok "brief survives malformed";; *) bad "brief survives malformed" "missing content";; esac
  local out2; out2=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief --stale-cap 7)
  local n2; n2=$(printf '%s\n' "$out2" | grep -c 'Stale number ')
  assert_eq "stale-cap override" "$n2" "7"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_stale_cap_and_malformed

test_brief_boundaries() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  mk_todo "$repo" surfacetoday <<'EOF'
---
created: 2026-05-01
title: Surface today item
surface: 2026-06-08
---
EOF
  mk_todo "$repo" soonedge <<'EOF'
---
created: 2026-05-01
title: Soon edge item
due: 2026-06-11
---
EOF
  mk_todo "$repo" soonpast <<'EOF'
---
created: 2026-05-01
title: Soon past item
due: 2026-06-12
---
EOF
  mk_todo "$repo" staleedge <<'EOF'
---
created: 2026-05-25
title: Stale edge item
---
EOF
  mk_todo "$repo" stalefresh <<'EOF'
---
created: 2026-05-26
title: Stale fresh item
---
EOF
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  # surface today -> Today section
  local tline sline
  tline=$(printf '%s\n' "$out" | grep -n '^Today'   | head -1 | cut -d: -f1)
  assert_contains "surface-today shown" "$out" "Surface today item"
  assert_contains "soon edge (today+3) shown" "$out" "Soon edge item"
  case "$out" in *"Soon past item"*) bad "soon past (today+4) hidden" "leaked";; *) ok "soon past (today+4) hidden";; esac
  assert_contains "stale edge (today-14) shown" "$out" "Stale edge item"
  case "$out" in *"Stale fresh item"*) bad "stale fresh (today-13) hidden" "leaked";; *) ok "stale fresh (today-13) hidden";; esac
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_boundaries

test_brief_sort_order() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  mk_todo "$repo" plow <<'EOF'
---
created: 2026-05-01
title: P low
due: 2026-06-08
priority: low
---
EOF
  mk_todo "$repo" phigh <<'EOF'
---
created: 2026-05-01
title: P high
due: 2026-06-08
priority: high
---
EOF
  mk_todo "$repo" pmed <<'EOF'
---
created: 2026-05-01
title: P med
due: 2026-06-08
priority: med
---
EOF
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  local h m l
  h=$(printf '%s\n' "$out" | grep -n 'P high' | head -1 | cut -d: -f1)
  m=$(printf '%s\n' "$out" | grep -n 'P med'  | head -1 | cut -d: -f1)
  l=$(printf '%s\n' "$out" | grep -n 'P low'  | head -1 | cut -d: -f1)
  { [ -n "$h" ] && [ -n "$m" ] && [ -n "$l" ] && [ "$h" -lt "$m" ] && [ "$m" -lt "$l" ]; } \
    && ok "within-bucket priority sort" || bad "within-bucket priority sort" "h=$h m=$m l=$l"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_sort_order

test_brief_invalid_fields() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  mk_todo "$repo" badfields <<'EOF'
---
created: 2026-05-01
title: Bad fields item
due: 2026-13-40
priority: urgent
---
EOF
  mk_todo "$repo" emptytitle <<'EOF'
---
created: 2026-05-01
title:
---
EOF
  local errf; errf=$(mktemp)
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief 2>"$errf")
  local err; err=$(cat "$errf"); rm -f "$errf"
  assert_contains "invalid due warned" "$err" "ignoring invalid due"
  assert_contains "invalid priority warned" "$err" "ignoring invalid priority"
  assert_contains "bad-fields todo still shown (stale)" "$out" "Bad fields item"
  assert_contains "empty title skipped" "$err" "skipping malformed"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_invalid_fields

test_brief_unreadable() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  mk_todo "$repo" good <<'EOF'
---
created: 2026-05-01
title: Good stale item
---
EOF
  mk_todo "$repo" locked <<'EOF'
---
created: 2026-05-01
title: Locked item
---
EOF
  chmod 000 "$repo/.todos/pending/locked.md"
  local errf; errf=$(mktemp)
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief 2>"$errf")
  local err; err=$(cat "$errf"); rm -f "$errf"
  assert_contains "readable todo still shown" "$out" "Good stale item"
  # Root bypasses file permissions, so chmod 000 cannot make the file
  # unreadable and the skip path never triggers; assert only as non-root.
  if [ "$(id -u)" -eq 0 ]; then
    ok "unreadable skipped (SKIP: running as root)"
  else
    case "$out" in *"Locked item"*) bad "unreadable skipped" "leaked";; *) ok "unreadable skipped";; esac
  fi
  chmod 644 "$repo/.todos/pending/locked.md" 2>/dev/null || true
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_unreadable

test_index_annotations() {
  local repo; repo=$(mk_repo)
  ( cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "Has due" --due 2026-06-09 --priority high >/dev/null )
  ( cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "No due"  --priority low  >/dev/null )
  ( cd "$repo" && bash "$TODOS" index >/dev/null )
  local idx; idx=$(cat "$repo/.todos/TODO.md")
  assert_contains "index shows due"      "$idx" "due 2026-06-09"
  assert_contains "index shows priority" "$idx" "[high]"
  local a b
  a=$(printf '%s\n' "$idx" | grep -n 'Has due' | head -1 | cut -d: -f1)
  b=$(printf '%s\n' "$idx" | grep -n 'No due'  | head -1 | cut -d: -f1)
  { [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; } \
    && ok "index sort dated-first" || bad "index sort dated-first" "a=$a b=$b"
  rm -rf "$repo"
}
test_index_annotations

test_index_priority_no_due() {
  local repo; repo=$(mk_repo)
  ( cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "Prio no due" --priority low >/dev/null )
  ( cd "$repo" && bash "$TODOS" index >/dev/null )
  local idx; idx=$(cat "$repo/.todos/TODO.md")
  assert_contains "priority-no-due tagged [low]" "$idx" "[low]"
  case "$idx" in *"due low"*) bad "no spurious 'due low'" "found 'due low'";; *) ok "no spurious 'due low'";; esac
  rm -rf "$repo"
}
test_index_priority_no_due

test_brief_bad_numeric_flags() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); printf '%s\n' "$(canon_helper "$repo")" >"$reg"
  # non-numeric value must error (exit 1) WITH a message on stderr, not silently
  local errf; errf=$(mktemp)
  TODOS_REGISTRY="$reg" bash "$TODOS" brief --soon abc >/dev/null 2>"$errf"
  assert_eq "bad --soon exits 1" "$?" "1"
  assert_contains "bad --soon explains" "$(cat "$errf")" "non-negative integer"
  rm -f "$errf"
  # valid numeric still works
  assert_status "valid --soon ok" 0 bash -c '(TODOS_REGISTRY="$1" bash "$2" brief --soon 5 >/dev/null)' _ "$reg" "$TODOS"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_bad_numeric_flags

test_brief_registry_dedup() {
  local reg; reg=$(mktemp); rm -f "$reg"
  local repo; repo=$(mk_repo); local root; root=$(canon_helper "$repo")
  printf '%s\n%s\n' "$root" "$root" >"$reg"   # same repo listed twice
  mk_todo "$repo" dup <<'EOF'
---
created: 2026-05-01
title: Dup once item
due: 2026-06-06
---
EOF
  local out; out=$(TODOS_TODAY=2026-06-08 TODOS_REGISTRY="$reg" bash "$TODOS" brief)
  local n; n=$(printf '%s\n' "$out" | grep -c 'Dup once item')
  assert_eq "duplicate registry entry counted once" "$n" "1"
  rm -rf "$repo"; rm -f "$reg"
}
test_brief_registry_dedup

test_index_undated_priority_order() {
  local repo; repo=$(mk_repo)
  ( cd "$repo" && TODOS_TODAY=2026-05-01 bash "$TODOS" new "Old low" --priority low >/dev/null )
  ( cd "$repo" && TODOS_TODAY=2026-06-08 bash "$TODOS" new "New high" --priority high >/dev/null )
  ( cd "$repo" && bash "$TODOS" index >/dev/null )
  local idx; idx=$(cat "$repo/.todos/TODO.md")
  local h l
  h=$(printf '%s\n' "$idx" | grep -n 'New high' | head -1 | cut -d: -f1)
  l=$(printf '%s\n' "$idx" | grep -n 'Old low'  | head -1 | cut -d: -f1)
  { [ -n "$h" ] && [ -n "$l" ] && [ "$h" -lt "$l" ]; } \
    && ok "undated high sorts before older low" || bad "undated high sorts before older low" "h=$h l=$l"
  rm -rf "$repo"
}
test_index_undated_priority_order

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
  mk_todo "$repo" 2026-05-01-target-four <<'EOF'
---
created: 2026-05-01
title: Target list then files
depends_on:
  - pr:1
files:
  - keep/me.py
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
  ( cd "$repo" && bash "$TODOS" depend target-four pr:6 >/dev/null )
  assert_contains "depend: appends before files when list precedes files" \
    "$(cat "$repo/.todos/pending/2026-05-01-target-four.md")" "$(printf 'depends_on:\n  - pr:1\n  - pr:6\nfiles:\n  - keep/me.py')"
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

assert_ready() {
  local name="$1" repo="$2" want_status="$3" want_json="$4"; shift 4
  local out rc got want
  out=$(cd "$repo" && bash "$TODOS" ready "$@" 2>/dev/null); rc=$?
  assert_eq "$name: exit" "$rc" "$want_status"
  got=$(printf '%s' "$out" | jq -ceS '{ready,task_id,dependencies}' 2>/dev/null)
  want=$(printf '%s' "$want_json" | jq -ceS .)
  assert_eq "$name: JSON" "$got" "$want"
}

test_ready_exact_and_readonly() {
  local TODOS_REGISTRY DEPS_CACHE
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-exact <<'EOF'
---
created: 2026-05-01
title: Exact
---
EOF
  mk_todo "$repo" 2026-05-01-exact-other <<'EOF'
---
created: 2026-05-01
title: Other
depends_on:
  - pr:1
---
EOF
  local before after registry cache
  registry="$repo/uncreated/repos.txt"; cache="$repo/cache"
  printf 'cache sentinel\n' >"$cache"
  before=$(find "$repo" -type f -exec shasum {} + | sort)
  chmod -R a-w "$repo"
  export TODOS_REGISTRY="$registry" DEPS_CACHE="$cache"
  assert_ready 'ready: no dependencies and read-only' "$repo" 0 \
    '{"ready":true,"task_id":"2026-05-01-exact","dependencies":[]}' 2026-05-01-exact
  after=$(find "$repo" -type f -exec shasum {} + | sort)
  assert_eq 'ready: leaves every fixture byte unchanged' "$after" "$before"
  [ ! -e "$repo/.todos/TODO.md" ] && [ ! -e "$repo/uncreated" ] \
    && ok 'ready: creates no index or registry directory' || bad 'ready: creates no index or registry directory' 'state created'
  chmod -R u+w "$repo"
  local query
  for query in exact 2026-05-01-ex 2026-05-01-exact.md ../2026-05-01-exact 2026-02-30-bad; do
    assert_status "ready: rejects nonexact/invalid ID $query" 2 bash -c 'cd "$1" && bash "$2" ready "$3"' _ "$repo" "$TODOS" "$query"
  done
  assert_status 'ready: missing ID argument' 2 bash -c 'cd "$1" && bash "$2" ready' _ "$repo" "$TODOS"
  assert_status 'ready: unknown argument' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-exact --typo' _ "$repo" "$TODOS"
  assert_status 'ready: missing exact target' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-missing' _ "$repo" "$TODOS"
  mkdir -p "$repo/.todos/completed"
  cp "$repo/.todos/pending/2026-05-01-exact.md" "$repo/.todos/completed/2026-05-01-exact.md"
  assert_status 'ready: duplicate pending/completed target' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-exact' _ "$repo" "$TODOS"
  rm "$repo/.todos/pending/2026-05-01-exact.md"
  assert_status 'ready: completed target cannot dispatch' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-exact' _ "$repo" "$TODOS"
  rm -rf "$repo"
  repo=$(mk_repo)
  assert_status 'ready: absent backlog' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-missing' _ "$repo" "$TODOS"
  [ ! -e "$repo/.todos" ] && ok 'ready: absent backlog stays absent' || bad 'ready: absent backlog stays absent' 'created .todos'
  rm -rf "$repo"
}
test_ready_exact_and_readonly

test_ready_dependency_states() {
  local TODOS_GH TODOS_BASE_REF
  local repo; repo=$(mk_branch_repo)
  mk_todo "$repo" 2026-05-01-gate <<'EOF'
---
created: 2026-05-01
title: Gate
depends_on:
  - todo:2026-05-01-finished
  - todo:2026-05-01-open
  - todo:2026-05-01-missing
  - todo:2026-05-01-gate
  - 'bad"ref'
  - pr:1
  - branch:merged-b
  - branch:open-b
  - branch:--help
  - branch:@{1}
---
EOF
  mk_todo "$repo" 2026-05-01-open <<'EOF'
---
created: 2026-05-01
title: Direct cycle
depends_on:
  - todo:2026-05-01-gate
---
EOF
  mkdir -p "$repo/.todos/completed"
  printf -- '---\ncreated: 2026-05-01\ntitle: Finished\n---\n' >"$repo/.todos/completed/2026-05-01-finished.md"
  local stub; stub=$(mktemp); mk_gh_stub "$stub"
  export TODOS_GH="$stub"
  assert_ready 'ready: direct unsatisfied states block without recursion' "$repo" 3 \
    '{"ready":false,"task_id":"2026-05-01-gate","dependencies":[{"ref":"todo:2026-05-01-finished","state":"done"},{"ref":"todo:2026-05-01-open","state":"open"},{"ref":"todo:2026-05-01-missing","state":"missing"},{"ref":"todo:2026-05-01-gate","state":"self"},{"ref":"bad\"ref","state":"invalid"},{"ref":"pr:1","state":"unknown"},{"ref":"branch:merged-b","state":"merged"},{"ref":"branch:open-b","state":"open"},{"ref":"branch:--help","state":"invalid"},{"ref":"branch:@{1}","state":"invalid"}]}' 2026-05-01-gate --offline
  [ ! -e "$stub.calls" ] && ok 'ready: offline never invokes gh' || bad 'ready: offline never invokes gh' 'gh called'
  mk_todo "$repo" 2026-05-01-satisfied <<'EOF'
---
created: 2026-05-01
title: Satisfied
depends_on:
  - todo:2026-05-01-finished
  - branch:merged-b
---
EOF
  assert_ready 'ready: all dependencies satisfied' "$repo" 0 \
    '{"ready":true,"task_id":"2026-05-01-satisfied","dependencies":[{"ref":"todo:2026-05-01-finished","state":"done"},{"ref":"branch:merged-b","state":"merged"}]}' 2026-05-01-satisfied
  export TODOS_BASE_REF=--help
  assert_ready 'ready: Git base option injection fails closed' "$repo" 3 \
    '{"ready":false,"task_id":"2026-05-01-satisfied","dependencies":[{"ref":"todo:2026-05-01-finished","state":"done"},{"ref":"branch:merged-b","state":"unknown"}]}' 2026-05-01-satisfied
  rm -rf "$repo"; rm -f "$stub" "$stub.calls"
}
test_ready_dependency_states

test_ready_online_bounded() {
  local TODOS_GH
  local repo; repo=$(mk_branch_repo)
  mk_todo "$repo" 2026-05-01-network <<'EOF'
---
created: 2026-05-01
title: Network
depends_on:
  - pr:1
  - branch:open-b
---
EOF
  local stub; stub=$(mktemp); mk_gh_stub "$stub"
  export TODOS_GH="$stub"
  assert_ready 'ready: default offline blocks unverified PR' "$repo" 3 \
    '{"ready":false,"task_id":"2026-05-01-network","dependencies":[{"ref":"pr:1","state":"unknown"},{"ref":"branch:open-b","state":"open"}]}' 2026-05-01-network
  assert_ready 'ready: online verifies PR and squash merge' "$repo" 0 \
    '{"ready":true,"task_id":"2026-05-01-network","dependencies":[{"ref":"pr:1","state":"merged"},{"ref":"branch:open-b","state":"merged"}]}' 2026-05-01-network --online
  printf '#!/usr/bin/env bash\nexec sleep 15\n' >"$stub"
  local started=$SECONDS
  assert_ready 'ready: hung gh stays unknown and respects shared deadline' "$repo" 3 \
    '{"ready":false,"task_id":"2026-05-01-network","dependencies":[{"ref":"pr:1","state":"unknown"},{"ref":"branch:open-b","state":"open"}]}' 2026-05-01-network --online
  [ "$((SECONDS - started))" -le 8 ] && ok 'ready: online completes within bounded budget' || bad 'ready: online completes within bounded budget' "elapsed $((SECONDS - started))"
  rm -rf "$repo"; rm -f "$stub" "$stub.calls"
}
test_ready_online_bounded

test_ready_malformed_dependencies() {
  local repo; repo=$(mk_repo)
  local value
  for value in 'depends_on: [pr:1]' 'depends_on: pr:1' $'depends_on:\n  - ' $'depends_on:\n - pr:1'; do
    printf -- '---\ncreated: 2026-05-01\ntitle: Bad dependency schema\n%s\n---\n' "$value" | mk_todo "$repo" 2026-05-01-malformed
    assert_status 'ready: malformed dependency declaration fails closed' 2 bash -c 'cd "$1" && bash "$2" ready 2026-05-01-malformed' _ "$repo" "$TODOS"
  done
  rm -rf "$repo"
}
test_ready_malformed_dependencies

test_ready_untrustworthy_todo_dependencies() {
  local repo; repo=$(mk_repo)
  mk_todo "$repo" 2026-05-01-gate <<'EOF'
---
created: 2026-05-01
title: Gate
depends_on:
  - ""
  - todo:2026-05-01-directory
  - todo:2026-05-01-link
  - todo:2026-05-01-duplicate
---
EOF
  mkdir -p "$repo/.todos/completed/2026-05-01-directory.md"
  printf -- '---\ncreated: 2026-05-01\ntitle: Done\n---\n' >"$repo/.todos/completed/2026-05-01-duplicate.md"
  cp "$repo/.todos/completed/2026-05-01-duplicate.md" "$repo/.todos/pending/2026-05-01-duplicate.md"
  ln -s 2026-05-01-duplicate.md "$repo/.todos/completed/2026-05-01-link.md"
  assert_ready 'ready: invalid completed state never satisfies' "$repo" 3 \
    '{"ready":false,"task_id":"2026-05-01-gate","dependencies":[{"ref":"","state":"invalid"},{"ref":"todo:2026-05-01-directory","state":"unknown"},{"ref":"todo:2026-05-01-link","state":"unknown"},{"ref":"todo:2026-05-01-duplicate","state":"unknown"}]}' 2026-05-01-gate
  rm -rf "$repo"
}
test_ready_untrustworthy_todo_dependencies

# --- store mode -------------------------------------------------------------
# Cases set these per call; never inherit them from the developer's shell.
unset TODOS_OFFLINE TODOS_SYNC_TIMEOUT TODOS_LOCK_WAIT TODOS_STORE_LOCKED CLAUDE_CODE_REMOTE
# A store is a separate clone that opted in with `git config todos.store true`;
# a repo's .todos links into it. Hermetic git config: identity, main, no hooks.
ST_GCFG=$(mktemp)
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n[core]\n\thooksPath = /dev/null\n[commit]\n\tgpgsign = false\n' >"$ST_GCFG"
stg() { GIT_CONFIG_GLOBAL="$ST_GCFG" GIT_CONFIG_NOSYSTEM=1 git "$@"; }
# st runs todos.sh with no account or sync knobs inherited from the caller.
st() {
  env -u CLAUDE_CONFIG_DIR -u CLAUDE_PERSONAL_ONLY -u WORKFLOW_PERSONAL_ACCOUNT \
    -u GIT_SSH_COMMAND -u GIT_DIR -u GIT_WORK_TREE \
    GIT_CONFIG_GLOBAL="$ST_GCFG" GIT_CONFIG_NOSYSTEM=1 TODOS_TODAY=2026-09-24 \
    bash "$TODOS" "$@"
}
# stw is st under the work Claude config ($1 is the config dir).
stw() {
  local cfg="$1"; shift
  env -u CLAUDE_PERSONAL_ONLY -u WORKFLOW_PERSONAL_ACCOUNT -u GIT_SSH_COMMAND \
    CLAUDE_CONFIG_DIR="$cfg" GIT_CONFIG_GLOBAL="$ST_GCFG" GIT_CONFIG_NOSYSTEM=1 \
    TODOS_TODAY=2026-09-24 bash "$TODOS" "$@"
}
# mk_remote <root>: bare <root>/remote.git whose main holds the store layout.
mk_remote() {
  local root="$1" seed="$1/seed"
  stg init -q --bare "$root/remote.git"
  stg init -q "$seed"
  mkdir -p "$seed/repos/dotfiles/.todos/pending" "$seed/repos/dotfiles/.todos/completed"
  : >"$seed/repos/dotfiles/.todos/pending/.gitkeep"
  : >"$seed/repos/dotfiles/.todos/completed/.gitkeep"
  printf 'TODO.md\n*.tmp.*\n*.swp\n*~\n.DS_Store\n' >"$seed/.gitignore"
  stg -C "$seed" add -A && stg -C "$seed" commit -qm seed
  stg -C "$seed" push -q "$root/remote.git" main
  rm -rf "$seed"
}
# mk_side <root> <name>: opted-in clone <root>/<name>-store plus repo
# <root>/<name> whose .todos links into it.
mk_side() {
  local root="$1" name="$2"
  stg clone -q "$root/remote.git" "$root/$name-store"
  stg -C "$root/$name-store" config todos.store true
  stg init -q "$root/$name"
  ln -s "$root/$name-store/repos/dotfiles/.todos" "$root/$name/.todos"
}
set_mtime() { python3 -c 'import os,sys; t=int(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }

test_store_real_todos_local() {
  local repo; repo=$(mk_repo)
  (cd "$repo" && TODOS_OFFLINE=1 st new "Plain item") >/dev/null 2>&1
  assert_eq "store: real .todos stays local" "$(git -C "$repo" rev-list --all --count)" "0"
  rm -rf "$repo"
}
test_store_real_todos_local

test_store_worktree_symlink_local() {
  local repo wt; repo=$(mk_repo); wt="$repo-wt"
  stg -C "$repo" commit -q --allow-empty -m base
  mkdir -p "$repo/.todos/pending" "$repo/.todos/completed"
  stg -C "$repo" worktree add -q "$wt" -b wt-b
  rm -rf "$wt/.todos"; ln -s "$repo/.todos" "$wt/.todos"
  (cd "$wt" && TODOS_OFFLINE=1 st new "Worktree item") >/dev/null 2>&1
  assert_eq "store: worktree symlink to main stays local" "$(git -C "$repo" rev-list --all --count)" "1"
  stg -C "$repo" worktree remove --force "$wt"; rm -rf "$repo" "$wt"
}
test_store_worktree_symlink_local

test_store_new_commits() {
  local root f id; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  f=$( (cd "$root/a" && TODOS_OFFLINE=1 st new "First item") 2>/dev/null ); id=$(basename "$f" .md)
  assert_eq "store: opted-in store commits new" \
    "$(stg -C "$root/a-store" log -1 --format=%s)|$(stg -C "$root/a-store" show --name-only --format= HEAD)" \
    "todos: new 2026-09-24-first-item|repos/dotfiles/.todos/pending/2026-09-24-first-item.md"
  rm -rf "$root"
}
test_store_new_commits

test_store_without_optin_local() {
  local root; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  stg -C "$root/a-store" config --unset todos.store
  (cd "$root/a" && TODOS_OFFLINE=1 st new "No opt in") >/dev/null 2>&1
  assert_eq "store: store without opt-in stays local" "$(stg -C "$root/a-store" rev-list --count HEAD)" "1"
  rm -rf "$root"
}
test_store_without_optin_local

test_store_dangling_link() {
  local root out rc; root=$(canon_helper "$(mktemp -d)")
  stg init -q "$root/r"; ln -s "$root/missing" "$root/r/.todos"
  out=$( (cd "$root/r" && st list) 2>&1 ); rc=$?
  assert_eq "store: dangling link fails list" "$rc|$out" \
    "1|todos: .todos link target is missing; rerun the dotfiles installer"
  rm -rf "$root"
}
test_store_dangling_link

test_store_work_config_refuses() {
  local root out rc; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  (cd "$root/a" && TODOS_OFFLINE=1 st new "Secret plan") >/dev/null 2>&1
  out=$( (cd "$root/a" && stw "$root/.claude-work" list) 2>&1 ); rc=$?
  assert_eq "store: work config refuses list" "$rc|$out" \
    "1|todos: .todos is not available under this account"
  rm -rf "$root"
}
test_store_work_config_refuses

test_store_brief_scope() {
  local root reg work pers; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  (cd "$root/a" && TODOS_OFFLINE=1 st new "Flagged secret" --priority high) >/dev/null 2>&1
  reg="$root/repos.txt"; printf '%s\n' "$root/a" >"$reg"
  work=$(TODOS_REGISTRY="$reg" stw "$root/.claude-work" brief 2>&1)
  pers=$(TODOS_REGISTRY="$reg" st brief 2>&1)
  case "$work" in
    *"Flagged secret"*|*"$root/a"*) bad "store: brief skips store repo under work config" "$work" ;;
    *) ok "store: brief skips store repo under work config" ;;
  esac
  assert_contains "store: brief shows store repo under personal config" "$pers" "Flagged secret"
  rm -rf "$root"
}
test_store_brief_scope

test_store_ready_out_of_scope() {
  local root out rc; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  (cd "$root/a" && TODOS_OFFLINE=1 st new "Gate") >/dev/null 2>&1
  out=$( (cd "$root/a" && stw "$root/.claude-work" ready 2026-09-24-gate) 2>&1 ); rc=$?
  assert_eq "store: ready out_of_scope under work config" "$rc|$out" \
    '2|{"ready":false,"task_id":"2026-09-24-gate","dependencies":[],"error":"out_of_scope"}'
  rm -rf "$root"
}
test_store_ready_out_of_scope

test_store_unrelated_dirt() {
  local root; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  printf 'extra\n' >>"$root/a-store/.gitignore"
  (cd "$root/a" && TODOS_OFFLINE=1 st new "Clean item") >/dev/null 2>&1
  assert_eq "store: unrelated dirty file stays uncommitted" \
    "$(stg -C "$root/a-store" status --porcelain)|$(stg -C "$root/a-store" show --name-only --format= HEAD)" \
    " M .gitignore|repos/dotfiles/.todos/pending/2026-09-24-clean-item.md"
  rm -rf "$root"
}
test_store_unrelated_dirt

test_store_index_no_commit() {
  local root before; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  before=$(stg -C "$root/a-store" rev-list --count HEAD)
  (cd "$root/a" && TODOS_OFFLINE=1 st index) >/dev/null 2>&1
  assert_eq "store: index without changes makes no commit" "$(stg -C "$root/a-store" rev-list --count HEAD)" "$before"
  rm -rf "$root"
}
test_store_index_no_commit

test_store_stray_edit_dated() {
  local root f; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  f=$( (cd "$root/a" && TODOS_OFFLINE=1 st new "Edited item") 2>/dev/null )
  printf 'more\n' >>"$f"; set_mtime "$f" 1772323200
  (cd "$root/a" && TODOS_OFFLINE=1 st new "Second item") >/dev/null 2>&1
  assert_eq "store: direct edit committed as dated sync before new" \
    "$(stg -C "$root/a-store" log -2 --format='%s@%at' | paste -sd'|' -)" \
    "todos: new 2026-09-24-second-item@$(stg -C "$root/a-store" log -1 --format=%at)|todos: sync pending/2026-09-24-edited-item.md@1772323200"
  rm -rf "$root"
}
test_store_stray_edit_dated

test_store_refused_commit() {
  local root err rc; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  mkdir -p "$root/hooks"; printf '#!/bin/sh\nexit 1\n' >"$root/hooks/commit-msg"; chmod +x "$root/hooks/commit-msg"
  stg -C "$root/a-store" config core.hooksPath "$root/hooks"
  err=$( (cd "$root/a" && TODOS_OFFLINE=1 st new "Blocked") 2>&1 >/dev/null ); rc=$?
  if [ "$rc" = 0 ] && [ -f "$root/a/.todos/pending/2026-09-24-blocked.md" ] \
    && printf '%s' "$err" | grep -q 'todos: sync skipped: commit refused'; then
    ok "store: refused commit warns and keeps file"
  else
    bad "store: refused commit warns and keeps file" "rc=$rc err=$err"
  fi
  rm -rf "$root"
}
test_store_refused_commit

test_store_refused_stray_file() {
  local root f err; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  f=$( (cd "$root/a" && TODOS_OFFLINE=1 st new "Leaky") 2>/dev/null )
  mkdir -p "$root/hooks"
  printf '#!/bin/sh\ngit diff --cached | grep -q SECRETWORD && exit 1\nexit 0\n' >"$root/hooks/pre-commit"
  chmod +x "$root/hooks/pre-commit"
  stg -C "$root/a-store" config core.hooksPath "$root/hooks"
  printf 'SECRETWORD\n' >>"$f"
  err=$( (cd "$root/a" && TODOS_OFFLINE=1 st new "Clean after") 2>&1 >/dev/null )
  if printf '%s' "$err" | grep -q 'commit refused for pending/2026-09-24-leaky.md' \
    && [ "$(stg -C "$root/a-store" log -1 --format=%s)" = "todos: new 2026-09-24-clean-after" ] \
    && stg -C "$root/a-store" status --porcelain | grep -q 'pending/2026-09-24-leaky.md'; then
    ok "store: refused stray file does not block others"
  else
    bad "store: refused stray file does not block others" "$err"
  fi
  rm -rf "$root"
}
test_store_refused_stray_file

test_store_share_refuses() {
  local root out rc; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  out=$( (cd "$root/a" && st share) 2>&1 ); rc=$?
  assert_eq "store: share refuses" "$rc|$out" \
    "1|todos: .todos is stored in a separate repository; share does not apply"
  rm -rf "$root"
}
test_store_share_refuses

test_store_lock_busy_and_killed() {
  local root lock holder i out rc; root=$(canon_helper "$(mktemp -d)")
  mk_remote "$root"; mk_side "$root" a
  lock="$(stg -C "$root/a-store" rev-parse --path-format=absolute --git-common-dir)/todos-sync.lock"
  python3 "$HERE/../todos_store.py" lock "$lock" 30 -- sleep 29.517 & holder=$!
  for i in $(seq 1 50); do
    python3 "$HERE/../todos_store.py" lock "$lock" 0 -- true; [ "$?" = 75 ] && break; sleep 0.1
  done
  out=$( (cd "$root/a" && TODOS_OFFLINE=1 TODOS_LOCK_WAIT=1 st new "Blocked by lock") 2>&1 ); rc=$?
  assert_eq "store: busy lock refuses new" "$rc|$out|$(ls "$root/a/.todos/pending" | grep -c blocked-by-lock)" \
    "1|todos: store is busy|0"
  kill -9 "$holder"; wait "$holder" 2>/dev/null; pkill -f 'sleep 29.517' 2>/dev/null
  (cd "$root/a" && TODOS_OFFLINE=1 TODOS_LOCK_WAIT=1 st new "After kill") >/dev/null 2>&1; rc=$?
  assert_eq "store: killed holder frees lock" "$rc|$(ls "$root/a/.todos/pending" | grep -c after-kill)" "0|1"
  rm -rf "$root"
}
test_store_lock_busy_and_killed

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
