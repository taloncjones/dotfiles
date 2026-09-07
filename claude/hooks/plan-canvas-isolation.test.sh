#!/bin/sh
# plan-canvas-isolation.test.sh -- prove the two ECC Plan Canvas hooks are
# inert under the settings template env, and live without it.
#
# ECC 2.2.1 resolves Plan Canvas state to ~/.claude/plan-canvas regardless of
# CLAUDE_CONFIG_DIR, so on a dual-account machine the work account would see
# personal Canvas sessions (SessionStart) and receive personal feedback (Stop).
# The template excludes both hooks via ECC_DISABLED_HOOKS. This suite drives
# the INSTALLED hook scripts against a fake home under mktemp; the real
# ~/.claude*/plan-canvas is never read or written. It proves the hooks are
# switched off, not that Canvas state is account-scoped.
#
# Knobs: ECC_PLUGIN_ROOT overrides ECC root resolution.
#        PLAN_CANVAS_TEST_REQUIRE_ECC=1 turns the no-ECC SKIP into a FAIL.

set -u

TMPL=claude/settings.json.tmpl
if [ ! -f "$TMPL" ]; then
    echo "FAIL: $TMPL not found (run from repo root)" >&2
    exit 2
fi

require_ecc="${PLAN_CANVAS_TEST_REQUIRE_ECC:-0}"
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
    missing "python3 not installed; fixture and assertions need it"
fi

ECC_ROOT="${ECC_PLUGIN_ROOT:-}"
if [ -z "$ECC_ROOT" ]; then
    for cand in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/marketplaces/ecc" \
                "$HOME/.claude/plugins/marketplaces/ecc" \
                "$HOME/.claude-work/plugins/marketplaces/ecc"; do
        if [ -f "$cand/scripts/hooks/run-with-flags.js" ]; then
            ECC_ROOT="$cand"
            break
        fi
    done
fi
if [ ! -f "$ECC_ROOT/scripts/hooks/run-with-flags.js" ]; then
    missing "ECC plugin scripts not installed (looked under the Claude config dirs)"
fi
for f in scripts/hooks/plan-canvas-pending.js scripts/hooks/plan-canvas-sessions.js scripts/hooks/check-hook-enabled.js; do
    if [ ! -f "$ECC_ROOT/$f" ]; then
        echo "FAIL: ECC layout changed: $ECC_ROOT/$f missing" >&2
        exit 1
    fi
done

DISABLED="$(python3 -c 'import json; print(json.load(open("claude/settings.json.tmpl")).get("env", {}).get("ECC_DISABLED_HOOKS", ""))')"

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/plan-canvas-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# Fixture: two open Canvas sessions with undelivered feedback, one artifact
# per fixture repo. Text markers are what the assertions grep for. No
# server.json, so the Stop hook can never contact a real Canvas server.
mkdir -p "$TMP/repo-a/docs" "$TMP/repo-b/docs" "$TMP/repo-c" "$TMP/personal" "$TMP/work"
: > "$TMP/repo-a/docs/plan.md"
: > "$TMP/repo-b/docs/plan.md"
python3 - "$TMP" <<'PY'
import json, sys
t = sys.argv[1]
state = {"sessions": {
    "aaa": {"key": "aaa", "file": t + "/repo-a/docs/plan.md", "status": "open",
            "pendingFeedback": [{"id": "fb-1", "kind": "chat", "text": "FIXTURE-FEEDBACK-A"}],
            "updatedAt": "2026-09-06T00:00:00.000Z"},
    "bbb": {"key": "bbb", "file": t + "/repo-b/docs/plan.md", "status": "open",
            "pendingFeedback": [{"id": "fb-2", "kind": "chat", "text": "FIXTURE-FEEDBACK-B"}],
            "updatedAt": "2026-09-06T00:00:01.000Z"}}}
with open(t + "/fixture.json", "w") as fh:
    json.dump(state, fh, indent=2)
PY

# fresh_home <name>: a new fake HOME holding a pristine copy of the fixture.
# Every scenario gets its own so the enabled control's drain cannot leak.
fresh_home() {
    h="$TMP/$1/home"
    mkdir -p "$h/.claude/plan-canvas"
    cp "$TMP/fixture.json" "$h/.claude/plan-canvas/sessions.json"
    printf '%s' "$h"
}

# run_hook <event> <home> <cfgdir> <cwd> <disabled-value>
# Runs the installed hook through ECC's flag gate exactly as hooks.json does.
# Profile and enabled flag are pinned so machine-level ECC settings cannot
# produce false results. stdout -> $TMP/out, stderr -> $TMP/err.
run_hook() {
    case "$1" in
        stop)
            payload="$(printf '{"hook_event_name":"Stop","cwd":"%s","stop_hook_active":false}' "$4")"
            hook_id=stop:plan-canvas-pending
            script=scripts/hooks/plan-canvas-pending.js
            profiles=minimal,standard,strict
            ;;
        start)
            payload='{"hook_event_name":"SessionStart","source":"startup"}'
            hook_id=session-start:plan-canvas-sessions
            script=scripts/hooks/plan-canvas-sessions.js
            profiles=standard,strict
            ;;
    esac
    printf '%s' "$payload" | (
        cd "$4" && HOME="$2" CLAUDE_CONFIG_DIR="$3" CLAUDE_PLUGIN_ROOT="$ECC_ROOT" \
            ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            ECC_DISABLED_HOOKS="$5" ECC_PLAN_CANVAS_STATE_DIR= \
            node "$ECC_ROOT/scripts/hooks/run-with-flags.js" "$hook_id" "$script" "$profiles"
    ) >"$TMP/out" 2>"$TMP/err"
    printf '%s' "$payload" >"$TMP/payload"
}

# silent_case <label> <event> <cwd> <disabled-value>
# Under both fake accounts: output is the untouched payload and the fixture
# state file is byte-identical afterwards.
silent_case() {
    ok=1
    for acct in personal work; do
        h="$(fresh_home "$acct-$PASS-$FAIL-$2")"
        run_hook "$2" "$h" "$TMP/$acct" "$3" "$4"
        if ! cmp -s "$TMP/out" "$TMP/payload"; then ok=0; fi
        if grep -q 'FIXTURE-FEEDBACK\|"decision"\|PlanCanvas' "$TMP/out"; then ok=0; fi
        if ! cmp -s "$h/.claude/plan-canvas/sessions.json" "$TMP/fixture.json"; then ok=0; fi
    done
    if [ "$ok" = 1 ]; then pass "$1"; else fail "$1"; fi
}

# --- hooks inert under the template env ---
silent_case "stop: pending personal feedback in this repo is not delivered" \
    stop "$TMP/repo-a" "$DISABLED"
silent_case "stop: concurrent pending feedback in the other reviewed repo is not delivered" \
    stop "$TMP/repo-b" "$DISABLED"
silent_case "stop: unrelated repo stays silent with the exclusion" \
    stop "$TMP/repo-c" "$DISABLED"
silent_case "stop: unrelated repo stays silent without the exclusion (hook cwd scoping)" \
    stop "$TMP/repo-c" ""
silent_case "session-start: open personal sessions are not enumerated" \
    start "$TMP/repo-a" "$DISABLED"

# --- falsifiable controls: same fixture, no exclusion ---
h="$(fresh_home control-stop)"
run_hook stop "$h" "$TMP/work" "$TMP/repo-a" ""
if grep -q '"decision":"block"' "$TMP/out" && grep -q 'FIXTURE-FEEDBACK-A' "$TMP/out" \
        && ! grep -q 'FIXTURE-FEEDBACK-B' "$TMP/out" \
        && ! cmp -s "$h/.claude/plan-canvas/sessions.json" "$TMP/fixture.json"; then
    pass "control: without the exclusion Stop blocks with this repo's feedback only"
else
    fail "control: without the exclusion Stop blocks with this repo's feedback only"
fi
h="$(fresh_home control-start)"
run_hook start "$h" "$TMP/work" "$TMP/repo-a" ""
if grep -q 'PlanCanvas' "$TMP/out" && grep -q 'repo-a/docs/plan.md' "$TMP/out" \
        && grep -q 'repo-b/docs/plan.md' "$TMP/out"; then
    pass "control: without the exclusion SessionStart enumerates every open session"
else
    fail "control: without the exclusion SessionStart enumerates every open session"
fi

# --- collateral: only the two Canvas ids are off under the template env ---
# check-hook-enabled exercises ECC's flag gate (the exclusion short-circuits
# before the profile check), not the hooks.json wiring. With no profile CSV
# the gate falls back to standard,strict, so the "yes" cases prove the ids
# are NOT EXCLUDED under the template env; profile membership is not tested.
enabled_is() {
    got="$(CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
        ECC_DISABLED_HOOKS="$DISABLED" node "$ECC_ROOT/scripts/hooks/check-hook-enabled.js" "$1" 2>/dev/null)"
    [ "$got" = "$2" ]
}
ok=1
for id in stop:plan-canvas-pending session-start:plan-canvas-sessions; do
    enabled_is "$id" no || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: both Plan Canvas ids answer no"; else fail "flag gate: both Plan Canvas ids answer no"; fi
ok=1
for id in stop:session-end pre:bash:dispatcher post:dispatcher:sync; do
    enabled_is "$id" yes || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: TDD and dispatcher hook ids are not excluded"; else fail "flag gate: TDD and dispatcher hook ids are not excluded"; fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
