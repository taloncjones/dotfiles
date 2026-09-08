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

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
