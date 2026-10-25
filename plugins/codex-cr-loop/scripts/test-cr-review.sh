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

fixture() { printf '%b' "$2" > "$TMP/$1.md"; printf '%s\n' "$TMP/$1.md"; }

F_CLEAN=$(fixture clean '# Codex Review\n\nAll fine. did not find any definite correctness bugs.\n')
F_HEAD_ONLY=$(fixture headonly '# Codex Review\n\nI could not finish the review.\n')
F_DIRTY=$(fixture dirty '# Codex Review\n\nx\n\nReview comment:\n\n- [P1] Class A — a.txt:1\n  Pattern: p\n  Instances: a.txt:1, a.txt:2\n  Fix: f\n  Prevent: t\n\n- [P3] Nit — a.txt:3\n  Pattern: n\n\nOut of scope (pre-existing, not counted):\n  a.txt:9 — old\n')
F_P3=$(fixture p3 '# Codex Review\n\nx\n\nReview comment:\n\n- [P3] Another nit — a.txt:4\n  Pattern: n\n')
F_MIXED=$(fixture mixed '# Codex Review\n\nx\n\nReview comment:\n\n- [P3] ok nit — a.txt:1\n\n* [P1] star bullet — a.txt:2\n')
F_INDENT=$(fixture indent '# Codex Review\n\nx\n\n  - [P0] indented — a.txt:1\n')
F_REOPEN=$(fixture reopen '# Codex Review\n\nx\n\nReview comment:\n\n- [P2] [C1] Class A — a.txt:2\n  Still wrong: one left\n')

# --- C2: state dir resolves identically from root, a subdirectory and a linked worktree
P_ROOT=$(bash "$CR" paths | kv STATE_DIR)
P_SUB=$(cd sub/dir && bash "$CR" paths | kv STATE_DIR)
expect "paths from subdir" "$P_ROOT" "$P_SUB"
git worktree add -q "$TMP/wt" -b feat/other >/dev/null 2>&1
P_WT=$(cd "$TMP/wt" && bash "$CR" paths | kv STATE_DIR)
expect "linked worktree common dir" "$(dirname "$P_ROOT")/feat__other" "$P_WT"

# --- C1: classification table
expect "clean"           "clean"   "$(run_round "$F_CLEAN" full | kv VERDICT)"
out=$(run_round "$F_HEAD_ONLY" full); rc=$?
expect "heading-only is error (exit)" "5" "$rc"
expect "heading-only is error" "error" "$(printf '%s\n' "$out" | kv VERDICT)"
out=$(run_round "$F_MIXED" full); rc=$?
expect "mixed valid P3 + malformed P1 is error" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
out=$(run_round "$F_INDENT" full); rc=$?
expect "indented finding is error" "5:error" "$rc:$(printf '%s\n' "$out" | kv VERDICT)"
out=$(FAKE_RC=1 run_round "$F_CLEAN" full); rc=$?
expect "non-zero codex exit is error" "5" "$rc"
out=$(run_round "$F_DIRTY" full)
expect "dirty verdict" "dirty" "$(printf '%s\n' "$out" | kv VERDICT)"
expect "dirty counts" "1:1" "$(printf '%s\n' "$out" | kv P1):$(printf '%s\n' "$out" | kv P3)"
expect "class ids" "C1,C2" "$(printf '%s\n' "$out" | kv NEW_CLASSES)"
LEDGER=$(bash "$CR" paths | kv LEDGER)
grep -q 'a.txt:9 — old' "$LEDGER" && ok || bad "out-of-scope section recorded in ledger"
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
out=$(run_round "$F_REOPEN" step-back)
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

# --- cancel stops the whole round process group (no orphans)
FAKE_SLEEP=30 FAKE_OUT="$F_CLEAN" bash "$CR" start --mode full --base main >/dev/null
sleep 1
bash "$CR" cancel >/dev/null
sleep 1
expect "cancel exit code" "130" "$(bash "$CR" status | kv EXIT)"
if ps -axo command | grep -v grep | grep -q 'sleep 30$'; then bad "cancel left an orphaned reviewer child"; else ok; fi

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
