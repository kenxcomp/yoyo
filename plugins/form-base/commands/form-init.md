---
description: "Initialize form-base in the current project (creates .form-base/ with config.json and .gitignore)."
---

# /form-init — Initialize form-base in this project

Run these steps:

1. Check whether `<cwd>/.form-base/` exists. If yes, tell the user it's already initialized and show the current config from `.form-base/config.json` (if present).
2. If not initialized, create the directory tree and write defaults using the `Write` tool:
   - `.form-base/config.json`:
     ```json
     {
       "default_user_role": "non-developer",
       "response_threshold_chars": 600,
       "response_threshold_lines": 30,
       "auto_open_browser": false
     }
     ```
   - `.form-base/.gitignore`:
     ```
     # form-base — keep prompts/content under review, ignore live state and answers.
     forms/*/state.json
     forms/*/answers.json
     responses/*/meta.json
     ```
3. Confirm to the user with a short summary: where the directory is, what was set, and a one-liner reminder ("智能体可在需要表单/长响应时直接调用 MCP 工具").

Do not call any MCP tools for this command — write the files directly.
