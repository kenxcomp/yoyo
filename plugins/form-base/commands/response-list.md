---
description: "List form-base responses in the current project (with optional status filter)."
argument-hint: "[active|archived]"
---

# /response-list — List responses

Call `form-base.list_responses` with `status` set to `$ARGUMENTS` if it matches `active` or `archived`; otherwise list all.

Render the result as a compact table: `response_id`, `title`, `status`, `user_role`, `has_technical`, `created_at` (relative).

If empty, say so plainly.
