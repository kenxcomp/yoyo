---
name: bug-fix-testcase
description: "Spawn a dedicated subagent in an isolated git worktree to write regression test cases while fixing bugs. Auto-detects test frameworks (pytest, jest, cargo test, go test, etc.) and writes targeted tests that prevent the specific bug from recurring."
user_invocable: true
---

# Bug-Fix Testcase Skill

Spawn a dedicated testcase-writer agent in an isolated git worktree to write regression tests while you fix bugs.

## When to Use This Skill

**Invoke this skill when:**
- User messages contain bug-fixing keywords: "fix bug", "bugfix", "hotfix", "patch", "regression", "defect"
- You are diagnosing or resolving a software defect
- User explicitly invokes `/bug-fix-testcase`
- A bug has been identified and you're about to implement a fix

**DO NOT use when:**
- The task is a new feature (not a bug fix)
- Not in a git repository
- User explicitly says they'll handle tests themselves
- Project has no test infrastructure and user hasn't requested tests
- The bug is trivial (e.g., typo fix with no behavioral impact)

## Prerequisites

- Must be inside a git repository
- Working tree must be clean enough for `git worktree add` (committed or stashed changes)
- A test framework should be present in the project (the agent will auto-detect)

## How to Use

When bug-fixing intent is detected and the user agrees, invoke the testcase-writer agent using the Agent tool:

```
Agent tool call:
- subagent_type: "bug-fix-testcase:testcase-writer"
- isolation: "worktree"
- prompt: |
    Write regression test cases for the following bug:

    **Bug Description**: [What the bug is — symptoms, error messages, incorrect behavior]
    **Root Cause**: [Why the bug happens — the underlying code/logic issue]
    **Affected Files**: [Comma-separated list of source files involved]
    **Fix Approach**: [How the bug will be / is being fixed]
    **Relevant Context**: [Test framework used, existing test patterns, related modules]
- description: "Write regression tests for [bug summary]"
```

### Example Agent Call

```
Agent tool call:
- subagent_type: "bug-fix-testcase:testcase-writer"
- isolation: "worktree"
- prompt: |
    Write regression test cases for the following bug:

    **Bug Description**: The `calculate_discount()` function in `pricing.py` returns negative
    prices when discount percentage exceeds 100%. Users reported being "paid" to buy items.

    **Root Cause**: No upper-bound validation on the `discount_pct` parameter. Values > 100
    cause `price * (1 - discount_pct/100)` to go negative.

    **Affected Files**: src/pricing.py, src/cart.py

    **Fix Approach**: Clamp discount_pct to range [0, 100] at the start of calculate_discount().

    **Relevant Context**: Project uses pytest with fixtures in conftest.py. Existing tests are
    in tests/ directory following test_<module>.py naming convention.
- description: "Write regression tests for negative price bug"
```

## Workflow

```
Main Thread                          Testcase-Writer Agent (worktree)
    |                                        |
    |  [User reports bug]                    |
    |  [Analyze root cause]                  |
    |                                        |
    |--- spawn agent with bug context ------>|
    |                                        |
    |  [Implement fix in main tree]          | [Set up worktree]
    |  [Continue working...]                 | [Explore codebase & test patterns]
    |                                        | [Design test cases]
    |                                        | [Write regression tests]
    |                                        | [Validate tests collect/compile]
    |                                        | [Commit tests]
    |                                        |
    |<--- agent returns summary -------------|
    |                                        |
    |  [Review test summary]                 |
    |  [Merge tests: cherry-pick or merge]   |
    |  [Clean up worktree]                   |
```

## Response Handling

After the agent completes, present these to the user:
- **Test file paths** created in the worktree
- **Test names** and what each tests
- **Merge commands** to integrate the tests:
  - `git cherry-pick <commit-hash>` — pick specific test commits
  - `git checkout <branch> -- <test-file>` — copy test files directly
  - `git merge <branch>` — merge the entire branch
- **Cleanup command**: `git worktree remove <worktree-path>`

The user decides which merge strategy to use.

## Anti-Patterns to Avoid

| DO NOT | DO INSTEAD |
|--------|------------|
| Wait until the fix is complete before spawning the agent | Spawn the agent as soon as you understand the bug |
| Write tests on the main thread | Always use the worktree-isolated agent |
| Skip providing context to the agent | Include all 5 fields: description, root cause, affected files, fix approach, relevant context |
| Ignore the agent's results | Present the summary and merge commands to the user |
| Spawn multiple testcase-writers for the same repo | One testcase-writer per repo at a time |

## Benefits

- **Parallel workflow**: Tests are written while you fix the bug — no sequential waiting
- **Isolation**: Worktree prevents conflicts between fix and test changes
- **Regression prevention**: Targeted tests ensure the specific bug never recurs
- **Context preservation**: Main conversation stays focused on the fix
