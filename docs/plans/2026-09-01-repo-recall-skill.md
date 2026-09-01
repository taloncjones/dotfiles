# Repo Recall Skill Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `claude/skills/repo-recall/`: one stdlib Python script giving any repo a ranked SQLite FTS5 search over docs, handoffs, todos, findings and Claude memory, with the index stored under the active Claude config dir.

**Architecture:** `recall.py` is a single-file CLI (`index`, `search`, `status`, `eval`, `eval add`) organised as pure functions (routing, source discovery, chunking, query building) plus thin SQLite I/O. Pure functions are unit-tested with `unittest`; CLI behaviour is tested by a shell suite against throwaway git repos with `HOME` and the Claude env vars pointed at temp dirs. The skill ships through the existing `claude/skills` whole-dir symlink; nothing else in the installer changes.

**Tech Stack:** Python 3.9+ stdlib (`sqlite3` with FTS5, `argparse`, `hashlib`, `os.walk`, `fnmatch`), bash test suite in the repo's PASS/FAIL style, `ruff`.

**Spec:** `docs/specs/2026-09-01-repo-recall-skill.md`

## Global Constraints

- Python >= 3.9, stdlib only, no `uv` project; `ruff check` clean.
- Runtime probe: FTS5 must be verified by creating an in-memory FTS5 table; `RECALL_FORCE_NO_FTS5=1` forces the failure path (test-only).
- No emojis anywhere; no AI attribution; commit format `<scope>: <summary>` (< 75 chars, imperative). Use `git -c commit.gpgsign=false commit` if signing is locked.
- Index path: `<config_dir>/recall/<repo-id>/index.db`, `<repo-id> = slug[:80] + "-" + sha256(toplevel)[:12]`, dirs 0700, file 0600. Never inside the repo (exit 6).
- Config dir routing: `$CLAUDE_CONFIG_DIR` > (top level under `$CLAUDE_WORK_TREE`, default `~/Git/work`) `$CLAUDE_WORK_CONFIG_DIR` (default `~/.claude-work`, created if absent) > `~/.claude`.
- Exit codes: 0 hits, 1 no hits, 2 no sources, 3 not git, 4 raw parse error, 5 no FTS5, 6 config/index path error, 7 locked or missing index, 8 eval input invalid, 64 usage.
- Kind precedence: `memory > extra > findings > handoffs > todos > docs`; each resolved path indexed once.
- Eligibility: regular file, not symlink, no symlinked directory component, inside top level (memory: inside its memory dir), extension allowed for the kind, <= 1 MiB, UTF-8.
- `search` stdout carries results only; refresh summary and warnings go to stderr.
- Ranking `bm25(chunks, 0, 0, 0, 3.0, 1.0)`, ties by `display` then `line`.
- Every task: write the failing test first, run it, implement, run again, commit.
- Test suites live at `claude/skills/repo-recall/scripts/tests/`; the shell suite runs the unittest file first, then the CLI cases.

## Baseline (record before Task 1)

Run `bin/dotfiles-tests --list | wc -l` and `bin/dotfiles-tests` from the repo root. Expected before this work: 16 suites listed, all passing. Write both numbers into the first commit message body.

## File Structure

| File | Responsibility |
| --- | --- |
| `claude/skills/repo-recall/scripts/recall.py` | The whole tool. Sections in order: constants, routing (`resolve_config_dir`, `repo_id`, `git_paths`, `index_path`), sources (`collect_sources`, `eligible`), chunking (`chunk_markdown`, `chunk_plain`), index I/O (`open_index`, `refresh`), search (`build_query`, `run_search`, printers), status, eval, CLI (`main`). |
| `claude/skills/repo-recall/scripts/tests/test_recall_units.py` | `unittest` for the pure functions: slug/repo id, routing, chunking, query building, corruption classification. |
| `claude/skills/repo-recall/scripts/tests/recall_test.sh` | Shell suite: runs the unit tests, then CLI cases against temp repos. Registered in `bin/dotfiles-tests`. |
| `claude/skills/repo-recall/SKILL.md` | Skill doc: triggers, commands, worker contract, degradation, golden-set capture. |
| `claude/skills/.gitignore` | Whitelist `!/repo-recall/`. |
| `bin/dotfiles-tests` | Add `bash claude/skills/repo-recall/scripts/tests/recall_test.sh` to `SUITES`. |

---

### Task 1: Scaffold, FTS5 probe, routing, repo id, git detection

**Files:**
- Create: `claude/skills/repo-recall/scripts/recall.py`
- Create: `claude/skills/repo-recall/scripts/tests/test_recall_units.py`
- Create: `claude/skills/repo-recall/scripts/tests/recall_test.sh`
- Modify: `claude/skills/.gitignore` (append `!/repo-recall/`)

**Interfaces:**
- Produces: `slug(path: str) -> str`, `repo_id(toplevel: Path) -> str`, `resolve_config_dir(anchor: Path, env: Mapping) -> Path`, `git_paths(cwd: Path) -> tuple[Path, Path] | None` (toplevel, canonical root), `index_path(config_dir, toplevel, canonical) -> Path` (raises `ConfigError` when inside the repo), `ensure_index_dir(path)`, `fts5_available() -> bool`, `main(argv) -> int`, exceptions `ConfigError` and `LockedError`, exit constants `EXIT_*`, class `Context` (attributes `toplevel`, `canonical`, `config_dir`, `index_file`; raises `SystemExit(3)` outside git), hidden flags `recall.py --slug <path>` and `recall.py --repo-id <path>` for tests.

- [ ] **Step 1: Whitelist the skill dir and write the unit tests**

Append to `claude/skills/.gitignore` after the `!/reconcile/` line, keeping alphabetical order:

```
!/repo-recall/
```

Create `claude/skills/repo-recall/scripts/tests/test_recall_units.py`:

```python
#!/usr/bin/env python3
"""Unit tests for the pure functions in recall.py."""
import importlib.util
import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("recall", HERE.parent / "recall.py")
recall = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(recall)


class SlugAndRepoId(unittest.TestCase):
    def test_slug_replaces_every_non_alnum_with_dash(self):
        self.assertEqual(recall.slug("/Users/t/Git/x.y/a+b"), "-Users-t-Git-x-y-a-b")

    def test_slug_is_byte_wise_for_non_ascii(self):
        # e-acute is two UTF-8 bytes, so it becomes two dashes, as Claude Code does.
        self.assertEqual(recall.slug("/tmp/caf\u00e9"), "-tmp-caf--")

    def test_repo_id_is_bounded_and_distinct_for_colliding_slugs(self):
        a = recall.repo_id(Path("/tmp/x.y"))
        b = recall.repo_id(Path("/tmp/x-y"))
        self.assertNotEqual(a, b)
        self.assertTrue(a.startswith("-tmp-x-y-"))
        self.assertEqual(len(a.rsplit("-", 1)[1]), 12)
        long = recall.repo_id(Path("/" + "a" * 300))
        self.assertLessEqual(len(long), 80 + 1 + 12)


class Routing(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.home = self.tmp / "home"
        self.work_tree = self.home / "Git" / "work"
        (self.work_tree / "repo").mkdir(parents=True)
        (self.home / "Git" / "personal" / "repo").mkdir(parents=True)
        self.env = {"HOME": str(self.home)}

    def test_explicit_config_dir_wins(self):
        env = dict(self.env, CLAUDE_CONFIG_DIR=str(self.tmp / "cfg"))
        got = recall.resolve_config_dir(self.work_tree / "repo", env)
        self.assertEqual(got, self.tmp / "cfg")

    def test_work_tree_routes_to_work_config_dir(self):
        got = recall.resolve_config_dir((self.work_tree / "repo").resolve(), self.env)
        self.assertEqual(got, self.home / ".claude-work")

    def test_work_config_dir_env_override(self):
        env = dict(self.env, CLAUDE_WORK_CONFIG_DIR=str(self.tmp / "w"))
        got = recall.resolve_config_dir((self.work_tree / "repo").resolve(), env)
        self.assertEqual(got, self.tmp / "w")

    def test_personal_tree_routes_to_personal(self):
        got = recall.resolve_config_dir(
            (self.home / "Git" / "personal" / "repo").resolve(), self.env)
        self.assertEqual(got, self.home / ".claude")

    def test_index_path_inside_repo_raises(self):
        top = (self.home / "Git" / "personal" / "repo").resolve()
        with self.assertRaises(recall.ConfigError):
            recall.index_path(top / ".claude", top, top)

    def test_index_path_layout(self):
        top = (self.home / "Git" / "personal" / "repo").resolve()
        got = recall.index_path(self.home / ".claude", top, top)
        self.assertEqual(got.name, "index.db")
        self.assertEqual(got.parent.parent, self.home / ".claude" / "recall")
        self.assertEqual(got.parent.name, recall.repo_id(top))


class Fts5Probe(unittest.TestCase):
    def test_force_flag_disables(self):
        os.environ["RECALL_FORCE_NO_FTS5"] = "1"
        try:
            self.assertFalse(recall.fts5_available())
        finally:
            del os.environ["RECALL_FORCE_NO_FTS5"]


if __name__ == "__main__":
    sys.exit(unittest.main())
```

- [ ] **Step 2: Write the shell suite skeleton with the first CLI cases**

Create `claude/skills/repo-recall/scripts/tests/recall_test.sh`:

```bash
#!/usr/bin/env bash
# Test suite for recall.py. Isolated via HOME / CLAUDE_* env pointed at mktemp dirs.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RECALL="$HERE/../recall.py"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }
assert_eq()       { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected [$3] got [$2]"; }
assert_contains() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "[$2] missing [$3]";; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "[$2] contains [$3]";; *) ok "$1";; esac; }
assert_file()    { if [ -e "$2" ]; then ok "$1"; else bad "$1" "missing $2"; fi; }
assert_no_file() { if [ -e "$2" ]; then bad "$1" "unexpected $2"; else ok "$1"; fi; }

# Fresh isolated environment per test: HOME, config dirs, work tree.
setup_env() {
  SANDBOX=$(mktemp -d)
  export HOME="$SANDBOX/home"
  mkdir -p "$HOME/Git/work" "$HOME/Git/personal"
  export CLAUDE_WORK_TREE="$HOME/Git/work"
  export CLAUDE_WORK_CONFIG_DIR="$HOME/.claude-work"
  unset CLAUDE_CONFIG_DIR RECALL_EXTRA_GLOBS RECALL_FORCE_NO_FTS5
}
# mk_repo <dir>: git init a repo at dir; echoes resolved path.
mk_repo() {
  mkdir -p "$1"
  ( cd "$1" && git init -q && git config user.email t@t && git config user.name t )
  /usr/bin/env realpath "$1"
}
# recall <repo> args...: run recall.py from inside repo, capture stdout in OUT,
# stderr in ERR, exit code in RC.
recall() {
  local repo="$1"; shift
  OUT=$(cd "$repo" && python3 "$RECALL" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}
# repo_id <repo> / mem_dir <config_dir> <repo>: paths derived by the script itself.
repo_id() { python3 "$RECALL" --repo-id "$1"; }
mem_dir() { printf '%s/projects/%s/memory' "$1" "$(python3 "$RECALL" --slug "$2")"; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

echo "== unit tests"
python3 "$HERE/test_recall_units.py" -q 2>&1 | tail -3
[ "${PIPESTATUS[0]}" = 0 ] && ok "unit tests" || bad "unit tests" "see above"

echo "== task 1: probe, routing, git detection"
test_outside_git_exits_3() {
  setup_env; mkdir -p "$SANDBOX/plain"
  recall "$SANDBOX/plain" search foo
  assert_eq "search outside git exits 3" "$RC" 3
  recall "$SANDBOX/plain" status
  assert_eq "status outside git exits 3" "$RC" 3
}
test_no_fts5_exits_5() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  RECALL_FORCE_NO_FTS5=1 recall "$r" search foo
  assert_eq "no fts5 exits 5" "$RC" 5
  assert_contains "no fts5 names the fix" "$ERR" "FTS5"
}
test_routing_personal() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  recall "$r" status
  assert_eq "status exits 0" "$RC" 0
  assert_contains "status prints personal config dir" "$OUT" "$HOME/.claude"
  assert_no_file "personal never creates work dir" "$HOME/.claude-work"
}
test_routing_work_creates_dir() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/work/r")
  recall "$r" status
  assert_contains "work tree routes to work config dir" "$OUT" "$HOME/.claude-work"
  assert_file "work config dir created" "$HOME/.claude-work/recall"
  assert_eq "work config dir mode 700" "$(file_mode "$HOME/.claude-work")" 700
  assert_eq "recall dir mode 700" "$(file_mode "$HOME/.claude-work/recall")" 700
  assert_no_file "work never touches personal recall dir" "$HOME/.claude/recall"
}
test_routing_override() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/work/r")
  CLAUDE_CONFIG_DIR="$SANDBOX/custom" recall "$r" status
  assert_contains "CLAUDE_CONFIG_DIR overrides" "$OUT" "$SANDBOX/custom"
}
test_index_inside_repo_exits_6() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  CLAUDE_CONFIG_DIR="$r/.claude" recall "$r" status
  assert_eq "index inside repo exits 6" "$RC" 6
}
test_usage_and_help() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r")
  recall "$r" --help
  assert_eq "help exits 0" "$RC" 0
  recall "$r" bogus
  assert_eq "unknown command exits 64" "$RC" 64
  assert_eq "usage error is one line" "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" 1
}
test_outside_git_exits_3
test_no_fts5_exits_5
test_routing_personal
test_routing_work_creates_dir
test_routing_override
test_index_inside_repo_exits_6
test_usage_and_help

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

Later tasks insert their blocks above the `printf ... passed` summary line.

- [ ] **Step 3: Run the suite to verify it fails**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`
Expected: unit tests FAIL (no recall.py), every CLI case FAIL.

- [ ] **Step 4: Write recall.py section 1 (constants, routing, git, probe, CLI skeleton)**

Create `claude/skills/repo-recall/scripts/recall.py`:

```python
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
        target = Path(argv[1]).resolve()
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
```

`fnmatch`, `json`, `time`, `namedtuple` are used from Task 2 onward. Ruff flags them as unused in this task: add `# noqa: F401` to those four import lines now and remove each marker in the task that first uses it. `--help` propagates argparse's `SystemExit(0)` through `main`, which is the intended exit 0.

- [ ] **Step 5: Run the suite; expect Task 1 cases to pass**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`
Expected: unit tests pass; all seven Task 1 CLI cases pass; `N passed, 0 failed`.

Run: `ruff check claude/skills/repo-recall/scripts/`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add claude/skills/.gitignore claude/skills/repo-recall/
git commit -m "skills: Scaffold repo-recall with routing and FTS5 probe"
```

Put the baseline suite count and pass/fail line from the Baseline section in the commit body.

---

### Task 2: Source discovery

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (add sources section after routing)
- Modify: `claude/skills/repo-recall/scripts/tests/test_recall_units.py`

**Interfaces:**
- Consumes: `slug`, `warn`, `_home`, constants.
- Produces: `Source` namedtuple `(path: Path, display: str, kind: str)`; `collect_sources(toplevel: Path, canonical: Path, config_dir: Path, env=None, quiet=False) -> list[Source]`; `display_path(path: Path, toplevel: Path, home: Path) -> str`; `memory_dirs(config_dir, toplevel, canonical) -> list[Path]`; `eligible(path, root, kind) -> bool`.

- [ ] **Step 1: Write the failing unit tests**

Append to `test_recall_units.py` before `if __name__`:

```python
class Sources(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()).resolve()
        self.top = self.tmp / "repo"
        self.cfg = self.tmp / "cfg"
        self.home = self.tmp / "home"
        for rel in ["docs/specs", "docs/findings", ".claude/handoffs", ".todos/pending",
                    ".todos/completed", ".hidden", "node_modules", "extra"]:
            (self.top / rel).mkdir(parents=True)
        self.write("docs/specs/s.md", "# S\nbody")
        self.write("docs/findings/f.md", "# F\nbody")
        self.write("docs/findings/f.txt", "plain finding")
        self.write(".claude/handoffs/h.md", "# H\nbody")
        self.write(".todos/pending/t.md", "# T\nbody")
        self.write(".todos/TODO.md", "index")
        self.write("README.md", "# R\nbody")
        self.write(".hidden/x.md", "# X\nbody")
        self.write("node_modules/n.md", "# N\nbody")
        self.write("extra/e.txt", "extra text")
        self.write("extra/e.py", "print(1)")
        mem = self.cfg / "projects" / recall.slug(self.top) / "memory"
        mem.mkdir(parents=True)
        (mem / "m.md").write_text("# M\nbody")
        (mem / "MEMORY.md").write_text("index")
        self.env = {"HOME": str(self.home)}

    def write(self, rel, text):
        p = self.top / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def kinds(self, env=None):
        srcs = recall.collect_sources(self.top, self.top, self.cfg, env or self.env, quiet=True)
        return {s.display: s.kind for s in srcs}

    def test_kinds_and_precedence(self):
        got = self.kinds()
        self.assertEqual(got["docs/specs/s.md"], "docs")
        self.assertEqual(got["docs/findings/f.md"], "findings")
        self.assertEqual(got["docs/findings/f.txt"], "findings")
        self.assertEqual(got[".claude/handoffs/h.md"], "handoffs")
        self.assertEqual(got[".todos/pending/t.md"], "todos")
        self.assertEqual(got["README.md"], "docs")
        self.assertNotIn(".todos/TODO.md", got)
        self.assertNotIn(".hidden/x.md", got)
        self.assertNotIn("node_modules/n.md", got)
        self.assertNotIn("extra/e.txt", got)

    def test_memory_display_and_index_skip(self):
        got = self.kinds()
        mem = [d for d, k in got.items() if k == "memory"]
        self.assertEqual(len(mem), 1)
        self.assertTrue(mem[0].endswith("/memory/m.md"))

    def test_memory_display_is_tilde_relative_when_under_home(self):
        cfg = self.home / ".claude"
        mem = cfg / "projects" / recall.slug(self.top) / "memory"
        mem.mkdir(parents=True)
        (mem / "m.md").write_text("# M\nbody")
        srcs = recall.collect_sources(self.top, self.top, cfg, self.env, quiet=True)
        mem_display = [s.display for s in srcs if s.kind == "memory"]
        self.assertEqual(mem_display, ["~/.claude/projects/%s/memory/m.md" % recall.slug(self.top)])

    def test_extra_globs_and_containment(self):
        env = dict(self.env, RECALL_EXTRA_GLOBS="extra/*.txt:extra/*.py:../outside/*.md")
        got = self.kinds(env)
        self.assertEqual(got["extra/e.txt"], "extra")
        self.assertNotIn("extra/e.py", got)
        self.assertFalse(any(d.startswith("..") for d in got))

    def test_each_path_once(self):
        srcs = recall.collect_sources(self.top, self.top, self.cfg, self.env, quiet=True)
        paths = [s.path for s in srcs]
        self.assertEqual(len(paths), len(set(paths)))

    def test_oversized_and_symlink_excluded(self):
        self.write("docs/big.md", "x" * (recall.MAX_FILE_BYTES + 1))
        os.symlink(self.top / "docs/specs/s.md", self.top / "docs/link.md")
        os.symlink(self.top / "docs/specs", self.top / "docs/linkdir")
        got = self.kinds()
        self.assertNotIn("docs/big.md", got)
        self.assertNotIn("docs/link.md", got)
        self.assertFalse(any(d.startswith("docs/linkdir/") for d in got))

    def test_extra_glob_double_star_matches_nested_and_direct(self):
        self.write("notes/a.txt", "a")
        self.write("notes/deep/b.txt", "b")
        env = dict(self.env, RECALL_EXTRA_GLOBS="notes/**/*.txt")
        got = self.kinds(env)
        self.assertEqual(got["notes/a.txt"], "extra")
        self.assertEqual(got["notes/deep/b.txt"], "extra")

    def test_canonical_root_memory_included_for_worktree(self):
        canonical = self.tmp / "main"
        mem = self.cfg / "projects" / recall.slug(canonical) / "memory"
        mem.mkdir(parents=True)
        (mem / "c.md").write_text("# C\nbody")
        srcs = recall.collect_sources(self.top, canonical, self.cfg, self.env, quiet=True)
        self.assertEqual(sorted(Path(s.path).name for s in srcs if s.kind == "memory"),
                         ["c.md", "m.md"])
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 claude/skills/repo-recall/scripts/tests/test_recall_units.py -q`
Expected: `AttributeError: module 'recall' has no attribute 'collect_sources'`.

- [ ] **Step 3: Implement the sources section**

Insert after the routing section of `recall.py` (before `class Context`):

```python
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
```

For memory sources the `root` passed to `eligible` is the memory dir, so containment is checked against it. The tree is walked once with `os.walk(followlinks=False)` and symlinked or excluded directories are pruned from `dirnames` before descent. Remove the `# noqa` from the `fnmatch` and `namedtuple` imports.

- [ ] **Step 4: Run the unit tests and ruff; expect pass**

Run: `python3 claude/skills/repo-recall/scripts/tests/test_recall_units.py -q && ruff check claude/skills/repo-recall/scripts/`

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall source discovery with kind precedence"
```

---

### Task 3: Chunking, query building, corruption classification

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (chunking + query section after sources)
- Modify: `claude/skills/repo-recall/scripts/tests/test_recall_units.py`

**Interfaces:**
- Produces: `Chunk` namedtuple `(heading: str, line: int, body: str)`; `chunk_markdown(text, filename) -> list[Chunk]`; `chunk_plain(text, filename) -> list[Chunk]`; `chunk_file(path, text) -> list[Chunk]`; `build_query(terms: list[str], raw: bool) -> str`; `is_corruption(exc) -> bool`.

- [ ] **Step 1: Write the failing unit tests**

Append to `test_recall_units.py`:

```python
class Chunking(unittest.TestCase):
    def test_preamble_uses_first_h1_and_line_1(self):
        text = "---\ntitle: T\n---\nintro\n\n# Main\nbody\n## Sub ##\nsub body\n#### deep\ndeep body\n"
        chunks = recall.chunk_markdown(text, "f.md")
        self.assertEqual([c.heading for c in chunks], ["Main", "Main", "Sub"])
        self.assertEqual([c.line for c in chunks], [1, 6, 8])
        self.assertIn("title: T", chunks[0].body)
        self.assertIn("deep body", chunks[2].body)
        self.assertNotIn("# Main", chunks[1].body)

    def test_file_starting_with_heading_has_no_empty_preamble(self):
        chunks = recall.chunk_markdown("# Only\nbody\n", "f.md")
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0].line, 1)

    def test_headingless_file_is_one_chunk_named_by_file(self):
        chunks = recall.chunk_markdown("just text\nmore\n", "notes.md")
        self.assertEqual(chunks, [recall.Chunk("notes.md", 1, "just text\nmore")])

    def test_empty_body_chunks_dropped(self):
        chunks = recall.chunk_markdown("# A\n\n# B\nb body\n", "f.md")
        self.assertEqual([c.heading for c in chunks], ["B"])

    def test_headings_inside_code_fences_ignored(self):
        text = "# A\n```sh\n# not a heading\n```\nafter\n"
        chunks = recall.chunk_markdown(text, "f.md")
        self.assertEqual(len(chunks), 1)
        self.assertIn("# not a heading", chunks[0].body)

    def test_fence_closes_only_with_matching_marker(self):
        # A ``` inside a ~~~ block does not close it; a longer ```` closes ```.
        text = "# A\n~~~\n```\n# still fenced\n~~~\n````\n# also fenced\n`````\n## B\nb\n"
        chunks = recall.chunk_markdown(text, "f.md")
        self.assertEqual([c.heading for c in chunks], ["A", "B"])

    def test_plain_is_one_chunk(self):
        self.assertEqual(recall.chunk_plain("x\ny", "f.txt"), [recall.Chunk("f.txt", 1, "x\ny")])
        self.assertEqual(recall.chunk_plain("  \n", "f.txt"), [])


class QueryBuilding(unittest.TestCase):
    def test_default_mode_quotes_and_ands(self):
        self.assertEqual(recall.build_query(['a"b', "c*", "(d"], raw=False),
                         '"a""b" AND "c*" AND "(d"')

    def test_raw_passthrough(self):
        self.assertEqual(recall.build_query(["a", "OR", "b*"], raw=True), "a OR b*")


class CorruptionClassification(unittest.TestCase):
    def test_only_specific_messages_count(self):
        self.assertTrue(recall.is_corruption(sqlite3.DatabaseError("file is not a database")))
        self.assertTrue(recall.is_corruption(sqlite3.DatabaseError("database disk image is malformed")))
        self.assertFalse(recall.is_corruption(sqlite3.OperationalError("database is locked")))
        self.assertFalse(recall.is_corruption(sqlite3.OperationalError("fts5: syntax error near ...")))
        self.assertFalse(recall.is_corruption(sqlite3.OperationalError("attempt to write a readonly database")))
        self.assertFalse(recall.is_corruption(sqlite3.DatabaseError("note: file is not a database")))
```

- [ ] **Step 2: Run to verify failure**

Run: `python3 claude/skills/repo-recall/scripts/tests/test_recall_units.py -q`
Expected: `AttributeError ... chunk_markdown`.

- [ ] **Step 3: Implement chunking, query building, corruption classification**

Insert after the sources section:

```python
# --- chunking --------------------------------------------------------------

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
```

- [ ] **Step 4: Run unit tests and ruff; expect pass**

Run: `python3 claude/skills/repo-recall/scripts/tests/test_recall_units.py -q && ruff check claude/skills/repo-recall/scripts/`

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall chunking and query building"
```

---

### Task 4: Index storage and incremental refresh (`index` command)

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (index I/O section after query, `cmd_index`)
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh`

**Interfaces:**
- Consumes: `Context`, `collect_sources`, `chunk_file`, `is_corruption`, `ensure_index_dir`.
- Produces: `open_index(ctx, quiet=False) -> sqlite3.Connection` (creates schema, quarantines corruption, rebuilds on schema mismatch); `refresh(conn, ctx, full=False, quiet=False) -> RefreshStats` namedtuple `(files, added, modified, removed, chunks)` raising `LockedError` when `BEGIN IMMEDIATE` times out; `has_index(conn) -> bool`; `_meta(conn, key) -> str | None`; `format_stats(stats) -> str`; `cmd_index(args) -> int`. Test-only env `RECALL_BUSY_TIMEOUT_MS`.

- [ ] **Step 1: Write the failing shell cases**

Insert into `recall_test.sh` above the summary line:

```bash
echo "== task 4: index"
# seed_repo <repo> <config_dir>: docs, todo, handoff, finding, memory (+ MEMORY.md index).
seed_repo() {
  local r="$1" cfg="$2"
  mkdir -p "$r/docs/specs" "$r/docs/findings" "$r/.claude/handoffs" "$r/.todos/pending"
  printf '# Widget spec\n\nThe widget frobnicates gizmos.\n\n## Decision\n\nWe chose the frobnicator over the gizmo mangler.\n' > "$r/docs/specs/widget.md"
  printf -- '---\ntitle: Fix the mangler\npriority: high\n---\n\n## Problem\n\nMangler leaks memory.\n' > "$r/.todos/pending/2026-01-01-fix-mangler.md"
  printf '# Handoff\n\nNext slice: wire the frobnicator to the widget bus.\n' > "$r/.claude/handoffs/latest.md"
  printf 'finding: mangler leak reproduced under load\n' > "$r/docs/findings/leak.txt"
  local mem; mem=$(mem_dir "$cfg" "$r")
  mkdir -p "$mem"; printf '# Memory\n\nUser prefers the frobnicator naming.\n' > "$mem/naming.md"
  printf 'index\n' > "$mem/MEMORY.md"
}
db_path() { printf '%s/recall/%s/index.db' "$1" "$(repo_id "$2")"; }
hold_lock() { # hold_lock <db> <seconds>: background writer holding BEGIN IMMEDIATE
  python3 - "$1" "$2" <<'PY' &
import sqlite3, sys, time
c = sqlite3.connect(sys.argv[1]); c.execute("BEGIN IMMEDIATE"); time.sleep(float(sys.argv[2]))
PY
  LOCK_PID=$!; sleep 0.5
}
test_index_builds_and_reports() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  assert_eq "index exits 0" "$RC" 0
  assert_contains "index summary counts files" "$OUT" "indexed 5 files (+5 ~0 -0)"
  local db; db=$(db_path "$HOME/.claude" "$r")
  assert_file "index file exists" "$db"
  assert_eq "index file mode 600" "$(file_mode "$db")" 600
  assert_eq "index dir mode 700" "$(file_mode "$(dirname "$db")")" 700
  recall "$r" index
  assert_contains "second index is a no-op" "$OUT" "(+0 ~0 -0)"
}
test_index_incremental() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  sleep 1; printf '\n## Addendum\n\nNew paragraph.\n' >> "$r/docs/specs/widget.md"
  unlink "$r/docs/findings/leak.txt"
  printf '# New\n\nfresh doc\n' > "$r/docs/new.md"
  recall "$r" index
  assert_contains "incremental counts +1 ~1 -1" "$OUT" "(+1 ~1 -1)"
  head -c $((1024*1024+1)) /dev/zero | tr '\0' 'x' > "$r/docs/new.md"
  recall "$r" index
  assert_contains "oversized file removed" "$OUT" "(+0 ~0 -1)"
  printf '\xff\xfe not utf8\n' > "$r/docs/bad.md"
  recall "$r" index
  assert_contains "non-utf8 skipped with warning" "$ERR" "skipping docs/bad.md"
  RECALL_EXTRA_GLOBS="docs/specs/*.md" recall "$r" index
  assert_contains "kind change re-indexes the file" "$OUT" "(+0 ~1 -0)"
  RECALL_EXTRA_GLOBS="docs/specs/*.md" recall "$r" search --json --no-refresh frobnicates
  assert_contains "kind change lands in the index" "$OUT" '"kind": "extra"'
  recall "$r" index --full
  assert_contains "full rebuild reindexes all" "$OUT" "(+4 ~0 -0)"
}
test_index_no_sources_and_git_clean() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/empty")
  local before; before=$(cd "$r" && git status --porcelain)
  recall "$r" index
  assert_eq "index with no sources exits 0" "$RC" 0
  assert_contains "index with no sources says so" "$OUT" "indexed 0 files"
  recall "$r" status
  recall "$r" search anything
  local after; after=$(cd "$r" && git status --porcelain)
  assert_eq "index, status and search leave git status unchanged" "$after" "$before"
}
test_index_corrupt_quarantined() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  local db; db=$(db_path "$HOME/.claude" "$r")
  printf 'garbage garbage garbage' > "$db"
  recall "$r" index
  assert_eq "corrupt index rebuild exits 0" "$RC" 0
  assert_contains "corrupt index warned" "$ERR" "corrupt"
  assert_file "corrupt index quarantined" "$db.corrupt"
  assert_contains "corrupt index rebuilt fully" "$OUT" "(+5 ~0 -0)"
}
test_index_schema_mismatch_rebuilds() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  local db; db=$(db_path "$HOME/.claude" "$r")
  python3 -c "import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute(\"UPDATE meta SET value='0' WHERE key='schema_version'\"); c.commit()" "$db"
  recall "$r" index
  assert_contains "schema mismatch warns" "$ERR" "schema"
  assert_contains "schema mismatch rebuilds" "$OUT" "(+5 ~0 -0)"
}
test_index_locked_exits_7() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  hold_lock "$(db_path "$HOME/.claude" "$r")" 6
  RECALL_BUSY_TIMEOUT_MS=500 recall "$r" index
  assert_eq "locked index exits 7" "$RC" 7
  wait "$LOCK_PID"
}
test_index_builds_and_reports
test_index_incremental
test_index_no_sources_and_git_clean
test_index_corrupt_quarantined
test_index_schema_mismatch_rebuilds
test_index_locked_exits_7
```

- [ ] **Step 2: Run the suite to verify the Task 4 cases fail**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`
Expected: Task 1 cases pass, Task 4 cases fail (`index: not implemented`).

- [ ] **Step 3: Implement index I/O and `cmd_index`**

Insert after the query section:

```python
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
                data = src.path.read_bytes()
                text = data.decode("utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                warn(f"skipping {src.display}: {exc}", quiet)
                continue
            current.add(str(src.path))
            row = known.get(str(src.path))
            if row and row[3] == st.st_mtime_ns and row[4] == st.st_size and row[2] == src.kind:
                continue
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
```

Register `"index": cmd_index` in `COMMANDS` (keep `COMMANDS` at the bottom of the file, after every handler). Remove the `# noqa` from `time`. Note on `--full`: rows are deleted inside the same transaction, so `known` is empty and every file counts as added, matching `(+4 ~0 -0)`. Note on the corrupt case: a garbage file makes `_connect` succeed but `PRAGMA quick_check` raise `file is not a database`, which `is_corruption` accepts; `_quarantine` renames it and `ensure_index_dir` recreates an empty 0600 file. Note on locks: `PRAGMA quick_check` and the meta read are plain reads, allowed while another connection holds `BEGIN IMMEDIATE`, so the only write is `refresh`'s own transaction; a lock error anywhere else reaches `main`'s `sqlite3.OperationalError` handler and maps to exit 7. A file that becomes ineligible (oversized) is simply absent from `sources`, so the removal loop drops it. A kind change (same path, different kind) fails the `row[2] == src.kind` checks and is re-indexed as modified.

- [ ] **Step 4: Run the suite and ruff; expect Task 1 and Task 4 cases to pass**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh && ruff check claude/skills/repo-recall/scripts/`

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall index storage and incremental refresh"
```

---

### Task 5: `search` command

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (search section after index I/O, `cmd_search`)
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh`

**Interfaces:**
- Consumes: `open_index`, `refresh`, `has_index`, `build_query`, `format_stats`, `LockedError`.
- Produces: `Hit` namedtuple `(rank, score, path, line, kind, heading, snippet)`; `run_search(conn, query, kinds, limit) -> list[Hit]` (lets `sqlite3.OperationalError` propagate on parse errors); `print_hits_text(hits)`, `print_hits_json(hits)`; `refresh_or_degrade(conn, ctx, quiet) -> bool`; `cmd_search(args) -> int`.

- [ ] **Step 1: Write the failing shell cases**

Insert above the summary line:

```bash
echo "== task 5: search"
test_search_hits_and_ranking() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search frobnicator
  assert_eq "search hit exits 0" "$RC" 0
  assert_contains "search prints anchor" "$OUT" "docs/specs/widget.md:"
  assert_contains "search prints kind" "$OUT" "[docs]"
  assert_contains "refresh summary on stderr" "$ERR" "indexed 5 files"
  assert_not_contains "refresh summary not on stdout" "$OUT" "indexed"
  recall "$r" search --json decision
  local first; first=$(printf '%s\n' "$OUT" | head -1)
  assert_contains "heading match ranks first" "$first" '"line": 5'
  assert_contains "json carries display path" "$first" '"path": "docs/specs/widget.md"'
  assert_contains "heading-only match is highlighted in snippet" "$first" '>>Decision<<'
  recall "$r" search "gizmo mangler"
  assert_eq "quoted multi-word query is split into AND terms" "$RC" 0
  printf '# Same\n\nzebra text\n' > "$r/docs/tie-b.md"; printf '# Same\n\nzebra text\n' > "$r/docs/tie-a.md"
  recall "$r" search --json zebra
  assert_contains "ties order by display path" "$(printf '%s\n' "$OUT" | head -1)" '"path": "docs/tie-a.md"'
  recall "$r" search mangler --kind todos
  assert_contains "kind filter keeps todos" "$OUT" ".todos/pending/2026-01-01-fix-mangler.md"
  assert_not_contains "kind filter drops findings" "$OUT" "leak.txt"
  recall "$r" search naming
  assert_contains "memory hit shows tilde path" "$OUT" "~/.claude/projects/"
  recall "$r" search zzzznotthere
  assert_eq "no hits exits 1" "$RC" 1
}
test_search_no_sources_exits_2() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/empty")
  recall "$r" search anything
  assert_eq "no sources exits 2" "$RC" 2
  assert_contains "no sources names locations" "$ERR" "docs/"
}
test_search_query_contract() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search 'widget"' '(spec' 'fro*'
  if [ "$RC" = 0 ] || [ "$RC" = 1 ]; then ok "default mode never errors on syntax"; else bad "default mode never errors on syntax" "exit $RC"; fi
  recall "$r" search --raw 'widget OR ('
  assert_eq "raw parse error exits 4" "$RC" 4
  recall "$r" search --raw 'frob* OR mangler'
  assert_eq "raw operators work" "$RC" 0
  recall "$r" search --limit 0 widget
  assert_eq "limit 0 exits 64" "$RC" 64
  recall "$r" search --kind bogus widget
  assert_eq "unknown kind exits 64" "$RC" 64
  recall "$r" search '   '
  assert_eq "blank query exits 64" "$RC" 64
}
test_search_refresh_and_no_refresh() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" search --no-refresh widget
  assert_eq "no-refresh without index exits 7" "$RC" 7
  recall "$r" index
  printf '# Later\n\nquux appears now\n' > "$r/docs/later.md"
  recall "$r" search --no-refresh quux
  assert_eq "no-refresh does not see new file" "$RC" 1
  recall "$r" search quux
  assert_eq "search refreshes and finds new file" "$RC" 0
}
test_search_json_pure_stdout() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  printf '# Extra\n\nwidget again\n' > "$r/docs/extra.md"
  recall "$r" search --json widget
  if printf '%s\n' "$OUT" | python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin if l.strip()]'; then
    ok "json stdout is pure JSONL after refresh"; else bad "json stdout is pure JSONL after refresh" "$OUT"; fi
}
test_search_isolation_sentinels() {
  setup_env
  local p; p=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$p" "$HOME/.claude"
  local w; w=$(mk_repo "$HOME/Git/work/r"); seed_repo "$w" "$HOME/.claude-work"
  printf '# P\n\npersonalsentinel\n' > "$(mem_dir "$HOME/.claude" "$p")/p.md"
  printf '# W\n\nworksentinel\n' > "$(mem_dir "$HOME/.claude-work" "$w")/w.md"
  recall "$w" search personalsentinel
  assert_eq "work search never sees personal memory" "$RC" 1
  recall "$p" search worksentinel
  assert_eq "personal search never sees work memory" "$RC" 1
  recall "$w" search worksentinel
  assert_eq "work search sees work memory" "$RC" 0
  assert_no_file "personal recall dir untouched by work" "$HOME/.claude/recall/$(repo_id "$w")"
}
test_search_worktree_sees_main_memory() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  ( cd "$r" && git add -A && git commit -qm init && git worktree add -q "$SANDBOX/wt" -b wt )
  local wt; wt=$(/usr/bin/env realpath "$SANDBOX/wt")
  recall "$wt" search naming
  assert_eq "worktree finds main checkout memory" "$RC" 0
  assert_file "worktree has its own index" "$(db_path "$HOME/.claude" "$wt")"
}
test_search_locked_degrades() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  hold_lock "$(db_path "$HOME/.claude" "$r")" 6
  RECALL_BUSY_TIMEOUT_MS=500 recall "$r" search widget
  assert_eq "locked search still answers" "$RC" 0
  assert_contains "locked search warns" "$ERR" "locked"
  wait "$LOCK_PID"
}
test_search_hits_and_ranking
test_search_no_sources_exits_2
test_search_query_contract
test_search_refresh_and_no_refresh
test_search_json_pure_stdout
test_search_isolation_sentinels
test_search_worktree_sees_main_memory
test_search_locked_degrades
```

- [ ] **Step 2: Run the suite; Task 5 cases fail**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh`
Expected: only `search: not implemented` failures.

- [ ] **Step 3: Implement search**

Insert after the index I/O section:

```python
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
        kind_filter = "AND kind IN (%s)" % ",".join("?" * len(kinds))
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
        if args.raw and "fts5" in str(exc).lower():
            return _fail(EXIT_QUERY, f"query error: {exc}")
        return _fail(classify_sqlite_error(exc), f"sqlite: {exc}")
    if not hits:
        return EXIT_NO_HITS
    (print_hits_json if args.json else print_hits_text)(hits)
    return EXIT_OK
```

Register `"search": cmd_search`. Remove the `# noqa` from `json`. The refresh summary goes through `warn` to stderr, so `--json` stdout stays pure. `snippet(chunks, -1, ...)` lets FTS5 pick the best-matching column, so a heading-only match highlights the heading instead of returning an unmarked body excerpt.

- [ ] **Step 4: Run suite and ruff; expect all cases so far to pass**

Run: `bash claude/skills/repo-recall/scripts/tests/recall_test.sh && ruff check claude/skills/repo-recall/scripts/`

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall search command with ranked output"
```

---

### Task 6: `status` and `status --all`

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (replace Task 1 `cmd_status` / `status_all`)
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh`

**Interfaces:**
- Consumes: `open_index`, `_meta`, `resolve_config_dir`.
- Produces: full `cmd_status(args)`; `status_all() -> int` (read-only listing).

- [ ] **Step 1: Write the failing shell cases**

Insert above the summary line:

```bash
echo "== task 6: status"
test_status_reports_counts() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  recall "$r" status
  assert_eq "status exits 0" "$RC" 0
  assert_contains "status shows schema version" "$OUT" "schema: 1"
  assert_contains "status shows script version" "$OUT" "version: 1"
  assert_contains "status shows docs count" "$OUT" "docs: 1 files"
  assert_contains "status shows memory count" "$OUT" "memory: 1 files"
  assert_contains "status shows last index" "$OUT" "last index: 20"
}
test_status_all_outside_git_and_corrupt() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" index
  mkdir -p "$HOME/.claude/recall/bogus-000000000000"; printf 'junk' > "$HOME/.claude/recall/bogus-000000000000/index.db"
  mkdir -p "$SANDBOX/plain"
  recall "$SANDBOX/plain" status --all
  assert_eq "status --all works outside git" "$RC" 0
  assert_contains "status --all lists live index" "$OUT" "$r"
  assert_contains "status --all flags corrupt" "$OUT" "corrupt"
  assert_file "status --all never quarantines" "$HOME/.claude/recall/bogus-000000000000/index.db"
  assert_no_file "status --all never rebuilds" "$HOME/.claude/recall/bogus-000000000000/index.db.corrupt"
}
test_status_reports_counts
test_status_all_outside_git_and_corrupt
```

- [ ] **Step 2: Run; expect Task 6 failures only**

- [ ] **Step 3: Implement status**

Replace the Task 1 `cmd_status` and `status_all`:

```python
# --- status ----------------------------------------------------------------

def cmd_status(args):
    if args.all:
        return status_all()
    ctx = Context()
    conn = open_index(ctx)
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
```

- [ ] **Step 4: Run suite and ruff; expect pass**

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall status with read-only index listing"
```

---

### Task 7: `eval` and `eval add`

**Files:**
- Modify: `claude/skills/repo-recall/scripts/recall.py` (eval section after status)
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh`

**Interfaces:**
- Consumes: `open_index`, `refresh_or_degrade`, `run_search`, `build_query`, `_meta`, `EVAL_NOTES`.
- Produces: `load_golden(path) -> (entries, errors)`; `heading_matches(expected: str, hit: Hit) -> bool`; `cmd_eval(args) -> int`; `cmd_eval_add(args) -> int`.

- [ ] **Step 1: Write the failing shell cases**

Insert above the summary line:

```bash
echo "== task 7: eval"
test_eval_metrics_and_grouping() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  cat > "$r/docs/recall-eval.jsonl" <<'EOF'
{"q": "frobnicator decision", "expect": ["docs/specs/widget.md#Decision"], "note": "hit", "added": "2026-01-02"}
{"q": "why does the mangler leak", "expect": ["docs/nonexistent.md"], "note": "missing-source", "added": "2026-01-02"}
{"q": "widget frobnicates gizmos", "expect": ["docs/specs/widget.md"], "note": "missing-source", "added": "2026-01-02"}
EOF
  recall "$r" eval
  assert_eq "eval exits 0" "$RC" 0
  assert_contains "eval header has version" "$OUT" "version 1"
  assert_contains "eval recall@5 is 0.33 (missing-source always misses)" "$OUT" "recall@5 0.33"
  assert_contains "eval MRR line" "$OUT" "MRR "
  assert_contains "eval groups miss by note" "$OUT" "misses [missing-source]"
}
test_eval_rejects_invalid() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  printf '{"q": "a", "expect": ["docs/nope.md"], "note": "hit", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "unindexed expected path exits 8" "$RC" 8
  printf 'not json\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "malformed line exits 8" "$RC" 8
  printf '{"q": "a", "expect": ["docs/specs/widget.md"], "note": "weird", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "unknown note exits 8" "$RC" 8
  assert_not_contains "invalid run prints no metrics" "$OUT" "recall@5"
  printf '{"q": "a", "expect": null, "note": "hit", "added": "2026-01-02"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "null expect exits 8 without traceback" "$RC" 8
  assert_not_contains "null expect gives no traceback" "$ERR" "Traceback"
  printf '{"q": "a", "expect": ["docs/specs/widget.md"], "note": "hit", "added": "yesterday"}\n' > "$r/docs/recall-eval.jsonl"
  recall "$r" eval
  assert_eq "bad added date exits 8" "$RC" 8
}
test_eval_add() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  recall "$r" eval add "frobnicator naming" --expect "docs/specs/widget.md" --note paraphrase
  assert_eq "eval add exits 0" "$RC" 0
  assert_contains "eval add wrote the query" "$(cat "$r/docs/recall-eval.jsonl")" '"q": "frobnicator naming"'
  recall "$r" eval add "frobnicator naming" --expect "docs/specs/widget.md"
  assert_eq "eval add refuses duplicate q" "$RC" 8
  assert_eq "duplicate not appended" "$(wc -l < "$r/docs/recall-eval.jsonl" | tr -d ' ')" 1
  recall "$r" eval add "gone" --expect "docs/nope.md"
  assert_eq "eval add refuses unindexed path" "$RC" 8
  recall "$r" eval add "gone" --expect "docs/nope.md" --note missing-source
  assert_eq "eval add allows missing-source" "$RC" 0
}
test_eval_metrics_and_grouping
test_eval_rejects_invalid
test_eval_add
```

- [ ] **Step 2: Run; expect Task 7 failures only**

- [ ] **Step 3: Implement eval**

Insert after the status section:

```python
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
```

Register `"eval": cmd_eval` and `"eval-add": cmd_eval_add`; delete `cmd_not_implemented`.

- [ ] **Step 4: Run suite and ruff; expect pass**

- [ ] **Step 5: Commit**

```bash
git add claude/skills/repo-recall/
git commit -m "skills: Add repo-recall eval and golden-set capture"
```

---

### Task 8: SKILL.md, suite registration, acceptance smoke, Linux FTS5 check

**Files:**
- Create: `claude/skills/repo-recall/SKILL.md`
- Modify: `bin/dotfiles-tests` (one `SUITES` line after the todos suite)
- Modify: `claude/skills/repo-recall/scripts/tests/recall_test.sh` (kind-coverage case)

**Interfaces:**
- Consumes: the finished CLI.
- Produces: the shipped skill.

- [ ] **Step 1: Write the last shell case (remaining kinds and extra globs through the CLI)**

Insert above the summary line:

```bash
echo "== task 8: kinds through the cli"
test_cli_kinds_extra_and_findings() {
  setup_env; local r; r=$(mk_repo "$HOME/Git/personal/r"); seed_repo "$r" "$HOME/.claude"
  mkdir -p "$r/notes"; printf 'extra glob content xyzzy\n' > "$r/notes/n.txt"
  RECALL_EXTRA_GLOBS="notes/*.txt" recall "$r" search --json xyzzy
  assert_contains "extra glob indexed as extra" "$OUT" '"kind": "extra"'
  recall "$r" search --json reproduced
  assert_contains "findings txt indexed as findings" "$OUT" '"kind": "findings"'
  recall "$r" search --json "widget bus"
  assert_contains "handoffs indexed" "$OUT" '"kind": "handoffs"'
  RECALL_EXTRA_GLOBS="../outside/*.md" recall "$r" search widget
  assert_contains "escaping extra glob rejected with warning" "$ERR" "rejected"
}
test_cli_kinds_extra_and_findings
```

Run the suite. The case should pass with the existing code; if it fails, fix the code, not the test.

- [ ] **Step 2: Register the suite**

In `bin/dotfiles-tests`, after `bash claude/skills/todos/scripts/tests/todos_test.sh`, add:

```
bash claude/skills/repo-recall/scripts/tests/recall_test.sh
```

Run: `bin/dotfiles-tests --list | wc -l` (expected: baseline + 1) and `bin/dotfiles-tests` (expected: every suite passes).

- [ ] **Step 3: Write SKILL.md**

Create `claude/skills/repo-recall/SKILL.md`:

```markdown
---
name: repo-recall
description: Use when answering questions about prior decisions, specs, plans, findings, todos, handoffs or session memory in the current repo -- "didn't we decide X", "what did the review say about Y", "find the spec/plan/todo about Z", "search our docs/notes/memory". Ranked SQLite FTS5 search over the repo's prose artifacts; not for code symbols (use LSP / grep).
---

# Repo Recall

A per-repo full-text index over prose artifacts, stored under the active
Claude config dir (never in the repo), refreshed at query time. One script,
called by absolute path:

    ~/.claude/skills/repo-recall/scripts/recall.py

## What it indexes

| Kind | Where |
| --- | --- |
| docs | `docs/**/*.md`, `*.md` at the repo root |
| handoffs | `.claude/handoffs/*.md` |
| todos | `.todos/pending/*.md`, `.todos/completed/*.md` |
| findings | `docs/findings/**`, `.claude/findings/**` (md, txt, jsonl) |
| memory | Claude auto-memory for this tree and its main checkout |
| extra | `RECALL_EXTRA_GLOBS` (colon-separated, repo-relative) |

Files over 1 MiB, symlinks, non-UTF-8 files, `.git/`, worktree dirs and
`node_modules/` are skipped. Every path is indexed once under the first
matching kind: memory, extra, findings, handoffs, todos, docs.

## Where the index lives

`<config_dir>/recall/<repo-id>/index.db`. The config dir follows the
`claude()` wrapper rule: `CLAUDE_CONFIG_DIR` if set, else `~/.claude-work`
for trees under `~/Git/work`, else `~/.claude`. So a work repo's index and
memory stay under the work account. `recall.py status` prints the resolved
paths.

## Commands

| Command | Does |
| --- | --- |
| `recall.py search <terms...> [--limit N] [--kind K] [--json] [--raw] [--no-refresh]` | Refresh, then rank. Terms are AND-ed; `--raw` passes FTS5 syntax through |
| `recall.py index [--full] [--quiet]` | Refresh the index (search does this for you) |
| `recall.py status [--all]` | Show routing, counts, last index; `--all` lists every index under the config dir |
| `recall.py eval [file] [--k N]` | Score the golden set (`docs/recall-eval.jsonl`) |
| `recall.py eval add "<q>" --expect <path>[#heading] [--note N]` | Record a golden query (human-requested only) |

Output line: `N. path:line  [kind]  Heading` then a one-line snippet.
`--json` prints one object per line and nothing else on stdout.

Exit codes: 0 hits, 1 no hits, 2 no sources here, 3 not a git tree, 4 raw
query error, 5 python3's sqlite3 lacks FTS5, 6 config dir problem, 7 index
locked or missing, 8 bad eval input, 64 usage.

## How to use it as a worker

1. Run `search` with the concept words, not a sentence:
   `recall.py search frobnicator decision`.
2. Open the file at the `path:line` anchor before answering. The snippet
   is a pointer, not evidence.
3. Exit 2 or 5: say so in one line and fall back to `rg`.
4. Never create files in the repo on the tool's behalf. `eval add` runs
   only when the user asks to record a query, and never with queries that
   contain secrets or customer data.
5. Golden queries are stored verbatim and never edited, with one exception:
   an entry found to contain sensitive data is deleted or redacted at once
   (the user decides which). A redacted query is re-added as a new entry
   with today's `added` date so longitudinal comparisons exclude it.

## Known limits

- An edit that keeps both mtime and size is not detected until
  `index --full`. Editors and git checkouts change mtime, so this does not
  occur in normal use.
- Headings deeper than `###` stay inside their parent section.

## Golden set and the embeddings decision

`docs/recall-eval.jsonl` records real questions as they are asked, hits and
misses alike, with a `note` (`hit`, `paraphrase`, `synonym`,
`tokenization`, `missing-source`). Embeddings are added only if, with at
least 30 real queries over 4 weeks, `recall@5 < 0.80` after FTS-level fixes
and at least half the misses are `paraphrase`. The full rule is in
`docs/specs/2026-09-01-repo-recall-skill.md`.
```

- [ ] **Step 4: Acceptance smoke in this worktree**

Run from the worktree root. The first command moves this tree's index directory aside (to a `.bak` sibling under `~/.claude/recall/`) so the run is cold; the next command regenerates it. Discard the `.bak` copy by hand afterwards.

```bash
R=claude/skills/repo-recall/scripts/recall.py
python3 -c 'import os,sys; d=sys.argv[1]; os.path.isdir(d) and os.rename(d, d + ".bak")' "$HOME/.claude/recall/$(python3 $R --repo-id .)"
time python3 $R search budget capped cheap model tier
python3 $R status
git status --porcelain
```

Expected: the todo `.todos/pending/2026-09-01-add-budget-capped-cheap-model-tier-for-mechanical.md` in the top 3; `real` under 1 s; status shows `config dir: /Users/talon/.claude`; `git status` shows nothing new beyond what was already untracked. Record the timing in the commit body.

- [ ] **Step 5: Linux FTS5 check**

If Docker is available:

```bash
docker run --rm -v "$PWD/claude/skills/repo-recall:/r" python:3.9-slim python3 /r/scripts/tests/test_recall_units.py -q
docker run --rm python:3.9-slim python3 -c "import sqlite3; sqlite3.connect(':memory:').execute('create virtual table t using fts5(x)'); print('fts5 ok')"
```

Expected: OK and `fts5 ok`. If Docker is not available, write "Linux FTS5 check not run" in the commit body and in the close-out report; do not claim it.

- [ ] **Step 6: Commit**

```bash
git add claude/skills/repo-recall/SKILL.md bin/dotfiles-tests claude/skills/repo-recall/scripts/tests/recall_test.sh
git commit -m "skills: Ship repo-recall skill and register its test suite"
```

---

## Verification at the branch gate

1. `bin/dotfiles-tests` passes, one more suite than the recorded baseline.
2. `ruff check claude/skills/repo-recall/scripts/` clean.
3. Acceptance smoke output from Task 8 Step 4 pasted into the PR description.
4. `co-review` on the branch diff (Claude + Codex) per the standing pipeline.

## Codex plan review, round 1 (2026-09-01)

Fifteen findings (one critical), verdict needs-rework. All folded in:
schema written only for fresh or rebuilt databases so an open never takes a
write lock (critical); lock / permission / I/O errors mapped to exits 7 and 6
in `main` and `search`; every directory level created 0700 and the index
file pre-created 0600; whitespace splitting of joined query terms; golden
validation completes before path checks, `added` must be `YYYY-MM-DD`, and
`eval add` reuses the validator; `missing-source` entries always miss;
`os.walk` traversal that prunes symlinked and excluded directories;
`SKILL.md` privacy exception; only raw-mode FTS5 parse errors map to exit 4;
corruption markers matched with `startswith`; fence tracking by marker
character and length; kind-change, tie-order and git-status tests added;
byte-wise slug; one-line usage errors with `--help` exiting 0; auto-column
snippets. Round 2 result is recorded below.

## Self-review against the spec

- Sources, precedence, eligibility, extra globs: Task 2 (+ Task 8 CLI case).
- Index location, routing, work dir creation, inside-repo rejection, repo id, permissions: Tasks 1 and 4.
- Data model, meta, schema version, chunking, ranking, ties: Tasks 3, 4, 5.
- Display paths: Task 2 (`display_path`), asserted in Task 5.
- Commands and exit codes: Tasks 4-7; usage validation in Tasks 5 and 7.
- Freshness, lock semantics, corruption narrowness: Tasks 4 and 5.
- Skill behaviour, golden capture, embeddings rule: Tasks 7 and 8.
- Spec testing items 1-12 map to: 1 -> T1/T5, 2 -> T3/T5, 3 -> T2/T8, 4 -> T4/T5, 5 -> T1/T5, 6 -> T1 unit, 7 -> T5, 8 -> T5, 9 -> T7, 10 -> T4, 11 -> T1, 12 -> T4/T5.
