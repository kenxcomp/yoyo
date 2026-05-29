# plan-guardian

A Claude Code plugin that provides rigorous plan review capabilities. Claude autonomously decides when to invoke the reviewer based on plan complexity and risk, or users can trigger it manually via `/plan-review`. As of **v1.3.0**, a second review path is available: an opt-out **codex review gate** that loops `codex exec` against every `ExitPlanMode` call and refuses to let plan mode exit until Codex emits `NO_CONCERNS`. **v1.5.0** reworks how the gate remembers "this plan was approved": instead of a sha256 sentinel **file**, it carries an inline marker inside the plan text — so the loop writes nothing to disk while in plan mode.

## Features

- **Plan-reviewer agent** — A dedicated agent that reviews plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent alignment)
- **EnterPlanMode hook** — Clears the previous review state when entering a new planning session
- **ExitPlanMode codex review gate** (v1.3.0, marker-based since v1.5.0) — `PreToolUse:ExitPlanMode` intercepts plan-mode exits; if the plan carries no valid Codex-review marker, the hook denies the call and instructs Claude to run `/plan-guardian:codex-plan-review`. The slash command loops `codex exec` reviews, revises the plan based on reasonable findings, and on convergence appends an inline marker to the plan so the next `ExitPlanMode` is allowed through.
- **SessionStart injection** — Injects plan review guidelines (including codex-gate awareness) into every session as additionalContext
- **/plan-review skill** — Manually trigger the plan-reviewer agent at any time
- **/plan-guardian:codex-plan-review command** — Manually run the codex review loop against the current plan
- **/plan-guardian:setup command** (v1.4.0, trimmed in v1.5.0) — Adds two scoped `Bash()` allow-rules (the `codex exec` call + the digest helper) so the codex loop stops prompting while you are still in plan mode

## How It Works

### Path A — Plan-reviewer agent (advisory, unchanged from v1.2)

1. When you enter plan mode, the `EnterPlanMode` hook clears any previous review state in `./.plan-review/review-status.md`.
2. You write your plan.
3. Claude may autonomously launch the `plan-reviewer` agent based on its judgment, or you can invoke `/plan-review` manually.
4. The agent evaluates the plan against all 8 criteria, proposes fixes for any issues, and reports results.
5. ExitPlanMode is **not blocked by this path** — the agent review is advisory.

### Path B — Codex review gate (v1.3.0, inline marker since v1.5.0, opt-out)

1. You write your plan in plan mode.
2. Claude calls `ExitPlanMode` with the plan.
3. The `PreToolUse:ExitPlanMode` hook (`codex-plan-review-trigger.sh`) fires:
   - It looks for an inline marker on the plan's **last line**: `<!-- codex-reviewed:<token> -->`.
   - If present, it strips that line, recomputes the token over the plan body (via the shared `plan-review-helper.sh digest`), and compares.
   - **Token matches** → allow `ExitPlanMode`. (No file to clear — the marker is bound to this exact plan body; the same plan always validates, a changed plan never does.)
   - **No/invalid marker** → write the plan to `./.plan-review/yoplan-pending.md` (a plain hook-process write, not gated by plan mode) and return `permissionDecision: "deny"` with a reason instructing Claude to run `/plan-guardian:codex-plan-review`.
4. Claude runs `/plan-guardian:codex-plan-review` — **entirely in conversation context, no files written**:
   - Takes the plan from context (the one just denied); `./.plan-review/yoplan-pending.md` is a fallback source.
   - Per round: builds a strict-format review prompt, calls `codex exec --sandbox read-only --skip-git-repo-check … < /dev/null` with the prompt inline, blocks until Codex returns, reads the review from **stdout**.
   - If Codex returns concerns → Claude triages each as `accept` / `partial` / `reject` (in its reasoning), revises the in-context plan, and re-prompts. The user's original intent overrides Codex — scope creep is rejected even if Codex's reasoning is technically sound.
   - If Codex emits `NO_CONCERNS` → loop ends; Claude mints a marker token for the final plan body (`plan-review-helper.sh digest`) and appends `<!-- codex-reviewed:<token> -->` as the plan's last line.
5. Claude re-calls `ExitPlanMode` with the **marked** plan text, verbatim.
6. The hook recomputes the token over the body, sees it match, and allows the call.

### The marker token

The token is computed by one shared subcommand (`plan-review-helper.sh digest`) so the mint side (command) and verify side (hook) can never drift. The signing key is resolved in priority order (v1.5.1):

1. **`$CODEX_REVIEW_SECRET`** if set — explicit per-user/per-project key.
2. **Per-machine auto key file** `~/.claude/plan-guardian/secret` (overridable via `$CODEX_REVIEW_SECRET_FILE`) — generated `mode 600` on first use. This makes the marker **content-bound by default, no setup required** — every user gets the strong mode.
3. **Literal fallback** `l1:none` — only when no key can be established (unwritable `HOME` and no random source). Spoofable; not content-bound.

With a key in effect (cases 1–2), the token is `h1:<sha256(key"\n"body)>` — **content-bound**: revising the plan changes the body, invalidating the marker and re-arming the gate automatically. (A keyed SHA-256, not RFC-2104 HMAC — sufficient for a single local user, not a cryptographic adversary.)

Both the hook and the command run this same helper, so they resolve the same key and always agree.

### Opt-out

- `CODEX_PLAN_REVIEW=0` in env → hook is a silent allow, slash command self-skips.
- Codex CLI not installed → hook is a silent allow.
- `jq` not installed → hook is a silent allow.

These conditions guarantee the gate **never** blocks users who can't or don't want to use it.

### No audit trail on disk (v1.5.0 tradeoff)

Earlier versions wrote per-round files under `./.plan-review/codex-rounds/`. v1.5.0 keeps the whole loop in conversation context to avoid any plan-mode file writes, so there is no on-disk audit trail by default — the round-by-round prompts, Codex outputs, and triage decisions live in the conversation. If you want a persisted record, copy it out of the conversation after exiting plan mode.

## Silencing plan-mode permission prompts (v1.5.0)

The codex review gate runs **while the session is still in plan mode** — the `ExitPlanMode` hook denies the exit and hands control to `/plan-guardian:codex-plan-review` before the mode changes. In plan mode, Write / Edit / Bash are gated exactly like `default` mode (they prompt).

**v1.5.0 removed all Write/Edit from the loop.** The reviewed-proof is now an inline marker inside the plan text (carried to the hook through `tool_input.plan`), so no files are written during plan mode. That deliberately sidesteps the open Claude Code bug where the allow-list *intermittently fails to suppress Write/Edit prompts* under mode toggles — there are no Write/Edit calls left to mis-prompt. Only **two Bash calls** remain per loop: `codex exec` (the review) and `plan-review-helper.sh digest` (minting the marker).

Run **`/plan-guardian:setup`** once to add these two scoped allow-rules to your `~/.claude/settings.json` (it shows them and asks before writing, backs the file up, and merges idempotently):

| Rule | Covers |
|------|--------|
| `Bash(codex exec *)` | the per-round `codex exec` review call |
| `Bash(<install-dir>/plan-guardian/*/scripts/plan-review-helper.sh *)` | the `digest` marker mint |

No `Edit`/`Write` rules are needed anymore. (Leftover `Edit/Write(.plan-review/**)` rules from an older setup are unused and harmless; you may delete them.) The version segment of the helper path is wildcarded (`…/plan-guardian/*/scripts/…`) because Claude Code expands `${CLAUDE_PLUGIN_ROOT}` to a version-stamped install dir before the command runs — a pinned path would break on the next plugin update.

Do **not** move state into `.claude/`: it is a Claude Code **protected path** whose writes are never auto-approved except under `bypassPermissions`, and an allow rule cannot override it.

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
│   ├── codex-plan-review-trigger.sh    # v1.3.0 gate; v1.5.0 verifies inline marker
│   └── plan-review-helper.sh           # v1.5.0 — shared `digest` (mint + verify)
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
| `yoplan-pending.md` | codex gate hook | Fallback copy of the plan being reviewed (ungated hook write) | Overwritten on every blocked `ExitPlanMode` |

The codex gate no longer uses a sentinel file or a `codex-rounds/` directory — the "reviewed" proof is the inline marker inside the plan text, and the loop runs in conversation context.

## Notes

- The `.plan-review/` directory is created in the project working directory (by the hook, for the fallback plan copy). Consider adding it to `.gitignore`.
- The plan-reviewer agent uses `memory: user` for persistent learning across sessions.
- The marker digest normalizes trailing newlines on both sides (mint and verify call the same `plan-review-helper.sh digest`), so byte-level equivalence is robust against editor-added trailing whitespace.
- The marker is content-bound by default (v1.5.1): the helper auto-generates a per-machine key at `~/.claude/plan-guardian/secret` on first use. Set `CODEX_REVIEW_SECRET` to override it; the literal fallback only appears if no key can be established.
- Implementation note: the hook's deny-path heredoc is fed straight into `jq -Rs` rather than `$(cat <<'EOF')` — macOS's stock bash 3.2.57 misparses a quoted heredoc nested in `$(...)` at runtime (`bash -n` does not catch it).
- Version: 1.5.1
