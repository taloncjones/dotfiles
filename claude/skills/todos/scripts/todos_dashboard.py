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
import hashlib
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
from todos_prd import NOTE_SECTIONS, URL_RE, esc, is_fence, render_body, safe_href, split_sections

TODOS_SH = Path(os.environ.get("TODOS_DASHBOARD_TODOS_SH") or HERE / "todos.sh")
TODOS_DIRNAME = ".todos"
SUMMARY_MAX = 220
RESEARCH_SUMMARY_LEN = 200
MAX_LINKS = 5
DEFAULT_COMPLETED = 10
SATISFIED = ("done", "merged")
IN_FLIGHT_STATUSES = ("kickoff", "in-progress", "blocked", "review-dispatched",
                      "changes-requested", "reviewed", "completed")
PR_URL_RE = re.compile(r"^https?://github\.com/[^/]+/[^/]+/pull/(\d+)")
ARTIFACT_URL_RE = re.compile(r"^https?://claude\.ai/(code/)?artifacts/")
PRIORITY_WEIGHT = {"high": "0", "med": "1", "low": "2"}
# Open-section grouping (D8): computed state (blocked-by-deps, in-flight-by-
# herdr) always wins over the manual `status:` field, since it reflects
# ground truth the field can go stale against. `status: waiting` / `someday`
# only sort a todo that is neither blocked nor in-flight.
BUCKET_ORDER = ("in-flight", "ready", "blocked", "waiting", "someday")
BUCKET_LABELS = {"in-flight": "In flight", "ready": "Ready", "blocked": "Blocked",
                 "waiting": "Waiting", "someday": "Someday", "done": "Recently done"}


def die(msg):
    print(f"todos: {msg}", file=sys.stderr)
    sys.exit(1)


def warn(msg):
    print(f"todos: {msg}", file=sys.stderr)


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


# A sentence ends at . ! or ? before whitespace and a capital, digit,
# backtick, ( or quote, or at the end of the paragraph.
SENTENCE_END_RE = re.compile(r"[.!?](?=\s+[A-Z0-9`(\"']|\s*$)")
LIST_LINE_RE = re.compile(r"^\s*([-*+]|\d+\.)\s")


def strip_inline(text):
    text = re.sub(r"\[([^\]\n]+)\]\([^)\s]+\)", r"\1", text)
    text = re.sub(r"\*\*([^*\n]+)\*\*", r"\1", text)
    return text.replace("`", "")


def card_summary(text):
    """The first sentence of the first paragraph of the first ## Problem."""
    problem = next((s for s in split_sections(text)[1] if s[0] == "Problem"), None)
    if problem is None:
        return ""
    para, fenced = [], False
    for line in text[problem[2]:problem[3]].split("\n"):
        if is_fence(line):
            if para:
                break
            fenced = not fenced
        elif fenced:
            continue
        elif not line.strip():
            if para:
                break
        elif para and LIST_LINE_RE.match(line):
            break
        else:
            para.append(line.strip())
    summary = strip_inline(" ".join(para))
    end = SENTENCE_END_RE.search(summary)
    if end:
        summary = summary[:end.end()]
    if len(summary) > SUMMARY_MAX:
        summary = summary[:SUMMARY_MAX - 3].rsplit(" ", 1)[0].rstrip(",;:") + "..."
    return summary


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
    """Read-only view of tasks/<task>.{json,review.json,done.json}.

    herdr names a todo's task by the bare todo id; older records used
    td-<basename>, read when no bare-id record exists.

    The task record is authoritative for status and the live worker. The
    review record is shown as-is only when its reviewed_head_sha equals the
    record's review_head_sha, else tagged stale; the done record only when
    its phase and agent both equal the live worker's (herdr reuses one
    workspace across phases, so workspace_id proves nothing), else stale.
    """
    task_id = basename if (tasks_dir / f"{basename}.json").exists() else f"td-{basename}"
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


def read_bytes(path):
    try:
        return path.read_bytes()
    except OSError as e:
        warn(f"skipping unreadable file: {path} ({e.strerror})")
        return None


def decode_text(data):
    """What Path.read_text(errors="replace") returns: universal newlines."""
    return data.decode("utf-8", errors="replace").replace("\r\n", "\n").replace("\r", "\n")


def read_text(path):
    data = read_bytes(path)
    return None if data is None else decode_text(data)


def load_todo(path, resolver, tasks_dir, pending, confined_state):
    # One read feeds both the rendered body and the hash the note form
    # sends back, so the page never shows one version and hashes another.
    data = read_bytes(path)
    if data is None:
        return None
    text = decode_text(data)
    scalars, lists, body = frontmatter(text)
    basename = path.stem
    t = {
        "basename": basename,
        "path": path,
        "text": text,
        "sha256": hashlib.sha256(data).hexdigest(),
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
        "summary": card_summary(text),
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


def today():
    return os.environ.get("TODOS_TODAY") or datetime.date.today().isoformat()


def open_sort_key(t):
    pw = PRIORITY_WEIGHT.get(t["priority"], "3")
    if t["due"]:
        return ("0" + t["due"] + pw, t["basename"])
    return ("1" + pw + (t["created"] or "9999-99-99"), t["basename"])


def view_matches(t, view):
    """Served pages: does todo t pass the filter form's q, area and priority?"""
    haystack = (t["basename"] + "\n" + t["text"]).lower()
    if not all(term in haystack for term in view["q"].lower().split()):
        return False
    if view["area"] and t["area"] != view["area"]:
        return False
    return not view["priority"] or t["priority"] == view["priority"]


def sort_open(todos, sort):
    """Order open todos in place. Any sort other than priority or created
    keeps open_sort_key, which already puts due dates first."""
    if sort == "priority":
        todos.sort(key=lambda t: (PRIORITY_WEIGHT.get(t["priority"], "3"),
                                  t["created"] or "9999-99-99", t["basename"]))
    elif sort == "created":
        # Two stable passes: newest first, equal dates by basename, and a
        # missing date ("") last.
        todos.sort(key=lambda t: t["basename"])
        todos.sort(key=lambda t: t["created"], reverse=True)
    else:
        todos.sort(key=open_sort_key)


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

DARK_VARS = """\
  color-scheme: dark;
  --ground: #1d2125;
  --surface: #22272b;
  --surface-soft: #282e33;
  --ink: #b6c2cf;
  --muted: #8c9bab;
  --accent: #579dff;
  --rule: #38414a;
  --chip: #2c333a;
  --idle: #738496;
  --blocked: #f87168;
  --blocked-soft: #3a2022;
  --blocked-rule: #6e3a38;
  --waiting: #f0a64b;
  --waiting-soft: #36291a;
  --waiting-rule: #70522a;
  --inflight: #579dff;
  --inflight-soft: #1c2b41;
  --inflight-rule: #2b4a7a;
  --done: #4bce97;
  --done-soft: #1b3028;
  --done-rule: #2d6b52;
  --scrim: rgb(0 0 0 / 0.6);
  --shadow: 0 1px 1px rgb(0 0 0 / 0.3);
  --lift: 0 18px 48px rgb(0 0 0 / 0.5);
"""

# The dark tokens apply twice, to the OS preference and to an explicit
# choice; DARK_VARS is the one copy, substituted for @@DARK@@ below.
CSS = r"""
:root {
  color-scheme: light;
  --ground: #f4f5f7;
  --surface: #ffffff;
  --surface-soft: #f1f2f4;
  --ink: #172b4d;
  --muted: #626f86;
  --accent: #0c66e4;
  --rule: #dcdfe4;
  --chip: #f1f2f4;
  --idle: #8590a2;
  --blocked: #c9372c;
  --blocked-soft: #ffedeb;
  --blocked-rule: #f5a9a2;
  --waiting: #b65c02;
  --waiting-soft: #fffcf7;
  --waiting-rule: #f2c98a;
  --inflight: #0c66e4;
  --inflight-soft: #e9f2ff;
  --inflight-rule: #b3d4ff;
  --done: #1f845a;
  --done-soft: #f7fefb;
  --done-rule: #9ddcc0;
  --scrim: rgb(9 30 66 / 0.5);
  --shadow: 0 1px 1px rgb(9 30 66 / 0.12);
  --lift: 0 18px 48px rgb(9 30 66 / 0.3);
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
@@DARK@@  }
}

:root[data-theme="dark"] {
@@DARK@@}

* { box-sizing: border-box; }

body {
  margin: 0;
  background: var(--ground);
  color: var(--ink);
  font: 14px/1.5 "Avenir Next", "Segoe UI", system-ui, sans-serif;
}

body:has(.modal:target) { overflow: hidden; }

a { color: var(--accent); text-underline-offset: 3px; overflow-wrap: anywhere; }
a:focus-visible, .card:focus-visible, .sheet:focus-visible, summary:focus-visible {
  outline: 2px solid var(--accent);
  outline-offset: 2px;
}

.mono { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 12px; overflow-wrap: anywhere; }
.meta { color: var(--muted); font-size: 12px; font-variant-numeric: tabular-nums; }

.top {
  position: sticky;
  top: 0;
  z-index: 5;
  background: var(--ground);
  border-bottom: 1px solid var(--rule);
}

.top-inner {
  max-width: 1440px;
  margin: 0 auto;
  padding: 14px 24px 12px;
  display: grid;
  gap: 10px;
}

.top-row {
  display: flex;
  flex-wrap: wrap;
  align-items: baseline;
  gap: 6px 16px;
}

h1 {
  margin: 0;
  font-size: 20px;
  font-weight: 650;
  letter-spacing: -0.015em;
}

.counts {
  display: flex;
  flex-wrap: wrap;
  gap: 6px;
  margin-left: auto;
}

.counts a, .counts span {
  display: inline-flex;
  align-items: baseline;
  gap: 5px;
  padding: 2px 10px;
  border: 1px solid var(--rule);
  border-radius: 999px;
  background: var(--surface);
  color: var(--muted);
  font-size: 12px;
  text-decoration: none;
}

.counts b { color: var(--ink); font-variant-numeric: tabular-nums; }
.counts b[data-count="in-flight"] { color: var(--inflight); }
.counts b[data-count="blocked"] { color: var(--blocked); }
.counts b[data-count="waiting"] { color: var(--waiting); }

form.filters {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  margin: 0;
}

form.filters input, form.filters select, form.filters button, form.note button, form.note textarea {
  font: inherit;
  color: var(--ink);
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 6px;
  padding: 4px 8px;
}

button.theme { font: inherit; font-size: 12px; color: var(--muted); background: var(--surface); border: 1px solid var(--rule); border-radius: 999px; padding: 2px 10px; cursor: pointer; }
form.filters input[type="search"] { flex: 1 1 18em; }
form.filters .meta { margin: 0 0 0 auto; }

main {
  max-width: 1440px;
  margin: 0 auto;
  padding: 16px 24px 64px;
}

.lane { margin: 0 0 22px; scroll-margin-top: 120px; }
#lane-in-flight { --lane: var(--inflight); }
#lane-ready { --lane: var(--idle); }
#lane-blocked { --lane: var(--blocked); }
#lane-waiting { --lane: var(--waiting); }
#lane-someday { --lane: var(--idle); }
#lane-done { --lane: var(--done); }

.lane h2 {
  display: flex;
  align-items: center;
  gap: 8px;
  margin: 0 0 8px;
  padding-bottom: 6px;
  border-bottom: 2px solid var(--lane, var(--rule));
  font-size: 13px;
  font-weight: 650;
  letter-spacing: 0.02em;
  text-transform: uppercase;
  color: var(--lane, var(--muted));
}

details.lane > summary { cursor: pointer; list-style: none; width: fit-content; }
details.lane > summary::-webkit-details-marker { display: none; }
details.lane > summary h2::before { content: "\25B8"; transition: transform 0.15s ease; }
details.lane[open] > summary h2::before { transform: rotate(90deg); }

.bucket-count {
  display: inline-flex;
  min-width: 20px;
  height: 18px;
  padding: 0 6px;
  align-items: center;
  justify-content: center;
  border-radius: 999px;
  background: var(--surface-soft);
  color: var(--muted);
  font-size: 11px;
  font-variant-numeric: tabular-nums;
  letter-spacing: 0;
}

ul.cards {
  display: grid;
  grid-template-columns: repeat(auto-fill, minmax(270px, 1fr));
  gap: 10px;
  margin: 0;
  padding: 0;
  list-style: none;
}

a.card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  height: 100%;
  padding: 10px 12px 10px 13px;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-left: 3px solid var(--lane, var(--idle));
  border-radius: 8px;
  box-shadow: var(--shadow);
  color: var(--ink);
  text-decoration: none;
}

a.card[data-state="blocked"] { background: var(--blocked-soft); }

@media (hover: hover) {
  a.card:hover { border-color: var(--lane, var(--accent)); }
}

.card-title {
  font-weight: 600;
  line-height: 1.35;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
}

.card-summary {
  color: var(--muted);
  font-size: 13px;
  line-height: 1.45;
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 2;
  overflow: hidden;
}

.badges {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
  margin-top: auto;
  padding-top: 2px;
}

.badge {
  display: inline-block;
  max-width: 100%;
  padding: 0 7px;
  border: 1px solid var(--rule);
  border-radius: 999px;
  background: var(--chip);
  color: var(--muted);
  font-size: 11px;
  line-height: 18px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.badge.prio-high, .badge.blocked, .badge.overdue, .badge.unreadable {
  background: var(--blocked-soft);
  border-color: var(--blocked-rule);
  color: var(--blocked);
  font-weight: 600;
}

.badge.prio-med {
  background: var(--waiting-soft);
  border-color: var(--waiting-rule);
  color: var(--waiting);
}

.badge.in-flight {
  background: var(--inflight-soft);
  border-color: var(--inflight-rule);
  color: var(--inflight);
}

.badge.in-flight { font-weight: 600; }

.badge.merged {
  background: var(--done-soft);
  border-color: var(--done-rule);
  color: var(--done);
}

.empty {
  margin: 0;
  padding: 16px;
  border: 1px dashed var(--rule);
  border-radius: 8px;
  color: var(--muted);
}

ul.research { display: grid; gap: 6px; margin: 0; padding: 0; list-style: none; }

ul.research > li {
  padding: 8px 12px;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 8px;
  font-size: 13px;
}

ul.research .name { font-weight: 600; }

.sub { color: var(--muted); font-size: 12px; }

.chip, .pill {
  display: inline-block;
  max-width: 100%;
  padding: 0 7px;
  border: 1px solid var(--rule);
  border-radius: 999px;
  background: var(--chip);
  color: var(--muted);
  font-size: 11px;
  line-height: 18px;
  overflow-wrap: anywhere;
}

.pill { font-weight: 600; }

.pill.merged {
  background: var(--done-soft);
  border-color: var(--done-rule);
  color: var(--done);
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

/* The modal is shown by :target alone, so the static page needs no script.
   No ancestor of .modal may set transform, filter or contain: that would
   re-anchor position: fixed to the ancestor instead of the viewport. */
.modal {
  display: none;
  position: fixed;
  inset: 0;
  z-index: 20;
  padding: 5vh 16px;
  overflow-y: auto;
}

.modal:target { display: block; }

.modal > .backdrop {
  position: fixed;
  inset: 0;
  background: var(--scrim);
}

.sheet {
  position: relative;
  max-width: 1040px;
  margin: 0 auto;
  background: var(--surface);
  border: 1px solid var(--rule);
  border-radius: 12px;
  box-shadow: var(--lift);
}

.sheet-head {
  display: grid;
  grid-template-columns: 1fr auto;
  gap: 6px 16px;
  padding: 18px 22px 14px;
  border-bottom: 1px solid var(--rule);
}

.sheet-head h2 {
  margin: 0;
  font-size: 20px;
  font-weight: 650;
  line-height: 1.3;
  letter-spacing: -0.01em;
  overflow-wrap: anywhere;
}

.sheet-head .badges { grid-column: 1 / -1; margin: 0; }

a.close {
  grid-row: 1;
  grid-column: 2;
  align-self: start;
  padding: 0 8px;
  border: 1px solid var(--rule);
  border-radius: 6px;
  color: var(--muted);
  font-size: 20px;
  line-height: 28px;
  text-decoration: none;
}

.prd, .facts { overflow-wrap: anywhere; }

.sheet-body {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 290px;
}

.prd {
  min-width: 0;
  padding: 6px 22px 22px;
  font-size: 14px;
  line-height: 1.6;
}

.prd h4 { margin: 18px 0 6px; font-size: 13px; text-transform: uppercase; letter-spacing: 0.03em; color: var(--muted); }
.prd h5 { margin: 12px 0 4px; font-size: 13px; }
.prd p, .prd ul.md { margin: 0 0 10px; }
.prd pre { overflow-x: auto; padding: 10px 12px; background: var(--surface-soft); border-radius: 6px; font-size: 12px; }
.prd code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: 12px; }

ul.md { padding-left: 18px; }
ul.md li.d1 { margin-left: 18px; }
ul.md li.d2 { margin-left: 36px; }
ul.md li.d3 { margin-left: 54px; }

form.note { display: grid; gap: 6px; margin: 4px 0 14px; color: var(--muted); font-size: 12px; }
form.note textarea { width: 100%; }
form.note button { width: fit-content; }

.facts {
  min-width: 0;
  padding: 16px 18px 20px;
  border-left: 1px solid var(--rule);
  background: var(--surface-soft);
  border-bottom-right-radius: 12px;
  font-size: 13px;
}

.facts h3 {
  margin: 14px 0 4px;
  color: var(--muted);
  font-size: 11px;
  font-weight: 650;
  letter-spacing: 0.04em;
  text-transform: uppercase;
}

.facts h3:first-child { margin-top: 0; }
.facts ul { margin: 0; padding: 0; list-style: none; }
.facts li + li { margin-top: 3px; }
.facts .dep.bad { color: var(--blocked); font-weight: 600; }
.facts .sub { color: var(--muted); }

.copy-chips { display: flex; flex-wrap: wrap; gap: 4px; }

button.copy {
  font: 12px/1.5 "SF Mono", Menlo, Consolas, monospace;
  color: var(--muted);
  background: var(--chip);
  border: 1px solid var(--rule);
  border-radius: 5px;
  padding: 1px 6px;
  cursor: pointer;
  max-width: 100%;
  overflow-wrap: anywhere;
  text-align: left;
}

@media (max-width: 860px) {
  .sheet-body { grid-template-columns: minmax(0, 1fr); }
  .facts { border-left: 0; border-top: 1px solid var(--rule); border-radius: 0 0 12px 12px; }
}

@media (max-width: 640px) {
  .top-inner, main { padding-left: 16px; padding-right: 16px; }
  .counts { margin-left: 0; }
  .modal { padding: 0; }
  .sheet { border-radius: 0; min-height: 100%; }
}
"""

CSS = CSS.replace("@@DARK@@", DARK_VARS)


# Served pages only. todos_serve.py allows exactly this text by its hash in
# the CSP header, so the header follows any edit here.
BOARD_JS = r"""
document.addEventListener("click", function (event) {
  var button = event.target.closest("button.copy");
  if (!button) return;
  if (!button.dataset.label) button.dataset.label = button.textContent;
  function show(text) {
    button.textContent = text;
    setTimeout(function () { button.textContent = button.dataset.label; }, 1500);
  }
  if (!navigator.clipboard) return show("copy failed");
  navigator.clipboard.writeText(button.dataset.copy).then(
    function () { show("copied"); },
    function () { show("copy failed"); });
});

// Theme: System follows the OS; Light and Dark set data-theme on <html>.
var THEMES = ["system", "light", "dark"];
var THEME_KEY = "todos-board-theme";

function applyTheme(name) {
  var root = document.documentElement;
  if (name === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", name);
  var toggle = document.querySelector("button.theme");
  if (toggle) toggle.textContent = "Theme: " + name.charAt(0).toUpperCase() + name.slice(1);
}

function savedTheme() {
  try {
    var name = localStorage.getItem(THEME_KEY);
    return THEMES.indexOf(name) >= 0 ? name : "system";
  } catch (e) { return "system"; }
}

document.addEventListener("click", function (event) {
  if (!event.target.closest("button.theme")) return;
  var current = document.documentElement.getAttribute("data-theme") || "system";
  var next = THEMES[(THEMES.indexOf(current) + 1) % THEMES.length];
  applyTheme(next);
  try { localStorage.setItem(THEME_KEY, next); } catch (e) { /* not remembered */ }
});

applyTheme(savedTheme());

// The todo id whose modal is open, so closing can return focus to its card
// even when the modal was opened by a link or a reload, not a card click.
var openId = null;

function openModal() {
  var match = /^#todo-(.+)$/.exec(location.hash);
  if (!match) return null;
  var id;
  try { id = decodeURIComponent(match[1]); } catch (e) { return null; }
  var modal = document.getElementById("todo-" + id);
  return modal && modal.classList.contains("modal") ? modal : null;
}

function syncFocus() {
  var modal = openModal();
  if (modal) {
    openId = modal.dataset.modal;
    modal.querySelector(".sheet").focus({ preventScroll: true });
    return;
  }
  if (openId === null) return;
  var cards = document.querySelectorAll("a.card");
  for (var i = 0; i < cards.length; i++) {
    if (cards[i].dataset.todo === openId) {
      var lane = cards[i].closest("details");
      if (lane) lane.open = true;
      cards[i].focus();
      break;
    }
  }
  openId = null;
}

document.addEventListener("click", function (event) {
  if (event.target.closest("a.close, a.backdrop")) {
    event.preventDefault();
    location.replace("#board");
  }
});

document.addEventListener("keydown", function (event) {
  if (event.key === "Escape" && openModal()) {
    event.preventDefault();
    location.replace("#board");
  } else if (event.key === "/" && !openModal() &&
             !event.target.closest("input, textarea, select")) {
    var search = document.querySelector("form.filters input[name=q]");
    if (search) {
      event.preventDefault();
      search.focus();
    }
  }
});

// On load, not at parse time: a fragment target is only styled once the
// document has loaded, and focusing a hidden sheet does nothing.
window.addEventListener("hashchange", syncFocus);
window.addEventListener("load", syncFocus);
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

def note_form(t, section, token):
    """Served pages only: append a note to one section (todos.sh note)."""
    return ('<form class="note" method="post" action="/note">'
            f'<input type="hidden" name="id" value="{esc(t["basename"])}">'
            f'<input type="hidden" name="section" value="{esc(section)}">'
            f'<input type="hidden" name="sha" value="{esc(t["sha256"])}">'
            f'<input type="hidden" name="token" value="{esc(token)}">'
            f'<label for="note-{esc(t["basename"])}-{esc(section)}">Add a note to {esc(section)}</label>'
            f'<textarea id="note-{esc(t["basename"])}-{esc(section)}" name="note" rows="3" required></textarea>'
            '<button type="submit">Add note</button></form>')


# Same rule as TODO_ID_RE in todos.sh; \Z so a trailing newline cannot pass.
TODO_ID_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]*[a-z0-9]\Z")


def copy_chips(basename):
    """Served pending rows: buttons that copy the id and ready-made commands."""
    if not TODO_ID_RE.match(basename):
        return ""
    items = ((basename, basename), ("done", f"todos.sh done {basename}"),
             ("kick off", f"kick off {basename}"))
    buttons = "".join(
        f'<button type="button" class="copy" data-copy="{esc(cmd)}" title="Copy: {esc(cmd)}">{esc(label)}</button>'
        for label, cmd in items)
    return f'<div class="copy-chips">{buttons}</div>'


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


def badge(text, cls):
    # cls is always a literal from this file, never user data; escaped anyway.
    return f'<span class="badge {esc(cls)}">{esc(text)}</span>'


def herdr_badge(t, pending):
    h = t["herdr"]
    if h is None:
        return ""
    if pending and h["status"] in IN_FLIGHT_STATUSES:
        return badge("in flight" + (f" - {h['phase']}" if h["phase"] else ""), "in-flight")
    if h["status"] == "merged":
        return badge("merged", "merged")
    if h["status"] == "unreadable":
        return badge("herdr unreadable", "unreadable")
    return ""


def deps_badge(t, pending):
    if not pending or not t["deps"]:
        return ""
    unmet = sum(1 for _, state in t["deps"] if state not in SATISFIED)
    if unmet:
        return badge(f"blocked by {unmet}", "blocked")
    return badge(f"{len(t['deps'])} deps met", "deps-ok")


def date_badge(t):
    if t["due"]:
        return badge(f"due {t['due']}", "overdue" if t["due"] < today() else "due")
    if t["surface"] and t["surface"] > today():
        return badge(f"surfaces {t['surface']}", "surface")
    return ""


def card_badges(t, pending):
    prio = t["priority"]
    parts = [herdr_badge(t, pending), deps_badge(t, pending),
             badge(prio, f"prio-{prio}" if prio in PRIORITY_WEIGHT else "prio-other") if prio else "",
             badge(t["area"], "area") if t["area"] else "",
             date_badge(t)]
    return f'<span class="badges">{"".join(parts)}</span>'


def render_card(t, pending):
    status = t["herdr"]["status"] if t["herdr"] else ""
    state = f' data-state="{"blocked" if t["blocked"] else "open"}"' if pending else ""
    prio = f' data-priority="{t["priority"]}"' if t["priority"] in PRIORITY_WEIGHT else ""
    summary = f'<span class="card-summary">{esc(t["summary"])}</span>' if t["summary"] else ""
    return (f'<li><a class="card" href="#todo-{esc(t["basename"])}" data-todo="{esc(t["basename"])}"'
            f'{state} data-task-status="{esc(status)}"{prio}>'
            f'<span class="card-title">{esc(t["title"])}</span>{summary}'
            f'{card_badges(t, pending)}</a></li>')


def render_lane(key, todos, pending, collapsed, opened=False):
    heading = (f'<h2 data-bucket="{key}">{esc(BUCKET_LABELS[key])} '
               f'<span class="bucket-count">{len(todos)}</span></h2>')
    cards = '<ul class="cards">' + "".join(render_card(t, pending) for t in todos) + "</ul>"
    if collapsed:
        is_open = " open" if opened else ""
        return f'<details class="lane" id="lane-{key}"{is_open}><summary>{heading}</summary>{cards}</details>'
    return f'<section class="lane" id="lane-{key}">{heading}{cards}</section>'


def render_counts(open_todos):
    # Each todo counts once, in the bucket open_bucket gives it.
    buckets = [open_bucket(t) for t in open_todos]
    pills = [f'<span><b data-count="open">{len(open_todos)}</b> open</span>']
    for key in BUCKET_ORDER:
        pills.append(f'<a href="#lane-{key}"><b data-count="{key}">{buckets.count(key)}</b> '
                     f'{esc(BUCKET_LABELS[key].lower())}</a>')
    return f'<nav class="counts" aria-label="Lanes">{"".join(pills)}</nav>'


def render_deps(t, on_page):
    items = []
    for ref, state in t["deps"]:
        label = f"{esc(ref)} ({esc(state)})"
        target = ref[len("todo:"):] if ref.startswith("todo:") else ""
        if target in on_page:
            label = f'<a href="#todo-{esc(target)}">{label}</a>'
        items.append(f'<li class="dep {"ok" if state in SATISFIED else "bad"} mono">{label}</li>')
    return "<ul>" + "".join(items) + "</ul>"


def render_facts(t, pending, edit, on_page):
    out = []
    chips = copy_chips(t["basename"]) if edit is not None and pending else ""
    if chips:
        out.append("<h3>Copy</h3>" + chips)
    else:
        out.append(f'<h3>Id</h3><div class="mono">{esc(t["basename"])}</div>')
    dates = [f"{label} {t[key]}" for label, key in (("created", "created"), ("due", "due"),
                                                     ("surfaces", "surface")) if t[key]]
    if dates:
        out.append("<h3>Dates</h3><ul>" + "".join(f"<li>{esc(d)}</li>" for d in dates) + "</ul>")
    level = " / ".join(x for x in (t["maturity"], t["tier"]) if x)
    if level:
        out.append(f"<h3>Maturity / tier</h3><div>{esc(level)}</div>")
    if t["deps"]:
        out.append("<h3>Depends on</h3>" + render_deps(t, on_page))
    if t["herdr"]:
        out.append("<h3>Herdr</h3>" + render_herdr(t["herdr"]))
    if t["files"]:
        out.append("<h3>Files</h3><ul>" + "".join(f'<li class="mono">{esc(f)}</li>' for f in t["files"]) + "</ul>")
    if t["links"]:
        out.append("<h3>Links</h3><ul>" + "".join(
            f'<li><a href="{esc(u)}">{esc(label)}</a></li>' for label, u in t["links"]) + "</ul>")
    return "".join(out)


def render_modal(t, pending, edit, on_page):
    """One todo's details, shown by CSS :target when the URL is #todo-<id>.

    edit is None on the static page; on a served page it is {"token", ...}
    and a pending todo gets a note form after each note section.
    """
    def forms(name):
        return note_form(t, name, edit["token"]) if name in NOTE_SECTIONS else ""

    bid = esc(t["basename"])
    body = render_body(t["text"], forms if edit is not None and pending else None)
    return (f'<div class="modal" id="todo-{bid}" data-modal="{bid}" role="dialog" aria-labelledby="title-{bid}">'
            '<a class="backdrop" href="#board" tabindex="-1" aria-hidden="true"></a>'
            '<article class="sheet" tabindex="-1"><header class="sheet-head">'
            f'<h2 id="title-{bid}">{esc(t["title"])}</h2>'
            '<a class="close" href="#board" aria-label="Close">&times;</a>'
            f'{card_badges(t, pending)}</header>'
            f'<div class="sheet-body"><div class="prd">{body}</div>'
            f'<aside class="facts">{render_facts(t, pending, edit, on_page)}</aside></div>'
            "</article></div>")


def render_lanes(open_todos, completed, show_completed, edit):
    grouped = {key: [] for key in BUCKET_ORDER}
    for t in open_todos:
        grouped[open_bucket(t)].append(t)
    lanes = [render_lane(key, grouped[key], True, key == "someday")
             for key in BUCKET_ORDER if grouped[key]]
    if not open_todos:
        lanes.append('<p class="empty">No open todos.</p>')
    if show_completed and completed:
        view = edit["view"] if edit else {}
        searching = any(view.get(k) for k in ("q", "area", "priority"))
        lanes.append(render_lane("done", completed, False, True, searching))
    return "".join(lanes)


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


SORT_CHOICES = (("", "Due date, then priority"), ("priority", "Priority"), ("created", "Newest"))


def render_select(name, label, choices, current):
    opts = "".join(
        f'<option value="{esc(value)}"{" selected" if value == current else ""}>{esc(text)}</option>'
        for value, text in choices)
    return f'<select name="{name}" aria-label="{label}">{opts}</select>'


def render_filters(view, todos, token, shown, total):
    """Served pages: the GET form behind view_matches and sort_open.

    The URL's area or priority is listed even when no todo has it, so the
    form always shows the state the page was built from.
    """
    def choices(key, all_label):
        values = {t[key] for t in todos if t[key]} | ({view[key]} if view[key] else set())
        return [("", all_label)] + [(v, v) for v in sorted(values)]

    sort = view["sort"] if view["sort"] in dict(SORT_CHOICES) else ""
    return ('<form class="filters" method="get" action="/">'
            f'<input type="hidden" name="t" value="{esc(token)}">'
            f'<input type="search" name="q" value="{esc(view["q"])}" placeholder="Search" aria-label="Search">'
            + render_select("area", "Area", choices("area", "All areas"), view["area"])
            + render_select("priority", "Priority", choices("priority", "All priorities"), view["priority"])
            + render_select("sort", "Sort", SORT_CHOICES, sort)
            + '<button type="submit">Apply</button>'
            f'<a href="/?t={esc(token)}">Clear</a>'
            f'<p class="meta" data-match="{shown}/{total}">Showing {shown} of {total} open todos.</p>'
            "</form>")


def render_page(repo_name, branch, stamp, open_todos, completed, research, show_completed,
                edit=None, filters=""):
    if edit is None:
        how = "Static page: rerun <span class=\"mono\">todos.sh dashboard</span> and reload to refresh."
    else:
        how = ("Served by <span class=\"mono\">todos.sh serve</span>: reload to refresh; "
               "notes are appended to the todo file.")
    shown_completed = completed if show_completed else []
    on_page = {t["basename"] for t in open_todos} | {t["basename"] for t in shown_completed}
    modals = ("".join(render_modal(t, True, edit, on_page) for t in open_todos)
              + "".join(render_modal(t, False, edit, on_page) for t in shown_completed))
    script = f"<script>{BOARD_JS}</script>" if edit is not None else ""
    theme_toggle = '<button type="button" class="theme">Theme: System</button>' if edit is not None else ""
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(repo_name)} board</title>
<style>{CSS}</style>
</head>
<body>
<header class="top"><div class="top-inner">
<div class="top-row"><h1>{esc(repo_name)} board</h1>
<span class="meta">generated {esc(stamp)} on <span class="mono">{esc(branch)}</span>. {how}</span>
{render_counts(open_todos)}{theme_toggle}</div>
{filters}
</div></header>
<main>
{render_lanes(open_todos, completed, show_completed, edit)}
<section class="lane" id="research"><h2>Research <span class="bucket-count">{len(research)}</span></h2>
{render_research(research)}</section>
</main>
<div class="modals">{modals}</div>
{script}
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


def board_context(args):
    """Repo, account scope and paths: everything a page build needs that
    does not change between builds (todos.sh serve builds one per request)."""
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
    state_root = default_state_root(scope)
    return {
        "root": root,
        "scope": scope,
        "slug": slug,
        "todos_dir": root / TODOS_DIRNAME,
        "state_root": state_root,
        "tasks_dir": state_root / slug / "tasks",
        "confined_state": not bool(os.environ.get("TODOS_STATE_ROOT")),
    }


def build_page(ctx, args, edit=None):
    """Read the board fresh and render it; edit as in render_modal, plus,
    on a served page, edit["view"]: the filter form's q, area, priority, sort."""
    root, todos_dir = ctx["root"], ctx["todos_dir"]
    _, branch = git(["rev-parse", "--abbrev-ref", "HEAD"], cwd=root)
    resolver = Resolver(root, args.online)
    pending = load_dir(todos_dir / "pending", resolver, ctx["tasks_dir"], True, ctx["confined_state"])
    completed = load_dir(todos_dir / "completed", resolver, ctx["tasks_dir"], False, ctx["confined_state"])
    view = edit["view"] if edit else None
    filters = ""
    if view:
        shown = [t for t in pending if view_matches(t, view)]
        filters = render_filters(view, pending + completed, edit["token"], len(shown), len(pending))
        pending = shown
        completed = [t for t in completed if view_matches(t, view)]
    sort_open(pending, view["sort"] if view else "")
    completed.sort(key=lambda t: (t["created"], t["basename"]), reverse=True)
    completed = completed[:args.completed]
    known = {t["basename"] for t in pending} | {t["basename"] for t in completed}
    research = load_research(todos_dir / "research", known)
    stamp = os.environ.get("TODOS_DASHBOARD_NOW") or datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
    return render_page(root.name, branch, stamp, pending, completed, research, args.completed > 0, edit,
                       filters)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    ctx = board_context(args)
    todos_dir = ctx["todos_dir"]
    out = Path(args.out) if args.out else default_out_dir(ctx["scope"]["account_id"]) / f"{ctx['slug']}.html"
    out = out if out.is_absolute() else Path.cwd() / out
    guard_out_path(out, [(f"{TODOS_DIRNAME}/", todos_dir), ("the herdr state root", ctx["state_root"])])

    if todos_dir.is_dir():
        visibility_warning(ctx["root"])
    page = build_page(ctx, args)

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
