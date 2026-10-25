---
description: Codex review loop (class-format findings, diff-only re-review, no-repeat ledger, 3-round step-back) until two consecutive clean rounds, then push branch and open PR against origin's default branch (worktree preserved)
argument-hint: '[<base-ref> (default: origin/<auto-detected default branch>)]'
---

# Codex Review Loop (open PR against origin's default branch)

Run Codex review rounds against `<base-ref>`, fix every bug **class** they report, commit,
and repeat until the loop **converges**. Convergence means two consecutive clean rounds on
the same HEAD, the second of which reviews the whole diff. A single clean round is not
enough: Codex sometimes returns a partial or empty review, and a second whole-diff pass
catches problems that the fixes introduced together.

After convergence, the command **pushes the feature branch to `origin` and opens a pull
request against `origin/<default branch>`**. If a PR already exists for this head branch,
the new commits are pushed to it and that PR's URL is reported. The worktree is kept.
**Never push to the base branch.** Merging the PR is the user's call.

Base ref: `$ARGUMENTS`. The default is `origin/<repo default branch>`, auto-detected into
`CR_PR_BASE` (see step 1). The review base should match the PR target, because the PR's
diff is `<merge-base(origin/<base>, HEAD)>..HEAD`.

## Shared review protocol (authoritative — read it first)

**Before step 2, read `${CLAUDE_PLUGIN_ROOT}/references/review-protocol.md` in full.** It
defines steps 2–7 and the shared parts of step 9:

- the reviewer runner, `${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh`
- the `full`, `incremental` and `step-back` modes
- class-format findings (`Pattern / Instances / Fix / Prevent`)
- the per-branch no-repeat **ledger**
- the exact **convergence rule**
- the **round cap**: 3 dirty rounds trigger a mandatory step-back
- **codify at source**
- the interaction-logic guard (5a), commit format, handoff and report contents
- the **PR-bot review loop rules** that apply after the PR is open

This file adds only:

- the preflight (step 1)
- the auto-rebase and push/PR completion (step 8)
- the PR-specific stop reasons and report lines

**Interaction-logic guard (always ON, cannot be disabled; protocol 5a).** Any fix that would
change user-visible interaction behavior pauses the loop until the user explicitly confirms
it. The **push and `gh pr create` are blocked** while the guard is pending. "No response" is
never consent.

**Auto-rebase onto the latest PR base (default ON; step 8.0).** After convergence and before
the push, the command:

1. Re-fetches `${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main}`.
2. If it advanced, rebases onto it and runs **one whole-diff confirmation round** before
   pushing.

Rebase conflicts are never auto-resolved: the command aborts the rebase and defers. If a
PR already exists, updating it after a rebase needs a user-confirmed `--force-with-lease`,
never a bare `--force`. `CR_PR_AUTO_REBASE=0` turns the rebase off and restores the deferral
behavior of precondition (e).

## Tunable knobs

The shared knobs (`CR_LOOP_ROUND_CAP=3`, `CR_LOOP_MAX_STEP_BACKS=1`, `CR_LOOP_SKIP_P3=1`,
`CR_LOOP_REQUIRE_REBASED=1`, `CR_LOOP_REVIEW_EFFORT=high`, `CR_LOOP_REVIEW_MODEL=`) are
documented in the protocol, along with how the v1.6 knobs that v1.7.0 removed are mapped.

This command adds:

- `CR_PR_AUTO_REBASE=1` — step 8.0 auto-rebase plus confirmation round. With `0`,
  precondition (e) defers instead when the base moved.
- `CR_PR_BASE=` — the PR target branch. **Unset means auto-detect** (step 1). Override it,
  e.g. with `develop`.
- `CR_PR_REMOTE=origin` — the push and PR remote, e.g. `upstream` for forks.
- `CR_PR_DRAFT=0` — `1` opens the PR as a draft.
- `CR_PR_TITLE=` — when non-empty, used verbatim as the PR title, truncated to 70 characters.

## Procedure

1. **Preflight.**
   - **Resolve `CR_PR_BASE` and `BASE`.** This auto-detects the default branch from local
     refs, with no network access:
     ```bash
     REMOTE="${CR_PR_REMOTE:-origin}"
     if [ -z "$CR_PR_BASE" ]; then
       CR_PR_BASE=$(git symbolic-ref --quiet --short "refs/remotes/$REMOTE/HEAD" 2>/dev/null | sed "s#^$REMOTE/##")
       if [ -z "$CR_PR_BASE" ]; then
         if   git rev-parse --verify --quiet "refs/remotes/$REMOTE/main"   >/dev/null; then CR_PR_BASE=main
         elif git rev-parse --verify --quiet "refs/remotes/$REMOTE/master" >/dev/null; then CR_PR_BASE=master
         else CR_PR_BASE=main
         fi
       fi
     fi
     BASE="${ARGUMENTS:-$REMOTE/$CR_PR_BASE}"
     ```
     **From here on, `CR_PR_BASE` holds this resolved value.** Every later
     `${CR_PR_BASE:-main}` evaluates to it.
   - **Check `gh`.** Confirm it is installed (`command -v gh`) and authenticated
     (`gh auth status`). Otherwise abort with the matching install or `gh auth login`
     instruction.
   - **Refresh the base:** `git fetch "${CR_PR_REMOTE:-origin}" "${CR_PR_BASE:-main}" --quiet`.
     Abort on failure.
   - **Check the working tree with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean`.** This is the single clean-tree check shared by
     preflight and completion. It must print `TREE=clean`; it ignores only untracked repo-root
     `.cr-loop-handoff-round-<N>.md` files left by an earlier stop. On `TREE=dirty`, show its
     `DIRTY|` lines and ask the user to commit or stash them first.
   - **Record the start:** `START=$(git rev-parse HEAD)`.
   - **Record the branch:** `FEATURE_BRANCH=$(git branch --show-current)`. Abort if it is
     empty (detached HEAD).
   - **Check the branch is not the base:** verify `FEATURE_BRANCH != ${CR_PR_BASE:-main}`.
   - **Check `BASE` resolves:** `git rev-parse --verify "$BASE"`. On failure, abort with
     `BASE ($BASE) does not resolve — check the ref name and that ${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main} was fetched`.
   - **Check the PR target exists on the remote:**
     `git rev-parse --verify "refs/remotes/${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main}"`.
   - **Base-currency gate** (hard block). It honors `CR_LOOP_REQUIRE_REBASED`, default `1`;
     `0` skips the gate. Run `git merge-base --is-ancestor "$BASE" HEAD`.
     - **Exit 0:** proceed.
     - **Exit 1** (the branch is **stale**): don't start a round. Ask the user through the
       step-5a surface (`form-base` radio, or inline **A/B**). There is intentionally no
       "review anyway" option:
       - **(A) Rebase first.** Print `git rebase "$BASE"` and `/cr-loop-pr $ARGUMENTS`,
         then stop. The command never rebases for you here.
       - **(B) Abort.**

       Block on the reply. "No response" is not consent.

     This gate catches a branch that *starts* stale. Step 8.0 handles the base moving
     *during* the loop.
   - **Initialize:** `ROUND_NUM=0`, `CLEAN_STREAK=0`, empty `LAST_CLEAN_HEAD`.

2. **Review loop: protocol steps 2–7.** Run them exactly as written, with `BASE` from step
   1. Convergence goes to step 8 with `LAST_REVIEWED_HEAD`; any stop reason goes to step 9.

8. **Push the feature branch and open or update the PR.** This step runs after convergence
   and before the report, in this order:
   1. **8.0** auto-rebase (when `CR_PR_AUTO_REBASE != 0`)
   2. the preconditions **(a)–(e)**, all of which must hold; otherwise go to step 9 with
      `PR status: deferred — <which>`
   3. **push**
   4. **PR create / update**

   The loop never auto-resolves a rebase conflict and never pushes with a bare `--force`.
   The only history-rewriting push is a user-confirmed `--force-with-lease` that updates an
   existing PR after an 8.0 rebase.

   **8.0 Auto-rebase onto the latest PR base.** This runs only when `CR_PR_AUTO_REBASE != 0`.
   With `0`, skip it, treat `REBASED_IN_8_0=0`, and let (e) guard instead.

   1. **Re-fetch:** `git fetch "${CR_PR_REMOTE:-origin}" "${CR_PR_BASE:-main}" --quiet`. On
      failure, defer with `pr-deferred-fetch-failed`.
   2. **Check whether the base moved.** Set
      `NEW_BASE_TIP=$(git rev-parse "refs/remotes/${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main}")`.
      If `git merge-base --is-ancestor "$NEW_BASE_TIP" HEAD` succeeds, don't rebase and
      don't run another round. Set `REBASED_IN_8_0=0` and continue with (a)–(e).
   3. **The base advanced: rebase, then re-confirm.** Run
      `git rebase "refs/remotes/${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main}"`.
      - **Conflict.** Capture `git diff --name-only --diff-filter=U`, then
        `git rebase --abort`. Defer with `pr-deferred-rebase-conflict`, listing the files
        and the manual remedy. Stop.
      - **Clean rebase.** The rewritten HEAD needs **one confirmation round**. Use
        protocol step 3 with `--mode full`, because the old reviewed head is no longer an
        ancestor; `cr-review.sh next` also returns `full` here.
        ```bash
        bash "$CR_REVIEW" start --mode full --base "$BASE"
        # wait (protocol 3c), then:
        bash "$CR_REVIEW" finish
        ```
        `ROUND_NUM` increments as usual. The ledger travels with the rebase, so the round
        reports nothing already handled. Head drift and reviewer errors follow protocol 3d.
        - **Clean** (or P3-only with `CR_LOOP_SKIP_P3=1`): set
          `LAST_REVIEWED_HEAD=$REVIEWED_HEAD` and `REBASED_IN_8_0=1`, then continue with
          (a)–(e). Preconditions (d) and (e) hold by construction.
        - **Dirty:** the new base exposed a real issue. Run protocol steps 5–6 (fix,
          including the 5a guard, then commit), reset `CLEAN_STREAK=0`, and go back to
          protocol step 3. The loop re-converges against the new base and comes back to
          step 8 and 8.0.

   **Preconditions:**

   - **(a) The working tree is clean.** `bash "${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh" tree-clean` must print `TREE=clean`. This is the same check
     as the preflight, so a leftover handoff never blocks completion; any other change does.
     Diagnostic: its `DIRTY|` lines.
   - **(b) HEAD has not moved since the last review:**
     `[ "$(git rev-parse HEAD)" = "$LAST_REVIEWED_HEAD" ]`. Diagnostic:
     `git log --oneline "$LAST_REVIEWED_HEAD"..HEAD`.
   - **(c) The current branch is not the PR target.**
   - **(d) The push range is inside the reviewed range.** Set
     `UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)`.
     - **Skip this check when `REBASED_IN_8_0=1`.**
     - Otherwise, if `UPSTREAM` is set, verify `git merge-base --is-ancestor "$BASE" "$UPSTREAM"`.
       Diagnostic: `git log --oneline "$UPSTREAM"..HEAD` plus
       `git log --oneline "$BASE"..HEAD`.
     - If `UPSTREAM` is unset (first push), skip the check.
   - **(e) The PR target's tip is covered by `BASE`.** With auto-rebase on, this always
     holds. It can only defer when `CR_PR_AUTO_REBASE=0`. Set
     `PR_TARGET_TIP=$(git rev-parse "refs/remotes/${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main}")`
     and verify
     `git merge-base --is-ancestor "$PR_TARGET_TIP" "$BASE" || [ "$BASE" = "$PR_TARGET_TIP" ]`.
     If that fails, defer with
     `PR status: deferred — origin/<base> moved during the loop; PR diff would include unreviewed commits`.
     Diagnostic: `git log --oneline "$BASE".."$PR_TARGET_TIP"`.

   **Push.** This runs once (a)–(e) hold:
   - **Upstream is `${CR_PR_REMOTE:-origin}/$FEATURE_BRANCH` and `REBASED_IN_8_0=0`:** run
     `git push`, with no force flag of any kind.
   - **Upstream is `${CR_PR_REMOTE:-origin}/$FEATURE_BRANCH` and `REBASED_IN_8_0=1`:** the
     update needs `--force-with-lease`. **Block for explicit user confirmation first**,
     using a `form-base` radio or inline A/B:
     - **(A) Force-update the PR:**
       `git push --force-with-lease "${CR_PR_REMOTE:-origin}" "$FEATURE_BRANCH"`. If the
       lease check fails, fall through to the non-fast-forward deferral below.
     - **(B) Skip the push:** defer with `pr-deferred-force-push-declined`.

     "No response" is not consent. Never force-push without an answer.
   - **Upstream points elsewhere:** defer with
     `PR status: deferred — upstream points at $UPSTREAM, expected ${CR_PR_REMOTE:-origin}/$FEATURE_BRANCH`.
   - **Upstream unset:** run `git push -u "${CR_PR_REMOTE:-origin}" "$FEATURE_BRANCH"`.
   - **Pre-push hook failure:** defer and show the hook output. Never use `--no-verify`.
   - **Push rejected (non-fast-forward, or a failed lease):** defer with
     `PR status: deferred — non-fast-forward push (someone else pushed to ${CR_PR_REMOTE:-origin}/$FEATURE_BRANCH)`.
     Diagnostic: `git log --oneline "$UPSTREAM"..HEAD` and `git log --oneline HEAD.."$UPSTREAM"`.
     **Never escalate to a bare `--force`.**

   **Detect an existing PR:**
   ```bash
   EXISTING_PR_URL=$(gh pr list --head "$FEATURE_BRANCH" --base "${CR_PR_BASE:-main}" \
       --state open --json url --jq '.[0].url' 2>/dev/null)
   ```
   If it is non-empty, **do not call `gh pr create`**. The push has already updated that PR;
   report its URL.

   **Create the PR** (only when there is no existing PR):
   - **Title.** Use `CR_PR_TITLE` if it is set. Otherwise use the subject of the single
     commit, or of the most recent commit when there are several. Truncate to 70 characters
     at a word boundary and append `…` if anything was cut.
   - **Body.** Write it to a **file** in a temporary directory, never inline. Inline
     `--body "$(…)"` and unquoted heredocs mangle backticks and quotes. Then pass it with
     `--body-file`. Replace every `<…>` placeholder with real content.
     ```markdown
     ## Summary
     <git log --reverse --format='- %s (%h)' "$BASE"..HEAD>

     ## Test plan
     <the project's build / test / lint commands this loop actually ran, from the repo's CLAUDE.md / AGENTS.md / README, each with its result>

     ## Codex review
     Converged after <ROUND_NUM> round(s) via `/cr-loop-pr` (full×a, incremental×b, step-back×c); the last two rounds were clean on <sha>, the second over the whole diff.
     Classes: <new / reopened ids with one-line titles>; codified: <Cn → artifact>; out of scope: <list or "none">.

     ## 业务影响
     <the business-impact summary from protocol 9b — 3–8 lines, or the literal 无业务逻辑影响>

     🤖 Generated with [Claude Code](https://claude.com/claude-code)
     ```
   - **Open the PR,** adding `--draft` only when `CR_PR_DRAFT=1`. Do not use the
     `${CR_PR_DRAFT:+--draft}` idiom: it also fires on the default `0`.
     ```bash
     DRAFT_FLAG=""; [ "${CR_PR_DRAFT:-0}" = "1" ] && DRAFT_FLAG="--draft"
     PR_URL=$(gh pr create --base "${CR_PR_BASE:-main}" --head "$FEATURE_BRANCH" \
         $DRAFT_FLAG --title "$PR_TITLE" --body-file "$PR_BODY_FILE")
     ```
   - **`gh pr create` fails:** defer with `PR status: deferred — gh pr create failed: <stderr>`.
     The branch is already pushed, so a re-run finds it and retries cleanly.

   **After a successful push and PR open or update:**
   - Run `rm -f .cr-loop-handoff-round-*.md` and report "Cleaned up N stale handoff
     file(s)". If the step was deferred, do **not** delete them.
   - Keep the ledger. The PR-bot loop uses it (see protocol, "After the PR is open").
   - **Keep the worktree.** After the PR merges, the user cleans up with
     `cd <main-checkout> && git worktree remove <path> && git branch -D "$FEATURE_BRANCH"`.
     Run `git fetch --prune` first when the PR was squash-merged.

9. **Stop / handoff.**

   **9a. Handoff.** Use protocol 9a with these extra stop reasons:
   - `push-deferred-<which-precondition>`
   - `push-rejected`
   - `pr-create-failed`
   - `pr-deferred-fetch-failed`
   - `pr-deferred-rebase-conflict`
   - `pr-deferred-force-push-declined`

   Add detail for each:
   - **push-deferred:** the precondition and its diagnostic, plus the manual command (e.g.
     `git pull --rebase ${CR_PR_REMOTE:-origin} $FEATURE_BRANCH`).
   - **pr-create-failed:** the stderr and a retry command that uses `--body-file`.
   - **pr-deferred-rebase-conflict:** the conflicting files and the manual remedy. The abort
     leaves the branch at its HEAD from before the rebase.
   - **pr-deferred-force-push-declined:** a ready-to-run
     `git push --force-with-lease ${CR_PR_REMOTE:-origin} $FEATURE_BRANCH`.
   - **pr-deferred-fetch-failed:** the fetch error. A re-run resumes at step 8.

   Resume with `/cr-loop-pr $ARGUMENTS`.

   **9b. Report.** Include the shared protocol 9b lines and end with the Chinese
   **Business-impact summary**, which is mandatory. The same text goes into the PR body's
   `## 业务影响` section. Add:
   - **Rebase status** (when `CR_PR_AUTO_REBASE != 0`): one of
     `rebased onto ${CR_PR_REMOTE:-origin}/${CR_PR_BASE:-main} @ <tip>, 1 confirmation round clean`,
     `base unchanged — no rebase needed`, or `deferred — <reason>`.
   - **Push status:** `pushed $FEATURE_BRANCH to ${CR_PR_REMOTE:-origin}/$FEATURE_BRANCH`.
     Note `--force-with-lease` when it was used. Otherwise `deferred — <reason>`.
   - **PR status:** `opened <PR_URL>` or `updated existing <PR_URL>`. Otherwise
     `deferred — <reason>`.
   - **Worktree status:** `preserved at <pwd>`, plus the cleanup hint for after the merge.
   - **Next:** if PR bots review the PR, follow the protocol's "After the PR is open" rules.
     That means diff-only re-review, no repeats (cite ledger ids), class grouping, and a
     step-back after 3 bot rounds.

## Guardrails

The shared protocol guardrails apply, plus:

- **Interaction guard.** No push and no `gh pr create` while a 5a decision is pending.
- **Base-currency gate.** The preflight check is hard and never auto-rebases. A base that
  moves *during* the loop is handled at step 8.0, or deferred by (e) when
  `CR_PR_AUTO_REBASE=0`.
- **Only push the feature branch.** Never push to `${CR_PR_BASE:-main}`.
- **Never use a bare `--force`.** `--force-with-lease` is allowed only on the step 8.0 path
  the user consented to. A non-fast-forward rejection on the normal path means "defer".
- **`gh` is required.** Never fall back to a browser URL.

## Differences from `/cr-loop` and `/cr-loop-merge`

1. **The default base is `origin/<default branch>`,** the same as `/cr-loop`.
2. **After convergence, this command pushes and opens or updates a PR** instead of stopping
   (`/cr-loop`) or merging locally (`/cr-loop-merge`).
3. **Before the push, it auto-rebases onto the latest PR base** (default on), followed by one
   whole-diff confirmation round.

Everything else is identical across the three commands: the review protocol, the modes, the
ledger, the round cap with step-back, codify-at-source, the interaction guard, head-drift
detection, and the handoff format.

| When to use | Command |
|---|---|
| Reviewed commits should land on local `main` so you can push manually later | `/cr-loop-merge` |
| Reviewed commits should land on `origin/<branch>` with a PR for human review | `/cr-loop-pr` |
| Codex should gate the work while integration stays manual | `/cr-loop` |
