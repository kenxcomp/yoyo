#!/usr/bin/perl
# parse-review.pl — strict fail-closed JSON validator and renderer for t3-cr-loop (v1.0.0).
#
# Modes:
#   1) Validate one child reviewer reply (bare JSON or single ```json ... ``` fence, zero extra prose):
#      parse-review.pl --validate-only <input> [--allow-sources] [--write-canonical <out.json>]
#
#   2) Validate merged/single round result and render ledger-fragment + review.md:
#      parse-review.pl <result.json> <next_class_id> <ledger.md> <fragment_out> <review_md_out> [--allow-sources]
#
# Strict recursive-descent JSON parser:
# - Rejects duplicate JSON object keys
# - Rejects extra keys (additionalProperties: false)
# - Rejects numbers/booleans/null where strings are required
# - Rejects duplicate non-empty `reopens` ids within one result (multiple "" new classes allowed)
# - Rejects prose outside a single JSON object or single ```json fence
use strict;
use utf8;
use warnings;
use Encode ();
binmode STDOUT, ":encoding(UTF-8)";

sub fail { print "ERROR=$_[0]\n"; exit 5; }

my $validate_only = 0;
my $allow_sources = 0;
my $write_canon   = '';
my @pos_args;
while (@ARGV) {
  my $a = shift @ARGV;
  if    ($a eq '--validate-only')   { $validate_only = 1; }
  elsif ($a eq '--allow-sources')   { $allow_sources = 1; }
  elsif ($a eq '--write-canonical') { $write_canon = shift @ARGV // fail('--write-canonical requires a path'); }
  else { push @pos_args, $a; }
}

my ($in, $next_id, $ledger, $frag_out, $md_out);
if ($validate_only) {
  @pos_args == 1 or fail('usage: parse-review.pl --validate-only <input> [--allow-sources] [--write-canonical <out.json>]');
  ($in) = @pos_args;
} else {
  @pos_args == 5 or fail('usage: parse-review.pl <result.json> <next_id> <ledger> <fragment_out> <review_md_out> [--allow-sources]');
  ($in, $next_id, $ledger, $frag_out, $md_out) = @pos_args;
  $next_id =~ /\A\d+\z/ or fail('next_class_id must be an integer');
}

open(my $fh, '<:raw', $in) or fail("cannot read $in");
my $raw_bytes = do { local $/; <$fh> };
close $fh;
$raw_bytes = '' unless defined $raw_bytes;
my $src = eval { Encode::decode('UTF-8', $raw_bytes, Encode::FB_CROAK) };
fail('result is not valid UTF-8') if $@ || !defined $src;

# Trim leading/trailing whitespace; allow a single ```json ... ``` fence ONLY if
# there is no prose outside the fence.
$src =~ s/\A\s+//;
$src =~ s/\s+\z//;
if ($src =~ /\A```(?:json)?[ \t]*\r?\n(.*?)\r?\n```\z/s) {
  $src = $1;
}

# --- Strict recursive-descent JSON parser ---
my $pos = 0;
my $len = length($src);

sub skip_ws { $pos++ while $pos < $len && substr($src, $pos, 1) =~ /[ \t\r\n]/; }

sub parse_string {
  substr($src, $pos, 1) eq '"' or fail('expected JSON string');
  $pos++;
  my $out = '';
  while ($pos < $len) {
    my $ch = substr($src, $pos, 1);
    if ($ch eq '"') { $pos++; return ['str', $out]; }
    if ($ch eq '\\') {
      $pos++;
      $pos < $len or fail('unterminated escape in JSON string');
      my $esc = substr($src, $pos, 1);
      $pos++;
      if    ($esc eq '"')  { $out .= '"'; }
      elsif ($esc eq '\\') { $out .= '\\'; }
      elsif ($esc eq '/')  { $out .= '/'; }
      elsif ($esc eq 'b')  { $out .= "\b"; }
      elsif ($esc eq 'f')  { $out .= "\f"; }
      elsif ($esc eq 'n')  { $out .= "\n"; }
      elsif ($esc eq 'r')  { $out .= "\r"; }
      elsif ($esc eq 't')  { $out .= "\t"; }
      elsif ($esc eq 'u')  {
        $pos + 4 <= $len or fail('truncated \\u escape in JSON string');
        my $hex = substr($src, $pos, 4);
        $hex =~ /\A[0-9a-fA-F]{4}\z/ or fail('invalid \\u escape in JSON string');
        $pos += 4;
        my $cp = hex($hex);
        if ($cp >= 0xD800 && $cp <= 0xDBFF) {
          ($pos + 6 <= $len && substr($src, $pos, 2) eq '\\u') or fail('unpaired high surrogate');
          my $hex2 = substr($src, $pos + 2, 4);
          $hex2 =~ /\A[0-9a-fA-F]{4}\z/ or fail('invalid low surrogate escape');
          my $cp2 = hex($hex2);
          ($cp2 >= 0xDC00 && $cp2 <= 0xDFFF) or fail('invalid surrogate pair');
          $pos += 6;
          $cp = 0x10000 + (($cp - 0xD800) << 10) + ($cp2 - 0xDC00);
        } elsif ($cp >= 0xDC00 && $cp <= 0xDFFF) {
          fail('unpaired low surrogate');
        }
        $out .= chr($cp);
      } else { fail("invalid escape \\$esc"); }
    } else {
      fail('unescaped control character in JSON string') if ord($ch) < 0x20;
      $out .= $ch;
      $pos++;
    }
  }
  fail('unterminated JSON string');
}

sub parse_value {
  skip_ws();
  $pos < $len or fail('unexpected end of JSON input');
  my $ch = substr($src, $pos, 1);
  return parse_string() if $ch eq '"';
  if ($ch eq '{') {
    $pos++;
    my %obj;
    skip_ws();
    if ($pos < $len && substr($src, $pos, 1) eq '}') { $pos++; return ['obj', \%obj]; }
    while (1) {
      skip_ws();
      ($pos < $len && substr($src, $pos, 1) eq '"') or fail('expected string key in JSON object');
      my $k = parse_string()->[1];
      fail("duplicate JSON object key '$k'") if exists $obj{$k};
      skip_ws();
      ($pos < $len && substr($src, $pos, 1) eq ':') or fail("expected ':' after key '$k'");
      $pos++;
      $obj{$k} = parse_value();
      skip_ws();
      $pos < $len or fail('unterminated JSON object');
      my $sep = substr($src, $pos, 1);
      if ($sep eq '}') { $pos++; return ['obj', \%obj]; }
      $sep eq ',' or fail("expected ',' or '}' in JSON object");
      $pos++;
    }
  }
  if ($ch eq '[') {
    $pos++;
    my @arr;
    skip_ws();
    if ($pos < $len && substr($src, $pos, 1) eq ']') { $pos++; return ['arr', \@arr]; }
    while (1) {
      push @arr, parse_value();
      skip_ws();
      $pos < $len or fail('unterminated JSON array');
      my $sep = substr($src, $pos, 1);
      if ($sep eq ']') { $pos++; return ['arr', \@arr]; }
      $sep eq ',' or fail("expected ',' or ']' in JSON array");
      $pos++;
    }
  }
  if (substr($src, $pos, 4) eq 'true')  { $pos += 4; return ['bool', 1]; }
  if (substr($src, $pos, 5) eq 'false') { $pos += 5; return ['bool', 0]; }
  if (substr($src, $pos, 4) eq 'null')  { $pos += 4; return ['null', undef]; }
  my $rest = substr($src, $pos);
  if ($rest =~ /\A(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/) {
    $pos += length($1);
    return ['num', $1];
  }
  fail('result is not valid JSON (expected strict schema JSON object)');
}

my $root_node = parse_value();
skip_ws();
fail('trailing content after JSON object') if $pos < $len;
$root_node->[0] eq 'obj' or fail('result is not a JSON object');
my $r = $root_node->[1];

sub check_keys {
  my ($obj, $what, $req_ref, $opt_ref) = @_;
  my %allowed = map { $_ => 1 } (@$req_ref, @$opt_ref);
  for my $k (@$req_ref) { fail("missing required field $what.$k") unless exists $obj->{$k}; }
  for my $k (sort keys %$obj) { fail("unexpected field $what.$k (additionalProperties is false)") unless $allowed{$k}; }
}

sub str_node { my ($n, $w) = @_; (defined $n && $n->[0] eq 'str') or fail("$w must be a string"); return $n->[1]; }
sub arr_node { my ($n, $w) = @_; (defined $n && $n->[0] eq 'arr') or fail("$w must be an array"); return @{$n->[1]}; }
sub obj_node { my ($n, $w) = @_; (defined $n && $n->[0] eq 'obj') or fail("$w must be an object"); return $n->[1]; }
sub one_line { my $s = shift; $s =~ s/\s*\n\s*/ /g; return $s; }

sub parse_sources {
  my ($obj, $what) = @_;
  return () unless exists $obj->{sources};
  my @srcs = map { one_line(str_node($_, "$what.sources[]")) } arr_node($obj->{sources}, "$what.sources");
  @srcs or fail("$what.sources must not be empty when present");
  for my $s (@srcs) { $s =~ /\S/ or fail("$what.sources[] must not be blank"); }
  return @srcs;
}

sub validate_merged_meta {
  my ($obj, $what) = @_;
  if (exists $obj->{merged_from}) {
    my @refs = arr_node($obj->{merged_from}, "$what.merged_from");
    @refs or fail("$what.merged_from must not be empty when present");
    my $ri = 0;
    for my $rn (@refs) {
      $ri++;
      my $ro = obj_node($rn, "$what.merged_from[$ri]");
      check_keys($ro, "$what.merged_from[$ri]", [qw(slot index)], []);
      my $rs = one_line(str_node($ro->{slot}, "$what.merged_from[$ri].slot"));
      $rs =~ /\S/ or fail("$what.merged_from[$ri].slot must not be blank");
      my $idx_n = $ro->{index};
      (defined $idx_n && $idx_n->[0] eq 'num' && $idx_n->[1] =~ /\A(?:0|[1-9][0-9]*)\z/)
        or fail("$what.merged_from[$ri].index must be a non-negative integer");
    }
  }
  if (exists $obj->{merge_rationale}) {
    str_node($obj->{merge_rationale}, "$what.merge_rationale");
  }
}

check_keys($r, 'root', [qw(summary verdict findings step_back out_of_scope)], []);
my $summary   = str_node($r->{summary}, 'summary');
my $verdict   = str_node($r->{verdict}, 'verdict');
($verdict eq 'clean' || $verdict eq 'findings') or fail("verdict must be clean|findings (got '$verdict')");
my @findings  = arr_node($r->{findings}, 'findings');
my @step_back = arr_node($r->{step_back}, 'step_back');
my @oos       = arr_node($r->{out_of_scope}, 'out_of_scope');

if ($verdict eq 'clean' && @findings)     { fail('verdict is clean but findings is not empty'); }
if ($verdict eq 'findings' && !@findings) { fail('verdict is findings but findings is empty'); }

my @opt_src    = $allow_sources ? ('sources') : ();
my @opt_merged = $allow_sources ? ('sources', 'merged_from', 'merge_rationale') : ();
my %known;
if (!$validate_only && open(my $lf, '<:encoding(UTF-8)', $ledger)) {
  while (<$lf>) { $known{$1} = 1 if /^### (C\d+)\b/; }
  close $lf;
}

my %count = (P0 => 0, P1 => 0, P2 => 0, P3 => 0);
my %seen_reopens;
my (@new, @reopened, @md_find, @frag_find);
my $i = 0;
for my $fn (@findings) {
  $i++;
  my $f = obj_node($fn, "findings[$i]");
  check_keys($f, "findings[$i]", [qw(severity reopens title location pattern still_wrong instances fix prevent)], \@opt_merged);
  my $sev = str_node($f->{severity}, "findings[$i].severity");
  exists $count{$sev} or fail("findings[$i].severity must be P0..P3 (got '$sev')");
  my $reopens = str_node($f->{reopens}, "findings[$i].reopens");
  $reopens =~ /\A(?:C\d+)?\z/ or fail("findings[$i].reopens must be '' or a ledger id like C3 (got '$reopens')");
  if (length $reopens) {
    fail("duplicate reopens id '$reopens' in the same round") if $seen_reopens{$reopens}++;
  }
  my %s;
  for my $k (qw(title location pattern still_wrong fix prevent)) {
    $s{$k} = one_line(str_node($f->{$k}, "findings[$i].$k"));
  }
  length $s{title} or fail("findings[$i].title is empty");
  my @inst = map { one_line(str_node($_, "findings[$i].instances[]")) } arr_node($f->{instances}, "findings[$i].instances");
  @inst or fail("findings[$i].instances is empty — every class must list its instances");
  my @srcs = parse_sources($f, "findings[$i]");
  validate_merged_meta($f, "findings[$i]");
  $count{$sev}++;

  if (!$validate_only) {
    my ($id, $hdr_md, $hdr_frag);
    my $src_tag = @srcs ? ' [' . join(', ', @srcs) . ']' : '';
    if (length $reopens && $known{$reopens}) {
      $id = $reopens; push @reopened, $id;
      $hdr_md   = "- [$sev] [$id] $s{title} — $s{location}$src_tag";
      $hdr_frag = "### $id (reopened) [$sev] $s{title} — $s{location}$src_tag";
    } else {
      $id = 'C' . $next_id++; push @new, $id;
      my $note = length $reopens ? " (cited unknown id $reopens)" : '';
      $hdr_md   = "- [$sev] $s{title} — $s{location}$src_tag";
      $hdr_frag = "### $id [$sev] $s{title} — $s{location}$src_tag$note";
    }
    my @body = ("  Pattern: $s{pattern}");
    push @body, "  Still wrong: $s{still_wrong}" if length $s{still_wrong};
    push @body, '  Instances: ' . join(', ', @inst), "  Fix: $s{fix}", "  Prevent: $s{prevent}";
    push @md_find, join("\n", $hdr_md, @body);
    push @frag_find, join("\n", $hdr_frag, @body);
  }
}

my @sb_lines;
my $j = 0;
for my $sn (@step_back) {
  $j++;
  my $s = obj_node($sn, "step_back[$j]");
  check_keys($s, "step_back[$j]", [qw(classes name invites_because approach_change prevent)], \@opt_merged);
  my @ids = map { one_line(str_node($_, "step_back[$j].classes[]")) } arr_node($s->{classes}, "step_back[$j].classes");
  my %v;
  for my $k (qw(name invites_because approach_change prevent)) {
    $v{$k} = one_line(str_node($s->{$k}, "step_back[$j].$k"));
  }
  my @srcs = parse_sources($s, "step_back[$j]");
  validate_merged_meta($s, "step_back[$j]");
  my $src_tag = @srcs ? ' (sources: ' . join(', ', @srcs) . ')' : '';
  push @sb_lines, '- [' . join(', ', @ids) . "] $v{name}$src_tag — Invites it because: $v{invites_because} — Approach change: $v{approach_change} — Prevent: $v{prevent}";
}

my @oos_lines;
my $k = 0;
for my $on (@oos) {
  $k++;
  my $o = obj_node($on, "out_of_scope[$k]");
  check_keys($o, "out_of_scope[$k]", [qw(location note)], \@opt_src);
  my @srcs = parse_sources($o, "out_of_scope[$k]");
  my $src_tag = @srcs ? ' [' . join(', ', @srcs) . ']' : '';
  push @oos_lines, '  ' . one_line(str_node($o->{location}, "out_of_scope[$k].location")) . ' — ' . one_line(str_node($o->{note}, "out_of_scope[$k].note")) . $src_tag;
}

if (length $write_canon) {
  open(my $co, '>:encoding(UTF-8)', $write_canon) or fail("cannot write $write_canon");
  print $co $src, "\n" or fail("cannot write $write_canon");
  close $co or fail("cannot close $write_canon");
}

my $total = $count{P0} + $count{P1} + $count{P2} + $count{P3};
if ($validate_only) {
  print "VALID=1\nVERDICT=$verdict\nP0=$count{P0}\nP1=$count{P1}\nP2=$count{P2}\nP3=$count{P3}\nTOTAL=$total\n";
  exit 0;
}

my @md = ('# T3 Review', '', $summary, '');
push @md, '## Step-back assessment', '', @sb_lines, '' if @sb_lines;
if (@md_find) { push @md, 'Review comment:', '', join("\n\n", @md_find), ''; }
push @md, 'Out of scope (pre-existing, not counted):', @oos_lines, '' if @oos_lines;
push @md, 'did not find any definite correctness bugs.' if $verdict eq 'clean';

my @frag;
push @frag, @frag_find;
push @frag, '#### Step-back assessment', @sb_lines if @sb_lines;
push @frag, '#### Out of scope (pre-existing, not counted)', @oos_lines if @oos_lines;

open(my $mo, '>:encoding(UTF-8)', $md_out) or fail("cannot write $md_out");
print $mo join("\n", @md), "\n" or fail("cannot write $md_out");
close $mo or fail("cannot close $md_out");
open(my $fo, '>:encoding(UTF-8)', $frag_out) or fail("cannot write $frag_out");
print $fo join("\n", @frag), (@frag ? "\n" : '') or fail("cannot write $frag_out");
close $fo or fail("cannot close $frag_out");

print "P0=$count{P0}\nP1=$count{P1}\nP2=$count{P2}\nP3=$count{P3}\nTOTAL=$total\n";
print 'NEW=' . join(',', @new) . "\nREOPENED=" . join(',', @reopened) . "\nNEXT=$next_id\n";
exit 0;
