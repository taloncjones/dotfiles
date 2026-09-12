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
_SCP_RE = re.compile(r"^(?:[^@/]+@)?(?P<host>[^/:]+):(?P<path>.+)$")
_PR_PATH_RE = re.compile(r"^/(?P<owner>[^/]+)/(?P<repo>[^/]+)/pull/(?P<num>\d+)/?$")


def _transport_host_path(url: str):
    """(transport, host, path). transport is 'ssh' (scp-like or ssh://) or
    'web' (https/http). None if the scheme is unsupported or the shape is
    unrecognized. Only an explicit allowlist of schemes is accepted, so
    file://, git://, or an arbitrary helper scheme is rejected outright.
    Transport matters: ssh config applies only to SSH, never to a web host."""
    if "://" in url:
        parts = urlsplit(url)
        host = parts.hostname or ""
        if not host:
            return None
        if parts.scheme == "ssh":
            return ("ssh", host, parts.path)
        if parts.scheme in ("https", "http"):
            return ("web", host, parts.path)
        return None  # file://, git://, unknown scheme
    scp = _SCP_RE.match(url)
    if scp:
        return ("ssh", scp.group("host"), scp.group("path"))
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
    transport, host, path = parsed
    host = host.lower()
    if transport == "ssh":
        # Resolve EVERY ssh host through ssh config, including a literal
        # 'github.com': a `Host github.com` / `HostName elsewhere` stanza would
        # otherwise let an origin that resolves off github.com pass.
        if host_resolver is None:
            return None
        resolved = host_resolver(host)
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
