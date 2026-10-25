#!/usr/bin/env bash
# cr-review.sh — reviewer runner + findings ledger for the codex-cr-loop plugin.
#
# The three /cr-loop* commands drive every review round through this script so
# the review protocol (modes, class-format prompt, ledger, round cap) lives in
# one place. See ../references/review-protocol.md for the procedure that calls it.
#
# Subcommands (run inside the feature branch's worktree):
#   init                         create/load per-branch state, print knobs + state
#   next [--clean-streak N]      print the mode the next round must use
#   start --mode M --base REF [--since SHA]
#                                launch one detached `codex exec` review round
#   status [ROUND_DIR]           running / done for a round (default: current)
#   wait [ROUND_DIR] [--timeout S]
#                                block up to S seconds (default 540) for a round
#   finish [ROUND_DIR]           head-drift check, classify, append ledger, update counters
#   note TEXT...                 append an author note (status, deferral, prevention) to the ledger
#   add SEVERITY TITLE [DETAIL]  register an external finding (PR bot, human) as a new class id
#   mark-converged               record convergence; reset round-cap counters
#   cancel [ROUND_DIR]           stop a running round (only its own PIDs)
#   reset                        archive this branch's state + ledger (fresh start)
#   paths                        print STATE_DIR / LEDGER / STATE
#   tree-clean                   exit 0 iff the working tree is clean, ignoring only untracked
#                                repo-root .cr-loop-handoff-round-<N>.md files (preflight + completion)
#
# State lives outside the working tree:
#   $(git rev-parse --git-common-dir)/cr-loop/<branch-key>/{state,ledger.md,rounds/}
# so it is shared by every worktree of the repo and survives across invocations.
#
# Compatible with macOS bash 3.2. No heredoc is nested inside $(...).

set -u

SELF_VERSION="1.7.0"
CLEAN_SENTENCE="did not find any definite correctness bugs"

die() { printf 'cr-review: %s\n' "$*" >&2; exit 2; }

self_path() {
  case "$0" in
    /*) printf '%s\n' "$0" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$(basename "$0")" ;;
  esac
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# ---------------------------------------------------------------- state ----

resolve_paths() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
  BRANCH=$(git branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] || die "detached HEAD — check out a branch first"
  ROOT=$(git rev-parse --show-toplevel)
  # --git-common-dir is relative to the *current directory* (not the top level)
  # when git prints it relative; ask for an absolute path (git >= 2.31) and fall
  # back to resolving against $PWD for older git.
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  case "$common" in
    /*) ;;
    *) common=$(git rev-parse --git-common-dir); case "$common" in /*) ;; *) common="$(pwd -P)/$common" ;; esac ;;
  esac
  common=$(cd "$common" && pwd -P) || die "cannot resolve git common dir"
  KEY=$(printf '%s' "$BRANCH" | sed 's#/#__#g; s#[^A-Za-z0-9._-]#-#g')
  STATE_DIR="$common/cr-loop/$KEY"
  STATE="$STATE_DIR/state"
  LEDGER="$STATE_DIR/ledger.md"
}

sget() {
  [ -f "$STATE" ] || return 0
  sed -n "s/^$1=//p" "$STATE" | tail -n 1
}

sset() {
  tmp="$STATE.tmp.$$"
  { grep -v "^$1=" "$STATE" 2>/dev/null; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$STATE"
}

snum() { v=$(sget "$1"); is_uint "$v" && printf '%s\n' "$v" || printf '0\n'; }

ensure_state() {
  mkdir -p "$STATE_DIR/rounds" || die "cannot create $STATE_DIR"
  if [ ! -f "$STATE" ]; then
    {
      printf 'branch=%s\n' "$BRANCH"
      printf 'created_at=%s\n' "$(now_utc)"
      printf 'rounds_started=0\nrounds_total=0\ndirty_since_step_back=0\nstep_backs_done=0\nnext_class_id=1\n'
    } > "$STATE"
  fi
  stored=$(sget branch)
  [ "$stored" = "$BRANCH" ] || die "state dir $STATE_DIR belongs to branch '$stored', not '$BRANCH' (key collision) — run 'reset' or rename the branch"
  if [ ! -f "$LEDGER" ]; then
    {
      printf '# cr-loop findings ledger — %s\n\n' "$BRANCH"
      printf 'Append-only. Class ids (C1, C2, ...) are stable for this branch. Reviewers must not\n'
      printf 're-report a class listed here; a reopened class cites its id ("[C3] ...").\n'
      printf 'Author notes mark classes fixed / deferred / accepted / wontfix / codified.\n'
    } > "$LEDGER"
  fi
}

# ---------------------------------------------------------------- knobs ----

resolve_knobs() {
  WARNINGS=""
  ROUND_CAP="${CR_LOOP_ROUND_CAP:-3}"
  is_uint "$ROUND_CAP" || die "CR_LOOP_ROUND_CAP must be a non-negative integer (got '$ROUND_CAP')"
  if [ -n "${CR_LOOP_MAX_STEP_BACKS:-}" ]; then
    MAX_STEP_BACKS="$CR_LOOP_MAX_STEP_BACKS"
  elif [ "${CR_LOOP_AUTO_WIDEN:-}" = "0" ]; then
    MAX_STEP_BACKS=0
    WARNINGS="$WARNINGS CR_LOOP_AUTO_WIDEN=0 is deprecated (v1.7.0) -> mapped to CR_LOOP_MAX_STEP_BACKS=0;"
  elif [ -n "${CR_LOOP_MAX_WIDENING_SWEEPS:-}" ]; then
    MAX_STEP_BACKS="$CR_LOOP_MAX_WIDENING_SWEEPS"
    WARNINGS="$WARNINGS CR_LOOP_MAX_WIDENING_SWEEPS is deprecated (v1.7.0) -> mapped to CR_LOOP_MAX_STEP_BACKS=$MAX_STEP_BACKS;"
  else
    MAX_STEP_BACKS=1
  fi
  is_uint "$MAX_STEP_BACKS" || die "CR_LOOP_MAX_STEP_BACKS must be a non-negative integer (got '$MAX_STEP_BACKS')"
  [ -n "${CR_LOOP_WIDEN_AFTER:-}" ] && WARNINGS="$WARNINGS CR_LOOP_WIDEN_AFTER is removed (v1.7.0) and ignored — the step-back trigger is CR_LOOP_ROUND_CAP;"
  SKIP_P3="${CR_LOOP_SKIP_P3:-1}"
  EFFORT="${CR_LOOP_REVIEW_EFFORT:-high}"
  case "$EFFORT" in minimal|low|medium|high|xhigh) ;; *) die "CR_LOOP_REVIEW_EFFORT must be minimal|low|medium|high|xhigh (got '$EFFORT')" ;; esac
  MODEL="${CR_LOOP_REVIEW_MODEL:-}"
}

# --------------------------------------------------------------- rounds ----

round_dir_arg() {
  d="${1:-}"
  [ -n "$d" ] || d=$(sget current_round_dir)
  [ -n "$d" ] || die "no round given and no current round recorded"
  [ -d "$d" ] || die "round dir not found: $d"
  printf '%s\n' "$d"
}

mget() { sed -n "s/^$2=//p" "$1/meta" | tail -n 1; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

round_state() {
  # prints running | done | dead
  if [ -f "$1/exit" ]; then printf 'done\n'; return; fi
  if pid_alive "$(cat "$1/pid" 2>/dev/null)"; then printf 'running\n'; else printf 'dead\n'; fi
}

file_size() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else printf '0\n'; fi; }

file_age() {
  m=$(stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '')
  [ -n "$m" ] && printf '%s\n' $(( $(date +%s) - m )) || printf '?\n'
}

print_status() {
  d="$1"; st=$(round_state "$d")
  started=$(mget "$d" started_epoch)
  elapsed="?"; is_uint "$started" && elapsed=$(( $(date +%s) - started ))
  printf 'STATE=%s\nROUND_DIR=%s\nMODE=%s\nPID=%s\nEXIT=%s\nELAPSED_S=%s\nLOG_BYTES=%s\nLOG_AGE_S=%s\n' \
    "$st" "$d" "$(mget "$d" mode)" "$(cat "$d/pid" 2>/dev/null)" "$(cat "$d/exit" 2>/dev/null)" \
    "$elapsed" "$(file_size "$d/log")" "$(file_age "$d/log")"
}

write_prompt() {
  d="$1"; mode="$2"; base_ref="$3"; base_sha="$4"; head="$5"; since="$6"; n="$7"
  dsb=$(snum dirty_since_step_back); sbd=$(snum step_backs_done)
  p="$d/prompt.md"
  {
    printf 'You are the code reviewer in an automated review loop (codex-cr-loop %s).\n' "$SELF_VERSION"
    printf 'Repository root: %s\nBranch: %s\nReview base: %s (%s)\nReviewed HEAD: %s\nRound: %s   Mode: %s\n\n' \
      "$ROOT" "$BRANCH" "$base_ref" "$base_sha" "$head" "$n" "$mode"
    printf 'SCOPE\n'
    case "$mode" in
      incremental)
        printf -- '- Review ONLY the changes since the last reviewed head: `git diff %s..%s`.\n' "$since" "$head"
        printf -- '  These are the fixes for the ledger classes. Read surrounding code for context only; do not rescan the rest of the branch.\n'
        printf -- '- Report (a) defects these changes introduce and (b) ledger classes whose fix here is incomplete or regressed, with every remaining instance.\n'
        ;;
      step-back)
        printf -- '- This branch has had %s dirty review rounds since the last step-back (%s step-back(s) so far). Point fixes are not converging.\n' "$dsb" "$sbd"
        printf -- '- Review the whole branch diff `git diff %s...%s` together with the FULL ledger.\n' "$base_sha" "$head"
        printf -- '- Main job (not line-level review): (1) identify the RECURRING bug classes behind the ledger entries — the same root pattern across rounds, even under different titles;\n'
        printf -- '  (2) for each, judge whether the current approach structurally invites it (e.g. duplicated predicates for display vs action, several owners of one piece of state,\n'
        printf -- '  per-event full recomputation, async work without an owned lifetime/cancellation, ad-hoc or imprecise equality);\n'
        printf -- '  (3) propose the approach change (single source of truth, ownership, invariant, API shape) that eliminates the whole class, plus the prevention artifact.\n'
        printf -- '- Write that under "## Step-back assessment", one bullet per recurring class:\n'
        printf -- '  "- [C2, C5] <class> — Invites it because: ... — Approach change: ... — Prevent: ..."\n'
        printf -- '  Then list instances that are still present as normal findings under "Review comment:".\n'
        ;;
      *)
        printf -- '- Review the whole branch diff `git diff %s...%s` (start with --stat, then read the hunks and the surrounding code you need).\n' "$base_sha" "$head"
        printf -- '- If the ledger already lists classes, this is a confirmation pass after earlier fixes: also look for cross-cutting problems the fixes introduced together.\n'
        ;;
    esac
    printf '\nPROJECT GUIDANCE\n'
    printf -- '- Read REVIEW.md (repository root and any next to the changed files) if present: it lists codified bug classes. A violation is a finding; cite the section.\n'
    printf -- '- Follow AGENTS.md / CLAUDE.md (root and nested next to changed files) if present.\n'
    printf '\nLEDGER (no repeats)\n'
    printf -- '- Read the findings ledger first: %s\n' "$LEDGER"
    printf -- '- Never report a ledger class again. Exception: its fix is incomplete or regressed in the code under review — then begin the title with its id, e.g. "[C3] <title>", and add a "Still wrong:" line.\n'
    printf -- '- Classes the ledger notes mark deferred / accepted / wontfix must not be reported at all, not even as reopened.\n'
    printf '\nWHAT TO REPORT\n'
    printf -- '- Only definite, actionable correctness, data-safety, concurrency or performance bugs introduced (or left incomplete) by this change. No style nits, no speculative hardening.\n'
    printf -- '- Report bug CLASSES, not single lines. One bullet per class: the root pattern and why it is wrong; EVERY instance in the reviewed scope (search for the pattern — do not stop at the first hit);\n'
    printf -- '  the systematic fix that removes all instances in one pass; how to prevent recurrence at the source (lint rule, source-guard or regression test, REVIEW.md entry, AGENTS.md/CLAUDE.md rule).\n'
    printf -- '- Severity: P0 data loss / security / crash on a common path; P1 wrong behaviour on a realistic path; P2 edge-case bug or measurable performance regression; P3 minor / defensive.\n'
    printf -- '- Pre-existing issues outside this change go under "Out of scope" without a severity tag; they do not count.\n'
    printf '\nOUTPUT FORMAT (exact; the loop parses it)\n'
    printf '# Codex Review\n\n<one-paragraph summary>\n\n'
    [ "$mode" = "step-back" ] && printf '## Step-back assessment\n\n- [C<ids>] <class> — Invites it because: ... — Approach change: ... — Prevent: ...\n\n'
    printf 'Review comment:\n\n'
    printf -- '- [P1] <class title> — <primary file>:<line>\n  Pattern: <root pattern and why it is wrong>\n  Instances: <file:line>, <file:line>, ...\n  Fix: <systematic fix>\n  Prevent: <lint rule / source-guard test / REVIEW.md entry>\n\n'
    printf -- '- [P2] [C3] <title of the reopened ledger class> — <file>:<line>\n  Still wrong: <what the fix missed>\n  Instances: ...\n  Fix: ...\n  Prevent: ...\n\n'
    printf 'Out of scope (pre-existing, not counted):\n  <file:line> — <one line>   (omit when empty; never start these lines with "- [P")\n\n'
    printf 'Every finding bullet starts with "- [P0]".."- [P3]" at column 0; detail lines are indented two spaces.\n'
    printf 'If there are no findings, write the summary followed by the exact sentence: %s.\n' "$CLEAN_SENTENCE"
    printf 'Do not modify any files.\n'
  } > "$p"
}

cmd_init() {
  resolve_paths; resolve_knobs; ensure_state
  printf 'CR_REVIEW_VERSION=%s\nBRANCH=%s\nSTATE_DIR=%s\nLEDGER=%s\n' "$SELF_VERSION" "$BRANCH" "$STATE_DIR" "$LEDGER"
  printf 'ROUND_CAP=%s\nMAX_STEP_BACKS=%s\nSKIP_P3=%s\nREVIEW_EFFORT=%s\nREVIEW_MODEL=%s\n' \
    "$ROUND_CAP" "$MAX_STEP_BACKS" "$SKIP_P3" "$EFFORT" "${MODEL:-<codex default>}"
  printf 'ROUNDS_TOTAL=%s\nDIRTY_SINCE_STEP_BACK=%s\nSTEP_BACKS_DONE=%s\nLAST_REVIEWED_HEAD=%s\nCLASSES=%s\n' \
    "$(snum rounds_total)" "$(snum dirty_since_step_back)" "$(snum step_backs_done)" \
    "$(sget last_reviewed_head)" "$(( $(snum next_class_id) - 1 ))"
  cur=$(sget current_round_dir)
  if [ -n "$cur" ] && [ -d "$cur" ]; then printf 'CURRENT_ROUND=%s (%s)\n' "$cur" "$(round_state "$cur")"; fi
  command -v codex >/dev/null 2>&1 && printf 'CODEX=%s\n' "$(command -v codex)" || printf 'CODEX=missing\n'
  [ -n "$WARNINGS" ] && printf 'WARNINGS=%s\n' "$WARNINGS"
  return 0
}

cmd_next() {
  resolve_paths; resolve_knobs; ensure_state
  cs=0
  while [ $# -gt 0 ]; do
    case "$1" in --clean-streak) cs="${2:-0}"; shift; [ $# -gt 0 ] && shift ;; *) die "next: unknown arg $1" ;; esac
  done
  is_uint "$cs" || die "--clean-streak must be an integer"
  dsb=$(snum dirty_since_step_back); sbd=$(snum step_backs_done)
  last=$(sget last_reviewed_head); head=$(git rev-parse HEAD)
  if [ "$ROUND_CAP" -gt 0 ] && [ "$dsb" -ge "$ROUND_CAP" ]; then
    if [ "$sbd" -lt "$MAX_STEP_BACKS" ]; then
      printf 'MODE=step-back\nREASON=%s dirty rounds since last step-back (cap %s)\n' "$dsb" "$ROUND_CAP"
    else
      printf 'MODE=stop\nREASON=step-back-exhausted (%s/%s step-backs used, %s dirty rounds since)\n' "$sbd" "$MAX_STEP_BACKS" "$dsb"
    fi
  elif [ "$cs" -ge 1 ]; then
    printf 'MODE=full\nREASON=confirmation round on the same HEAD (whole diff + ledger)\n'
  elif [ -n "$last" ] && [ "$last" != "$head" ] && git merge-base --is-ancestor "$last" "$head" 2>/dev/null; then
    printf 'MODE=incremental\nSINCE=%s\nREASON=changes since last reviewed head\n' "$last"
  else
    printf 'MODE=full\nREASON=%s\n' "$( [ -z "$last" ] && echo 'first review of this branch' || echo 'last reviewed head is not an ancestor of HEAD (or equals it)')"
  fi
}

launch_detached() {
  # Detach from the caller's process group so a tool timeout that kills the
  # caller does not kill the reviewer. macOS has no setsid(1); use perl's POSIX::setsid.
  self="$1"; d="$2"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash "$self" _run "$d" </dev/null >/dev/null 2>&1 &
  elif command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' bash "$self" _run "$d" </dev/null >/dev/null 2>&1 &
  else
    nohup bash "$self" _run "$d" </dev/null >/dev/null 2>&1 &
  fi
  lpid=$!
  disown "$lpid" 2>/dev/null || true
  printf '%s\n' "$lpid" > "$d/pid"
}

cmd_start() {
  resolve_paths; resolve_knobs; ensure_state
  mode=""; base=""; since=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) mode="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --base) base="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --since) since="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) die "start: unknown arg $1" ;;
    esac
  done
  case "$mode" in full|incremental|step-back) ;; *) die "start: --mode must be full|incremental|step-back" ;; esac
  [ -n "$base" ] || die "start: --base is required"
  command -v codex >/dev/null 2>&1 || die "codex CLI not found on PATH — install it (e.g. 'npm i -g @openai/codex' or 'brew install codex') and run 'codex login'"
  cur=$(sget current_round_dir)
  if [ -n "$cur" ] && [ -d "$cur" ] && [ "$(round_state "$cur")" = "running" ]; then
    die "a review round is already running for this branch: $cur (use 'wait', 'finish' or 'cancel')"
  fi
  base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "start: base '$base' does not resolve"
  head=$(git rev-parse HEAD)
  if [ "$mode" = "incremental" ]; then
    [ -n "$since" ] || die "start: incremental mode needs --since <last reviewed sha>"
    since=$(git rev-parse --verify --quiet "$since^{commit}") || die "start: --since does not resolve"
    git merge-base --is-ancestor "$since" "$head" || die "start: --since $since is not an ancestor of HEAD — use --mode full"
    [ "$since" != "$head" ] || die "start: nothing changed since $since — use --mode full for a confirmation round"
  fi
  n=$(( $(snum rounds_started) + 1 ))
  d="$STATE_DIR/rounds/$(printf '%03d' "$n")-$mode"
  mkdir -p "$d" || die "cannot create $d"
  {
    printf 'mode=%s\nbase_ref=%s\nbase_sha=%s\nsince=%s\nreviewed_head=%s\nround=%s\n' "$mode" "$base" "$base_sha" "$since" "$head" "$n"
    printf 'effort=%s\nmodel=%s\nroot=%s\nstarted_at=%s\nstarted_epoch=%s\n' "$EFFORT" "$MODEL" "$ROOT" "$(now_utc)" "$(date +%s)"
  } > "$d/meta"
  write_prompt "$d" "$mode" "$base" "$base_sha" "$head" "$since" "$n"
  sset rounds_started "$n"
  sset current_round_dir "$d"
  launch_detached "$(self_path)" "$d"
  printf 'ROUND=%s\nMODE=%s\nROUND_DIR=%s\nPID=%s\nREVIEWED_HEAD=%s\nBASE_SHA=%s\n' "$n" "$mode" "$d" "$(cat "$d/pid")" "$head" "$base_sha"
  [ -n "$since" ] && printf 'SINCE=%s\n' "$since"
  printf 'RESULT=%s/last.md\n' "$d"
}

cmd__run() {
  d="$1"
  printf '%s\n' "$$" > "$d/pid"
  root=$(mget "$d" root); effort=$(mget "$d" effort); model=$(mget "$d" model)
  prompt=$(cat "$d/prompt.md")
  if [ -n "$model" ]; then
    codex exec --sandbox read-only -C "$root" -m "$model" -c "model_reasoning_effort=$effort" \
      --output-last-message "$d/last.md" "$prompt" </dev/null >"$d/log" 2>&1 &
  else
    codex exec --sandbox read-only -C "$root" -c "model_reasoning_effort=$effort" \
      --output-last-message "$d/last.md" "$prompt" </dev/null >"$d/log" 2>&1 &
  fi
  cpid=$!
  printf '%s\n' "$cpid" > "$d/codex.pid"
  wait "$cpid"
  rc=$?
  printf 'finished_at=%s\n' "$(now_utc)" >> "$d/meta"
  printf '%s\n' "$rc" > "$d/exit"
}

cmd_status() { resolve_paths; d=$(round_dir_arg "${1:-}") || exit 2; print_status "$d"; }

cmd_wait() {
  resolve_paths
  d=""; t=540
  while [ $# -gt 0 ]; do
    case "$1" in --timeout) t="${2:-540}"; shift; [ $# -gt 0 ] && shift ;; *) d="$1"; shift ;; esac
  done
  is_uint "$t" || die "--timeout must be seconds"
  d=$(round_dir_arg "$d") || exit 2
  end=$(( $(date +%s) + t ))
  while [ "$(round_state "$d")" = "running" ] && [ "$(date +%s)" -lt "$end" ]; do sleep 10; done
  print_status "$d"
}

cmd_cancel() {
  resolve_paths; d=$(round_dir_arg "${1:-}") || exit 2
  [ "$(round_state "$d")" = "running" ] || { print_status "$d"; return 0; }
  rp=$(cat "$d/pid" 2>/dev/null)
  pg=$(ps -o pgid= -p "$rp" 2>/dev/null | tr -d ' ')
  if [ -n "$rp" ] && [ "$pg" = "$rp" ]; then
    # The runner leads its own process group (setsid at launch): stop the whole
    # group so codex's own children are not orphaned. Only this round's group.
    kill -TERM -- "-$rp" 2>/dev/null
  else
    for f in codex.pid pid; do
      p=$(cat "$d/$f" 2>/dev/null)
      pid_alive "$p" && kill -TERM "$p" 2>/dev/null
    done
  fi
  sleep 1
  [ -f "$d/exit" ] || printf '130\n' > "$d/exit"
  printf 'cancelled_at=%s\n' "$(now_utc)" >> "$d/meta"
  print_status "$d"
}

# Parse last.md into a ledger fragment, assigning class ids.
# stdout: NEW=<ids> / REOPENED=<ids> / NEXT=<n>
parse_findings() {
  awk -v nid="$2" -v frag="$3" '
    BEGIN { new=""; reo=""; inblock=0; insec="" }
    /^- \[P[0-3]\]/ {
      inblock=1; insec=""
      sev=substr($0, 4, 2)
      rest=substr($0, 7)
      sub(/^[ \t]+/, "", rest)
      if (match(rest, /^\[C[0-9]+\]/)) {
        id=substr(rest, RSTART+1, RLENGTH-2)
        rest=substr(rest, RLENGTH+1); sub(/^[ \t]+/, "", rest)
        print "### " id " (reopened) [" sev "] " rest > frag
        reo = reo (reo=="" ? "" : ",") id
      } else {
        id="C" nid; nid++
        print "### " id " [" sev "] " rest > frag
        new = new (new=="" ? "" : ",") id
      }
      next
    }
    /^## Step-back assessment/ { inblock=0; insec="sb"; print "#### Step-back assessment" > frag; next }
    /^Out of scope/ { inblock=0; insec="oos"; print "#### Out of scope (pre-existing, not counted)" > frag; next }
    /^Review comment:/ { inblock=0; insec=""; next }
    /^#/ { inblock=0; insec=""; next }
    {
      if (inblock) {
        if ($0 ~ /^[ \t]/ || $0 == "") { if ($0 != "") print $0 > frag; next }
        inblock=0
      }
      if (insec != "" && $0 != "") print $0 > frag
    }
    END { print "NEW=" new; print "REOPENED=" reo; print "NEXT=" nid }
  ' "$1"
}

cmd_finish() {
  resolve_paths; resolve_knobs; ensure_state
  d=$(round_dir_arg "${1:-}") || exit 2
  st=$(round_state "$d")
  [ "$st" = "running" ] && { printf 'VERDICT=running\n'; print_status "$d"; exit 4; }
  [ -f "$d/finished" ] && die "round already finished: $d (see $d/verdict)"
  mode=$(mget "$d" mode); reviewed=$(mget "$d" reviewed_head); n=$(mget "$d" round)
  head=$(git rev-parse HEAD)
  if [ "$head" != "$reviewed" ]; then
    printf 'VERDICT=head-drift\nREVIEWED_HEAD=%s\nHEAD=%s\n' "$reviewed" "$head"
    exit 3
  fi
  rc=$(cat "$d/exit" 2>/dev/null || printf 'dead')
  res="$d/last.md"
  if [ "$rc" != "0" ] || [ ! -s "$res" ]; then
    printf 'VERDICT=error\nEXIT=%s\nRESULT=%s\nLOG=%s\n' "$rc" "$res" "$d/log"
    tail -n 20 "$d/log" 2>/dev/null | sed 's/^/LOG| /'
    exit 5
  fi
  # Validate the whole response before classifying (never let a malformed or
  # unfinished review reach the convergence path):
  #  - every line that looks like a severity-tagged finding must be a column-0 "- [Pn]" bullet;
  #  - a response without findings is clean only with the explicit clean sentence.
  bad=$(grep -nE '^[[:space:]]*([-*+]|[0-9]+[.)])?[[:space:]]*\[P[0-3]\]' "$res" | grep -vE '^[0-9]+:- \[P[0-3]\] ')
  if [ -n "$bad" ]; then
    printf 'VERDICT=error\nREASON=malformed finding line(s) — every finding must start with "- [Pn] " at column 0; read %s manually\n' "$res"
    printf '%s\n' "$bad" | head -n 5 | sed 's/^/BAD| /'
    exit 5
  fi
  c0=$(grep -cE '^- \[P0\] ' "$res"); c1=$(grep -cE '^- \[P1\] ' "$res")
  c2=$(grep -cE '^- \[P2\] ' "$res"); c3=$(grep -cE '^- \[P3\] ' "$res")
  total=$(( c0 + c1 + c2 + c3 ))
  if [ "$total" -eq 0 ]; then
    if ! grep -qiF "$CLEAN_SENTENCE" "$res"; then
      printf 'VERDICT=error\nREASON=no findings and no explicit clean sentence ("%s") — incomplete or unparseable review, read %s manually\n' "$CLEAN_SENTENCE" "$res"
      exit 5
    fi
    verdict=clean
  elif [ $(( c0 + c1 + c2 )) -eq 0 ] && [ "$SKIP_P3" = "1" ]; then
    verdict=p3-only
  else
    verdict=dirty
  fi
  frag="$d/ledger-fragment.md"; : > "$frag"
  parsed=$(parse_findings "$res" "$(snum next_class_id)" "$frag")
  new=$(printf '%s\n' "$parsed" | sed -n 's/^NEW=//p')
  reo=$(printf '%s\n' "$parsed" | sed -n 's/^REOPENED=//p')
  nxt=$(printf '%s\n' "$parsed" | sed -n 's/^NEXT=//p')
  {
    printf '\n## Round %s — %s — %s — %s (P0×%s P1×%s P2×%s P3×%s) — %s\n' \
      "$n" "$mode" "$(git rev-parse --short "$reviewed")" "$verdict" "$c0" "$c1" "$c2" "$c3" "$(now_utc)"
    [ -s "$frag" ] && cat "$frag"
  } >> "$LEDGER"
  is_uint "$nxt" && sset next_class_id "$nxt"
  sset rounds_total $(( $(snum rounds_total) + 1 ))
  sset last_reviewed_head "$reviewed"
  sset last_reviewed_mode "$mode"
  if [ "$mode" = "step-back" ]; then
    sset step_backs_done $(( $(snum step_backs_done) + 1 ))
    sset dirty_since_step_back 0
  elif [ "$verdict" = "dirty" ]; then
    sset dirty_since_step_back $(( $(snum dirty_since_step_back) + 1 ))
  fi
  sset current_round_dir ""
  # Recurring = class ids with entries in >= 2 rounds.
  recurring=$(grep -oE '^### C[0-9]+' "$LEDGER" | sort | uniq -c | awk '$1 >= 2 { print $3 }' | paste -sd, -)
  {
    printf 'VERDICT=%s\nMODE=%s\nROUND=%s\nP0=%s\nP1=%s\nP2=%s\nP3=%s\n' "$verdict" "$mode" "$n" "$c0" "$c1" "$c2" "$c3"
    printf 'NEW_CLASSES=%s\nREOPENED=%s\nRECURRING=%s\n' "$new" "$reo" "$recurring"
    printf 'DIRTY_SINCE_STEP_BACK=%s/%s\nSTEP_BACKS_DONE=%s/%s\n' "$(snum dirty_since_step_back)" "$ROUND_CAP" "$(snum step_backs_done)" "$MAX_STEP_BACKS"
    printf 'REVIEWED_HEAD=%s\nRESULT=%s\nLEDGER=%s\n' "$reviewed" "$res" "$LEDGER"
  } | tee "$d/verdict"
  : > "$d/finished"
}

cmd_note() {
  resolve_paths; ensure_state
  [ $# -gt 0 ] || die "note: text required (e.g. 'C3 fixed — prevention: REVIEW.md#stale-predicate')"
  printf -- '- note %s @%s: %s\n' "$(now_utc)" "$(git rev-parse --short HEAD)" "$*" >> "$LEDGER"
  printf 'NOTED\n'
}

cmd_add() {
  resolve_paths; ensure_state
  sev="${1:-}"; title="${2:-}"; detail="${3:-}"
  case "$sev" in P0|P1|P2|P3) ;; *) die "add: severity must be P0..P3" ;; esac
  [ -n "$title" ] || die "add: title required ('<class title> — <file>:<line>')"
  id="C$(snum next_class_id)"
  {
    printf '\n## External finding — %s @%s\n### %s [%s] %s\n' "$(now_utc)" "$(git rev-parse --short HEAD)" "$id" "$sev" "$title"
    [ -n "$detail" ] && printf '  %s\n' "$detail"
  } >> "$LEDGER"
  sset next_class_id $(( $(snum next_class_id) + 1 ))
  printf 'ID=%s\n' "$id"
}

cmd_mark_converged() {
  resolve_paths; ensure_state
  printf '\n## Converged at %s — %s (rounds so far: %s, step-backs: %s)\n' \
    "$(git rev-parse --short HEAD)" "$(now_utc)" "$(snum rounds_total)" "$(snum step_backs_done)" >> "$LEDGER"
  sset dirty_since_step_back 0
  sset step_backs_done 0
  printf 'CONVERGED=%s\n' "$(git rev-parse HEAD)"
}

cmd_reset() {
  resolve_paths
  [ -d "$STATE_DIR" ] || { printf 'NOTHING_TO_RESET\n'; return 0; }
  cur=$(sget current_round_dir)
  if [ -n "$cur" ] && [ -d "$cur" ] && [ "$(round_state "$cur")" = "running" ]; then die "a round is running — cancel it first"; fi
  dest="$STATE_DIR.archived-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$STATE_DIR" "$dest" || die "cannot archive $STATE_DIR"
  printf 'ARCHIVED=%s\n' "$dest"
}

# Single source of truth for "working tree is clean" (preflight AND completion):
# everything must be clean except untracked repo-root .cr-loop-handoff-round-<N>.md files.
cmd_tree_clean() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
  all=$(git status --porcelain --untracked-files=all)
  rest=$(printf '%s\n' "$all" | grep -vE '^\?\? \.cr-loop-handoff-round-[0-9]+\.md$' | grep -v '^$')
  ignored=$(printf '%s\n' "$all" | grep -cE '^\?\? \.cr-loop-handoff-round-[0-9]+\.md$')
  if [ -n "$rest" ]; then
    printf 'TREE=dirty\nIGNORED_HANDOFFS=%s\n' "$ignored"
    printf '%s\n' "$rest" | sed 's/^/DIRTY| /'
    exit 1
  fi
  printf 'TREE=clean\nIGNORED_HANDOFFS=%s\n' "$ignored"
}

cmd_paths() { resolve_paths; printf 'STATE_DIR=%s\nLEDGER=%s\nSTATE=%s\n' "$STATE_DIR" "$LEDGER" "$STATE"; }

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  init) cmd_init "$@" ;;
  next) cmd_next "$@" ;;
  start) cmd_start "$@" ;;
  _run) cmd__run "$@" ;;
  status) cmd_status "$@" ;;
  wait) cmd_wait "$@" ;;
  finish) cmd_finish "$@" ;;
  note) cmd_note "$@" ;;
  add) cmd_add "$@" ;;
  mark-converged) cmd_mark_converged "$@" ;;
  cancel) cmd_cancel "$@" ;;
  reset) cmd_reset "$@" ;;
  paths) cmd_paths "$@" ;;
  tree-clean) cmd_tree_clean "$@" ;;
  ''|-h|--help|help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$sub' (try --help)" ;;
esac
