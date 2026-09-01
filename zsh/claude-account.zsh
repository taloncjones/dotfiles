#!/bin/zsh
##############################
###### Claude Code Accounts
##############################
# Sourced from zsh/.zshenv so account routing exists in interactive, login,
# AND non-interactive shells (zsh -lc / zsh -c read .zshenv but never .zshrc;
# headless probes, hooks, and orchestrator dispatches run there). Zero output
# on success; builtins and parameter expansion only -- every zsh on the
# machine pays this file's cost.
#
# Fable requires OAuth login (no API token), so work and personal need two
# separate logins. CLAUDE_CONFIG_DIR is the supported isolation mechanism:
# ~/.claude holds the personal login (the default -- the desktop app lands
# there); ~/.claude-work holds the work login. Routing precedence, highest
# first:
#   --personal > non-empty CLAUDE_CONFIG_DIR > cwd under $CLAUDE_WORK_TREE
#   > $HOME/.claude
# An exported-empty CLAUDE_CONFIG_DIR is treated as unset and is never
# propagated: the wrapper always injects an explicit non-empty dir. If
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
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
        echo "$CLAUDE_CONFIG_DIR"
    elif [[ "${PWD:A}/" == "${CLAUDE_WORK_TREE:A}/"* ]]; then
        echo "$CLAUDE_WORK_CONFIG_DIR"
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
    local use_personal=0 arg cfg work_tree
    local -a forwarded=()
    for arg in "$@"; do
        case "$arg" in
            --personal) use_personal=1 ;;
            *) forwarded+=("$arg") ;;
        esac
    done
    # Routing is inlined (see _claude_config_dir comment) with
    # literal-default fallbacks so a partially restored environment --
    # helper gone, CLAUDE_WORK_* unset -- still routes correctly.
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
    # and always hand the child an absolute path (:A also anchors a
    # relative inherited value to the current cwd instead of letting
    # claude re-anchor it to whatever cwd it sees).
    cfg="${cfg:-$HOME/.claude}"
    cfg="${cfg:A}"
    CLAUDE_CONFIG_DIR="$cfg" command claude "${forwarded[@]}"
}
