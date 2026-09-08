#!/bin/sh
# orch-edit-guard.test.sh -- hermetic payload tests for orch_edit_guard.py.
#
# Every fixture lives under mktemp: a throwaway CLAUDE_CONFIG_DIR with owner
# records, throwaway git repos with a fixed origin URL (so the repo slug is
# computable), a scratchpad and TMPDIR outside the repos (each also holding
# a checkout, which must still be guarded). No live Claude session, no real
# state root. The suite never performs a write the hook allows.
set -u
PYTHONDONTWRITEBYTECODE=1
export PYTHONDONTWRITEBYTECODE
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

HOOK=${ORCH_EDIT_GUARD_HOOK:-claude/hooks/orch_edit_guard.py}
CORE=claude/hooks/herdr_orch_core.py
PASS=0
FAIL=0
SID_A=11111111-1111-1111-1111-111111111111   # owns SLUG_A (fence 4) and aaa-first (fence 9)
SID_B=22222222-2222-2222-2222-222222222222   # owns SLUG_2 only
SID_C=33333333-3333-3333-3333-333333333333   # owns nothing: a worker or plain session
FIX=$(mktemp -d /tmp/orch-edit-guard.XXXXXX)
FIX=$(cd "$FIX" && pwd -P)
H="$FIX/home"; CFG="$FIX/cfg"; S="$FIX/scratch"; T="$FIX/tmpdir"; N="$FIX/plain"
mkdir -p "$H" "$S" "$T" "$N"
trap 'chmod -R u+w "$FIX" 2>/dev/null; rm -rf "$FIX"' EXIT

# mkrepo DIR REMOTE: one-commit repo with tracked.txt, f2, dir/inner.txt,
# an ignored/ dir, and an untracked .todos/pending/ dir.
mkrepo() {
    git -c init.defaultBranch=main init -q "$1"
    mkdir -p "$1/dir" "$1/ignored" "$1/.todos/pending"
    printf 'tracked\n' > "$1/tracked.txt"
    printf 'two\n' > "$1/f2"
    printf 'inner\n' > "$1/dir/inner.txt"
    printf 'ignored/\n' > "$1/.gitignore"
    printf 'x\n' > "$1/ignored/x"
    git -C "$1" add tracked.txt f2 dir/inner.txt .gitignore
    git -C "$1" -c user.name=t -c user.email=t@x commit -q -m base
    git -C "$1" remote add origin "$2"
}
R="$FIX/repo"; R2="$FIX/repo2"
mkrepo "$R" "git@example.com:org/repo.git"
mkrepo "$R2" "git@example.com:org/other.git"
mkrepo "$S/clone" "git@example.com:org/sclone.git"
mkrepo "$T/clone" "git@example.com:org/tclone.git"
ln -s "$R/tracked.txt" "$FIX/link_to_tracked"
: > "$S/note.txt"
: > "$T/note.txt"
slug_of() { python3 -c 'import sys; sys.path.insert(0, "claude/hooks"); import herdr_orch_core as c; print(c.repo_slug(sys.argv[1]))' "$1"; }
SLUG_A=$(slug_of "git@example.com:org/repo.git")
SLUG_2=$(slug_of "git@example.com:org/other.git")

# state fixture: SID_A owns SLUG_A (fence 4) AND a slug that sorts before
# it (aaa-first, fence 9) so refusals must name the target's slug, not the
# sorted-first one; SID_B owns SLUG_2; a corrupt owner file under a slug
# that sorts last; the scratch/tmp clones have no owner at all.
RD_A="$CFG/herdr-orch/$SLUG_A"; RD_2="$CFG/herdr-orch/$SLUG_2"
mkdir -p "$RD_A/tasks" "$RD_2" "$CFG/herdr-orch/aaa-first" "$CFG/herdr-orch/zz-corrupt"
printf '{"session_id":"%s","host":"h","pid":1,"heartbeat_ts":0,"fence":4}' "$SID_A" > "$RD_A/owner.json"
printf '{"session_id":"%s","host":"h","pid":1,"heartbeat_ts":0,"fence":9}' "$SID_A" > "$CFG/herdr-orch/aaa-first/owner.json"
printf '{"session_id":"%s","host":"h","pid":1,"heartbeat_ts":0,"fence":1}' "$SID_B" > "$RD_2/owner.json"
printf 'not json' > "$CFG/herdr-orch/zz-corrupt/owner.json"
AUDIT="$RD_A/tasks/orch-edits.jsonl"
# A copy of the hooks dir for the production-invocation bytecode check, so
# the suite never touches the checkout's own claude/hooks/.
mkdir -p "$FIX/hooks"; cp claude/hooks/*.py "$FIX/hooks/"

# payload TOOL SID ARG CWD [EVENT] -> PreToolUse JSON. ARG is file_path for
# Edit/Write and command for Bash.
payload() {
    P_TOOL="$1" P_SID="$2" P_ARG="$3" P_CWD="$4" P_EVENT="${5:-PreToolUse}" P_SCRATCH="$S" python3 - <<'PY'
import json, os
e = os.environ
if e["P_TOOL"] == "Bash":
    ti = {"command": e["P_ARG"]}
else:
    ti = {"file_path": e["P_ARG"], "content": "x"}
print(json.dumps({"session_id": e["P_SID"], "cwd": e["P_CWD"], "hook_event_name": e["P_EVENT"],
                  "tool_name": e["P_TOOL"], "tool_use_id": "toolu_" + os.urandom(4).hex(),
                  "scratchpad_dir": e["P_SCRATCH"], "permission_mode": "auto", "tool_input": ti}))
PY
}

# run PAYLOAD [NAME=VALUE ...]: hermetic env; later assignments override.
# Pass HERDR_ENV= (empty) to simulate a non-herdr session.
run() {
    payload="$1"
    shift
    if printf '%s' "$payload" | env HOME="$H" TMPDIR="$T" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 \
            PYTHONDONTWRITEBYTECODE=1 "$@" "$HOOK" >"$FIX/out" 2>"$FIX/err"; then
        return 0
    else
        return $?
    fi
}

# expect LABEL allow|deny RC
expect() {
    label="$1"; want="$2"; rc="$3"
    ok=0
    if [ "$want" = allow ] && [ "$rc" = 0 ] && [ ! -s "$FIX/out" ] && [ ! -s "$FIX/err" ]; then
        ok=1
    elif [ "$want" = deny ] && [ "$rc" = 2 ] && head -n 1 "$FIX/err" | grep -q '^Blocked: orch-edit-guard' \
            && [ "$(wc -l <"$FIX/err" | tr -d ' ')" = 3 ]; then
        ok=1
    fi
    if [ "$ok" = 1 ]; then
        printf 'PASS  %s\n' "$label"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s (rc=%s out=%s err=%s)\n' "$label" "$rc" "$(head -c 200 "$FIX/out")" "$(head -n 2 "$FIX/err" | tr '\n' '|')" >&2
        FAIL=$((FAIL + 1))
    fi
}

# hook_case LABEL allow|deny TOOL ARG CWD SID [NAME=VALUE ...]
hook_case() {
    label="$1"; want="$2"; tool="$3"; arg="$4"; cwd="$5"; sid="$6"
    shift 6
    if run "$(payload "$tool" "$sid" "$arg" "$cwd")" "$@"; then rc=0; else rc=$?; fi
    expect "$label" "$want" "$rc"
}

# audit_count EVENT -> number of lines with that event in the SLUG_A log
audit_count() { if [ -f "$AUDIT" ]; then grep -c "\"event\":\"$1\"" "$AUDIT"; else echo 0; fi; }

# tree_hash DIR -> content hash of every file under DIR (read-only checks)
tree_hash() {
    python3 - "$1" <<'PY'
import hashlib, os, sys
for dp, dn, fn in os.walk(sys.argv[1]):
    for f in sorted(fn):
        p = os.path.join(dp, f)
        print(os.path.relpath(p, sys.argv[1]), hashlib.sha256(open(p, "rb").read()).hexdigest())
PY
}

# --- AC1: never denies a session that is not the owner -----------------
before=$(tree_hash "$CFG")
hook_case "AC1 no HERDR_ENV: Edit tracked passes" allow Edit "$R/tracked.txt" "$R" "$SID_A" HERDR_ENV=
hook_case "AC1 unowned session: Edit tracked passes" allow Edit "$R/tracked.txt" "$R" "$SID_C"
hook_case "AC1 unowned session: Write tracked passes" allow Write "$R/tracked.txt" "$R" "$SID_C"
hook_case "AC1 unowned session: Bash redirect passes" allow Bash "echo x > $R/tracked.txt" "$R" "$SID_C"
hook_case "AC1 malformed session id passes" allow Edit "$R/tracked.txt" "$R" "not-a-uuid"
hook_case "AC1 empty state root passes" allow Edit "$R/tracked.txt" "$R" "$SID_A" CLAUDE_CONFIG_DIR="$FIX/nocfg"
after=$(tree_hash "$CFG")
if [ -n "$before" ] && [ "$before" = "$after" ]; then
    printf 'PASS  AC1 non-owner leaves the config dir byte-identical\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC1 non-owner leaves the config dir byte-identical\n' >&2; FAIL=$((FAIL + 1))
fi
# Production invocation against the copied hooks dir: bytecode suppression
# unset, no caches present, and none may appear.
if printf '%s' "$(payload Edit "$SID_C" "$R/tracked.txt" "$R")" | env -u PYTHONDONTWRITEBYTECODE HOME="$H" TMPDIR="$T" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 python3 "$FIX/hooks/orch_edit_guard.py" >/dev/null 2>&1 \
        && [ ! -d "$FIX/hooks/__pycache__" ]; then
    printf 'PASS  AC1 production invocation writes no bytecode next to the hook\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC1 production invocation writes no bytecode next to the hook\n' >&2; FAIL=$((FAIL + 1))
fi

# --- AC2: owner denied on guarded Edit/Write targets --------------------
hook_case "AC2 Edit tracked denied" deny Edit "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC2 Write tracked denied" deny Write "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC2 Edit nested tracked denied" deny Edit "$R/dir/inner.txt" "$R" "$SID_A"
hook_case "AC2 Write new untracked file denied" deny Write "$R/new.txt" "$R" "$SID_A"
hook_case "AC2 Write new file in new subdir denied" deny Write "$R/newdir/deep/new.txt" "$R" "$SID_A"
hook_case "AC2 relative file_path resolves against cwd" deny Edit "tracked.txt" "$R" "$SID_A"
hook_case "AC2 symlink parked outside the repo still reaches the tracked file" deny Edit "$FIX/link_to_tracked" "$N" "$SID_A"
hook_case "AC2 checkout under the scratchpad is still a checkout" deny Edit "$S/clone/tracked.txt" "$S" "$SID_A"
hook_case "AC2 checkout under TMPDIR is still a checkout" deny Edit "$T/clone/tracked.txt" "$T" "$SID_A"
hook_case "AC2 deny for a repo the session owns names its slug and fence" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if grep -q -- "--repo-slug $SLUG_A --session $SID_A --fence 4 " "$FIX/err" && ! grep -q 'aaa-first' "$FIX/err"; then
    printf 'PASS  AC2 refusal names the target repo slug and fence, not the sorted-first owned slug\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC2 refusal names the target repo slug and fence, not the sorted-first owned slug\n' >&2; FAIL=$((FAIL + 1))
fi
# Short os.write must not count as a record (audit_append, spec 6.5 3a).
if HOOK="$HOOK" CFG="$CFG" SLUG_A="$SLUG_A" python3 - <<'PY'
import importlib.util, os, sys
sys.dont_write_bytecode = True
os.environ["CLAUDE_CONFIG_DIR"] = os.environ["CFG"]
spec = importlib.util.spec_from_file_location("g", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
real = os.write
os.write = lambda fd, data: real(fd, data[:2])
try:
    assert g.audit_append(os.environ["SLUG_A"], {"v": 1, "event": "x"}) is False
finally:
    os.write = real
assert g.audit_append(os.environ["SLUG_A"], {"v": 1, "event": "x"}) is True
PY
then
    printf 'PASS  AC2 audit_append treats a short write as failure\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC2 audit_append treats a short write as failure\n' >&2; FAIL=$((FAIL + 1))
fi

# --- AC3: exempt and unguarded targets ----------------------------------
hook_case "AC3 gitignored path passes" allow Write "$R/ignored/x" "$R" "$SID_A"
hook_case "AC3 new file under an ignored dir passes" allow Write "$R/ignored/new" "$R" "$SID_A"
hook_case "AC3 .todos component passes" allow Write "$R/.todos/pending/2026-09-08-x.md" "$R" "$SID_A"
hook_case "AC3 STATE_ROOT path passes" allow Write "$RD_A/tasks/PROJ-1.brief.md" "$R" "$SID_A"
hook_case "AC3 inside .git passes" allow Write "$R/.git/info/exclude" "$R" "$SID_A"
hook_case "AC3 scratchpad file outside any repo passes" allow Write "$S/note.txt" "$R" "$SID_A"
hook_case "AC3 TMPDIR file outside any repo passes" allow Write "$T/note.txt" "$R" "$SID_A"
hook_case "AC3 plain directory outside any repo passes" allow Write "$N/note.txt" "$R" "$SID_A"
hook_case "AC3 home-relative path outside any repo passes" allow Write "~/note.txt" "$R" "$SID_A"

# --- AC4: Bash write shapes ---------------------------------------------
TR="$R/tracked.txt"
hook_case "AC4 redirect > tracked denied" deny Bash "echo x > $TR" "$R" "$SID_A"
hook_case "AC4 append >> tracked denied" deny Bash "printf x >> $TR" "$R" "$SID_A"
hook_case "AC4 clobber >| tracked denied" deny Bash "echo x >| $TR" "$R" "$SID_A"
hook_case "AC4 fd redirect 2> tracked denied" deny Bash "echo x 2> $TR" "$R" "$SID_A"
hook_case "AC4 &> tracked denied" deny Bash "echo x &> $TR" "$R" "$SID_A"
hook_case "AC4 >& tracked denied (B2)" deny Bash "echo x >& $TR" "$R" "$SID_A"
hook_case "AC4 glued >&tracked denied (B2)" deny Bash "echo x >&$TR" "$R" "$SID_A"
hook_case "AC4 >>& tracked denied (B2)" deny Bash "echo x >>& $TR" "$R" "$SID_A"
hook_case "AC4 glued >tracked denied" deny Bash "echo x >$TR" "$R" "$SID_A"
hook_case "AC4 heredoc into tracked denied" deny Bash "cat <<'EOF' > $TR
body > quoted
EOF" "$R" "$SID_A"
hook_case "AC4 sed -i tracked denied" deny Bash "sed -i s/a/b/ $TR" "$R" "$SID_A"
hook_case "AC4 BSD sed -i '' tracked denied" deny Bash "sed -i '' s/a/b/ $TR" "$R" "$SID_A"
hook_case "AC4 perl -pi -e tracked denied" deny Bash "perl -pi -e s/a/b/ $TR" "$R" "$SID_A"
hook_case "AC4 tee tracked denied" deny Bash "echo x | tee $TR" "$R" "$SID_A"
hook_case "AC4 tee -a tracked denied" deny Bash "echo x | tee -a $TR" "$R" "$SID_A"
hook_case "AC4 cp onto tracked denied" deny Bash "cp $S/note.txt $TR" "$R" "$SID_A"
hook_case "AC4 cp into repo dir denied (new untracked file)" deny Bash "cp $S/note.txt $R/dir" "$R" "$SID_A"
hook_case "AC4 mv onto tracked denied" deny Bash "mv $S/note.txt $TR" "$R" "$SID_A"
hook_case "AC4 mv tracked out of the repo denied (source)" deny Bash "mv $TR $S/saved.txt" "$R" "$SID_A"
hook_case "AC4 sh -c redirect denied" deny Bash "sh -c 'echo x > $TR'" "$R" "$SID_A"
hook_case "AC4 bash -ec redirect denied (combined flag cluster, B1)" deny Bash "bash -ec 'echo x > $TR'" "$R" "$SID_A"
hook_case "AC4 bash -lc redirect denied (combined flag cluster, B1)" deny Bash "bash -lc 'echo x > $TR'" "$R" "$SID_A"
hook_case "AC4 zsh -lc redirect denied (combined flag cluster, B1)" deny Bash "zsh -lc 'echo x > $TR'" "$R" "$SID_A"
hook_case "AC4 cd then relative redirect denied" deny Bash "cd $R/dir && echo x > inner.txt" "$N" "$SID_A"
hook_case "AC4 env prefix then tee denied" deny Bash "env FOO=1 tee $TR" "$R" "$SID_A"
hook_case "AC4 redirect after a scratch heredoc denied" deny Bash "cat <<'EOF' > $S/n.txt
body
EOF
echo x > $TR" "$R" "$SID_A"
hook_case "AC4 cp dest not masked by a trailing redirect" deny Bash "cp $S/note.txt $TR > $S/log" "$R" "$SID_A"
: > "$S/in"
hook_case "AC4 cp dest not masked by a trailing input redirect" deny Bash "cp $S/note.txt $TR < $S/in" "$R" "$SID_A"
hook_case "AC4 cp dest not masked by a descriptor input dup" deny Bash "cp $S/note.txt $TR <&0" "$R" "$SID_A"
hook_case "AC4 filename ending in a digit before > keeps its digit (sed -i f2)" deny Bash "sed -i s/a/b/ $R/f2> $S/log" "$R" "$SID_A"
hook_case "AC4 1>tracked denied" deny Bash "echo x 1>$TR" "$R" "$SID_A"
hook_case "AC4 cp dest not masked by a numbered heredoc (0<<EOF)" deny Bash "cp $S/note.txt $TR 0<<EOF
body
EOF" "$S" "$SID_A"
hook_case "AC4 mv of the whole checkout denied (work tree root is guarded)" deny Bash "mv $R $S/moved" "$S" "$SID_A"
hook_case "AC4 git status passes" allow Bash "git status" "$R" "$SID_A"
hook_case "AC4 plain echo passes" allow Bash "echo x" "$R" "$SID_A"
hook_case "AC4 sed without -i passes" allow Bash "sed s/a/b/ $TR" "$R" "$SID_A"
hook_case "AC4 input redirect passes" allow Bash "cat < $TR" "$R" "$SID_A"
hook_case "AC4 /dev/null passes" allow Bash "echo x > /dev/null" "$R" "$SID_A"
hook_case "AC4 >&2 dup passes" allow Bash "echo x >&2" "$R" "$SID_A"
hook_case "AC4 2>&1 dup passes" allow Bash "cmd 2>&1" "$R" "$SID_A"
hook_case "AC4 quoted > is data" allow Bash "echo \">\" $TR" "$R" "$SID_A"
hook_case "AC4 quoted << is data" allow Bash "echo \"<<EOF\" > $S/n.txt" "$R" "$SID_A"
hook_case "AC4 redirect to the scratchpad passes" allow Bash "echo x > $S/n.txt" "$R" "$SID_A"
hook_case "AC4 redirect to .todos passes" allow Bash "echo x > .todos/n" "$R" "$SID_A"
hook_case "AC4 unexpanded variable target passes" allow Bash "echo x > \"\$F\"" "$R" "$SID_A"
hook_case "AC4 redirect into an ignored dir passes" allow Bash "echo x > $R/ignored/n" "$R" "$SID_A"
hook_case "AC4 cp tracked out to the scratchpad passes" allow Bash "cp $TR $S/copy.txt" "$R" "$SID_A"
hook_case "AC4 heredoc body with > and a tracked redirect line passes" allow Bash "cat <<'EOF' > $S/n.txt
> quoted
echo x > $TR
EOF" "$R" "$SID_A"
hook_case "AC4 comment after # is not a redirect" allow Bash "echo x # > $TR" "$R" "$SID_A"
hook_case "AC4 read-write <> is not a write target (spec 6.4)" allow Bash "cmd <> $TR" "$R" "$SID_A"
hook_case "AC4 here-string then scratch redirect passes" allow Bash "cmd <<< word > $S/o" "$R" "$SID_A"
hook_case "AC4 input from tracked, output to scratch passes" allow Bash "cat < $TR > $S/o" "$R" "$SID_A"
hook_case "AC4 3>&1 dup passes" allow Bash "cmd 3>&1" "$R" "$SID_A"
many=$(i=1; while [ "$i" -le 24 ]; do printf 'echo x > %s/f%s; ' "$S" "$i"; i=$((i + 1)); done; printf 'echo x > %s' "$TR")
hook_case "AC4 25th distinct target is past the cap (fail open)" allow Bash "$many" "$R" "$SID_A"

# --- AC5/AC6: marker and budget ----------------------------------------
# marker DIR SID FENCE DELTA_SECS MAX [MARKER_ID]: a fixture marker.
marker() {
    M_DIR="$1" M_SID="$2" M_FENCE="$3" M_DELTA="$4" M_MAX="$5" M_ID="${6:-0123456789abcdef}" python3 - <<'PY'
import json, os, time
e = os.environ
rec = {"v": 1, "marker_id": e["M_ID"], "session_id": e["M_SID"], "fence": int(e["M_FENCE"]),
       "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "minutes": 5,
       "max_edits": int(e["M_MAX"]), "expires_epoch": time.time() + float(e["M_DELTA"]),
       "expires": "2026-09-08T00:00:00Z", "note": "test"}
open(os.path.join(e["M_DIR"], "orch-edit-allow.json"), "w").write(json.dumps(rec))
PY
}
reset_log() { rm -rf "$RD_A/tasks"; mkdir -p "$RD_A/tasks"; : > "$AUDIT"; }
second_line_has() {   # LABEL SUBSTRING: second stderr line of the last run
    if sed -n 2p "$FIX/err" | grep -qF -- "$2"; then
        printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1))
    else
        printf 'FAIL  %s: %s\n' "$1" "$(sed -n 2p "$FIX/err")" >&2; FAIL=$((FAIL + 1))
    fi
}

reset_log; marker "$RD_A" "$SID_A" 4 300 10
hook_case "AC5 valid marker allows Edit tracked" allow Edit "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC5 valid marker allows Write new file" allow Write "$R/new.txt" "$R" "$SID_A"
hook_case "AC5 valid marker allows Bash redirect" allow Bash "echo x > $TR" "$R" "$SID_A"
hook_case "AC5 valid marker allows sed -i" allow Bash "sed -i s/a/b/ $TR" "$R" "$SID_A"
if [ "$(audit_count orch-edit-claim)" = 4 ] && [ "$(audit_count orch-edit-allowed)" = 4 ] && AUDIT="$AUDIT" python3 - <<'PY'
import json, os
recs = [json.loads(l) for l in open(os.environ["AUDIT"]) if l.strip()]
claims = [r for r in recs if r["event"] == "orch-edit-claim"]
allows = [r for r in recs if r["event"] == "orch-edit-allowed"]
assert all(r["marker_id"] == "0123456789abcdef" for r in claims + allows)
assert all(len(r["claim_id"]) == 8 for r in claims) and len({r["claim_id"] for r in claims}) == 4
assert all(r["reason"] in ("tracked", "untracked") and r["marker_expires"] for r in allows)
PY
then
    printf 'PASS  AC5 one claim and one allowed line per guarded target\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC5 one claim and one allowed line per guarded target (claims=%s allowed=%s)\n' "$(audit_count orch-edit-claim)" "$(audit_count orch-edit-allowed)" >&2; FAIL=$((FAIL + 1))
fi
hook_case "AC5 marker does not allow an edit in a repo another session owns" deny Edit "$R2/tracked.txt" "$R2" "$SID_A"
second_line_has "AC5 scope refusal names the target slug" "does not orchestrate $SLUG_2"
if ! grep -q 'allow-edit' "$FIX/err"; then
    printf 'PASS  AC5 scope refusal gives no allow-edit line\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC5 scope refusal gives no allow-edit line\n' >&2; FAIL=$((FAIL + 1))
fi
hook_case "AC5 marker does not allow an edit in an unowned repo (scratch clone)" deny Edit "$S/clone/tracked.txt" "$S" "$SID_A"
reset_log; marker "$RD_A" "$SID_A" 4 -1 10
hook_case "AC5 expired marker denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if grep -q '"why":"expired"' "$AUDIT"; then printf 'PASS  AC5 expired marker audited as expired\n'; PASS=$((PASS + 1)); else printf 'FAIL  AC5 expired marker audited as expired\n' >&2; FAIL=$((FAIL + 1)); fi
reset_log; marker "$RD_A" "$SID_B" 4 300 10
hook_case "AC5 marker for another session denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
reset_log; marker "$RD_A" "$SID_A" 3 300 10
hook_case "AC5 marker with a stale fence denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if grep -q '"why":"fence"' "$AUDIT"; then printf 'PASS  AC5 stale-fence marker audited as fence\n'; PASS=$((PASS + 1)); else printf 'FAIL  AC5 stale-fence marker audited as fence\n' >&2; FAIL=$((FAIL + 1)); fi
reset_log; marker "$RD_A" "$SID_A" 4 300 10 "not-hex"
hook_case "AC5 marker without a valid marker_id denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
reset_log; printf 'not json' > "$RD_A/orch-edit-allow.json"
hook_case "AC5 marker that is not JSON denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
reset_log; M_DIR="$RD_A" M_SID="$SID_A" python3 -c 'import json,os; e=os.environ; open(os.path.join(e["M_DIR"],"orch-edit-allow.json"),"w").write(json.dumps({"v":1,"marker_id":"0123456789abcdef","session_id":e["M_SID"],"fence":4,"ts":"x","minutes":5,"max_edits":3,"expires_epoch":10**400,"expires":"x","note":""}))'
hook_case "AC5 marker with an overflowing expires_epoch denies (no fail-open)" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if grep -q '"why":"expired"' "$AUDIT"; then printf 'PASS  AC5 overflowing expiry audited as expired\n'; PASS=$((PASS + 1)); else printf 'FAIL  AC5 overflowing expiry audited as expired\n' >&2; FAIL=$((FAIL + 1)); fi
reset_log; rm -f "$RD_A/orch-edit-allow.json"; marker "$FIX" "$SID_A" 4 300 10; ln -s "$FIX/orch-edit-allow.json" "$RD_A/orch-edit-allow.json"
hook_case "AC5 symlinked marker denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
rm -f "$RD_A/orch-edit-allow.json" "$FIX/orch-edit-allow.json"
reset_log; mkdir -p "$RD_2/tasks"; marker "$RD_2" "$SID_A" 1 300 10
hook_case "AC5 marker under a slug the session does not own denies" deny Edit "$R/tracked.txt" "$R" "$SID_A"
rm -f "$RD_2/orch-edit-allow.json"

reset_log; marker "$RD_A" "$SID_A" 4 300 2 "aaaaaaaaaaaaaaaa"
hook_case "AC6 budget 2: first write allowed" allow Edit "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC6 budget 2: second write allowed" allow Edit "$R/dir/inner.txt" "$R" "$SID_A"
hook_case "AC6 budget 2: third write denied with the budget variant" deny Edit "$R/tracked.txt" "$R" "$SID_A"
second_line_has "AC6 budget refusal names the marker and counts" "marker aaaaaaaaaaaaaaaa for $SLUG_A is exhausted (3 of 2 claims)"
if [ "$(audit_count orch-edit-claim)" = 3 ] && [ "$(audit_count orch-edit-denied)" = 1 ]; then
    printf 'PASS  AC6 the denied third attempt still left a claim\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC6 the denied third attempt still left a claim\n' >&2; FAIL=$((FAIL + 1))
fi
reset_log; marker "$RD_A" "$SID_A" 4 300 2 "bbbbbbbbbbbbbbbb"
hook_case "AC6 three guarded targets under budget 2 denied outright" deny Bash "tee $TR $R/dir/inner.txt $R/new.txt" "$R" "$SID_A"
reset_log; marker "$RD_A" "$SID_A" 4 300 1 "cccccccccccccccc"
hook_case "AC6 budget 1: first allowed" allow Edit "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC6 budget 1: second denied" deny Edit "$R/tracked.txt" "$R" "$SID_A"
marker "$RD_A" "$SID_A" 4 300 1 "dddddddddddddddd"
hook_case "AC6 re-minted marker starts a fresh budget" allow Edit "$R/tracked.txt" "$R" "$SID_A"
reset_log; marker "$RD_A" "$SID_A" 4 300 2 "eeeeeeeeeeeeeeee"
i=0
while [ "$i" -lt 5 ]; do
    ( payload Edit "$SID_A" "$R/tracked.txt" "$R" | env HOME="$H" TMPDIR="$T" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 "$HOOK" >/dev/null 2>"$FIX/par.$i.err"; echo $? > "$FIX/par.$i.rc" ) &
    i=$((i + 1))
done
wait
allowed=0; denied=0; i=0
while [ "$i" -lt 5 ]; do
    case "$(cat "$FIX/par.$i.rc")" in
        0) [ ! -s "$FIX/par.$i.err" ] && allowed=$((allowed + 1)) ;;
        2) head -n 1 "$FIX/par.$i.err" | grep -q '^Blocked: orch-edit-guard' && denied=$((denied + 1)) ;;
    esac
    i=$((i + 1))
done
if [ "$allowed" = 2 ] && [ "$denied" = 3 ] && [ "$(audit_count orch-edit-claim)" = 5 ]; then
    printf 'PASS  AC6 five concurrent attempts against budget 2: exactly two exit 0, three exit 2, five claims\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC6 five concurrent attempts against budget 2 (allowed=%s denied=%s claims=%s)\n' "$allowed" "$denied" "$(audit_count orch-edit-claim)" >&2; FAIL=$((FAIL + 1))
fi
reset_log; marker "$RD_A" "$SID_A" 4 300 10; rm -rf "$RD_A/tasks"
hook_case "AC6 marker with no tasks dir cannot reserve: denied" deny Edit "$R/tracked.txt" "$R" "$SID_A"
second_line_has "AC6 unwritable log wording" "Cannot reserve budget"
reset_log; marker "$RD_A" "$SID_A" 4 300 10; rm -f "$AUDIT"; ln -s "$FIX/victim2" "$AUDIT"
hook_case "AC6 marker with a symlinked log cannot reserve: denied" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if [ ! -e "$FIX/victim2" ]; then printf 'PASS  AC6 symlinked log not written through\n'; PASS=$((PASS + 1)); else printf 'FAIL  AC6 symlinked log not written through\n' >&2; FAIL=$((FAIL + 1)); fi
# A claim of this invocation that does not survive on re-read (a concurrent
# partial line spliced into ours) is an incomplete reservation: deny.
reset_log; marker "$RD_A" "$SID_A" 4 300 5 "0000000000000002"
if HOOK="$HOOK" CFG="$CFG" SLUG_A="$SLUG_A" SID_A="$SID_A" python3 - <<'PY'
import importlib.util, json, os, sys
sys.dont_write_bytecode = True
os.environ["CLAUDE_CONFIG_DIR"] = os.environ["CFG"]
spec = importlib.util.spec_from_file_location("g", os.environ["HOOK"])
g = importlib.util.module_from_spec(spec); spec.loader.exec_module(g)
marker = json.load(open(os.path.join(os.environ["CFG"], "herdr-orch", os.environ["SLUG_A"], "orch-edit-allow.json")))
real = g.audit_append
calls = []
def flaky(slug, rec):
    calls.append(rec)
    return True if len(calls) == 2 else real(slug, rec)   # second claim silently lost
g.audit_append = flaky
assert g.claim_budget(os.environ["SLUG_A"], marker, os.environ["SID_A"], "toolu_t", ["/a", "/b"]) is None
g.audit_append = real
assert g.claim_budget(os.environ["SLUG_A"], marker, os.environ["SID_A"], "toolu_t", ["/a", "/b"]) == 3
PY
then
    printf 'PASS  AC6 a lost claim line makes the reservation incomplete (deny)\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC6 a lost claim line makes the reservation incomplete (deny)\n' >&2; FAIL=$((FAIL + 1))
fi
reset_log; marker "$RD_A" "$SID_A" 4 300 10; rm -f "$AUDIT"; mkfifo "$AUDIT"
( payload Edit "$SID_A" "$R/tracked.txt" "$R" | env HOME="$H" TMPDIR="$T" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 "$HOOK" >"$FIX/mfifo.out" 2>"$FIX/mfifo.err"; echo $? > "$FIX/mfifo.rc" ) &
fifo_pid=$!
i=0
while kill -0 "$fifo_pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$fifo_pid" 2>/dev/null; then
    kill "$fifo_pid" 2>/dev/null; printf 'FAIL  AC6 valid marker with a FIFO log denies without blocking\n' >&2; FAIL=$((FAIL + 1))
elif [ "$(cat "$FIX/mfifo.rc")" = 2 ] && sed -n 2p "$FIX/mfifo.err" | grep -q 'Cannot reserve budget'; then
    printf 'PASS  AC6 valid marker with a FIFO log denies without blocking\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC6 valid marker with a FIFO log denies without blocking (rc=%s)\n' "$(cat "$FIX/mfifo.rc")" >&2; FAIL=$((FAIL + 1))
fi
wait "$fifo_pid" 2>/dev/null
rm -f "$AUDIT"

# Marker-enabled coverage of the AC2/AC4 deny shapes (spec AC5): two
# fresh markers of budget 10, every shape below must now exit 0.
reset_log; marker "$RD_A" "$SID_A" 4 300 10 "ffffffffffffffff"
hook_case "AC5m Write tracked allowed" allow Write "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC5m Edit nested tracked allowed" allow Edit "$R/dir/inner.txt" "$R" "$SID_A"
hook_case "AC5m Write new file in new subdir allowed" allow Write "$R/newdir/deep/new.txt" "$R" "$SID_A"
hook_case "AC5m relative file_path allowed" allow Edit "tracked.txt" "$R" "$SID_A"
hook_case "AC5m symlink to tracked allowed" allow Edit "$FIX/link_to_tracked" "$N" "$SID_A"
hook_case "AC5m append >> allowed" allow Bash "printf x >> $TR" "$R" "$SID_A"
hook_case "AC5m 2> allowed" allow Bash "echo x 2> $TR" "$R" "$SID_A"
hook_case "AC5m heredoc into tracked allowed" allow Bash "cat <<'EOF' > $TR
body
EOF" "$R" "$SID_A"
hook_case "AC5m perl -pi allowed" allow Bash "perl -pi -e s/a/b/ $TR" "$R" "$SID_A"
hook_case "AC5m tee -a allowed" allow Bash "echo x | tee -a $TR" "$R" "$SID_A"
if [ "$(audit_count orch-edit-allowed)" = 10 ]; then printf 'PASS  AC5m ten allows under the first marker\n'; PASS=$((PASS + 1)); else printf 'FAIL  AC5m ten allows under the first marker (%s)\n' "$(audit_count orch-edit-allowed)" >&2; FAIL=$((FAIL + 1)); fi
marker "$RD_A" "$SID_A" 4 300 10 "0000000000000001"
hook_case "AC5m cp onto tracked allowed" allow Bash "cp $S/note.txt $TR" "$R" "$SID_A"
hook_case "AC5m cp into repo dir allowed" allow Bash "cp $S/note.txt $R/dir" "$R" "$SID_A"
hook_case "AC5m mv onto tracked allowed" allow Bash "mv $S/note.txt $TR" "$R" "$SID_A"
hook_case "AC5m mv tracked out allowed (the source is the guarded target)" allow Bash "mv $TR $S/saved.txt" "$R" "$SID_A"
hook_case "AC5m sh -c redirect allowed" allow Bash "sh -c 'echo x > $TR'" "$R" "$SID_A"
hook_case "AC5m cd then relative redirect allowed" allow Bash "cd $R/dir && echo x > inner.txt" "$N" "$SID_A"
hook_case "AC5m env prefix tee allowed" allow Bash "env FOO=1 tee $TR" "$R" "$SID_A"
hook_case "AC5m cp with input redirect allowed" allow Bash "cp $S/note.txt $TR < $S/in" "$R" "$SID_A"
hook_case "AC5m sed -i f2> allowed" allow Bash "sed -i s/a/b/ $R/f2> $S/log" "$R" "$SID_A"
reset_log; rm -f "$RD_A/orch-edit-allow.json"

# --- AC7 link: the real allow-edit CLI mints a marker the hook honours ---
reset_log
CLAIM=$(env CLAUDE_CONFIG_DIR="$CFG" python3 "$CORE" claim-owner --repo-slug "$SLUG_A" --session "$SID_A" --host h --pid 1 --stale-secs 0 2>/dev/null)
if env CLAUDE_CONFIG_DIR="$CFG" python3 "$CORE" allow-edit --repo-slug "$SLUG_A" --session "$SID_A" --fence "$CLAIM" --minutes 5 --max-edits 1 --note approved > "$FIX/ae.out" 2>"$FIX/ae.err" \
        && grep -q '^expires .* marker [0-9a-f]\{16\}$' "$FIX/ae.out"; then
    printf 'PASS  AC7 allow-edit under the live fence prints expires and marker\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC7 allow-edit under the live fence prints expires and marker\n' >&2; FAIL=$((FAIL + 1))
fi
hook_case "AC7 hook honours the CLI-minted marker" allow Edit "$R/tracked.txt" "$R" "$SID_A"
hook_case "AC7 CLI-minted budget 1 is then exhausted" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if env CLAUDE_CONFIG_DIR="$CFG" python3 "$CORE" allow-edit --repo-slug "$SLUG_A" --session "$SID_A" --fence "$((CLAIM + 1))" --minutes 5 >/dev/null 2>&1; then
    printf 'FAIL  AC7 stale fence cannot mint\n' >&2; FAIL=$((FAIL + 1))
else
    printf 'PASS  AC7 stale fence cannot mint\n'; PASS=$((PASS + 1))
fi
# restore the fixture owner record for the static block below
printf '{"session_id":"%s","host":"h","pid":1,"heartbeat_ts":0,"fence":4}' "$SID_A" > "$RD_A/owner.json"
rm -f "$RD_A/orch-edit-allow.json"

# --- AC8 (no-marker part) and AC9: audit and malformed input ------------
: > "$AUDIT"
hook_case "AC8 denied write appends one orch-edit-denied line" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if [ "$(audit_count orch-edit-denied)" = 1 ] && AUDIT="$AUDIT" R="$R" python3 - <<'PY'
import json, os, sys
rec = json.loads(open(os.environ["AUDIT"]).readline())
top = os.path.realpath(os.environ["R"])
assert rec["v"] == 1 and rec["event"] == "orch-edit-denied" and rec["why"] == "no-marker"
assert rec["tool_name"] == "Edit" and rec["reason"] == "tracked" and rec["repo"] == top
assert rec["path"] == os.path.join(top, "tracked.txt") and rec["tool_use_id"].startswith("toolu_")
PY
then
    printf 'PASS  AC8 denied line has the documented fields\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC8 denied line has the documented fields\n' >&2; FAIL=$((FAIL + 1))
fi
rm -rf "$RD_A/tasks"
hook_case "AC8 missing tasks dir: deny unchanged" deny Edit "$R/tracked.txt" "$R" "$SID_A"
mkdir -p "$RD_A/tasks"; ln -s "$FIX/victim" "$AUDIT"
hook_case "AC8 symlinked audit: deny unchanged" deny Edit "$R/tracked.txt" "$R" "$SID_A"
if [ ! -e "$FIX/victim" ]; then
    printf 'PASS  AC8 symlinked audit is not written through\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  AC8 symlinked audit is not written through\n' >&2; FAIL=$((FAIL + 1))
fi
rm -f "$AUDIT"; mkfifo "$AUDIT"
payload Edit "$SID_A" "$R/tracked.txt" "$R" | env HOME="$H" TMPDIR="$T" CLAUDE_CONFIG_DIR="$CFG" HERDR_ENV=1 "$HOOK" >"$FIX/fifo.out" 2>"$FIX/fifo.err" &
fifo_pid=$!
i=0
while kill -0 "$fifo_pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$fifo_pid" 2>/dev/null; then
    kill "$fifo_pid" 2>/dev/null; printf 'FAIL  AC8 FIFO audit does not block the deny\n' >&2; FAIL=$((FAIL + 1))
else
    wait "$fifo_pid"; rc=$?
    if [ "$rc" = 2 ] && head -n 1 "$FIX/fifo.err" | grep -q '^Blocked: orch-edit-guard'; then
        printf 'PASS  AC8 FIFO audit does not block the deny\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  AC8 FIFO audit does not block the deny (rc=%s)\n' "$rc" >&2; FAIL=$((FAIL + 1))
    fi
fi
rm -f "$AUDIT"; : > "$AUDIT"
hook_case "AC9 unknown tool passes" allow Read "$R/tracked.txt" "$R" "$SID_A"
if run "$(payload Edit "$SID_A" "$R/tracked.txt" "$R" PostToolUse)"; then rc=0; else rc=$?; fi
expect "AC9 non-PreToolUse event passes" allow "$rc"
if run 'not json'; then rc=0; else rc=$?; fi
expect "AC9 malformed JSON passes" allow "$rc"
if run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"session_id\":\"$SID_A\",\"cwd\":\"$R\"}"; then rc=0; else rc=$?; fi
expect "AC9 missing tool_input passes" allow "$rc"
if run "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"session_id\":\"$SID_A\",\"cwd\":\"$R\",\"tool_input\":{\"file_path\":7}}"; then rc=0; else rc=$?; fi
expect "AC9 non-string file_path passes" allow "$rc"
hook_case "AC9 corrupt sibling owner file does not un-guard the valid owner" deny Edit "$R/tracked.txt" "$R" "$SID_A"
# A git that hangs: the budget bounds the hook, and the target is not guarded.
mkdir -p "$FIX/slowbin"; printf '#!/bin/sh\nsleep 30\n' > "$FIX/slowbin/git"; chmod +x "$FIX/slowbin/git"
start=$(date +%s)
hook_case "AC9 hanging git yields allow" allow Edit "$R/tracked.txt" "$R" "$SID_A" PATH="$FIX/slowbin:$PATH"
elapsed=$(( $(date +%s) - start ))
if [ "$elapsed" -le 12 ]; then
    printf 'PASS  AC9 hanging git returns within the budget (%ss)\n' "$elapsed"; PASS=$((PASS + 1))
else
    printf 'FAIL  AC9 hanging git returns within the budget (%ss)\n' "$elapsed" >&2; FAIL=$((FAIL + 1))
fi

# --- static: shebang, executable, compiles, registration -----------------
if [ -x "$HOOK" ] && head -n 1 "$HOOK" | grep -qx '#!/usr/bin/env python3' \
        && PYTHONPYCACHEPREFIX="$FIX/pyc" python3 -m py_compile "$HOOK"; then
    printf 'PASS  static: hook is executable, python3 shebang, compiles\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  static: hook is executable, python3 shebang, compiles\n' >&2; FAIL=$((FAIL + 1))
fi
if grep -q '^sys.dont_write_bytecode = True' "$HOOK" && grep -q '^import rm_guard' "$HOOK" && grep -q '^import herdr_orch_core as core' "$HOOK"; then
    printf 'PASS  static: bytecode suppression precedes the sibling imports\n'; PASS=$((PASS + 1))
else
    printf 'FAIL  static: bytecode suppression precedes the sibling imports\n' >&2; FAIL=$((FAIL + 1))
fi
if [ -z "${ORCH_EDIT_GUARD_HOOK:-}" ]; then
    if python3 - <<'PY'
import json, sys
pre = json.load(open("claude/settings.json.tmpl"))["hooks"]["PreToolUse"]
def cmds(matcher):
    return [h["command"] for e in pre if e.get("matcher") == matcher for h in e["hooks"]]
ok = cmds("Bash")[-1] == "~/.claude/hooks/orch_edit_guard.py" \
    and cmds("Edit|Write") == ["~/.claude/hooks/protect_claude_md.py", "~/.claude/hooks/orch_edit_guard.py"] \
    and sum(c == "~/.claude/hooks/orch_edit_guard.py" for m in ("Bash", "Edit|Write") for c in cmds(m)) == 2
sys.exit(0 if ok else 1)
PY
    then
        printf 'PASS  static: template registers the guard last in the Bash and Edit|Write groups\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: template registers the guard last in the Bash and Edit|Write groups\n' >&2; FAIL=$((FAIL + 1))
    fi
    if grep -qx 'sh claude/hooks/orch-edit-guard.test.sh' bin/dotfiles-tests; then
        printf 'PASS  static: suite is registered in bin/dotfiles-tests\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  static: suite is registered in bin/dotfiles-tests\n' >&2; FAIL=$((FAIL + 1))
    fi
    if awk '/^## Safety/{f=1; next} f && /^- /{print; exit}' claude/skills/herdr-orchestration/SKILL.md | grep -q 'An orchestrator session dispatches; it does not edit' \
            && grep -q 'allow-edit --repo-slug <slug> --session <id> --fence <fence> --minutes 5 --max-edits 3' claude/skills/herdr-orchestration/SKILL.md \
            && grep -q 'CLAUDE_CODE_SESSION_ID' claude/skills/herdr-orchestration/SKILL.md; then
        printf 'PASS  docs: SKILL.md Safety first bullet, allow-edit line, session-id sentence\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  docs: SKILL.md Safety first bullet, allow-edit line, session-id sentence\n' >&2; FAIL=$((FAIL + 1))
    fi
    if grep -q 'orch-edit-allow.json' claude/skills/herdr-orchestration/references/state-layout.md \
            && grep -q 'tasks/orch-edits.jsonl' claude/skills/herdr-orchestration/references/state-layout.md \
            && grep -q 'orch_edit_guard.py' CLAUDE.md \
            && grep -q '^- (2026-09) An orchestrator session dispatches' claude/rules/personal/agent-lessons.md \
            && [ "$(wc -l < claude/rules/personal/agent-lessons.md | tr -d ' ')" -le 45 ] \
            && [ "$(grep -c '^- (' claude/rules/personal/agent-lessons.md)" -le 20 ]; then
        printf 'PASS  docs: state-layout, CLAUDE.md bullet, agent-lessons bullet within caps\n'; PASS=$((PASS + 1))
    else
        printf 'FAIL  docs: state-layout, CLAUDE.md bullet, agent-lessons bullet within caps\n' >&2; FAIL=$((FAIL + 1))
    fi
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
