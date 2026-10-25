# codex-cr-loop review protocol (v1.7.0)

This document is the **authoritative review-loop body** shared by `/cr-loop`, `/cr-loop-merge`
and `/cr-loop-pr`. Each command owns only its preflight (step 1) and its completion step
(step 8), plus a few command-specific stop reasons and report lines. Steps 2–7 and the
common parts of step 9 are defined here, and every command must follow them as written.

The protocol rests on four rules:

1. **Round cap = 3.** After `CR_LOOP_ROUND_CAP` (default 3) dirty rounds, the loop stops
   making line-by-line fixes and runs a mandatory **step-back** round. In that round the
   approach is reconsidered, one structural change is made per recurring class, and
   prevention is added.
2. **Flag the class of bug, not single lines.** The reviewer reports each bug *class* with
   its root pattern, **every** instance in scope, the systematic fix and how to prevent it.
   The author fixes all instances in one pass.
3. **Diff-only re-review, no repeats.** After round 1, a round reviews only the changes since
   the last reviewed head. A per-branch **ledger** of every reported class is passed to every
   round. A class already reported is never reported again, unless its fix is incomplete or
   has regressed. In that case the reviewer cites the original id.
4. **Codify at the source.** When a class recurs, its fix commit must add a prevention
   artifact: a lint rule, a source-guard or regression test, or a `REVIEW.md` entry. The
   class is not patched again PR by PR.

These rules came from real runs. Loops that ran for 9–16 rounds kept finding new edge
instances of the same few classes:

- per-keystroke full scans
- the display predicate and the action predicate drifting apart
- async work with no owned lifetime or cancellation
- imprecise text equality

Point fixes never converged on those.

---

## Step 2 — Reviewer setup

```bash
CR_REVIEW="${CLAUDE_PLUGIN_ROOT}/scripts/cr-review.sh"
bash "$CR_REVIEW" init
```

Claude Code expands `${CLAUDE_PLUGIN_ROOT}` before you see this text. If it shows up
literally, locate the script with
`ls -td "$HOME"/.claude/plugins/cache/*/codex-cr-loop/*/scripts/cr-review.sh | head -1`.

`init` creates or loads the per-branch state, then prints the resolved knobs, the persisted
counters, the ledger path, any deprecation `WARNINGS=`, and `CODEX=`.

- `CODEX=missing` means the `codex` CLI is not on `PATH`. Abort and tell the user to install
  and log in to it (`npm i -g @openai/codex` or `brew install codex`, then `codex login`;
  `/codex:setup` from the `openai-codex` plugin checks readiness).
- If `WARNINGS=` is present, include it verbatim in the first status line. It reports
  removed v1.6 knobs (see the knob table).
- If `CURRENT_ROUND=… (running)` is present, a round from an earlier session is still
  running. Wait for it (step 3c) or `cancel` it; never start a second round over it.

### Shared knobs (env overrides; read once at preflight)

| Knob | Default | Meaning |
|---|---|---|
| `CR_LOOP_ROUND_CAP` | `3` | Dirty rounds (not counting step-backs) before a mandatory **step-back** round. `0` disables the step-back trigger (not recommended). **v1.7.0 semantics change:** v1.6 used this name for an opt-in hard stop on total rounds, unset by default. |
| `CR_LOOP_MAX_STEP_BACKS` | `1` | Step-backs allowed before the next cap hit stops the loop with `step-back-exhausted` and asks the user. `0` means the first cap hit asks the user without a step-back. |
| `CR_LOOP_SKIP_P3` | `1` | A P3-only round counts as clean. `0` is strict mode: P3s block convergence and must be fixed. |
| `CR_LOOP_REQUIRE_REBASED` | `1` | The preflight base-currency gate (see each command's step 1). `0` skips it. |
| `CR_LOOP_REVIEW_EFFORT` | `high` | `model_reasoning_effort` for `codex exec`, one of `minimal`, `low`, `medium`, `high` or `xhigh`. `high` is the intended setting for review rounds; higher settings are slower without converging faster. |
| `CR_LOOP_REVIEW_MODEL` | (Codex default) | Optional `-m <model>` for `codex exec`. |

**Removed in v1.7.0.** The script reports these in `WARNINGS=`; they replaced the widening
guard and the auto-widening sweep.

| Removed knob | v1.7.0 handling |
|---|---|
| `CR_LOOP_WIDEN_AFTER` | Ignored. The trigger is now `CR_LOOP_ROUND_CAP` dirty rounds, whatever files they cite. |
| `CR_LOOP_AUTO_WIDEN=0` | Mapped to `CR_LOOP_MAX_STEP_BACKS=0` (ask instead of auto-escalating), unless `CR_LOOP_MAX_STEP_BACKS` is set. |
| `CR_LOOP_MAX_WIDENING_SWEEPS=N` | Mapped to `CR_LOOP_MAX_STEP_BACKS=N`, unless `CR_LOOP_MAX_STEP_BACKS` is set. |

The repo-local manual `.claude/rules/cr-loop-widening-sweep.md` is no longer read. Step 4s
below replaces it.

### Why `codex exec` instead of the companion `review`

Before v1.7.0 the loop drove `codex-companion.mjs review --base … --wait`. That command
cannot take a custom prompt, so it cannot do diff-only rounds, the ledger or class-format
findings. It also fails with `spawnSync ENOBUFS` on diffs larger than 1 MiB. The script runs
the reviewer as:

```text
codex exec --sandbox read-only -C <repo root> -c model_reasoning_effort=<CR_LOOP_REVIEW_EFFORT, default high>
           --output-schema references/review-output.schema.json
           --output-last-message <round>/result.json "<prompt>" < /dev/null
```

- **Structured verdict.** `--output-schema` forces the final message to be a strict JSON
  object: `verdict` (`clean` or `findings`), `findings[]` (with `severity`, `reopens`,
  `title`, `location`, `pattern`, `still_wrong`, `instances[]`, `fix` and `prevent`),
  `step_back[]` and `out_of_scope[]`. `scripts/parse-review.pl` (perl core `JSON::PP`)
  validates the object and renders the human-readable `review.md` from it. The loop
  classifies a round from these fields only and **never** parses prose. Before v1.7.0's
  step-back, every regex over markdown (headings, bold text, code spans, fences, an
  embedded "did not find…" sentence) left another way for an unfinished review to pass as
  clean.

- Stdin is always `/dev/null`. With piped stdin, `codex exec` waits for a `<stdin>` block and
  can hang forever.
- The run is detached with `nohup` plus `disown`, in a new session. macOS has no
  `setsid(1)`, so the script calls `POSIX::setsid` through perl. This means a 10-minute tool
  timeout on the caller cannot kill the reviewer.
- The reviewer computes the diff itself inside the read-only sandbox. No diff passes through
  a pipe, so there is no size limit.

### State and ledger location

Everything is stored outside the working tree, under
`$(git rev-parse --git-common-dir)/cr-loop/<branch-key>/`:

| Path | Content |
|---|---|
| `state` | Persisted counters: `rounds_total`, `dirty_since_step_back`, `step_backs_done`, `last_reviewed_head`, `next_class_id`, `current_round_dir`. |
| `ledger.md` | The append-only findings ledger (see "Ledger contract"). |
| `rounds/NNN-<mode>/` | One directory per round: `prompt.md`, `meta`, `log`, `result.json` (the raw structured result), `review.md` (rendered), `exit`, `verdict`, `ledger-fragment.md`. |
| `../<branch-key>.lock` | Branch-level **kernel advisory lock** (`flock`, taken through perl and held on fd 9). Every state transaction (`init`, `next`, `start`, `finish`, `note`, `add`, `mark-converged`, `cancel`, `reset`) runs under it, so two sessions on the same branch cannot both start a round, finish one twice, or allocate the same class id. The kernel releases the lock when the holder exits, crashes included, so there is no stale-lock state. A live holder is waited for up to 30 s. The detached reviewer is started with fd 9 closed, so it never holds the lock. |

The state is shared by every worktree of the repository. It **survives across invocations
for the same branch**. The round-cap counters persist too, so a re-invocation cannot reset
the cap; only convergence (`mark-converged`) does.

To start over, run `bash "$CR_REVIEW" reset`. It archives the directory, and only the user
should ask for this.

---

## Step 3 — Run one review round

### 3a. Choose the mode

```bash
bash "$CR_REVIEW" next --clean-streak "$CLEAN_STREAK"
```

`next` prints `MODE=` (and `SINCE=` for an incremental round). Apply these rules in order:

| Condition | `MODE` | What the reviewer sees |
|---|---|---|
| `dirty_since_step_back ≥ CR_LOOP_ROUND_CAP` and `step_backs_done < CR_LOOP_MAX_STEP_BACKS` | `step-back` | The whole branch diff plus the full ledger. The reviewer names the recurring classes, judges whether the approach structurally invites them, and proposes an approach change per class. |
| `dirty_since_step_back ≥ CR_LOOP_ROUND_CAP` and the step-back budget is spent | `stop` | Nothing. Go to step 9 with `Stop reason: step-back-exhausted` (see 4c). |
| `CLEAN_STREAK == 1` | `full` | A **confirmation round** on the same HEAD: the whole branch diff plus the ledger. |
| `last_reviewed_head` is a strict ancestor of HEAD | `incremental` | Only `git diff <last_reviewed_head>..HEAD`, which is the fixes since the last reviewed round, plus the ledger. |
| Otherwise | `full` | The whole branch diff `git diff <base>...HEAD` plus the ledger. This covers the first round of a branch, a rebased branch, and a HEAD equal to the last reviewed one. |

`CR_LOOP_ROUND_CAP=0` disables the first two rows. Never pick a mode by hand when `next`
says otherwise. The only exception is a one-off `full` after an `incremental` round that
errored twice (step 3d).

### 3b. Launch the round

Increment `ROUND_NUM` (this invocation's counter), then:

```bash
bash "$CR_REVIEW" start --mode "$MODE" --base "$BASE" ${SINCE:+--since "$SINCE"}
```

`start` returns immediately. It prints `ROUND_DIR=`, `PID=` and `REVIEWED_HEAD=`, the
snapshot of HEAD that this round reviews. In zsh, pass `--since "$SINCE"` explicitly,
because unquoted `${SINCE:+…}` does not word-split there.

The prompt that `start` writes is the class-format reviewer contract. It asks the reviewer to:

- read `REVIEW.md`, `AGENTS.md` and `CLAUDE.md` (at the repo root and next to the changed
  files) when present, and treat any violation of a codified `REVIEW.md` class as a finding
- read the ledger first and obey the no-repeat rule
- report only definite correctness, data-safety, concurrency or performance bugs introduced
  or left incomplete by the change
- give, for each **class**, the `Pattern / Instances / Fix / Prevent` fields (`pattern`,
  `instances[]`, `fix` and `prevent` in the schema)
- set `reopens` to the ledger id for an incomplete fix, and fill `still_wrong`
- put pre-existing issues in `out_of_scope`
- use `verdict: "clean"` only for a complete review with no findings

### 3c. Wait for the round to finish

There is no per-round timeout. Review time scales with the diff, and a legitimate round can
take more than 15 minutes.

- **Preferred:** use `Monitor` to block until the round's `PID` exits, for example with an
  until-loop on `kill -0 $PID`. Wait on the PID that `start` printed. Never use a
  `pgrep -f <pattern>` waiter, because the pattern matches the waiter's own command line and
  it never exits.
- **Fallback:** call `bash "$CR_REVIEW" wait --timeout 540` repeatedly. Each call blocks for
  up to 9 minutes and prints `STATE=`. Repeat while it prints `STATE=running`.
- **Do not use `ScheduleWakeup`** while a round runs. Stacked wake-ups re-enter the command
  and corrupt the loop state.
- **Long waits:** report progress at least every 30 minutes, using `bash "$CR_REVIEW" status`
  (elapsed time, log bytes, log age).
- **Hung reviewer:** if `LOG_AGE_S` is frozen for a long time and the user agrees, run
  `bash "$CR_REVIEW" cancel`. It stops only this round's own process group. Never auto-kill
  a slow review.

### 3d. Finish the round

```bash
bash "$CR_REVIEW" finish
```

`finish` prints `VERDICT=` and acts on it as follows.

| Exit | `VERDICT` | Meaning and handling |
|---|---|---|
| 3 | `head-drift` | HEAD moved while the reviewer ran (a concurrent agent, an auto-commit hook, or another shell). The round's verdict does not cover the current state. **Do not classify, do not touch `CLEAN_STREAK`, write nothing to the ledger.** Surface `git log --oneline "$REVIEWED_HEAD"..HEAD` and `git status -sb`, write a handoff with `Stop reason: head-drift-during-review`, and stop. |
| 5 | `error` | The reviewer exited non-zero or produced no result, or the result failed validation in `parse-review.pl`. Validation fails on: invalid JSON (for example a prose answer), a missing field, a `verdict` that disagrees with `findings` (`clean` with findings, or `findings` with none), a bad severity or `reopens` value, or a class with no instances. `REASON=` says which. Read `result.json` and the `LOG|` tail. Retry the round once with the same mode. A second error is a handoff with `Stop reason: reviewer-error`, quoting the reason. Never classify an unreadable review as clean. |
| 4 | `running` | The round has not finished. Go back to 3c. |
| 0 | `clean`, `p3-only` or `dirty` | Continue with step 4. `finish` has already appended the round to the ledger, assigned ids to the new classes (`NEW_CLASSES=`), listed the cited ones (`REOPENED=`), listed the classes seen in two or more rounds (`RECURRING=`), and updated the persisted counters. |

Read the review from `RESULT=`, the rendered `review.md` in the documented
`# Codex Review` / `Review comment:` layout. The raw object is at `RESULT_JSON=`.
Everything in `log` is the reviewer's command trace.

---

## Step 4 — Classify and decide

| Name | Scope | Meaning |
|---|---|---|
| `CLEAN_STREAK` | per invocation | Consecutive clean rounds |
| `LAST_CLEAN_HEAD` | per invocation | HEAD of the last clean round |
| `dirty_since_step_back` | persisted, maintained by `finish` | Dirty rounds since the last step-back |
| `step_backs_done` | persisted, maintained by `finish` | Step-backs done since the last convergence |

### 4a. Clean

`VERDICT=clean`, or `VERDICT=p3-only` when `CR_LOOP_SKIP_P3=1` (the default; the P3
classes are recorded in the ledger and are not fixed). With `CR_LOOP_SKIP_P3=0`, a P3-only
round comes back as `dirty`.

1. If `LAST_CLEAN_HEAD == REVIEWED_HEAD`, increment `CLEAN_STREAK`. Otherwise set
   `CLEAN_STREAK = 1` and `LAST_CLEAN_HEAD = REVIEWED_HEAD`.
2. **Convergence rule (exact).** The loop converges when **two consecutive rounds are clean
   on the same HEAD and the second one is a whole-diff round** (`full`).
   - Step 3a makes the round after any clean round a `full` round, so a clean `incremental`
     (or `step-back`) round is always followed by a whole-diff confirmation on the same HEAD.
   - That confirmation reads the ledger. It can catch cross-cutting problems the fixes
     introduced together without repeating any class already reported.
3. If `CLEAN_STREAK ≥ 2`:
   - Run `bash "$CR_REVIEW" mark-converged`. It records the convergence in the ledger and
     resets the round-cap counters.
   - Go to the command's **step 8** with `LAST_REVIEWED_HEAD = LAST_CLEAN_HEAD`.
4. Otherwise, go back to step 3 for the confirmation round. **Commit nothing**, so that HEAD
   stays the same.

A P3-only round makes no commit. The next round therefore reviews the same HEAD, and the
ledger stops the P3s from being reported again. Without this, the loop would rerun the same
P3-only verdict forever.

### 4b. Dirty

`VERDICT=dirty`: at least one P0–P2 finding, or any P3 with `CR_LOOP_SKIP_P3=0`.

1. Set `CLEAN_STREAK = 0` and clear `LAST_CLEAN_HEAD`. The fix commit produces a new HEAD,
   and that HEAD has to earn two clean rounds from scratch.
2. If this round's mode was `step-back`, follow the **step-back procedure (4s)** instead of
   step 5.
3. Otherwise, go to **step 5**. Fix every class in the round, including P3 classes that
   arrive alongside P0–P2 findings.

### 4c. Round cap

`finish` increments `dirty_since_step_back` on every dirty round that is not a step-back.
When it reaches `CR_LOOP_ROUND_CAP` (default **3**), `next` returns `MODE=step-back` for the
next round. This happens after the current round's fixes have been committed, so the
step-back reviews them as well.

When the counter reaches the cap again and `step_backs_done ≥ CR_LOOP_MAX_STEP_BACKS`
(default **1**), `next` returns `MODE=stop`. Then:

1. Write the handoff with `Stop reason: step-back-exhausted`. It must include the ledger
   path, every class with its round history, the step-back assessment(s), and what each
   step-back changed.
2. **Ask the user** through the step-5a surface: the `form-base` radio when that MCP is
   loaded, inline A/B/C/D otherwise. The options are:
   - **(A) Authorize one more step-back.** Continue this invocation, prefixing every later
     `cr-review.sh` call with `CR_LOOP_MAX_STEP_BACKS=<step_backs_done + 1>`.
   - **(B) Split the work.** Land what has converged and move the recurring class into a
     follow-up branch.
   - **(C) Hand off for a manual redesign.**
   - **(D) Stop.**
3. Block on the reply. "No response" is never consent.

With the defaults, the worst case is 3 dirty rounds, a step-back, then 3 more dirty rounds,
and then the user is asked. Clean and confirmation rounds do not count toward the cap.

### 4s. Step-back procedure

This replaces step 5 for one round.

**Phase 1 — Write the step-back assessment.** Read the reviewer's step-back assessment (`step_back[]`, rendered as `## Step-back assessment` in `review.md`)
and the full ledger. For each **recurring class** (any id in `RECURRING=`, any class the
step-back names, and any group of differently-titled classes that share one root pattern),
write down:

- **Root pattern:** the single mechanism behind every instance.
- **Why the approach invites it:** for example, two predicates that both decide one
  condition (display vs action), several owners of one piece of state, a full recomputation
  on every event, async work without an owned lifetime or cancellation, or an ad-hoc
  equality.
- **Structural change:** single source of truth, a clear owner, an invariant, or an API
  shape that makes the bad state impossible to express.
- **Prevention artifact:** see step 5c.

Record the assessment with `bash "$CR_REVIEW" note "step-back K: C2,C5 <class> — <structural change> — prevention: <artifact>"`
and repeat it in the step-back commit body.

**Phase 2 — Check scope and the interaction guard.**

- If a structural change needs files or modules outside the ones the branch already touches,
  or changes a public or external contract, **pause and ask the user** through the step-5a
  surface:
  - (A) Make the structural change in this branch.
  - (B) Keep complete point fixes plus prevention here, and move the structural change to a
    follow-up.
  - (C) Hand off.
- If the structural change would alter user-visible interaction behavior, run the **5a
  guard** first.
- In both cases, block on the user's reply.

**Phase 3 — Make the change.** Make one structural change per recurring class, fix every
still-present instance, and add the prevention artifact (step 5c, mandatory here).

**Phase 4 — Test.** Run the affected tests until they are green.

**Phase 5 — Commit.**

```text
refactor(<scope>): cr-loop step-back K — <approach-change headline>

Step-back assessment:
C2, C5 <class> — invited by <cause> → <structural change>
Prevention: <artifact path> (C2, C5)
Regression: <test names>
```

If the classes are independent, use one commit per class.

**Phase 6 — Resume.** `finish` already reset `dirty_since_step_back` to 0 and incremented
`step_backs_done`. Return to step 3; the next round is `incremental` over the step-back
commit.

If the step-back round came back **clean** (no recurring class, nothing still present),
treat it as a clean round under 4a.

---

## Step 5 — Fix the round's classes

Handle classes in severity order: P0, P1, P2, then P3. Each class goes through **5a**, then
**5b**, and **5c** where it applies.

### 5a. Interaction-logic guard — confirm before any user-visible change lands

This guard is **always on and has no env override.** Some findings, including high-severity
ones, involve **user-visible interaction logic**: the contract between a user action
(gesture, key, click, focus) and the system's visible response (which dialog, menu or sheet
opens, which navigation happens, which UI element is the hit target, what the default action
is). Changing that contract retrains the user. It must be a deliberate user decision, never a
side effect of the agent applying the "natural" fix.

These changes trip the guard:

- **Gesture or event-handler changes:** which gesture (tap, long-press, double-tap, swipe,
  right-click, drag, hover) triggers which response, or *which UI element* receives it. For
  example, "long-press the whole row → edit dialog" becoming "long-press only the title text
  → dropdown menu".
- **Modal, dialog or menu type changes:** an edit dialog becoming a dropdown, context menu,
  inline editor or navigation push; adding or removing a confirmation step; replacing an
  alert with a banner.
- **Keyboard shortcut or accessibility changes:** rebinding, removing or repurposing a
  shortcut; changing VoiceOver or accessibility actions or the focus order.
- **Navigation or flow changes:** a push becoming a sheet, a sheet becoming a full-screen
  cover, a step inserted into or removed from a multi-step flow.
- **Default-action changes:** what happens on Return, on the primary button, on an outside
  tap, or on cancel.

Classify every class (and every structural change from step 4s) first:

- **Pure correctness inside an event handler.** For example, the long-press still opens the
  edit dialog, but a stale-state bug *inside* the handler is fixed. This is **not** an
  interaction change; go to 5b.
- **The visible contract would shift** (any item in the list above). The guard fires: do not
  apply the change, and keep it out of the step 6 commit. Hand control to the user:
  1. **Compose a prompt** with:
     - **Current behavior:** one sentence on what the user does today.
     - **Codex's proposed change:** quoted or paraphrased in one sentence.
     - **2–3 alternatives** that address the underlying finding while keeping the current UX
       or changing it as little as possible, each labeled with its trade-off.
     - An explicit **"skip / leave as-is"** option.
  2. **Ask through form-base when you can.** When the `form-base` MCP is available
     (`mcp__plugin_form-base_form-base__create_form` / `read_answers`), ask one radio
     question with `create_form`. Otherwise ask inline with the same A/B/C/skip labels.
  3. **Block on the reply.** That means no other fixes, no commit, no next round, no
     step-back, and no completion step (merge, push or PR). "No response" is never consent.
     Poll `read_answers` on the form-base path; otherwise wait for the user's next message.
  4. **Apply only the chosen option.** Free text in the "Other" slot is the canonical fix.
     Add these trailers to the step 6 commit:
     ```text
     Interaction decision: <one-line summary of user's choice>
     Original Codex finding: <Cn> [Pn] <title> — <file>:<line>
     ```
  5. **On "skip":**
     - Leave the class out of the commit and add `User-deferred interaction finding: <Cn> [Pn] <title> — <file>:<line>`
       to the commit body.
     - Run `bash "$CR_REVIEW" note "<Cn> deferred by user (interaction guard): <summary>"`.
       The reviewer then never reports it again, so the user is not asked again in this or
       any later invocation.

The guard applies regardless of the finding's severity, of who proposed the change (Codex,
your own analysis, or a step-back), and of how obvious the change looks.

### 5b. Fix the whole class in one pass

1. **Read the code.** Read every listed instance and its surrounding code; never act on the
   headline alone.
2. **Sweep for unlisted instances.** Search the in-scope code (the files the branch changes
   and the code they rely on) for the class's pattern, using grep, an LSP or the type
   checker. The reviewer's instance list is a floor, not a ceiling. Fix every instance in
   the same commit and name the extra ones in the commit body.
3. **Fix the root pattern,** for example a shared predicate, one owner, or a single helper.
   Do not add one guard per call site.
4. **For a reopened class `[Cn]`,** read the ledger's original entry and cover what the
   previous fix missed.
5. **Add a regression test** that fails on the class, preferably parameterized or
   invariant-style so it covers every instance. Skip this only for documentation-only or
   purely cosmetic fixes.
6. **Update `CLAUDE.md`, `AGENTS.md` or other project docs** if the fix changes an invariant
   they describe.
7. **Run the affected tests** with the project's documented command until they are green.
8. **Record the outcome.** After committing (step 6), run
   `bash "$CR_REVIEW" note "<Cn> fixed in <short-sha> (<k> instances)"`.

**Out-of-scope** items (pre-existing issues outside the branch's diff) are not fixed by
default. Acknowledge them in the report, and ask before expanding scope.

### 5c. Codify at the source

This step is **mandatory for recurring classes.** A class counts as recurring when:

- `finish` lists it in `RECURRING=` (it appears in two or more rounds), or
- a step-back names it, or
- it matches a class already codified in `REVIEW.md` that this branch violated again.

Its fix commit must add at least one **prevention artifact** to the repository. In order of
preference:

1. **A lint rule** in the repository's existing linter config (for example a SwiftLint custom
   rule or an ESLint rule) that flags the pattern.
2. **A source-guard or invariant test** that fails on any new instance. Examples: a test that
   scans sources for the forbidden call shape, or a property test over every call site.
3. **A `REVIEW.md` entry,** when no executable check is practical. Add it to the nearest
   existing `REVIEW.md` that owns the files (a code-owner `REVIEW.md`); otherwise create
   `REVIEW.md` at the repository root (lazily, the first time it's needed). Use one section
   per class:

   ```markdown
   ## <Class title>
   <!-- cr-loop: <branch> C<n>, added <date> -->
   - **Pattern:** <the root pattern, recognizable in a diff>
   - **Why it's wrong:** <the failure it causes>
   - **How to check:** <grep / lint / test command, or the reviewer question to ask>
   - **How to fix:** <the systematic fix — owner, single source, invariant>
   ```

An executable artifact (1 or 2) may also get a short `REVIEW.md` pointer, so that reviewers
know the class exists.

Then:

- Add `Prevention: <artifact path or REVIEW.md#anchor> (<Cn>)` to the commit body.
- Run `bash "$CR_REVIEW" note "<Cn> codified: <artifact>"`.
- Reviewers read `REVIEW.md` every round. From then on the class is checked at the source,
  not rediscovered.

**Never edit user-global files.** `~/.claude/**`, `~/.codex/**`, global `CLAUDE.md` or
`AGENTS.md` files and agent memory belong to the user. Prevention artifacts live in the
repository. If a lesson belongs in a global file, suggest it in the report instead.

---

## Step 6 — Commit the round

Make one commit per round. Never use `--no-verify`. If a hook fails, fix the cause.

```text
fix(<scope>): Codex round N (<mode>) — <short summary>

C4 [P1] <class title> — fixed <k> instances (<files>)
C2 [P2] (reopened) <class title> — completed the remaining instances
Prevention: <artifact> (C2)            ← required for recurring classes (5c)
Regression: <test name(s)>
```

Then record the outcome of each class with `note` (5b step 8).

## Step 7 — Loop

Go back to step 3. `next` picks the mode:

- After a dirty round's commit, it picks `incremental`, over just that commit.
- After a clean round, it picks `full`, the confirmation round on the same HEAD.
- When the round cap is reached, it picks `step-back`.

---

## Ledger contract (no repeats)

- **One ledger per branch.** It is append-only and lives in
  `<git-common-dir>/cr-loop/<branch-key>/ledger.md`. It is shared by every worktree of the
  repository and survives across invocations.
- **Stable class ids.** `finish` assigns each new class id `C1`, `C2`, … in report order. A
  finding whose `reopens` field names a known ledger id is recorded as **reopened** under
  that id. An unknown id gets a new id, with a note.
- **Every round reads it.** The prompt points the reviewer at the ledger and forbids
  re-reporting any class in it. The only exception is a class whose fix is incomplete or
  regressed in the reviewed code; the reviewer reports that one with `reopens: "Cn"`
  and `still_wrong`. Classes noted as deferred, accepted or wontfix are never reported,
  not even as reopened.
- **The author annotates with `note`:** fixed, deferred, accepted, wontfix, codified, and
  step-back assessments.
- **External findings** from PR bots or human reviewers are registered with
  `bash "$CR_REVIEW" add P2 "<class title> — <file>:<line>" "<detail>"`, which prints an
  `ID=` for the class. Later local rounds will not repeat them, and PR replies can cite the
  id.
- **The ledger is diagnostic, not a gate.** The handoff and the report cite it. Never paste
  user content or secrets into it.

## Status line between rounds

Print one line per round, for example:

```text
Round N (incremental since <short-sha>): dirty — P1×1 P2×2, classes new C7 / reopened C2, recurring C2; dirty-since-step-back 2/3, step-backs 0/1, CLEAN_STREAK 0/2 — fixing.
Round N (full, confirmation): clean — CLEAN_STREAK 2/2 — converged.
```

## Step 9 (shared parts) — Handoff and report

### 9a. Handoff file

Write a handoff whenever the loop stops without completing. Never stop silently on a
non-converged path.

**File:** `.cr-loop-handoff-round-<N>.md` at the repository root. Both clean-tree checks,
the step 1 preflight and step 8(a), use the same predicate, `cr-review.sh tree-clean`. It
ignores only untracked repo-root handoff files, so neither the resumed loop nor its
completion is blocked by the loop's own handoff. Any other change still blocks both.
Handoffs are deleted only by a successful completion in step 8. Never re-implement the
clean-tree check inline with `git status --short`.

**Shared stop reasons:**

- `head-drift-during-review`
- `reviewer-error`
- `step-back-exhausted`
- `step-back-scope-declined`: the user chose a hand-off in 4s phase 2.
- `user-stopped`

Each command adds its own completion-step reasons.

The handoff always contains:

- **Position and counters:**
  - the stop reason
  - the current `HEAD` and the number of commits ahead of `BASE`
  - `START`
  - the round count for this invocation and in total (`rounds_total`)
  - `dirty_since_step_back`, `step_backs_done`, and the knobs in effect
- **The ledger:** its path and a summary table of every class: id, severity, title, the
  rounds where it appeared, and its status (open, fixed, deferred, codified).
- **Step-back history:** every step-back's assessment and commit SHA.
- **Reason-specific detail:**
  - `head-drift-during-review`: `git log --oneline "$REVIEWED_HEAD"..HEAD` and
    `git status -sb`
  - `reviewer-error`: the log tail and the round dir
  - `step-back-exhausted`: the user's answer to the 4c question, if any
- **Resume instructions:** the exact re-invocation and any one-shot preparation, such as
  `CR_LOOP_MAX_STEP_BACKS=<n+1>` to authorize another step-back, a rebase, or investigating
  a concurrent writer.

### 9b. Report (always)

Every command's final report includes these shared lines:

- **Rounds:** _N_ this invocation (by mode: full×a, incremental×b, step-back×c) and the
  branch total.
- **Classes:** new, reopened and recurring ids. Mark the codified ones with their prevention
  artifact, and list the out-of-scope items acknowledged.
- **Per-round histogram:** one line per round, for example `R2 incremental: P1×1 P2×2`.
- **Tests:** the final test status, which must be green, and the commands that were run.
- **Commits:** the commit range added by the loop, `git log --oneline $START..HEAD`.
- **Stop reason and handoff:** the stop reason (`converged` or a bail reason), and the
  handoff path when one was written.
- **Confirmation:** the last two rounds were clean on `<sha>` and the second was a
  whole-diff round. This line appears only when converged.
- **Business-impact summary** (in Chinese; **always present, never omitted**):
  - **判定**:扫描 `$START..HEAD` 全部 commit,看是否引入了用户或下游消费者**可观测的行为变化** —— 新增/调整功能、修复用户能察觉的 bug、调整默认值或配置语义、UI 交互变化(已被 5a 拦截并由用户确认)、对外 API/事件契约、文案/状态机/异常返回。
  - **有业务可观测改动 → 输出 3–8 行中文**。首行总览("本轮共改动 X 项业务能力");后续按 commit 顺序逐条列出可观测差异(用户动作 / 入口 + 旧行为 → 新行为 + 用户能直接感知到什么)。Codex 找到的 bug 修复要按"用户旧体验 → 新体验"的视角描述,不要只复述代码层的 finding 文本。**不要把代码层重构混入这一节**。
  - **全部为代码层重构 → 仅输出一行** `无业务逻辑影响`(rename、抽函数、注释、补测试、内部解耦、行为等价的性能优化、实现替换但接口语义不变)。这一行是固定字面值,不要替换成"无改动"/"none"/英文等其他写法 —— 用户和下游工具据此字符串识别"本轮无需回归"。
  - **判断模糊时按"有业务改动"处理**(漏报对产品/业务方的代价高于多写几行)。

---

## Shared guardrails

- **The interaction-logic guard (5a) comes first and cannot be silenced.**
- **Never skip hooks** (`--no-verify`).
- **Scope commits to the classes they resolve.** Do not reformat unflagged files, and do not
  fix out-of-scope pre-existing issues without asking.
- **Do not patch a recurring class point by point.** If a class shows up in `RECURRING=`,
  its fix must be systematic and codified (5c). The round cap forces a step-back before point
  fixes can pile up.
- **Never re-post or re-fix a ledger class** unless the reviewer reopened it with `[Cn]`.
- **Never edit user-global files** (5c).
- **Never fabricate a verdict.** An unreadable or empty review is an `error` (3d), never
  `clean`.

---

## After the PR is open — GitHub PR review loops

The same rules apply when PR bots review the branch, for example `@codex review` or other
review apps, and when you iterate on their comments.

1. **Fetch every comment.** Use `gh api --paginate` and read inline review comments by
   review id. Unpaginated reads silently miss findings once a PR passes about 30 comments.
2. **Group the findings into classes** before fixing anything. Fix each class completely,
   with the 5b sweep, in one push. Register each class with `bash "$CR_REVIEW" add …`, so
   that local loops do not report it again.
3. **No repeats.** If a bot re-posts something already handled, reply in the thread with the
   ledger id and the commit that fixed it, or with the user's deferral, instead of changing
   the code again. Real follow-ups get a reply that cites the original thread.
4. **Ask for diff-only re-review.** When re-requesting review, name the head the bot last
   reviewed and ask it to look only at the new commits, for example
   `@codex review — only the commits since <sha>; findings already addressed are in the
   threads above`.
5. **Three bot rounds, then step back.** If a third round of bot comments still brings new
   instances of the same classes, stop replying line by line. Run the step-back procedure
   (4s) locally: run `/cr-loop`, which enters step-back once the cap is reached, or write the
   assessment by hand. Push one structural change per class plus its prevention artifact,
   and summarize the approach change in a PR comment.
6. **Codify at the source.** A class that both the local loop and the PR bot have flagged
   gets its `REVIEW.md` entry, lint rule or guard test in the same PR (5c).
