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
    local target="$PWD" personal_tree="$HOME/Git/personal"
    local arg common_dir owner take_cd=0
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
    owner="$target"

    # A linked worktree can live outside its owner's directory convention.
    # Resolve relative common-dir results from the effective launch target,
    # ignoring Git variables inherited from a hook or another repository.
    common_dir="$(
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
        command git -C "$target" rev-parse --git-common-dir 2>/dev/null
    )"
    if [[ -n "$common_dir" ]]; then
        [[ "$common_dir" == /* ]] || common_dir="$target/$common_dir"
        owner="${common_dir:A}"
    fi

    # A personal checkout remains personal even when its Git metadata is elsewhere.
    if [[ "$target/" == "${personal_tree:A}/"* || "$owner/" == "${personal_tree:A}/"* ]]; then
        command codex -c 'plugins."atlassian@claude-plugins-official".enabled=false' "$@"
    else
        command codex "$@"
    fi
}
