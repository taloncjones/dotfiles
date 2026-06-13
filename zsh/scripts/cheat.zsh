#!/bin/zsh
# cheat.zsh - Command cheat sheets from cheat.sh
#
# Fetches human-readable help pages from cheat.sh, styled for terminal display.
function cheat() {    # cheat() will query a web service and return a human-readable man page for that command. ex $ cheat ls
	if [ -z "${1}" ]; then
		echo "ERROR: No command specified. Printing help instead.";
        result=$(curl "cheat.sh" -s)
        echo $result
		return 1;
	fi;
    
    result=$(curl "cheat.sh/${1}?style=xcode" -s)
    echo $result
}