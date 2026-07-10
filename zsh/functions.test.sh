#!/bin/sh
# functions.test.sh -- behavioral tests for the Claude and Codex plugin
# ground-truth helpers in zsh/functions.zsh.
#
# The helpers verify installs against <config-dir>/plugins/installed_plugins.json
# instead of trusting `claude` exit codes (ported from bootstrap-cloud.sh; the
# CLI can exit 0 without installing). Each behavioral case runs the real
# functions in zsh against a stub `claude` CLI and a sandbox config dir.
#
# Requires zsh; when absent (some containers), behavioral cases are skipped
# with a notice and only the static assertions run. CI installs zsh, so the
# full suite always runs there.

set -u

FUNCS=zsh/functions.zsh
if [ ! -f "$FUNCS" ]; then
    echo "FAIL: $FUNCS not found (run from repo root)" >&2
    exit 2
fi

PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

# --- static assertions (always run) ---
assert_grep() {
    label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

assert_grep "ecc-install goes through _claude_ensure_plugin" \
    grep -q '_claude_ensure_plugin "\$cfg_dir" "ecc@ecc"' "$FUNCS"
assert_grep "superpowers-install goes through _claude_ensure_plugin" \
    grep -q '_claude_ensure_plugin "\$cfg_dir" "superpowers@claude-plugins-official"' "$FUNCS"
assert_grep "ecc-install installs the native Codex plugin" \
    grep -q '_codex_install_ecc_plugin' "$FUNCS"
assert_grep "superpowers-install installs the native Codex plugin" \
    grep -q '_codex_install_superpowers_plugin' "$FUNCS"
assert_grep "Superpowers Codex install uses the dotfiles marketplace" \
    grep -q '_codex_ensure_plugin "superpowers@dotfiles-workflows"' "$FUNCS"
assert_grep "ECC no longer runs the unsafe upstream Codex sync" \
    sh -c "! grep -q 'scripts/sync-ecc-to-codex.sh' $FUNCS"
assert_grep "ECC uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "ecc@dotfiles-workflows"' "$FUNCS"
assert_grep "Superpowers uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "superpowers@dotfiles-workflows"' "$FUNCS"
assert_grep "install verification never greps CLI plugin listings" \
    sh -c "! grep -q 'claude plugins list' $FUNCS"
assert_grep "ensure helper verifies installed_plugins.json" \
    grep -q 'installed_plugins.json' "$FUNCS"

if ! command -v zsh >/dev/null 2>&1; then
    echo "SKIP: zsh not installed; behavioral cases run in CI (which installs zsh)"
    printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
    [ "$FAIL" = 0 ]
    exit $?
fi

REPO="$(pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/functions-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

# Stub CLIs. Each is a fake `claude` put first on PATH for one case.
# silent: every verb "succeeds" but writes nothing -- the exit-code lie.
mkdir -p "$TMP/stubs/silent"
cat >"$TMP/stubs/silent/claude" <<'EOF'
#!/bin/sh
exit 0
EOF

# unreachable: marketplace registration itself fails (network down).
mkdir -p "$TMP/stubs/unreachable"
cat >"$TMP/stubs/unreachable/claude" <<'EOF'
#!/bin/sh
case "$*" in
    *"marketplace add"*) echo "network error" >&2; exit 1 ;;
esac
exit 0
EOF

# good: writes the manifest on marketplace verbs and the install record on
# install, into the config dir the caller passed via CLAUDE_CONFIG_DIR.
mkdir -p "$TMP/stubs/good"
cat >"$TMP/stubs/good/claude" <<'EOF'
#!/bin/sh
cfg="${CLAUDE_CONFIG_DIR:?}"
case "$*" in
    *"marketplace add"*|*"marketplace update"*)
        mkdir -p "$cfg/plugins/marketplaces/ecc/.claude-plugin"
        printf '{"name": "ecc", "plugins": [{"name": "ecc"}]}\n' \
            > "$cfg/plugins/marketplaces/ecc/.claude-plugin/marketplace.json"
        ;;
    *"plugins install"*)
        mkdir -p "$cfg/plugins"
        printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' \
            > "$cfg/plugins/installed_plugins.json"
        ;;
esac
exit 0
EOF

# broken: any invocation fails loudly -- proves the caller never reached the CLI.
mkdir -p "$TMP/stubs/broken"
cat >"$TMP/stubs/broken/claude" <<'EOF'
#!/bin/sh
echo "claude should not have been invoked" >&2
exit 1
EOF
chmod +x "$TMP"/stubs/*/claude

# Codex stub: records marketplace and plugin operations in HOME so the real
# helpers can verify state through `codex plugin list --json`.
mkdir -p "$TMP/stubs/codex-good"
cat >"$TMP/stubs/codex-good/codex" <<'EOF'
#!/bin/sh
state="$HOME/codex-plugin-state"
marketplaces="$HOME/codex-marketplaces"
log="$HOME/codex-calls"
printf '%s\n' "$*" >>"$log"
case "$1 $2 ${3:-}" in
    "plugin marketplace list")
        printf 'MARKETPLACE ROOT\n'
        [ -f "$marketplaces" ] && cat "$marketplaces"
        ;;
    "plugin marketplace add")
        printf 'dotfiles-workflows %s\n' "$4" >"$marketplaces"
        ;;
    "plugin list --json")
        if [ -f "$state" ]; then
            plugin_id=$(cat "$state")
            enabled=true
            case "$plugin_id" in
                disabled:*) enabled=false; plugin_id=${plugin_id#disabled:} ;;
            esac
            plugin_name=${plugin_id%%@*}
            marketplace=${plugin_id#*@}
            printf '{\n  "installed": [\n    {\n      "pluginId": "%s",\n      "name": "%s",\n      "marketplaceName": "%s",\n      "installed": true,\n      "enabled": %s\n    }\n  ]\n}\n' \
                "$plugin_id" "$plugin_name" "$marketplace" "$enabled"
        else
            printf '{"installed":[]}'
        fi
        ;;
    "plugin add "*)
        printf '%s\n' "$3" >"$state"
        ;;
    "plugin remove "*)
        rm -f "$state"
        ;;
esac
EOF
chmod +x "$TMP/stubs/codex-good/codex"

# run_case <stub> <snippet>: source functions.zsh with claude OFF the PATH (so
# source-time update checks no-op), then put the stub first and eval the
# snippet with a fast retry budget. Output lands in $TMP/out.
run_case() {
    stub="$1"; snippet="$2"
    HOME="$TMP/home" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/$stub' /usr/bin /bin)
        CLAUDE_PLUGIN_RETRIES=2
        CLAUDE_PLUGIN_RETRY_DELAY=0
        $snippet
    " >"$TMP/out" 2>&1
}

run_codex_case() {
    snippet="$1"
    HOME="$TMP/home-codex" DOTFILEDIR="$REPO" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/codex-good' /usr/bin /bin)
        mkdir -p \"\$HOME\"
        $snippet
    " >"$TMP/out" 2>&1
}

# 1. Pre-recorded install short-circuits without ever invoking the CLI.
CFG="$TMP/cfg1"
mkdir -p "$CFG/plugins"
printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    pass "already-installed short-circuits on installed_plugins.json"
else
    fail "already-installed short-circuits on installed_plugins.json"
fi

# 2. The exit-code lie: every CLI verb exits 0 but nothing lands on disk.
#    The helper must fail closed and say so.
CFG="$TMP/cfg2"; mkdir -p "$CFG"
if run_case silent "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    fail "silent no-op install fails closed"
else
    pass "silent no-op install fails closed"
fi
if grep -q "not installed after" "$TMP/out"; then
    pass "silent no-op failure names the cause"
else
    fail "silent no-op failure names the cause"
fi

# 3. Unreachable marketplace: registration fails, helper returns non-zero.
CFG="$TMP/cfg3"; mkdir -p "$CFG"
if run_case unreachable "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    fail "unreachable marketplace returns non-zero"
else
    pass "unreachable marketplace returns non-zero"
fi
if grep -q "marketplace add failed" "$TMP/out"; then
    pass "unreachable marketplace says so"
else
    fail "unreachable marketplace says so"
fi

# 4. Healthy path: install writes the record, helper verifies and succeeds.
CFG="$TMP/cfg4"; mkdir -p "$CFG"
if run_case good "_claude_ensure_plugin '$CFG' ecc@ecc ecc https://example.invalid/ecc.git"; then
    pass "verified install succeeds"
else
    fail "verified install succeeds"
fi
if grep -q "Installed ecc@ecc" "$TMP/out"; then
    pass "verified install reports [OK]"
else
    fail "verified install reports [OK]"
fi

# 5. _claude_plugin_installed ground truth: false without the record, true with it.
CFG="$TMP/cfg5"; mkdir -p "$CFG"
if run_case broken "_claude_plugin_installed '$CFG' ecc@ecc"; then
    fail "plugin_installed false when record missing"
else
    pass "plugin_installed false when record missing"
fi
mkdir -p "$CFG/plugins"
printf '{"plugins": {"ecc@ecc": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_plugin_installed '$CFG' ecc@ecc"; then
    pass "plugin_installed true when record present"
else
    fail "plugin_installed true when record present"
fi

# 6. Codex install registers a local marketplace, installs the requested
#    plugin, and verifies the enabled state from JSON readback.
rm -rf "$TMP/home-codex"
if run_codex_case "_codex_ensure_plugin ecc@dotfiles-workflows '$TMP/marketplace'"; then
    pass "Codex plugin install is verified"
else
    fail "Codex plugin install is verified"
fi
if grep -q "plugin marketplace add $TMP/marketplace" "$TMP/home-codex/codex-calls" &&
   grep -q "plugin add ecc@dotfiles-workflows" "$TMP/home-codex/codex-calls"; then
    pass "Codex plugin install registers its marketplace"
else
    fail "Codex plugin install registers its marketplace"
fi

# 7. A self-contained ECC staging tree must carry the marketplace, plugin
#    manifest, skills, MCP config, and assets into a Codex-only directory.
ECC_FIXTURE="$TMP/ecc"
STAGED="$TMP/staged-marketplace"
mkdir -p "$ECC_FIXTURE/skills/sample" "$ECC_FIXTURE/skills/quoted" "$ECC_FIXTURE/assets"
printf '%s\n' '---' 'name: sample' 'description: sample: workflow' '---' >"$ECC_FIXTURE/skills/sample/SKILL.md"
printf '%s\n' '---' 'name: quoted' 'description: "Quoted: description"' '---' >"$ECC_FIXTURE/skills/quoted/SKILL.md"
printf '%s\n' '{}' >"$ECC_FIXTURE/.mcp.json"
printf '%s\n' 'asset' >"$ECC_FIXTURE/assets/ecc-icon.svg"
if run_codex_case "ECC_REPO_DIR='$ECC_FIXTURE'; CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_stage_ecc_plugin"; then
    pass "ECC Codex plugin staging succeeds"
else
    fail "ECC Codex plugin staging succeeds"
fi
if [ -f "$STAGED/.agents/plugins/marketplace.json" ] &&
   [ -f "$STAGED/plugins/ecc/.codex-plugin/plugin.json" ] &&
   [ -f "$STAGED/plugins/ecc/skills/sample/SKILL.md" ] &&
   [ -f "$STAGED/plugins/ecc/.mcp.json" ] &&
   [ -f "$STAGED/plugins/ecc/assets/ecc-icon.svg" ]; then
    pass "ECC Codex plugin staging is self-contained"
else
    fail "ECC Codex plugin staging is self-contained"
fi
if grep -q '^description: >-$' "$STAGED/plugins/ecc/skills/sample/SKILL.md"; then
    pass "ECC staging normalizes Codex skill frontmatter"
else
    fail "ECC staging normalizes Codex skill frontmatter"
fi
if grep -q '^description: "Quoted: description"$' "$STAGED/plugins/ecc/skills/quoted/SKILL.md"; then
    pass "ECC staging preserves quoted frontmatter"
else
    fail "ECC staging preserves quoted frontmatter"
fi

# 8. Superpowers is independently staged into the same native marketplace,
#    without depending on Codex's account-provisioned curated marketplace.
SUPERPOWERS_FIXTURE="$TMP/superpowers"
mkdir -p "$SUPERPOWERS_FIXTURE/.codex-plugin" "$SUPERPOWERS_FIXTURE/skills/brainstorming" "$SUPERPOWERS_FIXTURE/assets"
printf '%s\n' '{"name":"superpowers","version":"1.0.0","description":"test","author":{"name":"test"},"skills":"./skills/","interface":{"displayName":"Superpowers","shortDescription":"test","longDescription":"test","developerName":"test","category":"Coding","capabilities":[],"defaultPrompt":[]}}' >"$SUPERPOWERS_FIXTURE/.codex-plugin/plugin.json"
printf '%s\n' '---' 'name: brainstorming' 'description: Brainstorm before implementation.' '---' >"$SUPERPOWERS_FIXTURE/skills/brainstorming/SKILL.md"
printf '%s\n' 'asset' >"$SUPERPOWERS_FIXTURE/assets/icon.svg"
if run_codex_case "SUPERPOWERS_REPO_DIR='$SUPERPOWERS_FIXTURE'; CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_stage_superpowers_plugin"; then
    pass "Superpowers Codex plugin staging succeeds"
else
    fail "Superpowers Codex plugin staging succeeds"
fi
if [ -f "$STAGED/plugins/ecc/skills/sample/SKILL.md" ] &&
   [ -f "$STAGED/plugins/superpowers/.codex-plugin/plugin.json" ] &&
   [ -f "$STAGED/plugins/superpowers/skills/brainstorming/SKILL.md" ] &&
   [ -f "$STAGED/plugins/superpowers/assets/icon.svg" ]; then
    pass "workflow staging preserves both native plugins"
else
    fail "workflow staging preserves both native plugins"
fi

# 9. Uninstall must remove a present-but-disabled plugin instead of treating it
#    as absent and leaving stale config/cache state behind.
printf '%s\n' 'disabled:ecc@dotfiles-workflows' >"$TMP/home-codex/codex-plugin-state"
if run_codex_case "_codex_remove_plugin ecc@dotfiles-workflows" &&
   [ ! -f "$TMP/home-codex/codex-plugin-state" ]; then
    pass "Codex uninstall removes disabled plugins"
else
    fail "Codex uninstall removes disabled plugins"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
