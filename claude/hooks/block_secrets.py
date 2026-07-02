#!/usr/bin/env python3
"""Hook to block access to sensitive files.

Blocks Read/Edit/Write operations on:
- .env files (.env, .env.local, .env.production, etc.)
- Credentials/secrets directories and files (exact segment or filename match)
- Private keys (*.pem, *.key, id_rsa, id_ed25519, *.p12, *.pfx)

Matching mirrors codex/hooks/block_secrets.py: exact filenames, exact path
segments, and basename patterns -- NOT substring-of-full-path, which blocked
innocent sources like secrets_manager/util.py and this hook's own file.

Runs as PreToolUse hook for Read, Edit, Write tools.
"""

import json
import os
import sys

# Patterns matched against the basename only
SENSITIVE_PATTERNS = [
    ".env",
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

# Whole path segments to block (exact directory/file name, not substring)
SENSITIVE_SEGMENTS = {
    "credentials",
    "secrets",
}


def is_sensitive_path(path: str) -> tuple[bool, str]:
    """Check if path refers to a sensitive file."""
    if not path:
        return False, ""

    path = os.path.normpath(path)
    basename = os.path.basename(path).lower()
    path_segments = {part.lower() for part in path.split(os.sep)}

    # Public keys are safe by definition
    if basename.endswith(".pub"):
        return False, ""

    if basename in SENSITIVE_FILES:
        return True, f"Blocked: '{basename}' contains secrets"

    for segment in SENSITIVE_SEGMENTS:
        if segment in path_segments:
            return True, f"Blocked: path contains sensitive segment '{segment}'"

    basename_no_ext = os.path.splitext(basename)[0]
    if basename_no_ext.endswith("_secret"):
        return True, "Blocked: filename appears to contain a secret"

    for pattern in SENSITIVE_PATTERNS:
        if pattern not in basename:
            continue
        if basename.endswith(".example") or basename.endswith(".template"):
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
