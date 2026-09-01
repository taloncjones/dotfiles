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
assert "claude-plan-review invokes Claude reviewer" \
    rg -q 'claude' codex/skills/claude-plan-review/SKILL.md
assert "claude-spec-review invokes Claude reviewer" \
    rg -q 'claude -p' codex/skills/claude-spec-review/SKILL.md
assert "claude-plan-review uses valid no-tools flag" \
    rg -q -- '--tools ""' codex/skills/claude-plan-review/SKILL.md
assert "co-review mentions both reviewers" \
    rg -q 'Claude.*Codex|Codex.*Claude' codex/skills/co-review/SKILL.md
assert "co-review uses internal Codex session" \
    rg -q 'current Codex session' codex/skills/co-review/SKILL.md
assert "co-review does not spawn nested codex review" \
    rg -q 'Do not launch `codex review`' codex/skills/co-review/SKILL.md
assert "co-review uses Claude native code review" \
    rg -q 'claude -p "/code-review' codex/skills/co-review/SKILL.md
assert "Claude co-review pins Codex Sol" \
    sh -c "[ \"\$(rg -o -- '-m gpt-5\\.6-sol' claude/skills/co-review/SKILL.md | wc -l | tr -d ' ')\" -eq 1 ]"
assert "Claude co-review defaults Codex to high effort" \
    sh -c "[ \"\$(rg -o 'model_reasoning_effort=\\\"high\\\"' claude/skills/co-review/SKILL.md | wc -l | tr -d ' ')\" -eq 1 ]"
assert "Claude co-review defines an adversarial Codex rubric" \
    sh -c "rg -q 'CODEX_REVIEW_RUBRIC=' claude/skills/co-review/SKILL.md && rg -q 'runtime correctness' claude/skills/co-review/SKILL.md"
assert "Claude co-review reserves xhigh for high-risk changes" \
    sh -c "rg -q 'Escalate Codex to .*xhigh.* only for' claude/skills/co-review/SKILL.md && rg -U -q '(?s)high-risk changes involving auth/security.*concurrency/lifecycle.*migrations.*hardware safety' claude/skills/co-review/SKILL.md"
assert "Claude co-review reports the selected Codex effort" \
    rg -q '<codex-effort> effort' claude/skills/co-review/SKILL.md

# Pinning assertions -- guarantees already merged in PR #69; no negative test.
assert "Claude co-review invokes Codex exactly once" \
    sh -c "[ \"\$(rg -c -F '( cd \"\$WT\" && codex exec review --base' claude/skills/co-review/SKILL.md | tr -d ' ')\" -eq 1 ]"
assert "Claude co-review forbids subagent Codex invocations" \
    sh -c "[ \"\$(rg -c -F 'does not exempt this subagent' claude/skills/co-review/SKILL.md | tr -d ' ')\" -eq 2 ]"
assert "Claude co-review tears down the worktree unconditionally" \
    sh -c "rg -q 'unconditional finalization' claude/skills/co-review/SKILL.md && rg -q -F 'git worktree remove --force \"\$WT\"' claude/skills/co-review/SKILL.md"

# Slice assertions -- new guarantees from this branch; each MUST fail against
# the pre-slice SKILL.md (verified when first added, before the skill edits).
assert "Claude co-review pins the PR base to a merge-base SHA" \
    sh -c "rg -q -F 'merge-base FETCH_HEAD \"\$PR_HEAD\"' claude/skills/co-review/SKILL.md && rg -q -F 'fetch origin \"\$BASE_REF\"' claude/skills/co-review/SKILL.md"
assert "Claude co-review pins the branch-mode base against the pinned head" \
    sh -c "rg -q -F 'git merge-base <branch-the-work-forked-from> \"\$SNAP_HEAD\"' claude/skills/co-review/SKILL.md"
assert "Claude co-review guards the empty diff in every mode" \
    sh -c "rg -q -F 'diff --quiet \"\$SNAP_BASE\" \"\$SNAP_HEAD\"' claude/skills/co-review/SKILL.md"
assert "Claude co-review checks out the PR detached" \
    sh -c "rg -q -F 'gh pr checkout <n> --detach' claude/skills/co-review/SKILL.md"
assert "Claude co-review re-runs teardown in the re-review pass" \
    sh -c "rg -q 'Steps 1-3\.6 run again' claude/skills/co-review/SKILL.md"
assert "Claude co-review forbids generic Codex invocations" \
    rg -q -F 'NEVER invoke Codex' claude/skills/co-review/SKILL.md

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
    sh -c "rg -q 'dedupe_codex_workflow_plugins' install/common/claude-plugins.sh"

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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
