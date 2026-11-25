#!/usr/bin/env perl
# validate-blind-eval.pl — Strict structural + semantic validator for Phase 2a Blind Judge JSON.
# Enforces:
#   - Unique-key strict RFC 8259 JSON via StrictJson.pm
#   - Exact candidate_set + 64-char SHA-256 match against Phase 1 committed candidates
#   - primary_winner in candidate_set, eliminated covers exact remaining slots
#   - 12 required canonical axis_matrix rows covering every slot
#   - Every cherry_pick has source_slot in candidate_set, source_slot != primary_winner,
#     compatible_with_winner_architecture === true, and evidence_fact_check_id pointing to a
#     CONFIRMED fact_check whose candidate_slot == source_slot with non-empty file_line_evidence
#     and verifiable alignment with evidence_quote
#   - Zero unresolved product_forks unless --allow-forks is supplied
#   - Non-empty synthesis_body_markdown and initial_design_markdown

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/lib";
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
use StrictJson qw(load_json_file_typed load_json_file unwrap_typed encode_canonical);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my ($input_path, $cand_manifest_path, $allow_forks, $write_canon);
$allow_forks = 0;

while (@ARGV) {
  my $a = shift @ARGV;
  if    ($a eq '--input')               { $input_path         = shift @ARGV; }
  elsif ($a eq '--candidates-manifest') { $cand_manifest_path = shift @ARGV; }
  elsif ($a eq '--allow-forks')         { $allow_forks        = 1; }
  elsif ($a eq '--write-canonical')     { $write_canon        = shift @ARGV; }
  else                                  { fail("unknown arg: $a"); }
}

fail("--input is required") unless defined $input_path && -f $input_path;
fail("--candidates-manifest is required") unless defined $cand_manifest_path && -f $cand_manifest_path;

my $expected_cands = eval { load_json_file($cand_manifest_path) };
fail("invalid candidates-manifest: $@") if $@ || ref $expected_cands ne 'HASH' || !keys %$expected_cands;

my $root = eval { load_json_file_typed($input_path) };
fail("JSON parse error: $@") if $@;

sub fail {
  my ($msg) = @_;
  $msg =~ s/\r?\n/ /g;
  print "VALID=0\n";
  print "ERROR=$msg\n";
  exit 1;
}

sub req_obj {
  my ($node, $ctx, $req_keys, $opt_keys) = @_;
  fail("$ctx must be a JSON object") unless $node && $node->[0] eq 'obj';
  my $h = $node->[1];
  my %allowed = map { $_ => 1 } (@$req_keys, @{$opt_keys || []});
  for my $k (@$req_keys) {
    fail("$ctx missing required key '$k'") unless exists $h->{$k};
  }
  for my $k (sort keys %$h) {
    fail("$ctx has unexpected property '$k'") unless $allowed{$k};
  }
  return $h;
}

sub req_str {
  my ($node, $ctx, $nonempty) = @_;
  fail("$ctx must be a string") unless $node && $node->[0] eq 'str';
  my $s = $node->[1];
  fail("$ctx must be non-empty") if $nonempty && $s !~ /\S/;
  return $s;
}

sub req_arr {
  my ($node, $ctx, $min) = @_;
  fail("$ctx must be an array") unless $node && $node->[0] eq 'arr';
  my $a = $node->[1];
  fail("$ctx must have at least $min items") if defined $min && @$a < $min;
  return $a;
}

sub req_bool_true {
  my ($node, $ctx) = @_;
  fail("$ctx must be boolean true") unless $node && $node->[0] eq 'bool' && $node->[1];
  return 1;
}

my @TOP_REQ = qw(
  candidate_set fact_checks axis_matrix primary_winner winner_rationale
  eliminated cherry_picks rejected_ideas product_forks product_decisions
  synthesis_body_markdown initial_design_markdown
);
my $top = req_obj($root, 'root', \@TOP_REQ, []);

# 1. Validate candidate_set against manifest 1-to-1.
my $cset_arr = req_arr($top->{candidate_set}, 'candidate_set', 1);
my %got_cands;
for my $i (0 .. $#$cset_arr) {
  my $c = req_obj($cset_arr->[$i], "candidate_set[$i]", [qw(slot sha256)], []);
  my $slot = req_str($c->{slot}, "candidate_set[$i].slot", 1);
  my $sha  = req_str($c->{sha256}, "candidate_set[$i].sha256", 1);
  fail("candidate_set[$i].sha256 must be 64-char lowercase hex") unless $sha =~ /\A[0-9a-f]{64}\z/;
  fail("duplicate slot '$slot' in candidate_set") if exists $got_cands{$slot};
  $got_cands{$slot} = $sha;
}
for my $eslot (sort keys %$expected_cands) {
  fail("candidate_set missing committed slot '$eslot'") unless exists $got_cands{$eslot};
  fail("candidate_set sha256 mismatch for '$eslot': got $got_cands{$eslot}, expected $expected_cands->{$eslot}")
    unless $got_cands{$eslot} eq $expected_cands->{$eslot};
}
for my $gslot (sort keys %got_cands) {
  fail("candidate_set contains unknown slot '$gslot'") unless exists $expected_cands->{$gslot};
}

# 2. Validate fact_checks.
my $fc_arr = req_arr($top->{fact_checks}, 'fact_checks', 1);
my %fc_by_id;
my %VALID_FC_STATUS = map { $_ => 1 } qw(CONFIRMED REFUTED UNVERIFIED);
for my $i (0 .. $#$fc_arr) {
  my $fc = req_obj($fc_arr->[$i], "fact_checks[$i]", [qw(id candidate_slot claim status file_line_evidence)], []);
  my $id   = req_str($fc->{id}, "fact_checks[$i].id", 1);
  my $slot = req_str($fc->{candidate_slot}, "fact_checks[$i].candidate_slot", 1);
  my $clm  = req_str($fc->{claim}, "fact_checks[$i].claim", 1);
  my $st   = req_str($fc->{status}, "fact_checks[$i].status", 1);
  my $ev   = req_str($fc->{file_line_evidence}, "fact_checks[$i].file_line_evidence", 0);
  fail("duplicate fact_check id '$id'") if exists $fc_by_id{$id};
  fail("fact_checks[$i].candidate_slot '$slot' not in candidate_set") unless exists $got_cands{$slot};
  fail("fact_checks[$i].status '$st' invalid") unless $VALID_FC_STATUS{$st};
  if ($st eq 'CONFIRMED' || $st eq 'REFUTED') {
    fail("fact_checks[$i] ($id) with status $st must provide non-empty file_line_evidence") unless $ev =~ /\S/;
    fail("fact_checks[$i] ($id) file_line_evidence must cite a concrete file/line or path")
      unless $ev =~ /(?:[A-Za-z0-9_.\-\/]+\.[A-Za-z0-9_]+(?::\d+)?|:[0-9]+)/;
  }
  $fc_by_id{$id} = { id => $id, candidate_slot => $slot, claim => $clm, status => $st, file_line_evidence => $ev };
}

# 3. Validate 12-axis matrix.
my @AXES = qw(
  architecture_fit ssot_invariants hidden_callers migration_compat
  real_entrypoint_tests abstraction_restraint prd_scope_fidelity
  rollback_viability unique_risks key_assumptions dependency_order
  failure_recovery_acceptance
);
my %VALID_RATING = map { $_ => 1 } qw(strong acceptable weak);
my $amat = req_obj($top->{axis_matrix}, 'axis_matrix', \@AXES, []);
for my $axis (@AXES) {
  my $row = req_obj($amat->{$axis}, "axis_matrix.$axis", [sort keys %got_cands], []);
  for my $slot (sort keys %got_cands) {
    my $cell = req_obj($row->{$slot}, "axis_matrix.$axis.$slot", [qw(rating evidence_note)], []);
    my $r = req_str($cell->{rating}, "axis_matrix.$axis.$slot.rating", 1);
    fail("axis_matrix.$axis.$slot.rating '$r' invalid") unless $VALID_RATING{$r};
    req_str($cell->{evidence_note}, "axis_matrix.$axis.$slot.evidence_note", 1);
  }
}

# 4. Validate primary_winner & eliminated.
my $winner = req_str($top->{primary_winner}, 'primary_winner', 1);
fail("primary_winner '$winner' is not in candidate_set") unless exists $got_cands{$winner};
req_str($top->{winner_rationale}, 'winner_rationale', 1);

my $elim_arr = req_arr($top->{eliminated}, 'eliminated', 0);
my %elim_seen;
for my $i (0 .. $#$elim_arr) {
  my $e = req_obj($elim_arr->[$i], "eliminated[$i]", [qw(slot rationale)], []);
  my $s = req_str($e->{slot}, "eliminated[$i].slot", 1);
  req_str($e->{rationale}, "eliminated[$i].rationale", 1);
  fail("eliminated[$i].slot '$s' not in candidate_set") unless exists $got_cands{$s};
  fail("primary_winner '$s' cannot appear in eliminated") if $s eq $winner;
  fail("duplicate slot '$s' in eliminated") if $elim_seen{$s}++;
}
for my $s (sort keys %got_cands) {
  next if $s eq $winner;
  fail("non-winning candidate '$s' missing from eliminated") unless $elim_seen{$s};
}

# 5. Validate cherry_picks (strict grounding to CONFIRMED fact_check of same source_slot).
my $cp_arr = req_arr($top->{cherry_picks}, 'cherry_picks', 0);
for my $i (0 .. $#$cp_arr) {
  my $cp = req_obj(
    $cp_arr->[$i],
    "cherry_picks[$i]",
    [qw(source_slot gap_description evidence_fact_check_id evidence_quote compatible_with_winner_architecture)],
    []
  );
  my $sslot = req_str($cp->{source_slot}, "cherry_picks[$i].source_slot", 1);
  my $gap   = req_str($cp->{gap_description}, "cherry_picks[$i].gap_description", 1);
  my $fcid  = req_str($cp->{evidence_fact_check_id}, "cherry_picks[$i].evidence_fact_check_id", 1);
  my $quote = req_str($cp->{evidence_quote}, "cherry_picks[$i].evidence_quote", 1);
  req_bool_true($cp->{compatible_with_winner_architecture}, "cherry_picks[$i].compatible_with_winner_architecture");

  fail("cherry_picks[$i].source_slot '$sslot' not in candidate_set") unless exists $got_cands{$sslot};
  fail("cherry_picks[$i].source_slot '$sslot' cannot equal primary_winner") if $sslot eq $winner;
  my $fc = $fc_by_id{$fcid};
  fail("cherry_picks[$i].evidence_fact_check_id '$fcid' not found in fact_checks") unless $fc;
  fail("cherry_picks[$i] references fact_check '$fcid' belonging to '$fc->{candidate_slot}', not source_slot '$sslot'")
    unless $fc->{candidate_slot} eq $sslot;
  fail("cherry_picks[$i] references fact_check '$fcid' with status '$fc->{status}' (must be CONFIRMED)")
    unless $fc->{status} eq 'CONFIRMED';

  # Verify evidence_quote actually anchors to the referenced fact_check's claim or file_line_evidence
  # (supporting both ASCII file:line tokens and Unicode/CJK terms).
  my $haystack = lc("$fc->{claim} $fc->{file_line_evidence}");
  my $qnorm    = lc($quote);
  $qnorm =~ s/^\s+|\s+$//g;
  my $aligned = 0;
  if (index($haystack, $qnorm) >= 0) {
    $aligned = 1;
  } else {
    my @tokens = grep { length($_) >= 4 || /\p{Han}{2,}/ } ($qnorm =~ /([\p{Alnum}_.\-\/]+(?::\d+)?)/g);
    my $hits = 0;
    my %seen_t;
    for my $t (@tokens) {
      next if $seen_t{$t}++;
      $hits++ if index($haystack, $t) >= 0;
    }
    $aligned = 1 if @tokens > 0 && $hits >= 1;
  }
  fail("cherry_picks[$i].evidence_quote does not align with referenced fact_check '$fcid'") unless $aligned;
}

# 6. Validate rejected_ideas.
my $rej_arr = req_arr($top->{rejected_ideas}, 'rejected_ideas', 0);
for my $i (0 .. $#$rej_arr) {
  my $r = req_obj($rej_arr->[$i], "rejected_ideas[$i]", [qw(source_slot idea reason)], []);
  my $sslot = req_str($r->{source_slot}, "rejected_ideas[$i].source_slot", 1);
  fail("rejected_ideas[$i].source_slot '$sslot' not in candidate_set") unless exists $got_cands{$sslot};
  req_str($r->{idea}, "rejected_ideas[$i].idea", 1);
  req_str($r->{reason}, "rejected_ideas[$i].reason", 1);
}

# 7. Validate product_forks & product_decisions.
my $pf_arr = req_arr($top->{product_forks}, 'product_forks', 0);
for my $i (0 .. $#$pf_arr) {
  my $pf = req_obj($pf_arr->[$i], "product_forks[$i]", [qw(id question options trade_offs)], []);
  req_str($pf->{id}, "product_forks[$i].id", 1);
  req_str($pf->{question}, "product_forks[$i].question", 1);
  my $opts = req_arr($pf->{options}, "product_forks[$i].options", 2);
  for my $j (0 .. $#$opts) { req_str($opts->[$j], "product_forks[$i].options[$j]", 1); }
  req_str($pf->{trade_offs}, "product_forks[$i].trade_offs", 1);
}
if (!$allow_forks && @$pf_arr > 0) {
  fail("product_forks must be resolved and empty before locking Phase 2a (" . scalar(@$pf_arr) . " unresolved)");
}

my $pd_arr = req_arr($top->{product_decisions}, 'product_decisions', 0);
for my $i (0 .. $#$pd_arr) {
  my $pd = req_obj($pd_arr->[$i], "product_decisions[$i]", [qw(fork_id chosen_option user_answer)], []);
  req_str($pd->{fork_id}, "product_decisions[$i].fork_id", 1);
  req_str($pd->{chosen_option}, "product_decisions[$i].chosen_option", 1);
  req_str($pd->{user_answer}, "product_decisions[$i].user_answer", 1);
}

# 8. Validate frozen anonymous Markdown deliverables.
req_str($top->{synthesis_body_markdown}, 'synthesis_body_markdown', 1);
req_str($top->{initial_design_markdown}, 'initial_design_markdown', 1);

my $unwrapped = unwrap_typed($root);
my $canon = encode_canonical($unwrapped);
my $sha = sha256_hex($canon);

if (defined $write_canon) {
  my ($tmp, $oh);
  for (1 .. 16) {
    $tmp = "$write_canon.tmp.$$." . int(rand(10000000));
    last if sysopen($oh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644);
    $oh = undef;
  }
  fail("cannot create temp file for $write_canon: $!") unless $oh;
  binmode($oh, ':raw');
  print $oh $canon or do { close $oh; unlink $tmp; fail("cannot write $tmp: $!"); };
  close $oh or do { unlink $tmp; fail("cannot close $tmp: $!"); };
  rename($tmp, $write_canon) or do { unlink $tmp; fail("cannot rename $tmp to $write_canon: $!"); };
}

print "VALID=1\n";
print "WINNER=$winner\n";
print "CHERRY_PICKS=" . scalar(@$cp_arr) . "\n";
print "FORKS=" . scalar(@$pf_arr) . "\n";
print "SHA256=$sha\n";
exit 0;
