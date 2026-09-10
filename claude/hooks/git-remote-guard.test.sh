#!/bin/sh
# git-remote-guard.test.sh -- hermetic payload tests for git_remote_guard.py.
#
# Every fixture lives under one asserted mktemp root; the hook is driven with
# a throwaway HOME, TMPDIR, and CLAUDE_CONFIG_DIR, so nothing touches the real
# state root or any real checkout. Fixture safety (the incident this hook
# exists for): every fixture git call goes through g(), which isolates the
# git environment and names its repository with -C under $FIX; the word cd
# appears only inside payload strings on case_ lines, never executed.
set -u

# Never leave bytecode behind in claude/hooks/ (the hook imports siblings).
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${GIT_REMOTE_GUARD_HOOK:-claude/hooks/git_remote_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/git-remote-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

T="$FIX/tmpdir"       # the hook's TMPDIR (a temp root)
H="$FIX/home"         # the hook's HOME (never a fixture, spec D4)
R="$FIX/repo"         # fixture repo with an origin remote
WT="$FIX/wt"          # linked worktree of $R (inside the root)
ESC="$FIX/esc"        # gitfile pointing at metadata that does not exist
REAL="$H/proj"        # a "real" repo: under HOME, outside every root
WTESC="$T/wt-esc"     # linked worktree of $REAL: the containment escape
CFG="$FIX/cfg"        # throwaway CLAUDE_CONFIG_DIR with task records
NONTMP="/Users/grg-test-user/proj"   # synthetic cwd outside every root
WORK="$H/Git/work/project"  # real work-owned repository for account selection
COORD="$FIX/coordination"  # native coordination locks, never caller state
XDG="$FIX/xdg-state"       # native fallback state root, never caller state
WORK_CONFIG="$H/.claude-work"
mkdir -p "$T/x" "$H" "$ESC" "$FIX/wt-t1" "$FIX/other" "$COORD" "$XDG" \
    "$CFG/herdr-orch/slug-x/tasks" "$CFG/herdr-orch/slug-x/workspaces" \
    "$CFG/herdr-orch/slug-y/tasks" "$CFG/herdr-orch/slug-y/workspaces"

# g: every fixture git call, with an isolated environment (spec D8). The
# repository argument (-C <path>, or init's path) must sit under $FIX;
# anything else aborts the suite before git runs.
g() {
    case "$1" in
        -C) case "$2" in "$FIX"/*) ;; *) printf 'FAIL  fixture git outside FIX: %s\n' "$2" >&2; exit 1 ;; esac ;;
        init) case "$3" in "$FIX"/*) ;; *) printf 'FAIL  fixture git init outside FIX: %s\n' "$3" >&2; exit 1 ;; esac ;;
        *) printf 'FAIL  fixture git must use -C or init: %s\n' "$*" >&2; exit 1 ;;
    esac
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}
# The guard on g() is itself exercised: a repository outside $FIX aborts
# (inside a subshell, so the suite itself survives).
if ( g -C "$NONTMP" status ) >/dev/null 2>&1; then
    printf 'FAIL  g refuses a repository outside FIX\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  g refuses a repository outside FIX\n'; PASS=$((PASS + 1))
fi
g init -q "$R"
g -C "$R" remote add origin https://example.invalid/x.git
g -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
g -C "$R" worktree add -q "$WT" -b wtb >/dev/null 2>&1
g init -q "$REAL"
g -C "$REAL" remote add origin https://example.invalid/real.git
g -C "$REAL" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
g -C "$REAL" worktree add -q "$WTESC" -b escb >/dev/null 2>&1
mkdir -p "$WORK"
g init -q "$WORK"
g -C "$WORK" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
mkdir -p "$REAL/child"
ln -s "$REAL/child" "$R/escape"
printf 'gitdir: %s/.git/worktrees/esc\n' "$NONTMP" > "$ESC/.git"
ln -s "$REAL/.git/config" "$T/config-link"
ln -s "$REAL" "$T/repo-link"
mkdir -p "$T/metadata/.git"
ln -s "$H/config-store" "$T/metadata/.git/config"
mkdir -p "$T/~/.git"
# Task records: T-1 active (own task of workspace w1), T-2 merged, T-3
# reviewed (not terminal), and a same-id T-1 in another slug.
printf '{"task_id":"T-1","branch":"talon/T-1/x","worktree":"%s","status":"in-progress"}' "$FIX/wt-t1" \
    > "$CFG/herdr-orch/slug-x/tasks/T-1.json"
printf '{"task_id":"T-2","branch":"talon/T-2/x","worktree":"%s","status":"merged"}' "$FIX/wt-t2" \
    > "$CFG/herdr-orch/slug-x/tasks/T-2.json"
printf '{"task_id":"T-3","branch":"talon/T-3/x","worktree":"%s","status":"reviewed"}' "$FIX/wt-t3" \
    > "$CFG/herdr-orch/slug-x/tasks/T-3.json"
printf '{"task_id":"T-1","branch":"talon/T-1/y","worktree":"%s","status":"in-progress"}' "$FIX/wt-y1" \
    > "$CFG/herdr-orch/slug-y/tasks/T-1.json"
printf '{"task_id":"T-1","repo_slug":"slug-x","role":"impl"}' \
    > "$CFG/herdr-orch/slug-x/workspaces/w1.json"
# A sidecar and a symlinked record must be ignored by the lookup.
printf '{"task_id":"T-9","branch":"talon/T-9/x","status":"in-progress"}' \
    > "$CFG/herdr-orch/slug-x/tasks/T-9.done.json"
ln -s "$CFG/herdr-orch/slug-x/tasks/T-1.json" "$CFG/herdr-orch/slug-x/tasks/T-8.json"

# Native Codex state is selected from the work-owned repository, even when
# CLAUDE_CONFIG_DIR is absent. These records are created through the real core
# commands so selection and account-payload layout match the controller.
WORK_SLUG=$(env -u CLAUDE_CONFIG_DIR -u CLAUDE_PERSONAL_ONLY \
    -u WORKFLOW_PERSONAL_ACCOUNT -u CLAUDE_WORK_TREE -u HERDR_PERSONAL \
    -u HERDR_ACCOUNT_ID -u HERDR_WORKSPACE_ID HERDR_COORDINATION_ROOT="$COORD" \
    XDG_STATE_HOME="$XDG" HOME="$H" CLAUDE_WORK_CONFIG_DIR="$WORK_CONFIG" \
    python3 - "$WORK" <<'PY'
import sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
context = core.repository_context(sys.argv[1])
print(core.repo_slug("", context["common_dir"]))
PY
)
WORK_FENCE=$(env -u CLAUDE_CONFIG_DIR -u CLAUDE_PERSONAL_ONLY \
    -u WORKFLOW_PERSONAL_ACCOUNT -u CLAUDE_WORK_TREE -u HERDR_PERSONAL \
    -u HERDR_ACCOUNT_ID -u HERDR_WORKSPACE_ID HERDR_COORDINATION_ROOT="$COORD" \
    XDG_STATE_HOME="$XDG" HOME="$H" CLAUDE_WORK_CONFIG_DIR="$WORK_CONFIG" \
    python3 claude/hooks/herdr_orch_core.py claim-owner --repo-path "$WORK" --runtime codex \
    --repo-slug "$WORK_SLUG" --session work-session --host test --pid 1 --thread-id test-thread)
env -u CLAUDE_CONFIG_DIR -u CLAUDE_PERSONAL_ONLY -u WORKFLOW_PERSONAL_ACCOUNT \
    -u CLAUDE_WORK_TREE -u HERDR_PERSONAL -u HERDR_ACCOUNT_ID -u HERDR_WORKSPACE_ID \
    HERDR_COORDINATION_ROOT="$COORD" XDG_STATE_HOME="$XDG" HOME="$H" \
    CLAUDE_WORK_CONFIG_DIR="$WORK_CONFIG" \
    python3 claude/hooks/herdr_orch_core.py write-task --repo-path "$WORK" --runtime codex \
    --repo-slug "$WORK_SLUG" --task-id WORK-1 --session work-session --fence "$WORK_FENCE" \
    --json '{"task_id":"WORK-1","branch":"active-task","worktree":"'"$WORK"'/active","status":"in-progress"}'

# payload CMD CWD TOOL -> PreToolUse JSON on stdout (file_path for non-Bash)
payload() {
    P_CMD="$1" P_CWD="$2" P_TOOL="${3:-Bash}" python3 - <<'PY'
import json, os
e = os.environ
ti = {"command": e["P_CMD"]} if e["P_TOOL"] == "Bash" else {"file_path": e["P_CMD"]}
print(json.dumps({"hook_event_name": "PreToolUse", "tool_name": e["P_TOOL"],
                  "cwd": e["P_CWD"], "tool_input": ti}))
PY
}

# payload_codex TOOL FIELD CMD CWD -> a Codex shell-tool payload. FIELD is
# direct, nested, or camel to cover the native adapter aliases.
payload_codex() {
    P_TOOL="$1" P_FIELD="$2" P_CMD="$3" P_CWD="$4" python3 - <<'PY'
import json, os
e = os.environ
command = {"cmd": e["P_CMD"]}
if e["P_FIELD"] == "direct":
    data = {"tool_name": e["P_TOOL"], "cwd": e["P_CWD"], "tool_input": command}
elif e["P_FIELD"] == "nested":
    data = {"tool_name": e["P_TOOL"], "cwd": e["P_CWD"], "tool_input": {"args": command}}
else:
    data = {"toolName": e["P_TOOL"], "cwd": e["P_CWD"], "toolInput": command}
print(json.dumps(data))
PY
}

# payload_patch FIELD PATH CWD -> apply_patch payload variants used by Codex.
payload_patch() {
    P_FIELD="$1" P_PATH="$2" P_CWD="$3" python3 - <<'PY'
import json, os
e = os.environ
patch = "*** Begin Patch\n*** Update File: %s\n@@\n-old\n+new\n*** End Patch" % e["P_PATH"]
if e["P_FIELD"] == "freeform":
    tool_input = patch
else:
    tool_input = {e["P_FIELD"]: patch}
print(json.dumps({"tool_name": "apply_patch", "cwd": e["P_CWD"], "tool_input": tool_input}))
PY
}

# payload_file_alias FIELD PATH CWD -> Write payload with an adapter file key.
payload_file_alias() {
    P_FIELD="$1" P_PATH="$2" P_CWD="$3" python3 - <<'PY'
import json, os
e = os.environ
print(json.dumps({"tool_name": "Write", "cwd": e["P_CWD"],
                  "tool_input": {e["P_FIELD"]: e["P_PATH"]}}))
PY
}

# run PAYLOAD [NAME=VALUE ...]: drives the hook as a herdr session.
run() {
    p="$1"
    shift
    printf '%s' "$p" | env -u HERDR_WORKSPACE_ID HERDR_ENV=1 TMPDIR="$T" HOME="$H" \
        CLAUDE_CONFIG_DIR="$CFG" "$@" "$HOOK" >"$FIX/out" 2>"$FIX/err"
}
# run_plain PAYLOAD [NAME=VALUE ...]: the same, with HERDR_ENV unset.
run_plain() {
    p="$1"
    shift
    printf '%s' "$p" | env -u HERDR_WORKSPACE_ID -u HERDR_ENV TMPDIR="$T" HOME="$H" \
        CLAUDE_CONFIG_DIR="$CFG" "$@" "$HOOK" >"$FIX/out" 2>"$FIX/err"
}

# run_work PAYLOAD [NAME=VALUE ...]: a native Codex work-account payload with
# CLAUDE_CONFIG_DIR deliberately unset, matching the controller's launch env.
run_work() {
    p="$1"
    shift
    printf '%s' "$p" | env -u HERDR_WORKSPACE_ID -u CLAUDE_CONFIG_DIR \
        -u CLAUDE_PERSONAL_ONLY -u WORKFLOW_PERSONAL_ACCOUNT -u CLAUDE_WORK_TREE \
        -u HERDR_PERSONAL -u HERDR_ACCOUNT_ID HERDR_ENV=1 TMPDIR="$T" HOME="$H" \
        HERDR_COORDINATION_ROOT="$COORD" XDG_STATE_HOME="$XDG" \
        CLAUDE_WORK_CONFIG_DIR="$WORK_CONFIG" "$@" "$HOOK" >"$FIX/out" 2>"$FIX/err"
}

# check LABEL EXPECT(deny|allow) RC: deny is exit 2, empty stdout, exactly two
# stderr lines starting "Blocked: "; allow is exit 0 and silent (spec D2, D9).
check() {
    label="$1"
    expect="$2"
    rc="$3"
    ok=0
    if [ "$expect" = deny ] && [ "$rc" = 2 ] && [ ! -s "$FIX/out" ] \
        && head -n 1 "$FIX/err" | grep -q '^Blocked: ' \
        && [ "$(wc -l <"$FIX/err" | tr -d ' ')" = 2 ]; then
        ok=1
    elif [ "$expect" = allow ] && [ "$rc" = 0 ] && [ ! -s "$FIX/out" ] && [ ! -s "$FIX/err" ]; then
        ok=1
    fi
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s out=%s err=%s)\n' "$label" "$rc" "$(cat "$FIX/out")" "$(head -n 1 "$FIX/err")" >&2
        FAIL=$((FAIL + 1))
    fi
}

# case_ LABEL EXPECT CMD [CWD] [TOOL] [NAME=VALUE ...]
case_() {
    label="$1"; expect="$2"; cmd="$3"; cwd="${4:-$NONTMP}"; tool="${5:-Bash}"
    if [ $# -ge 5 ]; then shift 5; elif [ $# -ge 4 ]; then shift 4; else shift 3; fi
    if run "$(payload "$cmd" "$cwd" "$tool")" "$@"; then rc=0; else rc=$?; fi
    check "$label" "$expect" "$rc"
}
# reason_has LABEL TEXT: the last denial's first line contains TEXT.
reason_has() {
    if head -n 1 "$FIX/err" | grep -qF -- "$2"; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (err=%s)\n' "$1" "$(head -n 1 "$FIX/err")" >&2; FAIL=$((FAIL + 1))
    fi
}

# --- R1: remotes (spec D5) ---
case_ "denies bare git remote remove" deny "git remote remove origin"
reason_has "denial names the command and the fixture rule" "git remote remove origin"
grep -q 'git -C' "$FIX/err" && grep -q 'DOTFILES_ALLOW_GIT_META=1' "$FIX/err" \
    && { printf 'PASS  second line carries git -C and the override token\n'; PASS=$((PASS + 1)); } \
    || { printf 'FAIL  second line carries git -C and the override token\n' >&2; FAIL=$((FAIL + 1)); }
case_ "denies remote rm" deny "git remote rm origin"
case_ "denies remote set-url" deny "git remote set-url origin git@x:y.git"
case_ "denies remote rename" deny "git remote rename origin upstream"
case_ "denies remote prune" deny "git remote prune origin"
case_ "denies remote -v remove (option before subcommand)" deny "git remote -v remove origin"
case_ "denies remote --verbose remove" deny "git remote --verbose remove origin"
case_ "denies path-qualified git" deny "/usr/bin/git remote remove origin"
case_ "denies env-prefixed git" deny "env FOO=1 git remote remove origin"
case_ "denies sh -c wrapped" deny "sh -c 'git remote remove origin'"
case_ "denies after a compound" deny "ls && git remote remove origin"
case_ "allows remote add" allow "git remote add origin x"
case_ "allows remote -v" allow "git remote -v"
case_ "allows remote get-url" allow "git remote get-url origin"
case_ "allows a mention in a commit message" allow "git commit -m 'docs: git remote remove origin'"
case_ "allows a grep mention" allow "grep -rn 'git remote remove' claude/"

# --- incident shapes and cwd tracking (spec D3) ---
case_ "denies the cd empty-string form" deny "( cd \"\" && git remote remove origin )"
case_ "denies the cd unexpanded-variable form" deny "( cd \"\$repo\" && git remote remove origin )"
case_ "denies a subshell cd leaking out" deny "( cd $R ); git remote remove origin"
case_ "denies a glued-paren subshell cd leaking out" deny "(cd $R); git remote remove origin"
case_ "denies a cd inside a pipeline" deny "cd $R | git remote remove origin"
case_ "denies a cd as a background job" deny "cd $R & git remote remove origin"
case_ "denies a cd to a missing dir then ;" deny "cd $T/missing; git remote remove origin"
case_ "denies a skipped cd (false && cd X; git)" deny "false && cd $R; git remote remove origin"
case_ "denies a conditional cd via ||" deny "true || cd $R; git remote remove origin"
case_ "denies a cd in an and-chain then ;" deny "mkdir -p $T/x && cd $R; git remote remove origin"
case_ "denies a bare cd (goes home)" deny "cd; git remote remove origin" "$R"
case_ "denies cd - (unknown)" deny "cd -; git remote remove origin" "$R"
case_ "denies a quoted operator fabricating a cd" deny "echo ';' cd $R; git remote remove origin"
case_ "denies an escaped operator fabricating a cd" deny "echo \\; cd $R; git remote remove origin"
case_ "denies a skipped cd preserved across a subshell boundary" deny "false && cd $R && (true); git remote remove origin"
case_ "allows a literal cd && git" allow "cd $R && git remote remove origin"
case_ "allows a literal cd ; git" allow "cd $R; git remote remove origin"
case_ "allows a cd inside the same subshell" allow "( cd $R && git remote remove origin )"
case_ "allows a pure and-chain with a cd" allow "mkdir -p $T/x && cd $R && git remote remove origin"
case_ "allows two literal cds to fixtures" allow "cd $R; cd $WT; git remote remove origin"
case_ "allows false && cd X && git (git needs the cd)" allow "false && cd $R && git remote remove origin"
case_ "allows a quoted operator with an explicit -C" allow "echo ';' && git -C $R remote remove origin"
case_ "allows a quoted operator in a commit message" allow "git commit -m 'a; b' && git status"
case_ "allows a payload cwd inside a fixture" allow "git remote remove origin" "$R"

# --- fixture exemption (spec D4) ---
case_ "allows -C fixture repo" allow "git -C $R remote remove origin"
case_ "allows -C fixture repo set-url" allow "git -C $R remote set-url origin x"
case_ "allows -C linked worktree inside the root" allow "git -C $WT remote remove origin"
case_ "allows -C a subdir of a fixture" allow "git -C $R/.git remote remove origin"
case_ "denies -C unexpanded variable" deny "git -C \"\$d\" remote remove origin"
case_ "denies -C empty string" deny "git -C \"\" remote remove origin"
case_ "denies -C a non-existent temp path" deny "git -C $T/not-yet remote remove origin"
reason_has "non-existent path names the separate-call rule" "does not exist yet"
case_ "denies -C a temp dir that is not a repo" deny "git -C $T remote remove origin"
case_ "denies -C a gitfile with missing metadata" deny "git -C $ESC remote remove origin"
case_ "denies -C the containment escape" deny "git -C $WTESC remote remove origin"
reason_has "escape names the linked-worktree reason" "linked worktree whose .git lives outside the temp root"
case_ "denies -C through a fixture symlink parent" deny "git -C $R/escape/.. remote remove origin"
case_ "denies -C a repo under HOME" deny "git -C $REAL remote remove origin"
case_ "denies -C a symlink to a real repo" deny "git -C $T/repo-link remote remove origin"
case_ "denies -C a non-temp path" deny "git -C $NONTMP remote remove origin"
case_ "denies --git-dir= form" deny "git --git-dir=$NONTMP/.git remote remove origin"
case_ "denies --git-dir under a root too" deny "git -C $R --git-dir $WT/.git remote remove origin"
case_ "denies --work-tree= form" deny "git --work-tree=$R remote remove origin"
case_ "denies --attr-source consuming the subcommand token" deny "git --attr-source HEAD remote remove origin"
case_ "denies an unknown global option before the subcommand" deny "git --some-opt VALUE remote remove origin"
case_ "allows --no-pager before a read subcommand" allow "git --no-pager log"
case_ "allows --paginate before a read subcommand" allow "git --paginate log"
case_ "allows -p before a read subcommand" allow "git -p log"
case_ "allows --no-optional-locks before a read subcommand" allow "git --no-optional-locks status"
case_ "denies after ln in the same command (taint)" deny "ln -sfn $REAL $T/link; git -C $R remote remove origin"
case_ "denies after git worktree add in the same command (taint)" deny "git -C $R worktree add $T/wt2 && git -C $R remote remove origin"
case_ "allows a later ln (taint is forward only)" allow "git -C $R remote remove origin; ln -s a b"
case_ "denies taint reaching a sh -c wrapper" deny "ln -sfn $REAL $T/link2; sh -c 'git -C $R remote remove origin'"
case_ "denies taint raised inside a sh -c wrapper" deny "sh -c 'ln -sfn $REAL $T/link2'; git -C $R remote remove origin"
case_ "denies a re-pointed config --file under the root" deny "ln -sfn $REAL/.git/config $T/cfg; git config --file $T/cfg remote.origin.url x"
case_ "denies a re-pointed redirection under the root" deny "ln -sfn $REAL $T/link2; echo x >> $T/link2/.git/config"
case_ "denies a re-pointed tee under the root" deny "ln -sfn $REAL $T/link2; tee $T/link2/.git/info/exclude"
case_ "denies a location hint with a --file under the root" deny "git --git-dir=$NONTMP/.git config --file $T/cfg remote.origin.url x"

# --- R2: config writes (spec D5) ---
case_ "denies config --unset remote key" deny "git config --unset remote.origin.url"
case_ "denies config positional set of a remote key" deny "git config remote.origin.url https://x"
case_ "denies config --remove-section branch" deny "git config --remove-section branch.main"
case_ "denies config --remove-section dotted branch" deny "git config --remove-section branch.release.1"
case_ "denies config --rename-section into branch" deny "git config --rename-section foo branch.main"
case_ "denies config --unset branch remote" deny "git config --unset branch.main.remote"
case_ "denies config --unset dotted branch remote" deny "git config --unset branch.release.1.remote"
case_ "denies config core write" deny "git config core.hooksPath /x"
case_ "denies config --local write" deny "git config --local remote.origin.url x"
case_ "denies config --global core write" deny "git config --global core.sshCommand ssh"
case_ "denies config set (new style)" deny "git config set remote.origin.url x"
case_ "denies config unset (new style)" deny "git config unset core.hooksPath"
case_ "denies config set --value (no key misparse)" deny "git config set --value old core.hooksPath /x"
case_ "denies config --edit" deny "git config --edit"
case_ "denies config -e --global" deny "git config -e --global"
case_ "denies config edit (new style)" deny "git config edit"
case_ "denies config --file outside the root" deny "git config --file $NONTMP/.git/config remote.origin.url x"
case_ "denies config glued -f outside the root" deny "git -C $R config -f$NONTMP/.git/config core.hooksPath /x"
case_ "denies config --file= outside the root" deny "git -C $R config --file=$NONTMP/.git/config core.hooksPath /x"
case_ "denies config --unset unexpanded key" deny "git config --unset \"\$key\""
case_ "denies config write with an unknown option" deny "git config --frobnicate x user.name y"
case_ "allows config --get" allow "git config --get remote.origin.url"
case_ "allows config single positional read" allow "git config remote.origin.url"
case_ "allows config --list" allow "git config --list"
case_ "allows config get (new style)" allow "git config get remote.origin.url"
case_ "allows config unguarded key write" allow "git config user.name x"
case_ "allows config branch description write" allow "git config branch.main.description x"
case_ "allows git -c override" allow "git -c remote.origin.url=x fetch --dry-run"
case_ "allows -C fixture config write" allow "git -C $R config remote.origin.url x"
case_ "allows -C fixture config set --value" allow "git -C $R config set --value old core.hooksPath /x"
case_ "allows config --file under the root" allow "git config --file $T/cfg remote.origin.url x"
case_ "allows config --file relative to -C fixture" allow "git -C $R config --file .git/config remote.origin.url x" "$WT"
case_ "denies config --file through a fixture symlink parent" deny "git -C $R config --file escape/../.git/config remote.origin.url x" "$WT"

# --- R3: another task's branch or worktree (spec D5) ---
case_ "denies branch -D of an active task" deny "git branch -D talon/T-1/x"
reason_has "branch denial names the task and status" "task T-1 (in-progress)"
case_ "denies branch --delete --force of an active task" deny "git branch --delete --force talon/T-1/x"
case_ "denies branch -D of a reviewed (unmerged) task" deny "git branch -D talon/T-3/x"
case_ "denies branch -D in refs/heads form" deny "git branch -D refs/heads/talon/T-1/x"
case_ "denies branch shorthand while task branches are protected" deny "git branch -D @{-1}"
case_ "denies branch -D of a same-id task in another slug" deny "git branch -D talon/T-1/y" "$NONTMP" Bash HERDR_WORKSPACE_ID=w1
case_ "denies branch -D of an unexpanded name" deny "git branch -D \"\$branch\""
case_ "denies worktree remove of an active task path" deny "git worktree remove $FIX/wt-t1"
case_ "denies worktree remove --force of an active task path" deny "git worktree remove --force $FIX/wt-t1"
case_ "denies worktree remove by trailing component" deny "git worktree remove wt-t1"
case_ "denies worktree remove relative to -C fixture" deny "git -C $R worktree remove ../wt-t1"
case_ "denies worktree remove after unresolved -C" deny "git -C \"\$d\" worktree remove $FIX/other"
case_ "denies worktree remove of an unexpanded path" deny "git worktree remove \"\$wt\""
case_ "allows branch --list" allow "git branch --list"
case_ "allows branch -D of an unrelated branch" allow "git branch -D feature/other"
case_ "allows branch -D of a merged task" allow "git branch -D talon/T-2/x"
case_ "allows branch -D of the own task" allow "git branch -D talon/T-1/x" "$NONTMP" Bash HERDR_WORKSPACE_ID=w1
case_ "allows branch -D of a sidecar-only id" allow "git branch -D talon/T-9/x"
case_ "allows worktree remove of an unrelated path" allow "git worktree remove --force $FIX/other"
case_ "allows worktree remove of the own task" allow "git worktree remove $FIX/wt-t1" "$NONTMP" Bash HERDR_WORKSPACE_ID=w1
case_ "allows worktree list" allow "git worktree list"
case_ "allows worktree prune" allow "git worktree prune"
mkdir -p "$FIX/nocfg"
case_ "allows branch -D of an unexpanded name with no records" allow "git branch -D \"\$branch\"" "$NONTMP" Bash CLAUDE_CONFIG_DIR="$FIX/nocfg"
case_ "allows unresolved -C worktree remove with no records" allow "git -C \"\$d\" worktree remove $FIX/other" "$NONTMP" Bash CLAUDE_CONFIG_DIR="$FIX/nocfg"

# --- R3 account scope: native Codex work state (spec D5) ---
if run_work "$(payload_codex exec_command direct 'git branch -D active-task' "$WORK")"; then rc=0; else rc=$?; fi
check "denies Codex branch delete from work account state" deny "$rc"
if run_work "$(payload_codex exec_command direct "git worktree remove $WORK/active" "$WORK")"; then rc=0; else rc=$?; fi
check "denies Codex worktree remove from work account state" deny "$rc"
if run_work "$(payload_codex exec_command direct 'git branch -D active-task' "$WORK")" \
        WORKFLOW_PERSONAL_ACCOUNT=1; then rc=0; else rc=$?; fi
check "allows Codex personal override without reading work state" allow "$rc"
if run_work "$(payload_codex exec_command direct 'cd "\$empty_path"; git branch -D active-task' "$WORK")"; then rc=0; else rc=$?; fi
check "denies Codex branch delete after an unresolved cd" deny "$rc"

# --- R4: guarded files (spec D7) ---
case_ "denies Write to .git/config" deny "$NONTMP/.git/config" "$NONTMP" Write
case_ "denies Edit of .git/info/exclude" deny "$NONTMP/.git/info/exclude" "$NONTMP" Edit
case_ "denies Write to a relative .git/config" deny ".git/config" "$NONTMP" Write
case_ "denies Write to .git/config under HOME" deny "$REAL/.git/config" "$NONTMP" Write
case_ "denies Write through a symlink alias" deny "$T/config-link" "$NONTMP" Write
case_ "denies Write through a .git/config symlink" deny "$T/metadata/.git/config" "$NONTMP" Write
case_ "denies Write literal glob path to .git/config" deny "$H/project[1]/.git/config" "$NONTMP" Write
case_ "denies Edit literal dollar path to .git/config" deny "$H/project\$local/.git/config" "$NONTMP" Edit
case_ "allows Write literal glob path outside git metadata" allow "$H/project[1]/notes" "$NONTMP" Write
case_ "allows Write literal tilde path under TMPDIR" allow "~/.git/config" "$T" Write
case_ "denies redirection into .git/config" deny "echo x >> .git/config"
reason_has "redirection denial names the segment" "-- echo x >> .git/config"
case_ "denies a glued redirection into .git/info/exclude" deny "printf 'x\\n' >>.git/info/exclude"
case_ "denies >| spaced" deny "echo x >| .git/config"
case_ "denies >| glued" deny "echo x >|.git/config"
case_ "denies a redirection from a git head" deny "git status > .git/config"
case_ "denies a redirection from a cd head" deny "cd . > .git/config"
case_ "denies a redirection from a wrapper head" deny "sh -c true > .git/info/exclude"
case_ "denies a redirection to an absolute non-temp path" deny "echo x > $NONTMP/.git/config"
case_ "denies a redirection through a symlinked repo dir" deny "echo x >> $T/repo-link/.git/config"
case_ "denies tee into .git/config" deny "tee -a .git/config"
case_ "denies tee through a symlink alias" deny "tee $T/config-link"
case_ "denies sed -i on .git/config" deny "sed -i '' 's/a/b/' .git/config"
case_ "denies cp over .git/config" deny "cp x .git/config"
case_ "allows Write to .gitconfig" allow "$H/.gitconfig" "$NONTMP" Write
case_ "allows Write to a temp .git/config" allow "$T/r/.git/config" "$NONTMP" Write
case_ "allows Read of .git/config (not guarded)" allow "$NONTMP/.git/config" "$NONTMP" Read
case_ "allows a redirection into another file" allow "echo x >> .gitignore"
case_ "allows a redirection into a temp .git/config" allow "echo x >> $T/.git/config"
case_ "allows sed without -i on .git/config" allow "sed -n 1p .git/config"

# --- override (spec D6) ---
case_ "allows the override prefix" allow "DOTFILES_ALLOW_GIT_META=1 git remote remove origin"
case_ "allows the override after env" allow "env DOTFILES_ALLOW_GIT_META=1 git remote remove origin"
case_ "allows the override inside sh -c" allow "sh -c 'DOTFILES_ALLOW_GIT_META=1 git remote remove origin'"
case_ "allows the override leading a sh -c wrapper" allow "DOTFILES_ALLOW_GIT_META=1 sh -c 'git remote remove origin'"
case_ "allows the override on a redirection" allow "DOTFILES_ALLOW_GIT_META=1 echo x > .git/config"
case_ "allows the override on tee" allow "DOTFILES_ALLOW_GIT_META=1 tee .git/config"
case_ "denies the token as a config value" deny "git config remote.origin.url DOTFILES_ALLOW_GIT_META=1"
case_ "denies the token as a trailing argument" deny "git remote remove origin DOTFILES_ALLOW_GIT_META=1"
case_ "denies the token on an adjacent segment" deny "DOTFILES_ALLOW_GIT_META=1 true; git remote remove origin"
case_ "denies an overridden cd that leaves the fixture" deny "DOTFILES_ALLOW_GIT_META=1 cd $REAL; git remote remove origin" "$R"

# --- gate and malformed input (spec D1, D2) ---
case_ "allows an empty command" allow ""
if run_plain "$(payload 'git remote remove origin' "$NONTMP")"; then rc=0; else rc=$?; fi
check "inert without HERDR_ENV" allow "$rc"
if run_plain "$(payload 'git remote remove origin' "$NONTMP")" HERDR_ENV=0; then rc=0; else rc=$?; fi
check "inert with HERDR_ENV=0" allow "$rc"
if run_plain "$(payload "$NONTMP/.git/config" "$NONTMP" Write)"; then rc=0; else rc=$?; fi
check "inert for Write without HERDR_ENV" allow "$rc"
if printf 'not json' | env HERDR_ENV=1 HOME="$H" TMPDIR="$T" "$HOOK" >"$FIX/out" 2>"$FIX/err"; then rc=0; else rc=$?; fi
check "ignores malformed JSON" allow "$rc"
if printf '{"tool_name":"Bash","tool_input":"git remote remove origin","cwd":"%s"}' "$NONTMP" \
        | env HERDR_ENV=1 HOME="$H" TMPDIR="$T" "$HOOK" >"$FIX/out" 2>"$FIX/err"; then rc=0; else rc=$?; fi
check "ignores a string tool_input" allow "$rc"
if printf '[1,2]' | env HERDR_ENV=1 HOME="$H" TMPDIR="$T" "$HOOK" >"$FIX/out" 2>"$FIX/err"; then rc=0; else rc=$?; fi
check "ignores a non-object payload" allow "$rc"

# Codex aliases must drive the same behavior as the Claude Bash payload.
if run "$(payload_codex exec_command direct 'git remote remove origin' "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies exec_command cmd payload" deny "$rc"
if run "$(payload_codex shell_command nested 'git remote remove origin' "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies shell_command nested cmd payload" deny "$rc"
if run "$(payload_codex unified_exec camel 'git remote remove origin' "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies unified_exec camel cmd payload" deny "$rc"
if run "$(payload_patch patch "$NONTMP/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies apply_patch patch payload" deny "$rc"
if run "$(payload_patch input "$H/project[1]/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies apply_patch input literal glob path" deny "$rc"
if run "$(payload_patch freeform "$NONTMP/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies apply_patch freeform payload" deny "$rc"
if run "$(payload_patch freeform "$H/project\$local/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies apply_patch freeform literal dollar path" deny "$rc"
if run "$(payload_patch input '~/.git/config' "$T")"; then rc=0; else rc=$?; fi
check "allows apply_patch literal tilde path under TMPDIR" allow "$rc"
if run "$(payload_file_alias filePath "$NONTMP/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies Write filePath payload" deny "$rc"
if run "$(payload_file_alias path "$NONTMP/.git/config" "$NONTMP")"; then rc=0; else rc=$?; fi
check "denies Write path payload" deny "$rc"

# --- read-only state root (spec R3) ---
state_snapshot() {
    find "$CFG" -type f | sort | while read -r f; do shasum -a 256 "$f"; done
}
before=$(state_snapshot)
run "$(payload 'git branch -D talon/T-1/x' "$NONTMP")" || true
run "$(payload 'git branch -D talon/T-2/x' "$NONTMP")" || true
after=$(state_snapshot)
if [ -n "$before" ] && [ "$before" = "$after" ] \
    && [ -z "$(find "$CFG" -name '*.jsonl' -o -name 'events.jsonl' | head -n 1)" ]; then
    printf 'PASS  hook leaves the state root byte-identical\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  hook leaves the state root byte-identical\n' >&2; FAIL=$((FAIL + 1))
fi

# --- static checks (spec AC1, AC8, AC9); skipped when the hook path is overridden ---
if [ -z "${GIT_REMOTE_GUARD_HOOK:-}" ]; then
    if [ -x "$HOOK" ] && head -n 1 "$HOOK" | grep -qx '#!/usr/bin/env python3' \
        && PYTHONPYCACHEPREFIX="$FIX/pyc" python3 -m py_compile "$HOOK"; then
        printf 'PASS  static: hook is executable, python3 shebang, compiles\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: hook is executable, python3 shebang, compiles\n' >&2; FAIL=$((FAIL + 1))
    fi
    if grep -q '^import rm_guard' "$HOOK" \
        && ! grep -q '^def tokenize\|^def split_segments\|^def expand_braces' "$HOOK"; then
        printf 'PASS  static: hook reuses rm_guard parsing\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: hook reuses rm_guard parsing\n' >&2; FAIL=$((FAIL + 1))
    fi
    if python3 - <<'PY'
import json, sys
pre = json.load(open("claude/settings.json.tmpl"))["hooks"]["PreToolUse"]
ours = [e for e in pre if e.get("matcher") == "Bash|Edit|Write"]
bash = [h["command"] for e in pre if e.get("matcher") == "Bash" for h in e["hooks"]]
want_bash = ["~/.claude/hooks/commit_guard.py", "~/.claude/hooks/no_ai_attribution_bash.py",
             "~/.claude/hooks/push_guard.py", "~/.claude/hooks/herdr_worktree_guard.py",
             "~/.claude/hooks/rm_guard.py"]
ok = len(ours) == 1 and ours[0]["hooks"] == [{"type": "command", "command": "~/.claude/hooks/git_remote_guard.py"}] \
    and bash == want_bash
sys.exit(0 if ok else 1)
PY
    then
        printf 'PASS  static: template registers exactly this hook under Bash|Edit|Write\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: template registers exactly this hook under Bash|Edit|Write\n' >&2; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'sh claude/hooks/git-remote-guard.test.sh' bin/dotfiles-tests; then
        printf 'PASS  static: suite is registered in bin/dotfiles-tests\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: suite is registered in bin/dotfiles-tests\n' >&2; FAIL=$((FAIL + 1))
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
