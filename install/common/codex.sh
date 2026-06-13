#!/usr/bin/env bash
set -euo pipefail

# Install or update Codex CLI via OpenAI's official installer
# Idempotent -- safe to run on every bootstrap

if command -v codex &>/dev/null; then
    echo "Codex CLI already installed: $(codex --version)"
    echo "Run 'codex update' to update."
else
    echo "Installing Codex CLI..."
    curl -fsSL https://chatgpt.com/codex/install.sh | sh
fi
