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
     - **(d)** Merge range ⊆ reviewed range (using immutable `REVIEWED_BASE_SHA` from `mark-converged`'s `BASE_SHA=` / `release-state get`'s `CONVERGED_BASE_SHA=`, NEVER re-resolving mutable `$CR_MERGE_TARGET`): pin `EXPECTED_TARGET_SHA=$(git rev-parse --verify "refs/heads/$CR_MERGE_TARGET")`, compute `MERGE_BASE=$(git merge-base "$EXPECTED_TARGET_SHA" "$LAST_REVIEWED_HEAD")`, and require `git merge-base --is-ancestor "$REVIEWED_BASE_SHA" "$MERGE_BASE"` (catches local target rewind).
     - **(e)** Divergence vs `CR_MERGE_FF`: first check whether `$CR_MERGE_TARGET` already contains `$LAST_REVIEWED_HEAD` (`git merge-base --is-ancestor "$LAST_REVIEWED_HEAD" "$EXPECTED_TARGET_SHA"`, which passes for all `CR_MERGE_FF` modes including `ff-only`); otherwise if `$MERGE_BASE != $EXPECTED_TARGET_SHA` and `CR_MERGE_FF=ff-only`, defer.
   - **Worktree-aware serialized attached merge** (never `--force`, never `-X theirs`/`-X ours`, never `--no-verify`, never `git push`; hold an exclusive repo-common lock at `"$(git rev-parse --path-format=absolute --git-common-dir)/cr-loop-merge.lock"` across worktree detection, merge, and post-merge verification so Git retains exclusive branch-checkout ownership throughout and every merge is verified against `$EXPECTED_TARGET_SHA`):
     - Under the repo-common lock, check whether `$CR_MERGE_TARGET` is checked out in another worktree (space-safe): `MAIN_WT=$(git worktree list --porcelain | awk -v t="refs/heads/$CR_MERGE_TARGET" '/^worktree / {wt=$0; sub(/^worktree /, "", wt)} $0=="branch "t {print wt; exit}')` (or `t3_worktree_list`). Map `CR_MERGE_FF`: `auto` → empty, `ff-only` → `--ff-only`, `no-ff` → `--no-ff`.
     - **Shared 3-case post-merge check** (pure commit-graph topology — no reflog dependency, handles fast-forwarding onto existing merge commits cleanly; with `NEW_TARGET_SHA=$(git rev-parse HEAD)` on the merged worktree): accept ONLY (1) **Already up to date** (`[ "$NEW_TARGET_SHA" = "$EXPECTED_TARGET_SHA" ] && git merge-base --is-ancestor "$LAST_REVIEWED_HEAD" "$NEW_TARGET_SHA"`), (2) **Fast-forward** (`[ "$NEW_TARGET_SHA" = "$LAST_REVIEWED_HEAD" ] && git merge-base --is-ancestor "$EXPECTED_TARGET_SHA" "$NEW_TARGET_SHA"`), or (3) **Newly created merge commit** (`[ "$NEW_TARGET_SHA" != "$LAST_REVIEWED_HEAD" ] && [ "$(git rev-parse HEAD^1)" = "$EXPECTED_TARGET_SHA" ] && [ "$(git rev-parse HEAD^2)" = "$LAST_REVIEWED_HEAD" ]`); otherwise defer and instruct inspecting target history and re-running `/t3-cr-loop-merge`.
     - **Not checked out elsewhere (Path A)**: do **not** call bare `git update-ref` without owning the branch checkout. Under the repo-common lock, claim the branch via `git checkout "$CR_MERGE_TARGET"` (Git refuses atomically if another worktree checked it out concurrently), verify `[ "$(git rev-parse HEAD)" = "$EXPECTED_TARGET_SHA" ]` and `bash "$T3_STATE" tree-clean` prints `TREE=clean` (ignoring only leftover untracked `.cr-loop-handoff-round-*.md`; else `git checkout "$FEATURE_BRANCH"` and defer to re-run `/t3-cr-loop-merge`), run `git merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"`, verify the **3-case post-merge check**, then `git checkout "$FEATURE_BRANCH"` (on conflict or hook failure: `git merge --abort 2>/dev/null || true; git checkout "$FEATURE_BRANCH"` and defer).
     - **Checked out in `$MAIN_WT` (Path B)**: never run `git fetch . <sha>:refs/heads/$CR_MERGE_TARGET` into a checked-out branch, and **never `--detach` `$MAIN_WT`** (detaching releases Git's exclusive checkout ownership of `$CR_MERGE_TARGET`, letting another worktree check it out concurrently). Under the repo-common lock, keep `$MAIN_WT` attached to `$CR_MERGE_TARGET`, verify `[ "$(git -C "$MAIN_WT" branch --show-current)" = "$CR_MERGE_TARGET" ]`, `[ "$(git -C "$MAIN_WT" rev-parse HEAD)" = "$EXPECTED_TARGET_SHA" ]`, and `(cd "$MAIN_WT" && bash "$T3_STATE" tree-clean)` prints `TREE=clean`. If dirty or drifted, defer with `merge-target-locked` and instruct the user to inspect/clean `$MAIN_WT` and **re-run `/t3-cr-loop-merge`** (never print a bare `git merge` when the target tip may have moved/rewound!). Otherwise run `git -C "$MAIN_WT" merge $MERGE_FLAG "$LAST_REVIEWED_HEAD"` directly while attached and verify the **3-case post-merge check** inside `$MAIN_WT` (on conflict: `git -C "$MAIN_WT" merge --abort` and defer with `merge-conflict`; on post-merge mismatch: report discrepancy and defer to inspect target history and re-run `/t3-cr-loop-merge`).
   - Clean up **only untracked repo-root** `.cr-loop-handoff-round-<N>.md` files (listed via `git ls-files --others --exclude-standard -- '.cr-loop-handoff-round-*.md'`, never deleting Git-tracked files) only after a successful merge; preserve worktree and ledger.
5. **Step 9 — Report / Handoff**: protocol Step 9 lines (including mandatory Chinese business-impact summary) plus `Merge status`, `Worktree status: preserved at <pwd>`, and `Remote status: untouched`.
