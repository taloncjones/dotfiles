#!/usr/bin/env python3
"""List ignored files that exist only in a linked git worktree. Read-only.

Exit 0: nothing at risk, stdout empty.
Exit 1: at-risk paths on stdout (sorted, one per line), summary on stderr.
Exit 2: not a linked worktree, or incomplete evidence; stdout empty.
"""
import filecmp
import os
import stat
import subprocess
import sys

CACHE_DIRS = {
    "node_modules", "__pycache__", ".superpowers", ".ruff_cache",
    ".pytest_cache", ".mypy_cache", ".venv", ".tox",
}


class Incomplete(Exception):
    pass


def git(cwd, *args):
    proc = subprocess.run(
        ["git", "-C", cwd, *args], capture_output=True, check=False
    )
    if proc.returncode != 0 or proc.stderr:
        detail = proc.stderr.decode(errors="replace").strip().splitlines()
        raise Incomplete("git %s failed: %s" % (args[0], detail[0] if detail else proc.returncode))
    return proc.stdout


def under(path, root):
    return path == root or path.startswith(root + os.sep)


def is_regenerable(root, rel):
    parts = rel.rstrip("/").split("/")
    if any(p in CACHE_DIRS for p in parts):
        return True
    for i, p in enumerate(parts):
        if p == "target" and os.path.isfile(os.path.join(root, *parts[:i], "Cargo.toml")):
            return True
    if rel.startswith("claude/contracts/"):
        return True
    return False


def is_preserved(main, root_real, rel):
    """True when main holds an identical regular file that is not the worktree itself."""
    main_path = os.path.join(main, rel)
    try:
        if not stat.S_ISREG(os.lstat(main_path).st_mode):
            return False
        if under(os.path.realpath(main_path), root_real):
            return False
        return filecmp.cmp(os.path.join(root_real, rel), main_path, shallow=False)
    except (FileNotFoundError, NotADirectoryError):
        return False
    except OSError as exc:
        raise Incomplete("compare %s: %s" % (rel, exc))


def check(worktree):
    if not os.path.isdir(worktree):
        raise Incomplete("not a directory: %s" % worktree)
    root = git(worktree, "rev-parse", "--show-toplevel").decode().strip()
    listing = git(root, "worktree", "list", "--porcelain").decode()
    first = listing.splitlines()[0] if listing else ""
    if not first.startswith("worktree "):
        raise Incomplete("cannot find main checkout")
    main = first[len("worktree "):]
    root_real = os.path.realpath(root)
    if root_real == os.path.realpath(main):
        raise Incomplete("not a linked worktree: %s" % worktree)

    raw = git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z")
    at_risk = []
    for rel in raw.decode(errors="surrogateescape").split("\0"):
        if not rel or is_regenerable(root, rel):
            continue
        if rel.endswith("/"):
            at_risk.append(rel)
            continue
        try:
            mode = os.lstat(os.path.join(root, rel)).st_mode
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise Incomplete("lstat %s: %s" % (rel, exc))
        base = os.path.basename(rel)
        if stat.S_ISLNK(mode) or base == ".DS_Store" or base.endswith((".pyc", ".pyo")):
            continue
        if is_preserved(main, root_real, rel):
            continue
        at_risk.append(rel)
    return sorted(at_risk)


def main():
    if len(sys.argv) != 2:
        print("usage: worktree_ignored_check.py <worktree>", file=sys.stderr)
        return 2
    try:
        at_risk = check(sys.argv[1])
    except Incomplete as exc:
        print("worktree_ignored_check: %s" % exc, file=sys.stderr)
        return 2
    if not at_risk:
        return 0
    sys.stdout.write("\n".join(at_risk) + "\n")
    print("worktree_ignored_check: %d ignored path(s) exist only in %s" % (len(at_risk), sys.argv[1]), file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
