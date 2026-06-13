#!/usr/bin/env bash
# link.sh - Create symlinks for dotfiles (Linux)
#
# Links shell configs, git settings, SSH configs, and Claude Code config
# to their expected locations. Safe to re-run (uses ln -sf to overwrite existing links).

set -e

# Resolve DOTFILEDIR
SCRIPT_DIR="$( cd -P "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "$SCRIPT_DIR/../common/resolve_dotfiledir.sh"

# Run common symlinks (ZSH, git, SSH, Claude)
source "$DOTFILEDIR/install/common/link.sh"

# Linux-specific symlinks can be added below
