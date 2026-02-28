#!/bin/bash
# inject-skill.sh - Inject Plan Mode Rules as additionalContext at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "MANDATORY Plan Mode Rules (plan-guardian plugin): Before calling ExitPlanMode, you MUST complete the following steps in order: (1) Ensure ./.plan-review/ directory exists (create it if not). (2) Write the complete plan to the plan file (Claude Code manages the plan file location automatically). Do NOT copy or write the plan into ./.plan-review/review-status.md — that file is reserved for the review checklist only. (3) Launch the plan-reviewer subagent (Agent tool, subagent_type: plan-reviewer). (4) Wait for the plan-reviewer to complete and confirm ./.plan-review/review-status.md contains '- [x] Have I reviewed this plan?'. (5) Only then call ExitPlanMode. If ExitPlanMode is blocked by a hook error, immediately launch the plan-reviewer subagent, then retry. NEVER manually add '- [x] Have I reviewed this plan?' — only the plan-reviewer subagent may do so."
  }
}
EOF
