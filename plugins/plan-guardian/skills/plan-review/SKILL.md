---
name: plan-review
description: "Manually trigger a plan review. Use when you have a plan and want to validate it before execution, or when ExitPlanMode was blocked and you need to run the reviewer."
user_invocable: true
---

# Plan Review Skill

You have been asked to review a plan. Follow these steps:

1. **Locate the plan**: The plan may be in the conversation context, in `~/.claude/plans/`, or in `./.plan-review/yoplan.md`. Identify where the plan content is.
   - If no plan is found anywhere, inform the user that no plan was found to review.

2. **Launch the plan-reviewer agent**: Use the Agent tool to spawn a plan-reviewer subagent:
   ```
   Agent tool:
   - subagent_type: "plan-reviewer"
   - description: "Review plan for quality"
   - prompt: "Review the plan against all review criteria. This was manually triggered via /plan-review."
   ```
   If you know the plan file path, include it in the prompt so the agent can read it directly.

3. **Report results**: After the plan-reviewer completes, report whether the plan passed review and summarize any modifications made.
