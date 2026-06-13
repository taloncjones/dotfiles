#!/usr/bin/env bash
# linux.sh - Linux package installation
#
# Installs Linuxbrew and packages from the common Brewfile.

set -e

# install homebrew (Linuxbrew)
echo "Installing Homebrew (Linuxbrew)..."
if test ! "$(which brew)"; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"

  # Add Homebrew to PATH for this session
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi

# Update Homebrew recipes
echo "Updating homebrew..."
brew update

# Install all apps from the Brewfile
# Allow brew bundle to fail without aborting the rest of the install
echo "Installing all packages from the Brewfile"
BREW_FAILED=0
brew bundle --file "$DOTFILEDIR"/install/common/Brewfile.rb || BREW_FAILED=1
export BREW_FAILED
