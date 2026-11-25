# t3-tri-plan (v1.0.0)

T3 Code-native **triple-blind Trellis planning & design-review convergence pipeline** — standalone plugin usable across any repository with `.trellis/`, without modifying repository-local `/trellis:dual-plan`, `workflow.md`, or `continue.md`.

## Highlights

1. **True Triple-Blind Parallel Design (Phase 1)**:
   - Dispatches 3 independent read-only `delegate_task` designers in parallel (pre-recommending `antigravity/gemini-4-neon`, `claudeAgent/claude-opus-5-5`, and `codex/gpt-6.2-sol` when available via `orchestrator_capabilities`).
   - Zero parent history, zero disk writes by children (plain Markdown returned in final reply, validated by fence-aware `validate-candidate.pl`), shuffled anonymous slot files (`candidates/candidate-{a,b,c}.md`) written atomically only after collection.
2. **Zero-History Anonymous Blind Judging & Pre-Reveal Freeze (Phase 2)**:
   - A fresh zero-history read-only Blind Judge evaluates the anonymous candidates against real repository code, selects **1 Primary Winner** + **Surgical Cherry-Picks** (every cherry-pick backed by a `CONFIRMED` `file:line` fact check belonging to that exact source slot), and produces locked `blind-eval.json`, `synthesis-body-locked.md`, and `initial-design.md` **before** `reveal-blind-map` unlocks.
   - Phase 2b mechanically verifies `design.md` is byte-identical to pre-reveal `initial-design.md` and appends only the `## Attribution Reveal` table to `synthesis.md`.
3. **Multi-Model Design Review Convergence Loop (Phase 3–4)**:
   - Mirrors `t3-cr-loop`: parallel multi-model council on `initial-full` and `step-back` rounds; default single reviewer on `incremental` and `confirmation-full` rounds.
   - Fixes `dual-plan`'s `step-back` counter bug (`step_backs_done += 1` AND `dirty_since_step_back = 0` on committed `step-back`), enforces `disposition-required` before next review, checks cross-round `review_baseline_sha256` (detecting source code / `REVIEW.md` / spec drift between clean rounds), and enforces strict unique-key JSON validation (`StrictJson.pm`) + frozen baseline rule anchor verification.
4. **Atomic `flock` Transactions & Safe Phase 6 Activation**:
   - Process-exit-safe `flock` + two-phase replayable `.pending.tx.json` (with 3-state Pre/Done/Conflict verification catching recreated archive sources and symlinks).
   - Independent Phase 5 non-seed JSONL & codification validation (closing `task.py validate`'s missing/seed-only gap).
   - Process-lifetime `.activation.lock`, dual-source fail-closed `after_start` hook probing, zero-exit hook warning detection, and shared `verify_activation_postconditions` across normal completion, crash recovery, and manual resolution.

## Required Host Tools (T3 Code)

`t3-tri-plan` requires T3 Code's orchestration MCP tools:
`orchestrator_capabilities`, `delegate_task`, `task_cancel`, `t3_thread_list`, and `t3_thread_read` (plus interactive prompting via `ask_question` when available).

## Installation

`t3-tri-plan` supports two distinct discovery mechanisms:
- **Marketplace plugin discovery**: registered in `.agents/plugins/marketplace.json`.
- **Global / project skill symlinks**: installed via `scripts/install-skills.sh` (which strictly checks symlink ownership and never overwrites or removes user-owned files/links):

```bash
# Install into ~/.agents/skills/ (default) and ~/.claude/skills/
bash plugins/t3-tri-plan/scripts/install-skills.sh
bash plugins/t3-tri-plan/scripts/install-skills.sh --target "$HOME/.claude/skills"

# Verify installation
bash plugins/t3-tri-plan/scripts/install-skills.sh --check
bash plugins/t3-tri-plan/scripts/install-skills.sh --target "$HOME/.claude/skills" --check

# Optional: install into one project or uninstall cleanly
bash plugins/t3-tri-plan/scripts/install-skills.sh --project /path/to/repo
bash plugins/t3-tri-plan/scripts/install-skills.sh --uninstall
```

Restart your T3 Code agent session after installing so the `t3-tri-plan` skill loads.

## Configuration & Overrides

- **User config** (independent from `t3-cr-loop`): `~/.config/t3-tri-plan/config.json` (override path with `T3_TRI_PLAN_CONFIG`). Guided interactively on first run (`reconfigure` to re-run).
- **Optional repo override**: `<repo-root>/.t3-tri-plan.json` (cannot set `authorizedProviders`; new providers require explicit user authorization).
- **Per-invocation overrides**:
  - `designers=antigravity/gemini-4-neon,claudeAgent/claude-opus-5-5,codex/gpt-6.2-sol`
  - `judge=codex/gpt-6.2-sol:high` (never altered indirectly by `single=` or `model=`)
  - `model=codex/gpt-6.2-sol` / `effort=high`
  - `council=antigravity/gemini-4-neon:high,claudeAgent/claude-opus-5-5:high,codex/gpt-6.2-sol:high`
  - `single=codex/gpt-6.2-sol:high` (Phase 3 only; conflicts with `model=`/`council=`)

## Compatibility Boundary with Native Trellis Entrypoints

- **Safe native handoff**: once `t3-tri-plan` completes Phase 6 (`activated`) and `check-freshness` passes, native Trellis implementation/check/finish-work steps can consume `task.json`, `prd.md`, `design.md`, `implement.md`, `implement.jsonl`, `check.jsonl`, and `planning-state.json`.
- **Unsafe native resume**: native `/trellis:dual-plan` and `/trellis:continue` freshness reroutes do not understand 3-candidate artifacts, `.tri-plan.lock`, `.pending.tx.json`, `active-run.json`, `review_baseline_sha256`, `design_revisions[]`, or `activation_uncertain`. Always use `/t3-tri-plan` to resume or re-plan a tri-plan task.

## Running Regression Tests

```bash
bash plugins/t3-tri-plan/scripts/test-t3-tri-plan.sh
```
