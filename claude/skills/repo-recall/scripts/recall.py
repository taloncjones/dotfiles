#!/usr/bin/env python3
"""recall.py - per-repo full-text recall over prose artifacts.

Indexes docs/, .claude/handoffs/, .todos/, findings dirs and Claude Code
auto-memory into a SQLite FTS5 index stored under the active Claude config
dir, and answers ranked queries. See SKILL.md for the contract.
"""
import argparse
import fnmatch
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
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
    # home may carry an unresolved symlink component (e.g. macOS
    # /var -> /private/var); resolve it too so the comparison matches the
    # already-resolved path built in collect_sources().
    try:
        home_resolved = home.resolve()
    except OSError:
        home_resolved = home
    try:
        return "~/" + str(path.relative_to(home_resolved))
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
    # root may carry unresolved symlink components (e.g. a config dir built
    # from an unresolved $HOME); resolve it too so the containment check
    # compares like with like instead of rejecting every file under it.
    root_resolved = Path(root).resolve()
    if resolved != root_resolved and root_resolved not in resolved.parents:
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


# --- index I/O -------------------------------------------------------------

RefreshStats = namedtuple("RefreshStats", "files added modified removed chunks")

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS files (
  path TEXT PRIMARY KEY, display TEXT NOT NULL, kind TEXT NOT NULL,
  mtime_ns INTEGER NOT NULL, size INTEGER NOT NULL, sha256 TEXT NOT NULL);
CREATE VIRTUAL TABLE IF NOT EXISTS chunks USING fts5(
  display UNINDEXED, kind UNINDEXED, line UNINDEXED, heading, body,
  tokenize = 'porter unicode61');
"""


def _busy_timeout():
    return int(os.environ.get("RECALL_BUSY_TIMEOUT_MS", BUSY_TIMEOUT_MS))


def _connect(path):
    conn = sqlite3.connect(str(path), timeout=_busy_timeout() / 1000)
    conn.execute(f"PRAGMA busy_timeout = {_busy_timeout()}")
    return conn


def _quarantine(path, quiet):
    backup = Path(str(path) + ".corrupt")
    if backup.exists():
        backup.unlink()
    Path(path).rename(backup)
    warn(f"index was corrupt; moved to {backup} and rebuilding", quiet)


def _create_schema(conn, ctx):
    conn.executescript(SCHEMA)
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('schema_version', ?)", (SCHEMA_VERSION,))
    conn.execute("INSERT OR REPLACE INTO meta VALUES ('toplevel', ?)", (str(ctx.toplevel),))
    conn.execute("INSERT OR IGNORE INTO meta VALUES ('last_index_ok', '0')")
    conn.commit()


def _meta(conn, key):
    row = conn.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
    return row[0] if row else None


def open_index(ctx, quiet=False):
    """Open this tree's index. The schema is written only for a fresh
    (empty) file or after a quarantine / schema rebuild, so opening an
    existing index takes no write lock and works while another process
    holds one. Quarantines on the documented corruption markers only."""
    ensure_index_dir(ctx.index_file)
    path = ctx.index_file
    fresh = path.stat().st_size == 0
    for attempt in range(2):
        try:
            conn = _connect(path)
            if not fresh:
                check = conn.execute("PRAGMA quick_check").fetchone()[0]
                if check != "ok":
                    raise sqlite3.DatabaseError("database disk image is malformed")
                has_meta = conn.execute(
                    "SELECT 1 FROM sqlite_master WHERE name='meta'").fetchone()
                if not has_meta or _meta(conn, "schema_version") != SCHEMA_VERSION:
                    conn.close()
                    path.unlink()
                    warn("index schema outdated; rebuilding", quiet)
                    ensure_index_dir(path)
                    conn = _connect(path)
                    fresh = True
            if fresh:
                _create_schema(conn, ctx)
            return conn
        except sqlite3.DatabaseError as exc:
            if attempt == 0 and is_corruption(exc):
                _quarantine(path, quiet)
                ensure_index_dir(path)
                fresh = True
                continue
            raise
    raise ConfigError(f"cannot open index at {path}")


def has_index(conn):
    return _meta(conn, "last_index_ok") == "1"


def _index_one(conn, src, text):
    conn.execute("DELETE FROM chunks WHERE display = ?", (src.display,))
    for c in chunk_file(src.path, text):
        conn.execute("INSERT INTO chunks (display, kind, line, heading, body) VALUES (?,?,?,?,?)",
                     (src.display, src.kind, c.line, c.heading, c.body))


def refresh(conn, ctx, full=False, quiet=False):
    sources = collect_sources(ctx.toplevel, ctx.canonical, ctx.config_dir, quiet=quiet)
    try:
        conn.execute("BEGIN IMMEDIATE")
    except sqlite3.OperationalError as exc:
        if "locked" in str(exc).lower():
            raise LockedError("index is locked by another process") from exc
        raise
    try:
        if full:
            conn.execute("DELETE FROM files")
            conn.execute("DELETE FROM chunks")
        known = {row[0]: row for row in conn.execute(
            "SELECT path, display, kind, mtime_ns, size, sha256 FROM files")}
        added = modified = removed = 0
        current = set()
        for src in sources:
            try:
                st = src.path.stat()
            except OSError as exc:
                warn(f"skipping {src.display}: {exc}", quiet)
                continue
            row = known.get(str(src.path))
            if row and row[3] == st.st_mtime_ns and row[4] == st.st_size and row[2] == src.kind:
                current.add(str(src.path))  # unchanged: stat only, no read
                continue
            try:
                data = src.path.read_bytes()
                text = data.decode("utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                warn(f"skipping {src.display}: {exc}", quiet)
                continue
            current.add(str(src.path))
            digest = hashlib.sha256(data).hexdigest()
            if row and row[5] == digest and row[2] == src.kind:
                conn.execute("UPDATE files SET mtime_ns=?, size=? WHERE path=?",
                             (st.st_mtime_ns, st.st_size, str(src.path)))
                continue
            _index_one(conn, src, text)
            conn.execute("INSERT OR REPLACE INTO files VALUES (?,?,?,?,?,?)",
                         (str(src.path), src.display, src.kind, st.st_mtime_ns, st.st_size, digest))
            if row:
                modified += 1
            else:
                added += 1
        for path, row in known.items():
            if path not in current:
                conn.execute("DELETE FROM chunks WHERE display = ?", (row[1],))
                conn.execute("DELETE FROM files WHERE path = ?", (path,))
                removed += 1
        files = conn.execute("SELECT count(*) FROM files").fetchone()[0]
        chunks = conn.execute("SELECT count(*) FROM chunks").fetchone()[0]
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        conn.execute("INSERT OR REPLACE INTO meta VALUES ('last_index_at', ?)", (now,))
        conn.execute("INSERT OR REPLACE INTO meta VALUES ('last_index_ok', '1')")
        conn.commit()
    except BaseException:
        conn.rollback()
        raise
    return RefreshStats(files, added, modified, removed, chunks)


def format_stats(s):
    return f"indexed {s.files} files (+{s.added} ~{s.modified} -{s.removed}), {s.chunks} chunks"


def cmd_index(args):
    ctx = Context()
    conn = open_index(ctx, args.quiet)
    stats = refresh(conn, ctx, full=args.full, quiet=args.quiet)
    print(format_stats(stats))
    return EXIT_OK


# --- search ----------------------------------------------------------------

Hit = namedtuple("Hit", "rank score path line kind heading snippet")
SEARCH_SQL = """
SELECT display, kind, line, heading,
       snippet(chunks, -1, '>>', '<<', '...', 24) AS snip,
       bm25(chunks, 0, 0, 0, 3.0, 1.0) AS score
FROM chunks WHERE chunks MATCH ? {kind_filter}
ORDER BY score, display, line LIMIT ?
"""


def run_search(conn, query, kinds, limit):
    kind_filter = ""
    params = [query]
    if kinds:
        kind_filter = "AND kind IN ({})".format(",".join("?" * len(kinds)))
        params += kinds
    params.append(limit)
    rows = conn.execute(SEARCH_SQL.format(kind_filter=kind_filter), params).fetchall()
    hits = []
    for rank, (display, kind, line, heading, snip, score) in enumerate(rows, 1):
        snippet = " ".join(snip.split())[:SNIPPET_CHARS]
        hits.append(Hit(rank, round(-score, 3), display, int(line), kind, heading, snippet))
    return hits


def print_hits_text(hits):
    for h in hits:
        print(f"{h.rank}. {h.path}:{h.line}  [{h.kind}]  {h.heading}")
        print(f"   {h.snippet}")


def print_hits_json(hits):
    for h in hits:
        print(json.dumps(h._asdict(), ensure_ascii=False))


def refresh_or_degrade(conn, ctx, quiet):
    """Refresh; on lock, keep the prior index. Returns True when refreshed."""
    try:
        warn(format_stats(refresh(conn, ctx, quiet=quiet)), quiet)
        return True
    except LockedError:
        if not has_index(conn):
            raise
        warn("index is locked; answering from the previous index", quiet)
        return False


STORAGE_MARKERS = ("locked", "busy", "readonly", "disk i/o", "unable to open")


def _storage_error(exc):
    msg = str(exc).lower()
    return any(m in msg for m in STORAGE_MARKERS)


NO_SOURCES_MESSAGE = (
    "no eligible sources in this repo; looked for docs/**/*.md, *.md, "
    ".claude/handoffs/*.md, .todos/{pending,completed}/*.md, docs/findings/, "
    ".claude/findings/, and Claude memory for this path")


def cmd_search(args):
    # Default mode splits on whitespace so `search "foo bar"` means foo AND bar;
    # --raw keeps the joined input verbatim for FTS5 syntax.
    terms = args.query if args.raw else " ".join(args.query).split()
    if not " ".join(terms).strip():
        return _fail(EXIT_USAGE, "query must not be blank")
    if not 1 <= args.limit <= MAX_LIMIT:
        return _fail(EXIT_USAGE, f"--limit must be between 1 and {MAX_LIMIT}")
    for k in args.kind:
        if k not in KIND_ORDER:
            return _fail(EXIT_USAGE, f"unknown --kind {k!r}; choose from {', '.join(KIND_ORDER)}")
    ctx = Context()
    conn = open_index(ctx)
    if args.no_refresh:
        if not has_index(conn):
            raise LockedError("no index yet; run without --no-refresh or run `index` first")
    else:
        refresh_or_degrade(conn, ctx, quiet=False)
    if conn.execute("SELECT count(*) FROM files").fetchone()[0] == 0:
        return _fail(EXIT_NO_SOURCES, NO_SOURCES_MESSAGE)
    query = build_query(terms, args.raw)
    try:
        hits = run_search(conn, query, args.kind, args.limit)
    except sqlite3.OperationalError as exc:
        # In raw mode any non-storage error is the user's query (unterminated
        # string, unknown special query, no such column, fts5 syntax error).
        if args.raw and not _storage_error(exc):
            return _fail(EXIT_QUERY, f"query error: {exc}")
        return _fail(classify_sqlite_error(exc), f"sqlite: {exc}")
    if not hits:
        return EXIT_NO_HITS
    (print_hits_json if args.json else print_hits_text)(hits)
    return EXIT_OK


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


# --- status ----------------------------------------------------------------

def cmd_status(args):
    if args.all:
        return status_all()
    ctx = Context()
    conn = open_index(ctx)
    if not has_index(conn):
        # Never indexed, or just rebuilt after a schema mismatch / quarantine:
        # complete the rebuild so the counts below describe the tree, not an
        # empty schema.
        refresh_or_degrade(conn, ctx, quiet=False)
    print(f"config dir: {ctx.config_dir}")
    print(f"index: {ctx.index_file}")
    print(f"schema: {_meta(conn, 'schema_version')}")
    print(f"version: {RECALL_VERSION}")
    print(f"fts5: {'yes' if fts5_available() else 'no'}")
    print(f"last index: {_meta(conn, 'last_index_at') or 'never'}")
    counts = {k: [0, 0] for k in KIND_ORDER}
    for kind, n in conn.execute("SELECT kind, count(*) FROM files GROUP BY kind"):
        counts[kind][0] = n
    for kind, n in conn.execute("SELECT kind, count(*) FROM chunks GROUP BY kind"):
        counts[kind][1] = n
    for kind in KIND_ORDER:
        print(f"{kind}: {counts[kind][0]} files, {counts[kind][1]} chunks")
    return EXIT_OK


def status_all():
    config_dir = resolve_config_dir(Path(os.getcwd()).resolve())
    root = config_dir / "recall"
    print(f"config dir: {config_dir}")
    if not root.is_dir():
        print("no indexes")
        return EXIT_OK
    for db in sorted(root.glob("*/index.db")):
        try:
            conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            if conn.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise sqlite3.DatabaseError("database disk image is malformed")
            top = _meta(conn, "toplevel") or "?"
            last = _meta(conn, "last_index_at") or "never"
            conn.close()
        except sqlite3.DatabaseError:
            print(f"{db.parent.name}: corrupt")
            continue
        state = "present" if Path(top).is_dir() else "missing"
        print(f"{db.parent.name}: {top} ({state}, last index {last})")
    return EXIT_OK


# --- eval ------------------------------------------------------------------

def _golden_path(ctx, override):
    return Path(override) if override else ctx.toplevel / "docs" / "recall-eval.jsonl"


def _normalise_heading(text):
    return " ".join(text.split()).lower()


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def load_golden(path):
    """Parse the golden file; returns (entries, errors). Any error => exit 8."""
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        return [], [f"cannot read {path}: {exc}"]
    return load_golden_lines(lines)


def load_golden_lines(lines):
    """Validate golden lines. Only structurally valid entries are returned,
    so later phases never see bad shapes."""
    entries, errors, seen = [], [], set()
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError as exc:
            errors.append(f"line {number}: not JSON ({exc.msg})")
            continue
        if not isinstance(obj, dict):
            errors.append(f"line {number}: not a JSON object")
            continue
        q = obj.get("q")
        expect = obj.get("expect")
        note = obj.get("note", "hit")
        added = obj.get("added")
        line_errors = []
        if not isinstance(q, str) or not q.strip():
            line_errors.append("q must be a non-empty string")
        elif q in seen:
            line_errors.append(f"duplicate q {q!r}")
        else:
            seen.add(q)
        if not isinstance(expect, list) or not expect or not all(isinstance(e, str) for e in expect):
            line_errors.append("expect must be a non-empty list of paths")
        if note not in EVAL_NOTES:
            line_errors.append(f"note must be one of {sorted(EVAL_NOTES)}")
        if not isinstance(added, str) or not DATE_RE.match(added):
            line_errors.append("added must be a YYYY-MM-DD date")
        if line_errors:
            errors += [f"line {number}: {e}" for e in line_errors]
            continue
        entries.append(dict(obj, note=note, line=number))
    return entries, errors


def _indexed_displays(conn):
    return {row[0] for row in conn.execute("SELECT display FROM files")}


def _check_expected_paths(entries, indexed):
    errors = []
    for e in entries:
        if e["note"] == "missing-source":
            continue
        for exp in e["expect"]:
            if exp.split("#", 1)[0] not in indexed:
                errors.append(f"line {e['line']}: expected path not indexed: {exp}")
    return errors


def _report_errors(errors):
    for err in errors:
        print(f"recall: eval: {err}", file=sys.stderr)
    return EXIT_EVAL


def heading_matches(expected, hit):
    path, _, heading = expected.partition("#")
    if path != hit.path:
        return False
    return not heading or _normalise_heading(heading) == _normalise_heading(hit.heading)


def cmd_eval(args):
    if args.k < 1:
        return _fail(EXIT_USAGE, "--k must be >= 1")
    ctx = Context()
    golden = _golden_path(ctx, args.file)
    conn = open_index(ctx)
    refresh_or_degrade(conn, ctx, quiet=False)
    entries, errors = load_golden(golden)
    errors += _check_expected_paths(entries, _indexed_displays(conn))
    if errors:
        return _report_errors(errors)
    if not entries:
        return _fail(EXIT_EVAL, f"no queries in {golden}")
    print(f"recall eval version {RECALL_VERSION} k={args.k} n={len(entries)} "
          f"index={_meta(conn, 'last_index_at')}")
    hits_at_k, rr_sum, misses = 0, 0.0, {}
    for e in entries:
        if e["note"] == "missing-source":
            rank = None  # spec: a missing-source entry counts as a miss until its note changes
        else:
            results = run_search(conn, build_query(e["q"].split(), raw=False), [], args.k)
            rank = next((h.rank for h in results if any(heading_matches(x, h) for x in e["expect"])), None)
        if rank:
            hits_at_k += 1
            rr_sum += 1.0 / rank
            print(f"hit  @{rank}  {e['q']}")
        else:
            misses.setdefault(e["note"], []).append(e["q"])
            print(f"miss      {e['q']}")
    n = len(entries)
    print(f"recall@{args.k} {hits_at_k / n:.2f}")
    print(f"MRR {rr_sum / n:.2f}")
    for note in sorted(misses):
        print(f"misses [{note}]:")
        for q in misses[note]:
            print(f"  {q}")
    return EXIT_OK


def cmd_eval_add(args):
    if args.note not in EVAL_NOTES:
        return _fail(EXIT_USAGE, f"--note must be one of {sorted(EVAL_NOTES)}")
    if not args.q.strip():
        return _fail(EXIT_USAGE, "query must not be blank")
    ctx = Context()
    golden = _golden_path(ctx, None)
    conn = open_index(ctx)
    refresh_or_degrade(conn, ctx, quiet=False)
    entries, errors = load_golden(golden) if golden.exists() else ([], [])
    if errors:
        return _report_errors(errors)
    if any(e["q"] == args.q for e in entries):
        return _fail(EXIT_EVAL, f"duplicate query already recorded: {args.q!r}")
    entry = {"q": args.q, "expect": args.expect, "note": args.note,
             "added": time.strftime("%Y-%m-%d")}
    errors = _check_expected_paths([dict(entry, line=len(entries) + 1)], _indexed_displays(conn))
    if errors:
        return _report_errors(errors)
    # Same validator as eval, so a line eval add writes is always a line eval accepts.
    _, shape_errors = load_golden_lines([json.dumps(entry)])
    if shape_errors:
        return _report_errors(shape_errors)
    golden.parent.mkdir(parents=True, exist_ok=True)
    line = (json.dumps(entry, ensure_ascii=False) + "\n").encode("utf-8")
    fd = os.open(golden, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)
    print(f"recorded: {golden}")
    return EXIT_OK


COMMANDS = {
    "index": cmd_index,
    "search": cmd_search,
    "status": cmd_status,
    "eval": cmd_eval,
    "eval-add": cmd_eval_add,
}

if __name__ == "__main__":
    sys.exit(main())
