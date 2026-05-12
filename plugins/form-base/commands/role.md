---
description: "Switch the form-base role that shapes Claude's communication style (product-manager / developer / lawyer / null)."
argument-hint: "[--product-manager | --developer | --lawyer | --null]"
---

# /form-base:role — switch communication persona

User invoked: `/form-base:role $ARGUMENTS`

The form-base role shapes ONLY how you answer — vocabulary, framing, level of detail. It never restricts which tools you call, which files you edit, or how you execute tasks. Role config is per-project, stored at `<cwd>/.form-base/config.json`.

## Steps

1. **Parse `$ARGUMENTS`.** Recognize exactly one of these flags (case-insensitive):
   - `--product-manager` (alias: `--pm`)
   - `--developer` (alias: `--dev`)
   - `--lawyer`
   - `--null` (aliases: `--none`, `--clear`, `--reset`)

   Branching:
   - **No flag** → Read `<cwd>/.form-base/config.json` (if missing, default role is `product-manager`). Show the current role and the available options. Do NOT modify anything. Stop.
   - **Multiple flags or unknown flag** → Tell the user: `用法: /form-base:role [--product-manager|--developer|--lawyer|--null]`. Do NOT modify anything. Stop.
   - **One valid flag** → Continue to step 2.

2. **Persist the new role.**
   - Read `<cwd>/.form-base/config.json` with the `Read` tool. If the file does not exist, the directory does not exist, or the JSON is invalid, treat the starting config as `{}` and create the directory before writing.
   - Replace the `role` field (use JSON `null` for the `--null` family of flags).
   - Preserve any other existing fields (e.g. `default_user_role`, `response_threshold_chars`).
   - Write the result back with the `Write` tool, 2-space indented.

3. **Echo confirmation in CLI**, then adopt the persona immediately.

   Output format (one line):
   - For a named role: `✓ form-base role → <role>` and a one-line summary of that persona.
   - For `--null`: `✓ form-base role cleared (no persona injection)`.

4. **Adopt the persona for the rest of this conversation.** The SessionStart hook already ran for this session, so you must apply the new persona starting with your *very next* message. Use the personas defined in `${CLAUDE_PLUGIN_ROOT}/scripts/personas.json` verbatim (read that file once if you need the exact wording).

   Quick reference (authoritative copy in personas.json):
   - **product-manager** — Product / user-flow / scope / trade-off vocabulary. No file paths or line numbers in answers. Frame changes as "what changes for the user". Affects answering only.
   - **developer** — Engineer-to-engineer voice. File paths, line numbers, code blocks, design rationale welcome. Affects answering only.
   - **lawyer** — Legal-counsel voice. Frame as risk, compliance, IP / license, data handling. Surface ambiguities; recommend, don't decide. Affects answering only.
   - **null** — No persona override. Use default Claude Code voice.

5. **Do NOT do any other work in this turn.** The command's job is only to swap personas. Wait for the user's next instruction.

## Notes

- The role only shapes how you answer. It must never gate Bash, Edit, Write, or any other tool. A `--lawyer` role still edits files when asked; a `--product-manager` role still runs the test suite when asked.
- `render_response` uses the active role to pick its default `user_role` value: `developer` → technical visible by default; others → technical collapsed by default. This is also "answering style", not behavior.
- Adding a new role later: append the persona to `scripts/personas.json` and add a flag here. The SessionStart hook reads `personas.json` at startup, so new roles activate without any code change.
