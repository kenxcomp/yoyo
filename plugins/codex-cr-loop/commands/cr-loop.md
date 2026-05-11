---
description: Loop /codex:review in --wait mode, fix returned issues, re-run until two consecutive clean rounds, then stop (no push, no PR, no merge — local convergence only)
argument-hint: '[<base-ref> (default: origin/main)]'
---

# Codex Review Loop (review only — no remote interaction)

Run `/codex:review --base <ref> --wait` in the foreground, fix every P0/P1/P2/P3
finding it returns, commit, and re-run. Stop when **two consecutive rounds**
return no actionable findings ("did not find any definite correctness bugs" /
empty review body). A single clean round is not enough — Codex occasionally
produces partial / empty reviews on flaky network or model output, and a fresh
second round catches issues the first pass skipped or the previous fix exposed.

After convergence, **stop**. The loop does NOT push, does NOT open a PR, does
NOT merge into a local integration branch. The reviewed commits stay on the
current feature branch in the current worktree, and the next action — push,
open a PR, merge, rebase, squash — is entirely the user's call. Use this
command when you want Codex to gate the work but the integration step is
manual or handled by a different workflow (sibling commands `/cr-loop-merge`
and `/cr-loop-pr` cover those automated paths).

Base ref: `$ARGUMENTS` — default `origin/main`. Reviewing against the remote
target keeps Codex findings aligned with whatever a human reviewer or the
sibling `/cr-loop-pr` would see. Override only when you genuinely want a
different review base (e.g., a release branch, an integration branch named
`develop`).

## Tunable knobs (env overrides)

Read these once during preflight; defaults shown:

- `CR_LOOP_ROUND_CAP=` — **opt-in** ceiling on rounds (unset by default → no cap). When set to a positive integer N, hitting `ROUND_NUM >= N` stops the loop, writes a handoff, and surfaces to the user. Leave unset to let the loop run until it converges, hits the file-family widening guard, drifts, or you cancel manually.
- `CR_LOOP_WIDEN_AFTER=5` — after this many consecutive dirty rounds whose findings stay inside the same file family, stop and surface a widening hint instead of attempting a 6th symptomatic fix.
- `CR_LOOP_SKIP_P3=1` — when `1` (default), rounds whose findings are exclusively P3 are treated as clean (P3 ≈ defensive / style / nit; doesn't block convergence). Set to `0` for strict mode where P3s also block convergence and must be fixed.

No per-round timeout — Codex review duration scales with diff size and reviewer model output, and a large refactor's review can legitimately take 15+ minutes. The loop blocks on the foreground reviewer until it returns or the user manually cancels (`/codex:cancel`).

These are advisory escape valves, not silencers. Each one writes a handoff and stops — the user always decides whether to continue.

## Procedure

1. **Preflight.**
   - Resolve `BASE` from `$ARGUMENTS`. Default: `BASE="${ARGUMENTS:-origin/main}"`.
   - Refresh the review base when it points at a remote ref: if `BASE` is `origin/<branch>` (or any `<remote>/<branch>` form), run `git fetch <remote> <branch> --quiet` so the review diff isn't measured against a stale ref. Skip the fetch when `BASE` resolves to a local ref (no remote interaction at all in that case). Abort if a needed fetch fails (offline / unreachable remote / wrong remote name).
   - `git status --short` — working tree must be clean. If dirty, commit or stash before starting; otherwise the diff will include unrelated noise and reviewer findings won't map to commits cleanly.
   - Record the starting commit: `START=$(git rev-parse HEAD)`.
   - Capture the feature branch: `FEATURE_BRANCH=$(git branch --show-current)`. Abort if empty (detached HEAD — there's nothing for the loop to anchor to; create or check out a branch first).
   - **Verify `BASE` resolves.** Run `git rev-parse --verify "$BASE"` (must succeed). If it fails, abort with `BASE ($BASE) does not resolve — check the ref name, and that the relevant remote was fetched if BASE points at one`.
   - Initialize `CLEAN_STREAK=0` — tracks consecutive clean rounds; loop ends when it reaches 2.
   - Initialize `DIRTY_STREAK=0` and `STREAK_FILE_SET=∅` — see step 4b for widening guard semantics.
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

   **Post-review HEAD check is load-bearing**: the reviewer takes minutes, and during that window an external commit, rebase, or hook-driven rewrite from another shell can advance HEAD. The reviewer's verdict applies to whatever HEAD it saw mid-run; if the local HEAD has since moved, that verdict no longer covers the working state. **Do not classify this round, do not touch `CLEAN_STREAK`** — surface `git log --oneline "$REVIEWED_HEAD"..HEAD` plus `git status -sb` to the user, write a handoff (step 9) with `Stop reason: head-drift-during-review`, and stop. The user must investigate (concurrent agent? auto-commit hook? someone working in another shell?) before re-invoking `/cr-loop`. Treating the round as clean would let unreviewed commits ride into whatever the user decides to do with the branch next.

   Read the **`# Codex Review`** section from stdout — everything above it is reviewer command trace.

   **While waiting for a round to finish, use `Monitor` to block on the codex process PID exit, NOT `ScheduleWakeup`.** Wakeup re-enters the prompt at a fixed interval and produces redundant `/cr-loop` invocations stacked behind each other if the round runs long; Monitor delivers a single notification when the process exits, exactly when you need to act.

4. **Classify the verdict** (only reached if step 3's post-review HEAD check passed and the round didn't time out):

   **Clean** if the review body says "did not find any definite correctness bugs" OR contains no lines matching `^- \[P[0-3]\]`. **The streak only counts when consecutive clean rounds reviewed the same HEAD** — `LAST_REVIEWED_HEAD` is the SHA of the previous clean round (unset on first ever / after a dirty round). If `LAST_REVIEWED_HEAD == REVIEWED_HEAD`, this round confirms the same HEAD: `CLEAN_STREAK += 1`. Otherwise (HEAD changed between the previous clean round and this one — external commit, rebase, or step 6 commit landing between rounds): the previous streak no longer applies, set `CLEAN_STREAK = 1` and `LAST_REVIEWED_HEAD = REVIEWED_HEAD` (this is now the SHA being confirmed). Reset `DIRTY_STREAK = 0` and `STREAK_FILE_SET = ∅`. If `CLEAN_STREAK >= 2`, jump to step 8 — `LAST_REVIEWED_HEAD` is the SHA both clean rounds confirmed. Else, loop back to step 3 for the confirmation round.

   **Dirty** — every `- [Pn] <headline> — <file>:<line>` bullet is an issue to fix. Apply the optional P3-skip filter first (see 4a), then update the widening guard (see 4b), then proceed to step 5.

   **4a. P3-only skip filter** (when `CR_LOOP_SKIP_P3=1`):
   - Parse all finding bullets. If **every** finding is `[P3]`, treat the round as effectively clean and apply the **full clean-classification machinery from step 4** — do NOT just bump `CLEAN_STREAK` and loop. Specifically:
     - If `LAST_REVIEWED_HEAD == REVIEWED_HEAD`: `CLEAN_STREAK += 1`. Else: `CLEAN_STREAK = 1`, `LAST_REVIEWED_HEAD = REVIEWED_HEAD`.
     - Reset `DIRTY_STREAK = 0` and `STREAK_FILE_SET = ∅` (the dirty streak ends here, even though findings exist — they're just below the action threshold).
     - **Check convergence**: if `CLEAN_STREAK >= 2`, jump to step 8 (stop). This check is load-bearing — without it the loop keeps re-entering step 3 forever because no fix is applied, HEAD never changes, every subsequent round is the same P3-only set, `CLEAN_STREAK` increments without bound, and step 8 is never reached.
     - Log `Round N: P3-only ignored (CR_LOOP_SKIP_P3=1, CLEAN_STREAK=k/2)`.
     - Apply step 4c round cap (only when the user has opted in via `CR_LOOP_ROUND_CAP` — a misconfigured env var with persistent P3 findings shouldn't burn rounds silently when a ceiling has been set).
     - Otherwise return to step 3 for the confirmation round.
   - **Note on no-commit semantics**: this path deliberately does NOT commit anything (P3s are skipped, not fixed). HEAD stays at `REVIEWED_HEAD`, so the next round's `REVIEWED_HEAD` will equal `LAST_REVIEWED_HEAD` and the second pass will satisfy `CLEAN_STREAK >= 2` immediately if Codex returns the same P3-only verdict (or genuinely clean). If Codex returns a higher-severity finding next round, the dirty path takes over normally — `CLEAN_STREAK` resets, `DIRTY_STREAK` starts at 1 with the new file set.
   - If any finding is P0/P1/P2, ignore this filter (proceed to step 4b + 5 with the full finding list, including the P3 entries — fix them alongside the higher-severity ones).

   **4b. File-family widening guard.** Extract the set of cited file paths from the finding bullets (the `<file>` portion of `- [Pn] <headline> — <file>:<line>`). Call this `ROUND_FILES`.
   - If `DIRTY_STREAK == 0` (this is the first dirty round of a new streak): set `STREAK_FILE_SET = ROUND_FILES`, `DIRTY_STREAK = 1`. Proceed to step 5.
   - If `DIRTY_STREAK > 0` and `ROUND_FILES ⊆ STREAK_FILE_SET` (every cited file in this round was also cited in some prior dirty round of this streak): increment `DIRTY_STREAK`, keep `STREAK_FILE_SET` as-is. If `DIRTY_STREAK >= CR_LOOP_WIDEN_AFTER` (default 5): **stop**. Write a handoff (step 9) with `Stop reason: widening-hint`, including (a) the file family list (`STREAK_FILE_SET`), (b) the last `CR_LOOP_WIDEN_AFTER` rounds' findings verbatim, (c) suggested wider sweep targets (sibling files in the same module / call graph that weren't explicitly cited but might share the bug pattern). Surface the handoff path to the user and exit. The user runs the widening sweep manually or expands the fix scope and re-invokes `/cr-loop`.
   - If `DIRTY_STREAK > 0` and `ROUND_FILES ⊄ STREAK_FILE_SET` (this round cited a *new* file family — the bug surface moved): reset `STREAK_FILE_SET = ROUND_FILES`, `DIRTY_STREAK = 1`. Proceed to step 5. (A genuinely shifting surface is healthy progress; the widening guard only fires when we're spinning on the same file family.)
   - Always reset `CLEAN_STREAK = 0` and `LAST_REVIEWED_HEAD` on any dirty round (the upcoming step 6 commit produces a new HEAD that must be re-reviewed from scratch).

   **4c. Optional round cap.** After classification, if `CR_LOOP_ROUND_CAP` is set to a positive integer AND `ROUND_NUM >= CR_LOOP_ROUND_CAP`: write a handoff (step 9) with `Stop reason: round-cap-reached`, surface, exit. The cap is **opt-in** — when `CR_LOOP_ROUND_CAP` is unset or empty (the default), this step is a no-op and the loop runs uncapped (it still stops on convergence, widening guard, head-drift, or manual cancel). Set it (e.g. `CR_LOOP_ROUND_CAP=20 /cr-loop ...`) to bound worst-case token spend on a single invocation; the user can resume by re-invoking with a higher cap or take the surfaced state and decide manually.

5. **Fix each finding in order (highest severity first: P0 > P1 > P2 > P3):**
   - Read the cited file + line range first; do not act on the headline alone.
   - Apply the minimal fix addressing the root cause (not a symptom patch).
   - Add a regression test that would have caught the bug. Skip only for doc-only / pure-cosmetic findings.
   - Update `CLAUDE.md` / project docs if the fix changes an invariant called out there (e.g., cache-invalidation contract).
   - Run the affected test target(s) to confirm green. Use the project's standard test command (e.g., `xcodebuild test ...`, `cargo test`, `pytest`, `bun test` — see the project's `CLAUDE.md` for the canonical invocation).

6. **Commit the round's fixes as a single commit:**
   ```
   fix(<scope>): Codex round N — <short summary>

   Pn <description of finding 1>
   Pn <description of finding 2>
   …

   Regression: <test name(s)>
   ```

7. **Loop — return to step 3.** (After a dirty round: commit, then re-run. After a clean round with `CLEAN_STREAK == 1`: re-run the reviewer with no new commits; HEAD is unchanged so the reviewer sees the same diff, which acts as a confirmation pass.)

8. **Stop — verify final state and exit** (entered after `CLEAN_STREAK == 2`, before the report). No push, no PR, no merge. Two preconditions are checked purely so the report accurately reflects what's on disk; failure of either does NOT block the stop, but DOES surface the deviation in step 9b so the user knows their post-loop state isn't quite what convergence implied.

   - **(a) Working tree is clean.** `git status --short` MUST be empty. If non-empty, residual changes never went through a review round — surface them (`git status -sb`) so the user knows to commit / stash / discard before treating the converged state as "ready to push / merge / open PR".
   - **(b) HEAD didn't drift since the last review.** `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]` (snapshot from step 4). Catches external commits, rebases, amendments, or hook-driven rewrites that snuck in between the second clean review and step 8 — none of those advances were reviewer-approved. Surface `git log --oneline "$LAST_REVIEWED_HEAD"..HEAD` if drift detected.

   - **No remote interaction.** `git fetch` (other than the optional preflight refresh of the review base in step 1), `git push`, `gh pr create`, `git checkout <other-branch>`, `git merge` — none of these run in this command. The current worktree is preserved exactly as-is.

   - **Cleanup after successful converge**: delete any `.cr-loop-handoff-round-*.md` files at repo root via `rm -f` and include a one-line "Cleaned up N stale handoff file(s)" note in the report. The handoffs were recovery artifacts written by prior bail-outs; once the loop has converged, they're obsolete and shouldn't litter the repo. Skipping the rm leaves stale handoffs that confuse future sessions ("the file says round 26 isn't done — is it?"). If preconditions (a) or (b) above failed, **do NOT delete** — surface the deviation first; the user will tell you whether the converged state is still actionable.

9. **Stop / handoff.** Reached either after a successful converge (step 8) or whenever the loop bails out without converging (round-cap, widening-hint, head-drift).

   **9a. Handoff file (only when stopping without converging).** Write `.cr-loop-handoff-round-<N>.md` at the repo root with:
   - Stop reason (one of: `round-cap-reached` / `widening-hint` / `head-drift-during-review`).
   - Current `HEAD` SHA + commit count ahead of base.
   - `START` SHA (loop entry point).
   - For widening-hint: `STREAK_FILE_SET` + the last `CR_LOOP_WIDEN_AFTER` rounds' raw findings + suggested wider sweep targets the agent didn't try.
   - For round-cap: the per-round finding histogram (P0/P1/P2/P3 counts), commit list, advice on whether to raise the cap or restructure.
   - For head-drift: `git log --oneline "$REVIEWED_HEAD"..HEAD` + `git status -sb`.
   - **Resume instructions** at the end: exact `/cr-loop` re-invocation, plus any one-shot cleanup the user should do first (rebase / squash / widen scope / raise cap / investigate concurrent writer).
   - The handoff is auto-deleted by step 8 after the next successful converge, so no manual cleanup line is needed.

   The handoff is a load-bearing signal: it survives session boundaries and lets a fresh agent (or the user days later) pick up exactly where the loop bailed. Never silently exit on a non-converged stop reason — always write the handoff first. **On a successful converge, no handoff is written for THIS run, AND any pre-existing handoff files at repo root are deleted by step 8.**

   **9b. Report (always, whether converged or bailed).**
   - Rounds executed: _N_ (including the final confirmation round if converged).
   - Issues fixed per round (one-line histogram).
   - Final test suite status (must be green).
   - Commit range added by the loop: `git log --oneline $START..HEAD`.
   - Stop reason: `converged` / `<one of the bail reasons above>`.
   - Final state status: `clean — HEAD at <SHA> (== LAST_REVIEWED_HEAD)` when converged AND step 8 preconditions both held; otherwise `converged but <which-precondition> drifted — <diagnostic>` so the deviation is visible at a glance.
   - Worktree status: `preserved at <pwd>` — the worktree is intentionally left in place so the user can keep iterating, push, open a PR, merge, or invoke a sibling command (`/cr-loop-merge`, `/cr-loop-pr`).
   - Next-step suggestions (informational only — do NOT act on them automatically):
     - To push the feature branch to its upstream: `git push` (or `git push -u <remote> <branch>` on first push).
     - To open a PR after pushing: `gh pr create` (or use `/cr-loop-pr` for the integrated push-and-PR flow next time).
     - To merge into a local integration branch instead: `/cr-loop-merge`.
   - Handoff path (when applicable): `.cr-loop-handoff-round-<N>.md`.
   - Confirmation: _last two rounds were both clean_ (only when stop reason is `converged`).

## Guardrails

- **No remote interaction.** `git push`, `git push --force`, `git push --force-with-lease`, `gh pr create`, `gh pr edit` — none of these run in this command. If you find yourself reaching for any of them, you're in the wrong command — use `/cr-loop-pr` (push + PR) or `/cr-loop-merge` (local merge) instead.
- **No checkout / merge.** This command never switches branches and never creates a merge commit. The feature branch the user started on is the branch the user ends on.
- **Never skip hooks** (`--no-verify`). Fix the hook failure instead.
- **Don't reformat files the reviewer didn't flag.** Scope each commit to the findings it resolves.
- **Don't fix pre-existing issues** the reviewer surfaces in files outside this branch's diff — acknowledge them in the summary and ask before expanding scope.
- **If the same finding recurs after a fix**, the fix was too narrow. Re-read the reviewer's explanation and widen — do NOT burn another round on the same symptom. If the same finding recurs **a third time** after two distinct widening attempts, stop and surface to the user (this is a stricter, finer-grained version of the file-family widening guard in 4b — both can fire; whichever fires first wins).
- **Round budget is uncapped by default** (`CR_LOOP_ROUND_CAP` is opt-in, unset by default). The loop stops on convergence, the file-family widening guard, head-drift, or manual cancel — not on a default round count. If you're past ~15 rounds and still dirty, the widening guard (`CR_LOOP_WIDEN_AFTER`, default 5) should already have fired with a handoff; if it hasn't (genuinely shifting bug surface), token spend grows linearly with rounds, so consider squash + reorganize or splitting the work into multiple PRs. Set `CR_LOOP_ROUND_CAP=N` when you want an explicit ceiling for the run.
- **Keep the user informed between rounds** with one-line status. Always include both streaks: "Round N: M findings (Pn×a, Pn×b), DIRTY_STREAK=k/<CR_LOOP_WIDEN_AFTER>, applying fixes." On a clean round, include the clean streak: "Round N: clean (CLEAN_STREAK=1/2, running confirmation round)" or "Round N: clean (CLEAN_STREAK=2/2, stopping — no push, no PR, no merge)".
- **Don't `ScheduleWakeup` while waiting for a round.** Use `Monitor` against the codex companion PID (or block on the foreground bash). Wakeup-stacking creates redundant `/cr-loop` re-entries that confuse state and waste tokens.

## Why --wait (foreground) not --background

The loop is sequential by design — each round's diff depends on the previous round's commit. Running in background means polling for completion, which is wasted tokens compared to blocking on the stdout. If you genuinely suspect the reviewer is hung (no progress in the codex companion process for many minutes, output file size frozen), `/codex:cancel` it manually and resume the loop later — but **do not** wrap the foreground call with an automatic `timeout`, since codex review duration legitimately scales with diff size and you'll mis-classify a slow-but-working reviewer as stuck.

## Differences from `/cr-loop-pr` and `/cr-loop-merge`

This command shares the entire review-loop body with `/cr-loop-pr` (P3 skip filter, file-family widening guard, round cap, head-drift detection, handoff file format) and differs only in the completion step:

- `/cr-loop` — converges and **stops**. No push, no PR, no merge. The user takes whatever next action they want.
- `/cr-loop-pr` — converges, then **pushes the feature branch** to `${CR_PR_REMOTE:-origin}` and **opens a PR** against `${CR_PR_BASE:-main}` (or appends commits to an existing PR).
- `/cr-loop-merge` — converges, then **merges the feature branch into the local `${CR_MERGE_TARGET:-main}`** branch. No push, no PR.

| When to use | Command |
|---|---|
| You want Codex to gate the work, but the integration step (push / merge / PR) is manual or handled by a different workflow | `/cr-loop` |
| Reviewed commits should land on `origin/<branch>` AND open a PR for human review (multi-dev workflow, codeowner gate, CI required) | `/cr-loop-pr` |
| Reviewed commits should land on local `${CR_MERGE_TARGET:-main}` for a manual push later (single-dev workflow, local-first setups) | `/cr-loop-merge` |
