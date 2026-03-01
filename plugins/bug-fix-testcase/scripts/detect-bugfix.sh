#!/bin/bash
# detect-bugfix.sh - Detect bug-fixing intent from user prompt
# Reads user prompt from stdin (UserPromptSubmit hook)

PROMPT=$(cat)

# Pattern match for bug-fixing keywords (case-insensitive)
if echo "$PROMPT" | grep -iqE '(fix\s*(a\s+)?bug|bug\s*fix|bugfix|hotfix|hot\s*fix|patch|regression|defect|修复|修bug|修复bug|debug\s+and\s+fix)'; then
  cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "Bug-fixing intent detected in user prompt. The bug-fix-testcase skill can spawn a dedicated testcase-writer agent in an isolated git worktree to write regression tests while you fix the bug. Suggest to the user: 'I noticed you're working on a bug fix. Would you like me to spawn a testcase-writer agent to create regression tests in parallel? This runs in an isolated git worktree and won't interfere with your fix.' If the user agrees, invoke the bug-fix-testcase skill via the Skill tool."
  }
}
EOF
else
  # No bug-fixing keywords detected — output valid JSON with no additional context
  echo '{}'
fi
