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
trap 'rm -rf "$TMP"' EXIT

DOTFILEDIR="$(pwd)"
export DOTFILEDIR
. "$LINKS"

# jget <file> <python-expr over d>: evaluate an expression against parsed JSON.
jget() {
    python3 -c "
import json, sys
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
if [ -L "$CFG/CLAUDE.md" ] && [ ! -L "$CFG/settings.json" ]; then
    pass "link path symlinks assets but keeps settings.json a real file"
else
    fail "link path symlinks assets but keeps settings.json a real file"
fi

# --- static check: install/common/link.sh wires the unified session store ---
if grep -q '"\$DOTFILEDIR"/bin/claude-unify-projects' install/common/link.sh; then
    pass "link.sh runs the session-store link step"
else
    fail "link.sh runs the session-store link step"
fi
if grep -q 'claude-unify-projects "\$HOME"/bin/claude-unify-projects' install/common/link.sh; then
    pass "link.sh installs claude-unify-projects into ~/bin"
else
    fail "link.sh installs claude-unify-projects into ~/bin"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
