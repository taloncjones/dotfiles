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

# update the dotfiles completely
function update() {    # update() will update the current dotfiles installation and dependencies. ex: $ update
	# save the current directory
	currentdir=$(pwd)

	# navigate to dotfile install directory
	dotfiles

	# pull new version from origin
	git pull

    # update tldr definitions
    tldr --update
	
	# execute the install script
	# note: we manually specify bash here, since the install script is written in bash
	# and we're calling it from zsh. bad things happen if you use source instead
	local install_status=0
	bash $DOTFILEDIR/install/install.sh || install_status=$?

	# return user to previous directory
	cd $currentdir

	# propagate a red install instead of masking it with the cd above
	if (( install_status != 0 )); then
		echo "[X] update failed: install.sh exited $install_status"
		return $install_status
	fi
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

##############################
###### Claude Code Accounts
##############################
# Fable requires OAuth login (no API token), so work and personal need two
# separate logins. CLAUDE_CONFIG_DIR is the supported isolation mechanism:
# ~/.claude holds the personal login (the default -- desktop app and any
# unwrapped launch lands there); ~/.claude-work holds the work login. The
# claude() wrapper injects the work config dir whenever claude is launched
# from inside ~/Git/work. A pre-set CLAUDE_CONFIG_DIR always wins, and
# `claude --personal` (or CLAUDE_CONFIG_DIR=$HOME/.claude) forces the
# personal account from a work dir. If ~/.claude-work does not exist yet,
# claude creates it and prompts a fresh OAuth login for the work account.
CLAUDE_WORK_CONFIG_DIR="$HOME/.claude-work"
CLAUDE_WORK_TREE="$HOME/Git/work"

# helper: resolve which config dir a claude launch would use from $PWD.
# :A resolves symlinks on both sides so a symlinked path into ~/Git/work
# still routes to the work account.
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
    local use_personal=0 arg cfg
    local -a forwarded=()
    for arg in "$@"; do
        case "$arg" in
            --personal) use_personal=1 ;;
            *) forwarded+=("$arg") ;;
        esac
    done
    if (( use_personal )); then
        cfg="$HOME/.claude"
    else
        cfg="$(_claude_config_dir)"
    fi
    if [[ "$cfg" == "$HOME/.claude" ]]; then
        command claude "${forwarded[@]}"
    else
        CLAUDE_CONFIG_DIR="$cfg" command claude "${forwarded[@]}"
    fi
}

##############################
###### Claude Code Plugins
##############################

# helper: record update epoch for a plugin
function _claude_plugin_epoch_write() {
    local name="$1"
    zmodload zsh/datetime
    mkdir -p "${ZSH_CACHE_DIR:-$HOME/.cache/zsh}"
    echo "LAST_${name:u}_EPOCH=$(( EPOCHSECONDS / 60 / 60 / 24 ))" > "${ZSH_CACHE_DIR:-$HOME/.cache/zsh}/.${name}-update"
}

# helper: resolve install scope from args. Echoes "global" (the default) or "local".
function _claude_plugin_scope() {
    local scope="global" arg
    for arg in "$@"; do
        case "$arg" in
            -l|--local)  scope="local" ;;
            -g|--global) scope="global" ;;
        esac
    done
    echo "$scope"
}

# --- Plugin install ground truth (ported from bootstrap-cloud.sh) ---
# `claude plugins install` can exit 0 without installing: a marketplace that is
# registered but still mid-fetch resolves the plugin to "nothing to do" and the
# command "succeeds". Exit codes and CLI output are therefore not evidence; the
# on-disk record <config-dir>/plugins/installed_plugins.json is. These helpers
# mirror bootstrap-cloud.sh's plugin_installed / marketplace_lists_plugin /
# ensure_plugin, parameterized by config dir because machines have TWO
# (~/.claude personal, ~/.claude-work work). The retry budget is smaller than
# the cloud one: machines do not face the ~70s cold-container marketplace
# warmup, only transient network blips.
CLAUDE_OFFICIAL_MARKETPLACE_URL="https://github.com/anthropics/claude-plugins-official.git"
CLAUDE_PLUGIN_RETRIES=3
CLAUDE_PLUGIN_RETRY_DELAY=2
CLAUDE_PLUGIN_RETRY_MAX_DELAY=5

# helper: true iff the plugin id is recorded in the config dir's installed_plugins.json
function _claude_plugin_installed() {
    local cfg_dir="$1" plugin_id="$2"
    local record="$cfg_dir/plugins/installed_plugins.json"
    [[ -f "$record" ]] && grep -q "$plugin_id" "$record"
}

# helper: true iff the marketplace's on-disk manifest declares the plugin --
# the condition the install resolver actually checks, so waiting on it is
# deterministic rather than a blind timer.
function _claude_marketplace_lists_plugin() {
    local cfg_dir="$1" plugin_name="$2" marketplace="$3"
    local manifest="$cfg_dir/plugins/marketplaces/$marketplace/.claude-plugin/marketplace.json"
    [[ -f "$manifest" ]] && grep -Eq "\"name\"[[:space:]]*:[[:space:]]*\"${plugin_name}\"" "$manifest"
}

# helper: install one plugin into one config dir and PROVE it landed.
# Usage: _claude_ensure_plugin <config-dir> <plugin-id> <marketplace> [add-url]
function _claude_ensure_plugin() {
    local cfg_dir="$1" plugin_id="$2" marketplace="$3" add_url="${4:-}"
    local plugin_name="${plugin_id%@*}"

    if _claude_plugin_installed "$cfg_dir" "$plugin_id"; then
        echo "[INFO] $plugin_id already installed ($cfg_dir)"
        return 0
    fi

    # Register the marketplace if missing (idempotent). A pre-registered one
    # (e.g. added by the platform or an earlier run) is left alone.
    if ! CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugin marketplace list 2>/dev/null | grep -qiw "$marketplace"; then
        if [[ -n "$add_url" ]]; then
            echo "[INFO] Adding $marketplace marketplace ($cfg_dir)..."
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugin marketplace add "$add_url" \
                || { echo "[X] marketplace add failed for $marketplace ($cfg_dir)"; return 1; }
        else
            echo "[WARNING] Marketplace $marketplace not registered and no add URL known ($cfg_dir)"
        fi
    fi

    # Phase 1: wait until the marketplace manifest lists the plugin, refreshing
    # the cache between checks.
    local attempt=1 delay=$CLAUDE_PLUGIN_RETRY_DELAY
    while ! _claude_marketplace_lists_plugin "$cfg_dir" "$plugin_name" "$marketplace"; do
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
        _claude_marketplace_lists_plugin "$cfg_dir" "$plugin_name" "$marketplace" && break
        if [[ "$attempt" -ge "$CLAUDE_PLUGIN_RETRIES" ]]; then
            echo "[WARNING] $marketplace manifest never listed $plugin_name after $CLAUDE_PLUGIN_RETRIES refreshes; installing anyway ($cfg_dir)"
            break
        fi
        echo "[INFO] $marketplace manifest not warm yet (attempt $attempt/$CLAUDE_PLUGIN_RETRIES); retrying in ${delay}s..."
        sleep "$delay"
        delay=$(( delay * 2 ))
        [[ "$delay" -gt "$CLAUDE_PLUGIN_RETRY_MAX_DELAY" ]] && delay=$CLAUDE_PLUGIN_RETRY_MAX_DELAY
        attempt=$(( attempt + 1 ))
    done

    # Phase 2: install, then verify against installed_plugins.json.
    attempt=1; delay=$CLAUDE_PLUGIN_RETRY_DELAY
    while [[ "$attempt" -le "$CLAUDE_PLUGIN_RETRIES" ]]; do
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugin marketplace update "$marketplace" >/dev/null 2>&1 || true
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins install "$plugin_id" >/dev/null 2>&1 || true
        if _claude_plugin_installed "$cfg_dir" "$plugin_id"; then
            echo "[OK] Installed $plugin_id ($cfg_dir, attempt $attempt/$CLAUDE_PLUGIN_RETRIES)"
            return 0
        fi
        if [[ "$attempt" -lt "$CLAUDE_PLUGIN_RETRIES" ]]; then
            echo "[INFO] $plugin_id not in installed_plugins.json yet (attempt $attempt/$CLAUDE_PLUGIN_RETRIES); retrying in ${delay}s..."
            sleep "$delay"
            delay=$(( delay * 2 ))
            [[ "$delay" -gt "$CLAUDE_PLUGIN_RETRY_MAX_DELAY" ]] && delay=$CLAUDE_PLUGIN_RETRY_MAX_DELAY
        fi
        attempt=$(( attempt + 1 ))
    done

    echo "[X] $plugin_id not installed after $CLAUDE_PLUGIN_RETRIES attempts ($cfg_dir)."
    echo "[X] Recover with: CLAUDE_CONFIG_DIR=$cfg_dir claude plugins install $plugin_id"
    return 1
}

# --- Codex plugin lifecycle ---
# Codex plugins are global to CODEX_HOME. ECC and Superpowers are staged into a
# dedicated local marketplace so every manifest reference is copied into the
# plugin cache without depending on account-provisioned marketplaces.
CODEX_WORKFLOW_MARKETPLACE_DIR="${CODEX_WORKFLOW_MARKETPLACE_DIR:-$HOME/.local/share/dotfiles/codex-workflows}"

function _codex_plugin_installed() {
    local plugin_id="$1"
    command codex plugin list --json 2>/dev/null | awk -v target="$plugin_id" '
        /"pluginId"[[:space:]]*:/ {
            current = index($0, "\"" target "\"") > 0
            installed = 0
            enabled = 0
        }
        current && /"installed"[[:space:]]*:[[:space:]]*true/ { installed = 1 }
        current && /"enabled"[[:space:]]*:[[:space:]]*true/ { enabled = 1 }
        current && installed && enabled { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

function _codex_plugin_present() {
    local plugin_id="$1"
    command codex plugin list --json 2>/dev/null | awk -v target="$plugin_id" '
        /"pluginId"[[:space:]]*:/ && index($0, "\"" target "\"") > 0 { found = 1 }
        END { exit found ? 0 : 1 }
    '
}

function _codex_marketplace_installed() {
    local marketplace="$1"
    command codex plugin marketplace list 2>/dev/null | awk -v target="$marketplace" 'NR > 1 && $1 == target { found = 1 } END { exit found ? 0 : 1 }'
}

# Usage: _codex_ensure_plugin <plugin-id> [marketplace-source]
function _codex_ensure_plugin() {
    local plugin_id="$1" marketplace_source="${2:-}"
    local marketplace="${plugin_id#*@}"

    if _codex_plugin_installed "$plugin_id"; then
        echo "[INFO] $plugin_id already installed (Codex)"
        return 0
    fi

    if [[ -n "$marketplace_source" ]] && ! _codex_marketplace_installed "$marketplace"; then
        echo "[INFO] Adding $marketplace marketplace (Codex)..."
        command codex plugin marketplace add "$marketplace_source" \
            || { echo "[X] marketplace add failed for $marketplace (Codex)"; return 1; }
    fi

    echo "[INFO] Installing $plugin_id (Codex)..."
    command codex plugin add "$plugin_id" \
        || { echo "[X] install failed for $plugin_id (Codex)"; return 1; }
    if _codex_plugin_installed "$plugin_id"; then
        echo "[OK] Installed $plugin_id (Codex; start a new thread to apply)"
        return 0
    fi

    echo "[X] $plugin_id is not installed and enabled after Codex reported success"
    return 1
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

function _codex_reinstall_plugin() {
    local plugin_id="$1" marketplace_source="${2:-}"
    _codex_remove_plugin "$plugin_id" || return 1
    _codex_ensure_plugin "$plugin_id" "$marketplace_source"
}

function _codex_normalize_skill_frontmatter() {
    local skills_dir="$1"
    command -v perl &>/dev/null \
        || { echo "[X] perl is required to normalize Codex skill frontmatter"; return 1; }
    find "$skills_dir" -name SKILL.md -exec perl -pi -e \
        'if (/^description: (?!["\x27|>])(.+)$/) { $_ = "description: >-\n  $1\n" }' {} +
}

function _codex_stage_ecc_plugin() {
    local source_dir="$ECC_REPO_DIR"
    local destination="$CODEX_WORKFLOW_MARKETPLACE_DIR"
    local template_dir="$DOTFILEDIR/codex/plugins/ecc"
    local marketplace_template="$DOTFILEDIR/codex/.agents/plugins/marketplace.json"
    local plugins_dir="$destination/plugins"
    local staging="$plugins_dir/.ecc.tmp.$$"
    local plugin_dir="$staging"

    [[ -n "$destination" && "$destination" != "/" ]] \
        || { echo "[X] invalid Codex workflow marketplace path"; return 1; }
    [[ -d "$source_dir/skills" && -f "$source_dir/.mcp.json" ]] \
        || { echo "[X] ECC checkout lacks Codex skills or MCP config: $source_dir"; return 1; }
    [[ -f "$template_dir/.codex-plugin/plugin.json" && -f "$marketplace_template" ]] \
        || { echo "[X] dotfiles ECC Codex plugin templates are incomplete"; return 1; }

    rm -rf "$staging"
    mkdir -p "$destination/.agents/plugins" "$plugin_dir/.codex-plugin" || return 1
    cp "$marketplace_template" "$destination/.agents/plugins/marketplace.json" || return 1
    cp "$template_dir/.codex-plugin/plugin.json" "$plugin_dir/.codex-plugin/plugin.json" || return 1
    cp "$source_dir/.mcp.json" "$plugin_dir/.mcp.json" || return 1
    cp -R "$source_dir/skills" "$plugin_dir/skills" || return 1
    # Codex validates skill frontmatter as strict YAML. Convert upstream's
    # single-line descriptions to folded scalars so embedded colons remain
    # valid without changing the rendered description.
    _codex_normalize_skill_frontmatter "$plugin_dir/skills" || return 1
    if [[ -d "$source_dir/assets" ]]; then
        cp -R "$source_dir/assets" "$plugin_dir/assets" || return 1
    fi

    rm -rf "$plugins_dir/ecc"
    mv "$staging" "$plugins_dir/ecc" || return 1
    echo "[OK] Staged self-contained ECC Codex plugin at $plugins_dir/ecc"
}

function _codex_install_ecc_plugin() {
    command -v codex &>/dev/null || { echo "[INFO] Codex CLI not installed; skipping ECC Codex plugin."; return 0; }
    _codex_stage_ecc_plugin || return 1
    _codex_ensure_plugin "ecc@dotfiles-workflows" "$CODEX_WORKFLOW_MARKETPLACE_DIR"
}

function _codex_update_ecc_plugin() {
    command -v codex &>/dev/null || { echo "[INFO] Codex CLI not installed; skipping ECC Codex plugin."; return 0; }
    _codex_stage_ecc_plugin || return 1
    _codex_reinstall_plugin "ecc@dotfiles-workflows" "$CODEX_WORKFLOW_MARKETPLACE_DIR"
}

function _codex_stage_superpowers_plugin() {
    local source_dir="$SUPERPOWERS_REPO_DIR"
    local destination="$CODEX_WORKFLOW_MARKETPLACE_DIR"
    local marketplace_template="$DOTFILEDIR/codex/.agents/plugins/marketplace.json"
    local plugins_dir="$destination/plugins"
    local staging="$plugins_dir/.superpowers.tmp.$$"

    [[ -n "$destination" && "$destination" != "/" ]] \
        || { echo "[X] invalid Codex workflow marketplace path"; return 1; }
    [[ -f "$source_dir/.codex-plugin/plugin.json" && -d "$source_dir/skills" ]] \
        || { echo "[X] Superpowers checkout lacks its Codex plugin: $source_dir"; return 1; }
    [[ -f "$marketplace_template" ]] \
        || { echo "[X] dotfiles Codex marketplace template is missing"; return 1; }

    rm -rf "$staging"
    mkdir -p "$destination/.agents/plugins" "$staging/.codex-plugin" || return 1
    cp "$marketplace_template" "$destination/.agents/plugins/marketplace.json" || return 1
    cp "$source_dir/.codex-plugin/plugin.json" "$staging/.codex-plugin/plugin.json" || return 1
    # Superpowers 6.1.1 added an empty top-level hooks object that Codex's
    # plugin validator rejects. Hooks are not part of this skills-only package.
    perl -0pi -e 's/\s*"hooks"\s*:\s*(?:"[^"]*"|\{[^{}]*\})\s*,//s' \
        "$staging/.codex-plugin/plugin.json" || return 1
    if grep -q '"hooks"[[:space:]]*:' "$staging/.codex-plugin/plugin.json"; then
        echo "[X] unsupported Superpowers hooks field could not be removed"
        return 1
    fi
    cp -R "$source_dir/skills" "$staging/skills" || return 1
    _codex_normalize_skill_frontmatter "$staging/skills" || return 1
    if [[ -d "$source_dir/assets" ]]; then
        cp -R "$source_dir/assets" "$staging/assets" || return 1
    fi

    rm -rf "$plugins_dir/superpowers"
    mv "$staging" "$plugins_dir/superpowers" || return 1
    echo "[OK] Staged self-contained Superpowers Codex plugin at $plugins_dir/superpowers"
}

function _codex_install_superpowers_plugin() {
    _codex_stage_superpowers_plugin || return 1
    # Remove the account-provisioned variant before installing the managed
    # marketplace copy, preventing duplicate superpowers:* skill names.
    _codex_remove_plugin "superpowers@openai-curated" || return 1
    _codex_ensure_plugin "superpowers@dotfiles-workflows" "$CODEX_WORKFLOW_MARKETPLACE_DIR"
}

function _codex_update_superpowers_plugin() {
    _codex_stage_superpowers_plugin || return 1
    _codex_remove_plugin "superpowers@openai-curated" || return 1
    _codex_reinstall_plugin "superpowers@dotfiles-workflows" "$CODEX_WORKFLOW_MARKETPLACE_DIR"
}

# --- ECC (Everything Claude Code) ---
# Plugin provides: skills, agents, commands, hooks (auto-updated by Claude Code).
# Rules: NOT vendored (retired 2026-07-02). Claude Code natively auto-loads
#   every .md under ~/.claude/rules at launch: a `paths:` frontmatter scopes a
#   rule to sessions with matching files in context; none = every session.
#   (Verified live in a cloud session 2026-07-02; the earlier "nothing
#   auto-loads" finding came from fresh clones where the untracked vendored
#   dirs did not exist.) The full upstream rules tree ships inside the
#   marketplace clone at ~/.claude/plugins/marketplaces/ecc/rules/ on every
#   machine and container with the plugin installed -- point on-demand
#   consumers (e.g. rules-distill's scan-rules.sh) there. Only our own
#   always-on rules (claude/rules/personal/, tracked) live at ~/.claude/rules
#   now; leftover vendored language dirs from older installs still AUTO-LOAD
#   (common/ and web/ have no `paths:`, so they load every session) and should
#   be deleted (_ecc_legacy_rules_notice flags them). The ECC repo clone also
#   provides source content for an independent, self-contained Codex plugin.
# Upstream is the v2 repo (affaan-m/ECC, plugin id ecc@ecc); the older
#   everything-claude-code v1 repo/marketplace is retired.
ECC_REPO_URL="https://github.com/affaan-m/ECC.git"
ECC_REPO_DIR="$HOME/Git/personal/ECC"
SUPERPOWERS_REPO_URL="https://github.com/obra/superpowers.git"
SUPERPOWERS_REPO_DIR="${SUPERPOWERS_REPO_DIR:-$HOME/.local/share/dotfiles/sources/superpowers}"

# helper: flag vendored rules left behind by pre-retirement installs. Not
# inert: Claude Code auto-loads them (common/web every session, language dirs
# on matching files), so leftovers inject stale upstream guidance until removed.
function _ecc_legacy_rules_notice() {
    local l
    local -a leftovers=()
    for l in common cpp python rust typescript web; do
        [[ -d "$DOTFILEDIR/claude/rules/$l" ]] && leftovers+=("$l")
    done
    if (( ${#leftovers} > 0 )); then
        echo "[WARNING] Legacy vendored ECC rules present (${leftovers[*]}); vendoring is retired."
        echo "[WARNING] They are untracked but still auto-load into sessions. Remove with:"
        # No brace form here: a single-element {web} does not brace-expand when
        # pasted, so rm -rf would hit a literal '{web}' path and silently no-op.
        echo "[WARNING]   rm -rf" "${leftovers[@]/#/$DOTFILEDIR/claude/rules/}"
        echo "[INFO] The full upstream tree lives at ~/.claude/plugins/marketplaces/ecc/rules/"
    fi
}

function ecc-install() {    # ecc-install([--local]) installs ECC independently for Claude and Codex. ex: $ ecc-install
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] ECC's Claude rules/plugin are global-only; ignoring --local."
    local ecc_dir="$ECC_REPO_DIR"

    # clone repo if not present
    if [[ ! -d "$ecc_dir" ]]; then
        echo "[INFO] Cloning ECC repo..."
        git clone "$ECC_REPO_URL" "$ecc_dir" || { echo "[X] clone failed"; return 1; }
    else
        echo "[INFO] ECC repo already exists, pulling latest..."
        (cd "$ecc_dir" && git pull origin main) || { echo "[X] git pull failed"; return 1; }
    fi

    # clean previous full install to avoid duplicates with plugin
    if [[ -f "$HOME/.claude/ecc/install-state.json" ]]; then
        echo "[INFO] Cleaning previous ECC install..."
        (cd "$ecc_dir" && node scripts/uninstall.js 2>/dev/null)
    fi

    # rules vendoring retired (2026-07-02): the marketplace clone carries the
    # upstream rules tree; flag active leftovers from older installs.
    _ecc_legacy_rules_notice

    # ensure the ecc marketplace + plugin exist in EVERY account config dir
    # (~/.claude personal, ~/.claude-work work), verified against each dir's
    # installed_plugins.json rather than CLI output (_claude_ensure_plugin uses
    # explicit CLAUDE_CONFIG_DIR + `command claude`, so the result does not
    # depend on $PWD via the claude() wrapper). A dir that does not exist yet
    # (e.g. work not set up) is skipped.
    local cfg_dir install_status=0
    if command -v claude &>/dev/null; then
        for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
            [[ -d "$cfg_dir" ]] || continue
            _claude_ensure_plugin "$cfg_dir" "ecc@ecc" "ecc" "$ECC_REPO_URL" || install_status=1
        done
    else
        echo "[INFO] Claude CLI not installed; skipping ECC Claude plugins."
    fi

    _codex_install_ecc_plugin || install_status=1

    _claude_plugin_epoch_write ecc
    if (( install_status == 0 )); then
        echo "[OK] ECC installed for available Claude and Codex runtimes"
    else
        echo "[X] ECC installation was incomplete; review the runtime-specific errors above"
        return 1
    fi
}

function ecc-update() {    # ecc-update([--local]) will pull latest ECC repo and update rules. ex: $ ecc-update
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] ECC's Claude rules/plugin are global-only; ignoring --local."
    local ecc_dir="$ECC_REPO_DIR"

    if [[ ! -d "$ecc_dir" ]]; then
        echo "[X] ECC repo not found. Run 'ecc-install' first."
        return 1
    fi

    echo "[INFO] Syncing ECC to upstream main..."
    # ECC is a read-only source mirror: fetch + hard-reset guarantees the staged
    # Codex plugin and Claude marketplace both derive from upstream main.
    (cd "$ecc_dir" && git fetch origin main && git reset --hard origin/main) \
        || { echo "[X] ECC sync failed"; return 1; }

    # rules vendoring retired (2026-07-02); flag active leftovers only.
    _ecc_legacy_rules_notice

    local cfg_dir update_status=0
    if command -v claude &>/dev/null; then
        for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
            [[ -d "$cfg_dir" ]] || continue
            _claude_ensure_plugin "$cfg_dir" "ecc@ecc" "ecc" "$ECC_REPO_URL" || { update_status=1; continue; }
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugin marketplace update ecc >/dev/null 2>&1 || true
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins update ecc@ecc \
                || { echo "[X] ECC update failed ($cfg_dir)"; update_status=1; }
        done
    fi

    _codex_update_ecc_plugin || update_status=1

    _claude_plugin_epoch_write ecc
    if (( update_status == 0 )); then
        echo "[OK] ECC updated for available Claude and Codex runtimes"
    else
        echo "[X] ECC update was incomplete; review the runtime-specific errors above"
        return 1
    fi
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
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins uninstall ecc@ecc 2>/dev/null || uninstall_status=1
        fi
    done

    _codex_remove_plugin "ecc@dotfiles-workflows" || uninstall_status=1

    # remove repo
    if [[ -d "$ecc_dir" ]]; then
        echo "[INFO] Removing ECC repo..."
        rm -rf "$ecc_dir"
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
#   - ECC: staged as a self-contained plugin under
#     ~/.local/share/dotfiles/codex-workflows and installed from the
#     dotfiles-workflows marketplace. Claude and Codex installations do not
#     share runtime files.
#   - Superpowers: staged from its upstream repository into the same native
#     marketplace without sharing Claude's installed plugin files.
# install/common/link.sh still sweeps leftover mirror-style skill/agent links.

# --- Superpowers ---
# Claude uses its official plugin marketplace. Codex uses a separate upstream
# checkout staged into the dotfiles-owned native marketplace.

function superpowers-install() {    # superpowers-install([--local]) will install the Superpowers plugin. ex: $ superpowers-install
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] Claude Code plugins are global-only; ignoring --local."
    # The official marketplace is usually pre-registered by Claude Code, but on
    # a fresh machine it may be absent or still mid-fetch -- and `plugins
    # install` then no-ops with exit 0. _claude_ensure_plugin registers the
    # marketplace by git URL (synchronous clone), installs, and verifies against
    # installed_plugins.json, mirroring bootstrap-cloud.sh ensure_plugin.
    local cfg_dir install_status=0 codex_source_status=0
    if command -v claude &>/dev/null; then
        for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
            [[ -d "$cfg_dir" ]] || continue
            _claude_ensure_plugin "$cfg_dir" "superpowers@claude-plugins-official" \
                "claude-plugins-official" "$CLAUDE_OFFICIAL_MARKETPLACE_URL" || install_status=1
        done
    else
        echo "[INFO] Claude CLI not installed; skipping Superpowers Claude plugins."
    fi
    if command -v codex &>/dev/null; then
        if [[ ! -d "$SUPERPOWERS_REPO_DIR" ]]; then
            echo "[INFO] Cloning Superpowers source for Codex..."
            if mkdir -p "${SUPERPOWERS_REPO_DIR:h}"; then
                git clone "$SUPERPOWERS_REPO_URL" "$SUPERPOWERS_REPO_DIR" || codex_source_status=1
            else
                codex_source_status=1
            fi
        else
            echo "[INFO] Superpowers source already exists, pulling latest..."
            (cd "$SUPERPOWERS_REPO_DIR" && git pull origin main) || codex_source_status=1
        fi
        if (( codex_source_status == 0 )); then
            _codex_install_superpowers_plugin || install_status=1
        else
            install_status=1
        fi
    else
        echo "[INFO] Codex CLI not installed; skipping Superpowers Codex plugin."
    fi
    (( install_status == 0 )) || return 1
    echo "[OK] Superpowers installed for available Claude and Codex runtimes"
}

function superpowers-update() {    # superpowers-update([--local]) will update the Superpowers plugin. ex: $ superpowers-update
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] Claude Code plugins are global-only; ignoring --local."
    local cfg_dir update_status=0 codex_source_status=0
    if command -v claude &>/dev/null; then
        for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
            [[ -d "$cfg_dir" ]] || continue
            _claude_ensure_plugin "$cfg_dir" "superpowers@claude-plugins-official" \
                "claude-plugins-official" "$CLAUDE_OFFICIAL_MARKETPLACE_URL" || { update_status=1; continue; }
            echo "[INFO] Updating Superpowers plugin ($cfg_dir)..."
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins update superpowers@claude-plugins-official \
                || { echo "[X] update failed ($cfg_dir)"; update_status=1; }
        done
    fi
    if command -v codex &>/dev/null; then
        if [[ ! -d "$SUPERPOWERS_REPO_DIR" ]]; then
            echo "[X] Superpowers source not found. Run 'superpowers-install' first."
            update_status=1
        else
            echo "[INFO] Syncing Superpowers source to upstream main..."
            (cd "$SUPERPOWERS_REPO_DIR" && git fetch origin main && git reset --hard origin/main) \
                || codex_source_status=1
            if (( codex_source_status == 0 )); then
                _codex_update_superpowers_plugin || update_status=1
            else
                update_status=1
            fi
        fi
    fi
    (( update_status == 0 )) || return 1
    echo "[OK] Superpowers updated for available Claude and Codex runtimes; start new sessions to apply"
}

function superpowers-uninstall() {    # superpowers-uninstall() will remove the Superpowers plugin. ex: $ superpowers-uninstall
    local cfg_dir uninstall_status=0
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        if ! _claude_plugin_installed "$cfg_dir" "superpowers@claude-plugins-official"; then
            echo "[INFO] Superpowers not installed ($cfg_dir)"
            continue
        fi
        echo "[INFO] Removing Superpowers plugin ($cfg_dir)..."
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins uninstall superpowers@claude-plugins-official 2>/dev/null || uninstall_status=1
        echo "[OK] Superpowers uninstalled ($cfg_dir)"
    done
    _codex_remove_plugin "superpowers@dotfiles-workflows" || uninstall_status=1
    _codex_remove_plugin "superpowers@openai-curated" || uninstall_status=1
    if [[ -d "$SUPERPOWERS_REPO_DIR" ]]; then
        echo "[INFO] Removing Superpowers source checkout..."
        rm -rf "$SUPERPOWERS_REPO_DIR"
    fi
    (( uninstall_status == 0 )) || return 1
}

# --- Startup update check (OMZ-style) ---

function _claude_plugin_check_update() {
    [[ ! -t 1 ]] && return
    zmodload zsh/datetime
    local current_epoch=$(( EPOCHSECONDS / 60 / 60 / 24 ))
    local update_days=14
    local cache_dir="${ZSH_CACHE_DIR:-$HOME/.cache/zsh}"
    local stale=()

    # gsd is deliberately absent: GSD is retired, and a leftover cache stamp
    # would nag 'gsd-update' on machines where the right move is gsd-uninstall.
    for plugin in ecc; do
        local update_file="$cache_dir/.${plugin}-update"
        # Only remind for plugins actually managed here: the cache is written by
        # {plugin}-install/update and removed by {plugin}-uninstall, so an
        # uninstalled plugin has no cache file and is silently skipped (no nag).
        [[ -f "$update_file" ]] || continue
        source "$update_file"
        local epoch_var="LAST_${plugin:u}_EPOCH"
        local last=${(P)epoch_var:-0}
        local days_since=$(( current_epoch - last ))
        (( days_since >= update_days )) && stale+=("$plugin (${days_since}d)")
    done

    if (( ${#stale} > 0 )); then
        echo "[INFO] Stale: ${(j:, :)stale}. Run '${stale[1]%% *}-update' to refresh."
    fi
}
_claude_plugin_check_update

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
