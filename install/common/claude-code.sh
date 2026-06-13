#!/usr/bin/env bash
set -euo pipefail

# Install or update Claude Code CLI via native installer
# Idempotent -- safe to run on every bootstrap

if command -v claude &>/dev/null; then
    echo "Claude Code already installed: $(claude --version)"
    echo "Run 'claude update' to update."
else
    echo "Installing Claude Code CLI..."
    curl -fsSL https://claude.ai/install.sh | bash
fi
