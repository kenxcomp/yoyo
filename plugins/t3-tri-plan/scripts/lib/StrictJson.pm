package StrictJson;

use strict;
use warnings;
use Encode qw(decode FB_CROAK LEAVE_SRC);
use JSON::PP ();
use Exporter 'import';

our @EXPORT_OK = qw(
  decode_strict_typed
  decode_strict
  unwrap_typed
  encode_canonical
  encode_compact
  encode_compact_chars
  load_json_file
  load_json_file_typed
);

# Pure-Perl RFC 8259 recursive-descent JSON parser.
# Rejects duplicate keys at every nesting depth, preserves strict type tags
# (str, num, bool, null, arr, obj), rejects trailing garbage and invalid UTF-8.

sub decode_strict_typed {
  my ($raw_bytes) = @_;
  die "empty JSON input\n" unless defined $raw_bytes && length $raw_bytes;
  my $text = eval { decode('UTF-8', $raw_bytes, FB_CROAK | LEAVE_SRC) };
  die "invalid UTF-8 in JSON: $@\n" if $@;
  # Strip optional UTF-8 BOM only if explicitly unwanted? RFC 8259 forbids BOM; reject it.
  die "UTF-8 BOM is not allowed in strict JSON\n" if $text =~ /^\x{FEFF}/;

  my $len = length($text);
  my $pos = 0;

  my $skip_ws = sub {
    while ($pos < $len) {
      my $c = substr($text, $pos, 1);
      last unless $c eq ' ' || $c eq "\t" || $c eq "\n" || $c eq "\r";
      $pos++;
    }
  };

  my $parse_value;
  my $parse_string = sub {
    die "expected '\"' at offset $pos\n" unless $pos < $len && substr($text, $pos, 1) eq '"';
    $pos++;
    my $out = '';
    while ($pos < $len) {
      my $ch = substr($text, $pos, 1);
      if ($ch eq '"') {
        $pos++;
        return $out;
      }
      if ($ch eq '\\') {
        $pos++;
        die "unterminated escape at offset $pos\n" if $pos >= $len;
        my $esc = substr($text, $pos, 1);
        $pos++;
        if    ($esc eq '"')  { $out .= '"'; }
        elsif ($esc eq '\\') { $out .= '\\'; }
        elsif ($esc eq '/')  { $out .= '/'; }
        elsif ($esc eq 'b')  { $out .= "\b"; }
        elsif ($esc eq 'f')  { $out .= "\f"; }
        elsif ($esc eq 'n')  { $out .= "\n"; }
        elsif ($esc eq 'r')  { $out .= "\r"; }
        elsif ($esc eq 't')  { $out .= "\t"; }
        elsif ($esc eq 'u') {
          die "truncated \\u escape at offset $pos\n" if $pos + 4 > $len;
          my $hex = substr($text, $pos, 4);
          die "invalid \\u escape '\\u$hex' at offset $pos\n" unless $hex =~ /\A[0-9a-fA-F]{4}\z/;
          $pos += 4;
          my $cp = hex($hex);
          if ($cp >= 0xD800 && $cp <= 0xDBFF) {
            die "unpaired high surrogate \\u$hex at offset $pos\n"
              unless $pos + 6 <= $len && substr($text, $pos, 2) eq '\\u';
            my $hex2 = substr($text, $pos + 2, 4);
            die "invalid low surrogate '\\u$hex2' at offset $pos\n" unless $hex2 =~ /\A[0-9a-fA-F]{4}\z/;
            my $cp2 = hex($hex2);
            die "invalid low surrogate range \\u$hex2 at offset $pos\n" unless $cp2 >= 0xDC00 && $cp2 <= 0xDFFF;
            $pos += 6;
            $cp = 0x10000 + (($cp - 0xD800) << 10) + ($cp2 - 0xDC00);
          } elsif ($cp >= 0xDC00 && $cp <= 0xDFFF) {
            die "unpaired low surrogate \\u$hex at offset $pos\n";
          }
          $out .= chr($cp);
        } else {
          die "invalid escape '\\$esc' at offset $pos\n";
        }
      } else {
        my $ord = ord($ch);
        die "unescaped control character (0x" . sprintf('%02X', $ord) . ") in string at offset $pos\n"
          if $ord < 0x20;
        $out .= $ch;
        $pos++;
      }
    }
    die "unterminated string\n";
  };

  my $parse_number = sub {
    my $rest = substr($text, $pos);
    if ($rest =~ /\A(-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)/) {
      my $raw_num = $1;
      $pos += length($raw_num);
      my $is_int = ($raw_num =~ /\A-?(?:0|[1-9][0-9]*)\z/) ? 1 : 0;
      return ['num', 0 + $raw_num, $is_int, $raw_num];
    }
    die "invalid number at offset $pos\n";
  };

  my $parse_array = sub {
    $pos++; # skip '['
    $skip_ws->();
    my @arr;
    if ($pos < $len && substr($text, $pos, 1) eq ']') {
      $pos++;
      return ['arr', \@arr];
    }
    while (1) {
      $skip_ws->();
      push @arr, $parse_value->();
      $skip_ws->();
      die "unterminated array\n" if $pos >= $len;
      my $c = substr($text, $pos, 1);
      if ($c eq ']') { $pos++; return ['arr', \@arr]; }
      if ($c eq ',') { $pos++; next; }
      die "expected ',' or ']' in array at offset $pos\n";
    }
  };

  my $parse_object = sub {
    $pos++; # skip '{'
    $skip_ws->();
    my %obj;
    my @keys;
    if ($pos < $len && substr($text, $pos, 1) eq '}') {
      $pos++;
      return ['obj', \%obj, \@keys];
    }
    while (1) {
      $skip_ws->();
      die "expected string key in object at offset $pos\n"
        unless $pos < $len && substr($text, $pos, 1) eq '"';
      my $k = $parse_string->();
      die "duplicate JSON object key '$k'\n" if exists $obj{$k};
      $skip_ws->();
      die "expected ':' after key '$k' at offset $pos\n"
        unless $pos < $len && substr($text, $pos, 1) eq ':';
      $pos++;
      $skip_ws->();
      $obj{$k} = $parse_value->();
      push @keys, $k;
      $skip_ws->();
      die "unterminated object\n" if $pos >= $len;
      my $c = substr($text, $pos, 1);
      if ($c eq '}') { $pos++; return ['obj', \%obj, \@keys]; }
      if ($c eq ',') { $pos++; next; }
      die "expected ',' or '}' in object at offset $pos\n";
    }
  };

  $parse_value = sub {
    $skip_ws->();
    die "unexpected end of JSON at offset $pos\n" if $pos >= $len;
    my $c = substr($text, $pos, 1);
    return ['str', $parse_string->()] if $c eq '"';
    return $parse_object->()          if $c eq '{';
    return $parse_array->()           if $c eq '[';
    if ($c eq 't') {
      die "invalid token at offset $pos\n" unless substr($text, $pos, 4) eq 'true';
      $pos += 4;
      return ['bool', JSON::PP::true];
    }
    if ($c eq 'f') {
      die "invalid token at offset $pos\n" unless substr($text, $pos, 5) eq 'false';
      $pos += 5;
      return ['bool', JSON::PP::false];
    }
    if ($c eq 'n') {
      die "invalid token at offset $pos\n" unless substr($text, $pos, 4) eq 'null';
      $pos += 4;
      return ['null', undef];
    }
    return $parse_number->() if $c eq '-' || ($c ge '0' && $c le '9');
    die "unexpected character '$c' at offset $pos\n";
  };

  my $root = $parse_value->();
  $skip_ws->();
  die "trailing content after JSON at offset $pos\n" if $pos < $len;
  return $root;
}

sub unwrap_typed {
  my ($node) = @_;
  my $t = $node->[0];
  return $node->[1] if $t eq 'str' || $t eq 'num' || $t eq 'bool' || $t eq 'null';
  if ($t eq 'arr') {
    return [ map { unwrap_typed($_) } @{$node->[1]} ];
  }
  if ($t eq 'obj') {
    my %h;
    for my $k (keys %{$node->[1]}) {
      $h{$k} = unwrap_typed($node->[1]{$k});
    }
    return \%h;
  }
  die "unknown typed node '$t'\n";
}

sub decode_strict {
  my ($raw_bytes) = @_;
  return unwrap_typed(decode_strict_typed($raw_bytes));
}

sub encode_canonical {
  my ($val) = @_;
  return JSON::PP->new->utf8->canonical->pretty->encode($val);
}

sub encode_compact {
  my ($val) = @_;
  return JSON::PP->new->utf8->canonical->encode($val);
}

sub encode_compact_chars {
  my ($val) = @_;
  return JSON::PP->new->canonical->encode($val);
}

sub load_json_file_typed {
  my ($path) = @_;
  open(my $fh, '<:raw', $path) or die "cannot read $path: $!\n";
  local $/;
  my $raw = <$fh>;
  close $fh;
  return decode_strict_typed($raw);
}

sub load_json_file {
  my ($path) = @_;
  return unwrap_typed(load_json_file_typed($path));
}

1;
