#!/usr/bin/env bash
# cr-review.sh — reviewer runner + findings ledger for the codex-cr-loop plugin.
#
# The three /cr-loop* commands drive every review round through this script so
# the review protocol (modes, class-format prompt, ledger, round cap) lives in
# one place. See ../references/review-protocol.md for the procedure that calls it.
#
# Subcommands (run inside the feature branch's worktree):
#   init                         create/load per-branch state, print knobs + state
#   next [--clean-streak N] [--base REF]
#                                print the mode the next round must use
#   start --mode M --base REF [--since SHA]
#                                launch one detached `codex exec` review round
#   status [ROUND_DIR]           running / done for a round (default: current)
#   wait [ROUND_DIR] [--timeout S]
#                                block up to S seconds (default 540) for a round
#   finish [ROUND_DIR]           head/tree-drift check, classify, atomic ledger/state commit
#   ack-rules FP [--base REF] [NOTE...]
#                                record a person's approval of pending needs-human rule edits
#   note TEXT...                 append an author note (status, deferral, prevention) to the ledger
#   add SEVERITY TITLE [DETAIL]  register an external finding (PR bot, human) as a new class id
#   mark-converged [--post-rebase] [--base REF] [--round ROUND_DIR]
#                                verify convergence proof, record in ledger, reset round-cap counters
#   release-state get | set KEY=VAL... | clear
#                                atomically read/update/clear PR 8.0 release/rebase intent state
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

SELF_VERSION="1.8.1"
HERE=$(cd "$(dirname "$0")" && pwd -P)
SCHEMA="$HERE/../references/review-output.schema.json"
RULES="$HERE/review-rules.sh"
# shellcheck source=cr-tx.sh
. "$HERE/cr-tx.sh"

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
  ROOT=$(git rev-parse --show-toplevel) || die "cannot resolve repository root"
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
  { grep -v "^$1=" "$STATE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp" && mv "$tmp" "$STATE" || { rm -f "$tmp"; die "cannot update state key $1"; }
}

snum() { v=$(sget "$1"); is_uint "$v" && printf '%s\n' "$v" || printf '0\n'; }

ensure_state() {
  mkdir -p "$STATE_DIR/rounds" || die "cannot create $STATE_DIR"
  validate_branch_ownership
  recover_pending_tx
  if [ ! -f "$STATE" ]; then
    tmp="$STATE.tmp.$$"
    {
      printf 'branch=%s\n' "$BRANCH"
      printf 'created_at=%s\n' "$(now_utc)"
      printf 'rounds_started=0\nrounds_total=0\nlatest_finished_round=0\ndirty_since_step_back=0\nstep_backs_done=0\nnext_class_id=1\nclean_streak=0\n'
    } > "$tmp" && mv "$tmp" "$STATE" || { rm -f "$tmp"; die "cannot initialize $STATE"; }
  fi
  if [ ! -f "$LEDGER" ]; then
    ltmp="$LEDGER.tmp.$$"
    {
      printf '# cr-loop findings ledger — %s\n\n' "$BRANCH"
      printf 'Append-only. Class ids (C1, C2, ...) are stable for this branch. Reviewers must not\n'
      printf 're-report a class listed here; a reopened class cites its id ("[C3] ...").\n'
      printf 'Author notes mark classes fixed / deferred / accepted / wontfix / codified.\n'
    } > "$ltmp" && mv "$ltmp" "$LEDGER" || { rm -f "$ltmp"; die "cannot initialize $LEDGER"; }
  fi
}

# ---------------------------------------------------------------- lock ----
# Every state transaction runs under ONE branch-level kernel advisory lock
# (perl flock(LOCK_EX) on <state-dir>.lock held on fd 9). Detached reviewers
# close fd 9 so they never hold the lock.

with_branch_lock() {
  resolve_paths
  lockfile="$STATE_DIR.lock"
  mkdir -p "$(dirname "$lockfile")" || die "cannot create $(dirname "$lockfile")"
  command -v perl >/dev/null 2>&1 || die "perl is required (state lock + JSON parsing)"
  exec perl -MFcntl=:flock,F_SETFD -MPOSIX -e '
    my $f = shift @ARGV;
    open(my $l, ">>", $f) or do { print STDERR "cr-review: cannot open lock $f: $!\n"; exit 2 };
    my $deadline = time + 30;
    until (flock($l, LOCK_EX | LOCK_NB)) {
      if (time > $deadline) { print STDERR "cr-review: state lock busy for 30s: $f\n"; exit 2 }
      select(undef, undef, undef, 0.1);
    }
    if (fileno($l) != 9) { defined POSIX::dup2(fileno($l), 9) or do { print STDERR "cr-review: dup2: $!\n"; exit 2 } }
    open(my $nine, "+<&=", 9) or do { print STDERR "cr-review: fd 9: $!\n"; exit 2 };
    defined fcntl($nine, F_SETFD, 0) or do { print STDERR "cr-review: fcntl(F_SETFD): $!\n"; exit 2 };
    $ENV{CR_REVIEW_LOCK_HELD} = 1;
    exec @ARGV or do { print STDERR "cr-review: exec: $!\n"; exit 2 };
  ' -- "$lockfile" bash "$(self_path)" "$@"
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

validate_round_dir() {
  raw="$1"
  [ -d "$raw" ] || die "round dir not found: $raw"
  canon=$(cd "$raw" && pwd -P) || die "cannot resolve round dir: $raw"
  rounds_root="$STATE_DIR/rounds"
  [ -d "$rounds_root" ] || die "rounds dir missing: $rounds_root"
  rounds_canon=$(cd "$rounds_root" && pwd -P) || die "cannot resolve rounds dir"
  case "$canon" in
    "$rounds_canon/"*)
      rel="${canon#"$rounds_canon/"}"
      case "$rel" in */*) die "round dir must be a direct child of $rounds_canon: $canon" ;; esac
      ;;
    *) die "round dir does not belong to branch '$BRANCH': $canon" ;;
  esac
  printf '%s\n' "$canon"
}

round_dir_arg() {
  d="${1:-}"
  [ -n "$d" ] || d=$(sget current_round_dir)
  [ -n "$d" ] || die "no round given and no current round recorded"
  validate_round_dir "$d"
}

mget() { sed -n "s/^$2=//p" "$1/meta" | tail -n 1; }

pid_alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null; }

# Verify persisted PID is still running "cr-review.sh _run <this round dir>".
# Uses -ww so macOS/BSD ps never truncates long worktree paths, and anchors the
# match at end-of-line so a prefix dir can never match another round.
runner_pid() {
  rp=$(cat "$1/pid" 2>/dev/null)
  pid_alive "$rp" || return 1
  cmdline=$(ps -ww -o command= -p "$rp" 2>/dev/null) || return 1
  cmdline=$(printf '%s' "$cmdline" | sed 's/[[:space:]]*$//')
  case "$cmdline" in *"_run $1") printf '%s\n' "$rp" ;; *) return 1 ;; esac
}

codex_pid() {
  rp=$(runner_pid "$1") || return 1
  cp=$(cat "$1/codex.pid" 2>/dev/null)
  pid_alive "$cp" || return 1
  [ "$(ps -o ppid= -p "$cp" 2>/dev/null | tr -d ' ')" = "$rp" ] && printf '%s\n' "$cp"
}

round_state() {
  if [ -f "$1/exit" ]; then printf 'done\n'; return; fi
  if runner_pid "$1" >/dev/null; then printf 'running\n'; else printf 'dead\n'; fi
}

# Fail-closed snapshots of HEAD reflog count and working tree (v1 tracked-only for
# pre-1.8.1 round metas; v2 tracked diff + non-ignored non-handoff untracked files).
head_moves() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/cr-hm.XXXXXX") || return 1
  if ! git -C "$ROOT" reflog show --format=%H HEAD > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  cnt=$(wc -l < "$tmp" | tr -d ' ')
  rm -f "$tmp"
  is_uint "$cnt" || return 1
  printf '%s\n' "$cnt"
}

tree_fp_v1() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/cr-tf1.XXXXXX") || return 1
  if ! git -C "$ROOT" diff HEAD --no-relative --no-ext-diff --no-textconv --ignore-submodules=none --binary > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  h=$(git -C "$ROOT" hash-object --stdin < "$tmp" 2>/dev/null)
  rc=$?
  rm -f "$tmp"
  [ "$rc" -eq 0 ] && [ -n "$h" ] || return 1
  printf '%s\n' "$h"
}

tree_fp_v2() {
  tdiff=$(mktemp "${TMPDIR:-/tmp}/cr-tf2d.XXXXXX") || return 1
  tidx=$(mktemp "${TMPDIR:-/tmp}/cr-tf2i.XXXXXX") || { rm -f "$tdiff"; return 1; }
  twt=$(mktemp "${TMPDIR:-/tmp}/cr-tf2w.XXXXXX") || { rm -f "$tdiff" "$tidx"; return 1; }
  tuntr=$(mktemp "${TMPDIR:-/tmp}/cr-tf2u.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt"; return 1; }
  tstage=$(mktemp "${TMPDIR:-/tmp}/cr-tf2s.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr"; return 1; }
  tman=$(mktemp "${TMPDIR:-/tmp}/cr-tf2m.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage"; return 1; }
  if ! git -C "$ROOT" diff HEAD --no-relative --no-ext-diff --no-textconv --ignore-submodules=none --binary > "$tdiff" 2>/dev/null; then
    rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1
  fi
  if ! git -C "$ROOT" diff --cached --no-relative --no-ext-diff --no-textconv --ignore-submodules=none --binary > "$tidx" 2>/dev/null; then
    rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1
  fi
  if ! git -C "$ROOT" diff --no-relative --no-ext-diff --no-textconv --ignore-submodules=none --binary > "$twt" 2>/dev/null; then
    rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1
  fi
  dh=$(git -C "$ROOT" hash-object --stdin < "$tdiff" 2>/dev/null) || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1; }
  ih=$(git -C "$ROOT" hash-object --stdin < "$tidx" 2>/dev/null) || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1; }
  wh=$(git -C "$ROOT" hash-object --stdin < "$twt" 2>/dev/null) || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1; }
  if ! git -C "$ROOT" ls-files --others --exclude-standard -z > "$tuntr" 2>/dev/null; then
    rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1
  fi
  if ! git -C "$ROOT" ls-files --stage -z > "$tstage" 2>/dev/null; then
    rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1
  fi
  perl -MDigest::SHA=sha256_hex -e '
    use strict;
    use warnings;
    my ($root, $dh, $ih, $wh, $untr_file, $stage_file, $man_file) = @ARGV;

    sub run_git_raw {
      my ($dir, @args) = @_;
      my $pid = open(my $ph, "-|");
      return (1, "") unless defined $pid;
      if ($pid == 0) {
        open(STDERR, ">", "/dev/null");
        exec("git", "-C", $dir, @args) or exit 127;
      }
      binmode($ph, ":raw");
      local $/;
      my $out = <$ph>;
      my $closed = close $ph;
      my $st = $?;
      my $rc = (!$closed && $st == 0) ? 1 : (!defined($st) || $st == -1) ? 127 : ($st & 127) ? (128 + ($st & 127)) : ($st >> 8);
      return ($rc, defined $out ? $out : "");
    }

    sub hash_file_raw {
      my ($f) = @_;
      open(my $fh, "<:raw", $f) or exit 1;
      my $ctx = Digest::SHA->new(256);
      $ctx->addfile($fh);
      close $fh or exit 1;
      return $ctx->hexdigest;
    }

    my $hash_git_repo;
    $hash_git_repo = sub {
      my ($dir, $depth) = @_;
      exit 1 if $depth > 8;
      my ($rc_h, $sh) = run_git_raw($dir, "rev-parse", "--verify", "--quiet", "HEAD");
      $sh =~ s/\s+//g;
      if ($rc_h == 0 && $sh =~ /\A[0-9a-f]{40,64}\z/) {
        # valid committed HEAD
      } elsif ($rc_h == 1 && !length $sh) {
        my ($rc_sym, $sym) = run_git_raw($dir, "symbolic-ref", "-q", "HEAD");
        $sym =~ s/\s+//g;
        exit 1 unless $rc_sym == 0 && $sym =~ m{\Arefs/heads/.+\z};
        my ($rc_sr, $sr_out) = run_git_raw($dir, "show-ref", "--verify", "--quiet", $sym);
        exit 1 unless $rc_sr == 1 && !length $sr_out;
        $sh = "UNBORN";
      } else {
        exit 1;
      }
      my $ctx = Digest::SHA->new(256);
      $ctx->add("head\0$sh\0");
      if ($sh ne "UNBORN") {
        my ($rc_d, $d_out) = run_git_raw($dir, "diff", "HEAD", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--binary");
        exit 1 unless $rc_d == 0;
        $ctx->add("diff_head\0" . sha256_hex($d_out) . "\0");
        my ($rc_c, $c_out) = run_git_raw($dir, "diff", "--cached", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--binary");
        exit 1 unless $rc_c == 0;
        $ctx->add("diff_cached\0" . sha256_hex($c_out) . "\0");
      } else {
        my ($rc_st, $st_out) = run_git_raw($dir, "ls-files", "--stage", "-z");
        exit 1 unless $rc_st == 0;
        $ctx->add("stage_unborn\0" . sha256_hex($st_out) . "\0");
      }
      my ($rc_w, $w_out) = run_git_raw($dir, "diff", "--no-relative", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--binary");
      exit 1 unless $rc_w == 0;
      $ctx->add("diff_wt\0" . sha256_hex($w_out) . "\0");

      my ($rc_u, $u_out) = run_git_raw($dir, "ls-files", "--others", "--exclude-standard", "-z");
      exit 1 unless $rc_u == 0;
      for my $up (sort grep { length $_ } split(/\0/, $u_out)) {
        my $ufull = "$dir/$up";
        if (-l $ufull) {
          my $tgt = readlink($ufull); defined $tgt or exit 1;
          $ctx->add("ul\0$up\0$tgt\0");
        } elsif (-f $ufull) {
          my $ex = (-x $ufull) ? "x" : "f";
          $ctx->add("uf\0$ex\0$up\0" . hash_file_raw($ufull) . "\0");
        } elsif (-d $ufull && -e "$ufull/.git") {
          $ctx->add("ug\0$up\0" . $hash_git_repo->($ufull, $depth + 1) . "\0");
        } elsif (-d $ufull) {
          $ctx->add("ud\0$up\0");
        } else {
          $ctx->add("uo\0$up\0");
        }
      }
      my ($rc_gs, $gs_out) = run_git_raw($dir, "ls-files", "--stage", "-z");
      exit 1 unless $rc_gs == 0;
      my %sub_nested;
      for my $ent (split(/\0/, $gs_out)) {
        if ($ent =~ /\A160000\s+([0-9a-f]+)\s+\d+\t(.+)\z/s) {
          $sub_nested{$2} = $1;
        }
      }
      for my $sp (sort keys %sub_nested) {
        my $sfull = "$dir/$sp";
        if (-d $sfull && -e "$sfull/.git") {
          $ctx->add("sub\0$sp\0$sub_nested{$sp}\0" . $hash_git_repo->($sfull, $depth + 1) . "\0");
        } else {
          $ctx->add("sub_absent\0$sp\0$sub_nested{$sp}\0");
        }
      }
      return $ctx->hexdigest;
    };

    open(my $uf, "<:raw", $untr_file) or exit 1;
    local $/ = "\0";
    my @paths;
    while (defined(my $p = <$uf>)) {
      chomp $p;
      next if $p eq "";
      next if $p =~ /^\.cr-loop-handoff-round-[0-9]+\.md$/;
      push @paths, $p;
    }
    close $uf;
    @paths = sort @paths;

    open(my $sf, "<:raw", $stage_file) or exit 1;
    my %gitlinks;
    while (defined(my $ent = <$sf>)) {
      chomp $ent;
      if ($ent =~ /\A160000\s+([0-9a-f]+)\s+\d+\t(.+)\z/s) {
        $gitlinks{$2} = $1;
      }
    }
    close $sf;

    open(my $mf, ">:raw", $man_file) or exit 1;
    print $mf "tracked\t$dh\nindex\t$ih\nworktree\t$wh\n";
    for my $sp (sort keys %gitlinks) {
      my $full = "$root/$sp";
      my $ep = $sp; $ep =~ s/\\/\\\\/g; $ep =~ s/\n/\\n/g; $ep =~ s/\t/\\t/g;
      if (-d $full && -e "$full/.git") {
        my $sub_h = $hash_git_repo->($full, 1);
        print $mf "submodule\t$gitlinks{$sp}\t$sub_h\t$ep\n";
      } else {
        print $mf "submodule_uninit\t$gitlinks{$sp}\t$ep\n";
      }
    }
    for my $p (@paths) {
      my $full = "$root/$p";
      my $ep = $p; $ep =~ s/\\/\\\\/g; $ep =~ s/\n/\\n/g; $ep =~ s/\t/\\t/g;
      if (-l $full) {
        my $tgt = readlink($full);
        defined $tgt or exit 1;
        my $et = $tgt; $et =~ s/\\/\\\\/g; $et =~ s/\n/\\n/g; $et =~ s/\t/\\t/g;
        print $mf "link\t$ep\t$et\n";
      } elsif (-f $full) {
        open(my $hf, "-|", "git", "-C", $root, "hash-object", "--no-filters", "--", $full) or exit 1;
        my $oid = <$hf>;
        close $hf or exit 1;
        chomp $oid if defined $oid;
        (defined $oid && $oid =~ /^[0-9a-f]{40,64}$/) or exit 1;
        my $exec = (-x $full) ? "x" : "f";
        print $mf "file\t$exec\t$oid\t$ep\n";
      } elsif (-d $full) {
        if (-e "$full/.git") {
          my $sub_h = $hash_git_repo->($full, 1);
          print $mf "gitdir\t$sub_h\t$ep\n";
        } else {
          print $mf "dir\t$ep\n";
        }
      } else {
        print $mf "other\t$ep\n";
      }
    }
    close $mf or exit 1;
  ' -- "$ROOT" "$dh" "$ih" "$wh" "$tuntr" "$tstage" "$tman" || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1; }
  vh=$(git -C "$ROOT" hash-object --stdin < "$tman" 2>/dev/null)
  rc=$?
  rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"
  [ "$rc" -eq 0 ] && [ -n "$vh" ] || return 1
  printf 'v2:%s\n' "$vh"
}

tree_fp_matching() {
  expected="$1"
  case "$expected" in
    v2:*) tree_fp_v2 ;;
    *)    tree_fp_v1 ;;
  esac
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

# Compute RECURRING class ids across completed ## Round sections AFTER the latest
# ## Converged marker, deduplicating per (round, class) and ignoring ## External finding.
compute_recurring() {
  ledger_file="$1"
  perl -e '
    use strict;
    use warnings;
    my ($f) = @ARGV;
    open(my $fh, "<:encoding(UTF-8)", $f) or exit 0;
    my @lines = <$fh>;
    close $fh;
    my $start = 0;
    for (my $i = 0; $i < @lines; $i++) {
      $start = $i + 1 if $lines[$i] =~ /^## Converged\b/;
    }
    my $in_round = 0;
    my %round_seen;
    my %counts;
    for (my $i = $start; $i < @lines; $i++) {
      my $l = $lines[$i];
      if ($l =~ /^## Round /) {
        $in_round = 1;
        %round_seen = ();
      } elsif ($l =~ /^## /) {
        $in_round = 0;
      } elsif ($in_round && $l =~ /^### (C\d+)\b/) {
        my $cid = $1;
        $counts{$cid}++ unless $round_seen{$cid}++;
      }
    }
    my @rec = sort {
      my ($an) = ($a =~ /(\d+)/);
      my ($bn) = ($b =~ /(\d+)/);
      $an <=> $bn;
    } grep { $counts{$_} >= 2 } keys %counts;
    print join(",", @rec);
  ' -- "$ledger_file"
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
        printf -- '- Put that in the step_back array (one entry per recurring class), and list still-present instances as normal findings.\n'
        ;;
      *)
        printf -- '- Review the whole branch diff `git diff %s...%s` (start with --stat, then read the hunks and the surrounding code you need).\n' "$base_sha" "$head"
        printf -- '- If the ledger already lists classes, this is a confirmation pass after earlier fixes: also look for cross-cutting problems the fixes introduced together.\n'
        ;;
    esac
    bash "$RULES" prompt "$base_ref" "$base_sha" "$head" || return 1
    printf '\nLEDGER (no repeats)\n'
    printf -- '- Read the findings ledger first: %s\n' "$LEDGER"
    printf -- '- Never report a ledger class again. Exception: its fix is incomplete or regressed in the code under review — then set reopens to its id (e.g. "C3") and fill still_wrong.\n'
    printf -- '- Classes the ledger notes mark deferred / accepted / wontfix must not be reported at all, not even as reopened.\n'
    printf '\nWHAT TO REPORT\n'
    printf -- '- Only definite, actionable correctness, data-safety, concurrency or performance bugs introduced (or left incomplete) by this change. No style nits, no speculative hardening.\n'
    printf -- '- Report bug CLASSES, not single lines. One bullet per class: the root pattern and why it is wrong; EVERY instance in the reviewed scope (search for the pattern — do not stop at the first hit);\n'
    printf -- '  the systematic fix that removes all instances in one pass; how to prevent recurrence at the source (lint rule, source-guard or regression test, REVIEW.md entry, AGENTS.md/CLAUDE.md rule).\n'
    printf -- '- Severity: P0 data loss / security / crash on a common path; P1 wrong behaviour on a realistic path; P2 edge-case bug or measurable performance regression; P3 minor / defensive.\n'
    printf -- '- Pre-existing issues outside this change go in out_of_scope; they do not count.\n'
    printf '\nOUTPUT (structured; enforced by an output schema — the loop reads only these fields)\n'
    printf -- '- verdict: "clean" only when the review is complete and findings is empty; otherwise "findings". An incomplete review is never "clean".\n'
    printf -- '- findings: one object per bug class: severity (P0..P3), reopens ("" for a new class, or the ledger id such as "C3" for an incomplete/regressed fix),\n'
    printf -- '  title, location (primary file:line), pattern (root pattern + why wrong), still_wrong ("" unless reopens), instances (EVERY file:line), fix, prevent.\n'
    if [ "$mode" = "step-back" ]; then
      printf -- '- step_back: one object per recurring class: classes (ledger ids), name, invites_because, approach_change, prevent.\n'
    else
      printf -- '- step_back: [] (only used in step-back rounds).\n'
    fi
    printf -- '- out_of_scope: pre-existing issues outside this change as {location, note}; they do not count.\n'
    printf -- '- summary: one paragraph.\n'
    printf 'Do not modify any files.\n'
  } > "$p"
}

cmd_init() {
  resolve_paths; resolve_knobs; ensure_state
  conv_head=$(sget post_rebase_confirmed_head); conv_base=$(sget post_rebase_confirmed_base_sha)
  if [ -z "$conv_head" ]; then conv_head=$(sget base_converged_head); conv_base=$(sget base_converged_base_sha); fi
  printf 'CR_REVIEW_VERSION=%s\nBRANCH=%s\nSTATE_DIR=%s\nLEDGER=%s\n' "$SELF_VERSION" "$BRANCH" "$STATE_DIR" "$LEDGER"
  printf 'ROUND_CAP=%s\nMAX_STEP_BACKS=%s\nSKIP_P3=%s\nREVIEW_EFFORT=%s\nREVIEW_MODEL=%s\n' \
    "$ROUND_CAP" "$MAX_STEP_BACKS" "$SKIP_P3" "$EFFORT" "${MODEL:-<codex default>}"
  printf 'ROUNDS_TOTAL=%s\nDIRTY_SINCE_STEP_BACK=%s\nSTEP_BACKS_DONE=%s\nLAST_REVIEWED_HEAD=%s\nCLASSES=%s\n' \
    "$(snum rounds_total)" "$(snum dirty_since_step_back)" "$(snum step_backs_done)" \
    "$(sget last_reviewed_head)" "$(( $(snum next_class_id) - 1 ))"
  printf 'CLEAN_STREAK=%s\nLAST_CLEAN_HEAD=%s\nLAST_CLEAN_MODE=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\n' \
    "$(snum clean_streak)" "$(sget last_clean_head)" "$(sget last_clean_mode)" "$conv_head" "$conv_base"
  cur=$(sget current_round_dir)
  if [ -n "$cur" ] && [ -d "$cur" ]; then printf 'CURRENT_ROUND=%s (%s)\n' "$cur" "$(round_state "$cur")"; fi
  command -v codex >/dev/null 2>&1 && printf 'CODEX=%s\n' "$(command -v codex)" || printf 'CODEX=missing\n'
  perl -MJSON::PP -e 1 2>/dev/null && printf 'PERL_JSON=ok\n' || printf 'PERL_JSON=missing\n'
  [ -n "$WARNINGS" ] && printf 'WARNINGS=%s\n' "$WARNINGS"
  return 0
}

# Compute persisted clean_streak valid for ($head, $target_base_sha, $SKIP_P3).
effective_persisted_streak() {
  eh="$1"; eb="$2"
  pcs=$(snum clean_streak)
  [ "$pcs" -gt 0 ] || { printf '0\n'; return; }
  [ "$(sget last_clean_head)" = "$eh" ] || { printf '0\n'; return; }
  [ "$(sget last_clean_skip_p3)" = "$SKIP_P3" ] || { printf '0\n'; return; }
  if [ -n "$eb" ]; then
    [ "$(sget last_clean_base_sha)" = "$eb" ] || { printf '0\n'; return; }
  fi
  printf '%s\n' "$pcs"
}

cmd_next() {
  resolve_paths; resolve_knobs; ensure_state
  cs_explicit=0; cs=0; base_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --clean-streak) cs_explicit=1; cs="${2:-0}"; shift; [ $# -gt 0 ] && shift ;;
      --base) base_arg="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) die "next: unknown arg $1" ;;
    esac
  done
  is_uint "$cs" || die "--clean-streak must be an integer"
  head=$(git rev-parse HEAD) || die "cannot resolve HEAD"
  base_sha=""
  if [ -n "$base_arg" ]; then
    base_sha=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "next: --base '$base_arg' does not resolve"
  fi
  if [ "$cs_explicit" -eq 0 ]; then
    cs=$(effective_persisted_streak "$head" "$base_sha")
  fi
  dsb=$(snum dirty_since_step_back); sbd=$(snum step_backs_done)
  last=$(sget last_reviewed_head); lcm=$(sget last_clean_mode)
  bch=$(sget base_converged_head); bcb=$(sget base_converged_base_sha); bcp=$(sget base_converged_skip_p3)
  # Already converged on this exact binding (only when caller did not override --clean-streak)
  if [ "$cs_explicit" -eq 0 ]; then
    if [ "$cs" -ge 2 ] && [ "$lcm" = "full" ]; then
      printf 'MODE=converged\nCLEAN_STREAK=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\nREASON=already converged on this HEAD/base/policy\n' \
        "$cs" "$head" "$(sget last_clean_base_sha)"
      return 0
    fi
    if [ -n "$bch" ] && [ "$bch" = "$head" ] && [ "$bcp" = "$SKIP_P3" ] && { [ -z "$base_sha" ] || [ "$bcb" = "$base_sha" ]; }; then
      printf 'MODE=converged\nCLEAN_STREAK=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\nREASON=recorded convergence already holds for this HEAD/base/policy\n' \
        "$cs" "$bch" "$bcb"
      return 0
    fi
  fi
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
  self="$1"; d="$2"
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid bash "$self" _run "$d" </dev/null >/dev/null 2>&1 9>&- &
  elif command -v perl >/dev/null 2>&1; then
    nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!"' -- bash "$self" _run "$d" </dev/null >/dev/null 2>&1 9>&- &
  else
    nohup bash "$self" _run "$d" </dev/null >/dev/null 2>&1 9>&- &
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
  command -v perl >/dev/null 2>&1 || die "perl is required to parse review results"
  [ -f "$SCHEMA" ] || die "output schema missing: $SCHEMA"
  cur=$(sget current_round_dir)
  if [ -n "$cur" ] && [ -d "$cur" ] && [ "$(round_state "$cur")" = "running" ]; then
    die "a review round is already running for this branch: $cur (use 'wait', 'finish' or 'cancel')"
  fi
  base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "start: base '$base' does not resolve"
  head=$(git rev-parse HEAD) || die "start: cannot resolve HEAD"
  if [ "$mode" = "incremental" ]; then
    [ -n "$since" ] || die "start: incremental mode needs --since <last reviewed sha>"
    since=$(git rev-parse --verify --quiet "$since^{commit}") || die "start: --since does not resolve"
    git merge-base --is-ancestor "$since" "$head" || die "start: --since $since is not an ancestor of HEAD — use --mode full"
    [ "$since" != "$head" ] || die "start: nothing changed since $since — use --mode full for a confirmation round"
  fi
  hm=$(head_moves) || die "start: could not snapshot HEAD reflog (fail-closed)"
  tf=$(tree_fp_v2) || die "start: could not snapshot working tree (fail-closed)"
  n=$(( $(snum rounds_started) + 1 ))
  d="$STATE_DIR/rounds/$(printf '%03d' "$n")-$mode"
  mkdir -p "$STATE_DIR/rounds" && mkdir "$d" 2>/dev/null || die "round dir already exists (concurrent start?): $d"
  {
    printf 'mode=%s\nbase_ref=%s\nbase_sha=%s\nsince=%s\nreviewed_head=%s\nround=%s\n' "$mode" "$base" "$base_sha" "$since" "$head" "$n"
    printf 'effort=%s\nmodel=%s\nroot=%s\nschema=%s\nstarted_at=%s\nstarted_epoch=%s\n' "$EFFORT" "$MODEL" "$ROOT" "$SCHEMA" "$(now_utc)" "$(date +%s)"
    printf 'head_moves=%s\ntree_fp=%s\n' "$hm" "$tf"
  } > "$d/meta" || { rm -rf "$d"; die "start: cannot write round meta"; }
  if ! write_prompt "$d" "$mode" "$base" "$base_sha" "$head" "$since" "$n"; then
    rm -rf "$d"; die "start: could not build the reviewer prompt (rule-file scan failed) — nothing started"
  fi
  sset rounds_started "$n"
  sset current_round_dir "$d"
  launch_detached "$(self_path)" "$d"
  printf 'ROUND=%s\nMODE=%s\nROUND_DIR=%s\nPID=%s\nREVIEWED_HEAD=%s\nBASE_SHA=%s\n' "$n" "$mode" "$d" "$(cat "$d/pid")" "$head" "$base_sha"
  [ -n "$since" ] && printf 'SINCE=%s\n' "$since"
  printf 'RESULT_JSON=%s/result.json\n' "$d"
}

cmd__run() {
  d="$1"
  printf '%s\n' "$$" > "$d/pid"
  root=$(mget "$d" root); effort=$(mget "$d" effort); model=$(mget "$d" model); schema=$(mget "$d" schema)
  prompt=$(cat "$d/prompt.md")
  if [ -n "$model" ]; then
    codex exec --sandbox read-only -C "$root" -c project_doc_max_bytes=0 -m "$model" -c "model_reasoning_effort=$effort" \
      --output-schema "$schema" --output-last-message "$d/result.json" "$prompt" </dev/null >"$d/log" 2>&1 &
  else
    codex exec --sandbox read-only -C "$root" -c project_doc_max_bytes=0 -c "model_reasoning_effort=$effort" \
      --output-schema "$schema" --output-last-message "$d/result.json" "$prompt" </dev/null >"$d/log" 2>&1 &
  fi
  cpid=$!
  printf '%s\n' "$cpid" > "$d/codex.pid"
  wait "$cpid"
  rc=$?
  printf 'finished_at=%s\n' "$(now_utc)" >> "$d/meta"
  printf '%s\n' "$rc" > "$d/exit"
}

cmd_status() { resolve_paths; d=$(round_dir_arg "${1:-}") || exit 2; print_status "$d"; }

sleep_bounded() {
  # $1 = desired delay (can be 0.5), $2 = remaining integer seconds
  perl -e '
    my ($d, $rem) = @ARGV;
    $d = $rem if $rem < $d;
    select(undef, undef, undef, $d) if $d > 0;
  ' -- "$1" "$2"
}

cmd_wait() {
  resolve_paths
  d=""; t=540
  while [ $# -gt 0 ]; do
    case "$1" in --timeout) t="${2:-540}"; shift; [ $# -gt 0 ] && shift ;; *) d="$1"; shift ;; esac
  done
  is_uint "$t" || die "--timeout must be seconds"
  d=$(round_dir_arg "$d") || exit 2
  end=$(( $(date +%s) + t ))
  step=0
  while [ "$(round_state "$d")" = "running" ]; do
    now=$(date +%s)
    rem=$(( end - now ))
    [ "$rem" -gt 0 ] || break
    case "$step" in
      0) delay=0.5 ;;
      1) delay=1 ;;
      2) delay=2 ;;
      *) delay=5 ;;
    esac
    sleep_bounded "$delay" "$rem"
    step=$(( step + 1 ))
  done
  print_status "$d"
}

cmd_cancel() {
  resolve_paths; ensure_state
  d=$(round_dir_arg "${1:-}") || exit 2
  [ "$(round_state "$d")" = "running" ] || { print_status "$d"; return 0; }
  rp=$(runner_pid "$d") || { print_status "$d"; return 0; }
  cp=$(codex_pid "$d")
  pg=$(ps -o pgid= -p "$rp" 2>/dev/null | tr -d ' ')
  if [ "$pg" = "$rp" ]; then
    kill -TERM -- "-$rp" 2>/dev/null
  else
    [ -n "$cp" ] && kill -TERM "$cp" 2>/dev/null
    kill -TERM "$rp" 2>/dev/null
  fi
  sleep 1
  [ -f "$d/exit" ] || printf '130\n' > "$d/exit"
  printf 'cancelled_at=%s\n' "$(now_utc)" >> "$d/meta"
  print_status "$d"
}

cmd_finish() {
  resolve_paths; resolve_knobs; ensure_state
  explicit_arg="${1:-}"
  if [ -n "$explicit_arg" ]; then
    d=$(validate_round_dir "$explicit_arg")
    if [ -f "$d/finished" ]; then
      [ -f "$d/verdict" ] || die "round already finished but verdict missing: $d"
      cat "$d/verdict"
      return 0
    fi
  else
    if [ "$REPLAYED_TX_KIND" = "finish" ] && [ -n "$REPLAYED_TX_ROUND" ] && [ -f "$REPLAYED_TX_ROUND/verdict" ]; then
      cat "$REPLAYED_TX_ROUND/verdict"
      return 0
    fi
    d=$(round_dir_arg "")
    [ -f "$d/finished" ] && die "round already finished: $d (pass explicit ROUND_DIR to re-read verdict)"
  fi

  st=$(round_state "$d")
  [ "$st" = "running" ] && { printf 'VERDICT=running\n'; print_status "$d"; exit 4; }

  mode=$(mget "$d" mode); reviewed=$(mget "$d" reviewed_head); n=$(mget "$d" round)
  is_uint "$n" || die "corrupt round number in $d/meta"
  rs=$(snum rounds_started); lfr=$(snum latest_finished_round)
  if [ "$n" -le "$lfr" ] || [ "$n" -ne "$rs" ]; then
    die "round $n is superseded (rounds_started=$rs, latest_finished_round=$lfr) — refusing out-of-order finish"
  fi

  head=$(git rev-parse HEAD) || { printf 'VERDICT=error\nREASON=cannot resolve HEAD\n'; exit 5; }
  drift=""
  cur_hm=""; cur_tf=""
  exp_hm=$(mget "$d" head_moves)
  exp_tf=$(mget "$d" tree_fp)
  if [ "$head" != "$reviewed" ]; then
    drift=head-moved
  else
    if [ -n "$exp_hm" ]; then
      cur_hm=$(head_moves) || { printf 'VERDICT=error\nREASON=could not read HEAD reflog for drift check\n'; exit 5; }
      [ "$exp_hm" = "$cur_hm" ] || drift=head-moved-and-returned
    fi
    if [ -z "$drift" ] && [ -n "$exp_tf" ]; then
      cur_tf=$(tree_fp_matching "$exp_tf") || { printf 'VERDICT=error\nREASON=could not snapshot working tree for drift check\n'; exit 5; }
      [ "$exp_tf" = "$cur_tf" ] || drift=tree-changed
    fi
  fi
  if [ -n "$drift" ]; then
    printf 'VERDICT=head-drift\nREASON=%s\nREVIEWED_HEAD=%s\nHEAD=%s\n' "$drift" "$reviewed" "$head"
    exit 3
  fi

  rc=$(cat "$d/exit" 2>/dev/null || printf 'dead')
  res="$d/result.json"
  if [ "$rc" != "0" ] || [ ! -s "$res" ]; then
    printf 'VERDICT=error\nEXIT=%s\nRESULT=%s\nLOG=%s\n' "$rc" "$res" "$d/log"
    tail -n 20 "$d/log" 2>/dev/null | sed 's/^/LOG| /'
    exit 5
  fi

  frag="$d/ledger-fragment.md"; md="$d/review.md"
  parsed=$(perl "$HERE/parse-review.pl" "$res" "$(snum next_class_id)" "$LEDGER" "$frag" "$md")
  prc=$?
  if [ "$prc" -ne 0 ]; then
    printf 'VERDICT=error\n%s\nRESULT=%s\n' "$(printf '%s\n' "$parsed" | sed -n 's/^ERROR=/REASON=/p')" "$res"
    exit 5
  fi
  pv() { printf '%s\n' "$parsed" | sed -n "s/^$1=//p"; }
  c0=$(pv P0); c1=$(pv P1); c2=$(pv P2); c3=$(pv P3); total=$(pv TOTAL)
  new=$(pv NEW); reo=$(pv REOPENED); nxt=$(pv NEXT)
  if [ "$total" -eq 0 ]; then
    verdict=clean
  elif [ $(( c0 + c1 + c2 )) -eq 0 ] && [ "$SKIP_P3" = "1" ]; then
    verdict=p3-only
  else
    verdict=dirty
  fi

  # Single-pass rule-file scan reused for classification, fingerprint, and render.
  scan_file="$d/rules-scan.tsv"
  rules_4col=""; rules_fp=""; rules_open=0; rbase=$(mget "$d" base_sha)
  : > "$scan_file" || { printf 'VERDICT=error\nREASON=cannot create %s\n' "$scan_file"; exit 5; }
  if [ -n "$rbase" ]; then
    if ! bash "$RULES" scan "$rbase" "$reviewed" > "$scan_file" || ! rules_fp=$(bash "$RULES" fp "$rbase" "$reviewed" --from-scan "$scan_file"); then
      printf 'VERDICT=error\nREASON=rule-file scan failed (review-rules.sh); the round is not finished — retry finish\nRESULT=%s\n' "$res"
      exit 5
    fi
    rules_4col=$(awk -F '\t' 'NF >= 8 { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $8 }' "$scan_file")
  fi
  [ -n "$rules_fp" ] && [ "$rules_fp" != "$(sget rules_ack_fp)" ] && rules_open=1
  [ "$rules_open" = 1 ] && case "$verdict" in clean|p3-only) verdict=needs-human ;; esac
  if [ -n "$rbase" ]; then
    if ! bash "$RULES" render "$rbase" "$reviewed" "$rules_fp" "$rules_open" --from-scan "$scan_file" >> "$md"; then
      printf 'VERDICT=error\nREASON=rule-file render failed; the round is not finished — retry finish\nRESULT=%s\n' "$res"
      exit 5
    fi
  fi

  # Compute next state values before building the atomic transaction.
  new_rounds_total=$(( $(snum rounds_total) + 1 ))
  new_dsb=$(snum dirty_since_step_back)
  new_sbd=$(snum step_backs_done)
  if [ "$mode" = "step-back" ]; then
    new_sbd=$(( new_sbd + 1 ))
    new_dsb=0
  elif [ "$verdict" = "dirty" ]; then
    new_dsb=$(( new_dsb + 1 ))
  fi

  new_cs=$(snum clean_streak)
  new_lch=$(sget last_clean_head)
  new_lcb=$(sget last_clean_base_sha)
  new_lcp=$(sget last_clean_skip_p3)
  new_lcm=$(sget last_clean_mode)

  new_bch=$(sget base_converged_head)
  new_bcb=$(sget base_converged_base_sha)
  new_bcp=$(sget base_converged_skip_p3)
  new_bcr=$(sget base_converged_round)
  new_prh=$(sget post_rebase_confirmed_head)
  new_prb=$(sget post_rebase_confirmed_base_sha)
  new_prr=$(sget post_rebase_confirmed_round)

  rp_fp=""; rp_verdict=""; rp_round=""; rp_head=""; rp_base=""; rp_p3=""; rp_mode=""; rp_tf=""; rp_hm=""
  case "$verdict" in
    clean|p3-only)
      if [ "$reviewed" = "$new_lch" ] && [ "$rbase" = "$new_lcb" ] && [ "$SKIP_P3" = "$new_lcp" ]; then
        new_cs=$(( new_cs + 1 ))
      else
        new_cs=1
      fi
      new_lch="$reviewed"; new_lcb="$rbase"; new_lcp="$SKIP_P3"; new_lcm="$mode"
      ;;
    needs-human)
      rp_fp="$rules_fp"; rp_verdict="needs-human"; rp_round="$n"
      rp_head="$reviewed"; rp_base="$rbase"; rp_p3="$SKIP_P3"; rp_mode="$mode"
      rp_tf="$cur_tf"; rp_hm="$cur_hm"
      ;;
    dirty)
      new_cs=0; new_lch=""; new_lcb=""; new_lcp=""; new_lcm=""
      # Invalidate any prior convergence proof on a new dirty round.
      new_bch=""; new_bcb=""; new_bcp=""; new_bcr=""
      new_prh=""; new_prb=""; new_prr=""
      ;;
  esac

  cur_ptr=$(sget current_round_dir)
  new_cur_ptr="$cur_ptr"
  [ "$cur_ptr" = "$d" ] && new_cur_ptr=""
  new_next_id=$(snum next_class_id)
  is_uint "$nxt" && new_next_id="$nxt"

  # Prepare atomic transaction artifacts inside $d/tx.
  tx_dir="$d/tx"
  mkdir -p "$tx_dir" || die "cannot create tx dir $tx_dir"

  {
    cat "$LEDGER"
    printf '\n## Round %s — %s — %s — %s (P0×%s P1×%s P2×%s P3×%s) — %s\n' \
      "$n" "$mode" "$(git rev-parse --short "$reviewed")" "$verdict" "$c0" "$c1" "$c2" "$c3" "$(now_utc)"
    [ -s "$frag" ] && cat "$frag"
    if [ "$rules_open" = 1 ]; then
      printf '#### Rule-file edits awaiting a person (fingerprint %s)\n' "$rules_fp"
      printf '%s\n' "$rules_4col" | awk -F '\t' '$1 == "needs-human" { printf "- %s %s %s\n", $2, $3, $4 }'
    fi
  } > "$tx_dir/ledger.full" || die "cannot prepare tx ledger"

  build_state_file "$tx_dir/state.full" \
    "next_class_id=$new_next_id" \
    "rounds_total=$new_rounds_total" \
    "latest_finished_round=$n" \
    "last_reviewed_head=$reviewed" \
    "last_reviewed_base_sha=$rbase" \
    "last_reviewed_mode=$mode" \
    "last_reviewed_verdict=$verdict" \
    "last_reviewed_skip_p3=$SKIP_P3" \
    "dirty_since_step_back=$new_dsb" \
    "step_backs_done=$new_sbd" \
    "clean_streak=$new_cs" \
    "last_clean_head=$new_lch" \
    "last_clean_base_sha=$new_lcb" \
    "last_clean_skip_p3=$new_lcp" \
    "last_clean_mode=$new_lcm" \
    "base_converged_head=$new_bch" \
    "base_converged_base_sha=$new_bcb" \
    "base_converged_skip_p3=$new_bcp" \
    "base_converged_round=$new_bcr" \
    "post_rebase_confirmed_head=$new_prh" \
    "post_rebase_confirmed_base_sha=$new_prb" \
    "post_rebase_confirmed_round=$new_prr" \
    "rules_pending_fp=$rp_fp" \
    "rules_pending_verdict=$rp_verdict" \
    "rules_pending_round=$rp_round" \
    "rules_pending_head=$rp_head" \
    "rules_pending_base_sha=$rp_base" \
    "rules_pending_skip_p3=$rp_p3" \
    "rules_pending_mode=$rp_mode" \
    "rules_pending_tree_fp=$rp_tf" \
    "rules_pending_head_moves=$rp_hm" \
    "current_round_dir=$new_cur_ptr"

  recurring=$(compute_recurring "$tx_dir/ledger.full")
  {
    printf 'VERDICT=%s\nMODE=%s\nROUND=%s\nP0=%s\nP1=%s\nP2=%s\nP3=%s\n' "$verdict" "$mode" "$n" "$c0" "$c1" "$c2" "$c3"
    printf 'NEW_CLASSES=%s\nREOPENED=%s\nRECURRING=%s\n' "$new" "$reo" "$recurring"
    printf 'DIRTY_SINCE_STEP_BACK=%s/%s\nSTEP_BACKS_DONE=%s/%s\nCLEAN_STREAK=%s\n' \
      "$new_dsb" "$ROUND_CAP" "$new_sbd" "$MAX_STEP_BACKS" "$new_cs"
    printf 'REVIEWED_HEAD=%s\nBASE_SHA=%s\nRESULT=%s\nRESULT_JSON=%s\nLEDGER=%s\n' "$reviewed" "$rbase" "$md" "$res" "$LEDGER"
    printf 'RULE_CHANGES=%s\nRULES_NEED_HUMAN=%s\nRULES_FP=%s\n' \
      "$(printf '%s' "$rules_4col" | grep -c .)" \
      "$( [ "$rules_open" = 1 ] && printf '%s' "$rules_4col" | grep -c '^needs-human' || printf '0')" \
      "$rules_fp"
    if [ -n "$rules_4col" ]; then
      printf '%s\n' "$rules_4col" | awk -F '\t' '{ printf "RULE| [%s] %s %s %s\n", $1, $2, $3, $4 }'
    fi
  } > "$tx_dir/verdict.out" || die "cannot prepare tx verdict"

  commit_tx "$tx_dir" finish "$d"
  cat "$d/verdict"
}

cmd_ack_rules() {
  resolve_paths; resolve_knobs; ensure_state
  fp="${1:-}"; [ $# -gt 0 ] && shift
  base_arg=""
  if [ "${1:-}" = "--base" ]; then base_arg="${2:-}"; shift; [ $# -gt 0 ] && shift; fi
  pending=$(sget rules_pending_fp)
  pverdict=$(sget rules_pending_verdict)
  [ -n "$pending" ] && [ "$pverdict" = "needs-human" ] || die "ack-rules: no needs-human rule-file edits are awaiting a person"
  [ "$fp" = "$pending" ] || die "ack-rules: fingerprint '$fp' does not match the pending edits ($pending) — re-read the latest finish output"

  pround=$(sget rules_pending_round)
  lfr=$(snum latest_finished_round)
  [ "$pround" = "$lfr" ] || die "ack-rules: pending rule approval (round $pround) is superseded by round $lfr"

  phead=$(sget rules_pending_head); pbase=$(sget rules_pending_base_sha)
  pp3=$(sget rules_pending_skip_p3); pmode=$(sget rules_pending_mode)
  ptf=$(sget rules_pending_tree_fp); phm=$(sget rules_pending_head_moves)

  head=$(git rev-parse HEAD) || die "ack-rules: cannot resolve HEAD"
  [ "$head" = "$phead" ] || die "ack-rules: HEAD ($head) no longer matches pending round HEAD ($phead)"
  [ "$SKIP_P3" = "$pp3" ] || die "ack-rules: CR_LOOP_SKIP_P3 ($SKIP_P3) differs from pending round ($pp3)"
  if [ -n "$base_arg" ]; then
    bsha=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "ack-rules: --base '$base_arg' does not resolve"
    [ "$bsha" = "$pbase" ] || die "ack-rules: base ($bsha) differs from pending round base ($pbase)"
  fi
  if [ -n "$phm" ]; then
    cur_hm=$(head_moves) || die "ack-rules: cannot read HEAD reflog"
    [ "$cur_hm" = "$phm" ] || die "ack-rules: HEAD moved and returned since pending round"
  fi
  if [ -n "$ptf" ]; then
    cur_tf=$(tree_fp_matching "$ptf") || die "ack-rules: cannot snapshot working tree"
    [ "$cur_tf" = "$ptf" ] || die "ack-rules: working tree changed since pending round"
  fi

  # Apply the exact same clean-streak rule as normal clean rounds.
  cur_cs=$(snum clean_streak)
  if [ "$phead" = "$(sget last_clean_head)" ] && [ "$pbase" = "$(sget last_clean_base_sha)" ] && [ "$pp3" = "$(sget last_clean_skip_p3)" ]; then
    new_cs=$(( cur_cs + 1 ))
  else
    new_cs=1
  fi

  tx_dir="$STATE_DIR/tx-ack.$$"
  mkdir -p "$tx_dir" || die "cannot create $tx_dir"
  {
    cat "$LEDGER"
    printf -- '- note %s @%s: rule-file edits approved by a person (fingerprint %s)%s\n' \
      "$(now_utc)" "$(git rev-parse --short HEAD)" "$fp" "${*:+ — $*}"
  } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare ack ledger"; }

  build_state_file "$tx_dir/state.full" \
    "rules_ack_fp=$fp" \
    "rules_pending_fp=" \
    "rules_pending_verdict=" \
    "rules_pending_round=" \
    "rules_pending_head=" \
    "rules_pending_base_sha=" \
    "rules_pending_skip_p3=" \
    "rules_pending_mode=" \
    "rules_pending_tree_fp=" \
    "rules_pending_head_moves=" \
    "clean_streak=$new_cs" \
    "last_clean_head=$phead" \
    "last_clean_base_sha=$pbase" \
    "last_clean_skip_p3=$pp3" \
    "last_clean_mode=$pmode"

  commit_tx "$tx_dir" ack-rules
  rm -rf "$tx_dir"
  printf 'ACKED=%s\nCLEAN_STREAK=%s\n' "$fp" "$new_cs"
}

cmd_note() {
  resolve_paths; ensure_state
  [ $# -gt 0 ] || die "note: text required (e.g. 'C3 fixed — prevention: REVIEW.md#stale-predicate')"
  ltmp="$LEDGER.tmp.$$"
  {
    cat "$LEDGER"
    printf -- '- note %s @%s: %s\n' "$(now_utc)" "$(git rev-parse --short HEAD)" "$*"
  } > "$ltmp" && mv "$ltmp" "$LEDGER" || { rm -f "$ltmp"; die "cannot update ledger"; }
  printf 'NOTED\n'
}

cmd_add() {
  resolve_paths; ensure_state
  sev="${1:-}"; title="${2:-}"; detail="${3:-}"
  case "$sev" in P0|P1|P2|P3) ;; *) die "add: severity must be P0..P3" ;; esac
  [ -n "$title" ] || die "add: title required ('<class title> — <file>:<line>')"
  id="C$(snum next_class_id)"
  new_nxt=$(( $(snum next_class_id) + 1 ))
  tx_dir="$STATE_DIR/tx-add.$$"
  mkdir -p "$tx_dir" || die "cannot create $tx_dir"
  {
    cat "$LEDGER"
    printf '\n## External finding — %s @%s\n### %s [%s] %s\n' "$(now_utc)" "$(git rev-parse --short HEAD)" "$id" "$sev" "$title"
    if [ -n "$detail" ]; then printf '  %s\n' "$detail"; fi
  } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare add ledger"; }
  build_state_file "$tx_dir/state.full" "next_class_id=$new_nxt"
  commit_tx "$tx_dir" add
  rm -rf "$tx_dir"
  printf 'ID=%s\n' "$id"
}

cmd_mark_converged() {
  resolve_paths; resolve_knobs; ensure_state
  post_rebase=0; base_arg=""; round_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --post-rebase) post_rebase=1; shift ;;
      --base) base_arg="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      --round) round_arg="${2:-}"; shift; [ $# -gt 0 ] && shift ;;
      *) die "mark-converged: unknown arg $1" ;;
    esac
  done
  head=$(git rev-parse HEAD) || die "mark-converged: cannot resolve HEAD"
  short_head=$(git rev-parse --short HEAD)
  base_sha=""
  if [ -n "$base_arg" ]; then
    base_sha=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "mark-converged: --base '$base_arg' does not resolve"
  fi
  lfr=$(snum latest_finished_round)

  tx_dir="$STATE_DIR/tx-conv.$$"
  mkdir -p "$tx_dir" || die "cannot create $tx_dir"

  if [ "$post_rebase" -eq 1 ]; then
    bch=$(sget base_converged_head)
    [ -n "$bch" ] || die "mark-converged --post-rebase: no prior two-round convergence record exists"
    [ -n "$base_sha" ] || die "mark-converged --post-rebase: --base <ref> is required"
    if [ -n "$round_arg" ]; then
      rd=$(validate_round_dir "$round_arg")
      rn=$(mget "$rd" round)
      [ "$rn" = "$lfr" ] || die "mark-converged --post-rebase: --round ($rn) is not the latest finished round ($lfr)"
    else
      rn="$lfr"
    fi
    [ "$(sget last_clean_head)" = "$head" ] || die "mark-converged --post-rebase: HEAD ($head) has no clean confirmation round"
    [ "$(sget last_clean_base_sha)" = "$base_sha" ] || die "mark-converged --post-rebase: clean round base does not match --base ($base_sha)"
    [ "$(sget last_clean_skip_p3)" = "$SKIP_P3" ] || die "mark-converged --post-rebase: SKIP_P3 mismatch"
    [ "$(sget last_clean_mode)" = "full" ] || die "mark-converged --post-rebase: confirmation round must be mode full (got '$(sget last_clean_mode)')"
    bch_short=$(git rev-parse --short "$bch" 2>/dev/null || printf '%s' "$bch")
    {
      cat "$LEDGER"
      printf '\n## Converged (post-rebase 1-round full confirmation) at %s — %s (prior 2-round convergence: %s, base: %s, round: %s)\n' \
        "$short_head" "$(now_utc)" "$bch_short" "$(git rev-parse --short "$base_sha")" "$rn"
    } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare converged ledger"; }
    build_state_file "$tx_dir/state.full" \
      "post_rebase_confirmed_head=$head" \
      "post_rebase_confirmed_base_sha=$base_sha" \
      "post_rebase_confirmed_round=$rn" \
      "dirty_since_step_back=0" \
      "step_backs_done=0"
  else
    cs=$(snum clean_streak)
    [ "$cs" -ge 2 ] || die "mark-converged: requires clean_streak >= 2 (got $cs)"
    [ "$(sget last_clean_mode)" = "full" ] || die "mark-converged: second clean round must be mode full (got '$(sget last_clean_mode)')"
    [ "$(sget last_clean_head)" = "$head" ] || die "mark-converged: HEAD ($head) does not match last_clean_head ($(sget last_clean_head))"
    [ "$(sget last_clean_skip_p3)" = "$SKIP_P3" ] || die "mark-converged: SKIP_P3 ($SKIP_P3) does not match last_clean_skip_p3 ($(sget last_clean_skip_p3))"
    lcb=$(sget last_clean_base_sha)
    if [ -n "$base_sha" ]; then
      [ "$lcb" = "$base_sha" ] || die "mark-converged: --base ($base_sha) does not match last_clean_base_sha ($lcb)"
    fi
    {
      cat "$LEDGER"
      printf '\n## Converged at %s — %s (rounds so far: %s, step-backs: %s)\n' \
        "$short_head" "$(now_utc)" "$(snum rounds_total)" "$(snum step_backs_done)"
    } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare converged ledger"; }
    build_state_file "$tx_dir/state.full" \
      "base_converged_head=$head" \
      "base_converged_base_sha=$lcb" \
      "base_converged_skip_p3=$SKIP_P3" \
      "base_converged_round=$lfr" \
      "post_rebase_confirmed_head=" \
      "post_rebase_confirmed_base_sha=" \
      "post_rebase_confirmed_round=" \
      "dirty_since_step_back=0" \
      "step_backs_done=0"
  fi

  commit_tx "$tx_dir" mark-converged
  rm -rf "$tx_dir"
  if [ "$post_rebase" -eq 1 ]; then conv_base="$base_sha"; else conv_base="$lcb"; fi
  printf 'CONVERGED=%s\nBASE_SHA=%s\n' "$head" "$conv_base"
}

cmd_release_state() {
  resolve_paths; ensure_state
  action="${1:-get}"; [ $# -gt 0 ] && shift
  case "$action" in
    get)
      conv_head=$(sget post_rebase_confirmed_head); conv_base=$(sget post_rebase_confirmed_base_sha)
      if [ -z "$conv_head" ]; then conv_head=$(sget base_converged_head); conv_base=$(sget base_converged_base_sha); fi
      printf 'PRE_REBASE_HEAD=%s\nPINNED_REMOTE_HEAD_SHA=%s\nTARGET_BASE_SHA=%s\nREBASED_IN_8_0=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\n' \
        "$(sget rel_pre_rebase_head)" "$(sget rel_pinned_remote_head_sha)" "$(sget rel_target_base_sha)" "$(snum rel_rebased_in_8_0)" \
        "$conv_head" "$conv_base"
      ;;
    set)
      [ $# -gt 0 ] || die "release-state set: at least one KEY=VAL required"
      for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        case "$k" in
          rel_pre_rebase_head|rel_pinned_remote_head_sha|rel_target_base_sha) ;;
          rel_rebased_in_8_0)
            case "$v" in 0|1) ;; *) die "release-state set: rel_rebased_in_8_0 must be 0 or 1" ;; esac
            ;;
          *) die "release-state set: disallowed key '$k'" ;;
        esac
      done
      [ ! -L "$STATE" ] && [ ! -d "$STATE" ] || die "release-state set: invalid state target $STATE"
      stmp="$STATE.tmp.$$"
      build_state_file "$stmp" "$@"
      mv "$stmp" "$STATE" || { rm -f "$stmp"; die "release-state set failed"; }
      printf 'RELEASE_STATE_UPDATED\n'
      ;;
    clear)
      [ ! -L "$STATE" ] && [ ! -d "$STATE" ] || die "release-state clear: invalid state target $STATE"
      stmp="$STATE.tmp.$$"
      build_state_file "$stmp" "rel_pre_rebase_head=" "rel_pinned_remote_head_sha=" "rel_target_base_sha=" "rel_rebased_in_8_0=0"
      mv "$stmp" "$STATE" || { rm -f "$stmp"; die "release-state clear failed"; }
      printf 'RELEASE_STATE_CLEARED\n'
      ;;
    *) die "release-state: expected get | set | clear" ;;
  esac
}

cmd_reset() {
  resolve_paths
  [ -d "$STATE_DIR" ] || { printf 'NOTHING_TO_RESET\n'; return 0; }
  validate_branch_ownership
  recover_pending_tx
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
  all=$(git status --porcelain --untracked-files=all 2>/dev/null) || {
    printf 'TREE=error\n'
    git status --porcelain --untracked-files=all 2>&1 >/dev/null | sed 's/^/ERROR| /'
    exit 2
  }
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

sub="${1:-}"
case "$sub" in
  init|next|start|finish|note|add|ack-rules|mark-converged|release-state|cancel|reset)
    [ -n "${CR_REVIEW_LOCK_HELD:-}" ] || with_branch_lock "$@" ;;
esac
[ $# -gt 0 ] && shift
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
  ack-rules) cmd_ack_rules "$@" ;;
  mark-converged) cmd_mark_converged "$@" ;;
  release-state) cmd_release_state "$@" ;;
  cancel) cmd_cancel "$@" ;;
  reset) cmd_reset "$@" ;;
  paths) cmd_paths "$@" ;;
  tree-clean) cmd_tree_clean "$@" ;;
  ''|-h|--help|help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$sub' (try --help)" ;;
esac
