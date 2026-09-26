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

assert_grep "ECC uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "ecc@dotfiles-workflows"' "$FUNCS"
assert_grep "no ECC install or update entry point remains" \
    sh -c "! grep -qE '^function (ecc-install|ecc-update|_codex_(stage|install|update)_ecc_plugin|_ecc_legacy_rules_notice|_claude_plugin_check_update|_claude_plugin_epoch_write)\\(' '$FUNCS'"
assert_grep "no Superpowers install or update entry point remains" \
    sh -c "! grep -qE '^function (superpowers-install|superpowers-update|_codex_(stage|install|update)_superpowers_plugin)\\(' '$FUNCS'"
assert_grep "Superpowers uninstall removes the native Codex plugin" \
    grep -q '_codex_remove_plugin "superpowers@dotfiles-workflows"' "$FUNCS"
assert_grep "install verification never greps CLI plugin listings" \
    sh -c "! grep -q 'claude plugins list' $FUNCS"
assert_grep "retired-plugin uninstallers delegate to the shared sweep" \
    sh -c "grep -qF '_claude_sweep_retired \"\$cfg_dir\" \"[ecc-uninstall]\" ecc@ecc' '$FUNCS' && grep -qF '_claude_sweep_retired \"\$cfg_dir\" \"[superpowers-uninstall]\"' '$FUNCS' && ! grep -q 'plugins uninstall ecc@ecc' '$FUNCS'"
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
# macOS TMPDIR ends in "/"; collapse the doubled slash so paths the sweep
# prints (normalized by os.path.abspath) match the ones the cases grep for.
TMP="$(cd "$TMP" && pwd)"
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

# spu: records cwd and args, and on `plugin uninstall --scope S` drops that
# scope's superpowers record. SPU_MODE=fail makes every call fail;
# SPU_MODE=corrupt exits 0 but leaves an unreadable registry.
mkdir -p "$TMP/stubs/spu"
cat >"$TMP/stubs/spu/claude" <<'EOF'
#!/bin/sh
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
printf '%s|%s\n' "$(pwd -P)" "$*" >>"$SPU_TRACE"
[ "${SPU_MODE:-ok}" = fail ] && exit 1
case "$*" in
    "plugin uninstall --scope "*)
        if [ "${SPU_MODE:-ok}" = corrupt ]; then
            printf 'not json\n' >"$cfg/plugins/installed_plugins.json"
            exit 0
        fi
        python3 - "$cfg/plugins/installed_plugins.json" "$4" <<'PY'
import json, sys
path, scope = sys.argv[1:]
with open(path) as fh:
    data = json.load(fh)
key = "superpowers@claude-plugins-official"
kept = [r for r in data["plugins"].get(key, []) if r.get("scope") != scope]
if kept:
    data["plugins"][key] = kept
else:
    data["plugins"].pop(key, None)
with open(path, "w") as fh:
    json.dump(data, fh)
PY
        ;;
esac
exit 0
EOF
chmod +x "$TMP/stubs/spu/claude"

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

# run_spu_case <home> <snippet> [mode]: superpowers-uninstall against the spu
# stub (mode ok|fail|corrupt), with Codex removal stubbed out and every
# managed path inside <home>.
run_spu_case() {
    home="$1"; snippet="$2"; spu_mode="${3:-ok}"
    HOME="$home" SPU_TRACE="$TMP/spu-trace" SPU_MODE="$spu_mode" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/spu' /usr/bin /bin)
        CLAUDE_WORK_CONFIG_DIR='$home/.claude-work'
        DOTFILEDIR='$REPO'
        CODEX_WORKFLOW_MARKETPLACE_DIR='$home/codex-workflows'
        SUPERPOWERS_REPO_DIR='$home/sources/superpowers'
        _codex_remove_plugin() { return 0; }
        $snippet
    " >"$TMP/out" 2>&1
}

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

# 6b-nobareglobqual. The sweep's globs must resolve deterministically
# regardless of the calling shell's bareglobqual setting: a shell that has
# turned it off (e.g. after `reload`) must not hard-error out of the glob
# qualifiers and abort the whole sweep.
SWEEP_REPO_NBG="$TMP/sweep-dotfiles-nbg"
SWEEP_ECC_NBG="$TMP/sweep-ecc-nbg"
SWEEP_STATE_NBG="$TMP/sweep-state-nbg"
mkdir -p "$SWEEP_REPO_NBG/claude/agents" "$SWEEP_ECC_NBG/agents"
git -C "$SWEEP_REPO_NBG" init -q
printf 'upstream\n' >"$SWEEP_ECC_NBG/agents/planner.md"
printf 'vendored\n' >"$SWEEP_REPO_NBG/claude/agents/planner.md"
if run_case broken "setopt nobareglobqual
    DOTFILEDIR='$SWEEP_REPO_NBG'
    ECC_REPO_DIR='$SWEEP_ECC_NBG'
    CLAUDE_WORK_CONFIG_DIR='$TMP/sweep-no-work-nbg'
    CODEX_WORKFLOW_MARKETPLACE_DIR='$TMP/sweep-codex-stage-nbg'
    XDG_STATE_HOME='$SWEEP_STATE_NBG'
    _codex_remove_plugin() { return 0; }
    ecc-uninstall" &&
   [ ! -e "$SWEEP_REPO_NBG/claude/agents/planner.md" ] &&
   [ "$(cat "$SWEEP_STATE_NBG"/dotfiles/ecc-retired-*/claude/agents/planner.md)" = vendored ] &&
   [ ! -e "$SWEEP_ECC_NBG" ]; then
    pass "ecc-uninstall sweep succeeds under nobareglobqual"
else
    fail "ecc-uninstall sweep succeeds under nobareglobqual"
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

# 6d. ecc-uninstall removes project-scope ECC records through the shared
#     sweep; the old unscoped `plugins uninstall` could not reach them.
mkdir -p "$TMP/stubs/eccm"
cat >"$TMP/stubs/eccm/claude" <<'EOF'
#!/bin/sh
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
printf '%s\n' "$*" >>"$ECCM_TRACE"
[ "${ECCM_MODE:-ok}" = fail ] && exit 1
[ "$1 $2 $3 $4" = "plugin marketplace remove ecc" ] || exit 0
python3 - "$cfg/plugins" <<'PY'
import json, os, sys
d = sys.argv[1]
reg = json.load(open(os.path.join(d, "installed_plugins.json")))
reg["plugins"].pop("ecc@ecc", None)
json.dump(reg, open(os.path.join(d, "installed_plugins.json"), "w"))
json.dump({}, open(os.path.join(d, "known_marketplaces.json"), "w"))
PY
EOF
chmod +x "$TMP/stubs/eccm/claude"
ECCM_HOME="$TMP/eccm-home"
mkdir -p "$ECCM_HOME/.claude/plugins/cache/ecc"
printf '{"version": 2, "plugins": {"ecc@ecc": [{"scope": "project", "projectPath": "%s/gone"}]}}\n' \
    "$TMP" >"$ECCM_HOME/.claude/plugins/installed_plugins.json"
printf '{"ecc": {}}\n' >"$ECCM_HOME/.claude/plugins/known_marketplaces.json"
: >"$TMP/eccm-trace"
if HOME="$ECCM_HOME" ECCM_TRACE="$TMP/eccm-trace" zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/eccm' /usr/bin /bin)
        DOTFILEDIR='$REPO'
        ECC_REPO_DIR='$TMP/eccm-no-checkout'
        CLAUDE_WORK_CONFIG_DIR='$TMP/eccm-no-work'
        CODEX_WORKFLOW_MARKETPLACE_DIR='$TMP/eccm-codex'
        _codex_remove_plugin() { return 0; }
        _ecc_sweep_legacy_vendored() { return 0; }
        ecc-uninstall" >"$TMP/out" 2>&1 &&
   grep -qx 'plugin marketplace remove ecc' "$TMP/eccm-trace" &&
   ! grep -q ecc@ecc "$ECCM_HOME/.claude/plugins/installed_plugins.json" &&
   [ ! -e "$ECCM_HOME/.claude/plugins/cache/ecc" ]; then
    pass "ecc-uninstall removes project-scope ECC records through the shared sweep"
else
    fail "ecc-uninstall removes project-scope ECC records through the shared sweep"
fi
printf '{"ecc": {}}\n' >"$ECCM_HOME/.claude/plugins/known_marketplaces.json"
if HOME="$ECCM_HOME" ECCM_TRACE="$TMP/eccm-trace" ECCM_MODE=fail zsh -f -c "
        path=(/usr/bin /bin)
        source '$REPO/$FUNCS'
        path=('$TMP/stubs/eccm' /usr/bin /bin)
        DOTFILEDIR='$REPO'
        ECC_REPO_DIR='$TMP/eccm-no-checkout'
        CLAUDE_WORK_CONFIG_DIR='$TMP/eccm-no-work'
        CODEX_WORKFLOW_MARKETPLACE_DIR='$TMP/eccm-codex'
        _codex_remove_plugin() { return 0; }
        _ecc_sweep_legacy_vendored() { return 0; }
        ecc-uninstall" >"$TMP/out" 2>&1; then
    fail "ecc-uninstall reports failure when the shared sweep fails"
elif grep -qF '[X] ECC uninstall was incomplete' "$TMP/out"; then
    pass "ecc-uninstall reports failure when the shared sweep fails"
else
    fail "ecc-uninstall reports failure when the shared sweep fails"
fi

# 7. Superpowers retirement.
if run_case broken '
    for f in superpowers-install superpowers-update _codex_stage_superpowers_plugin _codex_install_superpowers_plugin _codex_update_superpowers_plugin; do
        eval "function $f { : }"
    done
    source "'$REPO/$FUNCS'" >/dev/null 2>&1
    for f in superpowers-install superpowers-update _codex_stage_superpowers_plugin _codex_install_superpowers_plugin _codex_update_superpowers_plugin; do
        (( ${+functions[$f]} )) && exit 1
    done
    (( ${+functions[superpowers-uninstall]} ))'; then
    pass "retired Superpowers entry points are undefined after reload"
else
    fail "retired Superpowers entry points are undefined after reload"
fi

if run_case broken '
    function superpowers-uninstall { echo old; }
    source "'$REPO/$FUNCS'" >/dev/null 2>&1
    [[ "${functions[superpowers-uninstall]}" == *_claude_sweep_retired* ]]'; then
    pass "reload replaces an old superpowers-uninstall definition"
else
    fail "reload replaces an old superpowers-uninstall definition"
fi

SPU_HOME="$TMP/spu-home"
SPU_PROJ="$TMP/spu-project"
mkdir -p "$SPU_HOME/.claude/plugins" "$SPU_PROJ" \
    "$SPU_HOME/codex-workflows/plugins/superpowers" "$SPU_HOME/sources/superpowers"
SPU_PROJ_REAL="$(cd "$SPU_PROJ" && pwd -P)"
printf '{"plugins": {"superpowers@claude-plugins-official": [{"scope": "user"}, {"scope": "local", "projectPath": "%s"}]}}\n' \
    "$SPU_PROJ" >"$SPU_HOME/.claude/plugins/installed_plugins.json"
: >"$TMP/spu-trace"
if run_spu_case "$SPU_HOME" superpowers-uninstall &&
   grep -qF "|plugin uninstall --scope user superpowers@claude-plugins-official" "$TMP/spu-trace" &&
   ! grep -qF "$SPU_PROJ_REAL|" "$TMP/spu-trace" &&
   ! grep -q superpowers "$SPU_HOME/.claude/plugins/installed_plugins.json" &&
   grep -qF "[OK] Removed superpowers@claude-plugins-official from $SPU_HOME/.claude" "$TMP/out"; then
    pass "superpowers-uninstall removes the user record by CLI and prunes the local record"
else
    fail "superpowers-uninstall removes the user record by CLI and prunes the local record"
fi
if [ ! -e "$SPU_HOME/codex-workflows/plugins/superpowers" ] && [ ! -e "$SPU_HOME/sources/superpowers" ]; then
    pass "superpowers-uninstall removes the staged Codex copy and the source checkout"
else
    fail "superpowers-uninstall removes the staged Codex copy and the source checkout"
fi

SPU_FAILHOME="$TMP/spu-failhome"
mkdir -p "$SPU_FAILHOME/.claude/plugins"
printf '{"plugins": {"superpowers@claude-plugins-official": [{"scope": "user"}]}}\n' \
    >"$SPU_FAILHOME/.claude/plugins/installed_plugins.json"
if ! run_spu_case "$SPU_FAILHOME" superpowers-uninstall fail &&
   ! grep -qF "[OK] Removed superpowers" "$TMP/out"; then
    pass "superpowers-uninstall fails without [OK] when the uninstall command fails"
else
    fail "superpowers-uninstall fails without [OK] when the uninstall command fails"
fi

SPU_CORRUPTHOME="$TMP/spu-corrupthome"
mkdir -p "$SPU_CORRUPTHOME/.claude/plugins"
printf '{"plugins": {"superpowers@claude-plugins-official": [{"scope": "user"}]}}\n' \
    >"$SPU_CORRUPTHOME/.claude/plugins/installed_plugins.json"
if ! run_spu_case "$SPU_CORRUPTHOME" superpowers-uninstall corrupt &&
   ! grep -qF "[OK] Removed superpowers" "$TMP/out"; then
    pass "superpowers-uninstall fails when the registry is unreadable after uninstall"
else
    fail "superpowers-uninstall fails when the registry is unreadable after uninstall"
fi

SPU_SHAPEHOME="$TMP/spu-shapehome"
mkdir -p "$SPU_SHAPEHOME/.claude/plugins"
printf '{"plugins": {"superpowers@claude-plugins-official": {"scope": "user"}}}\n' \
    >"$SPU_SHAPEHOME/.claude/plugins/installed_plugins.json"
if ! run_spu_case "$SPU_SHAPEHOME" superpowers-uninstall &&
   grep -qF "unreadable plugin registry" "$TMP/out"; then
    pass "superpowers-uninstall treats a malformed record shape as unreadable"
else
    fail "superpowers-uninstall treats a malformed record shape as unreadable"
fi

SPU_EMPTYHOME="$TMP/spu-emptyhome"
mkdir -p "$SPU_EMPTYHOME/.claude"
: >"$TMP/spu-trace"
if run_spu_case "$SPU_EMPTYHOME" superpowers-uninstall &&
   [ ! -s "$TMP/spu-trace" ]; then
    pass "superpowers-uninstall with no registry file succeeds and calls no CLI"
else
    fail "superpowers-uninstall with no registry file succeeds and calls no CLI"
fi

SPU_GONEHOME="$TMP/spu-gonehome"
mkdir -p "$SPU_GONEHOME/.claude/plugins"
printf '{"plugins": {"superpowers@claude-plugins-official": [{"scope": "local", "projectPath": "%s"}]}}\n' \
    "$TMP/spu-deleted-project" >"$SPU_GONEHOME/.claude/plugins/installed_plugins.json"
: >"$TMP/spu-trace"
if run_spu_case "$SPU_GONEHOME" superpowers-uninstall &&
   [ ! -s "$TMP/spu-trace" ] &&
   ! grep -q superpowers "$SPU_GONEHOME/.claude/plugins/installed_plugins.json"; then
    pass "superpowers-uninstall prunes a local record whose projectPath is missing"
else
    fail "superpowers-uninstall prunes a local record whose projectPath is missing"
fi

SPU_BADHOME="$TMP/spu-badhome"
mkdir -p "$SPU_BADHOME/.claude/plugins"
printf 'not json\n' >"$SPU_BADHOME/.claude/plugins/installed_plugins.json"
: >"$TMP/spu-trace"
if ! run_spu_case "$SPU_BADHOME" superpowers-uninstall &&
   [ ! -s "$TMP/spu-trace" ] &&
   grep -qF "unreadable plugin registry" "$TMP/out"; then
    pass "superpowers-uninstall with an unreadable registry calls no CLI and fails"
else
    fail "superpowers-uninstall with an unreadable registry calls no CLI and fails"
fi

# 9. Uninstall must remove a present-but-disabled plugin instead of treating it
#    as absent and leaving stale config/cache state behind.
mkdir -p "$TMP/home-codex"
printf '%s\n' 'disabled:superpowers@dotfiles-workflows' >"$TMP/home-codex/codex-plugin-state"
if run_codex_case "_codex_remove_plugin superpowers@dotfiles-workflows" &&
   [ ! -f "$TMP/home-codex/codex-plugin-state" ]; then
    pass "Codex uninstall removes disabled plugins"
else
    fail "Codex uninstall removes disabled plugins"
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
