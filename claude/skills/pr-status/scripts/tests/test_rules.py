"""Waiting-on rule order and the submodule prefix (spec R5)."""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pr_status.py"
_spec = importlib.util.spec_from_file_location("pr_status", SCRIPT)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

READY = {"state": "OPEN", "ci_failing": [], "ci_pending": 0, "ci_passing": 3,
         "co_review": "approve", "bench_ok": True, "body_reasons": [], "draft": False,
         "review_decision": "APPROVED", "reviewers": [], "authority": "human"}

# Each case breaks one rule and every rule after it, so the expected value
# proves that rule wins over all later ones.
LATER = {"bench_ok": False, "body_reasons": ["1 unchecked"], "draft": True,
         "review_decision": "REVIEW_REQUIRED", "reviewers": ["alice"]}
ORDER = [
    ({"ci_failing": ["unit"], "ci_pending": 2, "co_review": "none", **LATER}, "CI: unit"),
    ({"ci_pending": 2, "co_review": "none", **LATER}, "CI"),
    ({"co_review": "none", **LATER}, "co-review at head"),
    ({"co_review": "changes", **LATER}, "co-review findings"),
    (LATER, "bench run"),
    ({**LATER, "bench_ok": True}, "body edit"),
    ({**LATER, "bench_ok": True, "body_reasons": []}, "undraft"),
    ({**LATER, "bench_ok": True, "body_reasons": [], "draft": False}, "approvers (alice)"),
]


class WaitingOnOrder(unittest.TestCase):
    def test_ready_row_waits_on_merge(self):
        self.assertEqual(ps.waiting_on(READY), "merge (human)")
        self.assertEqual(ps.waiting_on({**READY, "authority": "director"}), "merge (director)")

    def test_each_rule_beats_every_later_rule(self):
        for flips, expected in ORDER:
            with self.subTest(expected=expected):
                self.assertEqual(ps.waiting_on({**READY, **flips}), expected)

    def test_closed_and_merged_come_first(self):
        self.assertEqual(ps.waiting_on({**READY, **ORDER[0][0], "state": "MERGED"}), "merged")
        self.assertEqual(ps.waiting_on({**READY, **ORDER[0][0], "state": "CLOSED"}), "closed")

    def test_no_checks_waits_on_ci(self):
        self.assertEqual(ps.waiting_on({**READY, "ci_passing": 0}), "CI")

    def test_stale_and_changes_co_review(self):
        self.assertEqual(ps.waiting_on({**READY, "co_review": "stale"}), "co-review at head")
        self.assertEqual(ps.waiting_on({**READY, "co_review": "changes"}), "co-review findings")

    def test_unconfigured_bench_is_skipped(self):
        self.assertEqual(ps.waiting_on({**READY, "bench_ok": None}), "merge (human)")

    def test_empty_review_decision_passes(self):
        self.assertEqual(ps.waiting_on({**READY, "review_decision": ""}), "merge (human)")
        self.assertEqual(ps.waiting_on({**READY, "review_decision": None}), "merge (human)")

    def test_approvers_without_requests(self):
        facts = {**READY, "review_decision": "CHANGES_REQUESTED"}
        self.assertEqual(ps.waiting_on(facts), "approvers")


class SubmodulePrefix(unittest.TestCase):
    SUB = {"repo": "org/sub", "number": 3, "url": "https://github.com/org/sub/pull/3"}

    def test_open_submodule_pr_prefixes(self):
        got = ps.with_submodule("CI", {**self.SUB, "state": "OPEN"})
        self.assertEqual(got, "submodule PR [#3](https://github.com/org/sub/pull/3) merge + re-pin; CI")

    def test_unknown_submodule_state_prefixes_with_built_url(self):
        got = ps.with_submodule("CI", {"repo": "org/sub", "number": 3, "state": None, "url": None})
        self.assertEqual(got, "submodule PR [#3](https://github.com/org/sub/pull/3) merge + re-pin; CI")

    def test_merged_submodule_pr_drops_prefix(self):
        self.assertEqual(ps.with_submodule("CI", {**self.SUB, "state": "MERGED"}), "CI")

    def test_no_submodule(self):
        self.assertEqual(ps.with_submodule("CI", None), "CI")


if __name__ == "__main__":
    unittest.main()
