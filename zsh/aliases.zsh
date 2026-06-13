#!/bin/zsh
# aliases.zsh - Shell aliases for common operations
#
# Defines shortcuts for navigation, networking, hardware info, and platform-specific tools.
# Loaded by .zshrc. Use `aliaslist` to see all available aliases.

##############################
###### General
##############################

# List all available aliases from this file
function aliaslist() {
    # grab all of the common aliases to both platforms
    local list=$(grep 'alias ' "$DOTFILEDIR/zsh/aliases.zsh" | awk '{$1=$1};1' | highlight --syntax=bash)

    echo "$list" | sort -u -d -s
}

# reload current configuration
alias reload="source ~/.zshrc"

# Print each PATH entry on a separate line
alias path='echo -e ${PATH//:/\\n}'

# print the dotfile directory
alias dotfile='cd $DOTFILEDIR'
alias dotfiles='cd $DOTFILEDIR'

# git directory shortcuts
alias work='cd ~/Git/work'
alias personal='cd ~/Git/personal'

# enter ncdu
alias fsa='ncdu'

# shorthand for permissions function
alias perms='permissions'

# shorthands for directory listing (fall back to plain ls if eza is missing)
if command -v eza >/dev/null; then
    alias ls='eza --time-style long-iso'
fi
alias ll='ls -alh'

# add formatting to glow command
alias glow='glow --style "$DOTFILEDIR/zsh/styles/glow_style.json" -w 120'

# shorthand for lazygit
alias lg='lazygit'

##############################
###### Networking
##############################

# IP lookup functions (lazy-evaluated, only run when called)
function _getipv4() { curl -4 simpip.com --max-time 2 --proto-default https --silent 2>/dev/null || echo "unavailable"; }
function _getipv6() { curl -6 simpip.com --max-time 2 --proto-default https --silent 2>/dev/null || echo "unavailable"; }

####################################################################################
#################################### macOS #########################################
####################################################################################

# Execute setup depending on the system
if [[ `uname` == "Darwin" ]]; then

    ##############################
    ###### General
    ##############################

    # open finder at current location
    alias finder="open -a Finder ./"

    # Show/hide hidden files in Finder
    alias findershow="defaults write com.apple.finder AppleShowAllFiles -bool true && killall Finder"
    alias finderhide="defaults write com.apple.finder AppleShowAllFiles -bool false && killall Finder"

    alias py="python3"
    alias python='py'
    alias ll="ls -lha"
    alias pip='pip3'

    ##############################
    ###### Networking
    ##############################

    # flush dns cache
    alias dnsflush="sudo killall -HUP mDNSResponder; sudo killall mDNSResponderHelper; sudo dscacheutil -flushcache"

    # alias traceroute to trip (only if trip is installed)
    if command -v trip >/dev/null; then
        alias traceroute='trip -u'
    fi

    # IP lookup functions (lazy-evaluated)
    function ipv4() { echo "IPv4: $(_getipv4)"; }
    function ipv6() { echo "IPv6: $(_getipv6)"; }
    function iploc() { echo "Local IP: $(ipconfig getifaddr en0 2>/dev/null || echo 'unavailable')"; }
    function interfaces() { echo "Active Interfaces: $(ifconfig | pcregrep -M -o '^[^\t:]+(?=:([^\n]|\n\t)*status: active)' | tr '\n' ' ')"; }
    function ip() { ipv4; ipv6; iploc; }
    function ips() { ip; echo; ifconfig -a | grep -o 'inet6\? \(addr:\)\?\s\?\(\(\([0-9]\+\.\)\{3\}[0-9]\+\)\|[a-fA-F0-9:]\+\)' | awk '{ sub(/inet6? (addr:)? ?/, ""); print }' | highlight --syntax=txt; }

    ##############################
    ###### Hardware
    ##############################

    # device information

    alias gpu="system_profiler SPDisplaysDataType"
    alias cpu="sysctl -n machdep.cpu.brand_string"

    ##############################
    ###### Web Browsing
    ##############################

    alias firefox="/Applications/Firefox.app/Contents/MacOS/firefox-bin"
    alias ff="firefox"



####################################################################################
#################################### Linux #########################################
####################################################################################

else 
    ##############################
    ###### Docker
    ##############################

    # docker helpers
    alias dc="docker-compose"
    alias dcu="docker-compose up -d"
    alias dcd="docker-compose down"
    alias dcr="docker-compose down && docker-compose up -d"
    alias dcl="docker-compose logs -f"
    alias dcupdate="docker-compose up -d --force-recreate --build"


    ##############################
    ###### Networking
    ##############################

    # alias traceroute to trip (only if trip is installed)
    if command -v trip >/dev/null; then
        alias traceroute='trip'
    fi

    # IP lookup functions (lazy-evaluated)
    function ipv4() { echo "IPv4: $(_getipv4)"; }
    function ipv6() { echo "IPv6: $(_getipv6)"; }
    function ip() { ipv4; ipv6; }
    function ips() { ip; }

    ##############################
    ###### Keys
    ##############################

    # copy primary public key to clipboard
    alias pubkey="more ~/.ssh/id_rsa.pub"


    ##############################
    ###### Hardware
    ##############################

    # device information

    alias gpu="sudo lshw -C display"
    alias cpu="cat /proc/cpuinfo"
fi