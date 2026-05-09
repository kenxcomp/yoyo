---
description: "Reopen a response's URL on the current MCP server's port."
argument-hint: "<response_id>"
---

# /response-show — Reopen a response's URL

If `$ARGUMENTS` is empty, ask the user for the `response_id` (suggest running `/response-list` first).

Otherwise call `form-base.reopen_response` with `response_id=$ARGUMENTS`. Tell the user:

> 「请打开 [URL] 查看详情。需要切换'非开发者/开发者'视角的话,直接点页面右上角的小标签即可。」
