#!/bin/sh
# opaque-label-hint.test.sh -- hermetic payload tests for opaque_label_hint.py:
# JSON piped to the hook, no HOME, config dir or state access.
set -u
cd "$(dirname "$0")/../.." || exit 1
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=claude/hooks/opaque_label_hint.py
PASS=0
FAIL=0
OUT=$(mktemp /tmp/opaque-hint.XXXXXX) || exit 1
trap 'rm -f "$OUT"' EXIT

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# ask QUESTION LABEL... -> AskUserQuestion payload with one question
ask() {
    python3 -c '
import json, sys
q, labels = sys.argv[1], sys.argv[2:]
opts = [{"label": l, "description": "Pick this."} for l in labels]
print(json.dumps({"tool_name": "AskUserQuestion", "tool_input": {"questions": [
    {"question": q, "header": "Decide", "multiSelect": False, "options": opts}]}}))
' "$@"
}
# run PAYLOAD: pipe to the hook; stdout in $OUT, status in $RC
run() { printf '%s' "$1" | python3 "$HOOK" >"$OUT" 2>/dev/null; RC=$?; }
warned() { [ "$RC" = 0 ] && grep -q '^{"hookSpecificOutput"' "$OUT"; }
silent() { [ "$RC" = 0 ] && [ ! -s "$OUT" ]; }
names() { grep -qF -- "$1" "$OUT"; }

# 1: bare R12 warns and is named
run "$(ask 'Still open: your R12 stand check. Merge now?' 'Hold for R12' 'Merge now')"
if warned && names 'AskUserQuestion: R12.'; then pass "1 bare R12 warns"; else fail "1 bare R12 warns"; fi

# 2: expanded in parentheses
run "$(ask 'Hold for the merge stand check (R12)?' 'Hold' 'Merge')"
if silent; then pass "2 (R12) silent"; else fail "2 (R12) silent"; fi

# 3: followed by a parenthesis
run "$(ask 'R12 (the merge stand check) is open. Hold?' 'Hold' 'Merge')"
if silent; then pass "3 R12 (...) silent"; else fail "3 R12 (...) silent"; fi

# 4: followed by a colon definition
run "$(ask 'R12: the merge stand check. Hold?' 'Hold' 'Merge')"
if silent; then pass "4 R12: ... silent"; else fail "4 R12: ... silent"; fi

# 5: expanded in the question, bare in an option label
run "$(ask 'Hold the merge stand check (R12)?' 'Hold for R12' 'Merge now')"
if silent; then pass "5 reuse after expansion silent"; else fail "5 reuse after expansion silent"; fi

# 6: bare in an option label, question without it
run "$(ask 'Merge the PR now?' 'Hold for R12' 'Merge now')"
if warned && names 'R12'; then pass "6 bare in option label warns"; else fail "6 bare in option label warns"; fi

# 7: expanded in question 1, bare in question 2 of the same call
run "$(python3 -c '
import json
def q(t): return {"question": t, "header": "H", "multiSelect": False,
                  "options": [{"label": "Yes", "description": "d"}, {"label": "No", "description": "d"}]}
print(json.dumps({"tool_name": "AskUserQuestion", "tool_input": {"questions": [
    q("Keep the stand check (R12)?"), q("Run R12 after merge?")]}}))
')"
if silent; then pass "7 cross-question reuse silent"; else fail "7 cross-question reuse silent"; fi

# 8: bare PR number
run "$(ask 'Merge #272?' 'Merge' 'Wait')"
if warned && names 'AskUserQuestion: #272.'; then pass "8 bare #272 warns"; else fail "8 bare #272 warns"; fi

# 9: number in parentheses
run "$(ask 'Merge Keep the host awake (#272)?' 'Merge' 'Wait')"
if silent; then pass "9 (#272) silent"; else fail "9 (#272) silent"; fi

# 10: number followed by a quoted title
run "$(ask 'Rebase #267 "Add writing-style rule" first?' 'Yes' 'No')"
if silent; then pass "10 #267 with quoted title silent"; else fail "10 #267 with quoted title silent"; fi

# 11: bare run number, and run #17 is one token
run "$(ask 'Rerun run 17?' 'Rerun' 'Skip')"
if warned && names 'AskUserQuestion: run 17.'; then pass "11a bare run 17 warns"; else fail "11a bare run 17 warns"; fi
run "$(ask 'Retry run #17?' 'Retry' 'Skip')"
if warned && names 'AskUserQuestion: run #17.'; then pass "11b run #17 is one token"; else fail "11b run #17 is one token"; fi

# 12: run number with a definition
run "$(ask 'Rerun run 17 (the 2026-10-12 nightly suite)?' 'Rerun' 'Skip')"
if silent; then pass "12 run 17 (...) silent"; else fail "12 run 17 (...) silent"; fi

# 13: bare decision id
run "$(ask 'Retire decision 51fdc8742406 now?' 'Retire' 'Keep')"
if warned && names '51fdc8742406'; then pass "13 bare decision id warns"; else fail "13 bare decision id warns"; fi

# 14: decision id in parentheses
run "$(ask 'Retire the merge hold (decision 51fdc8742406)?' 'Retire' 'Keep')"
if silent; then pass "14 (decision id) silent"; else fail "14 (decision id) silent"; fi

# 15: gh post shim go-token labels
run "$(ask 'Post this closing comment? Text: thanks, merged.' 'Post draft 9cb85c49' 'Skip draft 9cb85c49')"
if silent; then pass "15 Post/Skip draft labels silent"; else fail "15 Post/Skip draft labels silent"; fi

# 16: token only in an option preview
run "$(python3 -c '
import json
print(json.dumps({"tool_name": "AskUserQuestion", "tool_input": {"questions": [
    {"question": "Which layout?", "header": "H", "multiSelect": False, "options": [
        {"label": "Compact", "description": "d", "preview": "see #12 and R12"},
        {"label": "Wide", "description": "d"}]}]}}))
')"
if silent; then pass "16 preview not scanned"; else fail "16 preview not scanned"; fi

# 17: near misses
run "$(ask 'Ship the R2D2 build or R1234?' 'Ship' 'Wait')"
if silent; then pass "17 R2D2 and R1234 silent"; else fail "17 R2D2 and R1234 silent"; fi

# 18: six distinct tokens list five and a count
run "$(ask 'R1 R2 R3 R4 R5 R6 all open. Go?' 'Go' 'Stop')"
if warned && names 'R1, R2, R3, R4, R5 and 1 more.'; then pass "18 six tokens list five"; else fail "18 six tokens list five"; fi

# 19: output shape, no decision keys
run "$(ask 'Hold R12?' 'Hold' 'Go')"
if warned && python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
h = d["hookSpecificOutput"]
assert set(d) == {"hookSpecificOutput"} and set(h) == {"hookEventName", "additionalContext"}, d
assert h["hookEventName"] == "PreToolUse"
assert h["additionalContext"].startswith("[WARNING] opaque label in AskUserQuestion: ")
' "$OUT"; then pass "19 output shape, no decision keys, exit 0"; else fail "19 output shape, no decision keys, exit 0"; fi

# 20: other tool
run '{"tool_name": "Bash", "tool_input": {"questions": [{"question": "R12?"}]}}'
if silent; then pass "20 other tool silent"; else fail "20 other tool silent"; fi

# 21: malformed input
run 'not json'
if silent; then pass "21a malformed JSON silent"; else fail "21a malformed JSON silent"; fi
run '[1, 2]'
if silent; then pass "21b JSON array silent"; else fail "21b JSON array silent"; fi
run '{"tool_name": "AskUserQuestion", "tool_input": {}}'
if silent; then pass "21c missing questions silent"; else fail "21c missing questions silent"; fi

# 22: template wiring
if python3 - <<'PY'
import json
h = json.load(open("claude/settings.json.tmpl"))["hooks"]
pre = [e for e in h["PreToolUse"] if e.get("matcher") == "AskUserQuestion"]
assert len(pre) == 1 and pre[0]["hooks"] == [
    {"type": "command", "command": "~/.claude/hooks/opaque_label_hint.py"},
    {"type": "command", "command": "~/.claude/hooks/pr_post_guard.py"}], pre
post = [e for e in h["PostToolUse"] if e.get("matcher") == "AskUserQuestion"]
assert len(post) == 1 and post[0]["hooks"] == [
    {"type": "command", "command": "~/.claude/hooks/pr_post_guard.py"}], post
PY
then pass "22 template wiring"; else fail "22 template wiring"; fi

# 23: kind x form matrix
S="the merge stand check"
for T in 'R12' '#272' 'run 17' 'decision 51fdc8742406'; do
    run "$(ask "$T is open. Hold?" 'Hold' 'Go')"
    if warned && names "$T"; then pass "23 $T bare warns"; else fail "23 $T bare warns"; fi
    for form in "$S ($T) is open." "$T ($S) is open." "$T \"$S\" is open." \
        "$T $(printf '\342\200\234')$S$(printf '\342\200\235') is open." \
        "$T: $S is open." "$T -- $S is open." "$T $(printf '\342\200\224') $S is open."; do
        run "$(ask "$form Hold?" 'Hold' 'Go')"
        if silent; then pass "23 $T expanded: $form"; else fail "23 $T expanded: $form"; fi
    done
done

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
