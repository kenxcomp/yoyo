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
│   └── bug-fix-testcase/     # Plugin for regression test generation during bug fixes
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
| `plan-guardian` | 1.0.0 | Plan review workflow enforcement via agent, hooks, and skill |
| `socratic-questioning` | 2.0.0 | Clarify unclear prompts using multiple choice Socratic questions (skill-based) |
| `bug-fix-testcase` | 1.0.0 | Spawn subagent in isolated git worktree to write regression tests while fixing bugs |

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
