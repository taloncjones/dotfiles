#!/bin/sh
# ecc-hook-isolation.test.sh -- prove the ECC hooks that key state on
# ~/.claude cannot cross accounts under the settings template env.
#
# ECC 2.2.1 resolves several hook state paths through os.homedir() or
# $HOME/.claude and never consults CLAUDE_CONFIG_DIR, so on a dual-account
# machine (~/.claude personal, ~/.claude-work work, one $HOME) a work session
# would write into, or read from, the personal dir. The template handles the
# class two ways, and this suite proves both:
#   excluded -- ids with no scoping knob are in ECC_DISABLED_HOOKS:
#               post:bash:command-log-audit, post:bash:command-log-cost,
#               post:skill:track, pre:mcp-health-check, post:mcp-health-check
#               (the two Plan Canvas ids have their own suite);
#   scoped   -- ids that read ECC_AGENT_DATA_HOME get it resolved to the
#               account's config dir by the settings reconcile:
#               stop:cost-tracker, post:session-activity-tracker,
#               stop:session-end, pre:compact, session:start.
# Every hook is driven through ECC's own flag gate (run-with-flags.js or the
# Bash dispatcher) against a fake $HOME under mktemp holding fake .claude and
# .claude-work dirs. The real ~/.claude* and the ECC clone are never written.
# Controls run the same fixtures with the template env removed and must show
# the leak; a control that passes without the fix is a suite bug.
#
# Re-check after an ECC upgrade: grep the clone's scripts/hooks for
# os.homedir(), process.env.HOME, and getClaudeDir/getSessionsDir, map each
# hit to its hook id in hooks/hooks.json and the dispatchers, and add a row.
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
for f in scripts/hooks/check-hook-enabled.js scripts/hooks/bash-hook-dispatcher.js \
         scripts/hooks/post-bash-command-log.js scripts/hooks/skill-run-tracker.js \
         scripts/hooks/cost-tracker.js scripts/hooks/session-activity-tracker.js \
         scripts/hooks/session-end.js scripts/hooks/pre-compact.js \
         scripts/hooks/session-start.js scripts/hooks/mcp-health-check.js; do
    if [ ! -f "$ECC_ROOT/$f" ]; then
        echo "FAIL: ECC layout changed: $ECC_ROOT/$f missing" >&2
        exit 1
    fi
done

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/ecc-hook-isolation.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo"
N=0

# fresh_home <label>: a new fake HOME with empty personal and work config
# dirs. Every scenario gets its own so one hook's writes cannot leak into
# another scenario's assertions.
fresh_home() {
    N=$((N + 1))
    h="$TMP/$1-$N/home"
    mkdir -p "$h/.claude" "$h/.claude-work"
    printf '%s' "$h"
}

# template_env <cfgdir>: the template env as KEY=VALUE lines with the
# config-dir token resolved for <cfgdir>, exactly as reconcile does. Only the
# ECC keys are exported into hook runs; model and telemetry keys are inert.
template_env() {
    python3 - "$TMPL" "$1" <<'PY'
import json, sys
env = json.load(open(sys.argv[1])).get("env") or {}
for k, v in env.items():
    if k.startswith("ECC_") and isinstance(v, str):
        print(k + "=" + v.replace("{{CLAUDE_CONFIG_DIR}}", sys.argv[2]))
PY
}

# env_args <cfgdir> <envmode>: env(1) assignments for a hook run. "template"
# applies the resolved template env; "none" is the control (nothing set, and
# the knobs are explicitly cleared so the hooks fall back to ~/.claude).
env_args() {
    if [ "$2" = template ]; then
        template_env "$1"
    else
        printf 'ECC_DISABLED_HOOKS=\nECC_AGENT_DATA_HOME=\n'
    fi
}

# run_gated <cfgdir> <home> <cwd> <envmode> <id> <script> <profiles>
# Runs one hook through ECC's flag gate exactly as hooks.json does, reading
# $TMP/payload from stdin. Profile and enabled flag are pinned so
# machine-level ECC settings cannot produce false results.
# stdout -> $TMP/out, stderr -> $TMP/err.
run_gated() {
    env_args "$1" "$4" >"$TMP/envfile"
    (
        cd "$3" && env -i PATH="$PATH" HOME="$2" CLAUDE_CONFIG_DIR="$1" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            CLAUDE_SESSION_ID=fixture-session \
            $(cat "$TMP/envfile") \
            node "$ECC_ROOT/scripts/hooks/run-with-flags.js" "$5" "$6" "$7"
    ) <"$TMP/payload" >"$TMP/out" 2>"$TMP/err"
}

# run_bash_dispatcher <cfgdir> <home> <cwd> <envmode>: the PostToolUse Bash
# dispatcher, which hosts the two command-log ids.
run_bash_dispatcher() {
    env_args "$1" "$4" >"$TMP/envfile"
    (
        cd "$3" && env -i PATH="$PATH" HOME="$2" CLAUDE_CONFIG_DIR="$1" \
            CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
            $(cat "$TMP/envfile") \
            node "$ECC_ROOT/scripts/hooks/bash-hook-dispatcher.js" post
    ) <"$TMP/payload" >"$TMP/out" 2>"$TMP/err"
}

# files_under <dir>: regular files below <dir>, relative, sorted; empty when
# the dir does not exist.
files_under() {
    [ -d "$1" ] || return 0
    (cd "$1" && find . -type f | sort)
}

# --- excluded hooks: inert under the template env, live without it ---

printf '{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo FIXTURE-CMD"}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home cmdlog)"
    run_bash_dispatcher "$h/$acct" "$h" "$TMP/repo" template; rc=$?
    [ "$rc" = 0 ] || ok=0
    [ -z "$(files_under "$h/.claude")$(files_under "$h/.claude-work")" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: command-log audit/cost write nothing under either config dir"; else fail "excluded: command-log audit/cost write nothing under either config dir"; fi

h="$(fresh_home cmdlog-control)"
run_bash_dispatcher "$h/.claude-work" "$h" "$TMP/repo" none
if [ -f "$h/.claude/bash-commands.log" ] && [ -f "$h/.claude/cost-tracker.log" ] \
        && grep -q 'FIXTURE-CMD' "$h/.claude/bash-commands.log" \
        && [ -z "$(files_under "$h/.claude-work")" ]; then
    pass "control: without the exclusion a work session logs commands into the personal dir"
else
    fail "control: without the exclusion a work session logs commands into the personal dir"
fi

printf '{"hook_event_name":"PostToolUse","tool_name":"Skill","tool_input":{"skill":"fixture-skill"}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home skill)"
    run_gated "$h/$acct" "$h" "$TMP/repo" template post:skill:track scripts/hooks/skill-run-tracker.js standard,strict
    cmp -s "$TMP/out" "$TMP/payload" || ok=0
    [ -z "$(files_under "$h/.claude")$(files_under "$h/.claude-work")" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: skill-run tracker passes the payload through and writes nothing"; else fail "excluded: skill-run tracker passes the payload through and writes nothing"; fi

h="$(fresh_home skill-control)"
run_gated "$h/.claude-work" "$h" "$TMP/repo" none post:skill:track scripts/hooks/skill-run-tracker.js standard,strict
if [ -f "$h/.claude/state/skill-runs.jsonl" ] && grep -q 'fixture-skill' "$h/.claude/state/skill-runs.jsonl" \
        && [ -z "$(files_under "$h/.claude-work")" ]; then
    pass "control: without the exclusion a work session records skill runs into the personal dir"
else
    fail "control: without the exclusion a work session records skill runs into the personal dir"
fi

# mcp-health-check: excluded because its config-path knob cannot name the
# personal account's HOME-root .claude.json. Fixture: the personal dir
# declares a server with no transport (ECC treats it as unsupported: no
# network, no spawn) and a work session asks about it.
mcp_fixture() {
    printf '{"mcpServers":{"personalsrv":{"note":"fixture, no transport"}}}' >"$1/.claude/settings.json"
}
printf '{"hook_event_name":"PreToolUse","tool_name":"mcp__personalsrv__ping","tool_input":{}}' >"$TMP/payload"
ok=1
for acct in .claude .claude-work; do
    h="$(fresh_home mcp)"; mcp_fixture "$h"
    run_gated "$h/$acct" "$h" "$TMP/repo" template pre:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict
    cmp -s "$TMP/out" "$TMP/payload" || ok=0
    [ ! -e "$h/.claude/mcp-health-cache.json" ] || ok=0
    [ ! -e "$h/.claude-work/mcp-health-cache.json" ] || ok=0
done
if [ "$ok" = 1 ]; then pass "excluded: mcp-health-check passes the payload through and writes no cache"; else fail "excluded: mcp-health-check passes the payload through and writes no cache"; fi

h="$(fresh_home mcp-control)"; mcp_fixture "$h"
run_gated "$h/.claude-work" "$h" "$TMP/repo" none pre:mcp-health-check scripts/hooks/mcp-health-check.js standard,strict
if [ -f "$h/.claude/mcp-health-cache.json" ] && grep -q 'personalsrv' "$h/.claude/mcp-health-cache.json" \
        && [ ! -e "$h/.claude-work/mcp-health-cache.json" ]; then
    pass "control: without the exclusion a work session probes the personal MCP server and caches under the personal dir"
else
    fail "control: without the exclusion a work session probes the personal MCP server and caches under the personal dir"
fi

# --- flag gate: exactly the seven ids are off; neighbours stay on ---
# check-hook-enabled is called without a profile CSV, so the gate falls back
# to standard,strict: the "yes" cases prove the ids are NOT EXCLUDED under
# the template value, not their real profile membership (same caveat as
# plan-canvas-isolation.test.sh).
DISABLED="$(python3 -c 'import json; print(json.load(open("claude/settings.json.tmpl")).get("env", {}).get("ECC_DISABLED_HOOKS", ""))')"
enabled_is() {
    got="$(CLAUDE_PLUGIN_ROOT="$ECC_ROOT" ECC_HOOKS_ENABLED=true ECC_HOOK_PROFILE=standard \
        ECC_DISABLED_HOOKS="$DISABLED" node "$ECC_ROOT/scripts/hooks/check-hook-enabled.js" "$1" 2>/dev/null)"
    [ "$got" = "$2" ]
}
ok=1
for id in session-start:plan-canvas-sessions stop:plan-canvas-pending \
          post:bash:command-log-audit post:bash:command-log-cost post:skill:track \
          pre:mcp-health-check post:mcp-health-check; do
    enabled_is "$id" no || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: the seven excluded ids answer no"; else fail "flag gate: the seven excluded ids answer no"; fi
ok=1
for id in stop:session-end stop:cost-tracker pre:bash:dispatcher post:dispatcher:sync \
          pre:bash:gateguard-fact-force session:start; do
    enabled_is "$id" yes || ok=0
done
if [ "$ok" = 1 ]; then pass "flag gate: TDD, dispatcher, GateGuard, and scoped ids stay enabled"; else fail "flag gate: TDD, dispatcher, GateGuard, and scoped ids stay enabled"; fi

# --- scoped hooks: state lands under the account's own config dir ---

# scoped_case <label> <id> <script> <profiles> <payload-json> <expected-relpath>
# Under the template env: running as the work account creates the expected
# file under .claude-work and nothing under .claude; running as the personal
# account does the reverse. Control (env removed): the work account writes
# under .claude, proving the env is what scopes it.
scoped_case() {
    printf '%s' "$5" >"$TMP/payload"
    ok=1
    h="$(fresh_home scoped-work)"
    run_gated "$h/.claude-work" "$h" "$TMP/repo" template "$2" "$3" "$4"
    [ -e "$h/.claude-work/$6" ] || ok=0
    [ -z "$(files_under "$h/.claude")" ] || ok=0
    h="$(fresh_home scoped-personal)"
    run_gated "$h/.claude" "$h" "$TMP/repo" template "$2" "$3" "$4"
    [ -e "$h/.claude/$6" ] || ok=0
    [ -z "$(files_under "$h/.claude-work")" ] || ok=0
    if [ "$ok" = 1 ]; then pass "scoped: $1"; else fail "scoped: $1"; fi

    h="$(fresh_home scoped-control)"
    run_gated "$h/.claude-work" "$h" "$TMP/repo" none "$2" "$3" "$4"
    if [ -e "$h/.claude/$6" ] && [ -z "$(files_under "$h/.claude-work")" ]; then
        pass "control: without the env a work session puts $1 under the personal dir"
    else
        fail "control: without the env a work session puts $1 under the personal dir"
    fi
}

scoped_case "cost-tracker metrics" stop:cost-tracker scripts/hooks/cost-tracker.js minimal,standard,strict \
    '{"hook_event_name":"Stop","session_id":"fixture-session","cwd":"'"$TMP/repo"'","stop_hook_active":false}' \
    metrics/costs.jsonl
scoped_case "session-activity metrics" post:session-activity-tracker scripts/hooks/session-activity-tracker.js standard,strict \
    '{"hook_event_name":"PostToolUse","tool_name":"Read","tool_input":{"file_path":"'"$TMP/repo/fixture.txt"'"}}' \
    metrics/tool-usage.jsonl
scoped_case "session-end summary" stop:session-end scripts/hooks/session-end.js minimal,standard,strict \
    '{"hook_event_name":"Stop","session_id":"fixture-session","cwd":"'"$TMP/repo"'","stop_hook_active":false}' \
    session-data
scoped_case "compaction log" pre:compact scripts/hooks/pre-compact.js standard,strict \
    '{"hook_event_name":"PreCompact","trigger":"auto","session_id":"fixture-session"}' \
    session-data/compaction-log.txt
scoped_case "session-start data dir" session:start scripts/hooks/session-start.js minimal,standard,strict \
    '{"hook_event_name":"SessionStart","source":"startup","session_id":"fixture-session","cwd":"'"$TMP/repo"'"}' \
    session-data

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
