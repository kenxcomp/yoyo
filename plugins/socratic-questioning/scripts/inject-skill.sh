#!/bin/bash
# inject-skill.sh - Inject socratic-clarify skill awareness at session start

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "The socratic-clarify skill is available for clarifying unclear requirements. When a user's request is vague or ambiguous (e.g., 'improve performance', 'fix the bug', 'optimize this'), you should naturally ask ONE clarifying question using multiple choice format (A), (B), (C) before proceeding. Focus on: Purpose (what goal?), Constraints (what limitations?), or Success Criteria (how to verify?). Match the user's language (English/Chinese). For explicit clarification, user can invoke /clarify command."
  }
}
EOF
