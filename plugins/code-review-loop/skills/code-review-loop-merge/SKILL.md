---
name: code-review-loop-merge
description: Run the code review convergence loop, then merge the reviewed feature branch into a local target branch without pushing.
---

# Code Review Loop Merge

Run the shared review loop from `code-review-loop`. After convergence, merge the reviewed commits into a local target branch. This skill never pushes to a remote.

## Inputs

- Merge target: use the user's explicit target when provided; otherwise use `${CR_MERGE_TARGET}` or the detected local default branch.
- Review base: default to the local merge target, not `origin/<branch>`.
- Merge style: respect `${CR_MERGE_FF:-auto}`:
  - `auto`: allow Git's default fast-forward or merge commit behavior,
  - `ff-only`: defer unless fast-forward is possible,
  - `no-ff`: create a merge commit when possible.

## Convergence Contract

Follow the full `code-review-loop` procedure before any merge operation:

- clean working tree before start,
- local base resolves,
- merge target exists locally,
- current branch is not the merge target,
- branch is based on the local review base unless the user disables that gate,
- findings fixed in severity order,
- focused tests run before each fix commit,
- interaction changes require explicit user confirmation,
- two consecutive clean rounds against the same HEAD.

## Merge Preconditions

After convergence, all of these must hold before merging:

- working tree is clean,
- HEAD still equals the last reviewed HEAD,
- current branch is not the merge target,
- every commit that will land on the target is inside the reviewed range,
- merge target divergence is compatible with the selected merge style.

If any precondition fails, do not merge. Write a handoff with `Merge status: deferred - <reason>` and include exact manual recovery steps.

## Worktree-Aware Merge Rules

- Never push at any point.
- Never use `--force` or `--no-verify`.
- If the target branch is not checked out elsewhere, check it out, merge with the selected merge style, then return to the feature branch.
- If the target branch is checked out in another worktree and the merge is fast-forwardable, update the local target ref without touching the other working copy.
- If the target branch is checked out elsewhere and a true merge commit is required, defer and report the other worktree path plus the manual merge command.
- If conflicts occur, abort the merge when possible, write a handoff, and report conflicted files.

## Cleanup

Delete stale `.cr-loop-handoff-round-*.md` files only after successful convergence and merge. Leave the current worktree in place; do not remove branches or worktrees automatically.

## Final Report

Always report:

- rounds executed,
- issues fixed per round,
- tests run and final status,
- merge target and merge status,
- commit range from the feature branch,
- stop reason,
- final worktree status.

Always include the Chinese business-impact summary. Use exactly `无业务逻辑影响` when the loop only changed internal implementation, tests, or docs without user-visible behavior changes.
