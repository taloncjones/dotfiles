#!/bin/sh
# herdr-capabilities.test.sh - capability constants and procedure marker parsing.
# Stdlib python only; no network, no herdr.
set -e
TMPDIR=$(python3 -c 'import os,tempfile; print(os.path.realpath(tempfile.gettempdir()))'); export TMPDIR
PASS=0
FAIL=0

check() {
    label="$1"
    body=$(cat)
    first_line=$(printf '%s\n' "$body" | head -n 1)
    case "$first_line" in
        import*) runner="python3 -" ;;
        *) runner="sh -e -" ;;
    esac
    if printf '%s\n' "$body" | $runner; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s\n' "$label" >&2; FAIL=$((FAIL + 1))
    fi
}

LOAD='import importlib.util,sys,os,tempfile,json,pathlib
spec=importlib.util.spec_from_file_location("caps","claude/hooks/herdr_capabilities.py")
k=importlib.util.module_from_spec(spec);spec.loader.exec_module(k)'

check "constants: core and guard advertise 1, required is 1" <<PY
$LOAD
assert k.CORE_CAPABILITY == 1, k.CORE_CAPABILITY
assert k.GUARD_CAPABILITY == 1, k.GUARD_CAPABILITY
assert k.REQUIRED_CAPABILITY == 1, k.REQUIRED_CAPABILITY
assert k.MARKER_VERSION == 1, k.MARKER_VERSION
sys.exit(0)
PY

check "parse_marker: valid marker yields its capability" <<PY
$LOAD
t = 'prose\n<!-- herdr-capabilities: {"marker_version":1,"capability":0} -->\nmore\n'
assert k.parse_marker(t) == 0, k.parse_marker(t)
t1 = '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n'
assert k.parse_marker(t1) == 1, k.parse_marker(t1)
sys.exit(0)
PY

check "parse_marker: missing, duplicated, malformed all fail closed" <<PY
$LOAD
assert k.parse_marker('no marker here\n') is None
dup = ('<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n'
       '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')
assert k.parse_marker(dup) is None
assert k.parse_marker('<!-- herdr-capabilities: not json -->\n') is None
assert k.parse_marker('<!-- herdr-capabilities: [1,2] -->\n') is None
sys.exit(0)
PY

check "parse_marker: non-integer and boolean capability rejected" <<PY
$LOAD
assert k.parse_marker('<!-- herdr-capabilities: {"marker_version":1,"capability":"1"} -->\n') is None
assert k.parse_marker('<!-- herdr-capabilities: {"marker_version":1,"capability":1.0} -->\n') is None
assert k.parse_marker('<!-- herdr-capabilities: {"marker_version":1,"capability":true} -->\n') is None
assert k.parse_marker('<!-- herdr-capabilities: {"marker_version":true,"capability":1} -->\n') is None
sys.exit(0)
PY

check "parse_marker: unknown marker_version is unsupported" <<PY
$LOAD
assert k.parse_marker('<!-- herdr-capabilities: {"marker_version":2,"capability":1} -->\n') is None
assert k.parse_marker('<!-- herdr-capabilities: {"capability":1} -->\n') is None
sys.exit(0)
PY

check "procedure_capability: absent skill file is unsupported, not an error" <<PY
$LOAD
d = pathlib.Path(tempfile.mkdtemp())
assert k.procedure_capability(d) is None
sys.exit(0)
PY

check "procedure_capability: reads the installed skill under the config dir" <<PY
$LOAD
d = pathlib.Path(tempfile.mkdtemp())
p = d / "skills" / "herdr-orchestration"
p.mkdir(parents=True)
(p / "SKILL.md").write_text('<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')
assert k.procedure_capability(d) == 1, k.procedure_capability(d)
sys.exit(0)
PY

check "procedure_capability: non-path input is unsupported, not an error" <<PY
$LOAD
assert k.procedure_capability(None) is None
assert k.procedure_capability(12345) is None
assert k.procedure_capability(object()) is None
sys.exit(0)
PY

check "gate: absence means disabled" <<PY
$LOAD
rd = pathlib.Path(tempfile.mkdtemp())
ok, why = k.gate_enabled(rd, "slug-a", "acct-1")
assert ok is False, (ok, why)
assert "absent" in why, why
sys.exit(0)
PY

check "gate: a well-formed enabled record with matching identity is enabled" <<PY
$LOAD
rd = pathlib.Path(tempfile.mkdtemp())
(rd / "task-lead-gate.json").write_text(json.dumps({
    "schema_version": 1, "repo_slug": "slug-a", "repo_id": None,
    "account_id": "acct-1", "enabled": True}))
ok, why = k.gate_enabled(rd, "slug-a", "acct-1")
assert ok is True, (ok, why)
sys.exit(0)
PY

check "gate: malformed, wrong-version, and non-bool enabled all disable" <<PY
$LOAD
def gate(payload):
    rd = pathlib.Path(tempfile.mkdtemp())
    (rd / "task-lead-gate.json").write_text(payload)
    return k.gate_enabled(rd, "slug-a", "acct-1")
assert gate("{not json")[0] is False
assert gate("[]")[0] is False
base = {"schema_version": 1, "repo_slug": "slug-a", "repo_id": None,
        "account_id": "acct-1", "enabled": True}
assert gate(json.dumps(dict(base, schema_version=2)))[0] is False
assert gate(json.dumps(dict(base, enabled="yes")))[0] is False
sys.exit(0)
PY

check "gate: identity mismatch disables, with a distinct reason" <<PY
$LOAD
rd = pathlib.Path(tempfile.mkdtemp())
(rd / "task-lead-gate.json").write_text(json.dumps({
    "schema_version": 1, "repo_slug": "slug-a", "repo_id": None,
    "account_id": "acct-1", "enabled": True}))
ok_slug, why_slug = k.gate_enabled(rd, "slug-b", "acct-1")
ok_acct, why_acct = k.gate_enabled(rd, "slug-a", "acct-2")
assert ok_slug is False and "slug" in why_slug, (ok_slug, why_slug)
assert ok_acct is False and "account" in why_acct, (ok_acct, why_acct)
sys.exit(0)
PY

check "gate: an explicitly disabled record is disabled" <<PY
$LOAD
rd = pathlib.Path(tempfile.mkdtemp())
(rd / "task-lead-gate.json").write_text(json.dumps({
    "schema_version": 1, "repo_slug": "slug-a", "repo_id": None,
    "account_id": "acct-1", "enabled": False}))
ok, why = k.gate_enabled(rd, "slug-a", "acct-1")
assert ok is False and "disabled" in why, (ok, why)
sys.exit(0)
PY

check "gate: repo_id matching is nullable but fails closed when uncorroborated" <<PY
$LOAD
def gate(stated, expected):
    rd = pathlib.Path(tempfile.mkdtemp())
    (rd / "task-lead-gate.json").write_text(json.dumps({
        "schema_version": 1, "repo_slug": "slug-a", "repo_id": stated,
        "account_id": "acct-1", "enabled": True}))
    return k.gate_enabled(rd, "slug-a", "acct-1", expected)
assert gate(None, None)[0] is True
assert gate(None, "rid-1")[0] is True
assert gate("rid-1", "rid-1")[0] is True
assert gate("rid-1", "rid-2")[0] is False
ok, why = gate("rid-1", None)
assert ok is False and "corroborate" in why, (ok, why)
ok, why = gate(123, "rid-1")
assert ok is False and "malformed" in why, (ok, why)
sys.exit(0)
PY

check "gate: an orphaned temporary file is inert" <<PY
$LOAD
rd = pathlib.Path(tempfile.mkdtemp())
(rd / ".task-lead-gate.json.tmp12345").write_text(json.dumps({
    "schema_version": 1, "repo_slug": "slug-a", "repo_id": None,
    "account_id": "acct-1", "enabled": True}))
ok, why = k.gate_enabled(rd, "slug-a", "acct-1")
assert ok is False, (ok, why)
sys.exit(0)
PY

check "gate: non-path payload root is disabled, not an error" <<PY
$LOAD
for bad in (None, 12345, [], object()):
    ok, why = k.gate_enabled(bad, "slug-a", "acct-1")
    assert ok is False, (bad, ok, why)
    assert isinstance(why, str) and why, (bad, why)
sys.exit(0)
PY

check "shipped SKILL.md declares exactly one marker at capability 0" <<PY
$LOAD
text = open("claude/skills/herdr-orchestration/SKILL.md", encoding="utf-8").read()
cap = k.parse_marker(text)
assert cap == 0, cap
sys.exit(0)
PY

check "shipped procedure is below the required level, so leads cannot be admitted" <<PY
$LOAD
text = open("claude/skills/herdr-orchestration/SKILL.md", encoding="utf-8").read()
assert k.parse_marker(text) < k.REQUIRED_CAPABILITY
sys.exit(0)
PY

# The two readers' hardening was previously pinned by nothing: no case in this
# suite mentioned symlink, FIFO, O_NOFOLLOW, O_NONBLOCK or S_ISREG, so a change
# dropping any of those flags would have shipped green. Each case below fails
# if the corresponding flag is removed.

check "gate: a symlinked record is refused, not followed" <<PY
$LOAD
d = tempfile.mkdtemp(); elsewhere = tempfile.mkdtemp()
real = os.path.join(elsewhere, "planted.json")
open(real, "w").write(json.dumps({"schema_version": 1, "repo_slug": "s",
                                  "repo_id": None, "account_id": "a", "enabled": True}))
os.symlink(real, os.path.join(d, k.GATE_NAME))
ok, why = k.gate_enabled(d, "s", "a")
assert ok is False, (ok, why)
sys.exit(0)
PY

check "gate: a symlinked PARENT is refused, not followed" <<PY
$LOAD
base = tempfile.mkdtemp(); elsewhere = tempfile.mkdtemp()
open(os.path.join(elsewhere, k.GATE_NAME), "w").write(json.dumps(
    {"schema_version": 1, "repo_slug": "s", "repo_id": None,
     "account_id": "a", "enabled": True}))
link = os.path.join(base, "slug")
os.symlink(elsewhere, link)
ok, why = k.gate_enabled(link, "s", "a")
assert ok is False, (ok, why)
sys.exit(0)
PY

check "gate: a FIFO record returns instead of blocking the hook" <<PY
$LOAD
import subprocess
# NOT an in-process SIGALRM. An earlier version of this case used one and was
# vacuous: the handler's AssertionError is raised INSIDE gate_enabled, whose
# own \`except Exception\` swallows it into exactly the (False, ...) the
# assertion accepted -- so stripping O_NONBLOCK left the case green after five
# seconds. Two independent teeth instead: an EXTERNAL wall-clock cap, which
# nothing in the module can catch, and the specific reason, which only the
# S_ISREG path produces.
child = '''
import os, sys, tempfile, importlib.util
spec = importlib.util.spec_from_file_location("caps", "claude/hooks/herdr_capabilities.py")
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
d = tempfile.mkdtemp()
os.mkfifo(os.path.join(d, k.GATE_NAME))
ok, why = k.gate_enabled(d, "s", "a")
sys.stdout.write("%s\\t%s" % (ok, why))
'''
r = subprocess.run([sys.executable, "-c", child], capture_output=True, text=True, timeout=10)
assert r.returncode == 0, (r.returncode, r.stderr)
flag, why = r.stdout.split("\\t", 1)
assert flag == "False", (flag, why)
assert "regular file" in why, why
sys.exit(0)
PY

check "procedure: a symlinked marker is refused, not followed" <<PY
$LOAD
cfg = tempfile.mkdtemp(); elsewhere = tempfile.mkdtemp()
planted = os.path.join(elsewhere, "planted.md")
open(planted, "w").write('<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')
d = os.path.join(cfg, "skills", "herdr-orchestration")
os.makedirs(d)
os.symlink(planted, os.path.join(d, "SKILL.md"))
assert k.procedure_capability(cfg) is None, k.procedure_capability(cfg)
sys.exit(0)
PY

check "procedure: a FIFO marker returns instead of blocking the hook" <<PY
$LOAD
import subprocess
# External wall-clock cap, for the reason the gate FIFO case states. This one
# also asserts on _read_procedure_text directly, because procedure_capability
# flattens every failure to None and so cannot distinguish "refused a FIFO"
# from "blocked, then got interrupted".
child = '''
import os, sys, tempfile, importlib.util
spec = importlib.util.spec_from_file_location("caps", "claude/hooks/herdr_capabilities.py")
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
cfg = tempfile.mkdtemp()
d = os.path.join(cfg, "skills", "herdr-orchestration")
os.makedirs(d)
p = os.path.join(d, "SKILL.md")
os.mkfifo(p)
try:
    k._read_procedure_text(p)
    sys.stdout.write("NO-REFUSAL")
except ValueError as exc:
    sys.stdout.write("refused\\t%s\\t%s" % (exc, k.procedure_capability(cfg)))
'''
r = subprocess.run([sys.executable, "-c", child], capture_output=True, text=True, timeout=10)
assert r.returncode == 0, (r.returncode, r.stderr)
parts = r.stdout.split("\\t")
assert parts[0] == "refused", r.stdout
assert "regular file" in parts[1], parts[1]
assert parts[2] == "None", parts[2]
sys.exit(0)
PY

check "procedure: a symlinked PARENT is still followed, as the install needs" <<PY
$LOAD
cfg = tempfile.mkdtemp(); elsewhere = tempfile.mkdtemp()
real = os.path.join(elsewhere, "herdr-orchestration")
os.makedirs(real)
open(os.path.join(real, "SKILL.md"), "w").write(
    '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->\n')
skills = os.path.join(cfg, "skills")
os.makedirs(skills)
os.symlink(real, os.path.join(skills, "herdr-orchestration"))
# ~/.claude/skills is a symlink into the checkout in the real install, so a
# no-follow PARENT walk here would refuse the layout we ship. Only the leaf is
# no-follow. This case fails if that distinction is ever collapsed.
assert k.procedure_capability(cfg) == 1, k.procedure_capability(cfg)
sys.exit(0)
PY

check "marker: a whitespace-padded malformed line cannot stall the parser" <<PY
$LOAD
import subprocess
# Externally timed, because the failure mode is TIME, not a return value. The
# old pattern used \\s on both sides of a lazy group, which backtracks
# cubically in the whitespace run: 3000 spaces took 11.2s, and the cost
# multiplies per line. That is a hook timeout, which proceeds, and it also ran
# under the admission flock.
child = '''
import importlib.util, sys
spec = importlib.util.spec_from_file_location("caps", "claude/hooks/herdr_capabilities.py")
k = importlib.util.module_from_spec(spec); spec.loader.exec_module(k)
# MARKER_LINE_MAX is disabled on purpose, so this times the PARSER and not the
# length pre-filter. A cap is a control with no margin; if it is the only
# thing holding, raising it later silently restores the pathology.
k.MARKER_LINE_MAX = 10 ** 9
# Tab+space, terminated by a lone "-": the worst measured variant, about 8x
# the pure-space run and 1728s at this size under the original pattern.
pad = ("\\t " * 8000)
line = "<!--" + pad + "herdr-capabilities:" + pad + "-"
sys.stdout.write(repr(k.parse_marker(line)))
'''
r = subprocess.run([sys.executable, "-c", child], capture_output=True, text=True, timeout=10)
assert r.returncode == 0, (r.returncode, r.stderr)
assert r.stdout.strip() == "None", r.stdout
sys.exit(0)
PY

check "marker: an over-long candidate line is refused before matching" <<PY
$LOAD
long_line = "<!-- herdr-capabilities: " + "x" * (k.MARKER_LINE_MAX + 10) + " -->"
assert k.parse_marker(long_line + chr(10)) is None
good = '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->' + chr(10)
assert k.parse_marker(good) == 1, k.parse_marker(good)
sys.exit(0)
PY

check "gate: an over-long record is refused, not truncated" <<PY
$LOAD
d = tempfile.mkdtemp()
rec = {"schema_version": 1, "repo_slug": "s", "repo_id": None,
       "account_id": "a", "enabled": True}
body = json.dumps(rec)
pad = " " * (k.GATE_READ_LIMIT + 1024)
open(os.path.join(d, k.GATE_NAME), "w").write(body + pad)
ok, why = k.gate_enabled(d, "s", "a")
assert ok is False, (ok, why)
assert "too large" in why, why
sys.exit(0)
PY

check "procedure: an over-long file is refused, so truncation cannot validate it" <<PY
$LOAD
cfg = tempfile.mkdtemp()
d = os.path.join(cfg, "skills", "herdr-orchestration")
os.makedirs(d)
one = '<!-- herdr-capabilities: {"marker_version":1,"capability":1} -->' + chr(10)
two = '<!-- herdr-capabilities: {"marker_version":1,"capability":0} -->' + chr(10)
pad = ("padding" + chr(10)) * 4
body = one + (pad * ((k.PROCEDURE_READ_LIMIT // len(pad)) + 16)) + two
open(os.path.join(d, "SKILL.md"), "w").write(body)
# Truncating at the bound would return 1 here while parsing the whole file
# returns None (two markers, fail closed). Refusing over-length keeps those
# answers the same.
assert len(body) > k.PROCEDURE_READ_LIMIT, len(body)
assert k.parse_marker(body) is None, k.parse_marker(body)
assert k.procedure_capability(cfg) is None, k.procedure_capability(cfg)
sys.exit(0)
PY

check "gate: IDENTITY_DEFERRED defers corroboration without weakening any other clause" <<PY
$LOAD
d = tempfile.mkdtemp()
base = {"schema_version": 1, "repo_slug": "s", "repo_id": "abc",
        "account_id": "a", "enabled": True}
p = os.path.join(d, k.GATE_NAME)
open(p, "w").write(json.dumps(base))
# The whole point: None REFUSES a record naming an identity, so it is the
# wrong pre-check. The sentinel accepts, then the caller re-checks for real.
assert k.gate_enabled(d, "s", "a", None)[0] is False
assert k.gate_enabled(d, "s", "a", k.IDENTITY_DEFERRED)[0] is True
assert k.gate_enabled(d, "s", "a", "abc")[0] is True
assert k.gate_enabled(d, "s", "a", "other")[0] is False
# Every non-identity clause still bites under the sentinel.
for bad, field in ((0, "enabled"), (99, "schema_version")):
    rec = dict(base)
    rec["enabled" if field == "enabled" else "schema_version"] = False if field == "enabled" else 99
    open(p, "w").write(json.dumps(rec))
    assert k.gate_enabled(d, "s", "a", k.IDENTITY_DEFERRED)[0] is False, field
open(p, "w").write(json.dumps(dict(base, repo_slug="other")))
assert k.gate_enabled(d, "s", "a", k.IDENTITY_DEFERRED)[0] is False
open(p, "w").write(json.dumps(dict(base, account_id="other")))
assert k.gate_enabled(d, "s", "a", k.IDENTITY_DEFERRED)[0] is False
open(p, "w").write(json.dumps(dict(base, repo_id=17)))
assert k.gate_enabled(d, "s", "a", k.IDENTITY_DEFERRED)[0] is False
sys.exit(0)
PY

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
