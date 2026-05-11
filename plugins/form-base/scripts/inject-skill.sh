#!/bin/bash
# inject-skill.sh — emit a SessionStart additionalContext nudge so the agent
# knows form-base is available and when to use it.

cat << 'EOF'
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "form-base (HTML interaction base) is available via MCP. Two decision rules:\n\n[create_form] — When the user describes a new feature / app / project and key info (platform, feature set, style, constraints) is unclear, package the clarifying questions into ONE structured form via `form-base.create_form` instead of asking 5+ separate text questions. After the user says 'I'm done' / '我完成了', call `form-base.read_answers` to read their input and continue. **Also for UI style / placement decisions** (where a button goes, color, font, component choice) — prefer a form with radio/color/font/style_suggestions over text questions. This is allowed in plan mode too (MCP tool calls bypass plan-mode's filesystem-write gate).\n\n[render_response] — When your reply would be > ~600 chars / 30 lines, OR contains code/files/diffs, OR the user's request was business-level ('做个 X' / 'help me build Y'), prefer `form-base.render_response` over a long inline CLI reply. Split into:\n  - business: user-facing summary, NO file names / function names / jargon\n  - technical: code / files / diffs (default-collapsed for non-developers)\nSet user_role='non-developer' unless the user explicitly asked for code. After rendering, give the CLI a one-liner pointer to the URL — do NOT repeat business content inline.\n\n[skip] — Short replies (< 200 chars), pure Q&A where user is reading in CLI, fast back-and-forth debugging — just reply in CLI.\n\nFull skill at skills/form-base/SKILL.md (under the form-base plugin)."
  }
}
EOF
