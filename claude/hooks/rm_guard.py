#!/usr/bin/env python3
"""Hook to deny catastrophic `rm`/`rmdir` targets that a literal permission
rule cannot express.

Bash permission rules are literal, per-subcommand text patterns: they never
expand `~`/`$HOME`, never resolve a path relative to cwd, and cannot express
"any glob directly under root/home/.git". A deny-floor of literal strings
therefore misses `rm -rf /*`, `rm -rf ~/*`, `rm -rf $HOME/*`, `rm -rf .git/*`,
`rm -rf /etc`, compound commands (`cd / && rm -rf *`), shell-wrapped commands
(`sh -c 'rm -rf /*'`), brace-expanded targets (`rm -rf /{,bin}`), and variable
targets (`rm -rf "$X"`) -- see push_guard.py's docstring for the same class of
problem with git push. This hook resolves what a literal rule cannot: it
splits compound commands, unwraps shell/env/nice-style wrappers, shlex-parses
each `rm`/`rmdir` invocation, brace-expands and normalizes every target, and
denies the shapes that are actually catastrophic. A permissionDecision "ask"
could be auto-approved in auto permission mode, so the hook denies (exit 2)
instead.

Scope: this hook only recognizes `rm` and `rmdir` invocations (including
inside `sh -c`/`bash -c`/`zsh -c` wrappers). Other deleters (`find -delete`,
`xargs rm`, `gio trash`, etc.) and `rm` reached only via a pipe or command
substitution are not inspected; that residual is left to the classifier.

Runs before Bash tool calls. Fails open on any exception, and on any segment
that contains no `rm`/`rmdir` token.
"""

import json
import os
import re
import shlex
import sys

SEGMENT_OPERATORS = ";&|()\n"

PREFIX_WRAPPERS = ("env", "exec", "command", "nohup", "time", "xargs", "sudo", "nice")

SHELL_WRAPPERS = ("sh", "bash", "zsh")

REMOVE_COMMANDS = ("rm", "rmdir")

SYSTEM_PATHS = (
    "/etc", "/bin", "/usr", "/sbin", "/lib",
    "/System", "/Applications", "/private", "/var", "/opt",
)

# Directories that are legitimately covered by a SYSTEM_PATHS prefix only
# because macOS aliases them (/tmp -> /private/tmp, /var -> /private/var):
# scratch and mktemp cleanup here must stay allowed.
SCRATCH_EXCEPTIONS = ("/tmp", "/var/folders")

RECURSIVE_OR_FORCE_LONG = ("--recursive", "--force")

BRACE_GROUP = re.compile(r"^(.*)\{([^{}]+)\}(.*)$")


def basename(tok: str) -> str:
    return tok.rsplit("/", 1)[-1]


def is_env_assignment(tok: str) -> bool:
    return "=" in tok and not tok.startswith("-") and "/" not in tok.split("=")[0]


def strip_prefixes(tokens: list[str]) -> list[str]:
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if is_env_assignment(tok):
            i += 1
        elif basename(tok) in PREFIX_WRAPPERS:
            i += 1
        else:
            break
    return tokens[i:]


def tokenize(command: str) -> list[str]:
    """Tokenize the whole command in one quote-aware pass: `;`, `&`, `|`,
    `(`, `)` become their own tokens (so `&&`/`||` stay one token each)
    while quoted text -- including a `sh -c '...'` script containing those
    same characters -- stays intact as a single word token. A naive
    per-character regex split on the raw command text (the prior approach)
    would slice through a quoted script the same way it slices real segment
    separators, corrupting the extracted `-c` argument."""
    try:
        lexer = shlex.shlex(command, posix=True, punctuation_chars=SEGMENT_OPERATORS)
        lexer.whitespace_split = True
        # A bare newline separates commands like `;` does (e.g. a heredoc'd
        # multi-line script); punctuation_chars alone does not take effect
        # for it because shlex's default whitespace set consumes it first.
        lexer.whitespace = lexer.whitespace.replace("\n", "")
        return list(lexer)
    except ValueError:
        return command.split()


def split_segments(tokens: list[str]) -> list[list[str]]:
    """Split a token stream on `;`/`&`/`|` operator tokens; drop grouping
    `(`/`)` tokens so a subshell's contents are treated the same as an
    unparenthesized compound command (BF3: `(cd / && rm -rf *)`)."""
    segments = []
    current = []
    for tok in tokens:
        if tok and all(c in ";&|\n" for c in tok):
            if current:
                segments.append(current)
                current = []
        elif tok in ("(", ")"):
            continue
        else:
            current.append(tok)
    if current:
        segments.append(current)
    return segments


def expand_home(tok: str, home: str) -> str:
    m = re.match(r"^\$\{HOME\}(.*)$", tok) or re.match(r"^\$HOME(.*)$", tok)
    if m:
        return home + m.group(1)
    if tok == "~":
        return home
    if tok.startswith("~/"):
        return home + tok[1:]
    return tok


def expand_braces(tok: str) -> list[str]:
    """Expand one level of shell brace-list syntax (`{a,b,c}`), recursing so
    multiple non-nested groups in the same token all expand. Non-list groups
    (no comma, e.g. `{1..3}` ranges) are left literal, matching the common
    case this guard cares about: comma-separated alternatives."""
    m = BRACE_GROUP.match(tok)
    if not m:
        return [tok]
    prefix, body, suffix = m.groups()
    if "," not in body:
        return [tok]
    results = []
    for part in body.split(","):
        results.extend(expand_braces(prefix + part + suffix))
    return results


def canonicalize(path: str) -> str:
    """Lexically resolve macOS's `/tmp` and `/var` symlinks to their real
    `/private/...` location, without touching the filesystem, so a target
    and a SYSTEM_PATHS/SCRATCH_EXCEPTIONS entry compare equal regardless of
    which spelling was used."""
    if path == "/tmp" or path.startswith("/tmp/"):
        return "/private" + path
    if path == "/var" or path.startswith("/var/"):
        return "/private" + path
    return path


def resolve(tok: str, cwd: str) -> str:
    if tok.startswith("/"):
        path = os.path.normpath(tok)
    else:
        path = os.path.normpath(os.path.join(cwd, tok))
    # normpath preserves a leading "//" (POSIX allows it special meaning);
    # bash does not treat "//" specially, so collapse it to match root.
    return re.sub(r"^/{2,}", "/", path)


def has_glob_chars(name: str) -> bool:
    return any(c in name for c in "*?[")


def system_path_reason(path: str) -> str | None:
    canon_path = canonicalize(path)
    for exc in SCRATCH_EXCEPTIONS:
        canon_exc = canonicalize(exc)
        if canon_path == canon_exc or canon_path.startswith(canon_exc + "/"):
            return None
    for sys_path in SYSTEM_PATHS:
        canon_sys = canonicalize(sys_path)
        if canon_path == canon_sys or canon_path.startswith(canon_sys + "/"):
            return "target is a system path (%s)" % sys_path
    return None


def is_git_root(cwd: str) -> bool:
    try:
        return os.path.exists(os.path.join(cwd, ".git"))
    except OSError:
        return False


def denial_reason(path: str, has_unexpanded_var: bool, recursive_or_force: bool,
                   home: str, real_cwd: str, cwd: str) -> str | None:
    if has_unexpanded_var and recursive_or_force:
        return "target contains an unexpanded variable/command substitution"

    parent, name = os.path.split(path) if path != "/" else ("/", "")

    if path == "/" or (parent == "/" and has_glob_chars(name)):
        return "target is the filesystem root or a glob directly under it"

    if path == home or (parent == home and has_glob_chars(name)):
        return "target is the home directory or a glob directly under it"

    if name == ".git" or (basename(parent) == ".git" and has_glob_chars(name)):
        return "target is a .git directory or a glob directly under it"

    sys_reason = system_path_reason(path)
    if sys_reason:
        return sys_reason

    if real_cwd.startswith(path + "/") and path != real_cwd:
        return "target is a parent of the current working directory"

    if path == cwd and (cwd == home or is_git_root(cwd)):
        return "target is the current directory, which is a git worktree root or the home directory"

    return None


def rm_flag_is_recursive_or_force(tok: str) -> bool:
    if tok in RECURSIVE_OR_FORCE_LONG:
        return True
    if tok.startswith("-") and not tok.startswith("--"):
        return any(c in "rRf" for c in tok[1:])
    return False


def check_rm(tokens: list[str], cwd: str, home: str, real_cwd: str) -> str | None:
    """Return a denial reason for the `rm`/`rmdir` invocation `tokens`, or
    None."""
    recursive_or_force = any(rm_flag_is_recursive_or_force(t) for t in tokens[1:])
    targets = []
    only_targets = False
    for tok in tokens[1:]:
        if only_targets:
            targets.append(tok)
        elif tok == "--":
            only_targets = True
        elif tok.startswith("-") and tok != "-":
            continue
        else:
            targets.append(tok)

    for raw in targets:
        for candidate in expand_braces(raw):
            expanded = expand_home(candidate, home)
            has_unexpanded_var = "$" in expanded or "`" in expanded
            path = resolve(expanded, cwd)
            reason = denial_reason(path, has_unexpanded_var, recursive_or_force, home, real_cwd, cwd)
            if reason:
                return reason
    return None


def resolve_cd_target(tokens: list[str], cwd: str, home: str) -> str:
    if len(tokens) < 2 or tokens[1] == "-":
        return cwd
    return resolve(expand_home(tokens[1], home), cwd)


def extract_shell_c_arg(tokens: list[str]) -> str | None:
    """If `tokens` is a `sh`/`bash`/`zsh` invocation with a `-c <script>`
    argument, return the script string; else None."""
    i = 1
    while i < len(tokens):
        tok = tokens[i]
        if tok == "-c":
            return tokens[i + 1] if i + 1 < len(tokens) else None
        if tok.startswith("-"):
            i += 1
            continue
        break
    return None


def check_command(command: str, real_cwd: str, home: str, cwd: str | None = None) -> str | None:
    if cwd is None:
        cwd = real_cwd
    for tokens in split_segments(tokenize(command)):
        tokens = strip_prefixes(tokens)
        if not tokens:
            continue
        head = basename(tokens[0])
        if head in REMOVE_COMMANDS:
            reason = check_rm(tokens, cwd, home, real_cwd)
            if reason:
                return reason
        elif head == "cd":
            cwd = resolve_cd_target(tokens, cwd, home)
        elif head in SHELL_WRAPPERS:
            inner = extract_shell_c_arg(tokens)
            if inner is not None:
                reason = check_command(inner, real_cwd, home, cwd)
                if reason:
                    return reason
    return None


def main():
    try:
        data = json.load(sys.stdin)
        if data.get("tool_name", "") != "Bash":
            sys.exit(0)

        command = data.get("tool_input", {}).get("command", "")
        if not isinstance(command, str) or "rm" not in command:
            sys.exit(0)

        real_cwd = data.get("cwd") or os.getcwd()
        home = os.environ.get("HOME", os.path.expanduser("~"))

        reason = check_command(command, real_cwd, home)
        if not reason:
            sys.exit(0)

        print("Blocked: rm target is catastrophic -- " + reason + ".", file=sys.stderr)
        print(
            "Narrow the target to a specific file or subdirectory, or ask the "
            "user for explicit confirmation before removing it.",
            file=sys.stderr,
        )
        sys.exit(2)
    except Exception:
        # Fail open: a crashed guard must never block work.
        sys.exit(0)


if __name__ == "__main__":
    main()
