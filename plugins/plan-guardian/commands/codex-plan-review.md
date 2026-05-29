---
description: Loop `codex exec` plan review against the current plan, revise based on reasonable findings, repeat until codex has no concerns
---

# /plan-guardian:codex-plan-review

Drive an external review loop where **Codex** (`codex exec`) critiques the plan and you (Claude) revise it. Repeat until Codex returns no concerns (or the optional round cap is hit). On convergence, append an **inline review marker** to the plan so the `PreToolUse:ExitPlanMode` hook recognizes it and lets the `ExitPlanMode` call through.

**v1.5.0 — inline marker, no state files (read this first):** the entire loop runs while the session is **still in plan mode**, where `Write`/`Edit` prompt like default mode *and* the allow-list intermittently fails to suppress those prompts on some Claude Code versions. So this command writes **nothing** to disk during the loop. The plan body, every round's prompt, every round's Codex output, and your per-finding decisions all live in **conversation context**. The only persisted artifact is a marker line you append to the plan text itself — which rides to the hook through `tool_input.plan`, not the filesystem. The only two Bash calls in the whole loop are `codex exec` and `plan-review-helper.sh digest` (both covered by stable `Bash()` allow-rules from `/plan-guardian:setup`).

This command can be invoked two ways:

1. **Auto-triggered**: The `PreToolUse:ExitPlanMode` hook (`codex-plan-review-trigger.sh`) found no valid marker on the plan, denied the `ExitPlanMode` call, and instructed you to run this command. The plan is in your context (the one you just tried to submit); the hook also stashed a copy at `./.plan-review/yoplan-pending.md` as a fallback reference. This is the normal flow.
2. **Manual**: User typed `/plan-guardian:codex-plan-review` directly. Locate the plan from any of the standard sources (see Step 1).

## Preflight — verify Codex is available

Run `command -v codex >/dev/null 2>&1`. If Codex CLI is **not** installed:

- Print: `Codex CLI not found. Install via the openai-codex plugin or upstream instructions, then re-run /plan-guardian:codex-plan-review.`
- **Do not** append a marker. **Do not** fail silently. Terminate.

If `CODEX_PLAN_REVIEW=0` is set in the environment, the user has opted out — print `codex plan-review disabled via CODEX_PLAN_REVIEW=0` and terminate without appending a marker.

## Step 1 — Locate the plan

The plan body is whatever you are about to submit to `ExitPlanMode`. Resolve it in this order and stop at the first hit:

1. The plan in **conversation context** — the one whose `ExitPlanMode` the hook just denied. This is the canonical source for the auto-trigger flow.
2. `./.plan-review/yoplan-pending.md` (fallback copy written by the hook).
3. The most recently mentioned plan file in conversation context (a path the user passed).
4. `~/.claude/plans/*.md` — the most recently modified entry.

If nothing is found, print `No plan to review.` and terminate.

Hold the resolved text as `PLAN_BODY` **in context**. All revisions happen to this in-context copy. Do **not** write it to a file — there is no on-disk source of truth in v1.5.0; the plan body you finally pass to `ExitPlanMode` is authoritative, and the hook validates the marker against exactly that text.

> If `PLAN_BODY` already ends with a `<!-- codex-reviewed:... -->` line (e.g. you re-ran the command), strip that trailing marker line before reviewing — you review and re-mint over the body only, never over a body that still carries an old marker.

## Step 2 — The loop

Set `N = 1`. Set `MAX = ${CODEX_PLAN_REVIEW_MAX_ROUNDS:-0}` (0 = no cap, default). Keep all round artifacts in context (label them "round N prompt / output / decisions" in your reasoning). Loop:

### 2a. Build the Codex prompt (in context)

Compose this prompt with the current `PLAN_BODY` interpolated at the bottom:

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

<insert the full current PLAN_BODY here>
```

### 2b. Invoke Codex

Run **foreground**, blocking until Codex returns, passing the whole prompt as the positional arg. Capture **stdout** directly — do **not** use `--output-last-message` (that would write a file and prompt). The redirection `< /dev/null` is **mandatory** — see the first note:

```bash
codex exec \
  --sandbox read-only \
  --skip-git-repo-check \
  --cd "$(pwd)" \
  -- "$(cat <<'PROMPT'
<paste the round prompt from 2a here>
PROMPT
)" \
  < /dev/null
```

(Heredoc-as-arg keeps the multi-line prompt intact without a temp file. If your prompt contains a line that is literally `PROMPT`, pick another delimiter.)

Read Codex's review from the command's **stdout** in the tool result.

Notes:

- **`< /dev/null` is mandatory.** Per `codex exec --help`: if stdin is a pipe (non-TTY), Codex appends a `<stdin>` block to the prompt — and in agent contexts like Claude Code's Bash tool, stdin is always a pipe, so Codex blocks indefinitely waiting for input that never comes. Symptoms: the call appears to hang for many minutes and stdout contains `Reading additional input from stdin...`. Closing stdin with `< /dev/null` makes the prompt-arg the only input. **Do not omit this redirect.**
- **`--sandbox read-only`** is non-negotiable. Codex is reviewing text, not modifying code. If Codex tries to write, that's a bug; do not relax the sandbox.
- **No timeout wrapper.** Review duration legitimately scales with plan length and Codex's reasoning depth. Block on the foreground process. If you genuinely believe Codex is hung (many minutes of zero output AND stdout does NOT contain `Reading additional input from stdin...` — that one is a missing `< /dev/null` bug, not a hang), tell the user and let them decide; do NOT auto-kill.
- If `codex exec` exits non-zero, print a brief summary of the error and **terminate the loop without appending a marker** so the user can fix the upstream problem (auth, quota, model availability) and re-run.

### 2c. Classify the output

From Codex's stdout, determine: is the **first non-empty line** exactly `NO_CONCERNS` (case-sensitive, leading/trailing whitespace on that line allowed)?

- **Yes → loop terminates, jump to Step 3.**
- **No → treat as a concerns list and proceed to 2d.**

### 2d. Triage each concern (in context)

For each numbered concern, decide and record (in your reasoning, as "round N decisions") one of:

| Decision | When | Action |
|----------|------|--------|
| `accept` | The concern is real and the suggested fix (or your adapted version) materially improves the plan. | Revise `PLAN_BODY` in context to incorporate the fix. Change only the affected part. |
| `partial` | The underlying concern is valid but the suggested fix isn't quite right. | Apply your own corrective change to `PLAN_BODY`. Note what you changed and why your version is better. |
| `reject` | The concern is a nitpick, contradicts the user's stated intent, demands scope the user did not request, or is factually wrong about the codebase. | Do not change `PLAN_BODY`. Record the rejection rationale in 1–2 sentences. |

Critical guardrails:

- **Never let Codex push the plan outside the user's stated scope.** A correct fix that adds features the user didn't ask for is `reject`, not `accept` — even if Codex's reasoning is technically sound. The original user intent is the north star.
- **Never weaken safety or correctness** to placate a `reject`-class concern. If Codex demands removing a verification step you correctly added, reject.
- **One `accept` may invalidate a later concern.** After each accept, re-check the remaining concerns against the current `PLAN_BODY` — if a later concern is about something you just changed, mark it `superseded` instead of acting on it.

### 2e. Loop guard

After triaging, increment `N` and check:

- If `MAX > 0` and `N > MAX`: terminate **without** appending a marker. Print:
  ```
  Hit CODEX_PLAN_REVIEW_MAX_ROUNDS=<MAX> without convergence. Either raise the cap
  and re-run /plan-guardian:codex-plan-review, or review the remaining concerns
  manually and decide whether to proceed.
  ```
- **Anti-thrash check**: if **two consecutive rounds produced zero edits** (every concern was `reject` or `superseded`) AND Codex still didn't emit `NO_CONCERNS`, you've hit a stable disagreement. Terminate **without** appending a marker, print the disagreement summary, and let the user decide.
- Otherwise: go back to 2a with the updated `PLAN_BODY`.

## Step 3 — Convergence: mint the marker

Codex returned `NO_CONCERNS`. Mint the review marker for the final `PLAN_BODY` via the plugin's shared helper, which uses the **exact digest the hook verifies with** (so mint and verify can never drift). Pipe the body in on stdin:

```bash
TOKEN="$(printf '%s' "<final PLAN_BODY, no trailing marker>" \
  | ${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-helper.sh digest)"
echo "$TOKEN"
```

`TOKEN` is `h1:<sha256 hex>` whenever a signing key is in effect (content-bound). The helper resolves the key in priority order (v1.5.1): `$CODEX_REVIEW_SECRET` if set, else a per-machine auto key file at `~/.claude/plan-guardian/secret` (generated on first use) — so the marker is content-bound **by default, no setup**. Only if no key can be established (unwritable HOME and no random source) does it return the literal `l1:none` (spoofable). The command and the hook both run this same helper, so they resolve the same key and agree.

Then build the final plan text by appending the marker as the **last line**:

```
<final PLAN_BODY>
<!-- codex-reviewed:<TOKEN> -->
```

(Exactly one newline between the body and the marker line. The hook strips the marker line and re-hashes the body; trailing-newline differences are normalized away on both sides by the shared helper.)

Print to the user, in Chinese:

```
✅ Codex plan review 已收敛(共 <N> 轮)。
   - 已在计划末尾追加审查标记:<!-- codex-reviewed:<TOKEN> -->
   - 现在重新调用 ExitPlanMode,传入“带标记的完整计划文本”,hook 会重算并放行。
   - 注意:标记绑定计划内容;一旦再修改计划正文,标记失效,ExitPlanMode 会被重新拦截。
```

Only in the rare literal-fallback case (token is `l1:none` — no key could be established), also note:

```
   - 提示:未能建立签名密钥(HOME 不可写且无随机源),标记退化为固定字面值(可被伪造)。
     设置 CODEX_REVIEW_SECRET,或修复 ~/.claude 可写性以启用自动密钥文件,即可内容绑定。
```

## Step 4 — Hand control back

Do **not** call `ExitPlanMode` yourself from this command. The caller decides when to exit plan mode — and when they do, they must pass the **marked** plan text (body + marker line) produced in Step 3, verbatim. The hook recomputes the token over the body, sees it match, and allows the call. Your job ends at minting the marker and reporting.

## Guardrails

- **Never append a marker unless Codex emitted `NO_CONCERNS` in the most recent round.** Round cap, stable disagreement, codex-exec failure, sandbox violation — none of these justify a marker. The marker is a *positive* signal from Codex, not a fallback.
- **Never modify any file.** v1.5.0 writes nothing during the loop. No round files, no sentinel, no plan file. Everything is in context until the marked plan goes back to `ExitPlanMode`.
- **Never run `codex exec` with `--sandbox workspace-write` or `danger-full-access`.** Read-only is correct because the loop is text-on-text.
- **Never paraphrase `NO_CONCERNS`.** "looks good", "approved", "好的没问题" are NOT `NO_CONCERNS` — re-prompt Codex with the strict-format reminder, or escalate to the user. The marker mint depends on the exact literal.
- **Never silently accept Codex concerns that contradict the user's original request.** Reject and document. The user is the final authority on scope.
- **Honor the env opt-out.** `CODEX_PLAN_REVIEW=0` disables this command entirely; the hook respects it too.

## Manual bypass

To skip the loop for a one-off (codex down, trivial plan), the user can mint a marker by hand using the same helper, then exit plan mode with the marked plan:

```bash
TOKEN="$(printf '%s' "$(cat ./.plan-review/yoplan-pending.md)" \
  | ${CLAUDE_PLUGIN_ROOT}/scripts/plan-review-helper.sh digest)"
# then append  <!-- codex-reviewed:$TOKEN -->  as the last line of the plan you submit
```

Document this if they ask how to skip — do not do it for them silently. (Whole-gate opt-out: `CODEX_PLAN_REVIEW=0`.)
