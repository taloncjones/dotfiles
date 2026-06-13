#!/usr/bin/env bash
# install.sh - Main installation orchestrator
#
# Detects platform (macOS/Linux) and runs appropriate installation steps:
# 1. Package installation (Homebrew on macOS, apt on Linux)
# 2. oh-my-zsh and plugins
# 3. Symlinks for dotfiles
# 4. Platform-specific preferences
#
# Can be run standalone or via bootstrap.sh

####################################################################################
#################################### Common ########################################
####################################################################################

# Exit on error, unset variable, or pipeline failure
set -euo pipefail

# Ask for sudo password upfront and keep it alive
echo "Some steps require administrator access. Enter your password once now."
sudo -v
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &

# Install ZSH plugins (shared between macOS and Linux)
# Clones zsh-autosuggestions and zsh-syntax-highlighting to oh-my-zsh custom plugins dir.
# Skips if already installed.
install_zsh_plugins() {
  echo "Installing ZSH plugins..."
  if [ ! -e ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
  fi
  if [ ! -e ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
  fi
}

# Resolve DOTFILEDIR (absolute path to dotfiles repo)
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$SCRIPT_DIR/common/resolve_dotfiledir.sh"

# Execute setup depending on the system
if [ "$(uname)" == "Darwin" ]; then

####################################################################################
#################################### macOS #########################################
####################################################################################

  ####### Step 1
  ####### Install Homebrew and packages first (creates app directories)

  # run macOS specific install steps
  source "$DOTFILEDIR"/install/macos/macos.sh

  ####### Step 2
  ####### Install oh-my-zsh and plugins

  echo "Installing oh-my-zsh"
  if [ ! -e ~/.oh-my-zsh ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) --unattended"
  fi
  install_zsh_plugins

  ####### Step 3
  ####### Setup symlinks (after apps create their directories)

  # Set up symbolic links for ZSH and Git pointing to this cloned repo
  source "$DOTFILEDIR"/install/macos/link.sh

  ####### Step 4
  ####### Apply macOS defaults

  source "$DOTFILEDIR"/install/macos/defaults.sh

else
  

####################################################################################
#################################### Linux #########################################
####################################################################################

  ####### Step 0
  ####### Install any dependencies to run the setup scripts

  # Install required packages via apt (not available in Homebrew)
  echo "Installing required apt packages..."

  REQUIRED_PKG="curl build-essential xclip xdg-utils"
  for package in $REQUIRED_PKG
  do
    PKG_OK=$(dpkg-query -W --showformat='${Status}\n' "$package" 2>/dev/null | grep "install ok installed" || true)
    echo "Checking for $package: $PKG_OK"
    if [ "" = "$PKG_OK" ]; then
      echo "$package not yet installed. installing $package"
      sudo apt install -y "$package" || { echo "Failed to install $package"; exit 1; }
    fi
  done

  ####### Step 1
  ####### Run Linux steps

  # run Linux specific install steps
  source "$DOTFILEDIR"/install/linux/linux.sh

  ####### Step 2
  ####### Install oh-my-zsh and plugins

  echo "Installing oh-my-zsh"
  if [ ! -e ~/.oh-my-zsh ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh) --unattended"
  fi
  install_zsh_plugins

  ####### Step 3
  ####### Setup links

  # Set up symbolic links for ZSH and Git pointing to this cloned repo
  source "$DOTFILEDIR"/install/linux/link.sh

fi


# Install Claude Code CLI via native installer
source "$DOTFILEDIR"/install/common/claude-code.sh

# Install Codex CLI via OpenAI's official installer
source "$DOTFILEDIR"/install/common/codex.sh

# Install/refresh ECC + Superpowers Claude Code plugins (into both config dirs).
# Also re-vendors ECC's language rules, which are installer-managed (untracked).
source "$DOTFILEDIR"/install/common/claude-plugins.sh

# Ensure we're using the correct ZSH shell
# We want to use the latest that is installed by Homebrew
source "$DOTFILEDIR"/install/common/zsh.sh

# install complete

if [ "${BREW_FAILED:-0}" -eq 1 ]; then
  echo """
$(tput setaf 1)Warning: Some Homebrew packages failed to install.$(tput setaf 7)
Run 'brew bundle' manually to retry, or check the output above for details.
"""
fi

echo """
$(tput setaf 2)Install complete!

$(tput setaf 7)You might need to log out and log back in to activate Homebrew ZSH.

To check which shell is running use: $ which zsh
To change which shell is running use: $ chsh -s $(which zsh)

If you want to update to the latest version of the dotfiles, run the following command:
    $ update

"""
