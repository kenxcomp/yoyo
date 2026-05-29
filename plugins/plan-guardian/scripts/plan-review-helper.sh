#!/bin/bash
# plan-review-helper.sh — single source of truth for the codex plan-review
# "reviewed" marker digest.
#
# Why this exists (v1.5.0, marker gate): the codex review loop runs while the
# session is STILL in plan mode, where Write/Edit/Bash are gated exactly like
# default mode (they prompt) — and on some Claude Code versions the allow-list
# intermittently fails to suppress Write/Edit prompts under mode toggles. So the
# gate writes NO state files during plan mode. The "this plan was reviewed"
# signal lives INLINE in the plan text (an HTML-comment marker on the last line),
# which travels to the ExitPlanMode hook through tool_input.plan — the in-memory
# channel, not the filesystem.
#
# The marker is a keyed digest of the plan body so it is content-bound: revise
# the plan and the marker no longer validates, re-arming the gate automatically.
# (This is a secret-keyed SHA-256, not RFC-2104 HMAC — sufficient for this
# threat model: a single local user, preventing accidental stale-plan reuse and
# casual forgery, not defeating a cryptographic adversary.)
#
# Both the slash command (to MINT a marker on convergence) and the hook (to
# VERIFY one on ExitPlanMode) call this one subcommand, so the algorithm can
# never drift between mint and verify.
#
# Key resolution (v1.5.1 — content-binding by default), in priority order:
#   1. $CODEX_REVIEW_SECRET if set/non-empty  — explicit per-user/per-project key.
#   2. A per-machine auto key file at ${CODEX_REVIEW_SECRET_FILE:-~/.claude/plan-guardian/secret}.
#      Created (chmod 600, random) on first use if absent. This makes the marker
#      content-bound out of the box, with no setup — every user gets the strong
#      mode, not the spoofable literal.
#   3. Literal fallback (only if no key can be established, e.g. unwritable HOME
#      and no random source): a fixed token. Works, but spoofable / not
#      content-bound.
#
# Subcommand:
#   digest    Read the plan BODY (no marker line) from stdin, print the marker
#             token to stdout (no trailing newline):
#               h1:<sha256 hex>   when a key (env or file) is in effect
#               l1:none           literal fallback (no key available)
#
# The body is read via body="$(cat)", which strips trailing newlines exactly the
# way the hook's reconstruction does, so mint-side and verify-side normalization
# cancel and the comparison is byte-for-byte. Because both sides run THIS script,
# they resolve the same key (same env, same file) and therefore agree.

set -euo pipefail

# macOS/Linux portable sha256 over stdin -> bare hex.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    echo "no-sha256-available"
  fi
}

# Emit a hex random string, or empty if no source is available.
rand_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32 2>/dev/null && return
  fi
  if [ -r /dev/urandom ] && command -v od >/dev/null 2>&1; then
    od -An -tx1 -N32 /dev/urandom 2>/dev/null | tr -d ' \n' && return
  fi
  printf ''
}

# Resolve the signing key. Prints the key to stdout, or empty if none.
resolve_key() {
  # 1. Explicit env secret wins.
  if [ -n "${CODEX_REVIEW_SECRET:-}" ]; then
    printf '%s' "$CODEX_REVIEW_SECRET"
    return
  fi

  # 2. Per-machine auto key file.
  local keyfile="${CODEX_REVIEW_SECRET_FILE:-${HOME:-}/.claude/plan-guardian/secret}"
  if [ -f "$keyfile" ]; then
    cat "$keyfile" 2>/dev/null
    return
  fi

  # Create it (best-effort). umask 077 -> file is mode 600. noclobber subshell
  # so concurrent creators don't race: only the first write wins; everyone else
  # reads the winner's value back.
  local dir newkey
  dir="$(dirname "$keyfile")"
  if mkdir -p "$dir" 2>/dev/null; then
    newkey="$(rand_hex)"
    if [ -n "$newkey" ]; then
      ( umask 077; set -o noclobber; printf '%s' "$newkey" > "$keyfile" ) 2>/dev/null || true
      if [ -f "$keyfile" ]; then
        cat "$keyfile" 2>/dev/null   # canonical content (the race winner's)
        return
      fi
      # Write failed and file still absent -> use the in-memory key for this run.
      printf '%s' "$newkey"
      return
    fi
  fi

  # 3. No key could be established.
  printf ''
}

cmd="${1:-}"

case "$cmd" in
  digest)
    body="$(cat)"                       # trailing newlines stripped here
    key="$(resolve_key)"
    if [ -n "$key" ]; then
      hex="$(printf '%s\n%s' "$key" "$body" | sha256)"
      printf 'h1:%s' "$hex"
    else
      printf 'l1:none'
    fi
    ;;
  *)
    echo "plan-review-helper: unknown subcommand '${cmd}' (expected: digest)" >&2
    exit 1
    ;;
esac
