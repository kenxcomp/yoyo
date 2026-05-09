---
description: "Reopen a form's URL on the current MCP server's port."
argument-hint: "<form_id>"
---

# /form-show — Reopen a form's URL

If `$ARGUMENTS` is empty, ask the user for the `form_id` (suggest running `/form-list` first).

Otherwise call `form-base.reopen_form` with `form_id=$ARGUMENTS`. Then tell the user:

> 「请打开 [URL] 继续填写。完成后告诉我『我完成了』即可。」

Include the returned URL inline.
