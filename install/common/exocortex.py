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


COMMANDS = {"rename": rename, "link": link}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
