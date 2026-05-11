# codex-cr-loop

Three slash commands that wrap `/codex:review` (from the `openai-codex` plugin) into a **convergence loop**: iterate `/codex:review --wait`, fix every P0/P1/P2/P3 finding it returns, commit, re-run, and stop only when **two consecutive rounds** return no actionable findings.

The three commands share the entire review-loop body — P3 skip filter, file-family widening guard, optional opt-in round cap, head-drift detection, handoff file format — and differ only in what they do *after* convergence:

| Command | After convergence |
|---|---|
| `/cr-loop` | **Stops.** No push, no PR, no merge. The user takes whatever next action they want. |
| `/cr-loop-pr` | **Pushes** the feature branch to `${CR_PR_REMOTE:-origin}` and **opens a PR** against `${CR_PR_BASE:-main}` (or appends commits to an existing PR). Requires `gh` CLI authenticated. |
| `/cr-loop-merge` | **Merges** the feature branch into the local `${CR_MERGE_TARGET:-main}`. No push. Worktree-aware (handles target locked in another worktree by fast-forwarding via local refspec push when possible). |

## Requirements

- The [`openai-codex`](https://claude.com/claude-code/plugins) plugin must be installed (provides `/codex:review` and the `codex-companion.mjs` script the loop drives).
- `git` available; clean working tree before invocation (the loop will abort if dirty).
- For `/cr-loop-pr`: `gh` CLI installed and authenticated (`gh auth status`).

## Usage

```
/cr-loop                  # default base origin/main, converge and stop
/cr-loop-merge            # default base local main, converge and merge
/cr-loop-pr               # default base origin/main, converge, push, open PR
```

Pass an explicit base ref as the first argument when you want to review against something other than the default:

```
/cr-loop release/2026.05
/cr-loop-pr develop
```

## Tunable knobs

All three commands honor:

- `CR_LOOP_ROUND_CAP=` — **opt-in** ceiling on rounds (unset by default → no cap). Set to a positive integer to bound the run.
- `CR_LOOP_WIDEN_AFTER=5` — consecutive-same-file-family rounds before the widening guard fires.
- `CR_LOOP_SKIP_P3=1` — treat rounds with only P3 findings as clean.

`/cr-loop-merge` adds:

- `CR_LOOP_AUTO_WIDEN=1`, `CR_LOOP_MAX_WIDENING_SWEEPS=2` — auto-escalate to a systematic root-cause sweep instead of stopping at the widening guard.
- `CR_MERGE_TARGET=main`, `CR_MERGE_FF=auto` — local merge configuration.

`/cr-loop-pr` adds:

- `CR_PR_BASE=main`, `CR_PR_REMOTE=origin` — PR target.
- `CR_PR_DRAFT=0`, `CR_PR_TITLE=` — PR open options.

See each command file for the full procedure, guardrails, and handoff-file semantics.

## Why three commands instead of one with flags

Each command's contract is unambiguous: `/cr-loop-merge` will *never* push to remote; `/cr-loop-pr` will *always* end with a PR URL or a deferred handoff explaining why one wasn't created; `/cr-loop` will *never* touch any branch other than the one you started on. A single command with `--push` / `--pr` / `--merge` flags was rejected because the failure modes (push deferred, PR target moved, target locked in another worktree, gh unauthenticated) compound nontrivially and a flag-driven variant of one command would obscure which post-convergence step is actually authoritative.

## Safety guarantees

- `--no-verify`, `--force`, `--force-with-lease` are forbidden in all three commands.
- Pre-commit / pre-push hook failures defer to the user with the hook output surfaced; the loop never bypasses them.
- The post-review HEAD-drift check refuses to classify any round whose HEAD moved during review (catches concurrent agents / auto-commit hooks).
- All three commands write a `.cr-loop-handoff-round-<N>.md` file at the repo root on any non-converged exit, so a fresh session can resume exactly where the loop bailed. Handoffs are auto-cleaned on the next successful convergence.
