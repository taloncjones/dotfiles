#!/usr/bin/env python3
"""PreToolUse hook: deny git-metadata mutations aimed at a real checkout
in herdr sessions.

Incident 2026-09-07: a worker's fixture ran `( cd "$repo" && git remote
remove origin )` with `$repo` empty; `cd ""` succeeds in place, every herdr
worktree shares the main checkout's `.git`, and one bug deleted the origin
remote and every upstream stanza for every checkout at once. rm_guard.py
covers `rm`; this hook covers the git side of the same class.

Gate: decides only when HERDR_ENV=1 (herdr workers and orchestrators);
every other session exits 0 untouched. Matcher `Bash|Edit|Write`.

Denies (exit 2, two stderr lines naming the command and the fixture rule):
- `git remote remove|rm|set-url|rename|prune`, and `git config` writes to
  `remote.*`, `core.*`, `branch.<name>.remote|merge|pushremote` (or those
  sections, or any key when the option grammar is not recognized), unless
  every possible working directory is a fixture repository: a literal,
  existing directory under $TMPDIR or /tmp (never under HOME) whose git
  common dir is also under a temp root. `--global`/`--system` writes and
  `--git-dir`/`--work-tree` forms always deny.
- `git branch -d|-D` and `git worktree remove` of a branch or worktree
  listed in another orchestrated task's record (STATE_ROOT/*/tasks/*.json,
  status not merged/failed/abandoned; the session's own task, resolved
  through HERDR_WORKSPACE_ID, is exempt). Read-only: nothing is written.
- Write/Edit of `.git/config` or `.git/info/exclude` (by path or through a
  symlink) outside a temp root, and Bash redirections, tee, cp, mv,
  truncate, or sed -i into them.

Working directories are tracked as a SET: a `cd` may be skipped (`false &&
cd X; git ...`), undone by a subshell, or fabricated by a quoted operator,
so a mutation is allowed only when every possible directory is a fixture.

Override: `DOTFILES_ALLOW_GIT_META=1` as a leading env assignment on the
segment, after explicit user confirmation only.

Accepted holes: aliases, functions, and script files; `eval`; `$(...)`
and heredoc bodies (a heredoc line starting with a guarded command IS
scanned, so write such prose with the Write tool); `GIT_DIR=` env
assignments (stripped, not interpreted); arguments fed to `xargs git` via
stdin; shell control flow (`if`, `for`, `{ }`) is plain words to the walk;
bind mounts; a same-command re-point by a tool other than ln/mv/cp/rsync/
git worktree, or a concurrent one by another process; `cp .git/config
/tmp/backup` denies although it is a read.

Reuses rm_guard's tokenizer and helpers; fails open on any exception.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rm_guard

OVERRIDE = "DOTFILES_ALLOW_GIT_META=1"
UNTRUSTED = "$UNTRUSTED_CWD"  # non-literal sentinel: cwd cannot be established
OPERATOR_CHARS = ";&|()\n"
REMOTE_DENY = ("remove", "rm", "set-url", "rename", "prune")
GIT_OPTS_WITH_ARG = (
    "-C",
    "-c",
    "--git-dir",
    "--work-tree",
    "--namespace",
    "--config-env",
    "--attr-source",
    "--super-prefix",
)
GIT_VALUELESS_GLOBAL_OPTS = (
    "--no-pager",
    "--paginate",
    "-p",
    "-P",
    "--bare",
    "--no-replace-objects",
    "--no-lazy-fetch",
    "--literal-pathspecs",
    "--glob-pathspecs",
    "--noglob-pathspecs",
    "--icase-pathspecs",
    "--no-optional-locks",
    "--no-advice",
    "--html-path",
    "--man-path",
    "--info-path",
    "--version",
    "--help",
    "--exec-path",
)
LOCATION_OPTS = ("--git-dir", "--work-tree")
LOCATION_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR")
TAINT_HEADS = ("ln", "mv", "cp", "rsync")
TAINT_GIT_WORKTREE = ("add", "move", "repair")
# git config option tables; a write with an option outside them is guarded
CFG_VALUE = ("--file", "--blob", "--type", "--default", "--comment", "--value", "--url")
CFG_READ_VALUE = ("--get-color", "--get-colorbool")
CFG_WRITE = (
    "--add",
    "--replace-all",
    "--unset",
    "--unset-all",
    "--remove-section",
    "--rename-section",
    "--edit",
    "-e",
)
CFG_SECTION = ("--remove-section", "--rename-section")
CFG_READ = ("--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l")
CFG_SCOPE_OUTSIDE = ("--global", "--system")
CFG_FLAGS = (
    "--local",
    "--worktree",
    "--bool",
    "--int",
    "--bool-or-int",
    "--bool-or-str",
    "--path",
    "--expiry-date",
    "--fixed-value",
    "--all",
    "--append",
    "--includes",
    "--no-includes",
    "--null",
    "-z",
    "--name-only",
    "--show-origin",
    "--show-scope",
    "--show-names",
    "--no-show-names",
    "--",
)
CFG_WRITE_VERBS = ("set", "unset", "remove-section", "rename-section", "edit")
CFG_SECTION_VERBS = ("remove-section", "rename-section")
CFG_READ_VERBS = ("get", "list")
GUARDED_KEY = re.compile(
    r"^(remote(\..*)?|core(\..*)?|branch\..+\.(remote|merge|pushremote))$",
    re.IGNORECASE,
)
GUARDED_SECTION = re.compile(r"^(remote(\..*)?|core|branch\..+)$", re.IGNORECASE)
TERMINAL_STATUSES = frozenset({"merged", "failed", "abandoned"})
WRITER_HEADS = ("tee", "cp", "mv", "truncate", "sed")
REDIRECTS = (">", ">>", ">|", "1>", "2>", "1>>", "2>>", "&>", "&>>")
GIT_FILE = re.compile(r"(^|/)\.git/(config|info/exclude)$")
PATCH_FILE_HEADERS = re.compile(
    r"^\*\*\* (?:Update|Add|Delete) File: (.+)$|^\*\*\* Move (?:to|from): (.+)$",
    re.MULTILINE,
)
SEGMENT_MAX = 160
FIXTURE_RULE = (
    "Fixture repos only: pass a literal, existing path under ${TMPDIR:-/tmp} to git -C "
    "(resolve mktemp -d in a separate call; never cd into a variable that may be empty). "
    "With explicit user confirmation, prefix the command with " + OVERRIDE + "."
)


# --- paths -----------------------------------------------------------------


def canon(path: str) -> str:
    """Resolve symlinks while traversing the path, including before `..`."""
    return os.path.realpath(path)


def resolve_filesystem(path: str, cwd: str, home: str) -> str:
    """Resolve a user path from `cwd` with filesystem, not lexical, semantics.

    `normpath` before `realpath` turns `fixture/escape/..` into `fixture`
    without following `escape`. Git's `-C` and config-file paths traverse the
    symlink first, so guards must do the same.
    """
    return canon(raw_filesystem_path(path, cwd, home))


def raw_filesystem_path(
    path: str, cwd: str, home: str, *, expand_home: bool = True
) -> str:
    """Join `path` to `cwd` without lexical normalization or optional expansion."""
    expanded = rm_guard.expand_home(path, home) if expand_home else path
    return expanded if os.path.isabs(expanded) else os.path.join(cwd, expanded)


def tmp_roots(home_real: str) -> list:
    roots = []
    t = os.environ.get("TMPDIR") or ""
    if t and os.path.isabs(t):
        rp = os.path.realpath(t)
        shallow = len([c for c in rp.split("/") if c]) < 2
        if not (
            rp == "/" or rp == home_real or home_real.startswith(rp + "/") or shallow
        ):
            roots.append(rp)
    roots.append(os.path.realpath("/tmp"))
    return roots


def under_root(c: str, roots: list, home_real: str):
    """The temp root `c` sits under, or None. A path under HOME is never a
    fixture, whatever the roots say."""
    if c == home_real or c.startswith(home_real + "/"):
        return None
    for r in roots:
        if c.startswith(r + "/"):
            return r
    return None


def literal(tok: str) -> bool:
    return not ("$" in tok or "`" in tok or rm_guard.has_glob_chars(tok))


def fixture_dir(path: str, roots: list, home_real: str):
    """None when `path` is a fixture repository directory, else a reason."""
    c = canon(path)
    root = under_root(c, roots, home_real)
    if root is None:
        return "targets a checkout outside every temp root"
    if not os.path.isdir(c):
        return "fixture path does not exist yet (resolve mktemp -d in a separate call)"
    env = {k: v for k, v in os.environ.items() if k not in LOCATION_ENV}
    env["GIT_CEILING_DIRECTORIES"] = root
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    try:
        out = subprocess.run(
            ["git", "-C", c, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True,
            text=True,
            env=env,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return "fixture repository could not be resolved"
    if out.returncode != 0:
        return "fixture path is not inside a repository under the temp root"
    if under_root(canon(out.stdout.strip()), roots, home_real) is None:
        return (
            "fixture path is a linked worktree whose .git lives outside the temp root"
        )
    return None


def guarded_file(
    path: str,
    cwds: set,
    home: str,
    roots: list,
    home_real: str,
    taint: bool = False,
    direct_path: bool = False,
) -> bool:
    """True when `path` names .git/config or .git/info/exclude (directly or
    through a symlink) outside every temp root, for some possible cwd. Under
    taint (an earlier segment may re-point paths) the temp-root exemption is
    withdrawn: any matching path is guarded. Direct tool paths are literal
    filenames: shell expansion syntax has no special meaning in them."""
    if not direct_path and not literal(path):
        return False
    for cwd in cwds:
        base = cwd if direct_path or literal(cwd) else "/"
        p = raw_filesystem_path(path, base, home, expand_home=not direct_path)
        c = canon(p)
        if not (GIT_FILE.search(p) or GIT_FILE.search(c)):
            continue
        if taint or under_root(c, roots, home_real) is None:
            return True
    return False


def guarded_patch_file(patch: str, cwds: set, home: str, roots: list, home_real: str):
    """First guarded apply_patch file header, if any."""
    for match in PATCH_FILE_HEADERS.finditer(patch):
        path = next(value for value in match.groups() if value is not None)
        if guarded_file(path, cwds, home, roots, home_real, direct_path=True):
            return path
    return None


# --- tokens ----------------------------------------------------------------


def quoted_operator(command: str) -> bool:
    """True when an operator character is quoted or backslash-escaped: the
    tokenizer would turn it into a fake segment boundary."""
    quote = None
    i = 0
    n = len(command)
    while i < n:
        c = command[i]
        if quote:
            if quote == '"' and c == "\\" and i + 1 < n:
                if command[i + 1] in OPERATOR_CHARS:
                    return True
                i += 2
                continue
            if c == quote:
                quote = None
            elif c in OPERATOR_CHARS:
                return True
        elif c in ("'", '"'):
            quote = c
        elif c == "\\" and i + 1 < n:
            if command[i + 1] in OPERATOR_CHARS:
                return True
            i += 1
        i += 1
    return False


def normalize_operators(tokens: list) -> list:
    """Split operator runs into bare `(`/`)` and `;&|` runs (rm_guard's
    tokenizer yields `);` as one token), then re-join `>` `|` into `>|`."""
    out = []
    for tok in tokens:
        if tok and all(c in OPERATOR_CHARS for c in tok):
            run = ""
            for c in tok:
                if c in "()":
                    if run:
                        out.append(run)
                        run = ""
                    out.append(c)
                else:
                    run += c
            if run:
                out.append(run)
        else:
            out.append(tok)
    merged = []
    for tok in out:
        if tok == "|" and merged and merged[-1] == ">":
            merged[-1] = ">|"
        else:
            merged.append(tok)
    return merged


def is_operator(tok: str) -> bool:
    return bool(tok) and all(c in ";&|\n" for c in tok)


# --- git parsing -----------------------------------------------------------


def parse_git(tokens: list):
    """(subcommand, args, -C values in order, location-hint flag, unknown-option flag).

    A `-`-prefixed global option with its value embedded via `=` cannot shift
    which token is the subcommand, so it is skipped like any other flag.
    Known valueless globals (GIT_VALUELESS_GLOBAL_OPTS) are also skipped in
    place, since they never consume a separate argument. Any other
    `-`-prefixed option given as a separate argument is unrecognized and
    indistinguishable from a value-taking option whose value would otherwise
    be misread as the subcommand (git --attr-source HEAD remote remove
    origin), so `unknown` comes back True and the caller fails closed instead
    of trusting `subcommand`."""
    i = 1
    cdirs = []
    hints = False
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-C":
            if i + 1 < len(tokens):
                cdirs.append(tokens[i + 1])
            i += 2
            continue
        if tok in LOCATION_OPTS or tok.startswith(("--git-dir=", "--work-tree=")):
            hints = True
        if tok in GIT_OPTS_WITH_ARG:
            i += 2
            continue
        if tok in GIT_VALUELESS_GLOBAL_OPTS:
            i += 1
            continue
        if tok.startswith("-") and "=" not in tok:
            return None, tokens[i + 1 :], cdirs, hints, True
        if tok.startswith("-"):
            i += 1
            continue
        return tok, tokens[i + 1 :], cdirs, hints, False
    return None, [], cdirs, hints, False


def effective_dirs(cdirs: list, cwds: set, home: str):
    """Every possible effective directory after the -C values, or (None, reason)."""
    out = set()
    for cwd in cwds:
        d = cwd
        for c in cdirs:
            if not literal(c):
                return None, "working directory contains an unexpanded variable or glob"
            if c == "":
                continue  # git -C "" is a no-op
            d = resolve_filesystem(c, d, home)
        if not literal(d):
            return None, (
                "working directory cannot be established "
                "(unexpanded variable, quoted operator, or cd -)"
            )
        out.add(d)
    return out, None


def config_action(args: list):
    """(kind, keys, section_level, scope_outside, file_path, unknown_option)."""
    kind = None
    section = False
    scope_outside = False
    file_path = None
    unknown = False
    positionals = []
    i = 0
    while i < len(args):
        tok = args[i]
        if tok in CFG_VALUE or tok in CFG_READ_VALUE:
            if tok == "--file" and i + 1 < len(args):
                file_path = args[i + 1]
            if tok in CFG_READ_VALUE:
                kind = kind or "read"
            i += 2
            continue
        if tok == "-f":
            if i + 1 < len(args):
                file_path = args[i + 1]
            i += 2
            continue
        if tok.startswith("-f") and not tok.startswith("--") and len(tok) > 2:
            file_path = tok[2:]
        elif tok.startswith("--") and "=" in tok and tok.split("=", 1)[0] in CFG_VALUE:
            if tok.startswith("--file="):
                file_path = tok.split("=", 1)[1]
        elif tok in CFG_SCOPE_OUTSIDE:
            scope_outside = True
        elif tok in CFG_WRITE:
            kind = kind or "write"
            section = section or tok in CFG_SECTION
        elif tok in CFG_READ:
            kind = kind or "read"
        elif tok in CFG_FLAGS:
            pass
        elif tok.startswith("-") and tok != "-":
            unknown = True
        else:
            positionals.append(tok)
        i += 1
    if positionals and positionals[0] in CFG_WRITE_VERBS:
        kind = "write"
        section = positionals[0] in CFG_SECTION_VERBS
        positionals = positionals[1:]
    elif positionals and positionals[0] in CFG_READ_VERBS:
        kind = "read"
        positionals = positionals[1:]
    if kind is None:
        kind = "write" if len(positionals) >= 2 else "read"
    keys = positionals[:2] if section else positionals[:1]
    return kind, keys, section, scope_outside, file_path, unknown


def guarded_config(keys: list, section: bool, unknown: bool) -> bool:
    if unknown or not keys:
        return True
    pat = GUARDED_SECTION if section else GUARDED_KEY
    return any((not literal(k)) or pat.match(k) for k in keys)


def branch_delete_flag(args: list) -> bool:
    for a in args:
        if a in ("-d", "-D", "--delete"):
            return True
        if (
            a.startswith("-")
            and not a.startswith("--")
            and any(ch in "dD" for ch in a[1:])
        ):
            return True
    return False


# --- task records (read-only) -------------------------------------------------


def _core():
    import herdr_orch_core  # deferred: only R3 needs it (about 30 ms)

    return herdr_orch_core


def selected_state_root(cwds: set, runtime: str):
    """Select exactly one account-local state root from repository context.

    Synthetic fixture cwd values retain the legacy ambient root. A repository
    context never falls back across account roots: its policy selection is the
    same one used by the controller's claim-owner and write-task commands.
    """
    core = _core()
    bound_personal = os.environ.get("HERDR_PERSONAL")
    bound_account = os.environ.get("HERDR_ACCOUNT_ID")
    if (bound_personal is None) != (bound_account is None):
        return None
    if bound_personal is not None and bound_personal not in ("0", "1"):
        return None
    roots = set()
    for cwd in cwds:
        if not literal(cwd):
            continue
        try:
            context = core.repository_context(cwd)
            scope = core.account_scope(
                context["root"], runtime, personal=bound_personal == "1"
            )
        except (OSError, ValueError, subprocess.SubprocessError):
            continue
        if bound_account is not None and bound_account != scope["account_id"]:
            return None
        roots.add(core.account_payload_root(scope) / "herdr-orch")
    if not roots:
        return core.state_root()
    return roots.pop() if len(roots) == 1 else None


def own_task(root):
    """(repo_slug, task_id) of this session's task via HERDR_WORKSPACE_ID, or None."""
    core = _core()
    ws = os.environ.get("HERDR_WORKSPACE_ID", "")
    if not core.valid_workspace_id(ws):
        return None
    for idx in sorted(root.glob(f"*/workspaces/{ws}.json")):
        index = core.read_index(idx.parent.parent, ws)
        if index and isinstance(index.get("task_id"), str):
            return idx.parent.parent.name, index["task_id"]
    return None


def protected_records(cwds: set, runtime: str):
    """[(task_id, record)] for every non-terminal task that is not this
    session's own; sidecars, symlinks, and unreadable files are skipped."""
    core = _core()
    root = selected_state_root(cwds, runtime)
    if root is None:
        return None
    own = own_task(root)
    out = []
    for p in sorted(root.glob("*/tasks/*.json")):
        tid = p.name[:-5]
        if not core.valid_task_id(tid) or p.is_symlink():
            continue
        try:
            with open(p) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(rec, dict) or rec.get("status") in TERMINAL_STATUSES:
            continue
        if (p.parent.parent.name, tid) == own:
            continue
        out.append((tid, rec))
    return out


def protected_branch(name: str, cwds: set, runtime: str):
    records = protected_records(cwds, runtime)
    if records is None:
        return "(unresolved)", "account selection cannot be verified"
    recs = [(t, r) for t, r in records if isinstance(r.get("branch"), str)]
    if not literal(name):
        return (
            ("(unresolved)", f"{len(recs)} protected task branches exist")
            if recs
            else None
        )
    name = name.removeprefix("refs/heads/")
    if name in ("@", "HEAD") or name.startswith("@{"):
        return (
            ("(unresolved)", f"{len(recs)} protected task branches exist")
            if recs
            else None
        )
    for tid, rec in recs:
        if rec["branch"] == name:
            return tid, rec.get("status")
    return None


def protected_worktree(tok: str, cwds: set, account_cwds: set, home: str, runtime: str):
    records = protected_records(account_cwds, runtime)
    if records is None:
        return "(unresolved)", "account selection cannot be verified"
    recs = [
        (t, r)
        for t, r in records
        if isinstance(r.get("worktree"), str) and r["worktree"]
    ]
    if not literal(tok):
        return (
            ("(unresolved)", f"{len(recs)} protected task worktrees exist")
            if recs
            else None
        )
    targets = {resolve_filesystem(tok, cwd, home) for cwd in cwds if literal(cwd)}
    unknown_cwd = any(not literal(cwd) for cwd in cwds)
    suffix = tok.strip("/")
    for tid, rec in recs:
        wc = canon(rec["worktree"])
        if wc in targets:
            return tid, rec.get("status")
        if not tok.startswith("/") and (
            unknown_cwd or (suffix and wc.endswith("/" + suffix))
        ):
            return tid, rec.get("status")
    return None


# --- rules -----------------------------------------------------------------


def check_git(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    sub, args, cdirs, hints, unknown_opt = parse_git(tokens)
    seg = " ".join(tokens)[:SEGMENT_MAX]
    if unknown_opt:
        return f"an unrecognized global git option precedes the subcommand, so it cannot be verified as unguarded -- {seg}"
    fpath = None
    if sub == "remote":
        rargs = [a for a in args if not a.startswith("-")]
        if not rargs or rargs[0] not in REMOTE_DENY:
            return None
        what = f"git remote {rargs[0]} rewrites the shared .git/config of this checkout"
    elif sub == "config":
        kind, keys, section, outside, fpath, unknown = config_action(args)
        if kind != "write" or not guarded_config(keys, section, unknown):
            return None
        key = keys[0] if keys else "(whole file)"
        if unknown:
            key += " (unrecognized option, treated as guarded)"
        if outside:
            return f"git config --global/--system write to {key} edits the user's git config -- {seg}"
        if fpath is not None:
            what = f"git config --file write to {key} targets a config outside the temp root"
        else:
            what = f"git config write to {key} rewrites the shared .git/config of this checkout"
    elif sub == "branch":
        if not branch_delete_flag(args):
            return None
        for name in [a for a in args if not a.startswith("-")]:
            hit = protected_branch(name, ctx["account_cwds"], ctx["runtime"])
            if hit:
                return (
                    f"git branch delete of {name} targets the branch of orchestrated "
                    f"task {hit[0]} ({hit[1]}) -- {seg}"
                )
        return None
    elif sub == "worktree" and args and args[0] == "remove":
        dirs, reason = effective_dirs(cdirs, cwds, home)
        if dirs is None:
            recs = protected_records(ctx["account_cwds"], ctx["runtime"])
            if recs is None:
                return (
                    f"git worktree remove cannot verify its account selection -- {seg}"
                )
            if recs:
                return (
                    f"git worktree remove cannot resolve its working directory ({reason}) "
                    f"while {len(recs)} orchestrated tasks are protected -- {seg}"
                )
            return None
        for tok in [a for a in args[1:] if not a.startswith("-")]:
            hit = protected_worktree(
                tok, dirs, ctx["account_cwds"], home, ctx["runtime"]
            )
            if hit:
                return (
                    f"git worktree remove of {tok} targets the worktree of orchestrated "
                    f"task {hit[0]} ({hit[1]}) -- {seg}"
                )
        return None
    else:
        return None
    if hints:
        return f"{what} (--git-dir/--work-tree forms are not accepted; use git -C) -- {seg}"
    if ctx["taint"]:
        return (
            f"{what} (an earlier segment can re-point the fixture path before git runs; "
            f"run it as a separate call) -- {seg}"
        )
    if sub == "config" and fpath is not None:
        dirs, _ = effective_dirs(cdirs, cwds, home)
        if (
            literal(fpath)
            and dirs
            and all(
                under_root(resolve_filesystem(fpath, d, home), roots, home_real)
                for d in dirs
            )
        ):
            return None
        return f"{what} -- {seg}"
    dirs, reason = effective_dirs(cdirs, cwds, home)
    if dirs is None:
        return f"{what} ({reason}) -- {seg}"
    for d in sorted(dirs):
        reason = fixture_dir(d, roots, home_real)
        if reason:
            return f"{what} ({reason}) -- {seg}"
    return None


def check_redirects(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    taint = ctx["taint"]
    seg = " ".join(tokens)[:SEGMENT_MAX]
    for i, tok in enumerate(tokens):
        if (
            tok in REDIRECTS
            and i + 1 < len(tokens)
            and guarded_file(tokens[i + 1], cwds, home, roots, home_real, taint)
        ):
            return (
                f"redirection into {tokens[i + 1]} edits git metadata shared by every "
                f"linked worktree -- {seg}"
            )
        for r in REDIRECTS:
            if (
                tok.startswith(r)
                and len(tok) > len(r)
                and guarded_file(tok[len(r) :], cwds, home, roots, home_real, taint)
            ):
                return (
                    f"redirection into {tok[len(r) :]} edits git metadata shared by every "
                    f"linked worktree -- {seg}"
                )
    return None


def check_writers(tokens: list, ctx: dict):
    cwds, home, roots, home_real = ctx["P"], ctx["home"], ctx["roots"], ctx["home_real"]
    head = rm_guard.basename(tokens[0])
    if head not in WRITER_HEADS:
        return None
    if head == "sed" and not any(
        t == "--in-place"
        or t.startswith("--in-place=")
        or (t.startswith("-i") and not t.startswith("--"))
        for t in tokens[1:]
    ):
        return None
    seg = " ".join(tokens)[:SEGMENT_MAX]
    for tok in tokens[1:]:
        if not tok.startswith("-") and guarded_file(
            tok, cwds, home, roots, home_real, ctx["taint"]
        ):
            return f"{head} on {tok} edits git metadata shared by every linked worktree -- {seg}"
    return None


def is_taint(tokens: list) -> bool:
    head = rm_guard.basename(tokens[0])
    if head in TAINT_HEADS:
        return True
    if head == "git":
        sub, args, _, _, _ = parse_git(tokens)
        return sub == "worktree" and bool(args) and args[0] in TAINT_GIT_WORKTREE
    return False


def cd_target(tokens: list, cwd: str, home: str) -> str:
    if len(tokens) < 2:
        return home
    if tokens[1] == "-":
        return UNTRUSTED
    return rm_guard.resolve_cd_target(tokens, cwd, home)


# --- the walk ---------------------------------------------------------------


class Chain:
    """Possible-cwd bookkeeping for one run of segments between unconditional
    boundaries (`;`, newline, `&`, `(`, `)`, start, end)."""

    def __init__(self, start: set):
        self.start = set(start)
        self.first_cd = None  # target of a cd that opened the chain (always runs)
        self.cds = []  # targets of later cds (may be skipped)
        self.pure = True  # every joiner so far is &&
        self.first = True  # no segment consumed yet

    def possible(self) -> set:
        if self.pure:
            if self.cds:
                return {self.cds[-1]}
            if self.first_cd is not None:
                return {self.first_cd}
            return set(self.start)
        base = {self.first_cd} if self.first_cd is not None else set(self.start)
        return base | set(self.cds)

    def after(self) -> set:
        """Possible cwds once the chain has ended (a later cd may have been skipped)."""
        base = {self.first_cd} if self.first_cd is not None else set(self.start)
        return base | set(self.cds)

    def record_cd(self, target: str) -> None:
        if self.first:
            self.first_cd = target
        else:
            self.cds.append(target)


def check_command(
    command: str,
    real_cwd: str,
    home: str,
    roots: list,
    home_real: str,
    cwds=None,
    taint_box=None,
    runtime: str = "claude",
    account_cwds=None,
):
    """Denial reason for `command`, or None. `taint_box` is a one-element
    list shared across wrapper recursion: taint set inside `sh -c` reaches
    the caller and vice versa; cwd state stays scoped to each script."""
    account_cwds = set(account_cwds) if account_cwds is not None else {real_cwd}
    start = set(cwds) if cwds is not None else set(account_cwds)
    if quoted_operator(command):
        start = {UNTRUSTED}
    if taint_box is None:
        taint_box = [False]
    ctx = {
        "P": set(start),
        "home": home,
        "roots": roots,
        "home_real": home_real,
        "taint": taint_box[0],
        "runtime": runtime,
        "account_cwds": account_cwds,
    }
    tokens = normalize_operators(rm_guard.tokenize(command))
    chain = Chain(start)
    stack = []
    current = []

    def set_taint():
        taint_box[0] = True
        ctx["taint"] = True

    def evaluate(raw: list, term: str):
        """Shell-state effects (cd, taint) apply whatever the override says;
        only the denial checks are suppressed by it."""
        ctx["P"] = chain.possible()
        ctx["taint"] = taint_box[0]
        stripped = rm_guard.strip_prefixes(raw)
        overridden = OVERRIDE in raw[: len(raw) - len(stripped)]
        head = rm_guard.basename(stripped[0]) if stripped else ""
        if head == "cd" and term not in ("|", "&"):
            targets = {
                cd_target(stripped, cwd, home) if literal(cwd) else UNTRUSTED
                for cwd in ctx["P"]
            }
            chain.record_cd(next(iter(targets)) if len(targets) == 1 else UNTRUSTED)
        reason = None
        if (
            overridden
            or (reason := check_redirects(raw, ctx)) is not None
            or not stripped
            or head == "cd"
        ):
            pass
        elif head in rm_guard.SHELL_WRAPPERS:
            inner = rm_guard.extract_shell_c_arg(stripped)
            if inner is not None:
                reason = check_command(
                    inner,
                    real_cwd,
                    home,
                    roots,
                    home_real,
                    ctx["P"],
                    taint_box,
                    runtime,
                    ctx["account_cwds"],
                )
        elif head == "git":
            reason = check_git(stripped, ctx)
        else:
            reason = check_writers(stripped, ctx)
        if stripped and is_taint(stripped):
            set_taint()
        chain.first = False
        return reason

    def apply_term(term: str):
        nonlocal chain
        if term in (";", "\n", "", "&"):
            chain = Chain(chain.after())
        elif term == "||":
            chain.pure = False

    def flush(term: str):
        """Evaluate the pending segment (if any), then apply the terminator's
        chain effect even when no segment was pending: the `;` after a `)`
        must still end the chain."""
        reason = None
        if current:
            raw = list(current)
            current.clear()
            reason = evaluate(raw, term)
        apply_term(term)
        return reason

    for tok in tokens:
        if tok == "(":
            if current:  # not valid shell; evaluate what is there without a reset
                if (reason := evaluate(list(current), "&&")) is not None:
                    return reason
                current.clear()
            stack.append(chain)
            chain = Chain(chain.possible())
        elif tok == ")":
            if (reason := flush("")) is not None:
                return reason
            if stack:
                chain = stack.pop()
                chain.first = False
        elif is_operator(tok):
            if (reason := flush(tok)) is not None:
                return reason
        else:
            current.append(tok)
    return flush("")


# --- entry -------------------------------------------------------------------


def decide(data: dict):
    tool = data.get("tool_name") or data.get("toolName") or ""
    lowered = tool.lower() if isinstance(tool, str) else ""
    tool_input = data.get("tool_input") or data.get("toolInput") or {}
    home = os.environ.get("HOME", os.path.expanduser("~"))
    home_real = os.path.realpath(home)
    roots = tmp_roots(home_real)
    payload_cwd = data.get("cwd")
    cwd = payload_cwd if isinstance(payload_cwd, str) and payload_cwd else os.getcwd()
    if isinstance(tool_input, str):
        if lowered == "apply_patch":
            path = guarded_patch_file(tool_input, {cwd}, home, roots, home_real)
            if path is not None:
                return f"{tool} to {path} edits git metadata shared by every linked worktree"
        return None
    if not isinstance(tool_input, dict):
        return None
    nested = tool_input.get("args")
    inputs = [tool_input] + ([nested] if isinstance(nested, dict) else [])
    tool_cwd = next(
        (
            value
            for item in inputs
            for key in ("workdir", "cwd")
            if isinstance(value := item.get(key), str) and value
        ),
        None,
    )
    if tool_cwd is not None:
        cwd = resolve_filesystem(tool_cwd, cwd, home)
    if lowered in rm_guard.SHELL_TOOLS:
        command = next(
            (
                value
                for item in inputs
                for key in ("command", "cmd")
                if isinstance(value := item.get(key), str)
            ),
            None,
        )
        if isinstance(command, str) and command.strip():
            runtime = (
                "codex"
                if lowered in ("exec_command", "shell_command", "unified_exec")
                else "claude"
            )
            return check_command(command, cwd, home, roots, home_real, runtime=runtime)
        return None
    if lowered in ("write", "edit", "multiedit"):
        path = next(
            (
                value
                for item in inputs
                for key in ("file_path", "filePath", "path")
                if isinstance(value := item.get(key), str)
            ),
            None,
        )
        if isinstance(path, str) and guarded_file(
            path, {cwd}, home, roots, home_real, direct_path=True
        ):
            return (
                f"{tool} to {path} edits git metadata shared by every linked worktree"
            )
    if lowered == "apply_patch":
        patch = next(
            (
                value
                for item in inputs
                for key in ("input", "patch")
                if isinstance(value := item.get(key), str)
            ),
            None,
        )
        if isinstance(patch, str):
            path = guarded_patch_file(patch, {cwd}, home, roots, home_real)
            if path is not None:
                return f"{tool} to {path} edits git metadata shared by every linked worktree"
    return None


def main() -> int:
    if os.environ.get("HERDR_ENV") != "1":
        return 0
    try:
        data = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if not isinstance(data, dict):
        return 0
    reason = decide(data)
    if not reason:
        return 0
    print("Blocked: " + reason + ".", file=sys.stderr)
    print(FIXTURE_RULE, file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # noqa: BLE001 -- fail open: a crashed guard never blocks work
        sys.exit(0)
