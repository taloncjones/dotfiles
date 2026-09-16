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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
