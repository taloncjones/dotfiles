#!/usr/bin/env python3
"""List ignored files that exist only in a linked git worktree. Read-only.

Exit 0: nothing at risk, stdout empty.
Exit 1: at-risk paths on stdout (sorted, one per line), summary on stderr.
Exit 2: not a linked worktree, or incomplete evidence or any unexpected error; stdout empty.
Submodules are checked recursively; one that cannot be checked gives exit 2.
"""
import filecmp
import os
import stat
import subprocess
import sys

CACHE_DIRS = {
    "node_modules", "__pycache__", ".ruff_cache",
    ".pytest_cache", ".mypy_cache", ".venv", ".tox",
}


class Incomplete(Exception):
    pass


def git(cwd, *args, work_tree=None):
    # --work-tree overrides a submodule's core.worktree, which can name another checkout.
    prefix = ["--work-tree", work_tree] if work_tree else []
    proc = subprocess.run(
        ["git", "-C", cwd, *prefix, *args], capture_output=True, check=False
    )
    if proc.returncode != 0 or proc.stderr:
        detail = proc.stderr.decode(errors="replace").strip().splitlines()
        raise Incomplete("git %s failed: %s" % (args[0], detail[0] if detail else proc.returncode))
    return proc.stdout


def under(path, root):
    return path == root or path.startswith(root + os.sep)


def is_regenerable(root, rel):
    parts = rel.rstrip("/").split("/")
    if parts[0] == "docs":
        return False
    if parts[0] in CACHE_DIRS:
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


def gitlinks(root):
    """Relative paths of submodule gitlinks (mode 160000) in the index."""
    raw = git(root, "ls-files", "-s", "-z", work_tree=root).decode(errors="surrogateescape")
    links = []
    for entry in raw.split("\0"):
        meta, _, path = entry.partition("\t")
        if meta.startswith("160000 "):
            links.append(path)
    return links


def ignored_files(root, prefix=""):
    """Ignored paths under root, recursing into initialized submodules."""
    raw = git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "-z", work_tree=root)
    # Filter on the path relative to the repository that owns it, so a submodule's
    # own root-level node_modules stays regenerable.
    found = [
        prefix + p
        for p in raw.decode(errors="surrogateescape").split("\0")
        if p and not is_regenerable(root, p)
    ]
    for link in gitlinks(root):
        sub = os.path.join(root, link)
        if os.path.exists(os.path.join(sub, ".git")):
            found += ignored_files(sub, prefix + link + "/")
        elif os.path.isdir(sub) and os.listdir(sub):
            raise Incomplete("submodule not initialized but has content: %s" % (prefix + link))
    return found


def check(worktree):
    """Return (at_risk, differing) path lists; differing is a subset of at_risk."""
    if not os.path.isdir(worktree):
        raise Incomplete("not a directory: %s" % worktree)
    root = git(worktree, "rev-parse", "--show-toplevel").decode(errors="surrogateescape").removesuffix("\n")
    listing = git(root, "worktree", "list", "--porcelain").decode(errors="surrogateescape")
    first = listing.splitlines()[0] if listing else ""
    if not first.startswith("worktree "):
        raise Incomplete("cannot find main checkout")
    main = first[len("worktree "):]
    root_real = os.path.realpath(root)
    if root_real == os.path.realpath(main):
        raise Incomplete("not a linked worktree: %s" % worktree)

    at_risk = []
    differing = []
    for rel in ignored_files(root):
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
        if os.path.lexists(os.path.join(main, rel)):
            differing.append(rel)
    return sorted(at_risk), sorted(differing)


def emit(text, stream):
    stream.buffer.write(text.encode("utf-8", "surrogateescape"))
    stream.flush()


def main():
    if len(sys.argv) != 2:
        print("usage: worktree_ignored_check.py <worktree>", file=sys.stderr)
        return 2
    try:
        at_risk, differing = check(sys.argv[1])
        if not at_risk:
            return 0
        emit("\n".join(at_risk) + "\n", sys.stdout)
        summary = "worktree_ignored_check: %d ignored path(s) exist only in, or differ from, the main checkout: %s\n" % (len(at_risk), sys.argv[1])
        if differing:
            summary += "worktree_ignored_check: differ from the main copy (still at risk): %s\n" % ", ".join(differing)
        emit(summary, sys.stderr)
        return 1
    except Incomplete as exc:
        print("worktree_ignored_check: %s" % exc, file=sys.stderr)
        return 2
    except Exception as exc:  # fail closed: exit 1 would read as "files at risk"
        print("worktree_ignored_check: unexpected %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
