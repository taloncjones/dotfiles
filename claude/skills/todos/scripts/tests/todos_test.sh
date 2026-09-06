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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
