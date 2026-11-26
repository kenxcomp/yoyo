---
name: t3-tdd-adversarial
description: Run a contract-first, process-isolated Red/Blue adversarial TDD workflow in T3 Code. The host thread verifies planning activation, commits a compilable hard contract with observable non-crashing stubs, delegates implementation (Blue) and spec-only tests (Red) in parallel worktrees, enforces audited net-patch allowlist gates, verifies per-ID red-to-green proof, triages failures serially, and hands off clean green code to /t3-cr-loop with pre-push SHA verification.
---

# T3 Adversarial TDD (`t3-tdd-adversarial`)

Execute **Contract-First Red/Blue Adversarial TDD** inside a task session (typically an `antigravity / gemini-4-neon` `thought_level=high` top-level session after planning activation / approval).

## Role, `MODEL_CONFIG` & Override Precedence

Call `orchestrator_capabilities` once in the thread if not already called. **Explicit user- or task-card-specified models always override defaults across ALL roles.** Resolve `providerInstanceId`, `model`, and option IDs live; if any requested model/provider is unavailable, report the gap and confirm a substitute instead of silently switching.

Record the resolved **`MODEL_CONFIG`** once at startup and reuse the **exact same configuration** across Step 2 initial dispatch, every Step 4 fix round, and any Step 4 Arbiter invocation:
- **`HOST`** (this thread): default `antigravity / gemini-4-neon`, `options: [{ id: "thought_level", value: "high" }]`.
- **`BLUE`** (Implementation): default `claudeAgent / claude-opus-5-5`, `options: [{ id: "effort", value: "medium" }]`.
- **`RED`** (Spec-Only Adversarial Tests): default `antigravity / gemini-4-hydrogen`, `options: [{ id: "thought_level", value: "high" }]`.
  - Escalation rule (only when `RED` was not already locked by user/task card): for **hardcore domain logic, concurrency/state machines, strong-typing edge-case deduction, or strict invariants**, use `codex / gpt-6.2-sol`, `options: [{ id: "reasoningEffort", value: "high" }]`.
- **`ARBITER`** (Read-Only Deadlock Breaker Only): default `codex / gpt-6.2-sol`, `options: [{ id: "reasoningEffort", value: "high" }]`.
  - Do **NOT** run a generic pre-merge code review (full review happens in Step 5). Only invoke `MODEL_CONFIG.ARBITER` (`role: "review"`, `isolation: "shared"`, read-only) if Step 4 deadlocks after 2 failed logic-fix rounds.

## Universal ACP Fallback

If any required T3 MCP tool (`orchestrator_capabilities`, `delegate_task`, `task_cancel`, `task_status`, `t3_thread_send`, `t3_thread_read`, `t3_pending_request`, `pull_request_*`) is not eagerly exposed and `T3_ACP_MCP_NODE` is present, invoke it via:
`ELECTRON_RUN_AS_NODE=1 "$T3_ACP_MCP_NODE" ${T3_ACP_MCP_ENTRYPOINT:+"$T3_ACP_MCP_ENTRYPOINT"} acp-mcp-call <tool_name> '<json>'`

## Applicability & Preconditions (Mandatory Before Any Edit)

### 1. Applicability Check (Shared Escape Hatch)
Fits tasks with a **clear contract seam** (domain logic, state machines, parsers, persistence/sync, APIs, migrations, algorithms).

If the approved design is **purely visual UI polish / layout / animation** OR **tightly coupled exploratory refactoring with no stable contract seam**, document the reason explicitly and fall back to single-track implementation rather than forcing artificial stubs.

### 2. Planning & Implementation Authorization Gate (All Entry Paths)
**Every** entry path MUST first confirm explicit **implementation authorization** (never start coding if the session is planning-only or waiting on user approval):
1. **Trellis repo + `/t3-tri-plan` task**:
   - Confirm active task identity matches `<TASK>` (via `task.py current --json` / task card).
   - Run `check-freshness` and verify **all three** fields pass: `FRESH=1`, `PHASE6_STATE=activated`, AND `NEXT_STAGE=done` (exit code `0` alone is insufficient when `NEXT_STAGE=phase6`). Record `<TASK>` and the approved design revision.
   - Load `<TASK>/design.md`, `<TASK>/implement.md`, `<TASK>/implement.jsonl`, and `<TASK>/check.jsonl` to forward applicable specs/acceptance items to Blue and Red; host retains remaining checklist items (e.g. `REVIEW.md` codification).
2. **Trellis repo + direct TDD invocation (no `/t3-tri-plan`)**:
   - Confirm explicit implementation authorization AND a user-approved active Trellis task plan (`prd.md` / `design.md` / acceptance criteria loaded).
3. **Non-Trellis repo**:
   - Confirm explicit implementation authorization AND a user-approved written design & acceptance specification before Step 1.

---

## Step 1 — Clean Pre-Check, Compilable Hard Contract + Observable Stubs + Ownership Map

Before writing any contract or stub file, on the verified task branch (never directly on `<TARGET_BRANCH>`):

1. **Pre-Step-1 working-tree & index hygiene check**:
   - Run `git status --porcelain=v1 --untracked-files=all --ignore-submodules=none` to inspect unstaged, untracked, submodule, and **already-staged** files.
   - Preserve any pre-existing user changes (never let `git commit -m` sweep in unrelated staged items).
   - If authorized planning artifacts (e.g. `.trellis/` files from `/t3-tri-plan`) are uncommitted, commit them cleanly in their own dedicated planning commit **first** so the working tree and index are completely clean before writing stubs.
2. **Define the hard contract**: types/protocols/interfaces, public function signatures, API routes, error codes, and behavioral invariants derived from the approved design.
3. **Add compilable, non-crashing observable stubs & shared wiring**:
   - Stubs MUST compile cleanly and fail **observably** via catchable typed errors or sentinel/placeholder return values (e.g. `throw StubError.unimplemented`, `return .failure(...)`, `throw new NotImplementedError(...)`). **Never use process-crashing stubs** like Swift `fatalError(...)` that terminate the test host before assertions run.
   - Pre-create target implementation file(s), target test file(s), and **all shared build/manifest/wiring changes** (`project.yml`, `package.json`, barrel exports, DI registration, route tables). Where a manifest generates project files (e.g. Kenotex `project.yml` → `project.pbxproj`), run the generator (`xcodegen generate`) and never hand-edit generated files.
   - Keep the stub implementations clean and self-contained so a **final contract-stub baseline** can always be rebuilt in Step 5.2 if contract or shared wiring evolves later.
4. **Verify the contract baseline compiles** (fast build/typecheck, respecting all repo build/test-runner lock rules).
5. **Stage ONLY the explicit contract/stub/manifest files**, commit (`git commit -m "chore: define contract and stubs for <task>"`), verify `git status --porcelain=v1 --untracked-files=all --ignore-submodules=none` is **completely empty**, and record:
   - `CONTRACT_SHA=$(git rev-parse HEAD)`
   - `PRE_MERGE_HEAD=$CONTRACT_SHA`
   - `HOST_COMMON_DIR=$(git rev-parse --git-common-dir)`
6. Define a strict **Pairwise-Disjoint Allowlist Ownership Map**:
   - **Host-only frozen paths** (read-only for Blue and Red): contract/interface files, shared manifests (`project.yml`, `package.json`, generated project files, lockfiles, DI/route registries).
   - **Blue allowlist**: explicit file paths/globs for implementation files ONLY.
   - **Red allowlist**: explicit file paths/globs for test files (and test-only fixtures under test directories) ONLY.

> **Shared-manifest evolution & multi-generation slot rule**: if Blue or Red discovers a required manifest/dependency/new-target change mid-flight, they MUST NOT edit frozen files — they stop and report it to the host. When host updates the shared manifest on a new baseline `CONTRACT_SHA_NEW`:
> - Cancel every obsolete running slot via `task_cancel`, and **confirm each cancelled delegate reaches terminal state** (not merely `cancel_requested`) before launching replacement slots.
> - Record EVERY generation in the Merge State Record (`generation`, `taskId`, `childThreadId`, `worktreePath`, `branch`, `headSha`, and explicit `disposition`: `ported`, `approved-discard`, or `retain`).
> - For any already-finished prior-generation slot, either re-dispatch from `CONTRACT_SHA_NEW` (marking prior slot `approved-discard` or `retain`) OR explicitly port its audited net patch onto `CONTRACT_SHA_NEW` (`ported`) and re-run the full allowlist + compilation/Red-light audit before merging.

> **Repository runner & concurrency lock rule (ALL participants)**: Host, Blue, AND Red MUST all obey repository build/test-runner isolation and lock rules (e.g. Kenotex `run-tests.sh` concurrency locks and session-created isolated simulators).

---

## Step 2 — Parallel Red/Blue Delegation (`isolation: "worktree"`)

Generate and record a unique `clientRequestId` per slot before calling `delegate_task`, then launch **both** delegates in parallel (`isolation: "worktree"`, `mode: "async"`). Record each slot's `generation`, `clientRequestId`, `taskId`, `childThreadId`, and verbatim `link`.

> **Isolation boundary disclosure**: same-machine `delegate_task(isolation: "worktree")` creates separate local worktrees branched from `CONTRACT_SHA` that share Git objects/refs and local filesystem permissions. Blindness here is a **process constraint**, not OS sandboxing: both briefs MUST explicitly instruct each side to read ONLY its own worktree and frozen/brief materials, and never inspect sibling worktrees, sibling refs, or the other team's output before delivery. (Hard-enforced blindness requires verified OS/container isolation outside standard local `delegate_task`.)

### Blue Team Brief (`role: "implementation"`)
- **Model**: `MODEL_CONFIG.BLUE`.
- **Context**: locked design + applicable specs/acceptance items (`implement.md` / `implement.jsonl`) + `CONTRACT_SHA`.
- **Rules**:
  - Implement full business logic strictly against `CONTRACT_SHA`.
  - **Writable allowlist**: Blue allowlist paths ONLY. Never touch frozen files or test files.
  - **Blindness rule**: read only your own worktree and provided spec/contract; never inspect sibling worktrees or refs.
  - Obey repo build/test-runner lock rules, verify compilation, commit all changes with a clean working tree, and return: `worktreePath`, `branch`, `headSha`, `changedFiles`, and implementation summary.

### Red Team Brief (`role: "test"`)
- **Model**: `MODEL_CONFIG.RED`.
- **Context**: locked design + applicable specs/acceptance items (`implement.md` / `check.jsonl`) + `CONTRACT_SHA`.
- **Rules**:
  - Write unit/integration tests from contract + requirements ONLY (happy paths, boundaries, error paths, idempotency, state invariants) with **explicit, stable test IDs** for every required scenario.
  - **Writable allowlist**: Red allowlist paths ONLY. Never touch frozen files or production/stub source files.
  - **Blindness rule**: read only your own worktree and provided spec/contract; never inspect sibling worktrees or refs.
  - Obey repo build/test-runner lock rules and run the exact targeted test IDs against the stub baseline to confirm **per-ID observable Red light**: tests compile cleanly, **every expected test ID executes (zero missing/skipped/crashed)**, and each fails on its expected contract assertion.
  - Commit all changes with a clean working tree and return: `worktreePath`, `branch`, `headSha`, `changedFiles`, exact test command, full list of expected test IDs, and per-ID observed Red failure summary.

### Async Recovery Rules (Step 2)
- Follow `next`: end your turn and wait for completion wakeups (do NOT poll).
- On transport error / lost reply for an unconfirmed slot, retry that slot with its **exact original `clientRequestId`**. Never re-launch a slot that already returned a `taskId` (keep following `next` for it).
- Handle `hasPendingQuestion` via `t3_pending_request` (or escalate to user); surface `pendingApproval` to user (cannot be auto-approved); cancel obsolete slots with `task_cancel` and verify terminal state before replacing.

---

## Step 3 — Audited Net-Patch Gate, Crash-Safe Merge & Per-ID Red-to-Green

Do **not** run a generic pre-merge LLM code review here. Maintain a crash-safe **Merge State Record** across all generations:
- `CONTRACT_SHA`, `PRE_MERGE_HEAD`, `POST_RED_HEAD`, `POST_BLUE_HEAD` (plus updated post-rebase equivalents or `invalidated` marker after ANY rebase in Step 5), `LAST_VERIFIED_STAGE`, `LAST_RED_INPUT_TREE` (tree/file-hash snapshot of contract, shared wiring, tests, and fixtures from the latest verified Red run),
- `ALL_DELEGATES[]`: **every** delegate launched by this task across all steps (Step 2 Red/Blue across all generations, Step 4 shared fixes, Step 4 Arbiter), recording `{ role, step, generation, taskId, childThreadId, link, hasWorktree, canonicalWorktreePath, branch, headSha, disposition }`,
- `REPLAY_SLOTS[]`: any temporary Step 5.2 replay worktree created directly by the host (`{ owner: "host-helper", canonicalWorktreePath, branch, headSha, disposition }`),
- `ACTIVE_MERGE_INTENT`: `{ step, preHead, sourceSha, expectedTreeHash, patchHash }` persisted BEFORE mutating index/HEAD.

> **Crash-safe resume check (linked-worktree aware)**: if resuming after interruption, NEVER check literal `.git/MERGE_HEAD` (in a linked worktree `.git` is a file!). Inspect ALL Git in-progress operation markers via `git rev-parse --git-path`: `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`, `BISECT_LOG`, `rebase-merge`, and `rebase-apply`, plus `git status --porcelain=v1 --untracked-files=all --ignore-submodules=none`. If ANY in-progress Git operation exists, resolve/abort it cleanly first — do NOT treat it as ready to proceed. Then re-compute the patch hash of `git diff --binary "$CONTRACT_SHA" "$ACTIVE_MERGE_INTENT.sourceSha"` and verify it equals `ACTIVE_MERGE_INTENT.patchHash` before classifying into three exact states:
> 1. **Unapplied**: `HEAD == preHead` and clean working tree/index → safe to apply.
> 2. **Staged**: `HEAD == preHead` and `git write-tree` matches `expectedTreeHash` with no unexpected unstaged edits → safe to commit, then run the post-commit allowlist audit.
> 3. **Committed**: `HEAD` parent equals `preHead` and `HEAD^{tree}` matches `expectedTreeHash` → **still run the post-commit allowlist audit** (`git diff --name-status -z --no-renames "$preHead" HEAD`) and clean-tree check if not yet logged, then record `POST_*_HEAD` and advance.
> If `patchHash` mismatches or unexpected extra edits exist, **preserve the workspace and stop** to inspect.

1. **Authoritatively bind identity & audit both net diffs strictly against `CONTRACT_SHA` BEFORE applying**:
   - Confirm host working tree is clean (`git status --porcelain=v1 --untracked-files=all --ignore-submodules=none` empty).
   - For each active Red/Blue slot, verify `taskId` / `childThreadId` reached terminal state via T3's `task_status` / `t3_thread_read` and retrieve the **authoritative child worktree path and branch** from those T3 records (never trust self-reported text alone). Canonicalize `AUTH_PATH=$(realpath "$RAW_AUTH_PATH")`, verify `git -C "$AUTH_PATH" rev-parse --git-common-dir` matches `HOST_COMMON_DIR`, verify `AUTH_PATH` is registered in `git worktree list --porcelain` (or note if T3 already reclaimed), verify **`git -C "$AUTH_PATH" rev-parse HEAD` equals the candidate `RED_SHA` / `BLUE_SHA`**, and verify `git merge-base "$CONTRACT_SHA" "$SHA"` == `"$CONTRACT_SHA"`.
   - Audit the **exact two-dot net diff** from `CONTRACT_SHA` to each SHA (with renames disabled):
     ```bash
     git diff --name-status -z --no-renames "$CONTRACT_SHA" "$RED_SHA"
     git diff --name-status -z --no-renames "$CONTRACT_SHA" "$BLUE_SHA"
     ```
   - Verify **every single changed path** in `RED_SHA` is strictly inside **Red allowlist**, and **every single changed path** in `BLUE_SHA` is strictly inside **Blue allowlist**.
   - Apply ONLY the **single audited net patch** generated from `CONTRACT_SHA` (`git diff --binary "$CONTRACT_SHA" "$SHA" | git apply --check` then `--index`), avoiding arbitrary sibling history or hidden intermediate commits.
2. **Apply Red net patch first — Confirm Per-ID Observable Red Light**:
   - Dry-run (`git apply --check`), compute/record `ACTIVE_MERGE_INTENT` (`step: "apply-red"`, `preHead: HEAD`, `sourceSha: RED_SHA`, patch/tree identity), apply with `git apply --index`, and commit (`git commit -m "test: add adversarial contract tests for <task>"`). On unexpected apply failure, restore cleanly (`git reset --hard "$PRE_MERGE_HEAD"`), preserve the Merge State Record, and resolve before retrying.
   - Immediately verify `git diff --name-status -z --no-renames "$PRE_MERGE_HEAD" HEAD` touches **Red allowlist ONLY** and working tree is clean.
   - Record `POST_RED_HEAD=$(git rev-parse HEAD)`, clear `ACTIVE_MERGE_INTENT`, and set `LAST_VERIFIED_STAGE=red-merged`.
   - Run the **exact test command and every expected test ID** reported by Red; verify **every single expected test ID executed** (none skipped, missing, or crashed) and failed at its expected contract assertion. Record `LAST_VERIFIED_STAGE=red-verified`.
3. **Apply Blue net patch second — Verify Per-ID Green Light**:
   - Dry-run (`git apply --check`), record `ACTIVE_MERGE_INTENT` (`step: "apply-blue"`, `preHead: POST_RED_HEAD`, `sourceSha: BLUE_SHA`, patch/tree identity), apply with `git apply --index`, and commit (`git commit -m "feat: implement <task> against contract"`). On unexpected apply failure, restore cleanly (`git reset --hard "$POST_RED_HEAD"`), preserve the Merge State Record, and resolve before retrying.
   - Immediately verify `git diff --name-status -z --no-renames "$POST_RED_HEAD" HEAD` touches **Blue allowlist ONLY** and working tree is clean.
   - Record `POST_BLUE_HEAD=$(git rev-parse HEAD)`, clear `ACTIVE_MERGE_INTENT`, and set `LAST_VERIFIED_STAGE=blue-merged`.
   - Run the same expected test IDs + build check and verify per-ID results.

---

## Step 4 — Serial Root-Cause Triage & Fix Loop (Max 3 Logic Rounds)

If every expected test ID passes cleanly on the first run → proceed to Step 5.

On failure, the host thread MUST **classify every failure before delegating** (1 logic round = 1 serial fix + host HEAD/clean/allowlist audit + test re-verification):

1. **Environment / baseline / runner failure** (simulator lock, missing env, flaky infra):
   - Fix environment/runner issue directly without blaming Blue or Red, then re-run (does not consume a logic-fix round).
2. **Implementation bug / contract violation** (default path):
   - Record `BEFORE_SHA=$(git rev-parse HEAD)` and `TASK_BRANCH=$(git branch --show-current)`.
   - Delegate a serial fix to **`MODEL_CONFIG.BLUE`** (`role: "implementation"`, `isolation: "shared"`) with exact failure logs, failing test IDs, and triage notes, and **register its `taskId` / `childThreadId` / `link` in `ALL_DELEGATES[]`** (`hasWorktree: false`). Instruct Blue: **edit Blue allowlist paths ONLY; never edit or weaken tests; commit all changes and leave working tree clean**.
   - **Strict host-side audit BEFORE running tests**:
     - Verify the fix delegate reached terminal state, read actual `ACTUAL_HEAD=$(git rev-parse HEAD)` (never trust self-reported SHA alone), verify `git branch --show-current == "$TASK_BRANCH"`, and verify `git merge-base --is-ancestor "$BEFORE_SHA" "$ACTUAL_HEAD"`.
     - Run `git status --porcelain=v1 --untracked-files=all --ignored=traditional --ignore-submodules=none` (using `traditional` so files inside ignored directories like `node_modules/` are enumerated individually, not hidden behind one directory line): require **zero** modified, staged, untracked, or dirty submodule entries, and verify every ignored file is a known expendable build output (if any unknown/unenumerable ignored file exists, clean or re-verify in a clean isolated checkout).
     - Audit `git diff --name-status -z --no-renames "$BEFORE_SHA" "$ACTUAL_HEAD"` strictly against **Blue allowlist**.
     - Only after all checks pass, re-run affected tests.
3. **Test bug / fixture error / test contradicts the written contract**:
   - Record `BEFORE_SHA`, fix the test (host or `MODEL_CONFIG.RED` with `isolation: "shared"`, registering the delegate in `ALL_DELEGATES[]` with `hasWorktree: false`), perform the exact same strict host-side terminal/HEAD/clean/ignored(`traditional`)/allowlist audit against **Red allowlist**, and log why the test violated the written contract.
   - **Never weaken or delete a valid contract assertion** to force green.
4. **Contract clarification vs. substantive spec change**:
   - Clarifying an ambiguity using already-settled design decisions is allowed (commit clarification, sync affected side).
   - **Substantive behavioral or scope changes MUST return to `/t3-tri-plan` (or explicit user approval)** — never alter approved behavior under the label of "clarification".

- **Round cap & Read-Only Arbiter**:
  - Max **3** logic-fix rounds.
  - If still deadlocked after Round 2, optionally invoke **`MODEL_CONFIG.ARBITER`** (`role: "review"`, `isolation: "shared"`, strictly read-only; register in `ALL_DELEGATES[]` with `hasWorktree: false` and confirm terminal state) for a one-shot ruling on contract vs. test vs. implementation.
  - If still unresolved after Round 3, stop and report the exact conflict, Merge State Record, and logs to the user / coordinator thread.

---

## Step 5 — Final Red-to-Green Replay, Review, Pre-Push Gate & Single Host Cleanup

Once all expected test IDs are green:

1. Complete any remaining host-owned checklist items from `<TASK>/implement.md` (e.g. `REVIEW.md` codification, docs, or acceptance fixes), commit cleanly, and verify all acceptance criteria.
2. **Input-Diff-Driven Final Contract-Stub Replay Helper**:
   - Triggered whenever the actual files for **contract, shared wiring, tests, or fixtures** on the current candidate `HEAD` differ from `LAST_RED_INPUT_TREE` (automatically catching changes from Step 4, Step 5.1 host edits, `/t3-cr-loop` fixes, AND any rebase — zero blind spots!):
     - Construct an isolated temporary worktree (`REPLAY_SLOTS[]`, `owner: "host-helper"`) carrying the **final contract + final shared wiring + observable non-crashing stub bodies + final tests & fixtures**.
     - Run all expected test IDs there to confirm every ID compiles and fails observably at its expected contract assertion (Red), and verify the exact same IDs pass on `HEAD` (Green).
     - **Persist the per-ID Red→Green replay evidence in this thread's report first**, update `LAST_RED_INPUT_TREE`, and mark the helper `disposition: "replay-evidence-saved"` in `REPLAY_SLOTS[]` so Step 5.5 cleans it cleanly.
3. **Code review against `<TARGET_BRANCH>`**:
   - Run `/t3-cr-loop` with explicit base `EXPLICIT_BASE=origin/<TARGET_BRANCH>` (or local `<TARGET_BRANCH>` if remote doesn't exist yet), capturing immutable `REVIEWED_BASE_SHA` and `LAST_REVIEWED_HEAD`.
   - **Rebase tracking (ANY rebase, including `/t3-cr-loop` preflight rebase)**: whenever a rebase rewrites branch history, re-map and re-prove post-rebase equivalents for `POST_RED_HEAD` / `POST_BLUE_HEAD` in the Merge State Record (or mark them `invalidated` so Step 5.5 retains their temp branches safely).
   - If `/t3-cr-loop` fixes or rebase moved `HEAD`, check `LAST_RED_INPUT_TREE` (re-run Step 5.2 replay if contract/wiring/tests/fixtures changed) and re-run affected acceptance verification so green evidence is bound strictly to `VERIFIED_SHA == LAST_REVIEWED_HEAD`.
4. **Authorized PR Publishing (Hold push until full PR-diff coverage & final SHA are verified)**:
   - If PR publishing is NOT authorized → keep local with clean working tree and `FINAL_SHA == LAST_REVIEWED_HEAD == VERIFIED_SHA`, then proceed directly to Step 5.5 (cleanup).
   - If PR publishing IS authorized:
     - First confirm `origin/<TARGET_BRANCH>` exists on remote (if not, set status `publish-held`, notify coordinator/user, and proceed to Step 5.5 local wrap-up).
     - Fetch `origin/<TARGET_BRANCH>`, resolve `PR_TARGET_TIP`, and compute `PR_MB=$(git merge-base "$PR_TARGET_TIP" "$LAST_REVIEWED_HEAD")`.
     - **Exact PR-diff coverage gate**: require BOTH:
       1. `git merge-base --is-ancestor "$PR_TARGET_TIP" "$LAST_REVIEWED_HEAD"` (remote target hasn't moved ahead), AND
       2. **`REVIEWED_BASE_SHA == PR_MB`** (exact match — prevents revert-cancellation diffs like `A(0) -> B(1) -> H(0)` or remote target rewinds from slipping unreviewed into `PR_MB...HEAD`!).
     - If either fails:
       - Rebase onto `PR_TARGET_TIP` if needed (updating or invalidating `POST_RED_HEAD` / `POST_BLUE_HEAD` mappings), re-run `/t3-cr-loop` directly against `PR_TARGET_TIP` so `REVIEWED_BASE_SHA == PR_MB`, re-check `LAST_RED_INPUT_TREE` (running Step 5.2 replay if needed), and re-run affected acceptance verification on the new `LAST_REVIEWED_HEAD` **before** pushing.
     - Once `HEAD == LAST_REVIEWED_HEAD == VERIFIED_SHA`, working tree is clean, and exact PR coverage passes:
       - Push strictly by exact SHA refspec (with `-u` so first publish sets upstream cleanly):
         ```bash
         git push -u origin "${VERIFIED_SHA}:refs/heads/${TASK_BRANCH}"
         ```
       - Check target repo and whether a PR already exists (`pull_request_list` / `pull_request_read`):
         - **New PR**: under verified exclusive host checkout ownership where local `refs/heads/${TASK_BRANCH}`, upstream, and `refs/remotes/origin/${TASK_BRANCH}` all equal `VERIFIED_SHA`, call native `pull_request_create` (`base: <TARGET_BRANCH>`); if exclusivity against implicit native push cannot be guaranteed (or target repo differs), open the PR strictly from the already-pushed remote branch via `gh pr create --base <TARGET_BRANCH> --head <TASK_BRANCH>`.
         - **Existing PR**: verify actual `repo`, `base`, and `head` first. Because native `pull_request_update` does NOT support changing `base`, if existing `base != <TARGET_BRANCH>`, fix via `gh pr edit <number> --base <TARGET_BRANCH>` (or pause and notify coordinator), then update title/body via `pull_request_update`.
       - After creating/updating PR, verify actual PR `base` branch/OID and `head` OID `== VERIFIED_SHA`, and ensure every item of「完成的证据」cites `VERIFIED_SHA`.
5. **Single Host Wrap-Up — Run `/t3-task-cleanup` (Local-Only, Publish-Held, and PR Modes)**:
   - Host is the **sole wrap-up executor** and invokes `/t3-task-cleanup` **once** here — after final verification (and after PR verification when published, or immediately after local verification in local-only / `publish-held` modes), passing `ALL_DELEGATES[]` and `REPLAY_SLOTS[]` (with replay evidence already saved).
6. Report final evidence (per-ID Red-light & Green-light proof, triage summary, `FINAL_SHA`, PR link or `publish-held` note, and `/t3-task-cleanup` workspace/disk report) to the user or coordinator thread (using `t3_thread_send` with `mode: "queue"` for routine completion).
