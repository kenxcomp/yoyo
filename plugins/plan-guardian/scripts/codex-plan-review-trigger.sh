#!/bin/bash
# codex-plan-review-trigger.sh
#
# PreToolUse:ExitPlanMode hook. Captures the plan being submitted, compares its
# sha256 against the .codex-review-done sentinel, and either:
#   - allows the ExitPlanMode call (sentinel matches, meaning /plan-guardian:codex-plan-review
#     already drove the codex loop to NO_CONCERNS on this exact plan), OR
#   - denies the call and instructs Claude to run /plan-guardian:codex-plan-review first.
#
# Opt-out: set CODEX_PLAN_REVIEW=0 in env to disable. Hook becomes a no-op (allow).
#
# Input on stdin (JSON, schema from Claude Code PreToolUse):
#   { "tool_name": "ExitPlanMode", "tool_input": { "plan": "<plan markdown>" }, ... }
#
# Output on stdout (JSON):
#   { "hookSpecificOutput": { "hookEventName": "PreToolUse",
#       "permissionDecision": "allow" | "deny",
#       "permissionDecisionReason": "..." } }

set -euo pipefail

# Opt-out short-circuit.
if [ "${CODEX_PLAN_REVIEW:-1}" = "0" ]; then
  exit 0   # silent allow
fi

# Codex CLI not installed → silent allow (don't punish users without codex).
if ! command -v codex >/dev/null 2>&1; then
  exit 0
fi

# Pick a sha256 binary that exists on both macOS and Linux.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@" | awk '{print $1}'
  else
    echo "no-sha256-available"
  fi
}

# jq required to parse the hook payload. If missing, allow silently rather than
# blocking the user's normal flow.
if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

# Read stdin, extract plan. If extraction fails, allow silently.
PAYLOAD="$(cat)"
PLAN="$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.plan // empty' 2>/dev/null || true)"

if [ -z "$PLAN" ]; then
  exit 0
fi

# Compute hash of the current plan (over the raw bytes).
PLAN_HASH="$(printf '%s' "$PLAN" | sha256 -)"
[ -z "$PLAN_HASH" ] && exit 0   # hash failure → allow

mkdir -p ./.plan-review

SENTINEL=./.plan-review/.codex-review-done
PENDING=./.plan-review/yoplan-pending.md

# Sentinel exists and matches → codex review for THIS plan already passed.
# Allow the ExitPlanMode call and clear the sentinel (one-shot; re-arms for the
# next plan).
if [ -f "$SENTINEL" ]; then
  SENTINEL_HASH="$(tr -d '[:space:]' < "$SENTINEL")"
  if [ "$SENTINEL_HASH" = "$PLAN_HASH" ]; then
    rm -f "$SENTINEL"
    jq -n --arg reason "Codex plan review previously converged for this exact plan (hash matched). Sentinel cleared." \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:$reason}}'
    exit 0
  fi
fi

# Otherwise: stash the plan for the slash command and block ExitPlanMode.
printf '%s' "$PLAN" > "$PENDING"

REASON="$(cat <<EOF
ExitPlanMode is blocked by plan-guardian's codex review gate.

This plan has not yet been reviewed by Codex (or the plan was revised after the
last review). Before exiting plan mode, run the slash command:

    /plan-guardian:codex-plan-review

It will:
  1. Read the plan from ./.plan-review/yoplan-pending.md (just written by this hook).
  2. Loop "codex exec" review against the plan until Codex emits NO_CONCERNS.
  3. Revise the plan in-place based on each round's findings.
  4. Write ./.plan-review/.codex-review-done with the sha256 of the converged plan.

After convergence, re-call ExitPlanMode with the (possibly revised) plan from
./.plan-review/yoplan-pending.md — this hook will see the matching sentinel and
allow the call to go through.

Opt-out: set environment variable CODEX_PLAN_REVIEW=0 to bypass this gate entirely
(the slash command will also self-skip). Codex CLI missing → hook is a silent no-op.

Plan hash (for debugging): ${PLAN_HASH}
EOF
)"

jq -n --arg reason "$REASON" \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$reason}}'
