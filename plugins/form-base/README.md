# form-base

HTML interaction base for Claude Code & Codex. Lets agents:

1. **Ask via forms** — emit radio / checkbox / text / markdown questions plus color / font / slider style previews to a local HTML page; user fills, clicks save, returns to CLI and says "I'm done"; agent reads the answers and continues.
2. **Render long responses** — when a reply is long or contains code, render it as HTML where the **business view is shown by default** and **code / file changes / technical details are hidden behind a collapsed toggle**. Treats the reader as a non-developer unless told otherwise.

Cross-tool: works in Claude Code (via plugin) and Codex (via MCP config).

## Install

### Claude Code
```bash
/plugin marketplace add kenxcomp/yoyo
/plugin install form-base@yoyo
```
Restart your session. The plugin auto-starts the MCP server and injects a SessionStart skill.

### Codex
Install bun first (`brew install oven-sh/bun/bun`), clone the marketplace somewhere, then add to `~/.codex/config.toml`:

```toml
[mcp_servers.form-base]
command = "bun"
args = ["/abs/path/to/yoyo/plugins/form-base/mcp-server/src/index.ts"]
```

(Once published to npm: `command = "bunx"`, `args = ["@kenxyoyo/form-base-mcp"]`.)

## How it works

The MCP server exposes 10 tools across two modes:

**Form mode (collect input):**
- `create_form(title, items[], description?, style_suggestions?)` → `{form_id, url}`
- `get_form_status(form_id)` → `{status, submitted_at?}`
- `read_answers(form_id)` → `{answers, submitted_at}`
- `list_forms(status?)`, `archive_form(form_id)`, `reopen_form(form_id)`

**Response mode (render long output):**
- `render_response(title, business, technical?, user_role?)` → `{response_id, url}`
- `list_responses(status?)`, `archive_response(response_id)`, `reopen_response(response_id)`

The server runs an embedded HTTP server on `localhost:<random-port>` and serves HTML at `/forms/<id>` (writable form) and `/responses/<id>` (read-only response with toggle).

State lives in `<cwd>/.form-base/`:
```
.form-base/
├── forms/<id>/{definition.json, state.json, answers.json}
├── responses/<id>/{content.json, meta.json}
└── config.json   (default_user_role, response thresholds, ...)
```

## Slash commands (Claude Code)

- `/form-init` — initialise `.form-base/` in the current project
- `/form-list` — list active / archived forms
- `/form-show <id>` — re-open a form's URL
- `/form-status` — overview of current form/response state
- `/response-list` — list responses
- `/response-show <id>` — re-open a response's URL

## Skill prompt (auto-injected at SessionStart)

Tells the agent when to use forms vs responses vs plain CLI text. The agent decides — there's no hard interception.

## Storage hygiene

`.form-base/.gitignore` is created on `/form-init`, ignoring `answers.json`, `state.json`, and `meta.json` by default. Keep `definition.json` and `content.json` committed so PRs can review what was asked / answered.

## Development

```bash
cd mcp-server
bun install
bun run src/index.ts          # starts MCP stdio + embedded HTTP
```

## License

MIT — © kenxcomp 2026
