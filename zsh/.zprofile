#!/bin/zsh

DIRECTORY=""

# MacOS 
if [[ $(uname) == "Darwin" ]]; then
    if [[ $(uname -m) == "arm64" ]]; then
        DIRECTORY="/opt/homebrew/bin/brew"
    else 
        DIRECTORY="/usr/local/bin/brew"
    fi
else
# Linux
    DIRECTORY="/home/linuxbrew/.linuxbrew/bin/brew"
fi

eval "$($DIRECTORY shellenv)"
# pipx-installed tools
export PATH="$PATH:$HOME/.local/bin"

# GitHub token (requires gh from Homebrew PATH above); skip quietly when gh
# is missing or not yet authenticated instead of erroring on every login.
if command -v gh >/dev/null 2>&1; then
    _gh_token="$(gh auth token 2>/dev/null)" && export GITHUB_PERSONAL_ACCESS_TOKEN="$_gh_token"
    unset _gh_token
fi
