---
description: Codex review loop (class-format findings, diff-only re-review, no-repeat ledger, 3-round step-back) until two consecutive clean rounds, then merge into local main (no push, worktree preserved)
argument-hint: '[<base-ref> (default: <auto-detected local default branch>)]'
---

# Codex Review Loop (merge into local main)

Run Codex review rounds against `<base-ref>`, fix every bug **class** they report, commit,
and repeat until the loop **converges**: two consecutive clean rounds on the same HEAD,
the second of which reviews the whole diff. A single clean round is not enough. Codex
sometimes returns a partial or empty review, and a second whole-diff pass catches problems
that the fixes created together.

After convergence, **merge the reviewed commits into the local default branch**. The
current worktree is kept so the user can keep working from it. **Never push**: this command
leaves the remote untouched.

Base ref: `$ARGUMENTS`. The default is the **local** integration branch, auto-detected into
`CR_MERGE_TARGET` (see step 1), so `main`, `master` or any other default name works. The
default is **not** `origin/<anything>`. Reviewing against the local target limits the diff
to exactly what is about to be merged. Using `origin/main` would pull into the review any
commits that are on local `main` but not yet pushed.

## Shared review protocol (authoritative — read it first)

**Read `${CLAUDE_PLUGIN_ROOT}/references/review-protocol.md` in full before step 2.** It
defines steps 2–7 and the shared parts of step 9:

- the reviewer runner `${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh`
- the review modes `full`, `incremental` and `step-back`
- class-format findings, written as `Pattern / Instances / Fix / Prevent`
- the per-branch **ledger** that prevents repeated findings
- the exact **convergence rule**
- the **round cap**: after 3 dirty rounds, a step-back is mandatory
- **codify at source**: a recurring class gets a lint rule, a guard test or a `REVIEW.md`
  entry
- the interaction-logic guard (step 5a), the commit format, and the contents of the handoff
  and the report

This file adds only the preflight (step 1), the local merge (step 8), and the stop reasons
and report lines that apply to the merge.

**Interaction-logic guard.** This guard is always on and cannot be disabled; it is protocol
step 5a. Any fix that would change user-visible interaction behavior pauses the loop until
the user explicitly confirms it. That covers gestures, hit targets, dialog/menu/sheet types,
keyboard shortcuts, accessibility actions, navigation flow and default actions. The **merge
is also blocked** while the guard is waiting for an answer. "No response" is never consent.

## Tunable knobs

The shared knobs are documented in the protocol (`CR_LOOP_ROUND_CAP=3`,
`CR_LOOP_MAX_STEP_BACKS=1`, `CR_LOOP_SKIP_P3=1`, `CR_LOOP_REQUIRE_REBASED=1`,
`CR_LOOP_REVIEW_EFFORT=high`, `CR_LOOP_REVIEW_MODEL=`), together with how the v1.6 knobs
that v1.7.0 removed are mapped. This command adds two:

- `CR_MERGE_TARGET=` sets the local branch to merge into. **When unset, it is
  auto-detected** to the repo's default local branch (step 1). Set it to use another
  integration branch, for example `develop`.
- `CR_MERGE_FF=auto` sets the merge style:
  - `auto` (the default) fast-forwards when possible and creates a merge commit otherwise.
  - `ff-only` defers to the user when a fast-forward isn't possible.
  - `no-ff` always creates a merge commit.

## Procedure

1. **Preflight.**
   - **Resolve `CR_MERGE_TARGET` and `BASE`.** This auto-detects the local default branch
     and needs no network access:
     ```bash
     if [ -z "$CR_MERGE_TARGET" ]; then
       CR_MERGE_TARGET=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
       # accept the advertised name only if it exists as a LOCAL branch; otherwise probe local heads
       if [ -z "$CR_MERGE_TARGET" ] || ! git rev-parse --verify --quiet "refs/heads/$CR_MERGE_TARGET" >/dev/null; then
         if   git rev-parse --verify --quiet refs/heads/main   >/dev/null; then CR_MERGE_TARGET=main
         elif git rev-parse --verify --quiet refs/heads/master >/dev/null; then CR_MERGE_TARGET=master
         else CR_MERGE_TARGET=main
         fi
       fi
     fi
     BASE="${ARGUMENTS:-$CR_MERGE_TARGET}"
     ```
     - Reading `refs/remotes/origin/HEAD` is a **local ref read, not a fetch**, so the "no
       remote interaction" contract still holds. It is used only to get the branch name.
     - **From here on, `CR_MERGE_TARGET` holds this resolved value.**
     - **Never default `BASE` to `origin/<anything>`.**
   - **Check the working tree with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean`.** This is the single clean-tree check shared by
     preflight and completion. It must print `TREE=clean`; it ignores only untracked repo-root
     `.cr-loop-handoff-round-<N>.md` files left by an earlier stop. On `TREE=dirty`, show its
     `DIRTY|` lines and ask the user to commit or stash them first.
   - **Record the start:** `START=$(git rev-parse HEAD)`.
   - **Record the branch:** `FEATURE_BRANCH=$(git branch --show-current)`. Abort if it is
     empty (detached HEAD).
   - **Confirm the merge target exists locally:**
     `git rev-parse --verify "refs/heads/${CR_MERGE_TARGET:-main}"`. If it is missing,
     abort and tell the user to create it.
   - **Confirm `FEATURE_BRANCH != ${CR_MERGE_TARGET:-main}`.** If they match, abort.
   - **Confirm `BASE` resolves to a local ref reachable from the merge target.** Both
     `git rev-parse --verify "$BASE"` and
     `git merge-base --is-ancestor "$BASE" "${CR_MERGE_TARGET:-main}"` must succeed.
     Otherwise abort with `BASE ($BASE) is not an ancestor of ${CR_MERGE_TARGET:-main};
     pick a base reachable from the merge target, or update ${CR_MERGE_TARGET:-main}
     first`.
   - **Base-currency gate.** This is a hard block. It honors `CR_LOOP_REQUIRE_REBASED`
     (default `1`; `0` skips the gate). Run `git merge-base --is-ancestor "$BASE" HEAD`.
     - **Exit 0:** proceed.
     - **Exit 1** (the branch is **stale** relative to the local `BASE`): do not start a
       round. Ask the user through the step-5a surface: a `form-base` radio when that MCP is
       loaded, otherwise inline **A/B**. Offer exactly these two options; there is no
       "review anyway":
       - **(A) Rebase first.** Print `git rebase "$BASE"` (a local rebase) and the
         re-invocation `/cr-loop-merge $ARGUMENTS`, then stop. The loop never rebases for
         you.
       - **(B) Abort.**

       Block on the reply. "No response" is not consent.
   - **Initialize** `ROUND_NUM=0`. The persisted counters (including `clean_streak`) and ledger belong to `cr-review.sh`.

2. **Run the review loop: protocol steps 2–7.** Follow them exactly as written, using
   `BASE` from step 1.
   - **Convergence** goes to step 8 with `LAST_REVIEWED_HEAD`.
   - **Any stop reason** goes to step 9.

8. **Merge the reviewed commits into local `${CR_MERGE_TARGET:-main}`.** This step runs
   after convergence and before the report.
   - Five preconditions must **all** hold. If any fails, go to step 9 with
     `Merge status: deferred — <which precondition failed>` and its diagnostic.
   - Never auto-commit, never auto-rebase, never `--force`, and **never `git push`**.

   The preconditions:

   - **(a) The working tree is clean.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean` must print `TREE=clean`. This is the same check
     as the preflight, so a leftover handoff never blocks completion; any other change does.
     Diagnostic: its `DIRTY|` lines.
   - **(b) HEAD has not moved since the last review:**
     `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]`. Diagnostic:
     `git log --oneline "$LAST_REVIEWED_HEAD"..HEAD`.
   - **(c) The current branch is not the merge target:**
     `[ "$FEATURE_BRANCH" != "${CR_MERGE_TARGET:-main}" ]`.
   - **(d) Every commit being merged was reviewed.** Obtain the **immutable** `REVIEWED_BASE_SHA` (40-char commit SHA) from the convergence record (`mark-converged`'s `BASE_SHA=` or `cr-review.sh release-state get`'s `CONVERGED_BASE_SHA=`) — **never** re-resolve a mutable branch ref such as `${CR_MERGE_TARGET:-main}` after convergence (if the local target rewound to an ancestor `B` behind the reviewed baseline `A`, re-resolving the branch name would silently skip `B..A`). Compute `MERGE_BASE=$(git merge-base "${CR_MERGE_TARGET:-main}" "$LAST_REVIEWED_HEAD")`. Then require `git merge-base --is-ancestor "$REVIEWED_BASE_SHA" "$MERGE_BASE"`. Diagnostic: `git log --oneline "$REVIEWED_BASE_SHA".."$LAST_REVIEWED_HEAD"` plus `git log --oneline "$MERGE_BASE".."$REVIEWED_BASE_SHA"`.
   - **(e) The target has no diverged commits.** Check
     `[ "$MERGE_BASE" = "$(git rev-parse "${CR_MERGE_TARGET:-main}")" ]`. If the target
     has diverged, `auto` and `no-ff` create a merge commit, while `ff-only` **defers**.
     Diagnostic: `git log --oneline "$MERGE_BASE".."${CR_MERGE_TARGET:-main}"`.

   **Merge,** once (a)–(e) hold:

   - **Find out whether another worktree has the target checked out (space-safe):**
     `MAIN_WT=$(git worktree list --porcelain | awk -v t="refs/heads/${CR_MERGE_TARGET:-main}" '/^worktree / {wt=$0; sub(/^worktree /, "", wt)} $0=="branch "t {print wt; exit}')`.
   - **Path A: the target is not checked out anywhere.** Map `CR_MERGE_FF` to a flag:
     `auto` → no flag, `ff-only` → `--ff-only`, `no-ff` → `--no-ff`. Then run:
     ```bash
     git checkout "${CR_MERGE_TARGET:-main}"
     git merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"
     git checkout "$FEATURE_BRANCH"
     ```
   - **Path B: another worktree at `$MAIN_WT` has the target checked out.**
     Never run `git fetch . HEAD:refs/heads/<target>` into a branch that is checked out (Git rejects it, and updating a checked-out ref without updating its index/worktree would corrupt that worktree). Instead:
     1. Verify `$MAIN_WT` is on `${CR_MERGE_TARGET:-main}`, at the expected ref tip (`[ "$(git -C "$MAIN_WT" branch --show-current)" = "${CR_MERGE_TARGET:-main}" ]`), and completely clean (`[ -z "$(git -C "$MAIN_WT" status --porcelain --untracked-files=all)" ]`).
     2. If `$MAIN_WT` is dirty or drifted, defer with `Merge status: deferred — target worktree at $MAIN_WT is dirty or not on ${CR_MERGE_TARGET:-main}` and print `cd "$MAIN_WT" && git merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"`.
     3. If `$MAIN_WT` is clean, run the user's selected `CR_MERGE_FF` merge mode directly inside `$MAIN_WT`:
        ```bash
        git -C "$MAIN_WT" merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"
        ```
        On conflict, run `git -C "$MAIN_WT" merge --abort` and defer with `Merge status: deferred — conflicts on <files>`.
   - **Hook failure:** defer and show the hook output. Never use `--no-verify`.
   - **Conflict in Path A:** run `git merge --abort`, return to `$FEATURE_BRANCH`, then defer with
     `Merge status: deferred — conflicts on <files>`.

   **After a successful merge:**

   - Run `rm -f .cr-loop-handoff-round-*.md` and report "Cleaned up N stale handoff
     file(s)". If the merge was deferred, do **not** delete them.
   - Keep the ledger.
   - **Do not remove the worktree.** When the user is done, they run
     `cd <main-checkout> && git worktree remove <path> && git branch -d "$FEATURE_BRANCH"`
     themselves.

9. **Stop / handoff.**

   **9a. Handoff.** This follows protocol 9a. The merge adds these stop reasons:
   - `merge-deferred-<which-precondition>`
   - `merge-conflict`
   - `merge-target-locked`

   For a merge stop reason, the handoff also includes:
   - the precondition that failed
   - its diagnostic
   - the exact manual command to run, for example
     `cd <main-worktree> && git merge --no-ff <feature-branch>`

   The resume instructions name `/cr-loop-merge $ARGUMENTS`.

   **9b. Report.** Include the shared lines from protocol 9b, ending with the Chinese
   **business-impact summary**. That summary is mandatory, including after a local merge,
   so the user has release notes and a regression scope before pushing. Add these lines:
   - **Merge status:** `merged $FEATURE_BRANCH into ${CR_MERGE_TARGET:-main}` followed by
     `<merge-commit SHA>` or `fast-forward to <SHA>`. Otherwise `deferred — <reason>`.
   - **Worktree status:** `preserved at <pwd>`, plus the cleanup hint
     `git worktree remove <pwd> && git branch -d "$FEATURE_BRANCH"` (run from another
     worktree).
   - **Remote status:** untouched. The user pushes with `git push origin ${CR_MERGE_TARGET:-main}`.

## Guardrails

The shared guardrails from the protocol apply. In addition:

- **Interaction guard.** No merge into `${CR_MERGE_TARGET:-main}` while a 5a decision is
  pending.
- **Base-currency gate.** The preflight is hard by default. It is local only, and it never
  auto-rebases. Disable it with `CR_LOOP_REQUIRE_REBASED=0`.
- **Never `git push`.** If you need to push, you are in the wrong command; use `/cr-loop-pr` (or `/cr-loop` to stop locally and push manually).
- **Never `--force` the merge.** `--ff-only` is allowed. `--force`, `--force-with-lease`,
  `-X theirs` and `-X ours` are forbidden.
- **Worktree-aware.** When another worktree at `$MAIN_WT` has the target checked out, verify `$MAIN_WT` is clean and on `${CR_MERGE_TARGET:-main}`, then run `git -C "$MAIN_WT" merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"` (honoring `CR_MERGE_FF`); if `$MAIN_WT` is dirty or conflicts, abort/defer with a manual command. Never force-checkout a locked branch or fetch into a checked-out ref.

## Differences from `/cr-loop`

1. **The default base is the local default branch, not a remote ref.** The review diff is
   exactly what gets merged.
2. **After convergence, this command merges into local `${CR_MERGE_TARGET:-main}`.** There
   is no fetch, no push, and no remote interaction. The worktree is kept.

Everything else is identical across the three commands: the review protocol, its modes,
the ledger, the round cap with step-back, codify-at-source, the interaction guard,
head-drift detection, and the handoff format.
