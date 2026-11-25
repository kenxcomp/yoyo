#!/usr/bin/env bash
# t3-cr-state.sh — configuration, branch state machine, active-round CAS coordinator,
# and findings ledger for the t3-cr-loop T3 Code plugin (v1.0.0).
#
# Subcommands:
#   config-path
#   config-show [--capabilities FILE] [--override-model PROV/MODEL] [--override-effort VAL]
#               [--override-council SPEC] [--single PROV/MODEL[:EFFORT]] [--ignore-project-config]
#   config-set [--file FILE]                       (reads JSON from FILE or stdin)
#   config-authorize-provider PROVIDER_INSTANCE_ID
#   init [--ignore-project-config|--use-project-config]
#   next [--base REF] [--purpose P] [--clean-streak N] [--ignore-project-config]
#   prepare --purpose P --mode M --base REF [--since SHA] --slots S1,S2 --owner THREAD_ID [--ignore-project-config]
#   claim-slot ROUND_DIR --slot S --attempt K --owner T --provider P --model M --options-json J
#   record-dispatch ROUND_DIR --slot S --attempt K --owner T --task-id TID --child-thread-id CTID [--child-run-id CRID]
#   update-slot ROUND_DIR --slot S --attempt K --owner T --state ST [--reason R]
#   record-result ROUND_DIR --slot S --attempt K --owner T [--task-id TID] --input RAW_FILE
#   round-summary [ROUND_DIR]
#   cancel-round ROUND_DIR --owner T [--reason R]
#   finish ROUND_DIR [--merged MERGED_JSON] [--dismissed-findings FILE] [--partial-approved REASON] [--ignore-project-config]
#   ack-rules FP [--base REF] [--ignore-project-config] [NOTE...]
#   mark-converged [--post-rebase] [--base REF] [--round ROUND_DIR] [--ignore-project-config]
#   release-state get | set KEY=VAL... | clear
#   note TEXT...
#   add SEVERITY TITLE [DETAIL]
#   reset | paths | tree-clean
#
# State lives outside the working tree under:
#   $(git rev-parse --git-common-dir)/t3-cr-loop/<branch-key>/{state,ledger.md,rounds/}
# User config lives at:
#   ${T3_CR_LOOP_CONFIG:-$HOME/.config/t3-cr-loop/config.json}
# Optional project override:
#   <repo-root>/.t3-cr-loop.json
#
# Compatible with macOS bash 3.2.

set -u

SELF_VERSION="1.0.0"
HERE=$(cd "$(dirname "$0")" && pwd -P)
RULES="$HERE/review-rules.sh"
PARSER="$HERE/parse-review.pl"
# shellcheck source=cr-tx.sh
. "$HERE/cr-tx.sh"

die() { printf 't3-cr-state: %s\n' "$*" >&2; exit 2; }

self_path() {
  case "$0" in
    /*) printf '%s\n' "$0" ;;
    *) printf '%s/%s\n' "$(cd "$(dirname "$0")" && pwd -P)" "$(basename "$0")" ;;
  esac
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

user_config_path() {
  printf '%s\n' "${T3_CR_LOOP_CONFIG:-$HOME/.config/t3-cr-loop/config.json}"
}

# ---------------------------------------------------------------- paths ----

resolve_paths() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git work tree"
  BRANCH=$(git branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] || die "detached HEAD — check out a branch first"
  ROOT=$(git rev-parse --show-toplevel) || die "cannot resolve repository root"
  common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""
  case "$common" in
    /*) ;;
    *) common=$(git rev-parse --git-common-dir); case "$common" in /*) ;; *) common="$(pwd -P)/$common" ;; esac ;;
  esac
  common=$(cd "$common" && pwd -P) || die "cannot resolve git common dir"
  KEY=$(printf '%s' "$BRANCH" | sed 's#/#__#g; s#[^A-Za-z0-9._-]#-#g')
  STATE_DIR="$common/t3-cr-loop/$KEY"
  STATE="$STATE_DIR/state"
  LEDGER="$STATE_DIR/ledger.md"
}

sget() { [ -f "$STATE" ] || return 0; sed -n "s/^$1=//p" "$STATE" | tail -n 1; }
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
      printf 'rounds_started=0\nrounds_total=0\nlatest_finished_round=0\nrounds_in_cycle=0\n'
      printf 'dirty_since_step_back=0\nstep_backs_done=0\nnext_class_id=1\nclean_streak=0\n'
    } > "$tmp" && mv "$tmp" "$STATE" || { rm -f "$tmp"; die "cannot initialize $STATE"; }
  fi
  if [ ! -f "$LEDGER" ]; then
    ltmp="$LEDGER.tmp.$$"
    {
      printf '# t3-cr-loop findings ledger — %s\n\n' "$BRANCH"
      printf 'Append-only. Class ids (C1, C2, ...) are stable for this branch. Reviewers must not\n'
      printf 're-report a class listed here; a reopened class cites its id ("[C3] ...").\n'
      printf 'Author notes mark classes fixed / deferred / accepted / wontfix / codified.\n'
    } > "$ltmp" && mv "$ltmp" "$LEDGER" || { rm -f "$ltmp"; die "cannot initialize $LEDGER"; }
  fi
}

with_branch_lock() {
  resolve_paths
  lockfile="$STATE_DIR.lock"
  mkdir -p "$(dirname "$lockfile")" || die "cannot create $(dirname "$lockfile")"
  command -v perl >/dev/null 2>&1 || die "perl is required (state lock + JSON handling)"
  exec perl -MFcntl=:flock,F_SETFD -MPOSIX -e '
    my $f = shift @ARGV;
    open(my $l, ">>", $f) or do { print STDERR "t3-cr-state: cannot open lock $f: $!\n"; exit 2 };
    my $deadline = time + 30;
    until (flock($l, LOCK_EX | LOCK_NB)) {
      if (time > $deadline) { print STDERR "t3-cr-state: state lock busy for 30s: $f\n"; exit 2 }
      select(undef, undef, undef, 0.1);
    }
    if (fileno($l) != 9) { defined POSIX::dup2(fileno($l), 9) or do { print STDERR "t3-cr-state: dup2: $!\n"; exit 2 } }
    open(my $nine, "+<&=", 9) or do { print STDERR "t3-cr-state: fd 9: $!\n"; exit 2 };
    defined fcntl($nine, F_SETFD, 0) or do { print STDERR "t3-cr-state: fcntl(F_SETFD): $!\n"; exit 2 };
    $ENV{T3_CR_LOCK_HELD} = 1;
    exec @ARGV or do { print STDERR "t3-cr-state: exec: $!\n"; exit 2 };
  ' "$lockfile" bash "$(self_path)" "$@"
}

# ---------------------------------------------------------------- knobs ----

resolve_knobs() {
  rk_ign_arg="${1:-}"
  PROJECT_CONFIG_IGNORED_ACTIVE=0
  if [ "$rk_ign_arg" = "1" ]; then
    PROJECT_CONFIG_IGNORED_ACTIVE=1
  elif [ "$rk_ign_arg" = "0" ]; then
    PROJECT_CONFIG_IGNORED_ACTIVE=0
  elif [ "${T3_CR_IGNORE_PROJECT_CONFIG:-0}" = "1" ]; then
    PROJECT_CONFIG_IGNORED_ACTIVE=1
  elif [ -n "${STATE:-}" ] && [ -f "$STATE" ] && [ "$(sget ignore_project_config)" = "1" ]; then
    PROJECT_CONFIG_IGNORED_ACTIVE=1
  fi

  cfg_rc=""; cfg_sb=""; cfg_p3=""; cfg_rr=""; cfg_prar=""
  ucfg=$(user_config_path)
  pcfg=""
  if [ "$PROJECT_CONFIG_IGNORED_ACTIVE" -eq 0 ]; then
    if [ -n "${ROOT:-}" ] && [ -f "$ROOT/.t3-cr-loop.json" ]; then
      pcfg="$ROOT/.t3-cr-loop.json"
    elif git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      cand="$(git rev-parse --show-toplevel)/.t3-cr-loop.json"
      [ -f "$cand" ] && pcfg="$cand"
    fi
  fi
  if [ -f "$ucfg" ] || [ -n "$pcfg" ]; then
    kv_out=$(perl -MJSON::PP -e '
      use strict; use warnings;
      my ($u_path, $p_path) = @ARGV;
      my $J = JSON::PP->new->utf8;
      my %k;
      for my $pair ([$u_path, 0], [$p_path, 1]) {
        my ($path, $is_proj) = @$pair;
        next unless defined $path && length $path && -f $path && !-l $path;
        open(my $fh, "<:raw", $path) or next;
        local $/; my $raw = <$fh>; close $fh;
        my $j = eval { $J->decode($raw) };
        next unless defined $j && ref $j eq "HASH";
        next if $is_proj && exists $j->{authorizedProviders};
        next unless ref($j->{knobs}) eq "HASH";
        my $kh = $j->{knobs};
        if (defined $kh->{roundCap} && !ref $kh->{roundCap} && $kh->{roundCap} =~ /\A[0-9]+\z/) {
          $k{roundCap} = $kh->{roundCap};
        }
        if (defined $kh->{maxStepBacks} && !ref $kh->{maxStepBacks} && $kh->{maxStepBacks} =~ /\A[0-9]+\z/) {
          $k{maxStepBacks} = $kh->{maxStepBacks};
        }
        for my $bk (qw(skipP3 requireRebased prAutoRebase)) {
          next unless exists $kh->{$bk};
          my $v = $kh->{$bk};
          if (JSON::PP::is_bool($v)) { $k{$bk} = $v ? 1 : 0; }
          elsif (defined $v && !ref $v && ($v eq "0" || $v eq "1")) { $k{$bk} = $v; }
        }
      }
      print "RC=$k{roundCap}\n" if defined $k{roundCap};
      print "SB=$k{maxStepBacks}\n" if defined $k{maxStepBacks};
      print "P3=$k{skipP3}\n" if defined $k{skipP3};
      print "RR=$k{requireRebased}\n" if defined $k{requireRebased};
      print "PRAR=$k{prAutoRebase}\n" if defined $k{prAutoRebase};
    ' "$ucfg" "$pcfg" 2>/dev/null || true)
    cfg_rc=$(printf '%s\n' "$kv_out" | sed -n 's/^RC=//p' | tail -n 1)
    cfg_sb=$(printf '%s\n' "$kv_out" | sed -n 's/^SB=//p' | tail -n 1)
    cfg_p3=$(printf '%s\n' "$kv_out" | sed -n 's/^P3=//p' | tail -n 1)
    cfg_rr=$(printf '%s\n' "$kv_out" | sed -n 's/^RR=//p' | tail -n 1)
    cfg_prar=$(printf '%s\n' "$kv_out" | sed -n 's/^PRAR=//p' | tail -n 1)
  fi

  ROUND_CAP="${CR_LOOP_ROUND_CAP:-${cfg_rc:-3}}"
  MAX_STEP_BACKS="${CR_LOOP_MAX_STEP_BACKS:-${cfg_sb:-1}}"
  SKIP_P3="${CR_LOOP_SKIP_P3:-${cfg_p3:-1}}"
  REQUIRE_REBASED="${CR_LOOP_REQUIRE_REBASED:-${cfg_rr:-1}}"
  PR_AUTO_REBASE="${CR_PR_AUTO_REBASE:-${cfg_prar:-1}}"
  is_uint "$ROUND_CAP" || die "CR_LOOP_ROUND_CAP must be a non-negative integer (got '$ROUND_CAP')"
  is_uint "$MAX_STEP_BACKS" || die "CR_LOOP_MAX_STEP_BACKS must be a non-negative integer (got '$MAX_STEP_BACKS')"
  case "$SKIP_P3" in 0|1) ;; *) die "CR_LOOP_SKIP_P3 must be 0 or 1 (got '$SKIP_P3')" ;; esac
  case "$REQUIRE_REBASED" in 0|1) ;; *) die "CR_LOOP_REQUIRE_REBASED must be 0 or 1 (got '$REQUIRE_REBASED')" ;; esac
  case "$PR_AUTO_REBASE" in 0|1) ;; *) die "CR_PR_AUTO_REBASE must be 0 or 1 (got '$PR_AUTO_REBASE')" ;; esac
}

# --------------------------------------------------------------- config ----

cmd_config_path() {
  u=$(user_config_path)
  p=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    p="$(git rev-parse --show-toplevel)/.t3-cr-loop.json"
  fi
  printf 'USER_CONFIG=%s\nUSER_CONFIG_EXISTS=%s\n' "$u" "$([ -f "$u" ] && echo 1 || echo 0)"
  [ -n "$p" ] && printf 'PROJECT_CONFIG=%s\nPROJECT_CONFIG_EXISTS=%s\n' "$p" "$([ -f "$p" ] && echo 1 || echo 0)"
}

cmd_config_set() {
  infile=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) [ $# -ge 2 ] || die "config-set: --file requires a path"; infile="$2"; shift 2 ;;
      *) die "config-set: unknown arg $1" ;;
    esac
  done
  cfg=$(user_config_path)
  mkdir -p "$(dirname "$cfg")" || die "cannot create config dir $(dirname "$cfg")"
  tmp="$cfg.tmp.$$"
  in_tmp="$cfg.in.$$"
  if [ -n "$infile" ]; then
    [ -f "$infile" ] || die "config-set: file not found: $infile"
    cat "$infile" > "$in_tmp" || { rm -f "$in_tmp"; die "cannot copy $infile"; }
  else
    cat > "$in_tmp" || { rm -f "$in_tmp"; die "cannot read config JSON from stdin"; }
  fi
  perl -MJSON::PP -MEncode -e '
    use strict; use warnings;
    my ($f, $out) = @ARGV;
    open(my $fh, "<:raw", $f) or die "cannot read $f\n";
    local $/; my $raw = <$fh>; close $fh;
    my $src = eval { Encode::decode("UTF-8", $raw, Encode::FB_CROAK) };
    die "invalid UTF-8 JSON\n" if $@ || !defined $src;

    # Strict recursive-descent JSON parser rejecting duplicate keys & distinguishing types.
    my ($pos, $len) = (0, length($src));
    my $skip_ws = sub { $pos++ while $pos < $len && substr($src, $pos, 1) =~ /[ \t\r\n]/; };
    my ($parse_str, $parse_val);
    $parse_str = sub {
      substr($src, $pos, 1) eq "\"" or die "expected string\n";
      $pos++; my $s = "";
      while ($pos < $len) {
        my $c = substr($src, $pos, 1);
        if ($c eq "\"") { $pos++; return ["str", $s]; }
        if ($c eq "\\") {
          $pos++; $pos < $len or die "unterminated escape\n";
          my $e = substr($src, $pos++, 1);
          if    ($e eq "\"") { $s .= "\""; } elsif ($e eq "\\") { $s .= "\\"; }
          elsif ($e eq "/")  { $s .= "/"; }  elsif ($e eq "b")  { $s .= "\b"; }
          elsif ($e eq "f")  { $s .= "\f"; } elsif ($e eq "n")  { $s .= "\n"; }
          elsif ($e eq "r")  { $s .= "\r"; } elsif ($e eq "t")  { $s .= "\t"; }
          elsif ($e eq "u") {
            $pos + 4 <= $len or die "truncated \\u\n";
            my $hx = substr($src, $pos, 4); $hx =~ /\A[0-9a-fA-F]{4}\z/ or die "bad \\u\n";
            $pos += 4; my $cp = hex($hx);
            if ($cp >= 0xD800 && $cp <= 0xDBFF) {
              ($pos + 6 <= $len && substr($src, $pos, 2) eq "\\u") or die "bad surrogate\n";
              my $hx2 = substr($src, $pos + 2, 4); $hx2 =~ /\A[0-9a-fA-F]{4}\z/ or die "bad surrogate\n";
              my $cp2 = hex($hx2); ($cp2 >= 0xDC00 && $cp2 <= 0xDFFF) or die "bad surrogate\n";
              $pos += 6; $cp = 0x10000 + (($cp - 0xD800) << 10) + ($cp2 - 0xDC00);
            } elsif ($cp >= 0xDC00 && $cp <= 0xDFFF) { die "unpaired low surrogate\n"; }
            $s .= chr($cp);
          } else { die "invalid escape \\$e\n"; }
        } else {
          die "unescaped control char\n" if ord($c) < 0x20;
          $s .= $c; $pos++;
        }
      }
      die "unterminated string\n";
    };
    $parse_val = sub {
      $skip_ws->(); $pos < $len or die "unexpected EOF\n";
      my $c = substr($src, $pos, 1);
      return $parse_str->() if $c eq "\"";
      if ($c eq "{") {
        $pos++; my %o; $skip_ws->();
        if ($pos < $len && substr($src, $pos, 1) eq "}") { $pos++; return ["obj", \%o]; }
        while (1) {
          $skip_ws->();
          ($pos < $len && substr($src, $pos, 1) eq "\"") or die "expected object key\n";
          my $k = $parse_str->()->[1];
          die "duplicate JSON key '\''$k'\''\n" if exists $o{$k};
          $skip_ws->(); ($pos < $len && substr($src, $pos, 1) eq ":") or die "expected :\n";
          $pos++; $o{$k} = $parse_val->();
          $skip_ws->(); $pos < $len or die "unterminated object\n";
          my $sep = substr($src, $pos, 1);
          if ($sep eq "}") { $pos++; return ["obj", \%o]; }
          $sep eq "," or die "expected , or }\n"; $pos++;
        }
      }
      if ($c eq "[") {
        $pos++; my @a; $skip_ws->();
        if ($pos < $len && substr($src, $pos, 1) eq "]") { $pos++; return ["arr", \@a]; }
        while (1) {
          push @a, $parse_val->();
          $skip_ws->(); $pos < $len or die "unterminated array\n";
          my $sep = substr($src, $pos, 1);
          if ($sep eq "]") { $pos++; return ["arr", \@a]; }
          $sep eq "," or die "expected , or ]\n"; $pos++;
        }
      }
      if (substr($src, $pos, 4) eq "true")  { $pos += 4; return ["bool", JSON::PP::true]; }
      if (substr($src, $pos, 5) eq "false") { $pos += 5; return ["bool", JSON::PP::false]; }
      if (substr($src, $pos, 4) eq "null")  { $pos += 4; return ["null", undef]; }
      my $rest = substr($src, $pos);
      if ($rest =~ /\A(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/) {
        my $ns = $1; $pos += length($ns);
        my $is_int = ($ns =~ /\A-?(?:0|[1-9][0-9]*)\z/) ? 1 : 0;
        return ["num", 0 + $ns, $is_int];
      }
      die "invalid JSON token\n";
    };
    my $unwrap;
    $unwrap = sub {
      my ($n) = @_;
      return $n->[1] if $n->[0] eq "str" || $n->[0] eq "num" || $n->[0] eq "bool" || $n->[0] eq "null";
      return [ map { $unwrap->($_) } @{$n->[1]} ] if $n->[0] eq "arr";
      return { map { $_ => $unwrap->($n->[1]{$_}) } keys %{$n->[1]} };
    };

    my $root = $parse_val->();
    $skip_ws->(); die "trailing content after JSON\n" if $pos < $len;
    die "config root must be object\n" unless $root->[0] eq "obj";
    my $h = $root->[1];
    my %top_ok = map { $_ => 1 } qw(version authorizedProviders defaultReviewer council knobs);
    for my $k (sort keys %$h) { die "unexpected config key '\''$k'\''\n" unless $top_ok{$k}; }
    die "version must be integer 1\n" unless exists $h->{version} && $h->{version}[0] eq "num" && $h->{version}[2] && $h->{version}[1] == 1;
    die "authorizedProviders must be array\n" unless exists $h->{authorizedProviders} && $h->{authorizedProviders}[0] eq "arr";
    for my $ap (@{$h->{authorizedProviders}[1]}) {
      die "authorizedProviders entries must be non-empty strings\n" unless $ap->[0] eq "str" && $ap->[1] =~ /\S/;
    }
    my $chk_rev = sub {
      my ($node, $w) = @_;
      die "$w must be object\n" unless defined $node && $node->[0] eq "obj";
      my $rh = $node->[1];
      my %rok = map { $_ => 1 } qw(providerInstanceId model effortKey effort);
      for my $k (sort keys %$rh) { die "$w has unexpected key '\''$k'\''\n" unless $rok{$k}; }
      for my $k (qw(providerInstanceId model)) {
        die "$w.$k must be non-empty string\n" unless exists $rh->{$k} && $rh->{$k}[0] eq "str" && $rh->{$k}[1] =~ /\S/;
      }
      for my $k (qw(effortKey effort)) {
        die "$w.$k must be string\n" unless exists $rh->{$k} && $rh->{$k}[0] eq "str";
      }
      if (!length($rh->{effortKey}[1]) && length($rh->{effort}[1])) {
        die "$w.effort must be empty when effortKey is empty\n";
      }
    };
    $chk_rev->($h->{defaultReviewer}, "defaultReviewer");
    die "council must be object\n" unless exists $h->{council} && $h->{council}[0] eq "obj";
    my $ch = $h->{council}[1];
    my %cok = map { $_ => 1 } qw(effortMode unifiedEffort reviewers);
    for my $k (sort keys %$ch) { die "council has unexpected key '\''$k'\''\n" unless $cok{$k}; }
    die "council.effortMode must be unified|per-model\n"
      unless exists $ch->{effortMode} && $ch->{effortMode}[0] eq "str" && ($ch->{effortMode}[1] eq "unified" || $ch->{effortMode}[1] eq "per-model");
    my $em = $ch->{effortMode}[1];
    if (exists $ch->{unifiedEffort}) {
      die "council.unifiedEffort must be string\n" unless $ch->{unifiedEffort}[0] eq "str";
    }
    my $ue_str = (exists $ch->{unifiedEffort} && $ch->{unifiedEffort}[0] eq "str") ? $ch->{unifiedEffort}[1] : "";
    die "council.unifiedEffort required when effortMode is unified\n"
      if $em eq "unified" && !length($ue_str);
    die "council.reviewers must be non-empty array\n"
      unless exists $ch->{reviewers} && $ch->{reviewers}[0] eq "arr" && @{$ch->{reviewers}[1]} > 0;
    my $idx = 0;
    for my $rv (@{$ch->{reviewers}[1]}) {
      $idx++;
      $chk_rev->($rv, "council.reviewers[$idx]");
      if ($em eq "unified") {
        my $rh = $rv->[1];
        die "council.reviewers[$idx].effortKey must be non-empty when effortMode is unified\n"
          unless length($rh->{effortKey}[1]);
        if (length($rh->{effort}[1]) && $rh->{effort}[1] ne $ue_str) {
          die "council.reviewers[$idx].effort '\''$rh->{effort}[1]'\'' conflicts with council.unifiedEffort '\''$ue_str'\''\n";
        }
      }
    }
    if (exists $h->{knobs}) {
      die "knobs must be object\n" unless $h->{knobs}[0] eq "obj";
      my $kh = $h->{knobs}[1];
      for my $k (sort keys %$kh) {
        if ($k eq "roundCap" || $k eq "maxStepBacks") {
          die "knobs.$k must be non-negative integer\n" unless $kh->{$k}[0] eq "num" && $kh->{$k}[2] && $kh->{$k}[1] >= 0;
        } elsif ($k eq "skipP3" || $k eq "requireRebased" || $k eq "prAutoRebase") {
          my $n = $kh->{$k};
          my $ok_flag = ($n->[0] eq "bool") || ($n->[0] eq "num" && $n->[2] && ($n->[1] == 0 || $n->[1] == 1));
          die "knobs.$k must be boolean or 0/1\n" unless $ok_flag;
        } else {
          die "unknown knob '\''$k'\''\n";
        }
      }
    }

    my $j = $unwrap->($root);
    if ($j->{council}{effortMode} eq "unified") {
      my $ue = $j->{council}{unifiedEffort};
      $_->{effort} = $ue for @{$j->{council}{reviewers}};
    } else {
      delete $j->{council}{unifiedEffort};
    }
    if (ref($j->{knobs}) eq "HASH") {
      for my $bk (qw(skipP3 requireRebased prAutoRebase)) {
        if (exists $j->{knobs}{$bk} && JSON::PP::is_bool($j->{knobs}{$bk})) {
          $j->{knobs}{$bk} = $j->{knobs}{$bk} ? 1 : 0;
        }
      }
    }
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh JSON::PP->new->utf8->pretty->canonical->encode($j);
    close $oh or die "cannot close $out\n";
  ' "$in_tmp" "$tmp" || { rm -f "$in_tmp" "$tmp"; die "config-set: invalid config JSON"; }
  rm -f "$in_tmp"
  chmod 0600 "$tmp" || { rm -f "$tmp"; die "config-set: cannot chmod $tmp"; }
  mv "$tmp" "$cfg" || { rm -f "$tmp"; die "config-set: failed to write $cfg"; }
  printf 'CONFIG_SAVED=%s\n' "$cfg"
}

cmd_config_authorize_provider() {
  prov="${1:-}"
  [ -n "$prov" ] || die "config-authorize-provider: providerInstanceId required"
  cfg=$(user_config_path)
  [ -f "$cfg" ] || die "config-authorize-provider: user config missing ($cfg) — run first-time setup first"
  tmp="$cfg.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($f, $out, $p) = @ARGV;
    open(my $fh, "<:raw", $f) or die "cannot read $f\n";
    local $/; my $raw = <$fh>; close $fh;
    my $j = JSON::PP->new->utf8->decode($raw);
    $j->{authorizedProviders} ||= [];
    my %seen = map { $_ => 1 } @{$j->{authorizedProviders}};
    push @{$j->{authorizedProviders}}, $p unless $seen{$p};
    @{$j->{authorizedProviders}} = sort @{$j->{authorizedProviders}};
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh JSON::PP->new->utf8->pretty->canonical->encode($j);
    close $oh or die "cannot close $out\n";
  ' "$cfg" "$tmp" "$prov" || { rm -f "$tmp"; die "failed to update authorizedProviders"; }
  chmod 0600 "$tmp" || { rm -f "$tmp"; die "failed to chmod $tmp"; }
  mv "$tmp" "$cfg" || { rm -f "$tmp"; die "failed to replace $cfg"; }
  printf 'AUTHORIZED_PROVIDER=%s\n' "$prov"
}

cmd_config_show() {
  caps_file=""; ov_model=""; ov_effort=""; ov_council=""; ov_single=""
  ignore_proj=0
  [ "${T3_CR_IGNORE_PROJECT_CONFIG:-0}" = "1" ] && ignore_proj=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --capabilities) [ $# -ge 2 ] || die "config-show: --capabilities requires a file"; caps_file="$2"; shift 2 ;;
      --override-model) [ $# -ge 2 ] || die "config-show: --override-model requires a value"; ov_model="$2"; shift 2 ;;
      --override-effort) [ $# -ge 2 ] || die "config-show: --override-effort requires a value"; ov_effort="$2"; shift 2 ;;
      --override-council) [ $# -ge 2 ] || die "config-show: --override-council requires a value"; ov_council="$2"; shift 2 ;;
      --single) [ $# -ge 2 ] || die "config-show: --single requires a value"; ov_single="$2"; shift 2 ;;
      --ignore-project-config) ignore_proj=1; shift ;;
      --use-project-config) ignore_proj=0; shift ;;
      *) die "config-show: unknown arg $1" ;;
    esac
  done
  ucfg=$(user_config_path)
  pcfg_disk=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    cand="$(git rev-parse --show-toplevel)/.t3-cr-loop.json"
    [ -f "$cand" ] && pcfg_disk="$cand"
  fi
  pcfg=""
  [ "$ignore_proj" -eq 0 ] && pcfg="$pcfg_disk"
  if [ ! -f "$ucfg" ]; then
    printf 'CONFIGURED=0\nUSER_CONFIG=%s\n' "$ucfg"
    [ -n "$pcfg" ] && printf 'PROJECT_CONFIG=%s\n' "$pcfg"
    [ "$ignore_proj" -eq 1 ] && [ -n "$pcfg_disk" ] && printf 'PROJECT_CONFIG_IGNORED=1\n'
    return 0
  fi
  perl -MJSON::PP -MEncode -e '
    use strict; use warnings;
    my ($ucfg, $pcfg, $pcfg_disk, $ignore_proj, $caps_file, $ov_model, $ov_effort, $ov_council, $ov_single) = @ARGV;
    my $J = JSON::PP->new->utf8;

    sub parse_strict_json_file {
      my ($path) = @_;
      open(my $fh, "<:raw", $path) or die "cannot read $path\n";
      local $/; my $raw = <$fh>; close $fh;
      my $src = eval { Encode::decode("UTF-8", $raw, Encode::FB_CROAK) };
      die "invalid UTF-8 JSON in $path\n" if $@ || !defined $src;
      my ($pos, $len) = (0, length($src));
      my $skip_ws = sub { $pos++ while $pos < $len && substr($src, $pos, 1) =~ /[ \t\r\n]/; };
      my ($p_str, $p_val);
      $p_str = sub {
        substr($src, $pos, 1) eq "\"" or die "expected string in $path\n";
        $pos++; my $s = "";
        while ($pos < $len) {
          my $c = substr($src, $pos, 1);
          if ($c eq "\"") { $pos++; return ["str", $s]; }
          if ($c eq "\\") {
            $pos++; $pos < $len or die "unterminated escape in $path\n";
            my $e = substr($src, $pos++, 1);
            if    ($e eq "\"") { $s .= "\""; } elsif ($e eq "\\") { $s .= "\\"; }
            elsif ($e eq "/")  { $s .= "/"; }  elsif ($e eq "b")  { $s .= "\b"; }
            elsif ($e eq "f")  { $s .= "\f"; } elsif ($e eq "n")  { $s .= "\n"; }
            elsif ($e eq "r")  { $s .= "\r"; } elsif ($e eq "t")  { $s .= "\t"; }
            elsif ($e eq "u") {
              $pos + 4 <= $len or die "truncated \\u in $path\n";
              my $hx = substr($src, $pos, 4); $hx =~ /\A[0-9a-fA-F]{4}\z/ or die "bad \\u in $path\n";
              $pos += 4; my $cp = hex($hx);
              if ($cp >= 0xD800 && $cp <= 0xDBFF) {
                ($pos + 6 <= $len && substr($src, $pos, 2) eq "\\u") or die "bad surrogate in $path\n";
                my $hx2 = substr($src, $pos + 2, 4); $hx2 =~ /\A[0-9a-fA-F]{4}\z/ or die "bad surrogate in $path\n";
                my $cp2 = hex($hx2); ($cp2 >= 0xDC00 && $cp2 <= 0xDFFF) or die "bad surrogate in $path\n";
                $pos += 6; $cp = 0x10000 + (($cp - 0xD800) << 10) + ($cp2 - 0xDC00);
              } elsif ($cp >= 0xDC00 && $cp <= 0xDFFF) { die "unpaired low surrogate in $path\n"; }
              $s .= chr($cp);
            } else { die "invalid escape \\$e in $path\n"; }
          } else {
            die "unescaped control char in $path\n" if ord($c) < 0x20;
            $s .= $c; $pos++;
          }
        }
        die "unterminated string in $path\n";
      };
      $p_val = sub {
        $skip_ws->(); $pos < $len or die "unexpected EOF in $path\n";
        my $c = substr($src, $pos, 1);
        return $p_str->() if $c eq "\"";
        if ($c eq "{") {
          $pos++; my %o; $skip_ws->();
          if ($pos < $len && substr($src, $pos, 1) eq "}") { $pos++; return ["obj", \%o]; }
          while (1) {
            $skip_ws->();
            ($pos < $len && substr($src, $pos, 1) eq "\"") or die "expected key in $path\n";
            my $k = $p_str->()->[1];
            die "duplicate JSON key '\''$k'\'' in $path\n" if exists $o{$k};
            $skip_ws->(); ($pos < $len && substr($src, $pos, 1) eq ":") or die "expected : in $path\n";
            $pos++; $o{$k} = $p_val->();
            $skip_ws->(); $pos < $len or die "unterminated object in $path\n";
            my $sep = substr($src, $pos, 1);
            if ($sep eq "}") { $pos++; return ["obj", \%o]; }
            $sep eq "," or die "expected , or } in $path\n"; $pos++;
          }
        }
        if ($c eq "[") {
          $pos++; my @a; $skip_ws->();
          if ($pos < $len && substr($src, $pos, 1) eq "]") { $pos++; return ["arr", \@a]; }
          while (1) {
            push @a, $p_val->();
            $skip_ws->(); $pos < $len or die "unterminated array in $path\n";
            my $sep = substr($src, $pos, 1);
            if ($sep eq "]") { $pos++; return ["arr", \@a]; }
            $sep eq "," or die "expected , or ] in $path\n"; $pos++;
          }
        }
        if (substr($src, $pos, 4) eq "true")  { $pos += 4; return ["bool", JSON::PP::true]; }
        if (substr($src, $pos, 5) eq "false") { $pos += 5; return ["bool", JSON::PP::false]; }
        if (substr($src, $pos, 4) eq "null")  { $pos += 4; return ["null", undef]; }
        my $rest = substr($src, $pos);
        if ($rest =~ /\A(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/) {
          my $ns = $1; $pos += length($ns);
          my $is_int = ($ns =~ /\A-?(?:0|[1-9][0-9]*)\z/) ? 1 : 0;
          return ["num", 0 + $ns, $is_int];
        }
        die "invalid JSON in $path\n";
      };
      my $root = $p_val->();
      $skip_ws->(); die "trailing content in $path\n" if $pos < $len;
      return $root;
    }

    my $unwrap;
    $unwrap = sub {
      my ($n) = @_;
      return $n->[1] if $n->[0] eq "str" || $n->[0] eq "num" || $n->[0] eq "bool" || $n->[0] eq "null";
      return [ map { $unwrap->($_) } @{$n->[1]} ] if $n->[0] eq "arr";
      return { map { $_ => $unwrap->($n->[1]{$_}) } keys %{$n->[1]} };
    };

    my @errors;
    my $validate_cfg_typed = sub {
      my ($node, $is_proj, $prefix) = @_;
      unless (defined $node && $node->[0] eq "obj") { push @errors, "$prefix root must be JSON object"; return; }
      my $h = $node->[1];
      my %allowed = map { $_ => 1 } ($is_proj ? qw(version defaultReviewer council knobs) : qw(version authorizedProviders defaultReviewer council knobs));
      for my $k (sort keys %$h) {
        if ($is_proj && $k eq "authorizedProviders") {
          push @errors, "$prefix MUST NOT contain '\''authorizedProviders'\''";
        } elsif (!$allowed{$k}) {
          push @errors, "$prefix unexpected property '\''$k'\''";
        }
      }
      if (!$is_proj) {
        for my $rk (qw(version authorizedProviders defaultReviewer council)) {
          push @errors, "$prefix missing required key '\''$rk'\''" unless exists $h->{$rk};
        }
      }
      if (exists $h->{version} && ($h->{version}[0] ne "num" || !$h->{version}[2] || $h->{version}[1] != 1)) {
        push @errors, "$prefix version must be integer 1";
      }
      if (!$is_proj && exists $h->{authorizedProviders}) {
        if ($h->{authorizedProviders}[0] ne "arr") { push @errors, "$prefix authorizedProviders must be array"; }
        else {
          for my $el (@{$h->{authorizedProviders}[1]}) {
            push @errors, "$prefix authorizedProviders entry must be non-empty string" unless $el->[0] eq "str" && $el->[1] =~ /\S/;
          }
        }
      }
      my $chk_r = sub {
        my ($n, $lbl) = @_;
        unless ($n && $n->[0] eq "obj") { push @errors, "$prefix $lbl must be object"; return; }
        my $rh = $n->[1];
        my %ok = map { $_ => 1 } qw(providerInstanceId model effortKey effort);
        for my $k (sort keys %$rh) { push @errors, "$prefix $lbl unexpected property '\''$k'\''" unless $ok{$k}; }
        for my $k (qw(providerInstanceId model)) {
          push @errors, "$prefix $lbl.$k must be non-empty string" unless exists $rh->{$k} && $rh->{$k}[0] eq "str" && $rh->{$k}[1] =~ /\S/;
        }
        for my $k (qw(effortKey effort)) {
          push @errors, "$prefix $lbl.$k must be string" unless exists $rh->{$k} && $rh->{$k}[0] eq "str";
        }
        if (exists $rh->{effortKey} && $rh->{effortKey}[0] eq "str" && !length($rh->{effortKey}[1]) &&
            exists $rh->{effort} && $rh->{effort}[0] eq "str" && length($rh->{effort}[1])) {
          push @errors, "$prefix $lbl.effort must be empty when effortKey is empty";
        }
      };
      $chk_r->($h->{defaultReviewer}, "defaultReviewer") if exists $h->{defaultReviewer};
      if (exists $h->{council}) {
        if ($h->{council}[0] ne "obj") { push @errors, "$prefix council must be object"; }
        else {
          my $ch = $h->{council}[1];
          my %cok = map { $_ => 1 } qw(effortMode unifiedEffort reviewers);
          for my $k (sort keys %$ch) { push @errors, "$prefix council unexpected property '\''$k'\''" unless $cok{$k}; }
          if (!exists $ch->{effortMode} || $ch->{effortMode}[0] ne "str" || ($ch->{effortMode}[1] ne "unified" && $ch->{effortMode}[1] ne "per-model")) {
            push @errors, "$prefix council.effortMode must be unified|per-model";
          }
          if (exists $ch->{unifiedEffort} && $ch->{unifiedEffort}[0] ne "str") {
            push @errors, "$prefix council.unifiedEffort must be string";
          }
          my $is_unif = (exists $ch->{effortMode} && $ch->{effortMode}[0] eq "str" && $ch->{effortMode}[1] eq "unified") ? 1 : 0;
          my $ue_val  = (exists $ch->{unifiedEffort} && $ch->{unifiedEffort}[0] eq "str") ? $ch->{unifiedEffort}[1] : "";
          if ($is_unif && !length($ue_val)) {
            push @errors, "$prefix council.unifiedEffort required when effortMode is unified";
          }
          if (!exists $ch->{reviewers} || $ch->{reviewers}[0] ne "arr" || !@{$ch->{reviewers}[1]}) {
            push @errors, "$prefix council.reviewers must be non-empty array";
          } else {
            my $i = 0;
            for my $rv (@{$ch->{reviewers}[1]}) {
              $i++;
              $chk_r->($rv, "council.reviewers[$i]");
              if ($is_unif && $rv && $rv->[0] eq "obj") {
                my $rh = $rv->[1];
                if (exists $rh->{effortKey} && $rh->{effortKey}[0] eq "str" && !length($rh->{effortKey}[1])) {
                  push @errors, "$prefix council.reviewers[$i].effortKey must be non-empty when effortMode is unified";
                }
                if (length($ue_val) && exists $rh->{effort} && $rh->{effort}[0] eq "str" && length($rh->{effort}[1]) && $rh->{effort}[1] ne $ue_val) {
                  push @errors, "$prefix council.reviewers[$i].effort '\''$rh->{effort}[1]'\'' conflicts with unifiedEffort '\''$ue_val'\''";
                }
              }
            }
          }
        }
      }
      if (exists $h->{knobs}) {
        if ($h->{knobs}[0] ne "obj") { push @errors, "$prefix knobs must be object"; }
        else {
          my $kh = $h->{knobs}[1];
          for my $k (sort keys %$kh) {
            if ($k eq "roundCap" || $k eq "maxStepBacks") {
              push @errors, "$prefix knobs.$k must be non-negative integer" unless $kh->{$k}[0] eq "num" && $kh->{$k}[2] && $kh->{$k}[1] >= 0;
            } elsif ($k eq "skipP3" || $k eq "requireRebased" || $k eq "prAutoRebase") {
              my $n = $kh->{$k};
              my $ok_flag = ($n->[0] eq "bool") || ($n->[0] eq "num" && $n->[2] && ($n->[1] == 0 || $n->[1] == 1));
              push @errors, "$prefix knobs.$k must be boolean or 0/1" unless $ok_flag;
            } else {
              push @errors, "$prefix unknown knob '\''$k'\''";
            }
          }
        }
      }
    };

    my $u_typed = eval { parse_strict_json_file($ucfg) };
    if ($@) { chomp $@; print "CONFIGURED=1\nCONFIG_VALID=0\nCONFIG_ERROR=$@\n"; exit 3; }
    $validate_cfg_typed->($u_typed, 0, "user config:");
    my $p_typed;
    if (length $pcfg && -f $pcfg) {
      $p_typed = eval { parse_strict_json_file($pcfg) };
      if ($@) { chomp $@; print "CONFIGURED=1\nCONFIG_VALID=0\nCONFIG_ERROR=$@\n"; exit 3; }
      $validate_cfg_typed->($p_typed, 1, "project config:");
    }
    if (@errors) {
      print "CONFIGURED=1\nCONFIG_VALID=0\n";
      print "CONFIG_ERROR=$_\n" for @errors;
      exit 3;
    }

    my $u = $unwrap->($u_typed);
    my $p = $p_typed ? $unwrap->($p_typed) : undef;
    my %auth = map { $_ => 1 } @{$u->{authorizedProviders} || []};

    if (length($ov_single) && (length($ov_model) || length($ov_council))) {
      push @errors, "--single conflicts with --override-model and --override-council";
    }

    my $def = { %{$u->{defaultReviewer}} };
    my $council = {
      effortMode => $u->{council}{effortMode},
      (defined($u->{council}{unifiedEffort}) && length($u->{council}{unifiedEffort}) ? (unifiedEffort => $u->{council}{unifiedEffort}) : ()),
      reviewers  => [ map { { %$_ } } @{$u->{council}{reviewers}} ],
    };
    my $knobs = { %{$u->{knobs} || {}} };

    my $proj_overrode = 0;
    my %proj_providers;
    if ($p) {
      if ($p->{defaultReviewer}) {
        $proj_overrode = 1;
        $def = { %{$p->{defaultReviewer}} };
        $proj_providers{$def->{providerInstanceId}} = 1;
      }
      if ($p->{council}) {
        $proj_overrode = 1;
        $council = {
          effortMode => $p->{council}{effortMode},
          (defined($p->{council}{unifiedEffort}) && length($p->{council}{unifiedEffort}) ? (unifiedEffort => $p->{council}{unifiedEffort}) : ()),
          reviewers  => [ map { { %$_ } } @{$p->{council}{reviewers}} ],
        };
        $proj_providers{$_->{providerInstanceId}} = 1 for @{$council->{reviewers}};
      }
      if ($p->{knobs} && ref $p->{knobs} eq "HASH") {
        $proj_overrode = 1;
        for my $k (keys %{$p->{knobs}}) { $knobs->{$k} = $p->{knobs}{$k}; }
      }
    }

    # Build live capability lookup if provided.
    my (%cap_prov, %cap_model);
    my $caps_loaded = 0;
    my $inherited_pid = "";
    if (length $caps_file) {
      my $caps = eval {
        open(my $cfh, "<:raw", $caps_file) or die "cannot read $caps_file\n";
        local $/; my $cr = <$cfh>; close $cfh;
        $J->decode($cr);
      };
      if ($@ || ref $caps ne "HASH" || (exists $caps->{providers} && ref $caps->{providers} ne "ARRAY")) {
        push @errors, "cannot parse --capabilities JSON: $caps_file";
      } else {
        $caps_loaded = 1;
        $inherited_pid = $caps->{inheritedProviderInstanceId} // "";
        for my $pr (@{$caps->{providers} || []}) {
          my $pid = $pr->{providerInstanceId} // next;
          $cap_prov{$pid} = $pr;
          for my $m (@{$pr->{models} || []}) {
            my $mid = $m->{id} // next;
            my ($ek, $evals, $edef) = ("", [], "");
            for my $o (@{$m->{options} || []}) {
              if (($o->{id} // "") =~ /\A(thought_level|effort|reasoningEffort)\z/) {
                $ek = $o->{id};
                $evals = $o->{values} || [];
                $edef = $o->{default} // "";
                last;
              }
            }
            $cap_model{"$pid/$mid"} = {
              providerInstanceId           => $pid,
              driverKind                   => $pr->{driverKind} // $pid,
              model                        => $mid,
              canRunChildTask              => $pr->{canRunChildTask} ? 1 : 0,
              canRunCrossProviderChildTask => defined($pr->{canRunCrossProviderChildTask})
                ? ($pr->{canRunCrossProviderChildTask} ? 1 : 0)
                : ($pr->{canRunChildTask} ? 1 : 0),
              effortKey                    => $ek,
              effortValues                 => $evals,
              effortDefault                => $edef,
            };
          }
        }
      }
    }

    my $parse_spec = sub {
      my ($spec, $fallback_effort, $label) = @_;
      my ($left, $inline_eff) = split(/:/, $spec, 2);
      my $has_inline = (defined $inline_eff && length $inline_eff) ? 1 : 0;
      my $eff = $has_inline ? $inline_eff : ($fallback_effort // "");
      my ($pid, $mid);
      if ($left =~ m{\A([^/]+)/(.+)\z}) { ($pid, $mid) = ($1, $2); }
      else {
        $mid = $left;
        my @hits = grep { $cap_model{$_}{model} eq $mid && $cap_model{$_}{canRunChildTask} } sort keys %cap_model;
        if (@hits == 1) { $pid = $cap_model{$hits[0]}{providerInstanceId}; }
        elsif (@hits > 1) { push @errors, "$label ambiguous model id '\''$mid'\'' across providers — specify providerInstanceId/model"; return (undef, 0); }
        else { push @errors, "$label cannot resolve provider for model '\''$mid'\'' (specify providerInstanceId/model or pass --capabilities)"; return (undef, 0); }
      }
      my $ek = (exists $cap_model{"$pid/$mid"}) ? $cap_model{"$pid/$mid"}{effortKey} : "";
      return ({ providerInstanceId => $pid, model => $mid, effortKey => $ek, effort => $eff }, $has_inline);
    };

    my %user_override_providers;
    if (length $ov_single) {
      my ($r) = $parse_spec->($ov_single, $ov_effort, "single");
      if ($r) {
        $def = { %$r };
        $council = { effortMode => "per-model", reviewers => [ { %$r } ] };
        $user_override_providers{$r->{providerInstanceId}} = 1;
      }
    } else {
      if (length $ov_model) {
        my ($r) = $parse_spec->($ov_model, (length $ov_effort ? $ov_effort : $def->{effort}), "model");
        if ($r) {
          $def = $r;
          $user_override_providers{$r->{providerInstanceId}} = 1;
        }
      } elsif (length $ov_effort) {
        $def->{effort} = $ov_effort;
      }
      if (length $ov_council) {
        my (@revs, $any_inline);
        $any_inline = 0;
        for my $tok (split(/,/, $ov_council)) {
          $tok =~ s/^\s+|\s+$//g;
          next unless length $tok;
          my ($rv, $hi) = $parse_spec->($tok, $ov_effort, "council");
          next unless $rv;
          $any_inline = 1 if $hi;
          $user_override_providers{$rv->{providerInstanceId}} = 1;
          push @revs, $rv;
        }
        if (!@revs) { push @errors, "--override-council produced no reviewers"; }
        else {
          my $emode = (!$any_inline && length($ov_effort)) ? "unified" : "per-model";
          $council = {
            effortMode => $emode,
            ($emode eq "unified" ? (unifiedEffort => $ov_effort) : ()),
            reviewers  => \@revs,
          };
        }
      } elsif (length($ov_effort) && !length($ov_model) && ($council->{effortMode} // "") eq "unified") {
        $council->{unifiedEffort} = $ov_effort;
      }
    }

    # Actively apply unifiedEffort onto EVERY council reviewer!
    if (($council->{effortMode} // "") eq "unified") {
      my $ue = $council->{unifiedEffort} // "";
      if (!length $ue) {
        push @errors, "council has effortMode=unified without unifiedEffort";
      } else {
        $_->{effort} = $ue for @{$council->{reviewers}};
      }
    }

    # Validate against live capabilities if supplied (even if providers/models list is empty!).
    if ($caps_loaded) {
      my $check_one = sub {
        my ($rv, $label) = @_;
        my $key = "$rv->{providerInstanceId}/$rv->{model}";
        my $cm = $cap_model{$key};
        if (!$cm) { push @errors, "$label model $key not found in capabilities (use orchestrator_capabilities search if omitted)"; return; }
        if (!$cm->{canRunChildTask}) { push @errors, "$label provider $rv->{providerInstanceId} is disabled or cannot run child tasks"; return; }
        if (length($inherited_pid) && $rv->{providerInstanceId} ne $inherited_pid && !$cm->{canRunCrossProviderChildTask}) {
          push @errors, "$label provider $rv->{providerInstanceId} cannot run cross-provider child tasks from '\''$inherited_pid'\''";
          return;
        }
        $rv->{effortKey}  = $cm->{effortKey};
        $rv->{driverKind} = $cm->{driverKind};
        if (length $rv->{effortKey}) {
          $rv->{effort} = $cm->{effortDefault} if !length($rv->{effort} // "");
          my %okv = map { $_ => 1 } @{$cm->{effortValues}};
          if (!$okv{$rv->{effort}}) {
            push @errors, "$label effort '\''$rv->{effort}'\'' invalid for $key ($rv->{effortKey} allows: " . join(",", @{$cm->{effortValues}}) . ")";
          }
        } elsif (length($rv->{effort} // "")) {
          push @errors, "$label model $key does not support effort options (got effort '\''$rv->{effort}'\'')";
        }
      };
      $check_one->($def, "defaultReviewer");
      my $ci = 0;
      for my $rv (@{$council->{reviewers}}) { $ci++; $check_one->($rv, "council[$ci]"); }
      if (($council->{effortMode} // "") eq "unified" && length($council->{unifiedEffort} // "")) {
        my $ue = $council->{unifiedEffort};
        for my $rv (@{$council->{reviewers}}) {
          my $cm = $cap_model{"$rv->{providerInstanceId}/$rv->{model}"} or next;
          my %okv = map { $_ => 1 } @{$cm->{effortValues}};
          if (!$okv{$ue}) {
            push @errors, "unified effort '\''$ue'\'' is not in the intersection supported by $rv->{providerInstanceId}/$rv->{model}";
          }
        }
      }
    }

    if (@errors) {
      print "CONFIGURED=1\nCONFIG_VALID=0\n";
      print "CONFIG_ERROR=$_\n" for @errors;
      exit 3;
    }

    # Compute unauthorized project-introduced providers AFTER per-call overrides!
    my %effective_pids;
    $effective_pids{$def->{providerInstanceId}} = 1;
    $effective_pids{$_->{providerInstanceId}} = 1 for @{$council->{reviewers}};
    my @unauth = sort grep { $proj_providers{$_} && !$auth{$_} && !$user_override_providers{$_} } keys %effective_pids;

    sub opts_json {
      my ($rv) = @_;
      return "{}" unless length($rv->{effortKey} // "") && length($rv->{effort} // "");
      return $J->encode({ $rv->{effortKey} => $rv->{effort} });
    }

    print "CONFIGURED=1\nCONFIG_VALID=1\n";
    print "USER_CONFIG=$ucfg\n";
    print "PROJECT_CONFIG=$pcfg\n" if length $pcfg;
    print "PROJECT_CONFIG_IGNORED=1\n" if $ignore_proj && length $pcfg_disk;
    print "PROJECT_OVERRIDDEN=$proj_overrode\n";
    print "NEEDS_PROVIDER_AUTH=" . (@unauth ? 1 : 0) . "\n";
    print "UNAUTHORIZED_PROVIDERS=" . join(",", @unauth) . "\n" if @unauth;
    print "DEFAULT_PROVIDER=$def->{providerInstanceId}\n";
    print "DEFAULT_MODEL=$def->{model}\n";
    print "DEFAULT_EFFORT_KEY=$def->{effortKey}\n";
    print "DEFAULT_EFFORT=$def->{effort}\n";
    print "DEFAULT_OPTIONS_JSON=" . opts_json($def) . "\n";
    print "COUNCIL_EFFORT_MODE=$council->{effortMode}\n";
    print "COUNCIL_COUNT=" . scalar(@{$council->{reviewers}}) . "\n";
    my $idx = 0;
    for my $rv (@{$council->{reviewers}}) {
      $idx++;
      printf "COUNCIL_SLOT_%d=%s|%s|%s|%s|%s\n",
        $idx, $rv->{providerInstanceId}, $rv->{model}, $rv->{effortKey}, $rv->{effort}, opts_json($rv);
    }
    for my $k (sort keys %$knobs) {
      my $val = $knobs->{$k};
      $val = ($val ? 1 : 0) if JSON::PP::is_bool($val);
      print "KNOB_$k=$val\n";
    }
  ' "$ucfg" "$pcfg" "$pcfg_disk" "$ignore_proj" "$caps_file" "$ov_model" "$ov_effort" "$ov_council" "$ov_single"
}

# ------------------------------------------------------------- snapshots ----

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

mget() { sed -n "s/^$2=//p" "$1/meta" | tail -n 1; }

head_moves() {
  tmp=$(mktemp "${TMPDIR:-/tmp}/t3cr-hm.XXXXXX") || return 1
  if ! git -C "$ROOT" reflog show --format=%H HEAD > "$tmp" 2>/dev/null; then
    rm -f "$tmp"; return 1
  fi
  cnt=$(wc -l < "$tmp" | tr -d ' ')
  rm -f "$tmp"
  is_uint "$cnt" || return 1
  printf '%s\n' "$cnt"
}

tree_fp_v2() {
  tdiff=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2d.XXXXXX") || return 1
  tidx=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2i.XXXXXX") || { rm -f "$tdiff"; return 1; }
  twt=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2w.XXXXXX") || { rm -f "$tdiff" "$tidx"; return 1; }
  tuntr=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2u.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt"; return 1; }
  tstage=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2s.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr"; return 1; }
  tman=$(mktemp "${TMPDIR:-/tmp}/t3cr-tf2m.XXXXXX") || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage"; return 1; }
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
    use strict; use warnings;
    my ($root, $dh, $ih, $wh, $untr_file, $stage_file, $man_file) = @ARGV;

    sub run_git_raw {
      my ($dir, @args) = @_;
      open(my $ph, "-|", "git", "-C", $dir, @args) or return (1, "");
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
      my ($rc_h, $sh) = run_git_raw($dir, "rev-parse", "--verify", "HEAD");
      $sh =~ s/\s+//g;
      if ($rc_h != 0 || !length $sh) {
        my ($rc_sym) = run_git_raw($dir, "symbolic-ref", "-q", "HEAD");
        exit 1 unless $rc_sym == 0;
        $sh = "UNBORN";
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
      next if $p eq "" || $p =~ /^\.cr-loop-handoff-round-[0-9]+\.md$/;
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
        my $tgt = readlink($full); defined $tgt or exit 1;
        my $et = $tgt; $et =~ s/\\/\\\\/g; $et =~ s/\n/\\n/g; $et =~ s/\t/\\t/g;
        print $mf "link\t$ep\t$et\n";
      } elsif (-f $full) {
        open(my $hf, "-|", "git", "-C", $root, "hash-object", "--no-filters", "--", $full) or exit 1;
        my $oid = <$hf>; close $hf or exit 1;
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
      } else { print $mf "other\t$ep\n"; }
    }
    close $mf or exit 1;
  ' "$ROOT" "$dh" "$ih" "$wh" "$tuntr" "$tstage" "$tman" || { rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"; return 1; }
  vh=$(git -C "$ROOT" hash-object --stdin < "$tman" 2>/dev/null)
  rc=$?
  rm -f "$tdiff" "$tidx" "$twt" "$tuntr" "$tstage" "$tman"
  [ "$rc" -eq 0 ] && [ -n "$vh" ] || return 1
  printf 'v2:%s\n' "$vh"
}

compute_recurring() {
  perl -e '
    use strict; use warnings;
    my ($f) = @ARGV;
    open(my $fh, "<:encoding(UTF-8)", $f) or exit 0;
    my @lines = <$fh>; close $fh;
    my $start = 0;
    for (my $i = 0; $i < @lines; $i++) { $start = $i + 1 if $lines[$i] =~ /^## Converged\b/; }
    my ($in_round, %round_seen, %counts) = (0);
    for (my $i = $start; $i < @lines; $i++) {
      my $l = $lines[$i];
      if ($l =~ /^## Round /) { $in_round = 1; %round_seen = (); }
      elsif ($l =~ /^## /) { $in_round = 0; }
      elsif ($in_round && $l =~ /^### (C\d+)\b/) { $counts{$1}++ unless $round_seen{$1}++; }
    }
    my @rec = sort { my ($a1)=($a=~/(\d+)/); my ($b1)=($b=~/(\d+)/); $a1 <=> $b1 }
      grep { $counts{$_} >= 2 } keys %counts;
    print join(",", @rec);
  ' "$1"
}

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

# ----------------------------------------------------------- subcommands ----

cmd_init() {
  resolve_paths; ensure_state
  ign_set=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ignore-project-config) ign_set=1; shift ;;
      --use-project-config) ign_set=0; shift ;;
      *) die "init: unknown arg $1" ;;
    esac
  done
  if [ -n "$ign_set" ]; then
    [ ! -L "$STATE" ] && [ ! -d "$STATE" ] || die "init: invalid state target $STATE"
    stmp="$STATE.tmp.$$"
    build_state_file "$stmp" "ignore_project_config=$ign_set"
    mv "$stmp" "$STATE" || { rm -f "$stmp"; die "init: failed saving ignore_project_config"; }
  fi
  resolve_knobs "$ign_set"
  conv_head=$(sget post_rebase_confirmed_head); conv_base=$(sget post_rebase_confirmed_base_sha)
  if [ -z "$conv_head" ]; then conv_head=$(sget base_converged_head); conv_base=$(sget base_converged_base_sha); fi
  ucfg=$(user_config_path)
  printf 'T3_CR_VERSION=%s\nBRANCH=%s\nSTATE_DIR=%s\nLEDGER=%s\n' "$SELF_VERSION" "$BRANCH" "$STATE_DIR" "$LEDGER"
  printf 'USER_CONFIG=%s\nCONFIGURED=%s\nPROJECT_CONFIG_IGNORED=%s\n' "$ucfg" "$([ -f "$ucfg" ] && echo 1 || echo 0)" "$PROJECT_CONFIG_IGNORED_ACTIVE"
  printf 'ROUND_CAP=%s\nMAX_STEP_BACKS=%s\nSKIP_P3=%s\nREQUIRE_REBASED=%s\nPR_AUTO_REBASE=%s\n' \
    "$ROUND_CAP" "$MAX_STEP_BACKS" "$SKIP_P3" "$REQUIRE_REBASED" "$PR_AUTO_REBASE"
  printf 'ROUNDS_TOTAL=%s\nROUNDS_IN_CYCLE=%s\nDIRTY_SINCE_STEP_BACK=%s\nSTEP_BACKS_DONE=%s\n' \
    "$(snum rounds_total)" "$(snum rounds_in_cycle)" "$(snum dirty_since_step_back)" "$(snum step_backs_done)"
  printf 'CLEAN_STREAK=%s\nLAST_CLEAN_HEAD=%s\nLAST_CLEAN_MODE=%s\nLAST_REVIEWED_HEAD=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\nCLASSES=%s\n' \
    "$(snum clean_streak)" "$(sget last_clean_head)" "$(sget last_clean_mode)" "$(sget last_reviewed_head)" "$conv_head" "$conv_base" "$(( $(snum next_class_id) - 1 ))"
  ar=$(sget active_round_dir)
  if [ -n "$ar" ] && [ -d "$ar" ]; then printf 'ACTIVE_ROUND=%s\n' "$ar"; fi
  return 0
}

cmd_next() {
  resolve_paths; ensure_state
  base_arg=""; purpose_arg=""; cs_explicit=0; cs=0; ign_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || die "next: --base requires a value"; base_arg="$2"; shift 2 ;;
      --purpose) [ $# -ge 2 ] || die "next: --purpose requires a value"; purpose_arg="$2"; shift 2 ;;
      --clean-streak) [ $# -ge 2 ] || die "next: --clean-streak requires a value"; cs_explicit=1; cs="$2"; shift 2 ;;
      --ignore-project-config) ign_arg=1; shift ;;
      --use-project-config) ign_arg=0; shift ;;
      *) die "next: unknown arg $1" ;;
    esac
  done
  resolve_knobs "$ign_arg"
  is_uint "$cs" || die "--clean-streak must be an integer"
  head=$(git rev-parse HEAD) || die "next: cannot resolve HEAD"
  base_sha=""
  if [ -n "$base_arg" ]; then
    base_sha=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "next: --base '$base_arg' does not resolve"
  fi

  # Priority 1: pending active_round exists
  ar=$(sget active_round_dir)
  if [ -n "$ar" ] && [ -d "$ar" ] && [ ! -f "$ar/finished" ]; then
    printf 'PURPOSE=resume\nROUND_DIR=%s\nREASON=active round in progress — resume or cancel before starting another\n' "$ar"
    return 0
  fi

  # Priority 2: explicit post-rebase confirmation
  if [ "$purpose_arg" = "post-rebase-confirmation" ]; then
    printf 'PURPOSE=post-rebase-confirmation\nMODE=full\nPROFILE=default\nREASON=single full confirmation round after PR 8.0 rebase\n'
    return 0
  fi

  if [ "$cs_explicit" -eq 0 ]; then
    cs=$(effective_persisted_streak "$head" "$base_sha")
  fi
  dsb=$(snum dirty_since_step_back); sbd=$(snum step_backs_done)
  ric=$(snum rounds_in_cycle)
  last=$(sget last_reviewed_head); lrb=$(sget last_reviewed_base_sha)
  lcm=$(sget last_clean_mode)
  bch=$(sget base_converged_head); bcb=$(sget base_converged_base_sha); bcp=$(sget base_converged_skip_p3)

  # Priority 3: already converged on this exact HEAD/base/policy
  if [ "$cs_explicit" -eq 0 ]; then
    if [ "$cs" -ge 2 ] && [ "$lcm" = "full" ]; then
      printf 'PURPOSE=converged\nMODE=converged\nCLEAN_STREAK=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\nREASON=already converged on this HEAD/base/policy\n' \
        "$cs" "$head" "$(sget last_clean_base_sha)"
      return 0
    fi
    if [ -n "$bch" ] && [ "$bch" = "$head" ] && [ "$bcp" = "$SKIP_P3" ] && { [ -z "$base_sha" ] || [ "$bcb" = "$base_sha" ]; }; then
      printf 'PURPOSE=converged\nMODE=converged\nCLEAN_STREAK=%s\nCONVERGED_HEAD=%s\nCONVERGED_BASE_SHA=%s\nREASON=recorded convergence already holds for this HEAD/base/policy\n' \
        "$cs" "$bch" "$bcb"
      return 0
    fi
  fi

  # Priority 4: round cap -> step-back (council) or stop
  if [ "$ROUND_CAP" -gt 0 ] && [ "$dsb" -ge "$ROUND_CAP" ]; then
    if [ "$sbd" -lt "$MAX_STEP_BACKS" ]; then
      printf 'PURPOSE=step-back\nMODE=step-back\nPROFILE=council\nREASON=%s dirty rounds since last step-back (cap %s)\n' "$dsb" "$ROUND_CAP"
    else
      printf 'PURPOSE=stop\nMODE=stop\nREASON=step-back-exhausted (%s/%s step-backs used, %s dirty rounds since)\n' "$sbd" "$MAX_STEP_BACKS" "$dsb"
    fi
    return 0
  fi

  # Priority 5: 2nd-round confirmation on same HEAD (default single model)
  if [ "$cs" -ge 1 ]; then
    printf 'PURPOSE=confirmation-full\nMODE=full\nPROFILE=default\nREASON=confirmation round on the same HEAD (whole diff + ledger)\n'
    return 0
  fi

  # Priority 6: new convergence cycle, material base switch, or last_reviewed_head lost ancestry -> initial-full (council)
  if [ "$ric" -eq 0 ] || [ -z "$last" ] || { [ -n "$base_sha" ] && [ -n "$lrb" ] && [ "$lrb" != "$base_sha" ]; } || ! git merge-base --is-ancestor "$last" "$head" 2>/dev/null; then
    printf 'PURPOSE=initial-full\nMODE=full\nPROFILE=council\nREASON=new convergence cycle, base switch, or rewritten history\n'
    return 0
  fi

  # Priority 7: same HEAD after a dirty/unacked round with no new commit
  if [ "$last" = "$head" ]; then
    printf 'PURPOSE=full\nMODE=full\nPROFILE=default\nREASON=HEAD unchanged since last dirty/unacked round\n'
    return 0
  fi

  # Priority 8: last_reviewed_head is strict ancestor of HEAD -> incremental (default single model)
  printf 'PURPOSE=incremental\nMODE=incremental\nPROFILE=default\nSINCE=%s\nREASON=changes since last reviewed head\n' "$last"
}

write_prompt() {
  d="$1"; purpose="$2"; mode="$3"; base_ref="$4"; base_sha="$5"; head="$6"; since="$7"; n="$8"
  dsb=$(snum dirty_since_step_back); sbd=$(snum step_backs_done)
  p="$d/prompt.md"
  {
    printf 'You are an independent read-only code reviewer in an automated T3 Code review loop (t3-cr-loop %s).\n' "$SELF_VERSION"
    printf 'Repository root: %s\nBranch: %s\nReview base: %s (%s)\nReviewed HEAD: %s\nRound: %s   Purpose: %s   Mode: %s\n\n' \
      "$ROOT" "$BRANCH" "$base_ref" "$base_sha" "$head" "$n" "$purpose" "$mode"
    printf 'READ-ONLY CONTRACT\n'
    printf -- '- Do NOT modify, create, or delete any file in the repository or working tree.\n'
    printf -- '- Do NOT run git write commands (commit, rebase, checkout, reset, stash, etc.) and do NOT spawn subagents.\n\n'
    printf 'SCOPE\n'
    case "$mode" in
      incremental)
        printf -- '- Review ONLY the changes since the last reviewed head: `git diff %s..%s`.\n' "$since" "$head"
        printf -- '  Read surrounding code for context only; do not rescan the rest of the branch.\n'
        printf -- '- Report (a) defects introduced here and (b) ledger classes whose fix is incomplete or regressed, citing all remaining instances.\n'
        ;;
      step-back)
        printf -- '- This branch has had %s dirty rounds since the last step-back (%s step-back(s) so far). Point fixes are not converging.\n' "$dsb" "$sbd"
        printf -- '- Review the whole branch diff `git diff %s...%s` together with the FULL ledger.\n' "$base_sha" "$head"
        printf -- '- Main job: (1) identify RECURRING bug classes behind the ledger entries; (2) explain why the current approach structurally invites each;\n'
        printf -- '  (3) propose the structural approach change (single source of truth, ownership, invariant, API shape) plus prevention artifact in step_back[],\n'
        printf -- '  and list still-present instances in findings[].\n'
        ;;
      *)
        printf -- '- Review the whole branch diff `git diff %s...%s` (start with --stat, then inspect hunks and needed context).\n' "$base_sha" "$head"
        printf -- '- If the ledger already lists classes, also check for cross-cutting issues introduced together by earlier fixes.\n'
        ;;
    esac
    bash "$RULES" prompt "$base_ref" "$base_sha" "$head" || return 1
    printf '\nLEDGER (no repeats)\n'
    printf -- '- Read the findings ledger first: %s\n' "$LEDGER"
    printf -- '- Never re-report a ledger class unless its fix is incomplete or regressed — then set reopens to its id (e.g. "C3") and fill still_wrong.\n'
    printf -- '- Never re-report classes noted as deferred / accepted / wontfix.\n'
    printf '\nWHAT TO REPORT\n'
    printf -- '- Only definite, actionable correctness, data-safety, concurrency or performance bugs introduced or left incomplete by this change.\n'
    printf -- '- Report bug CLASSES, not isolated lines: pattern, EVERY instance in scope, systematic fix, and prevention at source.\n'
    printf -- '- Severity: P0 data loss / security / common-path crash; P1 wrong behavior on realistic path; P2 edge case / measurable perf regression; P3 minor/defensive.\n'
    printf -- '- Pre-existing issues outside this change go in out_of_scope[] and do not count.\n'
    printf '\nSTRICT OUTPUT CONTRACT (CRITICAL — NO PROSE OUTSIDE JSON)\n'
    printf -- '- Return ONLY a single valid JSON object (bare or inside one ```json ... ``` fence) matching this exact schema — NO surrounding commentary, NO extra keys, NO duplicate keys:\n'
    printf '  {"summary":"<one concise paragraph>","verdict":"clean|findings","findings":[{"severity":"P0|P1|P2|P3","reopens":"|C3","title":"...","location":"file:line","pattern":"...","still_wrong":"","instances":["file:line"],"fix":"...","prevent":"..."}],"step_back":[],"out_of_scope":[{"location":"file:line","note":"..."}]}\n'
    printf -- '- verdict must be "clean" iff findings is empty, and "findings" iff findings is non-empty.\n'
    printf -- '- Keep summary and descriptions concise to avoid output truncation.\n'
    if [ "$mode" = "step-back" ]; then
      printf -- '- Populate step_back[] with {"classes":["C1"],"name":"...","invites_because":"...","approach_change":"...","prevent":"..."}.\n'
    else
      printf -- '- step_back must be [].\n'
    fi
  } > "$p"
}

cmd_prepare() {
  resolve_paths; ensure_state
  purpose=""; mode=""; base=""; since=""; slots=""; owner=""; ign_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --purpose) [ $# -ge 2 ] || die "prepare: --purpose requires a value"; purpose="$2"; shift 2 ;;
      --mode) [ $# -ge 2 ] || die "prepare: --mode requires a value"; mode="$2"; shift 2 ;;
      --base) [ $# -ge 2 ] || die "prepare: --base requires a value"; base="$2"; shift 2 ;;
      --since) [ $# -ge 2 ] || die "prepare: --since requires a value"; since="$2"; shift 2 ;;
      --slots) [ $# -ge 2 ] || die "prepare: --slots requires a value"; slots="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "prepare: --owner requires a value"; owner="$2"; shift 2 ;;
      --ignore-project-config) ign_arg=1; shift ;;
      --use-project-config) ign_arg=0; shift ;;
      *) die "prepare: unknown arg $1" ;;
    esac
  done
  resolve_knobs "$ign_arg"
  case "$mode" in full|incremental|step-back) ;; *) die "prepare: --mode must be full|incremental|step-back" ;; esac
  [ -n "$purpose" ] || die "prepare: --purpose is required"
  [ -n "$base" ] || die "prepare: --base is required"
  [ -n "$slots" ] || die "prepare: --slots is required (comma-separated slot ids)"
  [ -n "$owner" ] || die "prepare: --owner <parent-thread-id> is required"

  ar=$(sget active_round_dir)
  if [ -n "$ar" ] && [ -d "$ar" ] && [ ! -f "$ar/finished" ]; then
    die "prepare: an active round is already open: $ar (resume or cancel-round first)"
  fi

  base_sha=$(git rev-parse --verify --quiet "$base^{commit}") || die "prepare: --base '$base' does not resolve"
  head=$(git rev-parse HEAD) || die "prepare: cannot resolve HEAD"
  if [ "$mode" = "incremental" ]; then
    [ -n "$since" ] || die "prepare: incremental mode needs --since <sha>"
    since=$(git rev-parse --verify --quiet "$since^{commit}") || die "prepare: --since does not resolve"
    git merge-base --is-ancestor "$since" "$head" || die "prepare: --since is not ancestor of HEAD"
    [ "$since" != "$head" ] || die "prepare: HEAD unchanged since --since"
  fi
  hm=$(head_moves) || die "prepare: could not snapshot HEAD reflog (fail-closed)"
  tf=$(tree_fp_v2) || die "prepare: could not snapshot working tree (fail-closed)"

  n=$(( $(snum rounds_started) + 1 ))
  d="$STATE_DIR/rounds/$(printf '%03d' "$n")-$purpose"
  mkdir -p "$STATE_DIR/rounds" && mkdir "$d" 2>/dev/null || die "prepare: round dir already exists: $d"
  {
    printf 'purpose=%s\nmode=%s\nbase_ref=%s\nbase_sha=%s\nsince=%s\nreviewed_head=%s\nround=%s\n' \
      "$purpose" "$mode" "$base" "$base_sha" "$since" "$head" "$n"
    printf 'owner_thread_id=%s\nroot=%s\nstarted_at=%s\nhead_moves=%s\ntree_fp=%s\n' \
      "$owner" "$ROOT" "$(now_utc)" "$hm" "$tf"
  } > "$d/meta" || { rm -rf "$d"; die "prepare: cannot write meta"; }

  if ! write_prompt "$d" "$purpose" "$mode" "$base" "$base_sha" "$head" "$since" "$n"; then
    rm -rf "$d"; die "prepare: failed building reviewer prompt (rule-file scan failed)"
  fi

  # Initialize active_round.json atomically.
  atmp="$d/active_round.json.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($out, $n, $purpose, $mode, $base_ref, $base_sha, $head, $owner, $slots_csv, $now) = @ARGV;
    my %slot_map;
    my @order;
    for my $s (split(/,/, $slots_csv)) {
      $s =~ s/^\s+|\s+$//g;
      next unless length $s;
      die "invalid slot id '\''$s'\''\n" unless $s =~ /\A[A-Za-z0-9._-]+\z/ && $s ne "." && $s ne "..";
      die "duplicate slot id $s\n" if exists $slot_map{$s};
      push @order, $s;
      $slot_map{$s} = {
        slot => $s, attempt => 0, state => "unclaimed",
        providerInstanceId => "", model => "", optionsJson => "{}",
        clientRequestId => "", taskId => "", childThreadId => "", childRunId => "",
        resultFile => "", resultSha256 => "", rawInputSha256 => "", reason => "",
      };
    }
    die "no valid slots\n" unless @order;
    my $obj = {
      round => int($n), purpose => $purpose, mode => $mode,
      baseRef => $base_ref, baseSha => $base_sha, reviewedHead => $head,
      ownerThreadId => $owner, status => "active", createdAt => $now,
      slotOrder => \@order, slots => \%slot_map,
    };
    open(my $fh, ">:raw", $out) or die "cannot write $out\n";
    print $fh JSON::PP->new->utf8->pretty->canonical->encode($obj);
    close $fh or die "cannot close $out\n";
  ' "$atmp" "$n" "$purpose" "$mode" "$base" "$base_sha" "$head" "$owner" "$slots" "$(now_utc)" \
    || { rm -rf "$d"; die "prepare: cannot write active_round.json"; }
  mv "$atmp" "$d/active_round.json" || { rm -rf "$d"; die "prepare: cannot move active_round.json"; }

  stmp="$STATE.tmp.$$"
  if [ -n "$ign_arg" ]; then
    build_state_file "$stmp" "rounds_started=$n" "active_round_dir=$d" "ignore_project_config=$ign_arg"
  else
    build_state_file "$stmp" "rounds_started=$n" "active_round_dir=$d"
  fi
  mv "$stmp" "$STATE" || { rm -f "$stmp"; die "prepare: cannot update state"; }

  printf 'ROUND=%s\nPURPOSE=%s\nMODE=%s\nROUND_DIR=%s\nPROMPT=%s/prompt.md\nREVIEWED_HEAD=%s\nBASE_SHA=%s\n' \
    "$n" "$purpose" "$mode" "$d" "$d" "$head" "$base_sha"
}

# Atomic CAS slot transitions on active_round.json (all under branch flock).
cmd_claim_slot() {
  resolve_paths; ensure_state
  [ $# -ge 1 ] || die "claim-slot: ROUND_DIR required"
  d=$(validate_round_dir "$1"); shift
  slot=""; attempt=""; owner=""; prov=""; model=""; opts="{}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --slot) [ $# -ge 2 ] || die "claim-slot: --slot requires a value"; slot="$2"; shift 2 ;;
      --attempt) [ $# -ge 2 ] || die "claim-slot: --attempt requires a value"; attempt="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "claim-slot: --owner requires a value"; owner="$2"; shift 2 ;;
      --provider) [ $# -ge 2 ] || die "claim-slot: --provider requires a value"; prov="$2"; shift 2 ;;
      --model) [ $# -ge 2 ] || die "claim-slot: --model requires a value"; model="$2"; shift 2 ;;
      --options-json) [ $# -ge 2 ] || die "claim-slot: --options-json requires a value"; opts="$2"; shift 2 ;;
      *) die "claim-slot: unknown arg $1" ;;
    esac
  done
  is_uint "$attempt" && [ "$attempt" -ge 1 ] && [ "$attempt" -le 2 ] || die "claim-slot: --attempt must be 1 or 2"
  [ -n "$slot" ] && [ -n "$owner" ] && [ -n "$prov" ] && [ -n "$model" ] || die "claim-slot: missing required args"
  af="$d/active_round.json"; [ -f "$af" ] || die "claim-slot: missing $af"
  base_name=$(basename "$d")
  crid="t3-cr:${KEY}:${base_name}:${slot}:a${attempt}"
  atmp="$af.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $slot, $att, $owner, $prov, $model, $opts, $crid, $now) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round is not active (status=$obj->{status})\n" unless ($obj->{status} // "") eq "active";
    die "owner mismatch: expected $obj->{ownerThreadId}, got $owner\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    my $s = $obj->{slots}{$slot} or die "unknown slot $slot\n";
    my $prev_att = $s->{attempt} // 0;
    my $st = $s->{state} // "unclaimed";
    if ($att == 1) {
      die "CAS failed: slot $slot already claimed (attempt=$prev_att, state=$st)\n" unless $prev_att == 0 && $st eq "unclaimed";
    } else {
      my %term = map { $_ => 1 } qw(completed_invalid failed cancelled interrupted);
      die "CAS failed: retry attempt $att requires previous attempt " . ($att - 1) . " in terminal failure state (got attempt=$prev_att, state=$st)\n"
        unless $prev_att == $att - 1 && $term{$st};
    }
    $s->{attempt} = int($att);
    $s->{state} = "dispatching";
    $s->{providerInstanceId} = $prov;
    $s->{model} = $model;
    $s->{optionsJson} = $opts;
    $s->{clientRequestId} = $crid;
    $s->{taskId} = "";
    $s->{childThreadId} = "";
    $s->{childRunId} = "";
    $s->{resultFile} = "";
    $s->{resultSha256} = "";
    $s->{rawInputSha256} = "";
    $s->{reason} = "";
    $s->{dispatchedAt} = $now;
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$atmp" "$slot" "$attempt" "$owner" "$prov" "$model" "$opts" "$crid" "$(now_utc)" \
    || { rm -f "$atmp"; die "claim-slot CAS failed"; }
  mv "$atmp" "$af" || { rm -f "$atmp"; die "claim-slot: failed replacing $af"; }
  printf 'CLAIMED=%s\nATTEMPT=%s\nCLIENT_REQUEST_ID=%s\n' "$slot" "$attempt" "$crid"
}

cmd_record_dispatch() {
  resolve_paths; ensure_state
  [ $# -ge 1 ] || die "record-dispatch: ROUND_DIR required"
  d=$(validate_round_dir "$1"); shift
  slot=""; attempt=""; owner=""; tid=""; ctid=""; crid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slot) [ $# -ge 2 ] || die "record-dispatch: --slot requires a value"; slot="$2"; shift 2 ;;
      --attempt) [ $# -ge 2 ] || die "record-dispatch: --attempt requires a value"; attempt="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "record-dispatch: --owner requires a value"; owner="$2"; shift 2 ;;
      --task-id) [ $# -ge 2 ] || die "record-dispatch: --task-id requires a value"; tid="$2"; shift 2 ;;
      --child-thread-id) [ $# -ge 2 ] || die "record-dispatch: --child-thread-id requires a value"; ctid="$2"; shift 2 ;;
      --child-run-id) [ $# -ge 2 ] || die "record-dispatch: --child-run-id requires a value"; crid="$2"; shift 2 ;;
      *) die "record-dispatch: unknown arg $1" ;;
    esac
  done
  [ -n "$slot" ] && [ -n "$attempt" ] && [ -n "$owner" ] && [ -n "$tid" ] && [ -n "$ctid" ] || die "record-dispatch: missing required args"
  af="$d/active_round.json"; [ -f "$af" ] || die "record-dispatch: missing $af"
  atmp="$af.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $slot, $att, $owner, $tid, $ctid, $crid) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round not active\n" unless ($obj->{status} // "") eq "active";
    die "owner mismatch\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    my $s = $obj->{slots}{$slot} or die "unknown slot $slot\n";
    die "CAS failed: expected attempt=$att state=dispatching, got attempt=$s->{attempt} state=$s->{state}\n"
      unless $s->{attempt} == $att && $s->{state} eq "dispatching";
    $s->{state} = "running";
    $s->{taskId} = $tid;
    $s->{childThreadId} = $ctid;
    $s->{childRunId} = $crid;
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$atmp" "$slot" "$attempt" "$owner" "$tid" "$ctid" "$crid" \
    || { rm -f "$atmp"; die "record-dispatch CAS failed"; }
  mv "$atmp" "$af" || { rm -f "$atmp"; die "record-dispatch: failed replacing $af"; }
  printf 'RECORDED=%s\nSTATE=running\nTASK_ID=%s\n' "$slot" "$tid"
}

cmd_update_slot() {
  resolve_paths; ensure_state
  [ $# -ge 1 ] || die "update-slot: ROUND_DIR required"
  d=$(validate_round_dir "$1"); shift
  slot=""; attempt=""; owner=""; st=""; reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slot) [ $# -ge 2 ] || die "update-slot: --slot requires a value"; slot="$2"; shift 2 ;;
      --attempt) [ $# -ge 2 ] || die "update-slot: --attempt requires a value"; attempt="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "update-slot: --owner requires a value"; owner="$2"; shift 2 ;;
      --state) [ $# -ge 2 ] || die "update-slot: --state requires a value"; st="$2"; shift 2 ;;
      --reason) [ $# -ge 2 ] || die "update-slot: --reason requires a value"; reason="$2"; shift 2 ;;
      *) die "update-slot: unknown arg $1" ;;
    esac
  done
  case "$st" in running|waiting|cancel_requested|failed|cancelled|interrupted) ;; *) die "update-slot: invalid --state '$st'" ;; esac
  [ -n "$slot" ] && [ -n "$attempt" ] && [ -n "$owner" ] || die "update-slot: missing required args"
  af="$d/active_round.json"; [ -f "$af" ] || die "update-slot: missing $af"
  atmp="$af.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $slot, $att, $owner, $st, $reason) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round not active\n" unless ($obj->{status} // "") eq "active";
    die "owner mismatch\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    my $s = $obj->{slots}{$slot} or die "unknown slot $slot\n";
    die "CAS failed: expected attempt=$att, got attempt=$s->{attempt}\n" unless $s->{attempt} == $att;
    my %allowed_from = (
      running          => { dispatching => 1, running => 1, waiting => 1 },
      waiting          => { running => 1, waiting => 1 },
      cancel_requested => { dispatching => 1, running => 1, waiting => 1, cancel_requested => 1 },
      cancelled        => { dispatching => 1, running => 1, waiting => 1, cancel_requested => 1, cancelled => 1 },
      failed           => { dispatching => 1, running => 1, waiting => 1, cancel_requested => 1, failed => 1 },
      interrupted      => { dispatching => 1, running => 1, waiting => 1, cancel_requested => 1, interrupted => 1 },
    );
    die "CAS failed: illegal slot transition '\''$s->{state}'\'' -> '\''$st'\''\n"
      unless $allowed_from{$st}{$s->{state} // ""};
    $s->{state} = $st;
    $s->{reason} = $reason if length $reason;
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$atmp" "$slot" "$attempt" "$owner" "$st" "$reason" \
    || { rm -f "$atmp"; die "update-slot CAS failed"; }
  mv "$atmp" "$af" || { rm -f "$atmp"; die "update-slot: failed replacing $af"; }
  printf 'SLOT=%s\nATTEMPT=%s\nSLOT_STATE=%s\n' "$slot" "$attempt" "$st"
}

cmd_record_result() {
  resolve_paths; ensure_state
  [ $# -ge 1 ] || die "record-result: ROUND_DIR required"
  d=$(validate_round_dir "$1"); shift
  slot=""; attempt=""; owner=""; infile=""; tid=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --slot) [ $# -ge 2 ] || die "record-result: --slot requires a value"; slot="$2"; shift 2 ;;
      --attempt) [ $# -ge 2 ] || die "record-result: --attempt requires a value"; attempt="$2"; shift 2 ;;
      --owner) [ $# -ge 2 ] || die "record-result: --owner requires a value"; owner="$2"; shift 2 ;;
      --task-id) [ $# -ge 2 ] || die "record-result: --task-id requires a value"; tid="$2"; shift 2 ;;
      --input) [ $# -ge 2 ] || die "record-result: --input requires a value"; infile="$2"; shift 2 ;;
      *) die "record-result: unknown arg $1" ;;
    esac
  done
  [ -n "$slot" ] && [ -n "$attempt" ] && [ -n "$owner" ] && [ -f "$infile" ] || die "record-result: missing required args or input file"
  is_uint "$attempt" || die "record-result: --attempt must be an integer"
  af="$d/active_round.json"; [ -f "$af" ] || die "record-result: missing $af"

  # 1. Strict CAS & slot-name validation BEFORE running parse-review.pl or writing/deleting ANY file!
  pre_chk=$(perl -MJSON::PP -MDigest::SHA=sha256_hex -e '
    use strict; use warnings;
    my ($af, $slot, $att, $owner, $tid, $infile) = @ARGV;
    die "invalid slot id '\''$slot'\''\n" unless $slot =~ /\A[A-Za-z0-9._-]+\z/ && $slot ne "." && $slot ne "..";
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round not active (status=$obj->{status})\n" unless ($obj->{status} // "") eq "active";
    die "owner mismatch\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    my $s = $obj->{slots}{$slot} or die "unknown slot $slot\n";
    die "CAS failed: stale attempt $att (current=$s->{attempt})\n" unless ($s->{attempt} // 0) == $att;
    if (length $tid && ($s->{taskId} // "") ne $tid) {
      die "CAS failed: taskId mismatch ($tid != " . ($s->{taskId} // "") . ")\n";
    }
    open(my $ifh, "<:raw", $infile) or die "cannot read $infile\n";
    local $/; my $in_bytes = <$ifh>; close $ifh;
    my $in_sha = sha256_hex(defined $in_bytes ? $in_bytes : "");
    my $st = $s->{state} // "";
    if ($st eq "completed_valid" || $st eq "completed_invalid") {
      if (length($s->{rawInputSha256} // "") && $s->{rawInputSha256} eq $in_sha) {
        print "ACTION=dup\nSTATE=$st\nRESULT_FILE=" . ($s->{resultFile} // "") . "\nIN_SHA=$in_sha\n";
        exit 0;
      }
      die "CAS failed: slot $slot already terminal ($st) — refusing overwrite\n";
    }
    die "CAS failed: slot $slot in state '\''$st'\'', expected running or waiting\n"
      unless $st eq "running" || $st eq "waiting";
    print "ACTION=proceed\nIN_SHA=$in_sha\n";
  ' "$af" "$slot" "$attempt" "$owner" "$tid" "$infile") || die "record-result CAS failed"

  act=$(printf '%s\n' "$pre_chk" | sed -n 's/^ACTION=//p' | head -n 1)
  in_sha=$(printf '%s\n' "$pre_chk" | sed -n 's/^IN_SHA=//p' | head -n 1)
  if [ "$act" = "dup" ]; then
    dup_st=$(printf '%s\n' "$pre_chk" | sed -n 's/^STATE=//p' | head -n 1)
    dup_rf=$(printf '%s\n' "$pre_chk" | sed -n 's/^RESULT_FILE=//p' | head -n 1)
    printf 'DUPLICATE_NOOP=1\nSLOT=%s\nATTEMPT=%s\nSLOT_STATE=%s\nRESULT_FILE=%s\n' "$slot" "$attempt" "$dup_st" "$dup_rf"
    [ "$dup_st" = "completed_valid" ] && return 0 || exit 5
  fi

  # 2. Validate into a temporary file inside $d (never overwriting live result paths prematurely).
  canon_out="$d/result-${slot}-a${attempt}.json"
  invalid_out="$d/result-${slot}-a${attempt}.invalid.txt"
  tmp_canon="$d/.result-${slot}-a${attempt}.tmp.$$.json"
  tmp_inv="$d/.result-${slot}-a${attempt}.tmp.$$.invalid.txt"
  vout=$(perl "$PARSER" --validate-only "$infile" --write-canonical "$tmp_canon")
  vrc=$?

  new_st="completed_valid"; err_reason=""; res_path="$canon_out"; staged_art="$tmp_canon"
  if [ "$vrc" -ne 0 ]; then
    rm -f "$tmp_canon"
    cp "$infile" "$tmp_inv" || { rm -f "$tmp_inv"; die "cannot stage invalid result"; }
    new_st="completed_invalid"
    err_reason=$(printf '%s\n' "$vout" | sed -n 's/^ERROR=//p' | head -n 1)
    res_path="$invalid_out"
    staged_art="$tmp_inv"
  fi

  # Refuse directory/symlink conflicts at artifact target AND active_round.json BEFORE moving!
  if [ -d "$res_path" ] || [ -L "$res_path" ]; then
    rm -f "$tmp_canon" "$tmp_inv"
    die "record-result: refusing directory or symlink conflict at $res_path"
  fi
  if [ -d "$af" ] || [ -L "$af" ]; then
    rm -f "$tmp_canon" "$tmp_inv"
    die "record-result: refusing directory or symlink conflict at $af"
  fi
  art_sha=$(perl -MDigest::SHA=sha256_hex -e '
    open(my $fh, "<:raw", $ARGV[0]) or exit 1;
    local $/; my $b = <$fh>; close $fh or exit 1;
    print sha256_hex(defined $b ? $b : "");
  ' "$staged_art") || { rm -f "$tmp_canon" "$tmp_inv"; die "record-result: cannot hash staged artifact"; }

  # 3. Stage active_round.json, then move artifact, post-verify regular file + byte hash, and commit active_round.json.
  atmp="$af.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $slot, $att, $owner, $nst, $rpath, $in_sha, $art_sha, $err) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round not active\n" unless ($obj->{status} // "") eq "active";
    die "owner mismatch\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    my $s = $obj->{slots}{$slot} or die "unknown slot $slot\n";
    die "CAS failed: stale attempt $att (current=$s->{attempt})\n" unless $s->{attempt} == $att;
    $s->{state} = $nst;
    $s->{resultFile} = $rpath;
    $s->{resultSha256} = $art_sha;
    $s->{rawInputSha256} = $in_sha;
    $s->{reason} = $err;
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$atmp" "$slot" "$attempt" "$owner" "$new_st" "$res_path" "$in_sha" "$art_sha" "$err_reason" \
    || { rm -f "$atmp" "$tmp_canon" "$tmp_inv"; die "record-result CAS failed"; }

  mv "$staged_art" "$res_path" || { rm -f "$atmp" "$staged_art"; die "record-result: failed moving $res_path"; }
  # Post-move verification: target MUST be a regular non-symlink file with exact expected SHA-256!
  if [ ! -f "$res_path" ] || [ -L "$res_path" ] || [ -d "$res_path" ]; then
    rm -f "$atmp"
    die "record-result: post-move target $res_path is not a regular file"
  fi
  post_sha=$(perl -MDigest::SHA=sha256_hex -e '
    open(my $fh, "<:raw", $ARGV[0]) or exit 1;
    local $/; my $b = <$fh>; close $fh or exit 1;
    print sha256_hex(defined $b ? $b : "");
  ' "$res_path") || { rm -f "$atmp"; die "record-result: post-move hash failed on $res_path"; }
  [ "$post_sha" = "$art_sha" ] || { rm -f "$atmp"; die "record-result: post-move byte verification failed on $res_path"; }
  mv "$atmp" "$af" || { rm -f "$atmp"; die "record-result: failed replacing $af"; }

  if [ "$vrc" -ne 0 ]; then
    printf 'SLOT=%s\nATTEMPT=%s\nSLOT_STATE=completed_invalid\nREASON=%s\nRAW=%s\n' "$slot" "$attempt" "$err_reason" "$invalid_out"
    exit 5
  fi
  printf 'SLOT=%s\nATTEMPT=%s\nSLOT_STATE=completed_valid\nRESULT_FILE=%s\n%s\n' "$slot" "$attempt" "$canon_out" "$vout"
}

cmd_round_summary() {
  resolve_paths; ensure_state
  d="${1:-}"
  [ -n "$d" ] || d=$(sget active_round_dir)
  [ -n "$d" ] || die "round-summary: no round specified and no active round"
  d=$(validate_round_dir "$d")
  af="$d/active_round.json"; [ -f "$af" ] || die "round-summary: missing $af"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    print "ROUND=$obj->{round}\nPURPOSE=$obj->{purpose}\nMODE=$obj->{mode}\nSTATUS=$obj->{status}\nOWNER=$obj->{ownerThreadId}\n";
    my ($valid, $term_fail, $pending) = (0, 0, 0);
    my %tf = map { $_ => 1 } qw(completed_invalid failed cancelled interrupted);
    for my $k (@{$obj->{slotOrder}}) {
      my $s = $obj->{slots}{$k};
      if ($s->{state} eq "completed_valid") { $valid++; }
      elsif ($tf{$s->{state}}) { $term_fail++; }
      else { $pending++; }
      printf "SLOT| %s\tattempt=%d\tstate=%s\tmodel=%s/%s\ttask=%s\tchild=%s\tresult=%s\n",
        $k, $s->{attempt}, $s->{state}, $s->{providerInstanceId}, $s->{model}, $s->{taskId}, $s->{childThreadId}, $s->{resultFile};
    }
    print "VALID_SLOTS=$valid\nFAILED_SLOTS=$term_fail\nPENDING_SLOTS=$pending\nTOTAL_SLOTS=" . scalar(@{$obj->{slotOrder}}) . "\n";
  ' "$af"
}

cmd_cancel_round() {
  resolve_paths; ensure_state
  [ $# -ge 1 ] || die "cancel-round: ROUND_DIR required"
  d=$(validate_round_dir "$1"); shift
  owner=""; reason="cancelled"
  while [ $# -gt 0 ]; do
    case "$1" in
      --owner) [ $# -ge 2 ] || die "cancel-round: --owner requires a value"; owner="$2"; shift 2 ;;
      --reason) [ $# -ge 2 ] || die "cancel-round: --reason requires a value"; reason="$2"; shift 2 ;;
      *) die "cancel-round: unknown arg $1" ;;
    esac
  done
  [ -n "$owner" ] || die "cancel-round: --owner required"
  af="$d/active_round.json"; [ -f "$af" ] || die "cancel-round: missing $af"
  atmp="$af.tmp.$$"
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $owner, $reason) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "owner mismatch\n" unless ($obj->{ownerThreadId} // "") eq $owner;
    $obj->{status} = "cancelled";
    $obj->{cancelReason} = $reason;
    for my $k (@{$obj->{slotOrder}}) {
      my $s = $obj->{slots}{$k};
      $s->{state} = "cancelled" if $s->{state} =~ /^(unclaimed|dispatching|running|waiting|cancel_requested)$/;
    }
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$atmp" "$owner" "$reason" || { rm -f "$atmp"; die "cancel-round failed"; }
  mv "$atmp" "$af" || { rm -f "$atmp"; die "cancel-round: failed replacing $af"; }
  if [ "$(sget active_round_dir)" = "$d" ]; then
    stmp="$STATE.tmp.$$"
    build_state_file "$stmp" "active_round_dir="
    mv "$stmp" "$STATE" || { rm -f "$stmp"; die "cancel-round: failed updating state"; }
  fi
  printf 'CANCELLED_ROUND=%s\n' "$d"
}

cmd_finish() {
  resolve_paths; ensure_state
  explicit_arg="${1:-}"
  merged_file=""; partial_reason=""; dismissed_file=""; ign_arg=""
  if [ -n "$explicit_arg" ] && [ "${explicit_arg#--}" = "$explicit_arg" ]; then
    shift
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
    d=$(sget active_round_dir)
    [ -n "$d" ] || die "finish: no round dir given and no active round"
    d=$(validate_round_dir "$d")
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --merged) [ $# -ge 2 ] || die "finish: --merged requires a file"; merged_file="$2"; shift 2 ;;
      --dismissed-findings) [ $# -ge 2 ] || die "finish: --dismissed-findings requires a file"; dismissed_file="$2"; shift 2 ;;
      --partial-approved) [ $# -ge 2 ] || die "finish: --partial-approved requires a reason"; partial_reason="$2"; shift 2 ;;
      --ignore-project-config) ign_arg=1; shift ;;
      --use-project-config) ign_arg=0; shift ;;
      *) die "finish: unknown arg $1" ;;
    esac
  done
  resolve_knobs "$ign_arg"
  if [ -n "$dismissed_file" ] && { [ ! -f "$dismissed_file" ] || [ -L "$dismissed_file" ]; }; then
    die "finish: --dismissed-findings file not found or symlink: $dismissed_file"
  fi

  mode=$(mget "$d" mode); purpose=$(mget "$d" purpose); reviewed=$(mget "$d" reviewed_head); n=$(mget "$d" round)
  is_uint "$n" || die "corrupt round number in $d/meta"
  rs=$(snum rounds_started); lfr=$(snum latest_finished_round)
  if [ "$n" -le "$lfr" ] || [ "$n" -ne "$rs" ]; then
    die "round $n is superseded (rounds_started=$rs, latest_finished_round=$lfr) — refusing out-of-order finish"
  fi

  # Verify slot completion status in active_round.json
  af="$d/active_round.json"; [ -f "$af" ] || die "finish: missing $af"
  slot_meta=$(perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $partial) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    die "round status is $obj->{status}, not active\n" unless ($obj->{status} // "") eq "active";
    my ($valid, $pending, @absent, @vfiles) = (0, 0);
    for my $k (@{$obj->{slotOrder}}) {
      my $s = $obj->{slots}{$k};
      if ($s->{state} eq "completed_valid") { $valid++; push @vfiles, $s->{resultFile} // ""; }
      elsif ($s->{state} =~ /^(unclaimed|dispatching|running|waiting|cancel_requested)$/) { $pending++; }
      else { push @absent, "$k($s->{providerInstanceId}/$s->{model}:$s->{state})"; }
    }
    die "slots still pending ($pending)\n" if $pending > 0;
    die "no valid reviewer results\n" if $valid == 0;
    if (@absent && !length $partial) {
      die "partial failure (" . join(", ", @absent) . ") requires explicit user approval (--partial-approved)\n";
    }
    print "VALID_COUNT=$valid\n";
    print "SINGLE_FILE=" . ($valid == 1 ? $vfiles[0] : "") . "\n";
    print "ABSENT=" . join(",", @absent) . "\n";
  ' "$af" "$partial_reason") || die "finish: slot precondition failed"
  valid_cnt=$(printf '%s\n' "$slot_meta" | sed -n 's/^VALID_COUNT=//p' | head -n 1)
  single_slot_file=$(printf '%s\n' "$slot_meta" | sed -n 's/^SINGLE_FILE=//p' | head -n 1)
  slot_chk=$(printf '%s\n' "$slot_meta" | sed -n 's/^ABSENT=//p' | head -n 1)

  if [ -z "$merged_file" ]; then
    if [ "$valid_cnt" = "1" ] && [ -n "$single_slot_file" ] && [ -f "$single_slot_file" ] && [ ! -L "$single_slot_file" ]; then
      merged_file="$single_slot_file"
    else
      die "finish: --merged <json-file> is required (unless single valid reviewer slot is auto-consumed)"
    fi
  fi
  [ -f "$merged_file" ] && [ ! -L "$merged_file" ] || die "finish: --merged file not found or symlink: $merged_file"

  # Drift checks (fail-closed)
  head=$(git rev-parse HEAD) || { printf 'VERDICT=error\nREASON=cannot resolve HEAD\n'; exit 5; }
  drift=""
  cur_hm=""; cur_tf=""
  exp_hm=$(mget "$d" head_moves); exp_tf=$(mget "$d" tree_fp)
  if [ "$head" != "$reviewed" ]; then
    drift=head-moved
  else
    if [ -n "$exp_hm" ]; then
      cur_hm=$(head_moves) || { printf 'VERDICT=error\nREASON=could not read HEAD reflog for drift check\n'; exit 5; }
      [ "$exp_hm" = "$cur_hm" ] || drift=head-moved-and-returned
    fi
    if [ -z "$drift" ] && [ -n "$exp_tf" ]; then
      cur_tf=$(tree_fp_v2) || { printf 'VERDICT=error\nREASON=could not snapshot working tree for drift check\n'; exit 5; }
      [ "$exp_tf" = "$cur_tf" ] || drift=tree-changed
    fi
  fi
  if [ -n "$drift" ]; then
    # Mark round drifted and clear active_round_dir so next run does not loop in PURPOSE=resume!
    atmp="$af.tmp.$$"
    perl -MJSON::PP -e '
      use strict; use warnings;
      my ($af, $out, $reason) = @ARGV;
      my $J = JSON::PP->new->utf8;
      open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
      $obj->{status} = "drifted";
      $obj->{driftReason} = $reason;
      open(my $oh, ">:raw", $out) or die "cannot write $out\n";
      print $oh $J->pretty->canonical->encode($obj);
      close $oh or die "cannot close $out\n";
    ' "$af" "$atmp" "$drift" && mv "$atmp" "$af" || rm -f "$atmp"
    if [ "$(sget active_round_dir)" = "$d" ]; then
      stmp="$STATE.tmp.$$"
      build_state_file "$stmp" "active_round_dir="
      mv "$stmp" "$STATE" || rm -f "$stmp"
    fi
    printf 'VERDICT=head-drift\nREASON=%s\nREVIEWED_HEAD=%s\nHEAD=%s\n' "$drift" "$reviewed" "$head"
    exit 3
  fi

  # Archive merged result and strictly validate/render it
  res="$d/merged-result.json"
  if [ -d "$res" ] || [ -L "$res" ]; then
    printf 'VERDICT=error\nREASON=refusing directory or symlink at %s\n' "$res"
    exit 5
  fi
  if [ "$(cd "$(dirname "$merged_file")" && pwd -P)/$(basename "$merged_file")" != "$res" ]; then
    cp "$merged_file" "$res" || die "cannot copy merged result to $res"
  fi
  frag="$d/ledger-fragment.md"; md="$d/review.md"
  parsed=$(perl "$PARSER" "$res" "$(snum next_class_id)" "$LEDGER" "$frag" "$md" --allow-sources)
  prc=$?
  if [ "$prc" -ne 0 ]; then
    printf 'VERDICT=error\n%s\nRESULT=%s\n' "$(printf '%s\n' "$parsed" | sed -n 's/^ERROR=/REASON=/p')" "$res"
    exit 5
  fi

  # Enforce strict slot-to-merged integrity (prevents settling blocking slot findings as clean!).
  bind_err=$(perl -MJSON::PP -MDigest::SHA=sha256_hex -MCwd=abs_path -e '
    use strict; use warnings;
    my ($af, $round_dir, $merged_path, $skip_p3, $mode, $dismissed_path) = @ARGV;
    my $J = JSON::PP->new->utf8;
    my $JC = JSON::PP->new->utf8->canonical;
    my %rank = (P0 => 4, P1 => 3, P2 => 2, P3 => 1);
    my $is_blocking = sub {
      my ($sev) = @_;
      return 1 if $sev eq "P0" || $sev eq "P1" || $sev eq "P2";
      return ($skip_p3 eq "0" && $sev eq "P3") ? 1 : 0;
    };

    my $rdir_real = abs_path($round_dir) // die "cannot resolve round dir\n";
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $ar = $J->decode(<$fh>); close $fh;
    open(my $mfh, "<:raw", $merged_path) or die "cannot read $merged_path\n"; local $/; my $merged = $J->decode(<$mfh>); close $mfh;

    my @valid_slots;
    for my $k (@{$ar->{slotOrder}}) {
      my $s = $ar->{slots}{$k};
      next unless ($s->{state} // "") eq "completed_valid";
      my $rf = $s->{resultFile} // "";
      die "valid slot $k missing resultFile\n" unless length($rf) && -f $rf && !-l $rf;
      my $rf_real = abs_path($rf) // die "cannot resolve resultFile for slot $k\n";
      die "slot $k resultFile escapes round dir\n" unless index($rf_real, "$rdir_real/") == 0;
      open(my $sfh, "<:raw", $rf) or die "cannot read slot $k resultFile\n"; local $/; my $sbytes = <$sfh>; close $sfh;
      if (length($s->{resultSha256} // "") && sha256_hex($sbytes) ne $s->{resultSha256}) {
        die "slot $k canonical resultFile digest mismatch (tampered on disk)\n";
      }
      my $sobj = eval { $J->decode($sbytes) };
      die "slot $k canonical resultFile invalid JSON\n" if $@ || ref $sobj ne "HASH";
      push @valid_slots, { slot => $k, meta => $s, obj => $sobj };
    }

    my $strip_sources = sub {
      my ($o) = @_;
      my $copy = {
        summary => $o->{summary},
        verdict => $o->{verdict},
        findings => [ map { my %x = %$_; delete $x{sources}; \%x } @{$o->{findings} || []} ],
        step_back => [ map { my %x = %$_; delete $x{sources}; \%x } @{$o->{step_back} || []} ],
        out_of_scope => [ map { my %x = %$_; delete $x{sources}; \%x } @{$o->{out_of_scope} || []} ],
      };
      return $JC->encode($copy);
    };

    if (@valid_slots == 1) {
      my $vs = $valid_slots[0];
      if ($strip_sources->($merged) ne $strip_sources->($vs->{obj})) {
        die "single-reviewer merged JSON does not match recorded canonical slot result ($vs->{slot})\n";
      }
      exit 0;
    }

    # Multi-reviewer council: load optional evidenced --dismissed-findings.
    my @dismissed;
    if (defined $dismissed_path && length $dismissed_path) {
      open(my $dfh, "<:raw", $dismissed_path) or die "cannot read --dismissed-findings\n"; local $/; my $draw = <$dfh>; close $dfh;
      my $darr = eval { $J->decode($draw) };
      die "--dismissed-findings must be a JSON array\n" if $@ || ref $darr ne "ARRAY";
      my $idx = 0;
      for my $d (@$darr) {
        $idx++;
        die "--dismissed-findings[$idx] must be object\n" unless ref $d eq "HASH";
        for my $req (qw(slot title severity code_evidence)) {
          die "--dismissed-findings[$idx].$req must be non-empty string\n"
            unless defined $d->{$req} && !ref($d->{$req}) && $d->{$req} =~ /\S/;
        }
        die "--dismissed-findings[$idx].severity invalid\n" unless exists $rank{$d->{severity}};
        push @dismissed, $d;
      }
    }

    my $is_dismissed = sub {
      my ($slot, $model_tag, $f) = @_;
      for my $d (@dismissed) {
        next unless ($d->{slot} eq $slot || $d->{slot} eq $model_tag);
        next unless $d->{severity} eq $f->{severity};
        next unless $d->{title} eq $f->{title};
        if (defined $d->{reopens} && length $d->{reopens}) {
          next unless $d->{reopens} eq ($f->{reopens} // "");
        }
        return 1;
      }
      return 0;
    };

    my %merged_reopen_max;
    my %merged_source_max;
    for my $mf (@{$merged->{findings} || []}) {
      my $rk = $rank{$mf->{severity}} // 0;
      if (length($mf->{reopens} // "")) {
        my $cid = $mf->{reopens};
        $merged_reopen_max{$cid} = $rk if ($merged_reopen_max{$cid} // 0) < $rk;
      }
      if ($is_blocking->($mf->{severity})) {
        for my $src (@{$mf->{sources} || []}) {
          $merged_source_max{$src} = $rk if ($merged_source_max{$src} // 0) < $rk;
        }
      }
    }

    my @unaccounted;
    my $any_slot_sb = 0;
    for my $vs (@valid_slots) {
      my $sn = $vs->{slot};
      my $mtag = "$vs->{meta}{providerInstanceId}/$vs->{meta}{model}";
      $any_slot_sb = 1 if @{$vs->{obj}{step_back} || []} > 0;
      my $max_undism_rank = 0;
      my @undism_titles;
      for my $f (@{$vs->{obj}{findings} || []}) {
        next unless $is_blocking->($f->{severity});
        next if $is_dismissed->($sn, $mtag, $f);
        my $rk = $rank{$f->{severity}} // 0;
        $max_undism_rank = $rk if $rk > $max_undism_rank;
        push @undism_titles, "$f->{severity}:$f->{title}";
        if (length($f->{reopens} // "")) {
          my $cid = $f->{reopens};
          if (($merged_reopen_max{$cid} // 0) < $rk) {
            push @unaccounted, "slot $sn ($mtag) reopened blocking $cid ($f->{severity}) missing or downgraded in merged findings without --dismissed-findings";
          }
        }
      }
      if ($max_undism_rank > 0) {
        my $got_rk = $merged_source_max{$mtag} // 0;
        $got_rk = $merged_source_max{$sn} if ($merged_source_max{$sn} // 0) > $got_rk;
        if ($got_rk < $max_undism_rank) {
          push @unaccounted, "slot $sn ($mtag) blocking finding(s) [" . join(", ", @undism_titles) . "] not traced in merged findings[].sources at >= severity without evidenced --dismissed-findings";
        }
      }
    }
    if ($mode eq "step-back" && $any_slot_sb && @{$merged->{step_back} || []} == 0) {
      push @unaccounted, "council slot(s) reported step_back[] items that were dropped from merged output";
    }
    if (@unaccounted) {
      die join("; ", @unaccounted) . "\n";
    }
  ' "$af" "$d" "$res" "$SKIP_P3" "$mode" "$dismissed_file" 2>&1)
  brc=$?
  if [ "$brc" -ne 0 ]; then
    bind_err=$(printf '%s' "$bind_err" | tr '\n' ' ')
    printf 'VERDICT=error\nREASON=%s\nRESULT=%s\n' "$bind_err" "$res"
    exit 5
  fi
  if [ -n "$dismissed_file" ]; then
    cp "$dismissed_file" "$d/dismissed-findings.json" || die "cannot archive dismissed findings"
  fi
  pv() { printf '%s\n' "$parsed" | sed -n "s/^$1=//p"; }
  c0=$(pv P0); c1=$(pv P1); c2=$(pv P2); c3=$(pv P3); total=$(pv TOTAL)
  new=$(pv NEW); reo=$(pv REOPENED); nxt=$(pv NEXT)
  if [ "$total" -eq 0 ]; then verdict=clean
  elif [ $(( c0 + c1 + c2 )) -eq 0 ] && [ "$SKIP_P3" = "1" ]; then verdict=p3-only
  else verdict=dirty
  fi

  # Single-pass rule-file scan + render
  scan_file="$d/rules-scan.tsv"
  rules_4col=""; rules_fp=""; rules_open=0; rbase=$(mget "$d" base_sha)
  : > "$scan_file" || { printf 'VERDICT=error\nREASON=cannot create %s\n' "$scan_file"; exit 5; }
  if [ -n "$rbase" ]; then
    if ! bash "$RULES" scan "$rbase" "$reviewed" > "$scan_file" || ! rules_fp=$(bash "$RULES" fp "$rbase" "$reviewed" --from-scan "$scan_file"); then
      printf 'VERDICT=error\nREASON=rule-file scan failed (review-rules.sh)\nRESULT=%s\n' "$res"
      exit 5
    fi
    rules_4col=$(awk -F '\t' 'NF >= 8 { printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $8 }' "$scan_file")
  fi
  [ -n "$rules_fp" ] && [ "$rules_fp" != "$(sget rules_ack_fp)" ] && rules_open=1
  [ "$rules_open" = 1 ] && case "$verdict" in clean|p3-only) verdict=needs-human ;; esac
  if [ -n "$rbase" ]; then
    if ! bash "$RULES" render "$rbase" "$reviewed" "$rules_fp" "$rules_open" --from-scan "$scan_file" >> "$md"; then
      printf 'VERDICT=error\nREASON=rule-file render failed\nRESULT=%s\n' "$res"
      exit 5
    fi
  fi

  new_rounds_total=$(( $(snum rounds_total) + 1 ))
  new_ric=$(( $(snum rounds_in_cycle) + 1 ))
  new_dsb=$(snum dirty_since_step_back); new_sbd=$(snum step_backs_done)
  if [ "$mode" = "step-back" ]; then
    new_sbd=$(( new_sbd + 1 )); new_dsb=0
  elif [ "$verdict" = "dirty" ]; then
    new_dsb=$(( new_dsb + 1 ))
  fi

  new_cs=$(snum clean_streak)
  new_lch=$(sget last_clean_head); new_lcb=$(sget last_clean_base_sha)
  new_lcp=$(sget last_clean_skip_p3); new_lcm=$(sget last_clean_mode)
  new_bch=$(sget base_converged_head); new_bcb=$(sget base_converged_base_sha)
  new_bcp=$(sget base_converged_skip_p3); new_bcr=$(sget base_converged_round)
  new_prh=$(sget post_rebase_confirmed_head); new_prb=$(sget post_rebase_confirmed_base_sha); new_prr=$(sget post_rebase_confirmed_round)
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
      new_bch=""; new_bcb=""; new_bcp=""; new_bcr=""
      new_prh=""; new_prb=""; new_prr=""
      ;;
  esac

  cur_ar=$(sget active_round_dir); new_ar="$cur_ar"
  [ "$cur_ar" = "$d" ] && new_ar=""
  new_next_id=$(snum next_class_id); is_uint "$nxt" && new_next_id="$nxt"

  tx_dir="$d/tx"
  mkdir -p "$tx_dir" || die "cannot create $tx_dir"

  # Prepare updated active_round.json marking status=finished
  perl -MJSON::PP -e '
    use strict; use warnings;
    my ($af, $out, $v, $pr) = @ARGV;
    my $J = JSON::PP->new->utf8;
    open(my $fh, "<:raw", $af) or die "cannot read $af\n"; local $/; my $obj = $J->decode(<$fh>); close $fh;
    $obj->{status} = "finished";
    $obj->{verdict} = $v;
    $obj->{partialApproved} = $pr if length $pr;
    open(my $oh, ">:raw", $out) or die "cannot write $out\n";
    print $oh $J->pretty->canonical->encode($obj);
    close $oh or die "cannot close $out\n";
  ' "$af" "$tx_dir/active_round.json" "$verdict" "$partial_reason" || die "cannot prepare tx active_round.json"

  {
    cat "$LEDGER"
    printf '\n## Round %s — %s (%s) — %s — %s (P0×%s P1×%s P2×%s P3×%s) — %s\n' \
      "$n" "$mode" "$purpose" "$(git rev-parse --short "$reviewed")" "$verdict" "$c0" "$c1" "$c2" "$c3" "$(now_utc)"
    if [ -n "$slot_chk" ]; then
      printf '  Partial council approved (%s); absent slots: %s\n' "$partial_reason" "$slot_chk"
    fi
    [ -s "$frag" ] && cat "$frag"
    if [ "$rules_open" = 1 ]; then
      printf '#### Rule-file edits awaiting a person (fingerprint %s)\n' "$rules_fp"
      printf '%s\n' "$rules_4col" | awk -F '\t' '$1 == "needs-human" { printf "- %s %s %s\n", $2, $3, $4 }'
    fi
  } > "$tx_dir/ledger.full" || die "cannot prepare tx ledger"

  build_state_file "$tx_dir/state.full" \
    "next_class_id=$new_next_id" \
    "rounds_total=$new_rounds_total" \
    "rounds_in_cycle=$new_ric" \
    "latest_finished_round=$n" \
    "last_reviewed_head=$reviewed" \
    "last_reviewed_base_sha=$rbase" \
    "last_reviewed_mode=$mode" \
    "last_reviewed_purpose=$purpose" \
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
    "active_round_dir=$new_ar"

  recurring=$(compute_recurring "$tx_dir/ledger.full")
  {
    printf 'VERDICT=%s\nPURPOSE=%s\nMODE=%s\nROUND=%s\nP0=%s\nP1=%s\nP2=%s\nP3=%s\n' \
      "$verdict" "$purpose" "$mode" "$n" "$c0" "$c1" "$c2" "$c3"
    printf 'NEW_CLASSES=%s\nREOPENED=%s\nRECURRING=%s\n' "$new" "$reo" "$recurring"
    printf 'DIRTY_SINCE_STEP_BACK=%s/%s\nSTEP_BACKS_DONE=%s/%s\nCLEAN_STREAK=%s\n' \
      "$new_dsb" "$ROUND_CAP" "$new_sbd" "$MAX_STEP_BACKS" "$new_cs"
    printf 'REVIEWED_HEAD=%s\nBASE_SHA=%s\nRESULT=%s\nRESULT_JSON=%s\nLEDGER=%s\n' \
      "$reviewed" "$rbase" "$md" "$res" "$LEDGER"
    if [ -n "$slot_chk" ]; then printf 'ABSENT_SLOTS=%s\n' "$slot_chk"; fi
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
  resolve_paths; ensure_state
  fp="${1:-}"; [ $# -gt 0 ] && shift
  base_arg=""; ign_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] || die "ack-rules: --base requires a value"; base_arg="$2"; shift 2 ;;
      --ignore-project-config) ign_arg=1; shift ;;
      --use-project-config) ign_arg=0; shift ;;
      *) break ;;
    esac
  done
  resolve_knobs "$ign_arg"
  pending=$(sget rules_pending_fp); pverdict=$(sget rules_pending_verdict)
  [ -n "$pending" ] && [ "$pverdict" = "needs-human" ] || die "ack-rules: no needs-human rule-file edits awaiting a person"
  [ "$fp" = "$pending" ] || die "ack-rules: fingerprint '$fp' does not match pending ($pending)"
  pround=$(sget rules_pending_round); lfr=$(snum latest_finished_round)
  [ "$pround" = "$lfr" ] || die "ack-rules: pending rule approval (round $pround) superseded by round $lfr"

  phead=$(sget rules_pending_head); pbase=$(sget rules_pending_base_sha)
  pp3=$(sget rules_pending_skip_p3); pmode=$(sget rules_pending_mode)
  ptf=$(sget rules_pending_tree_fp); phm=$(sget rules_pending_head_moves)

  head=$(git rev-parse HEAD) || die "ack-rules: cannot resolve HEAD"
  [ "$head" = "$phead" ] || die "ack-rules: HEAD mismatch"
  [ "$SKIP_P3" = "$pp3" ] || die "ack-rules: CR_LOOP_SKIP_P3 mismatch"
  if [ -n "$base_arg" ]; then
    bsha=$(git rev-parse --verify --quiet "$base_arg^{commit}") || die "ack-rules: --base '$base_arg' does not resolve"
    [ "$bsha" = "$pbase" ] || die "ack-rules: base mismatch"
  fi
  if [ -n "$phm" ]; then
    cur_hm=$(head_moves) || die "ack-rules: cannot read HEAD reflog"
    [ "$cur_hm" = "$phm" ] || die "ack-rules: HEAD moved and returned since pending round"
  fi
  if [ -n "$ptf" ]; then
    cur_tf=$(tree_fp_v2) || die "ack-rules: cannot snapshot working tree"
    [ "$cur_tf" = "$ptf" ] || die "ack-rules: working tree changed since pending round"
  fi

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
    "rules_pending_fp=" "rules_pending_verdict=" "rules_pending_round=" \
    "rules_pending_head=" "rules_pending_base_sha=" "rules_pending_skip_p3=" \
    "rules_pending_mode=" "rules_pending_tree_fp=" "rules_pending_head_moves=" \
    "clean_streak=$new_cs" \
    "last_clean_head=$phead" "last_clean_base_sha=$pbase" \
    "last_clean_skip_p3=$pp3" "last_clean_mode=$pmode"

  commit_tx "$tx_dir" ack-rules
  rm -rf "$tx_dir"
  printf 'ACKED=%s\nCLEAN_STREAK=%s\n' "$fp" "$new_cs"
}

cmd_mark_converged() {
  resolve_paths; ensure_state
  post_rebase=0; base_arg=""; round_arg=""; ign_arg=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --post-rebase) post_rebase=1; shift ;;
      --base) [ $# -ge 2 ] || die "mark-converged: --base requires a ref"; base_arg="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || die "mark-converged: --round requires a round dir"; round_arg="$2"; shift 2 ;;
      --ignore-project-config) ign_arg=1; shift ;;
      --use-project-config) ign_arg=0; shift ;;
      *) die "mark-converged: unknown arg $1" ;;
    esac
  done
  resolve_knobs "$ign_arg"
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
      rd=$(validate_round_dir "$round_arg"); rn=$(mget "$rd" round)
      [ "$rn" = "$lfr" ] || die "mark-converged --post-rebase: --round ($rn) is not latest finished round ($lfr)"
    else rn="$lfr"
    fi
    [ "$(sget last_clean_head)" = "$head" ] || die "mark-converged --post-rebase: HEAD has no clean confirmation round"
    [ "$(sget last_clean_base_sha)" = "$base_sha" ] || die "mark-converged --post-rebase: base mismatch"
    [ "$(sget last_clean_skip_p3)" = "$SKIP_P3" ] || die "mark-converged --post-rebase: SKIP_P3 mismatch"
    [ "$(sget last_clean_mode)" = "full" ] || die "mark-converged --post-rebase: confirmation round must be full"
    bch_short=$(git rev-parse --short "$bch" 2>/dev/null || printf '%s' "$bch")
    {
      cat "$LEDGER"
      printf '\n## Converged (post-rebase 1-round full confirmation) at %s — %s (prior 2-round convergence: %s, base: %s, round: %s)\n' \
        "$short_head" "$(now_utc)" "$bch_short" "$(git rev-parse --short "$base_sha")" "$rn"
    } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare converged ledger"; }
    build_state_file "$tx_dir/state.full" \
      "post_rebase_confirmed_head=$head" "post_rebase_confirmed_base_sha=$base_sha" "post_rebase_confirmed_round=$rn" \
      "dirty_since_step_back=0" "step_backs_done=0" "rounds_in_cycle=0"
  else
    cs=$(snum clean_streak)
    [ "$cs" -ge 2 ] || die "mark-converged: requires clean_streak >= 2 (got $cs)"
    [ "$(sget last_clean_mode)" = "full" ] || die "mark-converged: second clean round must be full (got '$(sget last_clean_mode)')"
    [ "$(sget last_clean_head)" = "$head" ] || die "mark-converged: HEAD mismatch"
    [ "$(sget last_clean_skip_p3)" = "$SKIP_P3" ] || die "mark-converged: SKIP_P3 mismatch"
    lcb=$(sget last_clean_base_sha)
    if [ -n "$base_sha" ]; then [ "$lcb" = "$base_sha" ] || die "mark-converged: --base mismatch"; fi
    {
      cat "$LEDGER"
      printf '\n## Converged at %s — %s (rounds so far: %s, step-backs: %s)\n' \
        "$short_head" "$(now_utc)" "$(snum rounds_total)" "$(snum step_backs_done)"
    } > "$tx_dir/ledger.full" || { rm -rf "$tx_dir"; die "cannot prepare converged ledger"; }
    build_state_file "$tx_dir/state.full" \
      "base_converged_head=$head" "base_converged_base_sha=$lcb" "base_converged_skip_p3=$SKIP_P3" "base_converged_round=$lfr" \
      "post_rebase_confirmed_head=" "post_rebase_confirmed_base_sha=" "post_rebase_confirmed_round=" \
      "dirty_since_step_back=0" "step_backs_done=0" "rounds_in_cycle=0"
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
      stmp="$STATE.tmp.$$"
      build_state_file "$stmp" "rel_pre_rebase_head=" "rel_pinned_remote_head_sha=" "rel_target_base_sha=" "rel_rebased_in_8_0=0"
      mv "$stmp" "$STATE" || { rm -f "$stmp"; die "release-state clear failed"; }
      printf 'RELEASE_STATE_CLEARED\n'
      ;;
    *) die "release-state: expected get | set | clear" ;;
  esac
}

cmd_note() {
  resolve_paths; ensure_state
  [ $# -gt 0 ] || die "note: text required"
  ltmp="$LEDGER.tmp.$$"
  { cat "$LEDGER"; printf -- '- note %s @%s: %s\n' "$(now_utc)" "$(git rev-parse --short HEAD)" "$*"; } > "$ltmp" \
    && mv "$ltmp" "$LEDGER" || { rm -f "$ltmp"; die "cannot update ledger"; }
  printf 'NOTED\n'
}

cmd_add() {
  resolve_paths; ensure_state
  sev="${1:-}"; title="${2:-}"; detail="${3:-}"
  case "$sev" in P0|P1|P2|P3) ;; *) die "add: severity must be P0..P3" ;; esac
  [ -n "$title" ] || die "add: title required"
  id="C$(snum next_class_id)"; new_nxt=$(( $(snum next_class_id) + 1 ))
  tx_dir="$STATE_DIR/tx-add.$$"; mkdir -p "$tx_dir" || die "cannot create $tx_dir"
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

cmd_reset() {
  resolve_paths
  [ -d "$STATE_DIR" ] || { printf 'NOTHING_TO_RESET\n'; return 0; }
  validate_branch_ownership
  recover_pending_tx
  ar=$(sget active_round_dir)
  if [ -n "$ar" ] && [ -d "$ar" ] && [ ! -f "$ar/finished" ]; then
    die "an active round is open ($ar) — cancel-round first"
  fi
  dest="$STATE_DIR.archived-$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$STATE_DIR" "$dest" || die "cannot archive $STATE_DIR"
  printf 'ARCHIVED=%s\n' "$dest"
}

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
  init|next|prepare|claim-slot|record-dispatch|update-slot|record-result|round-summary|cancel-round|finish|ack-rules|mark-converged|release-state|note|add|reset)
    [ -n "${T3_CR_LOCK_HELD:-}" ] || with_branch_lock "$@" ;;
esac
[ $# -gt 0 ] && shift
case "$sub" in
  config-path)               cmd_config_path "$@" ;;
  config-show)               cmd_config_show "$@" ;;
  config-set)                cmd_config_set "$@" ;;
  config-authorize-provider) cmd_config_authorize_provider "$@" ;;
  init)                      cmd_init "$@" ;;
  next)                      cmd_next "$@" ;;
  prepare)                   cmd_prepare "$@" ;;
  claim-slot)                cmd_claim_slot "$@" ;;
  record-dispatch)           cmd_record_dispatch "$@" ;;
  update-slot)               cmd_update_slot "$@" ;;
  record-result)             cmd_record_result "$@" ;;
  round-summary)             cmd_round_summary "$@" ;;
  cancel-round)              cmd_cancel_round "$@" ;;
  finish)                    cmd_finish "$@" ;;
  ack-rules)                 cmd_ack_rules "$@" ;;
  mark-converged)            cmd_mark_converged "$@" ;;
  release-state)             cmd_release_state "$@" ;;
  note)                      cmd_note "$@" ;;
  add)                       cmd_add "$@" ;;
  reset)                     cmd_reset "$@" ;;
  paths)                     cmd_paths "$@" ;;
  tree-clean)                cmd_tree_clean "$@" ;;
  ''|-h|--help|help)         sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)                         die "unknown subcommand '$sub' (try --help)" ;;
esac
