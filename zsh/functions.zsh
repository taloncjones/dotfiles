#!/bin/zsh
# functions.zsh - Shell functions for file operations, system tasks, and dotfile management
#
# General-purpose functions loaded by .zshrc. API-specific scripts live in scripts/.
# Use `functionlist` to see all available functions with descriptions.

# List all available functions from this file and scripts/
function functionlist() {    # functionlist() will list all of the available functions. ex: $ functionlist
    # grab all of the common funcs to both platforms
    local list=$(grep 'function ' "$DOTFILEDIR/zsh/functions.zsh" | awk '{$1=$1};1' | highlight --syntax=bash)

    local funcslist=()

    # grab all of the platform agnostic funcs
    for file in "$DOTFILEDIR/zsh/scripts/"*
    do
        if [[ -f $file ]]; then
            funcslist+=$(grep 'function' "$file" | awk '{$1=$1};1' | highlight --syntax=bash)
            funcslist+=$'\n'
        fi
    done

    echo "$funcslist" | awk '{$1=$1};1'
    echo "$list" | sort -u -d -s | tr -d '\\+'
}

# update the dotfiles completely, or just the Claude/Codex layer with --ai
function update() {    # update([--ai]) will update the dotfiles installation; --ai refreshes only the Claude/Codex layer. ex: $ update --ai
	local scope="full"
	case "${1:-}" in
		"") ;;
		--ai) scope="ai" ;;
		*)
			echo "[X] usage: update [--ai]"
			return 2
			;;
	esac

	# save the current directory
	currentdir=$(pwd)

	# navigate to dotfile install directory
	dotfiles

	# guarded fetch + fast-forward (repo-sync.sh): non-fatal for both scopes
	# -- the installer still runs from the current checkout when the sync
	# exits with a classified skip status (usage error 2, or the documented
	# 20-29 range: not-a-worktree, detached, wrong branch, no upstream,
	# offline, ahead, diverged, dirty, refused-ff, or a pre-merge inspection
	# failure). Any other status -- including 30 (unverified after a merge
	# attempt) and an unclassified status such as 143 from a SIGTERM mid-run,
	# where verification never ran -- aborts before the installer: installing
	# from an unverified checkout could propagate a half-updated tree into ~.
	local pull_status=0
	bash "$DOTFILEDIR/install/common/repo-sync.sh" "$DOTFILEDIR" || pull_status=$?
	if (( pull_status != 0 && pull_status != 2 && (pull_status < 20 || pull_status > 29) )); then
		cd $currentdir
		echo "[X] update aborted: sync exited $pull_status without verified state; inspect $DOTFILEDIR"
		return $pull_status
	fi

	local install_status=0
	if [[ "$scope" == "ai" ]]; then
		# scoped: Claude/Codex layer only -- no sudo, no brew, no defaults
		bash $DOTFILEDIR/install/common/ai-update.sh || install_status=$?
	else
		# update tldr definitions
		tldr --update

		# execute the install script
		# note: we manually specify bash here, since the install script is written in bash
		# and we're calling it from zsh. bad things happen if you use source instead
		bash $DOTFILEDIR/install/install.sh || install_status=$?
	fi

	# return user to previous directory
	cd $currentdir

	# propagate a red install instead of masking it with the cd above
	if (( install_status != 0 )); then
		if [[ "$scope" == "ai" ]]; then
			echo "[X] update --ai failed: ai-update.sh exited $install_status"
		else
			echo "[X] update failed: install.sh exited $install_status"
		fi
		return $install_status
	fi

	# A completed update supersedes any pending staleness nudge (Task 6);
	# keep the last-check stamp so the daily fetch cadence is unchanged.
	# Only clear it when BOTH the pull and the install actually succeeded --
	# a failed pull must not silence a real staleness reminder.
	if (( pull_status == 0 && install_status == 0 )); then
		rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles/repo-staleness-result"
	fi
	return 0
}

# Extract a compressed archive without worrying about which tool to use
function extract() { # extract() will unzip/unrar/untar any type of compressed file. ex $ extract file.tar.gz
  if [ -f "$1" ]; then
    case "$1" in
      *.tar.bz2)   tar xjf "$1"    ;;
      *.tar.gz)    tar xzf "$1"    ;;
      *.bz2)       bunzip2 "$1"    ;;
      *.rar)       unrar x "$1"    ;;
      *.gz)        gunzip "$1"     ;;
      *.tar)       tar xf "$1"     ;;
      *.tbz2)      tar xjf "$1"    ;;
      *.tgz)       tar xzf "$1"    ;;
      *.zip)       unzip "$1"      ;;
      *.Z)         uncompress "$1" ;;
      *.7z)        7z x "$1"       ;;
      *)           echo "'$1' cannot be extracted via extract()" ;;
    esac
  else
    echo "'$1' is not a valid file"
  fi
}

# Determine size of a file or total size of a directory
function fs() {    # fs() will print a human readable size of given file or directory. ex: $ fs ~
	if du -b /dev/null > /dev/null 2>&1; then
		local arg=-sbh;
	else
		local arg=-sh;
	fi
	if [[ -n "$@" ]]; then
		du $arg -- "$@";
	else
        if [[ $(uname) == "Darwin" ]]; then
            du $arg .[^.]* ./*;
        else
            find . -type f | du -ah -d1
        fi;
	fi;
}

# Prints permissions of file
function permissions() {    # permissions() will print human readable permissions for a given file or directory. ex: $ permissions ~
	if [ -z "${1}" ]; then
		echo "ERROR: No file or directory specified";
		return 1;
	fi;

    if [[ $(uname) == "Darwin" ]]; then
        stat -f "%Sp %OLp %N" "$1"
    else
        stat -c '%A %a %n' "$1"
    fi;
}


# pretty print json
function prettyjson() {    # prettyjson() will print human readable json that has been colorized. ex: $ prettyjson file.json
	if [ -z "${1}" ]; then
		echo "ERROR: No file specified";
		return 1;
	fi;

  result=$(python3 -m json.tool "$1")
  echo "$result" | highlight --syntax=json
}

# list all ssh endpoints from ssh configs
function sshlist() {    # sshlist() will list all available ssh endpoints. ex: $ sshlist
    local CONFIG_PATH=("$DOTFILEDIR/ssh/configs"/**/*(.))
    for f in $CONFIG_PATH
    do
        cat "$f" |
            grep -e "Host " -e "######## " -e "#### $" |
            grep -v "Host \*" |
            grep "Host \|####"
    done
}

# copy primary public key to clipboard
function pubkey() {    # pubkey() will copy a public key to the clipboard. ex: $ pubkey id_rsa_adobe.pub
    if [ -z "${1}" ]; then
        echo "ERROR: No key specified. The possible keys are:";
        local keylist=$(ls ~/.ssh/*.pub);
        echo $keylist;
        return 1;
    fi;
    if [[ $(uname) == "Darwin" ]]; then
        cat ~/.ssh/$1 | pbcopy && echo '=> Public key copied to clipboard.'
    else
        cat ~/.ssh/$1 | xclip -selection clipboard && echo '=> Public key copied to clipboard.'
    fi
}

# open vnc connection
function vnc() {    # vnc() will open a VNC connection to a given host. ex: $ vnc copper.jgrid.net
    if [ -z "${1}" ]; then
        echo "ERROR: No domain specified.";
        return 1;
    fi;
    if [[ $(uname) == "Darwin" ]]; then
        open vnc://$1
    else
        xdg-open vnc://$1
    fi
}

# set the computer's hostname
function sethostname() {    # sethostname() will set the machine's hostname to the given string. ex: $ sethostname JWORK
    if [ -z "${1}" ]; then
        echo "ERROR: No hostname specified.";
        return 1;
    fi;
    if [[ $(uname) == "Darwin" ]]; then
        sudo scutil --set ComputerName $1
        sudo scutil --set HostName $1
        sudo scutil --set LocalHostName $1
        sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string $1
    else
        sudo hostnamectl set-hostname $1
    fi
}

# lock screen / afk
function afk() {    # afk() will lock the screen. ex: $ afk
    if [[ $(uname) == "Darwin" ]]; then
        osascript -e 'tell app "System Events" to key code 12 using {control down, command down}'
    else
        # works with most Linux DEs (GNOME, KDE, etc.)
        if command -v gnome-screensaver-command &> /dev/null; then
            gnome-screensaver-command -l
        elif command -v loginctl &> /dev/null; then
            loginctl lock-session
        else
            echo "No supported lock mechanism found"
        fi
    fi
}

# launch lazygit and follow it into the worktree/repo it left you in
function lg() {    # lg() will run lazygit and cd into the worktree/repo selected on exit. ex: $ lg
    # lazygit writes its final repo/worktree path here on exit; a child process
    # cannot change the parent shell's cwd, so we cd after it quits. lazygit
    # won't create the parent dir, so ensure it exists or the write is silently dropped.
    export LAZYGIT_NEW_DIR_FILE=~/.lazygit/newdir
    mkdir -p "${LAZYGIT_NEW_DIR_FILE:h}"

    lazygit "$@"

    if [[ -f $LAZYGIT_NEW_DIR_FILE ]]; then
        cd "$(cat "$LAZYGIT_NEW_DIR_FILE")" || return
        rm -f "$LAZYGIT_NEW_DIR_FILE"
    fi
}

# sync the tracked VS Code extension list with the live installed set
function vscode-ext-sync() {    # vscode-ext-sync() will rewrite vscode/extensions.txt from the installed extensions and show the diff to commit. ex: $ vscode-ext-sync
    command -v code >/dev/null || { echo "code CLI not found" >&2; return 1; }
    local file="$DOTFILEDIR/vscode/extensions.txt"
    code --list-extensions | sort -u > "$file" || return
    if git -C "$DOTFILEDIR" diff --quiet -- "$file"; then
        echo "extensions.txt already matches the installed set ($(wc -l < "$file" | tr -d ' ') extensions)"
    else
        git -C "$DOTFILEDIR" --no-pager diff --stat -- "$file"
        echo "[INFO] extensions.txt updated -- review and commit the diff"
    fi
}

# Claude account routing (claude(), claude-account) lives in
# zsh/claude-account.zsh, sourced from zsh/.zshenv so it exists in
# non-interactive shells too.

##############################
###### Claude Code Plugins
##############################

# --- Plugin install ground truth (ported from bootstrap-cloud.sh) ---
# `claude plugins install` can exit 0 without installing: a marketplace that is
# registered but still mid-fetch resolves the plugin to "nothing to do" and the
# command "succeeds". Exit codes and CLI output are therefore not evidence; the
# on-disk record <config-dir>/plugins/installed_plugins.json is.

# helper: true iff the plugin id is recorded in the config dir's installed_plugins.json
function _claude_plugin_installed() {
    local cfg_dir="$1" plugin_id="$2"
    local record="$cfg_dir/plugins/installed_plugins.json"
    [[ -f "$record" ]] && grep -q "$plugin_id" "$record"
}

# Run a Claude plugin operation in the selected account namespace. Native
# personal Claude uses an unset variable; work and custom directories remain
# explicit. The subshell keeps the caller's environment unchanged.
function _claude_plugin_run() {
    local cfg_dir="$1"
    shift
    if [[ "$cfg_dir" == "$HOME/.claude" ]]; then
        ( unset CLAUDE_CONFIG_DIR; command claude "$@" )
    else
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude "$@"
    fi
}

# --- Codex plugin lifecycle ---
# Codex plugins are global to CODEX_HOME. Superpowers is staged into a
# dedicated local marketplace so every manifest reference is copied into the
# plugin cache without depending on account-provisioned marketplaces.
CODEX_WORKFLOW_MARKETPLACE_DIR="${CODEX_WORKFLOW_MARKETPLACE_DIR:-$HOME/.local/share/dotfiles/codex-workflows}"

function _codex_plugin_present() {
    local plugin_id="$1"
    command codex plugin list --json 2>/dev/null | awk -v target="$plugin_id" '
        /"pluginId"[[:space:]]*:/ && index($0, "\"" target "\"") > 0 { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

function _codex_remove_plugin() {
    local plugin_id="$1"
    command -v codex &>/dev/null || return 0
    if ! _codex_plugin_present "$plugin_id"; then
        echo "[INFO] $plugin_id not installed (Codex)"
        return 0
    fi
    echo "[INFO] Removing $plugin_id (Codex)..."
    command codex plugin remove "$plugin_id" \
        || { echo "[X] removal failed for $plugin_id (Codex)"; return 1; }
    if _codex_plugin_present "$plugin_id"; then
        echo "[X] $plugin_id is still present after Codex reported successful removal"
        return 1
    fi
    echo "[OK] Removed $plugin_id (Codex)"
}

# --- ECC (Everything Claude Code) -- RETIRED; uninstall tooling only ---
# ECC cost ~10.6k context tokens per session boot for skills nothing here
# called, plus an account-isolation layer re-audited on every upgrade. The
# settings reconcile forces ecc@ecc off and the Codex dedupe disables its
# Codex copies; ecc-uninstall removes what is still on disk.
ECC_REPO_DIR="$HOME/Git/personal/ECC"
SUPERPOWERS_REPO_URL="https://github.com/obra/superpowers.git"
SUPERPOWERS_REPO_DIR="${SUPERPOWERS_REPO_DIR:-$HOME/.local/share/dotfiles/sources/superpowers}"

# Retired entry points survive `reload` in a long-running shell -- drop them.
for _ecc_fn in ecc-install ecc-update _ecc_legacy_rules_notice _codex_stage_ecc_plugin \
        _codex_install_ecc_plugin _codex_update_ecc_plugin \
        _claude_plugin_check_update _claude_plugin_epoch_write; do
    (( ${+functions[$_ecc_fn]} )) && unfunction "$_ecc_fn"
done
unset _ecc_fn

for _sp_fn in superpowers-install superpowers-update _codex_stage_superpowers_plugin \
        _codex_install_superpowers_plugin _codex_update_superpowers_plugin; do
    (( ${+functions[$_sp_fn]} )) && unfunction "$_sp_fn"
done
unset _sp_fn

# helper: move the untracked copies an old full ECC install vendored into the
# symlinked asset dirs to a backup. A candidate is untracked (ls-files exit 1,
# never a git error) and shares a basename with the checkout; upstream edited
# most files since, so content matching would miss them. Tracked files and
# symlinks are never touched. Returns 1 on any git or move failure.
function _ecc_sweep_legacy_vendored() {
    emulate -L zsh
    local ecc_dir="$1" pair target origin f rel rc backup
    local -aU candidates
    git -C "$DOTFILEDIR" rev-parse --is-inside-work-tree &>/dev/null \
        || { echo "[X] Cannot read the dotfiles git index at $DOTFILEDIR; not sweeping."; return 1; }
    if [[ ! -d "$ecc_dir" ]]; then
        echo "[INFO] ECC checkout absent; nothing to match. Untracked candidates to review by hand:"
        for target in claude/agents claude/commands; do
            for f in "$DOTFILEDIR/$target"/*.md(N.); do
                git -C "$DOTFILEDIR" ls-files --error-unmatch -- "$target/${f:t}" &>/dev/null \
                    || echo "[INFO]   $f"
            done
        done
        return 0
    fi
    for pair in claude/agents:agents claude/commands:commands \
            claude/commands:legacy-command-shims/commands claude/hooks:hooks; do
        target="${pair%%:*}" origin="${pair#*:}"
        # (N.) = plain files only: symlinks and dirs are skipped.
        for f in "$DOTFILEDIR/$target"/*(N.); do
            [[ -f "$ecc_dir/$origin/${f:t}" ]] || continue
            rel="$target/${f:t}"
            git -C "$DOTFILEDIR" ls-files --error-unmatch -- "$rel" &>/dev/null
            rc=$?
            (( rc == 0 )) && continue
            (( rc == 1 )) || { echo "[X] git ls-files failed ($rc) on $rel; not sweeping."; return 1; }
            candidates+=("$rel")
        done
    done
    (( ${#candidates} )) || return 0
    backup="${XDG_STATE_HOME:-$HOME/.local/state}/dotfiles/ecc-retired-$(date +%Y%m%d%H%M%S)"
    for rel in "${candidates[@]}"; do
        # Copy, verify, then remove: a plain mv across filesystems is
        # copy-and-unlink, and an interruption there could lose the only copy.
        mkdir -p "$backup/${rel:h}" \
            && cp -p "$DOTFILEDIR/$rel" "$backup/$rel" \
            && cmp -s "$DOTFILEDIR/$rel" "$backup/$rel" \
            && rm -f "$DOTFILEDIR/$rel" \
            || { echo "[X] Could not back up $rel to $backup; rerun ecc-uninstall."; return 1; }
    done
    echo "[OK] Moved ${#candidates} legacy ECC copies to $backup"
}

function ecc-uninstall() {    # ecc-uninstall() removes ECC from Claude and Codex plus its source checkout. ex: $ ecc-uninstall
    local ecc_dir="$ECC_REPO_DIR"
    local uninstall_status=0

    # remove installed rules via uninstall script if available
    if [[ -f "$HOME/.claude/ecc/install-state.json" ]] && [[ -d "$ecc_dir" ]]; then
        echo "[INFO] Removing ECC-managed files..."
        (cd "$ecc_dir" && node scripts/uninstall.js 2>/dev/null)
    fi
    # always safe to remove ECC metadata; leave ~/.claude/rules intact
    rm -rf "$HOME/.claude/ecc"

    # remove plugin from every account config dir
    local cfg_dir
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        if _claude_plugin_installed "$cfg_dir" "ecc@ecc"; then
            echo "[INFO] Removing ECC plugin ($cfg_dir)..."
            _claude_plugin_run "$cfg_dir" plugins uninstall ecc@ecc 2>/dev/null || uninstall_status=1
        fi
    done

    _codex_remove_plugin "ecc@dotfiles-workflows" || uninstall_status=1

    _ecc_sweep_legacy_vendored "$ecc_dir" || uninstall_status=1
    if [[ -n "$CODEX_WORKFLOW_MARKETPLACE_DIR" && -d "$CODEX_WORKFLOW_MARKETPLACE_DIR/plugins/ecc" ]]; then
        rm -rf "$CODEX_WORKFLOW_MARKETPLACE_DIR/plugins/ecc" || uninstall_status=1
    fi

    # The checkout is the sweep's evidence: delete it last, and only when every
    # step above succeeded, so a rerun can still match what is left.
    if [[ -d "$ecc_dir" ]]; then
        if (( uninstall_status == 0 )); then
            echo "[INFO] Removing ECC repo..."
            rm -rf "$ecc_dir"
        else
            echo "[INFO] Keeping $ecc_dir so a rerun can finish the cleanup."
        fi
    fi

    rm -f "${ZSH_CACHE_DIR:-$HOME/.cache/zsh}/.ecc-update"
    if (( uninstall_status == 0 )); then
        echo "[OK] ECC uninstalled from Claude and Codex"
    else
        echo "[X] ECC uninstall was incomplete"
        return 1
    fi
}

# --- GSD (Get Shit Done) -- RETIRED; uninstall tooling only ---
# GSD is no longer used on this setup and there is no install path here. The
# original get-shit-done-cc package was abandoned after a token rug-pull with
# publish access retained, so it is treated as compromised: never reinstall
# it. The community redux fork (@opengsd/get-shit-done-redux) is retired too;
# the package ref below exists only so gsd-uninstall can invoke the official
# npx uninstaller. dotfiles-repair flags any GSD reappearance.
# Flags accepted by gsd-uninstall:
#   -l, --local       remove under ./.claude (and ./.codex) in the current dir
#   -g, --global      remove under ~/ (the default)
#   --claude          target Claude Code only
#   --codex           target Codex only
#                     (default: both runtimes when codex is installed, else Claude only)
GSD_REDUX_PKG="@opengsd/get-shit-done-redux@latest"

# Retired install entry points survive in long-running shells (re-sourcing a
# file never undefines functions it no longer contains) -- drop them explicitly
# so `reload` cannot leave a callable gsd-install behind.
for _gsd_fn in gsd-install gsd-update _gsd_install_target _gsd_install_targets; do
    (( ${+functions[$_gsd_fn]} )) && unfunction "$_gsd_fn"
done
unset _gsd_fn

function _codex_remove_legacy_mirror_symlinks() {
    find "$HOME/.codex/skills" -maxdepth 1 -type l \
        \( -name 'gsd-*' -o -name 'ecc-*' -o -name 'superpowers-*' \) -delete 2>/dev/null || true
    find "$HOME/.codex/agents" -maxdepth 1 -type l \
        \( -name 'ecc-*' -o -name 'superpowers-*' \) -delete 2>/dev/null || true
}

# helper: run a command in a subshell from a guaranteed-valid directory ($HOME), so
# npm/npx/node don't crash with `uv_cwd ENOENT` when the shell's CWD has been deleted.
# Only for *global* GSD operations — never wrap a --local op with this.
function _gsd_at_home() {
    ( cd "$HOME" 2>/dev/null || cd / ; "$@" )
}

# helper: bail out if a --local op was requested but the current directory is gone
function _gsd_require_cwd() {
    [[ "$1" != "local" ]] && return 0
    [[ -n "$PWD" && -d "$PWD" ]] && return 0
    echo "[X] current directory no longer exists; cd somewhere valid (or drop --local for a global op)."
    return 1
}

# helper: run the redux package at a scope (global runs from $HOME; local stays in CWD);
# only used with --uninstall now that the install path is retired
function _gsd_run() {
    local scope="$1"; shift
    if [[ "$scope" == "global" ]]; then
        _gsd_at_home npx -y "$GSD_REDUX_PKG" "$@"
    else
        npx -y "$GSD_REDUX_PKG" "$@"
    fi
}

# helper: parse gsd-uninstall args into caller-scoped vars:
#   gsd_scope       -> "global" (default) | "local"
#   gsd_targets     -> array of "claude"/"codex" (default: claude + codex-if-installed)
#   gsd_passthrough -> array of remaining args (rejected by gsd-uninstall --
#                      with the installer gone there is nothing to forward to)
function _gsd_parse_args() {
    gsd_scope="global"; gsd_targets=(); gsd_passthrough=()
    local arg want_claude=0 want_codex=0
    for arg in "$@"; do
        case "$arg" in
            -l|--local)  gsd_scope="local" ;;
            -g|--global) gsd_scope="global" ;;
            --claude)    want_claude=1 ;;
            --codex)     want_codex=1 ;;
            *)           gsd_passthrough+=("$arg") ;;
        esac
    done
    if (( want_claude || want_codex )); then
        (( want_claude )) && gsd_targets+=("claude")
        (( want_codex ))  && gsd_targets+=("codex")
    else
        gsd_targets=("claude")
        command -v codex &>/dev/null && gsd_targets+=("codex")
    fi
}

# helper: strip GSD hook registrations + gsd-sdk permission entries from a settings.json
function _gsd_strip_settings() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    command -v python3 &>/dev/null || return 0
    python3 - "$f" <<'PY'
import json, sys
p = sys.argv[1]
try:
    d = json.load(open(p))
except Exception:
    sys.exit(0)
changed = False
hooks = d.get("hooks", {})
for ev in list(hooks):
    groups = []
    for g in hooks[ev]:
        orig = g.get("hooks", [])
        kept = [h for h in orig if "gsd" not in json.dumps(h).lower()]
        if len(kept) != len(orig):
            changed = True
        if kept or not orig:
            g = dict(g); g["hooks"] = kept; groups.append(g)
    if groups:
        hooks[ev] = groups
    else:
        del hooks[ev]; changed = True
allow = d.get("permissions", {}).get("allow")
if isinstance(allow, list):
    na = [x for x in allow if "gsd" not in str(x).lower()]
    if len(na) != len(allow):
        d["permissions"]["allow"] = na; changed = True
if changed:
    d["hooks"] = hooks
    json.dump(d, open(p, "w"), indent=2); open(p, "a").write("\n")
    print("[INFO] stripped GSD entries from " + p)
PY
}

function gsd-uninstall() {    # gsd-uninstall([--local] [--claude|--codex]) fully removes GSD: the redux fork, the legacy compromised package, and all leftover state. ex: $ gsd-uninstall
    local gsd_scope gsd_targets gsd_passthrough
    _gsd_parse_args "$@"
    (( ${#gsd_passthrough} )) && { echo "[X] unknown args: ${gsd_passthrough[*]}"; return 1; }
    _gsd_require_cwd "$gsd_scope" || return 1
    local base="$HOME/.claude"; [[ "$gsd_scope" == "local" ]] && base="./.claude"

    # 1. official uninstaller per target (removes runtime skills + hook registrations)
    local target
    for target in "${gsd_targets[@]}"; do
        echo "[INFO] Removing GSD from ${target} ($gsd_scope)..."
        [[ "$target" == "codex" ]] && _codex_remove_legacy_mirror_symlinks
        _gsd_run "$gsd_scope" --$target --$gsd_scope --uninstall 2>/dev/null || true
    done

    # 2. purge the legacy/compromised original package + its npx caches (global only)
    if [[ "$gsd_scope" == "global" ]]; then
        command -v npm &>/dev/null && _gsd_at_home npm uninstall -g get-shit-done-cc 2>/dev/null
        local d
        for d in "$HOME"/.npm/_npx/*(N/); do
            [[ -e "$d/node_modules/get-shit-done-cc" ]] && rm -rf "$d"
        done
        rm -f "${ZSH_CACHE_DIR:-$HOME/.cache/zsh}/.gsd-update"
    fi

    # 3. sweep any GSD files + runtime state the installer leaves behind, across
    #    both the Claude base and the Codex base -- the codex uninstaller leaves
    #    gsd-install-state.json/gsd-migration-journal/gsd-pristine residue behind.
    local cbase="$HOME/.codex"; [[ "$gsd_scope" == "local" ]] && cbase="./.codex"
    # Shared globs sweep BOTH bases -- add a new installer artifact dir here
    # once and both are covered (hooks/ was previously missed on the codex side
    # because the lists were maintained per-base).
    local -a junk
    local b
    for b in "$base" "$cbase"; do
        junk+=( "$b"/skills/gsd-*(N) "$b"/commands/gsd-*(N) "$b"/agents/gsd-*(N) "$b"/hooks/gsd-*(N)
                "$b"/gsd-migration-journal(N) "$b"/gsd-file-manifest.json(N) "$b"/gsd-pristine(N)
                "$b"/gsd-install-state.json(N) "$b"/gsd-user-files-backup*(N) )
    done
    # base-specific residue
    junk+=( "$base"/get-shit-done(N) "$base"/commands/gsd(N) "$base"/.gsd-profile(N)
            "$cbase"/prompts/gsd-*(N) )
    (( ${#junk} )) && rm -rf "${junk[@]}"

    # 4. strip GSD hook registrations + permission from settings.json
    _gsd_strip_settings "$base/settings.json"

    echo "[OK] GSD uninstalled (${(j:+:)gsd_targets}, $gsd_scope)"
}

# Codex integration:
#   - Superpowers is retired (2026-09), like ECC; only its uninstaller remains.
# install/common/link.sh still sweeps leftover mirror-style skill/agent links.

# --- Superpowers -- RETIRED; uninstall tooling only ---
# The settings reconcile forces superpowers@claude-plugins-official off and
# the Codex dedupe disables its Codex copies; superpowers-uninstall removes
# what is still on disk.

# helper: print "<scope>\t<projectPath>" for each install record of a plugin
# in one config dir. No registry file means nothing is installed (exit 0);
# an unreadable one exits 2 so callers cannot mistake it for "absent".
function _claude_plugin_records() {
    local cfg_dir="$1" plugin_id="$2"
    local record="$cfg_dir/plugins/installed_plugins.json"
    [[ -f "$record" ]] || return 0
    command python3 - "$record" "$plugin_id" <<'PY'
import json, sys
path, plugin = sys.argv[1:]
try:
    with open(path) as fh:
        records = json.load(fh).get("plugins", {}).get(plugin, [])
except (OSError, ValueError, AttributeError):
    sys.exit(2)
if not isinstance(records, list) or not all(isinstance(r, dict) for r in records):
    sys.exit(2)
for rec in records:
    print(f"{rec.get('scope', 'user')}\t{rec.get('projectPath', '')}")
PY
}

function superpowers-uninstall() {    # superpowers-uninstall() removes the retired Superpowers plugin from Claude and Codex. ex: $ superpowers-uninstall
    local plugin_id="superpowers@claude-plugins-official"
    local cfg_dir records remaining scope project dir_status uninstall_status=0
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        if ! records=$(_claude_plugin_records "$cfg_dir" "$plugin_id"); then
            echo "[X] unreadable plugin registry in $cfg_dir; trying one user-scope uninstall"
            _claude_plugin_run "$cfg_dir" plugin uninstall --scope user "$plugin_id" </dev/null
            uninstall_status=1
            continue
        fi
        if [[ -z "$records" ]]; then
            echo "[INFO] Superpowers not installed ($cfg_dir)"
            continue
        fi
        dir_status=0
        while IFS=$'\t' read -r scope project; do
            if [[ "$scope" == user ]]; then
                _claude_plugin_run "$cfg_dir" plugin uninstall --scope user "$plugin_id" </dev/null || dir_status=1
            elif [[ -n "$project" && -d "$project" ]]; then
                ( cd "$project" && _claude_plugin_run "$cfg_dir" plugin uninstall --scope "$scope" "$plugin_id" </dev/null ) || dir_status=1
            else
                echo "[X] $scope-scope Superpowers record names a missing project: ${project:-<none>} ($cfg_dir)"
                dir_status=1
            fi
        done <<< "$records"   # CLI calls read /dev/null so they cannot eat these lines
        # The registry, not the CLI exit code, decides success.
        remaining=$(_claude_plugin_records "$cfg_dir" "$plugin_id") && [[ -z "$remaining" ]] || dir_status=1
        if (( dir_status == 0 )); then
            echo "[OK] Superpowers uninstalled ($cfg_dir)"
        else
            echo "[X] Superpowers still recorded in $cfg_dir"
            uninstall_status=1
        fi
    done
    _codex_remove_plugin "superpowers@dotfiles-workflows" || uninstall_status=1
    _codex_remove_plugin "superpowers@openai-curated" || uninstall_status=1
    if [[ -n "$CODEX_WORKFLOW_MARKETPLACE_DIR" && -d "$CODEX_WORKFLOW_MARKETPLACE_DIR/plugins/superpowers" ]]; then
        rm -rf "$CODEX_WORKFLOW_MARKETPLACE_DIR/plugins/superpowers" || uninstall_status=1
    fi
    if [[ -d "$SUPERPOWERS_REPO_DIR" ]]; then
        echo "[INFO] Removing Superpowers source checkout..."
        rm -rf "$SUPERPOWERS_REPO_DIR" || uninstall_status=1
    fi
    (( uninstall_status == 0 ))
}

# Check for Claude Code CLI updates (async, cached 24h)
_claude_code_update_check() {
    command -v claude &>/dev/null || return 0

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
    local cache_file="$cache_dir/claude-code-update-check"
    local cache_ttl=86400  # 24 hours

    # Skip if checked recently
    if [[ -f "$cache_file" ]]; then
        local cache_age=$(( $(date +%s) - $(stat -f%m "$cache_file" 2>/dev/null || stat -c%Y "$cache_file" 2>/dev/null || echo 0) ))
        (( cache_age < cache_ttl )) && return 0
    fi

    # Run check in background
    {
        mkdir -p "$cache_dir"
        local installed
        installed="$(command claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
        local latest
        latest="$(npm view @anthropic-ai/claude-code version 2>/dev/null)"

        if [[ -n "$installed" && -n "$latest" && "$installed" != "$latest" ]]; then
            echo "$installed:$latest" > "$cache_file"
        else
            touch "$cache_file"
        fi
    } &!

    # Show cached result from previous check
    if [[ -f "$cache_file" && -s "$cache_file" ]]; then
        local versions
        versions="$(cat "$cache_file")"
        local current="${versions%%:*}"
        local available="${versions##*:}"
        echo "[INFO] Claude Code update available: $current -> $available. Run 'claude update' to upgrade."
    fi
}
_claude_code_update_check

# Synchronous worker: fetch origin and record the behind-count in the result
# file (empty file = checked, up to date). Called in the background by
# _dotfiles_staleness_check; call directly only in tests. Advisory: every
# failure (offline, unwritable cache) is silent.
_dotfiles_staleness_fetch() {
    local result_file="$1"
    [[ -L "$result_file" ]] && return 0
    mkdir -p "${result_file:h}" 2>/dev/null || return 0
    local behind=""
    if git -C "$DOTFILEDIR" fetch --quiet 2>/dev/null; then
        behind="$(git -C "$DOTFILEDIR" rev-list --count 'HEAD..@{upstream}' 2>/dev/null)"
    fi
    if [[ -n "$behind" && "$behind" != "0" ]]; then
        echo "$behind" > "$result_file" 2>/dev/null
    else
        : > "$result_file" 2>/dev/null
    fi
}

# Check whether the dotfiles checkout is behind origin (async, cached 24h).
# Two files, so consuming a result never postpones the next check:
#   repo-staleness-last-check  mtime-only claim stamp (when did we last fetch)
#   repo-staleness-result      consumable behind-count from that fetch
# The first interactive shell past the TTL claims the day (touch BEFORE
# spawning, so a burst of new shells starts at most one fetch -- a
# millisecond-wide race between two literally simultaneous shells can
# double-fetch, which is idempotent and accepted), fetches in the
# background, and a later shell prints the result ONCE (print consumes it).
# Silent when current, offline, cache unwritable, or $DOTFILEDIR is not a
# real work tree (worktrees have a .git FILE, so ask git and require "true";
# a bare repo or .git dir prints "false" and is excluded).
_dotfiles_staleness_check() {
    [[ -o interactive ]] || return 0
    [[ ! -t 1 ]] && return 0
    [[ -n "${DOTFILEDIR:-}" ]] || return 0
    [[ "$(git -C "$DOTFILEDIR" rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] || return 0

    local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/dotfiles"
    local check_stamp="$cache_dir/repo-staleness-last-check"
    local result_file="$cache_dir/repo-staleness-result"
    local cache_ttl=86400  # 24 hours

    # Never follow a symlinked cache file -- refuse to read/truncate it.
    [[ -L "$result_file" || -L "$check_stamp" ]] && return 0

    # Surface the previous check's result once, then consume it so later
    # shells (and post-update shells) stay quiet until the next fetch.
    # Always truncate after reading (even a malformed result), and only
    # print when the content is a validated nonempty digit string.
    if [[ -f "$result_file" && -s "$result_file" ]]; then
        local behind
        behind="$(cat "$result_file" 2>/dev/null)"
        if [[ "$behind" == <-> ]]; then
            printf '[INFO] dotfiles is %s commit(s) behind -- run '\''update'\'' or '\''update --ai'\''.\n' "$behind"
        fi
        : > "$result_file" 2>/dev/null
    fi

    # Skip the fetch if checked recently (mtime of the claim stamp only;
    # consuming the result above never touches this file).
    if [[ -f "$check_stamp" ]]; then
        local cache_age=$(( $(date +%s) - $(stat -f%m "$check_stamp" 2>/dev/null || stat -c%Y "$check_stamp" 2>/dev/null || echo 0) ))
        (( cache_age < cache_ttl )) && return 0
    fi

    # Claim the day BEFORE spawning; unwritable cache degrades to silence.
    mkdir -p "$cache_dir" 2>/dev/null || return 0
    : > "$check_stamp" 2>/dev/null || return 0
    _dotfiles_staleness_fetch "$result_file" &!
}
_dotfiles_staleness_check
