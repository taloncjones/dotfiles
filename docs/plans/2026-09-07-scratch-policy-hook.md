# Scratch Policy Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `claude/hooks/scratch_policy.py`, a `PermissionRequest` hook for the Bash tool that answers a residual permission prompt with `allow` only for plain `rm`/`rmdir` commands whose every target lies strictly under a throwaway root, register it in the settings template, audit each allow for orchestrated workers, and prove it with a hermetic suite.

**Architecture:** One new Python hook that imports `rm_guard.py` for tokenizing and path resolution and `herdr_orch_core.py` for read-only state helpers; it prints one fixed JSON line on allow and nothing otherwise, never denies, and fails open toward the normal prompt. One new POSIX `sh` suite drives it with fixture payloads under `mktemp`. The template gains one `PermissionRequest` event; the reconcile that already delivers every template hook delivers this one.

**Tech Stack:** Python 3.10+ (stdlib only: `json`, `os`, `shlex`, `stat`, `fnmatch`), POSIX `sh` test suite, `bin/dotfiles-tests` runner (also Ubuntu CI), JSON settings template.

**Spec:** `docs/specs/2026-09-07-scratch-policy-hook.md` (branch-only, force-added; dropped before merge together with this plan). The spec's D2/D3 rule set is the authority; this plan's code implements it verbatim.

**Status:** branch-only document; dropped before merge together with the spec. The contract at `claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json` stays and is what the orchestrator runs.

**Review provenance:** Spec: Codex round 1 (12 findings) and round 2 (7 findings), both folded in, verdict needs-rework each time; proceeded on judgment per the review skill's two-round cap. Plan: see "Review notes" at the end. The hook and suite listed below were smoke-tested in a scratch copy (outside the repo) against the prototype before being written into this plan: 85 of 85 cases pass, fixtures clean up; the two static cases that inspect the template and runner are skipped outside the repo and become live in Task 3. Three defects found by that smoke run are already fixed in the listings (HOME compared before `realpath`, a `VAR=x func` assignment persisting in POSIX `sh`, and two fixture assumptions).

## Global Constraints

- Allow line, verbatim (spec D5): `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}` plus one newline. No-decision: empty stdout, empty stderr, exit 0. The hook never exits non-zero and never prints `deny`.
- Template event, verbatim (spec D1): `"PermissionRequest": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/scratch_policy.py" } ] } ]`, placed after `Notification`. PreToolUse Bash order stays `commit_guard, no_ai_attribution_bash, push_guard, herdr_worktree_guard, rm_guard`; `permissions` and `env` unchanged.
- Runner line, verbatim (spec D9): `sh claude/hooks/scratch-policy.test.sh`, directly after `sh claude/hooks/herdr-orch-contract.test.sh` in `bin/dotfiles-tests`.
- Audit sidecar (spec D6): `<repo dir>/tasks/<task_id>.policy.jsonl`, one JSON line per allow with `v` (1), `ts` (`core.now_iso()`, UTC `YYYY-MM-DDTHH:MM:SSZ`), `event` (`scratch-allow`), `task_id`, `workspace_id`, `tool_use_id`, `command` (first 300 chars). Written only when `HERDR_ENV=1`, `HERDR_WORKSPACE_ID` is valid, and a workspace index resolves; `tasks/` is never created; the path must be absent or a regular file; open flags `O_WRONLY|O_CREAT|O_APPEND|O_NONBLOCK|O_NOFOLLOW`, mode 0o600; the allow is flushed to stdout before logging.
- Files that may change (spec AC8): `claude/hooks/scratch_policy.py` (new), `claude/hooks/scratch-policy.test.sh` (new), `claude/settings.json.tmpl`, `bin/dotfiles-tests`, `CLAUDE.md`, the contract file, and the two branch-only docs. Nothing else: not `rm_guard.py`, not `herdr_orch_core.py`, not `claude-hooks.test.sh`, not `install/**`, not the herdr-orchestration skill, not `account_guard.py`.
- No emojis, no AI attribution, ASCII only in added lines (use ` -- ` not an em dash in CLAUDE.md), LF endings. Commit format `<scope>: <summary>`, imperative, under 75 chars.
- Test baseline (2026-09-07, this machine, base `026f043`): `bin/dotfiles-tests` 23 suites passed, 0 failed; `claude/hooks/claude-hooks.test.sh` 183 PASS lines, 57 of them `rmg:`. `git/hooks/public-safety.test.sh` fails exactly one check (`no tracked planning artifacts`) while the branch-only docs are tracked; that is expected until they are dropped before merge and is not a regression.
- Workflow: `git add -f` is needed only for the docs; every other file is a normal add. Commit after each task.

## File Structure

| File | Responsibility |
|---|---|
| `claude/hooks/scratch-policy.test.sh` | Hermetic suite: fixtures under `mktemp`, payload builder, allow/none assertions, defense-in-depth against `rm_guard.py`, audit sidecar cases, static registration checks. |
| `claude/hooks/scratch_policy.py` | The hook: raw-text refusals, grammar, target resolution and canonicalization, roots, repository exclusions, allow output, audit logging. |
| `claude/settings.json.tmpl` | Registers the `PermissionRequest` event. |
| `bin/dotfiles-tests` | Registers the suite. |
| `CLAUDE.md` | One symlink-targets bullet describing the hook. |
| `claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json` | Verification contract (already committed with this plan). |

Task order: 1 suite (red), 2 hook (green except the two static checks), 3 registration and docs (all green), 4 verification. Task 2 depends on Task 1's fixture layout; Task 3 depends on Task 2's file name.

## Acceptance criteria to contract mapping

| Spec AC | Contract command(s) |
|---|---|
| AC1 registration, PreToolUse order, permissions/env unchanged | `template-registers-permission-request-hook`, `template-permissions-env-unchanged-from-base` |
| AC2 allow output exact | `scratch-rm-allowed-exact-json`, `suite-registered-and-green` |
| AC3 no decision on out-of-scope shapes | `repo-path-rm-no-decision`, `escapes-and-grammar-no-decision`, `substitution-and-quote-shapes-no-decision`, `non-bash-other-event-plan-mode-ignored`, `suite-registered-and-green` |
| AC3b shared-root vs session-root distinction | `suite-registered-and-green` (cases "scratch clone inside the scratchpad", "checkout at the TMPDIR root level", "mktemp regular file") |
| AC4 defense in depth with rm_guard | `rm-guard-still-denies-and-policy-silent` |
| AC5 audit sidecar | `audit-sidecar-written-with-herdr-env`, `fifo-sidecar-does-not-block` |
| AC6 parsing reuse, rm_guard unchanged | `parsing-reuse-and-never-deny`, `owned-files-unchanged-from-base` |
| AC7 suites green, hook compiles | `hook-compiles-executable-shebang`, `suite-registered-and-green`, `claude-hooks-suite-keeps-rmg-57`, `all-suites-except-public-safety-green`, `public-safety-only-expected-failure` |
| AC8 scope and ASCII | `changed-files-within-scope`, `added-lines-ascii-no-attribution` |
| AC9 delivery through reconcile | `links-suite-and-reconcile-delivers-hook` |
| CLAUDE.md bullet (spec D9) | `claude-md-bullet` |
| AC10 live interactive verification | human-verify (Task 4 step 4), not in the contract |

---

### Task 1: The suite (red)

**Files:**
- Create: `claude/hooks/scratch-policy.test.sh`

**Interfaces:**
- Produces: the fixture layout and env contract the hook is tested against. The hook is invoked as `$HOOK` with a JSON payload on stdin and `HOME`, `TMPDIR` (or unset), `CLAUDE_CONFIG_DIR`, and optionally `HERDR_ENV=1 HERDR_WORKSPACE_ID=w1` in the environment. `SCRATCH_POLICY_HOOK` and `RM_GUARD_HOOK` override the hook paths (used only by out-of-repo smoke runs; when set, the two static repo checks are skipped).

- [ ] **Step 1: Write the suite**

Create `claude/hooks/scratch-policy.test.sh` with exactly this content, then `chmod +x` it:

```sh
#!/bin/sh
# scratch-policy.test.sh -- hermetic payload tests for scratch_policy.py.
#
# Every fixture lives under mktemp; the hook is driven with a throwaway
# HOME, a per-case TMPDIR, and (for the audit cases) a throwaway
# CLAUDE_CONFIG_DIR, so nothing touches the real state root and no live
# Claude session is involved. The suite never runs an rm the hook approves.
set -u

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
    "$T2/.git" "$T2/src" "$R/.git" "$H"
: > "$S/build/x"
: > "$S/-x"
: > "$R/file"
: > "$T/file"
ln -s "$R" "$S/link"
# R3 fixtures: entries directly under /tmp named like mktemp's default template.
M3=$(mktemp -d /tmp/tmp.XXXXXXXXXX)
mkdir -p "$M3/child" "$M3/clone/.git"
MF=$(mktemp /tmp/tmp.XXXXXXXXXX)
ML="/tmp/tmp.link$$"
ln -s "$R" "$ML"
trap 'rm -rf "$FIX" "$M3"; rm -f "$MF" "$ML"' EXIT

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
        if [ "$expect" = allow ] && [ "$(cat "$FIX/out")" = "$ALLOW" ]; then
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
elif [ "$(cat "$FIX/fifo.out")" = "$ALLOW" ] && [ ! -s "$FIX/fifo.err" ]; then
    printf 'PASS  audit: reader-less FIFO sidecar does not block the allow\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  audit: reader-less FIFO sidecar does not block the allow (out=%s)\n' "$(cat "$FIX/fifo.out")" >&2; FAIL=$((FAIL + 1))
fi
wait "$fifo_pid" 2>/dev/null

# --- static checks (spec AC1, AC6, AC7) ---
if [ -x "$HOOK" ] && head -n 1 "$HOOK" | grep -qx '#!/usr/bin/env python3' && python3 -m py_compile "$HOOK"; then
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
```

- [ ] **Step 2: Run the suite to verify it is red**

Run: `chmod +x claude/hooks/scratch-policy.test.sh && bash -n claude/hooks/scratch-policy.test.sh && sh claude/hooks/scratch-policy.test.sh 2>&1 | tail -n 3`
Expected: every hook-driven case prints `FAIL` (the hook file does not exist, so `env ... "$HOOK"` exits 127), the three `rm_guard` cases print `PASS`, the summary line reads `3 passed, 84 failed`, exit 1. No `scratch-policy.*` or `tmp.link*` entries remain under `/tmp` afterwards (`ls /tmp | grep -c 'scratch-policy\.\|^tmp\.link'` prints `0`).

- [ ] **Step 3: Commit**

```bash
git add claude/hooks/scratch-policy.test.sh
git commit -m "claude: Add hermetic suite for the scratch policy hook"
```

---

### Task 2: The hook (green)

**Files:**
- Create: `claude/hooks/scratch_policy.py`
- Test: `claude/hooks/scratch-policy.test.sh` (Task 1)

**Interfaces:**
- Consumes: `rm_guard.tokenize(command) -> list[str]`, `rm_guard.split_segments(tokens) -> list[list[str]]`, `rm_guard.expand_home(tok, home) -> str`, `rm_guard.resolve(tok, cwd) -> str` (absolute normpath), `rm_guard.has_glob_chars(name) -> bool`; `core.state_root() -> Path`, `core.valid_workspace_id(ws) -> bool`, `core.valid_task_id(tid) -> bool`, `core.read_index(rd, ws) -> dict | None`, `core.contained(path, root) -> bool`, `core.now_iso() -> str`. All exist unchanged at base `026f043`.
- Produces: the executable `claude/hooks/scratch_policy.py` that Task 3 registers by name.

- [ ] **Step 1: Write the hook**

Create `claude/hooks/scratch_policy.py` with exactly this content, then `chmod +x` it:

```python
#!/usr/bin/env python3
"""PermissionRequest hook: allow scratch-only rm/rmdir by policy.

Fires only when a Bash permission prompt would otherwise be shown (after
rm_guard.py has passed the command and, in auto mode, after the classifier
declined to decide). Prints an allow decision when EVERY segment of the
command is a plain `rm`/`rmdir` invocation and EVERY target canonicalizes
strictly under a throwaway root: the session scratchpad (payload
`scratchpad_dir`), `$TMPDIR` (or `/tmp` when unset), or a `mktemp` entry
directly under `/tmp`. Anything else, and every error, is "no decision":
exit 0 with empty output, so the normal prompt flow continues. Never
denies. See docs/specs/2026-09-07-scratch-policy-hook.md (branch-only)
for the full rule set; the CLAUDE.md bullet is the durable summary.

When HERDR_ENV=1 and HERDR_WORKSPACE_ID resolves to a workspace index,
each allow is audited to <repo dir>/tasks/<task_id>.policy.jsonl. The
allow is printed and flushed before logging; logging failures never
change the decision.
"""

import fnmatch
import json
import os
import shlex
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import herdr_orch_core as core  # noqa: E402  read-only helpers
import rm_guard  # noqa: E402  parsing helpers, unchanged

ALLOW = ('{"hookSpecificOutput":{"hookEventName":"PermissionRequest",'
         '"decision":{"behavior":"allow"}}}')
MODES = ("default", "auto", "acceptEdits")
HEADS = {
    "rm": "rm", "/bin/rm": "rm", "/usr/bin/rm": "rm",
    "rmdir": "rmdir", "/bin/rmdir": "rmdir", "/usr/bin/rmdir": "rmdir",
}
JOINERS = ("&&", ";", "\n")
RAW_REFUSE = "#$`{}"
QUOTE_CHARS = "'\"\\"
WALK_CAP = 20000
COMMAND_MAX = 300
EVENT = "scratch-allow"


def raw_ok(command: str) -> bool:
    """Raw-text refusals (spec D2 step 3) plus a strict shlex parse."""
    if any(c in command for c in RAW_REFUSE):
        return False
    if "**" in command:
        return False
    if any(c in command for c in QUOTE_CHARS) and rm_guard.has_glob_chars(command):
        return False
    try:
        shlex.split(command)
    except ValueError:
        return False
    return True


def operators_ok(tokens: list) -> bool:
    for tok in tokens:
        if tok in ("(", ")"):
            return False
        if "<" in tok or ">" in tok:
            return False
        if tok and all(c in ";&|\n" for c in tok) and tok not in JOINERS:
            return False
    return True


def segment_targets(tokens: list):
    """(kind, recursive, targets) for a plain remove segment, else None."""
    kind = HEADS.get(tokens[0])
    if kind is None:
        return None
    recursive = False
    targets = []
    only_targets = False
    for tok in tokens[1:]:
        if only_targets:
            targets.append(tok)
        elif tok == "--":
            only_targets = True
        elif tok.startswith("-") and tok != "-":
            short = not tok.startswith("--")
            if kind == "rmdir" and (tok in ("-p", "--parents") or (short and "p" in tok[1:])):
                return None
            if kind == "rm" and (tok == "--recursive" or (short and any(c in "rR" for c in tok[1:]))):
                recursive = True
        else:
            targets.append(tok)
    if not targets:
        return None
    return kind, recursive, targets


def discard_root(rp: str, home_real: str) -> bool:
    """True when a candidate root (already a realpath) is `/`, HOME, an
    ancestor of HOME, or shallower than two components."""
    if rp == "/" or rp == home_real or home_real.startswith(rp + "/"):
        return True
    return len([c for c in rp.split("/") if c]) < 2


def compute_roots(payload: dict, home: str):
    """[(realpath, kind)] with kind R1 (scratchpad) or R2 (tmpdir or /tmp)."""
    roots = []
    home_real = os.path.realpath(home)
    sp = payload.get("scratchpad_dir")
    if isinstance(sp, str) and os.path.isabs(sp) and not os.path.islink(sp):
        rp = os.path.realpath(sp)
        if not discard_root(rp, home_real):
            roots.append((rp, "R1"))
    tmpdir = os.environ.get("TMPDIR") or ""
    if tmpdir and os.path.isabs(tmpdir):
        rp = os.path.realpath(tmpdir)
        if not discard_root(rp, home_real):
            roots.append((rp, "R2"))
    else:
        roots.append((os.path.realpath("/tmp"), "R2"))  # R2b: count rule waived
    return roots


def canon(path: str) -> str:
    """realpath of the longest existing ancestor, joined with the rest."""
    existing, rest = path, []
    while existing != "/" and not os.path.lexists(existing):
        existing, tail = os.path.split(existing)
        rest.append(tail)
    real = os.path.realpath(existing)
    return os.path.join(real, *reversed(rest)) if rest else real


def expand_glob(path: str) -> list:
    """Existing paths matching an absolute glob, hidden entries included."""
    results = ["/"]
    for part in [p for p in path.split("/") if p]:
        nxt = []
        for base in results:
            if rm_guard.has_glob_chars(part):
                try:
                    names = sorted(os.listdir(base))
                except OSError:
                    continue
                nxt.extend(os.path.join(base, n) for n in names
                           if fnmatch.fnmatchcase(n, part))
            elif os.path.lexists(os.path.join(base, part)):
                nxt.append(os.path.join(base, part))
        results = nxt
        if not results:
            break
    return results


def find_root(c: str, roots: list, tmpdir_set: bool):
    for root, kind in roots:
        if c.startswith(root + "/"):
            return root, kind
    tmp_real = os.path.realpath("/tmp")
    if tmpdir_set and c.startswith(tmp_real + "/tmp."):
        entry = os.path.join(tmp_real, c[len(tmp_real) + 1:].split("/")[0])
        try:
            st = os.lstat(entry)
        except OSError:
            return None
        if stat.S_ISLNK(st.st_mode) or not (stat.S_ISDIR(st.st_mode) or stat.S_ISREG(st.st_mode)):
            return None
        return entry, "R3"
    return None


def git_between(c: str, root: str) -> bool:
    p = c
    while p.startswith(root):
        if os.path.lexists(os.path.join(p, ".git")):
            return True
        if p == root:
            return False
        p = os.path.dirname(p)
    return False


def subtree_has_git(path: str) -> bool:
    seen = 0
    for _, dirnames, filenames in os.walk(path, followlinks=False):
        if ".git" in dirnames or ".git" in filenames:
            return True
        seen += len(dirnames) + len(filenames)
        if seen > WALK_CAP:
            return True  # beyond the cap: no decision
    return False


def target_in_scope(tok: str, cwd: str, home: str, roots: list, recursive: bool,
                    tmpdir_set: bool) -> bool:
    expanded = rm_guard.expand_home(tok, home)
    if ".." in expanded.split("/"):
        return False
    resolved = rm_guard.resolve(expanded, cwd)
    parts = resolved.split("/")
    if any(rm_guard.has_glob_chars(p) and p.startswith(".") for p in parts):
        return False
    matches = expand_glob(resolved) if rm_guard.has_glob_chars(resolved) else [resolved]
    if not matches:
        matches = [resolved]
    for m in matches:
        c = canon(m)
        found = find_root(c, roots, tmpdir_set)
        if found is None:
            return False
        root, kind = found
        if os.path.basename(c) == ".git":
            return False
        if kind == "R2":
            if git_between(c, root):
                return False
            if recursive and os.path.isdir(c) and not os.path.islink(c) and subtree_has_git(c):
                return False
    return True


def decide(payload: dict) -> bool:
    if not isinstance(payload, dict):
        return False
    if payload.get("hook_event_name") != "PermissionRequest" or payload.get("tool_name") != "Bash":
        return False
    mode = payload.get("permission_mode")
    if mode is not None and mode not in MODES:
        return False
    tool_input = payload.get("tool_input")
    command = tool_input.get("command") if isinstance(tool_input, dict) else None
    if not isinstance(command, str) or not command.strip():
        return False
    if not raw_ok(command):
        return False
    tokens = rm_guard.tokenize(command)
    if not operators_ok(tokens):
        return False
    segments = rm_guard.split_segments(tokens)
    if not segments:
        return False
    cwd = payload.get("cwd") if isinstance(payload.get("cwd"), str) else os.getcwd()
    home = os.environ.get("HOME", os.path.expanduser("~"))
    roots = compute_roots(payload, home)
    tmpdir_set = bool(os.environ.get("TMPDIR")) and os.path.isabs(os.environ.get("TMPDIR", ""))
    for tokens in segments:
        parsed = segment_targets(tokens)
        if parsed is None:
            return False
        _, recursive, targets = parsed
        for tok in targets:
            if not target_in_scope(tok, cwd, home, roots, recursive, tmpdir_set):
                return False
    return True


def log_allow(payload: dict, command: str) -> None:
    if os.environ.get("HERDR_ENV") != "1":
        return
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return
    root = core.state_root()
    for idx in sorted(root.glob(f"*/workspaces/{ws}.json")):
        rd = idx.parent.parent
        index = core.read_index(rd, ws)
        if not index:
            continue
        task_id = index.get("task_id")
        if not isinstance(task_id, str) or not core.valid_task_id(task_id):
            return
        tasks = rd / "tasks"
        p = tasks / f"{task_id}.policy.jsonl"
        if not tasks.is_dir() or not core.contained(p, root):
            return
        try:
            st = os.lstat(p)
        except FileNotFoundError:
            st = None
        if st is not None and not stat.S_ISREG(st.st_mode):
            return
        rec = {"v": 1, "ts": core.now_iso(), "event": EVENT, "task_id": task_id,
               "workspace_id": ws, "tool_use_id": payload.get("tool_use_id"),
               "command": command[:COMMAND_MAX]}
        flags = (os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NONBLOCK
                 | getattr(os, "O_NOFOLLOW", 0))
        fd = os.open(p, flags, 0o600)
        try:
            os.write(fd, (json.dumps(rec, separators=(",", ":")) + "\n").encode())
        finally:
            os.close(fd)
        return


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    try:
        allow = decide(payload)
    except Exception:  # noqa: BLE001 -- any failure is "no decision"
        return 0
    if not allow:
        return 0
    sys.stdout.write(ALLOW + "\n")
    sys.stdout.flush()
    try:
        log_allow(payload, payload["tool_input"]["command"])
    except Exception:  # noqa: BLE001 -- logging never changes the decision
        pass
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open toward the normal prompt flow
        sys.exit(0)
```

How the listing maps to the spec, for the reviewer: `raw_ok` is D2 step 3's raw-text refusals; `operators_ok` is the operator and redirection rule of steps 3 and 4; `segment_targets` is the executable identity, `--`, and flag rule of steps 3 and 4 (`rmdir -p` refused, `rm -r` noted for step 7); `compute_roots`/`discard_root` are D3 R1, R2a, R2b; `find_root` adds the lazy R3 match (entry directly under `/tmp` named `tmp.*`, not a symlink, dir or regular file); `canon` is D3's canonicalization; `expand_glob` is step 6 (hidden entries included, `**` already refused); `target_in_scope` chains steps 5 to 7 (`..` refusal, dotglob, containment, `.git` basename, R2-only ancestor and subtree checks with the 20000-entry cap); `log_allow` is D6.

- [ ] **Step 2: Run the suite to verify it is green except the two static repo checks**

Run: `chmod +x claude/hooks/scratch_policy.py && python3 -m py_compile claude/hooks/scratch_policy.py && sh claude/hooks/scratch-policy.test.sh 2>&1 | grep -v '^PASS'`
Expected: exactly two `FAIL` lines, `static: template registers exactly this hook under PermissionRequest` and `static: suite is registered in bin/dotfiles-tests`, and the summary `85 passed, 2 failed`. Any other `FAIL` line means the listing was not copied exactly; diff against this plan before changing logic.

- [ ] **Step 3: Confirm rm_guard.py is untouched and the hook never emits a deny**

Run: `git diff --quiet origin/main -- claude/hooks/rm_guard.py claude/hooks/herdr_orch_core.py && ! grep -q '"deny"' claude/hooks/scratch_policy.py && echo ok`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add claude/hooks/scratch_policy.py
git commit -m "claude: Add scratch policy PermissionRequest hook for rm cleanup"
```

---

### Task 3: Registration, runner, CLAUDE.md (all green)

**Files:**
- Modify: `claude/settings.json.tmpl` (the `hooks` object, after the `Notification` entry, around line 255)
- Modify: `bin/dotfiles-tests` (the `SUITES` list, after `sh claude/hooks/herdr-orch-contract.test.sh`, around line 32)
- Modify: `CLAUDE.md` (the symlink-targets list, directly after the `claude/hooks/herdr_stop_gate.py` bullet)

**Interfaces:**
- Consumes: the file name `claude/hooks/scratch_policy.py` (Task 2) and the suite name `claude/hooks/scratch-policy.test.sh` (Task 1).
- Produces: the template event that `reconcile_claude_settings_file` copies into both account config dirs and that `claude-hooks.test.sh`'s template-derived drift check now expects live.

- [ ] **Step 1: Register the event in the template**

In `claude/settings.json.tmpl`, change the end of the `hooks` object from

```json
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "~/.claude/hooks/herdr_worker_status.py" } ] }
    ]
  },
```

to

```json
    "Notification": [
      { "matcher": "*", "hooks": [ { "type": "command", "command": "~/.claude/hooks/herdr_worker_status.py" } ] }
    ],
    "PermissionRequest": [
      { "matcher": "Bash", "hooks": [ { "type": "command", "command": "~/.claude/hooks/scratch_policy.py" } ] }
    ]
  },
```

Run: `python3 -c "import json; json.load(open('claude/settings.json.tmpl'))" && echo valid`
Expected: `valid`.

- [ ] **Step 2: Register the suite in the runner**

In `bin/dotfiles-tests`, directly after the line `sh claude/hooks/herdr-orch-contract.test.sh`, add the line:

```
sh claude/hooks/scratch-policy.test.sh
```

Run: `bash -n bin/dotfiles-tests && bash bin/dotfiles-tests --list | grep -n scratch-policy`
Expected: one line, `11:sh claude/hooks/scratch-policy.test.sh`.

- [ ] **Step 3: Add the CLAUDE.md bullet**

In `CLAUDE.md`, directly after the bullet that starts with `` - `claude/hooks/herdr_stop_gate.py` ``, add this bullet (one line, ASCII, ` -- ` not an em dash):

```
- `claude/hooks/scratch_policy.py` -- PermissionRequest hook (Bash matcher) that answers a residual permission prompt with `allow` only when every segment is a plain `rm`/`rmdir` whose every target canonicalizes strictly under a throwaway root (the payload's `scratchpad_dir`, `$TMPDIR` or `/tmp` when it is unset, or a `tmp.*` mktemp entry directly under `/tmp`); wrappers, pipes, redirections, `..`, symlink escapes, globs through symlinks, `.git` targets, and checkouts at or under a shared temp root all yield no decision so the prompt proceeds; it never denies (`rm_guard.py` runs first as PreToolUse and its block suppresses the event); each allow is audited to `tasks/<task_id>.policy.jsonl` under the herdr state root when `HERDR_ENV=1` (registered in `settings.json.tmpl`; tested by `scratch-policy.test.sh`; live registration drift-checked by `claude-hooks.test.sh`)
```

Run: `LC_ALL=C grep -n '[^ -~]' CLAUDE.md | grep -c scratch_policy`
Expected: `0` (the new line is pure ASCII; other lines in the file may carry non-ASCII and are not part of this change).

- [ ] **Step 4: Run the suite and the neighbouring suites**

Run: `sh claude/hooks/scratch-policy.test.sh 2>&1 | tail -n 1 && HOME="$(mktemp -d)" sh claude/hooks/claude-hooks.test.sh 2>/dev/null | grep -c '^PASS  rmg: ' && sh install/claude-links.test.sh 2>&1 | tail -n 1`
Expected: `87 passed, 0 failed`, then `57`, then `26 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add claude/settings.json.tmpl bin/dotfiles-tests CLAUDE.md
git commit -m "claude: Register the scratch policy hook and its suite"
```

---

### Task 4: Verification

**Files:**
- Read: `claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json` (committed with this plan; do not edit unless a command is wrong, and then say so in the commit)

- [ ] **Step 1: Run the full runner**

Run: `bash bin/dotfiles-tests 2>&1 | tail -n 3`
Expected: `24 suites passed, 0 failed` once the branch-only docs are dropped; while they are still tracked, expect `23 suites passed, 1 failed` with `git/hooks/public-safety.test.sh` as the only failing suite and `FAIL  no tracked planning artifacts` as its only failing check (verify with `sh git/hooks/public-safety.test.sh 2>&1 | grep '^FAIL'`). Any other failure is a regression to fix before continuing.

- [ ] **Step 2: Run the contract**

Run:

```bash
python3 ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/herdr_orch_core.py verify-contract \
  --repo-slug git-personal-taloncjones-dotfiles-6c3f6099 \
  --task-id td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat \
  --worktree "$(git rev-parse --show-toplevel)" \
  --contract claude/contracts/td-2026-09-06-add-a-worker-side-permission-policy-hook-for-scrat-contract.json \
  --allow-unpinned
```

Expected: every command prints `ok <name> exit=0` and the run ends with `PASS 21 commands`. The first failing command names the acceptance criterion to revisit (see the mapping table).

- [ ] **Step 3: Reconcile this machine (optional, machine state)**

Only if the human asked for it in this session: run `update` (or `install/common/claude-links.sh`'s reconcile through the usual install path) so both account config dirs pick up the `PermissionRequest` event; then `sh claude/hooks/claude-hooks.test.sh 2>&1 | grep 'settings:'` shows `registers every template hook` passing for each existing config dir. Do not do this unasked: settings.json is machine-local state.

- [ ] **Step 4: Human-verify AC10 and record it**

On a reconciled machine, in a throwaway git repo, start `claude --permission-mode default --debug`, present the GateGuard facts, then:
1. Create `<scratchpad>/probe` and run `rm -f <scratchpad>/probe`: no dialog, the file is gone, the debug log shows `executePermissionRequestHooks called for tool: Bash`.
2. With `HERDR_ENV=1` and a resolving `HERDR_WORKSPACE_ID` exported into that session, repeat: one `scratch-allow` line lands in `tasks/<task_id>.policy.jsonl`, proving `scratchpad_dir` reaches the hook interactively.
3. Run `rm -f ./tracked-file` in the repo: the permission dialog appears; no hook error or "invalid JSON" line in the debug log.
Record all three outcomes in the PR description under "AC10 live verification". A failed or skipped item blocks the PR.

- [ ] **Step 5: Drop the branch-only docs before review hand-off**

Run: `git rm -q docs/specs/2026-09-07-scratch-policy-hook.md docs/plans/2026-09-07-scratch-policy-hook.md && git commit -m "docs: Drop branch-only scratch policy spec and plan before review"`
Expected: `sh git/hooks/public-safety.test.sh` now passes in full and `bash bin/dotfiles-tests` reports `24 suites passed, 0 failed`. The contract's `changed-files-within-scope` command ignores `docs/` either way.

## Review notes

Filled in after `codex-plan-review`; see the commit that follows this plan's first commit.
