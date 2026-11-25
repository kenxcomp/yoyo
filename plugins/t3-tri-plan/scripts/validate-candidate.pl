#!/usr/bin/env perl
# validate-candidate.pl — Fence-aware canonical section validator for t3-tri-plan Phase 1 candidates.
# Checks:
#   - Non-empty UTF-8 Markdown
#   - Rejects outer whole-document code fence wrapper (while allowing internal code blocks)
#   - Rejects unclosed fenced code blocks
#   - Verifies all 11 canonical numbered sections + Summary section exist in exact order,
#     with no duplicate canonical headings and non-empty body for every section.

use strict;
use warnings;
use utf8;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

my ($input_path, $write_canon);
while (@ARGV) {
  my $a = shift @ARGV;
  if    ($a eq '--input')           { $input_path  = shift @ARGV; }
  elsif ($a eq '--write-canonical') { $write_canon = shift @ARGV; }
  else                              { die "validate-candidate: unknown arg $a\n"; }
}

my $raw;
if (defined $input_path) {
  open(my $fh, '<:raw', $input_path) or fail("cannot read input file $input_path: $!");
  local $/;
  $raw = <$fh>;
  close $fh;
} else {
  binmode(STDIN, ':raw');
  local $/;
  $raw = <STDIN>;
}

fail("empty candidate output") unless defined $raw && length $raw;

my $text = eval { decode('UTF-8', $raw, FB_CROAK | LEAVE_SRC) };
fail("candidate is not valid UTF-8: $@") if $@;

$text =~ s/\r\n/\n/g;
$text =~ s/\r/\n/g;

my @lines = split(/\n/, $text, -1);

# Find first and last non-blank lines for outer-fence rejection.
my ($first_nb, $last_nb) = (-1, -1);
for my $i (0 .. $#lines) {
  if ($lines[$i] =~ /\S/) {
    $first_nb = $i if $first_nb < 0;
    $last_nb  = $i;
  }
}
fail("candidate contains only whitespace") if $first_nb < 0;

# Detect outer whole-document code fence: opens on first non-blank line and closes on last non-blank line
# (including when an LLM wraps a markdown doc containing internal 3-backtick blocks in outer ```markdown ... ```).
if ($lines[$first_nb] =~ /^\s*(`{3,}|~{3,})/) {
  my $fc = substr($1, 0, 1);
  my $fl = length($1);
  if ($lines[$last_nb] =~ /^\s*(\Q$fc\E{$fl,})\s*$/ && $last_nb > $first_nb) {
    my $closed_at = -1;
    for my $i (($first_nb + 1) .. $last_nb) {
      if ($lines[$i] =~ /^\s*(\Q$fc\E{$fl,})\s*$/) {
        $closed_at = $i;
        last;
      }
    }
    if ($closed_at == $last_nb) {
      fail("outer whole-document code fence wrapper is forbidden; return plain Markdown");
    }
    # Also catch outer ```markdown ... ``` wrapping internal ``` blocks (which leaves odd fence parity).
    if ($lines[$first_nb] =~ /^\s*`{3,}\s*(?:md|markdown)?\s*$/i) {
      my $fence_lines = 0;
      for my $i ($first_nb .. $last_nb) {
        $fence_lines++ if $lines[$i] =~ /^\s*`{3,}/;
      }
      if ($fence_lines % 2 == 0) {
        fail("outer whole-document code fence wrapper is forbidden; return plain Markdown");
      }
    }
  }
}

# Canonical sections required in exact order.
my @CANON = (
  { num => 1,  label => '1. Current architecture evidence',        re => qr/^##\s+1\.\s+(?:Current architecture evidence|.*(?:(?:architecture|架构|现状|代码).*(?:evidence|现状|证据)|(?:现状|证据).*(?:架构|代码)))/i },
  { num => 2,  label => '2. Proposed architecture',                re => qr/^##\s+2\.\s+(?:Proposed architecture|.*(?:proposed|推荐架构|建议架构|拟议架构|架构方案|设计方案|目标架构))/i },
  { num => 3,  label => '3. Data and control flow',                re => qr/^##\s+3\.\s+(?:Data and control flow|.*(?:data.*control|control flow|数据.*控制流|控制流))/i },
  { num => 4,  label => '4. Files/modules likely affected',        re => qr/^##\s+4\.\s+(?:Files\/modules likely affected|.*(?:(?:files|modules|文件|模块).*(?:affected|影响|变更|涉及)|(?:影响|变更|涉及).*(?:文件|模块)))/i },
  { num => 5,  label => '5. Callers and downstream consumers',     re => qr/^##\s+5\.\s+(?:Callers and downstream consumers|.*(?:callers|downstream|调用方|下游))/i },
  { num => 6,  label => '6. Data migration and compatibility',     re => qr/^##\s+6\.\s+(?:Data migration and compatibility|.*(?:migration|compat|迁移|兼容))/i },
  { num => 7,  label => '7. Testing strategy',                     re => qr/^##\s+7\.\s+(?:Testing strategy|.*(?:testing|test strategy|测试策略|测试))/i },
  { num => 8,  label => '8. Rollback strategy',                    re => qr/^##\s+8\.\s+(?:Rollback strategy|.*(?:rollback|回滚))/i },
  { num => 9,  label => '9. Risks and unknowns',                   re => qr/^##\s+9\.\s+(?:Risks and unknowns|.*(?:risks|unknowns|风险))/i },
  { num => 10, label => '10. Alternatives considered',             re => qr/^##\s+10\.\s+(?:Alternatives considered|.*(?:alternatives|备选))/i },
  { num => 11, label => '11. Recommended implementation sequence', re => qr/^##\s+11\.\s+(?:Recommended implementation sequence|.*(?:implementation sequence|实施顺序|实施步骤))/i },
  { num => 12, label => 'Summary',                                 re => qr/^##\s+(?:12\.\s+)?(?:Summary|摘要|总结)\b/i },
);

my $in_fence   = 0;
my $fence_char = '';
my $fence_len  = 0;

my @seen_order;
my %seen_num;
my %body_lines;
my $current_num = 0;

for my $idx (0 .. $#lines) {
  my $line = $lines[$idx];

  if ($in_fence) {
    $body_lines{$current_num}++ if $current_num > 0 && $line =~ /\S/;
    if ($line =~ /^\s*(\Q$fence_char\E{$fence_len,})\s*$/) {
      $in_fence   = 0;
      $fence_char = '';
      $fence_len  = 0;
    }
    next;
  }

  if ($line =~ /^\s*(`{3,}|~{3,})/) {
    my $marker = $1;
    my $rest   = substr($line, $+[0]);
    # CommonMark: backtick info string cannot contain backticks.
    if (substr($marker, 0, 1) ne '`' || $rest !~ /`/) {
      $in_fence   = 1;
      $fence_char = substr($marker, 0, 1);
      $fence_len  = length($marker);
      $body_lines{$current_num}++ if $current_num > 0;
      next;
    }
  }

  # Match top-level canonical H2 headings outside code fences.
  my $matched_num = 0;
  for my $sec (@CANON) {
    if ($line =~ $sec->{re}) {
      $matched_num = $sec->{num};
      last;
    }
  }

  if ($matched_num > 0) {
    if ($seen_num{$matched_num}++) {
      fail("duplicate canonical section: $CANON[$matched_num - 1]{label} (line " . ($idx + 1) . ")");
    }
    push @seen_order, $matched_num;
    $current_num = $matched_num;
    $body_lines{$current_num} = 0;
    next;
  }

  # Any non-canonical H2 resets current_num? No — subheadings or extra H2 inside a section are fine,
  # except numbered canonical headings out of set shouldn't mask empty bodies. Keep counting non-blank content.
  if ($current_num > 0 && $line =~ /\S/) {
    $body_lines{$current_num}++;
  }
}

fail("unclosed fenced code block (possibly truncated output)") if $in_fence;

# Verify all 12 canonical sections exist.
my @missing;
for my $sec (@CANON) {
  push @missing, $sec->{label} unless $seen_num{$sec->{num}};
}
fail("missing canonical sections: " . join(', ', @missing)) if @missing;

# Verify exact order 1..12.
for my $i (0 .. $#CANON) {
  my $want = $i + 1;
  my $got  = $seen_order[$i] // 0;
  if ($got != $want) {
    fail("canonical sections out of order: expected '$CANON[$want - 1]{label}' at position $want, got '$CANON[$got - 1]{label}'");
  }
}

# Verify every canonical section has a non-empty body.
my @empty_secs;
for my $sec (@CANON) {
  push @empty_secs, $sec->{label} unless ($body_lines{$sec->{num}} // 0) > 0;
}
fail("empty canonical sections: " . join(', ', @empty_secs)) if @empty_secs;

if (defined $write_canon) {
  my $tmp;
  my $oh;
  for (1 .. 16) {
    $tmp = "$write_canon.tmp.$$." . int(rand(10000000));
    last if sysopen($oh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644);
    $oh = undef;
  }
  fail("cannot create exclusive temp file for $write_canon: $!") unless $oh;
  binmode($oh, ':raw');
  print $oh $raw or do { close $oh; unlink $tmp; fail("cannot write $tmp: $!"); };
  close $oh or do { unlink $tmp; fail("cannot close $tmp: $!"); };
  rename($tmp, $write_canon) or do { unlink $tmp; fail("cannot rename $tmp to $write_canon: $!"); };
}

my $sha = sha256_hex($raw);
print "VALID=1\n";
print "SECTIONS=12\n";
print "SHA256=$sha\n";
exit 0;

sub fail {
  my ($msg) = @_;
  $msg =~ s/\r?\n/ /g;
  print "VALID=0\n";
  print "ERROR=$msg\n";
  exit 1;
}
