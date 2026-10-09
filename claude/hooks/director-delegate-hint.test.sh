#!/bin/sh
# director-delegate-hint.test.sh -- hermetic payload tests for
# director_delegate_hint.py: a throwaway config dir, coordination root and
# repo with an owner claim; no live session, no real state root.
set -u
cd "$(dirname "$0")/../.." || exit 1
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset WORKFLOW_PERSONAL_ACCOUNT HERDR_PERSONAL CLAUDE_PERSONAL_ONLY
unset CLAUDE_WORK_TREE CLAUDE_WORK_CONFIG_DIR CODEX_HOME XDG_STATE_HOME

HOOK=claude/hooks/director_delegate_hint.py
CORE=claude/hooks/herdr_orch_core.py
PASS=0
FAIL=0
SID_A=11111111-1111-1111-1111-111111111111   # the director: owns the repo
SID_C=33333333-3333-3333-3333-333333333333   # owns nothing

FIX=$(mktemp -d /tmp/delegate-hint.XXXXXX) || exit 1
FIX=$(cd "$FIX" && pwd -P) || exit 1
[ -n "$FIX" ] && [ -d "$FIX" ] || exit 1
trap 'rm -rf "$FIX"' EXIT
H="$FIX/home"; CFG="$FIX/cfg"; R="$FIX/repo"
mkdir -p "$H/.claude/herdr-orch" "$CFG"
export HERDR_COORDINATION_ROOT="$FIX/coordination"
git -c init.defaultBranch=main init -q "$R"
printf 'tracked\n' > "$R/tracked.txt"
git -C "$R" add tracked.txt
git -C "$R" -c user.name=t -c user.email=t@x commit -q -m base
git -C "$R" remote add origin "git@example.com:org/hint.git"
SLUG=$(python3 -c 'import sys; sys.path.insert(0, "claude/hooks"); import herdr_orch_core as c; print(c.repo_slug(sys.argv[1]))' "git@example.com:org/hint.git")
env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" python3 "$CORE" claim-owner --repo-slug "$SLUG" \
    --repo-path "$R" --runtime claude --session "$SID_A" --host h --pid 1 --stale-secs 0 >/dev/null || exit 1
RD="$CFG/herdr-orch/$SLUG"
mkdir -p "$RD"
STATE="$RD/delegate-hint.json"
SKILL_FILE="$(pwd -P)/claude/skills/herdr-orchestration/SKILL.md"

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# payload SID TOOL INPUT_JSON [AGENT_TYPE] [AGENT_ID] -> PostToolUse JSON
payload() {
    P_SID="$1" P_TOOL="$2" P_INPUT="$3" P_TYPE="${4-director}" P_AID="${5-}" P_CWD="$R" python3 - <<'PY'
import json, os
e = os.environ
p = {"session_id": e["P_SID"], "cwd": e["P_CWD"], "hook_event_name": "PostToolUse",
     "tool_name": e["P_TOOL"], "tool_input": json.loads(e["P_INPUT"]), "tool_response": {}}
if e["P_TYPE"]:
    p["agent_type"] = e["P_TYPE"]
if e["P_AID"]:
    p["agent_id"] = e["P_AID"]
print(json.dumps(p))
PY
}
# run PAYLOAD [NAME=VALUE ...]: hermetic env; stdout to $FIX/out
run() {
    p="$1"; shift
    printf '%s' "$p" | env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 "$@" python3 "$HOOK" >"$FIX/out" 2>"$FIX/err"
}
bash_in() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1]}))' "$1"; }
work() { run "$(payload "$SID_A" Bash "$(bash_in 'uv run pytest')")"; }
count() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["count"])' "$STATE" 2>/dev/null || echo none; }
seed() { printf '{"v": 1, "session_id": "%s", "task_id": %s, "count": %s}\n' "$SID_A" "$1" "$2" > "$STATE"; }

# 1-4: silent for everyone but the director, and no state written
run "$(payload "$SID_A" Bash "$(bash_in 'uv run pytest')")" HERDR_ENV=
if [ ! -s "$FIX/out" ] && [ ! -e "$STATE" ]; then pass "1 no HERDR_ENV: silent, no state"; else fail "1 no HERDR_ENV: silent, no state"; fi
run "$(payload "$SID_A" Bash "$(bash_in 'uv run pytest')" worker)"
if [ ! -s "$FIX/out" ] && [ ! -e "$STATE" ]; then pass "2 non-director agent_type: silent, no state"; else fail "2 non-director agent_type: silent, no state"; fi
run "$(payload "$SID_A" Bash "$(bash_in 'uv run pytest')" director a-sub-1)"
if [ ! -s "$FIX/out" ] && [ ! -e "$STATE" ]; then pass "3 subagent call: silent, no state"; else fail "3 subagent call: silent, no state"; fi
run "$(payload "$SID_C" Bash "$(bash_in 'uv run pytest')")"
if [ ! -s "$FIX/out" ] && [ ! -e "$STATE" ]; then pass "4 non-owner session: silent, no state"; else fail "4 non-owner session: silent, no state"; fi

# 5: 19 work calls silent, the 20th prints once
printed=0; i=1
while [ "$i" -le 20 ]; do
    work
    if [ -s "$FIX/out" ]; then printed=$((printed + 1)); last=$i; fi
    i=$((i + 1))
done
if [ "$printed" = 1 ] && [ "${last-0}" = 20 ] && grep -q '20 work tool calls on this session since the last dispatch' "$FIX/out" \
        && grep -q '"hookEventName": "PostToolUse"' "$FIX/out"; then
    pass "5 the 20th work call prints once"
else fail "5 the 20th work call prints once (printed=$printed last=${last-0})"; fi

# 6: 21st-39th silent, 40th prints again
printed=0; i=21
while [ "$i" -le 40 ]; do
    work
    if [ -s "$FIX/out" ]; then printed=$((printed + 1)); last=$i; fi
    i=$((i + 1))
done
if [ "$printed" = 1 ] && [ "$last" = 40 ]; then pass "6 the 40th work call prints again"; else fail "6 the 40th work call prints again (printed=$printed last=$last)"; fi

# 7-9: each dispatch form resets the count
seed null 5; run "$(payload "$SID_A" Agent '{"description": "x", "prompt": "y"}')"
if [ "$(count)" = 0 ]; then pass "7 an Agent call resets"; else fail "7 an Agent call resets ($(count))"; fi
seed null 5; run "$(payload "$SID_A" Bash "$(bash_in 'python3 "$DISPATCH" launch --task-id td-a')")"
if [ "$(count)" = 0 ]; then pass "8 python3 \$DISPATCH launch resets"; else fail "8 python3 \$DISPATCH launch resets ($(count))"; fi
seed null 5; run "$(payload "$SID_A" Bash "$(bash_in 'python3 /x/claude/hooks/herdr_dispatch.py dispatch-gate --phase review')")"
if [ "$(count)" = 0 ]; then pass "9 absolute herdr_dispatch.py dispatch-gate resets"; else fail "9 absolute herdr_dispatch.py dispatch-gate resets ($(count))"; fi

# 10: orchestration calls neither count nor reset
seed null 5
run "$(payload "$SID_A" Bash "$(bash_in 'python3 "$CORE" checkin --repo-slug s')")"
run "$(payload "$SID_A" Bash "$(bash_in 'gh pr view 1')")"
run "$(payload "$SID_A" Bash "$(bash_in 'herdr pane list --workspace w1')")"
if [ "$(count)" = 5 ]; then pass "10 core, gh and herdr calls leave the count"; else fail "10 core, gh and herdr calls leave the count ($(count))"; fi

# 11: the preamble plus a test run is work
seed null 5
run "$(payload "$SID_A" Bash "$(bash_in 'CORE="$(cd x && pwd)/herdr_orch_core.py"; python3 "$CORE" status; uv run pytest')")"
if [ "$(count)" = 6 ]; then pass "11 a core call plus a test run counts as work"; else fail "11 a core call plus a test run counts as work ($(count))"; fi

# 12: a cd before gh is not work
seed null 5; run "$(payload "$SID_A" Bash "$(bash_in "cd $R && gh pr view 1")")"
if [ "$(count)" = 5 ]; then pass "12 cd then gh leaves the count"; else fail "12 cd then gh leaves the count ($(count))"; fi

# 13-14: the director's own reads do not count; a repo read does
seed null 5
run "$(payload "$SID_A" Read "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1]}))' "$H/.claude/herdr-orch/x.json")")"
a=$(count)
run "$(payload "$SID_A" Read "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1]}))' "$R/tracked.txt")")"
if [ "$a" = 5 ] && [ "$(count)" = 6 ]; then pass "13 a Read under ~/.claude is free, a repo Read counts"; else fail "13 a Read under ~/.claude is free, a repo Read counts ($a, $(count))"; fi
seed null 5
run "$(payload "$SID_A" Read "$(python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1]}))' "$SKILL_FILE")")"
if [ "$(count)" = 5 ]; then pass "14 a Read in the resolved skills dir is free"; else fail "14 a Read in the resolved skills dir is free ($(count))"; fi

# 15: a task-id change resets before counting
seed '"td-a"' 7
run "$(payload "$SID_A" Bash "$(bash_in 'python3 "$CORE" status --task-id td-b')")"
task=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["task_id"])' "$STATE")
if [ "$(count)" = 0 ] && [ "$task" = td-b ]; then pass "15 a task-id change resets the count"; else fail "15 a task-id change resets the count ($(count) $task)"; fi

# 16: a corrupt state file reads as zero
printf 'not json' > "$STATE"; work
if [ "$(count)" = 1 ]; then pass "16 a corrupt state file reads as zero"; else fail "16 a corrupt state file reads as zero ($(count))"; fi

# 17: garbage stdin
if printf 'garbage' | env HOME="$H" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 python3 "$HOOK" >"$FIX/out" 2>&1 && [ ! -s "$FIX/out" ]; then
    pass "17 garbage stdin exits 0 silently"; else fail "17 garbage stdin exits 0 silently"; fi

# 18: the template registers the hook for every tool
if python3 - <<'PY'
import json
entries = json.load(open("claude/settings.json.tmpl"))["hooks"]["PostToolUse"]
assert any(e.get("matcher") == "*" and any(h.get("command") == "~/.claude/hooks/director_delegate_hint.py"
                                            for h in e.get("hooks", [])) for e in entries)
PY
then pass "18 the template registers the hook under PostToolUse *"; else fail "18 the template registers the hook under PostToolUse *"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
