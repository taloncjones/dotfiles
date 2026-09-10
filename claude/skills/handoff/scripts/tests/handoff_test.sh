#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if command -v uv >/dev/null 2>&1; then
  exec uv run --python '>=3.11' --no-project --offline --no-cache python "$SCRIPT_DIR/test_handoff.py"
fi
exec python3 "$SCRIPT_DIR/test_handoff.py"
