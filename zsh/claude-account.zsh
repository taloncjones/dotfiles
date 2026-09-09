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
# Workflow children bind WORKFLOW_PERSONAL_ACCOUNT=1 for personal quota in any
# repository; unlike machine policy, it preserves work repository plugin choices.
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
typeset -g WORKFLOW_CONTEXT_PY="${${(%):-%N}:A:h}/../claude/skills/lib/workflow_context.py"

function workflow_account_scope() {
    local target="$1" runtime="$2" personal="${3:-0}"
    [[ -r "$WORKFLOW_CONTEXT_PY" ]] || return 127
    command -v python3 >/dev/null 2>&1 || return 127
    local -a args=(account-scope --cwd "$target" --runtime "$runtime")
    [[ "$personal" == 1 ]] && args+=(--personal)
    command python3 "$WORKFLOW_CONTEXT_PY" "${args[@]}"
}

function workflow_scope_field() {
    command python3 -c '
import json, sys
scope = json.loads(sys.argv[1])
value = scope.get(sys.argv[2])
if not isinstance(value, str) or "\n" in value or "\0" in value:
    raise SystemExit(2)
print(value)
' "$1" "$2"
}

function workflow_scope_bool() {
    command python3 -c '
import json, sys
value = json.loads(sys.argv[1]).get(sys.argv[2])
if not isinstance(value, bool):
    raise SystemExit(2)
print(1 if value else 0)
' "$1" "$2"
}

# helper: resolve which config dir a claude launch would use from $PWD.
# :A resolves symlinks on both sides so a symlinked path into ~/Git/work
# still routes to the work account. Used by claude-account only: claude()
# deliberately inlines the same logic instead of calling this -- Claude
# Code's shell snapshot strips _-prefixed functions, and a wrapper that
# survived while this helper did not once exported an empty
# CLAUDE_CONFIG_DIR and dumped a config tree into the cwd (2026-08-30).
function _claude_config_dir() {
    emulate -L zsh
    local scope
    scope="$(workflow_account_scope "$PWD" claude)" || return $?
    workflow_scope_field "$scope" root
}

function claude-account() {    # claude-account() prints which Claude account/config dir a launch from this directory would use. ex: $ claude-account
    local cfg
    cfg="$(_claude_config_dir)" || {
        echo "[X] Claude account context is ambiguous; use --personal or CLAUDE_PERSONAL_ONLY=1."
        return 2
    }
    case "$cfg" in
        "$CLAUDE_WORK_CONFIG_DIR") echo "work ($cfg)" ;;
        "$HOME/.claude")           echo "personal ($cfg)" ;;
        *)                         echo "custom ($cfg)" ;;
    esac
}

function claude() {    # claude() will launch Claude Code with the work account inside ~/Git/work, personal elsewhere. Pass --personal to force the personal account. ex: $ claude --personal
    emulate -L zsh
    local use_personal=0 arg cfg scope kind target="$PWD" take_cd=0 parse_cd=1
    local -a forwarded=()
    [[ "${CLAUDE_PERSONAL_ONLY:-}" == 1 ]] && use_personal=1
    for arg in "$@"; do
        case "$arg" in
            --personal) use_personal=1 ;;
            *) forwarded+=("$arg") ;;
        esac
        if (( take_cd )); then
            target="$arg"
            take_cd=0
        elif (( parse_cd )); then
            case "$arg" in
                --) parse_cd=0 ;;
                -C|--cd) take_cd=1 ;;
                --cd=*) target="${arg#--cd=}" ;;
                -C=*) target="${arg#-C=}" ;;
                -C?*) target="${arg#-C}" ;;
            esac
        fi
    done
    target="${target:A}"
    scope="$(workflow_account_scope "$target" claude "$use_personal")" || {
        echo "[X] Claude account context is ambiguous; relaunch with --personal or CLAUDE_PERSONAL_ONLY=1." >&2
        return 2
    }
    kind="$(workflow_scope_field "$scope" kind)" || return 2
    cfg="$(workflow_scope_field "$scope" root)" || return 2
    if [[ "$kind" == personal ]]; then
        # Preserve the native personal login and the caller's environment.
        (
            unset CLAUDE_CONFIG_DIR
            command claude "${forwarded[@]}"
        )
    else
        CLAUDE_CONFIG_DIR="$cfg" command claude "${forwarded[@]}"
    fi
}
