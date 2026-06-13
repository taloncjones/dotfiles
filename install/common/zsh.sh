#!/usr/bin/env bash
# zsh.sh - Configure Homebrew ZSH as default shell
#
# Adds Homebrew ZSH to /etc/shells if not present, then sets it as the login shell.
# Platform-specific paths:
#   Linux:       /home/linuxbrew/.linuxbrew/bin/zsh
#   macOS (arm): /opt/homebrew/bin/zsh
#   macOS (x86): /usr/local/bin/zsh

ZSHBREWSHELL=""

if [ "$(uname)" == "Darwin" ]; then
    if [[ "$(uname -m)" == "arm64" ]]; then
        ZSHBREWSHELL="/opt/homebrew/bin/zsh"
    else
        ZSHBREWSHELL="/usr/local/bin/zsh"
    fi
else
    ZSHBREWSHELL="/home/linuxbrew/.linuxbrew/bin/zsh"
fi

# Check if ZSH (installed by Homebrew) is currently in /etc/shells
if [[ "$(cat /etc/shells)" != *"$ZSHBREWSHELL"* ]]; then
    echo "Homebrew ZSH is not currently present in /etc/shells, adding it now..."
    echo "$ZSHBREWSHELL" | sudo tee -a /etc/shells
fi

# $SHELL is already the absolute path; no need to re-resolve via `which`
CURRENTSHELL="${SHELL:-}"

# Finally, we change our shell if it is not ZSH
if [ "$CURRENTSHELL" != "$ZSHBREWSHELL" ]; then
    chsh -s "$ZSHBREWSHELL"
fi