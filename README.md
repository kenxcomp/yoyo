# Claude Plugin Marketplace

A curated collection of useful plugins for Claude Code.

## Available Plugins

| Plugin | Description | Tags |
|--------|-------------|------|
| [claude_md](./plugins/claude_md) | A plugin for managing CLAUDE.md configurations | configuration, productivity |
| [Socratic_Questioning](./plugins/Socratic_Questioning) | A plugin that guides Claude to use Socratic questioning methods | thinking, methodology |

## Installation

### Method 1: Clone the entire marketplace

```bash
git clone https://github.com/kennethx/claude-plugin-marketplace.git
```

### Method 2: Download individual plugin

Navigate to the plugin directory and follow the plugin-specific installation instructions.

## Plugin Structure

Each plugin follows this standard structure:

```
plugin-name/
├── .claude-plugin/
│   └── plugin.json      # Plugin metadata and configuration
├── commands/            # Custom commands
├── agents/              # Custom agents
├── skills/              # Custom skills
└── README.md            # Plugin documentation
```

## Contributing

1. Fork this repository
2. Create your plugin directory under `plugins/`
3. Follow the standard plugin structure
4. Submit a pull request

## License

MIT
