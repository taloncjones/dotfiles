#!/bin/sh
set -eu
test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if command -v uv >/dev/null 2>&1; then
    exec uv run --no-project --python '>=3.11' --offline --no-cache python -m unittest discover -s "$test_dir" -p 'herdr_coordination*test.py'
fi
exec python3 -m unittest discover -s "$test_dir" -p 'herdr_coordination*test.py'
