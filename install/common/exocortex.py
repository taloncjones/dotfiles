#!/usr/bin/env python3
"""Exclusive filesystem steps and ADR extraction for exocortex.sh.

  exocortex.py rename <src> <dst>      os.rename; fails when <dst> exists
  exocortex.py link <target> <name>    os.symlink; fails when <name> exists
  exocortex.py decisions <markdown> <out-dir> <YYYY-MM-DD>
"""

import os
import re
import sys


def rename(argv):
    src, dst = argv
    if os.path.lexists(dst):
        return 1
    try:
        os.rename(src, dst)
    except OSError:
        return 1
    return 0


def link(argv):
    target, name = argv
    try:
        os.symlink(target, name)
    except OSError:
        return 1
    return 0


HEADING = re.compile(r"^### ADR-(\d{4}): (.+?)\s*$")


def adr_sections(text):
    """[(number, title, body lines)] for each `### ADR-NNNN: title` section.

    A body ends at the next line starting `## ` or `### `; `####` stays in it.
    """
    sections, current = [], None
    for line in text.splitlines():
        match = HEADING.match(line)
        if match:
            current = (match.group(1), match.group(2), [])
            sections.append(current)
        elif line.startswith("## ") or line.startswith("### "):
            current = None
        elif current is not None:
            current[2].append(line)
    return sections


def decisions(argv):
    source, out_dir, date = argv
    with open(source) as fh:
        sections = adr_sections(fh.read())
    if not sections:
        return 1
    os.makedirs(out_dir, exist_ok=True)
    for number, title, body in sections:
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        text = "\n".join(body).strip("\n")
        with open(os.path.join(out_dir, f"{number}-{slug}.md"), "w") as fh:
            fh.write(f"# ADR-{number}: {title}\n\nStatus: Accepted\nDate: {date}\n\n{text}\n")
    return 0


COMMANDS = {"rename": rename, "link": link, "decisions": decisions}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
