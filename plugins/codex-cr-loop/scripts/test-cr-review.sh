#!/usr/bin/env bash
# test-cr-review.sh — self-contained regression test for cr-review.sh.
# Uses a fake `codex` and a throwaway git repo under a temp dir; touches nothing else.
# Usage: bash plugins/codex-cr-loop/scripts/test-cr-review.sh   (exit 0 = all pass)

set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
CR="$HERE/cr-review.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cr-review-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()   { PASS=$((PASS + 1)); }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
expect() { # expect <label> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi
}

# Fake codex: copies $FAKE_OUT into the --output-last-message file.
mkdir -p "$TMP/bin"
{
  printf '#!/bin/bash\n'
  printf '[ -n "${FAKE_ARGS:-}" ] && printf "%%s\\n" "$*" > "$FAKE_ARGS"\n'
  printf 'out=""; while [ $# -gt 0 ]; do case "$1" in --output-last-message) out="$2"; shift 2;; *) shift;; esac; done\n'
  printf '[ -n "${FAKE_SLEEP:-}" ] && sleep "$FAKE_SLEEP"\n'
  printf '[ -n "${FAKE_OUT:-}" ] && cat "$FAKE_OUT" > "$out"\n'
  printf 'exit "${FAKE_RC:-0}"\n'
} > "$TMP/bin/codex"
chmod +x "$TMP/bin/codex"
export PATH="$TMP/bin:$PATH"
unset CR_LOOP_ROUND_CAP CR_LOOP_MAX_STEP_BACKS CR_LOOP_SKIP_P3 CR_LOOP_AUTO_WIDEN CR_LOOP_MAX_WIDENING_SWEEPS CR_LOOP_WIDEN_AFTER

R="$TMP/repo"
mkdir -p "$R/sub/dir" && cd "$R" || exit 2
git init -q -b main . && git config user.email t@example.invalid && git config user.name t
echo a > a.txt && git add . && git commit -qm init
git switch -qc feat/test && echo b >> a.txt && git commit -qam change

kv() { sed -n "s/^$1=//p" | head -n 1; }

# run_round <fixture> <mode> [since] -> prints the finish output; $? = finish exit code
run_round() {
  FAKE_OUT="$1" bash "$CR" start --mode "$2" --base main ${3:+--since "$3"} >/dev/null || return 9
  bash "$CR" wait --timeout 30 >/dev/null
  bash "$CR" finish
}

fixture() { printf '%s\n' "$2" > "$TMP/$1.json"; printf '%s\n' "$TMP/$1.json"; }
find_obj() { # find_obj <sev> <reopens> <title> [<still_wrong>]
  printf '{"severity":"%s","reopens":"%s","title":"%s","location":"a.txt:1","pattern":"p","still_wrong":"%s","instances":["a.txt:1","a.txt:2"],"fix":"f","prevent":"t"}' "$1" "$2" "$3" "${4:-}"
}
result() { # result <verdict> <findings-json-array> [<step_back-array>] [<oos-array>]
  printf '{"summary":"s","verdict":"%s","findings":%s,"step_back":%s,"out_of_scope":%s}' "$1" "$2" "${3:-[]}" "${4:-[]}"
}

F_CLEAN=$(fixture clean "$(result clean '[]')")
F_DIRTY=$(fixture dirty "$(result findings "[$(find_obj P1 '' 'Class A'),$(find_obj P3 '' 'Nit')]" '[]' '[{"location":"a.txt:9","note":"old"}]')")
F_P3=$(fixture p3 "$(result findings "[$(find_obj P3 '' 'Another nit')]")")
F_REOPEN=$(fixture reopen "$(result findings "[$(find_obj P2 C1 'Class A' 'one left')]")")
F_STEPBACK=$(fixture stepback "$(result findings "[$(find_obj P2 C1 'Class A' 'one left')]" '[{"classes":["C1"],"name":"Heuristic verdict","invites_because":"prose","approach_change":"schema","prevent":"test"}]')")
F_UNKNOWN=$(fixture unknown "$(result findings "[$(find_obj P2 C99 'Cites unknown id')]")")
# fail-closed fixtures: none of these may ever classify as clean
F_PROSE=$(fixture prose '# Codex Review

I could not complete the review.

```
did not find any definite correctness bugs.
```')
F_CLEAN_WITH_FINDINGS=$(fixture cleanwith "$(result clean "[$(find_obj P1 '' 'x')]")")
F_FINDINGS_EMPTY=$(fixture findempty "$(result findings '[]')")
F_BAD_SEV=$(fixture badsev "$(result findings "[$(find_obj P9 '' 'x')]")")
F_BAD_VERDICT=$(fixture badverdict "$(result maybe '[]')")
F_NO_INSTANCES=$(fixture noinst '{"summary":"s","verdict":"findings","findings":[{"severity":"P1","reopens":"","title":"t","location":"a:1","pattern":"p","still_wrong":"","instances":[],"fix":"f","prevent":"t"}],"step_back":[],"out_of_scope":[]}')
F_MISSING=$(fixture missing '{"summary":"s","verdict":"clean","findings":[]}')
F_BAD_REOPEN=$(fixture badreopen "$(result findings "[$(find_obj P1 'see C1' 'x')]")")

# --- C2: state dir resolves identically from root, a subdirectory and a linked worktree
P_ROOT=$(bash "$CR" paths | kv STATE_DIR)
P_SUB=$(cd sub/dir && bash "$CR" paths | kv STATE_DIR)
expect "paths from subdir" "$P_ROOT" "$P_SUB"
git worktree add -q "$TMP/wt" -b feat/other >/dev/null 2>&1
P_WT=$(cd "$TMP/wt" && bash "$CR" paths | kv STATE_DIR)
expect "linked worktree common dir" "$(dirname "$P_ROOT")/feat__other" "$P_WT"

# --- C1: classification table (structured verdict, fail closed)
expect "clean"           "clean"   "$(run_round "$F_CLEAN" full | kv VERDICT)"
grep -q '^did not find any definite correctness bugs\.$' "$(bash "$CR" paths | kv STATE_DIR)"/rounds/*-full/review.md && ok || bad "clean review.md rendered"
for f in "$F_PROSE" "$F_CLEAN_WITH_FINDINGS" "$F_FINDINGS_EMPTY" "$F_BAD_SEV" "$F_BAD_VERDICT" "$F_NO_INSTANCES" "$F_MISSING" "$F_BAD_REOPEN"; do
  out=$(run_round "$f" full); rc=$?
  expect "fails closed: $(basename "$f")" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
done
out=$(FAKE_RC=1 run_round "$F_CLEAN" full); rc=$?
expect "non-zero codex exit is error" "5" "$rc"
out=$(run_round "$F_DIRTY" full)
expect "dirty verdict" "dirty" "$(printf '%s\n' "$out" | kv VERDICT)"
expect "dirty counts" "1:1" "$(printf '%s\n' "$out" | kv P1):$(printf '%s\n' "$out" | kv P3)"
expect "class ids" "C1,C2" "$(printf '%s\n' "$out" | kv NEW_CLASSES)"
LEDGER=$(bash "$CR" paths | kv LEDGER)
grep -q 'a.txt:9 — old' "$LEDGER" && ok || bad "out-of-scope section recorded in ledger"
grep -q '^- \[P1\] Class A — a.txt:1$' "$(printf '%s\n' "$out" | kv RESULT)" && ok || bad "review.md renders class bullets"
expect "unknown reopen id becomes a new class" "C3:" "$(run_round "$F_UNKNOWN" full | sed -n 's/^NEW_CLASSES=//p;s/^REOPENED=//p' | paste -sd: -)"
expect "p3-only (skip on)" "p3-only" "$(run_round "$F_P3" full | kv VERDICT)"
expect "p3-only strict" "dirty" "$(CR_LOOP_SKIP_P3=0 run_round "$F_P3" full | kv VERDICT)"

# --- state machine: incremental -> cap -> step-back -> exhausted
bash "$CR" reset >/dev/null
run_round "$F_DIRTY" full >/dev/null
for i in 1 2; do
  echo "f$i" >> a.txt && git commit -qam "f$i"
  n=$(bash "$CR" next); expect "next incremental $i" "incremental" "$(printf '%s\n' "$n" | kv MODE)"
  out=$(run_round "$F_REOPEN" incremental "$(printf '%s\n' "$n" | kv SINCE)")
  expect "reopened id $i" "C1" "$(printf '%s\n' "$out" | kv REOPENED)"
done
expect "recurring after reopen" "C1" "$(printf '%s\n' "$out" | kv RECURRING)"
echo f3 >> a.txt && git commit -qam f3
expect "cap -> step-back" "step-back" "$(bash "$CR" next | kv MODE)"
expect "cap wins over confirmation" "step-back" "$(bash "$CR" next --clean-streak 1 | kv MODE)"
out=$(run_round "$F_STEPBACK" step-back)
grep -q '^- \[C1\] Heuristic verdict — Invites it because: prose' "$LEDGER" && ok || bad "step-back assessment recorded in ledger"
expect "step-back resets dirty counter" "0/3" "$(printf '%s\n' "$out" | kv DIRTY_SINCE_STEP_BACK)"
for i in 4 5 6; do
  echo "f$i" >> a.txt && git commit -qam "f$i"
  run_round "$F_REOPEN" incremental "$(bash "$CR" next | kv SINCE)" >/dev/null
done
expect "second cap -> stop" "stop" "$(bash "$CR" next | kv MODE)"
expect "extra step-back authorized" "step-back" "$(CR_LOOP_MAX_STEP_BACKS=2 bash "$CR" next | kv MODE)"
bash "$CR" mark-converged >/dev/null 2>&1; expect "mark-converged refused when not clean" "2" "$?"
run_round "$F_CLEAN" full >/dev/null
expect "cap still wins over streak 1 when exhausted" "stop" "$(bash "$CR" next --base main | kv MODE)"
run_round "$F_CLEAN" full >/dev/null
expect "persisted streak 2 -> converged" "converged" "$(bash "$CR" next --base main | kv MODE)"
bash "$CR" mark-converged --base main >/dev/null; expect "mark-converged succeeds after 2 clean" "0" "$?"
expect "converged resets counters" "full" "$(bash "$CR" next --clean-streak 1 | kv MODE)"
echo postconv >> a.txt && git commit -qam postconv
out=$(run_round "$F_REOPEN" full)
expect "RECURRING resets after ## Converged" "" "$(printf '%s\n' "$out" | kv RECURRING)"
expect "historical class id still reopened after convergence" "C1" "$(printf '%s\n' "$out" | kv REOPENED)"

# --- head drift
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo drift >> a.txt && git commit -qam drift
bash "$CR" wait --timeout 30 >/dev/null
out=$(bash "$CR" finish); rc=$?
expect "head drift" "3:head-drift" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"

# --- deprecated knob mapping
out=$(CR_LOOP_AUTO_WIDEN=0 bash "$CR" init)
expect "AUTO_WIDEN=0 maps" "0" "$(printf '%s\n' "$out" | kv MAX_STEP_BACKS)"
out=$(CR_LOOP_MAX_WIDENING_SWEEPS=2 bash "$CR" init)
expect "MAX_WIDENING_SWEEPS maps" "2" "$(printf '%s\n' "$out" | kv MAX_STEP_BACKS)"

# --- argument parsing never loops on a missing option value
out=$(bash "$CR" start --mode 2>&1); rc=$?
expect "missing option value fails fast" "2" "$rc"

# --- C3: one clean-tree predicate for preflight and completion
expect "tree clean" "clean" "$(bash "$CR" tree-clean | kv TREE)"
echo h > .cr-loop-handoff-round-4.md
out=$(bash "$CR" tree-clean); rc=$?
expect "handoff ignored" "0:clean:1" "$rc:$(printf '%s\n' "$out" | kv TREE):$(printf '%s\n' "$out" | kv IGNORED_HANDOFFS)"
echo x > other.txt
bash "$CR" tree-clean >/dev/null; expect "other untracked file blocks" "1" "$?"
rm other.txt; echo y > sub/dir/.cr-loop-handoff-round-1.md
bash "$CR" tree-clean >/dev/null; expect "nested handoff-looking file blocks" "1" "$?"
rm sub/dir/.cr-loop-handoff-round-1.md; echo z >> a.txt
bash "$CR" tree-clean >/dev/null; expect "tracked change blocks" "1" "$?"
git checkout -q a.txt; rm -f .cr-loop-handoff-round-4.md
printf 'garbage' > "$TMP/bad-index"
out=$(GIT_INDEX_FILE="$TMP/bad-index" bash "$CR" tree-clean); rc=$?
expect "git status failure is never clean" "2:error" "$rc:$(printf '%s\n' "$out" | kv TREE)"

# --- cancel stops the whole round process group (no orphans; isolated to this round's PGID)
out_c=$(FAKE_SLEEP=30 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main)
CPID=$(printf '%s\n' "$out_c" | kv PID)
sleep 1
PG=$(ps -o pgid= -p "$CPID" 2>/dev/null | tr -d ' ')
bash "$CR" cancel >/dev/null
sleep 1
expect "cancel exit code" "130" "$(bash "$CR" status | kv EXIT)"
if [ -n "$PG" ] && ps -axo pgid=,pid= | awk -v pg="$PG" '$1 == pg { found=1 } END { exit !found }'; then
  bad "cancel left an orphaned process in round process group $PG"
else
  ok
fi

# --- C5: one branch lock serializes state transactions
bash "$CR" reset >/dev/null
for i in 1 2 3 4; do (FAKE_SLEEP=3 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main > "$TMP/start.$i" 2>&1; echo $? > "$TMP/start.$i.rc") & done
wait
okc=0; for i in 1 2 3 4; do [ "$(cat "$TMP/start.$i.rc")" = 0 ] && okc=$((okc + 1)); done
expect "concurrent start: exactly one wins" "1" "$okc"
bash "$CR" wait --timeout 30 >/dev/null
for i in 1 2 3; do (bash "$CR" finish > "$TMP/fin.$i" 2>&1; echo $? > "$TMP/fin.$i.rc") & done
wait
okc=0; for i in 1 2 3; do [ "$(cat "$TMP/fin.$i.rc")" = 0 ] && okc=$((okc + 1)); done
expect "concurrent finish: exactly one completes" "1" "$okc"
expect "round appended to ledger once" "1" "$(grep -c '^## Round ' "$(bash "$CR" paths | kv LEDGER)")"
for i in 1 2 3 4 5 6 7 8; do (bash "$CR" add P2 "concurrent class $i — a.txt:$i" > "$TMP/add.$i" 2>&1) & done
wait
ids=$(cat "$TMP"/add.* | sed -n 's/^ID=//p' | sort -u | wc -l | tr -d ' ')
expect "concurrent add: 8 unique ids" "8" "$ids"
expect "next_class_id not lost" "9" "$(sed -n 's/^next_class_id=//p' "$(bash "$CR" paths | kv STATE)" | tail -n 1)"
# Same race with the caller holding fds 3-8 open, so the lock fd itself lands on 9.
rm -f "$TMP"/add.*
for i in 1 2 3 4 5 6 7 8; do (exec 3</dev/null 4</dev/null 5</dev/null 6</dev/null 7</dev/null 8</dev/null; bash "$CR" add P2 "fd9 class $i — a.txt:$i" > "$TMP/add.$i" 2>&1) & done
wait
expect "concurrent add with fds 3-8 open: 8 unique ids" "8" "$(cat "$TMP"/add.* | sed -n 's/^ID=//p' | sort -u | wc -l | tr -d ' ')"
LOCKF="$(bash "$CR" paths | kv STATE_DIR).lock"
hold_lock() { perl -MFcntl=:flock -e 'open(my $l, ">>", $ARGV[0]) or die; flock($l, LOCK_EX) or die; sleep $ARGV[1];' "$LOCKF" "$1" & HOLDER=$!; sleep 0.5; }
hold_lock 30; kill -9 "$HOLDER"; wait "$HOLDER" 2>/dev/null
t0=$(date +%s); bash "$CR" note "after holder crash" >/dev/null; rc=$?
expect "lock released when holder crashes" "0" "$rc"
[ $(( $(date +%s) - t0 )) -lt 5 ] && ok || bad "crash recovery should not wait for a timeout"
hold_lock 2
t0=$(date +%s); bash "$CR" note "waits for live holder" >/dev/null; rc=$?; el=$(( $(date +%s) - t0 ))
expect "waits for a live holder, then succeeds" "0" "$rc"
[ "$el" -ge 1 ] && ok || bad "note did not wait for the live lock holder (elapsed ${el}s)"
wait "$HOLDER" 2>/dev/null
FAKE_SLEEP=6 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
t0=$(date +%s); bash "$CR" note "while a round runs" >/dev/null; el=$(( $(date +%s) - t0 ))
expect "running reviewer does not hold the lock" "running" "$(bash "$CR" status | kv STATE)"
[ "$el" -lt 3 ] && ok || bad "note blocked ${el}s behind the running reviewer (lock fd leaked into it)"
bash "$CR" wait --timeout 30 >/dev/null; bash "$CR" finish >/dev/null

# --- C6: a persisted PID reused by an unrelated process is never treated as the reviewer
sleep 30 & STRANGER=$!
SD=$(bash "$CR" paths | kv STATE_DIR)
GHOST="$SD/rounds/999-full"; mkdir -p "$GHOST"
printf 'mode=full\nreviewed_head=%s\nround=999\nstarted_epoch=%s\n' "$(git rev-parse HEAD)" "$(date +%s)" > "$GHOST/meta"
printf '%s\n' "$STRANGER" > "$GHOST/pid"; printf '%s\n' "$STRANGER" > "$GHOST/codex.pid"
expect "reused PID is not a running round" "dead" "$(bash "$CR" status "$GHOST" | kv STATE)"
bash "$CR" cancel "$GHOST" >/dev/null
kill -0 "$STRANGER" 2>/dev/null && ok || bad "cancel signalled an unrelated process that reused the PID"
sed -i.bak "s#^current_round_dir=.*#current_round_dir=$GHOST#" "$(bash "$CR" paths | kv STATE)"
FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null; expect "start not blocked by a reused PID" "0" "$?"
bash "$CR" wait --timeout 30 >/dev/null; bash "$CR" finish >/dev/null
kill "$STRANGER" 2>/dev/null; wait "$STRANGER" 2>/dev/null

# --- v1.8.0: rules come from the base, the branch's rule-file edits are reviewed content
R2="$TMP/repo2"; mkdir -p "$R2/sub" && cd "$R2" || exit 2
git init -q -b main . && git config user.email t@example.invalid && git config user.name t
echo code > app.txt
printf '# REVIEW\n\n## no-raw-sql\nNever build SQL by string concatenation.\n' > REVIEW.md
printf '# sub rules\nAlways close handles.\n' > sub/AGENTS.md
git add . && git commit -qm base
BASE_SHA=$(git rev-parse main)
new_branch() { git switch -q main && git switch -qc "$1" && echo "$1" >> app.txt && git commit -qam "code $1"; }
rd() { bash "$CR" paths | kv STATE_DIR; }
last_round() { ls -d "$(rd)"/rounds/* | tail -n 1; }

new_branch rules/delete; git rm -q REVIEW.md && git commit -qm "drop review rules"
out=$(FAKE_ARGS="$TMP/args" run_round "$F_CLEAN" full); rc=$?; P="$(last_round)/prompt.md"
grep -qF "\`git show $BASE_SHA:<path>\`" "$P" && grep -qx '    REVIEW.md' "$P" && ok || bad "base rule deleted on branch: prompt still points at the base copy"
grep -q 'Read REVIEW.md (repository root' "$P" && bad "prompt still tells the reviewer to read the working tree" || ok
grep -q 'project_doc_max_bytes=0' "$TMP/args" && ok || bad "codex must run with project docs (worktree AGENTS.md) disabled"
expect "branch deletes rule file: listed for a person" "0:needs-human:1" "$rc:$(printf '%s\n' "$out" | kv VERDICT):$(printf '%s\n' "$out" | kv RULES_NEED_HUMAN)"
grep -q '^\s*\[needs-human\] D ' "$P" && ok || bad "prompt lists the deletion as content under review"

new_branch rules/relax; sed -i.bak 's/^Never build SQL/Prefer not to build SQL/' REVIEW.md && rm REVIEW.md.bak && git commit -qam "relax rule"
out=$(run_round "$F_CLEAN" full)
expect "branch relaxes rule: not clean" "needs-human" "$(printf '%s\n' "$out" | kv VERDICT)"
FP=$(printf '%s\n' "$out" | kv RULES_FP)
grep -q '^## Rule-file edits that need a person' "$(printf '%s\n' "$out" | kv RESULT)" && grep -q '^- M +1/-1 REVIEW.md$' "$(printf '%s\n' "$out" | kv RESULT)" && ok || bad "relaxation listed in its own review.md section"
grep -q "^#### Rule-file edits awaiting a person (fingerprint $FP)" "$(bash "$CR" paths | kv LEDGER)" && ok || bad "relaxation recorded in the ledger"
expect "relaxation does not count as dirty" "0/3" "$(printf '%s\n' "$out" | kv DIRTY_SINCE_STEP_BACK)"
expect "relaxation alongside findings stays dirty and flagged" "dirty:1" "$(run_round "$F_DIRTY" full | sed -n 's/^VERDICT=//p;s/^RULES_NEED_HUMAN=//p' | paste -sd: -)"
bash "$CR" ack-rules deadbeef >/dev/null 2>&1; expect "ack with a stale fingerprint is refused" "2" "$?"
run_round "$F_CLEAN" full >/dev/null
expect "ack with the pending fingerprint" "$FP" "$(bash "$CR" ack-rules "$FP" "reviewed by owner" | kv ACKED)"
out=$(run_round "$F_CLEAN" full)
expect "acked rule edit: clean" "clean:0" "$(printf '%s\n' "$out" | kv VERDICT):$(printf '%s\n' "$out" | kv RULES_NEED_HUMAN)"
sed -i.bak 's/^Prefer not to/You may/' REVIEW.md && rm REVIEW.md.bak && git commit -qam "relax more"
out=$(run_round "$F_CLEAN" full)
expect "further rule edit re-arms the gate" "needs-human" "$(printf '%s\n' "$out" | kv VERDICT)"
[ "$(printf '%s\n' "$out" | kv RULES_FP)" != "$FP" ] && ok || bad "new rule edit must get a new fingerprint"
RRS="$HERE/review-rules.sh"
expect "rule fingerprint from a subdirectory matches the root" "$(bash "$RRS" fp "$BASE_SHA" HEAD)" "$(cd sub && bash "$RRS" fp "$BASE_SHA" HEAD)"
expect "rule classification from a subdirectory matches the root" "$(bash "$RRS" list "$BASE_SHA" HEAD)" "$(cd sub && bash "$RRS" list "$BASE_SHA" HEAD)"
(cd sub && bash "$RRS" prompt main "$BASE_SHA" HEAD) | grep -qx '    REVIEW.md' && ok || bad "base rule inventory from a subdirectory covers the whole tree"
FP2=$(cd sub && bash "$RRS" fp "$BASE_SHA" HEAD)
sed -i.bak 's/^You may/You can always/' REVIEW.md && rm REVIEW.md.bak && git commit -qam "relax differently"
[ "$(cd sub && bash "$RRS" fp "$BASE_SHA" HEAD)" != "$FP2" ] && ok || bad "different rewrites must get different fingerprints from a subdirectory"

new_branch rules/add; printf '\n## close-handles\nClose every handle you open.\n' >> REVIEW.md
printf '# new\nPrefer small functions.\n' > NEWDIR_AGENTS.tmp; mkdir -p lib && mv NEWDIR_AGENTS.tmp lib/AGENTS.md
git add . && git commit -qm "codify at source"
out=$(run_round "$F_CLEAN" full)
expect "branch only adds rule entries: no false positive" "clean:2:0" "$(printf '%s\n' "$out" | kv VERDICT):$(printf '%s\n' "$out" | kv RULE_CHANGES):$(printf '%s\n' "$out" | kv RULES_NEED_HUMAN)"
grep -q '^\s*\[additive\] M +3/-0 REVIEW.md' "$(last_round)/prompt.md" && ok || bad "additions listed as content under review in the prompt"
grep -q '^## Rule-file additions' "$(printf '%s\n' "$out" | kv RESULT)" && ok || bad "additions listed in review.md"

new_branch rules/nested; git rm -q sub/AGENTS.md && git commit -qm "drop nested rules"
expect "nested rule file deleted: listed for a person" "needs-human" "$(run_round "$F_CLEAN" full | kv VERDICT)"

new_branch rules/newline-path; printf 'x\n' > "$(printf '0\nextra.txt')"
sed -i.bak 's/^Never build SQL/Prefer not to build SQL/' REVIEW.md && rm REVIEW.md.bak && git add -A && git commit -qm "newline filename + relax"
out=$(run_round "$F_CLEAN" full)
expect "newline in another filename cannot hide a rule edit" "needs-human:1" "$(printf '%s\n' "$out" | kv VERDICT):$(printf '%s\n' "$out" | kv RULES_NEED_HUMAN)"
mkdir -p "$(printf 'odd\ndir')" && printf 'r\n' > "$(printf 'odd\ndir')/AGENTS.md" && git add -A && git commit -qm "rule file under a newline dir"
grep -qF 'odd\ndir/AGENTS.md' "$(run_round "$F_CLEAN" full | kv RESULT)" && ok || bad "a rule path with a newline is escaped onto one line"

new_branch rules/textconv
printf 'REVIEW.md diff=lossy\n' > "$(git rev-parse --git-dir)/info/attributes"; git config diff.lossy.textconv 'head -n 1'
sed -i.bak 's/^Never build SQL/Sometimes build SQL/' REVIEW.md && rm REVIEW.md.bak && git commit -qam "rewrite 1"
TC1=$(bash "$HERE/review-rules.sh" fp "$BASE_SHA" HEAD)
sed -i.bak 's/^Sometimes build SQL/Always build SQL/' REVIEW.md && rm REVIEW.md.bak && git commit -qam "rewrite 2"
[ -n "$TC1" ] && [ "$(bash "$HERE/review-rules.sh" fp "$BASE_SHA" HEAD)" != "$TC1" ] && ok || bad "a lossy textconv cannot make two rewrites share one fingerprint"
expect "textconv does not hide a rewrite from classification" "needs-human" "$(bash "$HERE/review-rules.sh" list "$BASE_SHA" HEAD | cut -f1)"
rm -f "$(git rev-parse --git-dir)/info/attributes"; git config --unset diff.lossy.textconv

# a failed rule-file scan is an error, never "no rule edits"
FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null; bash "$CR" wait --timeout 30 >/dev/null
out=$(TMPDIR="$TMP/no-such-dir" bash "$CR" finish 2>/dev/null); rc=$?
expect "rule scan failure at finish fails closed" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
expect "round stays retryable after a scan failure" "needs-human" "$(bash "$CR" finish | kv VERDICT)"
nb=$(ls "$(rd)/rounds" | wc -l | tr -d ' ')
TMPDIR="$TMP/no-such-dir" FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null 2>&1; rc=$?
expect "rule scan failure at start starts nothing" "2:$nb" "$rc:$(ls "$(rd)/rounds" | wc -l | tr -d ' ')"
FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null; expect "start works again after a scan failure" "0" "$?"
bash "$CR" wait --timeout 30 >/dev/null; bash "$CR" finish >/dev/null

# --- v1.8.0: a result is bound to the commit + tracked tree the reviewer read
new_branch drift/tree
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo edit >> app.txt; bash "$CR" wait --timeout 30 >/dev/null
out=$(bash "$CR" finish); rc=$?
expect "uncommitted edit during the round" "3:tree-changed" "$rc:$(printf '%s\n' "$out" | kv REASON)"
git checkout -q app.txt
printf 'app.txt diff=lossy\n' > "$(git rev-parse --git-dir)/info/attributes"; git config diff.lossy.textconv 'head -n 1'
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo hidden-by-textconv >> app.txt; bash "$CR" wait --timeout 30 >/dev/null
out=$(bash "$CR" finish); rc=$?
expect "edit hidden by a lossy textconv is still tree drift" "3:tree-changed" "$rc:$(printf '%s\n' "$out" | kv REASON)"
git checkout -q app.txt; rm -f "$(git rev-parse --git-dir)/info/attributes"; git config --unset diff.lossy.textconv
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo tmp >> app.txt && git commit -qam tmp && git reset -q --hard HEAD~1
bash "$CR" wait --timeout 30 >/dev/null
out=$(bash "$CR" finish); rc=$?
expect "HEAD moved and came back during the round" "3:head-moved-and-returned" "$rc:$(printf '%s\n' "$out" | kv REASON)"
FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null; bash "$CR" wait --timeout 30 >/dev/null
sed -i.bak '/^head_moves=/d; /^tree_fp=/d' "$(last_round)/meta"
expect "pre-1.8.0 round meta still finishes" "clean" "$(bash "$CR" finish | kv VERDICT)"

# --- v1.8.1: strict JSON validation (duplicate keys, extra keys, non-string scalars, duplicate non-empty reopens)
new_branch v181/strict
F_DUP_KEY=$(fixture dupkey '{"summary":"s","verdict":"findings","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}')
F_EXTRA_KEY=$(fixture extrakey '{"summary":"s","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[],"extra":1}')
F_NUM_STR=$(fixture numstr '{"summary":123,"verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}')
F_DUP_REOPEN=$(fixture dupreopen "$(result findings "[$(find_obj P1 C1 'Dup A' 'x'),$(find_obj P2 C1 'Dup B' 'y')]")")
F_TWO_NEW=$(fixture twonew "$(result findings "[$(find_obj P1 '' 'New A'),$(find_obj P2 '' 'New B')]")")
for f in "$F_DUP_KEY" "$F_EXTRA_KEY" "$F_NUM_STR" "$F_DUP_REOPEN"; do
  out=$(run_round "$f" full); rc=$?
  expect "v1.8.1 strict fails closed: $(basename "$f")" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
done
expect "multiple new findings with empty reopens succeed" "dirty" "$(run_round "$F_TWO_NEW" full | kv VERDICT)"

# --- v1.8.1: atomic pending.tx recovery, writer barrier, idempotent explicit finish & superseded round guard
new_branch v181/tx
out_s=$(FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main)
RD1=$(printf '%s\n' "$out_s" | kv ROUND_DIR)
bash "$CR" wait --timeout 30 >/dev/null
out_f1=$(bash "$CR" finish "$RD1")
expect "first explicit finish clean" "clean" "$(printf '%s\n' "$out_f1" | kv VERDICT)"
out_f1_again=$(bash "$CR" finish "$RD1"); rc=$?
expect "explicit retry on finished round is idempotent" "0:clean" "$rc:$(printf '%s\n' "$out_f1_again" | kv VERDICT)"
expect "idempotent finish did not double-append ledger" "1" "$(grep -c '^## Round ' "$(bash "$CR" paths | kv LEDGER)")"
# Simulate crash right after pending.tx was published (before ledger/state/finished applied)
out_s2=$(FAKE_OUT="$F_DIRTY" bash "$CR" start --mode full --base main)
RD2=$(printf '%s\n' "$out_s2" | kv ROUND_DIR)
bash "$CR" wait --timeout 30 >/dev/null
bash "$CR" finish "$RD2" >/dev/null
# Restore pre-RD2 ledger/state while leaving RD2/tx + pending.tx active to simulate mid-commit crash, then call `add` first (writer barrier)
SD_TX=$(bash "$CR" paths | kv STATE_DIR)
rm -f "$RD2/finished" "$RD2/verdict"
sed -i.bak '/^## Round 2 /,$d' "$SD_TX/ledger.md" && rm -f "$SD_TX/ledger.md.bak"
printf 'tx_dir=%s/tx\ntx_branch=%s\ntx_kind=finish\ntx_round_dir=%s\n' "$RD2" "v181/tx" "$RD2" > "$SD_TX/pending.tx"
add_id=$(bash "$CR" add P2 "after crash — app.txt:1" | kv ID)
expect "writer barrier replayed pending finish before add" "C3" "$add_id"
expect "pending.tx cleared after recovery" "0" "$([ -f "$SD_TX/pending.tx" ] && echo 1 || echo 0)"
expect "recovered finish marked finished" "1" "$([ -f "$RD2/finished" ] && echo 1 || echo 0)"
expect "ledger has both recovered Round 2 and external finding" "1:1" "$(grep -c '^## Round 2 ' "$SD_TX/ledger.md"):$(grep -c '^### C3 ' "$SD_TX/ledger.md")"
# Out-of-order stale round cannot commit after a newer round starts
out_a=$(FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main); RDA=$(printf '%s\n' "$out_a" | kv ROUND_DIR)
bash "$CR" wait --timeout 30 >/dev/null
out_b=$(FAKE_OUT="$F_DIRTY" bash "$CR" start --mode full --base main); RDB=$(printf '%s\n' "$out_b" | kv ROUND_DIR)
bash "$CR" wait --timeout 30 >/dev/null
bash "$CR" finish "$RDB" >/dev/null
bash "$CR" finish "$RDA" >/dev/null 2>&1; expect "superseded older round refused" "2" "$?"

# --- v1.8.1: .gitattributes-immune binary rule check, symlink A/M, diff.relative=true
new_branch v181/rules-bin
printf 'CLAUDE.md diff\n' > .gitattributes
printf 'hello\0world\n' > CLAUDE.md
git add .gitattributes CLAUDE.md && git commit -qm "add binary CLAUDE.md with diff text attr"
expect "added binary rule file with diff attr is needs-human" "needs-human:1" "$(run_round "$F_CLEAN" full | sed -n 's/^VERDICT=//p;s/^RULES_NEED_HUMAN=//p' | paste -sd: -)"
rm -f CLAUDE.md && ln -s /etc/hosts CLAUDE.md && git add CLAUDE.md && git commit -qm "symlink CLAUDE.md"
expect "symlink rule file is needs-human" "needs-human" "$(run_round "$F_CLEAN" full | kv VERDICT)"
rm -f CLAUDE.md && ln -s /etc/passwd CLAUDE.md && git add CLAUDE.md && git commit -qm "modify symlink CLAUDE.md"
expect "modified symlink rule file is needs-human" "needs-human" "$(run_round "$F_CLEAN" full | kv VERDICT)"
# diff.relative=true from subdir must not hide root rule files
expect "diff.relative=true from subdir still detects root rule edit" "needs-human" "$(cd sub && git -c diff.relative=true rev-parse --show-toplevel >/dev/null && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=diff.relative GIT_CONFIG_VALUE_0=true bash "$HERE/review-rules.sh" list "$BASE_SHA" HEAD | awk -F '\t' '$4=="CLAUDE.md" {print $1}')"

# --- v1.8.1: persisted clean_streak, dirty non-credit on ack-rules, full-mode convergence & post-rebase proof
new_branch v181/streak
sed -i.bak 's/^Never build SQL/Prefer not to build SQL/' REVIEW.md && rm -f REVIEW.md.bak && git commit -qam "relax for streak"
out_d=$(run_round "$F_DIRTY" full)
FP_D=$(printf '%s\n' "$out_d" | kv RULES_FP)
bash "$CR" ack-rules "$FP_D" "should fail on dirty" >/dev/null 2>&1
expect "dirty round never gets ack-rules clean credit" "2" "$?"
out_nh=$(run_round "$F_CLEAN" full)
FP_NH=$(printf '%s\n' "$out_nh" | kv RULES_FP)
out_ack=$(bash "$CR" ack-rules "$FP_NH" --base main "approved")
expect "ack-rules grants clean streak 1 once" "1" "$(printf '%s\n' "$out_ack" | kv CLEAN_STREAK)"
bash "$CR" ack-rules "$FP_NH" --base main "duplicate" >/dev/null 2>&1
expect "duplicate ack-rules refused" "2" "$?"
# Incremental clean round as 2nd round cannot satisfy mark-converged (needs full)
echo inc1 >> app.txt && git commit -qam inc1
run_round "$F_CLEAN" full >/dev/null
# Reset head to confirm non-full 2nd round check using step-back mode
run_round "$F_CLEAN" step-back >/dev/null
bash "$CR" mark-converged --base main >/dev/null 2>&1
expect "mark-converged rejects non-full 2nd clean round" "2" "$?"
run_round "$F_CLEAN" full >/dev/null
bash "$CR" mark-converged --base main >/dev/null
expect "mark-converged succeeds after full 2nd clean round" "0" "$?"
# Base change invalidates persisted streak
git branch other-base HEAD~1
expect "base change invalidates persisted streak" "full" "$(bash "$CR" next --base other-base | kv MODE)"
# Post-rebase confirmation proof recorded cleanly
run_round "$F_CLEAN" full >/dev/null
bash "$CR" mark-converged --post-rebase --base main --round "$(last_round)" >/dev/null
expect "mark-converged --post-rebase succeeds with prior 2-round proof" "0" "$?"
grep -q '^## Converged (post-rebase 1-round full confirmation)' "$(bash "$CR" paths | kv LEDGER)" && ok || bad "post-rebase convergence logged"

# --- v1.8.1: fail-closed tree_fp v2 (untracked files caught, handoffs ignored, bad index fails closed)
new_branch v181/drift-v2
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo stray > stray-untracked.txt
bash "$CR" wait --timeout 30 >/dev/null
out=$(bash "$CR" finish); rc=$?
expect "untracked file added during round is tree-changed" "3:tree-changed" "$rc:$(printf '%s\n' "$out" | kv REASON)"
rm -f stray-untracked.txt
FAKE_SLEEP=2 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
echo h > .cr-loop-handoff-round-9.md
bash "$CR" wait --timeout 30 >/dev/null
expect "untracked root handoff file ignored by tree_fp v2" "clean" "$(bash "$CR" finish | kv VERDICT)"
rm -f .cr-loop-handoff-round-9.md
FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null; bash "$CR" wait --timeout 30 >/dev/null
out=$(GIT_INDEX_FILE="$TMP/bad-index" bash "$CR" finish 2>/dev/null); rc=$?
expect "corrupt index at finish fails closed as error (not clean)" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"

# --- v1.8.1: ps -ww handles long worktree paths without truncating _run <round-dir>
LONG_WT="$TMP/very-long-worktree-directory-name-exceeding-standard-eighty-column-ps-width-limit/nested"
mkdir -p "$(dirname "$LONG_WT")"
git worktree add -q "$LONG_WT" -b v181/longpath >/dev/null 2>&1
(
  cd "$LONG_WT" || exit 2
  out_lp=$(FAKE_SLEEP=5 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main)
  sleep 1
  st_lp=$(bash "$CR" status | kv STATE)
  bash "$CR" cancel >/dev/null
  [ "$st_lp" = "running" ]
) && ok || bad "runner_pid failed on long worktree path (ps -ww)"

# --- Post-review hardening: P0\n bypass, release-state, staged-only tree_fp, cr-tx dir conflict ---

# 1. Trailing newline in severity / verdict / reopens MUST fail closed (never clean!)
F_SEV_NL=$(fixture sevnl '{"summary":"s","verdict":"findings","findings":[{"severity":"P0\n","reopens":"","title":"P0 drop","location":"a.txt:1","pattern":"p","still_wrong":"","instances":["a.txt:1"],"fix":"f","prevent":"t"}],"step_back":[],"out_of_scope":[]}')
F_VERD_NL=$(fixture verdnl '{"summary":"s","verdict":"clean\n","findings":[],"step_back":[],"out_of_scope":[]}')
F_REO_NL=$(fixture reonl '{"summary":"s","verdict":"findings","findings":[{"severity":"P1","reopens":"C1\n","title":"Re","location":"a.txt:1","pattern":"p","still_wrong":"still","instances":["a.txt:1"],"fix":"f","prevent":"t"}],"step_back":[],"out_of_scope":[]}')
for f in "$F_SEV_NL" "$F_VERD_NL" "$F_REO_NL"; do
  out=$(run_round "$f" full); rc=$?
  expect "fails closed on trailing newline: $(basename "$f")" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
done

# 2. release-state get | set | clear (and disallow arbitrary keys)
bash "$CR" release-state set rel_pre_rebase_head="$(git rev-parse HEAD)" rel_pinned_remote_head_sha="deadbeef" rel_target_base_sha="cafebabe" rel_rebased_in_8_0=1 >/dev/null
expect "release-state set succeeded" "0" "$?"
out_rs=$(bash "$CR" release-state get)
expect "release-state persisted values" "deadbeef:cafebabe:1" "$(printf '%s\n' "$out_rs" | kv PINNED_REMOTE_HEAD_SHA):$(printf '%s\n' "$out_rs" | kv TARGET_BASE_SHA):$(printf '%s\n' "$out_rs" | kv REBASED_IN_8_0)"
bash "$CR" release-state set clean_streak=99 >/dev/null 2>&1
expect "release-state rejects disallowed key" "2" "$?"
bash "$CR" release-state clear >/dev/null
out_rsc=$(bash "$CR" release-state get)
expect "release-state cleared" "::0" "$(printf '%s\n' "$out_rsc" | kv PINNED_REMOTE_HEAD_SHA):$(printf '%s\n' "$out_rsc" | kv TARGET_BASE_SHA):$(printf '%s\n' "$out_rsc" | kv REBASED_IN_8_0)"

# 3. Staged-only index edit (working tree restored to HEAD) caught by tree_fp_v2!
FAKE_SLEEP=1 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
printf 'staged-only-change\n' >> app.txt
git add app.txt
git show HEAD:app.txt > app.txt
[ -z "$(git diff HEAD)" ] && [ -n "$(git diff --cached)" ] && ok || bad "staged-only setup failed"
bash "$CR" wait --timeout 30 >/dev/null
out_st=$(bash "$CR" finish); rc=$?
expect "staged-only index change caught as head-drift (tree-changed)" "3:head-drift:tree-changed" "$rc:$(printf '%s\n' "$out_st" | kv VERDICT):$(printf '%s\n' "$out_st" | kv REASON)"
git reset -q HEAD app.txt

# 4. cr-tx.sh directory-target conflict fails closed AND preserves pending.tx!
SD_CR=$(bash "$CR" paths | kv STATE_DIR)
TX_DIR_BAD="$SD_CR/tx-dir-conflict"
mkdir -p "$TX_DIR_BAD" "$SD_CR/rounds/999-full/verdict"
cp "$SD_CR/ledger.md" "$TX_DIR_BAD/ledger.full"
cp "$SD_CR/state" "$TX_DIR_BAD/state.full"
printf 'VERDICT=clean\n' > "$TX_DIR_BAD/verdict.out"
{
  printf 'tx_dir=%s\n' "$TX_DIR_BAD"
  printf 'tx_branch=%s\n' "$(git branch --show-current)"
  printf 'tx_kind=finish\n'
  printf 'tx_round_dir=%s/rounds/999-full\n' "$SD_CR"
} > "$SD_CR/pending.tx"
bash "$CR" init >/dev/null 2>&1
expect "cr-tx directory target conflict fails closed" "2" "$?"
[ -f "$SD_CR/pending.tx" ] && ok || bad "cr-tx deleted pending.tx despite directory target conflict!"
rm -rf "$SD_CR/pending.tx" "$TX_DIR_BAD" "$SD_CR/rounds/999-full"

# --- Round 2 hardening regressions: immutable BASE_SHA rewind check, dirty submodule 2nd edit, PR preflight ahead check, space worktree ---

# 5. mark-converged & release-state expose immutable CONVERGED_BASE_SHA (catches target rewind B..A!)
B_SHA=$(git rev-parse main)
git switch -qc r2/rewind-base main
printf 'base-a\n' > rewind-base.txt && git add rewind-base.txt && git commit -qm "base A"
A_SHA=$(git rev-parse HEAD)
git switch -qc r2/rewind-check "$A_SHA"
printf 'feat-f\n' > rewind-feat.txt && git add rewind-feat.txt && git commit -qm "feat F"
for _i in 1 2; do
  FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base r2/rewind-base >/dev/null
  bash "$CR" wait --timeout 30 >/dev/null
  bash "$CR" finish >/dev/null
done
out_mc=$(bash "$CR" mark-converged --base r2/rewind-base)
expect "mark-converged emits immutable BASE_SHA" "$A_SHA" "$(printf '%s\n' "$out_mc" | kv BASE_SHA)"
expect "release-state get exposes CONVERGED_BASE_SHA" "$A_SHA" "$(bash "$CR" release-state get | kv CONVERGED_BASE_SHA)"
# Simulate target rewind to ancestor B: mutable ref passes, immutable CONVERGED_BASE_SHA catches B..A!
REV_BASE_SHA=$(bash "$CR" release-state get | kv CONVERGED_BASE_SHA)
git branch -f r2/rewind-base "$B_SHA"
PR_MB_REWIND=$(git merge-base r2/rewind-base HEAD)
git merge-base --is-ancestor "$(git rev-parse r2/rewind-base)" "$PR_MB_REWIND" && ok || bad "rewind setup sanity failed"
if git merge-base --is-ancestor "$REV_BASE_SHA" "$PR_MB_REWIND" 2>/dev/null; then
  bad "immutable CONVERGED_BASE_SHA failed to detect target rewind"
else
  ok
fi
git branch -D r2/rewind-base >/dev/null 2>&1

# 6. tree_fp_v2 catches a SECOND edit to an already-dirty tracked submodule file!
SUB_REPO="$TMP/submod-src"
mkdir -p "$SUB_REPO"
(
  cd "$SUB_REPO" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'sub-v1\n' > sub.txt && git add sub.txt && git commit -qm sub1
)
SUB_HOST="$TMP/submod-host"
mkdir -p "$SUB_HOST"
(
  cd "$SUB_HOST" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'host-v1\n' > host.txt && git add host.txt && git commit -qm host1
  git -c protocol.file.allow=always submodule -q add "$SUB_REPO" vendor/sub >/dev/null 2>&1
  git commit -qm "add submodule"
  git switch -qc feat/submod
  printf 'feat\n' >> host.txt && git commit -qam "feat edit"
  # Dirty tracked submodule file BEFORE review starts!
  printf 'dirty-1\n' >> vendor/sub/sub.txt
  FAKE_SLEEP=1 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
  # Make a SECOND edit to the SAME already-dirty submodule file mid-round!
  printf 'dirty-2\n' >> vendor/sub/sub.txt
  bash "$CR" wait --timeout 30 >/dev/null
  out_sub=$(bash "$CR" finish); rc_sub=$?
  [ "$rc_sub" -eq 3 ] && [ "$(printf '%s\n' "$out_sub" | kv REASON)" = "tree-changed" ]
) && ok || bad "tree_fp_v2 missed 2nd edit inside already-dirty tracked submodule!"

# 7. PR preflight: default target ahead does NOT trip coverage check before Base-currency rebase prompt;
#    explicit intermediate BASE (PR_TARGET -> E -> HEAD) STILL fails coverage check!
PRE_REPO="$TMP/preflight-ahead"
mkdir -p "$PRE_REPO"
(
  cd "$PRE_REPO" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf '1\n' > f.txt && git add f.txt && git commit -qm c1
  git switch -qc feat/ahead
  printf 'e\n' >> f.txt && git commit -qam e1
  E_SHA=$(git rev-parse HEAD)
  printf 'f\n' >> f.txt && git commit -qam f1
  git switch -q main && printf 'm2\n' > m.txt && git add m.txt && git commit -qm m2
  git switch -q feat/ahead
  # Default BASE=main (ahead of HEAD): Base-currency fails (offering rebase), while BASE_MB==PR_MB passes coverage!
  PR_MB=$(git merge-base main HEAD)
  BASE_MB=$(git merge-base main HEAD)
  ! git merge-base --is-ancestor main HEAD &&
    git merge-base --is-ancestor "$BASE_MB" "$PR_MB" &&
    ! git merge-base --is-ancestor "$(git merge-base "$E_SHA" HEAD)" "$PR_MB"
) && ok || bad "PR preflight coverage math failed for ahead target / intermediate base"

# 8. Space-safe worktree parsing preserves full worktree path containing spaces!
SPACE_WT="$TMP/main checkout with spaces"
git branch space-target main
git worktree add -q "$SPACE_WT" space-target >/dev/null 2>&1
PARSED_WT=$(git worktree list --porcelain | awk -v t="refs/heads/space-target" '/^worktree / {wt=$0; sub(/^worktree /, "", wt)} $0=="branch "t {print wt; exit}')
REAL_SPACE_WT=$(cd "$SPACE_WT" && pwd -P)
expect "space-safe worktree parser preserves spaces in path" "$REAL_SPACE_WT" "$PARSED_WT"
git worktree remove -f "$SPACE_WT" >/dev/null 2>&1
git branch -D space-target >/dev/null 2>&1

# --- Round 3 hardening regressions: CAS merge TOCTOU, git SIGTERM UNBORN trap, unborn stderr silence ---

# 9. CAS merge protocol aborts atomically when target ref rewinds A -> B after coverage check!
CAS_REPO="$TMP/cas-merge-repo"
CAS_MAIN_WT="$TMP/cas-main-wt"
mkdir -p "$CAS_REPO"
(
  cd "$CAS_REPO" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'b\n' > f.txt && git add f.txt && git commit -qm "commit B"
  B_SHA=$(git rev-parse HEAD)
  printf 'a\n' >> f.txt && git commit -qam "commit A"
  A_SHA=$(git rev-parse HEAD)
  git switch -qc feat/cas
  printf 'f\n' >> f.txt && git commit -qam "commit F"
  F_SHA=$(git rev-parse HEAD)
  git worktree add -q "$CAS_MAIN_WT" main >/dev/null 2>&1
  # Coverage check pins EXPECTED_TARGET_SHA=A_SHA
  EXPECTED_TARGET_SHA=$(git rev-parse --verify refs/heads/main)
  [ "$EXPECTED_TARGET_SHA" = "$A_SHA" ] || exit 11
  # Concurrent rewind moves main from A -> B right before ref update!
  git -C "$CAS_MAIN_WT" checkout -q --detach "$EXPECTED_TARGET_SHA"
  git -C "$CAS_MAIN_WT" merge -q --ff-only "$F_SHA"
  NEW_TARGET_SHA=$(git -C "$CAS_MAIN_WT" rev-parse HEAD)
  git update-ref refs/heads/main "$B_SHA" "$A_SHA"
  # Atomic CAS update-ref MUST FAIL because refs/heads/main is now B_SHA != EXPECTED_TARGET_SHA!
  if git -C "$CAS_MAIN_WT" update-ref refs/heads/main "$NEW_TARGET_SHA" "$EXPECTED_TARGET_SHA" 2>/dev/null; then
    exit 12
  fi
  git -C "$CAS_MAIN_WT" checkout -q main
  [ "$(git rev-parse refs/heads/main)" = "$B_SHA" ] || exit 13
) && ok || bad "CAS merge failed to abort on concurrent target rewind A -> B"

# 9b. Round 4 High #4: Path A git checkout refuses atomically when target is concurrently checked out in another worktree,
#     and both merge protocols enforce repo-common lock + re-run defer guidance (no bare git merge on target move/rewind).
PA_REPO="$TMP/patha-race-repo"
PA_OTHER_WT="$TMP/patha-other-wt"
mkdir -p "$PA_REPO"
(
  cd "$PA_REPO" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'a\n' > f.txt && git add f.txt && git commit -qm "commit A"
  A_SHA=$(git rev-parse HEAD)
  git switch -qc feat/patha
  printf 'f\n' >> f.txt && git commit -qam "commit F"
  # Simulate concurrent checkout of main in another worktree right after Path A detection:
  git worktree add -q "$PA_OTHER_WT" main >/dev/null 2>&1
  # Path A claims main via git checkout (NOT bare update-ref) -> Git MUST reject atomically, leaving PA_OTHER_WT intact!
  if git checkout -q main 2>/dev/null; then
    exit 21
  fi
  [ "$(git rev-parse refs/heads/main)" = "$A_SHA" ] || exit 22
  [ "$(git -C "$PA_OTHER_WT" rev-parse HEAD)" = "$A_SHA" ] || exit 23
  [ -z "$(git -C "$PA_OTHER_WT" status --porcelain)" ] || exit 24
) && ok || bad "Path A git checkout failed to abort cleanly against concurrent target worktree checkout"

CODEX_MERGE_DOC="$HERE/../commands/cr-loop-merge.md"
T3_MERGE_DOC="$HERE/../../t3-cr-loop/skills/t3-cr-loop-merge/SKILL.md"
(
  grep -q 'cr-loop-merge.lock' "$CODEX_MERGE_DOC" &&
  grep -q 'cr-loop-merge.lock' "$T3_MERGE_DOC" &&
  grep -q 'git checkout "${CR_MERGE_TARGET:-main}"' "$CODEX_MERGE_DOC" &&
  grep -q 'git checkout "$CR_MERGE_TARGET"' "$T3_MERGE_DOC" &&
  ! grep -q 'git checkout main && git merge' "$CODEX_MERGE_DOC" &&
  ! grep -q 'git checkout main && git merge' "$T3_MERGE_DOC"
) && ok || bad "merge protocol docs missing repo-common lock, Path A checkout claim, or safe defer guidance"

# 10. SIGTERM on submodule git rev-parse HEAD fails closed (NEVER misclassified as UNBORN)!
SIG_GIT_BIN="$TMP/codex-git-sigterm"
mkdir -p "$SIG_GIT_BIN"
REAL_GIT=$(command -v git)
cat > "$SIG_GIT_BIN/git" <<EOF
#!/usr/bin/env bash
is_sub=0; is_rp=0; is_head=0
for arg in "\$@"; do
  case "\$arg" in
    *vendor/sub*) is_sub=1 ;;
    rev-parse) is_rp=1 ;;
    HEAD) is_head=1 ;;
  esac
done
if [ "\$is_sub" = 1 ] && [ "\$is_rp" = 1 ] && [ "\$is_head" = 1 ]; then
  kill -TERM \$\$
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SIG_GIT_BIN/git"
(
  cd "$SUB_HOST" || exit 2
  PATH="$SIG_GIT_BIN:$PATH" FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null 2>&1
)
rc_sig=$?
[ "$rc_sig" -ne 0 ] && ok || bad "cr-review.sh start exited 0 despite SIGTERM on submodule rev-parse HEAD!"

# 11. Unborn nested gitdir produces ZERO 'fatal: Needed a single revision' stderr leakage in tree_fp_v2!
UNB_HOST="$TMP/unborn-nested-host"
mkdir -p "$UNB_HOST/nested-unborn"
(
  cd "$UNB_HOST" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'h1\n' > h.txt && git add h.txt && git commit -qm h1
  git switch -qc feat/unb
  printf 'h2\n' >> h.txt && git commit -qam h2
  (cd nested-unborn && git init -q -b main .)
  printf 'unb-1\n' > nested-unborn/x.txt
  err_unb=$(FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main 2>&1 >/dev/null)
  rc_u=$?
  bash "$CR" wait --timeout 30 >/dev/null 2>&1
  bash "$CR" cancel >/dev/null 2>&1 || true
  [ "$rc_u" -eq 0 ] && ! printf '%s' "$err_unb" | grep -q "fatal: Needed a single revision"
) && ok || bad "unborn nested gitdir leaked stderr or failed start in cr-review.sh"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
