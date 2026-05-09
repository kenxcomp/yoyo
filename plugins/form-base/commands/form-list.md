---
description: "List form-base forms in the current project (with optional status filter)."
argument-hint: "[pending|submitted|archived]"
---

# /form-list — List forms

Call the MCP tool `form-base.list_forms` with `status` set to `$ARGUMENTS` if it matches `pending`, `submitted`, or `archived`; otherwise leave `status` unset to list all.

Render the result as a compact table with columns: `form_id` (short), `title`, `status`, `created_at` (relative time, e.g. "2h ago"), `submitted_at` (or `—`).

If there are zero forms, say so plainly and remind the user that forms are created automatically when the agent calls `create_form`.
