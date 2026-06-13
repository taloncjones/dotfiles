#!/bin/zsh
# info.zsh - Context-aware system/repo info display
#
# Shows git repo info (onefetch) if inside a repo, otherwise system info (fastfetch).
function info() {    # info() will print git repository info if inside a repository, otherwise print system info. ex: $ info
    git check-ignore -q . 2>/dev/null; if [ "$?" -ne "1" ]; then
        fastfetch
    else
        onefetch
    fi;
}