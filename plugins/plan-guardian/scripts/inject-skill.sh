#!/bin/bash
# inject-skill.sh - Inject Plan Mode Rules as additionalContext at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Plan Review Guidelines (plan-guardian plugin):\n\n(1) Plan-reviewer agent (advisory, path A): After writing a plan and before exiting plan mode, you SHOULD consider launching the plan-reviewer subagent (Agent tool, subagent_type: plan-reviewer). Recommended but NOT mandatory — use your judgment. User can manually trigger via /plan-review. The review checklist lives in ./.plan-review/review-status.md (separate from the plan file). NEVER manually add '- [x] Have I reviewed this plan?' — only the plan-reviewer subagent may do so.\n\n(2) Codex review gate (v1.3.0, path B, opt-out): A PreToolUse:ExitPlanMode hook intercepts your ExitPlanMode calls. If the plan hasn't been approved by Codex yet, the hook will DENY the call with permissionDecisionReason explaining that you must run /plan-guardian:codex-plan-review first. That slash command loops `codex exec` reviews against the plan in ./.plan-review/yoplan-pending.md, revises the plan based on reasonable findings, and writes a sha256 sentinel on convergence (NO_CONCERNS from Codex). After convergence, re-call ExitPlanMode with the (possibly revised) plan content from ./.plan-review/yoplan-pending.md — the hook will see the matching sentinel and allow the call.\n\nGate disabled when: CODEX_PLAN_REVIEW=0 in env, or codex CLI not installed, or jq not installed (hook silently allows in all three cases). When the gate fires, do not paraphrase the rejection — read the hook's permissionDecisionReason and follow its instructions exactly. The slash command writes per-round audit trails to ./.plan-review/codex-rounds/."
  }
}
EOF
