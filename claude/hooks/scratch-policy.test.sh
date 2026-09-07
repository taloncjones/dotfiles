#!/bin/sh
# scratch-policy.test.sh -- hermetic payload tests for scratch_policy.py.
#
# Every fixture lives under mktemp; the hook is driven with a throwaway
# HOME, a per-case TMPDIR, and (for the audit cases) a throwaway
# CLAUDE_CONFIG_DIR, so nothing touches the real state root and no live
# Claude session is involved. The suite never runs an rm the hook approves.
set -u

# Never leave bytecode behind in claude/hooks/ (the hook imports siblings).
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${SCRATCH_POLICY_HOOK:-claude/hooks/scratch_policy.py}
RMG=${RM_GUARD_HOOK:-claude/hooks/rm_guard.py}
ALLOW='{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
PASS=0
FAIL=0

# The fixture tree sits directly under /tmp (not under $TMPDIR) so the
# R2b cases, which unset TMPDIR and expect /tmp descendants in scope, see
# the scratchpad fixture as a /tmp descendant on macOS too.
FIX=$(mktemp -d /tmp/scratch-policy.XXXXXX)
S="$FIX/scratchpad"
T="$FIX/tmpdir"
R="$FIX/repo"
H="$FIX/home"
# S2: a second scratchpad with no checkout inside, for the R2b root case.
# T2: a TMPDIR that is itself a checkout, for the root-level repo case.
S2="$FIX/scratchpad2"
T2="$FIX/tmpdir2"
mkdir -p "$S/build" "$S/clone/.git" "$S2/build" "$T/x" "$T/build/project/.git" \
    "$T2/.git" "$T2/src" "$T/dark/inner" "$R/.git" "$H"
: > "$S/build/x"
: > "$S/-x"
: > "$R/file"
: > "$T/file"
: > "$T/-rf"
ln -s "$R" "$S/link"
# R3 fixtures: entries directly under /tmp named like mktemp's default template.
M3=$(mktemp -d /tmp/tmp.XXXXXXXXXX)
mkdir -p "$M3/child" "$M3/clone/.git"
MF=$(mktemp /tmp/tmp.XXXXXXXXXX)
ML="/tmp/tmp.link$$"
ln -s "$R" "$ML"
# $T/dark is made unreadable for the inspection-error cases; the trap
# restores it so the fixture tree can be removed.
trap 'chmod 700 "$T/dark" 2>/dev/null; rm -rf "$FIX" "$M3"; rm -f "$MF" "$ML"' EXIT

# pr_payload CMD CWD SCRATCH [MODE] [EVENT] [TOOL] -> PermissionRequest JSON on stdout
pr_payload() {
    PR_CMD="$1" PR_CWD="$2" PR_SCRATCH="$3" PR_MODE="${4:-auto}" \
        PR_EVENT="${5:-PermissionRequest}" PR_TOOL="${6:-Bash}" python3 - <<'PY'
import json, os
e = os.environ
p = {"session_id": "11111111-1111-1111-1111-111111111111", "cwd": e["PR_CWD"],
     "permission_mode": e["PR_MODE"], "hook_event_name": e["PR_EVENT"],
     "tool_name": e["PR_TOOL"], "tool_use_id": "toolu_test",
     "tool_input": {"command": e["PR_CMD"]}}
if e["PR_SCRATCH"]:
    p["scratchpad_dir"] = e["PR_SCRATCH"]
print(json.dumps(p))
PY
}

# run_hook PAYLOAD [NAME=VALUE ...]: drives the hook with a hermetic env.
# CASE_TMPDIR (default $T; the word "unset" unsets TMPDIR) picks the R2 root.
run_hook() {
    payload="$1"
    shift
    if [ "${CASE_TMPDIR:-$T}" = unset ]; then
        tmpargs="-u TMPDIR"
    else
        tmpargs="TMPDIR=${CASE_TMPDIR:-$T}"
    fi
    # shellcheck disable=SC2086 -- tmpargs is one env option or one assignment
    printf '%s' "$payload" | env -u HERDR_ENV -u HERDR_WORKSPACE_ID $tmpargs \
        HOME="$H" CLAUDE_CONFIG_DIR="$FIX/nocfg" "$@" "$HOOK" >"$FIX/out" 2>"$FIX/err"
}

# check LABEL EXPECT(allow|none) RC
check() {
    label="$1"
    expect="$2"
    rc="$3"
    ok=0
    if [ "$rc" = 0 ] && [ ! -s "$FIX/err" ]; then
        # Byte-exact: the allow line plus exactly one newline (spec D5).
        if [ "$expect" = allow ] && printf '%s\n' "$ALLOW" | cmp -s - "$FIX/out"; then
            ok=1
        elif [ "$expect" = none ] && [ ! -s "$FIX/out" ]; then
            ok=1
        fi
    fi
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s out=%s err=%s)\n' "$label" "$rc" "$(cat "$FIX/out")" "$(head -n 1 "$FIX/err")" >&2
        FAIL=$((FAIL + 1))
    fi
}

# allow_case / none_case LABEL CMD [CWD] [SCRATCH] [MODE] [EVENT] [TOOL]
allow_case() {
    label="$1"; cmd="$2"; cwd="${3:-$R}"; scratch="${4-$S}"
    if run_hook "$(pr_payload "$cmd" "$cwd" "$scratch" "${5:-auto}" "${6:-PermissionRequest}" "${7:-Bash}")"; then rc=0; else rc=$?; fi
    check "$label" allow "$rc"
}
none_case() {
    label="$1"; cmd="$2"; cwd="${3:-$R}"; scratch="${4-$S}"
    if run_hook "$(pr_payload "$cmd" "$cwd" "$scratch" "${5:-auto}" "${6:-PermissionRequest}" "${7:-Bash}")"; then rc=0; else rc=$?; fi
    check "$label" none "$rc"
}

# --- allow cases (spec D8) ---
allow_case "allows rm -rf under the scratchpad" "rm -rf $S/build"
allow_case "allows rmdir under the scratchpad" "rmdir $S/build"
allow_case "allows /bin/rm under the scratchpad" "/bin/rm $S/build/x"
allow_case "allows a relative target with cwd inside the scratchpad" "rm -rf ./build" "$S"
allow_case "allows -- before a dash-prefixed scratch target" "rm -- $S/-x"
allow_case "allows a glob whose matches are all scratch children" "rm -rf $S/build/*"
allow_case "allows a quoted literal scratch path" "rm -rf \"$S/build\""
allow_case "allows two remove segments joined by &&" "rm $S/build/x && rmdir $S/build"
allow_case "allows two remove segments joined by ;" "rm $S/build/x; rmdir $S/build"
allow_case "allows newline-joined remove segments" "rm $S/build/x
rmdir $S/build"
allow_case "allows a TMPDIR target" "rm $T/file"
allow_case "allows a mktemp dir directly under /tmp" "rm -rf $M3"
allow_case "allows a child of a mktemp dir" "rm -rf $M3/child"
allow_case "allows a mktemp regular file under /tmp" "rm $MF"
allow_case "allows a scratch clone inside the scratchpad (R1 exempt from repo rule)" "rm -rf $S/clone"
allow_case "allows a scratch clone inside a mktemp dir (R3 exempt from repo rule)" "rm -rf $M3/clone"
allow_case "allows listed long options" "rm --recursive --force --verbose $S/build"
# CASE_TMPDIR is set and unset explicitly around calls: POSIX sh keeps a
# `VAR=x func` prefix assignment after the call returns.
CASE_TMPDIR=unset
allow_case "allows /tmp descendants when TMPDIR is unset (R2b)" "rm -rf $M3/child"
allow_case "allows the scratchpad root itself under R2b" "rm -rf $S2" "$R" "$S2"
unset CASE_TMPDIR

# --- no-decision cases (spec D8) ---
none_case "ignores a repo path" "rm $R/file"
none_case "ignores mixed in-scope and out-of-scope targets" "rm $S/build/x $R/file"
none_case "ignores the scratchpad root itself" "rm -rf $S"
none_case "ignores a dot-dot escape" "rm -rf $S/../../etc"
none_case "ignores dot-dot through a symlink" "rm $S/link/../victim"
none_case "ignores a symlink that leaves the scratchpad" "rm $S/link"
none_case "ignores a path through a symlink that leaves the scratchpad" "rm $S/link/file"
none_case "ignores a glob that matches through an escaping symlink" "rm $S/*/file"
none_case "ignores an unexpanded variable target" "rm -rf \$TMPDIR/x"
none_case "ignores a dotglob" "rm -rf $S/.*"
none_case "ignores a .git target" "rm -rf $S/.git"
none_case "ignores /tmp/other when TMPDIR is set" "rm -rf /tmp/other-$$"
none_case "ignores a tmp.* symlink entry itself" "rm $ML"
none_case "ignores a child of a tmp.* symlink entry" "rm $ML/file"
none_case "ignores rmdir -p" "rmdir -p $S/build"
none_case "ignores rmdir with a bundled p flag" "rmdir -pv $S/build"
none_case "ignores an abbreviated rmdir --parents" "rmdir --par $S/build"
none_case "ignores an abbreviated rm --recursive" "rm --rec $S/build"
none_case "ignores an unknown long option" "rm --interactive=never $S/build/x"
none_case "ignores a quoted separator (a filename to the shell)" "rm $S/build/x ';' rm $S/-x"
none_case "ignores a glob that expands to an option word" "rm *" "$T"
none_case "ignores a POSIX bracket class (fnmatch cannot expand it)" "rm $S/[[:alpha:]]*/file"
none_case "ignores a bracket range" "rm $S/[a-z]*"
none_case "ignores a named-user tilde" "rm ~root/file" "$S"
none_case "ignores a quoted tilde (literal to the shell)" "rm \"~/tmpdir/file\"" "$S"
CASE_TMPDIR=relative-tmp
none_case "ignores /tmp descendants when TMPDIR is set but relative" "rm -rf $M3/child"
CASE_TMPDIR=unset
none_case "R2b never reaches under HOME even when HOME is under /tmp" "rm -rf $H/x"
unset CASE_TMPDIR
none_case "ignores a non-standard rm executable path" "/repo/rm $S/build/x"
none_case "ignores a relative rm executable" "./rm $S/build/x"
none_case "ignores sudo rm" "sudo rm $S/build/x"
none_case "ignores an env-assignment prefix" "FOO=1 rm $S/build/x"
none_case "ignores sh -c wrapping" "sh -c 'rm $S/build/x'"
none_case "ignores cd followed by rm" "cd $S && rm -rf build"
none_case "ignores a non-remove segment" "rm $S/build/x && ls"
none_case "ignores a pipeline" "rm $S/build/x | cat"
none_case "ignores || joining" "rm $S/build/x || true"
none_case "ignores a background job" "rm $S/build/x &"
none_case "ignores a subshell group" "(rm $S/build/x)"
none_case "ignores a standalone redirection" "rm $S/build/x > /dev/null"
none_case "ignores a redirection glued to the target" "rm $S/build/x>/dev/null"
none_case "ignores a redirection into the repo glued to the target" "rm $S/build/x>$R/file"
none_case "ignores an unbalanced quote" "rm '$S/build/x"
none_case "ignores a mid-token comment hiding an operand" "rm $S/build/x# $R/file"
none_case "ignores a substitution inside an option token" "rm \"-\$(true)\" $S/build/x"
none_case "ignores a backtick inside an option token" "rm \"-\`true\`\" $S/build/x"
none_case "ignores quoted braces" "rm '$S/{a,b}/x'"
none_case "ignores unquoted braces" "rm $S/{a,b}/x"
none_case "ignores a quoted glob" "rm '$S/build/*'"
none_case "ignores a recursive glob" "rm -rf $S/**/x"
none_case "ignores a glob that reaches a hidden .git under a TMPDIR root" "rm -rf $T/build/project/*"
CASE_TMPDIR="$T2"
none_case "ignores a checkout at the TMPDIR root level" "rm -rf $T2/src"
unset CASE_TMPDIR
none_case "ignores a nested checkout inside a recursive TMPDIR removal" "rm -rf $T/build"
# Inspection errors must never certify a target. Skipped as root, who can
# read anything.
if [ "$(id -u)" != 0 ]; then
    chmod 000 "$T/dark"
    none_case "ignores a recursive removal whose subtree cannot be inspected" "rm -rf $T/dark"
    none_case "ignores a glob over an unreadable directory" "rm $T/dark/*"
    chmod 700 "$T/dark"
else
    printf 'SKIP  ignores a recursive removal whose subtree cannot be inspected (root)\n'
    printf 'SKIP  ignores a glob over an unreadable directory (root)\n'
fi
none_case "ignores a scratch target when scratchpad_dir is absent" "rm -rf $S/build" "$R" ""
none_case "ignores a non-Bash tool" "rm -rf $S/build" "$R" "$S" "auto" "PermissionRequest" "Write"
none_case "ignores a PreToolUse payload" "rm -rf $S/build" "$R" "$S" "auto" "PreToolUse"
none_case "ignores plan mode" "rm -rf $S/build" "$R" "$S" "plan"
none_case "ignores dontAsk mode" "rm -rf $S/build" "$R" "$S" "dontAsk"
none_case "ignores an empty command" ""
CASE_TMPDIR="$H"
none_case "does not widen to HOME when TMPDIR is HOME" "rm -rf $H/x"
CASE_TMPDIR=/
none_case "does not widen to / when TMPDIR is /" "rm -rf /etc"
unset CASE_TMPDIR
if run_hook 'not json'; then rc=0; else rc=$?; fi
check "ignores malformed JSON" none "$rc"

# --- defense in depth: rm_guard runs first and still denies (spec AC4) ---
rmg_payload() {
    printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"cwd":"%s"}' "$1" "$R"
}
if printf '%s' "$(rmg_payload 'rm -rf /')" | HOME="$H" "$RMG" >/dev/null 2>&1; then
    printf 'FAIL  rm_guard still denies rm -rf /\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  rm_guard still denies rm -rf /\n'; PASS=$((PASS + 1))
fi
none_case "policy hook yields no decision on rm -rf / on its own" "rm -rf /"
if printf '%s' "$(rmg_payload "rm -rf $S/.git")" | HOME="$H" "$RMG" >/dev/null 2>&1; then
    printf 'FAIL  rm_guard still denies a .git target\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  rm_guard still denies a .git target\n'; PASS=$((PASS + 1))
fi
if printf '%s' "$(rmg_payload "rm -rf $S/build/*")" | HOME="$H" "$RMG" >/dev/null 2>&1; then
    printf 'PASS  rm_guard passes the scratch shape the policy allows\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  rm_guard passes the scratch shape the policy allows\n' >&2; FAIL=$((FAIL + 1))
fi

# --- audit sidecar (spec D6, AC5) ---
# cfg_fixture DIR: a throwaway config dir with one workspace index and tasks/.
cfg_fixture() {
    mkdir -p "$1/herdr-orch/slug-x/workspaces" "$1/herdr-orch/slug-x/tasks"
    printf '{"task_id":"PROJ-1","repo_slug":"slug-x","role":"impl"}' > "$1/herdr-orch/slug-x/workspaces/w1.json"
}
CFG="$FIX/cfg"
cfg_fixture "$CFG"
SIDECAR="$CFG/herdr-orch/slug-x/tasks/PROJ-1.policy.jsonl"
if run_hook "$(pr_payload "rm -rf $S/build" "$R" "$S")" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG"; then rc=0; else rc=$?; fi
check "audit: allow still printed with HERDR env" allow "$rc"
if [ -f "$SIDECAR" ] && [ "$(wc -l <"$SIDECAR" | tr -d ' ')" = 1 ] \
    && SIDECAR="$SIDECAR" S="$S" python3 - <<'PY'
import json, os, re
rec = json.loads(open(os.environ["SIDECAR"]).readline())
assert rec["v"] == 1 and rec["event"] == "scratch-allow"
assert rec["task_id"] == "PROJ-1" and rec["workspace_id"] == "w1"
assert rec["tool_use_id"] == "toolu_test"
assert rec["command"] == "rm -rf " + os.environ["S"] + "/build"
assert re.match(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$", rec["ts"])
PY
then
    printf 'PASS  audit: one scratch-allow line with the documented fields\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: one scratch-allow line with the documented fields\n' >&2; FAIL=$((FAIL + 1))
fi
if run_hook "$(pr_payload "rm $R/file" "$R" "$S")" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG"; then rc=0; else rc=$?; fi
check "audit: no decision with HERDR env stays silent" none "$rc"
if [ "$(wc -l <"$SIDECAR" | tr -d ' ')" = 1 ]; then
    printf 'PASS  audit: a no-decision appends nothing\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: a no-decision appends nothing\n' >&2; FAIL=$((FAIL + 1))
fi
if [ ! -e "$CFG/herdr-orch/slug-x/workspaces/w1.events.jsonl" ]; then
    printf 'PASS  audit: never creates an events.jsonl\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: never creates an events.jsonl\n' >&2; FAIL=$((FAIL + 1))
fi
CFG2="$FIX/cfg2"
cfg_fixture "$CFG2"
if run_hook "$(pr_payload "rm -rf $S/build" "$R" "$S")" HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG2"; then rc=0; else rc=$?; fi
check "audit: allow without HERDR_ENV" allow "$rc"
if [ ! -e "$CFG2/herdr-orch/slug-x/tasks/PROJ-1.policy.jsonl" ]; then
    printf 'PASS  audit: nothing written without HERDR_ENV\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: nothing written without HERDR_ENV\n' >&2; FAIL=$((FAIL + 1))
fi
CFG3="$FIX/cfg3"
cfg_fixture "$CFG3"
chmod 500 "$CFG3/herdr-orch/slug-x/tasks"
if run_hook "$(pr_payload "rm -rf $S/build" "$R" "$S")" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG3"; then rc=0; else rc=$?; fi
chmod 700 "$CFG3/herdr-orch/slug-x/tasks"
check "audit: unwritable tasks dir still yields the allow" allow "$rc"
CFG4="$FIX/cfg4"
cfg_fixture "$CFG4"
ln -s "$FIX/linked-sidecar" "$CFG4/herdr-orch/slug-x/tasks/PROJ-1.policy.jsonl"
if run_hook "$(pr_payload "rm -rf $S/build" "$R" "$S")" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG4"; then rc=0; else rc=$?; fi
check "audit: symlinked sidecar still yields the allow" allow "$rc"
if [ ! -e "$FIX/linked-sidecar" ]; then
    printf 'PASS  audit: symlinked sidecar is not written through\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: symlinked sidecar is not written through\n' >&2; FAIL=$((FAIL + 1))
fi
CFG5="$FIX/cfg5"
cfg_fixture "$CFG5"
mkfifo "$CFG5/herdr-orch/slug-x/tasks/PROJ-1.policy.jsonl"
pr_payload "rm -rf $S/build" "$R" "$S" | env TMPDIR="$T" HOME="$H" \
    HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 CLAUDE_CONFIG_DIR="$CFG5" "$HOOK" >"$FIX/fifo.out" 2>"$FIX/fifo.err" &
fifo_pid=$!
i=0
while kill -0 "$fifo_pid" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
done
if kill -0 "$fifo_pid" 2>/dev/null; then
    kill "$fifo_pid" 2>/dev/null
    printf 'FAIL  audit: reader-less FIFO sidecar does not block the allow\n' >&2; FAIL=$((FAIL + 1))
elif printf '%s\n' "$ALLOW" | cmp -s - "$FIX/fifo.out" && [ ! -s "$FIX/fifo.err" ]; then
    printf 'PASS  audit: reader-less FIFO sidecar does not block the allow\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: reader-less FIFO sidecar does not block the allow (out=%s)\n' "$(cat "$FIX/fifo.out")" >&2; FAIL=$((FAIL + 1))
fi
wait "$fifo_pid" 2>/dev/null

# --- static checks (spec AC1, AC6, AC7) ---
if [ -x "$HOOK" ] && head -n 1 "$HOOK" | grep -qx '#!/usr/bin/env python3' \
    && PYTHONPYCACHEPREFIX="$FIX/pyc" python3 -m py_compile "$HOOK"; then
    printf 'PASS  static: hook is executable, python3 shebang, compiles\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  static: hook is executable, python3 shebang, compiles\n' >&2; FAIL=$((FAIL + 1))
fi
if grep -q '^import rm_guard' "$HOOK" && ! grep -q '^def tokenize\|^def split_segments\|^def expand_braces' "$HOOK"; then
    printf 'PASS  static: hook reuses rm_guard parsing\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  static: hook reuses rm_guard parsing\n' >&2; FAIL=$((FAIL + 1))
fi
if [ -z "${SCRATCH_POLICY_HOOK:-}" ]; then
    if python3 - <<'PY'
import json, sys
h = json.load(open("claude/settings.json.tmpl"))["hooks"]
pr = h.get("PermissionRequest")
want = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "~/.claude/hooks/scratch_policy.py"}]}]
pre = [x["command"] for e in h["PreToolUse"] if e.get("matcher") == "Bash" for x in e["hooks"]]
want_pre = ["~/.claude/hooks/commit_guard.py", "~/.claude/hooks/no_ai_attribution_bash.py",
            "~/.claude/hooks/push_guard.py", "~/.claude/hooks/herdr_worktree_guard.py",
            "~/.claude/hooks/rm_guard.py"]
sys.exit(0 if pr == want and pre == want_pre else 1)
PY
    then
        printf 'PASS  static: template registers exactly this hook under PermissionRequest\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: template registers exactly this hook under PermissionRequest\n' >&2; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'sh claude/hooks/scratch-policy.test.sh' bin/dotfiles-tests; then
        printf 'PASS  static: suite is registered in bin/dotfiles-tests\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: suite is registered in bin/dotfiles-tests\n' >&2; FAIL=$((FAIL + 1))
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
