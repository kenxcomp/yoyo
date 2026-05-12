# form-base

HTML interaction base for Claude Code & Codex. Lets agents:

1. **Ask via forms** — emit radio / checkbox / text / markdown questions plus color / font / slider style previews to a local HTML page; user fills, clicks save, returns to CLI and says "I'm done"; agent reads the answers and continues.
2. **Render long responses** — when a reply is long or contains code, render it as HTML where the **business view is shown by default** and **code / file changes / technical details are hidden behind a collapsed toggle**. Treats the reader as a non-developer unless told otherwise.
3. **Inject a communication role** — after install, the agent adopts a **product-manager** persona by default: talk macro (features, user flows, architecture, trade-offs), not micro (file paths, line numbers). Switchable to `developer` / `lawyer` / `null` via slash command. The role shapes ONLY how the agent answers; it never restricts which tools the agent uses or how it executes tasks.

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
└── config.json   (role, default_user_role, response thresholds, ...)
```

## Slash commands (Claude Code)

- `/form-base:role [--product-manager|--developer|--lawyer|--null]` — switch the communication persona (no flag = show current role)
- `/form-init` — initialise `.form-base/` in the current project
- `/form-list` — list active / archived forms
- `/form-show <id>` — re-open a form's URL
- `/form-status` — overview of current form/response state
- `/response-list` — list responses
- `/response-show <id>` — re-open a response's URL

## Role (communication persona)

After install the SessionStart hook injects a role persona that shapes how the agent answers — vocabulary, framing, level of detail. It never gates tool use or task execution.

| Role | When to use | Voice |
|------|-------------|-------|
| `product-manager` *(default)* | Stakeholder reviews; non-technical user; product / scope decisions | Features, user flows, scope, trade-offs, architectural shape. No file paths or line numbers in answers. |
| `developer` | Pairing with another engineer; code-deep work | File paths, line numbers, code blocks, design rationale welcome. |
| `lawyer` | Compliance, IP, data-handling, contractual review | Risk / compliance framing. Surfaces ambiguities. Recommends, does not decide. |
| `null` | Plain Claude Code default | No persona injection. |

Switch:
```bash
/form-base:role --developer
/form-base:role --lawyer
/form-base:role --product-manager
/form-base:role --null            # remove persona entirely
/form-base:role                   # show current role
```

The active role also drives `render_response`'s default `user_role`: `developer` → technical visible by default; others → technical collapsed by default. Personas live in [`scripts/personas.json`](scripts/personas.json) — add new roles by appending to that file and adding a flag to `commands/role.md`.

## Skill prompt (auto-injected at SessionStart)

Tells the agent when to use forms vs responses vs plain CLI text, and which persona to adopt based on the active role. The agent decides — there's no hard interception.

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
