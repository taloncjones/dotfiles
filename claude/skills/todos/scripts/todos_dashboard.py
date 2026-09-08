#!/usr/bin/env python3
"""todos_dashboard.py - render this repo's todo board to one HTML file.

Invoked as `todos.sh dashboard [--open] [--online] [--out PATH]
[--completed N]`; see claude/skills/todos/SKILL.md ("Dashboard").

Reads, never writes: .todos/{pending,completed,research}/ and the herdr
task records under the selected account payload root (or the explicit
TODOS_STATE_ROOT override). Dependency state comes from
todos.sh's own resolver (`_depends` / `_normalize_ref` / `_resolve`), so
there is one resolver. The only write is the output file, default
${XDG_STATE_HOME:-~/.local/state}/dotfiles/dashboard/<account_id>/<repo_slug>.html.
TODOS_DASHBOARD_DIR and --out deliberately select an explicit output path.
The page is written to a sibling temp file and renamed into place.
"""
import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[2] / "hooks"))
sys.path.insert(0, str(HERE.parents[1] / "lib"))
import herdr_orch_core as core
from workflow_context import account_scope, repository_context
from workflow_context import git as context_git

TODOS_SH = Path(os.environ.get("TODOS_DASHBOARD_TODOS_SH") or HERE / "todos.sh")
TODOS_DIRNAME = ".todos"
SUMMARY_LEN = 140
RESEARCH_SUMMARY_LEN = 200
MAX_LINKS = 5
DEFAULT_COMPLETED = 10
SATISFIED = ("done", "merged")
IN_FLIGHT_STATUSES = ("kickoff", "in-progress", "blocked", "review-dispatched",
                      "changes-requested", "reviewed", "completed")
URL_RE = re.compile(r"https?://[^\s<>()\[\]\"']+")
PR_URL_RE = re.compile(r"^https?://github\.com/[^/]+/[^/]+/pull/(\d+)")
ARTIFACT_URL_RE = re.compile(r"^https?://claude\.ai/(code/)?artifacts/")
PRIORITY_WEIGHT = {"high": "0", "med": "1", "low": "2"}
# Open-section grouping (D8): computed state (blocked-by-deps, in-flight-by-
# herdr) always wins over the manual `status:` field, since it reflects
# ground truth the field can go stale against. `status: waiting` / `someday`
# only sort a todo that is neither blocked nor in-flight.
BUCKET_ORDER = ("ready", "in-flight", "blocked", "waiting", "someday")
BUCKET_LABELS = {"ready": "Ready", "in-flight": "In flight", "blocked": "Blocked",
                  "waiting": "Waiting", "someday": "Someday"}


def die(msg):
    print(f"todos: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"todos: {msg}", file=sys.stderr)


def esc(s):
    return html.escape(str(s), quote=True)


def safe_href(url):
    """Only http(s) URLs become links; anything else renders as text."""
    return url if re.match(r"^https?://", url) else ""


def git(args, cwd=None):
    try:
        return 0, context_git(cwd or Path.cwd(), *args).strip()
    except subprocess.CalledProcessError as e:
        return e.returncode, (e.stdout or "").strip()


def unquote(v):
    v = v.strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def frontmatter(text):
    """Return (scalars, lists, body). Reads only the first --- block.

    scalars: first `key: value` per key, quotes stripped (frontmatter_value).
    lists: `key:` followed by `  - item` lines (depends_list / files).
    """
    lines = text.split("\n")
    scalars, lists, body_start = {}, {}, 0
    seen = set()
    if lines and lines[0].strip() == "---":
        current = None
        i = 1
        while i < len(lines):
            line = lines[i]
            if line.strip() == "---":
                body_start = i + 1
                break
            if line.startswith("  - ") and current is not None:
                lists.setdefault(current, []).append(unquote(line[4:]))
            else:
                current = None
                m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*):[ \t]*(.*)$", line)
                if m:
                    key, val = m.group(1), m.group(2)
                    first = key not in seen
                    seen.add(key)
                    if val == "":
                        # A blank first value claims the key (frontmatter_value
                        # returns the first line, blank or not); its list items
                        # are still collected only for the first occurrence.
                        current = key if first else None
                        if first:
                            lists[key] = []
                    elif first:
                        scalars[key] = unquote(val)
            i += 1
        else:
            body_start = len(lines)
    return scalars, lists, "\n".join(lines[body_start:])


def problem_summary(body):
    in_problem = False
    for line in body.split("\n"):
        if line.startswith("## Problem"):
            in_problem = True
            continue
        if in_problem and line.startswith("## "):
            return ""
        if in_problem and line.strip():
            return line.strip()[:SUMMARY_LEN]
    return ""


def first_body_line(body):
    for line in body.split("\n"):
        if line.strip():
            return line.strip()[:RESEARCH_SUMMARY_LEN]
    return ""


def body_links(body):
    seen, out = set(), []
    for m in URL_RE.finditer(body):
        url = m.group(0).rstrip(".,;")
        if url in seen:
            continue
        seen.add(url)
        pr = PR_URL_RE.match(url)
        if pr:
            label = f"PR #{pr.group(1)}"
        elif ARTIFACT_URL_RE.match(url):
            label = "artifact"
        else:
            label = re.sub(r"^https?://", "", url).split("/")[0]
        out.append((label, url))
        if len(out) >= MAX_LINKS:
            break
    return out


class Resolver:
    """One todos.sh call per distinct ref, results memoised for the run.

    Offline by default (TODOS_OFFLINE=1 in the child env); --online removes
    TODOS_OFFLINE from the child env even when the caller exported it.
    """

    def __init__(self, root, online):
        self.root = root
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        if online:
            self.env.pop("TODOS_OFFLINE", None)
        else:
            self.env["TODOS_OFFLINE"] = "1"
        self.norm_cache, self.state_cache = {}, {}

    def _call(self, verb, arg):
        try:
            r = subprocess.run(["bash", str(TODOS_SH), verb, arg], cwd=self.root,
                               env=self.env, capture_output=True, text=True)
        except OSError:
            return 1, ""
        return r.returncode, r.stdout.strip()

    def depends(self, path):
        """-> (items, ok). ok is False when _depends itself failed."""
        rc, out = self._call("_depends", str(path))
        if rc != 0:
            return [], False
        return [l for l in out.split("\n") if l.strip()], True

    def normalize(self, raw):
        if raw not in self.norm_cache:
            rc, out = self._call("_normalize_ref", raw)
            self.norm_cache[raw] = out if rc == 0 and out else None
        return self.norm_cache[raw]

    def state(self, ref):
        if ref not in self.state_cache:
            rc, out = self._call("_resolve", ref)
            self.state_cache[ref] = out if rc == 0 and out else "unknown"
        return self.state_cache[ref]

    def resolve_all(self, path, basename):
        """-> list of (ref_text, state) in file order."""
        items, ok = self.depends(path)
        if not ok:
            return [("depends_on", "unreadable")]
        out = []
        for raw in items:
            ref = self.normalize(raw)
            if ref is None:
                out.append((raw, "invalid"))
            elif ref == f"todo:{basename}":
                out.append((ref, "self"))
            else:
                out.append((ref, self.state(ref)))
        return out


def read_json(path, *, confined=False):
    """-> (dict|None, unreadable: bool). Missing file is (None, False)."""
    try:
        if confined:
            data = json.loads(core.read_payload_text(path))
        else:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
    except FileNotFoundError:
        return None, False
    except (OSError, ValueError, UnicodeDecodeError):
        return None, True
    if not isinstance(data, dict):
        return None, True
    return data, False


def field(d, key):
    """String value of d[key] when it is a str or int; blank otherwise."""
    v = d.get(key)
    if isinstance(v, bool):
        return ""
    if isinstance(v, (str, int)):
        return str(v)
    return ""


def herdr_status(tasks_dir, basename, *, confined=False):
    """Read-only view of tasks/td-<basename>.{json,review.json,done.json}.

    The task record is authoritative for status and the live worker. The
    review record is shown as-is only when its reviewed_head_sha equals the
    record's review_head_sha, else tagged stale; the done record only when
    its phase and agent both equal the live worker's (herdr reuses one
    workspace across phases, so workspace_id proves nothing), else stale.
    """
    task_id = f"td-{basename}"
    rec, bad = read_json(tasks_dir / f"{task_id}.json", confined=confined)
    if rec is None and not bad:
        return None
    st = {"task_id": task_id, "status": "", "phase": "", "role": "", "model": "",
          "agent": "", "workspace_id": "", "branch": "", "review_head_sha": "",
          "review_outcome": "", "review": "", "review_stale": False,
          "blocking_count": "", "findings_ref": "", "done_outcome": "",
          "done_phase": "", "done_stale": False, "unreadable": bad}
    if rec is not None:
        for k in ("status", "branch", "review_head_sha", "review_outcome"):
            st[k] = field(rec, k)
        workers = rec.get("workers")
        if isinstance(workers, list) and workers and isinstance(workers[-1], dict):
            w = workers[-1]
            for k in ("phase", "role", "model", "agent", "workspace_id"):
                st[k] = field(w, k)
    else:
        st["status"] = "unreadable"
    rev, bad = read_json(tasks_dir / f"{task_id}.review.json", confined=confined)
    if rev is not None:
        st["review"] = field(rev, "outcome") or "unknown"
        st["blocking_count"] = field(rev, "blocking_count")
        st["findings_ref"] = field(rev, "findings_ref")
        st["review_stale"] = not st["review_head_sha"] or field(rev, "reviewed_head_sha") != st["review_head_sha"]
    elif bad:
        st["review"] = "unreadable"
    done, bad = read_json(tasks_dir / f"{task_id}.done.json", confined=confined)
    if done is not None:
        st["done_outcome"] = field(done, "outcome")
        st["done_phase"] = field(done, "phase")
        st["done_stale"] = not (st["phase"] and st["agent"]
                                and field(done, "phase") == st["phase"]
                                and field(done, "agent") == st["agent"])
    elif bad:
        st["done_outcome"] = "unreadable"
    return st


def read_text(path):
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as e:
        warn(f"skipping unreadable file: {path} ({e.strerror})")
        return None


def load_todo(path, resolver, tasks_dir, pending, confined_state):
    text = read_text(path)
    if text is None:
        return None
    scalars, lists, body = frontmatter(text)
    basename = path.stem
    t = {
        "basename": basename,
        "path": path,
        "title": scalars.get("title") or basename,
        "created": scalars.get("created", ""),
        "area": scalars.get("area", ""),
        "priority": scalars.get("priority", ""),
        "due": scalars.get("due", ""),
        "surface": scalars.get("surface", ""),
        "maturity": scalars.get("maturity", ""),
        "tier": scalars.get("tier", ""),
        "status": scalars.get("status", ""),
        "files": lists.get("files", []),
        "summary": problem_summary(body),
        "links": body_links(body),
        "deps": resolver.resolve_all(path, basename) if pending else [],
        "herdr": herdr_status(tasks_dir, basename, confined=confined_state),
    }
    t["blocked"] = any(state not in SATISFIED for _, state in t["deps"])
    h = t["herdr"]
    t["in_flight"] = bool(pending and h and h["status"] in IN_FLIGHT_STATUSES)
    return t


def load_dir(d, resolver, tasks_dir, pending, confined_state):
    if not d.is_dir():
        return []
    out = []
    for p in sorted(d.glob("*.md")):
        t = load_todo(p, resolver, tasks_dir, pending, confined_state)
        if t is not None:
            out.append(t)
    return out


def open_sort_key(t):
    pw = PRIORITY_WEIGHT.get(t["priority"], "3")
    if t["due"]:
        return ("0" + t["due"] + pw, t["basename"])
    return ("1" + pw + (t["created"] or "9999-99-99"), t["basename"])


def load_research(research_dir, known_basenames):
    entries = []
    if not research_dir.is_dir():
        return entries
    for p in sorted(research_dir.rglob("*.md")):
        text = read_text(p)
        if text is None:
            continue
        scalars, _, body = frontmatter(text)
        task = scalars.get("task", "")
        task_base = task[3:] if task.startswith("td-") else task
        entries.append({
            "rel": p.relative_to(research_dir).as_posix(),
            "path": p,
            "title": scalars.get("title") or p.name,
            "created": scalars.get("created", ""),
            "kind": scalars.get("kind", ""),
            "task": task,
            "task_anchor": task_base if task_base in known_basenames else "",
            "artifact": scalars.get("artifact", ""),
            "summary": first_body_line(body),
        })
    dated = [e for e in entries if e["created"]]
    undated = [e for e in entries if not e["created"]]
    dated.sort(key=lambda e: e["rel"])
    dated.sort(key=lambda e: e["created"], reverse=True)
    undated.sort(key=lambda e: e["rel"])
    return dated + undated


# --- rendering -------------------------------------------------------------

CSS = r"""
:root {
  color-scheme: light;
  --ground: #f4f6f3;
  --surface: #ffffff;
  --surface-soft: #eef2ee;
  --ink: #243128;
  --muted: #5f6d63;
  --accent: #285f4b;
  --rule: #d5ddd5;
  --chip: #edf1ec;
  --blocked: #913e1c;
  --blocked-soft: #fff3eb;
  --blocked-rule: #e9b99e;
  --merged: #285e8a;
  --merged-soft: #eaf2fa;
  --merged-rule: #b9cfdf;
  --inflight: #745813;
  --inflight-soft: #faf3db;
  --inflight-rule: #ddca8d;
  --shadow: 0 2px 6px rgb(22 38 28 / 0.04);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --ground: #171d19;
    --surface: #202823;
    --surface-soft: #26302a;
    --ink: #e8eee9;
    --muted: #aab6ad;
    --accent: #92ceb0;
    --rule: #3b493f;
    --chip: #2c362f;
    --blocked: #f2b38e;
    --blocked-soft: #332820;
    --blocked-rule: #74503c;
    --merged: #a6c9eb;
    --merged-soft: #223140;
    --merged-rule: #45617c;
    --inflight: #e4cb84;
    --inflight-soft: #332f20;
    --inflight-rule: #6d5d34;
    --shadow: 0 2px 6px rgb(0 0 0 / 0.12);
  }
}

:root[data-theme="dark"] {
  color-scheme: dark;
  --ground: #171d19;
  --surface: #202823;
  --surface-soft: #26302a;
  --ink: #e8eee9;
  --muted: #aab6ad;
  --accent: #92ceb0;
  --rule: #3b493f;
  --chip: #2c362f;
  --blocked: #f2b38e;
  --blocked-soft: #332820;
  --blocked-rule: #74503c;
  --merged: #a6c9eb;
  --merged-soft: #223140;
  --merged-rule: #45617c;
  --inflight: #e4cb84;
  --inflight-soft: #332f20;
  --inflight-rule: #6d5d34;
  --shadow: 0 2px 6px rgb(0 0 0 / 0.12);
}

* {
  box-sizing: border-box;
}

body {
  margin: 0;
  background: var(--ground);
  color: var(--ink);
  font: 15px/1.55 "Avenir Next", "Segoe UI", system-ui, sans-serif;
}

main {
  max-width: 1200px;
  margin: 0 auto;
  padding: 40px 24px 72px;
}

h1 {
  margin: 0 0 8px;
  font-size: clamp(26px, 3vw, 34px);
  font-weight: 600;
  line-height: 1.2;
  letter-spacing: -0.025em;
  overflow-wrap: anywhere;
  text-wrap: balance;
}

h2 {
  margin: 36px 0 12px;
  color: var(--ink);
  font-size: 18px;
  font-weight: 600;
  line-height: 1.3;
  letter-spacing: -0.01em;
}

.meta {
  color: var(--muted);
  font-size: 13px;
  line-height: 1.6;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
}

main > .meta {
  max-width: 80ch;
}

/* One compact summary panel. */
.counts {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(96px, 1fr));
  max-width: 760px;
  margin: 24px 0 0;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 12px;
  box-shadow: var(--shadow);
}

.counts > div {
  min-width: 0;
  padding: 18px 22px;
}

.counts > div + div {
  border-left: 1px solid var(--rule);
}

.counts b {
  display: block;
  font-size: 32px;
  font-weight: 600;
  line-height: 1.1;
  letter-spacing: -0.035em;
  font-variant-numeric: tabular-nums;
  overflow-wrap: anywhere;
}

.counts b[data-count="open"] {
  color: var(--accent);
}

.counts b[data-count="blocked"] {
  color: var(--blocked);
}

.counts b[data-count="in-flight"] {
  color: var(--inflight);
}

.counts b[data-count="waiting"] {
  color: var(--merged);
}

.counts b[data-count="someday"] {
  color: var(--muted);
}

.counts span {
  display: block;
  margin-top: 7px;
  color: var(--muted);
  font-size: 13px;
  line-height: 1.3;
}

/* Open-section grouping: one heading + table per bucket (Ready, In flight,
   Blocked, Waiting, Someday). Someday collapses via native <details>. */
.bucket + .bucket,
.bucket + details.bucket,
details.bucket + .bucket,
details.bucket + details.bucket {
  margin-top: 28px;
}

.bucket h3,
details.bucket summary {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0 0 10px;
  font-size: 14px;
  font-weight: 600;
  color: var(--ink);
}

details.bucket summary {
  cursor: pointer;
  list-style: none;
}

details.bucket summary::-webkit-details-marker {
  display: none;
}

details.bucket summary::before {
  content: "\25B8";
  color: var(--muted);
  transition: transform 0.15s ease;
}

details.bucket[open] summary::before {
  transform: rotate(90deg);
}

details.bucket summary h3 {
  margin: 0;
}

.bucket-count {
  display: inline-flex;
  min-width: 20px;
  height: 20px;
  padding: 0 6px;
  align-items: center;
  justify-content: center;
  border-radius: 999px;
  background: var(--surface-soft);
  color: var(--muted);
  font-size: 12px;
  font-variant-numeric: tabular-nums;
}

/* Preserve the table layout and contain horizontal scrolling. */
.wrap {
  max-width: 100%;
  overflow-x: auto;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 12px;
  box-shadow: var(--shadow);
}

table {
  width: 100%;
  min-width: 960px;
  border-collapse: separate;
  border-spacing: 0;
  table-layout: fixed;
}

th {
  padding: 12px 16px;
  background: var(--surface-soft);
  color: var(--muted);
  border-bottom: 1px solid var(--rule);
  text-align: left;
  font-size: 12px;
  font-weight: 600;
  line-height: 1.4;
}

th:first-child {
  width: 38%;
}

th:nth-child(2) {
  width: 14%;
}

th:last-child {
  width: 12%;
}

/* Completed has four columns; give its title more room. */
th:first-child:nth-last-child(4) {
  width: 48%;
}

td {
  padding: 16px;
  background: var(--surface);
  border-bottom: 1px solid var(--rule);
  vertical-align: top;
  overflow-wrap: anywhere;
}

tbody > tr:last-child > td {
  border-bottom: 0;
}

tr[id] {
  scroll-margin-top: 24px;
}

tr[data-state="blocked"] > td {
  background: var(--blocked-soft);
}

tr[data-state="blocked"] > td:first-child {
  box-shadow: inset 4px 0 0 var(--blocked);
}

/* Make research-to-todo anchor destinations easy to locate. */
tr:target > td:first-child .name {
  outline: 2px solid var(--accent);
  outline-offset: 4px;
  border-radius: 2px;
}

.name {
  font-size: 15px;
  font-weight: 600;
  line-height: 1.45;
  overflow-wrap: anywhere;
}

.sub {
  color: var(--muted);
  font-size: 13px;
  line-height: 1.55;
  overflow-wrap: anywhere;
}

.mono {
  font-family: "SF Mono", Menlo, Consolas, monospace;
  font-size: 12px;
  line-height: 1.55;
  overflow-wrap: anywhere;
}

td > .name + .sub,
td > .sub + .sub,
td > .pill + .sub {
  margin-top: 4px;
}

.chips {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-top: 10px;
}

.chip,
.pill {
  display: inline-block;
  max-width: 100%;
  padding: 2px 8px;
  border: 1px solid var(--rule);
  font-size: 12px;
  line-height: 1.5;
  vertical-align: middle;
  white-space: normal;
  overflow-wrap: anywhere;
}

.chip {
  border-radius: 5px;
  background: var(--chip);
  color: var(--muted);
}

.chip.prio-high {
  background: var(--blocked-soft);
  border-color: var(--blocked-rule);
  color: var(--blocked);
  font-weight: 600;
}

.pill {
  border-radius: 999px;
  background: var(--surface-soft);
  color: var(--muted);
  font-weight: 600;
}

.pill.merged {
  background: var(--merged-soft);
  border-color: var(--merged-rule);
  color: var(--merged);
}

.pill.in-flight {
  background: var(--inflight-soft);
  border-color: var(--inflight-rule);
  color: var(--inflight);
}

.pill.unreadable {
  background: var(--blocked-soft);
  border-color: var(--blocked-rule);
  color: var(--blocked);
}

.dep {
  display: block;
  white-space: normal;
  overflow-wrap: anywhere;
}

.dep + .dep {
  margin-top: 8px;
}

.dep.ok {
  color: var(--muted);
}

.dep.bad {
  color: var(--blocked);
  font-weight: 600;
}

.dates {
  color: var(--muted);
  font-size: 13px;
  line-height: 1.7;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
}

a {
  color: var(--accent);
  text-decoration: underline;
  text-decoration-thickness: 1px;
  text-underline-offset: 3px;
  text-decoration-skip-ink: auto;
  overflow-wrap: anywhere;
}

a:focus-visible,
.wrap:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 3px;
}

td:last-child > a {
  display: block;
  width: fit-content;
  max-width: 100%;
  font-size: 13px;
}

td:last-child > a + a {
  margin-top: 8px;
}

.empty {
  margin: 0;
  padding: 20px;
  background: var(--surface);
  color: var(--muted);
  border: 1px dashed var(--rule);
  border-radius: 10px;
  font-size: 14px;
  font-style: normal;
  overflow-wrap: anywhere;
}

/* Existing research children become title, metadata, and summary rows. */
ul.research {
  display: grid;
  gap: 12px;
  list-style: none;
  padding: 0;
  margin: 0;
}

ul.research > li {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 8px 12px;
  min-width: 0;
  padding: 18px 20px;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 10px;
}

ul.research > li > * {
  min-width: 0;
  max-width: 100%;
}

ul.research > li > .name {
  flex: 0 0 100%;
  color: var(--ink);
  font-size: 16px;
  text-decoration-color: var(--rule);
}

ul.research > li > div.sub {
  flex: 0 0 100%;
  max-width: 80ch;
  margin-top: 2px;
  font-size: 14px;
}

ul.research > li > a:not(.name):not(.mono) {
  font-size: 13px;
}

ul.research > li:focus-within {
  border-color: var(--accent);
}

@media (hover: hover) {
  a:hover {
    color: var(--ink);
    text-decoration-thickness: 2px;
  }

  ul.research > li > .name:hover {
    color: var(--accent);
    text-decoration-color: currentColor;
  }
}

@media (max-width: 640px) {
  main {
    padding: 24px 16px 48px;
  }

  h2 {
    margin-top: 28px;
  }

  .counts > div {
    padding: 16px 12px;
  }

  .counts b {
    font-size: 28px;
  }

  ul.research > li {
    padding: 16px;
  }
}
"""


def chip(text, cls=""):
    # cls is always a literal from this file, never user data; escaped anyway.
    return f'<span class="chip {esc(cls)}">{esc(text)}</span>' if text else ""


def render_herdr(h):
    if h is None:
        return ""
    status = h["status"]
    if status == "merged":
        cls = "merged"
    elif status == "unreadable":
        cls = "unreadable"
    elif status in IN_FLIGHT_STATUSES:
        cls = "in-flight"
    else:
        cls = "other"
    parts = [f'<span class="pill {cls}">{esc(status or "recorded")}</span>']
    line = " ".join(x for x in (h["phase"], h["role"], h["model"]) if x)
    if line:
        parts.append(f'<div class="sub">{esc(line)}</div>')
    if h["review"]:
        bc = f" ({esc(h['blocking_count'])} blocking)" if h["blocking_count"] != "" else ""
        stale = " (stale)" if h["review_stale"] and h["review"] != "unreadable" else ""
        parts.append(f'<div class="sub">review {esc(h["review"])}{bc}{stale}</div>')
    elif h["review_outcome"]:
        parts.append(f'<div class="sub">review {esc(h["review_outcome"])}</div>')
    if h["done_outcome"]:
        stale = " (stale)" if h["done_stale"] and h["done_outcome"] != "unreadable" else ""
        parts.append(f'<div class="sub">done {esc(h["done_outcome"])} {esc(h["done_phase"])}{stale}</div>')
    return "".join(parts)


def render_links(links):
    return " ".join(f'<a href="{esc(u)}">{esc(label)}</a>' for label, u in links)


def render_todo_cell(t):
    prio_cls = f"prio-{t['priority']}" if t["priority"] in PRIORITY_WEIGHT else ""
    chips = [chip(t["area"]), chip(t["priority"], prio_cls),
             chip(t["maturity"]), chip(t["tier"])]
    chips = "".join(c for c in chips if c)
    out = [f'<div class="name">{esc(t["title"])}</div>',
           f'<div class="sub mono">{esc(t["basename"])}</div>']
    if t["summary"]:
        out.append(f'<div class="sub">{esc(t["summary"])}</div>')
    if chips:
        out.append(f'<div class="chips">{chips}</div>')
    return "".join(out)


def open_bucket(t):
    """Which Open sub-section a todo sorts into (D8).

    Computed state -- blocked-by-deps, in-flight-by-herdr -- always wins
    over the manual `status:` field, since the field can go stale against
    it. `status: waiting` / `someday` only place a todo that is neither.
    """
    if t["blocked"]:
        return "blocked"
    if t["in_flight"]:
        return "in-flight"
    if t["status"] == "waiting":
        return "waiting"
    if t["status"] == "someday":
        return "someday"
    return "ready"


def render_open_table(todos):
    rows = []
    for t in todos:
        state = "blocked" if t["blocked"] else "open"
        status = t["herdr"]["status"] if t["herdr"] else ""
        deps = "".join(
            f'<span class="dep {"ok" if s in SATISFIED else "bad"} mono">{esc(r)} ({esc(s)})</span>'
            for r, s in t["deps"])
        dates = esc(t["created"]) + (f'<br>due {esc(t["due"])}' if t["due"] else "")
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-state="{state}" data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{dates}</td>'
            f'<td>{deps}</td><td>{render_herdr(t["herdr"])}</td>'
            f'<td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created / due</th>'
            '<th>Depends on</th><th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_open(todos):
    if not todos:
        return '<p class="empty">No open todos.</p>'
    grouped = {b: [] for b in BUCKET_ORDER}
    for t in todos:
        grouped[open_bucket(t)].append(t)
    sections = []
    for bucket in BUCKET_ORDER:
        items = grouped[bucket]
        if not items:
            continue
        heading = (f'<h3 data-bucket="{bucket}">{esc(BUCKET_LABELS[bucket])} '
                   f'<span class="bucket-count">{len(items)}</span></h3>')
        table = render_open_table(items)
        if bucket == "someday":
            # A native, JS-free collapse -- someday items are real but not
            # meant to compete for attention with what is actionable now.
            sections.append(f'<details class="bucket"><summary>{heading}</summary>{table}</details>')
        else:
            sections.append(f'<div class="bucket">{heading}{table}</div>')
    return "".join(sections)


def render_completed(todos):
    if not todos:
        return '<p class="empty">Nothing completed yet.</p>'
    rows = []
    for t in todos:
        status = t["herdr"]["status"] if t["herdr"] else ""
        rows.append(
            f'<tr id="todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}" '
            f'data-task-status="{esc(status)}">'
            f'<td>{render_todo_cell(t)}</td><td class="dates">{esc(t["created"])}</td>'
            f'<td>{render_herdr(t["herdr"])}</td><td>{render_links(t["links"])}</td></tr>')
    return ('<div class="wrap"><table><thead><tr><th>Todo</th><th>Created</th>'
            '<th>Herdr</th><th>Links</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>")


def render_research(entries):
    if not entries:
        return ('<p class="empty">No research reports. Save durable notes under '
                '.todos/research/ (see the todos skill).</p>')
    items = []
    for e in entries:
        # Resolve through a symlinked .todos/ (maintenance worktrees) so the
        # link points at the persistent main-checkout path, not an ephemeral
        # worktree path that 404s once the worktree is torn down.
        bits = [f'<a href="{esc(e["path"].resolve().as_uri())}" class="name">{esc(e["title"])}</a>',
                f'<span class="meta"> {esc(e["created"] or "undated")}</span>']
        if e["kind"]:
            bits.append(" " + chip(e["kind"]))
        if e["task_anchor"]:
            bits.append(f' <a href="#todo-{esc(e["task_anchor"])}" class="mono">{esc(e["task"])}</a>')
        elif e["task"]:
            bits.append(f' <span class="mono">{esc(e["task"])}</span>')
        if e["artifact"]:
            href = safe_href(e["artifact"])
            if href:
                bits.append(f' <a href="{esc(href)}">artifact</a>')
            else:
                bits.append(f' <span class="sub">artifact: {esc(e["artifact"])}</span>')
        if e["summary"]:
            bits.append(f'<div class="sub">{esc(e["summary"])}</div>')
        items.append(f'<li data-research="{esc(e["rel"])}">{"".join(bits)}</li>')
    return '<ul class="research">' + "".join(items) + "</ul>"


def render_page(repo_name, branch, stamp, open_todos, completed, research, show_completed):
    # Every tile derives from open_bucket, which is mutually exclusive per
    # todo (blocked wins over in-flight): a todo that is both dependency-
    # blocked and herdr-in-flight must count once, in Blocked, not in both
    # tiles.
    n_open = len(open_todos)
    n_blocked = sum(1 for t in open_todos if open_bucket(t) == "blocked")
    n_flight = sum(1 for t in open_todos if open_bucket(t) == "in-flight")
    n_waiting = sum(1 for t in open_todos if open_bucket(t) == "waiting")
    n_someday = sum(1 for t in open_todos if open_bucket(t) == "someday")
    completed_html = ""
    if show_completed:
        completed_html = "<h2>Completed</h2>" + render_completed(completed)
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(repo_name)} board</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>{esc(repo_name)} board</h1>
<div class="meta">generated {esc(stamp)} on <span class="mono">{esc(branch)}</span>.
Static page: rerun <span class="mono">todos.sh dashboard</span> and reload to refresh.</div>
<div class="counts">
<div><b data-count="open">{n_open}</b><span>open</span></div>
<div><b data-count="blocked">{n_blocked}</b><span>blocked</span></div>
<div><b data-count="in-flight">{n_flight}</b><span>in-flight</span></div>
<div><b data-count="waiting">{n_waiting}</b><span>waiting</span></div>
<div><b data-count="someday">{n_someday}</b><span>someday</span></div>
</div>
<h2>Open</h2>
{render_open(open_todos)}
{completed_html}
<h2>Research</h2>
{render_research(research)}
</main>
</body>
</html>
"""


# --- main -------------------------------------------------------------------

def default_out_dir(account_id):
    d = os.environ.get("TODOS_DASHBOARD_DIR")
    if d:
        return Path(d)
    state = os.environ.get("XDG_STATE_HOME") or str(Path.home() / ".local" / "state")
    return Path(state) / "dotfiles" / "dashboard" / account_id


def default_state_root(scope):
    d = os.environ.get("TODOS_STATE_ROOT")
    if d:
        return Path(d)
    return core.account_payload_root(scope) / "herdr-orch"


def _leaf_form(path):
    """Resolve `path`'s containing directory but leave its own leaf name
    literal -- the shape os.replace() actually acts on: it swaps whatever
    name `path` refers to, never following a symlink AT that name. Applying
    this identically to both `out` and each protected root normalizes any
    ancestor-path aliasing (e.g. macOS's /var -> /private/var) on both sides
    equally, so a plain string comparison afterward is not fooled by one
    side happening to already be in resolved form and the other not.
    """
    return Path(os.path.realpath(path.parent)) / path.name


def guard_out_path(out, protected):
    """Refuse to write under .todos/ or the state root, through symlinks too.

    Three symlink shapes must all be caught, since no single realpath() call
    covers all of them. (1) A symlinked ancestor directory earlier in the
    path: `_leaf_form` resolves it. (2) A symlink placed AT `out` itself,
    pointing outside a protected dir: `_leaf_form` leaves the leaf
    unresolved, so the comparison uses the name the write actually lands on,
    not wherever the symlink points. (3) A protected root that is ITSELF a
    symlink (the routine worktree case, `.todos` or the state root pointing
    at the main checkout) named directly via --out: comparing `_leaf_form`
    on both sides catches this without resolving the root's own name away;
    a separate check against the root's fully resolved target still catches
    a write reaching the same real directory through an unrelated symlink.
    """
    out_leaf = _leaf_form(out)
    for label, p in protected:
        p_leaf = _leaf_form(p)
        real_p = Path(os.path.realpath(p))
        if out_leaf == p_leaf or p_leaf in out_leaf.parents:
            die(f"refusing to write the dashboard under {label}: {out}")
        if out_leaf == real_p or real_p in out_leaf.parents:
            die(f"refusing to write the dashboard under {label}: {out}")


def open_file(path):
    """Best-effort, detached: never waited on, never touches stdout."""
    opener = os.environ.get("TODOS_DASHBOARD_OPENER") or ("open" if sys.platform == "darwin" else "xdg-open")
    try:
        subprocess.Popen([opener, str(path)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        warn(f"cannot open {path}: {opener}: {e.strerror or e}")


USAGE = "usage: todos.sh dashboard [--runtime claude|codex] [--personal] [--open] [--online] [--out PATH] [--completed N]"


class Parser(argparse.ArgumentParser):
    def error(self, message):
        die(f"{message} ({USAGE})")


def parse_args(argv):
    p = Parser(prog="todos.sh dashboard", add_help=True)
    p.add_argument("--runtime", choices=("claude", "codex"))
    p.add_argument("--personal", action="store_true")
    p.add_argument("--open", action="store_true")
    p.add_argument("--online", action="store_true")
    p.add_argument("--out")
    p.add_argument("--completed", type=int, default=DEFAULT_COMPLETED)
    args = p.parse_args(argv)
    if args.completed < 0:
        die("--completed needs a non-negative integer")
    return args


def selected_runtime(args):
    if args.runtime:
        return args.runtime
    inherited = os.environ.get("ORCH_RUNTIME")
    if inherited in ("claude", "codex"):
        return inherited
    return "codex" if os.environ.get("CODEX_HOME") else "claude"


def selected_scope(root, args):
    try:
        return account_scope(
            root,
            selected_runtime(args),
            personal=args.personal or os.environ.get("HERDR_PERSONAL") == "1",
        )
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        die(f"cannot resolve the selected account scope: {e}")


def visibility_warning(root):
    """Warn when .todos/ is neither git-ignored nor tracked (research would commit).

    A directory-only ignore pattern (`.todos/`) does not match a SYMLINK
    named .todos (a maintenance worktree convention), so check-ignore and
    ls-files both miss it on the symlink itself. Test the symlink's target
    instead; a target outside the repo entirely can never be committed here,
    so there is nothing to warn about.
    """
    path = root / TODOS_DIRNAME
    check_name = TODOS_DIRNAME
    if path.is_symlink():
        target = path.resolve()
        try:
            check_name = str(target.relative_to(root.resolve()))
        except ValueError:
            return
    rc, _ = git(["check-ignore", "-q", check_name], cwd=root)
    if rc == 0:
        return
    rc, out = git(["ls-files", "--", check_name], cwd=root)
    if rc == 0 and out:
        return
    warn(f"{TODOS_DIRNAME}/ is neither git-ignored nor tracked; run `todos.sh init` "
         "before saving research there")


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    rc, root = git(["rev-parse", "--show-toplevel"])
    if rc != 0 or not root:
        die("not inside a git repository")
    root = Path(root)
    try:
        context = repository_context(root)
    except (OSError, subprocess.SubprocessError) as e:
        die(f"cannot resolve repository identity: {e}")
    scope = selected_scope(root, args)
    rc, remote = git(["remote", "get-url", "origin"], cwd=root)
    if rc != 0:
        remote = ""
    slug = core.repo_slug(remote, context["common_dir"])
    _, branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root)

    todos_dir = root / TODOS_DIRNAME
    state_root = default_state_root(scope)
    tasks_dir = state_root / slug / "tasks"
    confined_state = not bool(os.environ.get("TODOS_STATE_ROOT"))
    out = Path(args.out) if args.out else default_out_dir(scope["account_id"]) / f"{slug}.html"
    out = out if out.is_absolute() else Path.cwd() / out
    guard_out_path(out, [(f"{TODOS_DIRNAME}/", todos_dir), ("the herdr state root", state_root)])

    if todos_dir.is_dir():
        visibility_warning(root)
    resolver = Resolver(root, args.online)
    pending = load_dir(todos_dir / "pending", resolver, tasks_dir, True, confined_state)
    completed = load_dir(todos_dir / "completed", resolver, tasks_dir, False, confined_state)
    pending.sort(key=open_sort_key)
    completed.sort(key=lambda t: (t["created"], t["basename"]), reverse=True)
    completed = completed[:args.completed]
    known = {t["basename"] for t in pending} | {t["basename"] for t in completed}
    research = load_research(todos_dir / "research", known)

    stamp = os.environ.get("TODOS_DASHBOARD_NOW") or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    page = render_page(root.name, branch, stamp, pending, completed, research, args.completed > 0)

    tmp = out.with_name(out.name + f".tmp.{os.getpid()}")
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        # O_EXCL|O_NOFOLLOW: a planted file or symlink at the temp name fails
        # here instead of being followed; nothing is written through it.
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(page)
        os.replace(tmp, out)
    except OSError as e:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        die(f"cannot write {out}: {e.strerror or e}")
    print(out)
    if args.open:
        open_file(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
