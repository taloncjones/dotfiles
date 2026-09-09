"""Codex Stop adapter for the shared Herdr completion gate."""

import importlib.util
import json
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / "claude" / "hooks" / "herdr_stop_gate.py"
SPEC = importlib.util.spec_from_file_location("shared_herdr_stop_gate", SOURCE)
gate = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(gate)


def main():
    try:
        payload = json.load(sys.stdin)
    except (OSError, ValueError):
        print("{}")
        return 0
    result = gate.evaluate(payload, native=True)
    if result["action"] == "allow":
        print("{}")
        return 0
    if result["action"] == "release":
        print(
            json.dumps(
                {
                    "systemMessage": "herdr-stop-gate: released without a completion record"
                }
            )
        )
        return 0
    reason = result["reason"]
    if result["command"]:
        reason += "; Run: " + result["command"]
    print(json.dumps({"decision": "block", "reason": reason}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- a broken hook must not trap a worker
        print("{}")
        sys.exit(0)
