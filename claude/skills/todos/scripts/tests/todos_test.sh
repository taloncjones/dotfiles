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
mk_repo() {
  local d; d=$(mktemp -d)
  ( cd "$d" && git init -q && git config user.email t@t && git config user.name t )
  printf '%s' "$d"
}
# Write a pending todo file from stdin. mk_todo <repo> <name>
mk_todo() {
  local repo="$1" name="$2"
  mkdir -p "$repo/.todos/pending"
  cat >"$repo/.todos/pending/$name.md"
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
  case "$out" in *"Locked item"*) bad "unreadable skipped" "leaked";; *) ok "unreadable skipped";; esac
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
