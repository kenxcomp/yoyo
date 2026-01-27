---
name: auto-fixer
description: Automatically fix runtime errors by invoking the error-fixer agent. Use when encountering Python script errors, Bash command failures, build failures (npm, cargo, make), test failures (pytest, jest), or any blocking error that interrupts the main workflow.
---

# Auto-Fixer Skill

Automatically invoke the error-fixer agent when runtime errors occur, preserving main conversation context.

## When to Use This Skill

**Invoke this skill when:**
- Python script execution fails with errors
- Bash commands return non-zero exit codes with error messages
- Build processes fail (npm, cargo, make, gradle, etc.)
- Test suites fail (pytest, jest, vitest, cargo test, etc.)
- Any runtime error blocks the current workflow
- Repeated attempts to fix an error have failed

**DO NOT use when:**
- Error is trivial and obvious (e.g., typo in filename)
- User explicitly says they'll handle it themselves
- Error is a user-input validation issue (not a code bug)
- The error message is already clear and the fix is one-line

## Core Principle

**Preserve main context** - Instead of spending main conversation turns debugging errors, offload the work to a dedicated agent that can iterate on the fix without consuming your context window.

## How to Use

When you encounter an error that matches the trigger conditions above, immediately invoke the error-fixer agent using the Task tool:

```
Task tool call:
- subagent_type: "darwin:error-fixer"
- prompt: Include the full error output, the command/script that failed, and any relevant context about what you were trying to accomplish
- description: "Fix [type] error"
```

### Example Task Call

```
subagent_type: "darwin:error-fixer"
prompt: |
  Error encountered while running Python script:

  Command: python3 scripts/process_data.py

  Error output:
  Traceback (most recent call last):
    File "scripts/process_data.py", line 45, in <module>
      df = pd.read_csv(input_path)
  FileNotFoundError: [Errno 2] No such file or directory: 'data/input.csv'

  Context: I was trying to process data files as part of the data pipeline setup.
  The script expects input files in the data/ directory.

description: "Fix Python FileNotFoundError"
```

## What the Agent Does

The error-fixer agent will:

1. **Analyze** the error message and context
2. **Diagnose** the root cause
3. **Implement** a fix (modifying code, creating missing files/directories, etc.)
4. **Verify** the fix by re-running the command
5. **Log** the solution via the config-fixer agent (for future reference)
6. **Return** a summary of what was fixed

## Response Handling

After the agent completes:
- Review the summary returned
- Continue with your original task
- The fix has been applied and verified

## Error Categories Handled

| Category | Examples |
|----------|----------|
| **File/Path Errors** | FileNotFoundError, missing directories, wrong paths |
| **Import Errors** | ModuleNotFoundError, missing dependencies |
| **Syntax Errors** | Python syntax errors, JSON parse errors |
| **Runtime Errors** | TypeErrors, AttributeErrors, index out of bounds |
| **Build Errors** | Compilation failures, missing build tools |
| **Test Failures** | Assertion failures, fixture errors, timeout errors |
| **Permission Errors** | Permission denied, access errors |
| **Network Errors** | Connection refused, timeout (for local services) |

## Anti-Patterns to Avoid

| DO NOT | DO INSTEAD |
|--------|------------|
| Try multiple manual fixes in main context | Invoke auto-fixer immediately after 1-2 failed attempts |
| Ignore error and continue | Address the error before proceeding |
| Ask user to fix trivial errors | Let the agent handle fixable errors automatically |
| Spend many turns analyzing errors | Offload analysis to the agent |

## Benefits

- **Context preservation**: Main conversation stays focused on the task
- **Iterative debugging**: Agent can try multiple approaches without context cost
- **Knowledge capture**: Solutions are logged for future reference
- **Faster resolution**: Dedicated focus on the error without distraction
