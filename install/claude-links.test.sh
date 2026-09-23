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
  "promptSuggestionEnabled": false,
  "enabledPlugins": {"template@market": true, "conflict@market": true}
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
if jget "$DEST" "d.get('promptSuggestionEnabled') is False"; then
    pass "template-owned promptSuggestionEnabled reasserted"
else
    fail "template-owned promptSuggestionEnabled reasserted"
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

# 6. Retired plugins stay retired. enabledPlugins and extraKnownMarketplaces
#    are unions where live state wins, and env keeps live keys, so a template
#    that merely drops ECC would leave it enabled forever. The reconcile forces
#    the retired plugin off, drops its marketplace, and prunes its six env keys,
#    while every other plugin, marketplace, and env key survives.
RETTMPL="$TMP/ret-tmpl.json"
cat >"$RETTMPL" <<'EOF'
{
  "env": {"TEMPLATE_KEY": "t"},
  "enabledPlugins": {"superpowers@claude-plugins-official": true},
  "extraKnownMarketplaces": {"claude-plugins-official": {"source": {"source": "git", "url": "https://example.invalid/official.git"}}}
}
EOF
RETDEST="$TMP/ret-dest.json"
cat >"$RETDEST" <<'EOF'
{
  "enabledPlugins": {"ecc@ecc": true, "other@market": true},
  "extraKnownMarketplaces": {
    "ecc": {"source": {"source": "git", "url": "https://example.invalid/ecc.git"}},
    "other": {"source": {"source": "git", "url": "https://example.invalid/other.git"}}
  },
  "env": {
    "ECC_CONTEXT_MONITOR_COST_WARNINGS": "0",
    "ECC_DISABLED_HOOKS": "a,b",
    "ECC_AGENT_DATA_HOME": "/somewhere",
    "ECC_PLAN_CANVAS_STATE_DIR": "/somewhere/plan-canvas",
    "GATEGUARD_BASH_ROUTINE_DISABLED": "1",
    "GATEGUARD_EXEMPT_GLOBS": "/**",
    "ECC_SKIP_PRECOMMIT": "1",
    "MACHINE_LOCAL": "keep"
  }
}
EOF
reconcile_claude_settings_file "$RETTMPL" "$RETDEST" "[test]" >/dev/null 2>&1
if jget "$RETDEST" "d['enabledPlugins']['ecc@ecc'] is False"; then
    pass "reconcile forces retired plugin ecc@ecc to false"
else
    fail "reconcile forces retired plugin ecc@ecc to false"
fi
if jget "$RETDEST" "'ecc' not in d['extraKnownMarketplaces']"; then
    pass "reconcile drops the retired ecc marketplace"
else
    fail "reconcile drops the retired ecc marketplace"
fi
if jget "$RETDEST" "not set(d['env']) & {'ECC_CONTEXT_MONITOR_COST_WARNINGS', 'ECC_DISABLED_HOOKS', 'ECC_AGENT_DATA_HOME', 'ECC_PLAN_CANVAS_STATE_DIR', 'GATEGUARD_BASH_ROUTINE_DISABLED', 'GATEGUARD_EXEMPT_GLOBS'}"; then
    pass "reconcile prunes the six retired ECC env keys"
else
    fail "reconcile prunes the six retired ECC env keys"
fi
if jget "$RETDEST" "d['env']['ECC_SKIP_PRECOMMIT'] == '1'"; then
    pass "reconcile keeps the git-hook ECC_SKIP knobs"
else
    fail "reconcile keeps the git-hook ECC_SKIP knobs"
fi
if jget "$RETDEST" "d['enabledPlugins']['other@market'] is True and d['enabledPlugins']['superpowers@claude-plugins-official'] is True and set(d['extraKnownMarketplaces']) == {'other', 'claude-plugins-official'} and d['env']['MACHINE_LOCAL'] == 'keep' and d['env']['TEMPLATE_KEY'] == 't'"; then
    pass "retirement keeps other plugins, marketplaces and env keys"
else
    fail "retirement keeps other plugins, marketplaces and env keys"
fi
cp "$RETDEST" "$TMP/ret-first.json"
reconcile_claude_settings_file "$RETTMPL" "$RETDEST" "[test]" >/dev/null 2>&1
if cmp -s "$RETDEST" "$TMP/ret-first.json"; then
    pass "retirement is idempotent"
else
    fail "retirement is idempotent"
fi
# A dest whose only marketplace is the retired one must not keep an empty map.
ONLYDEST="$TMP/only-ecc-dest.json"
printf '{"extraKnownMarketplaces": {"ecc": {"source": {"source": "git", "url": "https://example.invalid/ecc.git"}}}}\n' >"$ONLYDEST"
ONLYTMPL="$TMP/only-tmpl.json"
printf '{"env": {}}\n' >"$ONLYTMPL"
if reconcile_claude_settings_file "$ONLYTMPL" "$ONLYDEST" "[test]" >/dev/null 2>&1 &&
   jget "$ONLYDEST" "'extraKnownMarketplaces' not in d"; then
    pass "retirement removes an emptied marketplace map"
else
    fail "retirement removes an emptied marketplace map"
fi

# 6b. Retired model-alias pins are swept. env is otherwise a union, so a
# machine that once carried ANTHROPIC_DEFAULT_OPUS_MODEL would keep the stale
# model ID forever after the template dropped it. A pin the template still
# defines stays, and unrelated machine-local env additions survive.
PINTMPL="$TMP/pin-tmpl.json"
cat >"$PINTMPL" <<'EOF'
{
  "model": "fable[1m]",
  "env": {"ANTHROPIC_DEFAULT_SONNET_MODEL": "deliberate-pin"}
}
EOF
PINDEST="$TMP/pin-dest.json"
cat >"$PINDEST" <<'EOF'
{
  "env": {
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8[1m]",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "stale-value",
    "ANTHROPIC_BASE_URL": "https://gateway.example",
    "MACHINE_LOCAL": "keep"
  }
}
EOF
reconcile_claude_settings_file "$PINTMPL" "$PINDEST" "[test]" >/dev/null 2>&1
if jget "$PINDEST" "'ANTHROPIC_DEFAULT_OPUS_MODEL' not in d['env']"; then
    pass "reconcile sweeps a model pin the template dropped"
else
    fail "reconcile sweeps a model pin the template dropped"
fi
if jget "$PINDEST" "d['env']['ANTHROPIC_DEFAULT_SONNET_MODEL'] == 'deliberate-pin'"; then
    pass "reconcile keeps a model pin the template still defines"
else
    fail "reconcile keeps a model pin the template still defines"
fi
if jget "$PINDEST" "d['env']['ANTHROPIC_BASE_URL'] == 'https://gateway.example' and d['env']['MACHINE_LOCAL'] == 'keep'"; then
    pass "the sweep leaves unrelated env keys alone"
else
    fail "the sweep leaves unrelated env keys alone"
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
if jget "$CFG/settings.json" "'Skill(review-change)' in d['permissions']['allow']"; then
    pass "link path grants review-change skill permission"
else
    fail "link path grants review-change skill permission"
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
if jget "$CFG/settings.json" "d['model'] == 'fable[1m]'"; then
    pass "link path defaults to the Fable alias at 1M"
else
    fail "link path defaults to the Fable alias at 1M"
fi
# A version-pinned default (claude-fable-5[1m], claude-opus-4-8[1m]) strands
# the machine on a retired model; the alias always resolves to the newest
# release of that family. ANTHROPIC_DEFAULT_*_MODEL takes a concrete model ID,
# so the only way to leave the opus alias un-pinned is to not set it.
if jget "$CFG/settings.json" "not any(k.startswith('ANTHROPIC_DEFAULT_') for k in d['env'])"; then
    pass "link path leaves every model alias un-pinned"
else
    fail "link path leaves every model alias un-pinned"
fi
if jget "$CFG/settings.json" "d['enabledPlugins']['ecc@ecc'] is False and 'ecc' not in d.get('extraKnownMarketplaces', {}) and not [k for k in d.get('env', {}) if k.startswith(('ECC_', 'GATEGUARD_'))] and 'CLAUDE_CONFIG_DIR' not in json.dumps(d)"; then
    pass "link path delivers no ECC env and disables ecc@ecc"
else
    fail "link path delivers no ECC env and disables ecc@ecc"
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

# --- reconcile writes a template stamp ---------------------------------
STAMP_DIR="$TMP/stampdir"
mkdir -p "$STAMP_DIR"
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$STAMP_DIR/settings.json" >/dev/null 2>&1
expected_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$DOTFILEDIR"/claude/settings.json.tmpl)"
if [ -f "$STAMP_DIR/.settings-template-sha256" ] \
   && [ "$(cat "$STAMP_DIR/.settings-template-sha256")" = "$expected_sha" ]; then
    pass "reconcile writes .settings-template-sha256 with template sha"
else
    fail "reconcile writes .settings-template-sha256 with template sha"
fi

# stamp refreshes when the template changes
ALT_TMPL="$TMP/alt-settings.json.tmpl"
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["_stamp_test"]=1; json.dump(d,open(sys.argv[2],"w"))' \
    "$DOTFILEDIR"/claude/settings.json.tmpl "$ALT_TMPL"
reconcile_claude_settings_file "$ALT_TMPL" "$STAMP_DIR/settings.json" >/dev/null 2>&1
alt_sha="$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$ALT_TMPL")"
if [ "$(cat "$STAMP_DIR/.settings-template-sha256")" = "$alt_sha" ]; then
    pass "re-reconcile refreshes stamp to new template sha"
else
    fail "re-reconcile refreshes stamp to new template sha"
fi

# a failed reconcile (missing template) leaves no stamp behind
NOSTAMP_DIR="$TMP/nostamp"
mkdir -p "$NOSTAMP_DIR"
reconcile_claude_settings_file "$TMP/does-not-exist.tmpl" "$NOSTAMP_DIR/settings.json" >/dev/null 2>&1
if [ ! -f "$NOSTAMP_DIR/.settings-template-sha256" ]; then
    pass "failed reconcile writes no stamp"
else
    fail "failed reconcile writes no stamp"
fi

# a symlinked stamp path is never followed/overwritten by the stamp write
SYMLINK_DIR="$TMP/symlinkdir"
mkdir -p "$SYMLINK_DIR"
printf '{"enabledPlugins": {"x@y": true}}\n' >"$SYMLINK_DIR/settings.json"
ln -s "$SYMLINK_DIR/settings.json" "$SYMLINK_DIR/.settings-template-sha256"
reconcile_claude_settings_file "$DOTFILEDIR"/claude/settings.json.tmpl "$SYMLINK_DIR/settings.json" >/dev/null 2>&1
if jget "$SYMLINK_DIR/settings.json" "'hooks' in d" \
   && [ -L "$SYMLINK_DIR/.settings-template-sha256" ] \
   && ! grep -qE '^[0-9a-f]{64}$' "$SYMLINK_DIR/.settings-template-sha256"; then
    pass "stamp write skipped through a symlinked stamp path"
else
    fail "stamp write skipped through a symlinked stamp path"
fi

# --- director agent asset -------------------------------------------------
# The persona must be tracked despite the machine-local info/exclude pattern
# claude/agents/*.md; the committed whitelist .gitignore outranks it. A
# tracked file always reports not-ignored (check-ignore consults the index),
# so precedence is proven in an untracked fixture repo instead.
if [ -n "$(git ls-files claude/agents/director.md)" ]; then
    pass "claude/agents/director.md is tracked"
else
    fail "claude/agents/director.md is tracked"
fi

AGFIX="$(mktemp -d "${TMPDIR:-/tmp}/agents-ignore-test.XXXXXX")"
git -C "$AGFIX" init -q
mkdir -p "$AGFIX/claude/agents"
cp claude/agents/.gitignore "$AGFIX/claude/agents/.gitignore"
: > "$AGFIX/claude/agents/director.md"
: > "$AGFIX/claude/agents/architect.md"
# Whitelist alone (a machine WITHOUT the local exclude line): the committed
# /* must keep vendored files ignored, the negation must free director.md.
if git -C "$AGFIX" check-ignore -q claude/agents/director.md; then
    fail "whitelist alone leaves director.md addable"
else
    pass "whitelist alone leaves director.md addable"
fi
if git -C "$AGFIX" check-ignore -q claude/agents/architect.md; then
    pass "whitelist alone keeps vendored agents ignored"
else
    fail "whitelist alone keeps vendored agents ignored"
fi
# Now plant the machine-local exclude: the committed negation must outrank it.
printf 'claude/agents/*.md\n' >> "$AGFIX/.git/info/exclude"
if git -C "$AGFIX" check-ignore -q claude/agents/director.md; then
    fail "whitelist negation beats info/exclude for director.md"
else
    pass "whitelist negation beats info/exclude for director.md"
fi
if git -C "$AGFIX" check-ignore -q claude/agents/architect.md; then
    pass "vendored agents stay ignored with info/exclude present"
else
    fail "vendored agents stay ignored with info/exclude present"
fi
rm -rf "$AGFIX"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
