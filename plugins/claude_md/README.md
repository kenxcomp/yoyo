# Claude MD Plugin

A plugin for managing CLAUDE.md configurations with automatic update detection.

## Installation

### Method 1: Via Marketplace (Recommended)

```
/plugin marketplace add kenxcomp/yoyo
/plugin install claude_md@kenxcomp-yoyo
```

### Method 2: Local Development

```bash
git clone https://github.com/kenxcomp/yoyo
claude --plugin-dir ./yoyo/plugins/claude_md
```

> **Note**: Requires Claude Code version 1.0.33 or later.

## Features

### Auto-Update Detection (Hook)

This plugin uses a **Stop hook** to automatically detect major updates during your work session. When significant changes are made, it will prompt you to update your project's `CLAUDE.md` file.

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
claude_md/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata
├── hooks/
│   └── hooks.json            # Stop hook definition
├── skills/
│   └── update-claude-md.md   # CLAUDE.md update skill
├── commands/                 # Custom commands (reserved)
├── agents/                   # Custom agents (reserved)
└── README.md                 # This file
```

## How It Works

1. You complete work in Claude Code
2. The Stop hook evaluates if changes constitute a "major update"
3. If yes, Claude asks if you want to update `CLAUDE.md`
4. If confirmed, the update skill guides the process

## Configuration

The hook uses LLM-based judgment with the following criteria:
- Timeout: 30 seconds for evaluation
- Triggers on: Session stop
- **Prerequisite**: Only activates in git repositories (non-git directories are skipped)

## License

MIT
