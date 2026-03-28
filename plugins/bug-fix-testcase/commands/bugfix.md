---
description: "End-to-end bug fix workflow: analyze, research, plan, fix + parallel test generation, merge, verify"
argument-hint: "<bug description or issue reference>"
---

# End-to-End Bug Fix Workflow

You are executing a structured 6-phase bug fix workflow. Follow each phase sequentially and do NOT skip any phase.

**Bug Report:** $ARGUMENTS

---

## Phase 1: Analyze

**Goal**: Understand the bug and identify the root cause.

**Actions**:

1. If `$ARGUMENTS` is empty or too vague to act on, ask the user for:
   - What is the bug? (symptoms, error messages, incorrect behavior)
   - Where does it occur? (file, function, user action)
   - How to reproduce it?
   Do NOT proceed until you have enough information.

2. Search the codebase for affected code:
   - Use `Grep` to find relevant error messages, function names, or keywords from the bug description
   - Use `Glob` to locate related files
   - Use `Read` to examine the affected source files

3. Trace the code path where the bug occurs. Identify:
   - **Symptoms**: What the user sees / what goes wrong
   - **Root Cause**: The underlying code/logic issue
   - **Affected Files**: List of source files involved
   - **Severity**: Critical / High / Medium / Low

4. Present a structured **Bug Analysis** to the user:

   ```
   ## Bug Analysis

   **Symptoms**: ...
   **Root Cause**: ...
   **Affected Files**: file1.py, file2.py, ...
   **Severity**: ...
   ```

---

## Phase 2: Web Search

**Goal**: Find community solutions and best practices for this type of bug.

**Actions**:

1. Use `WebSearch` to search for the error message, symptoms, or root cause pattern. Target:
   - Stack Overflow
   - GitHub Issues
   - Relevant framework/library documentation

2. Summarize the top 2-3 most relevant results:
   - What solution was recommended
   - URL source
   - Whether it applies to our specific case

3. If `WebSearch` is unavailable or returns no relevant results, note this and proceed:
   > "Web search returned no directly relevant results. Proceeding with code-analysis-based approach."

---

## Phase 3: Plan & Confirm

**Goal**: Present a fix plan and get user approval before making any changes.

**CRITICAL: This is a hard gate. Do NOT proceed to Phase 4 without explicit user confirmation.**

**Actions**:

1. Synthesize your analysis (Phase 1) and research (Phase 2) into a fix plan:

   ```
   ## Fix Plan

   **Root Cause**: <brief summary>
   **Proposed Fix**: <what will be changed and why>
   **Affected Files**: <files to modify>
   **Risk Level**: Low / Medium / High
   **Community Reference**: <relevant URL if found in Phase 2>

   ### Changes
   1. In `file1.py`: <specific change description>
   2. In `file2.py`: <specific change description>
   ...
   ```

2. Present the plan and explicitly ask: "Do you approve this fix plan? (Yes / No / Suggest changes)"

3. If the user suggests changes, revise the plan and re-confirm.

4. Only proceed to Phase 4 after receiving explicit "Yes" or approval.

---

## Phase 4: Fix + Module Tests (Parallel)

**Goal**: Implement the fix AND generate module/integration regression tests simultaneously.

**Actions**:

### Step 4a: Spawn Testcase-Writer Agent

Before writing any fix code, you MUST spawn the testcase-writer agent to work in parallel. This is NOT optional.

**Prerequisites check before spawning**:
- Run `git rev-parse --is-inside-work-tree` to verify this is a git repository
- If NOT a git repo, skip the agent spawn, note that tests must be written manually, and proceed with the fix only

**If in a git repo, immediately call the Agent tool** with these exact parameters:
- **subagent_type**: `bug-fix-testcase:testcase-writer`
- **isolation**: `worktree`
- **run_in_background**: `true`
- **description**: `Write module regression tests for [one-line bug summary from Phase 1]`
- **prompt**: Compose the prompt by filling in the template below with actual values from Phase 1 and Phase 3:

    Write regression test cases for the following bug:

    **Bug Description**: [fill in symptoms from Phase 1]
    **Root Cause**: [fill in root cause from Phase 1]
    **Affected Files**: [fill in affected files list]
    **Fix Approach**: [fill in proposed fix from Phase 3]
    **Relevant Context**: [fill in test framework, existing test patterns, related modules]

    Focus on module-level and integration-level tests that verify the bug is fixed
    and does not recur. These should test the component's public interface and
    behavior, not internal implementation details.

Do NOT wrap this in a code block or treat it as an example. You must actually invoke the Agent tool NOW before proceeding to Step 4b.

### Step 4b: Implement the Fix

While the agent works in the background:

1. Make the minimum necessary changes to fix the root cause
2. Follow existing code patterns and style conventions
3. Add inline comments explaining the fix ONLY where the logic is non-obvious
4. Do NOT refactor unrelated code or add extra features

After implementing the fix, wait for the testcase-writer agent to complete if it hasn't already.

---

## Phase 5: Merge Tests + Write Unit Tests

**Goal**: Integrate the module tests from the worktree, then write additional unit tests.

**Actions**:

### Step 5a: Merge Module Tests

1. Review the testcase-writer agent's output:
   - List the test files created and their purpose
   - Note the commit hash and branch name

2. Cherry-pick the test commit(s) from the worktree branch:
   ```bash
   git cherry-pick <commit-hash>
   ```
   If cherry-pick has conflicts, resolve them manually.

3. Clean up the worktree:
   ```bash
   git worktree remove <worktree-path>
   git branch -d <branch-name>
   ```

### Step 5b: Write Unit Tests

Based on the merged module/integration tests, write additional **unit tests** that:

1. Test individual functions/methods at a granular level
2. Cover edge cases and boundary conditions specific to the fix
3. Follow the same test file naming and organization patterns as the project
4. Complement (not duplicate) the module tests from the agent

Place unit tests in the appropriate test directory following project conventions.

---

## Phase 6: Verify

**Goal**: Run the full test suite and ensure everything passes.

**Actions**:

1. Auto-detect the test runner and run the full test suite:
   - Python: `pytest` or project-specific test command
   - JavaScript/TypeScript: `bun test`, `jest`, or `vitest`
   - Rust: `cargo test`
   - Go: `go test ./...`

2. Analyze the results:

   | Result | Action |
   |--------|--------|
   | **All tests pass** | Proceed to summary |
   | **New regression tests fail** | The fix may be incomplete — iterate on the fix in Phase 4b |
   | **Existing tests broken** | The fix introduced a regression — adjust the fix |
   | **Pre-existing failures** | Unrelated — note them but do not block completion |

3. If tests fail, fix the issues and re-run. Retry up to 3 iterations. If still failing after 3 attempts, report the status to the user and ask for guidance.

---

## Final Summary

After all tests pass, present a summary:

```
## Bug Fix Complete

**Bug**: <one-line description>
**Root Cause**: <brief explanation>
**Fix Applied**: <what was changed>
**Tests Added**: <N> module tests + <M> unit tests

### Files Modified
- <list of source files changed>

### Tests Added
| # | Test Name | Type | Purpose |
|---|-----------|------|---------|
| 1 | test_xxx  | Module | ... |
| 2 | test_yyy  | Unit   | ... |

### Verification
- Test suite: PASS (<total> tests)
- Regression tests: PASS
```
