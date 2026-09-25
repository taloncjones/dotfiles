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
  "enabledPlugins": {"sample@claude-plugins-official": true},
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
if jget "$RETDEST" "'ecc@ecc' not in d['enabledPlugins']"; then
    pass "reconcile drops an unregistered retired ecc@ecc key"
else
    fail "reconcile drops an unregistered retired ecc@ecc key"
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
if jget "$RETDEST" "d['enabledPlugins']['other@market'] is True and d['enabledPlugins']['sample@claude-plugins-official'] is True and set(d['extraKnownMarketplaces']) == {'other', 'claude-plugins-official'} and d['env']['MACHINE_LOCAL'] == 'keep' and d['env']['TEMPLATE_KEY'] == 't'"; then
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

# Superpowers is retired too: forced off like ECC, but its marketplace is the
# shared official one and must survive.
SPDEST="$TMP/sp-dest.json"
cat >"$SPDEST" <<'EOF'
{
  "enabledPlugins": {"superpowers@claude-plugins-official": true, "sample@claude-plugins-official": true},
  "extraKnownMarketplaces": {"claude-plugins-official": {"source": {"source": "git", "url": "https://example.invalid/official.git"}}}
}
EOF
reconcile_claude_settings_file "$RETTMPL" "$SPDEST" "[test]" >/dev/null 2>&1
if jget "$SPDEST" "'superpowers@claude-plugins-official' not in d['enabledPlugins'] and d['enabledPlugins']['sample@claude-plugins-official'] is True"; then
    pass "reconcile drops an unregistered retired superpowers key"
else
    fail "reconcile drops an unregistered retired superpowers key"
fi
if jget "$SPDEST" "'claude-plugins-official' in d['extraKnownMarketplaces']"; then
    pass "retirement keeps the shared claude-plugins-official marketplace"
else
    fail "retirement keeps the shared claude-plugins-official marketplace"
fi

# Only ECC owns isolation env keys. A config dir that still has Superpowers
# installed but no ECC must not get ECC isolation env keys restored.
SPCFG="$TMP/sp-config"
mkdir -p "$SPCFG/plugins"
printf '{"plugins": {"superpowers@claude-plugins-official": [{"scope": "user"}]}}\n' \
    >"$SPCFG/plugins/installed_plugins.json"
printf '{"env": {"MACHINE_LOCAL": "keep"}}\n' >"$SPCFG/settings.json"
reconcile_claude_settings_file "$RETTMPL" "$SPCFG/settings.json" "[test]" >/dev/null 2>&1
if jget "$SPCFG/settings.json" "not [k for k in d['env'] if k.startswith(('ECC_', 'GATEGUARD_'))] and d['env']['MACHINE_LOCAL'] == 'keep'"; then
    pass "superpowers installed without ECC restores no ECC env key"
else
    fail "superpowers installed without ECC restores no ECC env key"
fi

if jget "$SPCFG/settings.json" "d['enabledPlugins']['superpowers@claude-plugins-official'] is False and 'ecc@ecc' not in d['enabledPlugins']"; then
    pass "reconcile forces a registered retired superpowers to false"
else
    fail "reconcile forces a registered retired superpowers to false"
fi

# A registry listing only other plugins retires nothing it lists: both
# retired keys go, the listed plugin stays.
OTHERCFG="$TMP/other-registry"
mkdir -p "$OTHERCFG/plugins"
printf '{"plugins": {"sample@claude-plugins-official": [{"scope": "user"}]}}\n' \
    >"$OTHERCFG/plugins/installed_plugins.json"
printf '{"enabledPlugins": {"ecc@ecc": false, "superpowers@claude-plugins-official": false, "sample@claude-plugins-official": true}}\n' \
    >"$OTHERCFG/settings.json"
reconcile_claude_settings_file "$RETTMPL" "$OTHERCFG/settings.json" "[test]" >/dev/null 2>&1
if jget "$OTHERCFG/settings.json" "'ecc@ecc' not in d['enabledPlugins'] and 'superpowers@claude-plugins-official' not in d['enabledPlugins'] and d['enabledPlugins']['sample@claude-plugins-official'] is True"; then
    pass "reconcile drops retired keys when the registry lists only other plugins"
else
    fail "reconcile drops retired keys when the registry lists only other plugins"
fi

# The sweep's validity rule: a record list that is not a list of objects is
# unreadable, so both retired ids stay pinned off and ECC isolation stays.
SHAPECFG="$TMP/shape-registry"
mkdir -p "$SHAPECFG/plugins"
printf '{"plugins": {"ecc@ecc": {"scope": "user"}}}\n' >"$SHAPECFG/plugins/installed_plugins.json"
printf '{"env": {}}\n' >"$SHAPECFG/settings.json"
reconcile_claude_settings_file "$RETTMPL" "$SHAPECFG/settings.json" "[test]" >/dev/null 2>&1
if jget "$SHAPECFG/settings.json" "d['enabledPlugins']['ecc@ecc'] is False and d['enabledPlugins']['superpowers@claude-plugins-official'] is False and d['env'].get('ECC_DISABLED_HOOKS')"; then
    pass "reconcile treats a wrong-shape registry as unreadable"
else
    fail "reconcile treats a wrong-shape registry as unreadable"
fi

# ECC records pruned but its marketplace still known: the marketplace can
# still offer ECC, so the pin and the isolation keys stay.
KEYCFG="$TMP/key-only"
mkdir -p "$KEYCFG/plugins"
printf '{"ecc": {}}\n' >"$KEYCFG/plugins/known_marketplaces.json"
printf '{"env": {"ECC_DISABLED_HOOKS": "a,b"}}\n' >"$KEYCFG/settings.json"
reconcile_claude_settings_file "$RETTMPL" "$KEYCFG/settings.json" "[test]" >/dev/null 2>&1
if jget "$KEYCFG/settings.json" "d['enabledPlugins']['ecc@ecc'] is False and d['env']['ECC_DISABLED_HOOKS'] == 'a,b' and 'superpowers@claude-plugins-official' not in d['enabledPlugins']"; then
    pass "reconcile keeps ECC pinned while its marketplace is still known"
else
    fail "reconcile keeps ECC pinned while its marketplace is still known"
fi

# An unreadable registry means "ECC may still be installed", never
# "Superpowers may be": ECC rescue keys return, superpowers stays retired.
BADCFG="$TMP/bad-registry"
mkdir -p "$BADCFG/plugins"
printf 'not json\n' >"$BADCFG/plugins/installed_plugins.json"
printf '{"env": {}}\n' >"$BADCFG/settings.json"
reconcile_claude_settings_file "$RETTMPL" "$BADCFG/settings.json" "[test]" >/dev/null 2>&1
if jget "$BADCFG/settings.json" "d['env'].get('ECC_DISABLED_HOOKS') and d['enabledPlugins']['superpowers@claude-plugins-official'] is False"; then
    pass "unreadable registry keeps ECC rescue keys and still retires superpowers"
else
    fail "unreadable registry keeps ECC rescue keys and still retires superpowers"
fi

# A config dir where the retired plugin is disabled in settings.json but
# still physically installed (installed_plugins.json still lists it, e.g.
# from a project-level override or a machine that has not run
# ecc-uninstall yet) must keep the isolation env keys -- sweeping them
# ahead of the actual uninstall would let the still-loadable plugin read
# state without ECC_DISABLED_HOOKS/ECC_AGENT_DATA_HOME in place.
STILLDIR="$TMP/still-installed-cdir"
mkdir -p "$STILLDIR/plugins"
cat >"$STILLDIR/plugins/installed_plugins.json" <<'EOF'
{"plugins": {"ecc@ecc": [{"scope": "user"}]}}
EOF
STILLDEST="$STILLDIR/settings.json"
cp "$RETTMPL" "$TMP/still-tmpl.json"
cat >"$STILLDEST" <<'EOF'
{
  "enabledPlugins": {"ecc@ecc": true},
  "env": {
    "ECC_DISABLED_HOOKS": "a,b",
    "ECC_AGENT_DATA_HOME": "/somewhere",
    "MACHINE_LOCAL": "keep"
  }
}
EOF
reconcile_claude_settings_file "$TMP/still-tmpl.json" "$STILLDEST" "[test]" >/dev/null 2>&1
if jget "$STILLDEST" "d['enabledPlugins']['ecc@ecc'] is False"; then
    pass "reconcile still forces the plugin off when it remains installed"
else
    fail "reconcile still forces the plugin off when it remains installed"
fi
if jget "$STILLDEST" "d['env']['ECC_DISABLED_HOOKS'] == 'a,b' and d['env']['ECC_AGENT_DATA_HOME'] == '/somewhere'"; then
    pass "reconcile keeps isolation env keys while the plugin is still installed"
else
    fail "reconcile keeps isolation env keys while the plugin is still installed"
fi
rm -f "$STILLDIR/plugins/installed_plugins.json"
reconcile_claude_settings_file "$TMP/still-tmpl.json" "$STILLDEST" "[test]" >/dev/null 2>&1
if jget "$STILLDEST" "not set(d['env']) & {'ECC_DISABLED_HOOKS', 'ECC_AGENT_DATA_HOME'}"; then
    pass "reconcile sweeps isolation env keys once the plugin is actually gone"
else
    fail "reconcile sweeps isolation env keys once the plugin is actually gone"
fi

# A dest that is corrupt or empty is rebuilt from {} (case 3 above). If the
# plugin is still installed at that point, the union of an empty dest env
# and a template that no longer declares these keys would otherwise leave
# isolation silently absent from the rebuilt file. The rescue defaults must
# fill the gap instead of leaving it open.
cat >"$STILLDIR/plugins/installed_plugins.json" <<'EOF'
{"plugins": {"ecc@ecc": [{"scope": "user"}]}}
EOF
CORRUPTDEST="$STILLDIR/settings.json"
printf '' >"$CORRUPTDEST"
reconcile_claude_settings_file "$TMP/still-tmpl.json" "$CORRUPTDEST" "[test]" >/dev/null 2>&1
if jget "$CORRUPTDEST" "d['env'].get('ECC_DISABLED_HOOKS') and d['env'].get('ECC_AGENT_DATA_HOME') == os.path.dirname(os.path.abspath(sys.argv[1]))"; then
    pass "reconcile restores isolation env defaults when rebuilding a corrupt dest with the plugin still installed"
else
    fail "reconcile restores isolation env defaults when rebuilding a corrupt dest with the plugin still installed"
fi

# Same rescue, but the dest file is entirely absent (a config dir that was
# never seeded) rather than present-but-corrupt.
cat >"$STILLDIR/plugins/installed_plugins.json" <<'EOF'
{"plugins": {"ecc@ecc": [{"scope": "user"}]}}
EOF
MISSINGDEST="$STILLDIR/newsettings.json"
reconcile_claude_settings_file "$TMP/still-tmpl.json" "$MISSINGDEST" "[test]" >/dev/null 2>&1
if jget "$MISSINGDEST" "d['env'].get('ECC_DISABLED_HOOKS') and d['env'].get('ECC_AGENT_DATA_HOME') == os.path.dirname(os.path.abspath(sys.argv[1]))"; then
    pass "reconcile restores isolation env defaults for a never-seeded dest with the plugin still installed"
else
    fail "reconcile restores isolation env defaults for a never-seeded dest with the plugin still installed"
fi
if jget "$MISSINGDEST" "d['env'].get('ECC_PLAN_CANVAS_STATE_DIR') == os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), 'plan-canvas')"; then
    pass "reconcile restores the plan-canvas state dir alongside the other rescue defaults"
else
    fail "reconcile restores the plan-canvas state dir alongside the other rescue defaults"
fi
rm -f "$STILLDIR/plugins/installed_plugins.json"

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

# --- sweep_retired_claude_plugins ---
# The stub `claude` records "<cwd>|<CLAUDE_CONFIG_DIR or unset>|<CLAUDECODE or
# none>|<HERDR_PANE_ID or none>|<CLAUDE_CODE_SENTINEL or none>|<args>" and
# mimics CLI 2.1.282 as probed. Like the real CLI (spec F6), it rewrites a
# project settings file found in its cwd, so a sweep that ran it inside a
# project would be caught by the byte compare. Verbs:
# - `plugin marketplace remove <m>` drops every <id>@<m> record in every
#   scope, the known_marketplaces key and the clone;
# - `plugin uninstall --scope user <id>` drops that id's user records.
# SWEEP_STUB selects a failure mode:
# - fail: exits 1;
# - lie: exits 0 and changes nothing;
# - truncate: empties (or creates) settings.json and exits 0;
# - tearreg: overwrites the registry with non-JSON and exits 0;
# - tearmk: overwrites known_marketplaces.json with a JSON array and exits 0.
SWEEP_BIN="$TMP/sweep-bin"
mkdir -p "$SWEEP_BIN"
cat >"$SWEEP_BIN/claude" <<'EOF'
#!/bin/sh
printf '%s|%s|%s|%s|%s|%s\n' "$(pwd -P)" "${CLAUDE_CONFIG_DIR-unset}" "${CLAUDECODE-none}" \
    "${HERDR_PANE_ID-none}" "${CLAUDE_CODE_SENTINEL-none}" "$*" >>"$SWEEP_TRACE"
for f in .claude/settings.json .claude/settings.local.json; do
    [ -f "$f" ] && printf '{"enabledPlugins": {}}\n' >"$f"
done
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
case "${SWEEP_STUB:-ok}" in
    fail) exit 1 ;;
    lie) exit 0 ;;
    truncate) : >"$cfg/settings.json"; exit 0 ;;
    tearreg) printf 'not json\n' >"$cfg/plugins/installed_plugins.json"; exit 0 ;;
    tearmk) printf '[1]\n' >"$cfg/plugins/known_marketplaces.json"; exit 0 ;;
esac
python3 - "$cfg" "$@" <<'PY'
import json, os, shutil, sys
cfg, args = sys.argv[1], sys.argv[2:]
reg_path = os.path.join(cfg, "plugins", "installed_plugins.json")
mk_path = os.path.join(cfg, "plugins", "known_marketplaces.json")
reg = json.load(open(reg_path)) if os.path.isfile(reg_path) else {"version": 2, "plugins": {}}
if args[:3] == ["plugin", "marketplace", "remove"]:
    market = args[3]
    reg["plugins"] = {k: v for k, v in reg["plugins"].items() if not k.endswith("@" + market)}
    if os.path.isfile(mk_path):
        mk = json.load(open(mk_path))
        mk.pop(market, None)
        json.dump(mk, open(mk_path, "w"))
    shutil.rmtree(os.path.join(cfg, "plugins", "marketplaces", market), ignore_errors=True)
elif args[:4] == ["plugin", "uninstall", "--scope", "user"]:
    plugin = args[4]
    kept = [r for r in reg["plugins"].get(plugin, []) if r.get("scope") != "user"]
    if kept:
        reg["plugins"][plugin] = kept
    else:
        reg["plugins"].pop(plugin, None)
json.dump(reg, open(reg_path, "w"))
PY
EOF
chmod +x "$SWEEP_BIN/claude"
# PATH variants: python3 and git without claude; sh alone without python3.
NOCLI_BIN="$TMP/nocli-bin"
NOPY_SWEEP_BIN="$TMP/nopy-sweep-bin"
mkdir -p "$NOCLI_BIN" "$NOPY_SWEEP_BIN"
for tool in sh python3 git; do
    ln -s "$(command -v "$tool")" "$NOCLI_BIN/$tool"
done
ln -s "$(command -v sh)" "$NOPY_SWEEP_BIN/sh"

# ECC fixture. Registry: two project records, one naming a deleted project
# and one naming a live project that enables ECC in its own settings.
# Marketplace: registered, with a clone. Cache: present. Three temp_git
# dirs: an ECC origin without the .git suffix (normalization), an Atlassian
# origin, one with no .git at all, and one git dir with no origin. The fixture root is itself a git repo
# with the ECC origin, so a check that walked up to the parent would wrongly
# match the plain dir.
ECCROOT="$TMP/sweep-ecc"
ECCCFG="$ECCROOT/cfg"
ECCPROJ="$ECCROOT/project"
mkdir -p "$ECCCFG/plugins/marketplaces/ecc" "$ECCCFG/plugins/cache/ecc/ecc/2.2.0" \
    "$ECCCFG/plugins/cache/temp_git_1_ecc" "$ECCCFG/plugins/cache/temp_git_2_atl" \
    "$ECCCFG/plugins/cache/temp_git_3_plain" "$ECCCFG/plugins/cache/temp_git_5_nested" "$ECCPROJ/.claude"
git -C "$ECCROOT" init -q
git -C "$ECCROOT" config remote.origin.url https://github.com/affaan-m/ECC.git
# A git dir with no origin of its own: `git -C <dir> remote get-url` would
# fall back to nothing here, but a lookup that walked up would find ECC's.
git -C "$ECCCFG/plugins/cache/temp_git_5_nested" init -q
git -C "$ECCCFG/plugins/cache/temp_git_1_ecc" init -q
git -C "$ECCCFG/plugins/cache/temp_git_1_ecc" remote add origin https://github.com/Affaan-M/ECC
git -C "$ECCCFG/plugins/cache/temp_git_2_atl" init -q
git -C "$ECCCFG/plugins/cache/temp_git_2_atl" remote add origin https://github.com/atlassian/atlassian-mcp-server.git
cat >"$ECCCFG/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {
  "ecc@ecc": [
    {"scope": "project", "projectPath": "$ECCROOT/deleted-project", "installPath": "$ECCCFG/plugins/cache/ecc/ecc/2.2.0"},
    {"scope": "project", "projectPath": "$ECCPROJ", "installPath": "$ECCCFG/plugins/cache/ecc/ecc/2.2.0"}],
  "sample@claude-plugins-official": [{"scope": "user"}]}}
EOF
printf '{"ecc": {"source": {"source": "git", "url": "https://github.com/affaan-m/ECC.git"}}, "claude-plugins-official": {}}\n' \
    >"$ECCCFG/plugins/known_marketplaces.json"
printf '{"enabledPlugins": {"ecc@ecc": true}}\n' >"$ECCPROJ/.claude/settings.json"
cp "$ECCPROJ/.claude/settings.json" "$TMP/ecc-project-settings.before"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$ECCCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   jget "$ECCCFG/plugins/installed_plugins.json" "'ecc@ecc' not in d['plugins'] and 'sample@claude-plugins-official' in d['plugins']" &&
   jget "$ECCCFG/plugins/known_marketplaces.json" "'ecc' not in d and 'claude-plugins-official' in d" &&
   [ "$(wc -l <"$TMP/sweep-trace" | tr -d ' ')" = 1 ] &&
   grep -q '|plugin marketplace remove ecc$' "$TMP/sweep-trace" &&
   grep -qF '[test] [OK] Removed ecc@ecc from' "$TMP/sweep.out" &&
   grep -qF '[test] [INFO] Restart running Claude sessions' "$TMP/sweep.out"; then
    pass "sweep removes every ECC record and the marketplace"
else
    fail "sweep removes every ECC record and the marketplace"
fi
if [ ! -e "$ECCCFG/plugins/cache/ecc" ] && [ ! -e "$ECCCFG/plugins/marketplaces/ecc" ] &&
   [ ! -e "$ECCCFG/plugins/cache/temp_git_1_ecc" ] &&
   [ -d "$ECCCFG/plugins/cache/temp_git_2_atl" ] && [ -d "$ECCCFG/plugins/cache/temp_git_3_plain" ] &&
   [ -d "$ECCCFG/plugins/cache/temp_git_5_nested" ]; then
    pass "sweep removes the retired cache, clone and only retired temp_git clones"
else
    fail "sweep removes the retired cache, clone and only retired temp_git clones"
fi
# The stub records `pwd -P`; compare against the resolved fixture root
# (on macOS /var is a symlink to /private/var).
ECCROOT_REAL="$(cd "$ECCROOT" && pwd -P)"
if cmp -s "$ECCPROJ/.claude/settings.json" "$TMP/ecc-project-settings.before" &&
   ! grep -q "^$ECCROOT_REAL" "$TMP/sweep-trace"; then
    pass "sweep never writes the project settings file and runs the CLI outside it"
else
    fail "sweep never writes the project settings file and runs the CLI outside it"
fi

# Idempotence: a second run on the swept dir calls no CLI and changes nothing.
cp "$ECCCFG/plugins/installed_plugins.json" "$TMP/ecc-reg.first"
cp "$ECCCFG/plugins/known_marketplaces.json" "$TMP/ecc-mk.first"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=fail HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$ECCCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ ! -s "$TMP/sweep-trace" ] && [ ! -s "$TMP/sweep.out" ] &&
   cmp -s "$ECCCFG/plugins/installed_plugins.json" "$TMP/ecc-reg.first" &&
   cmp -s "$ECCCFG/plugins/known_marketplaces.json" "$TMP/ecc-mk.first"; then
    pass "second sweep calls no CLI and changes nothing"
else
    fail "second sweep calls no CLI and changes nothing"
fi

# Superpowers shares the official marketplace, so it stays. The user record
# goes through the CLI. Local and project records, whether the dir is live
# or deleted, are pruned with a backup and take no CLI call.
SPROOT="$TMP/sweep-sp"
SPSCFG="$SPROOT/cfg"
SPSPROJ="$SPROOT/project"
mkdir -p "$SPSCFG/plugins/cache/claude-plugins-official/superpowers/6.4.1" \
    "$SPSCFG/plugins/cache/temp_git_4_sp" "$SPSPROJ/.claude"
git -C "$SPSCFG/plugins/cache/temp_git_4_sp" init -q
git -C "$SPSCFG/plugins/cache/temp_git_4_sp" remote add origin https://github.com/obra/superpowers.git/
cat >"$SPSCFG/plugins/installed_plugins.json" <<EOF
{"version": 2, "plugins": {
  "superpowers@claude-plugins-official": [
    {"scope": "user"},
    {"scope": "local", "projectPath": "$SPSPROJ"},
    {"scope": "project", "projectPath": "$SPROOT/deleted-project"}],
  "sample@claude-plugins-official": [{"scope": "user"}]}}
EOF
printf '{"enabledPlugins": {"superpowers@claude-plugins-official": true}}\n' >"$SPSPROJ/.claude/settings.local.json"
cp "$SPSPROJ/.claude/settings.local.json" "$TMP/sp-project-settings.before"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$SPSCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ "$(wc -l <"$TMP/sweep-trace" | tr -d ' ')" = 1 ] &&
   grep -q '|plugin uninstall --scope user superpowers@claude-plugins-official$' "$TMP/sweep-trace" &&
   jget "$SPSCFG/plugins/installed_plugins.json" "'superpowers@claude-plugins-official' not in d['plugins'] and d['plugins']['sample@claude-plugins-official'] == [{'scope': 'user'}] and d['version'] == 2" &&
   [ ! -e "$SPSCFG/plugins/cache/claude-plugins-official/superpowers" ] &&
   [ ! -e "$SPSCFG/plugins/cache/temp_git_4_sp" ] &&
   cmp -s "$SPSPROJ/.claude/settings.local.json" "$TMP/sp-project-settings.before"; then
    pass "sweep removes the superpowers user record by CLI and prunes the rest"
else
    fail "sweep removes the superpowers user record by CLI and prunes the rest"
fi
set -- "$SPSCFG"/plugins/installed_plugins.json.bak-retired-*
if [ "$#" = 1 ] && [ -f "$1" ] &&
   jget "$1" "[r['scope'] for r in d['plugins']['superpowers@claude-plugins-official']] == ['local', 'project']"; then
    pass "sweep backs up the registry before pruning"
else
    fail "sweep backs up the registry before pruning"
fi

# Partial ECC states (spec R5), each converging in one run.
PART1="$TMP/sweep-part-records"
mkdir -p "$PART1/plugins"
printf '{"version": 2, "plugins": {"ecc@ecc": [{"scope": "project", "projectPath": "%s/gone"}]}}\n' \
    "$TMP" >"$PART1/plugins/installed_plugins.json"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$PART1" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ ! -s "$TMP/sweep-trace" ] && jget "$PART1/plugins/installed_plugins.json" "d['plugins'] == {}"; then
    pass "partial ECC: records without a marketplace key are pruned with no CLI call"
else
    fail "partial ECC: records without a marketplace key are pruned with no CLI call"
fi
PART2="$TMP/sweep-part-key"
mkdir -p "$PART2/plugins"
printf '{"ecc": {}}\n' >"$PART2/plugins/known_marketplaces.json"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$PART2" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ "$(wc -l <"$TMP/sweep-trace" | tr -d ' ')" = 1 ] &&
   jget "$PART2/plugins/known_marketplaces.json" "'ecc' not in d"; then
    pass "partial ECC: a marketplace key without records takes one CLI call"
else
    fail "partial ECC: a marketplace key without records takes one CLI call"
fi
PART3="$TMP/sweep-part-clone"
mkdir -p "$PART3/plugins/marketplaces/ecc/hooks"
: >"$TMP/sweep-trace"
if (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$PART3" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ ! -s "$TMP/sweep-trace" ] && [ ! -e "$PART3/plugins/marketplaces/ecc" ]; then
    pass "partial ECC: a leftover clone alone is removed with no CLI call"
else
    fail "partial ECC: a leftover clone alone is removed with no CLI call"
fi

# Prune-only needs no CLI; a CLI-needing sweep without one fails loudly.
PRUNECFG="$TMP/sweep-prune-only"
mkdir -p "$PRUNECFG/plugins"
printf '{"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope": "project", "projectPath": "%s/gone"}]}}\n' \
    "$TMP" >"$PRUNECFG/plugins/installed_plugins.json"
if (export PATH="$NOCLI_BIN" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$PRUNECFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   jget "$PRUNECFG/plugins/installed_plugins.json" "d['plugins'] == {}"; then
    pass "sweep prunes project-only records without the claude CLI"
else
    fail "sweep prunes project-only records without the claude CLI"
fi
NOCLICFG="$TMP/sweep-nocli"
mkdir -p "$NOCLICFG/plugins"
printf '{"ecc": {}}\n' >"$NOCLICFG/plugins/known_marketplaces.json"
if ! (export PATH="$NOCLI_BIN" HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$NOCLICFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   grep -qF 'claude CLI not found' "$TMP/sweep.out" &&
   jget "$NOCLICFG/plugins/known_marketplaces.json" "'ecc' in d"; then
    pass "sweep fails when ECC needs the CLI and none is on PATH"
else
    fail "sweep fails when ECC needs the CLI and none is on PATH"
fi

# An unreadable, wrong-shape or symlinked registry fails closed: no CLI call,
# no change, cache kept.
for shape in bad-json bad-shape symlink; do
    BADSWEEP="$TMP/sweep-$shape"
    mkdir -p "$BADSWEEP/plugins/cache/ecc"
    case "$shape" in
        bad-json) printf 'not json\n' >"$BADSWEEP/plugins/installed_plugins.json" ;;
        bad-shape) printf '{"plugins": {"ecc@ecc": {"scope": "user"}}}\n' >"$BADSWEEP/plugins/installed_plugins.json" ;;
        symlink)
            printf '{"version": 2, "plugins": {"ecc@ecc": []}}\n' >"$TMP/sweep-real-registry.json"
            ln -s "$TMP/sweep-real-registry.json" "$BADSWEEP/plugins/installed_plugins.json" ;;
    esac
    cp "$BADSWEEP/plugins/installed_plugins.json" "$TMP/bad.before"
    : >"$TMP/sweep-trace"
    if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
          sweep_retired_claude_plugins "$BADSWEEP" "[test]") >"$TMP/sweep.out" 2>&1 &&
       grep -qF 'unreadable plugin registry' "$TMP/sweep.out" &&
       [ ! -s "$TMP/sweep-trace" ] &&
       cmp -s "$BADSWEEP/plugins/installed_plugins.json" "$TMP/bad.before" &&
       [ -d "$BADSWEEP/plugins/cache/ecc" ]; then
        pass "sweep fails closed on a $shape registry"
    else
        fail "sweep fails closed on a $shape registry"
    fi
done

# The registry decides: a CLI that exits 0 but leaves the marketplace
# registered is a failure, even after the prune clears the records.
LIECFG="$TMP/sweep-lie"
mkdir -p "$LIECFG/plugins/cache/ecc"
printf '{"ecc": {}}\n' >"$LIECFG/plugins/known_marketplaces.json"
if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=lie HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$LIECFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   grep -qF 'is still registered' "$TMP/sweep.out" && ! grep -qF '[OK]' "$TMP/sweep.out" &&
   [ -d "$LIECFG/plugins/cache/ecc" ]; then
    pass "sweep fails and keeps the cache when the marketplace stays registered"
else
    fail "sweep fails and keeps the cache when the marketplace stays registered"
fi

# Account routing and env scrub. $HOME/.claude runs with CLAUDE_CONFIG_DIR
# unset even when the caller exported one; any other dir gets it set
# explicitly. CLAUDECODE, CLAUDE_CODE_* and HERDR_* never reach the CLI.
ROUTEHOME="$TMP/route-home"
for cfgdir in "$ROUTEHOME/.claude" "$TMP/route-work"; do
    mkdir -p "$cfgdir/plugins"
    printf '{"ecc": {}}\n' >"$cfgdir/plugins/known_marketplaces.json"
done
: >"$TMP/sweep-trace"
(export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$ROUTEHOME" \
    CLAUDE_CONFIG_DIR="$TMP/inherited" CLAUDECODE=1 HERDR_PANE_ID=w9:p9 CLAUDE_CODE_SENTINEL=1
 sweep_retired_claude_plugins "$ROUTEHOME/.claude" "[test]"
 sweep_retired_claude_plugins "$TMP/route-work" "[test]") >"$TMP/sweep.out" 2>&1
if [ "$(sed -n '1p' "$TMP/sweep-trace" | cut -d'|' -f2)" = unset ] &&
   [ "$(sed -n '2p' "$TMP/sweep-trace" | cut -d'|' -f2)" = "$TMP/route-work" ] &&
   [ "$(cut -d'|' -f3-5 "$TMP/sweep-trace" | sort -u)" = "none|none|none" ]; then
    pass "sweep routes CLAUDE_CONFIG_DIR by account and scrubs the session env"
else
    fail "sweep routes CLAUDE_CONFIG_DIR by account and scrubs the session env"
fi

# Settings guard: a CLI call that leaves settings.json unparseable gets the
# pre-call bytes back, and the sweep fails.
GUARDCFG="$TMP/sweep-guard"
mkdir -p "$GUARDCFG/plugins"
printf '{"ecc": {}}\n' >"$GUARDCFG/plugins/known_marketplaces.json"
printf '{"enabledPlugins": {"keep@me": true}}\n' >"$GUARDCFG/settings.json"
cp "$GUARDCFG/settings.json" "$TMP/guard.before"
if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=truncate HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$GUARDCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   cmp -s "$GUARDCFG/settings.json" "$TMP/guard.before"; then
    pass "sweep restores settings.json when a CLI call leaves it unparseable"
else
    fail "sweep restores settings.json when a CLI call leaves it unparseable"
fi

# The file guard covers the registry, and a settings.json the CLI creates
# where none existed.
TEARCFG="$TMP/sweep-tear"
mkdir -p "$TEARCFG/plugins"
printf '{"ecc": {}}\n' >"$TEARCFG/plugins/known_marketplaces.json"
printf '{"version": 2, "plugins": {"ecc@ecc": [{"scope": "project", "projectPath": "/gone"}]}}\n' \
    >"$TEARCFG/plugins/installed_plugins.json"
cp "$TEARCFG/plugins/installed_plugins.json" "$TMP/tear.before"
if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=tearreg HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$TEARCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   cmp -s "$TEARCFG/plugins/installed_plugins.json" "$TMP/tear.before"; then
    pass "sweep restores a registry the CLI call left unreadable"
else
    fail "sweep restores a registry the CLI call left unreadable"
fi
TEARMK="$TMP/sweep-tear-mk"
mkdir -p "$TEARMK/plugins"
printf '{"ecc": {}, "other": {}}\n' >"$TEARMK/plugins/known_marketplaces.json"
cp "$TEARMK/plugins/known_marketplaces.json" "$TMP/tearmk.before"
if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=tearmk HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$TEARMK" "[test]") >"$TMP/sweep.out" 2>&1 &&
   cmp -s "$TEARMK/plugins/known_marketplaces.json" "$TMP/tearmk.before" &&
   grep -qF 'unreadable; restored it' "$TMP/sweep.out"; then
    pass "sweep restores a known_marketplaces.json the CLI call left unreadable"
else
    fail "sweep restores a known_marketplaces.json the CLI call left unreadable"
fi
NEWSETCFG="$TMP/sweep-newsettings"
mkdir -p "$NEWSETCFG/plugins"
printf '{"ecc": {}}\n' >"$NEWSETCFG/plugins/known_marketplaces.json"
if ! (export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=truncate HOME="$TMP/sweep-home"
      sweep_retired_claude_plugins "$NEWSETCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ ! -e "$NEWSETCFG/settings.json" ] && grep -qF 'unreadable; removed it' "$TMP/sweep.out"; then
    pass "sweep removes an unparseable settings.json the CLI call created"
else
    fail "sweep removes an unparseable settings.json the CLI call created"
fi

# Without git a temp_git dir cannot be identified: it stays, one [INFO] line
# says so, and the sweep succeeds.
NOGITCFG="$TMP/sweep-nogit"
mkdir -p "$NOGITCFG/plugins/cache/temp_git_9_ecc"
git -C "$NOGITCFG/plugins/cache/temp_git_9_ecc" init -q
git -C "$NOGITCFG/plugins/cache/temp_git_9_ecc" remote add origin https://github.com/affaan-m/ECC.git
NOGIT_BIN="$TMP/nogit-bin"
mkdir -p "$NOGIT_BIN"
for tool in sh python3; do
    ln -s "$(command -v "$tool")" "$NOGIT_BIN/$tool"
done
if (export PATH="$NOGIT_BIN" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$NOGITCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ -d "$NOGITCFG/plugins/cache/temp_git_9_ecc" ] &&
   [ "$(grep -c 'git not on PATH' "$TMP/sweep.out")" = 1 ]; then
    pass "sweep without git keeps temp_git dirs and says so once"
else
    fail "sweep without git keeps temp_git dirs and says so once"
fi

# A clone renamed to .retired-* by an interrupted run is finished next time.
STAGECFG="$TMP/sweep-staged"
mkdir -p "$STAGECFG/plugins/cache/.retired-temp_git_7_ecc/objects"
if (export PATH="$NOCLI_BIN" HOME="$TMP/sweep-home"
    sweep_retired_claude_plugins "$STAGECFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   [ ! -e "$STAGECFG/plugins/cache/.retired-temp_git_7_ecc" ]; then
    pass "sweep finishes a half-removed retired temp_git clone"
else
    fail "sweep finishes a half-removed retired temp_git clone"
fi

# Prune compare-before-replace (spec R12): SWEEP_TEST_BEFORE_RECHECK runs
# right before the re-read. Appending a space keeps the JSON valid but
# changes the bytes.
RACECFG="$TMP/sweep-race"
mkdir -p "$RACECFG/plugins"
printf '{"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope": "project", "projectPath": "/gone"}]}}\n' \
    >"$RACECFG/plugins/installed_plugins.json"
if (export PATH="$NOCLI_BIN" HOME="$TMP/sweep-home" RACE_REG="$RACECFG/plugins/installed_plugins.json" \
        RACE_MARK="$TMP/race-once" \
        SWEEP_TEST_BEFORE_RECHECK='[ -e "$RACE_MARK" ] || { : >"$RACE_MARK"; printf " " >>"$RACE_REG"; }'
    sweep_retired_claude_plugins "$RACECFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   jget "$RACECFG/plugins/installed_plugins.json" "d['plugins'] == {}"; then
    pass "prune retries once when the registry changes under it"
else
    fail "prune retries once when the registry changes under it"
fi
printf '{"version": 2, "plugins": {"superpowers@claude-plugins-official": [{"scope": "project", "projectPath": "/gone"}]}}\n' \
    >"$RACECFG/plugins/installed_plugins.json"
if ! (export PATH="$NOCLI_BIN" HOME="$TMP/sweep-home" RACE_REG="$RACECFG/plugins/installed_plugins.json" \
        SWEEP_TEST_BEFORE_RECHECK='printf " " >>"$RACE_REG"'
      sweep_retired_claude_plugins "$RACECFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   grep -qF 'registry changed during the sweep' "$TMP/sweep.out" &&
   jget "$RACECFG/plugins/installed_plugins.json" "'superpowers@claude-plugins-official' in d['plugins']"; then
    pass "prune fails without writing when the registry keeps changing"
else
    fail "prune fails without writing when the registry keeps changing"
fi

# Arguments: an unknown id returns 2 and changes nothing; without python3 the
# sweep returns 1 with [X].
ARGCFG="$TMP/sweep-args"
mkdir -p "$ARGCFG/plugins/cache/ecc"
(export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
 sweep_retired_claude_plugins "$ARGCFG" "[test]" nope@nowhere) >"$TMP/sweep.out" 2>&1
if [ $? -eq 2 ] && grep -qF 'not a retired plugin: nope@nowhere' "$TMP/sweep.out" && [ -d "$ARGCFG/plugins/cache/ecc" ]; then
    pass "sweep rejects an unknown plugin id with status 2"
else
    fail "sweep rejects an unknown plugin id with status 2"
fi
if ! (export PATH="$NOPY_SWEEP_BIN"; sweep_retired_claude_plugins "$ARGCFG" "[test]") >"$TMP/sweep.out" 2>&1 &&
   grep -qF '[test] [X] python3 not on PATH' "$TMP/sweep.out"; then
    pass "sweep fails with [X] when python3 is missing"
else
    fail "sweep fails with [X] when python3 is missing"
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
if jget "$CFG/settings.json" "'ecc@ecc' not in d['enabledPlugins'] and 'ecc' not in d.get('extraKnownMarketplaces', {}) and not [k for k in d.get('env', {}) if k.startswith(('ECC_', 'GATEGUARD_'))] and 'CLAUDE_CONFIG_DIR' not in json.dumps(d)"; then
    pass "link path delivers no ECC env and no ecc@ecc key"
else
    fail "link path delivers no ECC env and no ecc@ecc key"
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

# The link path sweeps before it reconciles: one run on a dir that still
# registers ECC leaves no ecc substring in settings.json. A failed sweep does
# not stop the link, and the reconcile keeps the plugin pinned off.
LINKECC="$TMP/link-ecc"
mkdir -p "$LINKECC/plugins"
printf '{"version": 2, "plugins": {"ecc@ecc": [{"scope": "project", "projectPath": "%s/gone"}]}}\n' \
    "$TMP" >"$LINKECC/plugins/installed_plugins.json"
printf '{"ecc": {}}\n' >"$LINKECC/plugins/known_marketplaces.json"
printf '{"enabledPlugins": {"ecc@ecc": false}}\n' >"$LINKECC/settings.json"
(export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" HOME="$TMP/sweep-home"
 link_claude_config_dir "$LINKECC") >"$TMP/link-ecc.out" 2>&1
if ! grep -q ecc "$LINKECC/settings.json"; then
    pass "link path sweeps a registered ECC and leaves no ecc key"
else
    fail "link path sweeps a registered ECC and leaves no ecc key"
fi
LINKFAIL="$TMP/link-fail"
mkdir -p "$LINKFAIL/plugins"
printf '{"ecc": {}}\n' >"$LINKFAIL/plugins/known_marketplaces.json"
printf '{"version": 2, "plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' >"$LINKFAIL/plugins/installed_plugins.json"
(export PATH="$SWEEP_BIN:$PATH" SWEEP_TRACE="$TMP/sweep-trace" SWEEP_STUB=fail HOME="$TMP/sweep-home"
 link_claude_config_dir "$LINKFAIL") >"$TMP/link-fail.out" 2>&1
if [ -L "$LINKFAIL/hooks" ] &&
   jget "$LINKFAIL/settings.json" "d['enabledPlugins']['ecc@ecc'] is False and 'hooks' in d"; then
    pass "link path completes and keeps ecc@ecc pinned off when the sweep fails"
else
    fail "link path completes and keeps ecc@ecc pinned off when the sweep fails"
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
