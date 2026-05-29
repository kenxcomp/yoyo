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
| `plan-guardian` | 1.5.1 | Non-blocking plan review via agent and `/plan-review` skill. **v1.3.0**: opt-out **codex review gate** — `PreToolUse:ExitPlanMode` hook blocks plan-mode exits until `/plan-guardian:codex-plan-review` loops `codex exec` against the plan and revises it until Codex emits the literal `NO_CONCERNS`; a sha256 sentinel (`./.plan-review/.codex-review-done`) confirms the exact plan was the one approved. `CODEX_PLAN_REVIEW=0` disables the gate; codex CLI missing → hook is a silent no-op. Per-round audit trail in `./.plan-review/codex-rounds/`. **v1.3.1**: the `codex exec` invocation in the slash command now mandates `< /dev/null` — in non-TTY contexts (Claude Code's Bash tool, agent runners) Codex otherwise treats the pipe stdin as a `<stdin>` prompt block and blocks indefinitely waiting for input. **v1.4.0**: new **`/plan-guardian:setup`** command fixes the repeated plan-mode permission prompts — the codex loop runs *while still in plan mode*, where Write/Edit/Bash prompt like `default` mode, so every `./.plan-review/` write + `codex exec` asks for approval. Root cause is plan mode, **not** the state-file location: `./.plan-review/` is a non-protected dir (correct, intentional); `.claude/` is a Claude Code **protected path** that would prompt *harder* (allow rules can't override it). Setup adds scoped allow-rules (`Edit/Write(.plan-review/**)`, `Bash(codex exec *)`, and a `Bash(<install-dir>/plan-guardian/*/scripts/plan-review-helper.sh *)` rule) to `~/.claude/settings.json` — shown + confirmed + backed up + idempotent jq-merge. The loop's `mkdir` and the fragile `printf\|shasum>file` sentinel pipe are consolidated into a pre-approvable `scripts/plan-review-helper.sh` (`init` / `sentinel <file>`, hash normalization byte-identical to the hook). Caveat: open upstream bugs where allowlist intermittently fails to suppress prompts under mode toggles. **v1.4.1**: helper allow-rule **wildcards the version segment** of the install path — `${CLAUDE_PLUGIN_ROOT}` is expanded by Claude Code (before the command runs) to a version-stamped cache dir (`…/plan-guardian/<version>`), so a pinned rule broke on every plugin update; there is no literal-`${CLAUDE_PLUGIN_ROOT}` rule because that form never reaches the permission matcher. **v1.5.0**: replaces the on-disk sha256 **sentinel** with an **inline review marker** carried inside the plan text. On convergence the codex loop appends `<!-- codex-reviewed:<token> -->` as the plan's **last line**; the `ExitPlanMode` hook strips that line, recomputes the token over the plan body, and allows the call iff it matches. The token is minted/verified by a single shared `plan-review-helper.sh digest` subcommand (so mint and verify can't drift): `h1:<sha256(secret"\n"body)>` when `CODEX_REVIEW_SECRET` is set (content-bound — revising the plan re-arms the gate), or the literal `l1:none` when unset (works, but spoofable; fine for single-user). The loop now writes **nothing** to disk in plan mode — the proof rides through `tool_input.plan`, the in-memory channel — which **eliminates the Write/Edit prompts entirely** and thus the upstream flaky-allow-list bug for the gate's core; only two Bash calls remain (`codex exec` + the digest mint), and `/plan-guardian:setup` is trimmed to those two `Bash()` rules (no more `Edit/Write(.plan-review/**)`). The hook still writes `./.plan-review/yoplan-pending.md` as a fallback copy, but that is a plain hook-process write (ungated). Implementation note: the deny-path heredoc is fed straight into `jq -Rs` rather than wrapped in `$(cat <<'EOF')` — macOS's stock bash 3.2.57 misparses a quoted heredoc nested in `$(...)` at runtime (executes the body as commands; `bash -n` does not catch it). **v1.5.1**: makes content-binding the **default**. `plan-review-helper.sh` now resolves the signing key in priority order — `$CODEX_REVIEW_SECRET` if set, else a **per-machine auto key file** `~/.claude/plan-guardian/secret` (`$CODEX_REVIEW_SECRET_FILE` overridable; generated `mode 600` via `openssl rand`/`/dev/urandom` on first use, `umask 077` + noclobber subshell so concurrent creators don't race), else the literal `l1:none` fallback **only** when no key can be established (unwritable `HOME` and no random source). So every user gets the content-bound `h1:` marker with zero setup, not the spoofable literal. The helper writes the key file as a plain shell `>` redirect (not Claude Code's Write tool), so `~/.claude/` being a protected path doesn't block it. |
| `socratic-questioning` | 2.0.0 | Clarify unclear prompts using multiple choice Socratic questions (skill-based) |
| `bug-fix-testcase` | 1.1.1 | End-to-end /bugfix command + subagent in isolated git worktree for regression tests |
| `codex-cr-loop` | 1.5.0 | Iterate `/codex:review` until two clean rounds; three completion modes (stop / merge / PR). Auto-widening sweep shared by all three commands (default ON, capped at `CR_LOOP_MAX_WIDENING_SWEEPS=2` per invocation). Round cap is opt-in (no default ceiling). **v1.3.0**: always-on interaction-logic guard pauses the loop and asks the user (via `form-base` form or inline) before any commit that would change user-visible interaction behavior (gestures, dialog/menu/sheet types, keyboard shortcuts, accessibility actions, navigation flow, default actions) — no env override; "no response" is never consent. **v1.4.0**: final report always ends with a Chinese **Business-impact summary** module — 3–8 lines when commits change user-observable behavior (功能/默认值/UI 交互/对外契约/文案 等),或固定字面值 `无业务逻辑影响` 在 commit 仅为纯代码层重构时(下游工具可据此字符串识别"无需回归")。 **v1.5.0**: preflight base-currency gate hard-stops each command before the first review round when the feature branch isn't built on top of its base (`git merge-base --is-ancestor "$BASE" HEAD` fails) — confirms with the user (rebase-first / abort, no "review anyway"), never auto-rebases; each command checks its own **auto-detected default branch** (`origin/<default>` for `/cr-loop` + `/cr-loop-pr`, local `<default>` for `/cr-loop-merge`; `main`/`master`/any, resolved via a local `git symbolic-ref refs/remotes/origin/HEAD` read — no network); disable the gate via `CR_LOOP_REQUIRE_REBASED=0`. |
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
