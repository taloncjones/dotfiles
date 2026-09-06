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

echo "== rewrite: fake codex wiring"
export VOICE_CODEX_BIN="$HERE/fake_codex.py"
export FAKE_CODEX_MARKER="$SANDBOX/codex-called"
# The fake only rewrites when its trigger substrings are present; assert the
# coupling so a fixture edit fails here, not as a mystery in AC5.
for trigger in "This PR introduces" "comprehensive and robust " "In order to " "## Notes"; do
  grep -qF -- "$trigger" "$FIX/pr_body_generated.md" && ok "fixture keeps trigger [$trigger]" \
    || bad "fixture keeps trigger [$trigger]" "missing from pr_body_generated.md"
done

echo "== rewrite: generated PR body is rewritten (AC5)"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "rewrite exits 1" "$RC" 1
assert_contains "report header" "$OUT" "VOICE pr-body $FIX/pr_body_generated.md: 4 changes"
assert_contains "lint echoed" "$OUT" "hedge: might"
assert_contains "diff marker" "$OUT" "+++ after"
assert_contains "diff drops filler" "$OUT" "-This PR introduces a comprehensive and robust"
assert_contains "changes list rule" "$OUT" "1. verdict-first:"
assert_contains "apply hint" "$OUT" "Apply with:"
assert_contains "codex called once" "$(cat "$FAKE_CODEX_MARKER")" "called"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md" --json
python3 -c 'import json,sys; d=json.load(sys.stdin); assert "https://example.atlassian.net/browse/DOT-42)" in d[0]["after"]' <<<"$OUT" \
  && ok "jira link survives in after" || bad "jira link survives in after" "$OUT"

echo "== rewrite: clean PR body comes back unchanged (AC6)"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_clean.md"
assert_eq "unchanged exits 0" "$RC" 0
assert_contains "reports unchanged" "$OUT" "VOICE pr-body $FIX/pr_body_clean.md: unchanged"
assert_not_contains "no diff on unchanged" "$OUT" "+++ after"

echo "== rewrite: dropped Jira link is an invariant violation (AC7)"
FAKE_CODEX_MODE=drop-link run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "invariant violation exits 2" "$RC" 2
assert_contains "names the violation" "$ERR" "invariant violated: url https://example.atlassian.net/browse/DOT-42"
assert_not_contains "no candidate shown" "$OUT" "+++ after"

echo "== rewrite: invariant checks exact multiset, not substring containment (F1)"
python3 - <<PY > "$SANDBOX/f1.py"
import sys
sys.path.insert(0, "$HERE/..")
import voice

def show(label, missing):
    print("%s: %s" % (label, missing))

show("extend", voice.check_invariants("pr-title", "See DOT-42.", "See DOT-420."))
show("query-append", voice.check_invariants(
    "pr-comment", "Read https://x.io/a for details.",
    "Read https://x.io/a?evil=1 for details."))
show("dedupe", voice.check_invariants(
    "pr-comment", "https://x.io/a and https://x.io/a again.",
    "https://x.io/a again."))
show("survives", voice.check_invariants(
    "pr-comment", "https://x.io/a and https://x.io/a again.",
    "https://x.io/a and https://x.io/a still there."))
PY
F1_OUT=$(cat "$SANDBOX/f1.py")
assert_contains "extend flags DOT-42" "$F1_OUT" "extend: ['jira-key DOT-42']"
assert_contains "query-append flags url" "$F1_OUT" "query-append: ['url https://x.io/a']"
assert_contains "dedupe flags dropped copy" "$F1_OUT" "dedupe: ['url https://x.io/a']"
assert_contains "unchanged multiset passes" "$F1_OUT" "survives: []"

echo "== rewrite: codex failure (AC11)"
FAKE_CODEX_MODE=fail run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md"
assert_eq "codex failure exits 2" "$RC" 2
assert_contains "names exit code" "$ERR" "codex exited 3"
assert_contains "names log path" "$ERR" "log: "
LOGPATH=${ERR##*log: }
[ -f "$LOGPATH" ] && ok "log file exists" || bad "log file exists" "$LOGPATH"

echo "== rewrite: dry-run never invokes codex (AC10)"
rm -f "$FAKE_CODEX_MARKER"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_generated.md" --dry-run
assert_eq "dry-run exits 0" "$RC" 0
assert_contains "prompt has rules line 3" "$OUT" "$(sed -n '3p' "$HERE/../../rules.md")"
assert_contains "prompt has addendum" "$OUT" "=== KIND: pr-body ==="
assert_contains "prompt has text" "$OUT" "=== TEXT ==="
assert_contains "prompt has the input" "$OUT" "This PR introduces a comprehensive"
[ -e "$FAKE_CODEX_MARKER" ] && bad "codex not called on dry-run" "marker exists" || ok "codex not called on dry-run"

echo "== rewrite: empty input"
OUT=$(printf '' | python3 "$VOICE" rewrite --kind pr-comment --stdin); RC=$?
assert_eq "empty exits 0" "$RC" 0
assert_contains "reports empty" "$OUT" "VOICE pr-comment stdin: empty"

echo "== rewrite: json output is always an array"
run_voice rewrite --kind pr-body --file "$FIX/pr_body_clean.md" --json
assert_eq "json exit 0" "$RC" 0
python3 -c 'import json,sys; d=json.load(sys.stdin); assert isinstance(d, list) and len(d)==1 and d[0]["status"]=="unchanged"' <<<"$OUT" \
  && ok "json is a one-element array" || bad "json is a one-element array" "$OUT"

echo "== rewrite: --pr target (AC9)"
export VOICE_GH_BIN="$HERE/fake_gh.sh"
export FAKE_GH_LOG="$SANDBOX/gh.log"
export FAKE_GH_PR_JSON="$SANDBOX/pr.json"
python3 - "$FIX/pr_body_generated.md" "$FAKE_GH_PR_JSON" <<'PY'
import json, sys
body = open(sys.argv[1]).read()
json.dump({"title": "skills: Add voice pass", "body": body}, open(sys.argv[2], "w"))
PY
: > "$FAKE_GH_LOG"
run_voice rewrite --pr 17
assert_eq "pr with rewritten body exits 1 (max rule)" "$RC" 1
assert_contains "title report unchanged" "$OUT" "VOICE pr-title PR #17 title: unchanged"
assert_contains "body report changed" "$OUT" "VOICE pr-body PR #17 body: 4 changes"
assert_contains "apply hint is gh pr edit" "$OUT" "gh pr edit 17 --body-file "
assert_eq "gh called exactly once" "$(wc -l < "$FAKE_GH_LOG" | tr -d ' ')" 1
assert_contains "gh call was pr view" "$(cat "$FAKE_GH_LOG")" "pr view 17 --json title,body"
assert_not_contains "no pr edit" "$(cat "$FAKE_GH_LOG")" "pr edit"
BODYFILE=$(printf '%s\n' "$OUT" | sed -n 's/^  gh pr edit 17 --body-file //p')
[ -f "$BODYFILE" ] && ok "body file written" || bad "body file written" "$BODYFILE"
assert_contains "body file holds the rewrite" "$(cat "$BODYFILE")" "Adds a voice pass"

run_voice rewrite --pr 17 --json
python3 -c 'import json,sys; d=json.load(sys.stdin); assert [r["kind"] for r in d]==["pr-title","pr-body"]' <<<"$OUT" \
  && ok "json array has title then body" || bad "json array has title then body" "$OUT"

echo "== rewrite: --pr with null body (AC9b)"
printf '{"title": "skills: Add voice pass", "body": null}\n' > "$FAKE_GH_PR_JSON"
run_voice rewrite --pr 18
assert_eq "null body exits 0" "$RC" 0
assert_contains "body reported empty" "$OUT" "VOICE pr-body PR #18 body: empty"

echo "== rewrite: --pr when gh fails"
printf 'not json' > "$FAKE_GH_PR_JSON"
run_voice rewrite --pr 19
assert_eq "bad gh json exits 2" "$RC" 2
assert_contains "names gh" "$ERR" "gh pr view"

echo "== rewrite: code-comment range protects a displayed docstring (AC8)"
REPO="$SANDBOX/gui_repo"
cp -R "$FIX/gui_repo" "$REPO"
( cd "$REPO" && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init )
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6"
assert_eq "range rewrite exits 1" "$RC" 1
assert_contains "comment line rewritten" "$OUT" "+# To run a check we call the checker here."
assert_contains "docstring protected reason" "$OUT" "widgets.py:3  protected: docstring displayed (run_check.__doc__ in gui.py)"
assert_not_contains "docstring not in diff" "$OUT" "-    \"\"\"Runs a comprehensive"
assert_contains "apply is line replacement" "$OUT" "replace line 1 with: # To run a check we call the checker here."
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6" --json
printf '%s\n' "$OUT" > "$SANDBOX/range.json"
python3 - "$SANDBOX/range.json" <<'PY' && ok "docstring byte-identical in after" || bad "docstring byte-identical in after" "$OUT"
import json, sys
r = json.load(open(sys.argv[1]))[0]
before = r["before"].splitlines(); after = r["after"].splitlines()
assert before[2:6] == after[2:6], (before[2:6], after[2:6])
assert after[0] == "# To run a check we call the checker here."
PY

echo "== rewrite: touched protected line is an invariant violation"
FAKE_CODEX_MODE=touch-protected run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6"
assert_eq "touched protected exits 2" "$RC" 2
assert_contains "names the line" "$ERR" "invariant violated: line 3 changed"

echo "== rewrite: referenced-elsewhere comment is protected"
printf '# Keep this exact wording, the dashboard greps for it.\nx = 1\n' > "$REPO/other.py"
printf 'MARK = "Keep this exact wording, the dashboard greps for it."\n' > "$REPO/dash.py"
run_voice rewrite --kind code-comment --range "$REPO/other.py:1-1"
assert_eq "referenced comment unchanged exits 0" "$RC" 0
assert_contains "referenced reason" "$OUT" "other.py:1  protected: referenced elsewhere (dash.py)"

echo "== rewrite: --range guards (AC9c)"
rm -f "$FAKE_CODEX_MARKER"
run_voice rewrite --kind pr-body --range "$REPO/widgets.py:1-6"
assert_eq "range with wrong kind exits 2" "$RC" 2
assert_contains "names the rule" "$ERR" "--range requires --kind code-comment"
[ -e "$FAKE_CODEX_MARKER" ] && bad "codex not called on kind error" "marker exists" || ok "codex not called on kind error"
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:5-99"
assert_eq "out of bounds exits 2" "$RC" 2
run_voice rewrite --kind code-comment --range "$REPO/widgets.py:1-6" --dry-run
assert_eq "range dry-run exits 0" "$RC" 0
assert_contains "dry-run lists rows" "$OUT" "3|protected|"
assert_contains "dry-run lists candidate" "$OUT" "1|candidate|# In order to"
assert_contains "dry-run lists code" "$OUT" "2|code|def run_check():"

printf 'voice: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
