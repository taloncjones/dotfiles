#!/bin/sh
# claude-links.test.sh -- behavioral tests for reconcile_claude_settings_file
# and its link_claude_config_dir integration (install/common/claude-links.sh).
#
# The reconcile merge is what delivers claude/settings.json.tmpl changes to
# EXISTING machines (seed-once alone never does) without losing the keys the
# plugin installers write into the live file. Every case runs against scratch
# files/dirs under mktemp; the real ~/.claude is never touched.

set -u

LINKS=install/common/claude-links.sh
if [ ! -f "$LINKS" ]; then
    echo "FAIL: $LINKS not found (run from repo root)" >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP: python3 not installed; reconcile is a python3 merge"
    exit 0
fi

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-links-test.XXXXXX")"
# Normalize: macOS sets TMPDIR with a trailing slash, which would otherwise
# leave a doubled slash in $TMP that os.path.abspath() (used by the reconcile
# substitution under test) normalizes away -- collapse it here so string
# comparisons against reconciled paths match.
TMP="$(cd "$TMP" && pwd)"
trap 'rm -rf "$TMP"' EXIT

DOTFILEDIR="$(pwd)"
export DOTFILEDIR
. "$LINKS"

# jget <file> <python-expr over d>: evaluate an expression against parsed JSON.
jget() {
    python3 -c "
import json, os, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if ($2) else 1)
" "$1"
}

# --- reconcile_claude_settings_file unit cases (synthetic template) ---
TMPL="$TMP/tmpl.json"
cat >"$TMPL" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/account_guard.py"}]
      }
    ]
  },
  "statusLine": {"type": "command", "command": "node ~/.claude/statusline.js"},
  "enabledPlugins": {"ecc@ecc": true, "conflict@market": true}
}
EOF

# 1. Template drift closes: a dest missing template keys gains them, while a
#    plugin-installer-written key and an unknown platform key both survive.
DEST="$TMP/dest1.json"
cat >"$DEST" <<'EOF'
{
  "enabledPlugins": {"installer@market": true, "conflict@market": false},
  "feedbackSurveyState": {"lastShown": 1}
}
EOF
reconcile_claude_settings_file "$TMPL" "$DEST" "[test]" >"$TMP/out" 2>&1
if jget "$DEST" "d['hooks']['SessionStart'][0]['hooks'][0]['command'].endswith('account_guard.py')"; then
    pass "template hook lands in drifted dest"
else
    fail "template hook lands in drifted dest"
fi
if jget "$DEST" "d['enabledPlugins']['installer@market'] is True"; then
    pass "installer-written plugin key survives"
else
    fail "installer-written plugin key survives"
fi
if jget "$DEST" "d['enabledPlugins']['conflict@market'] is False"; then
    pass "live plugin value wins on conflict"
else
    fail "live plugin value wins on conflict"
fi
if jget "$DEST" "d['feedbackSurveyState']['lastShown'] == 1"; then
    pass "unknown platform key preserved"
else
    fail "unknown platform key preserved"
fi
if grep -q "\[test\] Reconciled settings.json (SessionStart: account_guard.py)." "$TMP/out"; then
    pass "reconcile reports its SessionStart basenames"
else
    fail "reconcile reports its SessionStart basenames"
fi

# 2. Idempotent: a second run leaves the file byte-identical.
cp "$DEST" "$TMP/dest1.before"
reconcile_claude_settings_file "$TMPL" "$DEST" "[test]" >/dev/null 2>&1
if cmp -s "$DEST" "$TMP/dest1.before"; then
    pass "reconcile is idempotent"
else
    fail "reconcile is idempotent"
fi

# 3. Corrupt dest rebuilds from the template instead of erroring.
DEST="$TMP/dest2.json"
printf '{ not json' >"$DEST"
reconcile_claude_settings_file "$TMPL" "$DEST" "[test]" >/dev/null 2>&1
if jget "$DEST" "d['statusLine']['command'].startswith('node')"; then
    pass "corrupt dest rebuilt from template"
else
    fail "corrupt dest rebuilt from template"
fi

# 4. Absent dest is created (covers a config dir that never got seeded).
DEST="$TMP/newdir/settings.json"
reconcile_claude_settings_file "$TMPL" "$DEST" "[test]" >/dev/null 2>&1
if [ -f "$DEST" ] && jget "$DEST" "'hooks' in d"; then
    pass "absent dest created from template"
else
    fail "absent dest created from template"
fi

# 5. Missing template warns and returns non-zero (never nukes the dest).
DEST="$TMP/dest3.json"
printf '{"enabledPlugins": {"x@y": true}}\n' >"$DEST"
if reconcile_claude_settings_file "$TMP/no-such-tmpl.json" "$DEST" "[test]" >/dev/null 2>&1; then
    fail "missing template returns non-zero"
else
    pass "missing template returns non-zero"
fi
if jget "$DEST" "d['enabledPlugins']['x@y'] is True"; then
    pass "dest untouched when template missing"
else
    fail "dest untouched when template missing"
fi

# 6. Config-dir token: env string values carry {{CLAUDE_CONFIG_DIR}} in the
# template; reconcile replaces it with the absolute dir it writes into, and
# only inside env (a token elsewhere is left alone). No token survives in env.
TOKTMPL="$TMP/tok-tmpl.json"
cat >"$TOKTMPL" <<'EOF'
{
  "env": {
    "ECC_AGENT_DATA_HOME": "{{CLAUDE_CONFIG_DIR}}",
    "ECC_FIXTURE_MULTI": "a:{{CLAUDE_CONFIG_DIR}}/x:{{CLAUDE_CONFIG_DIR}}/y",
    "PLAIN": "unchanged"
  },
  "statusLine": {"type": "command", "command": "echo {{CLAUDE_CONFIG_DIR}}"}
}
EOF
mkdir -p "$TMP/tok-cfg"
reconcile_claude_settings_file "$TOKTMPL" "$TMP/tok-cfg/settings.json" >/dev/null 2>&1
if jget "$TMP/tok-cfg/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$TMP/tok-cfg'"; then
    pass "reconcile substitutes the config-dir token with the dest dir"
else
    fail "reconcile substitutes the config-dir token with the dest dir"
fi
if jget "$TMP/tok-cfg/settings.json" "d['env']['ECC_FIXTURE_MULTI'] == 'a:$TMP/tok-cfg/x:$TMP/tok-cfg/y'"; then
    pass "reconcile substitutes every token occurrence in one value"
else
    fail "reconcile substitutes every token occurrence in one value"
fi
if jget "$TMP/tok-cfg/settings.json" "d['env']['PLAIN'] == 'unchanged' and d['statusLine']['command'] == 'echo {{CLAUDE_CONFIG_DIR}}'"; then
    pass "reconcile leaves non-env values and token-free env values alone"
else
    fail "reconcile leaves non-env values and token-free env values alone"
fi
if ! grep -q '{{CLAUDE_CONFIG_DIR}}' "$TMP/tok-cfg/settings.json" 2>/dev/null || jget "$TMP/tok-cfg/settings.json" "all('{{CLAUDE_CONFIG_DIR}}' not in v for v in d['env'].values())"; then
    pass "reconcile leaves no token in env"
else
    fail "reconcile leaves no token in env"
fi

# --- link_claude_config_dir integration (real repo template) ---
# The campaign 3.2 gate: run the machine link path against a scratch config
# dir whose settings.json holds only installer-written keys, and prove the
# template config lands while those keys survive -- no hand-merge.
CFG="$TMP/cfg"
mkdir -p "$CFG"
printf '{"enabledPlugins": {"scratch@market": true}}\n' >"$CFG/settings.json"
link_claude_config_dir "$CFG" >"$TMP/link.out" 2>&1
if jget "$CFG/settings.json" "any(h['command'].endswith('account_guard.py') for g in d['hooks']['SessionStart'] for h in g['hooks'])"; then
    pass "link path reconciles template hooks into live settings"
else
    fail "link path reconciles template hooks into live settings"
fi
if jget "$CFG/settings.json" "d['enabledPlugins']['scratch@market'] is True"; then
    pass "link path keeps installer-written plugin key"
else
    fail "link path keeps installer-written plugin key"
fi
if jget "$CFG/settings.json" "'permissions' in d and 'statusLine' in d"; then
    pass "link path delivers template permissions/statusLine"
else
    fail "link path delivers template permissions/statusLine"
fi
if jget "$CFG/settings.json" "d['permissions']['deny'] == [] and 'Bash(rm:*)' not in d['permissions']['ask']"; then
    pass "link path drops the rm ask rule and deny floor"
else
    fail "link path drops the rm ask rule and deny floor"
fi
if jget "$CFG/settings.json" "'~/.claude/hooks/rm_guard.py' in [h['command'] for e in d['hooks']['PreToolUse'] if e.get('matcher') == 'Bash' for h in e['hooks']]"; then
    pass "link path registers rm_guard.py as a PreToolUse Bash hook"
else
    fail "link path registers rm_guard.py as a PreToolUse Bash hook"
fi
if jget "$CFG/settings.json" "d['model'] == 'claude-fable-5[1m]'"; then
    pass "link path pins the shared Claude default to Fable 5 1M"
else
    fail "link path pins the shared Claude default to Fable 5 1M"
fi
if jget "$CFG/settings.json" "d['env']['ANTHROPIC_DEFAULT_OPUS_MODEL'] == 'claude-opus-5[1m]'"; then
    pass "link path maps the Opus alias to Opus 5 1M"
else
    fail "link path maps the Opus alias to Opus 5 1M"
fi
if jget "$CFG/settings.json" "{x.strip().lower() for x in d['env']['ECC_DISABLED_HOOKS'].split(',') if x.strip()} == {'session-start:plan-canvas-sessions', 'stop:plan-canvas-pending', 'post:bash:command-log-audit', 'post:bash:command-log-cost', 'post:skill:track', 'pre:mcp-health-check', 'post:mcp-health-check'}"; then
    pass "link path delivers the seven-id ECC hook exclusion"
else
    fail "link path delivers the seven-id ECC hook exclusion"
fi
if jget "$CFG/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$CFG'"; then
    pass "link path scopes the ECC data home to this config dir"
else
    fail "link path scopes the ECC data home to this config dir"
fi
# A second config dir (the work account) must receive its own path, not a
# copy of the first dir's.
CFG2="$TMP/cfg-work"
mkdir -p "$CFG2"
link_claude_config_dir "$CFG2" >/dev/null 2>&1
if jget "$CFG2/settings.json" "d['env']['ECC_AGENT_DATA_HOME'] == '$CFG2'"; then
    pass "link path gives a second config dir its own ECC data home"
else
    fail "link path gives a second config dir its own ECC data home"
fi
# Two consecutive update runs must converge: the exclusion is delivered once
# and never re-written differently.
cp "$CFG/settings.json" "$TMP/link-first.json"
link_claude_config_dir "$CFG" >/dev/null 2>&1
if cmp -s "$CFG/settings.json" "$TMP/link-first.json"; then
    pass "second link run leaves settings.json byte-identical"
else
    fail "second link run leaves settings.json byte-identical"
fi
if [ -L "$CFG/CLAUDE.md" ] && [ ! -L "$CFG/settings.json" ]; then
    pass "link path symlinks assets but keeps settings.json a real file"
else
    fail "link path symlinks assets but keeps settings.json a real file"
fi

ACCOUNT_HOME="$TMP/account-home"
mkdir -p "$ACCOUNT_HOME/.claude" "$ACCOUNT_HOME/.claude-work"
printf '{"enabledPlugins":{"atlassian@claude-plugins-official":true,"keep@custom":true}}\n' \
    > "$ACCOUNT_HOME/.claude/settings.json"
cp "$ACCOUNT_HOME/.claude/settings.json" "$ACCOUNT_HOME/.claude-work/settings.json"
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude/settings.json" >/dev/null
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude-work/settings.json" >/dev/null
if jget "$ACCOUNT_HOME/.claude/settings.json" "d['enabledPlugins']['atlassian@claude-plugins-official'] is False and d['enabledPlugins']['keep@custom'] is True"; then
    pass "personal Claude config disables Atlassian and preserves other plugins"
else
    fail "personal Claude config disables Atlassian and preserves other plugins"
fi
if jget "$ACCOUNT_HOME/.claude-work/settings.json" "d['enabledPlugins']['atlassian@claude-plugins-official'] is True"; then
    pass "work Claude config retains Atlassian"
else
    fail "work Claude config retains Atlassian"
fi

# 7. Canvas hooks from ECC 2.2.1 resolve their state under the default
# ~/.claude path even when CLAUDE_CONFIG_DIR selects another account. Keep the
# two automatic hooks disabled in every account settings file, retain existing
# hook opt-outs and unrelated env keys, and set the manual Canvas state dir
# beside the settings file so the two accounts do not share it.
PERSONAL_HOOKS='keep-me,session-start:plan-canvas-sessions'
WORK_HOOKS='work-only,stop:plan-canvas-pending'
printf '{"env":{"PERSONAL_ONLY":"yes","ECC_DISABLED_HOOKS":"%s"}}\n' "$PERSONAL_HOOKS" \
    > "$ACCOUNT_HOME/.claude/settings.json"
printf '{"env":{"WORK_ONLY":"yes","ECC_DISABLED_HOOKS":"%s"}}\n' "$WORK_HOOKS" \
    > "$ACCOUNT_HOME/.claude-work/settings.json"
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude/settings.json" >/dev/null
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude-work/settings.json" >/dev/null
cp "$ACCOUNT_HOME/.claude/settings.json" "$TMP/personal-canvas.before"
cp "$ACCOUNT_HOME/.claude-work/settings.json" "$TMP/work-canvas.before"
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude/settings.json" >/dev/null
HOME="$ACCOUNT_HOME" reconcile_claude_settings_file "$DOTFILEDIR/claude/settings.json.tmpl" \
    "$ACCOUNT_HOME/.claude-work/settings.json" >/dev/null
if jget "$ACCOUNT_HOME/.claude/settings.json" "d['env']['PERSONAL_ONLY'] == 'yes' and d['env']['ECC_DISABLED_HOOKS'].split(',').count('keep-me') == 1 and set(('session-start:plan-canvas-sessions', 'stop:plan-canvas-pending')).issubset(d['env']['ECC_DISABLED_HOOKS'].split(',')) and d['env']['ECC_PLAN_CANVAS_STATE_DIR'] == os.path.abspath(os.path.join(os.path.dirname(sys.argv[1]), 'plan-canvas'))"; then
    pass "personal Canvas policy preserves env and scopes state"
else
    fail "personal Canvas policy preserves env and scopes state"
fi
if jget "$ACCOUNT_HOME/.claude-work/settings.json" "d['env']['WORK_ONLY'] == 'yes' and d['env']['ECC_DISABLED_HOOKS'].split(',').count('work-only') == 1 and set(('session-start:plan-canvas-sessions', 'stop:plan-canvas-pending')).issubset(d['env']['ECC_DISABLED_HOOKS'].split(',')) and d['env']['ECC_PLAN_CANVAS_STATE_DIR'] == os.path.abspath(os.path.join(os.path.dirname(sys.argv[1]), 'plan-canvas'))"; then
    pass "work Canvas policy preserves env and scopes state"
else
    fail "work Canvas policy preserves env and scopes state"
fi
if cmp -s "$ACCOUNT_HOME/.claude/settings.json" "$TMP/personal-canvas.before" &&
   cmp -s "$ACCOUNT_HOME/.claude-work/settings.json" "$TMP/work-canvas.before"; then
    pass "Canvas reconcile is stable across account namespaces"
else
    fail "Canvas reconcile is stable across account namespaces"
fi

# A pre-existing custom opt-out list must not mask new template exclusions.
if python3 - "$DOTFILEDIR/claude/settings.json.tmpl" "$ACCOUNT_HOME" <<'PY'
import json, os, sys
with open(sys.argv[1]) as stream:
    required = set(json.load(stream)['env']['ECC_DISABLED_HOOKS'].split(','))
for account in ('.claude', '.claude-work'):
    root = os.path.join(sys.argv[2], account)
    with open(os.path.join(root, 'settings.json')) as stream:
        env = json.load(stream)['env']
    assert required.issubset(env['ECC_DISABLED_HOOKS'].split(','))
    assert env['ECC_AGENT_DATA_HOME'] == root
PY
then
    pass "existing opt-outs retain every template isolation rule and account root"
else
    fail "existing opt-outs retain every template isolation rule and account root"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
