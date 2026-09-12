"""Bind a local origin remote to a PR's base repository. Pure core + thin CLI.

The PR identity is supplied independently (a PR URL), never derived from origin,
so the check can actually detect a fork or a wrong remote. Normalization keeps
the host, so a same-named repo on another host cannot pass.
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from urllib.parse import urlsplit

_GITHUB = "github.com"
_SCP_RE = re.compile(r"^(?:(?P<user>[^@/]+)@)?(?P<host>[^/:]+):(?P<path>.+)$")
_PR_PATH_RE = re.compile(r"^/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<num>\d+)/?$")


def _transport_host_path(url: str):
    """(transport, host, user, port, path). transport is 'ssh' (scp-like or
    ssh://) or 'web' (https/http). None if the scheme is unsupported or the
    shape is unrecognized. Only an explicit allowlist of schemes is accepted, so
    file://, git://, or an arbitrary helper scheme is rejected outright.
    user/port are the SSH connection parameters (None for web / scp without a
    user or port); they must feed `ssh -G` so a user- or port-dependent
    `HostName` rewrite resolves the way git actually connects."""
    if "://" in url:
        parts = urlsplit(url)
        host = parts.hostname or ""
        if not host:
            return None
        if parts.scheme == "ssh":
            return ("ssh", host, parts.username, parts.port, parts.path)
        if parts.scheme in ("https", "http"):
            return ("web", host, None, None, parts.path)
        return None  # file://, git://, unknown scheme
    scp = _SCP_RE.match(url)
    if scp:
        return ("ssh", scp.group("host"), scp.group("user"), None, scp.group("path"))
    return None


def _owner_repo(path: str):
    segments = [s for s in path.strip("/").split("/") if s]
    if len(segments) != 2:
        return None
    owner, repo = segments
    if repo.endswith(".git"):
        repo = repo[:-4]
    if not owner or not repo:
        return None
    return (owner, repo)


def normalize_url(url: str, host_resolver=None) -> str | None:
    """Canonical lowercased 'github.com/owner/repo', or None (fail closed)."""
    url = (url or "").strip()
    if not url:
        return None
    parsed = _transport_host_path(url)
    if parsed is None:
        return None
    transport, host, user, port, path = parsed
    host = host.lower()
    if transport == "ssh":
        # Resolve EVERY ssh host through ssh config, including a literal
        # 'github.com', and with the URL's own user and port: a `Host github.com`
        # / `HostName elsewhere` stanza -- or a `Match user`/port-dependent one --
        # would otherwise let an origin that resolves off github.com pass.
        if host_resolver is None:
            return None
        resolved = host_resolver(host, user, port)
        if not resolved or resolved.lower() != _GITHUB:
            return None
    else:  # web: a real DNS host, no ssh config; must be literally github.com
        if host != _GITHUB:
            return None
    owner_repo = _owner_repo(path)
    if owner_repo is None:
        return None
    owner, repo = owner_repo
    return f"{_GITHUB}/{owner.lower()}/{repo.lower()}"


def parse_pr_url(url: str):
    """(host, owner, repo, number) for a github.com PR URL, else None."""
    url = (url or "").strip()
    parts = urlsplit(url)
    if parts.scheme not in ("https", "http") or (parts.hostname or "").lower() != _GITHUB:
        return None
    match = _PR_PATH_RE.match(parts.path)
    if not match:
        return None
    return (_GITHUB, match.group("owner").lower(), match.group("repo").lower(), int(match.group("num")))


def matches(a, b) -> bool:
    return bool(a) and bool(b) and a == b


def ssh_host(alias, user=None, port=None, runner=subprocess.run) -> str | None:
    """Real hostname via `ssh -G`, or None. Resolve with the URL's own user
    (-l) and port (-p) so a user/port-dependent HostName rewrite resolves the
    way git actually connects. Signature matches host_resolver(host, user, port).
    """
    cmd = ["ssh", "-G"]
    if user:
        cmd += ["-l", user]
    if port:
        cmd += ["-p", str(port)]
    cmd.append(alias)
    try:
        result = runner(cmd, capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0:
        return None
    for line in result.stdout.splitlines():
        if line.lower().startswith("hostname "):
            return line.split(None, 1)[1].strip()
    return None


def check(origin_url, pr_url, base_full_name, host_resolver):
    """(ok, message). ok only when origin binds to the PR's base repo."""
    pr = parse_pr_url(pr_url)
    if pr is None:
        return (False, f"unusable PR URL: {pr_url!r}")
    origin_id = normalize_url(origin_url, host_resolver)
    if origin_id is None:
        return (False, f"unusable origin URL: {origin_url!r}")
    base_id = normalize_url(f"https://github.com/{base_full_name}")
    if base_id is None:
        return (False, f"unusable base repo: {base_full_name!r}")
    if matches(origin_id, base_id):
        return (True, f"origin {origin_id} binds to PR base {base_id}")
    return (False, f"binding mismatch: origin {origin_id} != PR base {base_id}")


def _git_origin(repo: str, runner=subprocess.run) -> str:
    out = runner(
        ["git", "-C", repo, "remote", "get-url", "origin"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def _gh_base_full_name(owner: str, repo: str, number: int, runner=subprocess.run) -> str:
    # Pin the host: gh honors GH_HOST/enterprise defaults, and check() hardcodes
    # github.com onto the result, so an unpinned lookup off github.com could
    # validate a same-named repo on another host.
    out = runner(
        ["gh", "api", "--hostname", "github.com",
         f"repos/{owner}/{repo}/pulls/{number}",
         "-q", ".base.repo.full_name"],
        capture_output=True, text=True, check=True,
    )
    return out.stdout.strip()


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="repo_binding.py")
    ap.add_argument("--repo", required=True)
    ap.add_argument("--pr-url", required=True)
    args = ap.parse_args(argv)
    pr = parse_pr_url(args.pr_url)
    if pr is None:
        print(f"unusable PR URL: {args.pr_url!r}", file=sys.stderr)
        return 1
    _, owner, repo, number = pr
    try:
        origin_url = _git_origin(args.repo)
        base_full_name = _gh_base_full_name(owner, repo, number)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"lookup failed (fail closed): {error}", file=sys.stderr)
        return 1
    ok, message = check(origin_url, args.pr_url, base_full_name, ssh_host)
    print(message)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
