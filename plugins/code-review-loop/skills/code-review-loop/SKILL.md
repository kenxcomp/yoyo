---
name: code-review-loop
description: Run a Codex-native code review convergence loop. Use when the user asks to review a branch, fix findings, rerun review until two consecutive clean rounds, and stop without pushing, opening a PR, or merging.
---

# Code Review Loop

Run a local Codex review convergence loop and stop after the branch has passed two consecutive clean review rounds.

## Inputs

- Review base: use the user's explicit base ref when provided; otherwise use `origin/<detected default branch>`.
- Strict mode: default off. In default mode, Nit-only findings are clean; in strict mode, Nit findings also block convergence.
- Optional round cap: respect a user-provided cap; otherwise keep going until convergence or a real blocker.

## Required Reviewer Rubric

Use `/Users/kennethx/.codex/skills/code-reviewer/SKILL.md` when present. If it is unavailable, use this equivalent rubric:

- Prioritize security, correctness, reliability, performance, maintainability, and missing tests.
- Report actionable findings first, ordered Critical, High, Medium, Low, Nit.
- Findings need a concrete file and line when available, impact, and fix guidance.
- No Critical, High, Medium, or Low findings means the round is clean. Nit-only rounds are clean unless strict mode is requested.

## Procedure

1. Preflight.
   - Resolve the review base. If the base is a remote-tracking ref, fetch that specific remote branch before reviewing.
   - Require a clean working tree.
   - Record `START=$(git rev-parse HEAD)`.
   - Require a named current branch; stop on detached HEAD.
   - Verify the base resolves.
   - Require the base to be an ancestor of HEAD unless the user explicitly asked to skip the rebase gate. If stale, ask the user whether to rebase first or abort; do not rebase automatically.

2. Review one round.
   - Review the diff from base to HEAD using the reviewer rubric above.
   - Snapshot HEAD before review. If HEAD changes during review, do not classify the round; write a handoff with stop reason `head-drift-during-review`.

3. Classify the round.
   - Clean: no Critical, High, Medium, or Low findings. Nit-only is clean unless strict mode is on.
   - Dirty: any Critical, High, Medium, or Low finding.
   - Track `CLEAN_STREAK` only when consecutive clean rounds reviewed the same HEAD. Two clean rounds are required.

4. Fix dirty rounds.
   - Fix findings in severity order.
   - Read cited code before editing.
   - Prefer minimal root-cause fixes over symptom patches.
   - Add or update regression tests when the fix changes behavior or protects a bug class.
   - Run the focused affected tests. Broaden test scope when shared contracts are touched.
   - Commit the round as one commit:
     `fix(<scope>): review round <N> - <short summary>`
   - Include fixed findings and test evidence in the commit body.

5. Interaction guard.
   - If a finding or inferred fix would change user-visible interaction behavior, pause before editing.
   - This includes gestures, hit targets, keyboard shortcuts, accessibility actions, dialog or sheet type, navigation flow, and default actions.
   - Present current behavior, proposed change, two or three alternatives, and a leave-as-is option.
   - Continue only after the user explicitly chooses an option. No response is not consent.
   - Record the user's interaction decision in the commit body.

6. Widening guard.
   - If repeated dirty rounds keep pointing to the same file family, stop making one-off patches.
   - Read the full file family, identify a single root cause, sweep for matching bystander positions, fix the pattern in one commit, and add a pattern-level regression test.
   - If no clear root cause emerges or repeated widening does not converge, write a handoff and stop.

7. Converged stop.
   - After two consecutive clean rounds on the same HEAD, verify the working tree is clean and HEAD still equals the last reviewed HEAD.
   - Do not push, open a PR, check out another branch, or merge.
   - Delete stale `.cr-loop-handoff-round-*.md` files only after successful convergence.

## Handoff

For any non-converged stop, write `.cr-loop-handoff-round-<N>.md` at the repository root with:

- stop reason,
- current HEAD,
- `START`,
- base ref,
- per-round findings,
- commits created by the loop,
- test status,
- exact resume instruction.

## Final Report

Always report:

- rounds executed,
- issues fixed per round,
- tests run and final status,
- commit range from `START..HEAD`,
- stop reason,
- final worktree status,
- confirmation that the last two rounds were clean when converged.

Always end with a Chinese business-impact summary:

- If user-visible behavior changed, write 3-8 concise Chinese lines describing old behavior to new behavior.
- If all changes are internal-only, output exactly `无业务逻辑影响`.
