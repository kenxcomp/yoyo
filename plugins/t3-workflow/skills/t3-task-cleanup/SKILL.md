---
name: t3-task-cleanup
description: Run a safe, task-scoped post-merge wrap-up protocol in T3 Code after all child delegate changes are integrated into the host task branch and tests are green. Enumerates tracked/untracked/ignored files before file-by-file cleanup, verifies authoritative T3 identity & exclusivity before removing ONLY this task's child worktrees, runs dry-run-checked worktree prune, atomically deletes ONLY this task's verified temp branches via update-ref CAS, and reports git status and df -h . disk space.
---

# T3 Task Cleanup (`t3-task-cleanup`)

Execute the **Task Wrap-Up Protocol (任务收尾协议)** once — as the **sole host wrap-up step** — after all delegated child changes have been integrated into the host task branch, all final verification checks pass, and (when PR publishing was executed) PR base/head verification is complete.

> Applies to **all** wrap-up modes: PR-published, local-only, and `publish-held` (when PR publishing is authorized but remote target branch doesn't exist yet). Always save any Step 5.2 replay evidence into the task report BEFORE removing replay helpers.

## Strict Safety Preconditions (Fail-Closed)

Before deleting ANY file, worktree, or branch, verify ALL four preconditions:

1. **Integration & Green Gate**: All intended child changes are committed on the host's active `<TASK_BRANCH>`, and the final test/verification suite has passed on `FINAL_SHA`.
2. **Terminal Child Delegates (ALL Delegates)**: Every delegate created by this task across **all** steps and generations in `ALL_DELEGATES[]` (worktree Red/Blue across all generations, replaced/cancelled slots, Step 4 shared fixes, Step 4 Arbiter) has reached a verified **terminal** state (never proceed while any delegate is `working`, `starting`, or merely `cancel_requested`).
3. **Authoritative Task Ownership Manifest**: Cleanup applies **ONLY** to items explicitly recorded in THIS task's ownership manifest:
   - Delegate worktrees/branches in `ALL_DELEGATES[]` (`hasWorktree: true`): bound by authoritative T3 `taskId` / `childThreadId` and canonical workspace identity (never self-reported strings alone).
   - Host-created replay helpers in `REPLAY_SLOTS[]` (`owner: "host-helper"`): no delegate ID required; bound by host-recorded canonical worktree path, branch, `headSha`, and `disposition: "replay-evidence-saved"`.
   - **NEVER** bulk-scan or delete worktrees/branches belonging to other sessions (other `~/.t3/worktrees/`, `.codex/worktrees/`, `.claude/worktrees/`, `orca/workspaces/`).
   - **NEVER** remove the main repository checkout root or the host's own active worktree (`realpath "$(git rev-parse --show-toplevel)"`).
4. **Protected Branch Denylist**: NEVER delete `main`, `master`, `<TARGET_BRANCH>`, the host's active `<TASK_BRANCH>`, or any branch checked out in any remaining worktree.

---

## Step 1 — File-by-File Cleanup of Task `.tmp/` & Debug Temp Files (No Blind `rm -rf`)

1. Enumerate tracked, untracked, AND **every individual ignored file** (using `--ignored=traditional`, NEVER `--ignored=matching`, which collapses ignored directories like `node_modules/` into a single line and hides nested unknown files):
   ```bash
   git status --porcelain=v1 --untracked-files=all --ignored=traditional --ignore-submodules=none
   ```
   Also list every file inside `.tmp/` explicitly (`find .tmp -mindepth 1` if `.tmp/` exists).
2. Evaluate **each file individually**:
   - Confirm it is NOT tracked (`git ls-files --error-unmatch "<file>"` fails).
   - Confirm it was **created by this task** and is expendable (temporary debug script, debug log, temporary scratch artifact).
   - **Preserve** any `.trellis/` artifact, review ledger, pre-existing user file, local config, acceptance evidence, or any directory/file whose full contents cannot be individually enumerated and attributed to this task.
3. Delete ONLY the confirmed expendable files **file-by-file** (`rm -- "<file>"`), recording every deleted path.
4. Remove `.tmp/` (and any empty temp subdirectories) ONLY via `rmdir` after confirming they are **completely empty**. If non-task/unknown files remain inside `.tmp/`, keep them and report them.

---

## Step 2 — Identity-Bound Child Worktree Removal & Scoped Prune

1. Resolve authoritative host Git identity:
   - `HOST_COMMON_DIR=$(realpath "$(git rev-parse --git-common-dir)")`
   - `MAIN_ROOT=$(realpath "$(git worktree list --porcelain | awk '/^worktree /{print substr($0,10); exit}')")`
   - `HOST_ROOT=$(realpath "$(git rev-parse --show-toplevel)")`
2. For each worktree entry in THIS task's ownership manifest (`ALL_DELEGATES[]` where `hasWorktree: true`, plus `REPLAY_SLOTS[]`):
   - **Disposition check**: only remove entries marked `integrated`, `ported`, `approved-discard`, or `replay-evidence-saved`. If marked `retain` or unverified, **keep and report**.
   - **Exclusivity & identity verification BEFORE removal**:
     1. For delegate slots (`ALL_DELEGATES[]`): confirm `taskId` / `childThreadId` is in a terminal state with no queued/active runs, and verify no other session, terminal, or concurrent writer holds/uses that checkout. For host helpers (`REPLAY_SLOTS[]`): confirm `owner: "host-helper"` and host no longer uses that checkout.
     2. Canonicalize `TARGET_PATH=$(realpath "$RAW_PATH")` (if path no longer exists, record `already-reclaimed` and skip removal).
     3. Verify `TARGET_PATH != MAIN_ROOT` and `TARGET_PATH != HOST_ROOT`.
     4. Verify `TARGET_PATH` is registered in `git worktree list --porcelain` AND `realpath "$(git -C "$TARGET_PATH" rev-parse --git-common-dir)" == "$HOST_COMMON_DIR"`.
     5. Verify `git -C "$TARGET_PATH" rev-parse HEAD` equals the entry's recorded `headSha` (and branch matches recorded `branch` if attached).
     6. Enumerate **every** tracked, untracked, AND individual ignored file inside the child worktree:
        ```bash
        git -C "$TARGET_PATH" status --porcelain=v1 --untracked-files=all --ignored=traditional --ignore-submodules=none
        ```
        Inspect file-by-file: if `HEAD` has unseen commits beyond `headSha`, OR ANY modified/untracked/ignored file or directory cannot be completely enumerated and confirmed as expendable task/build output (e.g. local configs, logs, user evidence, opaque ignored directories), **KEEP the worktree and report it** instead of `--force` wiping it.
     7. **Exclusivity gate**: if exclusive ownership across concurrent checkouts/writers cannot be proven through removal, **keep and report** rather than force-deleting.
   - Only once all checks pass, remove it:
     ```bash
     git worktree remove --force "$TARGET_PATH"
     ```
     and verify `TARGET_PATH` is no longer listed in `git worktree list --porcelain`.
3. **Scoped `git worktree prune` (respects `retain` & unrelated sessions)**:
   - Run dry-run first:
     ```bash
     git worktree prune --dry-run --verbose
     ```
   - Execute global `git worktree prune` **ONLY** when candidate membership is stable (serialized) AND **every** dry-run candidate both:
     1. Matches a registered entry in THIS task's ownership manifest, AND
     2. Has an approved removable disposition (`integrated`, `ported`, `approved-discard`, or `replay-evidence-saved` — **NEVER** `retain` or unverified, even if temporarily unmounted/inaccessible!).
   - If dry-run lists ANY candidate outside this task's manifest OR any `retain`/unverified entry, **do NOT run global `git worktree prune`** — report the dry-run output and preserve registrations.

---

## Step 3 — Atomic Deletion of THIS Task's Verified Temporary Branches

Only evaluate temporary branches recorded in THIS task's ownership manifest (after Step 2 has removed/detached their worktrees):

1. Reject any branch on the Protected Branch Denylist (`main`, `master`, `<TARGET_BRANCH>`, active `<TASK_BRANCH>`, or checked out in any remaining entry of `git worktree list --porcelain`).
2. Skip cleanly if `refs/heads/$TEMP_BRANCH` no longer exists.
3. Read `CURRENT_TIP=$(git rev-parse --verify "refs/heads/$TEMP_BRANCH")` and verify integration/disposition:
   - **Standard Git merge / ancestor**: `git merge-base --is-ancestor "$CURRENT_TIP" HEAD` succeeds AND `CURRENT_TIP == entry.headSha`.
   - **Audited net-patch integration** (e.g. `t3-tdd-adversarial` Step 3, including post-rebase re-mapped commits):
     - Verify `CURRENT_TIP == entry.headSha` (exact audited SHA) AND the recorded integrated commit (`POST_RED_HEAD` / `POST_BLUE_HEAD`, or its verified post-rebase equivalent SHA — NOT `invalidated`) is an ancestor of `HEAD`.
     - If a rebase occurred and equivalence was not re-proven (marked `invalidated`), **keep the branch and report**.
   - **Approved-discard replaced generation / completed replay helper**: `CURRENT_TIP == entry.headSha` and disposition is explicitly `approved-discard` or `replay-evidence-saved`.
   - If `CURRENT_TIP != entry.headSha` (unseen commits appeared after audit), **STOP and retain the branch**.
4. **Exclusivity + Atomic CAS ref deletion**:
   - Confirm exclusive ownership (no concurrent session/worktree can check out or write `$TEMP_BRANCH` during deletion); if exclusivity cannot be proven, **retain the branch and report**.
   - Never run non-atomic `git branch -D "$TEMP_BRANCH"` after checking the tip; delete atomically with expected old-OID check:
     ```bash
     git update-ref -d "refs/heads/$TEMP_BRANCH" "$CURRENT_TIP"
     ```
     (Fails safely without deleting if the ref moved concurrently.)

---

## Step 4 — Final Cleanliness & Disk Space Report

Run in the host workspace:

```bash
git status --short --branch
df -h .
```

Also verify via `git worktree list --porcelain` that none of this task's removed child worktrees remain registered.

Report concisely to the user (or include in the completion message sent to the coordinator):
1. **Workspace cleanliness**: exact `git status --short --branch` output, active branch, and `FINAL_SHA`.
2. **Disk space**: exact `df -h .` line (filesystem size, used, available, capacity).
3. **Cleanup audit**:
   - Files removed file-by-file (exact paths, or `none`) and whether `.tmp/` was empty & removed via `rmdir`
   - Child worktrees removed (paths + `taskId`) + `git worktree prune --dry-run` / prune outcome + any retained/already-reclaimed worktrees
   - Temporary branches atomically deleted via `update-ref -d` (names + verified `EXPECTED_TIP_SHA` + basis) and any retained branches
