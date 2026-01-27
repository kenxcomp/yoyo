#!/bin/bash
# inject-skill.sh - Inject CLAUDE.md update awareness at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "CLAUDE.md Update Awareness: After completing significant work in a git repository, you should proactively ask the user if they want to update CLAUDE.md. Significant work includes: (1) Code architecture changes (new modules, refactoring, core logic changes), (2) Functional changes (new features, removed features, API changes), (3) Configuration/specification changes (project config, coding standards, dependencies). When you detect such changes, ask: 'I noticed this session involved [brief description of changes]. Would you like me to update CLAUDE.md to reflect these changes?' Only ask for git repositories and truly significant changes - not for minor fixes, typos, or small adjustments."
  }
}
EOF
