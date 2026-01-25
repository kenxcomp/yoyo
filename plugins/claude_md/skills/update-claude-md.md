---
name: update-claude-md
description: Update or create CLAUDE.md based on recent changes
---

# Update CLAUDE.md Skill

When invoked after a major update, this skill guides the CLAUDE.md update process.

## Workflow

1. **Check for CLAUDE.md existence**
   - Look for `CLAUDE.md` in the current project directory

2. **If CLAUDE.md exists:**
   - Ask user: "检测到重大更新，是否需要更新 CLAUDE.md？"
   - If YES: Analyze changes and propose updates to:
     - Project structure description
     - Coding standards/constraints
     - Workflow instructions
   - If NO: End without changes

3. **If CLAUDE.md does NOT exist:**
   - Ask user: "当前目录没有 CLAUDE.md，是否需要执行 /init 创建？"
   - If YES: Execute the built-in `/init` command
   - If NO: End without changes

## Update Guidelines

- Only add information relevant to the recent changes
- Keep instructions concise and actionable
- Preserve existing content unless it conflicts with new changes
- Use bilingual prompts (Chinese/English) when appropriate
