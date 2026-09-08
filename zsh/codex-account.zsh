#!/bin/zsh
# Sourced by .zshenv in every shell mode. Only codex launches do a Git
# lookup; startup stays silent and uses no external commands.
# Personal repositories do not need Atlassian. Keep the native plugin and
# account configuration available for work, and override only this launch.

function codex() {
    emulate -L zsh
    # The machine's personal-only policy applies regardless of launch directory.
    if [[ "${CLAUDE_PERSONAL_ONLY:-}" == 1 ]]; then
        command codex -c 'plugins."atlassian@claude-plugins-official".enabled=false' "$@"
        return $?
    fi
    local target="$PWD" scope kind personal_repository
    local arg take_cd=0
    for arg in "$@"; do
        if (( take_cd )); then
            target="$arg"
            take_cd=0
            continue
        fi
        case "$arg" in
            --) break ;;
            -C|--cd) take_cd=1 ;;
            --cd=*) target="${arg#--cd=}" ;;
            -C=*) target="${arg#-C=}" ;;
            -C?*) target="${arg#-C}" ;;
        esac
    done
    target="${target:A}"
    scope="$(workflow_account_scope "$target" codex)" || {
        echo "[X] Codex account context is ambiguous; relaunch with CLAUDE_PERSONAL_ONLY=1 for a personal scope." >&2
        return 2
    }
    kind="$(workflow_scope_field "$scope" kind)" || return 2
    personal_repository="$(workflow_scope_bool "$scope" personal_repository)" || return 2
    if [[ "$kind" == personal && "$personal_repository" == 1 ]]; then
        command codex -c 'plugins."atlassian@claude-plugins-official".enabled=false' "$@"
    else
        command codex "$@"
    fi
}
