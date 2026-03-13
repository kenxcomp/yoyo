#!/bin/bash
# inject-skill.sh - Inject Plan Mode Rules as additionalContext at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Plan Review Guidelines (plan-guardian plugin): After writing a plan and before exiting plan mode, you SHOULD consider launching the plan-reviewer subagent (Agent tool, subagent_type: plan-reviewer) to review the plan for quality. This is recommended but NOT mandatory — use your judgment based on plan complexity and risk. The user can also manually trigger a review via /plan-review. When using the reviewer: (1) Ensure ./.plan-review/ directory exists. (2) The review checklist lives in ./.plan-review/review-status.md (separate from the plan file). (3) NEVER manually add '- [x] Have I reviewed this plan?' — only the plan-reviewer subagent may do so."
  }
}
EOF
