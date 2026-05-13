---
description: Loop /codex:review in --wait mode, fix returned issues, re-run until two consecutive clean rounds, then merge into local main (no push, worktree preserved)
argument-hint: '[<base-ref> (default: main)]'
---

# Codex Review Loop (merge into local main)

Run `/codex:review --base <ref> --wait` in the foreground, fix every P0/P1/P2/P3
finding it returns, commit, and re-run. Stop when **two consecutive rounds**
return no actionable findings ("did not find any definite correctness bugs" /
empty review body). A single clean round is not enough — Codex occasionally
produces partial / empty reviews on flaky network or model output, and a fresh
second round catches issues the first pass skipped or the previous fix exposed.

After convergence, **merge the reviewed commits into the local `main` branch**.
The current worktree is preserved so the user can keep iterating from it (run
`git worktree remove` manually when ready to clean up). **Never push** to the
remote — this command leaves remote untouched, the user pushes manually if/when
they want to.

Base ref: `$ARGUMENTS` — default `main` (the **local** integration branch, NOT
`origin/main`). Reviewing against the local target keeps the diff scoped to
exactly what's about to be merged; using `origin/main` would let any commits the
user pulled into local main but hasn't pushed yet leak into the review range
and produce noisy findings about code that isn't part of this branch's work.

**Auto-widening behavior (default ON)**: when the same file family keeps producing
findings round after round (a sign that fixes are symptomatic, not root-cause),
the loop auto-escalates to a **widening sweep round** (step 4d) instead of stopping:
read the full file family, hypothesize one root cause, sweep the codebase for all
matching positions, fix them in one commit + add a pattern-level regression test,
then continue the loop. The widening commit is itself reviewed by Codex on the next
round, so quality is still gated by the reviewer. The user is only paged when
`CR_LOOP_MAX_WIDENING_SWEEPS` (default 2) consecutive sweeps fail to converge —
that's when the surface is genuinely beyond auto-fix scope and needs human judgment.
Set `CR_LOOP_AUTO_WIDEN=0` to restore the original "stop and hand off" behavior.

## Tunable knobs (env overrides)

Read these once during preflight; defaults shown:

- `CR_LOOP_ROUND_CAP=` — **opt-in** ceiling on rounds (unset by default → no cap). When set to a positive integer N, hitting `ROUND_NUM >= N` stops the loop, writes a handoff, and surfaces to the user. Leave unset to let the loop run until it converges, hits the file-family widening guard, drifts, exhausts the auto-widening sweep budget, or you cancel manually.
- `CR_LOOP_WIDEN_AFTER=5` — after this many consecutive dirty rounds whose findings stay inside the same file family, escalate to a widening sweep (or stop, depending on `CR_LOOP_AUTO_WIDEN`).
- `CR_LOOP_AUTO_WIDEN=1` — when `1` (default), triggering the widening guard does NOT stop the loop. Instead the agent enters a single **widening sweep round** (step 4d) that reads the full file family, articulates one root-cause hypothesis, sweeps the codebase for matching positions, fixes them in one commit, and adds a pattern-level regression test, then resumes the normal loop. Set to `0` to restore the original "stop and hand off to user" behavior — useful when the user wants to inspect every escalation manually.
- `CR_LOOP_MAX_WIDENING_SWEEPS=2` — cap on automatic widening sweeps per `/cr-loop-merge` invocation. After this many sweeps, the next widening trigger writes a `widening-sweeps-exhausted` handoff and stops. Prevents the agent from indefinitely rewriting larger and larger swaths of code without human judgment when sweeps aren't converging.
- `CR_LOOP_SKIP_P3=1` — when `1` (default), rounds whose findings are exclusively P3 are treated as clean (P3 ≈ defensive / style / nit; doesn't block convergence). Set to `0` for strict mode where P3s also block convergence and must be fixed.
- `CR_MERGE_TARGET=main` — local branch to merge into. Override if your project's integration branch is named differently (e.g., `develop`, `trunk`).
- `CR_MERGE_FF=auto` — merge style. `auto` (default) lets git choose: fast-forward when possible, otherwise a true merge commit. `ff-only` defers to the user when fast-forward isn't possible. `no-ff` always creates a merge commit even when fast-forward would work (preserves branch topology).

No per-round timeout — Codex review duration scales with diff size and reviewer model output, and a large refactor's review can legitimately take 15+ minutes. The loop blocks on the foreground reviewer until it returns or the user manually cancels (`/codex:cancel`).

These are advisory escape valves, not silencers. Each one writes a handoff and stops — the user always decides whether to continue.

## Procedure

1. **Preflight.**
   - Resolve `BASE` from `$ARGUMENTS`. Default to the **local** merge target: `BASE="${ARGUMENTS:-${CR_MERGE_TARGET:-main}}"`. **Do not default to `origin/main`** — see the "Base ref" note above for why.
   - `git status --short` — working tree must be clean. If dirty, commit or stash before starting; otherwise the diff will include unrelated noise and reviewer findings won't map to commits cleanly.
   - Record the starting commit: `START=$(git rev-parse HEAD)`.
   - Capture the feature branch: `FEATURE_BRANCH=$(git branch --show-current)`. Abort if empty (detached HEAD — there's no branch to merge from).
   - Verify the merge target exists locally: `git rev-parse --verify "refs/heads/${CR_MERGE_TARGET:-main}"`. If missing, abort and tell the user to create it (`git branch main origin/main` or similar).
   - Verify `FEATURE_BRANCH != ${CR_MERGE_TARGET:-main}`. Merging main into itself is meaningless — abort with a clear error.
   - **Verify `BASE` resolves to a local ref reachable from the merge target's history.** Run `git rev-parse --verify "$BASE"` (must succeed) AND `git merge-base --is-ancestor "$BASE" "${CR_MERGE_TARGET:-main}"` (base must be an ancestor of, or equal to, the merge target). If `BASE` resolves but isn't an ancestor of the target — typical case: user explicitly passed `origin/main` and the local `main` lags behind — abort with `BASE ($BASE) is not an ancestor of ${CR_MERGE_TARGET:-main}; pick a base reachable from the merge target, or update ${CR_MERGE_TARGET:-main} first`. This catches the same noise-leak that defaulting to local main avoids.
   - Initialize `CLEAN_STREAK=0` — tracks consecutive clean rounds; loop ends when it reaches 2.
   - Initialize `DIRTY_STREAK=0` and `STREAK_FILE_SET=∅` — see step 4b for widening guard semantics.
   - Initialize `WIDENING_SWEEPS_DONE=0` and `WIDENING_SWEEP_HISTORY=[]` — counter + per-sweep root-cause record (used by step 4d and the handoff in step 9a).
   - Initialize `ROUND_NUM=0`.

2. **Locate the Codex companion script.**
   ```bash
   CODEX_SCRIPT=$(ls -t "$HOME/.claude/plugins/cache/openai-codex/codex"/*/scripts/codex-companion.mjs 2>/dev/null | head -1)
   ```
   If empty, the `openai-codex` plugin is not installed — abort and tell the user to `/plugin install openai-codex`.

3. **Run one review round (foreground, blocking).**

   Increment `ROUND_NUM`. Snapshot HEAD before launching, then block on the reviewer until it returns:

   ```bash
   REVIEWED_HEAD=$(git rev-parse HEAD)
   node "$CODEX_SCRIPT" review --base "$BASE" --wait
   [ "$(git rev-parse HEAD)" = "$REVIEWED_HEAD" ] || abort_round
   ```

   No per-round timeout — codex review duration scales with diff size and reviewer model output, and a large refactor's review can legitimately take 15+ minutes. If you genuinely believe the reviewer is hung (no progress in the codex companion process for many minutes, output file size frozen), use `/codex:cancel <task-id>` to stop it manually and resume the loop later — do NOT auto-kill mid-run, you'll mis-classify a slow-but-working review as stuck.

   **Post-review HEAD check is load-bearing**: the reviewer takes minutes, and during that window an external commit, rebase, or hook-driven rewrite from another shell can advance HEAD. The reviewer's verdict applies to whatever HEAD it saw mid-run; if the local HEAD has since moved, that verdict no longer covers the working state. **Do not classify this round, do not touch `CLEAN_STREAK`** — surface `git log --oneline "$REVIEWED_HEAD"..HEAD` plus `git status -sb` to the user, write a handoff (step 9) with `Stop reason: head-drift-during-review`, and stop. The user must investigate (concurrent agent? auto-commit hook? someone working in another shell?) before re-invoking `/cr-loop-merge`. Treating the round as clean would let unreviewed commits ride into main on the next merge.

   Read the **`# Codex Review`** section from stdout — everything above it is reviewer command trace.

   **While waiting for a round to finish, use `Monitor` to block on the codex process PID exit, NOT `ScheduleWakeup`.** Wakeup re-enters the prompt at a fixed interval and produces redundant `/cr-loop-merge` invocations stacked behind each other if the round runs long; Monitor delivers a single notification when the process exits, exactly when you need to act.

4. **Classify the verdict** (only reached if step 3's post-review HEAD check passed and the round didn't time out):

   **Clean** if the review body says "did not find any definite correctness bugs" OR contains no lines matching `^- \[P[0-3]\]`. **The streak only counts when consecutive clean rounds reviewed the same HEAD** — `LAST_REVIEWED_HEAD` is the SHA of the previous clean round (unset on first ever / after a dirty round). If `LAST_REVIEWED_HEAD == REVIEWED_HEAD`, this round confirms the same HEAD: `CLEAN_STREAK += 1`. Otherwise (HEAD changed between the previous clean round and this one — external commit, rebase, or step 6 commit landing between rounds): the previous streak no longer applies, set `CLEAN_STREAK = 1` and `LAST_REVIEWED_HEAD = REVIEWED_HEAD` (this is now the SHA being confirmed). Reset `DIRTY_STREAK = 0` and `STREAK_FILE_SET = ∅`. If `CLEAN_STREAK >= 2`, jump to step 8 — `LAST_REVIEWED_HEAD` is the SHA both clean rounds confirmed and step 8 will refuse to merge if it doesn't still match. Else, loop back to step 3 for the confirmation round.

   **Dirty** — every `- [Pn] <headline> — <file>:<line>` bullet is an issue to fix. Apply the optional P3-skip filter first (see 4a), then update the widening guard (see 4b), then proceed to step 5.

   **4a. P3-only skip filter** (when `CR_LOOP_SKIP_P3=1`):
   - Parse all finding bullets. If **every** finding is `[P3]`, treat the round as effectively clean and apply the **full clean-classification machinery from step 4** — do NOT just bump `CLEAN_STREAK` and loop. Specifically:
     - If `LAST_REVIEWED_HEAD == REVIEWED_HEAD`: `CLEAN_STREAK += 1`. Else: `CLEAN_STREAK = 1`, `LAST_REVIEWED_HEAD = REVIEWED_HEAD`.
     - Reset `DIRTY_STREAK = 0` and `STREAK_FILE_SET = ∅` (the dirty streak ends here, even though findings exist — they're just below the action threshold).
     - **Check convergence**: if `CLEAN_STREAK >= 2`, jump to step 8 (merge). This check is load-bearing — without it the loop keeps re-entering step 3 forever because no fix is applied, HEAD never changes, every subsequent round is the same P3-only set, `CLEAN_STREAK` increments without bound, and step 8 is never reached.
     - Log `Round N: P3-only ignored (CR_LOOP_SKIP_P3=1, CLEAN_STREAK=k/2)`.
     - Apply step 4c round cap (only when the user has opted in via `CR_LOOP_ROUND_CAP` — a misconfigured env var with persistent P3 findings shouldn't burn rounds silently when a ceiling has been set).
     - Otherwise return to step 3 for the confirmation round.
   - **Note on no-commit semantics**: this path deliberately does NOT commit anything (P3s are skipped, not fixed). HEAD stays at `REVIEWED_HEAD`, so the next round's `REVIEWED_HEAD` will equal `LAST_REVIEWED_HEAD` and the second pass will satisfy `CLEAN_STREAK >= 2` immediately if Codex returns the same P3-only verdict (or genuinely clean). If Codex returns a higher-severity finding next round, the dirty path takes over normally — `CLEAN_STREAK` resets, `DIRTY_STREAK` starts at 1 with the new file set.
   - If any finding is P0/P1/P2, ignore this filter (proceed to step 4b + 5 with the full finding list, including the P3 entries — fix them alongside the higher-severity ones).

   **4b. File-family widening guard.** Extract the set of cited file paths from the finding bullets (the `<file>` portion of `- [Pn] <headline> — <file>:<line>`). Call this `ROUND_FILES`.
   - If `DIRTY_STREAK == 0` (this is the first dirty round of a new streak): set `STREAK_FILE_SET = ROUND_FILES`, `DIRTY_STREAK = 1`. Proceed to step 5.
   - If `DIRTY_STREAK > 0` and `ROUND_FILES ⊆ STREAK_FILE_SET` (every cited file in this round was also cited in some prior dirty round of this streak): increment `DIRTY_STREAK`, keep `STREAK_FILE_SET` as-is. If `DIRTY_STREAK >= CR_LOOP_WIDEN_AFTER` (default 5): **branch by widening mode**:
     - **Auto-widen path** (`CR_LOOP_AUTO_WIDEN=1` AND `WIDENING_SWEEPS_DONE < CR_LOOP_MAX_WIDENING_SWEEPS`, both defaults; and `CR_LOOP_ROUND_CAP` either unset or `ROUND_NUM < CR_LOOP_ROUND_CAP`): jump to **step 4d (widening sweep)** instead of stopping. The agent reads the full family, hypothesizes one root cause, sweeps for bystander positions, fixes them in one commit + adds a pattern-level test, resets streak state, and resumes the loop. The next round's reviewer reviews the sweep commit, so quality stays gated.
     - **Manual path** (`CR_LOOP_AUTO_WIDEN=0` OR `WIDENING_SWEEPS_DONE >= CR_LOOP_MAX_WIDENING_SWEEPS`): **stop**. Write a handoff (step 9) with `Stop reason: widening-hint` (auto-widen disabled) or `widening-sweeps-exhausted` (cap reached). Handoff includes (a) the file family list (`STREAK_FILE_SET`), (b) the last `CR_LOOP_WIDEN_AFTER` rounds' findings verbatim, (c) `WIDENING_SWEEP_HISTORY` (every prior auto-sweep's root-cause headline + commit SHA + post-sweep verdict), (d) suggested wider sweep targets the agent didn't try. Surface the handoff path to the user and exit.
   - If `DIRTY_STREAK > 0` and `ROUND_FILES ⊄ STREAK_FILE_SET` (this round cited a *new* file family — the bug surface moved): reset `STREAK_FILE_SET = ROUND_FILES`, `DIRTY_STREAK = 1`. Proceed to step 5. (A genuinely shifting surface is healthy progress; the widening guard only fires when we're spinning on the same file family.)
   - Always reset `CLEAN_STREAK = 0` and `LAST_REVIEWED_HEAD` on any dirty round (the upcoming step 6 commit produces a new HEAD that must be re-reviewed from scratch).

   **4c. Optional round cap.** After classification, if `CR_LOOP_ROUND_CAP` is set to a positive integer AND `ROUND_NUM >= CR_LOOP_ROUND_CAP`: write a handoff (step 9) with `Stop reason: round-cap-reached`, surface, exit. The cap is **opt-in** — when `CR_LOOP_ROUND_CAP` is unset or empty (the default), this step is a no-op and the loop runs uncapped (it still stops on convergence, widening guard, head-drift, widening-sweeps-exhausted, or manual cancel). Set it (e.g. `CR_LOOP_ROUND_CAP=20 /cr-loop-merge ...`) to bound worst-case token spend on a single invocation; the user can resume by re-invoking with a higher cap or take the surfaced state and decide manually.

   **4d. Auto widening sweep** (entered from 4b when auto-widen is enabled and the cap isn't yet reached). Goal: turn this round into a *systematic root-cause fix* instead of another symptomatic patch. **This step replaces step 5's per-finding loop for one round.**

   Full execution manual: **`.claude/rules/cr-loop-widening-sweep.md`** — read it before running a sweep. Phase summary:

   - **A — Read the full family** end-to-end (not just cited line ranges).
   - **B — Hypothesize one root cause** that explains every prior round's findings; if no clean hypothesis emerges, fall through to manual handoff with `Stop reason: widening-hint-no-clear-root-cause`. Never invent a hypothesis to justify a sweep.
   - **C — Sweep the codebase** for bystander positions matching the same pattern (grep / LSP / Glob); build `BYSTANDER_FILES = STREAK_FILE_SET ∪ matches`.
   - **D — Apply one systematic fix** at the contract / abstraction layer, not per-call-site patches.
   - **E — Add a pattern-level regression test** (parameterized or invariant-style); flag any skip in the commit.
   - **F — Run the affected test target(s)**; if red, debug before committing.
   - **G — Commit** as `fix(<scope>): widening sweep <K> — <root-cause headline>` with the structured body in the rule file.
   - **H — Reset streak state**: `DIRTY_STREAK = 0`, `STREAK_FILE_SET = ∅`, `WIDENING_SWEEPS_DONE += 1`, `CLEAN_STREAK = 0`, clear `LAST_REVIEWED_HEAD`, append to `WIDENING_SWEEP_HISTORY`.
   - **I — Continue** to the next review round (step 3).

   The reviewer round that follows gates the sweep's quality — a wrong sweep gets flagged and the regular loop catches it. The `MAX_WIDENING_SWEEPS` cap (default 2) bounds unattended retry: after that many failed sweeps, the loop stops with `widening-sweeps-exhausted` and hands off.

5. **Fix each finding in order (highest severity first: P0 > P1 > P2 > P3):**
   - Read the cited file + line range first; do not act on the headline alone.
   - Apply the minimal fix addressing the root cause (not a symptom patch).
   - Add a regression test that would have caught the bug. Skip only for doc-only / pure-cosmetic findings.
   - Update `CLAUDE.md` / project docs if the fix changes an invariant called out there (e.g., cache-invalidation contract).
   - Run the affected test target(s) to confirm green. For this repo: `xcodebuild test -project Kenotex/Kenotex.xcodeproj -scheme Kenotex-macOS -destination 'platform=macOS,arch=arm64' -only-testing:KenotexTests-macOS/<SuiteName>`.

6. **Commit the round's fixes as a single commit:**
   ```
   fix(<scope>): Codex round N — <short summary>

   Pn <description of finding 1>
   Pn <description of finding 2>
   …

   Regression: <test name(s)>
   ```

7. **Loop — return to step 3.** (After a dirty round: commit, then re-run. After a clean round with `CLEAN_STREAK == 1`: re-run the reviewer with no new commits; HEAD is unchanged so the reviewer sees the same diff, which acts as a confirmation pass.)

8. **Merge the reviewed commits into local `${CR_MERGE_TARGET:-main}`** (entered after `CLEAN_STREAK == 2`, before the report). Five preconditions — **all** MUST hold, or fall through to step 9 with `Merge status: deferred — <which precondition failed>` plus the relevant diagnostic. The user takes over from there. Never auto-commit, never auto-rebase, never `--force` your way past a failure. **Never `git push`** at any point in this step — remote stays untouched.

   - **(a) Working tree is clean.** `git status --short` MUST be empty. Residual changes never went through a review round, so merging them defeats the loop's contract ("only Codex-reviewed commits reach main"). Diagnostic on defer: `git status -sb`.
   - **(b) HEAD didn't drift since the last review.** `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]` (snapshot from step 4). Catches external commits, rebases, amendments, or hook-driven rewrites that snuck in between the second clean review and step 8 — none of those advances were reviewer-approved. Diagnostic on defer: `git log --oneline "$LAST_REVIEWED_HEAD"..HEAD`.
   - **(c) Current branch is not the merge target.** `[ "$FEATURE_BRANCH" != "${CR_MERGE_TARGET:-main}" ]`. Already checked at preflight, but re-verify in case the branch was renamed mid-loop. Diagnostic on defer: `git branch --show-current`.
   - **(d) Merge range ⊆ reviewed range.** The reviewer covered `<base>..HEAD`; the merge will land `<merge-base(target,HEAD)>..HEAD` onto the target. Resolve `MERGE_BASE=$(git merge-base "${CR_MERGE_TARGET:-main}" HEAD)`. Verify `git merge-base --is-ancestor "$BASE" "$MERGE_BASE"` OR `[ "$BASE" = "$MERGE_BASE" ]` — base is at or before the merge-base, so every commit landing on the target was inside the review range. If the check fails (user picked a `--base` that's ahead of `main`'s history, or some commits between `main` and base never went through this review), some commits would land on main without reviewer coverage → defer. Diagnostic on defer: `git log --oneline "$BASE"..HEAD` plus `git log --oneline "$MERGE_BASE".."$BASE"` (the gap that wasn't reviewed).
   - **(e) Target has no diverged commits the reviewer didn't see.** `[ "$MERGE_BASE" = "$(git rev-parse "${CR_MERGE_TARGET:-main}")" ]` checks fast-forward eligibility from the target's perspective. When the check fails, target has commits not on the feature branch — the merge will become a true merge commit. That's allowed under `CR_MERGE_FF=auto` or `CR_MERGE_FF=no-ff`, but **defers** under `CR_MERGE_FF=ff-only`. Diagnostic on defer: `git log --oneline "$MERGE_BASE".."${CR_MERGE_TARGET:-main}"` (the diverged target commits).

   - **Merge.** When (a)–(e) all hold:
     - **Detect whether the target is checked out in another worktree.** `MAIN_WT=$(git worktree list --porcelain | awk -v t="refs/heads/${CR_MERGE_TARGET:-main}" '/^worktree / {wt=$2} $0=="branch "t {print wt; exit}')`.
     - **Path A — target is NOT checked out anywhere.** Plain checkout-and-merge. Resolve the merge flag from `CR_MERGE_FF`: `auto` → no extra flag (git's default), `ff-only` → `--ff-only`, `no-ff` → `--no-ff`.
       ```bash
       git checkout "${CR_MERGE_TARGET:-main}"
       git merge $MERGE_FLAG "$FEATURE_BRANCH"
       git checkout "$FEATURE_BRANCH"   # return to feature branch so subsequent /cr-loop-merge runs see the same starting state
       ```
     - **Path B — target IS checked out in another worktree at `$MAIN_WT`.** We can't `git checkout` it here (git refuses). Two sub-cases:
       - **Fast-forward eligible** (precondition (e) collapsed to a fast-forward): use a refspec push to update the local ref without touching either working copy. `git fetch . "HEAD:refs/heads/${CR_MERGE_TARGET:-main}"` advances the local ref. Note this is a *local* fetch (`. ` as remote) — no network, no remote push. The other worktree's working tree stays as the user left it; running `git status` there will show "Your branch is ahead of origin/main by N commits."
       - **True merge required** (target diverged from feature branch): we cannot create a merge commit without checking out the target, and the target is locked by `$MAIN_WT`. **Defer** with `Merge status: deferred — target locked by worktree at $MAIN_WT and merge is not fast-forward`. Diagnostic includes `MERGE_BASE`, the diverged commits on each side, and a copy-pasteable instruction: `cd "$MAIN_WT" && git merge $MERGE_FLAG "$FEATURE_BRANCH"`. The user runs the merge manually in the other worktree.
     - **Pre-merge hook failure** (any path): treat as defer. Surface the hook output. Do NOT bypass with `--no-verify`.
     - **Merge conflicts**: should not happen if precondition (d) holds (the feature branch is rooted at base, target diverged after base only via fast-forward-eligible commits would have been caught by (e); only true divergence reaches here, and even then the conflict surfaces during `git merge` in Path A or in the user's manual run in Path B). If git reports a conflict in Path A, run `git merge --abort` to leave the target branch untouched, then defer with `Merge status: deferred — conflicts on <files>` and the conflict file list. The user resolves manually.

   - **Cleanup after successful merge**: delete any `.cr-loop-handoff-round-*.md` files at repo root via `rm -f` and include a one-line "Cleaned up N stale handoff file(s)" note in the report. The handoffs were recovery artifacts written by prior bail-outs; once the loop has converged + merged, they're obsolete and shouldn't litter the repo. Skipping the rm leaves stale handoffs that confuse future sessions ("the file says round 26 isn't done — is it?"). If the merge fails / is deferred, **do NOT delete** — the handoff still describes work-in-progress that the user needs.

   - **Worktree is NOT removed.** The current worktree (whether the main checkout or a secondary worktree) is left in place after merge so the user can keep iterating from the same feature branch — adding follow-up commits, re-running `/cr-loop-merge` against the next batch of work, or polishing UX before pushing. When the user is genuinely done with the feature line, they remove the worktree manually: `cd <main-checkout> && git worktree remove <path-to-this-worktree> && git branch -d "$FEATURE_BRANCH"` (the `-d` lowercase form refuses unless the branch is merged, which is a useful safety check). This is the documented difference from earlier versions of `/cr-loop-merge` that auto-removed the worktree — auto-removal forced session termination after every merge and lost the in-progress conversational context, which the user found disruptive.

9. **Stop / handoff.** Reached either after a successful merge (step 8) or whenever the loop bails out without converging (round-cap, widening-hint, head-drift, merge-deferred).

   **9a. Handoff file (only when stopping without a successful merge).** Write `.cr-loop-handoff-round-<N>.md` at the repo root with:
   - Stop reason (one of: `round-cap-reached` / `widening-hint` / `widening-sweeps-exhausted` / `widening-hint-no-clear-root-cause` / `head-drift-during-review` / `merge-deferred-<which-precondition>` / `merge-conflict` / `merge-target-locked`).
   - Current `HEAD` SHA + commit count ahead of base.
   - `START` SHA (loop entry point).
   - For widening-hint / widening-sweeps-exhausted / widening-hint-no-clear-root-cause: `STREAK_FILE_SET` + the last `CR_LOOP_WIDEN_AFTER` rounds' raw findings + `WIDENING_SWEEP_HISTORY` (every prior auto-sweep's root-cause headline + commit SHA + post-sweep verdict, so the user can see what was already tried before the loop bailed) + suggested wider sweep targets the agent didn't try.
   - For round-cap: the per-round finding histogram (P0/P1/P2/P3 counts), commit list, advice on whether to raise the cap or restructure.
   - For head-drift: `git log --oneline "$REVIEWED_HEAD"..HEAD` + `git status -sb`.
   - For merge-deferred: which precondition failed + its diagnostic + the exact manual command the user should run (e.g., `cd <main-worktree> && git merge --no-ff <feature-branch>`).
   - **Resume instructions** at the end: exact `/cr-loop-merge` re-invocation, plus any one-shot cleanup the user should do first (rebase / squash / widen scope / raise cap / resolve conflicts in the other worktree).
   - The handoff is auto-deleted by step 8 after the next successful merge, so no manual cleanup line is needed.

   The handoff is a load-bearing signal: it survives session boundaries and lets a fresh agent (or the user days later) pick up exactly where the loop bailed. Never silently exit on a non-converged stop reason — always write the handoff first. **On a successful converge+merge, no handoff is written for THIS run, AND any pre-existing handoff files at repo root are deleted by step 8.**

   **9b. Report (always, whether converged or bailed).**
   - Rounds executed: _N_ (including the final confirmation round if converged).
   - Issues fixed per round (one-line histogram).
   - Final test suite status (must be green).
   - Commit range added by the loop: `git log --oneline $START..HEAD`.
   - Stop reason: `converged` / `<one of the bail reasons above>`.
   - Merge status: `merged $FEATURE_BRANCH into ${CR_MERGE_TARGET:-main}` (only when converged AND step 8 preconditions held), else `deferred — <reason>`. Include the merge-commit SHA on success (or "fast-forward to <SHA>" when no merge commit was created).
   - Worktree status: `preserved at <pwd>` — the worktree is intentionally left in place so the user can keep iterating. Include a one-line manual cleanup hint: `git worktree remove <pwd> && git branch -d "$FEATURE_BRANCH"` (run from a different worktree).
   - **Remote status: untouched** — `git push` was never invoked. The user pushes when they're ready: `git push origin ${CR_MERGE_TARGET:-main}` from a checkout that has the merge target.
   - Handoff path (when applicable): `.cr-loop-handoff-round-<N>.md`.
   - Confirmation: _last two rounds were both clean_ (only when stop reason is `converged`).

## Guardrails

- **Never `git push`.** This command is the local-merge variant; remote interaction is the user's call. If you find yourself reaching for `git push`, you're in the wrong command — use `/cr-loop` instead.
- **Never skip hooks** (`--no-verify`). Fix the hook failure instead.
- **Never `--force` the merge.** `--ff-only` is allowed (it just refuses non-FF merges); `--force`/`--force-with-lease`/`-X theirs`/`-X ours` are forbidden.
- **Don't reformat files the reviewer didn't flag.** Scope each commit to the findings it resolves.
- **Don't fix pre-existing issues** the reviewer surfaces in files outside this branch's diff — acknowledge them in the summary and ask before expanding scope.
- **If the same finding recurs after a fix**, the fix was too narrow. Re-read the reviewer's explanation and widen — do NOT burn another round on the same symptom. With auto-widen ON (default), step 4b's widening guard will auto-escalate to a systematic root-cause sweep (step 4d) before the third recurrence; the user is only paged when `CR_LOOP_MAX_WIDENING_SWEEPS` sweeps have already failed to converge.
- **Round budget is uncapped by default** (`CR_LOOP_ROUND_CAP` is opt-in, unset by default). The loop stops on convergence, the file-family widening guard, head-drift, widening-sweeps-exhausted, or manual cancel — not on a default round count. If you're past ~15 rounds and still dirty, the widening guard (`CR_LOOP_WIDEN_AFTER`, default 5) should already have fired (either auto-sweeping or handing off); if it hasn't (genuinely shifting bug surface), token spend grows linearly with rounds, so consider squash + reorganize or splitting the work into multiple PRs. Set `CR_LOOP_ROUND_CAP=N` when you want an explicit ceiling for the run.
- **Keep the user informed between rounds** with one-line status. Always include both streaks: "Round N: M findings (Pn×a, Pn×b), DIRTY_STREAK=k/<CR_LOOP_WIDEN_AFTER>, applying fixes." On a clean round, include the clean streak: "Round N: clean (CLEAN_STREAK=1/2, running confirmation round)" or "Round N: clean (CLEAN_STREAK=2/2, merging into ${CR_MERGE_TARGET:-main})".
- **Don't `ScheduleWakeup` while waiting for a round.** Use `Monitor` against the codex companion PID (or block on the foreground bash). Wakeup-stacking creates redundant `/cr-loop-merge` re-entries that confuse state and waste tokens.
- **Worktree-aware.** If `${CR_MERGE_TARGET:-main}` is checked out in another worktree, fast-forward via `git fetch . HEAD:refs/heads/<target>` is the only auto path; non-FF defers to the user with a copy-pasteable manual command. Never try to force-checkout the locked branch (git refuses anyway, and bypassing with `--detach` tricks would silently desync the other worktree's index).

## Why --wait (foreground) not --background

The loop is sequential by design — each round's diff depends on the previous round's commit. Running in background means polling for completion, which is wasted tokens compared to blocking on the stdout. If you genuinely suspect the reviewer is hung (no progress in the codex companion process for many minutes, output file size frozen), `/codex:cancel` it manually and resume the loop later — but **do not** wrap the foreground call with an automatic `timeout`, since codex review duration legitimately scales with diff size and you'll mis-classify a slow-but-working reviewer as stuck.

## Differences from `/cr-loop`

This command is a fork of `/cr-loop` with two behavioral changes:

1. **Default base is local `main`, not `origin/main`.** Reviewing against the local merge target keeps the diff scoped to exactly what's about to be merged.
2. **After convergence, merge into local `${CR_MERGE_TARGET:-main}` instead of pushing to the remote.** No `git fetch origin`, no `git push`, no remote interaction at all. The current worktree is preserved after merge so the user can keep iterating from the same feature branch — manual `git worktree remove` is the user's call.

Everything else — the review loop semantics, P3 skip filter, file-family widening guard, **auto-widening sweep** with `CR_LOOP_MAX_WIDENING_SWEEPS` budget, round cap, head-drift detection, handoff file format — is identical across all three commands.

Use `/cr-loop` when you want Codex to gate the work but the integration step (push / merge / PR) is manual or handled by a different workflow. Use `/cr-loop-pr` when you want the reviewed commits to land on the remote and a PR opened automatically (typical multi-dev workflow). Use `/cr-loop-merge` when you want the reviewed commits to land on the local integration branch with no remote interaction (single-dev workflow, local-first setups, or staging changes for a manual push later).
