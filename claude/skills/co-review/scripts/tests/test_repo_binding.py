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


def resolver(alias, user=None, port=None):
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
        def override(alias, user=None, port=None):
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

    def test_ssh_scheme_original_case_host_resolves(self):
        self.assertEqual(
            rb.normalize_url("ssh://git@Git-Personal/owner/repo.git", resolver),
            "github.com/owner/repo",
        )

    def test_extra_path_segments_is_none(self):
        self.assertIsNone(rb.normalize_url("https://github.com/a/b/c"))

    def test_missing_path_segments_is_none(self):
        self.assertIsNone(rb.normalize_url("https://github.com/onlyone"))

    def test_empty_is_none(self):
        self.assertIsNone(rb.normalize_url(""))

    def test_percent_encoded_ssh_host_is_none(self):
        # git percent-decodes the authority before connecting, so a
        # percent-encoded host must be rejected rather than decoded and
        # matched: decoding here could resolve a different host than git
        # actually uses.
        self.assertIsNone(
            rb.normalize_url("ssh://git@%47it-Personal/owner/repo.git", resolver)
        )

    def test_percent_encoded_scp_host_is_none(self):
        self.assertIsNone(
            rb.normalize_url("git@%47it-Personal:owner/repo.git", resolver)
        )

    def test_malformed_port_is_none(self):
        # urlsplit(...).port raises ValueError for a non-numeric port; that
        # must be caught and treated as invalid, not propagate.
        self.assertIsNone(
            rb.normalize_url("ssh://git@github.com:notaport/owner/repo.git", resolver)
        )


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


class Check(unittest.TestCase):
    def test_match(self):
        ok, _ = rb.check(
            "git@Git-Personal:owner/repo.git",
            "https://github.com/owner/repo/pull/3",
            "owner/repo",
            resolver,
        )
        self.assertTrue(ok)

    def test_fork_mismatch(self):
        ok, msg = rb.check(
            "git@github.com:contributor/repo.git",
            "https://github.com/owner/repo/pull/3",
            "owner/repo",
            resolver,
        )
        self.assertFalse(ok)
        self.assertIn("mismatch", msg.lower())

    def test_bad_pr_url(self):
        ok, _ = rb.check(
            "git@github.com:owner/repo.git", "not-a-url", "owner/repo", resolver
        )
        self.assertFalse(ok)


class SshHost(unittest.TestCase):
    def test_extracts_hostname(self):
        def fake_run(cmd, **kw):
            class R:
                returncode = 0
                stdout = "user git\nhostname github.com\nport 22\n"
            return R()

        self.assertEqual(rb.ssh_host("Git-Personal", runner=fake_run), "github.com")

    def test_missing_hostname_is_none(self):
        def fake_run(cmd, **kw):
            class R:
                returncode = 0
                stdout = "user git\n"
            return R()

        self.assertIsNone(rb.ssh_host("X", runner=fake_run))

    def test_passes_user_and_port(self):
        seen = {}

        def fake_run(cmd, **kw):
            seen["cmd"] = cmd
            class R:
                returncode = 0
                stdout = "hostname github.com\n"
            return R()

        rb.ssh_host("github.com", user="git", port=2222, runner=fake_run)
        self.assertIn("-l", seen["cmd"])
        self.assertEqual(seen["cmd"][seen["cmd"].index("-l") + 1], "git")
        self.assertIn("-p", seen["cmd"])
        self.assertEqual(seen["cmd"][seen["cmd"].index("-p") + 1], "2222")
        self.assertEqual(seen["cmd"][-1], "github.com")


class ResolverParams(unittest.TestCase):
    def test_ssh_resolver_receives_user_and_port(self):
        seen = {}

        def capture(host, user=None, port=None):
            seen["args"] = (host, user, port)
            return "github.com"

        rb.normalize_url("ssh://git@github.com:2222/owner/repo.git", capture)
        self.assertEqual(seen["args"], ("github.com", "git", 2222))

    def test_scp_resolver_receives_user_no_port(self):
        seen = {}

        def capture(host, user=None, port=None):
            seen["args"] = (host, user, port)
            return "github.com"

        rb.normalize_url("git@Git-Personal:owner/repo.git", capture)
        self.assertEqual(seen["args"], ("Git-Personal", "git", None))

    def test_ssh_resolver_gets_original_case(self):
        # ssh config `Host` matching is case-sensitive, so normalize_url must
        # pass the host to the resolver unmodified, not lowercased.
        seen = {}

        def capture(host, user=None, port=None):
            seen["host"] = host
            return "github.com"

        rb.normalize_url("git@Git-Personal:owner/repo.git", capture)
        self.assertEqual(seen["host"], "Git-Personal")

    def test_ssh_resolver_gets_original_case_host(self):
        # Same guarantee for the ssh:// scheme form (not just scp-like).
        seen = {}

        def capture(host, user=None, port=None):
            seen["host"] = host
            return "github.com"

        rb.normalize_url("ssh://git@Git-Personal/owner/repo.git", capture)
        self.assertEqual(seen["host"], "Git-Personal")


class GitOrigin(unittest.TestCase):
    def test_strips_git_routing_env(self):
        import os

        seen = {}

        def fake_run(cmd, **kw):
            seen["kwargs"] = kw
            class R:
                returncode = 0
                stdout = "git@github.com:o/r.git\n"
            return R()

        os.environ["GIT_CONFIG_COUNT"] = "1"
        try:
            rb._git_origin("/some/repo", runner=fake_run)
        finally:
            del os.environ["GIT_CONFIG_COUNT"]

        self.assertIn("env", seen["kwargs"])
        env = seen["kwargs"]["env"]
        self.assertFalse(any(k.startswith("GIT_") for k in env))


class GhLookup(unittest.TestCase):
    def test_pins_hostname_github(self):
        seen = {}

        def fake_run(cmd, **kw):
            seen["cmd"] = cmd
            class R:
                returncode = 0
                stdout = "owner/repo\n"
            return R()

        full_name = rb._gh_base_full_name("owner", "repo", 3, runner=fake_run)
        self.assertEqual(full_name, "owner/repo")
        self.assertIn("--hostname", seen["cmd"])
        idx = seen["cmd"].index("--hostname")
        self.assertEqual(seen["cmd"][idx + 1], "github.com")

    def test_lookup_failure_raises(self):
        import subprocess as sp

        def fake_run(cmd, **kw):
            raise sp.CalledProcessError(1, cmd)

        with self.assertRaises(sp.CalledProcessError):
            rb._gh_base_full_name("owner", "repo", 3, runner=fake_run)


if __name__ == "__main__":
    unittest.main()
