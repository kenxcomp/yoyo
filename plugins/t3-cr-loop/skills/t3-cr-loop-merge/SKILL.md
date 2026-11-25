---
name: t3-cr-loop-merge
description: Run the T3 Code multi-model review convergence loop, then merge the reviewed feature branch into the local default branch without pushing (worktree-aware).
---

# T3 CR Loop Merge (Local Merge — Never Push)

Run the shared T3 Code multi-model review protocol from `<PLUGIN_ROOT>/references/review-protocol.md` (resolved via `../../` from this `SKILL.md`'s real path). After convergence, merge the reviewed commits into the **local** integration branch. **Never push** to any remote; keep the current worktree.

## Extra Knobs
- `CR_MERGE_TARGET=` — local target branch (unset → auto-detected local default branch).
- `CR_MERGE_FF=auto` — `auto` (default), `ff-only`, or `no-ff`.

## Procedure

1. **Step 0 — Capabilities & Configuration**: run protocol Step 0.
2. **Step 1 — Preflight (local-only, zero network)**:
   - Auto-detect `CR_MERGE_TARGET` locally (`refs/remotes/origin/HEAD` local read only if that branch exists under `refs/heads/`, else probe `refs/heads/main`, then `refs/heads/master`). Set `BASE="${EXPLICIT_BASE:-$CR_MERGE_TARGET}"` (never default to `origin/<anything>`).
   - Check `bash "$T3_STATE" tree-clean` prints `TREE=clean`.
   - Record `START=$(git rev-parse HEAD)` and `FEATURE_BRANCH=$(git branch --show-current)` (abort on detached HEAD).
   - Verify `refs/heads/$CR_MERGE_TARGET` exists locally and `FEATURE_BRANCH != $CR_MERGE_TARGET`.
   - Verify `BASE` resolves and `git merge-base --is-ancestor "$BASE" "$CR_MERGE_TARGET"`.
   - **Base-currency gate** (`CR_LOOP_REQUIRE_REBASED=1`): verify `git merge-base --is-ancestor "$BASE" HEAD`; if stale, ask user **(A) Rebase first** (`git rebase "$BASE"`) or **(B) Abort**. Never auto-rebase.
3. **Steps 2–7 — Review Loop**: run protocol Steps 2–7 with local `BASE`.
4. **Step 8 — Merge into local `$CR_MERGE_TARGET`** (after convergence):
   - All five preconditions must hold (otherwise defer to step 9 with handoff):
     - **(a)** `bash "$T3_STATE" tree-clean` prints `TREE=clean`.
     - **(b)** `[ "$(git branch --show-current)" = "$FEATURE_BRANCH" ]` and `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]`.
     - **(c)** `[ "$FEATURE_BRANCH" != "$CR_MERGE_TARGET" ]`.
     - **(d)** Merge range ⊆ reviewed range: `MERGE_BASE=$(git merge-base "$CR_MERGE_TARGET" "$LAST_REVIEWED_HEAD")`; verify `BASE` is ancestor of or equal to `$MERGE_BASE`.
     - **(e)** Divergence vs `CR_MERGE_FF`: if `$MERGE_BASE != $(git rev-parse "$CR_MERGE_TARGET")` and `CR_MERGE_FF=ff-only`, defer.
   - **Worktree-aware merge** (never `--force`, never `-X theirs`/`-X ours`, never `--no-verify`, never `git push`):
     - Check whether `$CR_MERGE_TARGET` is checked out in another worktree (`git worktree list --porcelain` / `t3_worktree_list`).
     - **Not checked out elsewhere**: map `CR_MERGE_FF` (`auto` → empty, `ff-only` → `--ff-only`, `no-ff` → `--no-ff`), then `git checkout "$CR_MERGE_TARGET" && git merge $MERGE_FLAG "$LAST_REVIEWED_HEAD" && git checkout "$FEATURE_BRANCH"`. On conflict, `git merge --abort`, return to `$FEATURE_BRANCH`, and defer with `merge-conflict`.
     - **Checked out in `$MAIN_WT`**: never run `git fetch . <sha>:refs/heads/$CR_MERGE_TARGET` into a checked-out branch. Verify `$MAIN_WT` is on `$CR_MERGE_TARGET` (`[ "$(git -C "$MAIN_WT" branch --show-current)" = "$CR_MERGE_TARGET" ]`) and completely clean (`[ -z "$(git -C "$MAIN_WT" status --porcelain --untracked-files=all)" ]`). If dirty or drifted, defer with `merge-target-locked` and print `cd "$MAIN_WT" && git merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"`. If clean, run `git -C "$MAIN_WT" merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"` (honoring `auto`, `ff-only`, and `no-ff`; on conflict, run `git -C "$MAIN_WT" merge --abort` and defer with `merge-conflict`).
   - Clean up `.cr-loop-handoff-round-*.md` only after a successful merge; preserve worktree and ledger.
5. **Step 9 — Report / Handoff**: protocol Step 9 lines (including mandatory Chinese business-impact summary) plus `Merge status`, `Worktree status: preserved at <pwd>`, and `Remote status: untouched`.
