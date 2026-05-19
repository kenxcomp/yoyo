# CLAUDE.md

## Project Overview

**yoyo** is a curated collection of Claude Code plugins, published via the marketplace system.

## Directory Structure

```
yoyo/
├── .claude-plugin/
│   └── marketplace.json      # Marketplace registry (lists all plugins with versions)
├── plugins/
│   ├── claude-md/            # Plugin for CLAUDE.md auto-update detection
│   ├── darwin/               # Plugin for automatic error-fixing
│   ├── plan-guardian/        # Plugin for plan review workflow enforcement
│   ├── socratic-questioning/ # Plugin for Socratic clarification questions
│   ├── bug-fix-testcase/     # Plugin for regression test generation during bug fixes
│   ├── codex-cr-loop/        # Plugin for /codex:review loop with three completion modes
│   └── form-base/            # MCP-backed HTML form & rich-response base (Claude Code + Codex)
└── CLAUDE.md                 # This file
```

## Plugin Structure

Each plugin follows this structure:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata (name, version, description)
├── hooks/
│   └── hooks.json            # Hook definitions
├── skills/
│   └── skill-name/SKILL.md   # Skill documentation
├── commands/                 # Custom commands (reserved)
├── agents/                   # Custom agents (reserved)
└── README.md                 # Plugin documentation
```

### Plugins that ship an MCP server

`form-base` is the first plugin in this marketplace that bundles a local MCP server. The pattern:

```
form-base/
├── .claude-plugin/plugin.json
├── .mcp.json                  # tells Claude Code to spawn the bundled server
├── mcp-server/                 # publishable as @kenxyoyo/form-base-mcp
│   ├── package.json            # bin: form-base-mcp
│   ├── tsconfig.json
│   ├── src/                    # MCP entry, HTTP server, tool implementations
│   └── public/                 # browser-side HTML/CSS/JS served by the embedded HTTP
├── commands/, hooks/, skills/, scripts/  # standard plugin pieces
└── README.md / README_CN.md
```

Key wiring:
- `.mcp.json` uses `${CLAUDE_PLUGIN_ROOT}` so the server runs from the plugin directory:
  ```json
  { "mcpServers": { "form-base": { "command": "bun", "args": ["${CLAUDE_PLUGIN_ROOT}/mcp-server/src/index.ts"] } } }
  ```
- The MCP server starts an embedded HTTP server on `localhost:0` and serves both `/forms/<id>` (writable) and `/responses/<id>` (read-only) under that random port.
- All persistent state lives under `<cwd>/.form-base/` (project-scoped); the MCP server's own working directory is whatever Claude Code / Codex spawns it with.
- For Codex, install via `~/.codex/config.toml` referencing the same `mcp-server/src/index.ts` (or `bunx @kenxyoyo/form-base-mcp` once published).

## Development Guidelines

### Version Management (CRITICAL)

When updating a plugin, you **MUST** update versions in THREE places to ensure Claude Code detects the update:

| File | Location | Purpose |
|------|----------|---------|
| `plugin.json` | `plugins/<name>/.claude-plugin/plugin.json` | Plugin's own version |
| `marketplace.json` | `.claude-plugin/marketplace.json` | Marketplace registry version |
| `README.md` | (optional) Document version in changelog | User-facing documentation |

**Example version bump workflow:**

```bash
# 1. Update plugin.json
plugins/socratic-questioning/.claude-plugin/plugin.json
→ "version": "1.1.0"

# 2. Update marketplace.json (MUST match plugin.json)
.claude-plugin/marketplace.json
→ "version": "1.1.0"

# 3. Commit with version in message
git commit -m "feat: new feature in plugin-name v1.1.0"
```

**Why this matters:** If versions are not synced, users running `/plugin update` may not receive the latest changes even after merging to main.

### Hook Development

- Prefer `type: "command"` with shell scripts for reliable JSON output
- Use `type: "prompt"` only when LLM evaluation is necessary (note: JSON output is not guaranteed)
- For skill injection, use `SessionStart` hook with `additionalContext` in `hookSpecificOutput`
- Always set reasonable `timeout` (default: 30 seconds for prompts, 5 seconds for commands)

### Socratic Questioning Plugin Conventions

- **ALWAYS use multiple choice questions** with (A), (B), (C) options
- Ask ONE question at a time
- Focus on: Purpose → Constraints → Success Criteria
- Support bilingual (English/Chinese) responses

## Current Plugins

| Plugin | Version | Description |
|--------|---------|-------------|
| `claude-md` | 1.1.0 | Auto-detect major updates and prompt for CLAUDE.md updates (skill-based) |
| `darwin` | 1.0.0 | Automatic error-fixing via dedicated agent, preserves main conversation context |
| `plan-guardian` | 1.3.1 | Non-blocking plan review via agent and `/plan-review` skill. **v1.3.0**: opt-out **codex review gate** — `PreToolUse:ExitPlanMode` hook blocks plan-mode exits until `/plan-guardian:codex-plan-review` loops `codex exec` against the plan and revises it until Codex emits the literal `NO_CONCERNS`; a sha256 sentinel (`./.plan-review/.codex-review-done`) confirms the exact plan was the one approved. `CODEX_PLAN_REVIEW=0` disables the gate; codex CLI missing → hook is a silent no-op. Per-round audit trail in `./.plan-review/codex-rounds/`. **v1.3.1**: the `codex exec` invocation in the slash command now mandates `< /dev/null` — in non-TTY contexts (Claude Code's Bash tool, agent runners) Codex otherwise treats the pipe stdin as a `<stdin>` prompt block and blocks indefinitely waiting for input. |
| `socratic-questioning` | 2.0.0 | Clarify unclear prompts using multiple choice Socratic questions (skill-based) |
| `bug-fix-testcase` | 1.1.1 | End-to-end /bugfix command + subagent in isolated git worktree for regression tests |
| `codex-cr-loop` | 1.4.0 | Iterate `/codex:review` until two clean rounds; three completion modes (stop / merge / PR). Auto-widening sweep shared by all three commands (default ON, capped at `CR_LOOP_MAX_WIDENING_SWEEPS=2` per invocation). Round cap is opt-in (no default ceiling). **v1.3.0**: always-on interaction-logic guard pauses the loop and asks the user (via `form-base` form or inline) before any commit that would change user-visible interaction behavior (gestures, dialog/menu/sheet types, keyboard shortcuts, accessibility actions, navigation flow, default actions) — no env override; "no response" is never consent. **v1.4.0**: final report always ends with a Chinese **Business-impact summary** module — 3–8 lines when commits change user-observable behavior (功能/默认值/UI 交互/对外契约/文案 等),或固定字面值 `无业务逻辑影响` 在 commit 仅为纯代码层重构时(下游工具可据此字符串识别"无需回归")。 |
| `form-base` | 1.1.0 | MCP-backed HTML interaction base for Claude Code + Codex: forms (radio/checkbox/text/markdown + color/font/slider), rich-response views, and a SessionStart-injected role persona (product-manager default; developer / lawyer / null via `/form-base:role`). Role shapes answer style only. |

## Lessons Learned

### 2024-01: Plugin Version Sync Issue

**Problem:** After merging plugin changes to main, `/plugin update` did not pick up the new changes.

**Root Cause:**
1. `plugin.json` was missing the `version` field
2. `marketplace.json` version was not updated to match

**Solution:**
1. Added `version` field to all `plugin.json` files
2. Ensured `marketplace.json` versions match `plugin.json` versions
3. Established workflow: always update both files when releasing new versions

**Takeaway:** Version numbers are critical for Claude Code's plugin update detection mechanism.
