#!/bin/bash
# inject-skill.sh - Inject auto-fixer skill awareness at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "The darwin:auto-fixer skill is available for automatic error fixing. When you encounter runtime errors (Python script failures, Bash command errors, build failures, test failures), you should immediately invoke the darwin:auto-fixer skill using the Skill tool. This offloads error-fixing work to a dedicated agent, preserving main conversation context. The agent will analyze the error, implement a fix, verify it works, and return a summary."
  }
}
EOF
