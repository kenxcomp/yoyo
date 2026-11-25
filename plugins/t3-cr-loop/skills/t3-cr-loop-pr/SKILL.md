---
name: t3-cr-loop-pr
description: Run the T3 Code multi-model review convergence loop, auto-rebase onto the latest PR base with confirmation if it moved, push the feature branch, and create or update the PR using T3 Code native pull_request_* tools (gh fallback).
---

# T3 CR Loop PR (Auto-Rebase, Push & Open/Update PR)

Run the shared T3 Code multi-model review protocol from `<PLUGIN_ROOT>/references/review-protocol.md` (resolved via `../../` from this `SKILL.md`'s real path). After convergence, ensure the branch sits cleanly on top of the latest PR target, push the feature branch, and open or update the PR using T3 Code's native `pull_request_*` tools (falling back to `gh` CLI only when native PR tools are absent or when `CR_PR_REMOTE` targets a different repository than the thread's bound repository).

## Extra Knobs
- `CR_PR_REMOTE=origin` — remote for push and PR target.
- `CR_PR_BASE=` — PR target branch (unset → auto-detected remote default branch).
- `CR_PR_AUTO_REBASE=1` — Step 8.0 auto-rebase + single `full` confirmation round (default ON; `0` defers when target moved).
- `CR_PR_DRAFT=0` — open PR as draft when `1`.
- `CR_PR_TITLE=` — explicit PR title (truncated to 70 chars).

## Procedure

1. **Step 0 — Capabilities & Configuration**: run protocol Step 0.
2. **Step 1 — Preflight**:
   - Resolve `REMOTE="${CR_PR_REMOTE:-origin}"` and `CR_PR_BASE` locally (`refs/remotes/$REMOTE/HEAD`, fallback `main` → `master`), set `PR_TARGET_REF="refs/remotes/$REMOTE/$CR_PR_BASE"`, and `BASE="${EXPLICIT_BASE:-$REMOTE/$CR_PR_BASE}"`.
   - Verify PR tooling: prefer T3 Code native `pull_request_*` tools (`pull_request_list`, `pull_request_create`, `pull_request_read`, `link_pull_request`). **Pre-flight repo check**: compare the target repository parsed from `git remote get-url "$REMOTE"` against the thread's bound repository. If native `pull_request_*` tools are unavailable OR `REMOTE` points to a different repository than the thread's bound repo (e.g. an upstream fork), verify `gh` CLI is installed and authenticated (`gh auth status`) and use `gh --repo <owner/repo>` instead of calling `pull_request_create` on the wrong repo.
   - Fetch base: `git fetch "$REMOTE" "$CR_PR_BASE" --quiet` (abort on failure).
   - Check `bash "$T3_STATE" tree-clean` prints `TREE=clean`.
   - Record `START=$(git rev-parse HEAD)` and `FEATURE_BRANCH=$(git branch --show-current)` (abort on detached HEAD or `FEATURE_BRANCH == $CR_PR_BASE`).
   - Verify `BASE` and `$PR_TARGET_REF` resolve, AND verify `BASE` covers the PR diff (`PR_MB=$(git merge-base "$PR_TARGET_REF" HEAD)`; require `BASE` is ancestor of or equal to `$PR_MB` so no `PR_MB..BASE` commits are skipped).
   - **Base-currency gate** (`CR_LOOP_REQUIRE_REBASED=1`): check `git merge-base --is-ancestor "$BASE" HEAD`; if stale, ask user **(A) Rebase first** (`git rebase "$BASE"`) or **(B) Abort**. Never auto-rebase at preflight.
3. **Steps 2–7 — Review Loop**: run protocol Steps 2–7 with `BASE`.
4. **Step 8 — Auto-Rebase, Coverage Check, Push & PR** (after convergence):

   ### 8.0 Pre-Rebase Checks, Release Intent & Post-Rebase Confirmation (`CR_PR_AUTO_REBASE != 0`)
   1. **Verify branch & HEAD BEFORE touching git history**: confirm `git branch --show-current == $FEATURE_BRANCH`, `tree-clean == TREE=clean`, and `git rev-parse HEAD == $LAST_REVIEWED_HEAD`.
   2. **Re-fetch PR target & upstream feature branch**:
      - `git fetch "$REMOTE" "$CR_PR_BASE" --quiet` (defer `pr-deferred-fetch-failed` on error); `NEW_BASE_TIP=$(git rev-parse "$PR_TARGET_REF")`.
      - Check `bash "$T3_STATE" release-state get`. If upstream points to `$REMOTE/$FEATURE_BRANCH` and `PINNED_REMOTE_HEAD_SHA` is not yet persisted:
        - `git fetch "$REMOTE" "$FEATURE_BRANCH" --quiet`.
        - Set `PINNED_REMOTE_HEAD_SHA=$(git rev-parse "refs/remotes/$REMOTE/$FEATURE_BRANCH")` and verify `git merge-base --is-ancestor "$PINNED_REMOTE_HEAD_SHA" "$LAST_REVIEWED_HEAD"` (if not, remote has unseen commits → defer immediately with `push-rejected`).
   3. **Check whether rebase or coverage confirmation is needed**:
      - Compute `PR_MB=$(git merge-base "$NEW_BASE_TIP" "$LAST_REVIEWED_HEAD")` and `REVIEWED_BASE_SHA=$(git rev-parse "$BASE^{commit}")`.
      - If `NEW_BASE_TIP` is ancestor of `$LAST_REVIEWED_HEAD` AND `REVIEWED_BASE_SHA` is at or before `$PR_MB`: no rebase and no extra round needed; proceed to Preconditions.
      - **If `NEW_BASE_TIP` is NOT ancestor of `$LAST_REVIEWED_HEAD`**:
        - **Persist release intent BEFORE calling `git rebase`** so a crash right after rebase succeeds preserves the pre-rebase lease target and `REBASED_IN_8_0=1`:
          `bash "$T3_STATE" release-state set rel_pre_rebase_head="${PRE_REBASE_HEAD:-$LAST_REVIEWED_HEAD}" rel_pinned_remote_head_sha="${PINNED_REMOTE_HEAD_SHA:-}" rel_target_base_sha="$NEW_BASE_TIP" rel_rebased_in_8_0=1`.
        - Run `git rebase "$NEW_BASE_TIP"`.
        - On conflict: capture `git diff --name-only --diff-filter=U`, run `git rebase --abort`; clear `release-state` ONLY if no earlier 8.0 rebase had already succeeded in this cycle (prior `REBASED_IN_8_0 == 0` and `HEAD == PRE_REBASE_HEAD`); defer with `pr-deferred-rebase-conflict`.
        - On clean rebase: `rel_rebased_in_8_0=1` is already persisted; **update `BASE="$NEW_BASE_TIP"`** across the entire remainder of the flow.
      - **If `NEW_BASE_TIP` IS ancestor of `$LAST_REVIEWED_HEAD` but `$REVIEWED_BASE_SHA` was strictly ahead of `$PR_MB`**: do not rebase, **update `BASE="$NEW_BASE_TIP"`**.
      - **Run one `post-rebase-confirmation` round** (default single reviewer, `MODE=full` against updated `BASE` via protocol Steps 3b–3d):
        - **Clean** (or P3-only with `SKIP_P3=1`, or acked `needs-human` via 4h): run `bash "$T3_STATE" mark-converged --post-rebase --base "$BASE" --round "$ROUND_DIR"`, set `LAST_REVIEWED_HEAD=$REVIEWED_HEAD`, continue to Preconditions.
        - **Dirty**: fix (Steps 5–6) and return to **Step 3** using updated `BASE="$NEW_BASE_TIP"` to re-converge with **two full clean rounds** while keeping `rel_pinned_remote_head_sha` and `rel_rebased_in_8_0=1` persisted.

   ### Preconditions (Re-verified Immediately Before Push, Including `CR_PR_AUTO_REBASE=0`)
   - **(a)** `bash "$T3_STATE" tree-clean` prints `TREE=clean`.
   - **(b)** `[ "$(git branch --show-current)" = "$FEATURE_BRANCH" ]` and `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]`.
   - **(c)** `[ "$FEATURE_BRANCH" != "$CR_PR_BASE" ]`.
   - **(d)** Unless `REBASED_IN_8_0=1`, if upstream is set, `BASE` is ancestor of `@{u}`.
   - **(e) Unified pre-push PR target coverage check**: re-fetch `git fetch "$REMOTE" "$CR_PR_BASE" --quiet`, resolve `PR_TARGET_TIP`, compute `PR_MB=$(git merge-base "$PR_TARGET_TIP" "$LAST_REVIEWED_HEAD")`. Require BOTH `git merge-base --is-ancestor "$PR_TARGET_TIP" "$LAST_REVIEWED_HEAD"` AND `git merge-base --is-ancestor "$BASE" "$PR_MB" || [ "$BASE" = "$PR_MB" ]` (catches both target advance AND target rewind). Defer on failure.
   - **(f) Target repository verification**: confirm once more before pushing/creating PR whether T3 native PR tools match the target repo of `$REMOTE` (otherwise switch to `gh --repo <owner/repo>`).

   ### Push (Always Explicit Reviewed SHA Refspec)
   - Never `--no-verify`, never bare `--force`, never push `$CR_PR_BASE`.
   - **Upstream unset**: `git push -u "$REMOTE" "$LAST_REVIEWED_HEAD:refs/heads/$FEATURE_BRANCH"`.
   - **Upstream is `$REMOTE/$FEATURE_BRANCH` and `REBASED_IN_8_0=0`**: `git push "$REMOTE" "$LAST_REVIEWED_HEAD:refs/heads/$FEATURE_BRANCH"`.
   - **Upstream is `$REMOTE/$FEATURE_BRANCH` and `REBASED_IN_8_0=1`**: block for explicit user confirmation quoting BOTH `PINNED_REMOTE_HEAD_SHA` and `LAST_REVIEWED_HEAD`:
     - **(A) Force-update PR**: immediately AFTER user confirms and BEFORE pushing, **re-verify preconditions (a), (b), and (e)** (`tree-clean`, `HEAD == $LAST_REVIEWED_HEAD`, and re-fetched PR target tip coverage — defer if anything drifted while awaiting consent), then run `git push --force-with-lease="refs/heads/$FEATURE_BRANCH:$PINNED_REMOTE_HEAD_SHA" "$REMOTE" "$LAST_REVIEWED_HEAD:refs/heads/$FEATURE_BRANCH"`.
     - **(B) Skip push**: defer with `pr-deferred-force-push-declined`.
   - Clear persisted release state (`bash "$T3_STATE" release-state clear`) once push succeeds.

   ### Open / Update PR & Verify via `pull_request_read`
   - **T3 native PR path** (when `pull_request_*` tools are present AND target repo matches thread's bound repo):
     1. Call `pull_request_list(state: "open")` to check for an existing open PR matching `$FEATURE_BRANCH` → `$CR_PR_BASE`.
     2. If none exists, call `pull_request_create(base: "$CR_PR_BASE", title: "$PR_TITLE", body: "$PR_BODY", draft: <CR_PR_DRAFT==1>)` (`pull_request_create` auto-links the PR; if it returns an already-open PR, treat it as existing). If an existing PR was found in step 1, call `link_pull_request` so T3 tracks it.
     3. **Mandatory post-create/lookup verification**: call `pull_request_read(repository: "<owner/repo>", number: <PR_NUMBER>, sections: ["summary"])` and verify `baseBranch == "$CR_PR_BASE"`, `headBranch == "$FEATURE_BRANCH"`, and `headSha == "$LAST_REVIEWED_HEAD"`. Surface any mismatch immediately.
   - **`gh` CLI fallback** (only when native PR tools are absent or target repo differs from thread's repo):
     Check `gh pr list --repo <owner/repo> --head "$FEATURE_BRANCH" --base "$CR_PR_BASE" --state open --json number,url,headRefOid`; if missing, write PR body to a temp file and run `gh pr create --repo <owner/repo> --base "$CR_PR_BASE" --head "$FEATURE_BRANCH" [--draft] --title "$PR_TITLE" --body-file "$PR_BODY_FILE"`, then verify `headRefOid == "$LAST_REVIEWED_HEAD"` and call `link_pull_request` if available.
   - **PR body sections**: `## Summary`, `## Test plan` (actual commands run + results), `## Multi-Model Review` (rounds, participating models, classes, codified artifacts), and `## 业务影响` (exact Chinese business-impact summary from protocol 9b).
   - Clean up `.cr-loop-handoff-round-*.md` only after push + PR verification succeed; preserve worktree and ledger.

5. **Step 9 — Report / Handoff**: protocol Step 9 lines plus `Rebase status`, `Push status`, `PR status` (verified URL), `Worktree status: preserved at <pwd>`.
