#!/bin/sh
# planning-artifact-guard.test.sh -- hermetic payload tests for
# planning_artifact_guard.py. Every fixture lives under one asserted mktemp
# root; the hook runs with a throwaway HOME and TMPDIR and an isolated git
# environment. A repository under $HOME is guarded; one under TMPDIR (not
# under HOME) is a fixture and exempt. The word cd appears only inside
# payload strings, never executed.
set -u

PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE

HOOK=${PLANNING_ARTIFACT_GUARD_HOOK:-claude/hooks/planning_artifact_guard.py}
PASS=0
FAIL=0

FIX=$(mktemp -d /tmp/planning-artifact-guard.XXXXXX)
[ -n "$FIX" ] && [ -d "$FIX" ] || { printf 'FAIL  cannot create the fixture root\n' >&2; exit 1; }
trap 'rm -rf "$FIX"' EXIT

T="$FIX/tmpdir"        # the hook's TMPDIR (a temp root)
H="$FIX/home"          # the hook's HOME (never a fixture)
R="$H/proj"            # guarded repo: untracked docs/specs/x.md, tracked docs/plans/tracked.md, ignored claude/contracts/c.json
STAGED="$H/staged"     # guarded repo with docs/specs/s.md staged
AMEND="$H/amend"       # guarded repo whose HEAD added docs/plans/p.md
LEGACY="$H/legacy"     # guarded repo with a tracked contract removed from the index
X="$T/fixture"         # fixture repo under the temp root: exempt
mkdir -p "$T" "$H"

g() {
    case "$1" in
        -C) case "$2" in "$FIX"/*) ;; *) printf 'FAIL  fixture git outside FIX: %s\n' "$2" >&2; exit 1 ;; esac ;;
        init) last=; for a in "$@"; do last=$a; done
              case "$last" in "$FIX"/*) ;; *) printf 'FAIL  fixture git init outside FIX: %s\n' "$last" >&2; exit 1 ;; esac ;;
        *) printf 'FAIL  fixture git must use -C or init: %s\n' "$*" >&2; exit 1 ;;
    esac
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}
commit() { g -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q -m "$2"; }

seed() {  # seed <repo>: main branch, README committed
    mkdir -p "$1"
    g init -q -b main "$1"
    printf 'readme\n' > "$1/README.md"
    g -C "$1" add README.md
    commit "$1" init
}

seed "$R"
mkdir -p "$R/docs/specs" "$R/docs/plans" "$R/claude/contracts"
printf 'claude/contracts/\n' > "$R/.gitignore"
printf 'tracked\n' > "$R/docs/plans/tracked.md"
g -C "$R" add .gitignore docs/plans/tracked.md
commit "$R" plans
printf 'spec\n' > "$R/docs/specs/x.md"            # untracked, not ignored
printf '{}\n' > "$R/claude/contracts/c.json"        # ignored

seed "$STAGED"
mkdir -p "$STAGED/docs/specs"
printf 'spec\n' > "$STAGED/docs/specs/s.md"
g -C "$STAGED" add docs/specs/s.md                  # staged, never committed

seed "$AMEND"
mkdir -p "$AMEND/docs/plans"
printf 'plan\n' > "$AMEND/docs/plans/p.md"
g -C "$AMEND" add docs/plans/p.md
commit "$AMEND" plan

seed "$LEGACY"
mkdir -p "$LEGACY/claude/contracts"
printf '{}\n' > "$LEGACY/claude/contracts/old.json"
g -C "$LEGACY" add claude/contracts/old.json
commit "$LEGACY" contract
g -C "$LEGACY" rm -q --cached claude/contracts/old.json   # index: D only; disk copy stays

seed "$X"
mkdir -p "$X/docs/specs"
printf 'spec\n' > "$X/docs/specs/x.md"

LINKED="$T/linked"    # linked worktree of the guarded repo R, checked out under the temp root: NOT exempt (its .git lives in R, under HOME)
g -C "$R" worktree add -q "$LINKED" -b brk1-linked main
mkdir -p "$LINKED/docs/specs"
printf 'spec\n' > "$LINKED/docs/specs/y.md"

run_hook() {  # run_hook <payload>; stdout/stderr to $FIX/out $FIX/err; returns hook rc
    printf '%s' "$1" | env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        HOME="$H" TMPDIR="$T" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        python3 "$HOOK" > "$FIX/out" 2> "$FIX/err"
}
payload() {  # payload <cwd> <command> -> Claude Bash payload JSON (command must be JSON-safe)
    printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' "$1" "$2"
}
case_deny() {  # case_deny <label> <payload>
    run_hook "$2"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf 'FAIL  %s (rc=0)\n' "$1" >&2; FAIL=$((FAIL + 1))
    elif [ "$rc" -eq 2 ] && grep -q 'DOTFILES_ALLOW_PLAN_ARTIFACTS=1' "$FIX/err"; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s err=%s)\n' "$1" "$rc" "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
    fi
}
case_allow() {  # case_allow <label> <payload>
    if run_hook "$2"; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s err=%s)\n' "$1" "$?" "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
    fi
}

# --- add: literal pathspecs (no successful git call needed) ------------------
case_deny  "add of a spec path" "$(payload "$R" 'git add docs/specs/x.md')"
case_deny  "add of a plan path" "$(payload "$R" 'git add docs/plans/tracked.md')"
case_deny  "forced add of an ignored contract" "$(payload "$R" 'git add -f claude/contracts/c.json')"
case_deny  "stage alias" "$(payload "$R" 'git stage docs/specs/x.md')"
case_deny  "glob under a protected prefix" "$(payload "$R" 'git add docs/specs/*.md')"
case_deny  "dot-slash prefix" "$(payload "$R" 'git add ./docs/specs/x.md')"
case_deny  "pathspec after double dash" "$(payload "$R" 'git add -- docs/specs/x.md')"
case_deny  "relative pathspec from a subdirectory" "$(payload "$R/docs" 'git add specs/x.md')"
case_deny  "add of a spec path via :/ pathspec magic" "$(payload "$R" 'git add :/docs/specs/x.md')"
case_deny  "add of a spec path via :(top) pathspec magic" "$(payload "$R" 'git add :(top)docs/specs/x.md')"
case_deny  "git -C into the guarded repo" "$(payload "$X" "git -C $R add docs/specs/x.md")"
case_deny  "linked worktree of a HOME repo under /tmp is not exempt" "$(payload "$LINKED" 'git add -f docs/specs/y.md')"
case_deny  "case variant of a protected prefix" "$(payload "$R" 'git add -f Docs/Specs/y.md')"
case_deny  "sh -c wrapper" "$(payload "$R" "sh -c \\\"git add docs/specs/x.md\\\"")"
case_deny  "literal pathspec under a non-literal cd" "$(payload "$R" 'cd \"$wt\" && git add docs/specs/x.md')"
case_deny  "leading env assignment other than the override" "$(payload "$R" 'GIT_TRACE=1 git add docs/specs/x.md')"
case_allow "unrelated file" "$(payload "$R" 'git add README.md')"
case_allow "unrelated file via :/ pathspec magic" "$(payload "$R" 'git add :/README.md')"
case_allow "unrelated file with a protected-looking name" "$(payload "$R" 'git add docs/specs.md')"
case_allow "other git subcommands" "$(payload "$R" 'git status && git remote -v && git log -1')"
case_allow "override on the segment" "$(payload "$R" 'DOTFILES_ALLOW_PLAN_ARTIFACTS=1 git add docs/specs/x.md')"
case_deny  "override on another segment only" "$(payload "$R" 'DOTFILES_ALLOW_PLAN_ARTIFACTS=1 git status; git add docs/specs/x.md')"

# --- add: scans -------------------------------------------------------------
case_deny  "add -A with an unignored spec" "$(payload "$R" 'git add -A')"
case_deny  "add dot" "$(payload "$R" 'git add .')"
case_deny  "add of an ancestor directory" "$(payload "$R" 'git add docs')"
case_deny  "add -A via git -C from the fixture" "$(payload "$X" "git -C $R add -A")"
case_deny  "subshell cd into the guarded repo" "$(payload "$X" "(cd $R && git add -A)")"
case_deny  "or-chain: a skipped cd keeps the start cwd possible" "$(payload "$R" "false && cd $X || git add -A")"
case_deny  "or-chain literal pathspec" "$(payload "$R" 'false || git add docs/specs/x.md')"
case_deny  "non-literal cd falls back to the payload cwd" "$(payload "$R" 'cd \"$wt\" && git add -A')"
case_allow "non-literal cd with a fixture payload cwd" "$(payload "$X" 'cd \"$wt\" && git add -A')"
case_allow "add -u with no modified protected file" "$(payload "$R" 'git add -u')"
case_allow "add -A scoped to an unprotected path" "$(payload "$R" 'git add -A README.md')"
printf 'changed\n' > "$R/docs/plans/tracked.md"
case_deny  "add -u with a modified tracked plan" "$(payload "$R" 'git add -u')"
case_deny  "commit -a with a modified tracked plan" "$(payload "$R" 'git commit -am x')"
case_deny  "commit --all long form" "$(payload "$R" 'git commit --all -m x')"
case_allow "plain commit with a clean index" "$(payload "$R" 'git commit -m x')"
g -C "$R" checkout -q -- docs/plans/tracked.md

# --- commit ------------------------------------------------------------------
case_deny  "commit with a staged spec" "$(payload "$STAGED" 'git commit -m x')"
case_deny  "commit with a staged spec, message with spaces" "$(payload "$STAGED" 'git commit -m \"two words\"')"
case_deny  "commit -o pathspec" "$(payload "$R" 'git commit -o -m x -- docs/specs/x.md')"
case_deny  "commit -o pathspec via :/ pathspec magic" "$(payload "$STAGED" 'git commit -o -m x -- :/docs/specs/s.md')"
case_deny  "amend of a commit carrying a plan" "$(payload "$AMEND" 'git commit --amend --no-edit')"
case_allow "commit after git rm --cached (deletion only)" "$(payload "$LEGACY" 'git commit -m untrack')"
case_deny  "add -A while the untracked legacy copy is still on disk" "$(payload "$LEGACY" 'git add -A')"
rm -f "$LEGACY/claude/contracts/old.json"
case_allow "add -A after the legacy contract is gone from index and disk" "$(payload "$LEGACY" 'git add -A')"
case_allow "commit in the fixture repo" "$(payload "$X" 'git add docs/specs/x.md && git commit -m x')"

# --- non-literal pathspecs and pushd tracking --------------------------------
case_deny  "non-literal pathspec via a shell variable forces a full scan" "$(payload "$R" 'f=claude/contracts/c.json; git add -f \"$f\" && git commit -q -m leak')"
case_deny  "pushd into a protected dir is tracked like cd" "$(payload "$R" 'pushd docs/specs && git add -f y.md')"

# --- payload shapes ----------------------------------------------------------
case_deny  "codex exec_command cmd" "{\"tool_name\":\"exec_command\",\"cwd\":\"$R\",\"tool_input\":{\"cmd\":\"git add docs/specs/x.md\"}}"
case_deny  "codex nested args with workdir" "{\"tool_name\":\"unified_exec\",\"tool_input\":{\"args\":{\"cmd\":\"git add -A\",\"workdir\":\"$R\"}}}"
case_deny  "camelCase shell_command" "{\"toolName\":\"shell_command\",\"cwd\":\"$R\",\"toolInput\":{\"command\":\"git add docs/plans/tracked.md\"}}"
case_allow "non-shell tool" "{\"tool_name\":\"Write\",\"cwd\":\"$R\",\"tool_input\":{\"file_path\":\"docs/specs/x.md\",\"content\":\"git add docs/specs/x.md\"}}"
case_allow "malformed json" "{not json"
case_allow "null tool_input" "{\"tool_name\":\"Bash\",\"tool_input\":null}"
case_allow "empty command" "$(payload "$R" '')"

# --- deny message names the path and the rule --------------------------------
run_hook "$(payload "$R" 'git add docs/specs/x.md')"
if grep -q 'docs/specs/x.md' "$FIX/err" && grep -q '^Blocked: ' "$FIX/err" && [ "$(wc -l < "$FIX/err")" -eq 2 ]; then
    printf 'PASS  deny message: two lines, path and rule\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  deny message: two lines, path and rule (got: %s)\n' "$(cat "$FIX/err")" >&2; FAIL=$((FAIL + 1))
fi

# --- git budget exhaustion fails open for scans, not for literal paths ------
mkdir -p "$FIX/slowbin"
printf '#!/bin/sh\nsleep 30\n' > "$FIX/slowbin/git"; chmod +x "$FIX/slowbin/git"
if printf '%s' "$(payload "$R" 'git add -A')" | env -u GIT_DIR HOME="$H" TMPDIR="$T" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="$FIX/slowbin:$PATH" python3 "$HOOK" >/dev/null 2>&1; then
    printf 'PASS  slow git: scan yields no decision\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  slow git: scan yields no decision (rc=%s)\n' "$?" >&2; FAIL=$((FAIL + 1))
fi
if printf '%s' "$(payload "$R" 'git add docs/specs/x.md')" | env -u GIT_DIR HOME="$H" TMPDIR="$T" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PATH="$FIX/slowbin:$PATH" python3 "$HOOK" >/dev/null 2>&1; then
    printf 'FAIL  slow git: literal pathspec still denies (rc=0)\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  slow git: literal pathspec still denies\n'; PASS=$((PASS + 1))
fi

# --- static ------------------------------------------------------------------
if head -n 1 "$HOOK" | grep -qx '#!/usr/bin/env python3' && [ -x "$HOOK" ] \
    && grep -q '^import rm_guard' "$HOOK" && grep -q '^import git_remote_guard' "$HOOK" \
    && ! grep -q 'grg\.check_command\|git_remote_guard\.check_command' "$HOOK" \
    && ! grep -q '\.write_text\|open(.*"w"\|os\.open\|shutil' "$HOOK"; then
    printf 'PASS  static: shebang, executable, reuses guards, writes nothing\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  static: shebang, executable, reuses guards, writes nothing\n' >&2; FAIL=$((FAIL + 1))
fi
if find claude/hooks -name '__pycache__' -newer "$FIX" | grep -q .; then
    printf 'FAIL  no bytecode left under claude/hooks\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  no bytecode left under claude/hooks\n'; PASS=$((PASS + 1))
fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
