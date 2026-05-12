#!/bin/bash
# inject-skill.sh — emit a SessionStart additionalContext that combines:
#   1. The active role persona (read from <cwd>/.form-base/config.json; defaults
#      to "product-manager"). `null` role = no persona injection.
#   2. form-base's create_form / render_response decision rules.
#
# Role personas live in scripts/personas.json so the slash command and this
# hook stay in sync. JSON parse + escape is delegated to python3 (always
# present on macOS and on the platforms Claude Code targets).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSONAS_FILE="${SCRIPT_DIR}/personas.json"

python3 - "$PWD" "$PERSONAS_FILE" <<'PYEOF'
import json
import sys
from pathlib import Path

cwd = Path(sys.argv[1])
personas_path = Path(sys.argv[2])
config_path = cwd / ".form-base" / "config.json"

DEFAULT_ROLE = "product-manager"

try:
    personas = json.loads(personas_path.read_text(encoding="utf-8"))
except Exception:
    personas = {}

# Resolve the active role.
# - Missing config / unreadable config / missing key → default role.
# - Key present and explicitly null → no persona ("null" role).
# - Unknown role string → fall back to default (forward-compat: new roles ship
#   in newer personas.json; old hooks still work).
role = DEFAULT_ROLE
role_explicitly_null = False
try:
    data = json.loads(config_path.read_text(encoding="utf-8"))
    if isinstance(data, dict) and "role" in data:
        if data["role"] is None:
            role_explicitly_null = True
        elif isinstance(data["role"], str):
            role = data["role"]
except Exception:
    pass

if role_explicitly_null:
    persona = ""
elif role in personas and isinstance(personas[role], str):
    persona = personas[role]
else:
    persona = personas.get(DEFAULT_ROLE, "")

FORM_BASE_RULES = (
    "form-base (HTML interaction base) is available via MCP. Two decision rules:\n\n"
    "[create_form] — When the user describes a new feature / app / project and key info "
    "(platform, feature set, style, constraints) is unclear, package the clarifying questions "
    "into ONE structured form via `form-base.create_form` instead of asking 5+ separate text "
    "questions. After the user says 'I'm done' / '我完成了', call "
    "`form-base.read_answers` to read their input and continue. **Also for UI style / "
    "placement decisions** (where a button goes, color, font, component choice) — prefer "
    "a form with radio/color/font/style_suggestions over text questions. This is allowed in "
    "plan mode too (MCP tool calls bypass plan-mode's filesystem-write gate).\n\n"
    "[render_response] — When your reply would be > ~600 chars / 30 lines, OR contains "
    "code/files/diffs, OR the user's request was business-level ('做个 X' / 'help me "
    "build Y'), prefer `form-base.render_response` over a long inline CLI reply. Split into:\n"
    "  - business: user-facing summary, NO file names / function names / jargon\n"
    "  - technical: code / files / diffs (default-collapsed for non-developers)\n"
    "Set user_role='non-developer' unless the user explicitly asked for code. After "
    "rendering, give the CLI a one-liner pointer to the URL — do NOT repeat business "
    "content inline.\n\n"
    "[skip] — Short replies (< 200 chars), pure Q&A where user is reading in CLI, fast "
    "back-and-forth debugging — just reply in CLI.\n\n"
    "Full skill at skills/form-base/SKILL.md (under the form-base plugin)."
)

context_parts = []
if persona:
    context_parts.append(persona)
context_parts.append(FORM_BASE_RULES)
additional_context = "\n\n".join(context_parts)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": additional_context,
    },
}))
PYEOF
