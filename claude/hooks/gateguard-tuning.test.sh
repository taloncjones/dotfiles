#!/bin/sh
# gateguard-tuning.test.sh -- prove the two GateGuard knobs in the settings
# template do what the change relies on: the once-per-session routine-Bash
# gate and the first-touch Edit/Write gate are off, while the destructive
# Bash gate (rm -rf, git reset --hard, ...) still denies. Controls run the
# same payloads with the knobs cleared and must show the gate; a control
# that passes without the knobs is a suite bug.
#
# The exemption glob in the template is absolute (/**) because ECC 2.2.2
# scopes a relative glob to the project root: an unqualified ** only matches
# targets under it. The Edit/Write cases pin CLAUDE_PROJECT_DIR to /repo and
# check both a target contained under it and one outside it.
#
# Bash cases run ECC's real pre-Bash dispatcher chain (pre-bash-dispatcher.js
# -> bash-hook-dispatcher.js's runPreBash, which runs block-no-verify then
# auto-tmux-dev then gateguard-fact-force under standard/strict, with
# early-exit on a non-zero exit) exactly as hooks.json wires the Bash
# PreToolUse matcher. Edit/Write cases run gateguard-fact-force.js through
# run-with-flags.js with the pre:edit-write id, exactly as hooks.json wires
# the Write/Edit/MultiEdit matcher. Both run against a fake HOME and a fresh
# mktemp state dir with its own session id. GateGuard's only evidence is a
# per-session marker file under GATEGUARD_STATE_DIR; isolating it per case
# means no case can see another's "already checked" marker. The hook's
# stdout is captured to a file before assertion so an interrupted run leaves
# an attributable artifact, not a guess. The real ~/.gateguard is never
# touched.
#
# Knobs: ECC_PLUGIN_ROOT overrides ECC root resolution.
#        ECC_HOOK_TEST_REQUIRE_ECC=1 turns the no-ECC SKIP into a FAIL.

set -u

TMPL=claude/settings.json.tmpl
if [ ! -f "$TMPL" ]; then
    echo "FAIL: $TMPL not found (run from repo root)" >&2
    exit 2
fi

require_ecc="${ECC_HOOK_TEST_REQUIRE_ECC:-0}"
missing() {
    if [ "$require_ecc" = 1 ]; then
        echo "FAIL: $1" >&2
        exit 1
    fi
    echo "SKIP: $1"
    exit 0
}

if ! command -v node >/dev/null 2>&1; then
    missing "node not installed; ECC hooks are node scripts"
fi
if ! command -v python3 >/dev/null 2>&1; then
    missing "python3 not installed; assertions need it"
fi

ECC_ROOT="${ECC_PLUGIN_ROOT:-}"
if [ -z "$ECC_ROOT" ]; then
    for cand in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/ecc" \
                "$HOME/.claude/plugins/marketplaces/ecc" \
                "$HOME/.claude-work/plugins/marketplaces/ecc"; do
        if [ -f "$cand/scripts/hooks/gateguard-fact-force.js" ]; then
            ECC_ROOT="$cand"
            break
        fi
    done
fi
if [ ! -f "$ECC_ROOT/scripts/hooks/gateguard-fact-force.js" ] || [ ! -f "$ECC_ROOT/scripts/hooks/run-with-flags.js" ] \
        || [ ! -f "$ECC_ROOT/scripts/hooks/pre-bash-dispatcher.js" ]; then
    missing "ECC GateGuard hook not installed (looked under the Claude config dirs)"
fi

ROUTINE_OFF=$(python3 -c 'import json;print((json.load(open("claude/settings.json.tmpl")).get("env") or {}).get("GATEGUARD_BASH_ROUTINE_DISABLED",""))')
EXEMPT_GLOBS=$(python3 -c 'import json;print((json.load(open("claude/settings.json.tmpl")).get("env") or {}).get("GATEGUARD_EXEMPT_GLOBS",""))')

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/gateguard-tuning.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# decision <casedir> <rc>: "deny" when the hook emitted a deny; "allow" when
# it exited 0 with empty stdout or JSON carrying no deny (GateGuard passes
# an allowed call through by echoing the input or nothing); "error:<why>"
# for a non-zero exit or non-JSON stdout, so a crashed hook never reads as
# an allow.
decision() {
    python3 - "$1/out" "$2" <<'PY'
import json, sys
raw = open(sys.argv[1]).read().strip()
rc = sys.argv[2]
if rc != "0":
    print("error:exit-" + rc); sys.exit(0)
if not raw:
    print("allow"); sys.exit(0)
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("error:non-json-stdout"); sys.exit(0)
print((d.get("hookSpecificOutput") or {}).get("permissionDecision") or "allow")
PY
}

# run_case <hook-id> <envmode> <payload-json>: every call allocates its own
# mktemp case dir (state dir, session id, out/err files all derive from it),
# so cases stay isolated even though the caller runs this inside command
# substitution, where a counter increment would be lost. "template" applies
# the two template values, "none" clears them. Files live until the trap.
run_case() {
    cd_="$(mktemp -d "$TMP/case.XXXXXX")"
    mkdir -p "$cd_/state"
    sid="gateguard-tuning-$(basename "$cd_")"
    if [ "$2" = template ]; then
        knobs="GATEGUARD_BASH_ROUTINE_DISABLED=$ROUTINE_OFF GATEGUARD_EXEMPT_GLOBS=$EXEMPT_GLOBS"
    else
        knobs="GATEGUARD_BASH_ROUTINE_DISABLED= GATEGUARD_EXEMPT_GLOBS="
    fi
    printf '%s' "$3" | (
        set -f  # $knobs is word-split on purpose; ** must not glob
        cd "$TMP" && env -i PATH="$PATH" HOME="$TMP/home" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            GATEGUARD_STATE_DIR="$cd_/state" CLAUDE_SESSION_ID="$sid" CLAUDE_PROJECT_DIR=/repo \
            $knobs \
            node "$ECC_ROOT/scripts/hooks/run-with-flags.js" "$1" scripts/hooks/gateguard-fact-force.js standard,strict
    ) >"$cd_/out" 2>"$cd_/err"
    decision "$cd_" "$?"
}

# run_case_bash <envmode> <payload-json>: same isolation as run_case, but
# drives ECC's real pre-Bash dispatcher (block-no-verify, auto-tmux-dev, then
# gateguard-fact-force under standard/strict) instead of calling
# gateguard-fact-force.js directly, so a dispatcher-wiring regression in any
# of those hooks would also be caught.
run_case_bash() {
    cd_="$(mktemp -d "$TMP/case.XXXXXX")"
    mkdir -p "$cd_/state"
    sid="gateguard-tuning-$(basename "$cd_")"
    if [ "$1" = template ]; then
        knobs="GATEGUARD_BASH_ROUTINE_DISABLED=$ROUTINE_OFF GATEGUARD_EXEMPT_GLOBS=$EXEMPT_GLOBS"
    else
        knobs="GATEGUARD_BASH_ROUTINE_DISABLED= GATEGUARD_EXEMPT_GLOBS="
    fi
    printf '%s' "$2" | (
        set -f  # $knobs is word-split on purpose; ** must not glob
        cd "$TMP" && env -i PATH="$PATH" HOME="$TMP/home" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            GATEGUARD_STATE_DIR="$cd_/state" CLAUDE_SESSION_ID="$sid" \
            $knobs \
            node "$ECC_ROOT/scripts/hooks/pre-bash-dispatcher.js"
    ) >"$cd_/out" 2>"$cd_/err"
    decision "$cd_" "$?"
}

expect() {
    # expect <label> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want $2, got $3)"; fi
}

EDIT_ID=pre:edit-write:gateguard-fact-force
ROUTINE='{"tool_name":"Bash","tool_input":{"command":"cat README.md"}}'
RMRF='{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/scratch/build"}}'
RESET='{"tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD~1"}}'
EDIT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/src/module.py","old_string":"a","new_string":"b"},"cwd":"/repo"}'
WRITE='{"tool_name":"Write","tool_input":{"file_path":"/repo/docs/new.md","content":"x"},"cwd":"/repo"}'
EDIT_OUTSIDE='{"tool_name":"Edit","tool_input":{"file_path":"/elsewhere/notes.md","old_string":"a","new_string":"b"},"cwd":"/repo"}'

expect "template env: routine Bash is not gated"            allow "$(run_case_bash template "$ROUTINE")"
expect "control: without the knobs routine Bash is gated"    deny  "$(run_case_bash none "$ROUTINE")"
expect "template env: rm -rf still denied (destructive gate)" deny  "$(run_case_bash template "$RMRF")"
expect "template env: git reset --hard still denied"         deny  "$(run_case_bash template "$RESET")"
expect "template env: first-touch Edit is not gated"         allow "$(run_case "$EDIT_ID" template "$EDIT")"
expect "template env: first-touch Write is not gated"        allow "$(run_case "$EDIT_ID" template "$WRITE")"
expect "control: without the knobs first-touch Edit is gated" deny  "$(run_case "$EDIT_ID" none "$EDIT")"
expect "template env: first-touch Edit outside the project dir is not gated" allow "$(run_case "$EDIT_ID" template "$EDIT_OUTSIDE")"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
