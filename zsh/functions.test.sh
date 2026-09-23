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

assert_grep "superpowers-install goes through _claude_ensure_plugin" \
    grep -q '_claude_ensure_plugin "\$cfg_dir" "superpowers@claude-plugins-official"' "$FUNCS"
assert_grep "superpowers-install installs the native Codex plugin" \
    grep -q '_codex_install_superpowers_plugin' "$FUNCS"
assert_grep "Superpowers Codex install uses the dotfiles marketplace" \
    grep -q '_codex_ensure_plugin "superpowers@dotfiles-workflows"' "$FUNCS"
assert_grep "ECC uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "ecc@dotfiles-workflows"' "$FUNCS"
assert_grep "no ECC install or update entry point remains" \
    sh -c "! grep -qE '^function (ecc-install|ecc-update|_codex_(stage|install|update)_ecc_plugin|_ecc_legacy_rules_notice|_claude_plugin_check_update|_claude_plugin_epoch_write)\\(' '$FUNCS'"
assert_grep "Superpowers uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "superpowers@dotfiles-workflows"' "$FUNCS"
assert_grep "install verification never greps CLI plugin listings" \
    sh -c "! grep -q 'claude plugins list' $FUNCS"
assert_grep "ensure helper verifies installed_plugins.json" \
    grep -q 'installed_plugins.json' "$FUNCS"
assert_grep "update() syncs via repo-sync.sh" \
    grep -q 'install/common/repo-sync.sh" "\$DOTFILEDIR"' "$FUNCS"
# git pull appears legitimately elsewhere in the file (marketplace clone
# refreshes at ~863/~1194); only the update() body must be free of it.
assert_grep "update() no longer uses plain git pull" \
    sh -c "! sed -n '/^function update()/,/^function /p' $FUNCS | grep -q 'git pull'"
assert_grep "update() aborts on unverified sync state" \
    grep -q 'pull_status < 20' "$FUNCS"

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
        mkdir -p "$cfg/plugins/marketplaces/fixture/.claude-plugin"
        printf '{"name": "fixture", "plugins": [{"name": "sample"}]}\n' \
            > "$cfg/plugins/marketplaces/fixture/.claude-plugin/marketplace.json"
        ;;
    *"plugins install"*)
        mkdir -p "$cfg/plugins"
        printf '{"plugins": {"sample@fixture": [{"scope": "user"}]}}\n' \
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

mkdir -p "$TMP/stubs/env-capture"
cat >"$TMP/stubs/env-capture/claude" <<'EOF'
#!/bin/sh
printf '%s\n' "${CLAUDE_CONFIG_DIR-unset}" >>"$CLAUDE_ENV_TRACE"
exit 0
EOF
chmod +x "$TMP/stubs/env-capture/claude"

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
            source_path=""
            if [ -f "$marketplaces" ]; then
                source_path=$(awk -v name="$marketplace" '$1 == name { print $2 }' "$marketplaces")
            fi
            if [ -n "$source_path" ]; then
                source_path="$source_path/plugins/$plugin_name"
                version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$source_path/.codex-plugin/plugin.json" | head -n 1)
                printf '{\n  "installed": [\n    {\n      "pluginId": "%s",\n      "name": "%s",\n      "marketplaceName": "%s",\n      "version": "%s",\n      "installed": true,\n      "enabled": %s,\n      "source": {"source": "local", "path": "%s"}\n    }\n  ]\n}\n' \
                    "$plugin_id" "$plugin_name" "$marketplace" "$version" "$enabled" "$source_path"
            else
                printf '{\n  "installed": [\n    {\n      "pluginId": "%s",\n      "name": "%s",\n      "marketplaceName": "%s",\n      "installed": true,\n      "enabled": %s\n    }\n  ]\n}\n' \
                    "$plugin_id" "$plugin_name" "$marketplace" "$enabled"
            fi
        else
            printf '{"installed":[]}'
        fi
        ;;
    "plugin add "*)
        plugin_id="$3"
        plugin_name=${plugin_id%%@*}
        marketplace=${plugin_id#*@}
        source_root=$(awk -v name="$marketplace" '$1 == name { print $2 }' "$marketplaces")
        source_path="$source_root/plugins/$plugin_name"
        version=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$source_path/.codex-plugin/plugin.json" | head -n 1)
        if [ -d "$source_path" ] && [ -n "$version" ]; then
            cache_path="${CODEX_HOME:-$HOME/.codex}/plugins/cache/$marketplace/$plugin_name/$version"
            rm -rf "$cache_path"
            mkdir -p "$cache_path"
            cp -R "$source_path/." "$cache_path/"
        fi
        printf '%s\n' "$plugin_id" >"$state"
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
    HOME="$TMP/home-codex" CODEX_HOME="$TMP/home-codex/.codex" DOTFILEDIR="$REPO" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/codex-good' /usr/bin /bin)
        mkdir -p \"\$HOME\"
        $snippet
    " >"$TMP/out" 2>&1
}

: >"$TMP/claude-env-trace"
if CLAUDE_ENV_TRACE="$TMP/claude-env-trace" run_case env-capture '
    export CLAUDE_ENV_TRACE="'$TMP'/claude-env-trace"
    export CLAUDE_CONFIG_DIR="'$TMP'/inherited-work"
    _claude_plugin_run "$HOME/.claude" plugins install ecc@ecc
    _claude_plugin_run "'$TMP'/work-config" plugins install ecc@ecc
' && [ "$(sed -n '1p' "$TMP/claude-env-trace")" = unset ] &&
   [ "$(sed -n '2p' "$TMP/claude-env-trace")" = "$TMP/work-config" ]; then
    pass "plugin lifecycle unsets native personal config and preserves work config"
else
    fail "plugin lifecycle unsets native personal config and preserves work config"
fi

# 1. Pre-recorded install short-circuits without ever invoking the CLI.
CFG="$TMP/cfg1"
mkdir -p "$CFG/plugins"
printf '{"plugins": {"sample@fixture": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_ensure_plugin '$CFG' sample@fixture fixture https://example.invalid/fixture.git"; then
    pass "already-installed short-circuits on installed_plugins.json"
else
    fail "already-installed short-circuits on installed_plugins.json"
fi

# 2. The exit-code lie: every CLI verb exits 0 but nothing lands on disk.
#    The helper must fail closed and say so.
CFG="$TMP/cfg2"; mkdir -p "$CFG"
if run_case silent "_claude_ensure_plugin '$CFG' sample@fixture fixture https://example.invalid/fixture.git"; then
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
if run_case unreachable "_claude_ensure_plugin '$CFG' sample@fixture fixture https://example.invalid/fixture.git"; then
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
if run_case good "_claude_ensure_plugin '$CFG' sample@fixture fixture https://example.invalid/fixture.git"; then
    pass "verified install succeeds"
else
    fail "verified install succeeds"
fi
if grep -q "Installed sample@fixture" "$TMP/out"; then
    pass "verified install reports [OK]"
else
    fail "verified install reports [OK]"
fi

# 5. _claude_plugin_installed ground truth: false without the record, true with it.
CFG="$TMP/cfg5"; mkdir -p "$CFG"
if run_case broken "_claude_plugin_installed '$CFG' sample@fixture"; then
    fail "plugin_installed false when record missing"
else
    pass "plugin_installed false when record missing"
fi
mkdir -p "$CFG/plugins"
printf '{"plugins": {"sample@fixture": [{"scope": "user"}]}}\n' >"$CFG/plugins/installed_plugins.json"
if run_case broken "_claude_plugin_installed '$CFG' sample@fixture"; then
    pass "plugin_installed true when record present"
else
    fail "plugin_installed true when record present"
fi

# 6. Codex install registers a local marketplace, installs the requested
#    plugin, and verifies the enabled state from JSON readback.
rm -rf "$TMP/home-codex"
if run_codex_case "_codex_ensure_plugin superpowers@dotfiles-workflows '$TMP/marketplace'"; then
    pass "Codex plugin install is verified"
else
    fail "Codex plugin install is verified"
fi
if grep -q "plugin marketplace add $TMP/marketplace" "$TMP/home-codex/codex-calls" &&
   grep -q "plugin add superpowers@dotfiles-workflows" "$TMP/home-codex/codex-calls"; then
    pass "Codex plugin install registers its marketplace"
else
    fail "Codex plugin install registers its marketplace"
fi

# 6a. Retired entry points survive `reload` in a long-running shell unless
#     functions.zsh drops them explicitly (re-sourcing never undefines).
if command -v zsh >/dev/null 2>&1 &&
   env -i HOME="$TMP/reload-home" PATH=/usr/bin:/bin DOTFILEDIR="$PWD" zsh -c '
    for f in ecc-install ecc-update _ecc_legacy_rules_notice _codex_stage_ecc_plugin \
             _codex_install_ecc_plugin _codex_update_ecc_plugin \
             _claude_plugin_check_update _claude_plugin_epoch_write; do
        eval "function $f { : }"
    done
    source zsh/functions.zsh >/dev/null 2>&1
    for f in ecc-install ecc-update _ecc_legacy_rules_notice _codex_stage_ecc_plugin \
             _codex_install_ecc_plugin _codex_update_ecc_plugin \
             _claude_plugin_check_update _claude_plugin_epoch_write; do
        (( ${+functions[$f]} )) && exit 1
    done
    (( ${+functions[ecc-uninstall]} ))
'; then
    pass "retired ECC entry points are undefined after reload"
else
    fail "retired ECC entry points are undefined after reload"
fi

# 6b. ecc-uninstall moves the legacy vendored copies an old full ECC install
#     wrote through the ~/.claude* symlinks (untracked files whose basename
#     exists in the ECC checkout) into a backup dir. Tracked files, symlinks
#     and unrelated files stay. A git error or a failed move stops the sweep
#     and keeps the checkout, so a rerun can still match basenames.
SWEEP_REPO="$TMP/sweep-dotfiles"
SWEEP_ECC="$TMP/sweep-ecc"
SWEEP_STATE="$TMP/sweep-state"
mkdir -p "$SWEEP_REPO/claude/agents" "$SWEEP_REPO/claude/commands" "$SWEEP_REPO/claude/hooks" \
    "$SWEEP_ECC/agents" "$SWEEP_ECC/commands" "$SWEEP_ECC/legacy-command-shims/commands" "$SWEEP_ECC/hooks"
git -C "$SWEEP_REPO" init -q
for f in agents/planner.md agents/director.md commands/tdd.md commands/commit.md hooks/hooks.json; do
    printf 'upstream\n' >"$SWEEP_ECC/$f"
done
# tdd.md exists in both upstream command dirs: the sweep must move it once.
printf 'upstream\n' >"$SWEEP_ECC/legacy-command-shims/commands/verify.md"
printf 'upstream\n' >"$SWEEP_ECC/legacy-command-shims/commands/tdd.md"
printf 'vendored\n' >"$SWEEP_REPO/claude/agents/planner.md"
printf 'ours\n' >"$SWEEP_REPO/claude/agents/director.md"
printf 'vendored\n' >"$SWEEP_REPO/claude/commands/tdd.md"
printf 'vendored\n' >"$SWEEP_REPO/claude/commands/verify.md"
printf 'ours\n' >"$SWEEP_REPO/claude/commands/commit.md"
printf 'mine\n' >"$SWEEP_REPO/claude/commands/local-only.md"
printf 'vendored\n' >"$SWEEP_REPO/claude/hooks/hooks.json"
printf 'target\n' >"$TMP/sweep-link-target"
ln -s "$TMP/sweep-link-target" "$SWEEP_REPO/claude/agents/linked.md"
printf 'upstream\n' >"$SWEEP_ECC/agents/linked.md"
git -C "$SWEEP_REPO" add claude/agents/director.md claude/commands/commit.md
SWEEP_SETUP="
    DOTFILEDIR='$SWEEP_REPO'
    ECC_REPO_DIR='$SWEEP_ECC'
    CLAUDE_WORK_CONFIG_DIR='$TMP/sweep-no-work'
    CODEX_WORKFLOW_MARKETPLACE_DIR='$TMP/sweep-codex-stage'
    XDG_STATE_HOME='$SWEEP_STATE'
    _codex_remove_plugin() { return 0; }
"
mkdir -p "$TMP/sweep-codex-stage/plugins/ecc"

# A git error must not read as "untracked".
if run_case broken "$SWEEP_SETUP
    git() { [[ \"\$1\" == -C && \"\$3\" == ls-files ]] && return 128; command git \"\$@\"; }
    ecc-uninstall"; then
    fail "ecc-uninstall aborts the sweep on a git error"
elif [ -f "$SWEEP_REPO/claude/agents/planner.md" ] &&
     [ -f "$SWEEP_REPO/claude/agents/director.md" ] &&
     [ -d "$SWEEP_ECC" ] && [ ! -e "$SWEEP_STATE" ]; then
    pass "ecc-uninstall aborts the sweep on a git error"
else
    fail "ecc-uninstall aborts the sweep on a git error"
fi

# A failed move (backup root is a regular file) stops before the checkout goes.
printf 'not a dir\n' >"$TMP/sweep-state-file"
if run_case broken "$SWEEP_SETUP XDG_STATE_HOME='$TMP/sweep-state-file'; ecc-uninstall"; then
    fail "ecc-uninstall keeps the checkout when the sweep fails"
elif [ -f "$SWEEP_REPO/claude/agents/planner.md" ] && [ -d "$SWEEP_ECC" ]; then
    pass "ecc-uninstall keeps the checkout when the sweep fails"
else
    fail "ecc-uninstall keeps the checkout when the sweep fails"
fi

# The rerun completes: every candidate lands in one backup with its content.
if run_case broken "$SWEEP_SETUP ecc-uninstall" &&
   [ ! -e "$SWEEP_REPO/claude/agents/planner.md" ] &&
   [ ! -e "$SWEEP_REPO/claude/commands/tdd.md" ] &&
   [ ! -e "$SWEEP_REPO/claude/commands/verify.md" ] &&
   [ ! -e "$SWEEP_REPO/claude/hooks/hooks.json" ] &&
   [ "$(cat "$SWEEP_STATE"/dotfiles/ecc-retired-*/claude/agents/planner.md)" = vendored ] &&
   [ "$(cat "$SWEEP_STATE"/dotfiles/ecc-retired-*/claude/commands/tdd.md)" = vendored ] &&
   [ -f "$(echo "$SWEEP_STATE"/dotfiles/ecc-retired-*)/claude/hooks/hooks.json" ] &&
   [ ! -e "$TMP/sweep-codex-stage/plugins/ecc" ] &&
   [ ! -e "$SWEEP_ECC" ]; then
    pass "ecc-uninstall moves untracked ECC-named vendored files to a backup"
else
    fail "ecc-uninstall moves untracked ECC-named vendored files to a backup"
fi
if [ -f "$SWEEP_REPO/claude/agents/director.md" ] &&
   [ -f "$SWEEP_REPO/claude/commands/commit.md" ] &&
   [ -f "$SWEEP_REPO/claude/commands/local-only.md" ] &&
   [ -L "$SWEEP_REPO/claude/agents/linked.md" ] &&
   [ -f "$TMP/sweep-link-target" ]; then
    pass "ecc-uninstall keeps tracked, symlinked and non-matching files"
else
    fail "ecc-uninstall keeps tracked, symlinked and non-matching files"
fi

# 6c. Without the checkout there is nothing to match against: list, move nothing.
printf 'vendored\n' >"$SWEEP_REPO/claude/agents/architect.md"
if run_case broken "$SWEEP_SETUP ECC_REPO_DIR='$TMP/sweep-missing-ecc'; ecc-uninstall" &&
   [ -f "$SWEEP_REPO/claude/agents/architect.md" ] &&
   [ "$(ls "$SWEEP_STATE"/dotfiles | wc -l | tr -d ' ')" = 1 ] &&
   grep -q 'architect.md' "$TMP/out"; then
    pass "ecc-uninstall without a checkout lists candidates and moves nothing"
else
    fail "ecc-uninstall without a checkout lists candidates and moves nothing"
fi

# 7. A self-contained Superpowers staging tree carries the marketplace, plugin
#    manifest, skills and assets into a Codex-only directory.
SUPERPOWERS_FIXTURE="$TMP/superpowers"
STAGED="$TMP/staged-marketplace"
mkdir -p "$SUPERPOWERS_FIXTURE/.codex-plugin" "$SUPERPOWERS_FIXTURE/skills/sample" \
    "$SUPERPOWERS_FIXTURE/skills/quoted" "$SUPERPOWERS_FIXTURE/assets"
printf '%s\n' '{"name":"superpowers","version":"1.0.0","description":"test","author":{"name":"test"},"skills":"./skills/","hooks":{},"interface":{"displayName":"Superpowers","shortDescription":"test","longDescription":"test","developerName":"test","category":"Coding","capabilities":[],"defaultPrompt":[]}}' >"$SUPERPOWERS_FIXTURE/.codex-plugin/plugin.json"
printf '%s\n' '---' 'name: sample' 'description: sample: workflow' '---' >"$SUPERPOWERS_FIXTURE/skills/sample/SKILL.md"
printf '%s\n' '---' 'name: quoted' 'description: "Quoted: description"' '---' >"$SUPERPOWERS_FIXTURE/skills/quoted/SKILL.md"
printf '%s\n' 'asset' >"$SUPERPOWERS_FIXTURE/assets/icon.svg"
if run_codex_case "SUPERPOWERS_REPO_DIR='$SUPERPOWERS_FIXTURE'; CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_stage_superpowers_plugin"; then
    pass "Superpowers Codex plugin staging succeeds"
else
    fail "Superpowers Codex plugin staging succeeds"
fi
if [ -f "$STAGED/.agents/plugins/marketplace.json" ] &&
   [ -f "$STAGED/plugins/superpowers/.codex-plugin/plugin.json" ] &&
   [ -f "$STAGED/plugins/superpowers/skills/sample/SKILL.md" ] &&
   [ -f "$STAGED/plugins/superpowers/assets/icon.svg" ]; then
    pass "Superpowers Codex plugin staging is self-contained"
else
    fail "Superpowers Codex plugin staging is self-contained"
fi
if grep -q '^description: >-$' "$STAGED/plugins/superpowers/skills/sample/SKILL.md"; then
    pass "Superpowers staging normalizes Codex skill frontmatter"
else
    fail "Superpowers staging normalizes Codex skill frontmatter"
fi
if grep -q '^description: "Quoted: description"$' "$STAGED/plugins/superpowers/skills/quoted/SKILL.md"; then
    pass "Superpowers staging preserves quoted frontmatter"
else
    fail "Superpowers staging preserves quoted frontmatter"
fi
if [ -f "$STAGED/plugins/superpowers/.dotfiles-provenance.json" ] &&
   grep -q '"wrapperVersion"' "$STAGED/plugins/superpowers/.dotfiles-provenance.json" &&
   grep -q '"upstreamCommit"' "$STAGED/plugins/superpowers/.dotfiles-provenance.json" &&
   grep -q '"upstreamVersion"' "$STAGED/plugins/superpowers/.dotfiles-provenance.json" &&
   grep -q '"payloadDigest"' "$STAGED/plugins/superpowers/.dotfiles-provenance.json"; then
    pass "Superpowers staging records wrapper upstream and payload provenance"
else
    fail "Superpowers staging records wrapper upstream and payload provenance"
fi
rm -rf "$TMP/home-codex"
if run_codex_case "CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_ensure_plugin superpowers@dotfiles-workflows '$STAGED' && _codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    pass "Superpowers native install verifies its effective staged payload"
else
    fail "Superpowers native install verifies its effective staged payload"
fi

# 7a. A caller-selected CODEX_HOME must never receive the fixture cache.
CALLER_CODEX_HOME="$TMP/caller-codex-home"
CALLER_CACHE="$CALLER_CODEX_HOME/plugins/cache/dotfiles-workflows/superpowers/1.0.0"
mkdir -p "$CALLER_CACHE"
printf '%s\n' 'caller cache sentinel' >"$CALLER_CACHE/sentinel-payload"
printf '%s\n' 'caller config sentinel' >"$CALLER_CODEX_HOME/config.toml"
cp "$CALLER_CACHE/sentinel-payload" "$TMP/caller-cache-before"
cp "$CALLER_CODEX_HOME/config.toml" "$TMP/caller-config-before"
rm -rf "$TMP/home-codex"
if (
    CODEX_HOME="$CALLER_CODEX_HOME"
    export CODEX_HOME
    run_codex_case "CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_ensure_plugin superpowers@dotfiles-workflows '$STAGED'"
) &&
   cmp -s "$TMP/caller-cache-before" "$CALLER_CACHE/sentinel-payload" &&
   cmp -s "$TMP/caller-config-before" "$CALLER_CODEX_HOME/config.toml" &&
   [ ! -e "$CALLER_CACHE/skills/sample/SKILL.md" ] &&
   [ ! -e "$CALLER_CACHE/skills/quoted/SKILL.md" ]; then
    pass "Codex test cases preserve inherited CODEX_HOME"
else
    fail "Codex test cases preserve inherited CODEX_HOME"
fi

# Keep the remaining cache-validation cases independent from this sentinel.
mkdir -p "$TMP/home-codex/.codex/plugins/cache/dotfiles-workflows/superpowers/1.0.0"
cp -R "$STAGED/plugins/superpowers/." \
    "$TMP/home-codex/.codex/plugins/cache/dotfiles-workflows/superpowers/1.0.0/"

CACHE_PAYLOAD="$TMP/home-codex/.codex/plugins/cache/dotfiles-workflows/superpowers/1.0.0"
printf '%s\n' '{}' >"$CACHE_PAYLOAD/.dotfiles-provenance.json"
if run_codex_case "_codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    fail "invalid cache provenance never verifies from staged source alone"
else
    pass "invalid cache provenance never verifies from staged source alone"
fi
cp -R "$STAGED/plugins/superpowers/." "$CACHE_PAYLOAD/"
python3 - "$CACHE_PAYLOAD/.dotfiles-provenance.json" <<'PY'
import json
from pathlib import Path

path = Path(__import__("sys").argv[1])
record = json.loads(path.read_text())
record["schemaVersion"] = "1"
path.write_text(json.dumps(record) + "\n")
PY
if run_codex_case "_codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    fail "wrong-type cache provenance never verifies"
else
    pass "wrong-type cache provenance never verifies"
fi
cp -R "$STAGED/plugins/superpowers/." "$CACHE_PAYLOAD/"
python3 - "$CACHE_PAYLOAD/.dotfiles-provenance.json" <<'PY'
import json
from pathlib import Path

path = Path(__import__("sys").argv[1])
record = json.loads(path.read_text())
record["schemaVersion"] = 2
path.write_text(json.dumps(record) + "\n")
PY
if run_codex_case "_codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    fail "unsupported cache provenance schema never verifies"
else
    pass "unsupported cache provenance schema never verifies"
fi
cp -R "$STAGED/plugins/superpowers/." "$CACHE_PAYLOAD/"
printf '%s\n' 'stale cache payload' >>"$CACHE_PAYLOAD/skills/sample/SKILL.md"
if run_codex_case "_codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    fail "stale cache bytes never verify from copied provenance alone"
else
    pass "stale cache bytes never verify from copied provenance alone"
fi
if run_codex_case "_codex_verify_or_refresh_managed_plugin superpowers@dotfiles-workflows '$STAGED/plugins/superpowers' '$STAGED'" &&
   cmp -s "$STAGED/plugins/superpowers/skills/sample/SKILL.md" "$CACHE_PAYLOAD/skills/sample/SKILL.md"; then
    pass "stale managed cache refreshes through the native lifecycle"
else
    fail "stale managed cache refreshes through the native lifecycle"
fi
FIRST_DIGEST=$(awk -F '"' '/payloadDigest/ { print $4 }' "$STAGED/plugins/superpowers/.dotfiles-provenance.json")
printf '%s\n' 'updated source payload' >>"$SUPERPOWERS_FIXTURE/skills/sample/SKILL.md"
if run_codex_case "SUPERPOWERS_REPO_DIR='$SUPERPOWERS_FIXTURE'; CODEX_WORKFLOW_MARKETPLACE_DIR='$STAGED'; _codex_stage_superpowers_plugin"; then
    SECOND_DIGEST=$(awk -F '"' '/payloadDigest/ { print $4 }' "$STAGED/plugins/superpowers/.dotfiles-provenance.json")
    if [ "$FIRST_DIGEST" != "$SECOND_DIGEST" ] &&
       grep -q '"wrapperVersion": "1.0.0"' "$STAGED/plugins/superpowers/.dotfiles-provenance.json"; then
        pass "Superpowers provenance detects new payload under unchanged wrapper version"
    else
        fail "Superpowers provenance detects new payload under unchanged wrapper version"
    fi
else
    fail "Superpowers provenance detects new payload under unchanged wrapper version"
fi
if run_codex_case "_codex_staged_plugin_is_effective superpowers@dotfiles-workflows '$STAGED/plugins/superpowers'"; then
    fail "new staged payload fails against old cache under unchanged wrapper version"
else
    pass "new staged payload fails against old cache under unchanged wrapper version"
fi
if run_codex_case "_codex_verify_or_refresh_managed_plugin superpowers@dotfiles-workflows '$STAGED/plugins/superpowers' '$STAGED'" &&
   cmp -s "$STAGED/plugins/superpowers/skills/sample/SKILL.md" "$CACHE_PAYLOAD/skills/sample/SKILL.md"; then
    pass "new staged payload refreshes its old cache through Codex"
else
    fail "new staged payload refreshes its old cache through Codex"
fi

# 8. The workflow marketplace stages Superpowers only; ECC's marketplace entry
#    is retired.
if [ -f "$STAGED/.agents/plugins/marketplace.json" ] &&
   ! grep -q '"name": "ecc"' "$STAGED/.agents/plugins/marketplace.json" &&
   [ -f "$STAGED/plugins/superpowers/assets/icon.svg" ]; then
    pass "workflow marketplace stages Superpowers only"
else
    fail "workflow marketplace stages Superpowers only"
fi
if grep -q '"hooks"' "$STAGED/plugins/superpowers/.codex-plugin/plugin.json"; then
    fail "Superpowers staging removes unsupported manifest hooks"
else
    pass "Superpowers staging removes unsupported manifest hooks"
fi

# 9. Uninstall must remove a present-but-disabled plugin instead of treating it
#    as absent and leaving stale config/cache state behind.
printf '%s\n' 'disabled:superpowers@dotfiles-workflows' >"$TMP/home-codex/codex-plugin-state"
if run_codex_case "_codex_remove_plugin superpowers@dotfiles-workflows" &&
   [ ! -f "$TMP/home-codex/codex-plugin-state" ]; then
    pass "Codex uninstall removes disabled plugins"
else
    fail "Codex uninstall removes disabled plugins"
fi

# 10. Direct native lifecycle entry points must reconcile the same selected
# Codex home after successful installs, without invoking live plugin CLIs.
LIFECYCLE_REPO="$TMP/lifecycle-repo"
mkdir -p "$LIFECYCLE_REPO/install/common"
cat >"$LIFECYCLE_REPO/install/common/codex-plugin-dedupe.sh" <<'EOF'
dedupe_codex_workflow_plugins() {
    printf 'reconcile %s\n' "${CODEX_HOME:-$HOME/.codex}" >>"$LIFECYCLE_TRACE"
    return "${RECONCILE_RESULT:-0}"
}
EOF

LIFECYCLE_SETUP="
    DOTFILEDIR='$LIFECYCLE_REPO'
    CODEX_HOME='$TMP/alternate-codex'
    LIFECYCLE_TRACE='$TMP/lifecycle-trace'
    : >\"\$LIFECYCLE_TRACE\"
    _codex_stage_superpowers_plugin() { return 0; }
    _codex_staged_plugin_is_effective() { return 0; }
    _codex_remove_plugin() { return 0; }
    _codex_ensure_plugin() {
        [[ \"\$2\" == \"\$CODEX_WORKFLOW_MARKETPLACE_DIR\" ]] || return 1
        printf 'install %s\\n' \"\$1\" >>\"\$LIFECYCLE_TRACE\"
        return \"\${INSTALL_RESULT:-0}\"
    }
    _codex_reinstall_plugin() { _codex_ensure_plugin \"\$@\"; }
"
LIFECYCLE_CALLS='_codex_install_superpowers_plugin _codex_update_superpowers_plugin'

if run_codex_case "$LIFECYCLE_SETUP
    for lifecycle_call in $LIFECYCLE_CALLS; do
        \$lifecycle_call || exit 1
    done
" && awk -v selected="$TMP/alternate-codex" '
    NR % 2 == 1 && $1 != "install" { exit 1 }
    NR % 2 == 0 && $0 != "reconcile " selected { exit 1 }
    END { if (NR != 4) exit 1 }
' "$TMP/lifecycle-trace"; then
    pass "direct Codex installs and updates reconcile the selected home afterward"
else
    fail "direct Codex installs and updates reconcile the selected home afterward"
fi

if run_codex_case "$LIFECYCLE_SETUP
    INSTALL_RESULT=1
    for lifecycle_call in $LIFECYCLE_CALLS; do
        if \$lifecycle_call; then exit 1; fi
    done
" && ! grep -q '^reconcile ' "$TMP/lifecycle-trace"; then
    pass "failed native plugin installation skips reconciliation"
else
    fail "failed native plugin installation skips reconciliation"
fi

if run_codex_case "$LIFECYCLE_SETUP
    RECONCILE_RESULT=1
    for lifecycle_call in $LIFECYCLE_CALLS; do
        if \$lifecycle_call; then exit 1; fi
    done
"; then
    pass "direct native plugin lifecycles propagate reconciliation failures"
else
    fail "direct native plugin lifecycles propagate reconciliation failures"
fi

# --- update() wiring: guarded sync + exit contract ------------------------
UPD="$TMP/upd"
mkdir -p "$UPD"
cat >"$TMP/upd-gitconfig" <<'EOF'
[user]
	name = Fixture
	email = fixture@example.invalid
[commit]
	gpgsign = false
[init]
	defaultBranch = main
EOF
# env -u: a developer shell's GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE or
# GIT_CONFIG_COUNT/PARAMETERS would redirect fixture git calls or override
# the pinned config; strip them (this zsh suite's convention is a HOME
# sandbox, not env -i, so the strip is explicit).
ugit() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
        HOME="$TMP/home" GIT_CONFIG_NOSYSTEM=1 \
        GIT_CONFIG_GLOBAL="$TMP/upd-gitconfig" git "$@"
}
ugit init -q -b main "$UPD/seed"
mkdir -p "$UPD/seed/install/common"
cp "$REPO/install/common/repo-sync.sh" "$UPD/seed/install/common/repo-sync.sh"
cat >"$UPD/seed/install/install.sh" <<'EOF'
#!/usr/bin/env bash
touch "$UPDATE_TEST_MARKER"
exit "${UPDATE_TEST_INSTALL_RC:-0}"
EOF
printf 'version 1\n' >"$UPD/seed/payload.txt"
ugit -C "$UPD/seed" add -A
ugit -C "$UPD/seed" commit -q -m fixture
ugit clone -q --bare "$UPD/seed" "$UPD/origin.git"
ugit clone -q "$UPD/origin.git" "$UPD/clone"
ugit clone -q "$UPD/origin.git" "$UPD/work"
printf 'version 2\n' >"$UPD/work/payload.txt"
ugit -C "$UPD/work" commit -q -am advance
ugit -C "$UPD/work" push -q origin main

# run_update <dotfiledir> [env VAR=... ]: run `update` in zsh with stubs
# for dotfiles/tldr; staleness cache under the sandbox HOME.
run_update() {
    updir="$1"; shift
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE \
        -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS \
    HOME="$TMP/home" XDG_CACHE_HOME="$TMP/home/.cache" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/upd-gitconfig" \
    UPDATE_TEST_MARKER="$TMP/install-ran" "$@" zsh -f -c "
        DOTFILEDIR='$updir'
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        dotfiles() { cd \"\$DOTFILEDIR\"; }
        tldr() { :; }
        cd '$TMP'
        update
        rc=\$?
        pwd -P >'$TMP/pwd-after'
        exit \$rc
    " >"$TMP/out" 2>&1
}

# u1. clean fast-forward reaches the fetched commit and installer runs.
mkdir -p "$TMP/home/.cache/dotfiles"
printf '1\n' >"$TMP/home/.cache/dotfiles/repo-staleness-result"
rm -f "$TMP/install-ran"
if run_update "$UPD/clone" \
    && [ "$(ugit -C "$UPD/clone" rev-parse HEAD)" = "$(ugit -C "$UPD/work" rev-parse HEAD)" ] \
    && [ -f "$TMP/install-ran" ]; then
    pass "update() fast-forwards to fetched commit and runs installer"
else
    fail "update() fast-forwards to fetched commit and runs installer"
fi
# u2. ...and the staleness reminder was cleared (sync 0 + install 0).
if [ ! -f "$TMP/home/.cache/dotfiles/repo-staleness-result" ]; then
    pass "clean update clears the staleness reminder"
else
    fail "clean update clears the staleness reminder"
fi

# u3. installer failure propagates its EXACT code and restores the cwd.
rm -f "$TMP/install-ran"
run_update "$UPD/clone" env UPDATE_TEST_INSTALL_RC=3; urc=$?
if [ "$urc" -eq 3 ] && [ "$(cat "$TMP/pwd-after")" = "$(cd "$TMP" && pwd -P)" ]; then
    pass "installer failure propagates exact code from update()"
else
    fail "installer failure propagates exact code from update() (rc=$urc)"
fi

# u4. sync failure is non-fatal but blocks the reminder-clear.
printf '1\n' >"$TMP/home/.cache/dotfiles/repo-staleness-result"
ugit -C "$UPD/clone" remote set-url origin "$TMP/gone"
rm -f "$TMP/install-ran"
if run_update "$UPD/clone" && [ -f "$TMP/install-ran" ] \
    && [ -s "$TMP/home/.cache/dotfiles/repo-staleness-result" ]; then
    pass "failed sync keeps update green but leaves the reminder"
else
    fail "failed sync keeps update green but leaves the reminder"
fi
ugit -C "$UPD/clone" remote set-url origin "$UPD/origin.git"

# u5. exit 30 aborts before the installer runs.
rm -f "$TMP/install-ran"
FAKE_SYNC_DIR="$UPD/abort"
mkdir -p "$FAKE_SYNC_DIR/install/common"
cat >"$FAKE_SYNC_DIR/install/common/repo-sync.sh" <<'EOF'
#!/usr/bin/env bash
exit 30
EOF
cat >"$FAKE_SYNC_DIR/install/install.sh" <<'EOF'
#!/usr/bin/env bash
touch "$UPDATE_TEST_MARKER"
EOF
run_update "$FAKE_SYNC_DIR"; urc=$?
if [ "$urc" -eq 30 ] && [ ! -f "$TMP/install-ran" ] \
    && [ "$(cat "$TMP/pwd-after")" = "$(cd "$TMP" && pwd -P)" ] \
    && grep -q 'update aborted' "$TMP/out"; then
    pass "uncertain sync state aborts update before install, cwd restored"
else
    fail "uncertain sync state aborts update before install, cwd restored (rc=$urc)"
fi

# u6. an unclassified sync exit (e.g. 143 from a SIGTERM mid-merge, where
# verification never ran) aborts before the installer, same as exit 30.
rm -f "$TMP/install-ran"
FAKE_SYNC_DIR="$UPD/killed"
mkdir -p "$FAKE_SYNC_DIR/install/common"
cat >"$FAKE_SYNC_DIR/install/common/repo-sync.sh" <<'EOF'
#!/usr/bin/env bash
exit 143
EOF
cat >"$FAKE_SYNC_DIR/install/install.sh" <<'EOF'
#!/usr/bin/env bash
touch "$UPDATE_TEST_MARKER"
EOF
run_update "$FAKE_SYNC_DIR"; urc=$?
if [ "$urc" -eq 143 ] && [ ! -f "$TMP/install-ran" ]; then
    pass "unclassified sync exit aborts update before install"
else
    fail "unclassified sync exit aborts update before install (rc=$urc)"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
