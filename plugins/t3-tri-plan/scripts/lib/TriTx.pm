package TriTx;

use strict;
use warnings;
use utf8;
use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Fcntl qw(:flock O_WRONLY O_CREAT O_EXCL);
use File::Basename qw(dirname);
use File::Copy qw(copy);
use File::Find qw(find);
use File::Path qw(make_path remove_tree);
use File::Spec ();
use StrictJson qw(load_json_file encode_canonical encode_compact);
use Exporter 'import';

our @EXPORT_OK = qw(
  sha256_file
  sha256_bytes
  dir_tree_manifest
  with_task_lock
  check_stale_readonly
  recover_tx
  execute_tx
  compute_worktree_fp
  compare_worktree_fp
  scan_repo_rules
  compute_non_prd_baseline
  compute_review_baseline
  is_symlink_path
  ensure_no_symlink_components
  write_atomic_bytes
  read_raw_file
);

sub sha256_bytes {
  my ($bytes) = @_;
  return sha256_hex(defined $bytes ? $bytes : '');
}

sub read_raw_file {
  my ($path) = @_;
  open(my $fh, '<:raw', $path) or die "cannot read $path: $!\n";
  local $/;
  my $raw = <$fh>;
  close $fh;
  return defined $raw ? $raw : '';
}

sub sha256_file {
  my ($path) = @_;
  die "EXTERNAL_CONFLICT: symlink forbidden at $path\n" if -l $path;
  die "cannot hash non-file $path\n" unless -f $path;
  return sha256_hex(read_raw_file($path));
}

sub write_atomic_bytes {
  my ($dst, $bytes, $mode) = @_;
  die "EXTERNAL_CONFLICT: refusing to overwrite symlink at $dst\n" if -l $dst;
  my $parent = dirname($dst);
  make_path($parent) unless -d $parent;
  my $perm = defined $mode ? $mode : 0644;
  my ($tmp, $fh);
  for (1 .. 16) {
    $tmp = "$dst.tmp.$$." . int(rand(10000000));
    last if sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, $perm);
    $fh = undef;
  }
  die "cannot create exclusive temp file for $dst: $!\n" unless $fh;
  binmode($fh, ':raw');
  chmod($perm, $tmp) if defined $mode; # explicit chmod BEFORE rename (immune to umask)
  print $fh $bytes or do { close $fh; unlink $tmp; die "cannot write $tmp: $!\n"; };
  close $fh or do { unlink $tmp; die "cannot close $tmp: $!\n"; };
  rename($tmp, $dst) or do {
    unlink $tmp;
    die "cannot rename $tmp -> $dst: $!\n";
  };
}

sub is_symlink_path {
  my ($p) = @_;
  return (-l $p) ? 1 : 0;
}

# Validate a relative manifest path stays strictly within its root (no absolute paths, no '..' segments, no null bytes).
sub _assert_clean_rel_path {
  my ($rel, $ctx) = @_;
  die "EXTERNAL_CONFLICT: invalid empty path in $ctx\n" unless defined $rel && length $rel;
  die "EXTERNAL_CONFLICT: NUL byte in path ($ctx)\n" if index($rel, "\0") >= 0;
  die "EXTERNAL_CONFLICT: absolute path forbidden in $ctx: '$rel'\n" if $rel =~ m{\A/};
  for my $seg (split(m{/}, $rel, -1)) {
    die "EXTERNAL_CONFLICT: parent traversal '..' forbidden in $ctx: '$rel'\n" if $seg eq '..';
    die "EXTERNAL_CONFLICT: empty/dot segment forbidden in $ctx: '$rel'\n" if $seg eq '' || $seg eq '.';
  }
}

# Check path stays strictly inside $root and no existing component is a symlink.
sub ensure_no_symlink_components {
  my ($root, $target) = @_;
  my $r = abs_path($root) // die "EXTERNAL_CONFLICT: cannot resolve root '$root'\n";
  die "EXTERNAL_CONFLICT: symlink forbidden at root '$root'\n" if -l $root;
  return if !defined $target || !length $target;
  die "EXTERNAL_CONFLICT: NUL byte in managed path\n" if index($target, "\0") >= 0;

  # Reject any '..' component lexically before abs2rel normalization.
  for my $seg (File::Spec->splitdir($target)) {
    die "EXTERNAL_CONFLICT: parent traversal '..' forbidden in managed path '$target'\n" if $seg eq '..';
  }

  my $rel = File::Spec->abs2rel($target, $r);
  die "EXTERNAL_CONFLICT: managed path '$target' escapes root '$r'\n"
    if $rel =~ m{\A(?:/|\.\.(?:/|\z))};

  my @parts = grep { length $_ && $_ ne '.' } File::Spec->splitdir($rel);
  my $cur = $r;
  for my $part (@parts) {
    die "EXTERNAL_CONFLICT: parent traversal '..' forbidden in managed path '$target'\n" if $part eq '..';
    $cur = File::Spec->catfile($cur, $part);
    if (-l $cur) {
      die "EXTERNAL_CONFLICT: symlink detected at managed path $cur\n";
    }
    if (-e $cur) {
      my $resolved = abs_path($cur);
      die "EXTERNAL_CONFLICT: resolved path '$resolved' escapes root '$r'\n"
        unless defined $resolved && ($resolved eq $r || index($resolved, "$r/") == 0);
    } else {
      last;
    }
  }
}

# Deterministic recursive directory manifest (for move_dir_to_archive).
# Rejects any symlink inside the directory.
sub dir_tree_manifest {
  my ($dir) = @_;
  die "EXTERNAL_CONFLICT: symlink forbidden at directory $dir\n" if -l $dir;
  die "not a directory: $dir\n" unless -d $dir;
  my $abs_dir = abs_path($dir);
  my %files;
  my %empty_dirs;
  my %dir_has_child;

  find({
    no_chdir => 1,
    wanted   => sub {
      my $p = $File::Find::name;
      return if $p eq $abs_dir;
      die "EXTERNAL_CONFLICT: symlink forbidden inside managed directory at $p\n" if -l $p;
      my $rel = File::Spec->abs2rel($p, $abs_dir);
      $rel =~ s{\\}{/}g;
      my $parent = dirname($rel);
      $dir_has_child{$parent} = 1 if $parent ne '.';
      if (-d $p) {
        $empty_dirs{$rel} = 1;
      } elsif (-f $p) {
        $files{$rel} = sha256_file($p);
      } else {
        die "EXTERNAL_CONFLICT: unsupported non-regular file at $p\n";
      }
    },
  }, $abs_dir);

  my @empties = sort grep { !$dir_has_child{$_} } keys %empty_dirs;
  my $manifest = {
    files      => \%files,
    empty_dirs => \@empties,
  };
  my $tree_sha = sha256_bytes(encode_compact($manifest));
  return ($manifest, $tree_sha);
}

# Acquire exclusive flock on canonicalized <TASK>/research/plans/.tri-plan.lock.
sub with_task_lock {
  my ($task_dir, $code) = @_;
  die "EXTERNAL_CONFLICT: symlink forbidden at task dir $task_dir\n" if -l $task_dir;
  my $real_task = abs_path($task_dir);
  die "invalid task dir: $task_dir\n" unless defined $real_task && -d $real_task;
  my $plans_dir = "$real_task/research/plans";
  my $lock_path = "$plans_dir/.tri-plan.lock";
  ensure_no_symlink_components($real_task, $lock_path);
  make_path($plans_dir) unless -d $plans_dir;
  ensure_no_symlink_components($real_task, $lock_path);
  die "EXTERNAL_CONFLICT: non-regular lockfile at $lock_path\n" if -e $lock_path && (!-f $lock_path || -l $lock_path);
  open(my $lfh, '>>', $lock_path) or die "cannot open lockfile $lock_path: $!\n";
  flock($lfh, LOCK_EX) or die "cannot acquire flock on $lock_path: $!\n";
  my @res;
  my $want = wantarray;
  my $ok = eval {
    if ($want) { @res = $code->($real_task, $plans_dir); }
    else       { $res[0] = $code->($real_task, $plans_dir); }
    1;
  };
  my $err = $@;
  flock($lfh, LOCK_UN);
  close $lfh;
  die $err unless $ok;
  return $want ? @res : $res[0];
}

# Read-only staleness precheck BEFORE recover_tx for async callbacks.
# Checks BOTH live planning-state.json/active-run.json AND logical post-replay state of any
# committed-but-unreplayed .pending.tx.json (including slot/attempt/task_id!).
# Returns (1, $reason) if caller is stale, else (0, '').
sub check_stale_readonly {
  my ($plans_dir, $caller_gen, $caller_owner, $caller_owner_gen, $caller_run_id, $caller_slot, $caller_attempt, $caller_task_id) = @_;
  my $state_file = "$plans_dir/planning-state.json";
  my $tx_file    = "$plans_dir/.pending.tx.json";
  my $run_file   = "$plans_dir/active-run.json";

  my $logical_run;
  if (-f $tx_file && !-l $tx_file) {
    my $tx = eval { load_json_file($tx_file) };
    if (!$@ && ref $tx eq 'HASH' && ($tx->{commit_marker} // '') eq 'committed') {
      my $tx_next_gen = $tx->{next_generation};
      if (defined $tx_next_gen && defined $caller_gen && $caller_gen < $tx_next_gen) {
        return (1, "caller generation $caller_gen < committed pending tx next_generation $tx_next_gen");
      }
      if (defined $tx->{next_owner_generation} && defined $caller_owner_gen && $caller_owner_gen < $tx->{next_owner_generation}) {
        return (1, "caller owner_generation $caller_owner_gen < committed pending tx next_owner_generation $tx->{next_owner_generation}");
      }
      if (defined $tx->{closes_run_id} && defined $caller_run_id && $tx->{closes_run_id} eq $caller_run_id) {
        return (1, "caller run_id $caller_run_id is being closed by committed pending tx $tx->{tx_id}");
      }
      # If the committed pending tx updates active-run.json, read its staged post-state read-only!
      my $tx_id = $tx->{tx_id} // '';
      if ($tx_id =~ /\A[A-Za-z0-9._-]+\z/) {
        for my $op (@{$tx->{ops} || []}) {
          if (($op->{type} // '') eq 'write_file' && ($op->{dst} // '') eq 'research/plans/active-run.json') {
            my $srel = $op->{staged_rel} // '';
            if ($srel =~ /\A[A-Za-z0-9._-]+\z/) {
              my $sp = "$plans_dir/.tx-staging/$tx_id/$srel";
              if (-f $sp && !-l $sp) {
                my $sr = eval { load_json_file($sp) };
                $logical_run = $sr if !$@ && ref $sr eq 'HASH';
              }
            }
          }
        }
      }
    }
  }

  if (-f $state_file && !-l $state_file) {
    my $st = eval { load_json_file($state_file) };
    if (!$@ && ref $st eq 'HASH') {
      my $cur_gen = $st->{generation} // 0;
      if (defined $caller_gen && $caller_gen < $cur_gen) {
        return (1, "caller generation $caller_gen < current generation $cur_gen");
      }
      my $cur_og = $st->{owner_generation} // 0;
      if (defined $caller_owner_gen && $caller_owner_gen < $cur_og) {
        return (1, "caller owner_generation $caller_owner_gen < current owner_generation $cur_og");
      }
    }
  }

  if (!$logical_run && -f $run_file && !-l $run_file) {
    my $run = eval { load_json_file($run_file) };
    $logical_run = $run if !$@ && ref $run eq 'HASH';
  }

  if ($logical_run) {
    if (defined $caller_run_id && ($logical_run->{run_id} // '') ne $caller_run_id) {
      return (1, "caller run_id $caller_run_id != active run_id " . ($logical_run->{run_id} // 'none'));
    }
    if (($logical_run->{status} // '') ne 'active') {
      return (1, "active run status is '$logical_run->{status}'");
    }
    if (defined $caller_gen && ($logical_run->{generation} // 0) != $caller_gen) {
      return (1, "caller generation $caller_gen != active run generation " . ($logical_run->{generation} // 0));
    }
    if (defined $caller_owner && ($logical_run->{owner_thread_id} // '') ne $caller_owner) {
      return (1, "caller owner '$caller_owner' != active run owner '$logical_run->{owner_thread_id}'");
    }
    if (defined $caller_owner_gen && ($logical_run->{owner_generation} // 0) != $caller_owner_gen) {
      return (1, "caller owner_generation $caller_owner_gen != active run owner_generation " . ($logical_run->{owner_generation} // 0));
    }
    if (defined $caller_slot && length $caller_slot) {
      my $s = (ref($logical_run->{slots}) eq 'HASH') ? $logical_run->{slots}{$caller_slot} : undef;
      return (1, "unknown slot '$caller_slot'") unless ref $s eq 'HASH';
      if (defined $caller_attempt && ($s->{attempt} // 0) != $caller_attempt) {
        return (1, "caller attempt $caller_attempt != slot '$caller_slot' attempt " . ($s->{attempt} // 0));
      }
      if (defined $caller_task_id && length $caller_task_id && defined $s->{task_id} && $s->{task_id} ne $caller_task_id) {
        return (1, "caller task_id '$caller_task_id' != slot '$caller_slot' task_id '$s->{task_id}'");
      }
    }
  } elsif (defined $caller_run_id) {
    return (1, "no active-run.json for run_id $caller_run_id");
  }

  return (0, '');
}

# Verify a single transaction op and apply it idempotently if in Pre state.
# Implements exact 3-state table (Done / Pre / Conflict) with symlink rejection.
sub _replay_op {
  my ($task_dir, $plans_dir, $staged_dir, $op, $tx_id, $expected_gen, $next_gen) = @_;
  my $type = $op->{type} // die "tx op missing type\n";

  if ($type eq 'write_file') {
    _assert_clean_rel_path($op->{dst}, 'tx write_file.dst');
    _assert_clean_rel_path($op->{staged_rel}, 'tx write_file.staged_rel');
    my $dst = File::Spec->catfile($task_dir, $op->{dst});
    ensure_no_symlink_components($task_dir, $dst);
    my $post_sha = $op->{post_sha256};
    my $pre_kind = $op->{expected_pre_kind}; # 'absent' | 'file'
    my $pre_sha  = $op->{expected_pre_sha256};
    my $src_stage = File::Spec->catfile($staged_dir, $op->{staged_rel});
    ensure_no_symlink_components($staged_dir, $src_stage);

    if (-l $dst) {
      die "EXTERNAL_CONFLICT: symlink at write_file target $op->{dst}\n";
    }
    if (-d $dst) {
      die "EXTERNAL_CONFLICT: directory exists at write_file target $op->{dst}\n";
    }
    if (-f $dst) {
      my $cur_sha = sha256_file($dst);
      if ($cur_sha eq $post_sha) {
        # For planning-state.json, also verify tx_id & next_generation match.
        if ($op->{is_state_file}) {
          my $st = load_json_file($dst);
          if (($st->{last_tx_id} // '') eq $tx_id && ($st->{generation} // -1) == $next_gen) {
            return 'done';
          }
          die "EXTERNAL_CONFLICT: state file hash matched but tx_id/generation mismatch\n";
        }
        return 'done';
      }
      if ($pre_kind eq 'file' && defined $pre_sha && $cur_sha eq $pre_sha) {
        if ($op->{is_state_file}) {
          my $st = load_json_file($dst);
          die "EXTERNAL_CONFLICT: state file generation mismatch in pre-state\n"
            unless ($st->{generation} // 0) == $expected_gen;
        }
        die "tx staging file missing: $src_stage\n" unless -f $src_stage;
        my $bytes = read_raw_file($src_stage);
        die "tx staging digest mismatch for $op->{staged_rel}\n" unless sha256_bytes($bytes) eq $post_sha;
        write_atomic_bytes($dst, $bytes);
        return 'applied';
      }
      die "EXTERNAL_CONFLICT: write_file target '$op->{dst}' modified externally (cur=$cur_sha, expected_pre=" . ($pre_sha // 'absent') . ", post=$post_sha)\n";
    } else {
      if ($pre_kind eq 'absent') {
        die "tx staging file missing: $src_stage\n" unless -f $src_stage;
        my $bytes = read_raw_file($src_stage);
        die "tx staging digest mismatch for $op->{staged_rel}\n" unless sha256_bytes($bytes) eq $post_sha;
        write_atomic_bytes($dst, $bytes);
        return 'applied';
      }
      die "EXTERNAL_CONFLICT: write_file target '$op->{dst}' unexpectedly absent (expected_pre=$pre_sha)\n";
    }
  }
  elsif ($type eq 'move_file_to_archive') {
    _assert_clean_rel_path($op->{src}, 'tx move_file.src');
    _assert_clean_rel_path($op->{dst}, 'tx move_file.dst');
    my $src = File::Spec->catfile($task_dir, $op->{src});
    my $dst = File::Spec->catfile($task_dir, $op->{dst});
    ensure_no_symlink_components($task_dir, $src);
    ensure_no_symlink_components($task_dir, $dst);
    my $want_sha = $op->{src_sha256};

    die "EXTERNAL_CONFLICT: symlink at move_file src/dst ($op->{src} / $op->{dst})\n" if -l $src || -l $dst;
    my $src_exists = (-e $src) ? 1 : 0;
    my $dst_exists = (-e $dst) ? 1 : 0;

    if (!$src_exists && $dst_exists && -f $dst) {
      my $dsha = sha256_file($dst);
      return 'done' if $dsha eq $want_sha;
      die "EXTERNAL_CONFLICT: archive dst '$op->{dst}' has unexpected sha $dsha (want $want_sha)\n";
    }
    if ($src_exists && !$dst_exists && -f $src) {
      my $ssha = sha256_file($src);
      die "EXTERNAL_CONFLICT: archive src '$op->{src}' changed externally (cur=$ssha, want=$want_sha)\n"
        unless $ssha eq $want_sha;
      make_path(dirname($dst));
      rename($src, $dst) or die "cannot rename $src -> $dst: $!\n";
      return 'applied';
    }
    if ($src_exists && $dst_exists) {
      die "EXTERNAL_CONFLICT: archive dst '$op->{dst}' already exists AND src '$op->{src}' exists (source recreated or partial external conflict)\n";
    }
    die "EXTERNAL_CONFLICT: move_file_to_archive invalid state for '$op->{src}' -> '$op->{dst}'\n";
  }
  elsif ($type eq 'move_dir_to_archive') {
    _assert_clean_rel_path($op->{src}, 'tx move_dir.src');
    _assert_clean_rel_path($op->{dst}, 'tx move_dir.dst');
    my $src = File::Spec->catfile($task_dir, $op->{src});
    my $dst = File::Spec->catfile($task_dir, $op->{dst});
    ensure_no_symlink_components($task_dir, $src);
    ensure_no_symlink_components($task_dir, $dst);
    my $want_tree = $op->{tree_sha256};

    die "EXTERNAL_CONFLICT: symlink at move_dir src/dst ($op->{src} / $op->{dst})\n" if -l $src || -l $dst;
    my $src_exists = (-e $src) ? 1 : 0;
    my $dst_exists = (-e $dst) ? 1 : 0;

    if (!$src_exists && $dst_exists && -d $dst) {
      my (undef, $d_tree) = dir_tree_manifest($dst);
      return 'done' if $d_tree eq $want_tree;
      die "EXTERNAL_CONFLICT: archive dir '$op->{dst}' tree mismatch (cur=$d_tree, want=$want_tree)\n";
    }
    if ($src_exists && !$dst_exists && -d $src) {
      my (undef, $s_tree) = dir_tree_manifest($src);
      die "EXTERNAL_CONFLICT: archive src dir '$op->{src}' modified externally (cur=$s_tree, want=$want_tree)\n"
        unless $s_tree eq $want_tree;
      make_path(dirname($dst));
      rename($src, $dst) or die "cannot rename dir $src -> $dst: $!\n";
      return 'applied';
    }
    if ($src_exists && $dst_exists) {
      die "EXTERNAL_CONFLICT: archive dir '$op->{dst}' exists AND source dir '$op->{src}' was recreated externally\n";
    }
    die "EXTERNAL_CONFLICT: move_dir_to_archive invalid state for '$op->{src}' -> '$op->{dst}'\n";
  }
  elsif ($type eq 'remove_file') {
    _assert_clean_rel_path($op->{target}, 'tx remove_file.target');
    my $tgt = File::Spec->catfile($task_dir, $op->{target});
    ensure_no_symlink_components($task_dir, $tgt);
    my $pre_sha = $op->{expected_pre_sha256};
    die "EXTERNAL_CONFLICT: symlink at remove_file target $op->{target}\n" if -l $tgt;
    return 'done' unless -e $tgt;
    die "EXTERNAL_CONFLICT: non-regular file at remove_file target $op->{target}\n" unless -f $tgt;
    my $csha = sha256_file($tgt);
    die "EXTERNAL_CONFLICT: remove_file target '$op->{target}' modified externally (cur=$csha, want=$pre_sha)\n"
      unless $csha eq $pre_sha;
    unlink($tgt) or die "cannot unlink $tgt: $!\n";
    return 'applied';
  }
  else {
    die "unknown tx op type '$type'\n";
  }
}

# Recover any uncommitted or committed .pending.tx.json under flock.
sub recover_tx {
  my ($task_dir, $plans_dir) = @_;
  my $tx_file = "$plans_dir/.pending.tx.json";
  return 0 unless -e $tx_file;
  die "EXTERNAL_CONFLICT: non-regular file or symlink at $tx_file\n" if -l $tx_file || !-f $tx_file;

  my $tx = load_json_file($tx_file);
  die "EXTERNAL_CONFLICT: corrupt .pending.tx.json (not a JSON object)\n" unless ref $tx eq 'HASH';
  my $tx_id = $tx->{tx_id};
  die "EXTERNAL_CONFLICT: corrupt .pending.tx.json (invalid tx_id)\n"
    unless defined $tx_id && !ref($tx_id) && $tx_id =~ /\A[A-Za-z0-9._-]+\z/;
  die "EXTERNAL_CONFLICT: corrupt .pending.tx.json (ops must be an array)\n"
    unless ref($tx->{ops}) eq 'ARRAY';
  my $staged_root = "$plans_dir/.tx-staging";
  my $staged_dir  = "$staged_root/$tx_id";
  ensure_no_symlink_components($task_dir, $staged_dir);
  my $marker = $tx->{commit_marker} // 'staged';
  die "EXTERNAL_CONFLICT: corrupt .pending.tx.json (invalid commit_marker '$marker')\n"
    unless $marker eq 'staged' || $marker eq 'committed';

  if ($marker ne 'committed') {
    # Crashed before commit marker: roll back staging cleanly, touch zero live files.
    remove_tree($staged_dir) if -d $staged_dir && !-l $staged_dir;
    unlink($tx_file) or die "cannot remove uncommitted $tx_file: $!\n";
    return 1;
  }

  # Committed transaction: replay all ops idempotently, fail closed on EXTERNAL_CONFLICT.
  for my $op (@{$tx->{ops}}) {
    die "EXTERNAL_CONFLICT: corrupt tx op\n" unless ref $op eq 'HASH';
    _replay_op($task_dir, $plans_dir, $staged_dir, $op, $tx_id, $tx->{expected_generation}, $tx->{next_generation});
  }

  # Second pass: verify EVERY op is now strictly in Done state before cleaning up tx manifest.
  for my $op (@{$tx->{ops}}) {
    my $st = _replay_op($task_dir, $plans_dir, $staged_dir, $op, $tx_id, $tx->{expected_generation}, $tx->{next_generation});
    die "tx verification failed: op did not reach done state\n" unless $st eq 'done';
  }

  remove_tree($staged_dir) if -d $staged_dir && !-l $staged_dir;
  unlink($tx_file) or die "cannot finalize $tx_file: $!\n";
  return 2;
}

# Stage and execute a multi-file atomic transaction under flock.
# $spec: {
#   tx_id, expected_generation, next_generation,
#   next_owner_generation?, closes_run_id?,
#   writes => [ { dst => rel_to_task, bytes => ..., is_state_file => 0|1 } ],
#   moves  => [ { src => rel_to_task, dst => rel_to_task } ], # auto file or dir
#   removes => [ rel_to_task ],
# }
sub execute_tx {
  my ($task_dir, $plans_dir, $spec) = @_;
  recover_tx($task_dir, $plans_dir);

  my $tx_id = $spec->{tx_id} || ("tx-" . time() . "-$$-" . int(rand(100000)));
  my $staged_dir = "$plans_dir/.tx-staging/$tx_id";
  make_path($staged_dir);

  my @ops;
  my $idx = 0;

  # 1. Stage moves (capture pre-hashes / dir manifests).
  for my $m (@{$spec->{moves} || []}) {
    my $src_abs = File::Spec->catfile($task_dir, $m->{src});
    my $dst_abs = File::Spec->catfile($task_dir, $m->{dst});
    ensure_no_symlink_components($task_dir, $src_abs);
    ensure_no_symlink_components($task_dir, $dst_abs);
    next unless -e $src_abs;
    die "EXTERNAL_CONFLICT: move destination already exists: $m->{dst}\n" if -e $dst_abs;
    if (-d $src_abs) {
      my ($manifest, $tree_sha) = dir_tree_manifest($src_abs);
      push @ops, {
        type          => 'move_dir_to_archive',
        src           => $m->{src},
        dst           => $m->{dst},
        tree_sha256   => $tree_sha,
        tree_manifest => $manifest,
      };
    } elsif (-f $src_abs) {
      push @ops, {
        type       => 'move_file_to_archive',
        src        => $m->{src},
        dst        => $m->{dst},
        src_sha256 => sha256_file($src_abs),
      };
    } else {
      die "EXTERNAL_CONFLICT: unsupported move source type at $m->{src}\n";
    }
  }

  # 2. Stage removes.
  for my $r (@{$spec->{removes} || []}) {
    my $abs = File::Spec->catfile($task_dir, $r);
    ensure_no_symlink_components($task_dir, $abs);
    next unless -e $abs;
    die "EXTERNAL_CONFLICT: remove target is not a regular file: $r\n" unless -f $abs && !-l $abs;
    push @ops, {
      type                => 'remove_file',
      target              => $r,
      expected_pre_sha256 => sha256_file($abs),
    };
  }

  # 3. Stage writes (non-state files first, state file last unless state_first => 1).
  my %moved_srcs = map { $_->{src} => 1 } grep { $_->{type} =~ /^move_/ } @ops;
  my @write_ops;
  my @state_write_ops;
  for my $w (@{$spec->{writes} || []}) {
    die "tx invariant violated: write_file targets moved src '$w->{dst}' in same tx\n"
      if $moved_srcs{$w->{dst}};
    $idx++;
    my $dst_abs = File::Spec->catfile($task_dir, $w->{dst});
    ensure_no_symlink_components($task_dir, $dst_abs);
    my $staged_rel = sprintf("w%03d.bin", $idx);
    write_atomic_bytes("$staged_dir/$staged_rel", $w->{bytes});
    my $post_sha = sha256_bytes($w->{bytes});

    my ($pre_kind, $pre_sha) = ('absent', undef);
    my $cleared_by_prior = 0;
    for my $op (@ops) {
      if ($op->{type} eq 'remove_file' && $op->{target} eq $w->{dst}) {
        $cleared_by_prior = 1;
      }
    }
    if (!$cleared_by_prior && -e $dst_abs) {
      die "EXTERNAL_CONFLICT: write destination is not a regular file: $w->{dst}\n" unless -f $dst_abs && !-l $dst_abs;
      $pre_kind = 'file';
      $pre_sha  = sha256_file($dst_abs);
    }

    my $wop = {
      type                => 'write_file',
      staged_rel          => $staged_rel,
      dst                 => $w->{dst},
      expected_pre_kind   => $pre_kind,
      expected_pre_sha256 => $pre_sha,
      post_sha256         => $post_sha,
      is_state_file       => $w->{is_state_file} ? JSON::PP::true : JSON::PP::false,
    };
    if ($w->{is_state_file}) { push @state_write_ops, $wop; }
    else                     { push @write_ops, $wop; }
  }

  if ($spec->{state_first}) {
    @ops = (@state_write_ops, @ops, @write_ops);
  } else {
    @ops = (@ops, @write_ops, @state_write_ops);
  }

  my $tx = {
    tx_id               => $tx_id,
    expected_generation => $spec->{expected_generation} // 0,
    next_generation     => $spec->{next_generation} // ($spec->{expected_generation} // 0),
    commit_marker       => 'staged',
    ops                 => \@ops,
  };
  $tx->{next_owner_generation} = $spec->{next_owner_generation} if defined $spec->{next_owner_generation};
  $tx->{closes_run_id}         = $spec->{closes_run_id}         if defined $spec->{closes_run_id};

  my $tx_file = "$plans_dir/.pending.tx.json";
  write_atomic_bytes($tx_file, encode_canonical($tx));

  # Flip commit marker atomically -> point of no return.
  $tx->{commit_marker} = 'committed';
  write_atomic_bytes($tx_file, encode_canonical($tx));

  # Test hook: simulate crash right after commit_marker (or after N ops) when env var is set.
  if (defined $ENV{T3_TRI_PLAN_TEST_CRASH_TX} && $ENV{T3_TRI_PLAN_TEST_CRASH_TX} eq 'after_commit_marker') {
    die "SIMULATED_TX_CRASH: after_commit_marker ($tx_id)\n";
  }

  my $applied = 0;
  for my $op (@ops) {
    _replay_op($task_dir, $plans_dir, $staged_dir, $op, $tx_id, $tx->{expected_generation}, $tx->{next_generation});
    $applied++;
    if (defined $ENV{T3_TRI_PLAN_TEST_CRASH_AFTER_OP} && $ENV{T3_TRI_PLAN_TEST_CRASH_AFTER_OP} == $applied) {
      die "SIMULATED_TX_CRASH: after_op_$applied ($tx_id)\n";
    }
  }

  remove_tree($staged_dir) if -d $staged_dir;
  unlink($tx_file) or die "cannot finalize $tx_file: $!\n";
  return $tx_id;
}

# Helper to run git commands safely in $repo_root.
sub _git {
  my ($repo_root, @args) = @_;
  open(my $ph, '-|', 'git', '-C', $repo_root, @args) or return (1, '');
  binmode($ph, ':raw');
  local $/;
  my $out = <$ph>;
  close $ph;
  my $rc = $? >> 8;
  return ($rc, defined $out ? $out : '');
}

# Compute worktree_fp v3: content-based fingerprint covering HEAD, reflog count,
# staged index entries, and working-tree content SHA-256 of ALL modified tracked
# files and non-ignored untracked files (excluding engine runtime paths under
# <task_rel>/research/plans/{.tri-plan.lock,.tx-staging,.pending.tx.json,active-run.json,runs}).
sub compute_worktree_fp {
  my ($repo_root, $task_rel) = @_;
  my ($rc_g, $inside) = _git($repo_root, 'rev-parse', '--is-inside-work-tree');
  $inside =~ s/\s+//g;
  die "WORKTREE_FP_ERROR: '$repo_root' is not a valid git working tree (rc=$rc_g)\n"
    unless $rc_g == 0 && $inside eq 'true';

  my ($rc_h, $head) = _git($repo_root, 'rev-parse', '--verify', 'HEAD');
  $head =~ s/\s+//g;
  if ($rc_h != 0 || !length $head) {
    # Distinguish genuine unborn HEAD from corrupted repo.
    my ($rc_sym) = _git($repo_root, 'symbolic-ref', '-q', 'HEAD');
    die "WORKTREE_FP_ERROR: git rev-parse HEAD failed and HEAD is not an unborn symbolic ref\n"
      unless $rc_sym == 0;
    $head = 'UNBORN';
  }

  my $refcnt = '0';
  if ($head ne 'UNBORN') {
    my ($rc_r, $rc_out) = _git($repo_root, 'rev-list', '--count', '--walk-reflogs', 'HEAD');
    $rc_out =~ s/\s+//g;
    if ($rc_r == 0 && $rc_out =~ /\A\d+\z/) {
      $refcnt = $rc_out;
    } else {
      $refcnt = '0'; # shallow/no-reflog repo is allowed; HEAD itself already verified
    }
  }

  my $engine_prefix = defined $task_rel && length $task_rel
    ? "$task_rel/research/plans"
    : '';

  my $is_engine_runtime = sub {
    my ($p) = @_;
    return 0 unless length $engine_prefix;
    return 1 if $p eq "$engine_prefix/.tri-plan.lock";
    return 1 if $p eq "$engine_prefix/.pending.tx.json";
    return 1 if $p eq "$engine_prefix/active-run.json";
    return 1 if $p eq "$engine_prefix/planning-state.json";
    return 1 if $p eq "$engine_prefix/.activation.lock";
    return 1 if index($p, "$engine_prefix/.tx-staging/") == 0;
    return 1 if index($p, "$engine_prefix/runs/") == 0;
    return 0;
  };

  # Staged index diffs vs HEAD (fail-closed on git index corruption!).
  my %staged;
  if ($head eq 'UNBORN') {
    my ($rc_s, $raw_s) = _git($repo_root, 'ls-files', '--stage', '-z');
    die "WORKTREE_FP_ERROR: git ls-files --stage failed (rc=$rc_s)\n" unless $rc_s == 0;
    if (length $raw_s) {
      for my $entry (split(/\0/, $raw_s)) {
        next unless $entry =~ /\A(\d+)\s+([0-9a-f]+)\s+\d+\t(.+)\z/s;
        my ($mode, $blob, $p) = ($1, $2, $3);
        next if $is_engine_runtime->($p);
        $staged{$p} = "$mode:$blob";
      }
    }
  } else {
    my ($rc_s, $raw_s) = _git($repo_root, 'diff-index', '--cached', '--raw', '-z', 'HEAD');
    die "WORKTREE_FP_ERROR: git diff-index --cached failed (rc=$rc_s)\n" unless $rc_s == 0;
    if (length $raw_s) {
      my @toks = split(/\0/, $raw_s);
      my $i = 0;
      while ($i + 1 < @toks) {
        my ($meta, $p) = ($toks[$i], $toks[$i + 1]);
        $i += 2;
        next if $is_engine_runtime->($p);
        $staged{$p} = $meta;
      }
    }
  }

  # Collect ALL truly modified tracked paths (content-checked, fail-closed on git failure)
  # + non-ignored untracked paths.
  my %wt_paths;
  my ($rc_m, $raw_m) = _git($repo_root, 'diff', '--no-ext-diff', '--no-renames', '--name-only', '-z');
  die "WORKTREE_FP_ERROR: git diff failed (rc=$rc_m)\n" unless $rc_m == 0;
  $wt_paths{$_} = 1 for grep { length $_ } split(/\0/, $raw_m);

  if ($head ne 'UNBORN') {
    my ($rc_c, $raw_c) = _git($repo_root, 'diff', '--no-ext-diff', '--no-renames', '--name-only', '-z', 'HEAD');
    die "WORKTREE_FP_ERROR: git diff HEAD failed (rc=$rc_c)\n" unless $rc_c == 0;
    $wt_paths{$_} = 1 for grep { length $_ } split(/\0/, $raw_c);
  }
  my ($rc_u, $raw_u) = _git($repo_root, 'ls-files', '--others', '--exclude-standard', '-z');
  die "WORKTREE_FP_ERROR: git ls-files --others failed (rc=$rc_u)\n" unless $rc_u == 0;
  $wt_paths{$_} = 1 for grep { length $_ } split(/\0/, $raw_u);

  my %wt_files;
  for my $p (sort keys %wt_paths) {
    next if $is_engine_runtime->($p);
    my $abs = File::Spec->catfile($repo_root, $p);
    if (-l $abs) {
      my $lnk = readlink($abs) // '';
      $wt_files{$p} = 'symlink:' . sha256_bytes($lnk);
    } elsif (-f $abs) {
      my @st = lstat($abs);
      my $exec = (@st && ($st[2] & 0111)) ? 'x' : '-';
      $wt_files{$p} = "file:$exec:" . sha256_file($abs);
    } elsif (-d $abs) {
      # Dirty submodule / nested gitlink: capture its HEAD + status + diff hash instead of static 'dir'!
      if (-e "$abs/.git") {
        my ($rc_sh, $sub_h) = _git($abs, 'rev-parse', '--verify', 'HEAD');
        $sub_h =~ s/\s+//g;
        my ($rc_sp, $sub_p) = _git($abs, 'status', '--porcelain', '--untracked-files=all', '-z');
        my ($rc_sd, $sub_d) = _git($abs, 'diff', '--no-ext-diff', 'HEAD');
        die "WORKTREE_FP_ERROR: failed inspecting dirty submodule '$p'\n"
          unless $rc_sp == 0 && ($rc_sh == 0 || $rc_sd == 0);
        $wt_files{$p} = 'gitlink:' . sha256_bytes("$sub_h\0$sub_p\0$sub_d");
      } else {
        my (undef, $tsha) = dir_tree_manifest($abs);
        $wt_files{$p} = "dir:$tsha";
      }
    } else {
      $wt_files{$p} = 'deleted';
    }
  }

  my $fp = {
    version      => 3,
    head         => $head,
    reflog_count => 0 + $refcnt,
    staged       => \%staged,
    wt_files     => \%wt_files,
  };
  $fp->{digest} = sha256_bytes(encode_compact({
    head         => $head,
    reflog_count => 0 + $refcnt,
    staged       => \%staged,
    wt_files     => \%wt_files,
  }));
  return $fp;
}

# Compare start vs current worktree_fp, permitting ONLY explicit allowed_parent_writes
# ({ $rel_path => $expected_post_file_sha256 }).
# Returns arrayref of drift descriptions (empty = clean).
sub compare_worktree_fp {
  my ($start_fp, $cur_fp, $allowed_writes) = @_;
  $allowed_writes ||= {};
  my @drifts;

  push @drifts, "HEAD moved: $start_fp->{head} -> $cur_fp->{head}"
    if ($start_fp->{head} // '') ne ($cur_fp->{head} // '');
  push @drifts, "HEAD reflog count changed: $start_fp->{reflog_count} -> $cur_fp->{reflog_count}"
    if ($start_fp->{reflog_count} // 0) != ($cur_fp->{reflog_count} // 0);

  # Check staged changes.
  my %all_staged = map { $_ => 1 } (keys %{$start_fp->{staged} || {}}, keys %{$cur_fp->{staged} || {}});
  for my $p (sort keys %all_staged) {
    my $a = $start_fp->{staged}{$p} // '<none>';
    my $b = $cur_fp->{staged}{$p}   // '<none>';
    push @drifts, "staged changed at '$p': $a -> $b" if $a ne $b;
  }

  # Check working-tree file content changes.
  my %all_wt = map { $_ => 1 } (keys %{$start_fp->{wt_files} || {}}, keys %{$cur_fp->{wt_files} || {}});
  for my $p (sort keys %all_wt) {
    my $a = $start_fp->{wt_files}{$p} // '<absent>';
    my $b = $cur_fp->{wt_files}{$p}   // '<absent>';
    next if $a eq $b;
    if (exists $allowed_writes->{$p}) {
      my $want = $allowed_writes->{$p};
      if (!defined $want) {
        next if $b eq '<absent>';
      } elsif ($b =~ /\Afile:[-x]:([0-9a-f]{64})\z/ && $1 eq $want) {
        next;
      }
      push @drifts, "allowed path '$p' has unexpected digest ($b, expected $want)";
      next;
    }
    push @drifts, "unexplained working-tree change at '$p': $a -> $b";
  }

  return \@drifts;
}

sub _slugify_heading {
  my ($h) = @_;
  $h = lc($h);
  $h =~ s/`//g;
  $h =~ s/[^\p{Alnum}\s\-_]+//g;
  $h =~ s/^\s+|\s+$//g;
  $h =~ s/[\s_]+/-/g;
  $h =~ s/-+/-/g;
  return $h;
}

# Scan baseline repository rule files (REVIEW.md, AGENTS.md, AGENTS.override.md, CLAUDE.md)
# at HEAD via raw git ls-tree + git cat-file blob (immune to .gitattributes), plus detect
# working-tree deltas to those rule files. Also extracts heading anchors for REVIEW.md files.
sub scan_repo_rules {
  my ($repo_root) = @_;
  my ($rc_h, $head) = _git($repo_root, 'rev-parse', '--verify', 'HEAD');
  $head =~ s/\s+//g;
  $head = '' if $rc_h != 0;

  my %base_rules;   # path => blob_sha256
  my %rule_files;   # REVIEW.md paths => 1
  my %rules_index;  # REVIEW.md#slug => 1
  my %wt_deltas;    # path => status/sha

  my $is_rule_name = sub {
    my ($p) = @_;
    my $base = $p;
    $base =~ s{\A.*/}{}s;
    return ($base eq 'REVIEW.md' || $base eq 'AGENTS.md' || $base eq 'AGENTS.override.md' || $base eq 'CLAUDE.md') ? 1 : 0;
  };

  if (length $head) {
    my ($rc_t, $raw_t) = _git($repo_root, 'ls-tree', '-r', '-z', $head);
    die "RULES_SCAN_ERROR: git ls-tree HEAD failed (rc=$rc_t)\n" unless $rc_t == 0;
    if (length $raw_t) {
      for my $entry (split(/\0/, $raw_t)) {
        next unless $entry =~ /\A(\d+)\s+(\w+)\s+([0-9a-f]+)\t(.+)\z/s;
        my ($mode, $objtype, $oid, $p) = ($1, $2, $3, $4);
        next unless $is_rule_name->($p);
        if ($objtype eq 'blob' && $mode ne '120000') {
          my ($rc_b, $blob) = _git($repo_root, 'cat-file', 'blob', $oid);
          die "RULES_SCAN_ERROR: git cat-file blob $oid failed for $p (rc=$rc_b)\n" unless $rc_b == 0;
          my $bsha = sha256_bytes($blob);
          $base_rules{$p} = "$mode:$bsha";
          my $base = $p; $base =~ s{\A.*/}{}s;
          if ($base eq 'REVIEW.md') {
            $rule_files{$p} = 1;
            my $blob_text = eval { decode('UTF-8', $blob, FB_CROAK | LEAVE_SRC) };
            $blob_text = $blob if $@;
            for my $line (split(/\r?\n/, $blob_text)) {
              if ($line =~ /\A#{1,6}\s+(.+?)\s*#*\s*\z/) {
                my $slug = _slugify_heading($1);
                $rules_index{"$p#$slug"} = 1 if length $slug;
              }
            }
          }
        } else {
          $base_rules{$p} = "$mode:$objtype:$oid";
        }
      }
    }
  }

  # Inspect working-tree modifications/additions/deletions to rule files.
  my %cand_paths = map { $_ => 1 } keys %base_rules;
  my ($rc_u, $raw_u) = _git($repo_root, 'ls-files', '--others', '--exclude-standard', '-z');
  die "RULES_SCAN_ERROR: git ls-files --others failed (rc=$rc_u)\n" unless $rc_u == 0;
  if (length $raw_u) {
    for my $p (split(/\0/, $raw_u)) {
      $cand_paths{$p} = 1 if length($p) && $is_rule_name->($p);
    }
  }
  for my $p (sort keys %cand_paths) {
    my $abs = File::Spec->catfile($repo_root, $p);
    my $wt_val;
    if (-l $abs) {
      $wt_val = 'symlink:' . sha256_bytes(readlink($abs) // '');
    } elsif (-f $abs) {
      $wt_val = 'file:' . sha256_file($abs);
    } else {
      $wt_val = 'deleted';
    }
    my $base_v = $base_rules{$p};
    if (!defined $base_v) {
      $wt_deltas{$p} = "added:$wt_val";
    } elsif ($base_v =~ /\A\d+:([0-9a-f]{64})\z/ && $wt_val eq "file:$1") {
      # unchanged
    } else {
      $wt_deltas{$p} = "modified:$wt_val";
    }
  }

  my $digest = sha256_bytes(encode_compact({
    head       => $head,
    base_rules => \%base_rules,
    wt_deltas  => \%wt_deltas,
  }));

  return {
    base_head   => $head,
    base_rules  => \%base_rules,
    wt_deltas   => \%wt_deltas,
    rule_files  => \%rule_files,
    rules_index => \%rules_index,
    digest      => $digest,
  };
}

# Compute component-isolated non_prd_baseline_sha256:
# Covers:
#   1. live design.md SHA-256
#   2. Phase 1 committed candidates SHA-256 map + locked blind-eval.json SHA-256
#   3. repo code & spec state: HEAD + ALL non-task tracked dirty/staged/non-ignored files
#      + referenced .trellis/spec/ files
#   4. frozen repo rule baseline + worktree rule deltas
sub compute_non_prd_baseline {
  my ($repo_root, $task_dir, $task_rel, $state) = @_;
  my $design_path = "$task_dir/design.md";
  my $design_sha  = (-f $design_path && !-l $design_path) ? sha256_file($design_path) : 'MISSING';

  my $cands = {};
  if (ref($state->{phases}) eq 'HASH' && ref($state->{phases}{'1'}) eq 'HASH' && ref($state->{phases}{'1'}{candidates}) eq 'HASH') {
    for my $slot (sort keys %{$state->{phases}{'1'}{candidates}}) {
      my $cp = "$task_dir/research/plans/candidates/$slot.md";
      $cands->{$slot} = (-f $cp && !-l $cp) ? sha256_file($cp) : 'MISSING';
    }
  }

  my $be_path = "$task_dir/research/plans/blind-eval.json";
  my $be_sha  = (-f $be_path && !-l $be_path) ? sha256_file($be_path) : 'MISSING';
  my $sb_path = "$task_dir/research/plans/synthesis-body-locked.md";
  my $sb_sha  = (-f $sb_path && !-l $sb_path) ? sha256_file($sb_path) : 'MISSING';

  my $fp = compute_worktree_fp($repo_root, $task_rel);
  # Filter worktree files to NON-TASK paths (so edits to repo code/specs/rules change baseline,
  # while task-internal review-rounds/ledger appends and Trellis runtime pointers do not perturb cross-round baseline).
  my $task_prefix = defined $task_rel && length $task_rel ? "$task_rel/" : '';
  my $is_trellis_runtime = sub {
    my ($p) = @_;
    return 1 if $p eq '.trellis/.current-task' || $p eq '.trellis/.developer' || $p eq '.trellis/.session-id';
    return 1 if index($p, '.trellis/.runtime/') == 0;
    return 0;
  };
  my (%non_task_staged, %non_task_wt);
  for my $p (keys %{$fp->{staged}}) {
    next if length($task_prefix) && index($p, $task_prefix) == 0;
    next if $is_trellis_runtime->($p);
    $non_task_staged{$p} = $fp->{staged}{$p};
  }
  for my $p (keys %{$fp->{wt_files}}) {
    next if length($task_prefix) && index($p, $task_prefix) == 0;
    next if $is_trellis_runtime->($p);
    $non_task_wt{$p} = $fp->{wt_files}{$p};
  }

  # Hash ALL .trellis/spec/ files (independent of Phase 5 implement.jsonl/check.jsonl so writing
  # Phase 5 manifests never perturbs Phase 3's convergence baseline, while any spec edit DOES!).
  my %spec_shas;
  my $spec_dir = File::Spec->catdir($repo_root, '.trellis', 'spec');
  if (-d $spec_dir && !-l $spec_dir) {
    find({
      no_chdir => 1,
      wanted   => sub {
        my $p = $File::Find::name;
        return if -d $p;
        my $rel = File::Spec->abs2rel($p, $repo_root);
        $rel =~ s{\\}{/}g;
        if (-l $p) { $spec_shas{$rel} = 'symlink:' . sha256_bytes(readlink($p) // ''); }
        elsif (-f $p) { $spec_shas{$rel} = sha256_file($p); }
      },
    }, $spec_dir);
  }

  my $rules = scan_repo_rules($repo_root);

  my $payload = {
    design_sha                => $design_sha,
    candidates                => $cands,
    blind_eval_sha            => $be_sha,
    synthesis_body_locked_sha => $sb_sha,
    repo_head                 => $fp->{head},
    non_task_staged           => \%non_task_staged,
    non_task_wt               => \%non_task_wt,
    spec_shas                 => \%spec_shas,
    rules_digest              => $rules->{digest},
  };
  my $non_prd_sha = sha256_bytes(encode_compact($payload));
  return ($non_prd_sha, $payload, $rules);
}

sub compute_review_baseline {
  my ($effective_prd_sha, $non_prd_sha) = @_;
  return sha256_bytes(encode_compact({
    effective_prd_sha256    => $effective_prd_sha // '',
    non_prd_baseline_sha256 => $non_prd_sha // '',
  }));
}

1;
