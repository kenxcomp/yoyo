# Claude Plugin Marketplace

A curated collection of useful plugins for Claude Code.

## Available Plugins

| Plugin | Description | Tags |
|--------|-------------|------|
| [claude-md](./plugins/claude-md) | A plugin for managing CLAUDE.md configurations with auto-update detection | configuration, productivity, hooks |
| [darwin](./plugins/darwin) | Automatic error-fixing plugin that offloads runtime errors to dedicated agents, preserving main conversation context | error-handling, agents, automation |
| [plan-guardian](./plugins/plan-guardian) | Plan review workflow plugin that ensures plans are rigorously reviewed before execution | planning, review, agents, quality |
| [socratic-questioning](./plugins/socratic-questioning) | A plugin that guides Claude to use Socratic questioning methods to clarify unclear prompts before action | thinking, methodology, hooks |
| [bug-fix-testcase](./plugins/bug-fix-testcase) | End-to-end `/bugfix` command + subagent in isolated git worktree for regression tests | testing, bugfix, regression, agents, worktree |

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
/plugin install plan-guardian@kenxcomp-yoyo
/plugin install socratic-questioning@kenxcomp-yoyo
/plugin install bug-fix-testcase@kenxcomp-yoyo
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

### plan-guardian Plugin

The `plan-guardian` plugin enforces rigorous plan review before execution. Key features:

- **SessionStart Hook**: Injects Plan Mode Rules into every session as additionalContext
- **ExitPlanMode Hook**: Blocks exiting plan mode until the plan-reviewer agent has approved the plan
- **EnterPlanMode Hook**: Clears previous review state when entering a new planning session
- **Plan-Reviewer Agent**: Evaluates plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent)
- **/plan-review Skill**: Manually trigger a plan review at any time

**Review Workflow:**
1. Enter plan mode → previous review state is cleared
2. Write plan to `.plan-review/yoplan.md`
3. Launch plan-reviewer agent → evaluates all 8 criteria
4. If approved, ExitPlanMode is unblocked
5. If blocked, re-run plan-reviewer and retry

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

### bug-fix-testcase Plugin

The `bug-fix-testcase` plugin spawns a dedicated agent to write regression tests while you fix bugs. Key features:

- **SessionStart Hook**: Injects skill awareness at session start
- **UserPromptSubmit Hook**: Auto-detects bug-fixing keywords (fix bug, bugfix, hotfix, patch, regression, defect)
- **Bug-Fix Skill**: Orchestrates the testcase-writer agent invocation with bug context
- **Testcase-Writer Agent** (opus): Writes regression tests in an isolated git worktree
- **/bugfix Command**: End-to-end workflow — analyze → web search → plan → fix + parallel tests → merge → verify

**Usage:**
```
/bug-fix-testcase:bugfix <bug description or issue reference>
```

**Supported Test Frameworks:**
- Python (pytest), JavaScript (Jest, Vitest), TypeScript, Rust (cargo test), Go (go test), Ruby (RSpec), Java (JUnit)

**Worktree Isolation:**
- Tests are written in `.bug-fix-testcase/worktree-<timestamp>` on a separate branch
- Merge via `git cherry-pick`, `git checkout -- <file>`, or `git merge`
- Clean up with `git worktree remove <path>`

## Contributing

1. Fork this repository
2. Create your plugin directory under `plugins/`
3. Follow the standard plugin structure
4. Submit a pull request

## License

MIT
