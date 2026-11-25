#!/usr/bin/env perl
# t3-tri-plan-state.pl — Core atomic state, transaction, config, async run/slot,
# review convergence, freshness, and Phase 6 activation engine for t3-tri-plan v1.0.0.

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path getcwd);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(:flock O_RDWR O_CREAT O_NONBLOCK F_GETFD F_SETFD FD_CLOEXEC);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec ();
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use POSIX qw(strftime);
use lib "$Bin/lib";

use StrictJson qw(
  decode_strict_typed decode_strict unwrap_typed
  encode_canonical encode_compact encode_compact_chars
  load_json_file load_json_file_typed
);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
use TriTx qw(
  sha256_file sha256_bytes with_task_lock
  check_stale_readonly recover_tx execute_tx
  compute_worktree_fp compare_worktree_fp
  scan_repo_rules compute_non_prd_baseline compute_review_baseline
  ensure_no_symlink_components
  write_atomic_bytes read_raw_file
);

my $VALIDATE_CAND  = "$Bin/validate-candidate.pl";
my $VALIDATE_JUDGE = "$Bin/validate-blind-eval.pl";
my $PARSE_REVIEW   = "$Bin/parse-design-review.pl";

sub now_iso { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime()); }
sub die_err { my ($msg, $code) = @_; $code ||= 2; $msg =~ s/\r?\n/ /g; print STDERR "t3-tri-plan-state: $msg\n"; exit $code; }

sub user_config_path {
  return $ENV{T3_TRI_PLAN_CONFIG} if defined $ENV{T3_TRI_PLAN_CONFIG} && length $ENV{T3_TRI_PLAN_CONFIG};
  my $home = $ENV{HOME} // die_err("HOME is not set");
  return "$home/.config/t3-tri-plan/config.json";
}

sub resolve_repo_root {
  my ($explicit, $task_dir) = @_;
  if (defined $explicit && length $explicit) {
    my $r = abs_path($explicit) // die_err("invalid --repo $explicit");
    return $r;
  }
  my $probe = defined $task_dir && -d $task_dir ? abs_path($task_dir) : getcwd();
  open(my $ph, '-|', 'git', '-C', $probe, 'rev-parse', '--show-toplevel') or die_err("cannot run git rev-parse");
  my $out = <$ph>;
  close $ph;
  if (_decode_wait_status($?) == 0 && defined $out) {
    $out =~ s/\r?\n$//;
    return abs_path($out) // $out if length $out;
  }
  return abs_path($probe) // $probe;
}

sub task_rel_path {
  my ($repo_root, $real_task) = @_;
  my $rel = File::Spec->abs2rel($real_task, $repo_root);
  $rel =~ s{\\}{/}g;
  return '' if $rel =~ m{\A\.\./};
  my $dec = eval { decode('UTF-8', $rel, FB_CROAK | LEAVE_SRC) };
  return $@ ? $rel : $dec;
}

sub _decode_cli_text {
  my ($raw, $flag) = @_;
  return undef unless defined $raw;
  my $dec = eval { decode('UTF-8', $raw, FB_CROAK | LEAVE_SRC) };
  die_err("invalid UTF-8 bytes in $flag") if $@;
  return $dec;
}

# Join a raw OS-byte base path with decoded logical relative segments, keeping the result pure raw OS bytes (SvUTF8=0).
sub _fs_join {
  my ($base_bytes, @rel_chars) = @_;
  return File::Spec->catfile($base_bytes, map { encode('UTF-8', $_) } @rel_chars);
}

# Decode a raw OS-byte path to Perl characters before printing to :encoding(UTF-8) STDOUT/STDERR (prevents double-encoding!).
sub _display_path {
  my ($bytes) = @_;
  return '' unless defined $bytes;
  my $dec = eval { decode('UTF-8', $bytes, FB_CROAK | LEAVE_SRC) };
  return $@ ? $bytes : $dec;
}

sub _decode_wait_status {
  my ($status) = @_;
  return 127 if !defined($status) || $status == -1;
  my $sig = $status & 127;
  return 128 + $sig if $sig;
  return $status >> 8;
}

sub run_cmd_capture {
  my (@cmd) = @_;
  my $pid = open(my $ph, '-|');
  die_err("fork failed: $!") unless defined $pid;
  if ($pid == 0) {
    open(STDERR, '>&STDOUT');
    exec(@cmd) or exit 127;
  }
  local $/;
  my $out = <$ph>;
  close $ph;
  my $rc = _decode_wait_status($?);
  return ($rc, defined $out ? $out : '');
}

sub run_cmd_capture_split_opts {
  my ($opts, @cmd) = @_;
  my $cwd          = $opts->{cwd};
  my $env_override = $opts->{env};
  my $inherit_fh   = $opts->{inherit_fh};

  my $tmp_dir = tempdir('t3-tri-cmd-XXXXXX', TMPDIR => 1, CLEANUP => 1);
  my $out_f   = "$tmp_dir/out";
  my $err_f   = "$tmp_dir/err";
  my $pid = fork();
  die_err("fork failed: $!") unless defined $pid;
  if ($pid == 0) {
    chdir($cwd) if defined $cwd && length $cwd;
    if ($env_override) {
      for my $k (keys %$env_override) {
        if (defined $env_override->{$k}) { $ENV{$k} = $env_override->{$k}; }
        else                             { delete $ENV{$k}; }
      }
    }
    if (defined $inherit_fh) {
      # Clear FD_CLOEXEC ONLY in child before exec so the spawned command inherits
      # the open file description holding flock() even if parent Perl dies!
      my $flags = fcntl($inherit_fh, F_GETFD, 0);
      if (defined $flags) {
        fcntl($inherit_fh, F_SETFD, $flags & ~FD_CLOEXEC);
      }
    }
    open(STDOUT, '>', $out_f) or exit 126;
    open(STDERR, '>', $err_f) or exit 126;
    exec(@cmd) or exit 127;
  }
  my $wp = waitpid($pid, 0);
  my $rc = ($wp == $pid) ? _decode_wait_status($?) : 127;
  my $out = (-f $out_f) ? read_raw_file($out_f) : '';
  my $err = (-f $err_f) ? read_raw_file($err_f) : '';
  return ($rc, $out, $err);
}

sub run_cmd_capture_split {
  my ($cwd, $env_override, @cmd) = @_;
  return run_cmd_capture_split_opts({ cwd => $cwd, env => $env_override }, @cmd);
}

sub parse_kv_lines {
  my ($text) = @_;
  my %kv;
  for my $l (split(/\r?\n/, $text // '')) {
    if ($l =~ /\A([A-Z0-9_]+)=(.*)\z/) { $kv{$1} = $2; }
  }
  return \%kv;
}

sub state_path { my ($plans_dir) = @_; return "$plans_dir/planning-state.json"; }
sub load_state_or_undef {
  my ($plans_dir) = @_;
  my $sf = state_path($plans_dir);
  return undef unless -f $sf;
  return load_json_file($sf);
}

sub _effective_ignore_project_config {
  my ($st, $opt) = @_;
  $opt ||= {};
  return 0 if $opt->{use_project_config};
  return 1 if $opt->{ignore_project_config};
  return 1 if ($ENV{T3_TRI_PLAN_IGNORE_PROJECT_CONFIG} // '') eq '1';
  return 1 if ref($st) eq 'HASH' && $st->{ignore_project_config};
  return 0;
}

sub _with_activation_lock_guard {
  my ($plans_dir, $op_name, $code) = @_;
  my $act_fh = _try_activation_lock($plans_dir);
  if (!$act_fh) {
    print "ACTIVATION_IN_PROGRESS=1\nREASON=cannot run $op_name while Phase 6 activation holds .activation.lock\n";
    exit 5;
  }
  my @res;
  my $want = wantarray;
  my $ok = eval {
    if ($want) { @res = $code->(); }
    else       { $res[0] = $code->(); }
    1;
  };
  my $err = $@;
  flock($act_fh, LOCK_UN);
  close $act_fh;
  die $err unless $ok;
  return $want ? @res : $res[0];
}

sub _guard_phase6_not_in_flight {
  my ($st, $op_name) = @_;
  return unless ref($st) eq 'HASH' && ref($st->{phases}) eq 'HASH' && ref($st->{phases}{'6'}) eq 'HASH';
  my $p6_st = $st->{phases}{'6'}{state} // 'none';
  if ($p6_st eq 'activating' || $p6_st eq 'activation_uncertain') {
    die_err("cannot run $op_name while Phase 6 is '$p6_st' — run recover-activation, cancel-activating, or resolve-activation first", 3);
  }
}

sub resolve_configured_knobs {
  my ($repo_root, $ignore_project) = @_;
  my %knobs = (
    roundCap            => 3,
    maxStepBacks        => 1,
    has_round_cap       => 0,
    has_max_step_backs  => 0,
  );
  my $apply = sub {
    my ($path, $is_proj) = @_;
    return unless defined $path && length $path && -f $path && !-l $path;
    my $typed = eval { load_json_file_typed($path) };
    return if $@;
    my $errs = validate_config_typed($typed, $is_proj);
    return if @$errs;
    my $cfg = unwrap_typed($typed);
    return unless ref($cfg->{knobs}) eq 'HASH';
    if (defined $cfg->{knobs}{roundCap}) {
      $knobs{roundCap}      = int($cfg->{knobs}{roundCap});
      $knobs{has_round_cap} = 1;
    }
    if (defined $cfg->{knobs}{maxStepBacks}) {
      $knobs{maxStepBacks}       = int($cfg->{knobs}{maxStepBacks});
      $knobs{has_max_step_backs} = 1;
    }
  };
  my $ucfg = eval { user_config_path() };
  $apply->($ucfg, 0) if defined $ucfg && length $ucfg;
  if (!$ignore_project && defined $repo_root && length $repo_root) {
    $apply->("$repo_root/.t3-tri-plan.json", 1);
  }
  return \%knobs;
}

sub _init_fresh_review {
  my ($knobs) = @_;
  my $rcap = (ref($knobs) eq 'HASH' && defined $knobs->{roundCap})     ? int($knobs->{roundCap})     : 3;
  my $sbm  = (ref($knobs) eq 'HASH' && defined $knobs->{maxStepBacks}) ? int($knobs->{maxStepBacks}) : 1;
  return {
    rounds                        => [],
    classes                       => {},
    next_class_num                => 1,
    dirty_since_step_back         => 0,
    step_backs_done               => 0,
    max_step_backs_allowed        => $sbm,
    extra_step_backs_granted      => 0,
    round_cap                     => $rcap,
    clean_streak                  => 0,
    last_clean_mode               => '',
    last_clean_baseline_sha256    => '',
    last_clean_prd_sha256         => '',
    last_clean_non_prd_sha256     => '',
    last_reviewed_design_sha256   => '',
    last_reviewed_snapshot        => '',
    step_back_assessment_status   => 'none',
    pending_scope_decision        => JSON::PP::false,
    converged_at_round            => undef,
    converged_baseline_sha256     => '',
    converged_prd_sha256          => '',
    converged_non_prd_sha256      => '',
    converged_ledger_sha256       => '',
    user_decision                 => undef,
  };
}

sub init_fresh_state {
  my ($prd_sha, $auth, $knobs, $ignore_proj) = @_;
  return {
    pipeline              => 't3-tri-plan',
    schema_version        => 2,
    generation            => 1,
    owner_generation      => 1,
    last_tx_id            => '',
    ignore_project_config => $ignore_proj ? JSON::PP::true : JSON::PP::false,
    prd_lineage           => $prd_sha,
    effective_prd_sha256  => $prd_sha,
    prd_wording_updates   => [],
    wording_equivalent_prd_shas => [ $prd_sha ],
    authorization         => ($auth // ''),
    phases                => {
      '0' => {
        status         => 'completed',
        prd            => $prd_sha,
        prd_sha256     => $prd_sha,
        effective_prd_sha256 => $prd_sha,
        completed_at   => now_iso(),
      },
    },
    blind_map          => {},
    design_revisions   => [],
    orphaned_attempts  => [],
    review             => _init_fresh_review($knobs),
  };
}

# Validate user or project config typed AST strictly.
sub _validate_model_spec_typed {
  my ($node, $ctx, $errs) = @_;
  unless ($node && $node->[0] eq 'obj') { push @$errs, "$ctx must be an object"; return; }
  my $h = $node->[1];
  my %req = map { $_ => 1 } qw(providerInstanceId model effortKey effort);
  for my $k (sort keys %req) {
    if (!exists $h->{$k}) { push @$errs, "$ctx missing '$k'"; }
    elsif ($h->{$k}[0] ne 'str') { push @$errs, "$ctx.$k must be a string"; }
    elsif (($k eq 'providerInstanceId' || $k eq 'model') && $h->{$k}[1] !~ /\S/) { push @$errs, "$ctx.$k must be non-empty"; }
  }
  for my $k (sort keys %$h) {
    push @$errs, "$ctx has unexpected property '$k'" unless $req{$k};
  }
  if (exists $h->{effortKey} && $h->{effortKey}[0] eq 'str' && !length($h->{effortKey}[1]) &&
      exists $h->{effort} && $h->{effort}[0] eq 'str' && length($h->{effort}[1])) {
    push @$errs, "$ctx.effort must be empty when effortKey is empty";
  }
}

sub _validate_group_typed {
  my ($node, $ctx, $min_members, $errs) = @_;
  unless ($node && $node->[0] eq 'obj') { push @$errs, "$ctx must be an object"; return; }
  my $h = $node->[1];
  my %allowed = map { $_ => 1 } qw(effortMode unifiedEffort members);
  for my $k (sort keys %$h) { push @$errs, "$ctx has unexpected property '$k'" unless $allowed{$k}; }
  if (!exists $h->{effortMode} || $h->{effortMode}[0] ne 'str' || ($h->{effortMode}[1] ne 'unified' && $h->{effortMode}[1] ne 'per-model')) {
    push @$errs, "$ctx.effortMode must be 'unified' or 'per-model'";
  }
  my $emode = (exists $h->{effortMode} && $h->{effortMode}[0] eq 'str') ? $h->{effortMode}[1] : '';
  my $ue = '';
  if (exists $h->{unifiedEffort}) {
    if ($h->{unifiedEffort}[0] ne 'str') { push @$errs, "$ctx.unifiedEffort must be a string"; }
    else { $ue = $h->{unifiedEffort}[1]; }
  }
  if ($emode eq 'unified' && !length $ue) {
    push @$errs, "$ctx.unifiedEffort is required when effortMode is 'unified'";
  }
  if (!exists $h->{members} || $h->{members}[0] ne 'arr' || @{$h->{members}[1]} < $min_members) {
    push @$errs, "$ctx.members must be an array with at least $min_members entries";
    return;
  }
  my %seen_pair;
  my $idx = 0;
  for my $m (@{$h->{members}[1]}) {
    $idx++;
    _validate_model_spec_typed($m, "$ctx.members[$idx]", $errs);
    if ($m && $m->[0] eq 'obj') {
      my $mh = $m->[1];
      if (exists $mh->{providerInstanceId} && $mh->{providerInstanceId}[0] eq 'str' &&
          exists $mh->{model} && $mh->{model}[0] eq 'str') {
        my $pair = "$mh->{providerInstanceId}[1]/$mh->{model}[1]";
        push @$errs, "$ctx has duplicate model '$pair'" if $seen_pair{$pair}++;
      }
      if ($emode eq 'unified') {
        if (exists $mh->{effortKey} && $mh->{effortKey}[0] eq 'str' && !length($mh->{effortKey}[1])) {
          push @$errs, "$ctx.members[$idx].effortKey must be non-empty when effortMode is 'unified'";
        }
        if (length $ue && exists $mh->{effort} && $mh->{effort}[0] eq 'str') {
          if (length($mh->{effort}[1]) && $mh->{effort}[1] ne $ue) {
            push @$errs, "$ctx.members[$idx].effort '$mh->{effort}[1]' conflicts with unifiedEffort '$ue'";
          }
        }
      }
    }
  }
}

sub validate_config_typed {
  my ($node, $is_project) = @_;
  my @errs;
  unless ($node && $node->[0] eq 'obj') { return ["config root must be a JSON object"]; }
  my $h = $node->[1];
  my %allowed = map { $_ => 1 } ($is_project
    ? qw(version designers defaultReviewer judge reviewCouncil knobs)
    : qw(version authorizedProviders designers defaultReviewer judge reviewCouncil knobs));
  for my $k (sort keys %$h) {
    if ($is_project && $k eq 'authorizedProviders') {
      push @errs, "project config MUST NOT contain 'authorizedProviders'";
    } elsif (!$allowed{$k}) {
      push @errs, "unexpected config property '$k'";
    }
  }
  if (!$is_project) {
    for my $rk (qw(version authorizedProviders designers defaultReviewer reviewCouncil)) {
      push @errs, "user config missing required key '$rk'" unless exists $h->{$rk};
    }
  }
  if (exists $h->{version}) {
    if ($h->{version}[0] ne 'num' || !$h->{version}[2] || $h->{version}[1] != 1) {
      push @errs, "config version must be integer 1";
    }
  }
  if (!$is_project && exists $h->{authorizedProviders}) {
    if ($h->{authorizedProviders}[0] ne 'arr') {
      push @errs, "authorizedProviders must be an array";
    } else {
      for my $i (0 .. $#{$h->{authorizedProviders}[1]}) {
        my $el = $h->{authorizedProviders}[1][$i];
        push @errs, "authorizedProviders[$i] must be a non-empty string" unless $el->[0] eq 'str' && $el->[1] =~ /\S/;
      }
    }
  }
  _validate_group_typed($h->{designers}, 'designers', 2, \@errs) if exists $h->{designers};
  _validate_model_spec_typed($h->{defaultReviewer}, 'defaultReviewer', \@errs) if exists $h->{defaultReviewer};
  _validate_model_spec_typed($h->{judge}, 'judge', \@errs) if exists $h->{judge};
  _validate_group_typed($h->{reviewCouncil}, 'reviewCouncil', 1, \@errs) if exists $h->{reviewCouncil};
  if (exists $h->{knobs}) {
    if ($h->{knobs}[0] ne 'obj') { push @errs, "knobs must be an object"; }
    else {
      my $kh = $h->{knobs}[1];
      for my $k (sort keys %$kh) {
        if ($k ne 'roundCap' && $k ne 'maxStepBacks') { push @errs, "unknown knob '$k'"; next; }
        if ($kh->{$k}[0] ne 'num' || !$kh->{$k}[2] || $kh->{$k}[1] < 0) {
          push @errs, "knobs.$k must be a non-negative integer";
        }
      }
    }
  }
  return \@errs;
}

# =============================================================================
# Commands: config-set / config-authorize-provider / config-show
# =============================================================================

sub cmd_config_set {
  my ($file) = @_;
  die_err("config-set requires --file <path>") unless defined $file && -f $file;
  my $typed = eval { load_json_file_typed($file) };
  die_err("invalid JSON in $file: $@") if $@;
  my $errs = validate_config_typed($typed, 0);
  if (@$errs) {
    print "CONFIG_VALID=0\n";
    print "CONFIG_ERROR=$_\n" for @$errs;
    exit 3;
  }
  my $u = unwrap_typed($typed);
  # Normalize unified effort onto every member on save; omit unifiedEffort on per-model groups.
  for my $gk (qw(designers reviewCouncil)) {
    if ($u->{$gk}{effortMode} eq 'unified') {
      my $ue = $u->{$gk}{unifiedEffort};
      $_->{effort} = $ue for @{$u->{$gk}{members}};
    } else {
      delete $u->{$gk}{unifiedEffort};
    }
  }
  my $ucfg = user_config_path();
  write_atomic_bytes($ucfg, encode_canonical($u), 0600);
  print "CONFIG_SAVED=" . _display_path($ucfg) . "\n";
}

sub cmd_config_authorize_provider {
  my ($pid) = @_;
  die_err("config-authorize-provider requires <providerInstanceId>") unless defined $pid && length $pid;
  my $ucfg = user_config_path();
  die_err("user config does not exist: " . _display_path($ucfg)) unless -f $ucfg;
  my $u = load_json_file($ucfg);
  my %seen = map { $_ => 1 } @{$u->{authorizedProviders} || []};
  push @{$u->{authorizedProviders}}, $pid unless $seen{$pid};
  @{$u->{authorizedProviders}} = sort @{$u->{authorizedProviders}};
  write_atomic_bytes($ucfg, encode_canonical($u), 0600);
  print "AUTHORIZED_PROVIDER=$pid\n";
}

sub cmd_config_show {
  my %opt = @_;
  my $ucfg = user_config_path();
  my $st_ro;
  if (defined $opt{task} && -d $opt{task} && !-l $opt{task}) {
    my $rt = abs_path($opt{task});
    if (defined $rt && -f "$rt/research/plans/planning-state.json" && !-l "$rt/research/plans/planning-state.json") {
      my $loaded = eval { load_json_file("$rt/research/plans/planning-state.json") };
      $st_ro = $loaded if !$@ && ref $loaded eq 'HASH';
    }
  }
  my $repo = resolve_repo_root($opt{repo}, $opt{task});
  my $pcfg_on_disk = (-f "$repo/.t3-tri-plan.json") ? "$repo/.t3-tri-plan.json" : '';
  my $ign_proj = _effective_ignore_project_config($st_ro, \%opt);
  my $pcfg = ($ign_proj ? '' : $pcfg_on_disk);

  if (!-f $ucfg) {
    print "CONFIGURED=0\n";
    print "USER_CONFIG=" . _display_path($ucfg) . "\n";
    print "PROJECT_CONFIG=" . _display_path($pcfg) . "\n" if length $pcfg;
    print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj && length $pcfg_on_disk;
    return;
  }

  my $u_typed = eval { load_json_file_typed($ucfg) };
  if ($@) { print "CONFIGURED=1\nCONFIG_VALID=0\nCONFIG_ERROR=invalid user config JSON: $@\n"; exit 3; }
  my $uerrs = validate_config_typed($u_typed, 0);
  if (@$uerrs) {
    print "CONFIGURED=1\nCONFIG_VALID=0\n";
    print "CONFIG_ERROR=user config: $_\n" for @$uerrs;
    exit 3;
  }
  my $u = unwrap_typed($u_typed);

  my $p;
  if (length $pcfg) {
    my $p_typed = eval { load_json_file_typed($pcfg) };
    if ($@) { print "CONFIGURED=1\nCONFIG_VALID=0\nCONFIG_ERROR=invalid project config JSON: $@\n"; exit 3; }
    my $perrs = validate_config_typed($p_typed, 1);
    if (@$perrs) {
      print "CONFIGURED=1\nCONFIG_VALID=0\n";
      print "CONFIG_ERROR=project config: $_\n" for @$perrs;
      exit 3;
    }
    $p = unwrap_typed($p_typed);
  }

  my @errors;
  # Check override conflicts first.
  if (length($opt{single} // '') && (length($opt{ov_model} // '') || length($opt{ov_council} // ''))) {
    push @errors, "--single conflicts with --override-model and --override-council";
  }

  my %auth = map { $_ => 1 } @{$u->{authorizedProviders} || []};
  my $clone_spec = sub { my ($s) = @_; return { %$s }; };
  my $clone_grp  = sub {
    my ($g) = @_;
    return {
      effortMode => $g->{effortMode},
      (defined($g->{unifiedEffort}) && length($g->{unifiedEffort}) ? (unifiedEffort => $g->{unifiedEffort}) : ()),
      members    => [ map { { %$_ } } @{$g->{members}} ],
    };
  };

  my $designers = $clone_grp->($u->{designers});
  my $def_rev   = $clone_spec->($u->{defaultReviewer});
  my $judge_cfg_base = $u->{judge} ? $clone_spec->($u->{judge}) : $clone_spec->($u->{defaultReviewer});
  my $council   = $clone_grp->($u->{reviewCouncil});
  my $knobs     = { roundCap => 3, maxStepBacks => 1, %{$u->{knobs} || {}} };

  my $proj_overrode = 0;
  my %proj_providers;
  if ($p) {
    if ($p->{designers}) {
      $proj_overrode = 1;
      $designers = $clone_grp->($p->{designers});
      $proj_providers{$_->{providerInstanceId}} = 1 for @{$designers->{members}};
    }
    if ($p->{defaultReviewer}) {
      $proj_overrode = 1;
      $def_rev = $clone_spec->($p->{defaultReviewer});
      $proj_providers{$def_rev->{providerInstanceId}} = 1;
      # If neither user nor project configured explicit judge, judge inherits effective config defaultReviewer.
      if (!$u->{judge} && !$p->{judge}) {
        $judge_cfg_base = $clone_spec->($p->{defaultReviewer});
      }
    }
    if ($p->{judge}) {
      $proj_overrode = 1;
      $judge_cfg_base = $clone_spec->($p->{judge});
      $proj_providers{$judge_cfg_base->{providerInstanceId}} = 1;
    }
    if ($p->{reviewCouncil}) {
      $proj_overrode = 1;
      $council = $clone_grp->($p->{reviewCouncil});
      $proj_providers{$_->{providerInstanceId}} = 1 for @{$council->{members}};
    }
    if ($p->{knobs}) {
      $proj_overrode = 1;
      $knobs->{$_} = $p->{knobs}{$_} for keys %{$p->{knobs}};
    }
  }
  my $judge = $clone_spec->($judge_cfg_base);

  # Build live capability lookup if supplied.
  my (%cap_prov, %cap_model);
  my $caps_loaded = 0;
  my $inherited_pid = '';
  if (length($opt{caps} // '')) {
    my $caps = eval { load_json_file($opt{caps}) };
    if ($@ || ref $caps ne 'HASH' || (exists $caps->{providers} && ref $caps->{providers} ne 'ARRAY')) {
      push @errors, "cannot parse --capabilities JSON: $@";
    } else {
      $caps_loaded = 1;
      $inherited_pid = $caps->{inheritedProviderInstanceId} // '';
      for my $pr (@{$caps->{providers} || []}) {
        my $pid = $pr->{providerInstanceId} // next;
        $cap_prov{$pid} = $pr;
        for my $m (@{$pr->{models} || []}) {
          my $mid = $m->{id} // next;
          my ($ek, $evals, $edef) = ('', [], '');
          for my $o (@{$m->{options} || []}) {
            if (($o->{id} // '') =~ /\A(thought_level|effort|reasoningEffort)\z/) {
              $ek    = $o->{id};
              $evals = $o->{values} || [];
              $edef  = $o->{default} // '';
              last;
            }
          }
          $cap_model{"$pid/$mid"} = {
            providerInstanceId          => $pid,
            driverKind                  => $pr->{driverKind} // $pid,
            model                       => $mid,
            canRunChildTask             => $pr->{canRunChildTask} ? 1 : 0,
            canRunCrossProviderChildTask => defined $pr->{canRunCrossProviderChildTask}
              ? ($pr->{canRunCrossProviderChildTask} ? 1 : 0)
              : ($pr->{canRunChildTask} ? 1 : 0),
            effortKey                   => $ek,
            effortValues                => $evals,
            effortDefault               => $edef,
          };
        }
      }
    }
  }

  my $parse_spec = sub {
    my ($spec, $fallback_effort, $label) = @_;
    my ($left, $inline_eff) = split(/:/, $spec, 2);
    my $has_inline = (defined $inline_eff && length $inline_eff) ? 1 : 0;
    my $eff = $has_inline ? $inline_eff : ($fallback_effort // '');
    my ($pid, $mid);
    if ($left =~ m{\A([^/]+)/(.+)\z}) {
      ($pid, $mid) = ($1, $2);
    } else {
      $mid = $left;
      my @hits = grep { $cap_model{$_}{model} eq $mid && $cap_model{$_}{canRunChildTask} } sort keys %cap_model;
      if    (@hits == 1) { $pid = $cap_model{$hits[0]}{providerInstanceId}; }
      elsif (@hits > 1)  { push @errors, "$label ambiguous model '$mid' across providers — use providerInstanceId/model"; return undef; }
      else               { push @errors, "$label cannot resolve provider for model '$mid' (pass providerInstanceId/model)"; return undef; }
    }
    my $ek = (exists $cap_model{"$pid/$mid"}) ? $cap_model{"$pid/$mid"}{effortKey} : '';
    return ({ providerInstanceId => $pid, model => $mid, effortKey => $ek, effort => $eff }, $has_inline);
  };

  my $ov_eff = $opt{ov_effort} // '';
  my %user_override_providers;

  # Apply per-call overrides according to exact precedence table.
  # 1. designers=
  if (length($opt{ov_designers} // '')) {
    my (@mems, $any_inline);
    $any_inline = 0;
    for my $tok (split(/,/, $opt{ov_designers})) {
      $tok =~ s/^\s+|\s+$//g;
      next unless length $tok;
      my ($m, $hi) = $parse_spec->($tok, $ov_eff, 'designers');
      next unless $m;
      $any_inline = 1 if $hi;
      $user_override_providers{$m->{providerInstanceId}} = 1;
      push @mems, $m;
    }
    if (!@mems) { push @errors, "--override-designers produced no designers"; }
    else {
      my $emode = (!$any_inline && length $ov_eff) ? 'unified' : 'per-model';
      $designers = {
        effortMode => $emode,
        ($emode eq 'unified' ? (unifiedEffort => $ov_eff) : ()),
        members    => \@mems,
      };
    }
  }

  # 2. judge= (ONLY explicit --override-judge alters judge!)
  if (length($opt{ov_judge} // '')) {
    my ($j) = $parse_spec->($opt{ov_judge}, $ov_eff, 'judge');
    if ($j) {
      $judge = $j;
      $user_override_providers{$j->{providerInstanceId}} = 1;
    }
  }

  # 3. single= vs model= / council= (strictly Phase 3; NEVER touches judge!)
  if (length($opt{single} // '')) {
    my ($s) = $parse_spec->($opt{single}, $ov_eff, 'single');
    if ($s) {
      $def_rev = { %$s };
      $council = { effortMode => 'per-model', members => [ { %$s } ] };
      $user_override_providers{$s->{providerInstanceId}} = 1;
    }
  } else {
    if (length($opt{ov_model} // '')) {
      my ($m) = $parse_spec->($opt{ov_model}, (length $ov_eff ? $ov_eff : $def_rev->{effort}), 'model');
      if ($m) {
        $def_rev = $m;
        $user_override_providers{$m->{providerInstanceId}} = 1;
      }
    } elsif (length $ov_eff) {
      $def_rev->{effort} = $ov_eff;
    }
    if (length($opt{ov_council} // '')) {
      my (@mems, $any_inline);
      $any_inline = 0;
      for my $tok (split(/,/, $opt{ov_council})) {
        $tok =~ s/^\s+|\s+$//g;
        next unless length $tok;
        my ($m, $hi) = $parse_spec->($tok, $ov_eff, 'council');
        next unless $m;
        $any_inline = 1 if $hi;
        $user_override_providers{$m->{providerInstanceId}} = 1;
        push @mems, $m;
      }
      if (!@mems) { push @errors, "--override-council produced no reviewers"; }
      else {
        my $emode = (!$any_inline && length $ov_eff) ? 'unified' : 'per-model';
        $council = {
          effortMode => $emode,
          ($emode eq 'unified' ? (unifiedEffort => $ov_eff) : ()),
          members    => \@mems,
        };
      }
    } elsif (length($ov_eff) && !length($opt{ov_model} // '') && !length($opt{ov_designers} // '') && !length($opt{ov_judge} // '')) {
      # Global effort= passed alone: also apply to unified council & designers (validated against strict intersection below).
      if (($council->{effortMode} // '') eq 'unified') {
        $council->{unifiedEffort} = $ov_eff;
      }
      if (($designers->{effortMode} // '') eq 'unified') {
        $designers->{unifiedEffort} = $ov_eff;
      }
    }
  }

  # Enforce unified effort actively onto EVERY member of unified groups!
  for my $pair (['designers', $designers], ['reviewCouncil', $council]) {
    my ($gname, $grp) = @$pair;
    if (($grp->{effortMode} // '') eq 'unified') {
      my $ue = $grp->{unifiedEffort} // '';
      if (!length $ue) {
        push @errors, "$gname has effortMode=unified without unifiedEffort";
      } else {
        $_->{effort} = $ue for @{$grp->{members}};
      }
    }
  }

  # Check uniqueness & minimum cardinality of designers and reviewCouncil.
  {
    my %seen_d;
    for my $m (@{$designers->{members}}) {
      my $k = "$m->{providerInstanceId}/$m->{model}";
      push @errors, "designers contains duplicate model '$k'" if $seen_d{$k}++;
    }
    my $n_d = scalar @{$designers->{members}};
    if ($n_d < 2) {
      push @errors, "designers requires at least 2 distinct models (got $n_d)";
    } elsif ($n_d != 3 && !$opt{allow_non_tri}) {
      push @errors, "designers requires 3 distinct models for triple-blind design (got $n_d; pass --allow-non-tri to override)";
    }
    my %seen_c;
    for my $m (@{$council->{members}}) {
      my $k = "$m->{providerInstanceId}/$m->{model}";
      push @errors, "reviewCouncil contains duplicate model '$k'" if $seen_c{$k}++;
    }
  }

  # Validate every actual dispatch target against live capabilities (even if providers/models list is empty!).
  if ($caps_loaded) {
    my $check_one = sub {
      my ($rv, $label) = @_;
      my $key = "$rv->{providerInstanceId}/$rv->{model}";
      my $cm = $cap_model{$key};
      if (!$cm) {
        push @errors, "$label model '$key' not found in capabilities (use orchestrator_capabilities search if omitted)";
        return;
      }
      if (!$cm->{canRunChildTask}) {
        push @errors, "$label provider '$rv->{providerInstanceId}' cannot run child tasks";
        return;
      }
      if (length($inherited_pid) && $rv->{providerInstanceId} ne $inherited_pid && !$cm->{canRunCrossProviderChildTask}) {
        push @errors, "$label provider '$rv->{providerInstanceId}' cannot run cross-provider child tasks from '$inherited_pid'";
        return;
      }
      $rv->{effortKey}  = $cm->{effortKey};
      $rv->{driverKind} = $cm->{driverKind};
      if (length $rv->{effortKey}) {
        $rv->{effort} = $cm->{effortDefault} if !length($rv->{effort} // '');
        my %okv = map { $_ => 1 } @{$cm->{effortValues}};
        if (!$okv{$rv->{effort}}) {
          push @errors, "$label effort '$rv->{effort}' invalid for $key ($rv->{effortKey} allows: " . join(',', @{$cm->{effortValues}}) . ")";
        }
      } elsif (length($rv->{effort} // '')) {
        push @errors, "$label model '$key' does not support effort options (got effort '$rv->{effort}')";
      }
    };
    my $i = 0;
    for my $m (@{$designers->{members}}) { $i++; $check_one->($m, "designers[$i]"); }
    $check_one->($judge, 'judge');
    $check_one->($def_rev, 'defaultReviewer');
    $i = 0;
    for my $m (@{$council->{members}}) { $i++; $check_one->($m, "reviewCouncil[$i]"); }

    # Strict intersection check for unified groups.
    for my $pair (['designers', $designers], ['reviewCouncil', $council]) {
      my ($gname, $grp) = @$pair;
      if (($grp->{effortMode} // '') eq 'unified' && length($grp->{unifiedEffort} // '')) {
        my $ue = $grp->{unifiedEffort};
        for my $m (@{$grp->{members}}) {
          my $cm = $cap_model{"$m->{providerInstanceId}/$m->{model}"} or next;
          my %okv = map { $_ => 1 } @{$cm->{effortValues}};
          if (!$okv{$ue}) {
            push @errors, "$gname unifiedEffort '$ue' is not in strict intersection (rejected by $m->{providerInstanceId}/$m->{model})";
          }
        }
      }
    }
  }

  if (@errors) {
    print "CONFIGURED=1\nCONFIG_VALID=0\n";
    print "CONFIG_ERROR=$_\n" for @errors;
    exit 3;
  }

  # Compute unauthorized providers introduced by project config (not in user authorizedProviders and not explicitly passed by user in this call).
  my %effective_pids;
  $effective_pids{$_->{providerInstanceId}} = 1 for (@{$designers->{members}}, $judge, $def_rev, @{$council->{members}});
  my @unauth = sort grep { $proj_providers{$_} && !$auth{$_} && !$user_override_providers{$_} } keys %effective_pids;

  my $opts_json = sub {
    my ($rv) = @_;
    return '{}' unless length($rv->{effortKey} // '') && length($rv->{effort} // '');
    return encode_compact_chars({ $rv->{effortKey} => $rv->{effort} });
  };

  print "CONFIGURED=1\nCONFIG_VALID=1\n";
  print "USER_CONFIG=" . _display_path($ucfg) . "\n";
  print "PROJECT_CONFIG=" . _display_path($pcfg) . "\n" if length $pcfg;
  print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj && length $pcfg_on_disk;
  print "PROJECT_OVERRIDDEN=$proj_overrode\n";
  print "NEEDS_PROVIDER_AUTH=" . (@unauth ? 1 : 0) . "\n";
  print "UNAUTHORIZED_PROVIDERS=" . join(',', @unauth) . "\n" if @unauth;
  print "KNOB_ROUND_CAP=$knobs->{roundCap}\n";
  print "KNOB_MAX_STEP_BACKS=$knobs->{maxStepBacks}\n";

  print "DEFAULT_REVIEWER_PROVIDER=$def_rev->{providerInstanceId}\n";
  print "DEFAULT_REVIEWER_DRIVER_KIND=" . ($def_rev->{driverKind} // $def_rev->{providerInstanceId}) . "\n";
  print "DEFAULT_REVIEWER_MODEL=$def_rev->{model}\n";
  print "DEFAULT_REVIEWER_OPTIONS=" . $opts_json->($def_rev) . "\n";

  print "JUDGE_PROVIDER=$judge->{providerInstanceId}\n";
  print "JUDGE_DRIVER_KIND=" . ($judge->{driverKind} // $judge->{providerInstanceId}) . "\n";
  print "JUDGE_MODEL=$judge->{model}\n";
  print "JUDGE_OPTIONS=" . $opts_json->($judge) . "\n";

  print "DESIGNERS_EFFORT_MODE=$designers->{effortMode}\n";
  print "DESIGNERS_COUNT=" . scalar(@{$designers->{members}}) . "\n";
  my $di = 0;
  for my $m (@{$designers->{members}}) {
    $di++;
    print "DESIGNER_${di}_PROVIDER=$m->{providerInstanceId}\n";
    print "DESIGNER_${di}_DRIVER_KIND=" . ($m->{driverKind} // $m->{providerInstanceId}) . "\n";
    print "DESIGNER_${di}_MODEL=$m->{model}\n";
    print "DESIGNER_${di}_OPTIONS=" . $opts_json->($m) . "\n";
  }

  print "COUNCIL_EFFORT_MODE=$council->{effortMode}\n";
  print "COUNCIL_COUNT=" . scalar(@{$council->{members}}) . "\n";
  my $ci = 0;
  for my $m (@{$council->{members}}) {
    $ci++;
    print "COUNCIL_${ci}_PROVIDER=$m->{providerInstanceId}\n";
    print "COUNCIL_${ci}_DRIVER_KIND=" . ($m->{driverKind} // $m->{providerInstanceId}) . "\n";
    print "COUNCIL_${ci}_MODEL=$m->{model}\n";
    print "COUNCIL_${ci}_OPTIONS=" . $opts_json->($m) . "\n";
  }

  print "EFFECTIVE_JSON=" . encode_compact_chars({
    designers       => $designers,
    judge           => $judge,
    defaultReviewer => $def_rev,
    reviewCouncil   => $council,
    knobs           => $knobs,
  }) . "\n";
}

# =============================================================================
# Trellis Hook Probe (fail-closed on unreadable/malformed config!) & Preflight
# =============================================================================

# Returns ('true' | 'false' | 'unknown', \@commands, $detail)
sub probe_after_start_hooks {
  my ($repo_root, $task_dir) = @_;
  my @cmds;
  my @reasons;

  # 1. Directly check .trellis/config.yaml readability & parseability first
  #    because Trellis get_hooks() returns [] on both missing AND unreadable config!
  my $cfg_yaml = "$repo_root/.trellis/config.yaml";
  if (-l $cfg_yaml) {
    return ('unknown', [], "symlink at $cfg_yaml");
  }
  if (-e $cfg_yaml) {
    if (!-r $cfg_yaml) {
      return ('unknown', [], "unreadable $cfg_yaml");
    }
    my $raw_yaml = eval { read_raw_file($cfg_yaml) };
    if ($@) {
      return ('unknown', [], "failed reading $cfg_yaml: $@");
    }
    # Verify YAML parses cleanly using Python (yaml if available, else Trellis's own loader) AND inspect hooks.after_start.
    my $py_probe = <<'PY';
import json, os, sys
from pathlib import Path
repo = Path(sys.argv[1])
cfg_file = repo / ".trellis" / "config.yaml"
try:
    text = cfg_file.read_text(encoding="utf-8")
except Exception as e:
    print(json.dumps({"status": "unknown", "reason": f"read error: {e}", "commands": []}))
    sys.exit(0)
# First try PyYAML if installed to catch syntax errors cleanly.
parsed = None
try:
    import yaml
    parsed = yaml.safe_load(text)
    if parsed is None:
        parsed = {}
    if not isinstance(parsed, dict):
        print(json.dumps({"status": "unknown", "reason": "config.yaml root is not a mapping", "commands": []}))
        sys.exit(0)
except ImportError:
    parsed = None
except Exception as e:
    print(json.dumps({"status": "unknown", "reason": f"yaml parse error: {e}", "commands": []}))
    sys.exit(0)

cmds = []
if parsed is not None:
    hooks = parsed.get("hooks")
    if hooks is not None and not isinstance(hooks, dict):
        print(json.dumps({"status": "unknown", "reason": "hooks field is not a mapping", "commands": []}))
        sys.exit(0)
    if isinstance(hooks, dict) and "after_start" in hooks:
        c = hooks.get("after_start")
        if isinstance(c, list):
            cmds.extend(str(x) for x in c if str(x).strip())
        elif c is not None:
            print(json.dumps({"status": "unknown", "reason": "hooks.after_start is not a list", "commands": []}))
            sys.exit(0)

# Also query Trellis common.config.get_hooks if present.
scripts_dir = repo / ".trellis" / "scripts"
if scripts_dir.is_dir():
    sys.path.insert(0, str(scripts_dir))
    try:
        from common.config import get_hooks
        tc = get_hooks("after_start", repo)
        if isinstance(tc, list):
            for x in tc:
                sx = str(x)
                if sx.strip() and sx not in cmds:
                    cmds.append(sx)
    except Exception as e:
        if parsed is None:
            print(json.dumps({"status": "unknown", "reason": f"trellis get_hooks error: {e}", "commands": []}))
            sys.exit(0)
elif parsed is None:
    # No PyYAML and no Trellis loader: fail closed if 'hooks' or 'after_start' appears in file.
    if "after_start" in text or "hooks:" in text:
        print(json.dumps({"status": "unknown", "reason": "cannot parse config.yaml without PyYAML or trellis scripts", "commands": []}))
        sys.exit(0)

print(json.dumps({"status": "ok", "reason": "", "commands": cmds}))
PY
    my ($rc, $out) = run_cmd_capture('python3', '-B', '-c', $py_probe, $repo_root);
    if ($rc != 0) {
      return ('unknown', [], "python probe failed (rc=$rc): $out");
    }
    my $pr = eval { decode_strict($out) };
    if ($@ || ref $pr ne 'HASH') {
      return ('unknown', [], "invalid hook probe output");
    }
    if (($pr->{status} // '') ne 'ok') {
      return ('unknown', [], $pr->{reason} // 'config.yaml probe unknown');
    }
    push @cmds, @{$pr->{commands} || []};
  }

  # 2. Also inspect task.json.hooks.after_start (supported by some Trellis docs/forks).
  if (defined $task_dir && -e "$task_dir/task.json") {
    my $tj = eval { load_json_file("$task_dir/task.json") };
    if ($@ || ref $tj ne 'HASH') {
      return ('unknown', [], "cannot parse task.json: $@");
    }
    if (exists $tj->{hooks}) {
      return ('unknown', [], "task.json.hooks is not an object") unless ref($tj->{hooks}) eq 'HASH';
      if (exists $tj->{hooks}{after_start}) {
        my $ac = $tj->{hooks}{after_start};
        return ('unknown', [], "task.json.hooks.after_start is not an array") unless ref($ac) eq 'ARRAY';
        for my $c (@$ac) {
          push @cmds, "$c" if defined $c && "$c" =~ /\S/;
        }
      }
    }
  }

  return (@cmds ? 'true' : 'false', \@cmds, '');
}

sub cmd_preflight_trellis {
  my ($repo_arg) = @_;
  my $repo = resolve_repo_root($repo_arg, undef);
  my $task_py = "$repo/.trellis/scripts/task.py";
  if (!-d "$repo/.trellis") {
    print "TRELLIS_COMPAT=unsupported\n";
    print "REASON=no .trellis directory at " . _display_path($repo) . "\n";
    exit 3;
  }
  if (!-f $task_py) {
    print "TRELLIS_COMPAT=unsupported\n";
    print "REASON=missing .trellis/scripts/task.py\n";
    exit 3;
  }

  my ($rc_h, $help) = run_cmd_capture('python3', $task_py, '--help');
  my @missing_sub;
  for my $sub (qw(create current validate start)) {
    push @missing_sub, $sub unless $help =~ /\b\Q$sub\E\b/;
  }
  my ($rc_ch, $cur_help) = run_cmd_capture('python3', $task_py, 'current', '--help');
  my $has_cur_json   = ($rc_ch == 0 && $cur_help =~ /--json\b/)   ? 1 : 0;
  my $has_cur_source = ($rc_ch == 0 && $cur_help =~ /--source\b/) ? 1 : 0;

  my $ctx_id = $ENV{TRELLIS_CONTEXT_ID} // '';
  my $ctx_mode = length($ctx_id) ? 'session' : 'degraded';
  my ($hstat, $hcmds, $hdetail) = probe_after_start_hooks($repo, undef);

  if ($rc_h != 0 || @missing_sub) {
    print "TRELLIS_COMPAT=unsupported\n";
    print "MISSING_SUBCOMMANDS=" . join(',', @missing_sub) . "\n" if @missing_sub;
    print "TASK_PY=" . _display_path($task_py) . "\n";
    exit 3;
  }

  my $compat = ($ctx_mode eq 'session' && $has_cur_json) ? 'ok' : 'degraded';
  print "TRELLIS_COMPAT=$compat\n";
  print "REPO_ROOT=" . _display_path($repo) . "\n";
  print "TASK_PY=" . _display_path($task_py) . "\n";
  print "HAS_WORKFLOW_MD=" . (-f "$repo/.trellis/workflow.md" ? 1 : 0) . "\n";
  print "HAS_CURRENT_JSON=$has_cur_json\n";
  print "HAS_CURRENT_SOURCE=$has_cur_source\n";
  print "SESSION_CONTEXT_MODE=$ctx_mode\n";
  print "AFTER_START_HOOKS=$hstat\n";
  print "AFTER_START_HOOKS_DETAIL=$hdetail\n" if length $hdetail;
}

# =============================================================================
# Task Inspection & Legacy Migration
# =============================================================================

sub cmd_inspect_task {
  my ($task_dir) = @_;
  die_err("inspect-task requires --task <path>") unless defined $task_dir && -d $task_dir;
  with_task_lock($task_dir, sub {
    my ($real_task, $plans_dir) = @_;
    my $has_pending_tx = (-f "$plans_dir/.pending.tx.json") ? 1 : 0;
    my $has_active_run = (-f "$plans_dir/active-run.json")  ? 1 : 0;
    my $sf = state_path($plans_dir);

    my $has_legacy_files = (
      -f "$plans_dir/claude.md" ||
      -f "$plans_dir/codex.md"  ||
      glob("$plans_dir/design-review-round*.md")
    ) ? 1 : 0;

    if (!-f $sf) {
      my $kind = $has_legacy_files ? 'LEGACY_DUAL_PLAN' : 'NEW';
      print "TASK_KIND=$kind\n";
      print "TASK_DIR=" . _display_path($real_task) . "\n";
      print "PENDING_TX=$has_pending_tx\n";
      print "ACTIVE_RUN=$has_active_run\n";
      return;
    }

    my $st = eval { load_json_file($sf) };
    if ($@ || ref $st ne 'HASH') {
      print "TASK_KIND=CORRUPT\n";
      print "ERROR=$@\n";
      exit 2;
    }

    if (($st->{pipeline} // '') eq 't3-tri-plan') {
      # Safe to recover pending tx on a tri-plan task.
      my $tx_rec = recover_tx($real_task, $plans_dir);
      $st = load_json_file($sf);
      my $p6 = (ref($st->{phases}) eq 'HASH' && ref($st->{phases}{'6'}) eq 'HASH') ? $st->{phases}{'6'} : {};
      print "TASK_KIND=TRI_PLAN\n";
      print "TASK_DIR=" . _display_path($real_task) . "\n";
      print "GENERATION=" . ($st->{generation} // 0) . "\n";
      print "OWNER_GENERATION=" . ($st->{owner_generation} // 0) . "\n";
      print "TX_RECOVERED=$tx_rec\n";
      print "ACTIVE_RUN=" . (-f "$plans_dir/active-run.json" ? 1 : 0) . "\n";
      print "PHASE6_STATE=" . ($p6->{state} // 'none') . "\n";
      print "MIGRATED_FROM_LEGACY=" . ($st->{migrated_from_legacy} ? 1 : 0) . "\n";
    } else {
      print "TASK_KIND=LEGACY_DUAL_PLAN\n";
      print "TASK_DIR=" . _display_path($real_task) . "\n";
      print "PENDING_TX=0\n";
      print "ACTIVE_RUN=0\n";
      print "RECOMMENDATION=Continue on /trellis:dual-plan, or run migrate-legacy --confirm to import with strict re-verification\n";
    }
  });
}

sub cmd_migrate_legacy {
  my ($task_dir, $confirm) = @_;
  die_err("migrate-legacy requires --task <path>") unless defined $task_dir && -d $task_dir;
  die_err("migrate-legacy requires explicit --confirm") unless $confirm;

  with_task_lock($task_dir, sub {
    my ($real_task, $plans_dir) = @_;
    my $sf = state_path($plans_dir);
    my $old = (-f $sf) ? load_json_file($sf) : {};
    die_err("task is already a t3-tri-plan task") if ($old->{pipeline} // '') eq 't3-tri-plan';

    my $prd_path = "$real_task/prd.md";
    die_err("cannot migrate: missing prd.md") unless -f $prd_path && !-l $prd_path;
    my $live_prd_sha = sha256_file($prd_path);

    my $st = init_fresh_state($live_prd_sha, $old->{authorization} // '');
    $st->{migrated_from_legacy} = JSON::PP::true;
    $st->{legacy_snapshot}      = $old;

    my @unproven;
    # Check Phase 0 match.
    my $old_p0 = (ref($old->{phases}) eq 'HASH' && ref($old->{phases}{'0'}) eq 'HASH') ? ($old->{phases}{'0'}{prd} // '') : '';
    if ($old_p0 !~ /\A[0-9a-f]{64}\z/ || $old_p0 ne $live_prd_sha) {
      push @unproven, 'phase0(prd hash missing/short/mismatched)';
      $st->{phases}{'0'}{status} = 'needs-reverification';
    }

    # Preserve legacy candidates as references ONLY; mark Phase 1 needs-reverification unless proven.
    my %leg_cands;
    for my $name (qw(claude codex)) {
      my $leg_p = _fs_join($plans_dir, "$name.md");
      if (-f $leg_p && !-l $leg_p) {
        $leg_cands{$name} = sha256_file($leg_p);
      }
    }
    $st->{phases}{'1'} = {
      status            => 'needs-reverification',
      legacy_candidates => \%leg_cands,
      candidates        => {},
    };
    push @unproven, 'phase1(legacy dual-plan candidates require review or tri-plan re-run)';

    $st->{phases}{'2'} = {
      status            => 'needs-reverification',
      phase2a_locked    => JSON::PP::false,
    };
    push @unproven, 'phase2(legacy synthesis/design not locked via blind judge)';

    # Import legacy review rounds with strict short-hash & user_decision validation (NEVER auto-trust!).
    if (ref($old->{review}) eq 'HASH') {
      my $or = $old->{review};
      $st->{review}{dirty_since_step_back} = $or->{dirty_since_step_back} // 0;
      $st->{review}{step_backs_done}       = $or->{step_backs_done}       // 0;
      my @imp_rounds;
      for my $r (@{$or->{rounds} || []}) {
        my $sha = $r->{sha} // '';
        my $short_or_bad = ($sha !~ /\A[0-9a-f]{64}\z/) ? 1 : 0;
        push @unproven, "review_round_$r->{n}(short or missing 64-char sha: '$sha')" if $short_or_bad;
        push @imp_rounds, {
          %$r,
          legacy_imported => JSON::PP::true,
          hash_verified   => $short_or_bad ? JSON::PP::false : JSON::PP::true,
        };
      }
      $st->{review}{rounds} = \@imp_rounds;
      if (ref($or->{user_decision}) eq 'HASH') {
        my $ud_sha = $or->{user_decision}{design_sha256} // '';
        my $live_d = (-f "$real_task/design.md" && !-l "$real_task/design.md") ? sha256_file("$real_task/design.md") : '';
        my $matched = ($ud_sha =~ /\A[0-9a-f]{64}\z/ && $ud_sha eq $live_d) ? 1 : 0;
        push @unproven, "legacy_user_decision(design_sha256 '$ud_sha' != live '$live_d' — NOT trusted)" unless $matched;
        $st->{review}{legacy_user_decision} = {
          %{$or->{user_decision}},
          verified_for_current_design => JSON::PP::false, # NEVER auto-pass Phase 6 on legacy user_decision!
        };
      }
    }
    $st->{unproven_reasons} = \@unproven;

    my $tx_id = "tx-migrate-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    $st->{generation} = 1;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => 0,
      next_generation     => 1,
      writes              => [
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });

    print "MIGRATED=1\n";
    print "UNPROVEN_COUNT=" . scalar(@unproven) . "\n";
    print "UNPROVEN=$_\n" for @unproven;
  });
}

# =============================================================================
# Phase 0: PRD Commit (Initial / Material Supersedence / Wording Update)
# =============================================================================

sub _collect_orphaned_attempts {
  my ($plans_dir, $reason) = @_;
  my $rf = "$plans_dir/active-run.json";
  return () unless -f $rf && !-l $rf;
  my $run = load_json_file($rf);
  my @orph;
  for my $slot (sort keys %{$run->{slots} || {}}) {
    my $s = $run->{slots}{$slot};
    my $st = $s->{state} // '';
    if ($st eq 'dispatching' || $st eq 'dispatched' || $st eq 'waiting' ||
        $st eq 'needs_reconcile' || $st eq 'reconciled_untracked' || $st eq 'cancel_requested') {
      push @orph, {
        run_id                    => $run->{run_id},
        phase                     => $run->{phase},
        generation                => $run->{generation},
        owner_thread_id           => $run->{owner_thread_id},
        owner_generation          => $run->{owner_generation},
        slot                      => $slot,
        attempt                   => $s->{attempt},
        state_at_orphan           => $st,
        client_request_id         => $s->{client_request_id},
        correlation_marker        => $s->{correlation_marker},
        task_id                   => $s->{task_id},
        child_thread_id           => $s->{child_thread_id} // $s->{reconciled_child_thread_id},
        child_run_id              => $s->{child_run_id},
        orphaned_at               => now_iso(),
        reason                    => $reason,
      };
    }
  }
  return @orph;
}

sub cmd_commit_phase0 {
  my %opt = @_;
  die_err("commit-phase0 requires --task <path>") unless defined $opt{task} && -d $opt{task};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'commit-phase0', sub {
      recover_tx($real_task, $plans_dir);

      my $prd_path = "$real_task/prd.md";
      die_err("missing $prd_path") unless -f $prd_path && !-l $prd_path;
      my $prd_sha = sha256_file($prd_path);
      my $repo    = resolve_repo_root($opt{repo}, $real_task);

      my $st = load_state_or_undef($plans_dir);
      my $ign_proj = _effective_ignore_project_config($st, \%opt);
      my $knobs    = resolve_configured_knobs($repo, $ign_proj);
      if (!$st) {
        my $new_st = init_fresh_state($prd_sha, $opt{authorization} // '', $knobs, $ign_proj);
        my $tx_id  = "tx-p0-" . time() . "-$$";
        $new_st->{last_tx_id} = $tx_id;
        execute_tx($real_task, $plans_dir, {
          tx_id               => $tx_id,
          expected_generation => 0,
          next_generation     => 1,
          writes              => [
            { dst => 'research/plans/planning-state.json', bytes => encode_canonical($new_st), is_state_file => 1 },
          ],
        });
        print "PHASE0_COMMITTED=1\nCHANGE_KIND=initial\nPRD_SHA256=$prd_sha\nGENERATION=1\n";
        print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj;
        return;
      }

      die_err("legacy dual-plan task detected — run migrate-legacy --confirm or use /trellis:dual-plan")
        unless ($st->{pipeline} // '') eq 't3-tri-plan';

      my $cur_eff_prd = $st->{effective_prd_sha256} // '';
      if ($cur_eff_prd eq $prd_sha) {
        my $auth_chg = (defined $opt{authorization} && length $opt{authorization} && $opt{authorization} ne ($st->{authorization} // '')) ? 1 : 0;
        my $ign_toggled = (($opt{ignore_project_config} || $opt{use_project_config}) && (($st->{ignore_project_config} ? 1 : 0) != $ign_proj)) ? 1 : 0;
        if ($auth_chg || $ign_toggled) {
          _guard_phase6_not_in_flight($st, 'commit-phase0');
          my $old_gen = $st->{generation} // 1;
          my $tx_id = "tx-p0-auth-" . time() . "-$$";
          $st->{authorization}         = $opt{authorization} if $auth_chg;
          if ($ign_toggled) {
            $st->{ignore_project_config} = $ign_proj ? JSON::PP::true : JSON::PP::false;
            if (ref($st->{review}) eq 'HASH') {
              my $extra_sb = defined($st->{review}{extra_step_backs_granted})
                ? int($st->{review}{extra_step_backs_granted})
                : scalar(@{$st->{review}{extra_step_back_authorizations} || []});
              $st->{review}{round_cap}              = $knobs->{roundCap};
              $st->{review}{max_step_backs_allowed} = $knobs->{maxStepBacks} + $extra_sb;
            }
          }
          $st->{last_tx_id}            = $tx_id;
          execute_tx($real_task, $plans_dir, {
            tx_id               => $tx_id,
            expected_generation => $old_gen,
            next_generation     => $old_gen,
            writes              => [
              { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
            ],
          });
        }
        print "PHASE0_COMMITTED=1\nCHANGE_KIND=unchanged\nPRD_SHA256=$prd_sha\nGENERATION=$st->{generation}\n";
        print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj;
        return;
      }

      my $kind = $opt{change_kind} // '';
      die_err("prd.md SHA-256 changed ($cur_eff_prd -> $prd_sha); explicit --change-kind material|wording is required")
        unless $kind eq 'material' || $kind eq 'wording';

      my $old_gen = $st->{generation} // 1;
      if ($kind eq 'wording') {
        _guard_phase6_not_in_flight($st, 'commit-phase0 --change-kind wording');
        die_err("--change-kind wording requires --evidence <why contract/acceptance unchanged>")
          unless defined $opt{evidence} && $opt{evidence} =~ /\S/;
        my $tx_id = "tx-p0-word-" . time() . "-$$";
        push @{$st->{prd_wording_updates}}, {
          old_prd_sha256 => $cur_eff_prd,
          new_prd_sha256 => $prd_sha,
          evidence       => $opt{evidence},
          recorded_at    => now_iso(),
        };
        my %eq = map { $_ => 1 } @{$st->{wording_equivalent_prd_shas} || [$st->{prd_lineage}]};
        $eq{$prd_sha} = 1;
        $st->{wording_equivalent_prd_shas} = [ sort keys %eq ];
        $st->{effective_prd_sha256}        = $prd_sha;
        $st->{ignore_project_config}       = $ign_proj ? JSON::PP::true : JSON::PP::false;
        if (ref($st->{review}) eq 'HASH') {
          my $extra_sb = defined($st->{review}{extra_step_backs_granted})
            ? int($st->{review}{extra_step_backs_granted})
            : scalar(@{$st->{review}{extra_step_back_authorizations} || []});
          $st->{review}{round_cap}              = $knobs->{roundCap};
          $st->{review}{max_step_backs_allowed} = $knobs->{maxStepBacks} + $extra_sb;
        }
        $st->{phases}{'0'}{effective_prd_sha256} = $prd_sha;
        $st->{phases}{'0'}{prd}            = $prd_sha;
        $st->{last_tx_id}                  = $tx_id;
        execute_tx($real_task, $plans_dir, {
          tx_id               => $tx_id,
          expected_generation => $old_gen,
          next_generation     => $old_gen,
          writes              => [
            { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
          ],
        });
        print "PHASE0_COMMITTED=1\nCHANGE_KIND=wording\nOLD_PRD_SHA256=$cur_eff_prd\nPRD_SHA256=$prd_sha\nGENERATION=$old_gen\n";
        print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj;
        return;
      }

      # Material PRD change: state-first tx (MUST NOT bypass activating or activation_uncertain — resolve Phase 6 first!).
      _guard_phase6_not_in_flight($st, 'commit-phase0 --change-kind material');
      die_err("--change-kind material requires --reason <summary>")
        unless defined $opt{reason} && $opt{reason} =~ /\S/;
      my $next_gen = $old_gen + 1;
      my $tx_id    = "tx-p0-mat-" . time() . "-$$-" . int(rand(10000));
      my $short8   = substr($cur_eff_prd, 0, 8);
      my $sup_rel  = "research/plans/superseded-${short8}-${tx_id}";
      while (-e _fs_join($real_task, $sup_rel)) {
        $sup_rel .= "-" . int(rand(1000));
      }

      my @orphans = (@{$st->{orphaned_attempts} || []}, _collect_orphaned_attempts($plans_dir, "prd material change: $opt{reason}"));
      my $old_run_id;
      if (-f "$plans_dir/active-run.json") {
        my $r = eval { load_json_file("$plans_dir/active-run.json") };
        $old_run_id = $r->{run_id} if !$@ && ref $r eq 'HASH';
      }

      my @moves;
      my @archive_candidates = (
        'research/plans/candidates',
        'research/plans/blind-eval.json',
        'research/plans/synthesis-body-locked.md',
        'research/plans/synthesis.md',
        'research/plans/initial-design.md',
        'research/plans/review-ledger.md',
        'research/plans/review-rounds',
        'research/plans/active-run.json',
        'design.md',
        'implement.md',
        'implement.jsonl',
        'check.jsonl',
      );
      for my $rel (@archive_candidates) {
        if (-e _fs_join($real_task, $rel)) {
          my $dst_name = $rel;
          $dst_name =~ s{\Aresearch/plans/}{};
          push @moves, { src => $rel, dst => "$sup_rel/$dst_name" };
        }
      }

      # Save a snapshot of old planning-state.json into superseded dir via write_file.
      my $old_state_bytes = read_raw_file(state_path($plans_dir));

      my $new_st = init_fresh_state($prd_sha, length($opt{authorization} // '') ? $opt{authorization} : ($st->{authorization} // ''), $knobs, $ign_proj);
      $new_st->{generation}        = $next_gen;
      $new_st->{owner_generation}  = $st->{owner_generation} // 1;
      $new_st->{last_tx_id}        = $tx_id;
      $new_st->{orphaned_attempts} = \@orphans;
      $new_st->{superseded_history} = [
        @{$st->{superseded_history} || []},
        {
          old_prd_sha256 => $cur_eff_prd,
          new_prd_sha256 => $prd_sha,
          archive_dir    => $sup_rel,
          reason         => $opt{reason},
          generation     => $next_gen,
          at             => now_iso(),
        }
      ];

      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $old_gen,
        next_generation     => $next_gen,
        closes_run_id       => $old_run_id,
        state_first         => 1,
        moves               => \@moves,
        writes              => [
          { dst => "$sup_rel/planning-state.json", bytes => $old_state_bytes, is_state_file => 0 },
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($new_st), is_state_file => 1 },
        ],
      });

      print "PHASE0_COMMITTED=1\nCHANGE_KIND=material\nOLD_PRD_SHA256=$cur_eff_prd\nPRD_SHA256=$prd_sha\nGENERATION=$next_gen\nSUPERSEDED_DIR=$sup_rel\n";
      print "PROJECT_CONFIG_IGNORED=1\n" if $ign_proj;
    });
  });
}

sub cmd_ack_wording_closure {
  my %opt = @_;
  die_err("ack-wording-closure requires --task <path> and --evidence <text>")
    unless defined $opt{task} && -d $opt{task} && defined $opt{evidence} && $opt{evidence} =~ /\S/;

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'ack-wording-closure', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'ack-wording-closure');
    my $repo = resolve_repo_root($opt{repo}, $real_task);
    my $trel = task_rel_path($repo, $real_task);

    my $rev = $st->{review};
    # Must not have manual_redesign active or any open blocking class.
    if (ref($rev->{user_decision}) eq 'HASH' && ($rev->{user_decision}{choice} // '') eq 'manual_redesign') {
      die_err("cannot ack-wording-closure while manual_redesign is active", 3);
    }
    my @open_blk = _count_open_blocking($rev);
    if (@open_blk) {
      die_err("cannot ack-wording-closure with open blocking/unresolved classes: " . join(',', @open_blk), 3);
    }

    my $live_prd = sha256_file("$real_task/prd.md");
    die_err("prd.md does not match committed effective_prd_sha256 — run commit-phase0 --change-kind wording first", 3)
      unless $live_prd eq ($st->{effective_prd_sha256} // '');

    my %equiv = map { $_ => 1 } @{$st->{wording_equivalent_prd_shas} || []};
    my ($live_non_prd) = compute_non_prd_baseline($repo, $real_task, $trel, $st);
    my $live_ledger_sha = (-f "$plans_dir/review-ledger.md") ? sha256_file("$plans_dir/review-ledger.md") : '';
    my $new_baseline    = compute_review_baseline($live_prd, $live_non_prd);

    my $rebound = '';
    # Case 1: Rebind prior valid converged proof.
    if (defined $rev->{converged_at_round} && length($rev->{converged_non_prd_sha256} // '')) {
      die_err("prior converged prd_sha256 is not in wording-equivalent chain", 3)
        unless $equiv{$rev->{converged_prd_sha256} // ''};
      die_err("non_prd_baseline_sha256 drifted since convergence — normal review required", 3)
        unless $live_non_prd eq $rev->{converged_non_prd_sha256};
      die_err("review-ledger.md changed since convergence — normal review required", 3)
        unless $live_ledger_sha eq ($rev->{converged_ledger_sha256} // '');
      $rev->{converged_prd_sha256}      = $live_prd;
      $rev->{converged_baseline_sha256} = $new_baseline;
      $rev->{last_clean_prd_sha256}     = $live_prd if ($rev->{clean_streak} // 0) > 0;
      $rev->{last_clean_baseline_sha256} = $new_baseline if ($rev->{clean_streak} // 0) > 0;
      $rebound = 'converged';
    }
    # Case 2: Rebind eligible user_decision closure.
    elsif (ref($rev->{user_decision}) eq 'HASH' &&
           (($rev->{user_decision}{choice} // '') eq 'narrow_scope_and_proceed' ||
            ($rev->{user_decision}{choice} // '') eq 'dispose_and_close_review')) {
      my $ud = $rev->{user_decision};
      die_err("prior user_decision prd_sha256 is not in wording-equivalent chain", 3)
        unless $equiv{$ud->{effective_prd_sha256} // ''};
      die_err("non_prd_baseline_sha256 drifted since user_decision — normal review required", 3)
        unless $live_non_prd eq ($ud->{non_prd_baseline_sha256} // '');
      die_err("review-ledger.md changed since user_decision — normal review required", 3)
        unless $live_ledger_sha eq ($ud->{ledger_sha256} // '');
      $ud->{effective_prd_sha256}   = $live_prd;
      $ud->{review_baseline_sha256} = $new_baseline;
      $rebound = 'user_decision';
    }
    # Case 3: Rebind clean_streak == 1.
    elsif (($rev->{clean_streak} // 0) == 1 && length($rev->{last_clean_non_prd_sha256} // '')) {
      die_err("prior clean_streak prd_sha256 is not in wording-equivalent chain", 3)
        unless $equiv{$rev->{last_clean_prd_sha256} // ''};
      die_err("non_prd_baseline_sha256 drifted since clean round 1 — normal review required", 3)
        unless $live_non_prd eq $rev->{last_clean_non_prd_sha256};
      $rev->{last_clean_prd_sha256}      = $live_prd;
      $rev->{last_clean_baseline_sha256} = $new_baseline;
      $rebound = 'clean_streak_1';
    } else {
      die_err("no prior valid converged proof, eligible user_decision, or clean_streak=1 to rebind", 3);
    }

    push @{$rev->{wording_closure_acks}}, {
      rebound                => $rebound,
      effective_prd_sha256   => $live_prd,
      non_prd_baseline_sha256 => $live_non_prd,
      review_baseline_sha256 => $new_baseline,
      evidence               => $opt{evidence},
      at                     => now_iso(),
    };

    my $gen = $st->{generation};
    my $tx_id = "tx-ack-word-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
      print "WORDING_CLOSURE_ACKED=1\nREBOUND=$rebound\nREVIEW_BASELINE_SHA256=$new_baseline\n";
    });
  });
}

# =============================================================================
# Unified Async Run / Slot State Machine (Phase 1, Phase 2a, Phase 3)
# =============================================================================

sub _create_active_run {
  my ($real_task, $plans_dir, $st, $run_obj) = @_;
  die_err("an active run already exists — resume or abort/takeover first") if -f "$plans_dir/active-run.json";
  my $gen = $st->{generation};
  my $tx_id = "tx-prep-" . time() . "-$$-" . int(rand(10000));
  $st->{last_tx_id} = $tx_id;
  execute_tx($real_task, $plans_dir, {
    tx_id               => $tx_id,
    expected_generation => $gen,
    next_generation     => $gen,
    writes              => [
      { dst => 'research/plans/active-run.json', bytes => encode_canonical($run_obj), is_state_file => 0 },
      { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
    ],
  });
}

sub _shuffle_array {
  my (@a) = @_;
  for (my $i = $#a; $i > 0; $i--) {
    my $j = int(rand($i + 1));
    @a[$i, $j] = @a[$j, $i];
  }
  return @a;
}

sub cmd_prepare_design {
  my %opt = @_;
  die_err("prepare-design requires --task, --slots-json, --owner")
    unless defined $opt{task} && defined $opt{slots_json} && defined $opt{owner};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'prepare-design', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("commit-phase0 first");
      _guard_phase6_not_in_flight($st, 'prepare-design');
      if (ref($st->{review}) eq 'HASH' &&
          ref($st->{review}{user_decision}) eq 'HASH' &&
          ($st->{review}{user_decision}{choice} // '') eq 'manual_redesign') {
        die_err("manual_redesign is active — run clear-manual-redesign or commit-phase0 --change-kind material before re-running Phase 1", 3);
      }
      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

    my $prd_sha = sha256_file("$real_task/prd.md");
    die_err("prd.md modified since Phase 0 commit — run commit-phase0 first")
      unless $prd_sha eq ($st->{effective_prd_sha256} // '');

    my $targets = load_json_file($opt{slots_json});
    die_err("--slots-json must be an array of model specs") unless ref $targets eq 'ARRAY' && @$targets >= 2;
    die_err("triple-blind design expects 3 designers unless --degraded-allowed")
      if @$targets != 3 && !$opt{degraded_allowed};

    # Shuffled anonymous slot assignment (candidate-a, candidate-b, candidate-c, ...)
    my @letters = ('a' .. 'z');
    my @slot_names = map { "candidate-$letters[$_]" } (0 .. $#$targets);
    my @shuffled_targets = _shuffle_array(@$targets);

    my $run_id = "run-p1-" . time() . "-$$-" . int(rand(10000));
    my $fp = compute_worktree_fp($repo, $trel);
    my %slots;
    for my $i (0 .. $#slot_names) {
      my $sn = $slot_names[$i];
      $slots{$sn} = {
        slot                       => $sn,
        attempt                    => 0,
        state                      => 'pending',
        target                     => $shuffled_targets[$i],
        client_request_id          => undef,
        correlation_marker         => undef,
        task_id                    => undef,
        child_thread_id            => undef,
        child_run_id               => undef,
        reconciled_child_thread_id => undef,
        reconciled_by              => undef,
        result_file                => undef,
        result_sha256              => undef,
        reason                     => '',
      };
    }

    my $run_obj = {
      run_id            => $run_id,
      phase             => 'phase1-design',
      status            => 'active',
      generation        => $st->{generation},
      owner_thread_id   => $opt{owner},
      owner_generation  => $st->{owner_generation},
      input_manifest    => { prd_sha256 => $prd_sha },
      worktree_fp_start => $fp,
      created_at        => now_iso(),
      slots             => \%slots,
    };

    _create_active_run($real_task, $plans_dir, $st, $run_obj);
    print "RUN_ID=$run_id\nPHASE=phase1-design\nGENERATION=$st->{generation}\nOWNER_GENERATION=$st->{owner_generation}\n";
      print "SLOTS=" . join(',', @slot_names) . "\n";
    });
  });
}

sub cmd_prepare_judge {
  my %opt = @_;
  die_err("prepare-judge requires --task, --target-json, --owner")
    unless defined $opt{task} && defined $opt{target_json} && defined $opt{owner};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'prepare-judge', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'prepare-judge');
    my $repo = resolve_repo_root($opt{repo}, $real_task);
    my $trel = task_rel_path($repo, $real_task);

    my $p1 = $st->{phases}{'1'};
    die_err("Phase 1 must be completed before prepare-judge")
      unless ref $p1 eq 'HASH' && ($p1->{status} // '') eq 'completed' && ref($p1->{candidates}) eq 'HASH' && keys %{$p1->{candidates}};
    die_err("Phase 2a is already locked — cannot prepare another judge run without re-running Phase 1", 3)
      if ref($st->{phases}{'2'}) eq 'HASH' && $st->{phases}{'2'}{phase2a_locked};
    my $prd_path = "$real_task/prd.md";
    die_err("missing prd.md", 3) unless -f $prd_path && !-l $prd_path;
    die_err("prd.md modified since Phase 0 commit — run commit-phase0 first", 3)
      unless sha256_file($prd_path) eq ($st->{effective_prd_sha256} // '');

    # Verify live candidates match Phase 1 hashes.
    for my $slot (sort keys %{$p1->{candidates}}) {
      my $cp = _fs_join($plans_dir, 'candidates', "$slot.md");
      die_err("candidate file missing or modified: $slot.md")
        unless -f $cp && !-l $cp && sha256_file($cp) eq $p1->{candidates}{$slot};
    }

    my $target = load_json_file($opt{target_json});
    die_err("--target-json must be a model spec object") unless ref $target eq 'HASH';

    my $run_id = "run-p2a-" . time() . "-$$-" . int(rand(10000));
    my $fp = compute_worktree_fp($repo, $trel);
    my $cand_manifest_rel = "research/plans/runs/$run_id/candidates-manifest.json";

    my $run_obj = {
      run_id                  => $run_id,
      phase                   => 'phase2-judge',
      status                  => 'active',
      generation              => $st->{generation},
      owner_thread_id         => $opt{owner},
      owner_generation        => $st->{owner_generation},
      candidates_manifest_rel => $cand_manifest_rel,
      input_manifest          => {
        prd_sha256 => $st->{effective_prd_sha256},
        candidates => $p1->{candidates},
      },
      worktree_fp_start       => $fp,
      created_at              => now_iso(),
      slots                   => {
        judge => {
          slot                       => 'judge',
          attempt                    => 0,
          state                      => 'pending',
          target                     => $target,
          client_request_id          => undef,
          correlation_marker         => undef,
          task_id                    => undef,
          child_thread_id            => undef,
          child_run_id               => undef,
          reconciled_child_thread_id => undef,
          reconciled_by              => undef,
          result_file                => undef,
          result_sha256              => undef,
          reason                     => '',
        },
      },
    };

    die_err("an active run already exists") if -f "$plans_dir/active-run.json";
    my $gen = $st->{generation};
    my $tx_id = "tx-prep-j-" . time() . "-$$-" . int(rand(10000));
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => $cand_manifest_rel, bytes => encode_canonical($p1->{candidates}), is_state_file => 0 },
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run_obj), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });

    print "RUN_ID=$run_id\nPHASE=phase2-judge\nGENERATION=$gen\nOWNER_GENERATION=$st->{owner_generation}\n";
      print "CANDIDATES_MANIFEST=" . _display_path($real_task) . "/$cand_manifest_rel\n";
    });
  });
}

sub cmd_prepare_review {
  my %opt = @_;
  die_err("prepare-review requires --task, --purpose, --mode, --slots-json, --owner")
    unless defined $opt{task} && defined $opt{purpose} && defined $opt{mode} && defined $opt{slots_json} && defined $opt{owner};
  die_err("invalid mode '$opt{mode}'") unless $opt{mode} eq 'full' || $opt{mode} eq 'incremental' || $opt{mode} eq 'step-back';

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'prepare-review', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'prepare-review');
    my $repo = resolve_repo_root($opt{repo}, $real_task);
    my $trel = task_rel_path($repo, $real_task);

    die_err("an active run already exists") if -f "$plans_dir/active-run.json";
    die_err("design.md missing") unless -f "$real_task/design.md" && !-l "$real_task/design.md";

    my $design_bytes = read_raw_file("$real_task/design.md");
    my $design_sha   = sha256_bytes($design_bytes);
    my $eff_prd      = $st->{effective_prd_sha256};
    die_err("prd.md changed without commit-phase0") unless sha256_file("$real_task/prd.md") eq $eff_prd;

    my ($non_prd_sha, $non_prd_payload, $rules) = compute_non_prd_baseline($repo, $real_task, $trel, $st);
    my $baseline_sha = compute_review_baseline($eff_prd, $non_prd_sha);

    my $round_num = scalar(@{$st->{review}{rounds} || []}) + 1;
    my $round_dir_rel = sprintf("research/plans/review-rounds/%02d-%s", $round_num, $opt{mode});
    my $snap_rel      = "$round_dir_rel/design.md";
    my $frozen_led_rel = "$round_dir_rel/frozen-ledger.md";
    my $led_man_rel    = "$round_dir_rel/ledger-manifest.json";
    my $input_man_rel  = "$round_dir_rel/round-input-manifest.json";

    my $ledger_bytes = (-f "$plans_dir/review-ledger.md")
      ? read_raw_file("$plans_dir/review-ledger.md")
      : "# Review Ledger\n\n(No prior classes in current PRD lineage.)\n";
    my $ledger_sha = (-f "$plans_dir/review-ledger.md") ? sha256_bytes($ledger_bytes) : '';

    # Build round-specific input manifest (separate from cross-round review_baseline_sha256!).
    my %round_inputs = (
      mode                   => $opt{mode},
      purpose                => $opt{purpose},
      effective_prd_sha256   => $eff_prd,
      design_sha256          => $design_sha,
      design_snapshot_rel    => $snap_rel,
      pre_ledger_sha256      => $ledger_sha,
      non_prd_baseline_sha256 => $non_prd_sha,
      review_baseline_sha256 => $baseline_sha,
      rules_base_head        => $rules->{base_head},
      rules_digest           => $rules->{digest},
      rules_wt_deltas        => $rules->{wt_deltas},
    );
    if ($opt{mode} eq 'incremental') {
      my $prev = $st->{review}{last_reviewed_snapshot} // '';
      my $prev_abs = length($prev) ? _fs_join($real_task, $prev) : '';
      die_err("incremental mode requires existing previous reviewed snapshot")
        unless length $prev && -f $prev_abs && sha256_file($prev_abs) eq ($st->{review}{last_reviewed_design_sha256} // '');
      $round_inputs{prev_snapshot_rel}    = $prev;
      $round_inputs{prev_snapshot_sha256} = $st->{review}{last_reviewed_design_sha256};
    } else {
      $round_inputs{candidates} = $non_prd_payload->{candidates};
      if (-f "$plans_dir/synthesis-body-locked.md") {
        $round_inputs{locked_synthesis_sha256} = sha256_file("$plans_dir/synthesis-body-locked.md");
      }
    }
    my $round_input_sha = sha256_bytes(encode_compact(\%round_inputs));

    my $ledger_manifest = {
      known_classes => $st->{review}{classes} || {},
      rule_files    => $rules->{rule_files}   || {},
      rules_index   => $rules->{rules_index}  || {},
    };

    my $targets = load_json_file($opt{slots_json});
    die_err("--slots-json must be a non-empty array") unless ref $targets eq 'ARRAY' && @$targets >= 1;

    my $run_id = sprintf("run-p3-r%02d-%d-%d", $round_num, time(), $$);
    my %slots;
    for my $i (0 .. $#$targets) {
      my $sn = "slot" . ($i + 1);
      $slots{$sn} = {
        slot                       => $sn,
        attempt                    => 0,
        state                      => 'pending',
        target                     => $targets->[$i],
        client_request_id          => undef,
        correlation_marker         => undef,
        task_id                    => undef,
        child_thread_id            => undef,
        child_run_id               => undef,
        reconciled_child_thread_id => undef,
        reconciled_by              => undef,
        result_file                => undef,
        result_sha256              => undef,
        reason                     => '',
      };
    }

    my $fp_start = compute_worktree_fp($repo, $trel);
    # Note: snapshot/manifest files under review-rounds/NN-<mode>/ will be written by THIS tx,
    # so record expected post-writes inside active-run.json or compute fp AFTER?
    # Better: record their exact digests in allowed_setup_writes so compare_worktree_fp verifies them!
    my $snap_bytes      = $design_bytes;
    my $led_man_bytes   = encode_canonical($ledger_manifest);
    my $input_man_bytes = encode_canonical(\%round_inputs);
    my $frozen_led_sha  = sha256_bytes($ledger_bytes);
    my $led_man_sha     = sha256_bytes($led_man_bytes);
    my $input_man_sha   = sha256_bytes($input_man_bytes);
    my %setup_writes;
    if (length $trel) {
      $setup_writes{"$trel/$snap_rel"}       = sha256_bytes($snap_bytes);
      $setup_writes{"$trel/$frozen_led_rel"} = $frozen_led_sha;
      $setup_writes{"$trel/$led_man_rel"}    = $led_man_sha;
      $setup_writes{"$trel/$input_man_rel"}  = $input_man_sha;
    }

    my $run_obj = {
      run_id                       => $run_id,
      phase                        => 'phase3-review',
      status                       => 'active',
      generation                   => $st->{generation},
      owner_thread_id              => $opt{owner},
      owner_generation             => $st->{owner_generation},
      round_num                    => $round_num,
      round_dir_rel                => $round_dir_rel,
      purpose                      => $opt{purpose},
      mode                         => $opt{mode},
      design_snapshot_rel          => $snap_rel,
      reviewed_design_sha256       => $design_sha,
      ledger_manifest_rel          => $led_man_rel,
      ledger_manifest_sha256       => $led_man_sha,
      frozen_ledger_rel            => $frozen_led_rel,
      frozen_ledger_sha256         => $frozen_led_sha,
      round_input_manifest_rel     => $input_man_rel,
      round_input_manifest_sha256  => $input_man_sha,
      round_input_sha256           => $round_input_sha,
      effective_prd_sha256         => $eff_prd,
      non_prd_baseline_sha256      => $non_prd_sha,
      review_baseline_sha256       => $baseline_sha,
      pre_ledger_sha256            => $ledger_sha,
      prev_snapshot_rel            => $round_inputs{prev_snapshot_rel} // '',
      allowed_setup_writes         => \%setup_writes,
      worktree_fp_start            => $fp_start,
      created_at                   => now_iso(),
      slots                        => \%slots,
    };

    my $gen = $st->{generation};
    my $tx_id = "tx-prep-r$round_num-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => $snap_rel,       bytes => $snap_bytes,      is_state_file => 0 },
        { dst => $frozen_led_rel, bytes => $ledger_bytes,    is_state_file => 0 },
        { dst => $led_man_rel,    bytes => $led_man_bytes,   is_state_file => 0 },
        { dst => $input_man_rel,  bytes => $input_man_bytes, is_state_file => 0 },
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run_obj), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });

    print "RUN_ID=$run_id\nPHASE=phase3-review\nROUND_NUM=$round_num\nMODE=$opt{mode}\nPURPOSE=$opt{purpose}\n";
    print "GENERATION=$gen\nOWNER_GENERATION=$st->{owner_generation}\n";
    my $disp_task = _display_path($real_task);
    print "DESIGN_SNAPSHOT=$disp_task/$snap_rel\nREVIEWED_DESIGN_SHA256=$design_sha\n";
    print "FROZEN_LEDGER=$disp_task/$frozen_led_rel\nLEDGER_MANIFEST=$disp_task/$led_man_rel\n";
    print "REVIEW_BASELINE_SHA256=$baseline_sha\n";
    print "PREV_SNAPSHOT=$disp_task/$round_inputs{prev_snapshot_rel}\n" if length($round_inputs{prev_snapshot_rel} // '');
      print "SLOTS=" . join(',', sort keys %slots) . "\n";
    });
  });
}

sub cmd_claim_slot {
  my %opt = @_;
  die_err("claim-slot requires --task, --run-id, --slot, --owner, --owner-gen")
    unless defined $opt{task} && defined $opt{run_id} && defined $opt{slot} && defined $opt{owner} && defined $opt{owner_gen};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }
    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    _guard_phase6_not_in_flight($st, 'claim-slot');
    my $rf  = "$plans_dir/active-run.json";
    die_err("no active-run.json") unless -f $rf;
    my $run = load_json_file($rf);

    die_err("run_id mismatch", 4) unless $run->{run_id} eq $opt{run_id};
    die_err("run not active", 4)  unless ($run->{status} // '') eq 'active';
    die_err("owner/owner_generation mismatch", 4)
      unless $run->{owner_thread_id} eq $opt{owner} && $run->{owner_generation} == $opt{owner_gen};
    die_err("generation mismatch", 4)
      if defined $opt{generation} && $run->{generation} != $opt{generation};

    my $s = $run->{slots}{$opt{slot}} // die_err("unknown slot '$opt{slot}'");
    my $cur_st = $s->{state} // '';
    my %claimable = map { $_ => 1 } qw(pending failed completed_invalid completed_forks_pending cancelled);
    die_err("cannot claim slot '$opt{slot}' in state '$cur_st' (must reach terminal state or cancel first)")
      unless $claimable{$cur_st};

    my $att = ($s->{attempt} // 0) + 1;
    my $cid = sha256_bytes("$run->{run_id}:$run->{generation}:$run->{owner_generation}:$opt{slot}:a$att");
    $cid = "tri-" . substr($cid, 0, 24);
    my $marker = "[tri-plan:$run->{run_id}:g$run->{generation}:og$run->{owner_generation}:$opt{slot}:a$att:cid$cid]";

    $s->{attempt}                    = $att;
    $s->{state}                      = 'dispatching';
    $s->{client_request_id}          = $cid;
    $s->{correlation_marker}         = $marker;
    $s->{task_id}                    = undef;
    $s->{child_thread_id}            = undef;
    $s->{child_run_id}               = undef;
    $s->{reconciled_child_thread_id} = undef;
    $s->{reconciled_by}              = undef;
    $s->{result_file}                = undef;
    $s->{result_sha256}              = undef;
    $s->{reason}                     = '';

    my $gen = $st->{generation};
    my $tx_id = "tx-claim-$opt{slot}-a$att-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });

    print "CLAIMED=1\nSLOT=$opt{slot}\nATTEMPT=$att\nCLIENT_REQUEST_ID=$cid\nCORRELATION_MARKER=$marker\n";
    print "GENERATION=$run->{generation}\nOWNER_GENERATION=$run->{owner_generation}\n";
  });
}

sub cmd_record_dispatch {
  my %opt = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt task_id child_thread_id child_run_id)) {
    die_err("record-dispatch missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    # Read-only staleness check BEFORE recover_tx -> ZERO writes on stale callback!
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot}, $opt{attempt}, $opt{task_id});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }

    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot $opt{slot}");
    if ($s->{attempt} != $opt{attempt}) {
      print "STALE_CALLBACK=1\nREASON=attempt mismatch ($opt{attempt} != $s->{attempt})\n";
      exit 4;
    }
    if ($s->{state} eq 'dispatched' && ($s->{task_id} // '') eq $opt{task_id}) {
      print "DUPLICATE_NOOP=1\nSLOT=$opt{slot}\nATTEMPT=$opt{attempt}\n";
      return;
    }
    die_err("CAS failed: slot '$opt{slot}' state is '$s->{state}', expected 'dispatching'", 4)
      unless $s->{state} eq 'dispatching';

    $s->{state}           = 'dispatched';
    $s->{task_id}         = $opt{task_id};
    $s->{child_thread_id} = $opt{child_thread_id};
    $s->{child_run_id}    = $opt{child_run_id};

    my $gen = $st->{generation};
    my $tx_id = "tx-disp-$opt{slot}-a$opt{attempt}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
    print "DISPATCH_RECORDED=1\nSLOT=$opt{slot}\nATTEMPT=$opt{attempt}\n";
  });
}

sub cmd_update_slot {
  my %opt = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt state)) {
    die_err("update-slot missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  my %valid_st = map { $_ => 1 } qw(waiting cancel_requested cancelled failed needs_reconcile reconciled_untracked);
  die_err("invalid --state '$opt{state}'") unless $valid_st{$opt{state}};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot}, $opt{attempt});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }

    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot $opt{slot}");
    if ($s->{attempt} != $opt{attempt}) {
      print "STALE_CALLBACK=1\nREASON=attempt mismatch\n";
      exit 4;
    }
    my %allowed_from = (
      waiting              => { dispatched => 1, waiting => 1 },
      cancel_requested     => { dispatched => 1, waiting => 1, reconciled_untracked => 1, needs_reconcile => 1, cancel_requested => 1 },
      cancelled            => { cancel_requested => 1, dispatching => 1, needs_reconcile => 1, cancelled => 1 },
      failed               => { dispatching => 1, dispatched => 1, waiting => 1, reconciled_untracked => 1, needs_reconcile => 1, failed => 1 },
      needs_reconcile      => { dispatching => 1, dispatched => 1, waiting => 1, needs_reconcile => 1 },
      reconciled_untracked => { dispatching => 1, needs_reconcile => 1, reconciled_untracked => 1 },
    );
    die_err("illegal slot transition for '$opt{slot}': '$s->{state}' -> '$opt{state}'", 4)
      unless $allowed_from{$opt{state}}{$s->{state} // ''};
    $s->{state} = $opt{state};
    $s->{reason} = $opt{reason} if defined $opt{reason};
    $s->{reconciled_child_thread_id} = $opt{reconciled_child_thread_id}
      if defined $opt{reconciled_child_thread_id} && length $opt{reconciled_child_thread_id};

    my $gen = $st->{generation};
    my $tx_id = "tx-upd-$opt{slot}-a$opt{attempt}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
    print "SLOT_UPDATED=1\nSLOT=$opt{slot}\nSTATE=$opt{state}\n";
  });
}

sub _validate_slot_payload {
  my ($real_task, $run, $input_file) = @_;
  my $phase = $run->{phase};
  my $tmp_dir   = tempdir('t3-tri-val-XXXXXX', TMPDIR => 1, CLEANUP => 1);
  my $tmp_canon = "$tmp_dir/canon";
  my ($rc, $out);

  if ($phase eq 'phase1-design') {
    ($rc, $out) = run_cmd_capture('perl', $VALIDATE_CAND, '--input', $input_file, '--write-canonical', $tmp_canon);
  } elsif ($phase eq 'phase2-judge') {
    my $cm = _fs_join($real_task, $run->{candidates_manifest_rel});
    ($rc, $out) = run_cmd_capture('perl', $VALIDATE_JUDGE, '--input', $input_file, '--candidates-manifest', $cm, '--allow-forks', '--write-canonical', $tmp_canon);
  } elsif ($phase eq 'phase3-review') {
    my $lm = _fs_join($real_task, $run->{ledger_manifest_rel});
    ($rc, $out) = run_cmd_capture(
      'perl', $PARSE_REVIEW,
      '--input', $input_file,
      '--expected-mode', $run->{mode},
      '--expected-design-sha', $run->{reviewed_design_sha256},
      '--ledger-manifest', $lm,
      '--write-canonical', $tmp_canon
    );
  } else {
    die_err("unknown run phase '$phase'");
  }

  my $kv = parse_kv_lines($out);
  if ($rc == 0 && ($kv->{VALID} // '0') eq '1' && -f $tmp_canon) {
    my $bytes = read_raw_file($tmp_canon);
    my $ext = ($phase eq 'phase1-design') ? 'md' : 'json';
    return (1, $bytes, $ext, '', $kv);
  }
  my $raw = read_raw_file($input_file);
  return (0, $raw, 'invalid.txt', ($kv->{ERROR} // "validation failed (rc=$rc)"), $kv);
}

sub _ingest_result_common {
  my ($mode_reconcile, %opt) = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt child_run_id input)) {
    die_err("missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  die_err("input file not found or symlink: $opt{input}") unless -f $opt{input} && !-l $opt{input};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    # 1. Read-only staleness check BEFORE recover_tx (ZERO disk writes on stale callback!).
    my ($stale, $why) = check_stale_readonly(
      $plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen},
      $opt{run_id}, $opt{slot}, $opt{attempt}, ($mode_reconcile ? undef : $opt{task_id})
    );
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }

    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot '$opt{slot}'");

    # Snapshot external --input ONCE into an isolated temp file (zero TOCTOU between hash, dup check, and validation!).
    my $in_tmp_dir  = tempdir('t3-tri-in-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $in_bytes    = read_raw_file($opt{input});
    my $raw_in_sha  = sha256_bytes($in_bytes);
    my $in_snap     = "$in_tmp_dir/input.bin";
    write_atomic_bytes($in_snap, $in_bytes);

    # 2. Strict CAS BEFORE validating or writing ANY file!
    if ($s->{attempt} != $opt{attempt}) {
      print "STALE_CALLBACK=1\nREASON=attempt mismatch ($opt{attempt} != $s->{attempt})\n";
      exit 4;
    }
    my %done_states = map { $_ => 1 } qw(completed_valid completed_invalid completed_forks_pending);
    if ($mode_reconcile) {
      die_err("reconcile-and-record-result requires --child-thread-id") unless defined $opt{child_thread_id} && length $opt{child_thread_id};
      my %ok_rec = map { $_ => 1 } qw(dispatching needs_reconcile reconciled_untracked);
      if ($done_states{$s->{state}} &&
          ($s->{child_thread_id} // '') eq $opt{child_thread_id} &&
          ($s->{child_run_id} // '') eq $opt{child_run_id}) {
        if (($s->{raw_input_sha256} // '') eq $raw_in_sha) {
          print "DUPLICATE_NOOP=1\nSLOT=$opt{slot}\nSTATE=$s->{state}\n";
          return;
        }
      }
      die_err("reconcile-and-record-result rejected: slot '$opt{slot}' is in state '$s->{state}'", 4)
        unless $ok_rec{$s->{state}};
    } else {
      die_err("record-result requires --task-id") unless defined $opt{task_id} && length $opt{task_id};
      if (($s->{task_id} // '') ne $opt{task_id}) {
        print "STALE_CALLBACK=1\nREASON=task_id mismatch ($opt{task_id} != " . ($s->{task_id} // 'null') . ")\n";
        exit 4;
      }
      if (defined $s->{child_run_id} && length($s->{child_run_id}) && $s->{child_run_id} ne $opt{child_run_id}) {
        print "STALE_CALLBACK=1\nREASON=child_run_id mismatch ($opt{child_run_id} != $s->{child_run_id})\n";
        exit 4;
      }
      if ($done_states{$s->{state}}) {
        if (($s->{raw_input_sha256} // '') eq $raw_in_sha) {
          print "DUPLICATE_NOOP=1\nSLOT=$opt{slot}\nSTATE=$s->{state}\n";
          return;
        }
        print "STALE_CALLBACK=1\nREASON=slot already terminal ($s->{state}) with different payload\n";
        exit 4;
      }
      my %ok_st = map { $_ => 1 } qw(dispatched waiting);
      die_err("record-result rejected: slot '$opt{slot}' is in state '$s->{state}'", 4)
        unless $ok_st{$s->{state}};
    }

    # 3. Validate the SINGLE snapshot now that lock + CAS succeeded.
    my ($valid, $out_bytes, $ext, $err_reason, $kv) = _validate_slot_payload($real_task, $run, $in_snap);
    my $out_sha = sha256_bytes($out_bytes);
    my $sha16   = substr($out_sha, 0, 16);
    my $res_rel = "research/plans/runs/$run->{run_id}/results/$opt{slot}-a$opt{attempt}-${sha16}.${ext}";

    if ($mode_reconcile) {
      $s->{child_thread_id} = $opt{child_thread_id};
      $s->{child_run_id}    = $opt{child_run_id};
      $s->{reconciled_by}   = 'prompt_marker';
    }
    my $forks = ($run->{phase} eq 'phase2-judge' && defined $kv->{FORKS}) ? int($kv->{FORKS}) : 0;
    if ($valid && $run->{phase} eq 'phase2-judge' && $forks > 0) {
      $s->{state}  = 'completed_forks_pending';
      $s->{reason} = "product_forks pending user decision ($forks)";
    } else {
      $s->{state}  = $valid ? 'completed_valid' : 'completed_invalid';
      $s->{reason} = $err_reason;
    }
    $s->{result_file}      = $res_rel;
    $s->{result_sha256}    = $out_sha;
    $s->{raw_input_sha256} = $raw_in_sha;

    # 4. Single atomic transaction writing immutable content-addressed result file + active-run.json!
    my $gen = $st->{generation};
    my $tx_id = "tx-res-$opt{slot}-a$opt{attempt}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => $res_rel, bytes => $out_bytes, is_state_file => 0 },
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });

    print "RESULT_RECORDED=1\nSLOT=$opt{slot}\nATTEMPT=$opt{attempt}\nSLOT_STATE=$s->{state}\n";
    print "RESULT_FILE=" . _display_path($real_task) . "/$res_rel\nRESULT_SHA256=$out_sha\n";
    print "FORKS=$forks\n" if $run->{phase} eq 'phase2-judge';
    print "ERROR=$err_reason\n" if !$valid;
    exit($valid ? 0 : 1);
  });
}

sub cmd_reconcile_terminal_error {
  my %opt = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt child_thread_id child_run_id state)) {
    die_err("reconcile-terminal-error missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  die_err("--state must be failed or cancelled") unless $opt{state} eq 'failed' || $opt{state} eq 'cancelled';

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot}, $opt{attempt});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }

    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot $opt{slot}");
    if ($s->{attempt} != $opt{attempt}) { print "STALE_CALLBACK=1\nREASON=attempt mismatch\n"; exit 4; }
    my %ok = map { $_ => 1 } qw(dispatching needs_reconcile reconciled_untracked dispatched waiting cancel_requested);
    die_err("cannot reconcile terminal error from state '$s->{state}'", 4) unless $ok{$s->{state}};

    $s->{child_thread_id} = $opt{child_thread_id};
    $s->{child_run_id}    = $opt{child_run_id};
    $s->{reconciled_by}   = 'prompt_marker';
    $s->{state}           = $opt{state};
    $s->{reason}          = $opt{reason} // "terminal $opt{state} with no body";

    my $gen = $st->{generation};
    my $tx_id = "tx-recerr-$opt{slot}-a$opt{attempt}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
    print "RECONCILED_TERMINAL_ERROR=1\nSLOT=$opt{slot}\nSTATE=$opt{state}\n";
  });
}

sub cmd_reconcile_bind {
  my %opt = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt child_thread_id child_run_id)) {
    die_err("reconcile-bind missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot}, $opt{attempt});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }
    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot");
    die_err("reconcile-bind requires slot in needs_reconcile or dispatching", 4)
      unless $s->{state} eq 'needs_reconcile' || $s->{state} eq 'dispatching';
    die_err("attempt mismatch", 4) unless $s->{attempt} == $opt{attempt};

    $s->{child_thread_id} = $opt{child_thread_id};
    $s->{child_run_id}    = $opt{child_run_id};
    $s->{reconciled_by}   = 'manual_or_host_bind';
    if (defined $opt{task_id} && length $opt{task_id}) {
      $s->{task_id} = $opt{task_id};
      $s->{state}   = 'dispatched';
    } else {
      $s->{state}   = 'reconciled_untracked';
    }

    my $gen = $st->{generation};
    my $tx_id = "tx-rbind-$opt{slot}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
    print "RECONCILE_BOUND=1\nSLOT=$opt{slot}\nSTATE=$s->{state}\n";
  });
}

sub cmd_reconcile_abandon {
  my %opt = @_;
  for my $k (qw(task run_id generation owner owner_gen slot attempt reason)) {
    die_err("reconcile-abandon missing --$k") unless defined $opt{$k} && length $opt{$k};
  }
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my ($stale, $why) = check_stale_readonly($plans_dir, $opt{generation}, $opt{owner}, $opt{owner_gen}, $opt{run_id}, $opt{slot}, $opt{attempt});
    if ($stale) { print "STALE_CALLBACK=1\nREASON=$why\n"; exit 4; }
    recover_tx($real_task, $plans_dir);
    my $st  = load_state_or_undef($plans_dir) // die_err("missing state");
    my $run = load_json_file("$plans_dir/active-run.json");
    my $s   = $run->{slots}{$opt{slot}} // die_err("unknown slot");
    die_err("reconcile-abandon requires slot in needs_reconcile or reconciled_untracked", 4)
      unless $s->{state} eq 'needs_reconcile' || $s->{state} eq 'reconciled_untracked';
    die_err("attempt mismatch", 4) unless $s->{attempt} == $opt{attempt};

    push @{$st->{orphaned_attempts}}, {
      run_id             => $run->{run_id},
      phase              => $run->{phase},
      generation         => $run->{generation},
      owner_thread_id    => $run->{owner_thread_id},
      owner_generation   => $run->{owner_generation},
      slot               => $opt{slot},
      attempt            => $s->{attempt},
      state_at_orphan    => $s->{state},
      correlation_marker => $s->{correlation_marker},
      child_thread_id    => $s->{child_thread_id} // $s->{reconciled_child_thread_id},
      orphaned_at        => now_iso(),
      reason             => "reconcile-abandon: $opt{reason}",
    };
    $s->{state}  = 'cancelled';
    $s->{reason} = "abandoned: $opt{reason}";

    my $gen = $st->{generation};
    my $tx_id = "tx-raband-$opt{slot}-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $plans_dir, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/active-run.json', bytes => encode_canonical($run), is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
    print "RECONCILE_ABANDONED=1\nSLOT=$opt{slot}\nSTATE=cancelled\n";
  });
}

sub cmd_takeover_run {
  my %opt = @_;
  die_err("takeover-run requires --task, --new-owner, --reason")
    unless defined $opt{task} && defined $opt{new_owner} && defined $opt{reason};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'takeover-run', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'takeover-run');
      my $old_gen = $st->{generation} // 1;
      my $next_gen = $old_gen + 1;
      my $old_og  = $st->{owner_generation} // 1;
      my $next_og = $old_og + 1;

      my @orphans = (@{$st->{orphaned_attempts} || []}, _collect_orphaned_attempts($plans_dir, "takeover by $opt{new_owner}: $opt{reason}"));
      my $old_run_id;
      my @removes;
      if (-f "$plans_dir/active-run.json") {
        my $r = load_json_file("$plans_dir/active-run.json");
        $old_run_id = $r->{run_id};
        push @removes, 'research/plans/active-run.json';
      }

      my $tx_id = "tx-takeover-" . time() . "-$$";
      $st->{generation}        = $next_gen;
      $st->{owner_generation}  = $next_og;
      $st->{last_tx_id}        = $tx_id;
      $st->{orphaned_attempts} = \@orphans;
      $st->{last_takeover}     = {
        new_owner        => $opt{new_owner},
        reason           => $opt{reason},
        generation       => $next_gen,
        owner_generation => $next_og,
        at               => now_iso(),
      };

      execute_tx($real_task, $plans_dir, {
        tx_id                 => $tx_id,
        expected_generation   => $old_gen,
        next_generation       => $next_gen,
        next_owner_generation => $next_og,
        closes_run_id         => $old_run_id,
        state_first           => 1,
        removes               => \@removes,
        writes                => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "TAKEOVER_COMPLETE=1\nGENERATION=$next_gen\nOWNER_GENERATION=$next_og\nORPHANED_COUNT=" . scalar(@orphans) . "\n";
    });
  });
}

sub cmd_abort_run {
  my %opt = @_;
  die_err("abort-run requires --task and --reason") unless defined $opt{task} && defined $opt{reason};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'abort-run', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'abort-run');
      my $rf = "$plans_dir/active-run.json";
      if (!-f $rf) { print "ABORTED=0\nREASON=no active run\n"; return; }
      my $r = load_json_file($rf);
      my @orphans = (@{$st->{orphaned_attempts} || []}, _collect_orphaned_attempts($plans_dir, "abort: $opt{reason}"));
      my $gen = $st->{generation};
      my $tx_id = "tx-abort-" . time() . "-$$";
      $st->{last_tx_id}        = $tx_id;
      $st->{orphaned_attempts} = \@orphans;
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        closes_run_id       => $r->{run_id},
        removes             => ['research/plans/active-run.json'],
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "ABORTED=1\nCLOSED_RUN_ID=$r->{run_id}\n";
    });
  });
}

sub cmd_run_summary {
  my ($task_dir) = @_;
  die_err("run-summary requires --task") unless defined $task_dir && -d $task_dir;
  with_task_lock($task_dir, sub {
    my ($real_task, $plans_dir) = @_;
    recover_tx($real_task, $plans_dir);
    my $st = load_state_or_undef($plans_dir);
    my $rf = "$plans_dir/active-run.json";
    if (!-f $rf) {
      print "ACTIVE_RUN=0\n";
      print "ORPHANED_COUNT=" . scalar(@{$st->{orphaned_attempts} || []}) . "\n" if $st;
      return;
    }
    my $run = load_json_file($rf);
    print "ACTIVE_RUN=1\nRUN_ID=$run->{run_id}\nPHASE=$run->{phase}\nSTATUS=$run->{status}\n";
    print "GENERATION=$run->{generation}\nOWNER=$run->{owner_thread_id}\nOWNER_GENERATION=$run->{owner_generation}\n";
    for my $sn (sort keys %{$run->{slots} || {}}) {
      my $s = $run->{slots}{$sn};
      print "SLOT_${sn}_STATE=$s->{state}\n";
      print "SLOT_${sn}_ATTEMPT=$s->{attempt}\n";
      print "SLOT_${sn}_MARKER=" . ($s->{correlation_marker} // '') . "\n";
      print "SLOT_${sn}_TASK_ID=" . ($s->{task_id} // '') . "\n";
      print "SLOT_${sn}_CHILD_THREAD=" . ($s->{child_thread_id} // $s->{reconciled_child_thread_id} // '') . "\n";
      print "SLOT_${sn}_RESULT=" . ($s->{result_file} // '') . "\n";
    }
    print "ORPHANED_COUNT=" . scalar(@{$st->{orphaned_attempts} || []}) . "\n" if $st;
  });
}

# =============================================================================
# Phase 1, Phase 2a (Lock Before Reveal), reveal-blind-map, Phase 2b
# =============================================================================

sub cmd_commit_phase1 {
  my %opt = @_;
  die_err("commit-phase1 requires --task") unless defined $opt{task} && -d $opt{task};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'commit-phase1', sub {
      recover_tx($real_task, $plans_dir);
      my $st  = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'commit-phase1');
      if (ref($st->{review}) eq 'HASH' &&
          ref($st->{review}{user_decision}) eq 'HASH' &&
          ($st->{review}{user_decision}{choice} // '') eq 'manual_redesign') {
        die_err("manual_redesign is active — run clear-manual-redesign or commit-phase0 --change-kind material before committing Phase 1", 3);
      }
      my $rf  = "$plans_dir/active-run.json";
      die_err("no active phase1-design run") unless -f $rf;
      my $run = load_json_file($rf);
      die_err("active run is '$run->{phase}', expected 'phase1-design'") unless $run->{phase} eq 'phase1-design';

      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

      # Check worktree_fp v3 for unexplained drift (catches re-edits to existing M / ?? files!).
      my $cur_fp = compute_worktree_fp($repo, $trel);
      my $drifts = compare_worktree_fp($run->{worktree_fp_start}, $cur_fp, {});
      if (@$drifts) {
        print "UNEXPLAINED_DRIFT=1\n";
        print "DRIFT=$_\n" for @$drifts;
        exit 3;
      }

      my (@valid_slots, @non_valid_slots);
      for my $sn (sort keys %{$run->{slots}}) {
        my $s = $run->{slots}{$sn};
        if ($s->{state} eq 'completed_valid') { push @valid_slots, $sn; }
        else                                 { push @non_valid_slots, "$sn($s->{state})"; }
      }
      die_err("zero valid design candidates") unless @valid_slots >= 1;
      if (@non_valid_slots && !length($opt{degraded_approval} // '')) {
        die_err("incomplete Phase 1 slots: " . join(', ', @non_valid_slots) . " — complete/retry them or pass explicit --degraded-approval");
      }

      my (@writes, %cand_shas, %blind_map);
      for my $sn (@valid_slots) {
        my $s = $run->{slots}{$sn};
        my $src_res = _fs_join($real_task, $s->{result_file});
        die_err("missing recorded result file " . _display_path($src_res)) unless -f $src_res;
        my $bytes = read_raw_file($src_res);
        my $sha   = sha256_bytes($bytes);
        die_err("result digest mismatch for $sn") unless $sha eq $s->{result_sha256};
        push @writes, { dst => "research/plans/candidates/$sn.md", bytes => $bytes, is_state_file => 0 };
        $cand_shas{$sn} = $sha;
        $blind_map{$sn} = {
          providerInstanceId => $s->{target}{providerInstanceId},
          model              => $s->{target}{model},
          effortKey          => $s->{target}{effortKey} // '',
          effort             => $s->{target}{effort}    // '',
          task_id            => $s->{task_id},
          child_thread_id    => $s->{child_thread_id},
          child_run_id       => $s->{child_run_id},
          candidate_sha256   => $sha,
        };
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-p1-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $st->{blind_map}  = \%blind_map;
      $st->{phases}{'1'} = {
        status            => 'completed',
        prd_sha256        => $run->{input_manifest}{prd_sha256},
        candidates        => \%cand_shas,
        degraded_approval => length($opt{degraded_approval} // '')
          ? { reason => $opt{degraded_approval}, missing_slots => \@non_valid_slots, approved_at => now_iso() }
          : undef,
        completed_at      => now_iso(),
      };
      # Invalidate downstream Phase 2+ metadata AND review state if re-running Phase 1.
      delete $st->{phases}{'2'};
      delete $st->{phases}{'5'};
      delete $st->{phases}{'6'};
      $st->{design_revisions} = [];
      my $ign_proj = _effective_ignore_project_config($st, \%opt);
      $st->{review}           = _init_fresh_review(resolve_configured_knobs($repo, $ign_proj));

      my @p1_removes = ('research/plans/active-run.json');
      push @p1_removes, 'research/plans/review-ledger.md' if -f "$plans_dir/review-ledger.md" && !-l "$plans_dir/review-ledger.md";

      push @writes, { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 };
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        closes_run_id       => $run->{run_id},
        removes             => \@p1_removes,
        writes              => \@writes,
      });

      print "PHASE1_COMMITTED=1\nCANDIDATES=" . join(',', @valid_slots) . "\n";
    });
  });
}

sub cmd_commit_phase2a {
  my %opt = @_;
  die_err("commit-phase2a requires --task") unless defined $opt{task} && -d $opt{task};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'commit-phase2a', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'commit-phase2a');
      my $p1 = $st->{phases}{'1'};
      die_err("Phase 1 must be completed before commit-phase2a")
        unless ref $p1 eq 'HASH' && ($p1->{status} // '') eq 'completed';

      my $prd_path = "$real_task/prd.md";
      die_err("missing prd.md", 3) unless -f $prd_path && !-l $prd_path;
      die_err("prd.md modified since Phase 0 commit — run commit-phase0 first", 3)
        unless sha256_file($prd_path) eq ($st->{effective_prd_sha256} // '');
      for my $slot (sort keys %{$p1->{candidates} || {}}) {
        my $cp = _fs_join($plans_dir, 'candidates', "$slot.md");
        die_err("candidate file missing or modified: $slot.md", 3)
          unless -f $cp && !-l $cp && sha256_file($cp) eq $p1->{candidates}{$slot};
      }

      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

      my $input_file = $opt{input};
      my $raw_judge_bytes;
      my $closes_run_id;
      my @removes;
      if (-f "$plans_dir/active-run.json") {
        my $run = load_json_file("$plans_dir/active-run.json");
        die_err("active run is '$run->{phase}', expected 'phase2-judge'") unless $run->{phase} eq 'phase2-judge';
        my $cur_fp = compute_worktree_fp($repo, $trel);
        my $drifts = compare_worktree_fp($run->{worktree_fp_start}, $cur_fp, {});
        if (@$drifts) {
          print "UNEXPLAINED_DRIFT=1\n";
          print "DRIFT=$_\n" for @$drifts;
          exit 3;
        }
        my $js = $run->{slots}{judge};
        die_err("judge slot is '$js->{state}', expected 'completed_valid'", 3) unless ($js->{state} // '') eq 'completed_valid';
        my $expected_sha = $js->{result_sha256} // '';
        die_err("missing recorded judge result_sha256", 3) unless $expected_sha =~ /\A[0-9a-f]{64}\z/;
        my $slot_res = _fs_join($real_task, $js->{result_file});
        die_err("missing judge result file " . _display_path($slot_res), 3) unless -f $slot_res && !-l $slot_res;
        my $slot_bytes = read_raw_file($slot_res);
        die_err("recorded judge result digest mismatch (tampered on disk: $slot_res)", 3)
          unless sha256_bytes($slot_bytes) eq $expected_sha;
        if (defined $input_file && length $input_file) {
          die_err("--input missing or symlink: $input_file", 3) unless -f $input_file && !-l $input_file;
          my $in_bytes = read_raw_file($input_file);
          die_err("--input does not match recorded phase2-judge slot result", 3)
            unless sha256_bytes($in_bytes) eq $expected_sha && $in_bytes eq $slot_bytes;
        }
        $raw_judge_bytes = $slot_bytes;
        $closes_run_id = $run->{run_id};
        push @removes, 'research/plans/active-run.json';
      } else {
        die_err("commit-phase2a requires --input or active completed phase2-judge run")
          unless defined $input_file && -f $input_file && !-l $input_file;
        $raw_judge_bytes = read_raw_file($input_file);
      }

      # Validate the exact verified byte buffer (single read -> zero TOCTOU; NO --allow-forks -> zero unresolved product_forks!).
      my $tmp_dir   = tempdir('t3-tri-p2a-XXXXXX', TMPDIR => 1, CLEANUP => 1);
      my $in_tmp    = "$tmp_dir/judge-in.json";
      my $cm_tmp    = "$tmp_dir/cm.json";
      my $canon_tmp = "$tmp_dir/be.json";
      write_atomic_bytes($in_tmp, $raw_judge_bytes);
      write_atomic_bytes($cm_tmp, encode_canonical($p1->{candidates}));
      my ($rc, $vout) = run_cmd_capture(
        'perl', $VALIDATE_JUDGE,
        '--input', $in_tmp,
        '--candidates-manifest', $cm_tmp,
        '--write-canonical', $canon_tmp
      );
      my $vkv = parse_kv_lines($vout);
      if ($rc != 0 || ($vkv->{VALID} // '0') ne '1') {
        die_err("blind-eval validation failed: " . ($vkv->{ERROR} // $vout), 3);
      }

      my $be_bytes = read_raw_file($canon_tmp);
      my $be = decode_strict($be_bytes);
      my $be_sha = sha256_bytes($be_bytes);

      # Freeze synthesis-body-locked.md AND initial-design.md BEFORE attribution can ever be revealed!
      my $synth_body_text = $be->{synthesis_body_markdown};
      $synth_body_text .= "\n" unless $synth_body_text =~ /\n\z/;
      my $synth_body_bytes = encode('UTF-8', $synth_body_text);
      my $synth_body_sha = sha256_bytes($synth_body_bytes);

      my $init_design_text = $be->{initial_design_markdown};
      $init_design_text .= "\n" unless $init_design_text =~ /\n\z/;
      my $init_design_bytes = encode('UTF-8', $init_design_text);
      my $init_design_sha = sha256_bytes($init_design_bytes);

      # One-time unlocked -> locked CAS: refuse overwriting an already-locked Phase 2a!
      my $existing_p2 = $st->{phases}{'2'};
      if (ref($existing_p2) eq 'HASH' && $existing_p2->{phase2a_locked}) {
        if (($existing_p2->{blind_eval_sha256} // '') eq $be_sha &&
            ($existing_p2->{synthesis_body_locked_sha256} // '') eq $synth_body_sha &&
            ($existing_p2->{initial_design_sha256} // '') eq $init_design_sha &&
            !defined($closes_run_id)) {
          print "PHASE2A_ALREADY_LOCKED=1\nPHASE2A_LOCKED=1\nPRIMARY_WINNER=$existing_p2->{primary_winner}\n";
          print "BLIND_EVAL_SHA256=$be_sha\nSYNTHESIS_BODY_LOCKED_SHA256=$synth_body_sha\nINITIAL_DESIGN_SHA256=$init_design_sha\n";
          return;
        }
        die_err("FORBIDDEN: Phase 2a is already locked (blind_eval_sha256=$existing_p2->{blind_eval_sha256}) — refusing to overwrite locked blind judge outcome", 3);
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-p2a-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $st->{phases}{'2'} = {
        status                       => 'phase2a_locked',
        phase2a_locked               => JSON::PP::true,
        prd_sha256                   => $st->{effective_prd_sha256},
        candidates                   => $p1->{candidates},
        primary_winner               => $be->{primary_winner},
        blind_eval_sha256            => $be_sha,
        synthesis_body_locked_sha256 => $synth_body_sha,
        initial_design_sha256        => $init_design_sha,
        phase2a_locked_at            => now_iso(),
      };

      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        closes_run_id       => $closes_run_id,
        removes             => \@removes,
        writes              => [
          { dst => 'research/plans/blind-eval.json',          bytes => $be_bytes,          is_state_file => 0 },
          { dst => 'research/plans/synthesis-body-locked.md', bytes => $synth_body_bytes,  is_state_file => 0 },
          { dst => 'research/plans/initial-design.md',        bytes => $init_design_bytes, is_state_file => 0 },
          { dst => 'research/plans/planning-state.json',      bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });

      print "PHASE2A_LOCKED=1\nPRIMARY_WINNER=$be->{primary_winner}\n";
      print "BLIND_EVAL_SHA256=$be_sha\nSYNTHESIS_BODY_LOCKED_SHA256=$synth_body_sha\nINITIAL_DESIGN_SHA256=$init_design_sha\n";
    });
  });
}

sub cmd_reveal_blind_map {
  my ($task_dir) = @_;
  die_err("reveal-blind-map requires --task") unless defined $task_dir && -d $task_dir;
  with_task_lock($task_dir, sub {
    my ($real_task, $plans_dir) = @_;
    recover_tx($real_task, $plans_dir);
    my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
    my $p2 = $st->{phases}{'2'};
    die_err("FORBIDDEN: reveal-blind-map blocked until commit-phase2a locks blind-eval and initial-design", 3)
      unless ref $p2 eq 'HASH' && $p2->{phase2a_locked};
    die_err("blind-eval.json missing or modified since Phase 2a lock", 3)
      unless -f "$plans_dir/blind-eval.json" && sha256_file("$plans_dir/blind-eval.json") eq $p2->{blind_eval_sha256};
    die_err("initial-design.md missing or modified since Phase 2a lock", 3)
      unless -f "$plans_dir/initial-design.md" && sha256_file("$plans_dir/initial-design.md") eq $p2->{initial_design_sha256};

    print "BLIND_MAP_REVEALED=1\n";
    print "PRIMARY_WINNER=$p2->{primary_winner}\n";
    print "BLIND_MAP_JSON=" . encode_compact_chars($st->{blind_map} || {}) . "\n";
  });
}

sub _render_attribution_section {
  my ($blind_map, $winner) = @_;
  my @lines = (
    "",
    "---",
    "",
    "## Attribution Reveal",
    "",
    "| Slot | Role | Provider | Model | Effort | Child Thread |",
    "|---|---|---|---|---|---|",
  );
  for my $slot (sort keys %$blind_map) {
    my $m = $blind_map->{$slot};
    my $role = ($slot eq $winner) ? '**Primary Winner**' : 'Eliminated';
    my $eff  = length($m->{effortKey} // '') ? "$m->{effortKey}=$m->{effort}" : ($m->{effort} // '-');
    my $ct   = $m->{child_thread_id} // '-';
    push @lines, "| `$slot` | $role | `$m->{providerInstanceId}` | `$m->{model}` | `$eff` | `$ct` |";
  }
  return join("\n", @lines) . "\n";
}

sub cmd_commit_phase2b {
  my %opt = @_;
  die_err("commit-phase2b requires --task") unless defined $opt{task} && -d $opt{task};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'commit-phase2b', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'commit-phase2b');
      my $p2 = $st->{phases}{'2'};
      die_err("Phase 2a must be locked before commit-phase2b", 3)
        unless ref $p2 eq 'HASH' && $p2->{phase2a_locked};

      # Verify locked artifacts are untouched.
      die_err("blind-eval.json modified since Phase 2a lock", 3)
        unless -f "$plans_dir/blind-eval.json" && sha256_file("$plans_dir/blind-eval.json") eq $p2->{blind_eval_sha256};
      die_err("synthesis-body-locked.md modified since Phase 2a lock", 3)
        unless -f "$plans_dir/synthesis-body-locked.md" && sha256_file("$plans_dir/synthesis-body-locked.md") eq $p2->{synthesis_body_locked_sha256};
      die_err("initial-design.md modified since Phase 2a lock", 3)
        unless -f "$plans_dir/initial-design.md" && sha256_file("$plans_dir/initial-design.md") eq $p2->{initial_design_sha256};

      # Strictly enforce first-time commit from phase2a_locked ONLY; once completed, permit ONLY write-free idempotent retry!
      if (($p2->{status} // '') eq 'completed') {
        my $has_revs   = (ref($st->{design_revisions}) eq 'ARRAY' && @{$st->{design_revisions}} > 0) ? 1 : 0;
        my $has_rounds = (ref($st->{review}) eq 'HASH' && ref($st->{review}{rounds}) eq 'ARRAY' && @{$st->{review}{rounds}} > 0) ? 1 : 0;
        my $same_design = (-f "$real_task/design.md" && !-l "$real_task/design.md" &&
                           sha256_file("$real_task/design.md") eq ($p2->{design_sha256} // '') &&
                           ($p2->{design_sha256} // '') eq ($p2->{initial_design_sha256} // '')) ? 1 : 0;
        my $same_synth  = (-f "$plans_dir/synthesis.md" && !-l "$plans_dir/synthesis.md" &&
                           sha256_file("$plans_dir/synthesis.md") eq ($p2->{synthesis_sha256} // '')) ? 1 : 0;
        if (!$has_revs && !$has_rounds && $same_design && $same_synth) {
          print "PHASE2B_COMMITTED=1\nPHASE2B_IDEMPOTENT=1\nSYNTHESIS_SHA256=$p2->{synthesis_sha256}\nDESIGN_SHA256=$p2->{design_sha256}\n";
          return;
        }
        die_err("FORBIDDEN: Phase 2b is already completed and downstream design revisions/reviews exist — refusing to overwrite design.md or clear design_revisions[]", 3);
      }
      die_err("commit-phase2b requires Phase 2 status 'phase2a_locked' (got '" . ($p2->{status} // 'unset') . "')", 3)
        unless ($p2->{status} // '') eq 'phase2a_locked';

      my $locked_synth  = read_raw_file("$plans_dir/synthesis-body-locked.md");
      my $locked_design = read_raw_file("$plans_dir/initial-design.md");
      my @writes;
      my ($synth_sha, $design_sha);

      if ($opt{assemble}) {
        my $attr = encode('UTF-8', _render_attribution_section($st->{blind_map} || {}, $p2->{primary_winner}));
        my $full_synth = $locked_synth . $attr;
        $synth_sha  = sha256_bytes($full_synth);
        $design_sha = $p2->{initial_design_sha256};
        push @writes, { dst => 'research/plans/synthesis.md', bytes => $full_synth,   is_state_file => 0 };
        push @writes, { dst => 'design.md',                   bytes => $locked_design, is_state_file => 0 };
      } else {
        # Mechanical anti-swap verification when parent wrote synthesis.md / design.md directly!
        die_err("missing design.md", 3) unless -f "$real_task/design.md" && !-l "$real_task/design.md";
        die_err("missing research/plans/synthesis.md", 3) unless -f "$plans_dir/synthesis.md" && !-l "$plans_dir/synthesis.md";
        $design_sha = sha256_file("$real_task/design.md");
        die_err("POST_REVEAL_TAMPER: design.md differs from pre-reveal locked initial-design.md ($design_sha != $p2->{initial_design_sha256})", 3)
          unless $design_sha eq $p2->{initial_design_sha256};
        my $live_synth = read_raw_file("$plans_dir/synthesis.md");
        die_err("POST_REVEAL_TAMPER: synthesis.md does not begin verbatim with locked synthesis-body-locked.md", 3)
          unless index($live_synth, $locked_synth) == 0;
        $synth_sha = sha256_bytes($live_synth);
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-p2b-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $p2->{status}            = 'completed';
      $p2->{synthesis}         = $synth_sha;
      $p2->{synthesis_sha256}  = $synth_sha;
      $p2->{design_sha256}     = $design_sha;
      $p2->{completed_at}      = now_iso();
      $st->{design_revisions}  = [];

      push @writes, { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 };
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => \@writes,
      });

      print "PHASE2B_COMMITTED=1\nSYNTHESIS_SHA256=$synth_sha\nDESIGN_SHA256=$design_sha\n";
    });
  });
}

# =============================================================================
# Phase 3 & Phase 4: Review Routing, Finish Round, Dispositions, Decisions
# =============================================================================

sub _count_open_blocking {
  my ($rev) = @_;
  my @open;
  for my $cid (sort keys %{$rev->{classes} || {}}) {
    my $c = $rev->{classes}{$cid};
    next unless ($c->{status} // '') eq 'open';
    my $sev = $c->{severity} // '';
    my $dsp = $c->{disposition} // '';
    if ($sev eq 'BLOCKER' || $sev eq 'SHOULD_FIX' || $dsp eq 'unresolved-dispute') {
      push @open, $cid;
    }
  }
  return @open;
}

sub _compute_next_review {
  my ($real_task, $plans_dir, $repo, $trel, $st, $ignore_proj) = @_;
  $ignore_proj = _effective_ignore_project_config($st, {}) unless defined $ignore_proj;
  my $rev = $st->{review};

  # 1. Active Phase 3 run -> resume
  if (-f "$plans_dir/active-run.json") {
    my $r = load_json_file("$plans_dir/active-run.json");
    if (($r->{phase} // '') eq 'phase3-review') {
      return { purpose => 'resume', mode => 'resume', profile => 'resume', reason => "open phase3 run $r->{run_id}" };
    }
  }

  # 1b. Live prd.md must match committed effective_prd_sha256!
  my $eff_prd  = $st->{effective_prd_sha256} // '';
  my $live_prd = (-f "$real_task/prd.md" && !-l "$real_task/prd.md") ? sha256_file("$real_task/prd.md") : '';
  if (!length($live_prd) || $live_prd ne $eff_prd) {
    return { purpose => 'prd-changed', mode => 'phase0', profile => 'none', reason => 'prd.md modified or missing relative to committed effective_prd_sha256 — run commit-phase0 first' };
  }

  # 2. manual_redesign hard blocker (beats converged!)
  if (ref($rev->{user_decision}) eq 'HASH' && ($rev->{user_decision}{choice} // '') eq 'manual_redesign') {
    return { purpose => 'blocked-manual-redesign', mode => 'blocked', profile => 'none', reason => 'manual_redesign decision is active' };
  }

  # 3. disposition-required gate (open blocking/unresolved-dispute classes, unassessed step-back even with empty findings, scope fork)
  my @open_blk = _count_open_blocking($rev);
  if (@open_blk) {
    return { purpose => 'disposition-required', mode => 'phase4', profile => 'none', reason => 'open blocking classes: ' . join(',', @open_blk) };
  }
  if (($rev->{step_back_assessment_status} // 'none') eq 'pending') {
    return { purpose => 'disposition-required', mode => 'phase4', profile => 'none', reason => 'pending Phase 4c step-back structural assessment' };
  }
  if ($rev->{pending_scope_decision}) {
    return { purpose => 'disposition-required', mode => 'phase4', profile => 'none', reason => 'pending scope/product decision' };
  }

  my $live_design_sha = (-f "$real_task/design.md" && !-l "$real_task/design.md") ? sha256_file("$real_task/design.md") : '';
  my $live_ledger_sha = (-f "$plans_dir/review-ledger.md" && !-l "$plans_dir/review-ledger.md") ? sha256_file("$plans_dir/review-ledger.md") : '';
  my ($live_non_prd) = compute_non_prd_baseline($repo, $real_task, $trel, $st);
  my $live_baseline  = compute_review_baseline($eff_prd, $live_non_prd);

  # 4. converged (clean_streak >= 2, last_clean_mode == full, live baseline AND ledger match!)
  if (($rev->{clean_streak} // 0) >= 2 &&
      ($rev->{last_clean_mode} // '') eq 'full' &&
      defined($rev->{converged_at_round}) &&
      ($rev->{converged_baseline_sha256} // '') eq $live_baseline &&
      ($rev->{converged_ledger_sha256}   // '') eq $live_ledger_sha) {
    return { purpose => 'converged', mode => 'converged', profile => 'none', baseline => $live_baseline };
  }

  # 5. eligible user_decision (narrow_scope_and_proceed or dispose_and_close_review, bound to live baseline & ledger!)
  if (ref($rev->{user_decision}) eq 'HASH') {
    my $ud = $rev->{user_decision};
    my $ch = $ud->{choice} // '';
    if (($ch eq 'narrow_scope_and_proceed' || $ch eq 'dispose_and_close_review') &&
        ($ud->{effective_prd_sha256}   // '') eq $eff_prd &&
        ($ud->{design_sha256}          // '') eq $live_design_sha &&
        ($ud->{ledger_sha256}          // '') eq $live_ledger_sha &&
        ($ud->{review_baseline_sha256} // '') eq $live_baseline) {
      return { purpose => 'user-decided', mode => 'user-decided', profile => 'none', baseline => $live_baseline };
    }
  }

  # 6. roundCap -> step-back or stop (always derived from live effective config + ignore_project_config + extra step-back grants)
  my $live_knobs = resolve_configured_knobs($repo, $ignore_proj);
  my $cap        = $live_knobs->{roundCap};
  my $dirty      = $rev->{dirty_since_step_back} // 0;
  my $sb_done    = $rev->{step_backs_done} // 0;
  my $extra_sb   = defined($rev->{extra_step_backs_granted})
    ? int($rev->{extra_step_backs_granted})
    : scalar(@{$rev->{extra_step_back_authorizations} || []});
  my $sb_max     = $live_knobs->{maxStepBacks} + $extra_sb;
  if ($cap > 0 && $dirty >= $cap) {
    if ($sb_done < $sb_max) {
      return { purpose => 'step-back', mode => 'step-back', profile => 'council', baseline => $live_baseline };
    }
    return { purpose => 'stop', mode => 'stop', profile => 'none', baseline => $live_baseline };
  }

  # 7. clean_streak == 1 on SAME live review_baseline_sha256 -> confirmation-full
  if (($rev->{clean_streak} // 0) == 1 && ($rev->{last_clean_baseline_sha256} // '') eq $live_baseline) {
    return { purpose => 'confirmation-full', mode => 'full', profile => 'default', baseline => $live_baseline };
  }

  # 8. First review round of current PRD lineage -> initial-full (council)
  if (scalar(@{$rev->{rounds} || []}) == 0) {
    return { purpose => 'initial-full', mode => 'full', profile => 'council', baseline => $live_baseline };
  }

  # 9. Same design SHA as last reviewed -> full (default, warn design unchanged)
  if (($rev->{last_reviewed_design_sha256} // '') eq $live_design_sha) {
    return { purpose => 'full', mode => 'full', profile => 'default', warn => 'design unchanged since last review', baseline => $live_baseline };
  }

  # 10. Previous snapshot exists and matches last_reviewed_design_sha256 -> incremental, else fallback full!
  my $prev = $rev->{last_reviewed_snapshot} // '';
  my $prev_abs = length($prev) ? _fs_join($real_task, $prev) : '';
  if (length $prev && -f $prev_abs && !-l $prev_abs &&
      sha256_file($prev_abs) eq ($rev->{last_reviewed_design_sha256} // '')) {
    return { purpose => 'incremental', mode => 'incremental', profile => 'default', prev_snapshot => $prev, baseline => $live_baseline };
  }

  return { purpose => 'full', mode => 'full', profile => 'default', warn => 'previous snapshot missing or corrupted — falling back to full', baseline => $live_baseline };
}

sub cmd_next_review {
  my %opt = @_;
  die_err("next-review requires --task") unless defined $opt{task} && -d $opt{task};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    recover_tx($real_task, $plans_dir);
    my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
    my $repo = resolve_repo_root($opt{repo}, $real_task);
    my $trel = task_rel_path($repo, $real_task);
    my $r = _compute_next_review($real_task, $plans_dir, $repo, $trel, $st, _effective_ignore_project_config($st, \%opt));
    print "PURPOSE=$r->{purpose}\nMODE=$r->{mode}\nPROFILE=$r->{profile}\n";
    print "REASON=$r->{reason}\n" if defined $r->{reason} && length $r->{reason};
    print "WARN=$r->{warn}\n" if defined $r->{warn} && length $r->{warn};
    print "PREV_SNAPSHOT=" . _display_path($real_task) . "/$r->{prev_snapshot}\n" if defined $r->{prev_snapshot} && length $r->{prev_snapshot};
    print "REVIEW_BASELINE_SHA256=$r->{baseline}\n" if defined $r->{baseline} && length $r->{baseline};
  });
}

sub _render_ledger_md {
  my ($st) = @_;
  my $rev = $st->{review};
  my @lines = (
    "# Design Review Ledger (t3-tri-plan)",
    "",
    "- **PRD Lineage**: `$st->{prd_lineage}`",
    "- **Effective PRD**: `$st->{effective_prd_sha256}`",
    "- **Dirty Since Step-Back**: `$rev->{dirty_since_step_back}` / `$rev->{round_cap}`",
    "- **Step-Backs Done**: `$rev->{step_backs_done}` / `$rev->{max_step_backs_allowed}`",
    "- **Clean Streak**: `$rev->{clean_streak}`",
    "",
    "## Rounds",
    "",
  );
  for my $r (@{$rev->{rounds} || []}) {
    my $deg = $r->{degraded} ? " (degraded)" : "";
    push @lines, "- **Round $r->{n}** (`$r->{mode}` / `$r->{purpose}`$deg): verdict=`$r->{verdict}`, design=`$r->{sha}`, prd=`$r->{reviewed_prd_sha256}`";
  }
  push @lines, "", "## Classes", "";
  for my $cid (sort { (substr($a,1) <=> substr($b,1)) || ($a cmp $b) } keys %{$rev->{classes} || {}}) {
    my $c = $rev->{classes}{$cid};
    my $rec = $c->{recurring} ? " **[RECURRING]**" : "";
    push @lines, "### $cid [$c->{severity}]$rec — $c->{title}";
    push @lines, "- **Status**: `$c->{status}` | **Disposition**: `" . ($c->{disposition} // 'none') . "`";
    push @lines, "- **Rounds Seen**: " . join(', ', @{$c->{rounds_seen} || []});
    push @lines, "- **Pattern**: $c->{pattern}";
    push @lines, "- **Violates REVIEW.md rule**: `$c->{violates_review_md_rule}`" if length($c->{violates_review_md_rule} // '');
    push @lines, "- **Disposition Note**: $c->{disposition_note}" if length($c->{disposition_note} // '');
    if (ref($c->{codified}) eq 'HASH') {
      my $co = $c->{codified};
      push @lines, "- **Codified**: `$co->{invariant_id}` | guard=`$co->{guard_test}`"
        . (length($co->{review_md_entry} // '') ? " | REVIEW.md=`$co->{review_md_entry}`" : '');
    }
    push @lines, "";
  }
  return join("\n", @lines) . "\n";
}

sub _verify_review_slot_binding {
  my ($real_task, $run, $valid_slots_ref, $merged_obj, $dismissed_path) = @_;
  my %rank = (BLOCKER => 3, SHOULD_FIX => 2, OPTIONAL => 1);
  my $is_blocking = sub { my ($s) = @_; return ($s eq 'BLOCKER' || $s eq 'SHOULD_FIX') ? 1 : 0; };
  my $run_dir_real = abs_path(_fs_join($real_task, 'research', 'plans', 'runs', $run->{run_id}));
  my @slot_objs;

  for my $sn (@$valid_slots_ref) {
    my $s = $run->{slots}{$sn};
    my $rf = $s->{result_file} // '';
    my $rsha = $s->{result_sha256} // '';
    die_err("valid slot $sn missing recorded result_file or result_sha256", 3)
      unless length($rf) && $rsha =~ /\A[0-9a-f]{64}\z/;
    my $abs_rf = _fs_join($real_task, $rf);
    die_err("missing or symlink slot result file for $sn: " . _display_path($abs_rf), 3) unless -f $abs_rf && !-l $abs_rf;
    my $real_rf = abs_path($abs_rf) // die_err("cannot resolve slot result file " . _display_path($abs_rf), 3);
    die_err("slot $sn result_file escapes run dir", 3)
      unless defined($run_dir_real) && index($real_rf, "$run_dir_real/") == 0;
    my $sbytes = read_raw_file($abs_rf);
    die_err("slot $sn result_file digest mismatch (tampered on disk)", 3)
      unless sha256_bytes($sbytes) eq $rsha;
    my $sobj = eval { decode_strict($sbytes) };
    die_err("slot $sn canonical result_file invalid JSON: $@", 3) if $@ || ref $sobj ne 'HASH';
    my $t  = $s->{target} || {};
    my $mtag = ($t->{providerInstanceId} // '') . '/' . ($t->{model} // '');
    my (%reopened_cls, %blocking_reopened_cls, %verified_cls);
    for my $f (@{$sobj->{findings} || []}) {
      if (length($f->{reopens} // '')) {
        my $rk = $rank{$f->{severity}} // 0;
        $reopened_cls{$f->{reopens}} = $rk if ($reopened_cls{$f->{reopens}} // 0) < $rk;
        if ($is_blocking->($f->{severity})) {
          $blocking_reopened_cls{$f->{reopens}} = $rk if ($blocking_reopened_cls{$f->{reopens}} // 0) < $rk;
        }
      }
    }
    for my $v (@{$sobj->{verified} || []}) {
      $verified_cls{$v->{id}} = 1 if defined $v->{id} && length $v->{id};
    }
    push @slot_objs, {
      slot                  => $sn,
      mtag                  => $mtag,
      meta                  => $s,
      obj                   => $sobj,
      reopened_classes      => \%reopened_cls,
      blocking_reopened     => \%blocking_reopened_cls,
      verified_classes      => \%verified_cls,
    };
  }

  my $strip_merged_meta = sub {
    my ($o) = @_;
    return encode_compact({
      summary                => $o->{summary},
      mode                   => $o->{mode},
      reviewed_design_sha256 => $o->{reviewed_design_sha256},
      verdict                => $o->{verdict},
      findings               => [ map { my %x = %$_; delete $x{sources}; delete $x{dispute_note}; \%x } @{$o->{findings} || []} ],
      verified               => [ map { my %x = %$_; delete $x{sources}; delete $x{dispute_note}; \%x } @{$o->{verified} || []} ],
      step_back              => [ map { my %x = %$_; delete $x{sources}; \%x } @{$o->{step_back} || []} ],
      out_of_scope           => $o->{out_of_scope} || [],
    });
  };

  if (@slot_objs == 1) {
    my $so = $slot_objs[0];
    if (ref($merged_obj->{disputes}) eq 'ARRAY' && @{$merged_obj->{disputes}} > 0) {
      die_err("single-reviewer merged result cannot contain disputes[]", 3);
    }
    if ($strip_merged_meta->($merged_obj) ne $strip_merged_meta->($so->{obj})) {
      die_err("single-reviewer merged JSON diverges from recorded canonical slot result ($so->{slot})", 3);
    }
    return;
  }

  # Multi-reviewer council: load optional evidenced --dismissed-findings with strict typed string checks (1-to-1 consumable!).
  my @dismissed;
  if (defined $dismissed_path && length $dismissed_path) {
    die_err("--dismissed-findings not found or symlink: $dismissed_path", 3)
      unless -f $dismissed_path && !-l $dismissed_path;
    my $dnode = eval { load_json_file_typed($dismissed_path) };
    die_err("--dismissed-findings must be a JSON array: $@", 3) if $@ || ref($dnode) ne 'ARRAY' || $dnode->[0] ne 'arr';
    my $idx = 0;
    for my $dn (@{$dnode->[1]}) {
      $idx++;
      die_err("--dismissed-findings[$idx] must be an object", 3) unless $dn->[0] eq 'obj';
      my $dh = $dn->[1];
      for my $req (qw(slot title severity code_evidence)) {
        die_err("--dismissed-findings[$idx].$req must be a non-empty string", 3)
          unless exists $dh->{$req} && $dh->{$req}[0] eq 'str' && $dh->{$req}[1] =~ /\S/;
      }
      my $sev = $dh->{severity}[1];
      die_err("--dismissed-findings[$idx].severity invalid", 3) unless exists $rank{$sev};
      my $reo = '';
      if (exists $dh->{reopens} && $dh->{reopens}[0] ne 'null') {
        die_err("--dismissed-findings[$idx].reopens must be a string", 3) unless $dh->{reopens}[0] eq 'str';
        $reo = $dh->{reopens}[1];
      }
      push @dismissed, {
        slot          => $dh->{slot}[1],
        title         => $dh->{title}[1],
        severity      => $sev,
        code_evidence => $dh->{code_evidence}[1],
        reopens       => $reo,
      };
    }
  }

  my @dism_used = (0) x scalar(@dismissed);
  my $consume_dismissal = sub {
    my ($sn, $mtag, $f) = @_;
    for my $idx (0 .. $#dismissed) {
      next if $dism_used[$idx];
      my $d = $dismissed[$idx];
      next unless $d->{slot} eq $sn || $d->{slot} eq $mtag;
      next unless $d->{severity} eq $f->{severity};
      next unless $d->{title} eq $f->{title};
      my $f_reo = $f->{reopens} // '';
      my $d_reo = $d->{reopens} // '';
      if (length($f_reo) || length($d_reo)) {
        next unless $d_reo eq $f_reo;
      }
      $dism_used[$idx] = 1;
      return 1;
    }
    return 0;
  };

  # Map valid recorded slots by slot name and unique model tag for strict dispute verification.
  my %slot_by_name = map { $_->{slot} => $_ } @slot_objs;
  my %slots_by_mtag;
  push @{$slots_by_mtag{$_->{mtag}}}, $_ for @slot_objs;

  my %disputed_classes;
  for my $dp (@{$merged_obj->{disputes} || []}) {
    my $cid = $dp->{class_id} // '';
    my $res = $dp->{resolution} // '';
    die_err("duplicate dispute entry for class '$cid'", 3) if exists $disputed_classes{$cid};
    my (%seen_canon, $has_reopen_pos, $has_verified_pos);
    for my $rp (@{$dp->{reviewer_positions} || []}) {
      my $ref_slot = $rp->{slot} // '';
      my $so = $slot_by_name{$ref_slot};
      if (!$so && exists $slots_by_mtag{$ref_slot} && @{$slots_by_mtag{$ref_slot}} == 1) {
        $so = $slots_by_mtag{$ref_slot}[0];
      }
      die_err("dispute for $cid cites unknown or non-valid slot '$ref_slot'", 3) unless $so;
      die_err("dispute for $cid cites slot '$so->{slot}' more than once", 3) if $seen_canon{$so->{slot}}++;
      my $pos = $rp->{position} // '';
      if ($pos eq 'reopen' || $pos eq 'finding') {
        die_err("dispute for $cid claims slot $so->{slot} took position '$pos', but recorded slot did not reopen $cid", 3)
          unless exists $so->{reopened_classes}{$cid};
        $has_reopen_pos = 1;
      } elsif ($pos eq 'verified') {
        die_err("dispute for $cid claims slot $so->{slot} verified $cid, but recorded slot did not verify $cid", 3)
          unless $so->{verified_classes}{$cid};
        $has_verified_pos = 1;
      } else {
        die_err("dispute for $cid has invalid position '$pos'", 3);
      }
    }
    die_err("dispute for $cid lacks genuine reopen-vs-verified disagreement among recorded valid slots", 3)
      unless $has_reopen_pos && $has_verified_pos;
    for my $so (@slot_objs) {
      if (exists $so->{blocking_reopened}{$cid} && !$seen_canon{$so->{slot}}) {
        die_err("dispute for $cid omits slot $so->{slot} which recorded a blocking reopen of $cid", 3);
      }
    }
    $disputed_classes{$cid} = $res;
  }

  # Reject contradictory --dismissed-findings on any class whose dispute resolved 'reopen',
  # and ensure every 'reopen' dispute is actually represented in merged findings[].
  for my $d (@dismissed) {
    if (length($d->{reopens}) && ($disputed_classes{$d->{reopens}} // '') eq 'reopen') {
      die_err("contradictory --dismissed-findings for class $d->{reopens}: dispute resolved as 'reopen' cannot be dismissed", 3);
    }
  }
  for my $cid (sort keys %disputed_classes) {
    if ($disputed_classes{$cid} eq 'reopen') {
      my $has_reopen_finding = grep { ($_->{reopens} // '') eq $cid } @{$merged_obj->{findings} || []};
      die_err("dispute for $cid resolved as 'reopen' but merged findings[] has no entry reopening $cid", 3)
        unless $has_reopen_finding;
    }
  }

  my $norm = sub {
    my ($s) = @_;
    $s = defined $s ? lc($s) : '';
    $s =~ s/\A\s+|\s+\z//g;
    $s =~ s/\s+/ /g;
    return $s;
  };

  my $finding_locs = sub {
    my ($f) = @_;
    my %locs;
    for my $raw (($f->{location} // ''), @{$f->{instances} || []}) {
      my $n = $norm->($raw);
      $locs{$n} = 1 if length $n;
    }
    return \%locs;
  };

  my $locs_overlap = sub {
    my ($la, $lb) = @_;
    for my $k (keys %$la) {
      return 1 if $lb->{$k};
    }
    return 0;
  };

  my $text_matches = sub {
    my ($a, $b) = @_;
    my ($na, $nb) = ($norm->($a), $norm->($b));
    return 0 unless length($na) && length($nb);
    return 1 if $na eq $nb;
    my ($short, $long) = (length($na) <= length($nb)) ? ($na, $nb) : ($nb, $na);
    my $min_len = ($short =~ /[^\x00-\x7f]/) ? 4 : 6;
    return 0 if length($short) < $min_len;
    return 0 if length($nb) < length($na) && (length($nb) * 2 < length($na));
    if ($short =~ /[^\x00-\x7f]/) {
      return index($long, $short) >= 0 ? 1 : 0;
    }
    return ($long =~ /(?:\A|[^a-z0-9])\Q$short\E(?:[^a-z0-9]|\z)/) ? 1 : 0;
  };

  # Bipartite maximum matching helper (Kuhn) for strict 1-to-1 per-slot traceability.
  my $has_perfect_matching = sub {
    my ($n_left, $n_right, $adj) = @_;
    my @match_r = (-1) x $n_right;
    my $dfs;
    $dfs = sub {
      my ($u, $vis) = @_;
      for my $v (@{$adj->[$u] || []}) {
        next if $vis->[$v];
        $vis->[$v] = 1;
        if ($match_r[$v] == -1 || $dfs->($match_r[$v], $vis)) {
          $match_r[$v] = $u;
          return 1;
        }
      }
      return 0;
    };
    for my $u (0 .. $n_left - 1) {
      my @vis = (0) x $n_right;
      return 0 unless $dfs->($u, \@vis);
    }
    return 1;
  };

  my $has_src = sub {
    my ($item, $sn, $mtag) = @_;
    for my $src (@{$item->{sources} || []}) {
      return 1 if $src eq $sn || $src eq $mtag;
    }
    return 0;
  };

  # Reject duplicate copies in merged findings[] and step_back[] (prevents padding duplicates to drop independent items!).
  my @m_findings = @{$merged_obj->{findings} || []};
  my @m_sbs      = @{$merged_obj->{step_back} || []};
  my (%seen_mf_tl, %seen_mf_lp, %seen_mf_tpf);
  for my $mf (@m_findings) {
    my $nreo = $norm->($mf->{reopens});
    my $k_tl  = join("\0", $nreo, $norm->($mf->{title}), $norm->($mf->{location}));
    die_err("duplicate merged finding detected: $mf->{title} ($mf->{location})", 3) if $seen_mf_tl{$k_tl}++;
    my $k_lp  = join("\0", $nreo, $norm->($mf->{location}), $norm->($mf->{pattern}));
    die_err("duplicate merged finding location/pattern detected: $mf->{title} ($mf->{location})", 3) if $seen_mf_lp{$k_lp}++;
    my $k_tpf = join("\0", $nreo, $norm->($mf->{title}), $norm->($mf->{pattern}), $norm->($mf->{fix}));
    die_err("duplicate merged finding title/pattern/fix detected: $mf->{title} ($mf->{location})", 3) if $seen_mf_tpf{$k_tpf}++;
  }
  my (%seen_sb_name, %seen_sb_app);
  for my $msb (@m_sbs) {
    my $ckey = join(',', sort map { $norm->($_) } @{$msb->{classes} || []});
    my $kn = join("\0", $ckey, $norm->($msb->{name}));
    my $ka = join("\0", $ckey, $norm->($msb->{approach_change}));
    die_err("duplicate merged step_back[] proposal detected: $msb->{name}", 3)
      if $seen_sb_name{$kn}++ || $seen_sb_app{$ka}++;
  }

  my @unaccounted;

  for my $so (@slot_objs) {
    my $sn   = $so->{slot};
    my $mtag = $so->{mtag};

    # 1. Per-finding 1-to-1 identity-bound blocking finding binding.
    #    Reopened blocking findings are exempted ONLY when a validated dispute resolved 'verified' or 'unresolved'
    #    (resolution 'reopen' MUST keep the reopened finding at >= severity and CANNOT be dismissed!).
    my @need_f;
    for my $f (@{$so->{obj}{findings} || []}) {
      next unless $is_blocking->($f->{severity});
      if (length($f->{reopens} // '')) {
        my $dres = $disputed_classes{$f->{reopens}} // '';
        if ($dres eq 'reopen') {
          die_err("contradictory --dismissed-findings for reopened blocking class $f->{reopens} whose dispute resolved as 'reopen'", 3)
            if $consume_dismissal->($sn, $mtag, $f);
          push @need_f, $f;
          next;
        }
        next if $dres eq 'verified' || $dres eq 'unresolved';
      }
      next if $consume_dismissal->($sn, $mtag, $f);
      push @need_f, $f;
    }

    if (@need_f) {
      my @cand_mf = grep { $is_blocking->($_->{severity}) } @m_findings;
      my @need_locs = map { $finding_locs->($_) } @need_f;
      my @cand_locs = map { $finding_locs->($_) } @cand_mf;
      my @same_loc_peer = (0) x scalar(@need_f);
      for my $i (0 .. $#need_f) {
        for my $k ($i + 1 .. $#need_f) {
          if ($locs_overlap->($need_locs[$i], $need_locs[$k])) {
            $same_loc_peer[$i] = 1;
            $same_loc_peer[$k] = 1;
          }
        }
      }
      my @adj;
      for my $i (0 .. $#need_f) {
        my $nf   = $need_f[$i];
        my $nrk  = $rank{$nf->{severity}} // 0;
        my $nreo = $nf->{reopens} // '';
        my @edges;
        for my $j (0 .. $#cand_mf) {
          my $mf  = $cand_mf[$j];
          my $mrk = $rank{$mf->{severity}} // 0;
          next if $mrk < $nrk;
          if (length $nreo) {
            next unless ($mf->{reopens} // '') eq $nreo;
            if (ref($mf->{sources}) eq 'ARRAY' && @{$mf->{sources}}) {
              next unless $has_src->($mf, $sn, $mtag);
            }
          } else {
            next unless $has_src->($mf, $sn, $mtag);
            my $loc_ok = $locs_overlap->($need_locs[$i], $cand_locs[$j]);
            my $id_ok  = $text_matches->($nf->{title}, $mf->{title}) || $text_matches->($nf->{pattern}, $mf->{pattern});
            next unless $loc_ok || $text_matches->($nf->{title}, $mf->{title});
            next if $same_loc_peer[$i] && !$id_ok;
          }
          push @edges, $j;
        }
        push @adj, \@edges;
      }
      if (!$has_perfect_matching->(scalar(@need_f), scalar(@cand_mf), \@adj)) {
        my @titles = map { "$_->{severity}:" . (length($_->{reopens} // '') ? "$_->{reopens}:" : '') . $_->{title} } @need_f;
        push @unaccounted, "slot $sn ($mtag) has " . scalar(@need_f) . " undismissed blocking finding(s) [" . join(', ', @titles) . "] not matched 1-to-1 by identity/instances in merged findings[] at >= severity (with slot sources / matching reopens) without validated dispute or evidenced --dismissed-findings";
      }
    }

    # 2. Per-proposal 1-to-1 identity-bound step_back[] binding (sources, class-set superset, AND proposal identity!).
    my @slot_sbs = @{$so->{obj}{step_back} || []};
    if (@slot_sbs) {
      my @cand_sbs = grep { $has_src->($_, $sn, $mtag) } @m_sbs;
      my @adj;
      for my $i (0 .. $#slot_sbs) {
        my $sb = $slot_sbs[$i];
        my %need_cls = map { $_ => 1 } @{$sb->{classes} || []};
        my @edges;
        for my $j (0 .. $#cand_sbs) {
          my $msb = $cand_sbs[$j];
          my %got_cls = map { $_ => 1 } @{$msb->{classes} || []};
          my $ok_cls = 1;
          for my $c (keys %need_cls) {
            if (!$got_cls{$c}) { $ok_cls = 0; last; }
          }
          next unless $ok_cls;
          next unless $text_matches->($sb->{name}, $msb->{name}) || $text_matches->($sb->{approach_change}, $msb->{approach_change});
          push @edges, $j;
        }
        push @adj, \@edges;
      }
      if (!$has_perfect_matching->(scalar(@slot_sbs), scalar(@cand_sbs), \@adj)) {
        push @unaccounted, "slot $sn ($mtag) reported " . scalar(@slot_sbs) . " step_back[] proposal(s) not preserved 1-to-1 by class/proposal identity in merged step_back[]";
      }
    }
  }

  if (@unaccounted) {
    die_err("council blocking finding traceability failed: " . join('; ', @unaccounted), 3);
  }
}

sub cmd_finish_review_round {
  my %opt = @_;
  die_err("finish-review-round requires --task") unless defined $opt{task} && -d $opt{task};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'finish-review-round', sub {
      recover_tx($real_task, $plans_dir);
      my $st  = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'finish-review-round');
      my $rf  = "$plans_dir/active-run.json";
      die_err("no active phase3-review run") unless -f $rf;
      my $run = load_json_file($rf);
      die_err("active run is '$run->{phase}', expected 'phase3-review'") unless $run->{phase} eq 'phase3-review';

      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

      # Verify at least one valid reviewer slot completed; require explicit degraded approval if any slot non-valid.
      my (@valid_slots, @bad_slots);
      for my $sn (sort keys %{$run->{slots}}) {
        if ($run->{slots}{$sn}{state} eq 'completed_valid') { push @valid_slots, $sn; }
        else                                               { push @bad_slots, "$sn($run->{slots}{$sn}{state})"; }
      }
      die_err("cannot finish review round with zero valid reviewers", 3) unless @valid_slots >= 1;
      if (@bad_slots && !length($opt{degraded_approval} // '')) {
        die_err("incomplete council slots: " . join(', ', @bad_slots) . " — retry or pass explicit --degraded-approval", 3);
      }

      my $merged_input_path = $opt{merged_input};
      if (!defined($merged_input_path) || !length($merged_input_path)) {
        if (@valid_slots == 1) {
          my $s1 = $run->{slots}{$valid_slots[0]};
          $merged_input_path = _fs_join($real_task, $s1->{result_file}) if defined $s1->{result_file};
        }
      }
      die_err("finish-review-round requires --merged-input <path> (or single valid reviewer slot)")
        unless defined $merged_input_path && -f $merged_input_path && !-l $merged_input_path;

      # Check mid-round drift across design.md, prd.md, frozen round artifacts, worktree_fp v3, and review_baseline_sha256!
      my $cur_fp = compute_worktree_fp($repo, $trel);
      my $drifts = compare_worktree_fp($run->{worktree_fp_start}, $cur_fp, $run->{allowed_setup_writes} || {});
      my $live_design_sha = (-f "$real_task/design.md" && !-l "$real_task/design.md") ? sha256_file("$real_task/design.md") : '';
      push @$drifts, "design.md changed mid-round ($run->{reviewed_design_sha256} -> $live_design_sha)"
        if $live_design_sha ne $run->{reviewed_design_sha256};
      my $live_prd_sha = (-f "$real_task/prd.md" && !-l "$real_task/prd.md") ? sha256_file("$real_task/prd.md") : '';
      push @$drifts, "prd.md changed mid-round ($run->{effective_prd_sha256} -> $live_prd_sha)"
        if $live_prd_sha ne $run->{effective_prd_sha256};
      for my $fcheck (
        [ $run->{design_snapshot_rel},      $run->{reviewed_design_sha256}, 'frozen design snapshot' ],
        [ $run->{frozen_ledger_rel},        ($run->{frozen_ledger_sha256} // (length($trel) ? $run->{allowed_setup_writes}{"$trel/$run->{frozen_ledger_rel}"} : undef)), 'frozen ledger' ],
        [ $run->{ledger_manifest_rel},      ($run->{ledger_manifest_sha256} // (length($trel) ? $run->{allowed_setup_writes}{"$trel/$run->{ledger_manifest_rel}"} : undef)), 'ledger manifest' ],
        [ $run->{round_input_manifest_rel}, ($run->{round_input_manifest_sha256} // (length($trel) ? $run->{allowed_setup_writes}{"$trel/$run->{round_input_manifest_rel}"} : undef)), 'round input manifest' ],
      ) {
        my ($rel, $want, $label) = @$fcheck;
        next unless defined $rel && length $rel && defined $want && length $want;
        my $p = _fs_join($real_task, $rel);
        if (!-f $p || -l $p) {
          push @$drifts, "$label missing or symlink ($rel)";
        } else {
          my $got = sha256_file($p);
          push @$drifts, "$label modified mid-round ($rel: $want -> $got)" if $got ne $want;
        }
      }
      my ($live_non_prd) = compute_non_prd_baseline($repo, $real_task, $trel, $st);
      my $live_baseline  = compute_review_baseline($live_prd_sha, $live_non_prd);
      push @$drifts, "review_baseline_sha256 drifted mid-round ($run->{review_baseline_sha256} -> $live_baseline)"
        if $live_baseline ne $run->{review_baseline_sha256};

      if (@$drifts) {
        # Discard drifted round WITHOUT touching ledger or counters!
        my $gen = $st->{generation};
        my $tx_id = "tx-drift-r$run->{round_num}-" . time() . "-$$";
        $st->{last_tx_id} = $tx_id;
        execute_tx($real_task, $plans_dir, {
          tx_id               => $tx_id,
          expected_generation => $gen,
          next_generation     => $gen,
          closes_run_id       => $run->{run_id},
          removes             => ['research/plans/active-run.json'],
          writes              => [
            { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
          ],
        });
        print "DRIFTED=1\nROUND_DISCARDED=1\n";
        print "DRIFT=$_\n" for @$drifts;
        exit 3;
      }

      # Snapshot external inputs ONCE into $tmp_dir (zero TOCTOU across parse, binding verification, and archival!).
      my $tmp_dir   = tempdir('t3-tri-fin-XXXXXX', TMPDIR => 1, CLEANUP => 1);
      my $in_snap   = "$tmp_dir/merged-in.json";
      write_atomic_bytes($in_snap, read_raw_file($merged_input_path));
      my ($dism_snap, $dism_bytes);
      if (defined $opt{dismissed_findings} && length $opt{dismissed_findings}) {
        die_err("--dismissed-findings not found or symlink: $opt{dismissed_findings}", 3)
          unless -f $opt{dismissed_findings} && !-l $opt{dismissed_findings};
        $dism_bytes = read_raw_file($opt{dismissed_findings});
        $dism_snap  = "$tmp_dir/dismissed-in.json";
        write_atomic_bytes($dism_snap, $dism_bytes);
      }

      # Strictly re-validate merged result JSON (with --merged + frozen ledger manifest)!
      my $canon_tmp = "$tmp_dir/result.json";
      my $md_tmp    = "$tmp_dir/review.md";
      my ($rc, $vout) = run_cmd_capture(
        'perl', $PARSE_REVIEW,
        '--input', $in_snap,
        '--expected-mode', $run->{mode},
        '--expected-design-sha', $run->{reviewed_design_sha256},
        '--ledger-manifest', _fs_join($real_task, $run->{ledger_manifest_rel}),
        '--merged',
        '--write-canonical', $canon_tmp,
        '--render-md', $md_tmp
      );
      my $vkv = parse_kv_lines($vout);
      if ($rc != 0 || ($vkv->{VALID} // '0') ne '1') {
        die_err("merged review validation failed: " . ($vkv->{ERROR} // $vout), 3);
      }

      my $m_bytes  = read_raw_file($canon_tmp);
      my $md_bytes = read_raw_file($md_tmp);
      my $m = decode_strict($m_bytes);

      # Enforce strict slot-to-merged binding (single reviewer exact match; council 1-to-1 finding/step_back/dispute binding)!
      _verify_review_slot_binding($real_task, $run, \@valid_slots, $m, $dism_snap);

    my $eff_verdict = $vkv->{EFFECTIVE_VERDICT}; # clean | dirty
    my $rev = $st->{review};
    my $rn  = $run->{round_num};
    my (@new_ids, @reopened_ids, @recurring_ids);
    my %round_seen_class; # Guarantee 1 occurrence per council round!

    for my $f (@{$m->{findings}}) {
      my $cid;
      if (length($f->{reopens} // '')) {
        $cid = $f->{reopens};
        my $c = $rev->{classes}{$cid};
        $c->{severity} = $f->{severity} if $f->{severity} eq 'BLOCKER' || ($f->{severity} eq 'SHOULD_FIX' && $c->{severity} eq 'OPTIONAL');
        $c->{status}   = ($f->{severity} eq 'OPTIONAL') ? 'optional' : 'open';
        $c->{disposition} = 'reopened' if $f->{severity} ne 'OPTIONAL';
        if (!$round_seen_class{$cid}++) {
          push @{$c->{rounds_seen}}, $rn;
          push @reopened_ids, $cid;
        }
        $c->{violates_review_md_rule} = $f->{violates_review_md_rule}
          if length($f->{violates_review_md_rule} // '');
      } else {
        $cid = "D" . ($rev->{next_class_num}++);
        $rev->{classes}{$cid} = {
          id                      => $cid,
          severity                => $f->{severity},
          title                   => $f->{title},
          pattern                 => $f->{pattern},
          location                => $f->{location},
          status                  => ($f->{severity} eq 'OPTIONAL') ? 'optional' : 'open',
          disposition             => ($f->{severity} eq 'OPTIONAL') ? 'optional-noted' : undef,
          disposition_note        => '',
          rounds_seen             => [ $rn ],
          recurring               => JSON::PP::false,
          violates_review_md_rule => $f->{violates_review_md_rule} // '',
          codified                => undef,
        };
        $round_seen_class{$cid} = 1;
        push @new_ids, $cid;
      }
      my $c = $rev->{classes}{$cid};
      if (scalar(@{$c->{rounds_seen}}) >= 2 || length($c->{violates_review_md_rule} // '')) {
        $c->{recurring} = JSON::PP::true;
        push @recurring_ids, $cid;
      }
    }

    # Any class named by step_back[] is promoted to recurring!
    for my $sb (@{$m->{step_back} || []}) {
      for my $cid (@{$sb->{classes}}) {
        if (exists $rev->{classes}{$cid}) {
          $rev->{classes}{$cid}{recurring} = JSON::PP::true;
          push @recurring_ids, $cid;
        }
      }
    }

    # Unresolved council disputes keep target class open / force dirty.
    for my $d (@{$m->{disputes} || []}) {
      if (($d->{resolution} // '') eq 'unresolved' && exists $rev->{classes}{$d->{class_id}}) {
        $rev->{classes}{$d->{class_id}}{status} = 'open';
        $rev->{classes}{$d->{class_id}}{disposition} = 'unresolved-dispute';
      }
    }

    # Counter & streak state transitions (exact Plan v4.1 semantics!).
    $rev->{last_reviewed_design_sha256} = $run->{reviewed_design_sha256};
    $rev->{last_reviewed_snapshot}      = $run->{design_snapshot_rel};

    if ($run->{mode} eq 'step-back') {
      # FIX dual-plan bug: step-back ALWAYS increments step_backs_done AND resets dirty_since_step_back = 0!
      $rev->{step_backs_done}       = ($rev->{step_backs_done} // 0) + 1;
      $rev->{dirty_since_step_back} = 0;
      $rev->{clean_streak}          = 0;
      $rev->{converged_at_round}    = undef;
      # Even if findings[] was empty, structural step-back MUST go through Phase 4c evaluation!
      $rev->{step_back_assessment_status} = 'pending';
    } elsif ($eff_verdict eq 'dirty') {
      $rev->{dirty_since_step_back} = ($rev->{dirty_since_step_back} // 0) + 1;
      $rev->{clean_streak}          = 0;
      $rev->{converged_at_round}    = undef;
    } else {
      # Clean non-step-back round!
      my $prev_streak = $rev->{clean_streak} // 0;
      my $same_base   = (($rev->{last_clean_baseline_sha256} // '') eq $run->{review_baseline_sha256}) ? 1 : 0;
      my $inherit_wording = 0;
      if (!$same_base && $opt{inherit_wording_confirmation} && $prev_streak >= 1) {
        # Only inherit prior clean_streak == 1 across wording update if non_prd_baseline_sha256 is IDENTICAL!
        my %equiv = map { $_ => 1 } @{$st->{wording_equivalent_prd_shas} || []};
        if ($equiv{$rev->{last_clean_prd_sha256} // ''} &&
            ($rev->{last_clean_non_prd_sha256} // '') eq $run->{non_prd_baseline_sha256}) {
          $inherit_wording = 1;
        }
      }
      if ($prev_streak >= 1 && ($same_base || $inherit_wording)) {
        $rev->{clean_streak} = $prev_streak + 1;
      } else {
        $rev->{clean_streak} = 1;
      }
      $rev->{last_clean_mode}            = $run->{mode};
      $rev->{last_clean_baseline_sha256} = $run->{review_baseline_sha256};
      $rev->{last_clean_prd_sha256}      = $run->{effective_prd_sha256};
      $rev->{last_clean_non_prd_sha256}  = $run->{non_prd_baseline_sha256};
    }

    push @{$rev->{rounds}}, {
      n                       => $rn,
      mode                    => $run->{mode},
      purpose                 => $run->{purpose},
      snapshot                => $run->{design_snapshot_rel},
      sha                     => $run->{reviewed_design_sha256},
      reviewed_prd_sha256     => $run->{effective_prd_sha256},
      non_prd_baseline_sha256 => $run->{non_prd_baseline_sha256},
      review_baseline_sha256  => $run->{review_baseline_sha256},
      verdict                 => $eff_verdict,
      new                     => \@new_ids,
      reopened                => \@reopened_ids,
      degraded                => (@bad_slots ? JSON::PP::true : JSON::PP::false),
      degraded_approval       => (@bad_slots ? $opt{degraded_approval} : undef),
      committed_at            => now_iso(),
    };

      my $ledger_bytes = encode('UTF-8', _render_ledger_md($st));
      my $ledger_sha = sha256_bytes($ledger_bytes);

      # Check convergence proof AFTER ledger update!
      my @open_blk = _count_open_blocking($rev);
      if ($run->{mode} ne 'step-back' && $eff_verdict eq 'clean' &&
          $rev->{clean_streak} >= 2 && $rev->{last_clean_mode} eq 'full' && !@open_blk) {
        $rev->{converged_at_round}       = $rn;
        $rev->{converged_baseline_sha256} = $run->{review_baseline_sha256};
        $rev->{converged_prd_sha256}     = $run->{effective_prd_sha256};
        $rev->{converged_non_prd_sha256} = $run->{non_prd_baseline_sha256};
        $rev->{converged_ledger_sha256}  = $ledger_sha;
      }

      my @fin_writes = (
        { dst => "$run->{round_dir_rel}/result.json",  bytes => $m_bytes,      is_state_file => 0 },
        { dst => "$run->{round_dir_rel}/review.md",    bytes => $md_bytes,     is_state_file => 0 },
        { dst => 'research/plans/review-ledger.md',    bytes => $ledger_bytes, is_state_file => 0 },
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      );
      if (defined $dism_bytes) {
        push @fin_writes, {
          dst           => "$run->{round_dir_rel}/dismissed-findings.json",
          bytes         => $dism_bytes,
          is_state_file => 0,
        };
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-fin-r$rn-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $fin_writes[3]{bytes} = encode_canonical($st);
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        closes_run_id       => $run->{run_id},
        removes             => ['research/plans/active-run.json'],
        writes              => \@fin_writes,
      });

      print "ROUND_COMMITTED=1\nROUND_NUM=$rn\nVERDICT=$eff_verdict\n";
      print "CLEAN_STREAK=$rev->{clean_streak}\nDIRTY_SINCE_STEP_BACK=$rev->{dirty_since_step_back}\n";
      print "STEP_BACKS_DONE=$rev->{step_backs_done}\n";
      print "CONVERGED=" . (defined($rev->{converged_at_round}) ? 1 : 0) . "\n";
    });
  });
}

sub cmd_commit_phase4_revision {
  my %opt = @_;
  die_err("commit-phase4-revision requires --task") unless defined $opt{task} && -d $opt{task};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'commit-phase4-revision', sub {
      recover_tx($real_task, $plans_dir);
      my $st  = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'commit-phase4-revision');
      my $rev = $st->{review};

      if (defined $opt{dispositions_json} && length $opt{dispositions_json}) {
        my $disp_node = load_json_file_typed($opt{dispositions_json});
        die_err("--dispositions-json must be an array") unless ref($disp_node) eq 'ARRAY' && $disp_node->[0] eq 'arr';
        my %valid_d = map { $_ => 1 } qw(adopted rejected moved-to-implement out-of-scope);
        for my $item_node (@{$disp_node->[1]}) {
          die_err("disposition entry must be an object") unless $item_node->[0] eq 'obj';
          my $ih = $item_node->[1];
          die_err("disposition missing non-empty string id")
            unless exists $ih->{id} && $ih->{id}[0] eq 'str' && $ih->{id}[1] =~ /\S/;
          my $cid = $ih->{id}[1];
          die_err("disposition for $cid missing string disposition")
            unless exists $ih->{disposition} && $ih->{disposition}[0] eq 'str';
          my $kind = $ih->{disposition}[1];
          die_err("unknown class $cid in disposition") unless exists $rev->{classes}{$cid};
          die_err("invalid disposition '$kind' for $cid") unless $valid_d{$kind};
          my $note = '';
          if (exists $ih->{note} && $ih->{note}[0] ne 'null') {
            die_err("disposition note for $cid must be a string") unless $ih->{note}[0] eq 'str';
            $note = $ih->{note}[1];
          }
          my $c = $rev->{classes}{$cid};
          $c->{disposition}      = $kind;
          $c->{disposition_note} = $note;
          $c->{status}           = 'disposed';
          if ($c->{recurring}) {
            die_err("recurring class $cid MUST provide codified.{invariant_id, guard_test} (non-blank strings)")
              unless exists $ih->{codified} && $ih->{codified}[0] eq 'obj';
            my $coh = $ih->{codified}[1];
            die_err("recurring class $cid MUST provide codified.{invariant_id, guard_test} (non-blank strings)")
              unless exists $coh->{invariant_id} && $coh->{invariant_id}[0] eq 'str' && $coh->{invariant_id}[1] =~ /\S/ &&
                     exists $coh->{guard_test}   && $coh->{guard_test}[0]   eq 'str' && $coh->{guard_test}[1]   =~ /\S/;
            my $rme = '';
            if (exists $coh->{review_md_entry} && $coh->{review_md_entry}[0] ne 'null') {
              die_err("recurring class $cid codified.review_md_entry must be a string")
                unless $coh->{review_md_entry}[0] eq 'str';
              $rme = $coh->{review_md_entry}[1];
            }
            $c->{codified} = {
              invariant_id    => $coh->{invariant_id}[1],
              guard_test      => $coh->{guard_test}[1],
              review_md_entry => $rme,
            };
          }
        }
      }

      die_err("cannot pass both --mark-scope-fork and --clear-scope-fork")
        if $opt{mark_scope_fork} && $opt{clear_scope_fork};
      $rev->{step_back_assessment_status} = 'completed'     if $opt{step_back_assessment_done};
      $rev->{pending_scope_decision}      = JSON::PP::true  if $opt{mark_scope_fork};
      $rev->{pending_scope_decision}      = JSON::PP::false if $opt{clear_scope_fork};

      # Controlled design.md revision chain update (keeps Phase 2 valid!).
      my $p2 = $st->{phases}{'2'};
      die_err("Phase 2 must be completed before Phase 4 revision")
        unless ref $p2 eq 'HASH' && ($p2->{status} // '') eq 'completed';
      my $live_design_sha = sha256_file("$real_task/design.md");
      my $revs = $st->{design_revisions} || [];
      my $expected_parent = @$revs ? $revs->[-1]{new_sha256} : $p2->{initial_design_sha256};

      my $gen = $st->{generation};
      my $tx_id = "tx-p4-" . time() . "-$$";
      my $design_changed = ($live_design_sha ne $expected_parent) ? 1 : 0;
      if ($design_changed) {
        push @$revs, {
          seq               => scalar(@$revs) + 1,
          round             => scalar(@{$rev->{rounds} || []}),
          generation        => $gen,
          prd_lineage       => $st->{prd_lineage},
          disposition_tx_id => $tx_id,
          parent_sha256     => $expected_parent,
          new_sha256        => $live_design_sha,
          at                => now_iso(),
        };
        $st->{design_revisions} = $revs;
        # Editing design invalidates prior clean streak & convergence!
        $rev->{clean_streak}       = 0;
        $rev->{converged_at_round} = undef;
      }

      my $ledger_bytes = encode('UTF-8', _render_ledger_md($st));
      $st->{last_tx_id} = $tx_id;
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/review-ledger.md',    bytes => $ledger_bytes, is_state_file => 0 },
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "PHASE4_COMMITTED=1\nDESIGN_CHANGED=$design_changed\nCURRENT_DESIGN_SHA256=$live_design_sha\n";
    });
  });
}

sub cmd_authorize_step_back {
  my %opt = @_;
  die_err("authorize-step-back requires --task and --reason") unless defined $opt{task} && defined $opt{reason};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'authorize-step-back', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'authorize-step-back');
      $st->{review}{max_step_backs_allowed}   = ($st->{review}{max_step_backs_allowed} // 1) + 1;
      $st->{review}{extra_step_backs_granted} = ($st->{review}{extra_step_backs_granted} // 0) + 1;
      push @{$st->{review}{extra_step_back_authorizations}}, { reason => $opt{reason}, at => now_iso() };
      my $gen = $st->{generation};
      my $tx_id = "tx-auth-sb-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "STEP_BACK_AUTHORIZED=1\nMAX_STEP_BACKS_ALLOWED=$st->{review}{max_step_backs_allowed}\n";
    });
  });
}

sub cmd_record_user_decision {
  my %opt = @_;
  die_err("record-user-decision requires --task, --choice, --reason")
    unless defined $opt{task} && defined $opt{choice} && defined $opt{reason};
  my %valid = map { $_ => 1 } qw(authorize_extra_step_back narrow_scope_and_proceed manual_redesign dispose_and_close_review);
  die_err("invalid --choice '$opt{choice}'") unless $valid{$opt{choice}};

  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'record-user-decision', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'record-user-decision');
      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);
      my $rev = $st->{review};

      if (ref($rev->{user_decision}) eq 'HASH' && ($rev->{user_decision}{choice} // '') eq 'manual_redesign') {
        die_err("manual_redesign is active — run clear-manual-redesign or commit-phase0 --change-kind material first", 3);
      }

      my $eff_prd  = $st->{effective_prd_sha256} // '';
      my $prd_path = "$real_task/prd.md";
      die_err("missing prd.md", 3) unless -f $prd_path && !-l $prd_path;
      die_err("prd.md modified since Phase 0 commit — run commit-phase0 first", 3)
        unless sha256_file($prd_path) eq $eff_prd;

      if ($opt{choice} eq 'authorize_extra_step_back') {
        $rev->{max_step_backs_allowed}   = ($rev->{max_step_backs_allowed} // 1) + 1;
        $rev->{extra_step_backs_granted} = ($rev->{extra_step_backs_granted} // 0) + 1;
        push @{$rev->{extra_step_back_authorizations}}, { reason => $opt{reason}, at => now_iso() };
      }
      if ($opt{choice} eq 'narrow_scope_and_proceed' || $opt{choice} eq 'dispose_and_close_review') {
        my @open_blk = _count_open_blocking($rev);
        die_err("cannot record '$opt{choice}' while blocking classes remain open: " . join(',', @open_blk), 3)
          if @open_blk;
        die_err("cannot record '$opt{choice}' while step-back assessment is pending", 3)
          if ($rev->{step_back_assessment_status} // 'none') eq 'pending';
      }

      my $design_sha  = sha256_file("$real_task/design.md");
      my $ledger_sha  = (-f "$plans_dir/review-ledger.md") ? sha256_file("$plans_dir/review-ledger.md") : '';
      my ($non_prd)   = compute_non_prd_baseline($repo, $real_task, $trel, $st);
      my $base_sha    = compute_review_baseline($eff_prd, $non_prd);

      $rev->{user_decision} = {
        choice                  => $opt{choice},
        reason                  => $opt{reason},
        effective_prd_sha256    => $eff_prd,
        non_prd_baseline_sha256 => $non_prd,
        review_baseline_sha256  => $base_sha,
        design_sha256           => $design_sha,
        ledger_sha256           => $ledger_sha,
        at                      => now_iso(),
      };

      my $gen = $st->{generation};
      my $tx_id = "tx-ud-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "USER_DECISION_RECORDED=1\nCHOICE=$opt{choice}\nREVIEW_BASELINE_SHA256=$base_sha\n";
    });
  });
}

sub cmd_clear_manual_redesign {
  my %opt = @_;
  die_err("clear-manual-redesign requires --task and --reason") unless defined $opt{task} && defined $opt{reason};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    _with_activation_lock_guard($plans_dir, 'clear-manual-redesign', sub {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      _guard_phase6_not_in_flight($st, 'clear-manual-redesign');
      die_err("manual_redesign is not active")
        unless ref($st->{review}{user_decision}) eq 'HASH' && ($st->{review}{user_decision}{choice} // '') eq 'manual_redesign';
      $st->{review}{cleared_manual_redesigns} ||= [];
      push @{$st->{review}{cleared_manual_redesigns}}, { %{$st->{review}{user_decision}}, cleared_reason => $opt{reason}, cleared_at => now_iso() };
      $st->{review}{user_decision} = undef;
      $st->{review}{clean_streak}  = 0;
      $st->{review}{converged_at_round} = undef;

      my $gen = $st->{generation};
      my $tx_id = "tx-clrmr-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "MANUAL_REDESIGN_CLEARED=1\n";
    });
  });
}

# =============================================================================
# Freshness Gate, Phase 5 Validator & Phase 6 Activation
# =============================================================================

sub _validate_jsonl_non_seed {
  my ($repo_root, $jsonl_path) = @_;
  return (0, "missing $jsonl_path") unless -f $jsonl_path && !-l $jsonl_path;
  my $real_repo = abs_path($repo_root) // return (0, "invalid repo root $repo_root");
  my $raw = read_raw_file($jsonl_path);
  my $real_entries = 0;
  my $line_no = 0;
  for my $line (split(/\r?\n/, $raw)) {
    $line_no++;
    next unless $line =~ /\S/;
    my $node = eval { decode_strict_typed($line) };
    return (0, "$jsonl_path:$line_no invalid JSON: $@") if $@ || ref($node) ne 'ARRAY' || $node->[0] ne 'obj';
    my $oh = $node->[1];
    next unless exists $oh->{file};
    return (0, "$jsonl_path:$line_no 'file' must be a JSON string")
      unless $oh->{file}[0] eq 'str';
    my $rel = $oh->{file}[1];
    next unless length $rel;
    return (0, "$jsonl_path:$line_no 'file' must not be whitespace-only") unless $rel =~ /\S/;
    return (0, "$jsonl_path:$line_no absolute or traversal path forbidden: $rel")
      if $rel =~ m{\A/} || $rel =~ /\0/ || $rel =~ m{(?:\A|/)\.\.(?:/|\z)} || $rel eq '.' || $rel =~ m{\A\./?\z};
    my $rel_bytes = encode('UTF-8', $rel);
    my $target = File::Spec->catfile($real_repo, $rel_bytes);
    return (0, "$jsonl_path:$line_no referenced path not found: $rel") unless -e $target;
    my $real_target = abs_path($target);
    return (0, "$jsonl_path:$line_no referenced path escapes repo root: $rel")
      unless defined $real_target && index($real_target, "$real_repo/") == 0;
    $real_entries++;
  }
  return (0, "$jsonl_path has zero non-seed entries (seed-only manifests are invalid)") if $real_entries < 1;
  return (1, "ok ($real_entries real entries)");
}

sub _validate_implement_codification {
  my ($real_task, $st) = @_;
  my $imp_path = "$real_task/implement.md";
  return (0, "missing implement.md") unless -f $imp_path && !-l $imp_path;
  my $imp_txt = eval { decode('UTF-8', read_raw_file($imp_path), FB_CROAK | LEAVE_SRC) };
  return (0, "implement.md is not valid UTF-8") if $@ || !defined $imp_txt;
  my $des_txt = '';
  if (-f "$real_task/design.md" && !-l "$real_task/design.md") {
    $des_txt = eval { decode('UTF-8', read_raw_file("$real_task/design.md"), FB_CROAK | LEAVE_SRC) };
    return (0, "design.md is not valid UTF-8") if $@ || !defined $des_txt;
  }
  # Load typed AST of planning-state.json so numeric/boolean codified values cannot slip past Perl scalar coercion!
  my $typed_classes;
  my $sf = "$real_task/research/plans/planning-state.json";
  if (-f $sf && !-l $sf) {
    my $st_typed = eval { load_json_file_typed($sf) };
    return (0, "planning-state.json invalid typed JSON: $@") if $@ || ref($st_typed) ne 'ARRAY' || $st_typed->[0] ne 'obj';
    my $rev_n = $st_typed->[1]{review};
    if (ref($rev_n) eq 'ARRAY' && $rev_n->[0] eq 'obj' &&
        ref($rev_n->[1]{classes}) eq 'ARRAY' && $rev_n->[1]{classes}[0] eq 'obj') {
      $typed_classes = $rev_n->[1]{classes}[1];
    }
  }

  my @missing;
  for my $cid (sort keys %{$st->{review}{classes} || {}}) {
    my $c = $st->{review}{classes}{$cid};
    if (($c->{disposition} // '') eq 'moved-to-implement') {
      push @missing, "moved-to-implement class $cid not referenced in implement.md"
        unless index($imp_txt, $cid) >= 0;
    }
    if ($c->{recurring}) {
      my $tc = ($typed_classes && exists $typed_classes->{$cid} && $typed_classes->{$cid}[0] eq 'obj')
        ? $typed_classes->{$cid}[1] : undef;
      my $tco = ($tc && exists $tc->{codified} && $tc->{codified}[0] eq 'obj')
        ? $tc->{codified}[1] : undef;
      if (!$tco ||
          !exists $tco->{invariant_id} || $tco->{invariant_id}[0] ne 'str' || $tco->{invariant_id}[1] !~ /\S/ ||
          !exists $tco->{guard_test}   || $tco->{guard_test}[0]   ne 'str' || $tco->{guard_test}[1]   !~ /\S/) {
        push @missing, "recurring class $cid lacks non-blank JSON string codified.{invariant_id, guard_test}";
        next;
      }
      my $inv = $tco->{invariant_id}[1];
      my $gt  = $tco->{guard_test}[1];
      my $rme = '';
      if (exists $tco->{review_md_entry} && $tco->{review_md_entry}[0] ne 'null') {
        if ($tco->{review_md_entry}[0] ne 'str') {
          push @missing, "recurring class $cid codified.review_md_entry must be a JSON string";
          next;
        }
        $rme = $tco->{review_md_entry}[1];
      }
      push @missing, "recurring invariant $inv ($cid) not found in design.md"
        unless index($des_txt, $inv) >= 0;
      push @missing, "recurring invariant $inv ($cid) not referenced in implement.md"
        unless index($imp_txt, $inv) >= 0;
      push @missing, "recurring guard test '$gt' ($cid) not referenced in implement.md"
        unless index($imp_txt, $gt) >= 0;
      if ($rme =~ /\S/) {
        push @missing, "recurring REVIEW.md entry '$rme' ($cid) not referenced in implement.md"
          unless index($imp_txt, $rme) >= 0;
      }
    }
  }
  return (@missing ? (0, join('; ', @missing)) : (1, 'ok'));
}

# Validate upstream DAG from Phase 0 -> Phase 4 (shared by _evaluate_freshness AND commit-phase5).
sub _evaluate_upstream_freshness {
  my ($real_task, $plans_dir, $repo, $trel, $st, $ignore_proj) = @_;

  if (!$st) {
    return { ok => 0, next_stage => 'phase0', reasons => ['missing planning-state.json'] };
  }
  if (($st->{pipeline} // '') ne 't3-tri-plan') {
    return { ok => 0, next_stage => 'legacy', reasons => ['legacy dual-plan task (run /trellis:dual-plan or migrate-legacy --confirm)'] };
  }

  # Phase 0
  if (!-f "$real_task/prd.md" || -l "$real_task/prd.md") {
    return { ok => 0, next_stage => 'phase0', reasons => ['missing prd.md'] };
  }
  my $live_prd = sha256_file("$real_task/prd.md");
  if (($st->{phases}{'0'}{status} // '') ne 'completed' || ($st->{effective_prd_sha256} // '') ne $live_prd) {
    return { ok => 0, next_stage => 'phase0', reasons => ['prd.md changed or Phase 0 incomplete/unverified'] };
  }
  my %equiv_prd = map { $_ => 1 } @{$st->{wording_equivalent_prd_shas} || [$st->{prd_lineage}]};

  # Phase 1
  my $p1 = $st->{phases}{'1'};
  if (ref $p1 ne 'HASH' || ($p1->{status} // '') ne 'completed' || !$equiv_prd{$p1->{prd_sha256} // ''}) {
    return { ok => 0, next_stage => 'phase1', reasons => ['Phase 1 incomplete, unverified, or stale for PRD'] };
  }
  if (ref($p1->{candidates}) ne 'HASH' || !keys %{$p1->{candidates}}) {
    return { ok => 0, next_stage => 'phase1', reasons => ['Phase 1 has no committed candidates'] };
  }
  for my $slot (sort keys %{$p1->{candidates}}) {
    my $cp = _fs_join($plans_dir, 'candidates', "$slot.md");
    if (!-f $cp || -l $cp || sha256_file($cp) ne $p1->{candidates}{$slot}) {
      return { ok => 0, next_stage => 'phase1', reasons => ["candidate $slot.md missing or hash mismatch"] };
    }
  }

  # Phase 2a & 2b
  my $p2 = $st->{phases}{'2'};
  if (ref $p2 ne 'HASH' || !$p2->{phase2a_locked}) {
    return { ok => 0, next_stage => 'phase2a', reasons => ['Phase 2a blind-eval not locked'] };
  }
  if (!-f "$plans_dir/blind-eval.json" || sha256_file("$plans_dir/blind-eval.json") ne ($p2->{blind_eval_sha256} // '')) {
    return { ok => 0, next_stage => 'phase2a', reasons => ['blind-eval.json missing or modified'] };
  }
  if (!-f "$plans_dir/synthesis-body-locked.md" || sha256_file("$plans_dir/synthesis-body-locked.md") ne ($p2->{synthesis_body_locked_sha256} // '')) {
    return { ok => 0, next_stage => 'phase2a', reasons => ['synthesis-body-locked.md missing or modified'] };
  }
  if (!-f "$plans_dir/initial-design.md" || sha256_file("$plans_dir/initial-design.md") ne ($p2->{initial_design_sha256} // '')) {
    return { ok => 0, next_stage => 'phase2a', reasons => ['initial-design.md missing or modified'] };
  }
  if (($p2->{status} // '') ne 'completed' || !$equiv_prd{$p2->{prd_sha256} // ''}) {
    return { ok => 0, next_stage => 'phase2b', reasons => ['Phase 2b incomplete or stale'] };
  }
  if (!-f "$plans_dir/synthesis.md" || sha256_file("$plans_dir/synthesis.md") ne ($p2->{synthesis_sha256} // '')) {
    return { ok => 0, next_stage => 'phase2b', reasons => ['synthesis.md missing or hash mismatch'] };
  }
  if (!-f "$real_task/design.md" || -l "$real_task/design.md") {
    return { ok => 0, next_stage => 'phase2b', reasons => ['design.md missing'] };
  }

  # Verify contiguous design_revisions[] chain (preserves validity across takeover-run via prd_lineage + monotonic generation <= current!).
  my $live_design_sha = sha256_file("$real_task/design.md");
  my $revs = $st->{design_revisions} || [];
  my $chain_tip = $p2->{initial_design_sha256};
  my $prev_rev_gen = 0;
  for my $i (0 .. $#$revs) {
    my $rv = $revs->[$i];
    if (($rv->{parent_sha256} // '') ne $chain_tip) {
      return { ok => 0, next_stage => 'phase3', reasons => ["design_revisions[$i] chain broken: parent $rv->{parent_sha256} != $chain_tip"] };
    }
    if (defined $rv->{prd_lineage} && $rv->{prd_lineage} ne ($st->{prd_lineage} // '')) {
      return { ok => 0, next_stage => 'phase3', reasons => ["design_revisions[$i] prd_lineage mismatch"] };
    }
    my $rgen = $rv->{generation} // -1;
    if ($rgen < 1 || $rgen < $prev_rev_gen || $rgen > ($st->{generation} // 0)) {
      return { ok => 0, next_stage => 'phase3', reasons => ["design_revisions[$i] generation invalid ($rgen vs current $st->{generation})"] };
    }
    $prev_rev_gen = $rgen;
    $chain_tip = $rv->{new_sha256} // '';
  }
  if ($live_design_sha ne $chain_tip) {
    return { ok => 0, next_stage => 'phase3', reasons => ["uncontrolled out-of-band edit to design.md ($live_design_sha != chain tip $chain_tip)"] };
  }

  # Phase 3 & 4 review closure check.
  my $nr = _compute_next_review($real_task, $plans_dir, $repo, $trel, $st, $ignore_proj);
  if ($nr->{purpose} eq 'blocked-manual-redesign') {
    return { ok => 0, next_stage => 'blocked-manual-redesign', reasons => ['manual_redesign decision blocks Phase 5/6'] };
  }
  if ($nr->{purpose} eq 'disposition-required') {
    return { ok => 0, next_stage => 'phase4', reasons => [$nr->{reason}] };
  }
  if ($nr->{purpose} ne 'converged' && $nr->{purpose} ne 'user-decided') {
    return { ok => 0, next_stage => 'phase3', reasons => ["review not closed (next=$nr->{purpose})"] };
  }

  my $live_ledger_sha = (-f "$plans_dir/review-ledger.md") ? sha256_file("$plans_dir/review-ledger.md") : '';
  return {
    ok              => 1,
    live_prd        => $live_prd,
    live_design_sha => $live_design_sha,
    live_ledger_sha => $live_ledger_sha,
    live_baseline   => $nr->{baseline},
    review_closure  => $nr->{purpose},
  };
}

# Validate entire DAG from Phase 0 -> Phase 6. Returns hashref { ok, next_stage, reasons[], live_baseline }.
sub _evaluate_freshness {
  my ($real_task, $plans_dir, $repo, $trel, $st, $ignore_proj) = @_;
  my $up = _evaluate_upstream_freshness($real_task, $plans_dir, $repo, $trel, $st, $ignore_proj);
  return $up unless $up->{ok};

  my $live_prd        = $up->{live_prd};
  my $live_design_sha = $up->{live_design_sha};
  my $live_baseline   = $up->{live_baseline};
  my $live_ledger_sha = $up->{live_ledger_sha};

  # Phase 5
  my $p5 = $st->{phases}{'5'};
  if (ref $p5 ne 'HASH' || ($p5->{status} // '') ne 'completed') {
    return { ok => 0, next_stage => 'phase5', reasons => ['Phase 5 not completed'], live_baseline => $live_baseline };
  }
  if (($p5->{effective_prd_sha256} // '') ne $live_prd ||
      ($p5->{final_design_sha256}  // '') ne $live_design_sha ||
      ($p5->{review_baseline_sha256} // '') ne $live_baseline ||
      ($p5->{ledger_sha256}        // '') ne $live_ledger_sha) {
    return { ok => 0, next_stage => 'phase5', reasons => ['Phase 5 inputs stale relative to current PRD/design/baseline/ledger'], live_baseline => $live_baseline };
  }
  if (!-f "$real_task/implement.md" || sha256_file("$real_task/implement.md") ne ($p5->{implement_md_sha256} // '')) {
    return { ok => 0, next_stage => 'phase5', reasons => ['implement.md missing or hash mismatch'], live_baseline => $live_baseline };
  }
  for my $jf (['implement.jsonl', 'implement_jsonl_sha256'], ['check.jsonl', 'check_jsonl_sha256']) {
    my ($fname, $key) = @$jf;
    my $fp = _fs_join($real_task, $fname);
    my ($okj, $jmsg) = _validate_jsonl_non_seed($repo, $fp);
    return { ok => 0, next_stage => 'phase5', reasons => [$jmsg], live_baseline => $live_baseline } unless $okj;
    return { ok => 0, next_stage => 'phase5', reasons => ["$fname hash mismatch"], live_baseline => $live_baseline }
      unless sha256_file($fp) eq ($p5->{$key} // '');
  }
  my ($okc, $cmsg) = _validate_implement_codification($real_task, $st);
  return { ok => 0, next_stage => 'phase5', reasons => [$cmsg], live_baseline => $live_baseline } unless $okc;

  # Phase 6
  my $p6 = (ref($st->{phases}{'6'}) eq 'HASH') ? $st->{phases}{'6'} : {};
  my $p6_st = $p6->{state} // 'none';
  if ($p6_st eq 'activation_uncertain') {
    return { ok => 0, next_stage => 'activation_uncertain', reasons => ['Phase 6 in activation_uncertain — resolve via resolve-activation'], live_baseline => $live_baseline };
  }
  if ($p6_st eq 'activating') {
    return { ok => 0, next_stage => 'recover_activation', reasons => ['Phase 6 in activating — inspect/recover via recover-activation'], live_baseline => $live_baseline };
  }
  if ($p6_st eq 'none' || ($p6->{ready_baseline_sha256} // '') ne $live_baseline || ($p6->{implement_md_sha256} // '') ne ($p5->{implement_md_sha256} // '')) {
    return { ok => 1, next_stage => 'phase6', reasons => [], live_baseline => $live_baseline, phase6_state => $p6_st };
  }

  return { ok => 1, next_stage => ($p6_st eq 'activated' ? 'done' : 'phase6_ready'), reasons => [], live_baseline => $live_baseline, phase6_state => $p6_st };
}

sub cmd_check_freshness {
  my %opt = @_;
  die_err("check-freshness requires --task") unless defined $opt{task} && -d $opt{task};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my $st = load_state_or_undef($plans_dir);
    if ($st && ($st->{pipeline} // '') eq 't3-tri-plan') {
      recover_tx($real_task, $plans_dir);
      $st = load_state_or_undef($plans_dir);
    }
    my $repo = resolve_repo_root($opt{repo}, $real_task);
    my $trel = task_rel_path($repo, $real_task);
    my $res = _evaluate_freshness($real_task, $plans_dir, $repo, $trel, $st, _effective_ignore_project_config($st, \%opt));
    print "FRESH=" . ($res->{ok} ? 1 : 0) . "\n";
    print "NEXT_STAGE=$res->{next_stage}\n";
    print "PHASE6_STATE=$res->{phase6_state}\n" if defined $res->{phase6_state};
    print "REVIEW_BASELINE_SHA256=$res->{live_baseline}\n" if defined $res->{live_baseline};
    print "REASON=$_\n" for @{$res->{reasons} || []};
    exit($res->{ok} ? 0 : 1);
  });
}

sub cmd_commit_phase5 {
  my %opt = @_;
  die_err("commit-phase5 requires --task") unless defined $opt{task} && -d $opt{task};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my $act_guard_fh = _try_activation_lock($plans_dir);
    if (!$act_guard_fh) {
      print "ACTIVATION_IN_PROGRESS=1\nREASON=cannot commit Phase 5 while Phase 6 activation holds .activation.lock\n";
      exit 5;
    }
    my $run_err;
    eval {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

      my $p6_cur = (ref($st->{phases}{'6'}) eq 'HASH') ? ($st->{phases}{'6'}{state} // 'none') : 'none';
      die_err("cannot commit Phase 5 while Phase 6 is '$p6_cur' — resolve or recover activation first", 3)
        if $p6_cur eq 'activating' || $p6_cur eq 'activation_uncertain';

      # Verify ALL upstream Phases 0..4 freshness (PRD, candidates, Phase 2 lock, design_revisions[], review closure)!
      my $ign_proj = _effective_ignore_project_config($st, \%opt);
      my $up = _evaluate_upstream_freshness($real_task, $plans_dir, $repo, $trel, $st, $ign_proj);
      die_err("cannot commit Phase 5: upstream freshness failed ($up->{next_stage}: " . join('; ', @{$up->{reasons} || []}) . ")", 3)
        unless $up->{ok};

      # Run Trellis task.py validate <TASK> if task.py present (or --task-py override).
      my $task_py = $opt{task_py} || "$repo/.trellis/scripts/task.py";
      if (-f $task_py) {
        my ($rc, $out) = run_cmd_capture('python3', $task_py, 'validate', $real_task);
        die_err("task.py validate failed (rc=$rc): $out", 3) if $rc != 0;
      }

      # Independent hard checks (compensating for task_context.py skipping missing/seed-only JSONL!).
      for my $fname (qw(implement.jsonl check.jsonl)) {
        my ($okj, $jmsg) = _validate_jsonl_non_seed($repo, _fs_join($real_task, $fname));
        die_err("Phase 5 JSONL gate failed: $jmsg", 3) unless $okj;
      }
      my ($okc, $cmsg) = _validate_implement_codification($real_task, $st);
      die_err("Phase 5 codification gate failed: $cmsg", 3) unless $okc;

      my $imp_sha   = sha256_file("$real_task/implement.md");
      my $ij_sha    = sha256_file("$real_task/implement.jsonl");
      my $cj_sha    = sha256_file("$real_task/check.jsonl");
      my $des_sha   = $up->{live_design_sha};
      my $led_sha   = $up->{live_ledger_sha};

      # Idempotent retry when all Phase 5 inputs & outputs are unchanged: preserve existing Phase 6 record (including activated)!
      my $old_p5 = $st->{phases}{'5'};
      if (ref($old_p5) eq 'HASH' &&
          ($old_p5->{status}                 // '') eq 'completed' &&
          ($old_p5->{effective_prd_sha256}   // '') eq ($st->{effective_prd_sha256} // '') &&
          ($old_p5->{final_design_sha256}    // '') eq $des_sha &&
          ($old_p5->{review_closure_kind}    // '') eq ($up->{review_closure} // '') &&
          ($old_p5->{review_baseline_sha256} // '') eq ($up->{live_baseline} // '') &&
          ($old_p5->{ledger_sha256}          // '') eq $led_sha &&
          ($old_p5->{implement_md_sha256}    // '') eq $imp_sha &&
          ($old_p5->{implement_jsonl_sha256} // '') eq $ij_sha &&
          ($old_p5->{check_jsonl_sha256}     // '') eq $cj_sha) {
        print "PHASE5_COMMITTED=1\nPHASE5_IDEMPOTENT=1\nIMPLEMENT_MD_SHA256=$imp_sha\nREVIEW_BASELINE_SHA256=$up->{live_baseline}\n";
        print "PHASE6_STATE=$p6_cur\n" if $p6_cur ne 'none';
        return;
      }

      # If Phase 6 is already activated, refuse silently wiping it while task.json is still active (prevents re-running after_start)!
      if ($p6_cur eq 'activated') {
        my $tstat = 'unknown';
        if (-f "$real_task/task.json" && !-l "$real_task/task.json") {
          my $tj = eval { load_json_file("$real_task/task.json") };
          $tstat = $tj->{status} // 'unknown' if !$@ && ref $tj eq 'HASH';
        }
        die_err("cannot wipe activated Phase 6 via commit-phase5 while task.json.status is '$tstat' (must be planning)", 3)
          unless $tstat eq 'planning';
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-p5-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $st->{phases}{'5'} = {
        status                 => 'completed',
        effective_prd_sha256   => $st->{effective_prd_sha256},
        final_design_sha256    => $des_sha,
        review_closure_kind    => $up->{review_closure},
        review_baseline_sha256 => $up->{live_baseline},
        ledger_sha256          => $led_sha,
        implement_md_sha256    => $imp_sha,
        implement_jsonl_sha256 => $ij_sha,
        check_jsonl_sha256     => $cj_sha,
        completed_at           => now_iso(),
      };
      delete $st->{phases}{'6'};

      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "PHASE5_COMMITTED=1\nIMPLEMENT_MD_SHA256=$imp_sha\nREVIEW_BASELINE_SHA256=$up->{live_baseline}\n";
    };
    $run_err = $@;
    flock($act_guard_fh, LOCK_UN);
    close $act_guard_fh;
    die $run_err if $run_err;
  });
}

sub cmd_commit_phase6_ready {
  my %opt = @_;
  die_err("commit-phase6-ready requires --task") unless defined $opt{task} && -d $opt{task};
  with_task_lock($opt{task}, sub {
    my ($real_task, $plans_dir) = @_;
    my $act_guard_fh = _try_activation_lock($plans_dir);
    if (!$act_guard_fh) {
      print "ACTIVATION_IN_PROGRESS=1\nREASON=cannot mark Phase 6 ready while activation holds .activation.lock\n";
      exit 5;
    }
    my $run_err;
    eval {
      recover_tx($real_task, $plans_dir);
      my $st = load_state_or_undef($plans_dir) // die_err("missing planning-state.json");
      my $repo = resolve_repo_root($opt{repo}, $real_task);
      my $trel = task_rel_path($repo, $real_task);

      my $p6_cur = (ref($st->{phases}{'6'}) eq 'HASH') ? $st->{phases}{'6'} : {};
      my $p6_st  = $p6_cur->{state} // 'none';
      die_err("cannot overwrite Phase 6 state '$p6_st' — use recover-activation or resolve-activation", 3)
        if $p6_st eq 'activating' || $p6_st eq 'activation_uncertain';

      my $res = _evaluate_freshness($real_task, $plans_dir, $repo, $trel, $st, _effective_ignore_project_config($st, \%opt));
      die_err("cannot mark Phase 6 ready: freshness gate failed ($res->{next_stage}: " . join('; ', @{$res->{reasons}}) . ")", 3)
        unless $res->{ok};

      if ($p6_st eq 'activated' &&
          ($p6_cur->{ready_baseline_sha256} // '') eq ($res->{live_baseline} // '') &&
          ($p6_cur->{implement_md_sha256} // '') eq ($st->{phases}{'5'}{implement_md_sha256} // '')) {
        die_err("Phase 6 is already activated for this exact baseline — refusing to downgrade activated to ready", 3);
      }

      my $gen = $st->{generation};
      my $tx_id = "tx-p6-ready-" . time() . "-$$";
      $st->{last_tx_id} = $tx_id;
      $st->{authorization} = $opt{authorization} if defined $opt{authorization} && length $opt{authorization};
      $st->{phases}{'6'} = {
        state                 => 'ready',
        ready_at              => now_iso(),
        ready_baseline_sha256 => $res->{live_baseline},
        implement_md_sha256   => $st->{phases}{'5'}{implement_md_sha256},
        authorization_scope   => $st->{authorization},
      };

      execute_tx($real_task, $plans_dir, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "PHASE6_READY=1\nREVIEW_BASELINE_SHA256=$res->{live_baseline}\n";
    };
    $run_err = $@;
    flock($act_guard_fh, LOCK_UN);
    close $act_guard_fh;
    die $run_err if $run_err;
  });
}

# Query task.py current --json under the EXACT original trellis_context_key!
# Enforces Trellis JSON schema & exit-code convention:
#   - top-level object MUST contain 'current_task' (either null or object with non-empty string 'dir')
#   - MUST NOT contain error/failure keys (error/errors/traceback/exception/message/ok=false/status=error)
#   - rc=0 when current_task is present; rc=0|1 ONLY when current_task is null; any other rc or malformed JSON fails closed!
sub _probe_trellis_current {
  my ($repo_root, $task_py, $context_key) = @_;
  my %env_ov = (TRELLIS_CONTEXT_ID => ($context_key eq 'degraded-no-context' ? undef : $context_key));
  my ($rc, $out, $err) = run_cmd_capture_split($repo_root, \%env_ov, 'python3', $task_py, 'current', '--json');
  my $node = eval { decode_strict_typed($out) };
  if ($@ || ref($node) ne 'ARRAY' || $node->[0] ne 'obj') {
    return (0, undef, "task.py current --json failed (rc=$rc): $out $err");
  }
  my $oh = $node->[1];
  if (!exists $oh->{current_task}) {
    return (0, undef, "task.py current --json missing current_task key (rc=$rc): $out $err");
  }
  # Reject explicit error payloads even when current_task is null and rc == 0!
  for my $ek (qw(error errors traceback exception message)) {
    if (exists $oh->{$ek} && $oh->{$ek}[0] ne 'null') {
      if ($oh->{$ek}[0] ne 'str' || $oh->{$ek}[1] =~ /\S/) {
        return (0, undef, "task.py current --json reported '$ek' (rc=$rc): $out $err");
      }
    }
  }
  if (exists $oh->{ok} && $oh->{ok}[0] eq 'bool' && !$oh->{ok}[1]) {
    return (0, undef, "task.py current --json reported ok=false (rc=$rc): $out $err");
  }
  if (exists $oh->{status} && $oh->{status}[0] eq 'str' && lc($oh->{status}[1]) eq 'error') {
    return (0, undef, "task.py current --json reported status=error (rc=$rc): $out $err");
  }
  my $ctn = $oh->{current_task};
  if ($ctn->[0] eq 'null') {
    if ($rc != 0 && $rc != 1) {
      return (0, undef, "task.py current --json exited unexpectedly (rc=$rc): $out $err");
    }
  } elsif ($ctn->[0] eq 'obj') {
    if (!exists $ctn->[1]{dir} || $ctn->[1]{dir}[0] ne 'str' || $ctn->[1]{dir}[1] !~ /\S/) {
      return (0, undef, "task.py current --json returned malformed current_task (missing string dir): $out $err");
    }
    if ($rc != 0) {
      return (0, undef, "task.py current --json returned non-zero rc=$rc with non-null current_task: $out $err");
    }
  } else {
    return (0, undef, "task.py current --json returned malformed current_task type '$ctn->[0]': $out $err");
  }
  if (exists $oh->{stale} && $oh->{stale}[0] ne 'bool' && $oh->{stale}[0] ne 'null') {
    return (0, undef, "task.py current --json returned malformed stale field: $out $err");
  }
  return (1, unwrap_typed($node), '');
}

# SINGLE SHARED POSTCONDITION PREDICATE for ALL THREE activated paths
# (normal activate-task, crash recovery recover-activation, manual resolve-activation)!
sub _verify_activation_postconditions {
  my ($real_task, $plans_dir, $repo, $trel, $st, $task_py) = @_;
  my $p6 = $st->{phases}{'6'};
  return (0, 'Phase 6 state missing') unless ref $p6 eq 'HASH';
  my $act = $p6->{activation};
  return (0, 'missing activation intent metadata') unless ref $act eq 'HASH';

  # (a) activation_id & current generation match.
  return (0, "activation generation mismatch ($act->{generation} != $st->{generation})")
    unless ($act->{generation} // -1) == ($st->{generation} // 0);

  # (b) live freshness check (temporarily evaluate upstream stages 0..5 + live baseline!).
  my $p6_saved = $st->{phases}{'6'};
  $st->{phases}{'6'} = { state => 'ready', ready_baseline_sha256 => $p6_saved->{ready_baseline_sha256}, implement_md_sha256 => $p6_saved->{implement_md_sha256} };
  my $fresh = _evaluate_freshness($real_task, $plans_dir, $repo, $trel, $st);
  $st->{phases}{'6'} = $p6_saved;
  return (0, "freshness check failed: " . join('; ', @{$fresh->{reasons}})) unless $fresh->{ok};
  return (0, "live baseline drifted since ready ($fresh->{live_baseline} != $p6->{ready_baseline_sha256})")
    unless ($fresh->{live_baseline} // '') eq ($p6->{ready_baseline_sha256} // '');

  # (c) task.json.status == 'in_progress'.
  my $tj_path = "$real_task/task.json";
  return (0, "missing task.json") unless -f $tj_path && !-l $tj_path;
  my $tj = eval { load_json_file($tj_path) };
  return (0, "invalid task.json: $@") if $@ || ref $tj ne 'HASH';
  return (0, "task.json.status is '" . ($tj->{status} // 'unset') . "', expected 'in_progress'")
    unless ($tj->{status} // '') eq 'in_progress';

  # (d) Session pointer / degraded-mode invariant!
  my $ctx_key = $act->{trellis_context_key} // '';
  if ($ctx_key eq 'degraded-no-context') {
    # Recorded degraded mode: verify TRELLIS_CONTEXT_ID is absent or explicitly accepted degraded mode.
    return (1, 'ok (verified degraded mode + in_progress)');
  } else {
    my ($okp, $cur, $perr) = _probe_trellis_current($repo, $task_py, $ctx_key);
    return (0, "cannot verify active task pointer for session '$ctx_key': $perr") unless $okp;
    my $ct = $cur->{current_task};
    return (0, "active task pointer is empty/cleared for session '$ctx_key'")
      unless ref $ct eq 'HASH' && length($ct->{dir} // '');
    my $want_dir = $act->{expected_task_dir} // $trel;
    return (0, "active task pointer points to '$ct->{dir}', expected '$want_dir'")
      unless $ct->{dir} eq $want_dir;
    return (0, "active task pointer is stale") if $cur->{stale};
    return (1, "ok (session pointer verified: $ct->{dir}, source=" . ($cur->{source} // 'unknown') . ")");
  }
}

sub _prepare_phase6_lock {
  my ($task_arg, $create_plans_dir) = @_;
  die_err("EXTERNAL_CONFLICT: symlink forbidden at task directory " . _display_path($task_arg), 2)
    if -l $task_arg;
  my $real_task = abs_path($task_arg) // die_err("invalid --task");
  die_err("invalid --task: not a directory") unless -d $real_task;
  my $plans_dir = "$real_task/research/plans";
  my $lock_path = "$plans_dir/.activation.lock";
  eval { ensure_no_symlink_components($real_task, $lock_path); };
  die_err(_display_path($@), 2) if $@;
  if ($create_plans_dir && !-d $plans_dir) {
    make_path($plans_dir);
    eval { ensure_no_symlink_components($real_task, $lock_path); };
    die_err(_display_path($@), 2) if $@;
  }
  return ($real_task, $plans_dir);
}

sub _try_activation_lock {
  my ($plans_dir, $real_task) = @_;
  my $lp = "$plans_dir/.activation.lock";
  if (defined $real_task && length $real_task) {
    eval { ensure_no_symlink_components($real_task, $lp); };
    die_err(_display_path($@), 2) if $@;
  }
  my $o_nofollow = eval { Fcntl::O_NOFOLLOW() } || 0;
  die_err("EXTERNAL_CONFLICT: symlink or non-regular lockfile at " . _display_path($lp), 2)
    if -l $lp || (-e $lp && !-f $lp);
  sysopen(my $fh, $lp, O_RDWR | O_CREAT | O_NONBLOCK | $o_nofollow, 0644)
    or die_err("EXTERNAL_CONFLICT: cannot safely open lockfile " . _display_path($lp) . ": $!", 2);
  if (!-f $fh) {
    close $fh;
    die_err("EXTERNAL_CONFLICT: non-regular file at lockfile " . _display_path($lp), 2);
  }
  if (!flock($fh, LOCK_EX | LOCK_NB)) {
    close $fh;
    return undef;
  }
  return $fh;
}

sub cmd_activate_task {
  my %opt = @_;
  die_err("activate-task requires --task, --owner, --authorization")
    unless defined $opt{task} && defined $opt{owner} && defined $opt{authorization};

  my ($real_task, $plans_dir) = _prepare_phase6_lock($opt{task}, 1);

  # 1. Acquire process-lifetime non-blocking activation lock FIRST!
  my $act_lock_fh = _try_activation_lock($plans_dir, $real_task);
  if (!$act_lock_fh) {
    print "ACTIVATION_IN_PROGRESS=1\nREASON=another starter currently holds .activation.lock\n";
    exit 5;
  }

  my $repo    = resolve_repo_root($opt{repo}, $real_task);
  my $trel    = task_rel_path($repo, $real_task);
  my $task_py = $opt{task_py} || "$repo/.trellis/scripts/task.py";
  die_err("missing task.py at $task_py") unless -f $task_py;

  my ($act_id, $act_gen, $ctx_key, $hstat, $hcmds, $hdetail);

  # 2. Under task lock: verify freshness + ready + CAS ready -> activating BEFORE spawning task.py start!
  with_task_lock($real_task, sub {
    my (undef, $pd) = @_;
    recover_tx($real_task, $pd);
    my $st = load_state_or_undef($pd) // die_err("missing planning-state.json");
    my $p6 = $st->{phases}{'6'};
    die_err("Phase 6 must be in 'ready' state before activate-task (got '" . (ref $p6 eq 'HASH' ? ($p6->{state} // 'none') : 'none') . "')", 3)
      unless ref $p6 eq 'HASH' && ($p6->{state} // '') eq 'ready';

    my $fresh = _evaluate_freshness($real_task, $pd, $repo, $trel, $st);
    die_err("freshness failed before activation: " . join('; ', @{$fresh->{reasons}}), 3) unless $fresh->{ok};

    ($hstat, $hcmds, $hdetail) = probe_after_start_hooks($repo, $real_task);
    $ctx_key = (defined $ENV{TRELLIS_CONTEXT_ID} && length $ENV{TRELLIS_CONTEXT_ID})
      ? $ENV{TRELLIS_CONTEXT_ID}
      : 'degraded-no-context';
    $act_id  = "act-" . time() . "-$$-" . int(rand(10000));
    $act_gen = $st->{generation};

    my $pre_status = 'unknown';
    if (-f "$real_task/task.json" && !-l "$real_task/task.json") {
      my $tj = eval { load_json_file("$real_task/task.json") };
      $pre_status = $tj->{status} // 'unknown' if !$@ && ref $tj eq 'HASH';
    }
    die_err("cannot activate task: task.json.status is '$pre_status' (expected 'planning' — refusing duplicate start/after_start)", 3)
      unless $pre_status eq 'planning';

    my $gen = $act_gen;
    my $tx_id = "tx-act-begin-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    $p6->{state} = 'activating';
    $p6->{activation} = {
      activation_id        => $act_id,
      generation           => $gen,
      authorization_scope  => $opt{authorization},
      expected_task_dir    => $trel,
      trellis_context_key  => $ctx_key,
      started_by_thread_id => $opt{owner},
      pre_task_json_status => $pre_status,
      has_after_start_hooks => $hstat, # 'true' | 'false' | 'unknown'
      after_start_commands => $hcmds,
      hooks_probe_detail   => $hdetail,
      started_at           => now_iso(),
    };

    execute_tx($real_task, $pd, {
      tx_id               => $tx_id,
      expected_generation => $gen,
      next_generation     => $gen,
      writes              => [
        { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
      ],
    });
  });

  # Test hook: simulate crash while still holding .activation.lock or right after task.py start!
  if (defined $ENV{T3_TRI_PLAN_TEST_HOLD_ACT_LOCK_SECS} && $ENV{T3_TRI_PLAN_TEST_HOLD_ACT_LOCK_SECS} > 0) {
    sleep($ENV{T3_TRI_PLAN_TEST_HOLD_ACT_LOCK_SECS});
  }

  # 3. Spawn task.py start <TASK> while inheriting .activation.lock FD into the child process
  #    so even if this Perl wrapper dies mid-start, .activation.lock stays held until task.py exits!
  my ($rc, $out, $err) = run_cmd_capture_split_opts(
    { cwd => $repo, inherit_fh => $act_lock_fh },
    'python3', $task_py, 'start', $real_task
  );
  if (defined $ENV{T3_TRI_PLAN_TEST_CRASH_AFTER_START} && $ENV{T3_TRI_PLAN_TEST_CRASH_AFTER_START}) {
    flock($act_lock_fh, LOCK_UN);
    close $act_lock_fh;
    die_err("SIMULATED_CRASH_AFTER_START", 9);
  }

  my $combined = "$out\n$err";
  my $stripped = $combined;
  $stripped =~ s/\e\[[0-9;]*m//g;
  my $hook_warn = ($stripped =~ /\[WARN\]\s+Hook\s+(?:failed|timed out|error)\b/i) ? 1 : 0;

  # 4. Under task lock, verify CAS + shared verify_activation_postconditions and commit activated OR activation_uncertain!
  my $final_rc = 0;
  with_task_lock($real_task, sub {
    my (undef, $pd) = @_;
    recover_tx($real_task, $pd);
    my $st = load_state_or_undef($pd) // die_err("missing planning-state.json");
    my $p6 = $st->{phases}{'6'};

    if (($st->{generation} // -1) != $act_gen ||
        ref($p6) ne 'HASH' ||
        ($p6->{state} // '') ne 'activating' ||
        ref($p6->{activation}) ne 'HASH' ||
        ($p6->{activation}{activation_id} // '') ne $act_id) {
      die_err("activation CAS failed: state mutated during task.py start (expected gen=$act_gen act_id=$act_id)", 4);
    }

    my ($post_ok, $post_msg) = _verify_activation_postconditions($real_task, $pd, $repo, $trel, $st, $task_py);
    my $gen = $st->{generation};
    my $tx_id = "tx-act-end-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    $p6->{activation}{exit_code}         = $rc;
    $p6->{activation}{hook_warning_seen} = $hook_warn ? JSON::PP::true : JSON::PP::false;
    $p6->{activation}{output_log}        = $stripped;
    $p6->{activation}{postcheck_note}    = $post_msg;

    if ($rc == 0 && !$hook_warn && $post_ok) {
      $p6->{state}        = 'activated';
      $p6->{activated_at} = now_iso();
      execute_tx($real_task, $pd, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "ACTIVATED=1\nACTIVATION_ID=$act_id\nPOSTCHECK=$post_msg\n";
    } else {
      $p6->{state} = 'activation_uncertain';
      my @why;
      push @why, "task.py start exited $rc" if $rc != 0;
      push @why, "after_start hook warning detected in output" if $hook_warn;
      push @why, "postcondition failed: $post_msg" if !$post_ok;
      $p6->{activation}{uncertain_reason} = join('; ', @why);
      execute_tx($real_task, $pd, {
        tx_id               => $tx_id,
        expected_generation => $gen,
        next_generation     => $gen,
        writes              => [
          { dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 },
        ],
      });
      print "ACTIVATED=0\nPHASE6_STATE=activation_uncertain\nREASON=$p6->{activation}{uncertain_reason}\n";
      $final_rc = 3;
    }
  });

  flock($act_lock_fh, LOCK_UN);
  close $act_lock_fh;
  exit $final_rc;
}

sub cmd_recover_activation {
  my %opt = @_;
  die_err("recover-activation requires --task") unless defined $opt{task} && -d $opt{task};

  my ($real_task, $plans_dir) = _prepare_phase6_lock($opt{task}, 0);
  my $act_lock_fh = _try_activation_lock($plans_dir, $real_task);
  if (!$act_lock_fh) {
    print "ACTIVATION_IN_PROGRESS=1\nREASON=original starter still holds .activation.lock\n";
    exit 5;
  }

  my $repo    = resolve_repo_root($opt{repo}, $real_task);
  my $trel    = task_rel_path($repo, $real_task);
  my $task_py = $opt{task_py} || "$repo/.trellis/scripts/task.py";

  my $exit_rc = 0;
  with_task_lock($real_task, sub {
    my (undef, $pd) = @_;
    recover_tx($real_task, $pd);
    my $st = load_state_or_undef($pd) // die_err("missing planning-state.json");
    my $p6 = $st->{phases}{'6'};
    if (ref $p6 ne 'HASH' || (($p6->{state} // '') ne 'activating' && ($p6->{state} // '') ne 'activation_uncertain')) {
      print "RECOVERY_NEEDED=0\nPHASE6_STATE=" . (ref $p6 eq 'HASH' ? ($p6->{state} // 'none') : 'none') . "\n";
      return;
    }
    if ($p6->{state} eq 'activation_uncertain') {
      print "PHASE6_STATE=activation_uncertain\nREASON=" . ($p6->{activation}{uncertain_reason} // 'requires resolve-activation') . "\n";
      $exit_rc = 3;
      return;
    }

    my $act = $p6->{activation} || {};
    my $tj  = (-f "$real_task/task.json") ? eval { load_json_file("$real_task/task.json") } : undef;
    my $tstat = (ref $tj eq 'HASH') ? ($tj->{status} // 'unknown') : 'unknown';
    my $ctx_key = $act->{trellis_context_key} // 'degraded-no-context';
    my $pointer_set = 0;
    my $probe_err   = '';
    if ($ctx_key ne 'degraded-no-context') {
      if (!-f $task_py) {
        $probe_err = "missing task.py at $task_py";
      } else {
        my ($okp, $cur, $perr) = _probe_trellis_current($repo, $task_py, $ctx_key);
        if (!$okp) {
          $probe_err = $perr || 'task.py current --json failed';
        } elsif (ref($cur->{current_task}) eq 'HASH' && ($cur->{current_task}{dir} // '') eq ($act->{expected_task_dir} // $trel)) {
          $pointer_set = 1;
        }
      }
    }

    my $gen = $st->{generation};
    my $tx_id = "tx-rec-act-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;

    # Fail closed if pointer probe failed!
    if (length $probe_err) {
      $p6->{state} = 'activation_uncertain';
      $p6->{activation}{uncertain_reason} = "cannot verify session task pointer during recovery: $probe_err";
      execute_tx($real_task, $pd, {
        tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
        writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
      });
      print "RECOVERY_CASE=probe_failed\nPHASE6_STATE=activation_uncertain\nREASON=$p6->{activation}{uncertain_reason}\n";
      $exit_rc = 3;
      return;
    }

    # Case 1: planning & pointer NOT set -> unstarted (safe to cancel-activating or retry).
    if ($tstat eq 'planning' && !$pointer_set) {
      print "RECOVERY_CASE=unstarted\nPHASE6_STATE=activating\nACTION=safe to run cancel-activating then re-run activate-task\n";
      return;
    }
    # Case 2: planning & pointer ALREADY set -> crashed between set_active_task and write_json(task.json)!
    if ($tstat eq 'planning' && $pointer_set) {
      $p6->{state} = 'activation_uncertain';
      $p6->{activation}{uncertain_reason} = 'partial activation: session pointer set to task while task.json is still planning';
      execute_tx($real_task, $pd, {
        tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
        writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
      });
      print "RECOVERY_CASE=partial_pointer_only\nPHASE6_STATE=activation_uncertain\nREASON=$p6->{activation}{uncertain_reason}\n";
      $exit_rc = 3;
      return;
    }
    # Case 3/4: in_progress -> check hooks AND shared verify_activation_postconditions!
    my $hstat = $act->{has_after_start_hooks} // 'unknown';
    my ($post_ok, $post_msg) = _verify_activation_postconditions($real_task, $pd, $repo, $trel, $st, $task_py);
    if ($tstat eq 'in_progress' && $hstat eq 'false' && $post_ok) {
      $p6->{state}        = 'activated';
      $p6->{activated_at} = now_iso();
      $p6->{activation}{postcheck_note} = "recovered: $post_msg";
      execute_tx($real_task, $pd, {
        tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
        writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
      });
      print "RECOVERY_CASE=confirmed_no_hooks\nPHASE6_STATE=activated\nPOSTCHECK=$post_msg\n";
      return;
    }

    # Otherwise -> activation_uncertain (hooks true/unknown or postcondition failed)!
    my @why;
    push @why, "after_start hooks state is '$hstat' (outcome unknown after crash)" if $hstat ne 'false';
    push @why, "postcondition failed: $post_msg" if !$post_ok;
    $p6->{state} = 'activation_uncertain';
    $p6->{activation}{uncertain_reason} = join('; ', @why);
    execute_tx($real_task, $pd, {
      tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
      writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
    });
    print "RECOVERY_CASE=uncertain\nPHASE6_STATE=activation_uncertain\nREASON=$p6->{activation}{uncertain_reason}\n";
    $exit_rc = 3;
  });

  flock($act_lock_fh, LOCK_UN);
  close $act_lock_fh;
  exit $exit_rc;
}

sub cmd_cancel_activating {
  my %opt = @_;
  die_err("cancel-activating requires --task") unless defined $opt{task} && -d $opt{task};
  my ($real_task, $plans_dir) = _prepare_phase6_lock($opt{task}, 0);
  my $act_lock_fh = _try_activation_lock($plans_dir, $real_task);
  if (!$act_lock_fh) {
    print "ACTIVATION_IN_PROGRESS=1\nREASON=starter holds .activation.lock\n";
    exit 5;
  }
  my $repo = resolve_repo_root($opt{repo}, $real_task);
  my $trel = task_rel_path($repo, $real_task);
  my $task_py = $opt{task_py} || "$repo/.trellis/scripts/task.py";

  with_task_lock($real_task, sub {
    my (undef, $pd) = @_;
    recover_tx($real_task, $pd);
    my $st = load_state_or_undef($pd) // die_err("missing planning-state.json");
    my $p6 = $st->{phases}{'6'};
    die_err("cancel-activating requires state=activating") unless ref $p6 eq 'HASH' && ($p6->{state} // '') eq 'activating';
    my $tj = load_json_file("$real_task/task.json");
    die_err("cannot cancel-activating: task.json.status is '$tj->{status}' (must be planning)", 3)
      unless ($tj->{status} // '') eq 'planning';
    my $ctx_key = $p6->{activation}{trellis_context_key} // 'degraded-no-context';
    if ($ctx_key ne 'degraded-no-context') {
      die_err("cannot cancel-activating: missing task.py at $task_py", 3) unless -f $task_py;
      my ($okp, $cur, $perr) = _probe_trellis_current($repo, $task_py, $ctx_key);
      die_err("cannot cancel-activating: failed to verify session pointer: $perr", 3) unless $okp;
      if (ref($cur->{current_task}) eq 'HASH' && ($cur->{current_task}{dir} // '') eq ($p6->{activation}{expected_task_dir} // $trel)) {
        die_err("cannot cancel-activating: session pointer already points to task", 3);
      }
    }
    $p6->{state} = 'ready';
    delete $p6->{activation};
    my $gen = $st->{generation};
    my $tx_id = "tx-cact-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;
    execute_tx($real_task, $pd, {
      tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
      writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
    });
    print "ACTIVATING_CANCELLED=1\nPHASE6_STATE=ready\n";
  });
  flock($act_lock_fh, LOCK_UN);
  close $act_lock_fh;
}

sub cmd_resolve_activation {
  my %opt = @_;
  die_err("resolve-activation requires --task, --resolution, --evidence")
    unless defined $opt{task} && defined $opt{resolution} && defined $opt{evidence} && $opt{evidence} =~ /\S/;
  die_err("invalid --resolution '$opt{resolution}'")
    unless $opt{resolution} eq 'confirmed_activated' || $opt{resolution} eq 'reset_to_ready';

  my ($real_task, $plans_dir) = _prepare_phase6_lock($opt{task}, 0);
  my $act_lock_fh = _try_activation_lock($plans_dir, $real_task);
  if (!$act_lock_fh) {
    print "ACTIVATION_IN_PROGRESS=1\nREASON=starter holds .activation.lock\n";
    exit 5;
  }
  my $repo = resolve_repo_root($opt{repo}, $real_task);
  my $trel = task_rel_path($repo, $real_task);
  my $task_py = $opt{task_py} || "$repo/.trellis/scripts/task.py";

  with_task_lock($real_task, sub {
    my (undef, $pd) = @_;
    recover_tx($real_task, $pd);
    my $st = load_state_or_undef($pd) // die_err("missing planning-state.json");
    my $p6 = $st->{phases}{'6'};
    die_err("resolve-activation requires Phase 6 in activation_uncertain", 3)
      unless ref $p6 eq 'HASH' && ($p6->{state} // '') eq 'activation_uncertain';

    my $gen = $st->{generation};
    my $tx_id = "tx-resact-" . time() . "-$$";
    $st->{last_tx_id} = $tx_id;

    if ($opt{resolution} eq 'confirmed_activated') {
      # MUST PASS THE EXACT SAME SHARED POSTCONDITION PREDICATE!
      my ($post_ok, $post_msg) = _verify_activation_postconditions($real_task, $pd, $repo, $trel, $st, $task_py);
      die_err("cannot resolve as confirmed_activated: $post_msg", 3) unless $post_ok;
      $p6->{state}                        = 'activated';
      $p6->{activated_at}                 = now_iso();
      $p6->{activation}{manual_resolution} = { resolution => 'confirmed_activated', evidence => $opt{evidence}, at => now_iso(), postcheck => $post_msg };
      execute_tx($real_task, $pd, {
        tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
        writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
      });
      print "ACTIVATION_RESOLVED=1\nPHASE6_STATE=activated\nPOSTCHECK=$post_msg\n";
    } else {
      my $tj = load_json_file("$real_task/task.json");
      die_err("cannot reset_to_ready while task.json.status is '$tj->{status}' (must be planning)", 3)
        unless ($tj->{status} // '') eq 'planning';
      my $ctx_key = $p6->{activation}{trellis_context_key} // 'degraded-no-context';
      if ($ctx_key ne 'degraded-no-context') {
        die_err("cannot reset_to_ready: missing task.py at $task_py", 3) unless -f $task_py;
        my ($okp, $cur, $perr) = _probe_trellis_current($repo, $task_py, $ctx_key);
        die_err("cannot reset_to_ready: failed to verify session pointer: $perr", 3) unless $okp;
        if (ref($cur->{current_task}) eq 'HASH' && ($cur->{current_task}{dir} // '') eq ($p6->{activation}{expected_task_dir} // $trel)) {
          die_err("cannot reset_to_ready while session pointer still points to task", 3);
        }
      }
      $p6->{state} = 'ready';
      $p6->{last_reset_evidence} = { evidence => $opt{evidence}, at => now_iso() };
      delete $p6->{activation};
      execute_tx($real_task, $pd, {
        tx_id => $tx_id, expected_generation => $gen, next_generation => $gen,
        writes => [{ dst => 'research/plans/planning-state.json', bytes => encode_canonical($st), is_state_file => 1 }],
      });
      print "ACTIVATION_RESOLVED=1\nPHASE6_STATE=ready\n";
    }
  });
  flock($act_lock_fh, LOCK_UN);
  close $act_lock_fh;
}

# =============================================================================
# CLI Dispatcher
# =============================================================================

my $cmd = shift @ARGV // die_err("missing subcommand");
my %opt;
my @pos;
while (@ARGV) {
  my $a = shift @ARGV;
  if    ($a eq '--task')                         { $opt{task}                       = shift @ARGV; }
  elsif ($a eq '--repo')                         { $opt{repo}                       = shift @ARGV; }
  elsif ($a eq '--file')                         { $opt{file}                       = shift @ARGV; }
  elsif ($a eq '--capabilities')                 { $opt{caps}                       = shift @ARGV; }
  elsif ($a eq '--override-designers')           { $opt{ov_designers}               = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--override-judge')               { $opt{ov_judge}                   = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--override-model')               { $opt{ov_model}                   = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--override-effort')              { $opt{ov_effort}                  = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--override-council')             { $opt{ov_council}                 = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--single')                       { $opt{single}                     = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--allow-non-tri')                { $opt{allow_non_tri}              = 1; }
  elsif ($a eq '--ignore-project-config')        { $opt{ignore_project_config}      = 1; }
  elsif ($a eq '--use-project-config')           { $opt{use_project_config}         = 1; }
  elsif ($a eq '--confirm')                      { $opt{confirm}                    = 1; }
  elsif ($a eq '--change-kind')                  { $opt{change_kind}                = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--reason')                       { $opt{reason}                     = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--evidence')                     { $opt{evidence}                   = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--authorization')                { $opt{authorization}              = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--slots-json')                   { $opt{slots_json}                 = shift @ARGV; }
  elsif ($a eq '--target-json')                  { $opt{target_json}                = shift @ARGV; }
  elsif ($a eq '--owner')                        { $opt{owner}                      = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--owner-gen')                    { $opt{owner_gen}                  = shift @ARGV; }
  elsif ($a eq '--new-owner')                    { $opt{new_owner}                  = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--degraded-allowed')             { $opt{degraded_allowed}           = 1; }
  elsif ($a eq '--degraded-approval')            { $opt{degraded_approval}          = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--purpose')                      { $opt{purpose}                    = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--mode')                         { $opt{mode}                       = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--run-id')                       { $opt{run_id}                     = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--generation')                   { $opt{generation}                 = shift @ARGV; }
  elsif ($a eq '--slot')                         { $opt{slot}                       = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--attempt')                      { $opt{attempt}                    = shift @ARGV; }
  elsif ($a eq '--task-id')                      { $opt{task_id}                    = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--child-thread-id')              { $opt{child_thread_id}            = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--child-run-id')                 { $opt{child_run_id}               = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--state')                        { $opt{state}                      = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--reconciled-child-thread-id')   { $opt{reconciled_child_thread_id} = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--input')                        { $opt{input}                      = shift @ARGV; }
  elsif ($a eq '--merged-input')                 { $opt{merged_input}               = shift @ARGV; }
  elsif ($a eq '--dismissed-findings')           { $opt{dismissed_findings}         = shift @ARGV; }
  elsif ($a eq '--inherit-wording-confirmation') { $opt{inherit_wording_confirmation} = 1; }
  elsif ($a eq '--assemble')                     { $opt{assemble}                   = 1; }
  elsif ($a eq '--dispositions-json')            { $opt{dispositions_json}          = shift @ARGV; }
  elsif ($a eq '--step-back-assessment-done')    { $opt{step_back_assessment_done}  = 1; }
  elsif ($a eq '--mark-scope-fork')              { $opt{mark_scope_fork}            = 1; }
  elsif ($a eq '--clear-scope-fork')             { $opt{clear_scope_fork}           = 1; }
  elsif ($a eq '--choice')                       { $opt{choice}                     = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a eq '--task-py')                      { $opt{task_py}                    = shift @ARGV; }
  elsif ($a eq '--resolution')                   { $opt{resolution}                 = _decode_cli_text(shift @ARGV, $a); }
  elsif ($a =~ /^--/)                            { die_err("unknown option: $a"); }
  else                                           { push @pos, _decode_cli_text($a, 'arg'); }
}

if    ($cmd eq 'config-set')                  { cmd_config_set($opt{file}); }
elsif ($cmd eq 'config-authorize-provider')   { cmd_config_authorize_provider($pos[0]); }
elsif ($cmd eq 'config-show')                 { cmd_config_show(%opt); }
elsif ($cmd eq 'preflight-trellis')           { cmd_preflight_trellis($opt{repo}); }
elsif ($cmd eq 'inspect-task')                { cmd_inspect_task($opt{task}); }
elsif ($cmd eq 'migrate-legacy')              { cmd_migrate_legacy($opt{task}, $opt{confirm}); }
elsif ($cmd eq 'commit-phase0')               { cmd_commit_phase0(%opt); }
elsif ($cmd eq 'ack-wording-closure')         { cmd_ack_wording_closure(%opt); }
elsif ($cmd eq 'prepare-design')              { cmd_prepare_design(%opt); }
elsif ($cmd eq 'prepare-judge')               { cmd_prepare_judge(%opt); }
elsif ($cmd eq 'prepare-review')              { cmd_prepare_review(%opt); }
elsif ($cmd eq 'claim-slot')                  { cmd_claim_slot(%opt); }
elsif ($cmd eq 'record-dispatch')             { cmd_record_dispatch(%opt); }
elsif ($cmd eq 'update-slot')                 { cmd_update_slot(%opt); }
elsif ($cmd eq 'record-result')               { _ingest_result_common(0, %opt); }
elsif ($cmd eq 'reconcile-and-record-result') { _ingest_result_common(1, %opt); }
elsif ($cmd eq 'reconcile-terminal-error')    { cmd_reconcile_terminal_error(%opt); }
elsif ($cmd eq 'reconcile-bind')              { cmd_reconcile_bind(%opt); }
elsif ($cmd eq 'reconcile-abandon')           { cmd_reconcile_abandon(%opt); }
elsif ($cmd eq 'takeover-run')                { cmd_takeover_run(%opt); }
elsif ($cmd eq 'abort-run')                   { cmd_abort_run(%opt); }
elsif ($cmd eq 'run-summary')                 { cmd_run_summary($opt{task}); }
elsif ($cmd eq 'commit-phase1')               { cmd_commit_phase1(%opt); }
elsif ($cmd eq 'commit-phase2a')              { cmd_commit_phase2a(%opt); }
elsif ($cmd eq 'reveal-blind-map')            { cmd_reveal_blind_map($opt{task}); }
elsif ($cmd eq 'commit-phase2b')              { cmd_commit_phase2b(%opt); }
elsif ($cmd eq 'next-review')                 { cmd_next_review(%opt); }
elsif ($cmd eq 'finish-review-round')         { cmd_finish_review_round(%opt); }
elsif ($cmd eq 'commit-phase4-revision')      { cmd_commit_phase4_revision(%opt); }
elsif ($cmd eq 'authorize-step-back')         { cmd_authorize_step_back(%opt); }
elsif ($cmd eq 'record-user-decision')        { cmd_record_user_decision(%opt); }
elsif ($cmd eq 'clear-manual-redesign')       { cmd_clear_manual_redesign(%opt); }
elsif ($cmd eq 'commit-phase5')               { cmd_commit_phase5(%opt); }
elsif ($cmd eq 'check-freshness')             { cmd_check_freshness(%opt); }
elsif ($cmd eq 'commit-phase6-ready')         { cmd_commit_phase6_ready(%opt); }
elsif ($cmd eq 'activate-task')               { cmd_activate_task(%opt); }
elsif ($cmd eq 'recover-activation')          { cmd_recover_activation(%opt); }
elsif ($cmd eq 'cancel-activating')           { cmd_cancel_activating(%opt); }
elsif ($cmd eq 'resolve-activation')          { cmd_resolve_activation(%opt); }
else { die_err("unknown subcommand '$cmd'"); }
