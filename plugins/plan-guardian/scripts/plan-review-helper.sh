#!/bin/bash
# plan-review-helper.sh — single source of truth for the codex plan-review
# "reviewed" marker digest.
#
# Why this exists (v1.5.0, marker gate): the codex review loop runs while the
# session is STILL in plan mode, where Write/Edit/Bash are gated exactly like
# default mode (they prompt) — and on some Claude Code versions the allow-list
# intermittently fails to suppress Write/Edit prompts under mode toggles. So the
# v1.5.0 gate writes NO state files during plan mode. The "this plan was
# reviewed" signal lives INLINE in the plan text (an HTML-comment marker on the
# last line), which travels to the ExitPlanMode hook through tool_input.plan —
# the in-memory channel, not the filesystem.
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
# Subcommand:
#   digest    Read the plan BODY (no marker line) from stdin, print the marker
#             token to stdout (no trailing newline). With CODEX_REVIEW_SECRET
#             set:        h1:<sha256 hex>      (content-bound)
#             Without it:  l1:none             (literal fallback — works, but
#                                               spoofable / not content-bound).
#
# The body is read via body="$(cat)", which strips trailing newlines exactly the
# way the hook's reconstruction does, so mint-side and verify-side normalization
# cancel and the comparison is byte-for-byte.

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

cmd="${1:-}"

case "$cmd" in
  digest)
    body="$(cat)"                       # trailing newlines stripped here
    secret="${CODEX_REVIEW_SECRET:-}"
    if [ -n "$secret" ]; then
      hex="$(printf '%s\n%s' "$secret" "$body" | sha256)"
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
