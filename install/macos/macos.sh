#!/usr/bin/env bash
# macos.sh - macOS package installation
#
# Installs Homebrew, packages from Brewfiles, VSCode extensions, and Xcode CLI tools.

set -e

# Install Rosetta 2 (needed for Docker Desktop and x86_64 binaries on Apple Silicon)
if [[ "$(uname -m)" == "arm64" ]] && ! /usr/bin/pgrep -q oahd; then
  echo "Installing Rosetta 2..."
  softwareupdate --install-rosetta --agree-to-license
fi

# install homebrew
echo "Installing homebrew..."
if test ! "$(which brew)"; then
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install.sh)"

  # Add Homebrew to PATH for this session
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# Update Homebrew recipes
echo "Updating homebrew..."
brew update

# Install all apps from the Brewfile
# Allow brew bundle to fail without aborting the rest of the install
echo "Installing all packages and applications from the Brewfile"
BREW_FAILED=0
brew bundle --file "$DOTFILEDIR"/install/common/Brewfile.rb || BREW_FAILED=1
brew bundle --file "$DOTFILEDIR"/install/macos/Brewfile.rb || BREW_FAILED=1
export BREW_FAILED

# Install vscode extensions
cat "$DOTFILEDIR"/vscode/extensions.txt | xargs -L 1 code --install-extension

if xcode-select -p 1>/dev/null; then
  echo "Xcode Command Line Tools already installed, skipping installation"
else
  echo "Installing Xcode Command Line Tools"
  # Install Xcode Command Line Tools
  sudo xcode-select --install
  # Accept Xcode license
  sudo xcodebuild -license accept
fi