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
import signal
d = tempfile.mkdtemp()
os.mkfifo(os.path.join(d, k.GATE_NAME))
def bail(*a):
    raise AssertionError("gate_enabled blocked on a FIFO")
signal.signal(signal.SIGALRM, bail); signal.alarm(5)
ok, why = k.gate_enabled(d, "s", "a")
signal.alarm(0)
assert ok is False, (ok, why)
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
import signal
cfg = tempfile.mkdtemp()
d = os.path.join(cfg, "skills", "herdr-orchestration")
os.makedirs(d)
os.mkfifo(os.path.join(d, "SKILL.md"))
def bail(*a):
    raise AssertionError("procedure_capability blocked on a FIFO")
signal.signal(signal.SIGALRM, bail); signal.alarm(5)
cap = k.procedure_capability(cfg)
signal.alarm(0)
assert cap is None, cap
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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
