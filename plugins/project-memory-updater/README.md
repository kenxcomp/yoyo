# Project Memory Updater Plugin

A plugin for managing CLAUDE.md configurations with automatic update detection.

## Installation

### Method 1: Via Marketplace (Recommended)

```
/plugin marketplace add kenxcomp/yoyo
/plugin install project-memory-updater@yoyo
```

### Method 2: Local Development

```bash
git clone https://github.com/kenxcomp/yoyo
claude --plugin-dir ./yoyo/plugins/project-memory-updater
```

> **Note**: Requires Claude Code version 1.0.33 or later.

## Features

### Auto-Update Detection (Hook)

This plugin uses a **SessionStart hook** to inject CLAUDE.md update awareness into each new session. After significant work in a git repository, Claude then asks whether you want to update your project's `CLAUDE.md` file.

**Major updates include:**
- **Code architecture changes**: New modules, refactoring, core logic changes
- **Functional changes**: New features, removed features, API changes
- **Configuration/specification changes**: Project config, coding standards, dependencies

### Update CLAUDE.md Skill

When a major update is detected, the plugin can guide you through updating or creating a `CLAUDE.md` file:

- If `CLAUDE.md` exists: Proposes updates based on recent changes
- If `CLAUDE.md` doesn't exist: Offers to create one using `/init`

## Directory Structure

```
project-memory-updater/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata
├── hooks/
│   └── hooks.json            # SessionStart hook definition
├── scripts/
│   └── inject-skill.sh       # Emits the awareness prompt as additionalContext
├── skills/
│   └── update-claude-md/SKILL.md   # CLAUDE.md update skill
├── commands/                 # Custom commands (reserved)
├── agents/                   # Custom agents (reserved)
└── README.md                 # This file
```

## How It Works

1. A new session starts; the SessionStart hook (`matcher: startup`) runs `scripts/inject-skill.sh`
2. The script adds the update-awareness instructions to the session as `additionalContext`
3. After significant work in a git repository, Claude asks if you want to update `CLAUDE.md`
4. If confirmed, the update skill guides the process

## Configuration

- Hook type: `command` (shell script, no LLM call in the hook itself)
- Triggers on: new session startup (not on resume or compaction)
- Timeout: 5 seconds
- Scope: the injected instructions tell Claude to ask only in git repositories and only for significant changes; Claude makes that judgment during the session

## License

MIT
