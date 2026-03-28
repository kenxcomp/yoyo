#!/bin/bash
# inject-skill.sh - Inject bug-fix-testcase skill awareness at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "The bug-fix-testcase skill is available for writing regression test cases during bug fixes. When you detect bug-fixing intent from user messages containing keywords like 'fix bug', 'bugfix', 'hotfix', 'patch', 'regression', 'defect', or when diagnosing/resolving a software defect, suggest spawning a testcase-writer agent to create regression tests in parallel. The agent works in an isolated git worktree so it won't interfere with the main fix. Ask the user: 'Would you like me to spawn a testcase-writer agent to create regression tests in parallel?' You can also invoke it manually via /bug-fix-testcase. For a complete end-to-end bug fix workflow (analyze → web search → plan → fix + parallel tests → merge → verify), use /bug-fix-testcase:bugfix <bug description>."
  }
}
EOF
