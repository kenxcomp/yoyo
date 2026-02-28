---
name: plan-review
description: "Manually trigger a plan review. Use when you have a plan written in ./.plan-review/yoplan.md and want to validate it before execution, or when ExitPlanMode was blocked and you need to run the reviewer."
user_invocable: true
---

# Plan Review Skill

You have been asked to review a plan. Follow these steps:

1. **Check for plan file**: Look for `./.plan-review/yoplan.md` in the current working directory.
   - If the file does not exist or is empty, inform the user that no plan was found to review. Ask them to either enter plan mode and write a plan first, or manually create `./.plan-review/yoplan.md` with their plan content.

2. **Launch the plan-reviewer agent**: Use the Agent tool to spawn a plan-reviewer subagent:
   ```
   Agent tool:
   - subagent_type: "plan-reviewer"
   - description: "Review plan for quality"
   - prompt: "Review the plan in ./.plan-review/yoplan.md against all review criteria. This was manually triggered via /plan-review."
   ```

3. **Report results**: After the plan-reviewer completes, report whether the plan passed review and summarize any modifications made.
