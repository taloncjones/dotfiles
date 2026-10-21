#!/usr/bin/env python3
"""Hook to auto-format edited files with prettier, only where the repo already formats with it."""

import json
import os
import subprocess
import sys


def prettier_owns(path):
    """Return the work-tree top level when the repo formats `path` with prettier, else None.

    Owned means a prettier config resolves for the path, or the committed
    version is already prettier-clean. Everything else is left alone.
    """
    real = os.path.realpath(path)
    r = subprocess.run(
        ["git", "-C", os.path.dirname(real), "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        timeout=5,
    )
    if r.returncode != 0:
        return None
    top = os.path.realpath(r.stdout.strip())
    rel = os.path.relpath(real, top)

    r = subprocess.run(
        ["prettier", "--find-config-path", real],
        capture_output=True,
        cwd=top,
        timeout=5,
    )
    if r.returncode == 0:
        return top

    blob = subprocess.run(
        ["git", "-C", top, "show", f"HEAD:{rel}"],
        capture_output=True,
        timeout=5,
    )
    if blob.returncode != 0:
        return None

    # Compare bytes: --check exits 0 for unknown file types.
    r = subprocess.run(
        ["prettier", "--stdin-filepath", real],
        input=blob.stdout,
        capture_output=True,
        cwd=top,
        timeout=10,
    )
    if r.returncode == 0 and r.stdout == blob.stdout:
        return top
    return None


def main():
    try:
        data = json.load(sys.stdin)
        file_path = data.get("tool_input", {}).get("file_path", "")
        if not file_path:
            sys.exit(0)

        top = prettier_owns(file_path)
        if top is None:
            sys.exit(0)

        result = subprocess.run(
            ["prettier", "--write", "--ignore-unknown", os.path.realpath(file_path)],
            capture_output=True,
            text=True,
            cwd=top,
            timeout=30,
        )

        if result.returncode == 0 and result.stdout.strip():
            print(f"Formatted: {file_path}")

    except Exception:
        pass

    sys.exit(0)


if __name__ == "__main__":
    main()
