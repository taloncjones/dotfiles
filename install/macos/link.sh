#!/usr/bin/env bash
# link.sh - Create symlinks for dotfiles (macOS)
#
# Links shell configs, git settings, SSH configs, VSCode settings, and Claude Code config
# to their expected locations. Safe to re-run (uses ln -sf to overwrite existing links).

set -e

# Resolve DOTFILEDIR
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$SCRIPT_DIR/../common/resolve_dotfiledir.sh"

# Run common symlinks (ZSH, git, SSH, Claude)
source "$DOTFILEDIR/install/common/link.sh"

# macOS-specific symlinks

# VSCode settings (macOS path)
echo "Setting up symbolic links for VSCode..."
mkdir -p "$HOME/Library/Application Support/Code/User/"
ln -sf "$DOTFILEDIR"/vscode/settings.json "$HOME/Library/Application Support/Code/User/settings.json"
ln -sf "$DOTFILEDIR"/vscode/keybindings.json "$HOME/Library/Application Support/Code/User/keybindings.json"
ln -sf "$DOTFILEDIR"/vscode/welcomePage.js "$HOME/Library/Application Support/Code/User/welcomePage.js"

# 1Password SSH agent config is seeded machine-local by common/link.sh
# (seed_machine_local_file). Do NOT symlink it here: edits to the live file
# would write real vault/item names through the link into the tracked repo.
