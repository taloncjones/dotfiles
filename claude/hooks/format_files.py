#!/usr/bin/env python3
"""Hook to auto-format files after edits using prettier."""

import json
import subprocess
import sys


def main():
    try:
        data = json.load(sys.stdin)
        file_path = data.get("tool_input", {}).get("file_path", "")
        if not file_path:
            sys.exit(0)

        result = subprocess.run(
            ["prettier", "--write", "--ignore-unknown", file_path],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode == 0 and result.stdout.strip():
            print(f"Formatted: {file_path}")

    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
