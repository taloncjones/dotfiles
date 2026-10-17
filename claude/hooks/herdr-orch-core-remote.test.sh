#!/bin/sh
set -eu
unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_ACCOUNT_ID HERDR_BOUNDED_CHILD
test_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if command -v uv >/dev/null 2>&1; then
    exec uv run --no-project --python '>=3.11' --offline --no-cache python -m unittest discover -s "$test_dir" -p 'herdr_orch_core_remote_test.py'
fi
exec python3 -m unittest discover -s "$test_dir" -p 'herdr_orch_core_remote_test.py'
