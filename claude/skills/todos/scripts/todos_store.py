#!/usr/bin/env python3
"""Helpers for todos.sh when .todos lives in its own git repository.

  todos_store.py lock <lock-file> <wait-seconds> -- <command...>
  todos_store.py commit-each <repo> <todos-dir>
  todos_store.py import <source-dir> <todos-dir> [--commit-repo <repo>]

lock exits 75 while the lock stays busy; the kernel drops the flock if this
process dies, and the lock descriptor is not inherited by the command.
"""

import fcntl
import os
import subprocess
import sys
import time

BUSY = 75


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def lock(argv):
    if len(argv) < 4 or argv[2] != "--":
        print("usage: todos_store.py lock <lock-file> <wait-seconds> -- <command...>", file=sys.stderr)
        return 2
    path, wait, command = argv[0], float(argv[1]), argv[3:]
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    deadline = time.monotonic() + wait
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                return BUSY
            time.sleep(0.1)
    code = subprocess.call(command)
    return 128 - code if code < 0 else code


def commit_paths(repo, paths, message, when):
    """Commit exactly `paths`; `when` is an epoch author date or None (now).

    A refused commit is unstaged again so it cannot block later commits.
    """
    if git(repo, "add", "-A", "--", *paths).returncode != 0:
        return False
    if git(repo, "diff", "--cached", "--quiet", "--", *paths).returncode == 0:
        return True
    args = ["commit", "--quiet", "-m", message]
    if when is not None:
        args.append(f"--date=@{when}")
    if git(repo, *args, "--", *paths).returncode != 0:
        git(repo, "reset", "-q", "--", *paths)
        return False
    return True


def changed_paths(repo, todos_dir):
    """Repo-relative paths with uncommitted changes under todos_dir."""
    out = git(repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--", todos_dir)
    if out.returncode != 0:
        return None
    entries = out.stdout.split("\0")
    paths, i = [], 0
    while i < len(entries):
        entry = entries[i]
        i += 1
        if not entry:
            continue
        if "R" in entry[:2] or "C" in entry[:2]:
            i += 1  # -z puts the rename source in the next field
        paths.append(entry[3:])
    return paths


def commit_each(argv):
    if len(argv) != 2:
        print("usage: todos_store.py commit-each <repo> <todos-dir>", file=sys.stderr)
        return 2
    repo, todos_dir = argv
    top = git(repo, "rev-parse", "--show-toplevel").stdout.strip()
    base = os.path.realpath(todos_dir)
    paths = changed_paths(repo, base)
    if paths is None:
        print("todos: sync skipped: cannot read store status", file=sys.stderr)
        return 1
    status = 0
    for rel_repo in paths:
        full = os.path.join(top, rel_repo)
        rel = os.path.relpath(full, base)
        when = int(os.stat(full).st_mtime) if os.path.lexists(full) else None
        if not commit_paths(repo, [full], f"todos: sync {rel}", when):
            print(f"todos: sync skipped: commit refused for {rel}; edit it and rerun", file=sys.stderr)
            status = 1
    return status


COMMANDS = {"lock": lock, "commit-each": commit_each}


def main(argv):
    if not argv or argv[0] not in COMMANDS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return COMMANDS[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
