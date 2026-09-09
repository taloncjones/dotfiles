# Git Metadata Guard Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PreToolUse hook that, in herdr sessions, denies git remote and config mutations, another task's branch or worktree deletion, and direct edits of `.git/config` / `.git/info/exclude` aimed at a real checkout, while allowing the same operations on fixture repositories under a temp root.

**Architecture:** One new stdlib-only Python guard (`claude/hooks/git_remote_guard.py`) that reuses rm_guard's tokenizer and path helpers, walks the command into segments with a set of possible working directories (subshells, skipped `cd`s, pipelines, quoted operators, and same-command re-pointing are all modelled), proves a fixture with `git rev-parse --git-common-dir` under a ceiling, and reads (never writes) the herdr task records for the branch/worktree rule. One template entry with matcher `Bash|Edit|Write`, one hermetic POSIX-sh suite, one appended drift-check block, one runner line, two doc edits.

**Tech Stack:** Python 3 stdlib (`json`, `os`, `re`, `shlex` via rm_guard, `subprocess`), POSIX sh test suite (`PASS`/`FAIL`, `N passed, N failed`), JSON template and contract, git 2.31+ (`rev-parse --path-format=absolute`).

**Spec:** `docs/specs/2026-09-08-git-remote-guard-hook.md` (read it first; section numbers below refer to it).

**Status:** branch-only document; dropped before merge together with the spec. The task contract at `claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json` is already committed on this branch and stays.

## Global Constraints

- Work only in this worktree; every command below runs from its root. Verify with `git rev-parse --show-toplevel` before each commit.
- Gate: the hook decides only when the environment variable `HERDR_ENV` equals `1` (spec D1). Exit codes: 2 = deny (two stderr lines, first starts `Blocked: `), 0 = allow silently, 0 on any exception (fail open).
- Override token, verbatim: `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment of the segment (spec D6).
- Registration, verbatim (spec D2): a new PreToolUse entry `{"matcher": "Bash|Edit|Write", "hooks": [{"type": "command", "command": "~/.claude/hooks/git_remote_guard.py"}]}` appended LAST in the PreToolUse list. The existing Bash group (`commit_guard`, `no_ai_attribution_bash`, `push_guard`, `herdr_worktree_guard`, `rm_guard`) must not change: two suites pin it.
- Files that may change (spec, "Files that may change"): `claude/hooks/git_remote_guard.py` (new), `claude/hooks/git-remote-guard.test.sh` (new), `claude/settings.json.tmpl`, `claude/hooks/claude-hooks.test.sh` (append-only, no removed lines), `bin/dotfiles-tests` (exactly one added line, no removed lines), `CLAUDE.md`, `claude/skills/post-merge/SKILL.md`. The contract's `changed-files-within-scope` command enforces this list; nothing under `docs/` is merged.
- Parity constraint: `claude/hooks/claude-hooks.test.sh` and `bin/dotfiles-tests` carry uncommitted changes on `talon/claude-codex-parity`; keep every hunk in those two files small and append-only (the contract's `hooks-suite-and-test-runner-edits-append-only` command checks this).
- Fixture safety in the suite (spec D8, the incident this task exists for): one mktemp root asserted with `[ -n "$FIX" ] && [ -d "$FIX" ]`; every fixture git call through `g()` (isolated env, `-C` under `$FIX`); no executed `cd` anywhere (the word `cd` appears only inside payload strings on `case_` lines); the contract's `suite-fixture-safety-scan` command enforces this shape.
- Never edit live `~/.claude/settings.json` or `~/.claude-work/settings.json`, never run `update`; template only. Do not reconcile live settings from the branch (`~/.claude/hooks` points at the main checkout, so the live path would dangle until merge).
- Run the suites sandboxed: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh <suite>`. Full `bin/dotfiles-tests` takes over two minutes: run it in the background to a log and wait on a bounded until-loop for a terminal line; never inline, never `pgrep` a string that matches your own command line.
- Never `cd "$var"` into a possibly-empty variable anywhere; address fixture repos with `git -C "<path>"`.
- No emojis, no AI attribution, ASCII only in added lines, LF endings, stdlib Python only. Commit messages `<scope>: <summary>` (imperative, under 75 chars) and without the word "claude" outside the scope prefix (commit_guard blocks it): say "hooks", "settings template", "hook suite".
- Baseline (spec, 2026-09-08 at base `9ae3daf`, sandboxed HOME): `bin/dotfiles-tests` 25 suites passed, 0 failed; `claude-hooks.test.sh` 185/0; `scratch-policy.test.sh` 104/0; `install/claude-links.test.sh` 26/0; `public-safety.test.sh` 5/0 (it reports 1 expected failure, "no tracked planning artifacts", while the spec and plan are tracked).
- The hook and suite code below was executed during planning: the suite ran 155/155 against the hook (static checks skipped through `GIT_REMOTE_GUARD_HOOK`), and every behavioral contract command passed against the same hook. Copy them verbatim; the tests are the specification of behavior.

## File Structure

| File | Responsibility |
|---|---|
| `claude/hooks/git_remote_guard.py` | The guard: gate, tokenizing walk with possible-cwd sets (spec D3), fixture proof (D4), rules R1-R3 (D5), override (D6), guarded files (D7), denial text (D9). |
| `claude/hooks/git-remote-guard.test.sh` | Hermetic payload suite: fixtures under one mktemp root, 155 behavioral checks plus 4 static registration checks (D8). |
| `claude/settings.json.tmpl` | One appended PreToolUse entry with matcher `Bash|Edit|Write` (D2). |
| `claude/hooks/claude-hooks.test.sh` | One appended static block, label `grg: template registers the git metadata guard under Bash|Edit|Write` (D12). |
| `bin/dotfiles-tests` | One added line after the scratch-policy suite (D12). |
| `CLAUDE.md` | One Architecture bullet after the `scratch_policy.py` bullet (D11). |
| `claude/skills/post-merge/SKILL.md` | Step 3 teardown commands carry the override prefix, with a comment (D11). |
| `claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json` | Task contract (already committed; the orchestrator runs it at completion). |

Task order: 1 hook + suite + registration (one green suite), 2 drift-check block, 3 docs, 4 verification.

## Acceptance criteria to contract mapping

| Spec AC | Contract command(s) |
|---|---|
| AC1 hook shape | `hook-compiles-executable-shebang`, `hook-reuses-rm-guard-parser-and-reads-only` |
| AC2 gate | `gate-inert-outside-herdr`, `bare-remote-remove-denied-with-fixture-rule` |
| AC3 incident shapes | `incident-cd-shapes-denied`, `fixture-paths-allowed`, `fixture-escapes-denied` |
| AC4 config | `config-writes-classified` |
| AC5 task records, read-only | `task-records-branch-and-worktree` |
| AC6 files | `guarded-files-write-edit-and-bash-writers`, `malformed-input-fails-open` |
| AC7 override | `override-semantics` |
| AC8 registration | `template-registers-entry-and-rest-unchanged`, `links-suite-and-reconcile-delivers-hook`, `claude-hooks-suite-green-with-grg-label`, `hooks-suite-and-test-runner-edits-append-only`, `scratch-policy-suite-still-green` |
| AC9 suite | `suite-registered-and-green`, `suite-fixture-safety-scan` |
| AC10 docs | `claude-md-bullet`, `post-merge-teardown-prefixed` |
| AC11 scope | `changed-files-within-scope`, `added-lines-ascii-no-attribution`, `all-suites-except-public-safety-green`, `public-safety-only-expected-failure` |
| Live denial inside a real herdr worker session (after merge, once `update` reconciles live settings) | human-verify |

---

### Task 1: The guard, its suite, and its registration

**Files:**
- Create: `claude/hooks/git-remote-guard.test.sh`
- Create: `claude/hooks/git_remote_guard.py`
- Modify: `claude/settings.json.tmpl` (the `PreToolUse` list, after the `Edit|Write` entry that lists `protect_claude_md.py`, before `"PostToolUse"`)
- Modify: `bin/dotfiles-tests` (the `SUITES` block, directly after `sh claude/hooks/scratch-policy.test.sh`)

**Interfaces:**
- Consumes: `rm_guard.tokenize`, `rm_guard.strip_prefixes`, `rm_guard.basename`, `rm_guard.expand_home`, `rm_guard.resolve`, `rm_guard.resolve_cd_target`, `rm_guard.extract_shell_c_arg`, `rm_guard.has_glob_chars`, `rm_guard.SHELL_WRAPPERS` (unchanged); `herdr_orch_core.state_root`, `valid_workspace_id`, `valid_task_id`, `read_index` (unchanged, imported lazily).
- Produces: `claude/hooks/git_remote_guard.py` with `check_command(command, real_cwd, home, roots, home_real, cwds=None) -> str | None`, `decide(data) -> str | None`, `main() -> int`; the template entry Task 2's drift block asserts; the suite line Task 4 runs.

- [ ] **Step 1: Write the failing suite**

Create `claude/hooks/git-remote-guard.test.sh` with exactly this content (no executable bit needed; suites run as `sh <path>`):

```sh
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
mkdir -p "$T/x" "$H" "$ESC" "$FIX/wt-t1" "$FIX/other" \
    "$CFG/herdr-orch/slug-x/tasks" "$CFG/herdr-orch/slug-x/workspaces" \
    "$CFG/herdr-orch/slug-y/tasks" "$CFG/herdr-orch/slug-y/workspaces"

# g: every fixture git call, with an isolated environment (spec D8).
g() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git "$@"
}
g init -q "$R"
g -C "$R" remote add origin https://example.invalid/x.git
g -C "$R" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
g -C "$R" worktree add -q "$WT" -b wtb >/dev/null 2>&1
g init -q "$REAL"
g -C "$REAL" remote add origin https://example.invalid/real.git
g -C "$REAL" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
g -C "$REAL" worktree add -q "$WTESC" -b escb >/dev/null 2>&1
printf 'gitdir: %s/.git/worktrees/esc\n' "$NONTMP" > "$ESC/.git"
ln -s "$REAL/.git/config" "$T/config-link"
ln -s "$REAL" "$T/repo-link"
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
    if head -n 1 "$FIX/err" | grep -qF "$2"; then
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
case_ "denies -C a repo under HOME" deny "git -C $REAL remote remove origin"
case_ "denies -C a symlink to a real repo" deny "git -C $T/repo-link remote remove origin"
case_ "denies -C a non-temp path" deny "git -C $NONTMP remote remove origin"
case_ "denies --git-dir= form" deny "git --git-dir=$NONTMP/.git remote remove origin"
case_ "denies --git-dir under a root too" deny "git -C $R --git-dir $WT/.git remote remove origin"
case_ "denies --work-tree= form" deny "git --work-tree=$R remote remove origin"
case_ "denies after ln in the same command (taint)" deny "ln -sfn $REAL $T/link; git -C $R remote remove origin"
case_ "denies after git worktree add in the same command (taint)" deny "git -C $R worktree add $T/wt2 && git -C $R remote remove origin"
case_ "allows a later ln (taint is forward only)" allow "git -C $R remote remove origin; ln -s a b"

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

# --- R3: another task's branch or worktree (spec D5) ---
case_ "denies branch -D of an active task" deny "git branch -D talon/T-1/x"
reason_has "branch denial names the task and status" "task T-1 (in-progress)"
case_ "denies branch --delete --force of an active task" deny "git branch --delete --force talon/T-1/x"
case_ "denies branch -D of a reviewed (unmerged) task" deny "git branch -D talon/T-3/x"
case_ "denies branch -D in refs/heads form" deny "git branch -D refs/heads/talon/T-1/x"
case_ "denies branch -D of a same-id task in another slug" deny "git branch -D talon/T-1/y" "$NONTMP" Bash HERDR_WORKSPACE_ID=w1
case_ "denies branch -D of an unexpanded name" deny "git branch -D \"\$branch\""
case_ "denies worktree remove of an active task path" deny "git worktree remove $FIX/wt-t1"
case_ "denies worktree remove --force of an active task path" deny "git worktree remove --force $FIX/wt-t1"
case_ "denies worktree remove by trailing component" deny "git worktree remove wt-t1"
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

# --- R4: guarded files (spec D7) ---
case_ "denies Write to .git/config" deny "$NONTMP/.git/config" "$NONTMP" Write
case_ "denies Edit of .git/info/exclude" deny "$NONTMP/.git/info/exclude" "$NONTMP" Edit
case_ "denies Write to a relative .git/config" deny ".git/config" "$NONTMP" Write
case_ "denies Write to .git/config under HOME" deny "$REAL/.git/config" "$NONTMP" Write
case_ "denies Write through a symlink alias" deny "$T/config-link" "$NONTMP" Write
case_ "denies redirection into .git/config" deny "echo x >> .git/config"
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
```

- [ ] **Step 2: Run the suite to verify it fails**

Run: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh claude/hooks/git-remote-guard.test.sh 2>&1 | tail -n 1`
Expected: `0 passed, 159 failed` (every case fails because `claude/hooks/git_remote_guard.py` does not exist: the `run` helper exits 127, which is neither 2 nor 0; the four `static:` checks fail too).

- [ ] **Step 3: Write the hook**

Create `claude/hooks/git_remote_guard.py` with exactly this content:

```python
#!/usr/bin/env python3
"""PreToolUse hook: deny git-metadata mutations aimed at a real checkout
in herdr sessions.

Incident 2026-09-07: a worker's fixture ran `( cd "$repo" && git remote
remove origin )` with `$repo` empty; `cd ""` succeeds in place, every herdr
worktree shares the main checkout's `.git`, and one bug deleted the origin
remote and every upstream stanza for every checkout at once. rm_guard.py
covers `rm`; this hook covers the git side of the same class.

Gate: decides only when HERDR_ENV=1 (herdr workers and orchestrators);
every other session exits 0 untouched. Matcher `Bash|Edit|Write`.

Denies (exit 2, two stderr lines naming the command and the fixture rule):
- `git remote remove|rm|set-url|rename|prune`, and `git config` writes to
  `remote.*`, `core.*`, `branch.<name>.remote|merge|pushremote` (or those
  sections, or any key when the option grammar is not recognized), unless
  every possible working directory is a fixture repository: a literal,
  existing directory under $TMPDIR or /tmp (never under HOME) whose git
  common dir is also under a temp root. `--global`/`--system` writes and
  `--git-dir`/`--work-tree` forms always deny.
- `git branch -d|-D` and `git worktree remove` of a branch or worktree
  listed in another orchestrated task's record (STATE_ROOT/*/tasks/*.json,
  status not merged/failed/abandoned; the session's own task, resolved
  through HERDR_WORKSPACE_ID, is exempt). Read-only: nothing is written.
- Write/Edit of `.git/config` or `.git/info/exclude` (by path or through a
  symlink) outside a temp root, and Bash redirections, tee, cp, mv,
  truncate, or sed -i into them.

Working directories are tracked as a SET: a `cd` may be skipped (`false &&
cd X; git ...`), undone by a subshell, or fabricated by a quoted operator,
so a mutation is allowed only when every possible directory is a fixture.

Override: `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment on the
segment, after explicit user confirmation only.

Accepted holes: aliases, functions, and script files; `eval`; `$(...)`
and heredoc bodies (a heredoc line starting with a guarded command IS
scanned, so write such prose with the Write tool); `GIT_DIR=` env
assignments (stripped, not interpreted); arguments fed to `xargs git` via
stdin; shell control flow (`if`, `for`, `{ }`) is plain words to the walk;
bind mounts; a same-command re-point by a tool other than ln/mv/cp/rsync/
git worktree, or a concurrent one by another process; `cp .git/config
/tmp/backup` denies although it is a read.

Reuses rm_guard's tokenizer and helpers; fails open on any exception.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_guard  # noqa: E402  parsing helpers, unchanged

OVERRIDE = "DOTFILES_ALLOW_GIT_META=1"
UNTRUSTED = "$UNTRUSTED_CWD"  # non-literal sentinel: cwd cannot be established
OPERATOR_CHARS = ";&|()\n"
REMOTE_DENY = ("remove", "rm", "set-url", "rename", "prune")
GIT_OPTS_WITH_ARG = ("-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env")
LOCATION_OPTS = ("--git-dir", "--work-tree")
LOCATION_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR")
TAINT_HEADS = ("ln", "mv", "cp", "rsync")
TAINT_GIT_WORKTREE = ("add", "move", "repair")
# git config option tables; a write with an option outside them is guarded
CFG_VALUE = ("--file", "--blob", "--type", "--default", "--comment", "--value", "--url")
CFG_READ_VALUE = ("--get-color", "--get-colorbool")
CFG_WRITE = ("--add", "--replace-all", "--unset", "--unset-all",
             "--remove-section", "--rename-section", "--edit", "-e")
CFG_SECTION = ("--remove-section", "--rename-section")
CFG_READ = ("--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l")
CFG_SCOPE_OUTSIDE = ("--global", "--system")
CFG_FLAGS = ("--local", "--worktree", "--bool", "--int", "--bool-or-int", "--bool-or-str",
             "--path", "--expiry-date", "--fixed-value", "--all", "--append", "--includes",
             "--no-includes", "--null", "-z", "--name-only", "--show-origin", "--show-scope",
             "--show-names", "--no-show-names", "--")
CFG_WRITE_VERBS = ("set", "unset", "remove-section", "rename-section", "edit")
CFG_SECTION_VERBS = ("remove-section", "rename-section")
CFG_READ_VERBS = ("get", "list")
GUARDED_KEY = re.compile(r"^(remote(\..*)?|core(\..*)?|branch\..+\.(remote|merge|pushremote))$", re.I)
GUARDED_SECTION = re.compile(r"^(remote(\..*)?|core|branch\..+)$", re.I)
TERMINAL_STATUSES = frozenset({"merged", "failed", "abandoned"})
WRITER_HEADS = ("tee", "cp", "mv", "truncate", "sed")
REDIRECTS = (">", ">>", ">|", "1>", "2>", "1>>", "2>>", "&>", "&>>")
GIT_FILE = re.compile(r"(^|/)\.git/(config|info/exclude)$")
SEGMENT_MAX = 160
FIXTURE_RULE = (
    "Fixture repos only: pass a literal, existing path under ${TMPDIR:-/tmp} to git -C "
    "(resolve mktemp -d in a separate call; never cd into a variable that may be empty). "
    "With explicit user confirmation, prefix the command with " + OVERRIDE + "."
)


# --- paths -----------------------------------------------------------------

def canon(path: str) -> str:
    """realpath of the longest existing ancestor, joined with the rest."""
    existing, rest = path, []
    while existing != "/" and not os.path.lexists(existing):
        existing, tail = os.path.split(existing)
        rest.append(tail)
    real = os.path.realpath(existing)
    return os.path.join(real, *reversed(rest)) if rest else real


def tmp_roots(home_real: str) -> list:
    roots = []
    t = os.environ.get("TMPDIR") or ""
    if t and os.path.isabs(t):
        rp = os.path.realpath(t)
        shallow = len([c for c in rp.split("/") if c]) < 2
        if not (rp == "/" or rp == home_real or home_real.startswith(rp + "/") or shallow):
            roots.append(rp)
    roots.append(os.path.realpath("/tmp"))
    return roots


def under_root(c: str, roots: list, home_real: str):
    """The temp root `c` sits under, or None. A path under HOME is never a
    fixture, whatever the roots say."""
    if c == home_real or c.startswith(home_real + "/"):
        return None
    for r in roots:
        if c.startswith(r + "/"):
            return r
    return None


def literal(tok: str) -> bool:
    return not ("$" in tok or "`" in tok or rm_guard.has_glob_chars(tok))


def fixture_dir(path: str, roots: list, home_real: str):
    """None when `path` is a fixture repository directory, else a reason."""
    c = canon(path)
    root = under_root(c, roots, home_real)
    if root is None:
        return "targets a checkout outside every temp root"
    if not os.path.isdir(c):
        return "fixture path does not exist yet (resolve mktemp -d in a separate call)"
    env = {k: v for k, v in os.environ.items() if k not in LOCATION_ENV}
    env["GIT_CEILING_DIRECTORIES"] = root
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    try:
        out = subprocess.run(
            ["git", "-C", c, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, env=env, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return "fixture repository could not be resolved"
    if out.returncode != 0:
        return "fixture path is not inside a repository under the temp root"
    if under_root(canon(out.stdout.strip()), roots, home_real) is None:
        return "fixture path is a linked worktree whose .git lives outside the temp root"
    return None


def guarded_file(path: str, cwds: set, home: str, roots: list, home_real: str) -> bool:
    """True when `path` names .git/config or .git/info/exclude (directly or
    through a symlink) outside every temp root, for some possible cwd."""
    if not literal(path):
        return False
    for cwd in cwds:
        base = cwd if literal(cwd) else "/"
        p = rm_guard.resolve(rm_guard.expand_home(path, home), base)
        c = canon(p)
        if not (GIT_FILE.search(p) or GIT_FILE.search(c)):
            continue
        if under_root(c, roots, home_real) is None:
            return True
    return False


# --- tokens ----------------------------------------------------------------

def quoted_operator(command: str) -> bool:
    """True when an operator character is quoted or backslash-escaped: the
    tokenizer would turn it into a fake segment boundary."""
    quote = None
    i = 0
    n = len(command)
    while i < n:
        c = command[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
                if command[i + 1] in OPERATOR_CHARS:
                    return True
                i += 2
                continue
            if c == quote:
                quote = None
            elif c in OPERATOR_CHARS:
                return True
        elif c in ("'", '"'):
            quote = c
        elif c == "\\" and i + 1 < n:
            if command[i + 1] in OPERATOR_CHARS:
                return True
            i += 1
        i += 1
    return False


def normalize_operators(tokens: list) -> list:
    """Split operator runs into bare `(`/`)` and `;&|` runs (rm_guard's
    tokenizer yields `);` as one token), then re-join `>` `|` into `>|`."""
    out = []
    for tok in tokens:
        if tok and all(c in OPERATOR_CHARS for c in tok):
            run = ""
            for c in tok:
                if c in "()":
                    if run:
                        out.append(run)
                        run = ""
                    out.append(c)
                else:
                    run += c
            if run:
                out.append(run)
        else:
            out.append(tok)
    merged = []
    for tok in out:
        if tok == "|" and merged and merged[-1] == ">":
            merged[-1] = ">|"
        else:
            merged.append(tok)
    return merged


def is_operator(tok: str) -> bool:
    return bool(tok) and all(c in ";&|\n" for c in tok)


# --- git parsing -----------------------------------------------------------

def parse_git(tokens: list):
    """(subcommand, args, -C values in order, location-hint flag)."""
    i = 1
    cdirs = []
    hints = False
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-C":
            if i + 1 < len(tokens):
                cdirs.append(tokens[i + 1])
            i += 2
            continue
        if tok in LOCATION_OPTS or tok.startswith("--git-dir=") or tok.startswith("--work-tree="):
            hints = True
        if tok in GIT_OPTS_WITH_ARG:
            i += 2
            continue
        if tok.startswith("-"):
            i += 1
            continue
        return tok, tokens[i + 1:], cdirs, hints
    return None, [], cdirs, hints


def effective_dirs(cdirs: list, cwds: set, home: str):
    """Every possible effective directory after the -C values, or (None, reason)."""
    out = set()
    for cwd in cwds:
        d = cwd
        for c in cdirs:
            if not literal(c):
                return None, "working directory contains an unexpanded variable or glob"
            if c == "":
                continue  # git -C "" is a no-op
            d = rm_guard.resolve(rm_guard.expand_home(c, home), d)
        if not literal(d):
            return None, ("working directory cannot be established "
                          "(unexpanded variable, quoted operator, or cd -)")
        out.add(d)
    return out, None


def config_action(args: list):
    """(kind, keys, section_level, scope_outside, file_path, unknown_option)."""
    kind = None
    section = False
    scope_outside = False
    file_path = None
    unknown = False
    positionals = []
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in CFG_VALUE or tok in CFG_READ_VALUE:
            if tok == "--file" and i + 1 < len(args):
                file_path = args[i + 1]
            if tok in CFG_READ_VALUE:
                kind = kind or "read"
            i += 2
            continue
        if tok == "-f":
            if i + 1 < len(args):
                file_path = args[i + 1]
            i += 2
            continue
        if tok.startswith("-f") and not tok.startswith("--") and len(tok) > 2:
            file_path = tok[2:]
        elif tok.startswith("--") and "=" in tok and tok.split("=", 1)[0] in CFG_VALUE:
            if tok.startswith("--file="):
                file_path = tok.split("=", 1)[1]
        elif tok in CFG_SCOPE_OUTSIDE:
            scope_outside = True
        elif tok in CFG_WRITE:
            kind = kind or "write"
            section = section or tok in CFG_SECTION
        elif tok in CFG_READ:
            kind = kind or "read"
        elif tok in CFG_FLAGS:
            pass
        elif tok.startswith("-") and tok != "-":
            unknown = True
        else:
            positionals.append(tok)
        i += 1
    if positionals and positionals[0] in CFG_WRITE_VERBS:
        kind = "write"
        section = positionals[0] in CFG_SECTION_VERBS
        positionals = positionals[1:]
    elif positionals and positionals[0] in CFG_READ_VERBS:
        kind = "read"
        positionals = positionals[1:]
    if kind is None:
        kind = "write" if len(positionals) >= 2 else "read"
    keys = positionals[:2] if section else positionals[:1]
    return kind, keys, section, scope_outside, file_path, unknown


def guarded_config(keys: list, section: bool, unknown: bool) -> bool:
    if unknown or not keys:
        return True
    pat = GUARDED_SECTION if section else GUARDED_KEY
    return any((not literal(k)) or pat.match(k) for k in keys)


def branch_delete_flag(args: list) -> bool:
    for a in args:
        if a in ("-d", "-D", "--delete"):
            return True
        if a.startswith("-") and not a.startswith("--") and any(ch in "dD" for ch in a[1:]):
            return True
    return False


# --- task records (read-only) -------------------------------------------------

def _core():
    import herdr_orch_core  # deferred: only R3 needs it (about 30 ms)
    return herdr_orch_core


def own_task():
    """(repo_slug, task_id) of this session's task via HERDR_WORKSPACE_ID, or None."""
    core = _core()
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return None
    root = core.state_root()
    for idx in sorted(root.glob(f"*/workspaces/{ws}.json")):
        index = core.read_index(idx.parent.parent, ws)
        if index and isinstance(index.get("task_id"), str):
            return idx.parent.parent.name, index["task_id"]
    return None


def protected_records() -> list:
    """[(task_id, record)] for every non-terminal task that is not this
    session's own; sidecars, symlinks, and unreadable files are skipped."""
    core = _core()
    own = own_task()
    out = []
    for p in sorted(core.state_root().glob("*/tasks/*.json")):
        tid = p.name[:-5]
        if not core.valid_task_id(tid) or p.is_symlink():
            continue
        try:
            with open(p) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict) or rec.get("status") in TERMINAL_STATUSES:
            continue
        if (p.parent.parent.name, tid) == own:
            continue
        out.append((tid, rec))
    return out


def protected_branch(name: str):
    recs = [(t, r) for t, r in protected_records() if isinstance(r.get("branch"), str)]
    if not literal(name):
        return ("(unresolved)", f"{len(recs)} protected task branches exist") if recs else None
    if name.startswith("refs/heads/"):
        name = name[len("refs/heads/"):]
    for tid, rec in recs:
        if rec["branch"] == name:
            return tid, rec.get("status")
    return None


def protected_worktree(tok: str, cwds: set, home: str):
    recs = [(t, r) for t, r in protected_records()
            if isinstance(r.get("worktree"), str) and r["worktree"]]
    if not literal(tok):
        return ("(unresolved)", f"{len(recs)} protected task worktrees exist") if recs else None
    targets = {canon(rm_guard.resolve(rm_guard.expand_home(tok, home), cwd))
               for cwd in cwds if literal(cwd)}
    unknown_cwd = any(not literal(cwd) for cwd in cwds)
    suffix = tok.strip("/")
    for tid, rec in recs:
        wc = canon(rec["worktree"])
        if wc in targets:
            return tid, rec.get("status")
        if not tok.startswith("/") and (unknown_cwd or (suffix and wc.endswith("/" + suffix))):
            return tid, rec.get("status")
    return None


# --- rules -----------------------------------------------------------------

def check_git(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    sub, args, cdirs, hints = parse_git(tokens)
    seg = " ".join(tokens)[:SEGMENT_MAX]
    if sub == "remote":
        rargs = [a for a in args if not a.startswith("-")]
        if not rargs or rargs[0] not in REMOTE_DENY:
            return None
        what = f"git remote {rargs[0]} rewrites the shared .git/config of this checkout"
    elif sub == "config":
        kind, keys, section, outside, fpath, unknown = config_action(args)
        if kind != "write" or not guarded_config(keys, section, unknown):
            return None
        key = keys[0] if keys else "(whole file)"
        if unknown:
            key += " (unrecognized option, treated as guarded)"
        if outside:
            return f"git config --global/--system write to {key} edits the user's git config -- {seg}"
        if fpath is not None:
            if literal(fpath):
                dirs, _ = effective_dirs([], cwds, home)
                if dirs and all(under_root(canon(rm_guard.resolve(rm_guard.expand_home(fpath, home), d)),
                                           roots, home_real) for d in dirs):
                    return None
            return f"git config --file write to {key} targets a config outside the temp root -- {seg}"
        what = f"git config write to {key} rewrites the shared .git/config of this checkout"
    elif sub == "branch":
        if not branch_delete_flag(args):
            return None
        for name in [a for a in args if not a.startswith("-")]:
            hit = protected_branch(name)
            if hit:
                return (f"git branch delete of {name} targets the branch of orchestrated "
                        f"task {hit[0]} ({hit[1]}) -- {seg}")
        return None
    elif sub == "worktree" and args and args[0] == "remove":
        for tok in [a for a in args[1:] if not a.startswith("-")]:
            hit = protected_worktree(tok, cwds, home)
            if hit:
                return (f"git worktree remove of {tok} targets the worktree of orchestrated "
                        f"task {hit[0]} ({hit[1]}) -- {seg}")
        return None
    else:
        return None
    if hints:
        return f"{what} (--git-dir/--work-tree forms are not accepted; use git -C) -- {seg}"
    if ctx["taint"]:
        return (f"{what} (an earlier segment can re-point the fixture path before git runs; "
                f"run it as a separate call) -- {seg}")
    dirs, reason = effective_dirs(cdirs, cwds, home)
    if dirs is None:
        return f"{what} ({reason}) -- {seg}"
    for d in sorted(dirs):
        reason = fixture_dir(d, roots, home_real)
        if reason:
            return f"{what} ({reason}) -- {seg}"
    return None


def check_redirects(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    for i, tok in enumerate(tokens):
        if tok in REDIRECTS and i + 1 < len(tokens) \
                and guarded_file(tokens[i + 1], cwds, home, roots, home_real):
            return f"redirection into {tokens[i + 1]} edits git metadata shared by every linked worktree"
        for r in REDIRECTS:
            if tok.startswith(r) and len(tok) > len(r) \
                    and guarded_file(tok[len(r):], cwds, home, roots, home_real):
                return f"redirection into {tok[len(r):]} edits git metadata shared by every linked worktree"
    return None


def check_writers(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    head = rm_guard.basename(tokens[0])
    if head not in WRITER_HEADS:
        return None
    if head == "sed" and not any(
            t == "--in-place" or t.startswith("--in-place=")
            or (t.startswith("-i") and not t.startswith("--")) for t in tokens[1:]):
        return None
    for tok in tokens[1:]:
        if not tok.startswith("-") and guarded_file(tok, cwds, home, roots, home_real):
            return f"{head} on {tok} edits git metadata shared by every linked worktree"
    return None


def is_taint(tokens: list) -> bool:
    head = rm_guard.basename(tokens[0])
    if head in TAINT_HEADS:
        return True
    if head == "git":
        sub, args, _, _ = parse_git(tokens)
        return sub == "worktree" and bool(args) and args[0] in TAINT_GIT_WORKTREE
    return False


def cd_target(tokens: list, cwd: str, home: str) -> str:
    if len(tokens) < 2:
        return home
    if tokens[1] == "-":
        return UNTRUSTED
    return rm_guard.resolve_cd_target(tokens, cwd, home)


# --- the walk ---------------------------------------------------------------

class Chain:
    """Possible-cwd bookkeeping for one run of segments between unconditional
    boundaries (`;`, newline, `&`, `(`, `)`, start, end)."""

    def __init__(self, start: set):
        self.start = set(start)
        self.first_cd = None   # target of a cd that opened the chain (always runs)
        self.cds = []          # targets of later cds (may be skipped)
        self.pure = True       # every joiner so far is &&
        self.first = True      # no segment consumed yet

    def possible(self) -> set:
        if self.pure:
            if self.cds:
                return {self.cds[-1]}
            if self.first_cd is not None:
                return {self.first_cd}
            return set(self.start)
        base = {self.first_cd} if self.first_cd is not None else set(self.start)
        return base | set(self.cds)

    def after(self) -> set:
        """Possible cwds once the chain has ended (a later cd may have been skipped)."""
        base = {self.first_cd} if self.first_cd is not None else set(self.start)
        return base | set(self.cds)

    def record_cd(self, target: str) -> None:
        if self.first:
            self.first_cd = target
        else:
            self.cds.append(target)


def check_command(command: str, real_cwd: str, home: str, roots: list, home_real: str,
                  cwds=None):
    """Denial reason for `command`, or None."""
    start = set(cwds) if cwds is not None else {real_cwd}
    if quoted_operator(command):
        start = {UNTRUSTED}
    ctx = {"P": set(start), "home": home, "roots": roots, "home_real": home_real,
           "taint": False}
    tokens = normalize_operators(rm_guard.tokenize(command))
    chain = Chain(start)
    stack = []
    current = []

    def evaluate(raw: list, term: str):
        ctx["P"] = chain.possible()
        stripped = rm_guard.strip_prefixes(raw)
        overridden = OVERRIDE in raw[:len(raw) - len(stripped)]
        head = rm_guard.basename(stripped[0]) if stripped else ""
        reason = None
        if overridden:
            pass
        elif (reason := check_redirects(raw, ctx)) is not None:
            pass
        elif not stripped:
            pass
        elif head == "cd":
            if term not in ("|", "&"):
                targets = {cd_target(stripped, cwd, home) if literal(cwd) else UNTRUSTED
                           for cwd in ctx["P"]}
                chain.record_cd(next(iter(targets)) if len(targets) == 1 else UNTRUSTED)
        elif head in rm_guard.SHELL_WRAPPERS:
            inner = rm_guard.extract_shell_c_arg(stripped)
            if inner is not None:
                reason = check_command(inner, real_cwd, home, roots, home_real, ctx["P"])
        elif head == "git":
            reason = check_git(stripped, ctx)
        else:
            reason = check_writers(stripped, ctx)
        if stripped and is_taint(stripped):
            ctx["taint"] = True
        chain.first = False
        if term == "||":
            chain.pure = False
        return reason

    def flush(term: str):
        nonlocal chain
        if not current:
            return None
        raw = list(current)
        current.clear()
        reason = evaluate(raw, term)
        if term in (";", "\n", "", "&"):
            chain = Chain(chain.after())
        return reason

    for tok in tokens:
        if tok == "(":
            if (reason := flush(";")) is not None:
                return reason
            stack.append(chain)
            chain = Chain(chain.possible())
        elif tok == ")":
            if (reason := flush("")) is not None:
                return reason
            if stack:
                chain = stack.pop()
                chain.first = False
        elif is_operator(tok):
            if (reason := flush(tok)) is not None:
                return reason
        else:
            current.append(tok)
    return flush("")


# --- entry -------------------------------------------------------------------

def decide(data: dict):
    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    home = os.environ.get("HOME", os.path.expanduser("~"))
    home_real = os.path.realpath(home)
    roots = tmp_roots(home_real)
    cwd = data.get("cwd") or os.getcwd()
    if tool == "Bash":
        command = tool_input.get("command")
        if isinstance(command, str) and command.strip():
            return check_command(command, cwd, home, roots, home_real)
        return None
    if tool in ("Write", "Edit"):
        path = tool_input.get("file_path")
        if isinstance(path, str) and guarded_file(path, {cwd}, home, roots, home_real):
            return f"{tool} to {path} edits git metadata shared by every linked worktree"
    return None


def main() -> int:
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(data, dict):
        return 0
    reason = decide(data)
    if not reason:
        return 0
    print("Blocked: " + reason + ".", file=sys.stderr)
    print(FIXTURE_RULE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
```

Then: `chmod +x claude/hooks/git_remote_guard.py`

Notes for the implementer, all already reflected in the code above:
- `import herdr_orch_core` is deferred into `_core()` so that Bash calls outside the branch/worktree rule do not pay its 30 ms import; `rm_guard` (2 ms) is imported at the top.
- `Chain` implements spec D3 exactly: `possible()` is the segment's possible-cwd set (pure chain: the latest cd target; otherwise start or first_cd united with every later cd target); `after()` is the set carried into the next chain.
- `normalize_operators` is what makes `(cd /x); git ...` split correctly (rm_guard's tokenizer yields `);` as one token) and re-joins `>|`.
- The only subprocess is `git rev-parse` inside `fixture_dir`, run with `GIT_CEILING_DIRECTORIES`, a null global config, and the location env removed.

- [ ] **Step 4: Run the suite to verify the behavioral cases pass**

Run: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh claude/hooks/git-remote-guard.test.sh 2>&1 | grep -v '^PASS'`
Expected: exactly two FAIL lines, `FAIL  static: template registers exactly this hook under Bash|Edit|Write` and `FAIL  static: suite is registered in bin/dotfiles-tests`, and the trailer `157 passed, 2 failed`. Any other FAIL means the hook text was not copied verbatim; diff it against this plan before changing logic.

Also run: `python3 -m py_compile claude/hooks/git_remote_guard.py && test -x claude/hooks/git_remote_guard.py && test -z "$(git status --porcelain claude/hooks | grep -v 'git-remote-guard\|git_remote_guard')" && echo ok`
Expected: `ok` (compiles, executable, and no bytecode or other stray files under `claude/hooks`).

- [ ] **Step 5: Register the hook in the settings template**

In `claude/settings.json.tmpl`, the `PreToolUse` list currently ends with this entry (lines 203-212 at base):

```json
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/protect_claude_md.py"
          }
        ]
      }
    ],
    "PostToolUse": [
```

Change it to (a comma after the existing entry's closing brace, then the new entry, then the unchanged `],` and `"PostToolUse": [`):

```json
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/protect_claude_md.py"
          }
        ]
      },
      {
        "matcher": "Bash|Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/git_remote_guard.py"
          }
        ]
      }
    ],
    "PostToolUse": [
```

Verify: `python3 -c "import json; pre=json.load(open('claude/settings.json.tmpl'))['hooks']['PreToolUse']; print(pre[-1])"`
Expected: `{'matcher': 'Bash|Edit|Write', 'hooks': [{'type': 'command', 'command': '~/.claude/hooks/git_remote_guard.py'}]}`

- [ ] **Step 6: Register the suite in the test runner**

In `bin/dotfiles-tests`, inside the `SUITES="` block, directly after the line `sh claude/hooks/scratch-policy.test.sh`, add one line:

```
sh claude/hooks/git-remote-guard.test.sh
```

Verify: `grep -A1 -x 'sh claude/hooks/scratch-policy.test.sh' bin/dotfiles-tests`
Expected: the two lines, scratch-policy then git-remote-guard.

- [ ] **Step 7: Run the suite to verify it is fully green**

Run: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh claude/hooks/git-remote-guard.test.sh 2>&1 | tail -n 1`
Expected: `159 passed, 0 failed`

Also run: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh claude/hooks/scratch-policy.test.sh 2>&1 | tail -n 1`
Expected: `104 passed, 0 failed` (its pinned Bash-group list is untouched because the new entry has its own matcher).

- [ ] **Step 8: Commit**

```bash
git rev-parse --show-toplevel   # must print this worktree's path
git add claude/hooks/git_remote_guard.py claude/hooks/git-remote-guard.test.sh claude/settings.json.tmpl bin/dotfiles-tests
git commit -m "hooks: Deny git metadata mutations in herdr sessions"
```

---

### Task 2: Drift-check the registration in the hooks suite

**Files:**
- Modify: `claude/hooks/claude-hooks.test.sh` (append one block at the very end, immediately before the final two lines `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` and `[ "$FAIL" = 0 ]`)

**Interfaces:**
- Consumes: the template entry from Task 1 Step 5.
- Produces: the label `grg: template registers the git metadata guard under Bash|Edit|Write`, which the contract's `claude-hooks-suite-green-with-grg-label` command greps for verbatim.

- [ ] **Step 1: Prove the check is falsifiable, then append it**

First run the check against the base template to see it fail (the base has no such entry):

```bash
git show "$(git merge-base origin/main HEAD):claude/settings.json.tmpl" > /tmp/grg-base-tmpl.json && python3 - <<'PY'
import json, sys
pre = json.load(open("/tmp/grg-base-tmpl.json"))["hooks"]["PreToolUse"]
ours = [e for e in pre if e.get("matcher") == "Bash|Edit|Write"]
print("base has entry:", len(ours) == 1)
PY
rm -f /tmp/grg-base-tmpl.json
```

Expected: `base has entry: False`.

Then append this block to `claude/hooks/claude-hooks.test.sh` directly above `printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"` (keep one blank line before the printf):

```sh
# git_remote_guard.py registration: the template carries exactly one
# PreToolUse entry with matcher Bash|Edit|Write, listing only the git
# metadata guard, appended last, and the Bash guard group is untouched.
# Independent of live machine state; the live drift check above is
# derived from the template and covers reconciled machines.
if python3 - <<'PY'
import json
import sys

pre = json.load(open("claude/settings.json.tmpl"))["hooks"]["PreToolUse"]
ours = [e for e in pre if e.get("matcher") == "Bash|Edit|Write"]
bash = [h["command"] for e in pre if e.get("matcher") == "Bash" for h in e["hooks"]]
want_bash = [
    "~/.claude/hooks/commit_guard.py",
    "~/.claude/hooks/no_ai_attribution_bash.py",
    "~/.claude/hooks/push_guard.py",
    "~/.claude/hooks/herdr_worktree_guard.py",
    "~/.claude/hooks/rm_guard.py",
]
ok = (len(ours) == 1 and pre[-1] is ours[0] and bash == want_bash
      and ours[0]["hooks"] == [{"type": "command",
                                "command": "~/.claude/hooks/git_remote_guard.py"}])
sys.exit(0 if ok else 1)
PY
then
    printf 'PASS  grg: template registers the git metadata guard under Bash|Edit|Write\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  grg: template registers the git metadata guard under Bash|Edit|Write\n' >&2; FAIL=$((FAIL + 1))
fi

```

- [ ] **Step 2: Run the hooks suite**

Run: `HOME="$(mktemp -d)" PYTHONDONTWRITEBYTECODE=1 sh claude/hooks/claude-hooks.test.sh 2>&1 | grep -E '^PASS  grg|^FAIL|passed,'`
Expected: `PASS  grg: template registers the git metadata guard under Bash|Edit|Write`, no FAIL lines, trailer `186 passed, 0 failed`.

- [ ] **Step 3: Confirm the edit is append-only**

Run: `git diff -- claude/hooks/claude-hooks.test.sh | grep '^-' | grep -v '^---' | wc -l`
Expected: `0`

- [ ] **Step 4: Commit**

```bash
git add claude/hooks/claude-hooks.test.sh
git commit -m "hooks: Drift-check the git metadata guard registration"
```

---

### Task 3: Document the guard and the post-merge override

**Files:**
- Modify: `CLAUDE.md` (Architecture symlink list; insert one bullet directly after the bullet that starts with `- \`claude/hooks/scratch_policy.py\` -- PermissionRequest hook`, line 82 at base)
- Modify: `claude/skills/post-merge/SKILL.md` (Step 3 code block, lines 61-70 at base)

**Interfaces:**
- Consumes: the file names, matcher, gate, and override token from Task 1.
- Produces: the strings the contract's `claude-md-bullet` and `post-merge-teardown-prefixed` commands grep for.

- [ ] **Step 1: Add the CLAUDE.md bullet**

Insert this single line (one physical line, no wrapping) directly after the `scratch_policy.py` bullet:

```
- `claude/hooks/git_remote_guard.py` -- PreToolUse hook (matcher `Bash|Edit|Write`) that, only when `HERDR_ENV=1`, denies git-metadata mutations aimed at a real checkout: `git remote remove|rm|set-url|rename|prune` and `git config` writes to `remote.*`, `core.*`, or a branch's `remote`/`merge`/`pushremote` (or `--global`/`--system`, `--git-dir`/`--work-tree`, `--edit`, an unresolvable key, or an unrecognized option) unless every possible working directory is a fixture repository under `$TMPDIR` or `/tmp` (never under HOME) whose git common dir is also under a temp root; `git branch -d|-D` and `git worktree remove` of another orchestrated task's branch or worktree (records under the herdr state root with status other than merged/failed/abandoned, read only; the session's own task is exempt); and Write/Edit, redirections, tee, cp, mv, truncate, or sed -i into `.git/config` or `.git/info/exclude` outside a temp root. Working directories are tracked as a set (a `cd` may be skipped, undone by a subshell, or fabricated by a quoted operator), so the incident shape `( cd "$repo" && git remote remove origin )` denies while `git -C <fixture> ...` allows. `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment overrides one segment after explicit user confirmation (registered in `settings.json.tmpl`; tested by `git-remote-guard.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)
```

Verify: `grep -B1 'claude/hooks/git_remote_guard.py' CLAUDE.md | head -n 1 | grep -c 'claude/hooks/scratch_policy.py'`
Expected: `1`

- [ ] **Step 2: Prefix the post-merge teardown commands**

In `claude/skills/post-merge/SKILL.md`, Step 3, replace the first two commands of the code block. Before:

```bash
# Worktree removal. Plain `git worktree remove` FAILS on a worktree that
# contains submodules ("working trees containing submodules cannot be moved or
# removed"). Fall back to rm -rf + prune in that case.
git worktree remove "<wt>" 2>/dev/null \
  || { rm -rf "<wt>" && git worktree prune; }

# Local branch: -D, not -d. A squash-merged branch's commits are NOT ancestors
# of the base, so -d refuses ("not fully merged") even though the PR is merged.
# Only force-delete after Step 0 confirmed state == MERGED.
git branch -D "<headRefName>"
```

After:

```bash
# Worktree removal. Plain `git worktree remove` FAILS on a worktree that
# contains submodules ("working trees containing submodules cannot be moved or
# removed"). Fall back to rm -rf + prune in that case.
# In a herdr session the git metadata guard denies deleting a task's worktree
# or branch until its record reads merged; the Step 2 confirmation is the
# explicit confirmation the DOTFILES_ALLOW_GIT_META=1 override requires.
DOTFILES_ALLOW_GIT_META=1 git worktree remove "<wt>" 2>/dev/null \
  || { rm -rf "<wt>" && git worktree prune; }

# Local branch: -D, not -d. A squash-merged branch's commits are NOT ancestors
# of the base, so -d refuses ("not fully merged") even though the PR is merged.
# Only force-delete after Step 0 confirmed state == MERGED.
DOTFILES_ALLOW_GIT_META=1 git branch -D "<headRefName>"
```

Verify: `grep -c '^DOTFILES_ALLOW_GIT_META=1 git ' claude/skills/post-merge/SKILL.md`
Expected: `2`

- [ ] **Step 3: Run the two doc contract commands**

Run:

```bash
python3 - <<'PY'
import json, subprocess
c = json.load(open("claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json"))
for name in ("claude-md-bullet", "post-merge-teardown-prefixed"):
    cmd = next(x for x in c["commands"] if x["name"] == name)
    rc = subprocess.run(["sh", "-c", cmd["run"]]).returncode
    print(name, "ok" if rc == 0 else f"FAIL exit={rc}")
PY
```

Expected: both lines end with `ok`.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md claude/skills/post-merge/SKILL.md
git commit -m "docs: Document the git metadata guard and post-merge override"
```

---

### Task 4: Verification

**Files:** none modified.

- [ ] **Step 1: Run the fast contract commands**

Run:

```bash
python3 - <<'PY'
import json, subprocess
c = json.load(open("claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json"))
for cmd in c["commands"]:
    if cmd["name"] == "all-suites-except-public-safety-green":
        continue
    rc = subprocess.run(["sh", "-c", cmd["run"]], timeout=cmd["timeout_secs"]).returncode
    print("ok  " if rc == 0 else "FAIL", cmd["name"], rc)
PY
```

Expected: every line starts with `ok`. A FAIL names the command; fix the cause in the task that owns it (see the mapping table) and rerun.

- [ ] **Step 2: Run the full test runner in the background**

Run in the background, to a log (the Bash tool's `run_in_background`, or `&` with the log path):

```bash
h="$(mktemp -d)"; HOME="$h" PYTHONDONTWRITEBYTECODE=1 bash bin/dotfiles-tests > "$h/full.log" 2>&1; echo "rc=$?" >> "$h/full.log"; echo FULL_DONE >> "$h/full.log"
```

Then wait with a bounded loop on the terminal line (never `pgrep`):

```bash
i=0; until grep -q FULL_DONE "$h/full.log" || [ "$i" -ge 900 ]; do sleep 1; i=$((i+1)); done; grep -E '^=== dotfiles-tests|^rc=|^\[X\] FAILED' "$h/full.log"
```

Expected: `=== dotfiles-tests: 25 suites passed, 1 failed` and `[X] FAILED git/hooks/public-safety.test.sh` (the tracked spec and plan trigger its documented "no tracked planning artifacts" failure; every other suite, the new one included, passes). Then run the contract's `public-safety-only-expected-failure` command as in Step 1 and expect `ok`.

- [ ] **Step 3: Confirm the worktree is clean and the diff is in scope**

Run: `git status --porcelain && git diff --name-only "$(git merge-base origin/main HEAD)" HEAD | grep -v '^docs/'`
Expected: no porcelain output; exactly these eight paths: `CLAUDE.md`, `bin/dotfiles-tests`, `claude/contracts/td-2026-09-07-guard-git-remote-and-config-mutations-in-worker-se-contract.json`, `claude/hooks/claude-hooks.test.sh`, `claude/hooks/git-remote-guard.test.sh`, `claude/hooks/git_remote_guard.py`, `claude/settings.json.tmpl`, `claude/skills/post-merge/SKILL.md`.

- [ ] **Step 4: Hand back**

Emit the completion record per the worker brief (`emit-done --phase implement`), citing the three commit hashes and the two suite trailers (`159 passed, 0 failed` and `186 passed, 0 failed`). Do not open a PR, do not merge, do not reconcile live settings.

---

## Follow-ups (not in this task, from the spec)

- Brief template and planner-contract rule ("fixture mutations only under an asserted mktemp root; never `cd "$var"` into a possibly-empty variable") lives on `talon/claude-codex-parity`; add it when parity lands.
- rm_guard: normalize operator runs (`);`) before segment splitting so a subshell close cannot hide an `rm`; this hook's `normalize_operators` is the reference.
- Widen the gate to `permission_mode == auto` plain sessions if the incident class recurs outside herdr.
- `git push --delete` of a task branch (push_guard).
