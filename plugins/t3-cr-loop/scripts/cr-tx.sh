#!/usr/bin/env bash
# cr-tx.sh — atomic transaction and state helpers for t3-cr-loop (v1.0.0).
#
# Compatible with macOS bash 3.2.

validate_branch_ownership() {
  if [ -f "$STATE" ]; then
    stored=$(sget branch)
    [ "$stored" = "$BRANCH" ] || die "state dir $STATE_DIR belongs to branch '$stored', not '$BRANCH' (key collision) — run 'reset' or rename the branch"
  fi
}

build_state_file() {
  out="$1"; shift
  tmp="$out.tmp.$$"
  if [ -f "$STATE" ]; then
    cp "$STATE" "$tmp" || die "cannot copy $STATE to $tmp"
  else
    : > "$tmp" || die "cannot create $tmp"
  fi
  for kv in "$@"; do
    k="${kv%%=*}"
    v="${kv#*=}"
    tmp2="$out.tmp2.$$"
    { grep -v "^$k=" "$tmp" 2>/dev/null || true; printf '%s=%s\n' "$k" "$v"; } > "$tmp2" || { rm -f "$tmp" "$tmp2"; die "cannot update state key $k"; }
    mv "$tmp2" "$tmp" || { rm -f "$tmp" "$tmp2"; die "cannot move state temp file"; }
  done
  mv "$tmp" "$out" || { rm -f "$tmp"; die "cannot finalize $out"; }
}

tx_get() {
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

_tx_canon_dir() {
  [ -n "${1:-}" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  (cd "$1" 2>/dev/null && pwd -P)
}

_tx_assert_within_state_dir() {
  raw_path="$1"; label="$2"
  state_canon=$(_tx_canon_dir "$STATE_DIR") || die "cannot canonicalize STATE_DIR ($STATE_DIR)"
  path_canon=$(_tx_canon_dir "$raw_path") || die "$label missing, symlink, or not a directory: $raw_path (pending.tx preserved)"
  case "$path_canon" in
    "$state_canon/"*) printf '%s\n' "$path_canon" ;;
    *) die "$label escapes branch state dir ($state_canon): $path_canon (pending.tx preserved)" ;;
  esac
}

_tx_replace_file() {
  src="$1"; dst="$2"; label="$3"
  [ -f "$src" ] && [ ! -L "$src" ] || die "tx replay source invalid for $label: $src (pending.tx preserved)"
  [ ! -L "$dst" ] || die "tx replay conflict: symlink at $label target $dst (pending.tx preserved)"
  [ ! -d "$dst" ] || die "tx replay conflict: directory at $label target $dst (pending.tx preserved)"
  tmp="$dst.tmp.$$"
  rm -f "$tmp" 2>/dev/null || true
  cp "$src" "$tmp" && mv "$tmp" "$dst" || { rm -f "$tmp"; die "tx replay failed replacing $label (pending.tx preserved)"; }
  [ -f "$dst" ] && [ ! -L "$dst" ] && cmp -s "$src" "$dst" || die "tx replay post-verify failed for $label (pending.tx preserved)"
}

recover_pending_tx() {
  REPLAYED_TX_KIND=""
  REPLAYED_TX_ROUND=""
  ptx="$STATE_DIR/pending.tx"
  [ ! -L "$ptx" ] || die "pending.tx is a symlink — refusing recovery"
  [ -f "$ptx" ] || return 0
  tx_dir=$(tx_get "$ptx" tx_dir)
  tx_branch=$(tx_get "$ptx" tx_branch)
  tx_kind=$(tx_get "$ptx" tx_kind)
  tx_round=$(tx_get "$ptx" tx_round_dir)
  [ "$tx_branch" = "$BRANCH" ] || die "pending transaction belongs to branch '$tx_branch', not '$BRANCH' — refusing recovery"
  tx_dir=$(_tx_assert_within_state_dir "$tx_dir" "pending transaction directory")
  [ -f "$tx_dir/ledger.full" ] && [ ! -L "$tx_dir/ledger.full" ] || die "pending transaction missing ledger.full: $tx_dir (pending.tx preserved)"
  [ -f "$tx_dir/state.full" ] && [ ! -L "$tx_dir/state.full" ] || die "pending transaction missing state.full: $tx_dir (pending.tx preserved)"
  if [ "$tx_kind" = "finish" ]; then
    tx_round=$(_tx_assert_within_state_dir "$tx_round" "pending finish tx round dir")
    rounds_canon=$(_tx_canon_dir "$STATE_DIR/rounds") || die "rounds dir missing or symlink (pending.tx preserved)"
    case "$tx_round" in
      "$rounds_canon/"*)
        rel_r="${tx_round#"$rounds_canon/"}"
        case "$rel_r" in */*) die "pending finish tx round dir not a direct child of rounds/: $tx_round (pending.tx preserved)" ;; esac
        ;;
      *) die "pending finish tx round dir outside rounds/: $tx_round (pending.tx preserved)" ;;
    esac
    [ -f "$tx_dir/verdict.out" ] && [ ! -L "$tx_dir/verdict.out" ] || die "pending finish tx missing verdict.out: $tx_dir (pending.tx preserved)"
  fi

  _tx_replace_file "$tx_dir/ledger.full" "$LEDGER" "ledger"
  _tx_replace_file "$tx_dir/state.full" "$STATE" "state"

  if [ "$tx_kind" = "finish" ]; then
    if [ -f "$tx_dir/active_round.json" ]; then
      _tx_replace_file "$tx_dir/active_round.json" "$tx_round/active_round.json" "active_round.json"
    fi
    _tx_replace_file "$tx_dir/verdict.out" "$tx_round/verdict" "verdict"
    fin="$tx_round/finished"
    [ ! -L "$fin" ] || die "tx replay conflict: symlink at finished target $fin (pending.tx preserved)"
    [ ! -d "$fin" ] || die "tx replay conflict: directory at finished target $fin (pending.tx preserved)"
    ftmp="$fin.tmp.$$"
    : > "$ftmp" && mv "$ftmp" "$fin" || { rm -f "$ftmp"; die "tx replay failed marking finished (pending.tx preserved)"; }
    [ -f "$fin" ] && [ ! -L "$fin" ] || die "tx replay post-verify failed for finished marker (pending.tx preserved)"
  fi

  rm -f "$ptx" || die "tx replay failed removing pending.tx"
  REPLAYED_TX_KIND="$tx_kind"
  REPLAYED_TX_ROUND="$tx_round"
}

commit_tx() {
  tx_dir="$1"; tx_kind="$2"; tx_round="${3:-}"
  tx_dir=$(_tx_assert_within_state_dir "$tx_dir" "commit_tx tx_dir")
  if [ "$tx_kind" = "finish" ]; then
    tx_round=$(_tx_assert_within_state_dir "$tx_round" "commit_tx tx_round")
  fi
  [ ! -L "$STATE_DIR/pending.tx" ] && [ ! -d "$STATE_DIR/pending.tx" ] || die "cannot publish pending.tx: conflict at target"
  ptmp="$STATE_DIR/pending.tx.tmp.$$"
  {
    printf 'tx_dir=%s\n' "$tx_dir"
    printf 'tx_branch=%s\n' "$BRANCH"
    printf 'tx_kind=%s\n' "$tx_kind"
    printf 'tx_round_dir=%s\n' "$tx_round"
  } > "$ptmp" || { rm -f "$ptmp"; die "cannot write pending.tx temp file"; }
  mv "$ptmp" "$STATE_DIR/pending.tx" || { rm -f "$ptmp"; die "cannot publish pending.tx"; }
  recover_pending_tx
}
