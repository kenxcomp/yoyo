# plan-guardian

A Claude Code plugin that provides rigorous plan review capabilities. Claude autonomously decides when to invoke the reviewer based on plan complexity and risk, or users can trigger it manually via `/plan-review`. As of **v1.3.0**, a second review path is available: an opt-out **codex review gate** that loops `codex exec` against every `ExitPlanMode` call and refuses to let plan mode exit until Codex emits `NO_CONCERNS`.

## Features

- **Plan-reviewer agent** — A dedicated agent that reviews plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent alignment)
- **EnterPlanMode hook** — Clears the previous review state when entering a new planning session
- **ExitPlanMode codex review gate** (v1.3.0) — `PreToolUse:ExitPlanMode` intercepts plan-mode exits; if the plan hasn't yet been approved by Codex, the hook denies the call and instructs Claude to run `/plan-guardian:codex-plan-review`. The slash command loops `codex exec` reviews, revises the plan based on reasonable findings, and writes a sha256 sentinel on convergence so the next `ExitPlanMode` is allowed through.
- **SessionStart injection** — Injects plan review guidelines (including codex-gate awareness) into every session as additionalContext
- **/plan-review skill** — Manually trigger the plan-reviewer agent at any time
- **/plan-guardian:codex-plan-review command** — Manually run the codex review loop against the current plan

## How It Works

### Path A — Plan-reviewer agent (advisory, unchanged from v1.2)

1. When you enter plan mode, the `EnterPlanMode` hook clears any previous review state in `./.plan-review/review-status.md`.
2. You write your plan.
3. Claude may autonomously launch the `plan-reviewer` agent based on its judgment, or you can invoke `/plan-review` manually.
4. The agent evaluates the plan against all 8 criteria, proposes fixes for any issues, and reports results.
5. ExitPlanMode is **not blocked by this path** — the agent review is advisory.

### Path B — Codex review gate (v1.3.0, opt-out)

1. You write your plan in plan mode.
2. Claude calls `ExitPlanMode` with the plan.
3. The `PreToolUse:ExitPlanMode` hook (`codex-plan-review-trigger.sh`) fires:
   - It computes sha256 of the plan.
   - It compares against `./.plan-review/.codex-review-done` (the sentinel of the last-approved plan).
   - **Match** → allow `ExitPlanMode`, clear the sentinel (one-shot; re-arms on the next plan).
   - **No match** → write the plan to `./.plan-review/yoplan-pending.md`, return `permissionDecision: "deny"` with a reason instructing Claude to run `/plan-guardian:codex-plan-review`.
4. Claude runs `/plan-guardian:codex-plan-review`:
   - Loads the plan from `./.plan-review/yoplan-pending.md`.
   - Per round: builds a strict-format review prompt, calls `codex exec --sandbox read-only --skip-git-repo-check ...`, blocks until Codex returns.
   - If Codex emits `NO_CONCERNS` → loop ends; sha256 of the current plan is written to `./.plan-review/.codex-review-done`.
   - If Codex returns concerns → Claude triages each one as `accept` / `partial` / `reject` (recorded in `./.plan-review/codex-rounds/round-<N>-decisions.md`), applies the accepted/partial edits to the plan file, and re-prompts.
   - The user's original intent overrides Codex — scope creep is rejected even if Codex's reasoning is technically sound.
5. Claude re-calls `ExitPlanMode` with the (possibly revised) plan from `./.plan-review/yoplan-pending.md`.
6. The hook sees the matching sentinel hash, allows the call, and clears the sentinel.

### Opt-out

- `CODEX_PLAN_REVIEW=0` in env → hook is a silent allow, slash command self-skips.
- Codex CLI not installed → hook is a silent allow.
- `jq` not installed → hook is a silent allow.

These three conditions guarantee the gate **never** blocks users who can't or don't want to use it.

### Audit trail

Every round writes three files under `./.plan-review/codex-rounds/`:

- `round-<N>-prompt.md` — what was sent to Codex
- `round-<N>-output.md` — Codex's raw response
- `round-<N>-decisions.md` — Claude's per-finding decision and rationale

These are not auto-cleaned — the user can inspect or delete them at any time. Add `./.plan-review/` to `.gitignore` if you don't want this audit trail tracked.

## Review Criteria (plan-reviewer agent only)

The plan-reviewer agent evaluates:

1. **Edge Cases** — Boundary conditions, null inputs, race conditions
2. **High-Impact Abnormal Scenarios** — Failure modes, data loss, security risks
3. **Syntax & Style Consistency** — Alignment with existing codebase patterns
4. **Logical Consistency** — No contradictions, circular dependencies, or impossible orderings
5. **Verification Steps** — Specific, measurable acceptance criteria
6. **Unclear Intentions** — No ambiguous goals or unstated assumptions
7. **Semantic Ambiguity** — No language that can be interpreted multiple ways
8. **User's Core Intent** — Plan delivers what was actually requested

The codex review gate uses Codex's own judgment (not these criteria) but applies the same north star: **material correctness/intent issues only, no nitpicks, user intent overrides Codex**.

## File Layout

```
plan-guardian/
├── .claude-plugin/
│   └── plugin.json
├── agents/
│   └── plan-reviewer.md
├── hooks/
│   └── hooks.json
├── skills/
│   └── plan-review/
│       └── SKILL.md
├── scripts/
│   ├── inject-skill.sh
│   └── codex-plan-review-trigger.sh    # v1.3.0 — PreToolUse:ExitPlanMode gate
├── commands/
│   └── codex-plan-review.md            # v1.3.0 — /plan-guardian:codex-plan-review
└── README.md
```

## State files (under `./.plan-review/`)

| File | Owner | Purpose | Lifecycle |
|------|-------|---------|-----------|
| `review-status.md` | plan-reviewer agent | 8-criterion checklist | Cleared by `EnterPlanMode` hook |
| `yoplan.md` | user (manual) | Fallback plan source | User-managed |
| `yoplan-pending.md` | codex gate hook | Plan being reviewed by codex loop | Overwritten on every blocked `ExitPlanMode` |
| `.codex-review-done` | `/plan-guardian:codex-plan-review` | sha256 of converged plan | Cleared by hook on successful `ExitPlanMode` |
| `codex-rounds/` | slash command | Per-round audit trail | User-managed |

## Notes

- The `.plan-review/` directory is created in the project working directory. Consider adding it to `.gitignore`.
- The plan-reviewer agent uses `memory: user` for persistent learning across sessions.
- The codex gate's sha256 normalization strips trailing newlines on both sides (hook and slash command) so byte-level equivalence is robust against editor-added trailing whitespace.
- Version: 1.3.0
