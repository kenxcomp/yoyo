---
name: code-review-loop-pr
description: Run the code review convergence loop, then push the feature branch and create or update a pull request after two consecutive clean rounds.
---

# Code Review Loop PR

Run the shared review loop from `code-review-loop`. After convergence, push the current feature branch and create or update a pull request.

## Inputs

- Review base: use the user's explicit base when provided; otherwise use `${CR_PR_REMOTE:-origin}/<detected default branch>`.
- PR remote: `${CR_PR_REMOTE:-origin}` unless the user specifies another remote.
- PR base branch: `${CR_PR_BASE}` when set; otherwise the detected remote default branch.
- Draft mode: respect `CR_PR_DRAFT=1` or an explicit user request for a draft PR.
- PR title: use `CR_PR_TITLE` or a user-provided title when available; otherwise derive it from commits.

## Convergence Contract

Follow the full `code-review-loop` procedure before any push or PR operation:

- clean working tree before start,
- base resolves and is fresh,
- branch is based on the review base unless the user disables that gate,
- findings fixed in severity order,
- focused tests run before each fix commit,
- interaction changes require explicit user confirmation,
- two consecutive clean rounds against the same HEAD.

## PR Preconditions

After convergence, all of these must hold before pushing:

- working tree is clean,
- HEAD still equals the last reviewed HEAD,
- current branch is not the PR target,
- push range is contained in the reviewed range,
- remote PR target has not moved beyond the reviewed base during the loop,
- `gh` is installed and authenticated.

If any precondition fails, do not push. Write a handoff with `PR status: deferred - <reason>` and include exact manual recovery steps.

## Push Rules

- Push only the current feature branch to the selected remote.
- Never push to the base branch.
- Never use `--force`, `--force-with-lease`, or `--no-verify`.
- If upstream is unset, set it with a normal first push.
- If upstream points somewhere unexpected, defer and report the upstream mismatch.
- If push is rejected, defer and report local and remote divergence.

## Pull Request Rules

- After a successful push, first check whether an open PR already exists for the head branch and target base.
- If an open PR exists, report its URL and do not create a duplicate.
- If no PR exists, create one with a concise title and a body containing:
  - summary,
  - tests run,
  - commit range,
  - review-loop evidence,
  - Chinese business-impact summary.
- Respect draft mode.

## Final Report

Always report:

- rounds executed,
- issues fixed per round,
- tests run and final status,
- pushed branch or deferred reason,
- PR URL or deferred reason,
- stop reason,
- final worktree status.

Always include the Chinese business-impact summary. Use exactly `无业务逻辑影响` when the loop only changed internal implementation, tests, or docs without user-visible behavior changes.
