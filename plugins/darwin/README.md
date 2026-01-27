# Darwin Plugin

Automatic error-fixing plugin for Claude Code that offloads runtime error resolution to dedicated agents, preserving main conversation context.

## Overview

When Claude encounters runtime errors during task execution, the Darwin plugin automatically invokes a specialized error-fixer agent. This approach:

- **Preserves context**: Main conversation doesn't get cluttered with debugging iterations
- **Enables iteration**: The agent can try multiple fixes without consuming your context window
- **Captures knowledge**: Solutions are logged for future reference via config-fixer

## Components

### Skill: `auto-fixer`

Injected at session start, this skill triggers when errors are encountered:

- Python script execution errors
- Bash command failures
- Build failures (npm, cargo, make, gradle)
- Test failures (pytest, jest, vitest)
- Any blocking runtime error

### Agent: `error-fixer`

A dedicated agent that:

1. Analyzes the error message and context
2. Diagnoses the root cause
3. Implements the minimal fix needed
4. Verifies the fix by re-running the command
5. Logs the solution via `claude-config-fixer`
6. Returns a summary to the main conversation

### Agent: `claude-config-fixer`

Handles knowledge capture by:

- Logging error fixes to `update.md`
- Updating configuration files when appropriate
- Preserving solutions for future reference

## Usage

The plugin works automatically once installed. When you encounter an error:

1. Claude detects the error matches the skill trigger conditions
2. The `auto-fixer` skill is invoked
3. The `error-fixer` agent is spawned to handle the fix
4. A summary is returned to your main conversation
5. You continue with your original task

### Manual Invocation

You can also explicitly request error fixing:

```
Please use the darwin:auto-fixer skill to fix this error
```

## Error Categories Handled

| Category | Examples |
|----------|----------|
| File/Path Errors | FileNotFoundError, missing directories |
| Import Errors | ModuleNotFoundError, missing dependencies |
| Syntax Errors | Python syntax errors, JSON parse errors |
| Runtime Errors | TypeErrors, AttributeErrors |
| Build Errors | Compilation failures, missing build tools |
| Test Failures | Assertion failures, fixture errors |
| Permission Errors | Permission denied, access errors |

## Installation

Via Claude Code plugin system:

```
/plugin install yoyo:darwin
```

## Version History

### v1.0.0
- Initial release
- Auto-fixer skill for automatic error detection
- Error-fixer agent for isolated debugging
- Integration with claude-config-fixer for solution logging
