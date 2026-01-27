# Claude Plugin Marketplace

A curated collection of useful plugins for Claude Code.

## Available Plugins

| Plugin | Description | Tags |
|--------|-------------|------|
| [claude-md](./plugins/claude-md) | A plugin for managing CLAUDE.md configurations with auto-update detection | configuration, productivity, hooks |
| [darwin](./plugins/darwin) | Automatic error-fixing plugin that offloads runtime errors to dedicated agents, preserving main conversation context | error-handling, agents, automation |
| [socratic-questioning](./plugins/socratic-questioning) | A plugin that guides Claude to use Socratic questioning methods to clarify unclear prompts before action | thinking, methodology, hooks |

## Installation

### Method 1: Add Marketplace and Install Plugins (Recommended)

First, add this marketplace to Claude Code:

```
/plugin marketplace add kenxcomp/yoyo
```

Then install the plugins you need:

```
/plugin install claude-md@kenxcomp-yoyo
/plugin install darwin@kenxcomp-yoyo
/plugin install socratic-questioning@kenxcomp-yoyo
```

### Method 2: Interactive UI

Use the interactive plugin manager:

```
/plugin
```

Navigate to **Marketplaces** tab → Add this marketplace → Switch to **Discover** tab → Install desired plugins.

### Method 3: Local Development

Clone the repository and load plugins locally for development/testing:

```bash
git clone https://github.com/kenxcomp/yoyo.git
claude --plugin-dir ./yoyo/plugins/claude-md
```

> **Note**: Requires Claude Code version 1.0.33 or later. Check with `claude --version`.

## Plugin Structure

Each plugin follows this standard structure:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json      # Plugin metadata and configuration
├── hooks/               # Hook definitions
├── commands/            # Custom commands
├── agents/              # Custom agents
├── skills/              # Custom skills
└── README.md            # Plugin documentation
```

## Plugin Features

### claude-md Plugin

The `claude-md` plugin provides automatic detection of major updates during your work session. Key features:

- **Stop Hook**: Automatically evaluates if changes warrant a CLAUDE.md update
- **Smart Detection**: Uses LLM to identify code architecture, functional, and configuration changes
- **Update Skill**: Guides users through updating or creating CLAUDE.md

### darwin Plugin

The `darwin` plugin provides automatic error-fixing by offloading runtime errors to dedicated agents. Key features:

- **SessionStart Hook**: Injects skill awareness at session start
- **Auto-Fixer Skill**: Triggers when runtime errors are encountered (Python, Bash, build, test failures)
- **Error-Fixer Agent**: Analyzes errors, implements fixes, verifies solutions, and returns summaries
- **Config-Fixer Agent**: Logs solutions and updates configurations for future reference

**Error Categories Handled:**
- File/Path errors (FileNotFoundError, missing directories)
- Import errors (ModuleNotFoundError, missing dependencies)
- Syntax errors (Python syntax, JSON parse errors)
- Runtime errors (TypeError, AttributeError)
- Build errors (npm, cargo, make, gradle failures)
- Test failures (pytest, jest, vitest)
- Permission errors

### socratic-questioning Plugin

The `socratic-questioning` plugin uses Socratic questioning methodology to ensure clarity before taking action. Key features:

- **UserPromptSubmit Hook**: Evaluates every user prompt for clarity
- **Multi-round Dialogue**: Asks ONE focused question at a time until requirements are clear
- **Bilingual Support**: Automatically detects and responds in user's language (English/Chinese)
- **No Inference**: Never assumes or guesses - always asks to confirm

**Clarity Criteria:**
- Specificity (are vague terms defined?)
- Context (is scope/environment provided?)
- Requirements (are expected outcomes clear?)
- Assumptions (are implicit beliefs identified?)
- Constraints (are limitations specified?)

## Contributing

1. Fork this repository
2. Create your plugin directory under `plugins/`
3. Follow the standard plugin structure
4. Submit a pull request

## License

MIT
