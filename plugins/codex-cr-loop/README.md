# codex-cr-loop

Three slash commands that wrap `/codex:review` (from the `openai-codex` plugin) into a **convergence loop**: iterate `/codex:review --wait`, fix every P0/P1/P2/P3 finding it returns, commit, re-run, and stop only when **two consecutive rounds** return no actionable findings.

The three commands share the entire review-loop body — P3 skip filter, file-family widening guard, **auto-widening sweep** (default ON, bounded by `CR_LOOP_MAX_WIDENING_SWEEPS`), optional opt-in round cap, head-drift detection, handoff file format — and differ only in what they do *after* convergence:

| Command | After convergence |
|---|---|
| `/cr-loop` | **Stops.** No push, no PR, no merge. The user takes whatever next action they want. |
| `/cr-loop-pr` | **Pushes** the feature branch to `${CR_PR_REMOTE:-origin}` and **opens a PR** against `${CR_PR_BASE:-main}` (or appends commits to an existing PR). Requires `gh` CLI authenticated. |
| `/cr-loop-merge` | **Merges** the feature branch into the local `${CR_MERGE_TARGET:-main}`. No push. Worktree-aware (handles target locked in another worktree by fast-forwarding via local refspec push when possible). |

## Requirements

- The [`openai-codex`](https://claude.com/claude-code/plugins) plugin must be installed (provides `/codex:review` and the `codex-companion.mjs` script the loop drives).
- `git` available; clean working tree before invocation (the loop will abort if dirty).
- The feature branch must be built on top of its base (rebased), or the loop stops at preflight and asks you to rebase first — see [Base-currency gate](#base-currency-gate-v150).
- For `/cr-loop-pr`: `gh` CLI installed and authenticated (`gh auth status`).

## Usage

```
/cr-loop                  # default base origin/<default branch>, converge and stop
/cr-loop-merge            # default base local <default branch>, converge and merge
/cr-loop-pr               # default base origin/<default branch>, converge, push, open PR
```

Pass an explicit base ref as the first argument when you want to review against something other than the default:

```
/cr-loop release/2026.05
/cr-loop-pr develop
```

The default base branch is **auto-detected** — `main`, `master`, or whatever your repo's default is — via a local ref read (`git symbolic-ref refs/remotes/origin/HEAD`, with a `main`→`master` probe fallback). No network, so it works out of the box on `master` repos and respects `/cr-loop-merge`'s no-remote contract. Override per repo with `CR_PR_BASE` / `CR_MERGE_TARGET` or the positional arg.

## Tunable knobs

All three commands honor:

- `CR_LOOP_ROUND_CAP=` — **opt-in** ceiling on rounds (unset by default → no cap). Set to a positive integer to bound the run.
- `CR_LOOP_WIDEN_AFTER=5` — consecutive-same-file-family rounds before the widening guard fires.
- `CR_LOOP_AUTO_WIDEN=1` — when `1` (default), the widening guard auto-escalates to a systematic root-cause sweep (one commit, pattern-level regression test) and resumes the loop instead of stopping. Set to `0` to restore the original "stop and hand off" behavior.
- `CR_LOOP_MAX_WIDENING_SWEEPS=2` — cap on automatic widening sweeps per invocation. After this many sweeps, the next widening trigger writes a `widening-sweeps-exhausted` handoff and stops.
- `CR_LOOP_SKIP_P3=1` — treat rounds with only P3 findings as clean.
- `CR_LOOP_REQUIRE_REBASED=1` — preflight hard-block (default ON) when the feature branch isn't built on top of its base. Set to `0` to skip the gate. See [Base-currency gate](#base-currency-gate-v150) below.

`/cr-loop-merge` adds:

- `CR_MERGE_TARGET=` (unset → auto-detected default branch), `CR_MERGE_FF=auto` — local merge configuration.

`/cr-loop-pr` adds:

- `CR_PR_BASE=` (unset → auto-detected default branch), `CR_PR_REMOTE=origin` — PR target.
- `CR_PR_DRAFT=0`, `CR_PR_TITLE=` — PR open options.

See each command file for the full procedure, guardrails, and handoff-file semantics.

## Why three commands instead of one with flags

Each command's contract is unambiguous: `/cr-loop-merge` will *never* push to remote; `/cr-loop-pr` will *always* end with a PR URL or a deferred handoff explaining why one wasn't created; `/cr-loop` will *never* touch any branch other than the one you started on. A single command with `--push` / `--pr` / `--merge` flags was rejected because the failure modes (push deferred, PR target moved, target locked in another worktree, gh unauthenticated) compound nontrivially and a flag-driven variant of one command would obscure which post-convergence step is actually authoritative.

## Base-currency gate (v1.5.0)

A review round that diffs against a base your branch hasn't caught up to wastes a (potentially 15-minute) loop and produces a PR/merge with a confusing diff or conflicts. So all three commands add a **preflight gate**: before the first review round, they check that the feature branch is built on top of its base.

```
git merge-base --is-ancestor "$BASE" HEAD
```

- **Exit 0** — base is fully contained in `HEAD`'s history (branch is current or ahead): the loop proceeds.
- **Exit 1** — base has commits `HEAD` lacks (branch is **stale** relative to base): the loop **does not start**. It confirms with the user — via the [`form-base`](../form-base/) MCP radio prompt when loaded, plain inline **A/B** otherwise — offering exactly two options:
  - **(A) Rebase first** — prints the exact `git rebase "$BASE"` + re-invocation, then stops. The loop **never rebases for you** (a history rewrite that may conflict is the user's call).
  - **(B) Abort** — stops immediately.

The gate is **intentionally hard**: there is no "review anyway" option, and "no response" is never treated as consent. Each command checks against **its own base**, so the contract is preserved:

| Command | Base checked | Rebase remedy | Remote touched |
|---|---|---|---|
| `/cr-loop` | `origin/<default branch>` (auto-detected, freshly fetched) | `git rebase "$BASE"` | fetch only |
| `/cr-loop-pr` | `${CR_PR_REMOTE:-origin}/$CR_PR_BASE` (auto-detected, freshly fetched) | `git rebase "$BASE"` | fetch only |
| `/cr-loop-merge` | local `$CR_MERGE_TARGET` (auto-detected) | `git rebase "$BASE"` | **none** |

For `/cr-loop-pr` this is distinct from step 8(e), which catches the remote base moving *during* the loop; the preflight gate catches a branch that *starts* stale.

Set `CR_LOOP_REQUIRE_REBASED=0` to skip the gate entirely — for deliberately reviewing against an older base, or a repo where the comparison doesn't apply.

## Interaction-logic guard (v1.3.0+)

User-visible interaction contracts — *which gesture triggers which response*, *which UI element receives a tap or long-press*, *dialog vs dropdown vs inline editor vs sheet*, *keyboard shortcuts*, *accessibility actions*, *navigation flow*, *default actions on Return / primary-button / outside-tap* — are sacred. Codex reviewers (and the agent's own root-cause analysis) routinely suggest "naturally cleaner" fixes that quietly change those contracts. The codex-cr-loop refuses to let those changes land silently.

When any fix — Codex finding or agent-inferred, single-finding or part of a widening sweep — would shift the visible action→response contract, the loop:

1. **Halts before the commit.** No fix is applied, no widening sweep advances, no merge / push / PR runs.
2. **Surfaces a structured prompt** with the current behavior, Codex's proposed change, and 2–3 alternative options that address the underlying finding while preserving or minimally changing the current UX (plus an explicit "skip / leave as-is" option).
3. **Prefers the [`form-base`](../form-base/) MCP** (yoyo's HTML interaction base) for the prompt — emitted as one radio question via `create_form` — so the user can compare options visually. Falls back to plain text A/B/C if `form-base` isn't loaded.
4. **Blocks on the user's reply.** "No response" is never treated as consent.
5. **Applies only the user-approved variant**, and records the decision in the commit body as `Interaction decision: <summary>` / `Original Codex finding: <Pn> ...` trailers, so the trail back to the original finding is auditable.

The guard is **always on** and has no env override — interaction contracts belong to the user, not the reviewer or the agent. Pure correctness fixes inside an event handler (the long-press still opens the same dialog, but a stale-state bug inside the handler is fixed) proceed normally; only changes that shift the visible contract trigger the guard. See each command file's **step 5a** for the full classification rules and **step 4d phase D** for how the guard composes with the automatic widening sweep.

## Business-impact summary (v1.4.0+)

The final report from each of the three commands **always** ends with a Chinese **Business-impact summary** module — designed for product / business stakeholders who don't read the diff but need to know whether the round shipped any user-visible change.

- **有业务可观测改动**(新增/调整功能、修复用户能察觉的 bug、调整默认值或配置语义、UI 交互变化、对外 API/事件契约、文案/状态机/异常返回): 输出 3–8 行中文。首行总览("本轮共改动 X 项业务能力"),后续按 commit 顺序逐条列出"动作 + 旧行为 → 新行为"。
- **全部为代码层重构**(rename / 抽函数 / 注释 / 补测试 / 内部解耦 / 行为等价的性能优化 / 实现替换但接口语义不变): 仅输出一行固定字面值 `无业务逻辑影响`。这一字符串是稳定锚点 —— 下游工具(发版机器人、回归测试调度、PR 模板填充)可据此识别"本轮无需业务回归"。
- **判断模糊时按"有业务改动"处理**: 漏报对产品方的代价 > 多写几行的代价。Codex 找到的 bug 修复要按"用户旧体验 → 新体验"的视角描述,不要复述代码层的 finding 文本。

`/cr-loop-pr` 把这套总结嵌入 PR 描述,人工 reviewer 可直接读;`/cr-loop-merge` 在本地 merge 之后输出,便于用户 push 前给出发版说明;`/cr-loop` 也始终输出,便于交给下一步工作流(PR、changelog、回归脚本)。

## Safety guarantees

- `--no-verify`, `--force`, `--force-with-lease` are forbidden in all three commands.
- Pre-commit / pre-push hook failures defer to the user with the hook output surfaced; the loop never bypasses them.
- The post-review HEAD-drift check refuses to classify any round whose HEAD moved during review (catches concurrent agents / auto-commit hooks).
- The **interaction-logic guard** (see section above) blocks any commit that would change user-visible interaction behavior until the user has explicitly chosen an option. No severity level can override it.
- All three commands write a `.cr-loop-handoff-round-<N>.md` file at the repo root on any non-converged exit, so a fresh session can resume exactly where the loop bailed. Handoffs are auto-cleaned on the next successful convergence.
