#!/bin/sh
set -eu
tests_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
scripts_dir="$(CDPATH= cd -- "$tests_dir/.." && pwd)"
cd "$scripts_dir"
if command -v uv >/dev/null 2>&1; then
    exec uv run --no-project --python '>=3.11' --offline --no-cache \
        python -m unittest discover -s tests -p 'test_*.py'
fi
exec python3 -m unittest discover -s tests -p 'test_*.py'
