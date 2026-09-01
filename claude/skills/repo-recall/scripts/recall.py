#!/usr/bin/env python3
"""recall.py - per-repo full-text recall over prose artifacts.

Indexes docs/, .claude/handoffs/, .todos/, findings dirs and Claude Code
auto-memory into a SQLite FTS5 index stored under the active Claude config
dir, and answers ranked queries. See SKILL.md for the contract.
"""
import argparse
import fnmatch
import hashlib
import json  # noqa: F401
import os
import re
import sqlite3
import subprocess
import sys
import time  # noqa: F401
from collections import namedtuple
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


# --- sources ---------------------------------------------------------------

Source = namedtuple("Source", "path display kind")


def display_path(path, toplevel, home):
    path = Path(path)
    try:
        return str(path.relative_to(toplevel))
    except ValueError:
        pass
    try:
        return "~/" + str(path.relative_to(home))
    except ValueError:
        return str(path)


def memory_dirs(config_dir, toplevel, canonical):
    dirs = []
    for root in (toplevel, canonical):
        d = Path(config_dir) / "projects" / slug(root) / "memory"
        if d not in dirs:
            dirs.append(d)
    return dirs


def _has_symlink_component(path, root):
    cur = Path(root)
    for part in Path(path).relative_to(root).parts:
        cur = cur / part
        if cur.is_symlink():
            return True
    return False


def _excluded_dir(dir_parts):
    """True when any directory component is excluded: .git, worktree dirs,
    node_modules, or a dot-directory other than .todos / .claude."""
    for i, part in enumerate(dir_parts):
        if part in EXCLUDED_DIRS:
            return True
        if part.startswith(".") and part not in ALLOWED_HIDDEN_DIRS:
            return True
        if part == "worktrees" and i > 0 and dir_parts[i - 1] == ".claude":
            return True
    return False


def _tree_files(toplevel):
    """Relative POSIX paths of every regular file under toplevel. Symlinked
    and excluded directories are pruned before descent, so they are never
    walked (spec: symlinked directories are not descended)."""
    toplevel = Path(toplevel)
    out = []
    for dirpath, dirnames, filenames in os.walk(toplevel, followlinks=False):
        rel_dir = Path(dirpath).relative_to(toplevel)
        keep = []
        for d in sorted(dirnames):
            if (Path(dirpath) / d).is_symlink():
                continue
            if _excluded_dir(tuple(rel_dir.parts) + (d,)):
                continue
            keep.append(d)
        dirnames[:] = keep
        for f in filenames:
            out.append((rel_dir / f).as_posix() if rel_dir.parts else f)
    return sorted(out)


def _rule_matches(rel, base, recursive):
    parent = rel.rsplit("/", 1)[0] if "/" in rel else ""
    if base == "":
        return parent == ""
    if parent == base:
        return True
    return recursive and parent.startswith(base + "/")


def _glob_matches(rel, pattern):
    """fnmatch with `**` folded to `*` (fnmatch's `*` already crosses `/`),
    so `notes/**/*.txt` matches both notes/a.txt and notes/deep/b.txt."""
    return fnmatch.fnmatchcase(rel, pattern.replace("**/", "*").replace("**", "*"))


def eligible(path, root, kind):
    """Regular, non-symlinked, inside root, allowed extension, <= 1 MiB."""
    path = Path(path)
    if path.suffix.lower() not in KIND_EXT[kind]:
        return False
    if path.is_symlink() or not path.is_file():
        return False
    try:
        resolved = path.resolve()
        rel = path.relative_to(root)
    except (OSError, ValueError):
        return False
    if resolved != root and root not in resolved.parents:
        return False
    if _has_symlink_component(path, root) or _excluded_dir(rel.parts[:-1]):
        return False
    if (kind, path.name) in SKIP_BASENAMES:
        return False
    try:
        return path.stat().st_size <= MAX_FILE_BYTES
    except OSError:
        return False


def _extra_globs(env, quiet):
    raw = env.get("RECALL_EXTRA_GLOBS", "")
    out = []
    for pattern in filter(None, raw.split(":")):
        if Path(pattern).is_absolute() or ".." in Path(pattern).parts:
            warn(f"RECALL_EXTRA_GLOBS: rejected {pattern!r} (must stay inside the repo)", quiet)
            continue
        out.append(pattern)
    return out


def collect_sources(toplevel, canonical, config_dir, env=None, quiet=False):
    """Every eligible file, each once, tagged by first-matching kind
    (memory > extra > findings > handoffs > todos > docs)."""
    env = os.environ if env is None else env
    home = _home(env)
    toplevel = Path(toplevel)
    tree = _tree_files(toplevel)
    extra = _extra_globs(env, quiet)
    seen = {}

    def consider(path, root, kind):
        if not eligible(path, Path(root), kind):
            return
        key = path.resolve()
        if key not in seen:
            seen[key] = Source(key, display_path(key, toplevel, home), kind)

    for d in memory_dirs(config_dir, toplevel, canonical):
        for p in sorted(d.glob("*.md")):
            consider(p, d, "memory")
    for rel in tree:
        if any(_glob_matches(rel, g) for g in extra):
            consider(toplevel / rel, toplevel, "extra")
    for kind, base, recursive in IN_TREE_RULES:
        for rel in tree:
            if _rule_matches(rel, base, recursive):
                consider(toplevel / rel, toplevel, kind)
    return sorted(seen.values(), key=lambda s: (KIND_ORDER.index(s.kind), s.display))


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


# --- chunking ---------------------------------------------------------------

Chunk = namedtuple("Chunk", "heading line body")
HEADING_RE = re.compile(r"^(#{1,3})\s+(.*?)\s*#*\s*$")
FENCE_RE = re.compile(r"^\s*(`{3,}|~{3,})")


def _fence_state(line, opener):
    """Open-fence marker after this line (None = not inside a fence). A fence
    closes only on the same character with at least the opener's length."""
    m = FENCE_RE.match(line)
    if not m:
        return opener
    marker = m.group(1)
    if opener is None:
        return marker
    if marker[0] == opener[0] and len(marker) >= len(opener):
        return None
    return opener


def _first_h1(lines):
    opener = None
    for line in lines:
        if FENCE_RE.match(line):
            opener = _fence_state(line, opener)
            continue
        m = HEADING_RE.match(line)
        if m and opener is None and m.group(1) == "#":
            return m.group(2).strip()
    return None


def chunk_markdown(text, filename):
    lines = text.splitlines()
    heading = _first_h1(lines) or filename
    start, body, out, opener = 1, [], [], None
    for number, line in enumerate(lines, 1):
        if FENCE_RE.match(line):
            opener = _fence_state(line, opener)
            body.append(line)
            continue
        m = HEADING_RE.match(line)
        if m and opener is None:
            out.append(Chunk(heading, start, "\n".join(body)))
            heading, start, body = m.group(2).strip(), number, []
        else:
            body.append(line)
    out.append(Chunk(heading, start, "\n".join(body)))
    return [Chunk(c.heading, c.line, c.body.strip("\n")) for c in out if c.body.strip()]


def chunk_plain(text, filename):
    body = text.strip("\n")
    return [Chunk(filename, 1, body)] if body.strip() else []


def chunk_file(path, text):
    if Path(path).suffix.lower() == ".md":
        return chunk_markdown(text, Path(path).name)
    return chunk_plain(text, Path(path).name)


# --- query -----------------------------------------------------------------

def build_query(terms, raw):
    if raw:
        return " ".join(terms)
    return " AND ".join('"' + t.replace('"', '""') + '"' for t in terms)


CORRUPTION_MARKERS = ("file is not a database", "database disk image is malformed")


def is_corruption(exc):
    msg = str(exc).lower().strip()
    return isinstance(exc, sqlite3.DatabaseError) and msg.startswith(CORRUPTION_MARKERS)


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
