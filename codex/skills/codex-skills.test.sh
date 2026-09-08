#!/bin/sh
set -e

PASS=0
FAIL=0

assert() {
    label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf 'PASS  %s\n' "$label"
        PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert "claude-plan-review skill exists" \
    test -f codex/skills/claude-plan-review/SKILL.md
assert "claude-spec-review skill exists" \
    test -f codex/skills/claude-spec-review/SKILL.md
assert "co-review skill exists" \
    test -f codex/skills/co-review/SKILL.md
# Snapshot/base/tree, privacy, cleanup, and route behavior are exercised by
# the registered review-helper and agent-runtime suites. Keep this suite
# focused on installed discovery and links to those shared implementations.
assert "claude-plan-review uses the shared native runtime" \
    rg -q 'agent_runtime' codex/skills/claude-plan-review/SKILL.md
assert "claude-spec-review selects the Claude runtime" \
    rg -q -- '--runtime claude' codex/skills/claude-spec-review/SKILL.md
assert "co-review mentions both reviewers" \
    rg -q 'Claude.*Codex|Codex.*Claude' codex/skills/co-review/SKILL.md
assert "co-review uses the native Codex session" \
    rg -q 'Codex reviews.*in this session' codex/skills/co-review/SKILL.md
assert "co-review prevents nested Codex CLI reviews" \
    rg -q 'Do not run `codex exec`' codex/skills/co-review/SKILL.md
assert "co-review uses the Claude native review flow" \
    rg -q '/code-review' codex/skills/co-review/SKILL.md
assert "Claude co-review routes model and effort through the shared runtime" \
    rg -q 'agent_runtime' claude/skills/co-review/SKILL.md
assert "Claude co-review freezes and verifies its input" \
    sh -c 'rg -q "prepare --repo" claude/skills/co-review/SKILL.md && rg -q "verify --manifest" claude/skills/co-review/SKILL.md'
assert "Claude co-review uses ownership-checked cleanup" \
    rg -q 'cleanup --manifest' claude/skills/co-review/SKILL.md
assert "document review binds a frozen plan" \
    rg -q 'FROZEN_PLAN_SHA256' codex/skills/claude-plan-review/SKILL.md

assert "installer links repo-managed codex skills" \
    rg -q 'codex/skills' install/common/link.sh
assert "installer keeps ~/.codex/skills as a real directory" \
    rg -q 'mkdir -p "\$HOME"/\.codex/skills' install/common/link.sh
assert "installer treats Codex plugins as canonical workflow owners" \
    rg -q 'Codex plugins are the canonical owner' install/common/link.sh
assert "ECC lifecycle installs a native Codex plugin" \
    rg -q '_codex_install_ecc_plugin' zsh/functions.zsh
assert "Superpowers lifecycle installs the managed Codex plugin" \
    rg -q '_codex_ensure_plugin "superpowers@dotfiles-workflows"' zsh/functions.zsh
assert "bootstrap installs workflows for Claude and Codex" \
    rg -q 'for Claude and Codex' install/common/claude-plugins.sh
assert "ECC lifecycle never invokes the upstream Codex sync" \
    sh -c "! rg -q 'scripts/sync-ecc-to-codex.sh' zsh/functions.zsh"
assert "installer removes stale standalone Superpowers skill snapshots" \
    rg -q "name 'superpowers-\*'" install/common/link.sh
assert "installer removes stale standalone ECC skill snapshots" \
    rg -q "name 'ecc-\*'" install/common/link.sh
assert "Codex AGENTS references plugin-qualified Superpowers skills" \
    rg -q 'superpowers:brainstorming' codex/AGENTS.md
assert "Codex AGENTS defaults implementation work to worktrees" \
    rg -q '## Worktree Default' codex/AGENTS.md
assert "Codex AGENTS defines default skill routing" \
    rg -q '## Default Skill Routing' codex/AGENTS.md
assert "Codex AGENTS routes security and deployment skills by default" \
    sh -c "rg -q 'ecc:security-review' codex/AGENTS.md && rg -q 'ecc:deployment-patterns' codex/AGENTS.md"
assert "Codex AGENTS uses plugin-qualified ECC skills" \
    sh -c "rg -q 'ecc:tdd-workflow' codex/AGENTS.md && rg -q 'ecc:workspace-surface-audit' codex/AGENTS.md"
assert "Codex AGENTS keeps project-specific product names out of global defaults" \
    sh -c "! rg -q 'Peru BESS|TimescaleDB|edge/cloud/simulator|dashboard/UI' codex/AGENTS.md claude/CLAUDE.md"

project_skill_bridge_is_complete() {
    [ -L .agents/skills ] || return 1
    [ "$(readlink .agents/skills)" = "../.claude/skills" ] || return 1
    [ "$(cd .agents/skills && pwd -P)" = "$(cd .claude/skills && pwd -P)" ]
}

assert "project Codex skills bridge to canonical Claude sources" \
    project_skill_bridge_is_complete

plugin_enabled_value() {
    config="$1"
    plugin="$2"
    awk -v plugin="$plugin" '
        function clean(line) {
            sub(/[[:space:]]*#.*/, "", line)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            return line
        }
        {
            line = clean($0)
            if (line == "[plugins.\"" plugin "\"]") {
                in_plugin = 1
                next
            }
            if (in_plugin && line ~ /^\[/) exit
        }
        in_plugin && line ~ /^enabled[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "", line)
            print line
            exit
        }
    ' "$config"
}

dedupes_managed_workflow_plugins() {
    tmp_home="$(mktemp -d)"
    mkdir -p "$tmp_home/.codex"
    cat >"$tmp_home/.codex/config.toml" <<'TOML'
[plugins."superpowers@dotfiles-workflows"]
enabled = true

[plugins."superpowers@openai-curated"] # account-provisioned
enabled = true # duplicate

[plugins."superpowers@claude-plugins-official"]
enabled = true

[plugins."ecc@dotfiles-workflows"]
enabled = true

[plugins."ecc@ecc"] # upstream marketplace
enabled = true # duplicate

[plugins."unrelated@example"]
enabled = true
TOML

    HOME="$tmp_home" DOTFILEDIR="$PWD" bash install/common/link.sh >/dev/null

    [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "superpowers@dotfiles-workflows")" = true ] &&
        [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "superpowers@openai-curated")" = false ] &&
        [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "superpowers@claude-plugins-official")" = false ] &&
        [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "ecc@dotfiles-workflows")" = true ] &&
        [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "ecc@ecc")" = false ] &&
        [ "$(plugin_enabled_value "$tmp_home/.codex/config.toml" "unrelated@example")" = true ] || {
            rm -rf "$tmp_home"
            return 1
        }

    first_cksum="$(cksum "$tmp_home/.codex/config.toml")"
    HOME="$tmp_home" DOTFILEDIR="$PWD" bash install/common/link.sh >/dev/null
    second_cksum="$(cksum "$tmp_home/.codex/config.toml")"
    rm -rf "$tmp_home"
    [ "$first_cksum" = "$second_cksum" ]
}

assert "installer disables duplicate managed workflow providers" \
    dedupes_managed_workflow_plugins

assert "plugin lifecycle re-runs workflow dedupe post-install" \
    rg -q '^reconcile_codex_workflow_plugins_for_install$' install/common/claude-plugins.sh

removes_stale_claude_web_codex_hook() {
    tmp_home="$(mktemp -d)"
    tmp_repo="$tmp_home/dotfiles"
    mkdir -p "$tmp_repo/.codex/hooks"
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/.codex/hooks/session-start.sh"}]}]}}\n' \
        "$tmp_repo" >"$tmp_repo/.codex/hooks.json"
    printf '#!/bin/sh\n[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0\nexec "$PWD/bootstrap-cloud.sh"\n' \
        >"$tmp_repo/.codex/hooks/session-start.sh"

    for path in install zsh git ssh claude bin ghostty codex; do
        ln -s "$PWD/$path" "$tmp_repo/$path"
    done

    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    result=0
    test ! -e "$tmp_repo/.codex/hooks.json" || result=1
    test ! -e "$tmp_repo/.codex/hooks/session-start.sh" || result=1
    test ! -e "$tmp_repo/.codex" || result=1
    rm -rf "$tmp_home"
    return "$result"
}

assert "installer removes stale Claude-web hooks from the Codex project surface" \
    removes_stale_claude_web_codex_hook

preserves_multi_command_codex_hook_manifest() {
    tmp_home="$(mktemp -d)"
    tmp_repo="$tmp_home/dotfiles"
    mkdir -p "$tmp_repo/.codex/hooks"
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/.codex/hooks/session-start.sh"},{"type":"command","command":"echo keep-me"}]}]}}\n' \
        "$tmp_repo" >"$tmp_repo/.codex/hooks.json"
    printf '#!/bin/sh\n[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0\nexec "$PWD/bootstrap-cloud.sh"\n' \
        >"$tmp_repo/.codex/hooks/session-start.sh"

    for path in install zsh git ssh claude bin ghostty codex; do
        ln -s "$PWD/$path" "$tmp_repo/$path"
    done

    cp "$tmp_repo/.codex/hooks.json" "$tmp_home/manifest.before"
    cp "$tmp_repo/.codex/hooks/session-start.sh" "$tmp_home/script.before"
    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    result=0
    cmp -s "$tmp_repo/.codex/hooks.json" "$tmp_home/manifest.before" || result=1
    cmp -s "$tmp_repo/.codex/hooks/session-start.sh" "$tmp_home/script.before" || result=1
    rm -rf "$tmp_home"
    return "$result"
}

assert "installer preserves a multi-command Codex hook manifest" \
    preserves_multi_command_codex_hook_manifest

sweeps_empty_codex_project_dirs() {
    tmp_home="$(mktemp -d)"
    tmp_repo="$tmp_home/dotfiles"
    mkdir -p "$tmp_repo/.codex/hooks"

    for path in install zsh git ssh claude bin ghostty codex; do
        ln -s "$PWD/$path" "$tmp_repo/$path"
    done

    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    result=0
    test ! -e "$tmp_repo/.codex" || result=1
    rm -rf "$tmp_home"
    return "$result"
}

assert "installer sweeps empty legacy Codex project dirs" \
    sweeps_empty_codex_project_dirs

preserves_codex_hook_with_unrecognized_script() {
    tmp_home="$(mktemp -d)"
    tmp_repo="$tmp_home/dotfiles"
    mkdir -p "$tmp_repo/.codex/hooks"
    printf '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"%s/.codex/hooks/session-start.sh"}]}]}}\n' \
        "$tmp_repo" >"$tmp_repo/.codex/hooks.json"
    printf '#!/bin/sh\necho not-the-legacy-bootstrap\n' \
        >"$tmp_repo/.codex/hooks/session-start.sh"

    for path in install zsh git ssh claude bin ghostty codex; do
        ln -s "$PWD/$path" "$tmp_repo/$path"
    done

    cp "$tmp_repo/.codex/hooks.json" "$tmp_home/manifest.before"
    cp "$tmp_repo/.codex/hooks/session-start.sh" "$tmp_home/script.before"
    HOME="$tmp_home" DOTFILEDIR="$tmp_repo" bash install/common/link.sh >/dev/null
    result=0
    cmp -s "$tmp_repo/.codex/hooks.json" "$tmp_home/manifest.before" || result=1
    cmp -s "$tmp_repo/.codex/hooks/session-start.sh" "$tmp_home/script.before" || result=1
    rm -rf "$tmp_home"
    return "$result"
}

assert "installer preserves a Codex hook whose script is not the legacy bootstrap" \
    preserves_codex_hook_with_unrecognized_script

links_shared_workflow_surfaces() (
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    HOME="$tmp_home" DOTFILEDIR="$PWD" bash install/common/link.sh >/dev/null
    HOME="$tmp_home" DOTFILEDIR="$PWD" bash install/common/link.sh >/dev/null
    for skill in repo-recall post-merge todos handoff kickoff; do
        [ "$(readlink "$tmp_home/.codex/skills/$skill")" = "$PWD/claude/skills/$skill" ] || return 1
        [ -f "$tmp_home/.codex/skills/$skill/SKILL.md" ] || return 1
    done
    [ "$(readlink "$tmp_home/.codex/skills/herdr-orchestration")" = "$PWD/codex/skills/herdr-orchestration" ] || return 1
    [ -f "$tmp_home/.codex/skills/herdr-orchestration/SKILL.md" ] || return 1
    [ "$(readlink "$tmp_home/.codex/rules/agent-lessons.md")" = "$PWD/claude/rules/personal/agent-lessons.md" ] || return 1
    [ "$(readlink "$tmp_home/.codex/hooks/herdr_worktree_guard.py")" = "$PWD/claude/hooks/herdr_worktree_guard.py" ] || return 1
    [ "$(rg -c 'command = .*herdr_worktree_guard.py' "$tmp_home/.codex/config.toml")" -eq 1 ] || return 1
    printf '%s\n' '{"tool_name":"exec_command","tool_input":{"cmd":"herdr worktree create task"}}' |
        "$tmp_home/.codex/hooks/herdr_worktree_guard.py" >/dev/null 2>&1 && return 1
    [ "$?" -eq 2 ]
)

assert "installer shares maintained workflows and Herd guard with Codex" \
    links_shared_workflow_surfaces

preserves_custom_codex_skill_destinations() (
    tmp_home="$(mktemp -d)"
    trap 'rm -rf "$tmp_home"' EXIT
    for skill in repo-recall claude-plan-review; do
        mkdir -p "$tmp_home/.codex/skills/$skill"
        printf 'custom skill\n' >"$tmp_home/.codex/skills/$skill/SKILL.md"
    done
    for skill in todos co-review; do
        printf 'custom file\n' >"$tmp_home/.codex/skills/$skill"
    done
    ln -s "$tmp_home/missing-old-skill" "$tmp_home/.codex/skills/post-merge"
    mkdir -p "$tmp_home/custom-target"
    printf 'keep target\n' >"$tmp_home/custom-target/personal.txt"
    ln -s "$tmp_home/custom-target" "$tmp_home/.codex/skills/claude-spec-review"
    HOME="$tmp_home" CODEX_HOME="$tmp_home/.codex" DOTFILEDIR="$PWD" bash install/common/link.sh >"$tmp_home/install.out" 2>"$tmp_home/install.err"
    for skill in repo-recall claude-plan-review; do
        [ ! -L "$tmp_home/.codex/skills/$skill" ] || return 1
        [ "$(cat "$tmp_home/.codex/skills/$skill/SKILL.md")" = 'custom skill' ] || return 1
        [ ! -e "$tmp_home/.codex/skills/$skill/$skill" ] || return 1
        rg -q -F "Preserving existing Codex skill: $tmp_home/.codex/skills/$skill" "$tmp_home/install.err" || return 1
    done
    for skill in todos co-review; do
        [ ! -L "$tmp_home/.codex/skills/$skill" ] || return 1
        [ "$(cat "$tmp_home/.codex/skills/$skill")" = 'custom file' ] || return 1
        rg -q -F "Preserving existing Codex skill: $tmp_home/.codex/skills/$skill" "$tmp_home/install.err" || return 1
    done
    [ "$(readlink "$tmp_home/.codex/skills/post-merge")" = "$PWD/claude/skills/post-merge" ] || return 1
    [ "$(readlink "$tmp_home/.codex/skills/claude-spec-review")" = "$PWD/codex/skills/claude-spec-review" ] || return 1
    [ "$(cat "$tmp_home/custom-target/personal.txt")" = 'keep target' ] || return 1
    [ ! -e "$tmp_home/custom-target/claude-spec-review" ]
)

assert "installer preserves custom skill directories and files while refreshing symlinks" \
    preserves_custom_codex_skill_destinations

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
