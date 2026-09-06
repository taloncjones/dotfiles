#!/usr/bin/env bash
# Test suite for voice.py. No network, no user-level writes: Codex and gh are
# replaced by fakes via VOICE_CODEX_BIN / VOICE_GH_BIN.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
VOICE="$HERE/../voice.py"
FIX="$HERE/fixtures"
export HOME
HOME=$(mktemp -d)
SANDBOX=$(mktemp -d)

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()           { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains()     { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] contains [$3]";; *) ok "$1";; esac; }

# run_voice args...: run voice.py, capture stdout in OUT, stderr in ERR, exit in RC.
run_voice() {
  OUT=$(python3 "$VOICE" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

echo "== lint: generated PR body"
run_voice lint --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "generated body exits 1" "$RC" 1
assert_contains "flags filler" "$OUT" "filler: comprehensive"
assert_contains "flags In order to" "$OUT" "filler: In order to"
assert_contains "flags hedge" "$OUT" "hedge: might"
assert_contains "flags empty heading" "$OUT" "empty-heading: ## Notes"

echo "== lint: clean PR body"
run_voice lint --kind pr-body --file "$FIX/pr_body_clean.md"
assert_eq "clean body exits 0" "$RC" 0
assert_eq "clean body prints nothing" "$OUT" ""

echo "== lint: jira titles"
run_voice lint --kind jira-title --file "$FIX/jira_title_generated.txt"
assert_eq "generated title exits 1" "$RC" 1
assert_contains "flags word count" "$OUT" "title-shape: 16 words, over 12"
assert_contains "flags filename" "$OUT" "title-shape: filename voice.py"
assert_contains "flags function call" "$OUT" "title-shape: function call lint_text()"
run_voice lint --kind jira-title --file "$FIX/jira_title_clean.txt"
assert_eq "clean title exits 0" "$RC" 0
assert_eq "clean title prints nothing" "$OUT" ""

echo "== lint: pr title shape"
OUT=$(printf 'Added a thing' | python3 "$VOICE" lint --kind pr-title --stdin); RC=$?
assert_eq "title without scope exits 1" "$RC" 1
assert_contains "flags missing scope" "$OUT" "title-shape: missing <scope>: prefix"
OUT=$(printf 'skills: Add voice pass' | python3 "$VOICE" lint --kind pr-title --stdin); RC=$?
assert_eq "scoped short title exits 0" "$RC" 0

echo "== lint: emoji and attribution (fixture built at run time)"
# The trailer is assembled from fragments so the repo's own attribution guards
# never see it as one string in a committed file.
printf 'Ship it \xf0\x9f\x9a\x80\n\nCo-authored' > "$SANDBOX/mixed.md"
printf -- '-by: Claude <noreply@example.com>\n' >> "$SANDBOX/mixed.md"
run_voice lint --kind pr-comment --file "$SANDBOX/mixed.md"
assert_eq "mixed exits 1" "$RC" 1
assert_contains "flags emoji" "$OUT" "emoji: U+1F680"
assert_contains "flags attribution" "$OUT" "attribution: Co-authored"

echo "== lint: input errors"
run_voice lint --kind nope --file "$FIX/pr_body_clean.md"
assert_eq "unknown kind exits 2" "$RC" 2
assert_contains "unknown kind names the kinds" "$ERR" "pr-body"
run_voice lint --kind pr-body
assert_eq "no input source exits 2" "$RC" 2

printf 'voice: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
