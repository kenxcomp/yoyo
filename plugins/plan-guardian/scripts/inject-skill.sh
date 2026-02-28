#!/bin/bash
# inject-skill.sh - Inject Plan Mode Rules as additionalContext at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "MANDATORY Plan Mode Rules (plan-guardian plugin): Before calling ExitPlanMode, you MUST complete the following steps in order: (1) Ensure ./.plan-review/ directory exists (create it if not). (2) Write the complete plan to ./.plan-review/yoplan.md. (3) Launch the plan-reviewer subagent (Agent tool, subagent_type: plan-reviewer). (4) Wait for the plan-reviewer to complete and confirm ./.plan-review/yoplan.md contains '- [x] Have I reviewed this plan?'. (5) Only then call ExitPlanMode. If ExitPlanMode is blocked by a hook error, immediately launch the plan-reviewer subagent, then retry. NEVER manually add '- [x] Have I reviewed this plan?' — only the plan-reviewer subagent may do so."
  }
}
EOF
