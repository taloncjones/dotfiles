"""Tests for repo_binding pure core."""
from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SRC = Path(__file__).resolve().parents[1] / "repo_binding.py"
_spec = importlib.util.spec_from_file_location("repo_binding", SRC)
rb = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(rb)

# A real ssh config resolves github.com to itself; aliases map to github.com.
ALIASES = {"github.com": "github.com", "git-personal": "github.com", "gh-work": "github.com"}


def resolver(alias):
    return ALIASES.get(alias.lower())


class NormalizeUrl(unittest.TestCase):
    def test_https(self):
        self.assertEqual(
            rb.normalize_url("https://github.com/Owner/Repo.git"),
            "github.com/owner/repo",
        )

    def test_https_no_suffix(self):
        self.assertEqual(
            rb.normalize_url("https://github.com/owner/repo"),
            "github.com/owner/repo",
        )

    def test_scp_github_resolves(self):
        # Even a literal github.com SSH host is resolved through ssh config.
        self.assertEqual(
            rb.normalize_url("git@github.com:owner/repo.git", resolver),
            "github.com/owner/repo",
        )

    def test_ssh_scheme_resolves(self):
        self.assertEqual(
            rb.normalize_url("ssh://git@github.com/owner/repo.git", resolver),
            "github.com/owner/repo",
        )

    def test_ssh_github_hostname_override_is_none(self):
        # `Host github.com` / `HostName elsewhere`: literal token is github.com
        # but it resolves off github.com, so it must be rejected.
        def override(alias):
            return "another.example" if alias.lower() == "github.com" else None

        self.assertIsNone(
            rb.normalize_url("git@github.com:owner/repo.git", override)
        )

    def test_ssh_alias_resolved(self):
        self.assertEqual(
            rb.normalize_url("git@Git-Personal:owner/repo.git", resolver),
            "github.com/owner/repo",
        )

    def test_ssh_alias_unresolved_is_none(self):
        self.assertIsNone(rb.normalize_url("git@Unknown:owner/repo.git", resolver))

    def test_ssh_without_resolver_is_none(self):
        # SSH always needs a resolver now (even for a literal github.com host).
        self.assertIsNone(rb.normalize_url("git@github.com:owner/repo.git"))

    def test_https_alias_host_not_resolved(self):
        # An ssh alias must NOT resolve for an HTTPS host: HTTPS uses DNS, not
        # ssh config. A resolver that maps 'git-personal' cannot rescue it.
        self.assertIsNone(rb.normalize_url("https://git-personal/owner/repo", resolver))

    def test_file_scheme_is_none(self):
        self.assertIsNone(rb.normalize_url("file://github.com/owner/repo", resolver))

    def test_git_scheme_is_none(self):
        self.assertIsNone(rb.normalize_url("git://github.com/owner/repo", resolver))

    def test_ssh_scheme_alias_resolved(self):
        self.assertEqual(
            rb.normalize_url("ssh://git@git-personal/owner/repo.git", resolver),
            "github.com/owner/repo",
        )

    def test_non_github_host_is_none(self):
        self.assertIsNone(rb.normalize_url("git@gitlab.com:owner/repo.git"))

    def test_extra_path_segments_is_none(self):
        self.assertIsNone(rb.normalize_url("https://github.com/a/b/c"))

    def test_missing_path_segments_is_none(self):
        self.assertIsNone(rb.normalize_url("https://github.com/onlyone"))

    def test_empty_is_none(self):
        self.assertIsNone(rb.normalize_url(""))


class ParsePrUrl(unittest.TestCase):
    def test_ok(self):
        self.assertEqual(
            rb.parse_pr_url("https://github.com/Owner/Repo/pull/42"),
            ("github.com", "owner", "repo", 42),
        )

    def test_trailing_slash(self):
        self.assertEqual(
            rb.parse_pr_url("https://github.com/owner/repo/pull/7/"),
            ("github.com", "owner", "repo", 7),
        )

    def test_non_github_is_none(self):
        self.assertIsNone(rb.parse_pr_url("https://gitlab.com/o/r/pull/1"))

    def test_malformed_is_none(self):
        self.assertIsNone(rb.parse_pr_url("https://github.com/owner/repo"))


class Matches(unittest.TestCase):
    def test_equal(self):
        self.assertTrue(rb.matches("github.com/o/r", "github.com/o/r"))

    def test_none_never_matches(self):
        # normalize_url would already reject non-github, but matches must also
        # fail-close on any None input.
        self.assertFalse(rb.matches(None, "github.com/o/r"))
        self.assertFalse(rb.matches("github.com/o/r", None))

    def test_fork_owner_differs(self):
        self.assertFalse(rb.matches("github.com/fork/r", "github.com/base/r"))


if __name__ == "__main__":
    unittest.main()
