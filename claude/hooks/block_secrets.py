#!/usr/bin/env python3
"""Hook to block access to sensitive files.

Blocks Read/Edit/Write operations on:
- .env files (.env, .env.local, .env.production, etc.)
- Credentials files (credentials.*, *credentials*)
- Private keys (*.pem, *.key)
- Secrets files (secrets.*, *secrets*, *_secret*)

Runs as PreToolUse hook for Read, Edit, Write tools.
"""

import json
import os
import sys

# Patterns that indicate sensitive files
SENSITIVE_PATTERNS = [
    ".env",
    "credentials",
    "secrets",
    "_secret",
    ".pem",
    ".key",
    "id_rsa",
    "id_ed25519",
    ".p12",
    ".pfx",
]

# Exact filenames to block
SENSITIVE_FILES = {
    ".env",
    ".env.local",
    ".env.development",
    ".env.production",
    ".env.staging",
    ".env.test",
    "credentials.json",
    "secrets.json",
    "service-account.json",
}


def is_sensitive_path(path: str) -> tuple[bool, str]:
    """Check if path refers to a sensitive file."""
    if not path:
        return False, ""

    # Normalize path
    path = os.path.normpath(path)
    basename = os.path.basename(path).lower()
    path_lower = path.lower()

    # Check exact filename matches
    if basename in SENSITIVE_FILES:
        return True, f"Blocked: '{basename}' contains secrets"

    # Check pattern matches
    for pattern in SENSITIVE_PATTERNS:
        if pattern in basename or pattern in path_lower:
            # Allow reading .env.example files
            if basename.endswith(".example") or basename.endswith(".template"):
                return False, ""
            # Allow .pem in directory names like /etc/pki/tls/certs/
            if pattern in [".pem", ".key"] and pattern not in basename:
                return False, ""
            return True, f"Blocked: path matches sensitive pattern '{pattern}'"

    return False, ""


def main():
    try:
        data = json.load(sys.stdin)
        tool_input = data.get("tool_input", {})
        tool_name = data.get("tool_name", "")

        # Only check file operation tools
        if tool_name not in ("Read", "Edit", "Write"):
            sys.exit(0)

        file_path = tool_input.get("file_path", "")
        is_sensitive, reason = is_sensitive_path(file_path)

        if is_sensitive:
            print(reason, file=sys.stderr)
            print("Use environment variables or a secret manager instead.", file=sys.stderr)
            sys.exit(2)

        sys.exit(0)
    except Exception:
        # Don't block on errors
        sys.exit(0)


if __name__ == "__main__":
    main()
