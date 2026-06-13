#!/usr/bin/env bash
# Plain-bash test harness for work-state.sh (no bats dependency).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0; FAIL=0
ok() { if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $3"; echo "  expected: [$2]"; echo "  actual:   [$1]"; fi; }

SOURCE_SENTINEL=before
# shellcheck disable=SC1091
source "$HERE/work-state.sh"; SOURCE_SENTINEL=after
ok "$(type -t ws_require_deps)" "function" "ws_require_deps defined after sourcing"
ok "$SOURCE_SENTINEL" "after" "sourcing does not exit the shell (main guarded)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
( cd "$TMP" && git init -q main && cd main && git -c user.name=ws-test -c user.email=ws@test -c commit.gpgsign=false commit -q --allow-empty -m init \
    && git worktree add -q ../linked -b wt >/dev/null 2>&1 )
ok "$(ws_canonical_key "$TMP/main")"   "$(realpath "$TMP/main")" "main worktree key = repo root"
ok "$(ws_canonical_key "$TMP/linked")" "$(realpath "$TMP/main")" "linked worktree key = main repo root"
ws_canonical_key "$TMP" >/dev/null 2>&1; ok "$?" "2" "non-git dir returns error code 2"
# Submodule: key is the submodule's OWN root, not <super>/.git/modules.
# protocol.file.allow=always is required to add a submodule from a local path on modern git.
( cd "$TMP" && git init -q sub && cd sub && git -c user.name=ws-test -c user.email=ws@test -c commit.gpgsign=false commit -q --allow-empty -m s )
( cd "$TMP/main" && git -c protocol.file.allow=always -c user.name=ws-test -c user.email=ws@test submodule add -q "$TMP/sub" sub >/dev/null 2>&1 \
    && git -c user.name=ws-test -c user.email=ws@test -c commit.gpgsign=false commit -q -m addsub >/dev/null 2>&1 )
ok "$(ws_canonical_key "$TMP/main/sub")" "$(realpath "$TMP/main/sub")" "submodule key = submodule own root"
# Bare repo: unsupported -> skip code 4.
git init -q --bare "$TMP/bare.git" >/dev/null 2>&1
ws_canonical_key "$TMP/bare.git" >/dev/null 2>&1; ok "$?" "4" "bare repo returns skip code 4"

# --- Task 4: ws_select_config ---
FX="$(mktemp -d)"; CFG="$FX/projects.json"
mkdir -p "$FX/myapp"
jq -n --arg p "$(realpath "$FX/myapp")" '{"myapp":{repo_paths:[$p],jira_project:"PROJ"}}' >"$CFG"
ok "$(ws_select_config "$FX/myapp" "$CFG" | jq -r '.jira_project')" "PROJ" "select_config matches block by repo_paths"
ws_select_config "$FX/other" "$CFG" >/dev/null 2>&1; ok "$?" "3" "no matching block returns code 3"
echo 'not json' >"$CFG"; ws_select_config "$FX/myapp" "$CFG" >/dev/null 2>&1; ok "$?" "2" "invalid JSON returns hard error code 2"
rm -rf "$FX"

# --- Task 5: ws_iso_to_epoch, ws_epoch_to_iso, ws_in_window ---
NOW=1750000000
ok "$(ws_iso_to_epoch 1970-01-01T00:00:00Z)" "0" "iso_to_epoch parses ISO-8601 Z"
IN_TS="$(ws_epoch_to_iso $((NOW - 8*86400)))"
OUT_TS="$(ws_epoch_to_iso $((NOW - 10*86400)))"
ws_in_window "$IN_TS" 9 "$NOW";  ok "$?" "0" "8-day-old PR within 9-day window"
ws_in_window "$OUT_TS" 9 "$NOW"; ok "$?" "1" "10-day-old PR outside 9-day window"

# --- Task 6: ws_gather_github ---
NOW=1750000000
STUB="$(mktemp)"; chmod +x "$STUB"
# `-R o/bad` exits nonzero for BOTH merged+open queries (per-repo failure case);
# its pattern must precede the --state patterns since the command contains both.
cat >"$STUB" <<STUBEOF
#!/usr/bin/env bash
case "\$*" in
  "api user --jq .login") echo me ;;
  *"-R o/bad"*) exit 1 ;;
  *"--state merged"*) jq -c -n '[{number:1,title:"in",headRefName:"a",mergedAt:"$(ws_epoch_to_iso $((NOW-2*86400)))",url:"u1",body:"closes PROJ-7"},{number:2,title:"out",headRefName:"b",mergedAt:"$(ws_epoch_to_iso $((NOW-30*86400)))",url:"u2",body:""}]' ;;
  *"--state open"*) jq -c -n '[{number:3,title:"open",headRefName:"c",mergedAt:null,url:"u3",isDraft:false,body:"fixes PROJ-42",mergeable:"MERGEABLE",statusCheckRollup:[{state:"SUCCESS"}]}]' ;;
  *) echo '[]' ;;
esac
STUBEOF
OUT="$(GH="$STUB" ws_gather_github '["o/r"]' 9 "$NOW")"
ok "$(echo "$OUT" | jq '.merged | length')" "1" "only in-window merged PR kept"
ok "$(echo "$OUT" | jq -r '.merged[0].number')" "1" "kept the in-window PR"
ok "$(echo "$OUT" | jq -r '.merged[0].body')" "closes PROJ-7" "merged PR body passed through (key match for transition)"
ok "$(echo "$OUT" | jq '.open | length')" "1" "open PR captured"
ok "$(echo "$OUT" | jq -r '.open[0].body')" "fixes PROJ-42" "open PR body passed through (untracked-PR key match needs it)"
ok "$(echo "$OUT" | jq -r '.open[0].mergeable')" "MERGEABLE" "open PR mergeable passed through (review-ready gate)"
ok "$(echo "$OUT" | jq -r '.open[0].statusCheckRollup[0].state')" "SUCCESS" "open PR check state passed through (review-ready gate)"
ok "$(echo "$OUT" | jq -r '.gh_ok')" "true" "gh_ok true when gh works"
ok "$(echo "$OUT" | jq -r '.partial')" "false" "partial false when every repo succeeds"
# Cap reached -> truncated:true (gates downstream mutation-blocking). Stub returns 2 merged; cap=1.
ok "$(GH="$STUB" WS_GH_CAP=1 ws_gather_github '["o/r"]' 9 "$NOW" | jq -r '.truncated')" "true" "truncated true when a query hits the cap"
# One repo errors while another succeeds -> surfaced in errors[], never silently dropped.
OUT3="$(GH="$STUB" ws_gather_github '["o/r","o/bad"]' 9 "$NOW")"
ok "$(echo "$OUT3" | jq -r '.gh_ok')" "true" "gh_ok stays true when auth ok but a repo query errors"
ok "$(echo "$OUT3" | jq -r '.partial')" "true" "partial true when a repo query errors"
ok "$(echo "$OUT3" | jq -r '[.errors[].repo]|unique|.[0]')" "o/bad" "failing repo surfaced in errors[]"
OUT2="$(GH=/bin/false ws_gather_github '["o/r"]' 9 "$NOW"; echo "rc=$?")"
ok "$(echo "$OUT2" | sed 's/rc=.*//' | jq -r '.gh_ok')" "false" "gh_ok false when gh auth fails"
ok "$(echo "$OUT2" | grep -o 'rc=[0-9]*')" "rc=0" "gather exits 0 when gh unavailable"
rm -f "$STUB"

# --- Task 7: ws_main dispatch ---
# Uses TMP7 (not TMP) so it does not clobber Task 3's TMP, which the EXIT trap cleans.
NOW=1750000000
TMP7="$(mktemp -d)"; ( cd "$TMP7" && git init -q r && cd r && git -c user.name=ws-test -c user.email=ws@test -c commit.gpgsign=false commit -q --allow-empty -m i )
CFG="$(mktemp)"
jq -n --arg p "$(realpath "$TMP7/r")" '{demo:{repo_paths:[$p],github_repos:["o/r"],merged_window_days:9}}' >"$CFG"
STUB="$(mktemp)"; chmod +x "$STUB"
printf '#!/usr/bin/env bash\ncase "$*" in\n  "api user --jq .login") echo me ;;\n  *) echo "[]" ;;\nesac\n' >"$STUB"
OUT="$(GH="$STUB" ws_main --repo "$TMP7/r" --config "$CFG" --now "$NOW")"
ok "$(echo "$OUT" | jq -r '.project')" "demo" "main emits selected project name"
ok "$(echo "$OUT" | jq -r '.github.gh_ok')" "true" "main nests github gather"
rm -rf "$TMP7"; rm -f "$CFG" "$STUB"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
