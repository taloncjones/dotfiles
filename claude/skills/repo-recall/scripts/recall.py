#!/usr/bin/env python3
"""recall.py - per-repo full-text recall over prose artifacts.

Indexes docs/, .claude/handoffs/, .todos/, findings dirs and Claude Code
auto-memory into a SQLite FTS5 index stored under the active Claude config
dir, and answers ranked queries. See SKILL.md for the contract.
"""
import argparse
import fnmatch  # noqa: F401
import hashlib
import json  # noqa: F401
import os
import re
import sqlite3
import subprocess
import sys
import time  # noqa: F401
from collections import namedtuple  # noqa: F401
from pathlib import Path

RECALL_VERSION = "1"
SCHEMA_VERSION = "1"

EXIT_OK = 0
EXIT_NO_HITS = 1
EXIT_NO_SOURCES = 2
EXIT_NOT_GIT = 3
EXIT_QUERY = 4
EXIT_NO_FTS5 = 5
EXIT_CONFIG = 6
EXIT_LOCKED = 7
EXIT_EVAL = 8
EXIT_USAGE = 64

MAX_FILE_BYTES = 1 << 20
BUSY_TIMEOUT_MS = 5000
DEFAULT_LIMIT = 8
MAX_LIMIT = 100
SNIPPET_CHARS = 200

KIND_ORDER = ["memory", "extra", "findings", "handoffs", "todos", "docs"]
KIND_EXT = {
    "memory": {".md"},
    "extra": {".md", ".txt", ".jsonl"},
    "findings": {".md", ".txt", ".jsonl"},
    "handoffs": {".md"},
    "todos": {".md"},
    "docs": {".md"},
}
# (kind, directory relative to the top level, recursive). "" = top level itself.
IN_TREE_RULES = [
    ("findings", "docs/findings", True),
    ("findings", ".claude/findings", True),
    ("handoffs", ".claude/handoffs", False),
    ("todos", ".todos/pending", False),
    ("todos", ".todos/completed", False),
    ("docs", "docs", True),
    ("docs", "", False),
]
EXCLUDED_DIRS = {".git", ".worktrees", "node_modules"}
ALLOWED_HIDDEN_DIRS = {".todos", ".claude"}
SKIP_BASENAMES = {("todos", "TODO.md"), ("memory", "MEMORY.md")}
EVAL_NOTES = {"hit", "paraphrase", "synonym", "tokenization", "missing-source"}


class ConfigError(Exception):
    """Config dir unusable or index path resolves inside the repo (exit 6)."""


class LockedError(Exception):
    """Index locked past the busy timeout, or missing when required (exit 7)."""


class UsageError(Exception):
    """Bad command line (exit 64)."""


def warn(msg, quiet=False):
    if not quiet:
        print(f"recall: {msg}", file=sys.stderr)


def _fail(code, msg):
    print(f"recall: {msg}", file=sys.stderr)
    return code


def classify_sqlite_error(exc):
    """Exit code for a non-corruption SQLite failure: locks are 7, storage,
    permission and I/O problems are 6."""
    msg = str(exc).lower()
    if "locked" in msg or "busy" in msg:
        return EXIT_LOCKED
    return EXIT_CONFIG


# --- routing ---------------------------------------------------------------

def slug(path):
    """Claude Code's project slug: every non-alphanumeric BYTE becomes '-'."""
    raw = os.fsencode(str(path))
    return re.sub(rb"[^A-Za-z0-9]", b"-", raw).decode("ascii")


def repo_id(toplevel):
    digest = hashlib.sha256(os.fsencode(str(toplevel))).hexdigest()[:12]
    return f"{slug(toplevel)[:80]}-{digest}"


def _home(env):
    return Path(env.get("HOME", str(Path.home())))


def resolve_config_dir(anchor, env=None):
    """Same rule as _claude_config_dir() in zsh/functions.zsh.

    anchor: resolved directory to classify (the top level, or cwd for
    status --all)."""
    env = os.environ if env is None else env
    explicit = env.get("CLAUDE_CONFIG_DIR")
    if explicit:
        return Path(explicit).expanduser()
    home = _home(env)
    work_tree = Path(env.get("CLAUDE_WORK_TREE", str(home / "Git" / "work"))).expanduser()
    try:
        work_tree = work_tree.resolve()
    except OSError:
        pass
    anchor = Path(anchor)
    if anchor == work_tree or work_tree in anchor.parents:
        return Path(env.get("CLAUDE_WORK_CONFIG_DIR", str(home / ".claude-work"))).expanduser()
    return home / ".claude"


def git_paths(cwd):
    """(toplevel, canonical_root) resolved, or None outside a working tree."""
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel", "--git-common-dir"],
            cwd=str(cwd), capture_output=True, text=True, check=True,
        ).stdout.splitlines()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if len(out) < 2 or not out[0]:
        return None
    toplevel = Path(out[0]).resolve()
    common = Path(out[1])
    if not common.is_absolute():
        common = Path(cwd) / common
    common = common.resolve()
    canonical = toplevel if ".git/modules/" in f"{common}/" else common.parent
    return toplevel, canonical


def index_path(config_dir, toplevel, canonical):
    """Index file for this tree; refuses a location inside the repo."""
    path = Path(config_dir) / "recall" / repo_id(toplevel) / "index.db"
    try:
        probe = path.parent.resolve()
    except OSError:
        probe = path.parent
    for root in (toplevel, canonical):
        if probe == root or root in probe.parents:
            raise ConfigError(f"index path {path} resolves inside the repository")
    return path


def ensure_index_dir(path):
    """Create <config_dir>/recall/<repo-id>/ with every level 0700 and an
    empty 0600 index file, so neither mkdir defaults nor SQLite choose modes."""
    path = Path(path)
    repo_dir = path.parent
    try:
        for d in (repo_dir.parent.parent, repo_dir.parent, repo_dir):
            if not d.exists():
                d.mkdir(mode=0o700)
        if not path.exists():
            os.close(os.open(str(path), os.O_CREAT | os.O_WRONLY, 0o600))
    except OSError as exc:
        raise ConfigError(f"cannot create {repo_dir}: {exc}") from exc
    if not os.access(repo_dir, os.W_OK):
        raise ConfigError(f"config dir not writable: {repo_dir}")


def fts5_available():
    if os.environ.get("RECALL_FORCE_NO_FTS5"):
        return False
    try:
        sqlite3.connect(":memory:").execute("CREATE VIRTUAL TABLE t USING fts5(x)")
        return True
    except sqlite3.OperationalError:
        return False


class Context:
    """Everything a command needs about where it runs."""

    def __init__(self, cwd=None):
        cwd = Path(cwd or os.getcwd())
        paths = git_paths(cwd)
        if paths is None:
            raise SystemExit(_fail(EXIT_NOT_GIT, "not inside a git working tree"))
        self.toplevel, self.canonical = paths
        self.config_dir = resolve_config_dir(self.toplevel)
        self.index_file = index_path(self.config_dir, self.toplevel, self.canonical)


# --- CLI -------------------------------------------------------------------

class Parser(argparse.ArgumentParser):
    """argparse that reports usage errors on one line via UsageError (exit 64)
    while leaving --help on its normal exit-0 path."""

    def error(self, message):
        raise UsageError(message)


def build_parser():
    p = Parser(prog="recall.py")
    sub = p.add_subparsers(dest="cmd", required=True, parser_class=Parser)
    ix = sub.add_parser("index")
    ix.add_argument("--full", action="store_true")
    ix.add_argument("--quiet", action="store_true")
    se = sub.add_parser("search")
    se.add_argument("query", nargs="+")
    se.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    se.add_argument("--kind", action="append", default=[])
    se.add_argument("--json", action="store_true")
    se.add_argument("--no-refresh", action="store_true")
    se.add_argument("--raw", action="store_true")
    st = sub.add_parser("status")
    st.add_argument("--all", action="store_true")
    ev = sub.add_parser("eval")
    ev.add_argument("file", nargs="?")
    ev.add_argument("--k", type=int, default=5)
    ea = sub.add_parser("eval-add")
    ea.add_argument("q")
    ea.add_argument("--expect", action="append", required=True)
    ea.add_argument("--note", default="hit")
    return p


def normalise_argv(argv):
    """Accept `eval add ...` as the documented spelling of `eval-add`."""
    if len(argv) >= 2 and argv[0] == "eval" and argv[1] == "add":
        return ["eval-add"] + argv[2:]
    return list(argv)


def main(argv=None):
    argv = normalise_argv(sys.argv[1:] if argv is None else argv)
    if len(argv) == 2 and argv[0] in ("--slug", "--repo-id"):
        target = Path(argv[1])
        print(slug(target) if argv[0] == "--slug" else repo_id(target))
        return EXIT_OK
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except UsageError as exc:
        return _fail(EXIT_USAGE, f"usage: {exc}")
    if not fts5_available():
        return _fail(EXIT_NO_FTS5, "this python3's sqlite3 lacks FTS5; use a python3 whose "
                     "sqlite3 has FTS5 (e.g. Homebrew python) and retry")
    handler = COMMANDS[args.cmd]
    try:
        return handler(args)
    except UsageError as exc:
        return _fail(EXIT_USAGE, f"usage: {exc}")
    except ConfigError as exc:
        return _fail(EXIT_CONFIG, str(exc))
    except LockedError as exc:
        return _fail(EXIT_LOCKED, str(exc))
    except sqlite3.OperationalError as exc:
        return _fail(classify_sqlite_error(exc), f"sqlite: {exc}")


def cmd_status(args):
    if args.all:
        return status_all()
    ctx = Context()
    ensure_index_dir(ctx.index_file)
    print(f"config dir: {ctx.config_dir}")
    print(f"index: {ctx.index_file}")
    print(f"fts5: {'yes' if fts5_available() else 'no'}")
    return EXIT_OK


def status_all():
    return EXIT_OK


def cmd_not_implemented(args):
    Context()  # Check git first
    return _fail(EXIT_USAGE, f"{args.cmd}: not implemented")


COMMANDS = {
    "index": cmd_not_implemented,
    "search": cmd_not_implemented,
    "status": cmd_status,
    "eval": cmd_not_implemented,
    "eval-add": cmd_not_implemented,
}

if __name__ == "__main__":
    sys.exit(main())
