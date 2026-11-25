# t3-tri-plan Authoritative Protocol (v1.0.0)

This document defines the complete orchestration protocol for `/t3-tri-plan`. Every state transition MUST execute through `<PLUGIN_ROOT>/scripts/t3-tri-plan-state.sh` (backed by Perl `Fcntl::flock`, two-phase replayable `.pending.tx.json`, and `StrictJson.pm` unique-key JSON parsing).

---

## 1. Compatibility Contract & Security Boundary

### Artifact vs Entrypoint Compatibility
- **Artifact compatibility (native Trellis readable once Phase 6 is ready/activated)**:
  - Standard Trellis artifacts: `task.json`, `prd.md`, `design.md`, `implement.md`, `implement.jsonl`, `check.jsonl`.
  - `<TASK>/research/plans/planning-state.json`: keeps backward-compatible top-level `phases["0"|"1"|"2"|"5"|"6"]`, `review`, and `authorization` fields (all 64-char SHA-256), plus tri-plan metadata (`pipeline: "t3-tri-plan"`, `schema_version: 2`, `generation`, `owner_generation`, `design_revisions`, `blind_map`, `orphaned_attempts`, `phases["6"].activation`).
- **Entrypoint compatibility (honest boundary)**:
  - Repository-native `/trellis:dual-plan` and `/trellis:continue` freshness reroutes expect fixed `claude.md` + `codex.md` and do NOT acquire `.tri-plan.lock` or verify `.pending.tx.json`, `active-run.json`, `review_baseline_sha256`, `design_revisions[]`, non-seed JSONL, or `activation_uncertain`.
  - Therefore **`/t3-tri-plan` is the ONLY safe resume and re-planning entrypoint for `t3-tri-plan` tasks.**
  - **First transition to implementation** MUST go through `t3-tri-plan` Phase 6 (`check-freshness` + `activate-task` → `activated`), after which native Trellis implementation/check/finish-work steps may take over. `phases["6"].state == "ready"` is a valid standalone read-only planning deliverable when implementation is not yet authorized.
- **Legacy `dual-plan` detection**:
  - Run `bash "$TRI_STATE" inspect-task --task "$TASK"`.
  - If `TASK_KIND=LEGACY_DUAL_PLAN`, default to recommending `/trellis:dual-plan`. Only run `migrate-legacy --task "$TASK" --confirm` when the user explicitly confirms migration. Migration preserves legacy artifacts untouched and marks unproven stages, short hashes (`<64` hex), and mismatched legacy `user_decision` hashes as `needs-reverification` (never auto-passing Phase 6).

### Honest T3 Code Shared-Workspace & Locking Boundaries
- `t3-tri-plan` dispatches Phase 1 designers, Phase 2a blind judge, and Phase 3 reviewers with `delegate_task(..., isolation: "shared", mode: "async")`.
- **Protocol-level isolation**: T3 `delegate_task` in `shared` mode has no OS read-only sandbox and providers may auto-load local workspace files/instructions at startup. Independence and blindness are enforced by zero parent history + read-only prompt prohibitions + zero disk writes by children + shuffled anonymous candidate files + pre-reveal lock of `blind-eval.json`, `synthesis-body-locked.md`, and `initial-design.md`.
- **Observable drift scope (`worktree_fp` v3)**: captures `HEAD`, reflog count, staged blobs, and full content SHA-256 of ALL modified tracked files and non-ignored untracked files (including re-edits to pre-existing `M` and `??` files), excluding only engine runtime paths (`planning-state.json`, `active-run.json`, `.pending.tx.json`, `.tri-plan.lock`, `.activation.lock`, `.tx-staging/`, `runs/`). **Outside visibility**: gitignored files, edits made and reverted mid-run, and attribution of external concurrent edits.
- **Locking (`flock`)**: `.tri-plan.lock` and `.activation.lock` coordinate `t3-tri-plan` CLI invocations only (and release automatically on process crash). External non-cooperating processes can write during the TOCTOU window between pre-hash verification and `rename`; if overwritten by expected bytes, post-facto hashing cannot detect that lost external edit — drift detection guarantees cover observable post-write drift only.

---

## 2. Step 0 — Host Preflight, Capabilities & Configuration

### 0a. Trellis Preflight
```bash
bash "$TRI_STATE" preflight-trellis --repo "$REPO_ROOT"
```
Verify `TRELLIS_COMPAT=ok` or `degraded` (never guess paths if `.trellis/` is missing or `unsupported`). Read `.trellis/workflow.md`'s **Authorization and Completion** if present.

### 0b. Live Host Model Discovery
Call `orchestrator_capabilities` once per thread. Keep providers where `canRunChildTask == true` (and `canRunCrossProviderChildTask == true` for cross-provider targets).
- If a configured or requested model is absent from the short list and a provider reports `omittedModels > 0`, call `orchestrator_capabilities(search: "<model>")` before declaring it unavailable.
- Save the raw JSON response to a temp file `$CAPS_JSON`.

### 0c. First-Run Setup (`CONFIGURED=0` or `reconfigure`)
User config lives at `${T3_TRI_PLAN_CONFIG:-$HOME/.config/t3-tri-plan/config.json}` (independent of `t3-cr-loop`). Optional repo override lives at `<repo-root>/.t3-tri-plan.json` (strictly forbidden from specifying `authorizedProviders`).

When `config-show` reports `CONFIGURED=0` or user passed `reconfigure`:
1. Display live available providers, models, and exact effort option enums (`thought_level`, `effort`, `reasoningEffort`).
2. Guide interactive setup (`ask_question` when available):
   - **Phase 1 blind designers (multi-select)**: pre-recommend available subset of `antigravity/gemini-4-neon`, `claudeAgent/claude-opus-5-5`, `codex/gpt-6.2-sol`, plus unified strict-intersection effort or per-model effort.
   - **Phase 3 default single reviewer** (also inherited by Phase 2a blind judge unless `judge` is separately set) + effort from its exact allowed enum.
   - **Phase 3 council reviewers** (`initial-full` & `step-back`): offer quick option **"Same as Phase 1 designers (Recommended)"** or custom multi-select + effort.
3. Save confirmed config via `bash "$TRI_STATE" config-set --file "$TMP_CFG"`, setting `authorizedProviders` to the approved `providerInstanceId`s.

### 0d. Resolve Effective Config & Provider Authorization
```bash
bash "$TRI_STATE" config-show --repo "$REPO_ROOT" --capabilities "$CAPS_JSON" \
  [--override-designers ...] [--override-judge ...] [--override-model ...] \
  [--override-effort ...] [--override-council ...] [--single ...] [--allow-non-tri] \
  [--ignore-project-config]
```
- **Precedence & conflict table**:
  - `designers=`: replaces Phase 1 group (requires 3 distinct `provider/model` unless `--allow-non-tri`).
  - `judge=`: overrides Phase 2a blind judge ONLY. When omitted from config, `judge` inherits config `defaultReviewer` — **`single=` and `model=` NEVER alter `judge`**.
  - `single=`: forces Phase 3 (`defaultReviewer` and `reviewCouncil`); conflicts with `model=` or `council=` (exit 3).
  - Inline `:effort` wins over global `effort=`. When `effortMode == "unified"`, `unifiedEffort` is validated against the strict intersection and applied to EVERY member's emitted `options`. Models without an effort option reject non-empty effort values.
  - Each resolved target emits `*_PROVIDER`, `*_DRIVER_KIND`, `*_MODEL`, and `*_OPTIONS` for `delegate_task.target`.
- **Exit 3 (`CONFIG_VALID=0`)**: report every `CONFIG_ERROR=` verbatim and ask the user to fix/reconfigure. **Never silently substitute models or clamp effort.**
- **`NEEDS_PROVIDER_AUTH=1`**: pause and ask the user to authorize (`config-authorize-provider <id>`), ignore project override (`--ignore-project-config` on `config-show` AND persisted via `commit-phase0 --ignore-project-config` so `commit-phase1`/`next-review` consume the same effective knobs on resume), or abort.

---

## 3. Unified Async Dispatch, Reconciliation & Takeover Contract

Applies identically to **Phase 1 (`phase1-design`)**, **Phase 2a (`phase2-judge`)**, and **Phase 3 (`phase3-review`)**.

### Dispatching Slots (Parallel Within One Turn)
For each slot to launch:
1. **Claim atomically under `flock` BEFORE calling `delegate_task`**:
   ```bash
   bash "$TRI_STATE" claim-slot --task "$TASK" --run-id "$RUN_ID" --slot "$SLOT" \
     --owner "$PARENT_THREAD_ID" --owner-gen "$OWNER_GEN" --generation "$GEN"
   ```
   Capture `ATTEMPT`, `CLIENT_REQUEST_ID`, and `CORRELATION_MARKER` (`[tri-plan:<run_id>:g<g>:og<og>:<slot>:a<att>:cid<cid>]`).
2. **Call `delegate_task`**:
   - `mode: "async"`, `isolation: "shared"`, `clientRequestId: "$CLIENT_REQUEST_ID"`
   - `role`: `"design"` for Phase 1, `"review"` for Phase 2a & Phase 3
   - `title`: `"$CORRELATION_MARKER $SHORT_DESC"`
   - `task`: first line MUST be `"$CORRELATION_MARKER"`, followed by pinned header fields and full canonical prompt from `references/`.
   - `target`: exact `{ providerInstanceId, driverKind, model, options }` from `config-show` (or frozen slot target on resume).
3. **Record dispatch immediately**:
   ```bash
   bash "$TRI_STATE" record-dispatch --task "$TASK" --run-id "$RUN_ID" --generation "$GEN" \
     --owner "$PARENT_THREAD_ID" --owner-gen "$OWNER_GEN" --slot "$SLOT" --attempt "$ATTEMPT" \
     --task-id "$TASK_ID" --child-thread-id "$CHILD_THREAD_ID" --child-run-id "$CHILD_RUN_ID"
   ```
4. **End your turn and wait for wakeups.** Never poll (`task_status`, `sleep`, timers). Mention every launched child thread verbatim by its `link`.

### Crash Recovery & Reconciliation
Check open run via `bash "$TRI_STATE" run-summary --task "$TASK"`:
- **Resuming frozen targets**: re-check provider authorization/capabilities for the frozen slot targets stored in `active-run.json`; never swap models silently mid-run.
- **Slot stuck in `dispatching` (unknown dispatch outcome / lost `task_id`)**:
  1. Paginate `t3_thread_list(includeSubagents: true)` (`cursor`) across all subagent threads belonging to `owner_thread_id`. Use title match as a fast-path hint ONLY — **never skip threads whose title changed**.
  2. For candidate child threads, call `t3_thread_read(threadId, view: "messages", afterPosition: -1)` and verify message 0 contains the exact immutable `CORRELATION_MARKER`.
  3. **1 exact match + terminal `completed`**: locate the terminal assistant message belonging to `child_run_id` via `t3_thread_read(threadId, view: "messages")`, paginate `itemId` + `textOffset = nextTextOffset` until `nextTextOffset` is absent, save verbatim to `$RAW_FILE`, and run single-transaction:
     ```bash
     bash "$TRI_STATE" reconcile-and-record-result --task "$TASK" --run-id "$RUN_ID" \
       --generation "$GEN" --owner "$PARENT_THREAD_ID" --owner-gen "$OWNER_GEN" \
       --slot "$SLOT" --attempt "$ATTEMPT" --child-thread-id "$CHILD_THREAD_ID" \
       --child-run-id "$CHILD_RUN_ID" --input "$RAW_FILE"
     ```
  4. **1 exact match + terminal `failed` / `cancelled` / `interrupted`** (may have no final body): run:
     ```bash
     bash "$TRI_STATE" reconcile-terminal-error --task "$TASK" --run-id "$RUN_ID" \
       --generation "$GEN" --owner "$PARENT_THREAD_ID" --owner-gen "$OWNER_GEN" \
       --slot "$SLOT" --attempt "$ATTEMPT" --child-thread-id "$CHILD_THREAD_ID" \
       --child-run-id "$CHILD_RUN_ID" --state failed|cancelled --reason "..."
     ```
  5. **1 exact match still running/waiting, OR 0 / >1 matches**: transition slot to `needs_reconcile` (`update-slot --state needs_reconcile [--reconciled-child-thread-id ...]`) and pause for user choice. Exit `needs_reconcile` ONLY via `reconcile-bind` or `reconcile-abandon`.
- **Normal completion ingestion**: write verbatim full reply (paginating `t3_thread_read` if needed) to `$RAW_FILE` and run `record-result`. If exit 4 (`STALE_CALLBACK=1`), discard silently (zero disk side effects). If `DUPLICATE_NOOP=1`, proceed idempotently.
- **`waiting` / Retry / Takeover**:
  - `waiting`: run `update-slot --state waiting`, surface child `link`, wait.
  - Retry (max 1 automatic retry per slot on `failed` / `completed_invalid`): if prior attempt is non-terminal (`dispatched`/`waiting`), call `task_cancel(taskId)`, record `cancel_requested`, wait for cancellation confirmation (`cancelled`), then `claim-slot` for `attempt + 1`.
  - Cross-thread takeover (requires user confirmation): cancel any known `task_id` slots via `task_cancel`, run `takeover-run --new-owner "$NEW_THREAD_ID" --reason "..."` (increments BOTH `generation` and `owner_generation` and records all unresolved `dispatching`/`needs_reconcile`/`reconciled_untracked`/`cancel_requested` slots in `orphaned_attempts[]`). Never call `t3_thread_interrupt` on subagent threads (top-level only) — surface orphaned child links to the user instead.

---

## 4. Seven-Phase Pipeline (Phases 0–6)

### Phase 0 — Task & PRD (`prd.md`)
1. Check developer identity, `task.py current --source`, Git status, and session authorization. Create task via `task.py create` if authorized and none active.
2. Author or update `<TASK>/prd.md` (background, goals, non-goals, requirements, constraints, compatibility, observable acceptance criteria, genuine open questions).
3. Commit Phase 0:
   - First time or unchanged: `bash "$TRI_STATE" commit-phase0 --task "$TASK" [--authorization "..."]`
   - Material PRD change: `commit-phase0 --task "$TASK" --change-kind material --reason "..."` (state-first atomic tx invalidating downstream, incrementing `generation`, moving old artifacts into unique `superseded-<prd8>-<txid>/`, archiving ledger & resetting counters, recording any open run orphans).
   - Wording-only change: `commit-phase0 --task "$TASK" --change-kind wording --evidence "..."` (preserves historical `reviewed_prd_sha256` and valid Phase 1/2 artifacts; existing `clean_streak == 1`, `converged`, or `user_decision` MUST still be explicitly rebound via `ack-wording-closure --evidence "..."` — which succeeds ONLY if `non_prd_baseline_sha256` and `review-ledger.md` are byte-identical — or re-verified by confirmation review!).

### Phase 1 — True Triple-Blind Parallel Design
1. `prepare-design --task "$TASK" --slots-json "$DESIGNERS_JSON" --owner "$PARENT_THREAD_ID"` (shuffles slots into `candidate-a/b/c`, snapshots `worktree_fp_start`).
2. Dispatch all designers in parallel using `references/blind-design-prompt.md` (`role: "design"`, read-only, zero file writes).
3. Validate each reply via `record-result` (`validate-candidate.pl`). Retry invalid/failed slots at most once. If still partial (e.g., 2/3 valid), pause and ask the user: (A) Retry / (B) Proceed with valid candidates (`--degraded-approval`) / (C) Replace failed designer / (D) Abort.
4. Run `commit-phase1 --task "$TASK" [--degraded-approval "..."]` to check `worktree_fp` v3 and atomically publish anonymous `candidates/candidate-*.md` + store `blind_map`.

### Phase 2 — Zero-History Anonymous Blind Judge (2a) & Mechanical Reveal/Assembly (2b)
- **Phase 2a (STRICTLY BLIND — before `reveal-blind-map`)**:
  1. `prepare-judge --task "$TASK" --target-json "$JUDGE_JSON" --owner "$PARENT_THREAD_ID"`.
  2. Dispatch 1 fresh zero-history read-only Blind Judge `delegate_task` (`role: "review"`) with `references/blind-judge-prompt.md`, pinned `prd.md` SHA-256, and the anonymous `candidates/candidate-*.md` paths + SHA-256s (NO `blind_map`, NO dispatch history).
  3. **Zero parent technical arbitration**: the parent dispatched Phase 1 and saw model attribution, so the parent MUST NOT edit `blind-eval.json` or arbitrate technical disputes. If the Blind Judge returns non-empty `product_forks[]`, `record-result` transitions the `judge` slot to `completed_forks_pending` (`FORKS=<N>`): the parent ONLY forwards the anonymous `Option 1 / Option 2` choices to the user via `ask_question`, then claims a fresh judge attempt (`claim-slot`) and dispatches a fresh Blind Judge call carrying the user's verbatim anonymous `product_decisions[]` so the Blind Judge produces final `blind-eval.json` (`product_forks: []`, `SLOT_STATE=completed_valid`), `synthesis_body_markdown`, and `initial_design_markdown`.
  4. Run `commit-phase2a --task "$TASK"` to validate (`validate-blind-eval.pl` + `StrictJson.pm`), check `worktree_fp` v3, and perform a one-time `unlocked → locked` CAS freezing `blind-eval.json`, `synthesis-body-locked.md`, AND `initial-design.md` (`initial_design_sha256`).
- **Phase 2b (Attribution Reveal & Mechanical Assembly)**:
  1. Run `reveal-blind-map --task "$TASK"` (unlocked ONLY after `phase2a_locked == true`).
  2. Run `commit-phase2b --task "$TASK" --assemble` to mechanically write `design.md` (byte-identical copy of locked `initial-design.md`) and `research/plans/synthesis.md` (verbatim `synthesis-body-locked.md` + generated `## Attribution Reveal` table). Post-reveal winner/design tampering is rejected (`POST_REVEAL_TAMPER`).

### Phase 3 — Multi-Model Design Review Loop
1. Determine next step:
   ```bash
   bash "$TRI_STATE" next-review --task "$TASK"
   ```
   Routes strictly in order: `resume` → `blocked-manual-redesign` → `disposition-required` (Phase 4) → `converged` / `user-decided` (Phase 5) → `step-back` (`reviewCouncil`) / `stop` (Phase 4d) → `confirmation-full` (`defaultReviewer`) → `initial-full` (`reviewCouncil`) → `full` (`defaultReviewer`) → `incremental` (`defaultReviewer`, falling back to `full` if previous snapshot is missing/corrupt).
2. Run `prepare-review --task "$TASK" --purpose "$PURPOSE" --mode "$MODE" --slots-json "$REVIEWERS_JSON" --owner "$PARENT_THREAD_ID"`.
3. Dispatch reviewer slot(s) in parallel using `references/design-review-prompt.md` (`role: "review"`, read-only, JSON-only reply).
4. Ingest each slot via `record-result` (`parse-design-review.pl` against frozen `ledger-manifest.json` + frozen baseline rule index). Retry invalid/failed slots once; on partial council failure after retry, pause and ask the user (never silently drop or substitute; zero valid reviewers cannot commit).
5. **Council synthesis** (`initial-full` / `step-back`, or single reviewer pass-through):
   - Deduplicate findings by code-verified root mechanism (max severity `BLOCKER > SHOULD_FIX > OPTIONAL`, union of verified `instances` and `evidence`, `sources[]` tagged).
   - If reviewers contradict on the same `Dn` (`verified` vs `reopens`), inspect real code and record a `disputes[]` entry (`resolution: "reopen" | "verified" | "unresolved"` + `code_evidence`). Any `"unresolved"` dispute blocks `clean`!
6. Run `finish-review-round --task "$TASK" [--merged-input "$MERGED_JSON"] [--dismissed-findings "$DISMISSED_JSON"] [--degraded-approval "..."] [--inherit-wording-confirmation]`.
   - Checks mid-round drift across `design.md`, `prd.md`, `worktree_fp` v3, and `review_baseline_sha256` (drifted rounds are discarded without touching ledger/counters).
   - Enforces slot-to-merged binding: single-reviewer rounds enforce exact canonical equivalence with the recorded slot file (`--merged-input` may be omitted); multi-reviewer council rounds verify 1-to-1 per-slot traceability of every blocking (`BLOCKER`/`SHOULD_FIX`) finding into merged `findings[].sources` (and every `step_back[]` proposal into merged `step_back[].sources`), verify every `disputes[]` entry against actual recorded slot positions (only `verified`/`unresolved` disputes exempt a reopened blocking finding; `resolution: "reopen"` must preserve `>= severity`), or require explicit `--dismissed-findings` with concrete `code_evidence`.
   - Re-validates merged JSON (`--merged`), counts at most 1 occurrence per class per council round, promotes `recurring` (≥2 rounds in lineage, named by `step-back`, or non-empty `violates_review_md_rule`), renders `review.md`, and atomically commits `review-ledger.md` + `planning-state.json` (on `step-back`, increments `step_backs_done` AND resets `dirty_since_step_back = 0`, setting `step_back_assessment_status = "pending"` even when `findings[]` is empty).

### Phase 4 — Controlled Revision, Codification & Stop Decisions
- **4a (Disposition)**: dispose EVERY open `BLOCKER`/`SHOULD_FIX` class as `adopted`, `rejected` (with repo evidence), `moved-to-implement`, or `out-of-scope` (requires real user answer via `ask_question`).
- **4b (Codify recurring classes)**: every `recurring` class MUST record `codified: { invariant_id: "I-n", guard_test: "...", review_md_entry?: "..." }`, add `I-n` into `design.md`, and defer any repo-wide `REVIEW.md` edit to an explicit step in `implement.md` (never edit `REVIEW.md` during planning).
- **4c (Step-back assessment)**: write structural root-cause analysis and execute ONE structural design revision fixing all open instances. If the structural change exceeds PRD scope or external contracts, ask the user via `ask_question` before modifying `design.md`. Pass `--step-back-assessment-done` on commit.
- Commit Phase 4 atomically:
  ```bash
  bash "$TRI_STATE" commit-phase4-revision --task "$TASK" --dispositions-json "$DISP_JSON" \
    [--step-back-assessment-done] [--clear-scope-fork]
  ```
  Appends a contiguous entry to `design_revisions[]` so legitimate Phase 4 edits preserve Phase 2 validity while out-of-band edits are caught by `check-freshness`.
- **4d (`stop` handoff)**: present ledger summary & history, ask user via `ask_question`:
  - **(A)** `authorize_extra_step_back` (+1 step-back budget, return to Phase 3)
  - **(B)** `narrow_scope_and_proceed` (split recurring to follow-up, dispose remaining classes, record bound decision)
  - **(C)** `manual_redesign` (hard blocker across `next-review`, Phase 5, and Phase 6 until PRD material change or `clear-manual-redesign`)
  - **(D)** `dispose_and_close_review` (dispose every remaining class via 4a, record bound decision)
  Record via `record-user-decision --task "$TASK" --choice <enum> --reason "..."`.

### Phase 5 — Execution Plan & Context Manifests
1. Generate `<TASK>/implement.md` (ordered verifiable steps, acceptance mapping, AND explicit checklist items for every `moved-to-implement` class, every `recurring` class's `I-n` + guard test, and any applicable `REVIEW.md` codification step).
2. Populate `<TASK>/implement.jsonl` and `<TASK>/check.jsonl` with real spec/research entries (seed-only manifests are rejected).
3. Run `bash "$TRI_STATE" commit-phase5 --task "$TASK"` (runs `task.py validate`, enforces non-seed JSONL existence/validity, verifies codification coverage in `design.md` & `implement.md`, binds live `review_baseline_sha256`).

### Phase 6 — Readiness Gate & Process-Locked Activation
1. Run `bash "$TRI_STATE" commit-phase6-ready --task "$TASK" [--authorization "..."]` (runs full `check-freshness` across Phases 0–5, `design_revisions[]`, live `review_baseline_sha256`, and Phase 5 hard gates).
2. Check session authorization (`.trellis/workflow.md` **Authorization and Completion**):
   - If planning-only or explicit user wait gate is active: deliver the complete plan cleanly (`phases["6"].state == "ready"`).
   - If implementation is already authorized and no open decision remains: activate via:
     ```bash
     bash "$TRI_STATE" activate-task --task "$TASK" --owner "$PARENT_THREAD_ID" --authorization "<scope>"
     ```
     `activate-task` holds `.activation.lock` across the entire lifetime of `task.py start <TASK>`, probes `after_start` hooks from BOTH `.trellis/config.yaml` (fail-closed `unknown` if unreadable/malformed) and `task.json`, detects `[WARN] Hook (failed|timed out|error)` even on exit 0, and verifies the shared postcondition predicate (`activation_id` + `generation` + live `check-freshness` + `task.json.status == "in_progress"` + exact original session task pointer via `task.py current --json` or recorded degraded mode) before recording `activated`.
   - If `ACTIVATION_IN_PROGRESS=1` (exit 5): another starter is alive — do NOT retry.
   - If interrupted in `activating`: run `recover-activation --task "$TASK"` (`unstarted` → `cancel-activating`; partial pointer or hooks `true`/`unknown` → `activation_uncertain`).
   - If `activation_uncertain`: NEVER auto-rerun `task.py start`. Surface full logs/hooks/pointer status to the user; exit ONLY via explicit human-verified `resolve-activation --resolution confirmed_activated|reset_to_ready --evidence "..."` (`confirmed_activated` runs the exact same shared postcondition predicate, so a cleared pointer cannot be bypassed).
3. Only after `phases["6"].state == "activated"` and `check-freshness` passes does implementation hand off to native Trellis implementation steps.
