"""Tests for the Codex usage-limit marker and automatic-substitute helper."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

HELPER = Path(__file__).resolve().parents[1] / "codex_quota.py"
AT = ("You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage "
      "to purchase more credits or try again at Oct 3rd, 2026 10:10 AM.")
IN2 = "You've hit your usage limit. Upgrade to Pro or try again in 2 days."
BARE = "You've hit your usage limit."
FAR = "You've hit your usage limit. Try again at Dec 31st, 2026 10:10 AM."
NOW = datetime(2026, 9, 29, 22, 55, tzinfo=timezone.utc)
OK_CODEX = {"runtime": "codex", "status": "success", "result": "ok", "errors": []}
OK_CLAUDE = {"runtime": "claude", "status": "success", "result": "ok", "errors": []}
AUTH = {"runtime": "codex", "status": "error", "result": None, "errors": ["AuthRequired"]}


def limit(notice, **extra):
    return {"runtime": "codex", "status": "error", "result": None,
            "errors": [notice], "scope_id": "s1", **extra}


def put(directory, name, obj, mtime=NOW):
    path = Path(directory) / name
    path.write_text(json.dumps(obj), encoding="utf-8")
    os.utime(path, (mtime.timestamp(), mtime.timestamp()))


def run(*args, env=None):
    full_env = {**os.environ, "TZ": "America/Los_Angeles", **(env or {})}
    return subprocess.run([sys.executable, str(HELPER), *args], capture_output=True,
                          text=True, env=full_env, timeout=60)


def parse(result):
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def parse_time(value):
    return datetime.fromisoformat(value)


class ResetParsingTests(unittest.TestCase):
    def record_marker(self, notice):
        with tempfile.TemporaryDirectory() as tmp:
            put(tmp, "probe-codex-reviewer.json", limit(notice))
            out = parse(run("record", "--run-dir", tmp, "--state-file",
                            str(Path(tmp) / "state" / "m.json")))
        return out["marker"]

    def test_reset_parses_try_again_at_local_time(self):
        marker = self.record_marker(AT)
        self.assertEqual(parse_time(marker["reset_at"]),
                         datetime(2026, 10, 3, 17, 10, tzinfo=timezone.utc))
        self.assertEqual(marker["reset_source"], "at")

    def test_reset_parses_try_again_in_days(self):
        marker = self.record_marker(IN2)
        self.assertEqual(parse_time(marker["reset_at"]), NOW + timedelta(days=2))
        self.assertEqual(marker["reset_source"], "in")

    def test_reset_defaults_to_one_hour_when_unparsed(self):
        marker = self.record_marker(BARE)
        self.assertEqual(parse_time(marker["reset_at"]), NOW + timedelta(hours=1))
        self.assertEqual(marker["reset_source"], "default")

    def test_reset_out_of_range_falls_back_to_default(self):
        marker = self.record_marker(FAR)
        self.assertEqual(parse_time(marker["reset_at"]), NOW + timedelta(hours=1))
        self.assertEqual(marker["reset_source"], "default")


class RecordTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state" / "codex-quota.json"
        self.run_dir = self.tmp / "run"
        self.run_dir.mkdir()

    def record(self, now=NOW):
        return parse(run("record", "--run-dir", str(self.run_dir), "--state-file",
                         str(self.state), "--now", now.isoformat()))

    def test_record_writes_marker_from_codex_usage_limit_probe(self):
        put(self.run_dir, "probe-codex-reviewer.json", limit(AT))
        put(self.run_dir, "probe-claude-skeptic.json", OK_CLAUDE)
        out = self.record()
        self.assertEqual(out["action"], "wrote")
        self.assertEqual(set(out["marker"]), {"v", "observed_at", "reset_at", "reset_source",
                                              "notice", "source", "scope_id"})
        self.assertEqual(out["marker"]["source"], "probe-codex-reviewer.json")
        self.assertEqual(out["marker"]["scope_id"], "s1")
        self.assertEqual(json.loads(self.state.read_text()), out["marker"])
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.state.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual([p.name for p in self.state.parent.iterdir()], ["codex-quota.json"])

    def test_record_clears_marker_on_codex_success(self):
        put(self.run_dir, "probe-codex-reviewer.json", limit(AT))
        self.record()
        put(self.run_dir, "probe-codex-reviewer.json", OK_CODEX)
        self.assertEqual(self.record()["action"], "cleared")
        self.assertFalse(self.state.exists())

    def test_record_ignores_other_failures_and_claude_results(self):
        put(self.run_dir, "probe-codex-reviewer.json", limit(AT))
        self.record()
        before = self.state.read_bytes()
        put(self.run_dir, "probe-codex-reviewer.json",
            {"runtime": "codex", "status": "timeout", "result": None, "errors": ["timed out"]})
        put(self.run_dir, "probe-codex-skeptic.json", AUTH)
        put(self.run_dir, "codex.runtime.json",
            {"runtime": "claude", "status": "error", "result": None, "errors": [AT]})
        self.assertEqual(self.record()["action"], "unchanged")
        self.assertEqual(self.state.read_bytes(), before)

    def test_record_prefers_seat_results_over_probes(self):
        put(self.run_dir, "probe-codex-reviewer.json", OK_CODEX)
        put(self.run_dir, "codex.runtime.json", limit(IN2))
        out = self.record()
        self.assertEqual(out["action"], "wrote")
        self.assertEqual(out["marker"]["source"], "codex.runtime.json")
        for name in ("probe-codex-reviewer.json", "codex.runtime.json"):
            (self.run_dir / name).unlink()
        put(self.run_dir, "codex.codex-attempt.json", limit(AT))
        put(self.run_dir, "breaker.runtime.json", OK_CODEX)
        self.assertEqual(self.record()["action"], "cleared")
        self.assertFalse(self.state.exists())

    def test_record_observed_at_follows_runner_mtime(self):
        put(self.run_dir, "probe-codex-reviewer.json", limit(IN2))
        for later in (NOW + timedelta(hours=3), NOW + timedelta(hours=9)):
            marker = self.record(now=later)["marker"]
            self.assertEqual(parse_time(marker["observed_at"]), NOW)
            self.assertEqual(parse_time(marker["reset_at"]), NOW + timedelta(days=2))
        future = NOW + timedelta(hours=5)
        put(self.run_dir, "probe-codex-reviewer.json", limit(IN2), mtime=future)
        for at in (NOW, NOW + timedelta(hours=6)):
            marker = self.record(now=at)["marker"]
            self.assertEqual(parse_time(marker["observed_at"]), future)
            self.assertEqual(parse_time(marker["reset_at"]), future + timedelta(days=2))


class CheckTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.tmp = Path(self._tmp.name)
        self.state = self.tmp / "state" / "codex-quota.json"
        put(self.tmp, "probe-codex-reviewer.json", limit(AT))
        parse(run("record", "--run-dir", str(self.tmp), "--state-file", str(self.state)))

    def check(self, now):
        return parse(run("check", "--state-file", str(self.state), "--now", now))

    def test_check_reports_valid_marker_before_reset(self):
        out = self.check("2026-10-03T17:09:00+00:00")
        self.assertTrue(out["valid"])
        self.assertEqual(out["marker"]["reset_source"], "at")
        self.assertTrue(self.state.exists())

    def test_check_removes_expired_marker(self):
        out = self.check("2026-10-03T17:10:00+00:00")
        self.assertFalse(out["valid"])
        self.assertTrue(out["expired"])
        self.assertFalse(self.state.exists())

    def test_check_removes_malformed_marker(self):
        self.state.write_text("not json")
        out = self.check("2026-09-30T00:00:00+00:00")
        self.assertFalse(out["valid"])
        self.assertFalse(out["expired"])
        self.assertFalse(self.state.exists())

    def test_default_state_file_follows_xdg_state_home(self):
        out = parse(run("check", env={"XDG_STATE_HOME": str(self.tmp / "xdg")}))
        self.assertEqual(out["state_file"], str(self.tmp / "xdg/dotfiles/co-review/codex-quota.json"))
        env = {k: v for k, v in os.environ.items() if k != "XDG_STATE_HOME"}
        env["HOME"] = str(self.tmp / "home")
        result = subprocess.run([sys.executable, str(HELPER), "check"], capture_output=True,
                                text=True, env=env, timeout=60)
        self.assertEqual(json.loads(result.stdout)["state_file"],
                         str(self.tmp / "home/.local/state/dotfiles/co-review/codex-quota.json"))


class SubstitutesTests(unittest.TestCase):
    BASE = {"probe-claude-reviewer.json": OK_CLAUDE, "probe-claude-skeptic.json": OK_CLAUDE,
            "probe-codex-skeptic.json": OK_CODEX}

    def substitutes(self, files, cls):
        with tempfile.TemporaryDirectory() as tmp:
            for name, obj in files.items():
                if obj is None:
                    (Path(tmp) / name).write_text("{", encoding="utf-8")
                else:
                    put(tmp, name, obj)
            return run("substitutes", "--run-dir", tmp, "--class", cls)

    def test_substitutes_names_every_usage_limited_codex_seat(self):
        both = {**self.BASE, "probe-codex-reviewer.json": limit(AT),
                "probe-codex-skeptic.json": limit(IN2)}
        result = self.substitutes(both, "full")
        self.assertEqual((result.returncode, result.stdout), (0, "codex breaker\n"))
        only_skeptic = {**self.BASE, "probe-codex-reviewer.json": OK_CODEX,
                        "probe-codex-skeptic.json": limit(AT)}
        self.assertEqual(self.substitutes(only_skeptic, "full").stdout, "breaker\n")
        light = {"probe-claude-skeptic.json": OK_CLAUDE, "probe-codex-reviewer.json": limit(BARE)}
        self.assertEqual(self.substitutes(light, "light").stdout, "codex\n")
        self.assertEqual(self.substitutes(light, "small").stdout, "codex\n")
        unparseable = {**self.BASE, "probe-codex-reviewer.json": limit(AT, status="unparseable")}
        self.assertEqual(self.substitutes(unparseable, "full").stdout, "codex\n")

    def test_substitutes_refuses_mixed_non_quota_or_tierless_failures(self):
        claude_down = {"runtime": "claude", "status": "error", "result": None, "errors": ["x"]}
        light_only = {"probe-claude-skeptic.json": OK_CLAUDE}
        cases = {
            "claude failed": ({**self.BASE, "probe-claude-skeptic.json": claude_down,
                               "probe-codex-reviewer.json": limit(AT)}, "full"),
            "auth": ({**self.BASE, "probe-codex-reviewer.json": AUTH}, "full"),
            "timeout": ({**self.BASE, "probe-codex-reviewer.json":
                         {"runtime": "codex", "status": "timeout", "result": None,
                          "errors": [AT]}}, "full"),
            "mixed": ({**self.BASE, "probe-codex-reviewer.json": limit(AT),
                       "probe-codex-skeptic.json": AUTH}, "full"),
            "none failed": ({**self.BASE, "probe-codex-reviewer.json": OK_CODEX}, "full"),
            "delta": ({**self.BASE, "probe-codex-reviewer.json": limit(AT)}, "delta"),
            "lessons": ({**self.BASE, "probe-codex-reviewer.json": limit(AT)}, "lessons"),
            "light skeptic": ({**light_only, "probe-codex-skeptic.json": limit(AT)}, "light"),
            "has result": ({**self.BASE, "probe-codex-reviewer.json":
                            {**limit(AT), "result": "APPROVE"}}, "full"),
            "wrong runtime": ({**self.BASE, "probe-codex-reviewer.json":
                               {**limit(AT), "runtime": "claude"}}, "full"),
            "unreadable": ({**self.BASE, "probe-codex-reviewer.json": None}, "full"),
        }
        for label, (files, cls) in cases.items():
            with self.subTest(label):
                result = self.substitutes(files, cls)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertEqual(result.stdout, "")
                self.assertTrue(result.stderr.strip())

    def test_substitutes_refuses_missing_probe_or_prior_attempt(self):
        missing = {"probe-claude-reviewer.json": OK_CLAUDE, "probe-codex-reviewer.json": limit(AT),
                   "probe-codex-skeptic.json": limit(AT)}
        self.assertEqual(self.substitutes(missing, "full").returncode, 1)
        prior = {**self.BASE, "probe-codex-reviewer.json": limit(AT),
                 "probe-codex-skeptic.json": limit(AT), "codex.codex-attempt.json": limit(AT)}
        self.assertEqual(self.substitutes(prior, "full").returncode, 1)


if __name__ == "__main__":
    unittest.main()
