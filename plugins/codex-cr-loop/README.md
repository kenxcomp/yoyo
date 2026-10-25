# codex-cr-loop

codex-cr-loop adds three slash commands that run Codex code review as a **convergence loop**.
Each round reviews the branch, fixes every bug **class** the review reports, commits, and
reviews again. The loop stops when **two consecutive rounds are clean on the same HEAD**,
with the second round covering the whole diff.

v1.7.0 replaces the review mechanics with a protocol designed to converge. Earlier versions
often ran for 9–16 rounds. The full protocol is in
[`references/review-protocol.md`](./references/review-protocol.md).

1. **The round cap is 3.** After 3 dirty rounds, the loop runs a mandatory **step-back**
   round. The reviewer and the author reconsider the approach instead of continuing
   line-by-line fixes. They make one structural change per recurring bug class and add
   prevention.
2. **Findings name a class of bug, not a single line.** The reviewer reports
   `Pattern / Instances / Fix / Prevent` for each class: the root pattern, **every** instance
   in scope, the systematic fix, and how to prevent it. The author fixes all instances in one
   pass.
3. **Re-reviews cover only the new diff, and findings are never repeated.**
   - After round 1, a round reviews only `git diff <last-reviewed>..HEAD`.
   - A per-branch **ledger** of every class reported so far is passed to every round. Each
     class has a stable id (`C1`, `C2`, …).
   - A class already in the ledger is never reported again. The one exception is an
     incomplete or regressed fix, which the reviewer reports as `[Cn]`, citing the original
     id.
4. **Recurring classes are codified at the source.** A class that recurs gets a lint rule, a
   source-guard or regression test, or a `REVIEW.md` entry in the same fix commit, instead of
   being patched again PR by PR. Reviewers read `REVIEW.md`, `AGENTS.md`, and `CLAUDE.md`
   every round.

The three commands share that protocol and the reviewer script
[`scripts/cr-review.sh`](./scripts/cr-review.sh). They differ only in what happens *after*
convergence:

| Command | After convergence |
|---|---|
| `/cr-loop` | **Stops.** No push, no PR, no merge. |
| `/cr-loop-pr` | **Auto-rebases** onto the latest `${CR_PR_REMOTE:-origin}/${CR_PR_BASE}` (on by default), then runs one confirmation round over the whole diff. After that it **pushes** the branch and **opens a PR**, or updates the existing one. Requires an authenticated `gh`. |
| `/cr-loop-merge` | **Merges** into the local `${CR_MERGE_TARGET}`. No push. Handles a target branch that is checked out in another worktree. |

## Requirements

- The **`codex` CLI** on `PATH`, logged in. Install it with `npm i -g @openai/codex` or
  `brew install codex`, then run `codex login`. `/codex:setup` from the `openai-codex`
  plugin can check this, but that plugin is no longer required (see
  [Breaking changes](#breaking-changes-in-v170)).
- `git`, and a clean working tree. Untracked `.cr-loop-handoff-round-*.md` files from an
  earlier stop are ignored.
- A feature branch built on top of its base. Otherwise the preflight gate asks you to rebase
  first; see [Base-currency gate](#base-currency-gate-v150).
- For `/cr-loop-pr`: `gh`, installed and authenticated (`gh auth status`).

## Usage

```
/cr-loop                  # base origin/<default branch>; converge and stop
/cr-loop-merge            # base local <default branch>; converge and merge
/cr-loop-pr               # base origin/<default branch>; converge, push, open PR
/cr-loop release/2026.05  # explicit base ref
```

The default branch (`main`, `master`, or whatever the repo uses) is detected from local refs
with `git symbolic-ref refs/remotes/origin/HEAD`, falling back to `main` and then `master`.
Detection doesn't use the network.

## How a loop runs

```text
round 1  full         whole branch diff vs base            → dirty: fix all classes, commit
round 2  incremental  git diff <round-1 head>..HEAD only   → dirty: fix, commit
round 3  incremental  only the round-2 fixes               → dirty: fix, commit   (cap 3 reached)
round 4  step-back    whole diff + full ledger: recurring classes, why the approach invites
                      them, approach change per class      → structural change + prevention, commit
round 5  incremental  only the step-back commit            → clean   (CLEAN_STREAK 1/2)
round 6  full         confirmation: whole diff + ledger, same HEAD → clean (2/2) → converged
```

**Convergence rule.** The loop converges after two consecutive clean rounds on the same
HEAD, where the second is a `full` (whole-diff) round.
- After any clean round, the next round is automatically a `full` confirmation on the same
  HEAD. That round catches problems the fixes caused in combination, and because it reads
  the ledger it repeats nothing.
- With `CR_LOOP_SKIP_P3=1`, a round with only P3 findings counts as clean. Those P3s are
  recorded in the ledger and are not reported again.

**Round cap and step-back.** The cap counts dirty rounds; every dirty round except a
step-back increments `dirty_since_step_back`.
- When that count reaches `CR_LOOP_ROUND_CAP` (default 3), the next round must be a
  step-back.
- In the step-back, the author writes an assessment for each recurring class: root pattern,
  why the approach invites it, the structural change, and the prevention artifact. The
  author then makes one structural change per class, adds the prevention, commits, and
  resumes with incremental rounds.
- If a structural change would go beyond the branch's scope, the loop asks the user first.
  The interaction guard still applies.
- If the cap is reached again after `CR_LOOP_MAX_STEP_BACKS` (default 1) step-backs, the
  loop writes a handoff and **asks the user**. The options are another step-back, splitting
  the work, a manual redesign, or stopping.
- Clean rounds and confirmation rounds never count toward the cap.

**Ledger.**
- **Location:** `$(git rev-parse --git-common-dir)/cr-loop/<branch>/ledger.md`. That is
  outside the working tree, and every worktree of the repo shares it.
- **Contents:** an append-only log of each round with its class ids, the step-back
  assessments, and author notes marking classes as fixed, deferred, accepted, wontfix, or
  codified.
- **Persistence:** the ledger and the round-cap counters persist across invocations on the
  same branch, so re-invoking doesn't reset the cap. Convergence resets the counters.
- **Fresh start:** run `bash <plugin>/scripts/cr-review.sh reset`. It archives the ledger.
- **External findings:** register findings from PR bots or human reviewers with
  `cr-review.sh add P2 "<class> — <file>:<line>"` so later rounds won't repeat them.

**Codify at the source.** A class is recurring if it appears in the ledger in at least 2
rounds, if a step-back names it, or if it violates an existing `REVIEW.md` class. Its fix
commit must add at least one prevention artifact, in this order of preference:
1. a lint rule;
2. a source-guard or invariant test;
3. an entry in the nearest code-owner `REVIEW.md`, or in a repo-root `REVIEW.md` created
   the first time one is needed. Each entry has one section per class: **Pattern**, **Why
   it's wrong**, **How to check**, **How to fix**.

The commit body carries a `Prevention:` trailer. The commands **never edit user-global
files**: `~/.claude`, `~/.codex`, global `CLAUDE.md`/`AGENTS.md`, and agent memory are off
limits.

## The reviewer runner

`scripts/cr-review.sh` replaces the v1.6 `codex-companion.mjs review --wait` call. That call
couldn't take a custom prompt, so it couldn't do diff-only rounds, the ledger, or
class-format findings. It also failed with `spawnSync ENOBUFS` on diffs larger than 1 MiB.
The runner launches:

```text
codex exec --sandbox read-only -C <repo> -c model_reasoning_effort=high \
           --output-last-message <round>/last.md "<class-format prompt>" < /dev/null
```

- **stdin is `/dev/null`.** With a piped stdin, `codex exec` waits for a `<stdin>` block and
  can hang forever.
- **The reviewer runs detached.** It starts with `nohup … & disown` in a new session. macOS
  has no `setsid(1)`, so the runner calls perl's `POSIX::setsid` instead. As a result, a
  caller's 10-minute tool timeout can't kill the reviewer.
- **The reviewer computes the diff itself,** so diff size doesn't matter.
- **Rounds are tracked by PID file, never by `pgrep -f`.** `cancel` stops only that round's
  process group.

| Subcommand | Purpose |
|---|---|
| `init` | Create or load the per-branch state. Prints the resolved knobs, counters, ledger path, and deprecation warnings. |
| `next --clean-streak N` | Print the mode the next round must use: `full`, `incremental` (with `SINCE=`), `step-back`, or `stop`. |
| `start --mode M --base REF [--since SHA]` | Launch one detached round. Prints `ROUND_DIR`, `PID`, and `REVIEWED_HEAD`. |
| `status` / `wait [--timeout 540]` | Report whether a round is running or done, with elapsed time, log size, and log age. |
| `finish` | Check for head drift (exit 3) and for errors or bad output format (exit 5). Then classify the round as `clean`, `p3-only`, or `dirty`, assign class ids, append to the ledger, and update the counters. |
| `note TEXT` / `add Pn TITLE [DETAIL]` | Append an author note, or register an external finding (prints a new class id). |
| `tree-clean` | The one clean-tree check, shared by the preflight and the completion step. It ignores only untracked repo-root `.cr-loop-handoff-round-<N>.md` files. |
| `mark-converged` / `cancel` / `reset` / `paths` | Housekeeping. |

`scripts/test-cr-review.sh` is a self-contained regression test for the runner. It uses a fake `codex` in a temporary repo and covers verdict classification, malformed output, state paths from subdirectories and linked worktrees, `tree-clean`, the round-cap and step-back state machine, and `cancel`. Run it with `bash plugins/codex-cr-loop/scripts/test-cr-review.sh` after changing the script.

Your permission settings may prompt on every script call. To stop that, add an allow rule
that wildcards the version segment of the install path, for example
`Bash(bash */codex-cr-loop/*/scripts/cr-review.sh *)`.

## Tunable knobs

| Knob | Default | Applies to | Meaning |
|---|---|---|---|
| `CR_LOOP_ROUND_CAP` | `3` | all | Dirty rounds before a mandatory step-back. `0` disables the trigger (not recommended). |
| `CR_LOOP_MAX_STEP_BACKS` | `1` | all | Step-backs allowed before the next cap hit asks the user. |
| `CR_LOOP_SKIP_P3` | `1` | all | A round with only P3 findings counts as clean. Set `0` for strict mode. |
| `CR_LOOP_REQUIRE_REBASED` | `1` | all | Preflight base-currency gate. Set `0` to skip it. |
| `CR_LOOP_REVIEW_EFFORT` | `high` | all | `model_reasoning_effort` for review rounds. |
| `CR_LOOP_REVIEW_MODEL` | (Codex default) | all | `-m` value passed to `codex exec`. |
| `CR_MERGE_TARGET` | auto-detected | `/cr-loop-merge` | Local branch to merge into. |
| `CR_MERGE_FF` | `auto` | `/cr-loop-merge` | `auto`, `ff-only`, or `no-ff`. |
| `CR_PR_BASE` | auto-detected | `/cr-loop-pr` | PR target branch. |
| `CR_PR_REMOTE` | `origin` | `/cr-loop-pr` | Remote to push to and open the PR on. |
| `CR_PR_DRAFT` | `0` | `/cr-loop-pr` | Set `1` to open the PR as a draft. |
| `CR_PR_TITLE` | (from commits) | `/cr-loop-pr` | PR title, truncated to 70 characters. |
| `CR_PR_AUTO_REBASE` | `1` | `/cr-loop-pr` | Step 8.0 auto-rebase and confirmation round. Set `0` to defer instead. |

## Breaking changes in v1.7.0

- **The reviewer is now `codex exec`, run through `scripts/cr-review.sh`.** It replaces
  `codex-companion.mjs review --wait`. The `codex` CLI is required; the `openai-codex`
  plugin is optional. Use `cr-review.sh cancel` where you used `/codex:cancel`.
- **`CR_LOOP_ROUND_CAP` has a new meaning.** In v1.6 it was an opt-in hard stop on the total
  number of rounds, unset by default. It now defaults to `3` and counts **dirty rounds before
  a mandatory step-back**.
- **The widening guard and the auto-widening sweep are removed.** The 3-round step-back
  replaces them, so there are no longer two overlapping escalation systems.
  - `CR_LOOP_WIDEN_AFTER` is ignored, with a warning.
  - `CR_LOOP_AUTO_WIDEN=0` maps to `CR_LOOP_MAX_STEP_BACKS=0`.
  - `CR_LOOP_MAX_WIDENING_SWEEPS=N` maps to `CR_LOOP_MAX_STEP_BACKS=N`.
  - In both mappings, an explicit `CR_LOOP_MAX_STEP_BACKS` takes precedence.
  - The repo-local `.claude/rules/cr-loop-widening-sweep.md` is no longer read.
- **Stop reasons changed.** `widening-hint`, `widening-sweeps-exhausted`,
  `widening-hint-no-clear-root-cause`, and `round-cap-reached` are replaced by
  `step-back-exhausted`, `step-back-scope-declined`, and `reviewer-error`.
- **The review output format is class-based** (`Pattern / Instances / Fix / Prevent`).
  Findings are still detected from `- [P0]` to `- [P3]` bullets at column 0. Output that
  can't be parsed is an `error`, never a clean round.
- **`/cr-loop-pr` fixes:**
  - The PR body is written to a file and passed with `--body-file`.
  - The body's test plan is now generic instead of listing hard-coded project commands, and
    the body includes a `## 业务影响` section.
  - `CR_PR_DRAFT=0` no longer opens a draft. The `${CR_PR_DRAFT:+--draft}` idiom used to fire
    on `0`.

## After the PR is open: GitHub PR review loops

The same rules apply when PR bots review the branch, for example with `@codex review`:

- **Read every comment.** Use `gh api --paginate`, and read inline comments by review id.
  Without pagination, findings are missed once a PR passes about 30 comments.
- **Group findings into classes.** Fix each class completely in one push, and register it
  with `cr-review.sh add` so local loops won't repeat it.
- **Don't re-fix repeats.** When a bot re-posts something already handled, reply with the
  ledger id and the commit that fixed it.
- **Ask for a diff-only re-review.** For example: `@codex review — only the commits since
  <sha>; earlier findings are addressed above`.
- **Step back after 3 bot rounds.** If the third bot round still finds new instances of the
  same classes, run `/cr-loop` (which enters step-back once the cap is reached) or write the
  assessment yourself. Then push one structural change per class, with prevention.
- **Codify what both reviewers caught.** If a class is flagged by both the local loop and
  the bot, add its `REVIEW.md` entry, lint rule, or guard test in the same PR.

## Why three commands instead of one with flags

Each command has an unambiguous contract:
- `/cr-loop-merge` *never* pushes.
- `/cr-loop-pr` *always* ends with a PR URL or a deferred handoff.
- `/cr-loop` *never* touches any branch except the one you started on.

The completion steps can fail in ways that compound: a deferred push, a moved PR target, a
target locked by another worktree, an unauthenticated `gh`. With one command and flags, it
would be unclear which completion step is actually in charge.

## Base-currency gate (v1.5.0)

Before the first round, each command checks `git merge-base --is-ancestor "$BASE" HEAD`. If
the branch is **stale** relative to its base, the loop **does not start**. It asks you to
choose:
- **(A) rebase first.** The loop prints `git rebase "$BASE"` but never rebases for you.
- **(B) abort.**

The question appears as a [`form-base`](../form-base/) radio button, or as inline A/B when
`form-base` isn't available. There is no "review anyway" option, and "no response" is never
treated as consent.

| Command | Base checked | Remote touched |
|---|---|---|
| `/cr-loop` | `origin/<default>` (freshly fetched) | fetch only |
| `/cr-loop-pr` | `${CR_PR_REMOTE:-origin}/$CR_PR_BASE` (freshly fetched) | fetch only |
| `/cr-loop-merge` | local `$CR_MERGE_TARGET` | **none** |

`CR_LOOP_REQUIRE_REBASED=0` skips the gate.

## Auto-rebase before PR (v1.6.0)

This applies to `/cr-loop-pr` only. After convergence and **before the push** (step 8.0),
`/cr-loop-pr` re-fetches the PR base. If the base advanced, it rebases onto it and runs
**one whole-diff confirmation round**. That round is a `full` round, because after the
rebase the old reviewed head is no longer an ancestor. The ledger carries over, so the
round repeats nothing.
- If that round is clean, the loop pushes and opens the PR.
- If it is dirty, the loop fixes the findings and re-converges.
- Conflicts are never auto-resolved. The loop runs `git rebase --abort` and defers.
- If a PR already exists, updating it after a rebase needs a **user-confirmed**
  `--force-with-lease`, never a bare `--force`.

`CR_PR_AUTO_REBASE=0` defers instead whenever the base has moved.

## Interaction-logic guard (v1.3.0+)

User-visible interaction contracts are off limits to automatic fixes. These include:
- which gesture triggers which response;
- the hit target;
- whether something is a dialog, dropdown, inline editor, or sheet;
- keyboard shortcuts and accessibility actions;
- navigation flow and default actions.

When a fix would shift such a contract, the loop **stops before the commit**. This applies
whether the fix comes from a Codex finding, from the agent's own analysis, or from a
step-back structural change.
- The loop shows the current behavior, Codex's proposal, 2–3 alternatives that preserve the
  UX, and a "skip" option. It asks through a [`form-base`](../form-base/) radio button or
  inline.
- It **blocks on your reply**, applies only the variant you chose, and records it in commit
  trailers.
- A "skip" is recorded in the ledger, so the reviewer never re-raises that finding.
- The guard is always on, with no env override. Pure correctness fixes inside an event
  handler proceed as normal.

## Business-impact summary (v1.4.0+)

Each command's final report **always** ends with a Chinese **business-impact summary**:

- **有业务可观测改动**: 3–8 行中文,首行总览,后续按 commit 列"旧行为 → 新行为"。
- **全部为代码层重构**: 仅一行固定字面值 `无业务逻辑影响`(下游工具据此识别"无需回归")。
- **判断模糊时按"有业务改动"处理**。

`/cr-loop-pr` also embeds the summary in the PR body under `## 业务影响`.

## Safety guarantees

- **No `--no-verify`, no bare `--force`.** The only history-rewriting push is
  `/cr-loop-pr`'s user-confirmed `--force-with-lease`, used in step 8.0 to update an existing
  PR after an auto-rebase.
- **Hooks are never bypassed.** When a hook fails, the loop defers and shows the output.
- **Head drift is caught.** `cr-review.sh finish` refuses to classify a round if HEAD moved
  while the reviewer was running (exit 3, `head-drift-during-review`).
- **Bad reviews are never treated as clean.** An empty, failed, or badly formatted review is
  an `error`.
- **Interaction contracts don't change without your consent** (interaction-logic guard).
- **User-global files are never edited.** State and the ledger live under `.git/`, not in
  the working tree.
- **Every stop without convergence writes a handoff** to `.cr-loop-handoff-round-<N>.md`,
  including a ledger summary and resume instructions. Handoffs are cleaned up automatically
  on the next successful completion.
