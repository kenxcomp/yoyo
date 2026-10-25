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
bash "$CR" mark-converged >/dev/null
expect "converged resets counters" "full" "$(bash "$CR" next --clean-streak 1 | kv MODE)"

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

# --- cancel stops the whole round process group (no orphans)
FAKE_SLEEP=30 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
sleep 1
bash "$CR" cancel >/dev/null
sleep 1
expect "cancel exit code" "130" "$(bash "$CR" status | kv EXIT)"
if ps -axo command | grep -v grep | grep -q 'sleep 30$'; then bad "cancel left an orphaned reviewer child"; else ok; fi

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

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
