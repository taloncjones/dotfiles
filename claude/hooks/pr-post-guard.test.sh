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

# payload_a SID LABEL TEXT -> PostToolUse AskUserQuestion JSON: one
# question "$PA_QUESTION" (default "Post this draft?" plus TEXT) with the
# options LABEL (preview $PA_OPT_PREVIEW, none by default) and "Hold",
# answered with $PA_ANSWER (default LABEL). PA_MULTI=1 makes it multi-select, PA_EXTRA is JSON merged into
# tool_response, PA_TOOL replaces the tool name. Set these only inside
# $(...): a sh assignment before a function call can outlive the call.
payload_a() {
    PA_SID="$1" PA_LABEL="$2" PA_TEXT="${3-}" python3 - <<'PY'
import json, os
q = os.environ.get("PA_QUESTION") or "Post this draft?\n" + os.environ["PA_TEXT"]
label = os.environ["PA_LABEL"]
option = {"label": label, "description": "posts the draft"}
if os.environ.get("PA_OPT_PREVIEW"):
    option["preview"] = os.environ["PA_OPT_PREVIEW"]
questions = [{"question": q, "header": "Post", "multiSelect": os.environ.get("PA_MULTI") == "1",
              "options": [option,
                          {"label": "Hold", "description": "wait"}]}]
response = {"questions": questions, "answers": {q: os.environ.get("PA_ANSWER", label)}}
response.update(json.loads(os.environ.get("PA_EXTRA") or "{}"))
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": os.environ["PA_SID"],
                  "tool_name": os.environ.get("PA_TOOL", "AskUserQuestion"),
                  "tool_input": {"questions": questions}, "tool_response": response}))
PY
}

# payload_q SID LABEL PREVIEW_TEXT QUESTION -> PreToolUse AskUserQuestion JSON:
# one question QUESTION with the option LABEL (preview PREVIEW_TEXT when set)
payload_q() {
    PQ_SID="$1" PQ_LABEL="$2" PQ_PREVIEW="$3" PQ_QUESTION="$4" python3 - <<'PY'
import json, os
option = {"label": os.environ["PQ_LABEL"], "description": "posts the draft"}
if os.environ["PQ_PREVIEW"]:
    option["preview"] = os.environ["PQ_PREVIEW"]
questions = [{"question": os.environ["PQ_QUESTION"], "header": "Post", "multiSelect": False,
              "options": [option, {"label": "Hold", "description": "wait"}]}]
print(json.dumps({"hook_event_name": "PreToolUse", "session_id": os.environ["PQ_SID"],
                  "tool_name": "AskUserQuestion", "tool_input": {"questions": questions}}))
PY
}

# expect_err LABEL NEEDLE PAYLOAD -> the hook exits 2 and stderr contains NEEDLE
expect_err() {
    printf '%s' "$3" | python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
    rc=$?
    case "$(cat "$FIX/err")" in
        *"$2"*) found=1 ;;
        *) found=0 ;;
    esac
    if [ "$rc" = 2 ] && [ "$found" = 1 ]; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s err=%s)\n' "$1" "$rc" "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
    fi
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
expect_out "A17c a draft only in the option preview is refused" "its text was not in the question" "$(PA_QUESTION='Post this draft?' PA_OPT_PREVIEW='reply one' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A17c a preview-only draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17c2
pending aaaaaaaa 1 'reply one'
expect_out "A17c a returned preview holding the text is refused" "its text was not in the question" "$(PA_QUESTION='Post this draft?' PA_EXTRA='{"annotations": {"Post this draft?": {"preview": "reply one"}}}' payload_a s1 'Post draft aaaaaaaa' 'reply one')"
expect_file "A17c a returned-preview draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17d
ONELINE=$(python3 -c 'print("word " * 248)')
pending aaaaaaaa 1 "$ONELINE"
expect_out "A17d a 1240-character paragraph only in the preview is refused" "its text was not in the question" "$(PA_QUESTION='Post this draft?' PA_OPT_PREVIEW="$ONELINE" payload_a s1 'Post draft aaaaaaaa' "$ONELINE")"
expect_file "A17d a preview-only paragraph is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17e
FIVE=$(python3 -c 'print("\n".join("line %d %s" % (i, "x" * 160) for i in range(5)))')
pending aaaaaaaa 1 "$FIVE"
expect_out "A17e a 5-line draft only in the preview is refused" "its text was not in the question" "$(PA_QUESTION='Post this draft?' PA_OPT_PREVIEW="$FIVE" payload_a s1 'Post draft aaaaaaaa' "$FIVE")"
expect_file "A17e a preview-only 5-line draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate a17g
pending aaaaaaaa 1 "$FIVE"
expect_rc "A17g a draft in the question needs no option preview" 0 "$(payload_a s1 'Post draft aaaaaaaa' "$FIVE")"
expect_file "A17g a question-shown draft is approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate a17h
BIGQ=$(python3 -c 'print("reply one " + "pad " * 600)')
pending aaaaaaaa 1 'reply one'
expect_out "A17h a question over 2000 characters is refused" "question is over 2000 characters" "$(payload_a s1 'Post draft aaaaaaaa' "$BIGQ")"
expect_file "A17h an over-limit question is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

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
if grep -q 'AskUserQuestion' "$FIX/err" && grep -qF '(draft <hash>)' "$FIX/err" && grep -qF '(skip draft <hash>)' "$FIX/err" \
    && grep -q 'update --ai' "$FIX/err" && ! grep -qi 'post it' "$FIX/err"; then
    printf 'PASS  A23 the reply denial names the prompt and the upgrade fix\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  A23 reply denial text (%s)\n' "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
fi

case_gate a23b
payload_b s1 "$REVIEW" | python3 "$HOOK" >/dev/null 2>"$FIX/err"
if grep -qF 'plus a space' "$FIX/err"; then
    printf 'PASS  A23b the reply denial states the space rule\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  A23b space rule missing (%s)\n' "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
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

# --- PQ: a Post draft prompt that cannot approve is refused before it is shown ---

case_gate pq1
expect_err "PQ1 an unregistered hash is refused with the register command" "pr_post_guard.py draft -- gh" "$(payload_q s1 'Post draft cccccccc' '' 'Post this draft? reply one')"
expect_file "PQ1 the refusal creates no gate dir" "$GATE" absent

case_gate pq2
pending aaaaaaaa 1 'reply one'
expect_err "PQ2 text only in the option preview is refused" "put the full draft text in the question body, not the option preview" "$(payload_q s1 'Post draft aaaaaaaa' 'reply one' 'Post this draft?')"
expect_file "PQ2 still pending" "$GATE/s1.draft-aaaaaaaa.pending" present
expect_file "PQ2 not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

case_gate pq3
pending aaaaaaaa 1 'reply one'
expect_rc "PQ3 a registered draft shown in the question passes" 0 "$(payload_q s1 'Post draft aaaaaaaa' '' 'Post this draft? reply one')"
expect_file "PQ3 still pending" "$GATE/s1.draft-aaaaaaaa.pending" present
expect_file "PQ3 not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent

# --- L: option labels that read as the action, with the hash in parentheses ---

NF_POST='Post the closing comment on PR #1 (draft aaaaaaaa)'
NF_SKIP='Leave PR #1 open (skip draft aaaaaaaa)'

case_gate l1
pending aaaaaaaa 1 'reply one'
expect_out "L1 a new-form post label approves" "post gate: approved draft aaaaaaaa" "$(payload_a s1 "$NF_POST" 'reply one')"
expect_file "L1 the draft is approved" "$GATE/s1.draft-aaaaaaaa.approved" present

case_gate l2
pending aaaaaaaa 1 'reply one'
expect_out "L2 a new-form skip label skips" "post gate: draft aaaaaaaa skipped" "$(payload_a s1 "$NF_SKIP" '')"
expect_file "L2 the draft is dismissed" "$GATE/s1.draft-aaaaaaaa.dismissed" present

case_gate l3
pending aaaaaaaa 1 'reply one'
expect_out "L3 a new-form post label with (Recommended) approves" "post gate: approved draft aaaaaaaa" "$(payload_a s1 "$NF_POST (Recommended)" 'reply one')"

case_gate l4
pending aaaaaaaa 1 'reply one'
expect_out "L4 a skip word inside a post label still approves" "post gate: approved draft aaaaaaaa" "$(payload_a s1 'Post the reply and skip the nit (draft aaaaaaaa)' 'reply one')"

case_gate l5
pending aaaaaaaa 1 'reply one'
expect_out "L5 (post draft hash) after another leading word is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Close PR 5 with the reply (post draft aaaaaaaa)' 'reply one')"

case_gate l6
pending aaaaaaaa 1 'reply one'
expect_out "L6 a leading Skip with (draft hash) skips" "post gate: draft aaaaaaaa skipped" "$(payload_a s1 'Skip the reply for now (draft aaaaaaaa)' '')"

case_gate l7
pending aaaaaaaa 1 'reply one'
expect_out "L7 a label with no verb signal is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Leave PR 5 open (draft aaaaaaaa)' 'reply one')"
expect_file "L7 the draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present

case_gate l8
pending aaaaaaaa 1 'reply one'
expect_out "L8 a label with both verb signals is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Post the reply (skip draft aaaaaaaa)' 'reply one')"
expect_file "L8 the draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present

case_gate l9
pending aaaaaaaa 1 'reply one'
pending bbbbbbbb 2 'reply two'
L9=$(payload_a s1 'Post the reply (draft aaaaaaaa) (draft bbbbbbbb)' 'reply one')
expect_out "L9 a label naming two hashes reports the first draft undecided" "post gate: draft aaaaaaaa not decided (the question names more than one draft)" "$L9"
expect_out "L9 and the second" "post gate: draft bbbbbbbb not decided (the question names more than one draft)" "$L9"

case_gate l10
pending aaaaaaaa 1 'reply one'
expect_out "L10 Draft in another case approves" "post gate: approved draft aaaaaaaa" "$(payload_a s1 'post the reply on PR 5 (Draft aaaaaaaa)' 'reply one')"

case_gate l11
expect_out "L11 a new-form post for an unregistered hash reports no pending draft" "post gate: draft aaaaaaaa not approved: no pending draft in this session" "$(payload_a s1 "$NF_POST" 'reply one')"

case_gate l12
pending aaaaaaaa 1 'reply one'
expect_out "L12 the legacy Skip label with (Recommended) skips" "post gate: draft aaaaaaaa skipped" "$(payload_a s1 'Skip draft aaaaaaaa (Recommended)' '')"

case_gate l13
pending aaaaaaaa 1 'reply one'
L13=$(python3 - <<'PY'
import json
q = "Post this draft?\nreply one"
qs = [{"question": q, "multiSelect": False,
       "options": [{"label": "Post the reply on PR 5 (draft aaaaaaaa)", "description": "posts it"},
                   {"label": "Leave PR 5 open (draft aaaaaaaa)", "description": "skips it"}]}]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs},
                  "tool_response": {"questions": qs, "answers": {q: "Post the reply on PR 5 (draft aaaaaaaa)"}}}))
PY
)
expect_out "L13 a clear chosen option beside an ambiguous one approves" "post gate: approved draft aaaaaaaa" "$L13"

case_gate l14
pending aaaaaaaa 1 'reply one'
L14=$(payload_a s1 'Post the reply (draft aaaaaaaa0)' 'reply one' | python3 "$HOOK")
case "$L14" in
    *aaaaaaaa*) printf 'FAIL  L14 draft hash0 is not a draft label (stdout %s)\n' "$L14" >&2; FAIL=$((FAIL + 1)) ;;
    *) [ -e "$GATE/s1.draft-aaaaaaaa.pending" ] && { printf 'PASS  L14 draft hash0 is not a draft label\n'; PASS=$((PASS + 1)); } \
        || { printf 'FAIL  L14 the draft left pending\n' >&2; FAIL=$((FAIL + 1)); } ;;
esac

AMB="post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)"
n=0
for label in 'Post none of it (draft aaaaaaaa)' 'Post neither reply (draft aaaaaaaa)' 'Post zero replies (draft aaaaaaaa)' 'Post to nobody (draft aaaaaaaa)' 'Post nor skip (draft aaaaaaaa)'; do
    n=$((n + 1))
    case_gate "l16-$n"
    pending aaaaaaaa 1 'reply one'
    expect_out "L16.$n [$label] is ambiguous" "$AMB" "$(payload_a s1 "$label" 'reply one')"
    expect_file "L16.$n the draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present
done

case_gate l17
pending aaaaaaaa 1 'reply one'
expect_out "L17 an uppercase second hash is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Post draft aaaaaaaa or 142E31F6' 'reply one')"

case_gate pq4
expect_err "PQ4 a new-form post for an unregistered hash is refused with the register command" "pr_post_guard.py draft -- gh" "$(payload_q s1 "$NF_POST" '' 'Post this draft? reply one')"

case_gate pq5
pending aaaaaaaa 1 'reply one'
expect_rc "PQ5 a new-form post for a registered, shown draft passes" 0 "$(payload_q s1 "$NF_POST" '' 'Post this draft? reply one')"

case_gate pq6
pending aaaaaaaa 1 'reply one'
expect_err "PQ6 a no-verb label is refused as ambiguous with the fix" "(skip draft <hash>)" "$(payload_q s1 'Leave PR 5 open (draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ6 and says is ambiguous" "is ambiguous" "$(payload_q s1 'Leave PR 5 open (draft aaaaaaaa)' '' 'Post this draft? reply one')"

case_gate pq7
expect_rc "PQ7 a new-form skip for an unregistered hash passes" 0 "$(payload_q s1 "$NF_SKIP" '' 'Skip this draft?')"

case_gate pq8
pending aaaaaaaa 1 'reply one'
expect_err "PQ8 a two-hash label is refused as ambiguous" "is ambiguous" "$(payload_q s1 'Post the reply (draft aaaaaaaa) (draft bbbbbbbb)' '' 'Post this draft? reply one')"

case_gate pq9
mkdir -p "$GATE"
: >"$GATE/s1.draft-aaaaaaaa.spent"
expect_err "PQ9 a new-form post for a spent draft is refused" "already posted once" "$(payload_q s1 "$NF_POST" '' 'Post this draft? reply one')"

case_gate pq10
pending aaaaaaaa 1 'reply one'
expect_err "PQ10 a both-verb label is refused as ambiguous with the fix" "(skip draft <hash>)" "$(payload_q s1 'Post the reply (skip draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ10 and says is ambiguous" "is ambiguous" "$(payload_q s1 'Post the reply (skip draft aaaaaaaa)' '' 'Post this draft? reply one')"

case_gate l15
pending aaaaaaaa 1 'reply one'
expect_out "L15 a negated post label is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Do not post draft aaaaaaaa' 'reply one')"
expect_out "L15 a Post-nothing label is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Post nothing (draft aaaaaaaa)' 'reply one')"
expect_out "L15 a Post-led no-mentions label is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Post the reply, no mentions (draft aaaaaaaa)' 'reply one')"
expect_out "L15 a curly-apostrophe Don't label is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 "$(printf 'Don\342\200\231t post draft aaaaaaaa')" 'reply one')"
expect_out "L15 a curly-apostrophe Can't label is ambiguous" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 "$(printf 'Can\342\200\231t post draft aaaaaaaa')" 'reply one')"
expect_out "L15 a hyphenated Post-mortem lead is not a post" "post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)" "$(payload_a s1 'Post-mortem note (draft aaaaaaaa)' 'reply one')"
expect_file "L15 the draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present

AMB="post gate: draft aaaaaaaa not decided (the chosen option label is ambiguous)"
case_gate l16b
pending aaaaaaaa 1 'reply one'
for lab in 'Hold off on post draft aaaaaaaa' 'Cancel post draft aaaaaaaa' 'Decline to post draft aaaaaaaa' 'Maybe post draft aaaaaaaa' 'Stop post draft aaaaaaaa' 'Save post draft aaaaaaaa' 'Cancel "Post draft aaaaaaaa"'; do
  expect_out "L16b refusal-led label is ambiguous: $lab" "$AMB" "$(payload_a s1 "$lab" 'reply one')"
done
expect_file "L16b the draft stays pending" "$GATE/s1.draft-aaaaaaaa.pending" present
expect_file "L16b the draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
case_gate l17b
pending aaaaaaaa 1 'reply one'
expect_out "L17b a (Post lead approves" "post gate: approved draft aaaaaaaa" "$(payload_a s1 '(Post the reply) (draft aaaaaaaa)' 'reply one')"
case_gate l19
pending aaaaaaaa 1 'reply one'
for lab in 'Post the reply only if I confirm again (draft aaaaaaaa)' 'Post after CI passes (draft aaaaaaaa)' 'Post the reply? Hold off for now (draft aaaaaaaa)' 'Post -- wait (draft aaaaaaaa)' 'Post the reply (draft aaaaaaaa) - or skip it'; do
  expect_out "L19 hedged post label is ambiguous: $lab" "$AMB" "$(payload_a s1 "$lab" 'reply one')"
  expect_err "PQ19 hedged post label is refused: $lab" "is ambiguous" "$(payload_q s1 "$lab" '' 'Post this draft? reply one')"
done
expect_file "L19 the draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
case_gate l18
pending aaaaaaaa 1 'reply one'
expect_out "L18 two hashes joined by or are ambiguous" "$AMB" "$(payload_a s1 'Post draft aaaaaaaa or bbbbbbbb' 'reply one')"
expect_out "L18 two hashes joined by a dash are ambiguous" "$AMB" "$(payload_a s1 'Post draft aaaaaaaa-bbbbbbbb' 'reply one')"
expect_file "L18 the draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
case_gate l20
pending aaaaaaaa 1 'reply one'
EM=$(printf '\342\200\224'); EN=$(printf '\342\200\223'); HB=$(printf '\342\200\225'); FD=$(printf '\342\200\222'); MN=$(printf '\342\210\222')
for lab in "Post the reply${EM}pending approval (draft aaaaaaaa)" "Post the reply${EN}pending approval (draft aaaaaaaa)" "Post the reply (draft aaaaaaaa)${EM}pending approval" "Post the reply ${EM}pending approval (draft aaaaaaaa)" "Post the reply${HB}pending approval (draft aaaaaaaa)" "Post the reply${FD}pending approval (draft aaaaaaaa)" "Post the reply ${MN} pending (draft aaaaaaaa)"; do
  expect_out "L20 unspaced dash aside is ambiguous: $lab" "$AMB" "$(payload_a s1 "$lab" 'reply one')"
  expect_err "PQ20 unspaced dash aside is refused: $lab" "is ambiguous" "$(payload_q s1 "$lab" '' 'Post this draft? reply one')"
done
expect_file "L20 the draft is not approved" "$GATE/s1.draft-aaaaaaaa.approved" absent
for lab in 'Post the follow-up (draft aaaaaaaa)' 'Post the hold-harmless clause (draft aaaaaaaa)' 'Post the if-statement bug note (draft aaaaaaaa)'; do
  expect_out "L20 hyphenated compound approves: $lab" "post gate: approved draft aaaaaaaa" "$(payload_a s1 "$lab" 'reply one')"
  pending aaaaaaaa 1 'reply one'
done
for w in not never no none nothing nobody neither nor zero without cannot "don't"; do
  expect_out "L20 negation word $w is ambiguous" "$AMB" "$(payload_a s1 "Post the reply $w now (draft aaaaaaaa)" 'reply one')"
done
expect_err "PQ20 a hedge refusal names the plain-statement rule" "a post label must be a plain statement: avoid if/unless/after/until/later/wait/hold/or/maybe/but/only/again/for now, a question mark, and a dash-separated aside" "$(payload_q s1 'Post after CI passes (draft aaaaaaaa)' '' 'Post this draft? reply one')"

case_gate l21
pending aaaaaaaa 1 'reply one'
expect_out "L21 Post colon is ambiguous" "$AMB" "$(payload_a s1 'Post: the closing comment (draft aaaaaaaa)' 'reply one')"
expect_out "L21 Post comma is ambiguous" "$AMB" "$(payload_a s1 'Post, then close (draft aaaaaaaa)' 'reply one')"
expect_out "L21 Post dash is ambiguous" "$AMB" "$(payload_a s1 'Post-the comment (draft aaaaaaaa)' 'reply one')"
expect_out "L21 Post em dash is ambiguous" "$AMB" "$(payload_a s1 "$(printf 'Post\342\200\224the comment (draft aaaaaaaa)')" 'reply one')"

case_gate pq11
pending aaaaaaaa 1 'reply one'
expect_err "PQ11 a negated post label is refused as ambiguous" "is ambiguous" "$(payload_q s1 'Do not post draft aaaaaaaa' '' 'Post this draft? reply one')"
expect_err "PQ11 a curly-apostrophe negated label is refused as ambiguous" "is ambiguous" "$(payload_q s1 "$(printf 'Don\342\200\231t post draft aaaaaaaa')" '' 'Post this draft? reply one')"

expect_err "PQ11 a Post-nothing label names the negation rule" "avoid not/no/none/never/nothing/nobody/neither/nor/zero/without/cannot/n't" "$(payload_q s1 'Post nothing (draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ11 a Post-led no-mentions label names the negation rule" "avoid not/no/none/never/nothing/nobody/neither/nor/zero/without/cannot/n't" "$(payload_q s1 'Post the reply, no mentions (draft aaaaaaaa)' '' 'Post this draft? reply one')"

case_gate pq12
pending aaaaaaaa 1 'reply one'
for lab in 'Hold off on post draft aaaaaaaa' 'Cancel post draft aaaaaaaa' 'Decline to post draft aaaaaaaa' 'Maybe post draft aaaaaaaa' 'Post draft aaaaaaaa or bbbbbbbb' 'Post draft aaaaaaaa-bbbbbbbb'; do
  expect_err "PQ12 refused at PreToolUse: $lab" "is ambiguous" "$(payload_q s1 "$lab" '' 'Post this draft? reply one')"
done
expect_err "PQ12 Post colon names the space rule" "must be followed by a space" "$(payload_q s1 'Post: the closing comment (draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ12 Post comma names the space rule" "must be followed by a space" "$(payload_q s1 'Post, then close (draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ12 Post dash names the space rule" "must be followed by a space" "$(payload_q s1 'Post-the comment (draft aaaaaaaa)' '' 'Post this draft? reply one')"
expect_err "PQ12 a leading-verb refusal names the leading-word rule" "any other leading word is a refusal" "$(payload_q s1 'Hold off on post draft aaaaaaaa' '' 'Post this draft? reply one')"

expect_err "PQ12 Post em dash names the space rule" "must be followed by a space" "$(payload_q s1 "$(printf 'Post\342\200\224the comment (draft aaaaaaaa)')" '' 'Post this draft? reply one')"

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
expect_py "DS4 an old draft approved now survives the next prune" "True" "import time; from pathlib import Path; d = Path('$GATE'); g.approve_draft(d, 's1', 'ffffffff', 'Post this draft?'); g.prune(d, time.time()); print((d / 's1.draft-ffffffff.approved').exists())"

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

# --- RE: review events bound to the option verb ------------------------------

HOOK_ABS="$(pwd)/$HOOK"
H40=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'review text' >"$FIX/body.md"

# payload_alt SID ANSWER LABEL1 LABEL2 TEXT -> PostToolUse AskUserQuestion JSON:
# one single-select question with TEXT, the two labels and a Hold option
payload_alt() {
    PL_SID="$1" PL_ANSWER="$2" PL_L1="$3" PL_L2="$4" PL_TEXT="$5" python3 - <<'PY'
import json, os
q = "Post which?\n" + os.environ["PL_TEXT"]
opts = [{"label": os.environ["PL_L1"], "description": "one"},
        {"label": os.environ["PL_L2"], "description": "two"},
        {"label": "Hold the review on #5", "description": "wait"}]
qs = [{"question": q, "multiSelect": False, "options": opts}]
print(json.dumps({"hook_event_name": "PostToolUse", "session_id": os.environ["PL_SID"], "tool_name": "AskUserQuestion",
                  "tool_input": {"questions": qs}, "tool_response": {"questions": qs, "answers": {q: os.environ["PL_ANSWER"]}}}))
PY
}

# reg ARG...: register `gh ARG...` as a draft for s1 from $FIX; prints its hash, rc 1 when refused
reg() {
    out=$(cd "$FIX" && python3 "$HOOK_ABS" draft -- gh "$@" 2>"$FIX/reg.err"); rc=$?
    printf '%s\n' "$out" | sed -n '1s/^draft \([0-9a-f]\{8\}\).*/\1/p'
    return "$rc"
}

# refused LABEL NEEDLE ARG...: registration exits 1 naming NEEDLE and writes no draft
refused() {
    label="$1"; needle="$2"; shift 2
    reg "$@" >/dev/null; rc=$?
    if [ "$rc" = 1 ] && grep -q -- "$needle" "$FIX/reg.err" && [ -z "$(ls "$GATE" 2>/dev/null)" ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s err=%s)\n' "$label" "$rc" "$(cat "$FIX/reg.err")" >&2; FAIL=$((FAIL + 1))
    fi
}

REVIEW_APPROVE="api -X POST repos/o/r/pulls/5/reviews -f commit_id=$H40 -f event=APPROVE -F body=@body.md"
REVIEW_CHANGES="api -X POST repos/o/r/pulls/5/reviews -f commit_id=$H40 -f event=REQUEST_CHANGES -F body=@body.md"
COMMENT_CALL="pr comment 5 -R o/r --body-file body.md"
LBL_APPROVE='Approve #5 at aaaaaaa with this text (draft %s)'
LBL_CHANGES='Request changes on #5 at aaaaaaa with this text (draft %s)'
LBL_COMMENT='Post as a comment on #5 (draft %s)'

case_gate re1
HR=$(reg $REVIEW_APPROVE)
expect_err "RE1 an approve review draft with a Post label is refused before the prompt" 'must start with `Approve`' "$(payload_q s1 "$(printf "$LBL_COMMENT" "$HR")" '' 'Post this? review text')"

case_gate re2
HR=$(reg $REVIEW_APPROVE)
expect_out "RE2 an Approve label approves an approve review draft" "post gate: approved draft $HR" "$(payload_a s1 "$(printf "$LBL_APPROVE" "$HR")" 'review text')"
expect_file "RE2 the draft is approved" "$GATE/s1.draft-$HR.approved" present

case_gate re3
HC=$(reg $COMMENT_CALL)
expect_out "RE3 an Approve label on a comment draft is refused" 'its option must start with `Post`, not `Approve`' "$(payload_a s1 "$(printf "$LBL_APPROVE" "$HC")" 'review text')"
expect_file "RE3 the comment draft stays pending" "$GATE/s1.draft-$HC.pending" present

case_gate re4
HRC=$(reg $REVIEW_CHANGES)
HR=$(reg $REVIEW_APPROVE)
expect_out "RE4 a Request changes label on an approve review is refused" 'must start with `Approve`, not `Request changes`' "$(payload_a s1 "$(printf "$LBL_CHANGES" "$HR")" 'review text')"
expect_out "RE4 a Request changes label approves a request-changes draft" "post gate: approved draft $HRC" "$(payload_a s1 "$(printf "$LBL_CHANGES" "$HRC")" 'review text')"
expect_file "RE4 only the request-changes draft is approved" "$GATE/s1.draft-$HR.approved" absent

case_gate re5
HC=$(reg $COMMENT_CALL)
HR=$(reg $REVIEW_APPROVE)
L_REVIEW=$(printf "$LBL_APPROVE" "$HR"); L_COMMENT=$(printf "$LBL_COMMENT" "$HC")
expect_out "RE5 choosing the review approves it and dismisses the comment" "post gate: draft $HC dismissed (another option was chosen)" "$(payload_alt s1 "$L_REVIEW" "$L_REVIEW" "$L_COMMENT" 'review text')"
expect_file "RE5 the review draft is approved" "$GATE/s1.draft-$HR.approved" present
expect_file "RE5 the comment draft is not approved" "$GATE/s1.draft-$HC.approved" absent
expect_file "RE5 the comment draft is dismissed" "$GATE/s1.draft-$HC.dismissed" present

case_gate re6
HC=$(reg $COMMENT_CALL)
HR=$(reg $REVIEW_APPROVE)
L_REVIEW=$(printf "$LBL_APPROVE" "$HR"); L_COMMENT=$(printf "$LBL_COMMENT" "$HC")
expect_out "RE6 Hold decides nothing" "not decided (no Post or Skip option was chosen)" "$(payload_alt s1 'Hold the review on #5' "$L_REVIEW" "$L_COMMENT" 'review text')"
expect_file "RE6 the review draft stays pending" "$GATE/s1.draft-$HR.pending" present
expect_file "RE6 the comment draft stays pending" "$GATE/s1.draft-$HC.pending" present

case_gate re7
refused "RE7 draft registration refuses gh pr review --approve" "must be" pr review 5 --approve -b x

case_gate re8
refused "RE8 draft registration refuses a reviews API event with a short commit_id" "must be" api -X POST repos/o/r/pulls/5/reviews -f commit_id=abc1234 -f event=APPROVE -f body=x
case_gate re8b
refused "RE8 and one with no commit_id" "must be" api -X POST repos/o/r/pulls/5/reviews -f event=REQUEST_CHANGES -f body=x

case_gate re9
refused "RE9 draft registration refuses a graphql mutation naming APPROVE" "must be" api graphql -f 'query=mutation { addPullRequestReview(input: {event: APPROVE}) { clientMutationId } }'

case_gate re13
refused "RE13 draft registration refuses a reviews events call carrying APPROVE" "must be" api -X POST repos/o/r/pulls/5/reviews/9/events -f event=APPROVE -f body=x

case_gate re10
HR=$(reg $REVIEW_APPROVE)
expect_err "RE10 a hedge word in an Approve label is ambiguous" "is ambiguous" "$(payload_q s1 "Approve #5 or hold (draft $HR)" '' 'Post this? review text')"

case_gate re11
HC=$(reg $COMMENT_CALL)
HR=$(reg $REVIEW_APPROVE)
L_REVIEW=$(printf "$LBL_APPROVE" "$HR"); L_COMMENT=$(printf "$LBL_COMMENT" "$HC")
payload_alt s1 "$L_REVIEW" "$L_REVIEW" "$L_COMMENT" 'review text' | python3 "$HOOK" >/dev/null 2>&1
expect_out "RE11 a later question naming the dismissed sibling cannot approve it" "post gate: draft $HC not decided (the question names more than one draft)" "$(payload_alt s1 "$L_COMMENT" "$L_REVIEW" "$L_COMMENT" 'review text')"
expect_file "RE11 the sibling stays unapproved" "$GATE/s1.draft-$HC.approved" absent

case_gate re14
refused "RE14 draft registration refuses a reviews call with an event in the query string" "must be" api -X POST "repos/o/r/pulls/5/reviews?event=APPROVE&commit_id=$H40" -F body=@body.md
case_gate re14b
refused "RE14 and a reviews events call with an event in the query string" "must be" api -X POST "repos/o/r/pulls/5/reviews/9/events?event=APPROVE" -F body=@body.md
case_gate re14c
refused "RE14 and a reviews call with a fragment" "must be" api -X POST "repos/o/r/pulls/5/reviews#x" -f commit_id=$H40 -f event=APPROVE -F body=@body.md

printf '{"event":"COMMENT","body":"x"}' >"$FIX/comment.json"
printf '{"event":"APPROVE","body":"x"}' >"$FIX/approve.json"
case_gate re16a
refused "RE16 draft registration refuses two --input files" "must be" api -X POST repos/o/r/pulls/5/reviews --input "$FIX/comment.json" --input "$FIX/approve.json"
case_gate re16b
refused "RE16 and an --input file with a disagreeing -f event" "must be" api -X POST repos/o/r/pulls/5/reviews --input "$FIX/comment.json" -f event=APPROVE
case_gate re16c
refused "RE16 and a repeated -X" "must be" api -X GET -X POST repos/o/r/pulls/5/reviews -f commit_id=$H40 -f event=APPROVE -F body=@body.md
case_gate re16d
refused "RE16 and a repeated -f event" "must be" api -X POST repos/o/r/pulls/5/reviews -f commit_id=$H40 -f event=COMMENT -f event=APPROVE -F body=@body.md
case_gate re17a
refused "RE17 draft registration refuses a +5 PR segment" "must be" api -X POST repos/o/r/pulls/+5/reviews -f commit_id=$H40 -f event=COMMENT -F body=@body.md
case_gate re17b
refused "RE17 and a %35 PR segment" "must be" api -X POST repos/o/r/pulls/%35/reviews -f commit_id=$H40 -f event=COMMENT -F body=@body.md
case_gate re17c
refused "RE17 and a zero-padded PR segment" "must be" api -X POST repos/o/r/pulls/05/reviews -f commit_id=$H40 -f event=COMMENT -F body=@body.md

case_gate re15
HR=$(reg $REVIEW_APPROVE)
expect_out "RE15 an Approve label naming another PR is refused" "must name the PR as \`#5\`" "$(payload_a s1 "Approve #6 at aaaaaaa with this text (draft $HR)" 'review text')"
expect_file "RE15 the draft stays pending" "$GATE/s1.draft-$HR.pending" present
expect_out "RE15 an Approve label naming another head is refused" "must name the pinned head \`aaaaaaa\`" "$(payload_a s1 "Approve #5 at bbbbbbb with this text (draft $HR)" 'review text')"
expect_file "RE15 the draft still stays pending" "$GATE/s1.draft-$HR.pending" present
HRC=$(reg $REVIEW_CHANGES)
expect_out "RE15 a Request changes label naming another PR is refused" "must name the PR as \`#5\`" "$(payload_a s1 "Request changes on #15 at aaaaaaa with this text (draft $HRC)" 'review text')"

expect_py "RE12 review_event classifies each argv branch" ok '
cases = [
    (["pr", "review", "5", "--approve", "-b", "x"], "approve"),
    (["pr", "review", "5", "--approve=true"], "approve"),
    (["pr", "review", "5", "-ab", "x"], "approve"),
    (["pr", "review", "5", "-rb", "x"], "request-changes"),
    (["pr", "review", "5", "--request-changes"], "request-changes"),
    (["pr", "review", "5", "-a", "-r"], "unknown"),
    (["pr", "review", "5", "-c", "-b", "--approve"], None),
    (["pr", "review", "5", "-b", "-a"], "unknown"),
    (["pr", "review", "5"], "unknown"),
    (["pr", "review", "5", "-b", "x"], "unknown"),
    (["pr", "review", "5", "--comment", "-b", "x"], None),
    (["pr", "review", "5", "-cb", "x"], None),
    (["pr", "review", "5", "--comment=true"], None),
    (["pr", "review", "5", "--comment=T"], None),
    (["pr", "review", "5", "--comment=false"], "unknown"),
    (["pr", "review", "5", "--comment=0"], "unknown"),
    (["pr", "review", "5", "--comment=F"], "unknown"),
    (["pr", "review", "5", "-c=false"], "unknown"),
    (["pr", "review", "5", "-c=true"], None),
    (["pr", "review", "5", "--comment", "--comment=false"], "unknown"),
    (["pr", "review", "5", "--comment=false", "--comment"], None),
    (["pr", "review", "5", "-c", "-c=false"], "unknown"),
    (["pr", "review", "5", "-c=false", "-c"], None),
    (["api", "-X", "POST", "repos/o/r/pulls/5/{branch}", "-f", "event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/:owner/:repo/pulls/5/reviews", "-f", "event=APPROVE"], "approve"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/x:branch", "-f", "event=APPROVE"], "unknown"),
    (["pr", "review", "5", "-R", "-a", "-c"], None),
    (["pr", "comment", "5", "-b", "x"], None),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews", "-f", "event=APPROVE"], "approve"),
    (["api", "repos/o/r/pulls/5/reviews", "-f", "event=REQUEST_CHANGES"], "request-changes"),
    (["api", "repos/o/r/pulls/5/reviews", "-f", "event=COMMENT"], None),
    (["api", "repos/o/r/pulls/5/reviews", "-f", "body=x"], None),
    (["api", "repos/o/r/pulls/5/reviews", "-f", "event=DISMISS"], "unknown"),
    (["api", "repos/o/r/pulls/5/reviews", "-F", "event=@e.txt"], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews/9/events", "-f", "event=APPROVE"], "approve"),
    (["api", "repos/o/r/pulls/5/reviews", "-f", "event=APPROVE", "-f", "event=COMMENT"], "unknown"),
    (["api", "graphql", "-f", "query=mutation { x(event: APPROVE) }"], "unknown"),
    (["api", "graphql", "-f", "query=mutation { x(event: REQUEST_CHANGES) }"], "unknown"),
    (["api", "graphql", "-f", "query=mutation { x }"], None),
    ([], None),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews?event=APPROVE&commit_id=" + "a" * 40], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews/9/events?event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews#frag", "-f", "event=COMMENT"], "unknown"),
]
import json, os, tempfile
d = tempfile.mkdtemp()
for name, body, want in (("a.json", {"event": "APPROVE"}, "approve"), ("c.json", {"body": "x"}, None)):
    with open(os.path.join(d, name), "w") as f:
        json.dump(body, f)
    cases.append((["api", "-X", "POST", "repos/o/r/pulls/5/reviews", "--input", name], want))
cases.append((["api", "-X", "POST", "repos/o/r/pulls/5/reviews", "--input", "missing.json"], "unknown"))
with open(os.path.join(d, "g.json"), "w") as f:
    f.write(json.dumps({"variables": {"e": "APPROVE"}}).replace("A", "\\u0041"))
cases.append((["api", "graphql", "--input", "g.json"], "unknown"))
bad = [(a, g.review_event(a, d), w) for a, w in cases if g.review_event(a, d) != w]
print("ok" if not bad else bad)
'

expect_py "RE18 review_event reads one normalized endpoint and refuses repeated flags first" ok '
import json, os, tempfile
d = tempfile.mkdtemp()
for name, body in (("gc.json", {"query": "mutation { addPullRequestReview(input: {event: COMMENT}) { clientMutationId } }"}),
                   ("ga.json", {"query": "mutation { addPullRequestReview(input: {event: APPROVE}) { clientMutationId } }"})):
    with open(os.path.join(d, name), "w") as f:
        json.dump(body, f)
mut = "query=mutation{addPullRequestReview(input:{event:APPROVE}){clientMutationId}}"
rev = ["-f", "commit_id=" + "a" * 40, "-f", "event=COMMENT"]
cases = [
    (["api", "graphql", "--input", "gc.json", "--input", "ga.json"], "unknown"),
    (["api", "graphql", "--input", "gc.json"], None),
    (["api", "https://api.github.com/graphql", "-f", mut], "unknown"),
    (["api", "HTTPS://API.GitHub.com/graphql", "-f", mut], "unknown"),
    (["api", "--hostname", "ghe.example.com", "https://ghe.example.com/graphql", "-f", mut], "unknown"),
    (["api", "graphql/", "-f", mut], "unknown"),
    (["api", "https://ghe.example.com/api/graphql", "-f", mut], "unknown"),
    (["api", "/graphql", "-f", mut], "unknown"),
    (["api", "graphql?x=1", "-f", mut], "unknown"),
    (["api", "./graphql", "-f", mut], "unknown"),
    (["api", "%67raphql", "-f", mut], "unknown"),
    (["api", "GraphQL", "-f", mut], "unknown"),
    (["api", "gRaPhQl", "-f", mut], "unknown"),
    (["api", "https://api.github.com/GraphQL", "-f", mut], "unknown"),
    (["api", "api/v3/graphql", "-f", mut], "unknown"),
    (["api", "https://api.github.com/graphql", "-f", "query=query { viewer { login } }", "-X", "GET"], None),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews/", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews/?x=1", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls//5/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5//reviews", *rev], "unknown"),
    (["api", "-X", "POST", "https://api.github.com/repos/o/r/pulls/5/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5%2Freviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/./5/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/reviews", *rev], None),
    (["api", "repos/o/r/pulls/5/reviews/"], None),
    (["api", "-X", "POST", "repos/o/r/issues/5/comments", "--input", "gc.json", "--input", "ga.json"], "unknown"),
    (["api", "-X", "GET", "-X", "POST", "repos/o/r/issues/5/comments", "-f", "body=x"], "unknown"),
    (["api", "-X", "POST", "repos/o/r/issues/5/comments", "-f", "body=x"], None),
    (["api", "repos/{owner}/{repo}/issues/5/comments", "-f", "body=x"], None),
    (["api", "-X", "PATCH", "repos/{owner}/{repo}/issues/5", "-f", "state=closed"], None),
    (["api", "repos/:owner/:repo/issues/5/labels", "-f", "labels[]=x"], None),
    (["api", "-X", "POST", "repos/o/{branch}/pulls/5/reviews", "-f", "event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/x:branch/r/pulls/5/reviews", "-f", "event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/{owner}x/{repo}/pulls/5/reviews", "-f", "event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/:owner:branch/r/pulls/5/reviews", "-f", "event=APPROVE"], "unknown"),
    (["api", "-X", "POST", "repos/{owner}/{repo}/pulls/5/reviews", "-f", "event=APPROVE", "-f", "commit_id=" + "a" * 40], "approve"),
    (["api", "-X", "POST", "repos/o/r/issues/5%2Fcomments", "-f", "body=x"], "unknown"),
]
bad = [(a, g.review_event(a, d), w) for a, w in cases if g.review_event(a, d) != w]
print("ok" if not bad else bad)
'


expect_py "RE19 review_event lets ordinary calls through and still refuses event shapes" ok '
import json, os, tempfile
d = tempfile.mkdtemp()
with open(os.path.join(d, "m.md"), "w") as f:
    f.write("APPROVE this when ready")
rev = ["-f", "commit_id=" + "a" * 40, "-f", "event=APPROVE"]
mut = "query=mutation{addComment(input:{body:\"x\"}){clientMutationId}}"
cases = [
    (["api", "-X", "DELETE", "repos/me/repo/issues/5/labels/needs%20review"], None),
    (["api", "-X", "PUT", "repos/me/repo/contents/a%20b.txt", "-f", "message=m"], None),
    (["api", "-X", "DELETE", "repos/{owner}/{repo}/branches/{branch}/protection"], None),
    (["api", "-X", "PATCH", "repos/{owner}/{repo}/git/refs/heads/{branch}", "-f", "sha=abc"], None),
    (["api", "-X", "POST", "repos/o/r/pulls/5/review%73", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5%2Freviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/%2e%2e/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/issues/5/labels/%zz", "-f", "x=y"], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/{x}/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/{x}/5/reviews", *rev], "unknown"),
    (["api", "-X", "POST", "repos/o/r/pulls/5/{x}", *rev], "unknown"),
    (["pr", "review", "--help"], None),
    (["pr", "review", "5", "--help"], None),
    (["pr", "review", "-h"], None),
    (["pr", "review", "5", "--approve", "--help"], "approve"),
    (["api", "-X", "GET", "-X", "GET", "repos/o/r/issues/5"], None),
    (["api", "-X", "POST", "-X", "POST", "repos/o/r/issues/5/comments", "-f", "body=x"], None),
    (["api", "-XPOST", "-X", "POST", "repos/o/r/issues/5/comments", "-f", "body=x"], None),
    (["api", "-X", "POST", "-X", "PUT", "repos/o/r/issues/5/comments", "-f", "body=x"], "unknown"),
    (["pr", "review", "5", "--approve=false"], "unknown"),
    (["pr", "review", "5", "--request-changes=false"], "unknown"),
    (["pr", "review", "5", "--approve=false", "--comment"], None),
    (["pr", "review", "5", "--request-changes=false", "--comment"], None),
    (["pr", "review", "5", "--approve=false", "--request-changes"], "request-changes"),
    (["api", "graphql", "-f", mut, "-f", "body=APPROVE"], None),
    (["api", "graphql", "-f", mut, "-F", "b=@m.md"], None),
    (["api", "graphql", "-f", "query=query { search(query: \"APPROVE\") { issueCount } }"], None),
    (["api", "graphql", "-f", "query=mutation($e:PullRequestReviewEvent!){addPullRequestReview(input:{event:$e}){clientMutationId}}", "-f", "e=APPROVE"], "unknown"),
    (["api", "graphql", "-f", "query=mutation($e:PullRequestReviewEvent!){submitPullRequestReview(input:{event:$e}){clientMutationId}}", "-f", "e=REQUEST_CHANGES"], "unknown"),
    (["api", "-X", "PUT", "repos/o/r/contents/schema.graphql", "-f", "message=add mutation", "-f", "content=APPROVE"], None),
]
bad = [(a, g.review_event(a, d), w) for a, w in cases if g.review_event(a, d) != w]
if g.classify_gh(["api", "-X", "PUT", "repos/o/r/contents/schema.graphql", "-f", "message=add mutation"]) != "write":
    bad.append("schema.graphql classify")
print("ok" if not bad else bad)
'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
