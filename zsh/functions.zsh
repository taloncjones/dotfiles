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
	bash $DOTFILEDIR/install/install.sh

	# return user to previous directory
	cd $currentdir
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

# --- ECC (Everything Claude Code) ---
# Plugin provides: skills, agents, commands, hooks (auto-updated by Claude Code).
# Rules: NOT vendored (retired 2026-07-02). Nothing auto-loads ~/.claude/rules;
#   the only functional consumers are on-demand ECC skills (e.g. rules-distill's
#   scan-rules.sh) whose paths are overridable. The full upstream rules tree
#   ships inside the marketplace clone at
#   ~/.claude/plugins/marketplaces/ecc/rules/ on every machine and container
#   with the plugin installed -- point consumers there. Only personal rules
#   (claude/rules/personal/, tracked) live at ~/.claude/rules now; leftover
#   vendored language dirs from older installs are inert and safe to delete
#   (_ecc_legacy_rules_notice flags them). The ECC repo clone remains only as
#   the source for codex-ecc-sync.
# Upstream is the v2 repo (affaan-m/ECC, plugin id ecc@ecc); the older
#   everything-claude-code v1 repo/marketplace is retired.
ECC_REPO_URL="https://github.com/affaan-m/ECC.git"
ECC_REPO_DIR="$HOME/Git/personal/ECC"

# helper: flag inert vendored rules left behind by pre-retirement installs
function _ecc_legacy_rules_notice() {
    local l
    local -a leftovers=()
    for l in common cpp python rust typescript web; do
        [[ -d "$DOTFILEDIR/claude/rules/$l" ]] && leftovers+=("$l")
    done
    if (( ${#leftovers} > 0 )); then
        echo "[INFO] Legacy vendored ECC rules present (${leftovers[*]}); vendoring is retired."
        echo "[INFO] They are untracked and inert. Remove with:"
        echo "[INFO]   rm -rf $DOTFILEDIR/claude/rules/{${(j:,:)leftovers}}"
        echo "[INFO] The full upstream tree lives at ~/.claude/plugins/marketplaces/ecc/rules/"
    fi
}

function codex-ecc-sync() {    # codex-ecc-sync() merges ECC into ~/.codex (AGENTS, prompts, MCP) and installs ECC git hooks into the dotfiles-owned hooks dir. ex: $ codex-ecc-sync
    local ecc_dir="$ECC_REPO_DIR"
    if [[ ! -d "$ecc_dir" ]]; then
        echo "[X] ECC repo not found. Run 'ecc-install' first."
        return 1
    fi
    # Codex is opt-in: only sync when the Codex CLI is actually installed.
    if ! command -v codex &>/dev/null; then
        echo "[INFO] Codex CLI not installed; skipping ECC -> Codex sync."
        return 0
    fi
    # The sync's add-only TOML merge needs node deps (e.g. @iarna/toml).
    if [[ ! -d "$ecc_dir/node_modules/@iarna/toml" ]]; then
        echo "[INFO] Installing ECC node deps for Codex sync..."
        (cd "$ecc_dir" && npm install --no-audit --no-fund --loglevel=error) \
            || { echo "[X] npm install failed"; return 1; }
    fi
    # Point ECC's git-hook installer at the DOTFILES-owned global hooks dir
    # (symlinked to $DOTFILEDIR/git/hooks) instead of ~/.codex/git-hooks, so
    # core.hooksPath stays dotfiles-managed and one hooks dir serves Claude,
    # Codex, and manual commits. AGENTS.md is already symlinked into dotfiles,
    # so the AGENTS merge lands there too.
    echo "[INFO] Syncing ECC into ~/.codex..."
    (cd "$ecc_dir" && ECC_GLOBAL_HOOKS_DIR="$HOME/.config/git/hooks" bash scripts/sync-ecc-to-codex.sh) \
        || { echo "[X] codex sync failed"; return 1; }
    # The hook installer rewrites core.hooksPath to an absolute path; restore the
    # canonical tilde form so the dotfiles-tracked .gitconfig stays stable.
    local gc="$DOTFILEDIR/git/.gitconfig"
    [[ -f "$gc" ]] && sed -i '' -E 's#^([[:space:]]*hooksPath = ).*#\1~/.config/git/hooks#' "$gc"
    echo "[OK] ECC synced into Codex; git hooks live in dotfiles git/hooks"
}

function ecc-install() {    # ecc-install([--local]) will set up ECC from scratch (repo, vendored rules, plugin). ex: $ ecc-install
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] ECC's Claude rules/plugin are global-only; ignoring --local."
    local ecc_dir="$ECC_REPO_DIR"

    # clone repo if not present
    if [[ ! -d "$ecc_dir" ]]; then
        echo "[INFO] Cloning ECC repo..."
        git clone "$ECC_REPO_URL" "$ecc_dir" || { echo "[X] clone failed"; return 1; }
        (cd "$ecc_dir" && npm install --no-audit --no-fund --loglevel=error)
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
    # upstream rules tree; only flag inert leftovers from older installs.
    _ecc_legacy_rules_notice

    # ensure the ecc marketplace + plugin exist in EVERY account config dir
    # (~/.claude personal, ~/.claude-work work), verified against each dir's
    # installed_plugins.json rather than CLI output (_claude_ensure_plugin uses
    # explicit CLAUDE_CONFIG_DIR + `command claude`, so the result does not
    # depend on $PWD via the claude() wrapper). A dir that does not exist yet
    # (e.g. work not set up) is skipped.
    local cfg_dir
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        _claude_ensure_plugin "$cfg_dir" "ecc@ecc" "ecc" "$ECC_REPO_URL" || return 1
    done

    # mirror ECC into Codex (no-op when the Codex CLI is absent)
    codex-ecc-sync || echo "[WARNING] Codex sync failed; Claude-side ECC install is unaffected"

    _claude_plugin_epoch_write ecc
    echo "[OK] ECC installed"
}

function ecc-update() {    # ecc-update([--local]) will pull latest ECC repo and update rules. ex: $ ecc-update
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] ECC's Claude rules/plugin are global-only; ignoring --local."
    local ecc_dir="$ECC_REPO_DIR"

    if [[ ! -d "$ecc_dir" ]]; then
        echo "[X] ECC repo not found. Run 'ecc-install' first."
        return 1
    fi

    echo "[INFO] Syncing ECC to upstream main..."
    # ECC is a read-only vendored mirror: we never commit here, and codex-ecc-sync's
    # `npm install` rewrites the tracked lockfiles (package-lock.json, yarn.lock) every
    # run. A rebase-pull (pull.rebase=true) then aborts on those unstaged changes. Fetch
    # + hard-reset sidesteps that and guarantees we exactly match upstream each time.
    (cd "$ecc_dir" && git fetch origin main && git reset --hard origin/main) \
        || { echo "[X] ECC sync failed"; return 1; }

    # rules vendoring retired (2026-07-02); flag inert leftovers only.
    _ecc_legacy_rules_notice

    # refresh the Codex mirror too (no-op when the Codex CLI is absent)
    codex-ecc-sync || echo "[WARNING] Codex sync failed; Claude-side ECC update is unaffected"

    _claude_plugin_epoch_write ecc
    echo "[OK] ECC updated"
}

function ecc-uninstall() {    # ecc-uninstall() removes the ECC plugin, repo, and metadata; vendored rules in dotfiles are left intact. ex: $ ecc-uninstall
    local ecc_dir="$ECC_REPO_DIR"

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
            CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins uninstall ecc@ecc 2>/dev/null
        fi
    done

    # remove repo
    if [[ -d "$ecc_dir" ]]; then
        echo "[INFO] Removing ECC repo..."
        rm -rf "$ecc_dir"
    fi

    rm -f "${ZSH_CACHE_DIR:-$HOME/.cache/zsh}/.ecc-update"
    echo "[OK] ECC uninstalled"
}

# --- GSD (Get Shit Done, community "redux" fork) ---
# Source of truth: npm @opengsd/get-shit-done-redux -- the safe community fork
# (https://github.com/open-gsd/get-shit-done-redux). The original
# get-shit-done-cc package was abandoned after a token rug-pull with publish
# access retained, so it is treated as compromised: never reinstall it, and
# gsd-uninstall actively removes it. The installer is npx-only (no global
# package, no gsd-sdk shim); it writes skills/commands/agents/hooks into
# ~/.claude (and ~/.codex when the codex CLI is present), and is idempotent.
# Flags accepted by gsd-{install,update,uninstall}:
#   -l, --local       install/remove under ./.claude (and ./.codex) in the current dir
#   -g, --global      install/remove under ~/ (the default)
#   --claude          target Claude Code only
#   --codex           target Codex only
#                     (default: both runtimes when codex is installed, else Claude only)
#   anything else     forwarded verbatim to the installer (e.g. --profile=core, --minimal)
GSD_REDUX_PKG="@opengsd/get-shit-done-redux@latest"

function _codex_remove_legacy_mirror_symlinks() {
    find "$HOME/.codex/skills" -maxdepth 1 -type l \
        \( -name 'gsd-*' -o -name 'ecc-*' -o -name 'superpowers-*' \) -delete 2>/dev/null || true
    find "$HOME/.codex/agents" -maxdepth 1 -type l \
        \( -name 'ecc-*' -o -name 'superpowers-*' \) -delete 2>/dev/null || true
}

# helper: run a command in a subshell from a guaranteed-valid directory ($HOME), so
# npm/npx/node don't crash with `uv_cwd ENOENT` when the shell's CWD has been deleted.
# Only for *global* GSD operations — never wrap a --local install with this.
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

# helper: run the redux installer at a scope (global runs from $HOME; local stays in CWD)
function _gsd_run() {
    local scope="$1"; shift
    if [[ "$scope" == "global" ]]; then
        _gsd_at_home npx -y "$GSD_REDUX_PKG" "$@"
    else
        npx -y "$GSD_REDUX_PKG" "$@"
    fi
}

# helper: parse gsd-{install,update,uninstall} args into caller-scoped vars:
#   gsd_scope       -> "global" (default) | "local"
#   gsd_targets     -> array of "claude"/"codex" (default: claude + codex-if-installed)
#   gsd_passthrough -> array of remaining args forwarded to the GSD installer
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

# helper: install/update GSD for one runtime target at a scope, forwarding any extra flags
function _gsd_install_target() {
    local scope="$1" target="$2"; shift 2
    [[ "$target" == "codex" ]] && _codex_remove_legacy_mirror_symlinks
    _gsd_run "$scope" --$target --$scope "$@"
}

# helper: install/update GSD for every parsed target
function _gsd_install_targets() {
    local verb="$1" scope="$2"; shift 2  # remaining args = installer passthrough
    local target
    for target in "${gsd_targets[@]}"; do
        echo "[INFO] ${verb} GSD for ${target} (${scope})..."
        _gsd_install_target "$scope" "$target" "$@" || { echo "[X] GSD ${target} ${verb:l} failed"; return 1; }
    done
}

function gsd-install() {    # gsd-install([--local] [--claude|--codex] [installer flags]) installs the GSD redux fork (global, both runtimes by default). ex: $ gsd-install --local
    local gsd_scope gsd_targets gsd_passthrough
    _gsd_parse_args "$@"
    _gsd_require_cwd "$gsd_scope" || return 1

    _gsd_install_targets Installing "$gsd_scope" "${gsd_passthrough[@]}" || return 1

    [[ "$gsd_scope" == "global" ]] && (( ${gsd_targets[(Ie)claude]} )) && _claude_plugin_epoch_write gsd
    echo "[OK] GSD installed (${(j:+:)gsd_targets}, $gsd_scope)"
}

function gsd-update() {    # gsd-update([--local] [--claude|--codex] [installer flags]) updates the GSD redux fork by re-running the idempotent installer. ex: $ gsd-update --profile=core
    local gsd_scope gsd_targets gsd_passthrough
    _gsd_parse_args "$@"
    _gsd_require_cwd "$gsd_scope" || return 1

    _gsd_install_targets Updating "$gsd_scope" "${gsd_passthrough[@]}" || return 1

    [[ "$gsd_scope" == "global" ]] && (( ${gsd_targets[(Ie)claude]} )) && _claude_plugin_epoch_write gsd
    echo "[OK] GSD updated (${(j:+:)gsd_targets}, $gsd_scope)"
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
    local -a junk
    junk=( "$base"/skills/gsd-*(N) "$base"/commands/gsd-*(N) "$base"/agents/gsd-*(N) "$base"/hooks/gsd-*(N)
           "$base"/get-shit-done(N) "$base"/commands/gsd(N) "$base"/.gsd-profile(N)
           "$base"/gsd-migration-journal(N) "$base"/gsd-file-manifest.json(N) "$base"/gsd-pristine(N)
           "$base"/gsd-install-state.json(N) "$base"/gsd-user-files-backup*(N)
           "$cbase"/skills/gsd-*(N) "$cbase"/prompts/gsd-*(N) "$cbase"/commands/gsd-*(N) "$cbase"/agents/gsd-*(N)
           "$cbase"/gsd-migration-journal(N) "$cbase"/gsd-file-manifest.json(N) "$cbase"/gsd-pristine(N)
           "$cbase"/gsd-install-state.json(N) "$cbase"/gsd-user-files-backup*(N) )
    (( ${#junk} )) && rm -rf "${junk[@]}"

    # 4. strip GSD hook registrations + permission from settings.json
    _gsd_strip_settings "$base/settings.json"

    echo "[OK] GSD uninstalled (${(j:+:)gsd_targets}, $gsd_scope)"
}

# Codex integration:
#   - ECC: codex-ecc-sync (run by ecc-install/ecc-update) merges ECC's AGENTS
#     block, prompts, and MCP servers into ~/.codex via the upstream
#     sync-ecc-to-codex.sh, and installs ECC's pre-commit/pre-push into the
#     dotfiles-owned global hooks dir ($DOTFILEDIR/git/hooks) so core.hooksPath
#     stays dotfiles-managed. Generated artifacts (~/.codex/prompts/ecc-*, the
#     config.toml MCP merge) are reproduced idempotently, not committed; the
#     static shared files (codex/AGENTS.md, git/hooks) live in this repo.
#   - Superpowers: provided to Codex by Codex's own plugin marketplace
#     ([plugins."superpowers@openai-curated"] in ~/.codex/config.toml) -- nothing
#     for dotfiles to mirror.
# install/common/link.sh still sweeps any leftover ~/.codex/{skills,agents}/{ecc,superpowers}-*
# symlinks from older mirror-style installs (the current sync writes prompts, not
# skill symlinks, so the sweep is harmless to it).

# --- Superpowers ---
# Plugin-only — no repo, no rules, no extra files

function superpowers-install() {    # superpowers-install([--local]) will install the Superpowers plugin. ex: $ superpowers-install
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] Claude Code plugins are global-only; ignoring --local."
    # The official marketplace is usually pre-registered by Claude Code, but on
    # a fresh machine it may be absent or still mid-fetch -- and `plugins
    # install` then no-ops with exit 0. _claude_ensure_plugin registers the
    # marketplace by git URL (synchronous clone), installs, and verifies against
    # installed_plugins.json, mirroring bootstrap-cloud.sh ensure_plugin.
    local cfg_dir
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        _claude_ensure_plugin "$cfg_dir" "superpowers@claude-plugins-official" \
            "claude-plugins-official" "$CLAUDE_OFFICIAL_MARKETPLACE_URL" || return 1
    done
}

function superpowers-update() {    # superpowers-update([--local]) will update the Superpowers plugin. ex: $ superpowers-update
    [[ "$(_claude_plugin_scope "$@")" == "local" ]] && echo "[WARNING] Claude Code plugins are global-only; ignoring --local."
    local cfg_dir updated=0
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        if ! _claude_plugin_installed "$cfg_dir" "superpowers@claude-plugins-official"; then
            echo "[INFO] Superpowers not installed ($cfg_dir); skipping"
            continue
        fi
        echo "[INFO] Updating Superpowers plugin ($cfg_dir)..."
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins update superpowers@claude-plugins-official \
            || { echo "[X] update failed ($cfg_dir)"; return 1; }
        updated=1
    done
    if (( updated )); then
        echo "[OK] Superpowers updated (restart Claude Code to apply)"
    else
        echo "[X] Superpowers not installed in any config dir. Run 'superpowers-install' first."
        return 1
    fi
}

function superpowers-uninstall() {    # superpowers-uninstall() will remove the Superpowers plugin. ex: $ superpowers-uninstall
    local cfg_dir
    for cfg_dir in "$HOME/.claude" "${CLAUDE_WORK_CONFIG_DIR:-$HOME/.claude-work}"; do
        [[ -d "$cfg_dir" ]] || continue
        if ! _claude_plugin_installed "$cfg_dir" "superpowers@claude-plugins-official"; then
            echo "[INFO] Superpowers not installed ($cfg_dir)"
            continue
        fi
        echo "[INFO] Removing Superpowers plugin ($cfg_dir)..."
        CLAUDE_CONFIG_DIR="$cfg_dir" command claude plugins uninstall superpowers@claude-plugins-official 2>/dev/null
        echo "[OK] Superpowers uninstalled ($cfg_dir)"
    done
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

# launch claude code with telegram channel enabled
function claude-telegram() {    # claude-telegram() will launch Claude Code with the Telegram bot channel. ex: $ claude-telegram
    claude --channels plugin:telegram@claude-plugins-official "$@"
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
