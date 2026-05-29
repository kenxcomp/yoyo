#!/bin/bash
# codex-plan-review-trigger.sh
#
# PreToolUse:ExitPlanMode hook (v1.5.0, inline marker gate). Reads the plan being
# submitted and decides whether codex review already approved THIS exact plan by
# validating an inline marker on the plan's last line — NO state file involved.
#
#   - The plan's last line is  <!-- codex-reviewed:<token> -->  and <token>
#     matches the keyed digest of the plan body (everything above the marker) →
#     ALLOW the ExitPlanMode call.
#   - No marker, malformed marker, or token mismatch (plan revised after review,
#     or never reviewed) → DENY and instruct Claude to run
#     /plan-guardian:codex-plan-review first.
#
# Why inline instead of a sentinel file: the review loop runs while the session
# is STILL in plan mode, where Write/Edit prompt like default mode AND the
# allow-list intermittently fails to suppress those prompts on some Claude Code
# versions. Carrying the "reviewed" proof inside tool_input.plan (the in-memory
# channel) means the loop writes nothing during plan mode, so there is nothing
# for a flaky allow-list to miss. The digest is content-bound, so revising the
# plan invalidates the marker and re-arms the gate automatically.
#
# Marker token (computed by the SHARED plan-review-helper.sh digest subcommand,
# so mint-side and verify-side can never drift):
#   - CODEX_REVIEW_SECRET set   → h1:<sha256(secret"\n"body)>   (content-bound)
#   - CODEX_REVIEW_SECRET unset → l1:none                       (literal fallback)
#
# Opt-out: CODEX_PLAN_REVIEW=0 in env → hook is a no-op (silent allow).
#
# Input on stdin (JSON, Claude Code PreToolUse schema):
#   { "tool_name": "ExitPlanMode", "tool_input": { "plan": "<plan markdown>" }, ... }
# Output on stdout (JSON):
#   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#       "permissionDecision": "allow" | "deny", "permissionDecisionReason": "..." } }

set -euo pipefail

# Opt-out short-circuit.
if [ "${CODEX_PLAN_REVIEW:-1}" = "0" ]; then
  exit 0   # silent allow
fi

# Codex CLI not installed → silent allow (don't punish users without codex).
if ! command -v codex >/dev/null 2>&1; then
  exit 0
fi

# jq required to parse the hook payload. If missing, allow silently rather than
# blocking the user's normal flow.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Shared digest implementation lives next to this script. Mint (slash command)
# and verify (here) MUST use the same one.
HELPER="$(cd "$(dirname "$0")" && pwd)/plan-review-helper.sh"
if [ ! -x "$HELPER" ] && [ ! -f "$HELPER" ]; then
  exit 0   # helper missing → don't block the user
fi

# Read stdin, extract plan. If extraction fails, allow silently.
PAYLOAD="$(cat)"
PLAN="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.plan // empty' 2>/dev/null || true)"

if [ -z "$PLAN" ]; then
  exit 0
fi

# Marker is strictly the LAST line of the plan: <!-- codex-reviewed:<token> -->
LAST_LINE="$(printf '%s' "$PLAN" | tail -n1)"
SUBMITTED_TOKEN="$(printf '%s' "$LAST_LINE" \
  | sed -n 's/^[[:space:]]*<!-- codex-reviewed:\(.*\) -->[[:space:]]*$/\1/p')"

if [ -n "$SUBMITTED_TOKEN" ]; then
  # Reconstruct the body (everything except the marker line) and recompute the
  # expected token. sed '$d' drops the last line; the shared helper strips
  # trailing newlines on its side, mirroring how the marker was minted.
  EXPECTED_TOKEN="$(printf '%s' "$PLAN" | sed '$d' | bash "$HELPER" digest 2>/dev/null || true)"
  if [ -n "$EXPECTED_TOKEN" ] && [ "$EXPECTED_TOKEN" = "$SUBMITTED_TOKEN" ]; then
    jq -n --arg reason "Codex plan review marker valid for this exact plan body — allowing ExitPlanMode." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$reason}}'
    exit 0
  fi
fi

# No valid marker → stash the plan for the slash command (a plain hook-process
# write — NOT gated by plan mode) and block ExitPlanMode.
mkdir -p ./.plan-review
PENDING=./.plan-review/yoplan-pending.md
printf '%s' "$PLAN" > "$PENDING"

# Feed the heredoc straight into jq (jq -Rs reads raw stdin as one string `.`).
# This avoids a heredoc nested inside $(...) command substitution, which macOS's
# stock bash 3.2 misparses (executes the body as commands at runtime — bash -n
# does not catch it).
jq -Rs \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
<<'EOF'
ExitPlanMode is blocked by plan-guardian's codex review gate.

This plan carries no valid Codex-review marker (it was never reviewed, or it was
revised after the last review — the marker is bound to the plan's content). Before
exiting plan mode, run the slash command:

    /plan-guardian:codex-plan-review

It will:
  1. Take the plan from context (also stashed at ./.plan-review/yoplan-pending.md).
  2. Loop "codex exec" review against the plan until Codex emits NO_CONCERNS.
  3. Revise the plan in context based on each round's findings.
  4. Append an inline marker line to the converged plan:
         <!-- codex-reviewed:<token> -->
     (No files are written during plan mode — the proof rides inside the plan.)

After convergence, re-call ExitPlanMode with the marked plan exactly as the
command produced it — this hook will recompute the token, see it match, and
allow the call through.

Content-binding: set CODEX_REVIEW_SECRET in your environment to make the marker a
keyed digest of the plan body (revising the plan then re-arms the gate). Without
it, the gate still works but the marker is a fixed literal (spoofable) — fine for
a single-user setup.

Opt-out: set CODEX_PLAN_REVIEW=0 to bypass this gate entirely (the slash command
self-skips too). Codex CLI / jq missing → hook is a silent no-op.
EOF
