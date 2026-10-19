#!/bin/sh
# Runs the herdr-fleet mod's validate and test suites; skips without claude.
cd "$(dirname "$0")/../../.." || exit 2
PLUGIN=claude/plugins/herdr-fleet

python3 -I - <<'PY' || { echo "FAIL: label cases differ from herdr_orch_core._label_title" >&2; exit 1; }
import json, sys
sys.path.insert(0, "claude/hooks")
import herdr_orch_core as core
text = open("claude/plugins/herdr-fleet/hooks/label-cases.ts").read()
cases = json.loads(text.split("export const LABEL_CASES = ", 1)[1])
bad = [c for c in cases if core._label_title(c["task"]) != c["title"]]
if bad or not cases:
    sys.exit(f"mismatch: {bad}")
print(f"PASS: label cases match herdr_orch_core._label_title ({len(cases)})")
PY

if ! command -v claude >/dev/null 2>&1; then
    echo "[INFO] skip: claude not on PATH"
    exit 0
fi

claude plugin validate "$PLUGIN" || { echo "FAIL: plugin validate" >&2; exit 1; }
out=$(claude plugin test "$PLUGIN" 2>&1)
rc=$?
printf '%s\n' "$out"
[ "$rc" = 0 ] || { echo "FAIL: plugin test" >&2; exit 1; }
