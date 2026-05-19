---
description: Loop `codex exec` plan review against the current plan, revise based on reasonable findings, repeat until codex has no concerns
---

# /plan-guardian:codex-plan-review

Drive an external review loop where **Codex** (`codex exec`) critiques the plan and you (Claude) revise it. Repeat until Codex returns no concerns (or the optional round cap is hit). On convergence, write a `sha256` sentinel so the `PreToolUse:ExitPlanMode` hook stops blocking and the original `ExitPlanMode` proposal goes through.

This command can be invoked two ways:

1. **Auto-triggered**: The `PreToolUse:ExitPlanMode` hook (`codex-plan-review-trigger.sh`) detected an unreviewed plan, saved it to `./.plan-review/yoplan-pending.md`, blocked the `ExitPlanMode` call, and instructed Claude to run this command. This is the normal flow.
2. **Manual**: User typed `/plan-guardian:codex-plan-review` directly. Locate the plan from any of the standard sources (see Step 1).

## Preflight — verify Codex is available

Run `command -v codex >/dev/null 2>&1` (or `which codex`). If Codex CLI is **not** installed:

- Print: `Codex CLI not found. Install via the openai-codex plugin or upstream instructions, then re-run /plan-guardian:codex-plan-review.`
- **Do not** write the sentinel file. **Do not** fail silently. Terminate.

If `CODEX_PLAN_REVIEW=0` is set in the environment, the user has opted out of this command — print `codex plan-review disabled via CODEX_PLAN_REVIEW=0` and terminate without writing the sentinel.

## Step 1 — Locate the plan

Check sources in this order and stop at the first hit:

1. `./.plan-review/yoplan-pending.md` (written by the `ExitPlanMode` hook — **canonical location for auto-trigger**)
2. The most recently mentioned plan file in conversation context (e.g., something the user passed as a path)
3. `./.plan-review/yoplan.md`
4. `~/.claude/plans/*.md` — the most recently modified entry
5. Conversation context — if Claude just wrote the plan inline and there's no file yet, **dump it** to `./.plan-review/yoplan-pending.md` first so the loop has a stable file to mutate

If nothing is found, print `No plan to review.` and terminate.

Store the resolved path as `$PLAN`. All edits in this command MUST operate on this single file. Never inline-edit the conversation copy — there's no point, only the file is the source of truth for the sentinel hash.

## Step 2 — Initialize the round directory

```bash
mkdir -p ./.plan-review/codex-rounds
```

Each round writes:

- `./.plan-review/codex-rounds/round-<N>-prompt.md` — the prompt sent to Codex
- `./.plan-review/codex-rounds/round-<N>-output.md` — Codex's raw response
- `./.plan-review/codex-rounds/round-<N>-decisions.md` — your per-finding decision (accept / partial / reject + rationale)

The directory is intentionally per-project and **not** auto-cleaned — it's the audit trail of how the plan converged. The user can delete it whenever they want.

## Step 3 — The loop

Set `N=1`. Set `MAX = ${CODEX_PLAN_REVIEW_MAX_ROUNDS:-0}` (0 = no cap, default). Loop:

### 3a. Build the Codex prompt

Read the current contents of `$PLAN`. Write to `round-<N>-prompt.md`:

```
You are reviewing a software-engineering plan written by another agent. Your job
is to surface **material** problems only — issues that would cause incorrect
behavior, missed user intent, data loss, security gaps, undefined edge cases,
contradictory steps, or unmeasurable acceptance criteria.

DO NOT nitpick wording or style. DO NOT propose unrelated refactors. DO NOT
demand defensive code or validation that the plan doesn't need.

Output format — strictly one of these two shapes, nothing else:

  (A) The literal line:
      NO_CONCERNS
      followed (optionally) by a single line summarizing why the plan is sound.

  (B) A numbered list of concerns. For each concern:
      - **Concern**: <one sentence>
      - **Why it matters**: <one or two sentences>
      - **Suggested fix**: <concrete change to the plan, not vague advice>

If the plan has zero material issues, emit (A). Otherwise emit (B). Never both.

---
PLAN UNDER REVIEW
---

<insert the full contents of $PLAN here>
```

### 3b. Invoke Codex

Run **foreground**, blocking until Codex returns. The redirection `< /dev/null` is **mandatory** — see the first note below:

```bash
codex exec \
  --sandbox read-only \
  --skip-git-repo-check \
  --cd "$(pwd)" \
  --output-last-message ./.plan-review/codex-rounds/round-${N}-output.md \
  -- "$(cat ./.plan-review/codex-rounds/round-${N}-prompt.md)" \
  < /dev/null
```

Notes:

- **`< /dev/null` is mandatory.** Per `codex exec --help`: if stdin is a pipe (non-TTY), Codex appends a `<stdin>` block to the prompt — and in agent contexts like Claude Code's Bash tool, stdin is always a pipe, so Codex blocks indefinitely waiting for input that will never come. Symptoms: the call appears to hang for many minutes, `round-<N>-output.md` never gets created, and the run's stdout contains `Reading additional input from stdin...`. Explicitly closing stdin with `< /dev/null` makes the prompt-arg the only input. **Do not omit this redirect** under any circumstance.
- **`--sandbox read-only`** is non-negotiable. Codex is reviewing text, not modifying code. If Codex tries to write, that's a bug; do not relax the sandbox.
- **No timeout wrapper.** Plan review duration legitimately scales with plan length and Codex's reasoning depth. Block on the foreground process. If you genuinely believe Codex is hung (multiple minutes of zero output to the output file AND the stdout does NOT contain `Reading additional input from stdin...` — that one is a missing `< /dev/null` bug, not a hang), tell the user and let them decide whether to interrupt — do NOT auto-kill.
- If `codex exec` exits non-zero, write the error to `round-<N>-output.md`, print a brief summary, and **terminate the loop without writing the sentinel** so the user can fix the upstream problem (auth, quota, model availability) and re-run.

### 3c. Classify the output

Read `round-<N>-output.md`. Determine: is the **first non-empty line** exactly `NO_CONCERNS` (case-sensitive, allowing leading/trailing whitespace on that line)?

- **Yes → loop terminates, jump to Step 4.** Append the optional reason line to `round-<N>-decisions.md` as `Codex final note: <reason>`.
- **No → treat as a concerns list and proceed to 3d.**

### 3d. Triage each concern

For each numbered concern in the Codex output, write to `round-<N>-decisions.md` one of:

| Decision | When | Action |
|----------|------|--------|
| `accept` | The concern is real and the suggested fix (or your adapted version) materially improves the plan. | Edit `$PLAN` to incorporate the fix. Use `Edit` with a narrow `old_string` / `new_string` — do not rewrite unaffected sections. |
| `partial` | The underlying concern is valid but the suggested fix isn't quite right. | Apply your own corrective change to `$PLAN`. Record in `round-<N>-decisions.md` what you changed and why your version is better. |
| `reject` | The concern is a nitpick, contradicts the user's stated intent, demands scope the user did not request, or is factually wrong about the codebase. | Do not modify `$PLAN`. Record the rejection rationale in 1–2 sentences. |

Critical guardrails:

- **Never let Codex push the plan outside the user's stated scope.** A correct fix that adds features the user didn't ask for is `reject`, not `accept` — even if Codex's reasoning is technically sound. The original user intent is the north star.
- **Never edit the plan to weaken safety or correctness** just to placate a `reject`-class concern. If Codex demands removing a verification step you correctly added, reject.
- **One `accept` may invalidate a later concern.** After each accept, re-check the remaining concerns in the same list against the current plan state — if a later concern was about something you just changed, mark it `superseded` instead of running it.

### 3e. Loop guard

After triaging, increment `N` and check:

- If `MAX > 0` and `N > MAX`: terminate **without** writing the sentinel. Print:
  ```
  Hit CODEX_PLAN_REVIEW_MAX_ROUNDS=<MAX> without convergence. Last round's
  concerns are in ./.plan-review/codex-rounds/round-<MAX>-output.md. Either:
    (a) raise the cap and re-run /plan-guardian:codex-plan-review, or
    (b) review the remaining concerns manually and decide whether to proceed.
  ```
- **Anti-thrash check**: compare the current `$PLAN` content hash with the previous round's *post-edit* content hash. If **two consecutive rounds produced zero edits** (every concern was `reject` or `superseded`) AND Codex still didn't emit `NO_CONCERNS`, you've hit a stable disagreement. Terminate **without** writing the sentinel, print the disagreement summary, and let the user decide.
- Otherwise: go back to 3a with the updated `$PLAN`.

## Step 4 — Convergence

Codex returned `NO_CONCERNS`. The plan is approved by Codex. Write the sentinel using the **exact same normalization the hook uses** — read the file contents, strip trailing newlines (bash command-substitution behavior), hash:

```bash
printf '%s' "$(cat "$PLAN")" | shasum -a 256 | awk '{print $1}' > ./.plan-review/.codex-review-done
```

This matches the hook's hash computation (`printf '%s' "$(jq -r .tool_input.plan ...)" | shasum -a 256`), because both sides strip trailing newlines before hashing.

The hook will read this sentinel and compare it against the hash of the `plan` field passed to the next `ExitPlanMode` call. So when you re-call `ExitPlanMode`, **pass the contents of `$PLAN` exactly as-is** — Claude Code's tool input plumbing preserves the bytes, and trailing-newline differences are normalized away by both sides.

Then print to the user, in Chinese (because this project communicates in Chinese):

```
✅ Codex plan review 已收敛(共 <N> 轮)。
   - 修订后的计划:$PLAN
   - 审计轨迹:./.plan-review/codex-rounds/
   - 现在可以重新调用 ExitPlanMode,hook 将放行。
```

If the user manually invoked this command (not via the hook), append:

```
   - 提示:hook sentinel 已写入 ./.plan-review/.codex-review-done。
     该 sentinel 仅对当前 $PLAN 的字节内容有效;一旦 $PLAN 再被修改,
     下次 ExitPlanMode 仍会被 hook 拦截重新走 review 循环。
```

## Step 5 — Hand control back

Do **not** call `ExitPlanMode` yourself from this command. The user (or the calling agent) decides when to exit plan mode. Your job ends at writing the sentinel and reporting.

## Guardrails

- **Never write the sentinel unless Codex emitted `NO_CONCERNS` in the most recent round.** Hitting the round cap, stable disagreement, codex-exec failure, sandbox violation — none of these justify writing the sentinel. The sentinel is a *positive* signal from Codex, not a fallback.
- **Never modify any file outside `$PLAN` and `./.plan-review/`.** This command does not refactor code, does not edit READMEs, does not touch git state.
- **Never run `codex exec` with `--sandbox workspace-write` or `danger-full-access`.** Read-only is correct because the loop is text-on-text.
- **Never paraphrase `NO_CONCERNS`.** If Codex says "looks good to me" or "approved" or "好的没问题", that is **NOT** `NO_CONCERNS` — re-prompt Codex with the strict-format reminder, or escalate to the user. Downstream tools depend on the exact literal.
- **Never silently accept Codex concerns that contradict the user's original request.** Reject and document. The user is the final authority on scope.
- **Honor the env opt-out.** `CODEX_PLAN_REVIEW=0` disables this command entirely; the hook should also respect it (it does, see the trigger script).

## Manual reset

If a user wants to bypass the loop for a one-off case (e.g., codex is down, plan is trivial), they can manually write the sentinel **using the same normalization the hook uses**:

```bash
printf '%s' "$(cat ./.plan-review/yoplan-pending.md)" | shasum -a 256 | awk '{print $1}' > ./.plan-review/.codex-review-done
```

Document this in your response if they ask how to skip — do not do it for them silently.
