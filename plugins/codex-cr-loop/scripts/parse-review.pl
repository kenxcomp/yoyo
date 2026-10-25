#!/usr/bin/perl
# parse-review.pl — validate one codex-cr-loop review result (JSON, see
# ../references/review-output.schema.json) and render it.
#
# usage: parse-review.pl <result.json> <next_class_id> <ledger.md> <fragment_out> <review_md_out>
#
# stdout (key=value): P0= P1= P2= P3= TOTAL= NEW= REOPENED= NEXT=
# exit 0 = valid; exit 5 = invalid (prints ERROR=<reason>), nothing written.
#
# The verdict is taken from structured fields only. No prose is parsed, so
# headings, bold text, code fences or embedded sentences cannot change it.
use strict;
use utf8;
use warnings;
use JSON::PP ();
binmode STDOUT, ":encoding(UTF-8)";

my ($in, $next_id, $ledger, $frag_out, $md_out) = @ARGV;
sub fail { print "ERROR=$_[0]\n"; exit 5; }
@ARGV == 5 or fail('usage: parse-review.pl <result.json> <next_id> <ledger> <fragment_out> <review_md_out>');
$next_id =~ /^\d+$/ or fail("next_class_id must be an integer");

open(my $fh, '<:raw', $in) or fail("cannot read $in");
my $raw = do { local $/; <$fh> };
close $fh;
my $r = eval { JSON::PP->new->utf8->decode($raw) };
fail('result is not valid JSON (expected the --output-schema object): ' . (($@ // '') =~ s/\s+at \S+ line \d+.*//sr)) unless defined $r;
ref $r eq 'HASH' or fail('result is not a JSON object');

my %known;
if (open(my $lf, '<:encoding(UTF-8)', $ledger)) {
  while (<$lf>) { $known{$1} = 1 if /^### (C\d+)\b/; }
  close $lf;
}

sub str  { my ($v, $what) = @_; defined $v && !ref $v or fail("$what must be a string"); return $v; }
sub arr  { my ($v, $what) = @_; ref $v eq 'ARRAY' or fail("$what must be an array"); return @$v; }
sub one_line { my $s = shift; $s =~ s/\s*\n\s*/ /g; return $s; }

my $summary = str($r->{summary}, 'summary');
my $verdict = str($r->{verdict}, 'verdict');
$verdict =~ /^(clean|findings)$/ or fail("verdict must be clean|findings (got '$verdict')");
my @findings = arr($r->{findings}, 'findings');
my @step_back = arr($r->{step_back}, 'step_back');
my @oos = arr($r->{out_of_scope}, 'out_of_scope');

if ($verdict eq 'clean' && @findings) { fail('verdict is clean but findings is not empty'); }
if ($verdict eq 'findings' && !@findings) { fail('verdict is findings but findings is empty'); }

my %count = (P0 => 0, P1 => 0, P2 => 0, P3 => 0);
my (@new, @reopened, @md_find, @frag_find);
my $i = 0;
for my $f (@findings) {
  $i++;
  ref $f eq 'HASH' or fail("findings[$i] must be an object");
  my $sev = str($f->{severity}, "findings[$i].severity");
  $sev =~ /^P[0-3]$/ or fail("findings[$i].severity must be P0..P3 (got '$sev')");
  my $reopens = str($f->{reopens}, "findings[$i].reopens");
  $reopens =~ /^(C\d+)?$/ or fail("findings[$i].reopens must be '' or a ledger id like C3 (got '$reopens')");
  my %s;
  for my $k (qw(title location pattern still_wrong fix prevent)) { $s{$k} = one_line(str($f->{$k}, "findings[$i].$k")); }
  length $s{title} or fail("findings[$i].title is empty");
  my @inst = map { one_line(str($_, "findings[$i].instances[]")) } arr($f->{instances}, "findings[$i].instances");
  @inst or fail("findings[$i].instances is empty — every class must list its instances");
  $count{$sev}++;

  my ($id, $hdr_md, $hdr_frag);
  if (length $reopens && $known{$reopens}) {
    $id = $reopens; push @reopened, $id;
    $hdr_md = "- [$sev] [$id] $s{title} — $s{location}";
    $hdr_frag = "### $id (reopened) [$sev] $s{title} — $s{location}";
  } else {
    $id = 'C' . $next_id++; push @new, $id;
    my $note = length $reopens ? " (cited unknown id $reopens)" : '';
    $hdr_md = "- [$sev] $s{title} — $s{location}";
    $hdr_frag = "### $id [$sev] $s{title} — $s{location}$note";
  }
  my @body = ("  Pattern: $s{pattern}");
  push @body, "  Still wrong: $s{still_wrong}" if length $s{still_wrong};
  push @body, '  Instances: ' . join(', ', @inst), "  Fix: $s{fix}", "  Prevent: $s{prevent}";
  push @md_find, join("\n", $hdr_md, @body);
  push @frag_find, join("\n", $hdr_frag, @body);
}

my @sb_lines;
my $j = 0;
for my $s (@step_back) {
  $j++;
  ref $s eq 'HASH' or fail("step_back[$j] must be an object");
  my @ids = map { str($_, "step_back[$j].classes[]") } arr($s->{classes}, "step_back[$j].classes");
  my %v;
  for my $k (qw(name invites_because approach_change prevent)) { $v{$k} = one_line(str($s->{$k}, "step_back[$j].$k")); }
  push @sb_lines, '- [' . join(', ', @ids) . "] $v{name} — Invites it because: $v{invites_because} — Approach change: $v{approach_change} — Prevent: $v{prevent}";
}

my @oos_lines;
my $k = 0;
for my $o (@oos) {
  $k++;
  ref $o eq 'HASH' or fail("out_of_scope[$k] must be an object");
  push @oos_lines, '  ' . one_line(str($o->{location}, "out_of_scope[$k].location")) . ' — ' . one_line(str($o->{note}, "out_of_scope[$k].note"));
}

# Human-readable review (same layout the protocol documents).
my @md = ('# Codex Review', '', $summary, '');
push @md, '## Step-back assessment', '', @sb_lines, '' if @sb_lines;
if (@md_find) { push @md, 'Review comment:', '', join("\n\n", @md_find), ''; }
push @md, 'Out of scope (pre-existing, not counted):', @oos_lines, '' if @oos_lines;
push @md, 'did not find any definite correctness bugs.' if $verdict eq 'clean';

my @frag;
push @frag, @frag_find;
push @frag, '#### Step-back assessment', @sb_lines if @sb_lines;
push @frag, '#### Out of scope (pre-existing, not counted)', @oos_lines if @oos_lines;

open(my $mo, '>:encoding(UTF-8)', $md_out) or fail("cannot write $md_out");
print $mo join("\n", @md), "\n";
close $mo;
open(my $fo, '>:encoding(UTF-8)', $frag_out) or fail("cannot write $frag_out");
print $fo join("\n", @frag), (@frag ? "\n" : '');
close $fo;

my $total = $count{P0} + $count{P1} + $count{P2} + $count{P3};
print "P0=$count{P0}\nP1=$count{P1}\nP2=$count{P2}\nP3=$count{P3}\nTOTAL=$total\n";
print 'NEW=' . join(',', @new) . "\nREOPENED=" . join(',', @reopened) . "\nNEXT=$next_id\n";
exit 0;
