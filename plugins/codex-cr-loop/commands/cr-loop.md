---
description: Codex review loop (class-format findings, diff-only re-review, no-repeat ledger, 3-round step-back) until two consecutive clean rounds, then stop (no push, no PR, no merge — local convergence only)
argument-hint: '[<base-ref> (default: origin/<auto-detected default branch>)]'
---

# Codex Review Loop (review only — no remote interaction)

Run Codex review rounds against `<base-ref>`, fix every bug **class** they report, commit,
and repeat until the loop **converges**. Convergence means two consecutive clean rounds on
the same HEAD, the second of which reviews the whole diff. A single clean round is not
enough: Codex sometimes returns a partial or empty review, and a second whole-diff pass
catches problems that the fixes created together.

After convergence the loop **stops**. It does not push, open a PR, or merge into an
integration branch. The reviewed commits stay on the current feature branch in the current
worktree, and the next step (push, PR, merge, rebase, squash) is up to the user. The
sibling commands `/cr-loop-merge` and `/cr-loop-pr` automate those paths.

Base ref: `$ARGUMENTS`. The default is `origin/<repo default branch>`, auto-detected so that
`main`, `master` or any other default name works (see step 1). Reviewing against the remote
target keeps the findings aligned with what a human reviewer, or `/cr-loop-pr`, would see.
Override it only when you really want a different review base, such as a release branch or
an integration branch named `develop`.

## Shared review protocol (authoritative — read it first)

**Before step 2, read `${CLAUDE_PLUGIN_ROOT}/references/review-protocol.md` in full.** It
defines steps 2–7 and the shared parts of step 9:

- the reviewer runner `${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh`
- the review modes `full`, `incremental` and `step-back`
- class-format findings (`Pattern / Instances / Fix / Prevent`)
- the per-branch no-repeat **ledger**
- the exact **convergence rule**
- the **round cap**: 3 dirty rounds trigger a mandatory step-back
- **codify at source**: a recurring class gets a lint rule, a guard test or a `REVIEW.md`
  entry
- the interaction-logic guard (5a), the commit format, and the handoff and report contents

This file adds only the preflight (step 1), the completion step (step 8) and
`/cr-loop`-specific report lines. Where they conflict, the protocol wins on the review loop
and this file wins on preflight and completion.

**The interaction-logic guard is always on and cannot be disabled.** It is protocol step 5a.
A fix that would change user-visible interaction behavior pauses the loop until the user
explicitly confirms. That includes Codex findings, your own analysis, and step-back
structural changes. It covers:

- which gesture triggers which response
- which UI element is the hit target
- dialog vs dropdown vs inline editor vs sheet
- keyboard shortcuts and accessibility actions
- navigation flow
- default actions on Return, the primary button, or an outside tap

"No response" is never consent, and there is no env override.

## Tunable knobs

The shared knobs are listed in the protocol: `CR_LOOP_ROUND_CAP=3`,
`CR_LOOP_MAX_STEP_BACKS=1`, `CR_LOOP_SKIP_P3=1`, `CR_LOOP_REQUIRE_REBASED=1`,
`CR_LOOP_REVIEW_EFFORT=high`, `CR_LOOP_REVIEW_MODEL=`. The protocol also lists the v1.6
knobs removed in v1.7.0 and how they are mapped. `/cr-loop` has no knobs of its own.

## Procedure

1. **Preflight.**
   - **Resolve `BASE`** by auto-detecting the default branch. This is a local read with no
     network access. When `$ARGUMENTS` is empty, default to
     `origin/<detected default branch>`, so the command works on `main`, `master` or any
     other default name:
     ```bash
     DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
     if [ -z "$DEFAULT_BRANCH" ]; then
       if   git rev-parse --verify --quiet refs/remotes/origin/main   >/dev/null; then DEFAULT_BRANCH=main
       elif git rev-parse --verify --quiet refs/remotes/origin/master >/dev/null; then DEFAULT_BRANCH=master
       else DEFAULT_BRANCH=main
       fi
     fi
     BASE="${ARGUMENTS:-origin/$DEFAULT_BRANCH}"
     ```
     `git symbolic-ref refs/remotes/origin/HEAD` reads the remote's advertised default from
     the local ref set at clone time, so there is **no fetch**. If that ref is unset, the
     script probes `origin/main`, then `origin/master`, then falls back to `main`. The fetch
     and verify steps below catch a wrong guess. An explicit `$ARGUMENTS` always wins.
   - **Refresh a remote base.** If `BASE` is a `<remote>/<branch>` ref, run
     `git fetch <remote> <branch> --quiet`. Skip the fetch when `BASE` is a local ref; then
     there is no remote interaction at all. Abort if a needed fetch fails.
   - **Check the working tree with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean`.** This is the single clean-tree check shared by
     preflight and completion. It must print `TREE=clean`; it ignores only untracked repo-root
     `.cr-loop-handoff-round-<N>.md` files left by an earlier stop. On `TREE=dirty`, show its
     `DIRTY|` lines and ask the user to commit or stash them first.
   - **Record the start:** `START=$(git rev-parse HEAD)`.
   - **Capture the branch:** `FEATURE_BRANCH=$(git branch --show-current)`. If it is empty
     (detached HEAD), abort.
   - **Verify that `BASE` resolves** with `git rev-parse --verify "$BASE"`. On failure,
     abort with `BASE ($BASE) does not resolve — check the ref name, and that the relevant
     remote was fetched if BASE points at one`.
   - **Base-currency gate.** This is a hard block. It honors `CR_LOOP_REQUIRE_REBASED`
     (default `1`; set `0` to skip). Run `git merge-base --is-ancestor "$BASE" HEAD`.
     - **Exit 0** (the branch is current or ahead): proceed.
     - **Exit 1** (the branch is **stale** relative to `BASE`): do not start a review round.
       Ask the user through the step-5a surface (a `form-base` `create_form` radio when that
       MCP is loaded, inline **A/B** otherwise). Offer exactly two options; there is
       intentionally no "review anyway":
       - **(A) Rebase first.** Print `git rebase "$BASE"` and the re-invocation
         `/cr-loop $ARGUMENTS`, then stop. The loop never rebases for you.
       - **(B) Abort.** Stop immediately.

       Block on the reply. "No response" is not consent. Either choice ends this invocation.
   - **Initialize** `ROUND_NUM=0`, `CLEAN_STREAK=0`, and an empty `LAST_CLEAN_HEAD`. The
     persisted counters and the ledger belong to `cr-review.sh` (protocol step 2).

2. **Reviewer setup, the review loop, fixes and commits: protocol steps 2–7.** Run them
   exactly as written in `review-protocol.md`, with `BASE` from step 1. There are three ways
   out:
   - **Convergence** (protocol 4a) goes to step 8 below with `LAST_REVIEWED_HEAD`.
   - **Any stop reason** goes to step 9.
   - A **user decision** at a 5a or 4s prompt continues the loop or stops it, as the user
     chooses.

8. **Stop — verify the final state and exit.** This step runs after convergence and before
   the report. It does not push, open a PR or merge. It checks two preconditions only so
   the report accurately reflects what is on disk. A failure does not block the stop, but
   it does appear in step 9b.
   - **(a) The working tree is clean.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean` must print `TREE=clean`. This is the same check
     as the preflight, so a leftover handoff never blocks completion; any other change does. If it is
     dirty, show the `DIRTY|` lines: those changes never went through a review round.
   - **(b) HEAD did not move since the last review.** Check
     `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]`. If it moved, surface
     `git log --oneline "$LAST_REVIEWED_HEAD"..HEAD`.
   - **No remote interaction.** None of `git push`, `gh pr create`,
     `git checkout <other-branch>` or `git merge` runs in this command. The only fetch
     allowed is the preflight refresh in step 1.
   - **Cleanup after a successful convergence.** If (a) and (b) both held, run
     `rm -f .cr-loop-handoff-round-*.md` at the repository root and report "Cleaned up N
     stale handoff file(s)". If either precondition failed, do **not** delete them; surface
     the deviation first. The ledger is kept: it prevents repeats in later invocations and
     PR-bot loops on this branch.

9. **Stop / handoff.**

   **9a. Handoff.** On any stop without convergence, write the handoff as protocol 9a
   describes. `/cr-loop` has only the shared stop reasons: `head-drift-during-review`,
   `reviewer-error`, `rule-edits-declined`, `step-back-exhausted`, `step-back-scope-declined`,
   `user-stopped`. The
   resume instructions name `/cr-loop $ARGUMENTS`.

   **9b. Report.** Always output the shared lines from protocol 9b, ending with the Chinese
   **Business-impact summary**, which is mandatory. Add these lines:
   - **Final state:** `clean — HEAD at <SHA> (== LAST_REVIEWED_HEAD)` when converged and
     both step 8 preconditions held. Otherwise `converged but <which precondition>
     drifted — <diagnostic>`.
   - **Worktree:** `preserved at <pwd>`.
   - **Next steps** (informational only; do not run them):
     - `git push`, or `git push -u <remote> <branch>` on the first push
     - `gh pr create`, or use `/cr-loop-pr` next time
     - `/cr-loop-merge` for a local merge

## Guardrails

The shared guardrails in the protocol apply: the interaction guard comes first, hooks are
never skipped, commits stay scoped, recurring classes are codified, nothing is re-reported,
and user-global files are never edited. In addition:

- **Base-currency gate.** The preflight is hard by default. It never auto-rebases and never
  reviews against a stale base. Disable it with `CR_LOOP_REQUIRE_REBASED=0`.
- **No remote interaction.** This command never runs `git push` in any form, `gh pr create`
  or `gh pr edit`. If you need one of them, you are in the wrong command: use `/cr-loop-pr`
  or `/cr-loop-merge`.
- **No checkout and no merge.** The branch the user started on is the branch the user ends
  on.

## Differences from `/cr-loop-pr` and `/cr-loop-merge`

All three commands share the same review protocol: the modes, the ledger, the round cap
with its step-back, codifying at the source, the interaction guard, head-drift detection,
and the handoff and report format. They differ only in what happens after convergence:

| When to use | Command |
|---|---|
| Codex gates the work, but integration (push, merge or PR) is manual or handled by another workflow | `/cr-loop` (stops) |
| Reviewed commits land on `origin/<branch>` and a PR opens for human review | `/cr-loop-pr` (auto-rebase, push, PR) |
| Reviewed commits land on the local `${CR_MERGE_TARGET}` to be pushed manually later | `/cr-loop-merge` (local merge, no push) |
