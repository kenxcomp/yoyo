# bug-fix-testcase Plugin

Automatically spawns a subagent in an isolated git worktree to write regression test cases while you fix bugs, preventing the same bug from recurring.

## Overview

When you're fixing a bug, this plugin can spawn a dedicated **testcase-writer** agent that works in parallel — in an isolated git worktree — to write targeted regression tests. This ensures the specific bug never recurs while keeping your main workflow uninterrupted.

## Components

| Component | Type | Description |
|-----------|------|-------------|
| `inject-skill.sh` | SessionStart Hook | Injects skill awareness at session start |
| `detect-bugfix.sh` | UserPromptSubmit Hook | Auto-detects bug-fixing keywords in user prompts |
| `bug-fix-testcase` | Skill | Orchestrates the testcase-writer agent invocation |
| `testcase-writer` | Agent (opus) | Writes regression tests in an isolated git worktree |
| `bugfix` | Command | End-to-end bug fix workflow: analyze, research, plan, fix + test, merge, verify |

## Usage

### Automatic Detection

The plugin automatically detects bug-fixing intent from keywords in your messages:
- "fix bug", "bugfix", "hotfix", "patch", "regression", "defect"
- Chinese: "修复", "修bug"

When detected, Claude will suggest spawning the testcase-writer agent.

### Manual Invocation

```
/bug-fix-testcase
```

### /bugfix Command

Full end-to-end bug fix workflow:

```
/bug-fix-testcase:bugfix <bug description or issue reference>
```

**Workflow:**

| Phase | Name | Description |
|-------|------|-------------|
| 1 | **Analyze** | Read code, trace the bug, identify root cause |
| 2 | **Web Search** | Search Stack Overflow / GitHub Issues for solutions |
| 3 | **Plan & Confirm** | Present fix plan, wait for user approval |
| 4 | **Fix + Module Tests** | Implement fix + spawn testcase-writer agent in parallel |
| 5 | **Merge + Unit Tests** | Cherry-pick module tests, then write additional unit tests |
| 6 | **Verify** | Run full test suite, iterate if failures remain |

**Examples:**

```bash
# Describe the bug in natural language
/bug-fix-testcase:bugfix login form crashes when email contains a plus sign

# Reference a specific file
/bug-fix-testcase:bugfix negative prices in src/pricing.py when discount > 100%

# Reference an issue
/bug-fix-testcase:bugfix #42 session timeout not handled correctly
```

## Supported Test Frameworks

| Language | Framework | Config Files |
|----------|-----------|-------------|
| Python | pytest | `pytest.ini`, `conftest.py`, `setup.cfg`, `pyproject.toml` |
| JavaScript | Jest | `jest.config.js`, `jest.config.ts` |
| JavaScript | Vitest | `vitest.config.js`, `vitest.config.ts` |
| TypeScript | Jest / Vitest | Same as JavaScript |
| Rust | cargo test | `Cargo.toml` `[dev-dependencies]` |
| Go | go test | `*_test.go` convention |
| Ruby | RSpec | `.rspec`, `spec/` directory |
| Java | JUnit | `pom.xml`, `build.gradle` |

## Directory Structure

```
bug-fix-testcase/
├── .claude-plugin/
│   └── plugin.json              # Plugin metadata
├── hooks/
│   └── hooks.json               # SessionStart + UserPromptSubmit hooks
├── scripts/
│   ├── inject-skill.sh          # Skill awareness injection
│   └── detect-bugfix.sh         # Bug-fix keyword detection
├── skills/
│   └── bug-fix-testcase/
│       └── SKILL.md             # Skill documentation and usage guide
├── agents/
│   └── testcase-writer.md       # Testcase-writer agent definition
├── commands/
│   └── bugfix.md              # End-to-end bug fix workflow command
└── README.md                    # This file
```

## Worktree Management

The agent creates worktrees under `.bug-fix-testcase/worktree-<timestamp>` with branch names like `bugfix-tests-<timestamp>`.

### Merging Tests

After the agent completes, choose a merge strategy:

```bash
# Cherry-pick specific commits
git cherry-pick <commit-hash>

# Copy test files directly
git checkout <branch-name> -- <test-file-path>

# Merge the entire branch
git merge <branch-name>
```

### Cleanup

Always check for unmerged commits before cleaning up:

```bash
# Check for unmerged work
git log main..<branch-name>

# Remove worktree and branch
git worktree remove .bug-fix-testcase/worktree-<timestamp>
git branch -d <branch-name>
```

## Installation

```
/plugin install bug-fix-testcase@kenxcomp-yoyo
```

## Version History

| Version | Changes |
|---------|---------|
| 1.1.0 | Add `/bugfix` command for end-to-end bug fix workflow (analyze, research, plan, fix + parallel tests, merge, verify) |
| 1.0.0 | Initial release: SessionStart + UserPromptSubmit hooks, testcase-writer agent, auto-detection |
