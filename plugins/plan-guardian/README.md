# plan-guardian

A Claude Code plugin that provides rigorous plan review capabilities. Claude autonomously decides when to invoke the reviewer based on plan complexity and risk, or users can trigger it manually via `/plan-review`. As of **v1.3.0**, a second review path is available: an opt-out **codex review gate** that loops `codex exec` against every `ExitPlanMode` call and refuses to let plan mode exit until Codex emits `NO_CONCERNS`.

## Features

- **Plan-reviewer agent** — A dedicated agent that reviews plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent alignment)
- **EnterPlanMode hook** — Clears the previous review state when entering a new planning session
- **ExitPlanMode codex review gate** (v1.3.0) — `PreToolUse:ExitPlanMode` intercepts plan-mode exits; if the plan hasn't yet been approved by Codex, the hook denies the call and instructs Claude to run `/plan-guardian:codex-plan-review`. The slash command loops `codex exec` reviews, revises the plan based on reasonable findings, and writes a sha256 sentinel on convergence so the next `ExitPlanMode` is allowed through.
- **SessionStart injection** — Injects plan review guidelines (including codex-gate awareness) into every session as additionalContext
- **/plan-review skill** — Manually trigger the plan-reviewer agent at any time
- **/plan-guardian:codex-plan-review command** — Manually run the codex review loop against the current plan
- **/plan-guardian:setup command** (v1.4.0) — Adds scoped permission allow-rules so the codex loop's `./.plan-review/` writes and its `codex exec` call stop prompting while you are still in plan mode

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

## Silencing plan-mode permission prompts (v1.4.0)

The codex review gate runs **while the session is still in plan mode** — the `ExitPlanMode` hook denies the exit and hands control to `/plan-guardian:codex-plan-review` before the mode changes. In plan mode, Write / Edit / Bash are gated exactly like `default` mode (they prompt), so each round's file writes and the `codex exec` call ask you to approve them. That can be several prompts per plan.

This is caused by **plan mode, not by the `./.plan-review/` location** — every non-read write prompts in plan mode regardless of path. Moving state into `.claude/` would be *worse*: `.claude` is a Claude Code **protected path** whose writes are never auto-approved in any mode except `bypassPermissions`, and an allow rule cannot override it. `./.plan-review/` is a normal, non-protected project directory, which is exactly why allow rules can pre-approve it.

Run **`/plan-guardian:setup`** once to add these scoped allow-rules to your `~/.claude/settings.json` (it shows them and asks before writing, backs the file up, and merges idempotently):

| Rule | Covers |
|------|--------|
| `Edit(.plan-review/**)` | plan revisions to `yoplan-pending.md` |
| `Write(.plan-review/**)` | `round-<N>-prompt.md`, `round-<N>-decisions.md`, `review-status.md` |
| `Bash(codex exec *)` | the per-round `codex exec` review call |
| `Bash(<abs>/scripts/plan-review-helper.sh *)` | `init` (mkdir) + `sentinel` write (resolved absolute path) |
| `Bash(${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-helper.sh *)` | same, literal-variable form (matches whether or not the matcher expands the variable) |

`.plan-review/**` is anchored to the current working directory, so one rule set in global user settings works in every project. The loop's `mkdir` and the sha256 sentinel write (a fragile-to-allow `printf | shasum > file` pipe) are consolidated into `scripts/plan-review-helper.sh` so a single stable `Bash()` rule covers both.

**Caveat:** there are open upstream reports where the allow-list intermittently fails to suppress Write/Edit prompts under mode toggles. If prompts persist after setup, that is the upstream bug, not a mis-config — check `/permissions` to confirm the rules loaded. Alternatively, disable the whole gate with `CODEX_PLAN_REVIEW=0`.

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
│   ├── codex-plan-review-trigger.sh    # v1.3.0 — PreToolUse:ExitPlanMode gate
│   └── plan-review-helper.sh           # v1.4.0 — pre-approvable init + sentinel
├── commands/
│   ├── codex-plan-review.md            # v1.3.0 — /plan-guardian:codex-plan-review
│   └── setup.md                        # v1.4.0 — /plan-guardian:setup
└── README.md
```

## State files (under `./.plan-review/`)

| File | Owner | Purpose | Lifecycle |
|------|-------|---------|-----------|
| `review-status.md` | plan-reviewer agent | 8-criterion checklist | Cleared by `EnterPlanMode` hook |
| `yoplan.md` | user (manual) | Fallback plan source | User-managed |
| `yoplan-pending.md` | codex gate hook | Plan being reviewed by codex loop | Overwritten on every blocked `ExitPlanMode` |
| `.codex-review-done` | `plan-review-helper.sh sentinel` (called by the slash command) | sha256 of converged plan | Cleared by hook on successful `ExitPlanMode` |
| `codex-rounds/` | slash command | Per-round audit trail | User-managed |

## Notes

- The `.plan-review/` directory is created in the project working directory. Consider adding it to `.gitignore`.
- The plan-reviewer agent uses `memory: user` for persistent learning across sessions.
- The codex gate's sha256 normalization strips trailing newlines on both sides (hook and `plan-review-helper.sh sentinel`) so byte-level equivalence is robust against editor-added trailing whitespace.
- Version: 1.4.0
