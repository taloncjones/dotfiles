#!/usr/bin/env python3
"""Exec-time half of the herdr PR post gate: runs in place of `gh`.

bin/herdr-shims/gh execs this with its own path and the final argv, after
the shell has done all quoting, substitution and continuation -- the shapes
four review rounds used to hide a write from pr_post_guard.py's text hook.
Classification and the draft state are pr_post_guard's; this file finds the
real gh, reads the target PR's author (cached per session), decides the
audience, spends an approved draft for a gated call, checks a delete targets
our own marker, prints an [INFO] notice for each work-repo write it lets
through, and execs.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "skills" / "co-review" / "scripts"))
import pr_post_guard
from pr_ready_gate import MARKER_PREFIX

OWNERSHIP_READ_TIMEOUT = 30


def real_gh() -> str | None:
    """DOTFILES_REAL_GH, else the first gh on PATH that is not a shim. Any
    shim copy is skipped by content, so no PATH layout can exec-loop."""
    override = os.environ.get("DOTFILES_REAL_GH")
    if override:
        return override if _runnable(override) else None
    for entry in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(entry, "gh")
        if entry and _runnable(candidate):
            return candidate
    return None


def _runnable(path: str) -> bool:
    return os.path.isfile(path) and os.access(path, os.X_OK) and not pr_post_guard.is_shim(path)


def delete_target(args: list[str]) -> tuple[str | None, str | None]:
    """(path, hostname) of a `gh api ... DELETE <path>` argv."""
    _method, path, host, _field = pr_post_guard.parse_api(args[args.index("api") + 1:])
    return path, host


def _fetch_env() -> dict[str, str]:
    """The caller's env, including token and host, with gh's output forced
    plain: a TTY or color override would corrupt the JSON (spec R5)."""
    env = dict(os.environ)
    env.pop("GH_FORCE_TTY", None)
    env.pop("CLICOLOR_FORCE", None)
    env["NO_COLOR"] = "1"
    env["GH_PAGER"] = "cat"
    return env


def _gh_json(target: str, argv: list[str]):
    done = subprocess.run(
        [target, *argv], capture_output=True, text=True, env=_fetch_env(),
        timeout=OWNERSHIP_READ_TIMEOUT, check=True,
    )
    return json.loads(done.stdout)


def own_marker(target: str, args: list[str]) -> bool:
    """A delete may remove only this account's own co-review marker (review
    finding 5): its author is the authenticated user and its body starts
    with the marker. Any read failure refuses."""
    path, host = delete_target(args)
    if not path:
        return False
    extra = ["--hostname", host] if host else []
    try:
        comment = _gh_json(target, ["api", path, *extra])
        me = _gh_json(target, ["api", "user", *extra])
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    if not isinstance(comment, dict) or not isinstance(me, dict):
        return False
    user = comment.get("user")
    login = user.get("login") if isinstance(user, dict) else None
    body = comment.get("body")
    return (
        isinstance(login, str) and login == me.get("login")
        and isinstance(body, str) and body.startswith(MARKER_PREFIX)
    )


NOTICES = {"maintenance": "self-maintenance", "green": "green evidence", "own-comment": "own-PR comment"}


def notice(text: str) -> None:
    print(f"gh shim: [INFO] {text}", file=sys.stderr)


def read_cache(path) -> dict:
    data = pr_post_guard.read_json(path) if path else None
    if isinstance(data, dict) and data.get("v") == 2 and isinstance(data.get("repos"), dict):
        return data
    return {"v": 2, "repos": {}}


def write_cache(path, cache: dict) -> None:
    if path is None:
        return
    try:
        pr_post_guard.write_atomic(path, json.dumps(cache))
    except OSError:
        pass  # a lost cache entry only costs a re-read


def own_pr(target: str, args: list[str], cwd: str) -> bool:
    """True when this account authored the PR a post or body call targets:
    one cached `gh pr view --json author,url` read per PR and target context,
    and one `gh api user` per host (the PR url's host, as own_marker threads
    --hostname). Any failure is False, which gates the call."""
    i, _j = pr_post_guard.subcommand_index(args)
    if i < len(args) and args[i] == "api" and "://" in (pr_post_guard.parse_api(args[i + 1:])[1] or ""):
        return False  # a full-URL endpoint names its own host; never assume it is ours
    selector, slug = pr_post_guard.pr_target(args)
    pr_key = selector or "branch:" + pr_post_guard.git_output(cwd, "rev-parse", "--abbrev-ref", "HEAD").strip()
    sid = pr_post_guard.shim_session_id()
    path = pr_post_guard.gate_dir() / f"{sid}.authors.json" if sid else None
    cache = read_cache(path)
    key = pr_post_guard.repo_key(args, cwd)
    entry = cache["repos"].get(key)
    if not isinstance(entry, dict) or not isinstance(entry.get("prs"), dict) or not isinstance(entry.get("logins"), dict):
        entry = cache["repos"][key] = {"logins": {}, "prs": {}}
    record = entry["prs"].get(pr_key)
    try:
        if not isinstance(record, dict):
            view = ["pr", "view", *([selector] if selector else []), "--json", "author,url"]
            data = _gh_json(target, view + (["-R", slug] if slug else []))
            record = {"author": data.get("author").get("login"), "host": urlparse(data.get("url")).hostname}
        author, host = record.get("author"), record.get("host")
        if not isinstance(author, str) or not isinstance(host, str):
            return False
        login = entry["logins"].get(host)
        if not isinstance(login, str):
            login = _gh_json(target, ["api", "user", "--hostname", host]).get("login")
    except (OSError, ValueError, AttributeError, TypeError, subprocess.SubprocessError):
        return False
    if not isinstance(login, str):
        return False
    entry["prs"][pr_key] = record
    entry["logins"][host] = login
    write_cache(path, cache)
    return author == login


def gate(args: list[str], target: str) -> str | None:
    """Denial text, or None to exec. A work-repo post, body or reply that
    passes gets its [INFO] notice first."""
    kind = pr_post_guard.classify_gh(args)
    cwd = os.getcwd()
    if kind not in ("post", "body", "reply") or pr_post_guard.exempt_from_go(args, cwd):
        return None
    body = pr_post_guard.post_body(args, cwd)
    own = kind != "reply" and body[0] != "unreadable" and own_pr(target, args, cwd)
    verdict = pr_post_guard.audience(kind, own, body)
    where = f"PR {pr_post_guard.pr_target(args)[0] or '(current branch)'}"
    if verdict != "gated":
        notice(f"{NOTICES[verdict]} on {where}")
        return None
    sid = pr_post_guard.shim_session_id()
    digest = pr_post_guard.draft_hash(args, cwd)
    if sid and digest and pr_post_guard.spend_draft(pr_post_guard.gate_dir(), sid, digest):
        notice(f"approved draft {digest} on {where}")
        return None
    denial = pr_post_guard.gated_denial(pr_post_guard.gated_reason(kind, own, body), args)
    if sid and digest and pr_post_guard.draft_path(pr_post_guard.gate_dir(), sid, digest, "spent").exists():
        denial += (
            "\n[WARNING] this exact command already ran once under an earlier go; "
            "read the PR first: a duplicate is possible."
        )
    return denial


def main(argv: list[str]) -> int:
    args = argv[2:]
    target = real_gh()
    if target is None:
        print("gh shim: real gh not found on PATH", file=sys.stderr)
        return 127
    reason = gate(args, target)
    if reason:
        print(f"gh shim: {reason}", file=sys.stderr)
        return 1
    if pr_post_guard.classify_gh(args) == "delete":
        if not own_marker(target, args):
            print(
                "gh shim: Blocked: a delete may only remove this account's own co-review marker comment.",
                file=sys.stderr,
            )
            return 1
        if not pr_post_guard.exempt_from_go(args, os.getcwd()):
            notice(f"own marker delete {delete_target(args)[0]}")
    os.execv(target, ["gh", *args])
    return 127  # unreachable: execv replaces this process or raises


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as exc:  # noqa: BLE001 -- fail closed: never exec on error
        print(f"gh shim: Blocked: internal error ({type(exc).__name__}).", file=sys.stderr)
        sys.exit(1)
