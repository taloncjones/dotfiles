#!/usr/bin/env python3
"""Hook to warn before editing global CLAUDE.md.

Warns (but doesn't block) when editing the global CLAUDE.md to prevent
accidental overwrites. Project CLAUDE.md files are fine to edit.
"""

import json
import os
import sys


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        file_path = tool_input.get("file_path", "")

        # Check if editing the global CLAUDE.md
        home = os.path.expanduser("~")
        global_claude_md = os.path.join(home, ".claude", "CLAUDE.md")

        # Resolve symlinks to compare actual paths
        try:
            resolved_path = os.path.realpath(file_path)
            resolved_global = os.path.realpath(global_claude_md)

            if resolved_path == resolved_global:
                print("Warning: Editing global CLAUDE.md (affects all projects).")
                print("This file is managed by dotfiles. Edit claude/CLAUDE.md in your dotfiles repo.")
                # Exit 0 to allow (just warn), exit 2 to block
                sys.exit(0)
        except Exception:
            pass

        sys.exit(0)
    except Exception:
        sys.exit(0)


if __name__ == "__main__":
    main()
