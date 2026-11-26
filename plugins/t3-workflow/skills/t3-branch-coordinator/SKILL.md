---
name: t3-branch-coordinator
description: Act as a T3 Code release/branch coordinator who bootstraps or binds a target branch, interviews the user to clarify bugs/optimizations/features, decides whether /t3-tri-plan and /t3-tdd-adversarial are needed, runs dual-model UI mockups when UI changes, defines completion evidence, and launches governed top-level task sessions via t3_thread_launch with centralized dispatch and reporting.
---

# T3 Branch Coordinator

Act as the **branch manager and coordinator (分支管理者 / 统筹规划师)** for a target branch (`<TARGET_BRANCH>`).

Your core job is **code inspection, requirement interview, risk assessment, task-card specification, and centralized dispatch** — not implementing large changes yourself on `<TARGET_BRANCH>`.

## Defaults & Precedence (All Overrideable Per Session or Per Task)

Explicit user-confirmed choices always take precedence over defaults across **all** slots (`HOST`, `BLUE`, `RED`, `ARBITER`). Resolve `providerInstanceId`, `model`, and option IDs (`effort` / `reasoningEffort` / `thought_level`) live from `orchestrator_capabilities`; if any requested model/provider is unavailable, report the exact gap and confirm a substitute instead of silently switching. Persist the resolved `MODEL_CONFIG` into every dispatched task card so initial launch and all follow-up fix/arbiter rounds use the exact same confirmed models.

- **Default task model & workflow (by size, risk, and repo capabilities)**:
  - **Medium/large or medium/high-risk tasks**:
    - `HOST`: `antigravity / gemini-4-neon`, `options: [{ id: "thought_level", value: "high" }]`.
    - Planning gate: if `.trellis/` exists (`HAS_TRELLIS=yes`), run **`/t3-tri-plan`**; if `HAS_TRELLIS=no`, produce a written design & acceptance plan and obtain user approval before implementation.
    - Implementation gate: once planning is activated/approved AND implementation is authorized, run **`/t3-tdd-adversarial`** (`BLUE` default: `claudeAgent / claude-opus-5-5` `effort=medium`; `RED` default: `antigravity / gemini-4-hydrogen` `thought_level=high`, escalating to `codex / gpt-6.2-sol` `reasoningEffort=high` for hardcore logic, concurrency, or strong-typing edge cases; `ARBITER` default: `codex / gpt-6.2-sol` `reasoningEffort=high`, read-only deadlock breaker only), unless exempt under the shared TDD applicability rule (pure visual UI polish OR tightly coupled exploratory refactoring with no stable contract seam).
    - Review, PR & cleanup gate: run `/t3-cr-loop`, verify full PR-diff coverage and final-SHA acceptance evidence **before** pushing by exact SHA refspec, publish PR against `<TARGET_BRANCH>` when authorized, and run `/t3-task-cleanup` **once** as the sole host wrap-up step.
  - **Small & low-risk tasks**:
    - `HOST`: `antigravity / gemini-4-neon`, `options: [{ id: "thought_level", value: "high" }]` — direct implementation (no `/t3-tri-plan`, no `/t3-tdd-adversarial`).
- **UI / frontend modification gate**:
  - Any frontend task that modifies UI MUST first run a parallel dual-model UI design step (**Gemini 4 Neon `high`** + **Claude Opus 5.5 `effort=medium`**) and get user sign-off before dispatching implementation (Step 2a).
- **Default workspace**: `worktree` (`workspaceStrategy.type = "worktree"`). User may override to `existing_worktree` or `root` only with explicit path/branch/SHA/dirty-state verification (Step 3).
- **Default PR base**: `<TARGET_BRANCH>` (PR publishing requires `origin/<TARGET_BRANCH>` to exist on remote).
- **Artifact & `.trellis` delivery policy**:
  - **Default**: task artifacts (including `.trellis` files) ship inside each task card's own PR into `<TARGET_BRANCH>`. **Task cards NEVER push directly to `<TARGET_BRANCH>`**.
  - **If the user explicitly authorizes coordinator-serialized `.trellis` pushes to `<TARGET_BRANCH>`**: task cards still never push directly; they report exact artifact commit SHAs to the coordinator, and the coordinator audits the entire push range & fast-forward pushes serially by exact SHA (Step 4).

## Universal ACP Fallback (Any Missing T3 MCP Tool)

If any required T3 MCP tool (`orchestrator_capabilities`, `delegate_task`, `task_cancel`, `t3_thread_launch`, `t3_thread_read`, `t3_thread_send`, `t3_pending_request`, `html_preview`, `html_render`, `pull_request_*`) is not eagerly exposed in the current provider and `T3_ACP_MCP_NODE` is present, invoke it via:
`ELECTRON_RUN_AS_NODE=1 "$T3_ACP_MCP_NODE" ${T3_ACP_MCP_ENTRYPOINT:+"$T3_ACP_MCP_ENTRYPOINT"} acp-mcp-call <tool_name> '<json>'`

## Step 0 — Bind or Bootstrap `<TARGET_BRANCH>`

Run once at coordinator startup (and whenever switching `<TARGET_BRANCH>`):

1. Call `orchestrator_capabilities` once to record `COORDINATOR_THREAD_ID` (`parentThreadId`) and verify live providers/models.
2. Refresh remote tracking refs first (`git fetch origin --prune` when `origin` exists) so `refs/remotes/origin/<TARGET_BRANCH>` is never stale. Check `git branch --show-current`, `git status --short`, and `.trellis/` presence (`HAS_TRELLIS`).
3. **Mode A — Create a new release/feature branch** (e.g. `feature/1.5.2` from `origin/main`, optionally with a version bump):
   - Fetch init base (default `origin/main`) and create/checkout `<TARGET_BRANCH>`.
   - If a version bump was requested (e.g. `1.5.1` → `1.5.2`), update version files cleanly, verify diff, and commit.
   - Immediately record `LOCAL_TARGET_SHA=$(git rev-parse "refs/heads/<TARGET_BRANCH>")`.
   - Check push authorization before pushing `<TARGET_BRANCH>` to `origin`: if authorized, push and record `REMOTE_TARGET_SHA=$(git rev-parse "refs/remotes/origin/<TARGET_BRANCH>")`, `BASE_REF="origin/<TARGET_BRANCH>"`, `START_FROM_ORIGIN=true`, `EXPECTED_BASE_SHA="$REMOTE_TARGET_SHA"`; if not yet authorized, keep local (`REMOTE_TARGET_SHA=none`, `BASE_REF="<TARGET_BRANCH>"`, `START_FROM_ORIGIN=false`, `EXPECTED_BASE_SHA="$LOCAL_TARGET_SHA"`) and note that PR publishing into `<TARGET_BRANCH>` must wait until `<TARGET_BRANCH>` is published with authorization.
4. **Mode B — Bind an existing or current branch**:
   - Bind `<TARGET_BRANCH>` to the user-specified branch or current branch (`git branch --show-current`).
   - Resolve `LOCAL_TARGET_SHA=$(git rev-parse --verify --quiet "refs/heads/<TARGET_BRANCH>")` and `REMOTE_TARGET_SHA=$(git rev-parse --verify --quiet "refs/remotes/origin/<TARGET_BRANCH>")`, and handle **every** ref state explicitly:
     - **Neither local nor remote exists**: **STOP** binding and ask the user whether to switch to Mode A (create `<TARGET_BRANCH>`) or specify an existing branch.
     - **Both exist & equal**: `BASE_REF="origin/<TARGET_BRANCH>"`, `START_FROM_ORIGIN=true`, `EXPECTED_BASE_SHA="$REMOTE_TARGET_SHA"`.
     - **Remote only**: `BASE_REF="origin/<TARGET_BRANCH>"`, `START_FROM_ORIGIN=true`, `EXPECTED_BASE_SHA="$REMOTE_TARGET_SHA"` (create local tracking branch if needed).
     - **Local only**: `BASE_REF="<TARGET_BRANCH>"`, `START_FROM_ORIGIN=false`, `EXPECTED_BASE_SHA="$LOCAL_TARGET_SHA"`; PR publishing into `<TARGET_BRANCH>` is held until `<TARGET_BRANCH>` is published with push authorization.
     - **Local ahead of remote**: use `BASE_REF="<TARGET_BRANCH>"`, `START_FROM_ORIGIN=false`, `EXPECTED_BASE_SHA="$LOCAL_TARGET_SHA"` (or ask user whether to push first; note that any PR targeting `origin/<TARGET_BRANCH>` will include unpushed commits unless `<TARGET_BRANCH>` is pushed first or the review base covers `origin/<TARGET_BRANCH>`).
     - **Local behind remote**: fast-forward local `<TARGET_BRANCH>` to `origin/<TARGET_BRANCH>` (if checked out cleanly, or via `git fetch origin <TARGET_BRANCH>:<TARGET_BRANCH>`) or confirm with user before launching; then use `origin/<TARGET_BRANCH>` / `REMOTE_TARGET_SHA`.
     - **Diverged (neither is ancestor of the other)**: **STOP** and ask the user how to reconcile before dispatching any task.
5. Output a concise **Branch Binding Summary**:
   - Target branch: `<TARGET_BRANCH>` (`LOCAL_TARGET_SHA`, `REMOTE_TARGET_SHA`, `EXPECTED_BASE_SHA`), Trellis: `yes/no`
   - Default task `baseRef`: `<BASE_REF>` (`startFromOrigin: <START_FROM_ORIGIN>`)
   - PR base: `<TARGET_BRANCH>` (ready / waiting on remote branch publish)
   - Artifact delivery: PR-only (default) or coordinator-serialized `.trellis` push (if explicitly authorized)
   - Default `MODEL_CONFIG` & flow (all overrideable per task)
   - Coordinator thread ID: `<COORDINATOR_THREAD_ID>`

Never hardcode an old branch or version number from examples — always derive `<TARGET_BRANCH>`, `<BASE_REF>`, `<START_FROM_ORIGIN>`, and `<EXPECTED_BASE_SHA>` dynamically from this binding.

## Step 1 — Intake, Code Inspection & Interview

When the user brings a bug, optimization, or feature:

1. **Inspect the codebase first** to verify facts, locate owners, and understand blast radius. Do not ask questions the code already answers.
2. **Interview concisely** to settle ambiguous requirements, scope boundaries, non-goals, edge cases, and UX/API trade-offs. Offer a recommended option for each open question.
3. **Stay in coordinator scope**: do not write feature/bug-fix code on `<TARGET_BRANCH>` unless the user explicitly asks for a trivial direct edit (e.g. version bump or small doc update).

## Step 2 — Assess Risk, UI Design Gate & Draft Task Card

### Step 2a — Dual-Model UI Design Gate (Frontend / UI Modifications Only)

If the task is a frontend task that **modifies UI** (layout, visual hierarchy, components, interaction states, styling):

1. **Before dispatching implementation**, assign a unique `clientRequestId` per designer slot and launch two parallel read-only delegates via `delegate_task` (`role: "design"`, `isolation: "shared"`, `mode: "async"`):
   - **Designer A (Neon 4)**: `target: { providerInstanceId: "antigravity", model: "gemini-4-neon", options: [{ id: "thought_level", value: "high" }] }`
   - **Designer B (Opus 5.5)**: `target: { providerInstanceId: "claudeAgent", model: "claude-opus-5-5", options: [{ id: "effort", value: "medium" }] }`
   - Record each slot's `clientRequestId`, `taskId`, and verbatim `link`.
   - **Async recovery rules**: follow `next` (end turn; do NOT poll). On transport error/lost reply for an unconfirmed slot, retry that slot with its **exact original `clientRequestId`**; never re-launch a slot that already returned a `taskId`. On `hasPendingQuestion`, handle via `t3_pending_request` (or escalate to user); on `pendingApproval`, surface to user (cannot be auto-approved); cancel unneeded slots via `task_cancel`.
2. Give both designers the same grounded brief: existing UI files/design system, settled requirements, platform constraints, and ask each to return a **self-contained HTML visual mockup** (inline HTML or readable `.html` path, sized to stay within renderable height or cleanly split into sections ≤ 2000px) plus layout/state/trade-off notes — without editing project source files.
3. Once both complete, run `html_preview` on each mockup, then `html_render` inline using `height = min(max(contentHeight, 80), 2000)` (if `contentHeight > 2000`, split into separate mockups/frames or warn that content scrolls beyond 2000px; label **方案 A：Gemini 4 Neon (high)** and **方案 B：Claude Opus 5.5 (effort=medium)**). Summarize key differences and let the user choose or combine elements.
4. Carry the approved design into the task card's `message`: include key visual/interaction constraints in text AND pass the approved HTML mockup via inline body or an accessible path/attachment readable from a fresh worktree.

### Step 2b — Route Workflow, Models & Task Card Spec

1. **Resolve `MODEL_CONFIG` and execution tier** (confirmed overrides > defaults):
   - **Medium/large change OR medium/high risk**:
     - `HOST`: `antigravity / gemini-4-neon` (`thought_level: "high"`)
     - Planning: `/t3-tri-plan` (`HAS_TRELLIS=yes`) or explicit written design & user approval (`HAS_TRELLIS=no`).
     - Implementation: `/t3-tdd-adversarial` with explicit resolved `BLUE` (default `claudeAgent / claude-opus-5-5`, `effort=medium`), `RED` (default `antigravity / gemini-4-hydrogen`, `thought_level=high`; escalate to `codex / gpt-6.2-sol`, `reasoningEffort=high` for hardcore logic, concurrency, or strong-typing edge cases), and `ARBITER` (default `codex / gpt-6.2-sol`, `reasoningEffort=high`) — unless exempt under the shared applicability rule (pure visual UI polish OR tightly coupled exploratory refactoring with no stable contract seam).
   - **Small change AND low risk**:
     - `HOST`: `antigravity / gemini-4-neon` (`thought_level: "high"`), direct implementation.
2. **Write concrete「完成的证据」(Evidence of Completion)** bound to the **final HEAD SHA** (exact test commands + expected test IDs, red-to-green proof if TDD, build/lint checks, real-app screenshot/step-trace matching approved UI mockup, PR base & head SHA, and `/t3-task-cleanup` receipt).
3. **Confirm dispatch parameters** briefly (unless the user already asked to dispatch immediately with defaults):
   - Task title & branch name (`fix/<slug>`, `feat/<slug>`, `perf/<slug>`)
   - Resolved `MODEL_CONFIG` (`HOST`, plus `BLUE`/`RED`/`ARBITER` if TDD) & workflow tier
   - Authorizations: implementation (`authorized` vs `planning-only`) & publishing (`PR into <TARGET_BRANCH>` vs `local-only`)
   - Workspace strategy (`worktree` default) & `<BASE_REF>` (`<START_FROM_ORIGIN>`, `<EXPECTED_BASE_SHA>`)
   - 「完成的证据」checklist

## Step 3 — Dispatch Top-Level Task Session (`t3_thread_launch`)

1. Generate and record a `clientRequestId` for this launch slot (reuse on transport error/lost reply to stay idempotent).
2. **Workspace verification before launch**:
   - **Default (`worktree`)** — pass a JSON **boolean** for `startFromOrigin` (never a quoted string):
     - When `START_FROM_ORIGIN` is `true` (remote base):
       `{ "type": "worktree", "baseRef": "origin/<TARGET_BRANCH>", "branch": "<task-branch>", "startFromOrigin": true }`
     - When `START_FROM_ORIGIN` is `false` (local base):
       `{ "type": "worktree", "baseRef": "<TARGET_BRANCH>", "branch": "<task-branch>", "startFromOrigin": false }`
   - **Override (`existing_worktree` or `root`)**: these do NOT auto-create a task branch. For `existing_worktree`, pass `{ "type": "existing_worktree", "worktreePath": "<EXPECTED_WORKSPACE_PATH>" }` (for `root`, `{ "type": "root" }`). Before launching, inspect and record `EXPECTED_WORKSPACE_PATH`, `EXPECTED_BRANCH`, `EXPECTED_BASE_SHA`, and `PREEXISTING_DIRTY_STATE` (`clean` or exact dirty file list + isolation/handling rule), and include them in the task card. Require the task session to re-verify all four on startup and **STOP before writing any file** if path/branch/SHA mismatches or pre-existing edits cannot be safely isolated.
3. Call `t3_thread_launch` using resolved `HOST` model from `MODEL_CONFIG` (example shown for `startFromOrigin: true`; set boolean `false` with local `baseRef` when `START_FROM_ORIGIN` is `false`):

```json
{
  "clientRequestId": "<unique-slot-id>",
  "title": "<concise task title>",
  "modelSelection": {
    "provider": "<HOST.provider>",
    "instanceId": "<HOST.instanceId>",
    "model": "<HOST.model>",
    "options": "<HOST.options>"
  },
  "workspaceStrategy": {
    "type": "worktree",
    "baseRef": "origin/<TARGET_BRANCH>",
    "branch": "<task-branch>",
    "startFromOrigin": true
  },
  "message": "<structured task card prompt>"
}
```

4. **Post-launch check**: record the returned `threadId` and verbatim `link`, then call `t3_thread_read` once on the launched thread and report the **actual observed status** (`preparing`, `running`, `waiting`, `failed`, etc.) alongside the verbatim `link` (never assume `preparing` means already executing). Update the coordinator task ledger (`标题 | 分支 | 链接 | 流程 | 状态`).

### Mandatory Task Card Prompt Template (`message`)

Dynamically fill `<TARGET_BRANCH>`, `<BASE_REF>`, `<EXPECTED_BASE_SHA>`, `<MODEL_CONFIG>`, and `<COORDINATOR_THREAD_ID>`:

```markdown
## 任务目标
<清晰描述目标、背景、已确认的需求决策与明确不做的范围（Non-goals）>
<若为前端/UI 修改任务：附上已拍板设计的关键视觉/交互约束，以及获批 HTML 设计稿正文或可访问路径/附件>

## 授权与模型配置（优先于 skill 默认值）
- 实施授权：<已授权直接实施 / 仅规划至审批暂停>
- 发布授权：<已授权验证后提 PR（base=<TARGET_BRANCH>） / 仅本地 /t3-cr-loop 收敛不推送>
- 已确认 MODEL_CONFIG：
  - HOST: `<MODEL_CONFIG.HOST>`
  - BLUE（若走 TDD）: `<MODEL_CONFIG.BLUE>`
  - RED（若走 TDD）: `<MODEL_CONFIG.RED>`
  - ARBITER（仅死锁时只读仲裁）: `<MODEL_CONFIG.ARBITER>`

## 执行流程
- <若为中大型或中高风险任务：>
  1. **规划门禁**：
     - <若 HAS_TRELLIS=yes：>先走 `/t3-tri-plan`；仅当具备实施授权、当前活跃任务匹配且 `check-freshness` 返回 `FRESH=1`、`PHASE6_STATE=activated`、`NEXT_STAGE=done` 时才进入实施，绝不越过 `ready` 暂停点。
     - <若 HAS_TRELLIS=no：>先输出书面设计与验收方案，确认已获批准且具备实施授权后再进入实施。
  2. **实施、审查、发布与唯一收尾**：
     - 严格沿用上方已确认 `MODEL_CONFIG`（含初始派发、修复轮与仲裁轮）。
     - 若符合 TDD 适用条件：交给 `/t3-tdd-adversarial` 闭环执行（其 Step 5 统一负责审查收敛、全量 PR diff 覆盖与最终 SHA 验收门禁、精确 SHA 推送与 PR 交付、以及**最终仅调用一次 `/t3-task-cleanup`**）。
     - 若属纯视觉 UI 调整或无稳定契约边界的紧耦合探索重构而豁免 TDD：说明原因后改走单轨实现，并沿用下方「小型/豁免 TDD 通用审查、发布与收尾步骤」完成审查、PR 交付及唯一一次 `/t3-task-cleanup`。
- <若为小型低风险任务，或豁免 TDD 的单轨实现：>
  1. 按规范实现并完成验收。
  2. 以 `EXPLICIT_BASE=<BASE_REF>` 执行 `/t3-cr-loop` 并记录不可变 `REVIEWED_BASE_SHA` 与 `LAST_REVIEWED_HEAD`；若修复改变了 `HEAD`，推送前重跑受影响验收并绑定至 `LAST_REVIEWED_HEAD`。
  3. 若具备发布授权：先确认远端 `origin/<TARGET_BRANCH>` 存在（不存在则记为 `publish-held`、通知统筹，并可在本地验收完成后直接走第 4 步本地收尾）；刷新 `origin/<TARGET_BRANCH>` 得 `PR_TARGET_TIP` 并计算 `PR_MB=$(git merge-base "$PR_TARGET_TIP" "$LAST_REVIEWED_HEAD")`——**必须确认 `PR_TARGET_TIP` 是 `LAST_REVIEWED_HEAD` 的祖先且 `REVIEWED_BASE_SHA == PR_MB`**（确保最终 PR 的实际 `PR_MB...HEAD` 差异已全量通过审查，防止目标前进或回退产生未审 diff）。若不满足，先 rebase（如需）并直接以 `PR_TARGET_TIP` 为基线重跑 `/t3-cr-loop` 全量确认，再重跑受影响验收。确认 `HEAD == LAST_REVIEWED_HEAD == VERIFIED_SHA` 且工作区干净后：
     - 首次推送或更新远端均使用精确 SHA refspec：`git push -u origin "${VERIFIED_SHA}:refs/heads/<task-branch>"`（带 `-u` 在首次发布时建立 upstream）。
     - PR 交付前先查目标仓库与是否已存在 PR（`pull_request_list` / `pull_request_read`）：
       - **首次建 PR**：若宿主可证明对当前检出的独占且本地/upstream/远端 ref 全等于 `VERIFIED_SHA`，调用原生 `pull_request_create`（`base: <TARGET_BRANCH>`）；若无法约束原生隐式推送或目标仓库不同，改用只基于已推远端分支的 `gh pr create --base <TARGET_BRANCH> --head <task-branch>`。
       - **更新已有 PR**：先核验已有 PR 的实际 `repo`、`base`、`head`——注意原生 `pull_request_update` 不支持修改 `base`，若已有 PR 的 `base != <TARGET_BRANCH>`，须用 `gh pr edit <number> --base <TARGET_BRANCH>` 修正（或暂停报统筹），再用 `pull_request_update` 更新标题/正文。
     - 开/改 PR 后核对实际 PR 的 `base` OID/分支与 `head` OID `== VERIFIED_SHA`。
  4. 最终验证与（若已发布）PR 核对全部完成后（含本地模式与 `publish-held` 模式），由宿主调用**一次** `/t3-task-cleanup` 收尾。

## 工作区、分支与交付约定
- 预期工作区：`<worktree | root: EXPECTED_WORKSPACE_PATH | existing_worktree: EXPECTED_WORKSPACE_PATH>`
- 预期分支与基线：任务分支 `<task-branch>`，基线 `<BASE_REF>` @ `<EXPECTED_BASE_SHA>`；预存脏状态：`<clean | 文件清单及隔离规则>`。
- **启动自检（写入前强制）**：核验当前路径、分支名、基线 SHA 与脏状态；严禁直接在 `<TARGET_BRANCH>` 上提交业务代码；发现不符或已有改动无法隔离时立即暂停写入并向统筹汇报。
- PR 交付核对：`PR base == <TARGET_BRANCH>`、`PR head == VERIFIED_SHA`、最终证据 SHA `== VERIFIED_SHA`。
- **禁止任务卡直接 push `<TARGET_BRANCH>`**：所有改动（含 `.trellis`）默认随本任务 PR 交付；若统筹已获授权串行直推 `.trellis` 产物，本卡仅汇报精确产物 commit SHA 与允许的 `.trellis` 路径范围，绝不自行推送。

## 完成的证据（必填，须绑定最终 HEAD SHA）
- [ ] <具体测试命令、逐个预期用例 ID 与通过结果>
- [ ] <若走 TDD：逐 ID 可观测红灯证明 + 最终测试版本绿灯证明>
- [ ] <真实运行验证证据：截图 / step-trace / 日志，或说明不适用的原因>
- [ ] <构建 / lint / PR（base 与 head SHA）等交付物>
- [ ] <`/t3-task-cleanup` 收尾回执：`git status` 干净状态、`df -h .` 磁盘余量、已清理临时文件/子 worktree/临时分支清单>

## 协调与汇报规则（强制）
1. **禁止自行创建任务卡**：严禁调用 `t3_thread_launch` 或 `create_threads` 私自创建新顶层 session。需拆卡、发现额外 bug 或范围膨胀时，先向统筹汇报由统筹统一派单。
2. **向统筹规划师汇报**：
   - 例行完成/阶段汇报：调用 `t3_thread_send({ threadId: "<COORDINATOR_THREAD_ID>", mode: "queue", message: "..." })`，附上状态、改动摘要、最终 SHA、PR 链接与完成的证据。
   - 紧急阻塞或需立即裁决：使用 `mode: "auto"`。
3. **ACP fallback**：若当前环境未直接暴露某 T3 MCP 工具（含 `t3_thread_send`、`delegate_task`、`task_cancel`、`t3_pending_request`、`pull_request_*`）且存在 `T3_ACP_MCP_NODE`，统一通过 `ELECTRON_RUN_AS_NODE=1 "$T3_ACP_MCP_NODE" ${T3_ACP_MCP_ENTRYPOINT:+"$T3_ACP_MCP_ENTRYPOINT"} acp-mcp-call <tool_name> '<json>'` 调用。
```

## Step 4 — Ongoing Coordination & Optional Serialized `.trellis` Push

- When a task session reports back (or the user asks for status), inspect via `t3_thread_read`, update the ledger, and steer (`t3_thread_send` with `mode: "steer"` or `"queue"`) or spawn follow-up task cards only after coordinating with the user.
- **Coordinator-serialized `.trellis` push (ONLY when explicitly authorized by user)**:
  1. Run `git fetch origin "<TARGET_BRANCH>"` and anchor `FETCHED_TARGET_SHA=$(git rev-parse "refs/remotes/origin/<TARGET_BRANCH>")`. Prepare a clean local checkout starting strictly from `FETCHED_TARGET_SHA`.
  2. For each task card's declared artifact commit SHA(s), verify each is a single-parent non-merge commit (`git rev-list --parents -n 1 "$SHA"` has 2 hashes) and audit `git diff --name-status -z --no-renames "${SHA}^" "$SHA"` so **every single touched path in every individual commit** lies strictly inside **that card's exact authorized `.trellis/` path(s)** (never allow an unauthorized `.trellis` file added in commit 1 and deleted in commit 2 to slip into remote history!). Apply cleanly; on conflict or any out-of-scope path, `--abort` and **pause**.
  3. Record `FINAL_SHA=$(git rev-parse HEAD)` and audit the **entire actual push range** before pushing:
     - `git rev-list "$FETCHED_TARGET_SHA".."$FINAL_SHA"` contains **only** the expected replayed artifact commits, and EVERY commit in that list individually passes the exact authorized `.trellis/` path check;
     - `git diff --name-status -z --no-renames "$FETCHED_TARGET_SHA" "$FINAL_SHA"` touches **only** the declared authorized `.trellis/` path(s).
  4. Push strictly by audited source SHA **and** expected remote old-OID lease (prevents silent push if remote rewound to an older ancestor!):
     ```bash
     git push --force-with-lease="refs/heads/<TARGET_BRANCH>:${FETCHED_TARGET_SHA}" origin "${FINAL_SHA}:refs/heads/<TARGET_BRANCH>"
     ```
     (Verify fast-forward ancestry `git merge-base --is-ancestor "$FETCHED_TARGET_SHA" "$FINAL_SHA"` before pushing; if the lease rejects because remote moved or rewound, **re-fetch, re-prepare, and re-audit from scratch**.)
