#!/bin/sh
set -eu
test_file="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/test_workflow_context.py"
if command -v uv >/dev/null 2>&1; then
    exec uv run --no-project --python '>=3.11' --offline --no-cache python "$test_file"
fi
exec python3 "$test_file"
