#!/bin/zsh
##############################
###### Claude Code Accounts
##############################
# Sourced from zsh/.zshenv so account routing exists in interactive, login,
# AND non-interactive shells (zsh -lc / zsh -c read .zshenv but never .zshrc;
# headless probes, hooks, and orchestrator dispatches run there). Zero output
# on success; sourcing uses builtins only -- Git ownership checks run only
# when claude or claude-account is invoked.
#
# Fable requires OAuth login (no API token), so work and personal need two
# separate logins. CLAUDE_CONFIG_DIR is the supported isolation mechanism:
# ~/.claude holds the personal login (the default -- the desktop app lands
# there); ~/.claude-work holds the work login. Routing precedence, highest
# first:
#   CLAUDE_PERSONAL_ONLY=1 / --personal > known personal repository
#   > non-empty CLAUDE_CONFIG_DIR > cwd under $CLAUDE_WORK_TREE > $HOME/.claude
# Set CLAUDE_PERSONAL_ONLY=1 in ~/.zshenv.local on personal-only machines;
# leave it unset on machines that use both accounts by repository.
# Known personal repositories always use the personal account, even when
# launched from a work session that exported its account configuration.
# Either the checkout path or Git common-dir ownership marks a repository
# personal, so external linked worktrees and separate Git metadata stay safe.
# An exported-empty CLAUDE_CONFIG_DIR is treated as unset and is never
# propagated: the personal default unsets it, while work/custom launches
# receive an explicit non-empty path. Setting it to ~/.claude explicitly
# selects a different authentication namespace from the native default. If
# ~/.claude-work does not exist yet, claude creates it and prompts a fresh
# OAuth login for the work account.
CLAUDE_WORK_CONFIG_DIR="${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"
CLAUDE_WORK_TREE="${CLAUDE_WORK_TREE:-$HOME/Git/work}"

# helper: resolve which config dir a claude launch would use from $PWD.
# :A resolves symlinks on both sides so a symlinked path into ~/Git/work
# still routes to the work account. Used by claude-account only: claude()
# deliberately inlines the same logic instead of calling this -- Claude
# Code's shell snapshot strips _-prefixed functions, and a wrapper that
# survived while this helper did not once exported an empty
# CLAUDE_CONFIG_DIR and dumped a config tree into the cwd (2026-08-30).
function _claude_config_dir() {
    emulate -L zsh
    if [[ "${CLAUDE_PERSONAL_ONLY:-}" == 1 ]]; then
        echo "$HOME/.claude"
        return
    fi
    local owner="${PWD:A}" personal_tree="$HOME/Git/personal"
    local work_tree="${CLAUDE_WORK_TREE:-$HOME/Git/work}" common_dir
    common_dir="$(
        unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
        command git -C "$PWD" rev-parse --git-common-dir 2>/dev/null
    )"
    if [[ -n "$common_dir" ]]; then
        [[ "$common_dir" == /* ]] || common_dir="$PWD/$common_dir"
        owner="${common_dir:A}"
    fi
    if [[ "${PWD:A}/" == "${personal_tree:A}/"* || "$owner/" == "${personal_tree:A}/"* ]]; then
        echo "$HOME/.claude"
    elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        echo "$CLAUDE_CONFIG_DIR"
    elif [[ "${PWD:A}/" == "${work_tree:A}/"* ]]; then
        echo "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"
    else
        echo "$HOME/.claude"
    fi
}

function claude-account() {    # claude-account() prints which Claude account/config dir a launch from this directory would use. ex: $ claude-account
    local cfg
    cfg="$(_claude_config_dir)"
    case "$cfg" in
        "$CLAUDE_WORK_CONFIG_DIR") echo "work ($cfg)" ;;
        "$HOME/.claude")           echo "personal ($cfg)" ;;
        *)                         echo "custom ($cfg)" ;;
    esac
}

function claude() {    # claude() will launch Claude Code with the work account inside ~/Git/work, personal elsewhere. Pass --personal to force the personal account. ex: $ claude --personal
    emulate -L zsh
    local use_personal=0 arg cfg work_tree common_dir
    local owner="${PWD:A}" personal_tree="$HOME/Git/personal"
    local personal_cfg="$HOME/.claude"
    local -a forwarded=()
    [[ "${CLAUDE_PERSONAL_ONLY:-}" == 1 ]] && use_personal=1
    for arg in "$@"; do
        case "$arg" in
            --personal) use_personal=1 ;;
            *) forwarded+=("$arg") ;;
        esac
    done
    # Routing is inlined (see _claude_config_dir comment) with
    # literal-default fallbacks so a partially restored environment --
    # helper gone, CLAUDE_WORK_* unset -- still routes correctly. Resolve
    # actual repository ownership before trusting inherited account state.
    if (( ! use_personal )); then
        common_dir="$(
            unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE
            command git -C "$PWD" rev-parse --git-common-dir 2>/dev/null
        )"
        if [[ -n "$common_dir" ]]; then
            [[ "$common_dir" == /* ]] || common_dir="$PWD/$common_dir"
            owner="${common_dir:A}"
        fi
        [[ "${PWD:A}/" == "${personal_tree:A}/"* || "$owner/" == "${personal_tree:A}/"* ]] && use_personal=1
    fi
    if (( use_personal )); then
        cfg="$HOME/.claude"
    elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        cfg="$CLAUDE_CONFIG_DIR"
    else
        work_tree="${CLAUDE_WORK_TREE:-$HOME/Git/work}"
        if [[ "${PWD:A}/" == "${work_tree:A}/"* ]]; then
            cfg="${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"
        else
            cfg="$HOME/.claude"
        fi
    fi
    # Hard floor: never launch with an empty config dir (an empty
    # CLAUDE_CONFIG_DIR makes claude treat the cwd as its config root),
    # and normalize explicit paths before handing them to the child.
    cfg="${cfg:-$HOME/.claude}"
    cfg="${cfg:A}"
    if [[ "$cfg" == "${personal_cfg:A}" ]]; then
        # Preserve the native personal login and the caller's environment.
        (
            unset CLAUDE_CONFIG_DIR
            command claude "${forwarded[@]}"
        )
    else
        CLAUDE_CONFIG_DIR="$cfg" command claude "${forwarded[@]}"
    fi
}
