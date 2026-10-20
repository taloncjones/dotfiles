// Checked against herdr_orch_core.task_state_token by plugin.test.sh; keep the value plain JSON.
export const STATE_CASES = [
  {"task": {"status": "reviewed"}, "ship": null, "token": "open-pr?"},
  {"task": {"status": "reviewed", "pr_number": 7}, "ship": null, "token": "co-review"},
  {"task": {"status": "reviewed", "pr_number": 7, "review_head_sha": "aaa"}, "ship": {"verdict": "APPROVE", "head_sha": "aaa"}, "token": "merge?"},
  {"task": {"status": "reviewed", "pr_number": 7, "review_head_sha": "aaa"}, "ship": {"verdict": "APPROVE", "head_sha": "bbb"}, "token": "gate?"},
  {"task": {"status": "reviewed", "pr_number": 7, "review_head_sha": "aaa"}, "ship": {"verdict": "REQUEST_CHANGES", "head_sha": "aaa"}, "token": "gate?"},
  {"task": {"status": "reviewed", "pr": 7}, "ship": null, "token": "co-review"},
  {"task": {"status": "reviewed", "pr_number": true}, "ship": null, "token": "open-pr?"},
  {"task": {"status": "pr-open-pending-merge"}, "ship": null, "token": "merge?"},
  {"task": {"status": "blocked"}, "ship": null, "token": "blocked"},
  {"task": {"status": "in-progress", "phase": "implement"}, "ship": null, "token": "impl"}
]
