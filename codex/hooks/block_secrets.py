#!/usr/bin/env python3
"""Codex hook: block file operations on sensitive paths."""

import json
import os
import sys

FILE_TOOL_NAMES = {
    "edit",
    "read",
    "write",
    "multiedit",
    "apply_patch",
}

SENSITIVE_PATTERNS = [
    ".env",
    ".pem",
    ".key",
    "id_rsa",
    "id_ed25519",
    ".p12",
    ".pfx",
]

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

SENSITIVE_SEGMENTS = {
    "credentials",
    "secrets",
}


def hook_input(data: dict) -> dict:
    value = data.get("tool_input") or data.get("toolInput") or {}
    return value if isinstance(value, dict) else {}


def file_path(tool_input: dict) -> str:
    for key in ("file_path", "filePath", "path"):
        value = tool_input.get(key)
        if isinstance(value, str):
            return value
    return ""


def is_sensitive_path(path: str) -> tuple[bool, str]:
    if not path:
        return False, ""

    path = os.path.normpath(path)
    basename = os.path.basename(path).lower()
    path_lower = path.lower()
    path_segments = {part.lower() for part in path.split(os.sep)}

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


def block(reason: str) -> None:
    print(json.dumps({"decision": "block", "reason": reason}))
    sys.exit(2)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        return

    tool_name = data.get("tool_name") or data.get("toolName") or ""
    if tool_name and tool_name.lower() not in FILE_TOOL_NAMES:
        return

    sensitive, reason = is_sensitive_path(file_path(hook_input(data)))
    if sensitive:
        block(f"{reason}. Use environment variables or a secret manager instead.")


if __name__ == "__main__":
    main()
