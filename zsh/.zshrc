# Optional toolchain paths (added if they exist)
[ -d "/Applications/CMake.app/Contents/bin" ] && export PATH="$PATH:/Applications/CMake.app/Contents/bin"
[ -d "/Applications/ArmGNUToolchain/12.2.rel1/arm-none-eabi/bin" ] && export PATH="$PATH:/Applications/ArmGNUToolchain/12.2.rel1/arm-none-eabi/bin"
[ -d ~/ti/ti-cgt-armllvm_4.0.1.LTS ] && export TI_ARMLLVM_DIR=~/ti/ti-cgt-armllvm_4.0.1.LTS && export PATH="$TI_ARMLLVM_DIR/bin:$PATH"

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# set XDG_CONFIG_HOME
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"

# tool defaults
export EDITOR="nano"
export VEDITOR="code"

# Set name of the theme to load --- if set to "random", it will
# load a random theme each time oh-my-zsh is loaded, in which case,
# to know which specific one was loaded, run: echo $RANDOM_THEME
# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="alanpeabody"

# Set list of themes to pick from when loading at random
# Setting this variable when ZSH_THEME=random will cause zsh to load
# a theme from this variable instead of looking in $ZSH/themes/
# If set to an empty array, this variable will have no effect.
# ZSH_THEME_RANDOM_CANDIDATES=( "robbyrussell" "agnoster" )

# Uncomment the following line to use case-sensitive completion.
# CASE_SENSITIVE="true"

# Uncomment the following line to use hyphen-insensitive completion.
# Case-sensitive completion must be off. _ and - will be interchangeable.
# HYPHEN_INSENSITIVE="true"

# Uncomment one of the following lines to change the auto-update behavior
# zstyle ':omz:update' mode disabled  # disable automatic updates
# zstyle ':omz:update' mode auto      # update automatically without asking
# zstyle ':omz:update' mode reminder  # just remind me to update when it's time

# Uncomment the following line to change how often to auto-update (in days).
# zstyle ':omz:update' frequency 13

# Uncomment the following line if pasting URLs and other text is messed up.
# DISABLE_MAGIC_FUNCTIONS="true"

# Uncomment the following line to disable colors in ls.
# DISABLE_LS_COLORS="true"

# Uncomment the following line to disable auto-setting terminal title.
# DISABLE_AUTO_TITLE="true"

# Uncomment the following line to enable command auto-correction.
# ENABLE_CORRECTION="true"

# Uncomment the following line to display red dots whilst waiting for completion.
# You can also set it to another string to have that shown instead of the default red dots.
# e.g. COMPLETION_WAITING_DOTS="%F{yellow}waiting...%f"
# Caution: this setting can cause issues with multiline prompts in zsh < 5.7.1 (see #5765)
# COMPLETION_WAITING_DOTS="true"

# Uncomment the following line if you want to disable marking untracked files
# under VCS as dirty. This makes repository status check for large repositories
# much, much faster.
# DISABLE_UNTRACKED_FILES_DIRTY="true"

# Uncomment the following line if you want to change the command execution time
# stamp shown in the history command output.
# You can set one of the optional three formats:
# "mm/dd/yyyy"|"dd.mm.yyyy"|"yyyy-mm-dd"
# or set a custom format using the strftime function format specifications,
# see 'man strftime' for details.
# HIST_STAMPS="mm/dd/yyyy"

# Would you like to use another custom folder than $ZSH/custom?
# ZSH_CUSTOM=/path/to/new-custom-folder

# Which plugins would you like to load?
# Standard plugins can be found in $ZSH/plugins/
# Custom plugins may be added to $ZSH_CUSTOM/plugins/
# Example format: plugins=(rails git textmate ruby lighthouse)
# Add wisely, as too many plugins slow down shell startup.
# Install ZSH plugins
# install zsh-autosugestions
plugins=(
    git
    colorize
    zsh-syntax-highlighting
    zsh-autosuggestions
)

# Rebuild the completion dump if it's older than 24h, otherwise reuse the cache
autoload -Uz compinit
_zcompdump_stale=(~/.zcompdump(N.mh+24))
if (( ${#_zcompdump_stale} )); then
  compinit
else
  compinit -C
fi
unset _zcompdump_stale

source $ZSH/oh-my-zsh.sh

# User configuration

# export MANPATH="/usr/local/man:$MANPATH"

# You may need to manually set your language environment
# export LANG=en_US.UTF-8

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# Compilation flags
# export ARCHFLAGS="-arch x86_64"

# Set personal aliases, overriding those provided by oh-my-zsh libs,
# plugins, and themes. Aliases can be placed here, though oh-my-zsh
# users are encouraged to define aliases within the ZSH_CUSTOM folder.
# For a full list of active aliases, run `alias`.
#
# Example aliases
# alias zshconfig="mate ~/.zshrc"
# alias ohmyzsh="mate ~/.oh-my-zsh"


#  Find dotfile repo directory on this system, set $DOTFILEDIR to contain absolute path
SOURCE="${(%):-%N}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
ZSHDIR="$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )"
DOTFILEDIR="$(dirname "$ZSHDIR")"
export DOTFILEDIR

# Add dotfiles bin and local bin to PATH
export PATH="$HOME/.local/bin:$DOTFILEDIR/bin:$PATH"

[ -d "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin" ] && export STM32_PRG_PATH=/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin

if [[ $(uname) == "Darwin" ]]; then
    ####################################################################################
    #################################### macOS #########################################
    ####################################################################################
    export VISUAL="code"
    export BROWSER="/Applications/Firefox.app/Contents/MacOS/firefox-bin"
    # Set 1Password as SSH agent on macOS
    export SSH_AUTH_SOCK=~/Library/Group\ Containers/2BUA8C4S2C.com.1password/t/agent.sock

    # Add visual studio code to the path if it isn't already there
    if [ -d "/Applications/Visual Studio Code.app/Contents/Resources/app/bin" ] && [[ ":$PATH:" != *":/Applications/Visual Studio Code.app/Contents/Resources/app/bin:"* ]]; then
        PATH="${PATH:+"$PATH:"}/Applications/Visual Studio Code.app/Contents/Resources/app/bin"
    fi
fi


# the below sources need to happen after the above shell initializations
# otherwise some functions/scripts like 'which' will not be found in the 
# correct spots, and that causes errors in aliases and functions

# load common ZSH aliases
source $DOTFILEDIR/zsh/aliases.zsh

# load common ZSH functions
source $DOTFILEDIR/zsh/functions.zsh

# load common ZSH custom themes
source $DOTFILEDIR/zsh/theme.zsh

# load common helper scripts
for file in "$DOTFILEDIR/zsh/scripts/"*
do
    if [[ -f $file ]]; then
        source $file
    fi
done

# Source 1Password plugins if available
if [ -f ~/.config/op/plugins.sh ]; then
    source ~/.config/op/plugins.sh
fi

[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# bun completions
[ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# Machine-local work overrides (not tracked in this repo).
# Put work-specific PATH, env, aliases, and functions in ~/.zsh-work.zsh.
[ -f "$HOME/.zsh-work.zsh" ] && source "$HOME/.zsh-work.zsh"
