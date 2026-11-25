#!/usr/bin/env perl
# parse-design-review.pl — Strict structural + semantic validator and Markdown renderer
# for t3-tri-plan Phase 3 design-review outputs (individual reviewers and merged council rounds).

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

my ($input_path, $expected_mode, $expected_sha, $ledger_manifest_path, $is_merged, $write_canon, $render_md);
$is_merged = 0;

while (@ARGV) {
  my $a = shift @ARGV;
  if    ($a eq '--input')               { $input_path           = shift @ARGV; }
  elsif ($a eq '--expected-mode')       { $expected_mode        = shift @ARGV; }
  elsif ($a eq '--expected-design-sha') { $expected_sha         = shift @ARGV; }
  elsif ($a eq '--ledger-manifest')     { $ledger_manifest_path = shift @ARGV; }
  elsif ($a eq '--merged')              { $is_merged            = 1; }
  elsif ($a eq '--write-canonical')     { $write_canon          = shift @ARGV; }
  elsif ($a eq '--render-md')           { $render_md            = shift @ARGV; }
  else                                  { fail("unknown arg: $a"); }
}

fail("--input is required") unless defined $input_path && -f $input_path;

my $known_classes = {};
my $rule_files    = {};
my $rules_index   = {};
if (defined $ledger_manifest_path) {
  fail("ledger-manifest not found: $ledger_manifest_path") unless -f $ledger_manifest_path;
  my $lm = eval { load_json_file($ledger_manifest_path) };
  fail("invalid ledger-manifest: $@") if $@ || ref $lm ne 'HASH';
  $known_classes = $lm->{known_classes} if ref($lm->{known_classes}) eq 'HASH';
  $rule_files    = $lm->{rule_files}    if ref($lm->{rule_files})    eq 'HASH';
  $rules_index   = $lm->{rules_index}   if ref($lm->{rules_index})   eq 'HASH';
}

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

my @TOP_REQ = qw(summary mode reviewed_design_sha256 verdict findings verified step_back out_of_scope);
my @TOP_OPT = $is_merged ? ('disputes') : ();
my $top = req_obj($root, 'root', \@TOP_REQ, \@TOP_OPT);

req_str($top->{summary}, 'summary', 1);
my $mode = req_str($top->{mode}, 'mode', 1);
fail("invalid mode '$mode'") unless $mode eq 'full' || $mode eq 'incremental' || $mode eq 'step-back';
if (defined $expected_mode && $mode ne $expected_mode) {
  fail("mode mismatch: got '$mode', expected '$expected_mode'");
}

my $rsha = req_str($top->{reviewed_design_sha256}, 'reviewed_design_sha256', 1);
fail("reviewed_design_sha256 must be 64-char lowercase hex") unless $rsha =~ /\A[0-9a-f]{64}\z/;
if (defined $expected_sha && $rsha ne $expected_sha) {
  fail("reviewed_design_sha256 mismatch: got '$rsha', expected '$expected_sha'");
}

my $verdict = req_str($top->{verdict}, 'verdict', 1);
fail("invalid verdict '$verdict'") unless $verdict eq 'clean' || $verdict eq 'findings';

my %VALID_SEV = map { $_ => 1 } qw(BLOCKER SHOULD_FIX OPTIONAL);
my @F_REQ = qw(severity reopens title location pattern still_wrong instances fix prevent evidence violates_review_md_rule);
my @F_OPT = $is_merged ? qw(sources dispute_note) : ();

my $findings_arr = req_arr($top->{findings}, 'findings', 0);
my %reopened_seen;
my ($blocker_cnt, $should_fix_cnt, $optional_cnt) = (0, 0, 0);

for my $i (0 .. $#$findings_arr) {
  my $f = req_obj($findings_arr->[$i], "findings[$i]", \@F_REQ, \@F_OPT);
  my $sev = req_str($f->{severity}, "findings[$i].severity", 1);
  fail("findings[$i].severity '$sev' invalid") unless $VALID_SEV{$sev};
  $blocker_cnt++    if $sev eq 'BLOCKER';
  $should_fix_cnt++ if $sev eq 'SHOULD_FIX';
  $optional_cnt++   if $sev eq 'OPTIONAL';

  my $reopens = req_str($f->{reopens}, "findings[$i].reopens", 0);
  my $sw      = req_str($f->{still_wrong}, "findings[$i].still_wrong", 0);
  req_str($f->{title}, "findings[$i].title", 1);
  req_str($f->{location}, "findings[$i].location", 1);
  req_str($f->{pattern}, "findings[$i].pattern", 1);
  req_str($f->{fix}, "findings[$i].fix", 1);
  req_str($f->{prevent}, "findings[$i].prevent", 1);
  req_str($f->{evidence}, "findings[$i].evidence", 1);

  my $insts = req_arr($f->{instances}, "findings[$i].instances", 1);
  for my $j (0 .. $#$insts) {
    req_str($insts->[$j], "findings[$i].instances[$j]", 1);
  }

  if (length $reopens) {
    fail("UNKNOWN_REOPEN: findings[$i].reopens '$reopens' does not exist in frozen ledger")
      if defined $ledger_manifest_path && !exists $known_classes->{$reopens};
    fail("DUPLICATE_REOPEN: class '$reopens' reopened more than once in one output")
      if $reopened_seen{$reopens}++;
    fail("MISSING_STILL_WRONG: findings[$i] reopens '$reopens' without non-empty still_wrong")
      unless $sw =~ /\S/;
  } else {
    fail("findings[$i].still_wrong must be empty when reopens is empty") if $sw =~ /\S/;
  }

  my $vrule = req_str($f->{violates_review_md_rule}, "findings[$i].violates_review_md_rule", 0);
  if (length $vrule) {
    fail("findings[$i].violates_review_md_rule '$vrule' must have format <path>#<anchor>")
      unless $vrule =~ /\A([^#\s]+)#([^\s#]+)\z/;
    my ($rpath, $ranchor) = ($1, $2);
    if (defined $ledger_manifest_path) {
      fail("UNKNOWN_RULE_FILE: findings[$i].violates_review_md_rule cites '$rpath' which is not in frozen baseline rule files")
        unless $rule_files->{$rpath};
      my $has_anchors_for_file = grep { index($_, "$rpath#") == 0 } keys %$rules_index;
      if ($has_anchors_for_file && !$rules_index->{$vrule}) {
        fail("UNKNOWN_RULE_ANCHOR: findings[$i].violates_review_md_rule '$vrule' not found in frozen baseline rule index");
      }
    }
  }

  if ($is_merged && exists $f->{sources}) {
    my $srcs = req_arr($f->{sources}, "findings[$i].sources", 1);
    for my $j (0 .. $#$srcs) { req_str($srcs->[$j], "findings[$i].sources[$j]", 1); }
  }
  if ($is_merged && exists $f->{dispute_note}) {
    req_str($f->{dispute_note}, "findings[$i].dispute_note", 0);
  }
}

# Validate verified[].
my $ver_arr = req_arr($top->{verified}, 'verified', 0);
my %verified_seen;
my @V_OPT = $is_merged ? qw(sources dispute_note) : ();
for my $i (0 .. $#$ver_arr) {
  my $v = req_obj($ver_arr->[$i], "verified[$i]", [qw(id note)], \@V_OPT);
  my $id = req_str($v->{id}, "verified[$i].id", 1);
  req_str($v->{note}, "verified[$i].note", 1);
  if ($id ne 'V') {
    fail("UNKNOWN_VERIFIED: verified[$i].id '$id' does not exist in frozen ledger")
      if defined $ledger_manifest_path && !exists $known_classes->{$id};
    fail("CONTRADICTORY_VERIFIED_AND_REOPEN: class '$id' appears in both verified and findings.reopens")
      if $reopened_seen{$id};
    $verified_seen{$id}++;
  }
  if ($is_merged && exists $v->{sources}) {
    my $srcs = req_arr($v->{sources}, "verified[$i].sources", 1);
    for my $j (0 .. $#$srcs) { req_str($srcs->[$j], "verified[$i].sources[$j]", 1); }
  }
  if ($is_merged && exists $v->{dispute_note}) {
    req_str($v->{dispute_note}, "verified[$i].dispute_note", 0);
  }
}

# Validate step_back[].
my $sb_arr = req_arr($top->{step_back}, 'step_back', 0);
if ($mode ne 'step-back' && @$sb_arr > 0) {
  fail("step_back must be empty when mode is '$mode'");
}
for my $i (0 .. $#$sb_arr) {
  my $sb = req_obj($sb_arr->[$i], "step_back[$i]", [qw(classes name invites_because approach_change prevent)], []);
  my $cls = req_arr($sb->{classes}, "step_back[$i].classes", 1);
  for my $j (0 .. $#$cls) {
    my $cid = req_str($cls->[$j], "step_back[$i].classes[$j]", 1);
    fail("UNKNOWN_STEP_BACK_CLASS: step_back[$i].classes[$j] '$cid' does not exist in frozen ledger")
      if defined $ledger_manifest_path && !exists $known_classes->{$cid};
  }
  req_str($sb->{name}, "step_back[$i].name", 1);
  req_str($sb->{invites_because}, "step_back[$i].invites_because", 1);
  req_str($sb->{approach_change}, "step_back[$i].approach_change", 1);
  req_str($sb->{prevent}, "step_back[$i].prevent", 1);
}

# Validate out_of_scope[].
my $oos_arr = req_arr($top->{out_of_scope}, 'out_of_scope', 0);
for my $i (0 .. $#$oos_arr) {
  my $o = req_obj($oos_arr->[$i], "out_of_scope[$i]", [qw(location note)], []);
  req_str($o->{location}, "out_of_scope[$i].location", 1);
  req_str($o->{note}, "out_of_scope[$i].note", 1);
}

# Validate disputes[] (merged output only).
my $unresolved_disputes = 0;
if ($is_merged && exists $top->{disputes}) {
  my $disp_arr = req_arr($top->{disputes}, 'disputes', 0);
  my %VALID_POS = map { $_ => 1 } qw(reopen verified finding);
  my %VALID_RES = map { $_ => 1 } qw(reopen verified unresolved);
  for my $i (0 .. $#$disp_arr) {
    my $d = req_obj($disp_arr->[$i], "disputes[$i]", [qw(class_id reviewer_positions resolution code_evidence)], []);
    my $cid = req_str($d->{class_id}, "disputes[$i].class_id", 1);
    fail("UNKNOWN_DISPUTE_CLASS: disputes[$i].class_id '$cid' does not exist in frozen ledger")
      if defined $ledger_manifest_path && !exists $known_classes->{$cid};
    my $pos_arr = req_arr($d->{reviewer_positions}, "disputes[$i].reviewer_positions", 2);
    for my $j (0 .. $#$pos_arr) {
      my $p = req_obj($pos_arr->[$j], "disputes[$i].reviewer_positions[$j]", [qw(slot position evidence)], []);
      req_str($p->{slot}, "disputes[$i].reviewer_positions[$j].slot", 1);
      my $pv = req_str($p->{position}, "disputes[$i].reviewer_positions[$j].position", 1);
      fail("invalid dispute position '$pv'") unless $VALID_POS{$pv};
      req_str($p->{evidence}, "disputes[$i].reviewer_positions[$j].evidence", 1);
    }
    my $res = req_str($d->{resolution}, "disputes[$i].resolution", 1);
    fail("invalid dispute resolution '$res'") unless $VALID_RES{$res};
    my $cev = req_str($d->{code_evidence}, "disputes[$i].code_evidence", 0);
    if ($res eq 'unresolved') {
      $unresolved_disputes++;
    } elsif ($res eq 'reopen') {
      fail("disputes[$i] resolved as reopen must cite code_evidence") unless $cev =~ /\S/;
      fail("disputes[$i] resolved as reopen must include '$cid' in findings.reopens") unless $reopened_seen{$cid};
      fail("disputes[$i] resolved as reopen must exclude '$cid' from verified") if $verified_seen{$cid};
    } elsif ($res eq 'verified') {
      fail("disputes[$i] resolved as verified must cite code_evidence") unless $cev =~ /\S/;
      fail("disputes[$i] resolved as verified must include '$cid' in verified") unless $verified_seen{$cid};
      fail("disputes[$i] resolved as verified must exclude '$cid' from findings.reopens") if $reopened_seen{$cid};
    }
  }
}

# Verdict consistency.
my $has_blocking = ($blocker_cnt + $should_fix_cnt + $unresolved_disputes) > 0 ? 1 : 0;
if ($verdict eq 'clean' && $has_blocking) {
  fail("verdict is 'clean' despite BLOCKER/SHOULD_FIX findings or unresolved council disputes");
}
if ($verdict eq 'findings' && @$findings_arr == 0 && $unresolved_disputes == 0) {
  fail("verdict is 'findings' but findings and unresolved disputes are both empty");
}

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

if (defined $render_md) {
  my @md;
  push @md, "# Design Review ($unwrapped->{mode})";
  push @md, "";
  push @md, "- **Reviewed design SHA-256**: `$unwrapped->{reviewed_design_sha256}`";
  push @md, "- **Reported verdict**: `$unwrapped->{verdict}` | **Effective**: `" . ($has_blocking ? 'dirty' : 'clean') . "`";
  push @md, "- **Summary**: $unwrapped->{summary}";
  push @md, "";
  if (@{$unwrapped->{findings}}) {
    push @md, "## Findings";
    my $idx = 0;
    for my $f (@{$unwrapped->{findings}}) {
      $idx++;
      my $re = length($f->{reopens}) ? " [reopens $f->{reopens}]" : "";
      my $srcs = ($f->{sources} && @{$f->{sources}}) ? " (sources: " . join(', ', @{$f->{sources}}) . ")" : "";
      push @md, "### $idx. [$f->{severity}]$re $f->{title}$srcs";
      push @md, "- **Location**: $f->{location}";
      push @md, "- **Pattern**: $f->{pattern}";
      push @md, "- **Still wrong**: $f->{still_wrong}" if length($f->{still_wrong});
      push @md, "- **Instances**:";
      push @md, "  - $_" for @{$f->{instances}};
      push @md, "- **Fix**: $f->{fix}";
      push @md, "- **Prevent**: $f->{prevent}";
      push @md, "- **Evidence**: $f->{evidence}";
      push @md, "- **Violates REVIEW.md rule**: `$f->{violates_review_md_rule}`" if length($f->{violates_review_md_rule});
      push @md, "- **Dispute note**: $f->{dispute_note}" if defined $f->{dispute_note} && length($f->{dispute_note});
      push @md, "";
    }
  }
  if (@{$unwrapped->{step_back}}) {
    push @md, "## Step-Back Structural Analysis";
    for my $sb (@{$unwrapped->{step_back}}) {
      push @md, "### $sb->{name} (" . join(', ', @{$sb->{classes}}) . ")";
      push @md, "- **Why current approach invites it**: $sb->{invites_because}";
      push @md, "- **Structural approach change**: $sb->{approach_change}";
      push @md, "- **Prevent**: $sb->{prevent}";
      push @md, "";
    }
  }
  if ($unwrapped->{disputes} && @{$unwrapped->{disputes}}) {
    push @md, "## Council Disputes";
    for my $d (@{$unwrapped->{disputes}}) {
      push @md, "- **$d->{class_id}** → `$d->{resolution}`: $d->{code_evidence}";
    }
    push @md, "";
  }
  if (@{$unwrapped->{verified}}) {
    push @md, "## Verified";
    for my $v (@{$unwrapped->{verified}}) {
      push @md, "- **$v->{id}**: $v->{note}";
    }
    push @md, "";
  }
  if (@{$unwrapped->{out_of_scope}}) {
    push @md, "## Out of Scope";
    for my $o (@{$unwrapped->{out_of_scope}}) {
      push @md, "- **$o->{location}**: $o->{note}";
    }
    push @md, "";
  }
  my ($tmp, $mh);
  for (1 .. 16) {
    $tmp = "$render_md.tmp.$$." . int(rand(10000000));
    last if sysopen($mh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644);
    $mh = undef;
  }
  fail("cannot create temp file for $render_md: $!") unless $mh;
  binmode($mh, ':encoding(UTF-8)');
  print $mh join("\n", @md) . "\n" or do { close $mh; unlink $tmp; fail("cannot write $tmp: $!"); };
  close $mh or do { unlink $tmp; fail("cannot close $tmp: $!"); };
  rename($tmp, $render_md) or do { unlink $tmp; fail("cannot rename $tmp to $render_md: $!"); };
}

print "VALID=1\n";
print "EFFECTIVE_VERDICT=" . ($has_blocking ? 'dirty' : 'clean') . "\n";
print "HAS_STEP_BACK_ITEMS=" . (@$sb_arr > 0 ? 1 : 0) . "\n";
print "UNRESOLVED_DISPUTES=$unresolved_disputes\n";
print "BLOCKER_COUNT=$blocker_cnt\n";
print "SHOULD_FIX_COUNT=$should_fix_cnt\n";
print "OPTIONAL_COUNT=$optional_cnt\n";
print "SHA256=$sha\n";
exit 0;
