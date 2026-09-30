"""Column rules of pr_status.py (spec R4), one pure function at a time."""
import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "pr_status.py"
_spec = importlib.util.spec_from_file_location("pr_status", SCRIPT)
ps = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ps)

HEAD = "a" * 40
OLD = "b" * 40
ME = "me"
URL = "https://github.com/org/alpha/pull/7"


def check(name, conclusion="SUCCESS", status="COMPLETED"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion}


def status(context, state):
    return {"__typename": "StatusContext", "context": context, "state": state}


def comment(cid, body, login=ME, created="2026-09-29T10:00:00Z"):
    return {"id": cid, "html_url": f"{URL}#issuecomment-{cid}", "created_at": created,
            "user": {"login": login}, "body": body}


def round_marker(sha, verdict, rnd):
    return (f"<!-- co-review: sha={sha} base={'c' * 40} base_ref=main "
            f"verdict={verdict} round={rnd} -->\nCHANGES\n")


def audit_marker(sha):
    return f"<!-- co-review-audit head={sha} run=run-1 -->\nCo-review gate: APPROVE\n"


class PrAndHeadCells(unittest.TestCase):
    def test_pr_cell_links_number_and_escapes_title(self):
        pr = {"number": 7, "url": URL, "title": "Fix a|b\nnext"}
        self.assertEqual(ps.pr_cell(pr, None), f"[#7]({URL}) Fix a\\|b next")

    def test_pr_cell_prefixes_other_repo_name(self):
        pr = {"number": 3, "url": "https://github.com/org/sub/pull/3", "title": "Sub"}
        self.assertEqual(ps.pr_cell(pr, "sub"), "sub [#3](https://github.com/org/sub/pull/3) Sub")

    def test_head_cell_links_short_sha_to_commit(self):
        pr = {"url": URL, "headRefOid": HEAD}
        self.assertEqual(ps.head_cell(pr), f"[{HEAD[:9]}](https://github.com/org/alpha/commit/{HEAD})")


class CiCell(unittest.TestCase):
    def test_all_success_is_green(self):
        state = ps.ci_state([check("lint"), status("ci/x", "SUCCESS")])
        self.assertEqual(ps.ci_cell(*state), "green")

    def test_skipped_and_neutral_are_ignored(self):
        state = ps.ci_state([check("lint"), check("opt", "SKIPPED"), check("info", "NEUTRAL")])
        self.assertEqual(state, ([], 0, 1))
        self.assertEqual(ps.ci_cell(*state), "green")

    def test_only_skipped_is_no_checks(self):
        self.assertEqual(ps.ci_cell(*ps.ci_state([check("opt", "SKIPPED")])), "no checks")

    def test_empty_rollup_is_no_checks(self):
        self.assertEqual(ps.ci_cell(*ps.ci_state([])), "no checks")
        self.assertEqual(ps.ci_cell(*ps.ci_state(None)), "no checks")

    def test_failing_wins_over_pending(self):
        rollup = [check("unit", "FAILURE"), check("e2e", None, "IN_PROGRESS"), status("ci/x", "ERROR")]
        self.assertEqual(ps.ci_cell(*ps.ci_state(rollup)), "2 failing: unit, ci/x")

    def test_pending_counts_checkruns_and_contexts(self):
        rollup = [check("unit", None, "QUEUED"), status("ci/x", "PENDING"), status("ci/y", "EXPECTED")]
        self.assertEqual(ps.ci_cell(*ps.ci_state(rollup)), "3 pending")

    def test_cancelled_and_timed_out_fail(self):
        rollup = [check("a", "CANCELLED"), check("b", "TIMED_OUT")]
        self.assertEqual(ps.ci_cell(*ps.ci_state(rollup)), "2 failing: a, b")


class CoReviewCell(unittest.TestCase):
    def test_round_marker_at_head(self):
        found = ps.markers([comment(11, round_marker(HEAD, "APPROVE", 2))], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("approve", f"r2 APPROVE ([11]({URL}#issuecomment-11))"))

    def test_changes_at_head(self):
        found = ps.markers([comment(11, round_marker(HEAD, "CHANGES", 1))], ME)
        self.assertEqual(ps.co_review(found, HEAD)[0], "changes")
        self.assertEqual(ps.co_review(found, HEAD)[1], f"r1 CHANGES ([11]({URL}#issuecomment-11))")

    def test_audit_comment_at_head(self):
        found = ps.markers([comment(12, audit_marker(HEAD))], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("approve", f"audit APPROVE ([12]({URL}#issuecomment-12))"))

    def test_marker_at_older_head_is_stale(self):
        found = ps.markers([comment(11, round_marker(OLD, "APPROVE", 3))], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("stale", f"stale (r3 at {OLD[:9]})"))

    def test_audit_at_older_head_is_stale(self):
        found = ps.markers([comment(12, audit_marker(OLD))], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("stale", f"stale (audit at {OLD[:9]})"))

    def test_newest_at_head_wins(self):
        comments = [comment(20, round_marker(HEAD, "APPROVE", 2), created="2026-09-29T11:00:00Z"),
                    comment(10, round_marker(HEAD, "CHANGES", 1), created="2026-09-29T10:00:00Z")]
        self.assertEqual(ps.co_review(ps.markers(comments, ME), HEAD)[0], "approve")

    def test_untrusted_author_is_ignored(self):
        found = ps.markers([comment(11, round_marker(HEAD, "APPROVE", 1), login="mallory")], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("none", "none"))

    def test_marker_not_on_first_line_is_ignored(self):
        found = ps.markers([comment(11, "hello\n" + round_marker(HEAD, "APPROVE", 1))], ME)
        self.assertEqual(ps.co_review(found, HEAD), ("none", "none"))


RUN_URL = "https://github.com/org/alpha/actions/runs/"


def bench_run(rid, sha, status, conclusion, created):
    return {"databaseId": rid, "headSha": sha, "status": status, "conclusion": conclusion,
            "createdAt": created, "url": f"{RUN_URL}{rid}"}


class BenchCell(unittest.TestCase):

    def test_newest_completed_success_at_head(self):
        runs = [bench_run(1, HEAD, "completed", "failure", "2026-09-29T09:00:00Z"),
                bench_run(2, HEAD, "completed", "success", "2026-09-29T10:00:00Z")]
        self.assertEqual(ps.bench(runs, HEAD), (True, f"success [2]({RUN_URL}2)"))

    def test_failed_at_head(self):
        runs = [bench_run(2, HEAD, "completed", "failure", "2026-09-29T10:00:00Z")]
        self.assertEqual(ps.bench(runs, HEAD), (False, f"failure [2]({RUN_URL}2)"))

    def test_in_progress_at_head(self):
        runs = [bench_run(3, HEAD, "in_progress", "", "2026-09-29T10:00:00Z")]
        self.assertEqual(ps.bench(runs, HEAD), (False, f"in_progress [3]({RUN_URL}3)"))

    def test_none_at_head_lists_other_active_runs(self):
        runs = [bench_run(4, OLD, "completed", "success", "2026-09-29T09:00:00Z"),
                bench_run(5, OLD, "queued", "", "2026-09-29T10:00:00Z")]
        self.assertEqual(ps.bench(runs, HEAD), (False, f"none at head, queued [5]({RUN_URL}5)"))

    def test_evidence_link_from_checked_test_plan_box(self):
        body = ("## Summary\n- [x] see [run 9](https://e/9)\n## Test plan\n"
                "- [x] unit tests\n- [x] HIL stand evidence: [bench 42](https://e/42)\n")
        self.assertEqual(ps.evidence_link(ps.plan_section(body)), "evidence [bench 42](https://e/42)")

    def test_unchecked_evidence_box_is_ignored(self):
        body = "## Test plan\n- [ ] stand evidence: [bench 42](https://e/42)\n"
        self.assertIsNone(ps.evidence_link(ps.plan_section(body)))


class BodyCell(unittest.TestCase):
    def test_current_body_has_no_reasons(self):
        body = f"## Test plan\n- [x] tests at {HEAD[:9]}\n"
        self.assertEqual(ps.body_reasons(body, [{"oid": OLD}, {"oid": HEAD}], HEAD), [])

    def test_every_reason_in_order(self):
        body = (f"Bench at {OLD[:8]}, see <run link> and PR <n>.\n## Test plan\n"
                "- [ ] one\n- [x] two\n  - [ ] three\n## Notes\n- [ ] not in plan\n")
        self.assertEqual(ps.body_reasons(body, [{"oid": OLD}, {"oid": HEAD}], HEAD),
                         ["2 unchecked", "placeholder `<run link>`", "placeholder `<n>`",
                          f"stale sha {OLD[:8]}"])

    def test_sha_not_on_branch_is_not_stale(self):
        self.assertEqual(ps.body_reasons("merge-base cccccccc", [{"oid": OLD}], HEAD), [])


if __name__ == "__main__":
    unittest.main()
