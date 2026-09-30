#!/bin/sh
# pr-post-guard.test.sh -- hermetic payload tests for pr_post_guard.py.
#
# Every case runs the hook with a throwaway DOTFILES_POST_GATE_DIR under
# mktemp, no live Claude session, and no real state root. HERDR_ENV=1 is set
# explicitly per case (except M1, which unsets it) rather than inherited.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${PR_POST_GUARD_HOOK:-claude/hooks/pr_post_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/pr-post-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

export HERDR_ENV=1
# The gate is a work-repo rule: run from a fixture home so the result does
# not depend on the machine, with payload cwd outside ~/Git/personal.
mkdir -p "$FIX/home/work" "$FIX/home/Git/personal/repo"
git init -q "$FIX/home/Git/personal/repo"
git -C "$FIX/home/Git/personal/repo" remote add origin https://github.com/me/repo.git
HOME="$FIX/home"
export HOME
unset CLAUDE_PERSONAL_ONLY
WORK_CWD="$FIX/home/work"
PERSONAL_CWD="$FIX/home/Git/personal/repo"
# The hook honors a go only when `gh` on its PATH is the shim that spends it.
PATH="$(pwd)/bin/herdr-shims:$PATH"
export PATH
# Drafts bind to a session: never inherit the live pane's session or pid.
CLAUDE_CODE_SESSION_ID=s1
export CLAUDE_CODE_SESSION_ID
unset CLAUDE_PID

case_gate() {
    GATE="$FIX/gate-$1"
    export DOTFILES_POST_GATE_DIR="$GATE"
}

# pending HASH CREATED [TEXT]: a shown v3 draft for s1 in the current gate
# dir; TEXT defaults to "x", and PD_NULL=1 (in a subshell) records no text
pending() {
    mkdir -p "$GATE"
    PD_TEXT="${3-x}" python3 -c 'import json, os, sys; t = None if os.environ.get("PD_NULL") == "1" else os.environ["PD_TEXT"]; print(json.dumps({"v": 3, "created": int(sys.argv[1]), "argv": [], "text": t}))' "$2" >"$GATE/s1.draft-$1.pending"
}

REVIEW='gh pr review 5 -c -b x'

# payload_u SID PROMPT -> UserPromptSubmit JSON on stdout
payload_u() {
    PU_SID="$1" PU_PROMPT="$2" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "UserPromptSubmit",
    "session_id": os.environ["PU_SID"],
    "prompt": os.environ["PU_PROMPT"],
}))
PY
}

# payload_b SID COMMAND -> PreToolUse Bash JSON on stdout
payload_b() {
    PB_SID="$1" PB_CMD="$2" PB_CWD="${PB_CWD:-$WORK_CWD}" python3 - <<'PY'
import json, os
print(json.dumps({
    "hook_event_name": "PreToolUse",
    "session_id": os.environ["PB_SID"],
    "cwd": os.environ["PB_CWD"],
    "tool_name": "Bash",
    "tool_input": {"command": os.environ["PB_CMD"]},
}))
PY
}

# payload_a SID LABEL PREVIEW -> PostToolUse AskUserQuestion JSON: one
# question "$PA_QUESTION" (default "Post this draft?") with the options
# LABEL (preview PREVIEW) and "Hold", answered with $PA_ANSWER (default
# LABEL). PA_MULTI=1 makes it multi-select, PA_EXTRA is JSON merged into
# tool_response, PA_TOOL replaces the tool name. Set these only inside
# $(...): a sh assignment before a function call can outlive the call.
payload_a() {
    PA_SID="$1" PA_LABEL="$2" PA_PREVIEW="${3-}" python3 - <<'PY'
import json, os
q = os.environ.get("PA_QUESTION", "Post this draft?")
label = os.environ["PA_LABEL"]
questions = [{"question": q, "header": "Post", "multiSelect": os.environ.get("PA_MULTI") == "1",
              "options": [{"label": label, "description": "posts the draft", "preview": os.environ["PA_PREVIEW"]},
                          {"label": "Hold", "description": "wait"}]}]
response = {"questions": questions, "answers": {q: os.environ.get("PA_ANSWER", label)}}
response.update(json.loads(os.environ.get("PA_EXTRA") or "{}"))
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": os.environ["PA_SID"],
                  "tool_name": os.environ.get("PA_TOOL", "AskUserQuestion"),
                  "tool_input": {"questions": questions}, "tool_response": response}))
PY
}

# expect_out LABEL NEEDLE PAYLOAD -> the hook's stdout contains NEEDLE
expect_out() {
    got=$(printf '%s' "$3" | python3 "$HOOK" 2>/dev/null)
    case "$got" in
        *"$2"*) printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)) ;;
        *) printf 'FAIL  %s (stdout %s)\n' "$1" "$got" >&2; FAIL=$((FAIL + 1)) ;;
    esac
}

expect_rc() {
    label="$1"; want="$2"; payload="$3"
    printf '%s' "$payload" | python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
    rc=$?
    if [ "$rc" = "$want" ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want rc=%s got rc=%s err=%s)\n' "$label" "$want" "$rc" "$(cat "$FIX/err")" >&2
        FAIL=$((FAIL + 1))
    fi
}

expect_file() {
    label="$1"; path="$2"; want="$3"
    if [ "$want" = present ] && [ -e "$path" ]; then
        ok=1
    elif [ "$want" = absent ] && [ ! -e "$path" ]; then
        ok=1
    else
        ok=0
    fi
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s at %s)\n' "$label" "$want" "$path" >&2
        FAIL=$((FAIL + 1))
    fi
}

# expect_class LABEL WANT ARG... -> classify_gh verdict for one gh argv
expect_class() {
    label="$1"; want="$2"; shift 2
    got=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import pr_post_guard; print(pr_post_guard.classify_gh(sys.argv[2:]))' "$(dirname "$HOOK")" "$@")
    if [ "$got" = "$want" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s got %s)\n' "$label" "$want" "$got" >&2; FAIL=$((FAIL + 1))
    fi
}

# --- A: the go is the owner's AskUserQuestion answer, one draft at a time --

case_gate a1
pending aaaaaaaa 1 'reply one'
pending bbbbbbbb 2 'reply two'
expect_out "A1 an answer reports the approval" "post gate: approved draft aaaaaaaa" "$(payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A1 draft A approved" "$GATE/s1.draft-aaaaaaaa.approved" present
expect_file "A1 draft B still pending" "$GATE/s1.draft-bbbbbbbb.pending" present
expect_rc "A1 one reply passes" 0 "$(payload_b s1 "$REVIEW")"
expect_rc "A1 a second reply needs its own approval" 2 "$(payload_b s1 "$REVIEW && $REVIEW")"

case_gate a2
pending aaaaaaaa 1 'reply one'
expect_rc "A2 a recommended post option" 0 "$(payload_a s1 'Post draft aaaaaaaa (Recommended)' 'reply one')"
expect_file "A2 approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a3
pending aaaaaaaa 1 'reply one'
expect_out "A3 text not shown is reported" "draft aaaaaaaa not approved: its text was not in the question" "$(payload_a s1 'Post draft aaaaaaaa' 'another text')"
expect_file "A3 not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
expect_file "A3 still pending" "$GATE/s1.draft-aaaaaaaa.pending" present

case_gate a4
pending aaaaaaaa 1 'line one
  line two'
expect_rc "A4 whitespace differences do not matter" 0 "$(payload_a s1 'Post draft aaaaaaaa' 'line one line two')"
expect_file "A4 approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a5
pending aaaaaaaa 1 'reply one'
expect_rc "A5 the text in the question counts" 0 "$(PA_QUESTION='Post this reply on PR 5? reply one' payload_a s1 'Post draft aaaaaaaa' '')"
expect_file "A5 approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a6
pending aaaaaaaa 1 'reply one'
expect_out "A6 a skip is reported" "post gate: draft aaaaaaaa skipped" "$(payload_a s1 'Skip draft aaaaaaaa' '')"
expect_file "A6 a skipped draft is dismissed" "$GATE/s1.draft-aaaaaaaa.dismissed" present
expect_rc "A6 a later post answer without re-registering" 0 "$(payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A6 a dismissed draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

for extra in '{"afkTimeoutMs": 60000}' '{"followUp": true}'; do
    case_gate a7
    rm -rf "$GATE"
    pending aaaaaaaa 1 'reply one'
    expect_out "A7 [$extra] answer is reported as ignored" "post gate: draft aaaaaaaa not decided (" "$(PA_EXTRA="$extra" payload_a s1 'Post draft aaaaaaaa' 'reply one')"
    expect_file "A7 [$extra] approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent
done

case_gate a8
pending aaaaaaaa 1 'reply one'
expect_out "A8 a multi-select answer is reported as ignored" "not decided (a multi-select question cannot approve)" "$(PA_MULTI=1 payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A8 a multi-select question approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a9
pending aaaaaaaa 1 'reply one'
expect_out "A9 free-form text is reported as undecided" "not decided (no Post or Skip option was chosen)" "$(PA_ANSWER='yes, post draft aaaaaaaa' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A9 free text that is not a label approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a10
expect_out "A10 an unregistered hash is reported" "draft cccccccc not approved: no pending draft in this session" "$(payload_a s1 'Post draft cccccccc' '')"

case_gate a11
pending aaaaaaaa 1 'reply one'
expect_rc "A11 answer in another session" 0 "$(payload_a s2 'Post draft aaaaaaaa' 'reply one')"
expect_file "A11 another session's answer approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a12
mkdir -p "$GATE"
printf '{"v":2,"batch":"initial","created":1,"argv":[]}' >"$GATE/s1.draft-aaaaaaaa.pending"
expect_out "A12 a v2 draft is reported" "its record is unreadable or predates prompt approval" "$(payload_a s1 'Post draft aaaaaaaa' '')"
expect_file "A12 a v2 draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a13
(PD_NULL=1 pending aaaaaaaa 1)
expect_rc "A13 a draft with no text" 0 "$(payload_a s1 'Post draft aaaaaaaa' '')"
expect_file "A13 a textless draft needs only its label" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a17b
LONG=$(python3 -c 'print("word " * 500)')
pending aaaaaaaa 1 "$LONG"
expect_out "A17b a draft over 2000 characters is refused" "over 2000 characters; shorten the draft or split it" "$(payload_a s1 'Post draft aaaaaaaa' "$LONG")"
expect_file "A17b an over-length draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
expect_file "A17b an over-length draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present

case_gate a17c
pending aaaaaaaa 1 'reply one'
expect_out "A17c a returned preview that lacks the text is refused" "its text was not in the question or the option's preview" "$(PA_EXTRA='{"annotations": {"Post this draft?": {"preview": "withheld"}}}' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A17c not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
expect_rc "A17c a returned preview with the text" 0 "$(PA_EXTRA='{"annotations": {"Post this draft?": {"preview": "reply one"}}}' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A17c approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a17d
BIGPREV=$(python3 -c 'print("reply one " + "pad " * 600)')
pending aaaaaaaa 1 'reply one'
expect_out "A17d a returned preview over 2000 characters is refused" "preview is over 2000 characters" "$(PA_EXTRA="{\"annotations\": {\"Post this draft?\": {\"preview\": \"$BIGPREV\"}}}" payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A17d an over-limit returned preview is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17e
pending aaaaaaaa 1 'reply one'
expect_out "A17e a sent preview over 2000 characters is refused" "preview is over 2000 characters" "$(payload_a s1 'Post draft aaaaaaaa' "$BIGPREV")"
expect_file "A17e an over-limit sent preview is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

for text in 'post it' 'post all' 'post aaaaaaaa' 'Post it.'; do
    case_gate a14
    rm -rf "$GATE"
    pending aaaaaaaa 1 'reply one'
    expect_rc "A14 [$text] typed prompt" 0 "$(payload_u s1 "$text")"
    expect_file "A14 [$text] a typed phrase approves nothing" "$GATE/s1.draft-aaaaaaaa.pending" present
done

case_gate a15
pending aaaaaaaa 1 'reply one'
expect_rc "A15 another tool's result" 0 "$(PA_TOOL=Read payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A15 only AskUserQuestion answers approve" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a16
pending aaaaaaaa 1 'reply one'
expect_rc "A16 a non-object tool_response exits 0" 0 '{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"AskUserQuestion","tool_response":"Post draft aaaaaaaa"}'
expect_file "A16 approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17
pending aaaaaaaa 1 'reply one'
pending bbbbbbbb 2 'reply two'
A17=$(python3 - <<'PY'
import json
qs = [{"question": f"Post reply {n}?", "multiSelect": False,
       "options": [{"label": f"Post draft {h}", "description": "posts it", "preview": f"reply {n}"},
                   {"label": f"Skip draft {h}", "description": "skips it"}]}
      for n, h in (("one", "aaaaaaaa"), ("two", "bbbbbbbb"))]
answers = {q["question"]: q["options"][0]["label"] for q in qs}
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": answers}}))
PY
)
expect_rc "A17 a two-question answer" 0 "$A17"
expect_file "A17 first draft approved" "$GATE/s1.draft-aaaaaaaa.approved" present
expect_file "A17 second draft approved" "$GATE/s1.draft-bbbbbbbb.approved" present
expect_rc "A17 two replies pass under two approvals" 0 "$(payload_b s1 'gh pr review 5 -c -b one && gh pr review 5 -c -b two')"

case_gate a18
pending aaaaaaaa 1 'reply one'
env -u HERDR_ENV sh -c 'printf "%s" "$1" | python3 "$2"' _ "$(payload_a s1 'Post draft aaaaaaaa' 'reply one')" "$HOOK" >/dev/null 2>&1
expect_file "A18 an answer outside herdr approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a19
pending aaaaaaaa 1 'reply one'
expect_rc "A19 post answer" 0 "$(payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_out "A19 a skip answer withdraws it" "post gate: draft aaaaaaaa approval withdrawn" "$(payload_a s1 'Skip draft aaaaaaaa' '')"
expect_file "A19 a withdrawn approval is dismissed" "$GATE/s1.draft-aaaaaaaa.dismissed" present
expect_rc "A19 the reply is denied again" 2 "$(payload_b s1 "$REVIEW")"

case_gate a20
pending aaaaaaaa 1 'reply one'
A20=$(python3 - <<'PY'
import json
qs = [{"question": "Post reply one?", "multiSelect": False,
       "options": [{"label": "Post draft aaaaaaaa", "description": "posts it", "preview": "reply one"},
                   {"label": "Hold", "description": "waits"}]},
      {"question": "Skip reply one after all?", "multiSelect": False,
       "options": [{"label": "Skip draft aaaaaaaa", "description": "skips it"},
                   {"label": "Hold", "description": "waits"}]}]
answers = {"Post reply one?": "Post draft aaaaaaaa", "Skip reply one after all?": "Skip draft aaaaaaaa"}
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": answers}}))
PY
)
expect_rc "A20 post then skip in one prompt" 0 "$A20"
expect_file "A20 ends dismissed" "$GATE/s1.draft-aaaaaaaa.dismissed" present

case_gate a21
mkdir -p "$GATE"
: >"$GATE/s1.draft-aaaaaaaa.approved"
expect_out "A21 an approved draft is reported as approved" "post gate: draft aaaaaaaa already approved; post it" "$(payload_a s1 'Post draft aaaaaaaa' '')"
expect_file "A21 it stays approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a22
mkdir -p "$GATE"
: >"$GATE/s1.draft-aaaaaaaa.spent"
expect_out "A22 a posted draft is reported as posted" "post gate: draft aaaaaaaa already posted once" "$(payload_a s1 'Post draft aaaaaaaa' '')"

case_gate a23
payload_b s1 "$REVIEW" | python3 "$HOOK" >/dev/null 2>"$FIX/err"
if grep -q 'AskUserQuestion' "$FIX/err" && grep -q 'Post draft <hash>' "$FIX/err" \
    && grep -q 'update --ai' "$FIX/err" && ! grep -qi 'post it' "$FIX/err"; then
    printf 'PASS  A23 the reply denial names the prompt and the upgrade fix\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  A23 reply denial text (%s)\n' "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
fi

case_gate a24
mkdir -p "$GATE"
: >"$GATE/s1.draft-aaaaaaaa.spent"
expect_out "A24 skipping a posted draft says it was posted" "post gate: draft aaaaaaaa not skipped: already posted" "$(payload_a s1 'Skip draft aaaaaaaa' '')"

case_gate a25
expect_out "A25 an answer with a bad session id is reported as ignored" "not decided (no valid session id)" "$(payload_a '../x' 'Post draft aaaaaaaa' '')"
expect_file "A25 no pid map is written" "$GATE" absent

case_gate a26
pending aaaaaaaa 1 'reply one'
expect_out "A26 a notes-only answer is reported as undecided" "not decided (no Post or Skip option was chosen)" "$(PA_ANSWER='(notes only)' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A26 approves nothing" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a27
pending aaaaaaaa 1 'reply one'
expect_out "A27 a timed-out prompt with no answers is reported" "not decided (the prompt timed out)" "$(PA_EXTRA='{"afkTimeoutMs": 60000, "answers": {}}' payload_a s1 'Post draft aaaaaaaa' 'reply one')"

case_gate a28
pending aaaaaaaa 1 'reply one'
pending bbbbbbbb 2 'reply two'
A28=$(python3 - <<'PY'
import json
q = "Post which reply?"
qs = [{"question": q, "multiSelect": False,
       "options": [{"label": "Post draft aaaaaaaa", "description": "posts one", "preview": "reply one"},
                   {"label": "Post draft bbbbbbbb", "description": "posts two", "preview": "reply two"}]}]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": {q: "Post draft aaaaaaaa"}}}))
PY
)
expect_out "A28 a question naming two drafts is refused" "post gate: draft bbbbbbbb not decided (the question names more than one draft)" "$A28"
expect_file "A28 neither draft is approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

# --- P: an approval is per draft, per session, and survives other prompts ---

case_gate p1
pending aaaaaaaa 1
expect_rc "P1 mint" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "P1 first post allowed" 0 "$(payload_b s1 "$REVIEW")"
expect_rc "P1 second post passes the hook (the shim spends the approval)" 0 "$(payload_b s1 "$REVIEW")"
expect_file "P1 the hook spends nothing" "$GATE/s1.draft-aaaaaaaa.approved" present
mv "$GATE/s1.draft-aaaaaaaa.approved" "$GATE/s1.draft-aaaaaaaa.spent"
expect_rc "P1c post denied once the shim has spent the approval" 2 "$(payload_b s1 "$REVIEW")"

case_gate p2
pending aaaaaaaa 1
expect_rc "P2 mint" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "P2 next prompt keeps the approval" 0 "$(payload_u s1 'thanks')"
expect_file "P2 a non-go prompt keeps the approval" "$GATE/s1.draft-aaaaaaaa.approved" present
expect_rc "P2 post allowed" 0 "$(payload_b s1 "$REVIEW")"

case_gate p3
pending aaaaaaaa 1
expect_rc "P3 mint under s1" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "P3 post under s2 denied" 2 "$(payload_b s2 "$REVIEW")"

case_gate p4
mkdir -p "$GATE"
printf '{"v":1,"kind":"post","expires_epoch":9999999999}' >"$GATE/s1.json"
expect_rc "P4 a legacy go marker is not honoured" 2 "$(payload_b s1 "$REVIEW")"

case_gate p5
pending aaaaaaaa 1
expect_rc "P5 mint" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "P5 one approval does not cover two replies" 2 "$(payload_b s1 "$REVIEW && $REVIEW")"

# --- D: deletes of own markers need no go (the shim checks ownership) ------

case_gate d1
expect_rc "D1 a delete passes the hook with no go (the shim checks ownership)" 0 "$(payload_b s1 'gh api -X DELETE repos/o/r/issues/comments/9')"

case_gate d2
expect_rc "D2 delete via -X DELETE" 0 "$(payload_b s1 'gh api -X DELETE repos/o/r/issues/comments/9')"
expect_rc "D2 delete via --method DELETE" 0 "$(payload_b s1 'gh api --method DELETE repos/o/r/issues/comments/8')"

case_gate d3
expect_rc "D3 loop delete allowed" 0 "$(payload_b s1 'for id in 1 2; do gh api -X DELETE repos/o/r/issues/comments/$id; done')"

# --- B: body edits and comments pass the hook; the shim decides ownership --

case_gate b1
expect_rc "B1 a body edit passes the hook with no go" 0 "$(payload_b s1 'gh pr edit 5 --body-file b.md')"

case_gate b2
expect_rc "B2 a title edit passes the hook" 0 "$(payload_b s1 'gh pr edit 5 --title t')"
expect_rc "B2 an api body PATCH passes the hook" 0 "$(payload_b s1 'gh api -X PATCH repos/o/r/pulls/5 -f body=x')"

case_gate b3
expect_rc "B3 a comment passes the hook with no go" 0 "$(payload_b s1 'gh pr comment 5 --body x')"

case_gate b4
expect_rc "B4 two body edits in one command pass the hook" 0 "$(payload_b s1 'gh pr edit 5 --body-file a.md ; gh pr edit 5 --body-file b.md')"

# --- R: reads and non-posting gh calls are always allowed -----------------

case_gate r1
expect_rc "R1 pr view" 0 "$(payload_b s1 'gh pr view 5 --json comments')"

case_gate r2
expect_rc "R2 api GET comments paginate slurp" 0 "$(payload_b s1 'gh api repos/o/r/issues/5/comments --paginate --slurp')"
expect_rc "R2 api user jq" 0 "$(payload_b s1 'gh api user --jq .login')"
expect_rc "R2 api explicit GET with field" 0 "$(payload_b s1 'gh api -X GET search/issues -f q=x')"

case_gate r3
expect_rc "R3 pr create" 0 "$(payload_b s1 'gh pr create --title t --body b')"
expect_rc "R3 pr checks" 0 "$(payload_b s1 'gh pr checks 5')"

# --- FP: ordinary work must never be misread as a post --------------------

case_gate fp1
expect_rc "FP1 commit message mentions gh pr comment" 0 "$(payload_b s1 'git commit -m "co-review: handle gh pr comment"')"

case_gate fp2
expect_rc "FP2 command substitution around a GET" 0 "$(payload_b s1 'X=$(gh api repos/o/r/issues/5/comments)')"

case_gate fp3
heredoc='git commit -F - <<'"'"'EOF'"'"'
gh pr comment 5 --body x
EOF'
expect_rc "FP3 heredoc body line is not parsed as a command" 0 "$(payload_b s1 "$heredoc")"

case_gate fp4
expect_rc "FP4 plain words that happen to include comment/review" 0 "$(payload_b s1 'echo high through right comment review')"

case_gate fp5
expect_rc "FP5 graphql read query" 0 "$(payload_b s1 "gh api graphql -f query='query { viewer { login } }'")"

# --- FN: classification must not miss these shapes -------------------------

case_gate fn1
expect_rc "FN1 reply endpoint" 2 "$(payload_b s1 'gh api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x')"

case_gate fn2
expect_rc "FN2 reaction endpoint" 2 "$(payload_b s1 'gh api repos/o/r/issues/comments/9/reactions -f content=+1')"

expect_class "FN3 issue body PATCH" body api -X PATCH repos/o/r/issues/5 -f body=x

expect_class "FN4 attached -XPOST" post api -XPOST repos/o/r/issues/5/comments --input c.json

expect_class "FN5 lowercase --method post" post api --method post repos/o/r/issues/5/comments --input c.json

case_gate fn6
expect_rc "FN6 path-invoked gh" 2 "$(payload_b s1 '/opt/homebrew/bin/gh pr review 5 -c -b x')"

case_gate fn7
expect_rc "FN7a command gh" 2 "$(payload_b s1 'command gh pr review 5 -c -b x')"
expect_rc "FN7b gh -R" 2 "$(payload_b s1 'gh -R o/r pr review 5 -c -b x')"

expect_class "FN8a pr close -c" post pr close 5 -c bye
expect_class "FN8b issue close --comment" post issue close 5 --comment bye

case_gate fn9
expect_rc "FN9a sh -c post" 2 "$(payload_b s1 "sh -c 'gh pr review 5 -c -b x'")"
expect_rc "FN9b bash -c reply" 2 "$(payload_b s1 "bash -c 'gh api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x'")"

case_gate fn10
expect_rc "FN10 graphql mutation" 2 "$(payload_b s1 "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'")"

case_gate fn11
expect_rc "FN11a pr review" 2 "$(payload_b s1 'gh pr review 5 --approve')"
expect_class "FN11b issue comment" post issue comment 5 -b x

case_gate fn12
expect_rc "FN12a env -i gh pr comment denied with no go" 2 "$(payload_b s1 'env -i gh pr review 5 -c -b x')"
expect_rc "FN12b sudo -u me gh pr comment denied with no go" 2 "$(payload_b s1 'sudo -u me gh pr review 5 -c -b x')"
expect_rc "FN12c nice -n 5 gh pr review denied with no go" 2 "$(payload_b s1 'nice -n 5 gh pr review 5 -c -b x')"
expect_rc "FN12d env -i gh api thread reply denied with no go" 2 "$(payload_b s1 'env -i gh api -X POST repos/o/r/pulls/5/comments/9/replies -f body=x')"
pending aaaaaaaa 1
expect_rc "FN12e mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "FN12f env -i gh pr comment allowed once after an approved draft" 0 "$(payload_b s1 'env -i gh pr review 5 -c -b x')"

case_gate fn13
expect_rc "FN13a if-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'if gh pr review 5 -c -b x; then echo ok; fi')"
expect_rc "FN13b while-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'while ! gh pr review 5 -c -b x; do :; done')"
expect_rc "FN13c until-wrapped gh pr comment denied with no go" 2 "$(payload_b s1 'until gh pr review 5 -c -b x; do :; done')"

case_gate fn14
trailing_comment='cd /repo  # go to repo
gh pr review 5 -c -b x'
expect_rc "FN14 gh pr comment on the line after a trailing # comment is denied with no go" 2 "$(payload_b s1 "$trailing_comment")"

case_gate fn15
apostrophe_comment="# don't post yet
gh pr review 5 -c -b x"
expect_rc "FN15 an apostrophe inside a # comment does not desync the tokenizer" 2 "$(payload_b s1 "$apostrophe_comment")"

case_gate fn16
paren_line='(cd /repo)
gh pr review 5 -c -b x'
expect_rc "FN16 gh pr comment on the line after a lone ) is denied with no go" 2 "$(payload_b s1 "$paren_line")"

case_gate fn17
subst_line='PR=$(gh pr view --json number -q .number)
gh pr review "$PR" -c -b x'
expect_rc "FN17 gh pr comment on the line after a command substitution is denied with no go" 2 "$(payload_b s1 "$subst_line")"

# --- V: round-3 blocker and minors, and the redesign's default-deny -------

case_gate v1
cont_line=$(printf 'gh api -X POST \\\nrepos/o/r/pulls/5/comments/9/replies -f body=x')
expect_rc "V1 backslash line continuation is denied with no go" 2 "$(payload_b s1 "$cont_line")"
case_gate v1b
pending aaaaaaaa 1
expect_rc "V1b mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "V1b same continuation allowed after an approved draft" 0 "$(payload_b s1 "$cont_line")"

case_gate v2
expect_rc "V2 env assignment ahead of a flagged wrapper is still denied with no go" 2 "$(payload_b s1 'FOO=1 sudo -u me gh pr review 5 -c -b x')"

case_gate v3
expect_rc "V3 a mid-word # in an argument does not defeat the post gate" 2 "$(payload_b s1 'gh pr review 5 -c -b abc#hidden')"

case_gate v4
expect_rc "V4a timeout-wrapped gh pr comment is denied with no go" 2 "$(payload_b s1 'timeout 5 gh pr review 5 -c -b x')"
pending aaaaaaaa 1
expect_rc "V4a mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "V4a timeout-wrapped gh pr comment passes after an approved draft" 0 "$(payload_b s1 'timeout 5 gh pr review 5 -c -b x')"
case_gate v4b
expect_rc "V4b stdbuf-wrapped gh pr comment is denied with no go" 2 "$(payload_b s1 'stdbuf -oL gh pr review 5 -c -b x')"

case_gate v5
expect_rc "V5 ANSI-C \$'...' quoting is denied outright, no go" 2 "$(payload_b s1 "gh pr review 5 -c -b \$'hi'")"
pending aaaaaaaa 1
expect_rc "V5 mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "V5 ANSI-C quoted post passes after an approved draft" 0 "$(payload_b s1 "gh pr review 5 -c -b \$'hi'")"

# --- U: a gh call outside the read and gated tables passes as a write ------

case_gate u1
expect_rc "U1 unknown gh subcommand passes the hook as a plain write" 0 "$(payload_b s1 'gh foo bar')"
case_gate u1b
pending aaaaaaaa 1
expect_rc "U1b mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "U1b unknown gh subcommand passes the hook after an approved draft" 0 "$(payload_b s1 'gh foo bar')"

case_gate u2
expect_rc "U2 api POST to an ungated path passes the hook as a plain write" 0 "$(payload_b s1 'gh api -X POST repos/o/r/labels -f name=x')"
case_gate u2b
pending aaaaaaaa 1
expect_rc "U2b mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "U2b api POST to an ungated path passes the hook after an approved draft" 0 "$(payload_b s1 'gh api -X POST repos/o/r/labels -f name=x')"

# --- W: every allowed read and known write form -----------------------------

case_gate w1
expect_rc "W1 pr checks" 0 "$(payload_b s1 'gh pr checks 5')"
expect_rc "W1 pr diff" 0 "$(payload_b s1 'gh pr diff 5')"
expect_rc "W1 pr status" 0 "$(payload_b s1 'gh pr status')"
expect_rc "W1 pr list" 0 "$(payload_b s1 'gh pr list')"
expect_rc "W1 run view" 0 "$(payload_b s1 'gh run view 123')"
expect_rc "W1 run list" 0 "$(payload_b s1 'gh run list')"
expect_rc "W1 run watch" 0 "$(payload_b s1 'gh run watch 123')"
expect_rc "W1 issue view" 0 "$(payload_b s1 'gh issue view 5')"
expect_rc "W1 issue list" 0 "$(payload_b s1 'gh issue list')"
expect_rc "W1 repo view" 0 "$(payload_b s1 'gh repo view')"
expect_rc "W1 search prs" 0 "$(payload_b s1 'gh search prs --author=@me --state=open')"
expect_rc "W1 auth status" 0 "$(payload_b s1 'gh auth status')"

case_gate w2
expect_rc "W2 pr merge is a known non-comment write" 0 "$(payload_b s1 'gh pr merge --squash --match-head-commit abc123')"

# --- X: an internal error on a gh-mentioning command fails closed ----------

case_gate x1
X1_RC=$(HOOK="$HOOK" GATE="$GATE" python3 - <<'PY'
import importlib.util, io, json, os, sys
sys.path.insert(0, "claude/hooks")
os.environ["HERDR_ENV"] = "1"
os.environ["DOTFILES_POST_GATE_DIR"] = os.environ["GATE"]
spec = importlib.util.spec_from_file_location("g_forced", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(command, depth=0, cwd=""):
    raise RuntimeError("forced")


g.classify = boom
payload = {
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr comment 5 --body x"},
}
sys.stdin = io.StringIO(json.dumps(payload))
print(g.main())
PY
)
if [ "$X1_RC" = 0 ]; then
    printf 'PASS  X1 forced classify() exception fails open (the shim still gates)\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  X1 forced classify() exception fails open (the shim still gates) (got %s)\n' "$X1_RC" >&2; FAIL=$((FAIL + 1))
fi

case_gate x2
X2_RC=$(HOOK="$HOOK" GATE="$GATE" python3 - <<'PY'
import importlib.util, io, json, os, sys
sys.path.insert(0, "claude/hooks")
os.environ.pop("HERDR_ENV", None)
os.environ["DOTFILES_POST_GATE_DIR"] = os.environ["GATE"]
spec = importlib.util.spec_from_file_location("g_forced2", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)


def boom(command, depth=0, cwd=""):
    raise RuntimeError("forced")


g.classify = boom
payload = {
    "hook_event_name": "PreToolUse",
    "session_id": "s1",
    "tool_name": "Bash",
    "tool_input": {"command": "gh pr comment 5 --body x"},
}
sys.stdin = io.StringIO(json.dumps(payload))
print(g.main())
PY
)
if [ "$X2_RC" = 0 ]; then
    printf 'PASS  X2 forced classify() exception outside herdr still exits 0\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  X2 forced classify() exception outside herdr still exits 0 (got %s)\n' "$X2_RC" >&2; FAIL=$((FAIL + 1))
fi

# --- H: second-layer rules for the exec-time gh shim -----------------------

# A PATH with python3 but no shim: the unarmed session case.
mkdir -p "$FIX/py"
ln -s "$(command -v python3)" "$FIX/py/python3"

case_gate h1
pending aaaaaaaa 1
expect_rc "H1 mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
payload_b s1 'gh pr comment 5 --body x' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>"$FIX/err"
rc=$?
if [ "$rc" = 2 ] && grep -q 'Relaunch' "$FIX/err"; then
    printf 'PASS  H1 go not honored when gh on PATH is not the shim\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 go not honored when gh on PATH is not the shim (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'gh pr view 5' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 reads are denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 reads are denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'g""h pr comment 5 --body x' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 quote-split gh is denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 quote-split gh is denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
unarmed_heredoc='bash <<EOF
gh pr comment 5 --body x
EOF'
payload_b s1 "$unarmed_heredoc" | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 2 ]; then
    printf 'PASS  H1 gh in a heredoc is denied too when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 gh in a heredoc is denied too when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi
payload_b s1 'ls -l' | PATH="$FIX/py:/bin" python3 "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" = 0 ]; then
    printf 'PASS  H1 commands without gh pass when the shim is not armed\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H1 commands without gh pass when the shim is not armed (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate h2
pending aaaaaaaa 1
expect_rc "H2 mint post" 0 "$(payload_a s1 'Post draft aaaaaaaa' x)"
expect_rc "H2 path-qualified gh denied even with a go" 2 "$(payload_b s1 '/opt/homebrew/bin/gh pr view 5')"
expect_rc "H2 path-qualified gh inside bash -c denied" 2 "$(payload_b s1 "bash -c '/opt/homebrew/bin/gh pr view 5'")"
expect_rc "H2 path-qualified gh behind timeout denied" 2 "$(payload_b s1 'timeout 5 /opt/homebrew/bin/gh pr comment 5 --body x')"
expect_rc "H2 path-qualified gh in an eval script denied" 2 "$(payload_b s1 "eval '/opt/homebrew/bin/gh pr comment 5 --body x'")"
expect_rc "H2 shell behind a runner is checked" 2 "$(payload_b s1 "timeout 60 bash -c '/opt/homebrew/bin/gh pr comment 5 --body x'")"
expect_rc "H2 login sh behind a runner denied" 2 "$(payload_b s1 "timeout 60 sh -lc 'gh pr comment 5 --body x'")"
expect_rc "H2 pane text behind a flagged env denied" 2 "$(payload_b s1 "env -u FOO herdr pane run w1:p3 'gh pr comment 5 --body x'")"
expect_rc "H2 backtick-built gh path denied" 2 "$(payload_b s1 '`brew --prefix`/bin/gh pr comment 5 --body x')"
expect_rc "H2 substituted path-qualified gh denied" 2 "$(payload_b s1 '$(brew --prefix)/bin/gh pr view 5')"
expect_rc "H2 login sh denied even with a go" 2 "$(payload_b s1 "sh -lc 'gh pr comment 5 --body x'")"
expect_rc "H2 login dash denied" 2 "$(payload_b s1 'dash -l -c true')"
expect_rc "H2 sh --login denied" 2 "$(payload_b s1 'sh --login -c true')"
expect_rc "H2 bash --posix login denied" 2 "$(payload_b s1 'bash --posix -l -c true')"
expect_rc "H2 zsh --emulate login denied" 2 "$(payload_b s1 'zsh --emulate sh -l -c true')"
expect_rc "H2 interactive login bash denied" 2 "$(payload_b s1 "bash -lic 'gh pr comment 5 --body x'")"
expect_rc "H2 split interactive login bash flags denied" 2 "$(payload_b s1 'bash -l -i -c true')"
expect_rc "H2 gh sent to another pane denied" 2 "$(payload_b s1 "herdr pane run w1:p3 'gh pr view 5'")"
expect_rc "H2 quote-split gh sent to another pane denied" 2 "$(payload_b s1 "herdr pane send-text w1:p3 'g\"\"h pr comment 5 --body x'")"

case_gate h3
expect_rc "H3 login bash passes (BASH_ENV anchors it)" 0 "$(payload_b s1 "bash -lc 'gh pr view 5'")"
expect_rc "H3 login zsh passes (.zprofile anchors it)" 0 "$(payload_b s1 "zsh -lc 'gh pr view 5'")"
expect_rc "H3 timeout wrapper passes (the shim gates at exec)" 0 "$(payload_b s1 'timeout 60 gh run watch 1')"
expect_rc "H3 repo clone passes" 0 "$(payload_b s1 'gh repo clone o/r')"
expect_rc "H3 ANSI-C elsewhere in the command passes" 0 "$(payload_b s1 "echo \$'a' && gh pr view 5")"
expect_rc "H3 git add of the shim path passes" 0 "$(payload_b s1 'git add bin/herdr-shims/gh')"
expect_rc "H3 a runner in front of git add passes" 0 "$(payload_b s1 'env -u HERDR_ENV git add bin/herdr-shims/gh')"
expect_rc "H3 a runner in front of cat passes" 0 "$(payload_b s1 'timeout 5 cat bin/herdr-shims/gh')"
expect_rc "H3 a backtick in single quotes passes" 0 "$(payload_b s1 "git commit -m 'run \`/opt/homebrew/bin/gh\` by hand'")"
expect_rc "H3 sh -c with an -l argument passes" 0 "$(payload_b s1 "sh -c 'ls -l'")"
expect_rc "H3 other text sent to a pane passes" 0 "$(payload_b s1 "herdr pane run w1:p3 'ls -l'")"
expect_rc "H3 a gh-named task id sent to a pane passes" 0 "$(payload_b s1 "herdr pane run w1:p3 'python3 core.py run-mech --task-id 2026-09-25-fix-gh-shim'")"
expect_rc "H3 help on an alias stays unknown and passes the hook" 0 "$(payload_b s1 'gh c 5 --help')"

# --- PA: gh api argv is split the way gh splits it --------------------------

expect_class "PA1 clustered -iX DELETE is a delete" delete api -iX DELETE repos/o/r/issues/comments/1
expect_class "PA2 clustered -if field is a post" post api -ifbody=x repos/o/r/issues/1/comments
expect_class "PA3 clustered -iF graphql query file is a reply" reply api graphql -iF query=@m.graphql
expect_class "PA4 -X=GET is a read" read api -X=GET repos/o/r/issues/1
expect_class "PA5 an unknown short flag is a plain write" write api -Z repos/o/r/issues/1
expect_class "PA6 a value flag takes a dash-led next arg; fields still post" post api -t -iXGET repos/o/r/issues/1/comments -f body=hi
expect_class "PA7 -q taking -iXGET keeps the DELETE" delete api -X DELETE -q -iXGET repos/o/r/issues/comments/1
expect_class "PA8 plain -X DELETE is still a delete" delete api -X DELETE repos/o/r/issues/comments/1
expect_class "PA9 a paginated read is still a read" read api repos/o/r/issues/1/comments --paginate

case_gate pa10
expect_rc "PA10 the hook sees a clustered reply" 2 "$(payload_b s1 'gh api -iX POST repos/o/r/pulls/5/comments/9/replies -f body=x')"

# --- C: classifier entries and the pid map the gh shim reads ---------------

case_gate c1
expect_rc "C1 help on a gated subcommand is a read" 0 "$(payload_b s1 'gh pr comment 5 --help')"
expect_rc "C1 graphql query from a file is gated" 2 "$(payload_b s1 'gh api graphql -F query=@m.graphql')"
expect_rc "C1 graphql query from stdin is gated" 2 "$(payload_b s1 'gh api graphql --input -')"

case_gate h4
expect_rc "H4 prompt writes the pid map" 0 "$(payload_u s1 'thanks')"
if [ "$(cat "$GATE"/pid-*.sid 2>/dev/null)" = s1 ] && [ "$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$GATE"/pid-*.sid)" = 0o600 ]; then
    printf 'PASS  H4 pid map holds the session id, mode 0600\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  H4 pid map holds the session id, mode 0600\n' >&2; FAIL=$((FAIL + 1))
fi

case_gate h5
: >"$GATE"
expect_rc "H5 an unwritable gate dir never blocks a prompt" 0 "$(payload_u s1 'thanks')"

# --- M: gate mechanics ------------------------------------------------------

case_gate m1
env -u HERDR_ENV sh -c '
    export DOTFILES_POST_GATE_DIR="'"$GATE"'"
    payload="{\"hook_event_name\": \"UserPromptSubmit\", \"session_id\": \"s1\", \"prompt\": \"post it\"}"
    printf "%s" "$payload" | python3 "'"$HOOK"'" >/dev/null 2>&1
    echo $?
' >"$FIX/m1-u-rc"
if [ "$(cat "$FIX/m1-u-rc")" = 0 ]; then
    printf 'PASS  M1 prompt inert outside herdr\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M1 prompt inert outside herdr (rc=%s)\n' "$(cat "$FIX/m1-u-rc")" >&2; FAIL=$((FAIL + 1))
fi
env -u HERDR_ENV sh -c '
    export DOTFILES_POST_GATE_DIR="'"$GATE"'"
    payload="{\"hook_event_name\": \"PreToolUse\", \"session_id\": \"s1\", \"tool_name\": \"Bash\", \"tool_input\": {\"command\": \"gh pr comment 5 --body x\"}}"
    printf "%s" "$payload" | python3 "'"$HOOK"'" >/dev/null 2>&1
    echo $?
' >"$FIX/m1-b-rc"
if [ "$(cat "$FIX/m1-b-rc")" = 0 ]; then
    printf 'PASS  M1 post inert outside herdr\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M1 post inert outside herdr (rc=%s)\n' "$(cat "$FIX/m1-b-rc")" >&2; FAIL=$((FAIL + 1))
fi
expect_file "M1 gate dir never created" "$GATE" absent

case_gate m2
expect_rc "M2 bad sid prompt is a no-op" 0 "$(payload_u '../x' 'post it')"
expect_file "M2 no file escapes the gate dir" "$FIX/x.json" absent
expect_rc "M2 bad sid post denied" 2 "$(payload_b '../x' "$REVIEW")"
mkdir -p "$GATE"
printf '{' >"$GATE/s9.json"
expect_rc "M2 a corrupt legacy marker grants nothing" 2 "$(payload_b s9 "$REVIEW")"

case_gate m3
python3 "$HOOK" draft -- gh pr review 5 -c -b x >/dev/null
modes=$(python3 -c "
import glob, os, stat, sys
d = sys.argv[1]
f = glob.glob(d + '/s1.draft-*.pending')[0]
print(oct(stat.S_IMODE(os.stat(d).st_mode)), oct(stat.S_IMODE(os.stat(f).st_mode)))
" "$GATE")
if [ "$modes" = "0o700 0o600" ]; then
    printf 'PASS  M3 draft file modes\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  M3 draft file modes (got %s)\n' "$modes" >&2; FAIL=$((FAIL + 1))
fi
: >"$GATE/old.json"
python3 -c "
import os, sys, time
p = sys.argv[1]
old = time.time() - 2 * 86400
os.utime(p, (old, old))
" "$GATE/old.json"
expect_rc "M3 a prompt prunes old files" 0 "$(payload_u s1 'thanks')"
expect_file "M3 old marker pruned" "$GATE/old.json" absent

# --- P: personal repositories post without a go -------------------------

case_gate pp1
NOSHIM_PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v 'herdr-shims' | paste -sd: -)
P1_PAYLOAD=$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 1 --body x')
printf '%s' "$P1_PAYLOAD" | PATH="$NOSHIM_PATH" python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
p1rc=$?
if [ "$p1rc" = 0 ]; then
    printf 'PASS  P1 personal unarmed comment passes\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  P1 personal unarmed comment (rc=%s)\n' "$p1rc" >&2; FAIL=$((FAIL + 1))
fi
expect_rc "P2 personal armed pr comment no go" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr comment 1 --body x')"
expect_rc "P3 personal armed pr edit body no go" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr edit 1 --body x')"
expect_rc "P4 work armed pr review no go" 2 "$(payload_b s1 'gh pr review 1 -c -b x')"
expect_rc "P5 work armed pr edit passes the hook (the shim decides)" 0 "$(payload_b s1 'gh pr edit 1 --body x')"

# --- V1x: options before the subcommand pair and other spellings stay gated --

case_gate v1x
expect_class "V1x-1 -R between the subcommand words is a post" post pr -R o/r comment 5 --body x
expect_class "V1x-2 an unknown flag before the pair is skipped" post --paginate pr comment 5 --body x
expect_class "V1x-3 attached close comment -cbye is a post" post pr close 5 -cbye
expect_class "V1x-4 --comment=bye on issue close is a post" post issue close 5 --comment=bye
expect_class "V1x-5 a close without a comment is a plain write" write pr close 5 --delete-branch
expect_class "V1x-6 a query string on a body path is still a body edit" body api -X PATCH "repos/o/r/pulls/5?x=1" -f body=x
expect_class "V1x-7 a fragment on a comment path is still a post" post api "repos/o/r/issues/5/comments#top" -f body=x
expect_class "V1x-8 a query string on a comment delete is still a delete" delete api -X DELETE "repos/o/r/issues/comments/9?x=1"
expect_rc "V1x-9 hook denies -R between the words with no go" 2 "$(payload_b s1 'gh pr -R o/r review 5 -c -b x')"
expect_rc "V1x-10 hook denies an attached-flag review with no go" 2 "$(payload_b s1 'gh pr review 5 -cb x')"
expect_rc "V1x-11 hook denies a query-string reply with no go" 2 "$(payload_b s1 'gh api -X POST '"'"'repos/o/r/pulls/5/comments/9/replies?x=1'"'"' -f body=x')"

# --- T: the personal exemption follows the post target, not the cwd --------

case_gate t1
expect_rc "T1 personal cwd, -R to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr review 5 -R work-org/repo -c -b x')"
expect_rc "T1 personal cwd, --repo= to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr review 5 --repo=work-org/repo -c -b x')"
expect_rc "T1 personal cwd, api path to a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh api repos/work-org/repo/pulls/5/comments/9/replies -f body=x')"
GH_REPO=work-org/repo
export GH_REPO
expect_rc "T1 personal cwd, GH_REPO on a work repo needs a go" 2 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr review 5 -c -b x')"
unset GH_REPO
expect_rc "T1 personal cwd, -R to its own origin needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr review 5 -R me/repo -c -b x')"
expect_rc "T1 personal cwd, api path to its own origin needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh api repos/me/repo/pulls/5/comments/9/replies -f body=x')"
expect_rc "T1 personal cwd, no target needs none" 0 "$(PB_CWD="$PERSONAL_CWD" payload_b s1 'gh pr review 5 -c -b x')"
expect_rc "T1 work cwd, -R to the personal login still needs a go" 2 "$(payload_b s1 'gh pr review 5 -R me/repo -c -b x')"

# --- AU/MN/PB: pure helpers the gh shim decides with --------------------

# expect_py LABEL WANT CODE -> stdout of CODE run with pr_post_guard as g
expect_py() {
    label="$1"; want="$2"; code="$3"
    got=$(python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import pr_post_guard as g; $code" "$(dirname "$HOOK")" 2>&1)
    if [ "$got" = "$want" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (want %s got %s)\n' "$label" "$want" "$got" >&2; FAIL=$((FAIL + 1))
    fi
}

expect_py "AU1 a reply is gated even on an own PR" gated 'print(g.audience("reply", True, ("text", "hi")))'
expect_py "AU2 a comment on another author PR is gated" gated 'print(g.audience("post", False, ("text", "hi")))'
expect_py "AU3 an own-PR edit with no body is maintenance" maintenance 'print(g.audience("body", True, ("none", None)))'
expect_py "AU4 an own-PR edit with an unreadable body is gated" gated 'print(g.audience("body", True, ("unreadable", None)))'
expect_py "AU5 an own-PR edit that mentions someone is gated" gated 'print(g.audience("body", True, ("text", "see @rev")))'
expect_py "AU6 an own-PR body edit is maintenance" maintenance 'print(g.audience("body", True, ("text", "new counts")))'
expect_py "AU7 an own-PR comment with no body is gated" gated 'print(g.audience("post", True, ("none", None)))'
expect_py "AU8 an APPROVE marker on an own PR is green" green 'print(g.audience("post", True, ("text", "<!-- co-review: sha=" + "a" * 40 + " base=" + "b" * 40 + " base_ref=main verdict=APPROVE round=1 -->\nVerdict: APPROVE")))'
expect_py "AU9 a CHANGES marker on an own PR is gated" gated 'print(g.audience("post", True, ("text", "<!-- co-review: sha=" + "a" * 40 + " base=" + "b" * 40 + " base_ref=main verdict=CHANGES round=2 -->\nVerdict: CHANGES")))'
expect_py "AU10 a truncated marker on an own PR is gated" gated 'print(g.audience("post", True, ("text", "<!-- co-review: sha=abc")))'
expect_py "AU11 a free comment on an own PR is own-comment" own-comment 'print(g.audience("post", True, ("text", "bench: 12/12 passed")))'

expect_py "MN1 an at-login mentions a person" True 'print(g.mentions_person("thanks @rev"))'
expect_py "MN2 an email address does not" False 'print(g.mentions_person("mail a@b.com"))'
expect_py "MN3 an inline code span does not" False 'print(g.mentions_person("use `@dataclass` here"))'
expect_py "MN4 a fenced code block does not" False 'print(g.mentions_person("```\n@x\n```\nok"))'
expect_py "MN5 a parenthesised mention does" True 'print(g.mentions_person("(@rev)"))'


expect_py "PB1 a stdin body file is unreadable" "unreadable None" 'print(*g.post_body(["pr", "comment", "5", "--body-file", "-"], "."))'
expect_py "PB2 a --body value is the text" "text hi" 'print(*g.post_body(["pr", "comment", "5", "-b", "hi"], "."))'
expect_py "PB3 a gh api body field is the text" "text x" 'print(*g.post_body(["api", "repos/o/r/issues/5/comments", "-f", "body=x"], "."))'

# --- DH/DR/DS: draft hash, registration and state files ---------------------

DH1_OUT=$(HOOK="$HOOK" FIX="$FIX" python3 - <<'PY'
import os, subprocess, sys
sys.path.insert(0, os.path.dirname(os.environ["HOOK"]))
import pr_post_guard as g
d = os.path.join(os.environ["FIX"], "dh1")
os.makedirs(d)
subprocess.run(["git", "init", "-q", d], check=True)
subprocess.run(["git", "-C", d, "remote", "add", "origin", "https://github.com/o/r.git"], check=True)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply one")
argv = ["pr", "review", "5", "-c", "-F", "r.md"]
first = g.draft_hash(argv, d)
same = first == g.draft_hash(argv, d)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply two")
byte = first != g.draft_hash(argv, d)
with open(os.path.join(d, "r.md"), "w") as f:
    f.write("reply one")
token = first != g.draft_hash(["pr", "review", "6", "-c", "-F", "r.md"], d)
os.environ["GH_REPO"] = "o/other"
repo = first != g.draft_hash(argv, d)
del os.environ["GH_REPO"]
subprocess.run(["git", "-C", d, "remote", "set-url", "origin", "https://github.com/x/r.git"], check=True)
origin = first != g.draft_hash(argv, d)
print(len(first), same, byte, token, repo, origin)
PY
)
if [ "$DH1_OUT" = "8 True True True True True" ]; then
    printf 'PASS  DH1 draft_hash is stable and binds body bytes, argv, GH_REPO and origin\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DH1 draft_hash binding (got %s)\n' "$DH1_OUT" >&2; FAIL=$((FAIL + 1))
fi

expect_py "DH2 a stdin or editor body has no draft hash" "None None" 'print(g.draft_hash(["pr", "comment", "5", "--body-file", "-"], "."), g.draft_hash(["pr", "comment", "5", "-e"], "."))'

case_gate dr1
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>"$FIX/err"; rc=$?
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\): gh pr review 5 -c -b hi$/\1/p' "$FIX/out")
if [ "$rc" = 0 ] && [ -n "$h" ] && [ "$(sed -n 2p "$FIX/out")" = hi ] \
    && python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); sys.exit(0 if r["v"] == 3 and r["text"] == "hi" and "batch" not in r else 1)' "$GATE/s1.draft-$h.pending"; then
    printf 'PASS  DR1 draft prints its hash and body and records a pending draft\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR1 draft registration (rc=%s out=%s err=%s)\n' "$rc" "$(cat "$FIX/out")" "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
fi
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.approved"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
if [ "$(cat "$FIX/out")" = "draft $h already approved" ] && [ ! -e "$GATE/s1.draft-$h.pending" ] && [ -e "$GATE/s1.draft-$h.approved" ]; then
    printf 'PASS  DR2 re-showing an approved draft leaves the approval alone\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR2 re-showing an approved draft (out=%s)\n' "$(cat "$FIX/out")" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr3
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p' "$FIX/out")
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.dismissed"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >/dev/null 2>&1
if [ -e "$GATE/s1.draft-$h.pending" ] && [ ! -e "$GATE/s1.draft-$h.dismissed" ]; then
    printf 'PASS  DR3 re-showing a dismissed draft makes it pending again\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR3 re-showing a dismissed draft\n' >&2; FAIL=$((FAIL + 1))
fi

case_gate dr4
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID python3 "$HOOK" draft -- gh pr review 5 -c -b hi >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ ! -e "$GATE" ]; then
    printf 'PASS  DR4 draft without a session id refuses\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR4 draft without a session id (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr5
printf 'x' | python3 "$HOOK" draft -- gh pr comment 5 --body-file - >/dev/null 2>&1; rc=$?
if [ "$rc" = 1 ] && [ ! -e "$GATE" ]; then
    printf 'PASS  DR5 draft of a stdin body refuses\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR5 draft of a stdin body (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
fi

case_gate dr7
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
h=$(sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p' "$FIX/out")
mv "$GATE/s1.draft-$h.pending" "$GATE/s1.draft-$h.spent"
python3 "$HOOK" draft -- gh pr review 5 -c -b hi >"$FIX/out" 2>&1
if grep -q "^\[WARNING\] draft $h already ran once; read the PR first: a duplicate is possible$" "$FIX/out" && [ -e "$GATE/s1.draft-$h.pending" ]; then
    printf 'PASS  DR7 re-showing a spent draft warns that a duplicate is possible\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  DR7 duplicate warning (out=%s)\n' "$(cat "$FIX/out")" >&2; FAIL=$((FAIL + 1))
fi

case_gate ds2
mkdir -p "$GATE"
: >"$GATE/s1.draft-cccccccc.approved"
expect_py "DS2 an approved draft spends exactly once" "True False" "from pathlib import Path; d = Path('$GATE'); print(g.spend_draft(d, 's1', 'cccccccc'), g.spend_draft(d, 's1', 'cccccccc'))"

case_gate ds3
mkdir -p "$GATE"
: >"$GATE/s1.draft-eeeeeeee.approved"
python3 -c 'import os, sys, time; old = time.time() - 2 * 86400; os.utime(sys.argv[1], (old, old))' "$GATE/s1.draft-eeeeeeee.approved"
expect_py "DS3 a late spend survives the next prune" "True True" "import time; from pathlib import Path; d = Path('$GATE'); ok = g.spend_draft(d, 's1', 'eeeeeeee'); g.prune(d, time.time()); print(ok, (d / 's1.draft-eeeeeeee.spent').exists())"

case_gate ds4
mkdir -p "$GATE"
printf '{"v":3,"created":1,"argv":[],"text":null}' >"$GATE/s1.draft-ffffffff.pending"
python3 -c 'import os, sys, time; old = time.time() - 2 * 86400; os.utime(sys.argv[1], (old, old))' "$GATE/s1.draft-ffffffff.pending"
expect_py "DS4 an old draft approved now survives the next prune" "True" "import time; from pathlib import Path; d = Path('$GATE'); g.approve_draft(d, 's1', 'ffffffff', 'Post this draft?', ''); g.prune(d, time.time()); print((d / 's1.draft-ffffffff.approved').exists())"

# --- P9: legacy cleanup ---

case_gate p9
mkdir -p "$GATE"
: >"$GATE/s1.json"
: >"$GATE/s1.post-used"
: >"$GATE/s1.batch"
expect_rc "P9 prompt" 0 "$(payload_u s1 'thanks')"
expect_file "P9 legacy go files are removed" "$GATE/s1.json" absent
expect_file "P9 the retired batch file is removed" "$GATE/s1.batch" absent

# --- KC: kinds the hook and shim now tell apart ------------------------------

expect_class "KC1 pr review is a reply" reply pr review 5 -c -b x
expect_class "KC2 a new review comment is a reply" reply api -X POST repos/o/r/pulls/5/comments -f body=x
expect_class "KC3 editing a comment is a reply" reply api -X PATCH repos/o/r/issues/comments/9 -f body=x
expect_class "KC4 an in_reply_to field is a reply" reply api repos/o/r/issues/5/comments -F in_reply_to=9 -f body=x
expect_class "KC5 a graphql mutation is a reply" reply api graphql -f 'query=mutation { x }'
expect_class "KC6 a title edit is a body write" body pr edit 5 --title t
expect_class "KC7 an issue comment is a post" post issue comment 5 -b x
expect_class "KC8 a comment delete stays a delete" delete api -X DELETE repos/o/r/issues/comments/9

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
