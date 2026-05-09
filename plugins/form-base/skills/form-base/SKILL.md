---
name: form-base
description: "Decide when to use form-base's HTML form (create_form) for collecting structured input vs. its rich response view (render_response) for rendering long agent output. Use forms when requirements are unclear; use responses when your reply is long, contains code, or the user's request was business-level."
user_invocable: false
---

# form-base — How to decide between Form, Response, and plain CLI text

`form-base` is an MCP server that gives you two HTML interaction modes through a local web server. **The user — not you — opens the page in a browser.** Then the user comes back to the CLI and either says "I'm done" (form filled) or just keeps the conversation going (response read).

## When to use `create_form`

Use it when the user has described a need but **key information is unclear** and you'd otherwise have to ask many separate text questions. Typical triggers:

- "I want to build a [thing]" — but you don't know platform / target users / must-have features / style direction
- "Help me design [X]" — but constraints / deadlines / scope are vague
- The user's request is **broad** and a structured form would save 5+ rounds of back-and-forth

Pack the questions into one `create_form` call. Use the right item types:

- `radio` — single choice (e.g. platform: web vs mobile)
- `checkbox` — multi choice (e.g. features wanted)
- `text` — short free text (names, identifiers)
- `markdown` — long-form description (live preview, GFM)
- `color` — color picker for theme decisions
- `font` — font sample selector (rendered in actual font)
- `slider` — numeric range (font size, radius, spacing)

You can also pass `style_suggestions` — comparison cards with `name` / `primary` / `secondary` / `font` / `radius` / `notes`. Use them when offering 2–4 design directions for the user to react to.

After `create_form` returns `{form_id, url}`, give the user a one-liner: "请打开 [URL] 填写。完成后告诉我『我完成了』即可。" Then **wait** for the user. When they reply with "我完成了" / "done" / similar, call `read_answers(form_id)` to retrieve their input and continue.

## When to use `render_response`

Use it instead of replying inline whenever **any** of these is true:

1. Your reply would be longer than ~600 characters or ~30 lines
2. Your reply contains code blocks, file paths, or diffs
3. The user's original request was **business-level** ("做个 X" / "帮我 X") rather than a pure technical question

Split your reply into two markdown sections:

- `business` — what changed from the user's app/business perspective. Use plain user-facing language. **Do not mention file names, function names, type names, or technical jargon here.**
- `technical` — files / code / diffs / decisions. Default-collapsed in the page. Treat this as the engineer's view.

Set `user_role` to:
- `"non-developer"` (default) — technical hidden behind a toggle
- `"developer"` — only when the user explicitly asks for code / details / or said earlier "我是开发者"

Optional: pass `attachments.files_changed` — list of file paths shown above the technical body. Pass `attachments.images` only if you have a real screenshot or mock to embed.

After `render_response` returns `{response_id, url}`, **do not repeat the business content in CLI**. Just say one line: "已经准备好详细说明,请打开 [URL] 查看,有反馈随时说。"

## When to NOT use form-base

- Reply is short (< 200 characters) and clearly a direct answer → just reply in CLI.
- Pure technical Q&A where the user is reading the answer in CLI anyway → just reply in CLI.
- The user is in a back-and-forth debugging session and needs each answer fast → just reply in CLI.

## Project setup

`.form-base/` is created automatically on first form/response. The user can run `/form-init` to set defaults explicitly. Config lives in `.form-base/config.json`:

```json
{
  "default_user_role": "non-developer",
  "response_threshold_chars": 600,
  "response_threshold_lines": 30,
  "auto_open_browser": false
}
```

## Available tools

Form: `create_form`, `get_form_status`, `read_answers`, `list_forms`, `archive_form`, `reopen_form`
Response: `render_response`, `list_responses`, `archive_response`, `reopen_response`

All tools are namespaced under `form-base.<tool_name>` in MCP.
