#!/usr/bin/env python3
"""Deterministic stand-in for `codex exec`. Reads the prompt on stdin, applies
a fixed substitution table, writes the JSON answer to the -o path.

FAKE_CODEX_MODE: rewrite (default) | drop-link | fail | touch-protected | mangle-url
FAKE_CODEX_MARKER: file appended to on every invocation
"""
import json
import os
import sys

SUBS = [
    ("This PR introduces", "Adds", "verdict-first"),
    ("comprehensive and robust ", "", "filler"),
    ("In order to ", "To ", "filler"),
    ("## Notes\n", "", "empty-heading"),
]


def fix(text):
    changes = []
    for before, after, rule in SUBS:
        if before in text:
            text = text.replace(before, after)
            changes.append({"before": before.strip(), "after": after.strip(),
                            "rule": rule})
    return text, changes


def main():
    args = sys.argv[1:]
    out_path = args[args.index("-o") + 1]
    prompt = sys.stdin.read()
    marker = os.environ.get("FAKE_CODEX_MARKER")
    if marker:
        with open(marker, "a") as f:
            f.write("called\n")
    mode = os.environ.get("FAKE_CODEX_MODE", "rewrite")
    if mode == "fail":
        sys.stderr.write("fake codex: simulated failure\n")
        return 3
    if "=== LINES ===\n" in prompt:
        rows = prompt.split("=== LINES ===\n", 1)[1].splitlines()
        lines, changes = [], []
        for row in rows:
            if not row:
                continue
            n, status, text = row.split("|", 2)
            if status == "candidate":
                text, more = fix(text)
                changes.extend(more)
                if mode == "mangle-url":
                    text = text.replace("https://example.com/spec#anchor",
                                        "https://example.com/spec#anchor?evil=1")
            elif status == "protected" and mode == "touch-protected":
                text = text + " (edited)"
            lines.append({"n": int(n), "text": text})
        data = {"lines": lines, "changes": changes}
    else:
        text = prompt.split("=== TEXT ===\n", 1)[1]
        text, changes = fix(text)
        if mode == "drop-link":
            text = "\n".join(l for l in text.splitlines() if "/browse/" not in l) + "\n"
        data = {"rewritten": text, "changes": changes}
    with open(out_path, "w") as f:
        json.dump(data, f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
