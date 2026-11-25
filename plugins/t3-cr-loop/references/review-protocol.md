# t3-cr-loop review protocol (v1.0.0)

This document is the **authoritative review-loop body** shared by `t3-cr-loop`, `t3-cr-loop-merge`, and `t3-cr-loop-pr`. Each skill owns only its preflight (step 1) and its completion step (step 8), plus command-specific stop reasons and report lines. Steps 0, 2–7, and the shared parts of step 9 are defined here.

## Core Design

1. **Multi-model council on high-leverage rounds, default single model on fast rounds.**
   - `initial-full` (first round of a convergence cycle, base switch, or rewritten history) and `step-back` run a **parallel multi-model council** via T3 Code `delegate_task` (default recommendation when available on host: `antigravity/gemini-4-neon`, `claudeAgent/claude-opus-5-5`, `codex/gpt-6.2-sol`).
   - `incremental` (diff-only re-review after fixes), `confirmation-full` (2nd clean round on same HEAD), and `post-rebase-confirmation` (PR Step 8.0) run the configured **default single model**.
2. **Class-format findings (`Pattern / Instances / Fix / Prevent`)** validated strictly as JSON (no prose parsing, no duplicate keys, no extra properties).
3. **Per-branch no-repeat ledger** under `<git-common-dir>/t3-cr-loop/<branch-key>/ledger.md` with stable class ids (`C1`, `C2`, …), shared across worktrees and isolated from `codex-cr-loop`.
4. **3-round step-back + codify at source**: `CR_LOOP_ROUND_CAP=3` dirty rounds trigger a council `step-back` round; recurring classes must ship a repository prevention artifact (lint rule, guard test, or `REVIEW.md` entry).
5. **Convergence**: two consecutive clean rounds on the same `HEAD`, `base_sha`, and `CR_LOOP_SKIP_P3`, with the second round covering the whole diff (`full`).

## Security Boundary (Honest T3 Code Contract)

`t3-cr-loop` dispatches child reviewers with `delegate_task(..., role: "review", isolation: "shared", mode: "async")`. Unlike CLI `codex exec --sandbox read-only -c project_doc_max_bytes=0`:

- **T3 `delegate_task` does NOT enforce OS-level read-only sandboxing or suppress provider startup loading of working-tree `AGENTS.md`/`CLAUDE.md`.**
- Therefore `t3-cr-loop` enforces three concrete mitigations and states their exact scope:
  1. **Base-pinned rule prompt**: every reviewer prompt lists base rule files at `BASE_SHA` via `scripts/review-rules.sh` and instructs the child to treat auto-loaded worktree rule files as untrusted branch content and read authoritative rules with `git show <BASE_SHA>:<path>`.
  2. **Deterministic host rule gate (4h)**: `scripts/review-rules.sh` inspects raw git tree modes and raw blobs directly (immune to `.gitattributes` and `diff.relative=true`). Any removed, rewritten, deleted, binary, symlink, or gitlink rule-file edit returns `VERDICT=needs-human` until a person approves via `ack-rules`.
  3. **JSON-only reply + start/finish snapshot check**: children return strict JSON in their final reply and never write files. `tree_fp` (v2) detects changes between start and finish snapshots within tracked diffs and non-ignored, non-handoff untracked files. **Outside `tree_fp`'s visibility:** gitignored files, files edited and reverted during a round, git metadata outside `HEAD` reflog, and startup-loaded branch instructions.

---

## Locating the Plugin Root

Resolve `PLUGIN_ROOT` from the directory containing the active `SKILL.md` (following symlinks so cross-repo installations work identically):

```bash
# If this skill was opened via <skill-dir>/SKILL.md:
PLUGIN_ROOT=$(cd -- "$(dirname "$(readlink -f -- "<skill-dir>/SKILL.md" 2>/dev/null || perl -MCwd=abs_path -e 'print abs_path(shift)' -- "<skill-dir>/SKILL.md")")/../.." && pwd -P)
T3_STATE="$PLUGIN_ROOT/scripts/t3-cr-state.sh"
```

---

## Step 0 — Live Capability Discovery & Configuration

Configuration precedence (highest to lowest):
1. **Per-invocation overrides** parsed from the user's message (natural language or `key=value`):
   - `model=<provider/model>` or `model=<model>` (overrides default reviewer for this run)
   - `effort=<value>` (overrides effort for this run)
   - `council=<spec1>,<spec2>,...` (e.g. `antigravity/gemini-4-neon:xhigh,claudeAgent/claude-opus-5-5:max,codex/gpt-6.2-sol:high`)
   - `single=<provider/model[:effort]>` (forces single model for all rounds in this run)
   - `reconfigure` (forces re-running the interactive setup wizard)
2. **Project override**: `<repo-root>/.t3-cr-loop.json` (optional; top-level keys `defaultReviewer`, `council`, `knobs`).
3. **User config**: `${T3_CR_LOOP_CONFIG:-$HOME/.config/t3-cr-loop/config.json}`.

### 0a. Query live host capabilities
Call `orchestrator_capabilities` once per thread. Keep only providers where `canRunChildTask == true`.
- Identify every model unambiguously by `providerInstanceId + model`.
- If a user-requested or configured model is missing from the initial short list and a provider reports `omittedModels > 0`, call `orchestrator_capabilities(search: "<model>")` before declaring it unavailable.
- Record each model's real effort option key and allowed values (for example on typical hosts: `antigravity` → `thought_level`, `claudeAgent` → `effort`, `codex` → `reasoningEffort`).
- Save the raw capabilities JSON to a temp file (`$CAPS_JSON`) for `t3-cr-state.sh config-show --capabilities "$CAPS_JSON"`.

### 0b. First-run setup (when `CONFIGURED=0` or `reconfigure` was requested)
Use the host's interactive prompt tool when available (`ask_question` if exposed, else `form-base`, else concise plain-text multiple choice). Never invent defaults without user confirmation; never persist unconfirmed choices.

1. Show the live available providers, models, and effort option values returned by `orchestrator_capabilities`.
2. **Select default single reviewer**: one available `providerInstanceId + model` (used for `incremental`, `confirmation-full`, and `post-rebase-confirmation`).
3. **Select default reviewer effort**: from that model's exact allowed values.
4. **Multi-select council reviewers** (for `initial-full` and `step-back`): pre-recommend whichever of `antigravity/gemini-4-neon`, `claudeAgent/claude-opus-5-5`, and `codex/gpt-6.2-sol` are available on this host, plus all other available models.
5. **Select council effort strategy**:
   - **Unified effort**: compute the **strict intersection** of allowed effort values across all selected council models (do NOT silently clamp). Let the user pick one value from that intersection (if the intersection is empty, fall back to per-model).
   - **Per-model effort**: let the user choose each selected council model's effort from its own allowed enum.
6. Save the confirmed config via `bash "$T3_STATE" config-set --file <tmp.json>`, including `authorizedProviders` set to the unique `providerInstanceId`s the user just approved.

### 0c. Validate effective config & project provider authorization
Run:
```bash
bash "$T3_STATE" config-show --capabilities "$CAPS_JSON" \
  [--override-model ...] [--override-effort ...] [--override-council ...] [--single ...] \
  [--ignore-project-config]
```
- **Exit 3 (`CONFIG_VALID=0`)**: a configured or requested model/effort is unavailable or invalid on this host. Surface every `CONFIG_ERROR=` verbatim and ask the user to reconfigure or specify an available model. **Never silently substitute another model or clamp effort unasked.**
- **`NEEDS_PROVIDER_AUTH=1`** (a repository `.t3-cr-loop.json` selected a `providerInstanceId` not in the user's `authorizedProviders`): pause, display the effective reviewer list and `UNAUTHORIZED_PROVIDERS`, and ask the user to either:
  - **(A) Authorize** (`bash "$T3_STATE" config-authorize-provider <id>`) and proceed,
  - **(B) Ignore project provider override** (`--ignore-project-config` on `config-show` AND `init --ignore-project-config`, which persists the ignore policy for this branch's loop) and use user config, or
  - **(C) Abort**.
- Whenever `PROJECT_OVERRIDDEN=1` or per-invocation overrides changed the reviewers, display the resolved effective reviewers (`default` and `council`, with exact `providerInstanceId/model` and effort options) to the user before dispatching.

---

## Step 2 — State Setup

```bash
bash "$T3_STATE" init [--ignore-project-config]
```

- Shared knobs (env overrides or `config.json` `knobs`): `CR_LOOP_ROUND_CAP=3` (`0` disables step-back), `CR_LOOP_MAX_STEP_BACKS=1`, `CR_LOOP_SKIP_P3=1`, `CR_LOOP_REQUIRE_REBASED=1`, `CR_PR_AUTO_REBASE=1`. Passing `--ignore-project-config` to `init` persists the ignore policy in branch state so subsequent `next`/`prepare`/`finish`/`ack-rules`/`mark-converged` commands consume the same effective knobs on resume.
- If `ACTIVE_ROUND=` is present, an earlier async round is still open — follow step 3a (`PURPOSE=resume`) before starting anything new.

---

## Step 3 — Run One Review Round (T3 Async `delegate_task`)

### 3a. Determine round purpose & reviewer profile

```bash
bash "$T3_STATE" next --base "$BASE"
```

Priority table implemented by `t3-cr-state.sh next`:

| Priority | Condition | `PURPOSE` | `MODE` | `PROFILE` |
|---|---|---|---|---|
| 1 | Open `active_round_dir` exists | `resume` | — | Resume / recover active slots (3c) |
| 2 | Explicit `--purpose post-rebase-confirmation` | `post-rebase-confirmation` | `full` | `default` |
| 3 | `clean_streak ≥ 2` with `last_clean_mode == full`, or matching `base_converged_*` for current `HEAD/base_sha/SKIP_P3` | `converged` | `converged` | Re-verify HEAD/base, ensure `mark-converged`, go to step 8 |
| 4 | `CR_LOOP_ROUND_CAP > 0` and `dirty_since_step_back ≥ CR_LOOP_ROUND_CAP` | `step-back` (if `step_backs_done < MAX`) else `stop` | `step-back` / `stop` | `council` / 4c user prompt |
| 5 | `clean_streak == 1` matching current `HEAD/base_sha/SKIP_P3` | `confirmation-full` | `full` | `default` |
| 6 | New convergence cycle (`rounds_in_cycle == 0`), material base switch (`last_reviewed_base_sha != base_sha`), or `last_reviewed_head` not ancestor of `HEAD` | `initial-full` | `full` | `council` |
| 7 | `last_reviewed_head == HEAD` (same HEAD after dirty/unacked round) | `full` | `full` | `default` (warn HEAD unchanged) |
| 8 | `last_reviewed_head` strict ancestor of `HEAD` | `incremental` | `incremental` | `default` (`SINCE=last_reviewed_head`) |

### 3b. Prepare & dispatch parallel `delegate_task` reviewers

1. Build the slot list from `PROFILE` (`default` → `slot1`; `council` → `slot1,slot2,...`).
2. Prepare the round (snapshots `HEAD`, `head_moves`, `tree_fp` v2, and builds `prompt.md` + `active_round.json`):
   ```bash
   bash "$T3_STATE" prepare --purpose "$PURPOSE" --mode "$MODE" --base "$BASE" \
     ${SINCE:+--since "$SINCE"} --slots "$SLOTS" --owner "$PARENT_THREAD_ID"
   ```
   Capture `ROUND_DIR` and read `$ROUND_DIR/prompt.md`.
3. For each slot to dispatch (in parallel in one turn):
   - **First, atomically claim the slot under branch lock** (prevents duplicate dispatch across turns):
     ```bash
     bash "$T3_STATE" claim-slot "$ROUND_DIR" --slot "$SLOT" --attempt "$ATTEMPT" \
       --owner "$PARENT_THREAD_ID" --provider "$PROV" --model "$MODEL" --options-json "$OPTS_JSON"
     ```
     Capture `CLIENT_REQUEST_ID`.
   - **Call `delegate_task`**:
     - `role: "review"`, `mode: "async"`, `isolation: "shared"`, `clientRequestId: "$CLIENT_REQUEST_ID"`
     - `target: { providerInstanceId: "$PROV", model: "$MODEL", options: <parsed OPTS_JSON> }`
     - `task`: exact contents of `$ROUND_DIR/prompt.md` (with a one-line header identifying slot & reviewer model).
   - **Immediately record dispatch metadata**:
     ```bash
     bash "$T3_STATE" record-dispatch "$ROUND_DIR" --slot "$SLOT" --attempt "$ATTEMPT" \
       --owner "$PARENT_THREAD_ID" --task-id "$TASK_ID" --child-thread-id "$CHILD_THREAD_ID" \
       --child-run-id "$CHILD_RUN_ID"
     ```
4. **End your turn and wait for T3 Code wakeups.** Follow `delegate_task`'s `next` contract — **never poll** (`task_status`, `sleep`, `Monitor`, `ScheduleWakeup`). Mention each launched child thread by its verbatim `link`.

### 3c. Handle wakeups, recovery, retries & partial failures

Inspect current slot state with `bash "$T3_STATE" round-summary "$ROUND_DIR"`.

- **Crash recovery when a slot is stuck in `dispatching` (no `taskId` persisted)**:
  Check `t3_thread_list(includeSubagents: true)` to see if a child thread was already created for that slot/attempt. If found, record it via `record-dispatch`; **if identity cannot be confirmed, pause and ask the user** — never blindly dispatch a duplicate reviewer in the shared worktree.
- **Crash recovery when parent exited after reading a terminal completion but before `record-result`**:
  Use the persisted `childThreadId` with `t3_thread_read(threadId: "$CHILD_THREAD_ID", view: "messages")` (paginating with `textOffset` if truncated) to fetch the child's full final message verbatim, then run `record-result` idempotently.
- **Slot state handling**:
  - Reject any wakeup whose `taskId` does not match the slot's active `attempt`.
  - **`waiting` (pending user question or approval)**: record `update-slot --state waiting`, surface the child thread `link` to the user, and wait — never treat waiting as failure.
  - **`cancel_requested`**: record `update-slot --state cancel_requested`, wait until `task_cancel` confirms cancellation before any retry.
  - **`completed`**: write the child's full verbatim completion text to a temp file and run:
    ```bash
    bash "$T3_STATE" record-result "$ROUND_DIR" --slot "$SLOT" --attempt "$ATTEMPT" \
      --owner "$PARENT_THREAD_ID" --task-id "$TASK_ID" --input "$RAW_FILE"
    ```
    - Exit 0 → `SLOT_STATE=completed_valid` (strict JSON validated and canonicalized to `result-<slot>-a<k>.json`; duplicate identical submissions return `DUPLICATE_NOOP=1`).
    - Exit 5 → `SLOT_STATE=completed_invalid` (invalid/truncated JSON, duplicate keys, extra keys, non-string scalars, or duplicate non-empty `reopens`).
  - **Terminal failure (`failed` / `cancelled` / `interrupted` / `completed_invalid`)**:
    - Record `update-slot --state <failed|cancelled|interrupted>` (for non-`record-result` failures). Note: `interrupted` is a terminal non-success state, never `clean`.
    - **Timeout policy**: T3 Code does not auto-timeout reviewers; only T3 terminal errors or explicit user-approved `task_cancel` end a running slot.
    - **Automatic 1-retry per slot**: if `attempt == 1` AND the whole round was not cancelled (`cancel-round`), claim `attempt=2` via `claim-slot`, launch ONE fresh `delegate_task` with the new `clientRequestId` (for `completed_invalid`, append a brief reminder to output ONLY strict schema JSON with concise text), and `record-dispatch`. Never reuse `t3_thread_send` for a retry.
  - **Whole-round cancel**: if the user asks to cancel the round, call `task_cancel` on all running tasks and run `bash "$T3_STATE" cancel-round "$ROUND_DIR" --owner "$PARENT_THREAD_ID"`. No slot auto-retries after `cancel-round`.
- **When all slots reach terminal state (`PENDING_SLOTS=0`)**:
  - If `VALID_SLOTS == 0`: cancel/close active round, write `reviewer-error` handoff (step 9a), and stop.
  - If `VALID_SLOTS >= 1` and `FAILED_SLOTS >= 1` (partial council failure after retry): **pause and ask the user** via the host prompt tool / dialogue:
    - **(A) Proceed with the successful reviewer(s)** — pass `--partial-approved "<summary>"` to `finish` and list absent models in the report.
    - **(B) Abort and write handoff** — `cancel-round`, write handoff with `Stop reason: reviewer-partial-failure`, and stop.
    "No response" is never consent.

### 3d. Synthesize council results & finish the round

- **Single valid reviewer**: `finish` enforces exact canonical equivalence with the recorded `result-<slot>-a<k>.json` (modulo optional `sources: ["<provider>/<model>"]` tags; `--merged` may also be omitted to directly consume the recorded canonical slot file). A blocking finding from a single reviewer can never be settled as `clean`.
- **Multiple valid reviewers (council synthesis)**:
  - Keep every model's raw canonical `result-<slot>-a<k>.json` untouched for auditability.
  - Semantically merge into `$ROUND_DIR/merged-result.json`:
    1. Every merged `findings[]` and `step_back[]` entry MUST include exact 0-based `merged_from: [{ "slot": "<slot-id>", "index": <int> }, ...]` provenance pointing to the contributing canonical slot results, matching `sources: ["<slot-or-provider/model>", ...]`, and (whenever merging `>= 2` distinct slots into one entry) a non-empty `merge_rationale`. Findings sharing a **verified** root pattern become one class: take the **highest severity** (`P0 > P1 > P2 > P3`), take the **union of deduplicated `instances[]`** (preserving every source's `location` and `instances[]`), combine the strongest `pattern`/`fix`/`prevent`, and preserve valid ledger `reopens` without duplicating the same non-empty `reopens` id across two merged entries. Never collapse two items from the same slot or two unrelated root causes at the same line into one merged entry.
    2. **Divergent findings** (reported by only one model or with conflicting claims): inspect the cited code directly before deciding — keep valid issues (tagged with their reporting `sources` and `merged_from`), never silently drop a real bug just because another model missed it. If a blocking finding from a council slot is verified to be a false positive after inspecting the code, pass `--dismissed-findings <json-file>` containing `[{ "slot": "...", "title": "...", "severity": "...", "code_evidence": "..." }]` with concrete code evidence (disallowed in single-reviewer rounds); otherwise `finish` rejects unaccounted blocking findings.
    3. Merge `step_back[]` similarly with `sources[]`, `merged_from[]`, and (when merging across slots) `merge_rationale`, preserving each source's `classes` and `approach_change` (keep independent proposals with different `approach_change` as separate entries even if they share a title). Merge `out_of_scope[]` with `sources[]`.
    4. Set `verdict: "clean"` iff merged `findings` is empty; otherwise `"findings"`.
- **Commit the round atomically**:
  ```bash
  bash "$T3_STATE" finish "$ROUND_DIR" [--merged "$ROUND_DIR/merged-result.json"] \
    [--dismissed-findings "$ROUND_DIR/dismissed.json"] [--partial-approved "<reason>"]
  ```
  - Exit 3 (`head-drift`): `head-moved`, `head-moved-and-returned`, or `tree-changed` (catches any accidental write by a shared-worktree child or concurrent editor; marks the round `drifted` and clears `active_round_dir` so the next run does not loop in `resume`). Do NOT classify; write `head-drift-during-review` handoff and stop.
  - Exit 5 (`error`): merged JSON failed strict schema validation or `review-rules.sh` scan/render failed. Fix merged JSON formatting if parent-induced (or retry `finish` on transient scan error); otherwise `reviewer-error` handoff.
  - Exit 0 (`clean` / `p3-only` / `needs-human` / `dirty`): proceed to step 4. Explicit retry `finish "$ROUND_DIR"` is idempotent; before acting on any recovered verdict, re-verify `HEAD` and `BASE`.

---

## Step 4 — Classify and Decide

- **4a. Clean** (`clean`, or `p3-only` with `CR_LOOP_SKIP_P3=1`):
  - Read `CLEAN_STREAK=` from `finish` (or `ack-rules`).
  - **Convergence**: when `CLEAN_STREAK >= 2` AND the latest round's `MODE` is `full`, run `bash "$T3_STATE" mark-converged --base "$BASE"` (verifies `HEAD`, `base_sha`, `SKIP_P3`, and `last_clean_mode == full`), then go to the skill's **step 8** with `LAST_REVIEWED_HEAD = REVIEWED_HEAD`.
  - Otherwise commit nothing and return to step 3 (`next` automatically picks `confirmation-full` with `PROFILE=default`).
- **4h. Rule-file edits need a person** (`VERDICT=needs-human`):
  - Show `RULE|` lines, `review.md`'s rule-file section, and `git diff <BASE_SHA>...<REVIEWED_HEAD> -- <paths>`.
  - Ask the user (host prompt tool / dialogue):
    - **(A) Approve**: run `bash "$T3_STATE" ack-rules <RULES_FP> --base "$BASE" "<who / why>"` (atomically commits approval and updates `CLEAN_STREAK=` via normal 4a rules), then continue with **4a**.
    - **(B) Restore rules**: revert removed/rewritten/type-changed rule lines, commit (step 6), return to step 3.
    - **(C) Stop**: handoff with `Stop reason: rule-edits-declined`.
  - "No response" is never consent; an agent never approves its own rule edits.
- **4b. Dirty**: if `MODE == step-back`, follow **4s**; else follow **step 5**.
- **4c. Step-back exhausted** (`PURPOSE=stop`): write `step-back-exhausted` handoff and ask the user:
  - (A) Authorize one more step-back (`CR_LOOP_MAX_STEP_BACKS=<done+1>`), (B) Split work, (C) Manual redesign, (D) Stop.
- **4s. Step-back procedure** (replaces step 5 for one round):
  1. Write the step-back assessment for every recurring class (root pattern, why approach invites it, structural change, prevention artifact) and record via `bash "$T3_STATE" note "..."`.
  2. If structural change crosses branch scope or alters a public contract, ask user before editing; if it alters user-visible UX, run **5a** first.
  3. Make one structural change per recurring class, fix remaining instances, add mandatory prevention artifact (**5c**), verify tests green, commit as `refactor(<scope>): t3-cr-loop step-back K — <headline>`, and return to step 3.

---

## Step 5 — Fix the Round's Classes

Process classes in severity order (`P0 > P1 > P2 > P3`):

- **5a. Interaction-logic guard (ALWAYS ON, no override)**:
  Any change to gestures/hit targets, modal/dialog/menu/sheet type, keyboard shortcuts/accessibility actions, navigation flow, or default actions (Return / primary button / outside-tap) MUST block and ask the user (current behavior, proposed change, 2–3 UX-preserving alternatives, explicit "skip / leave as-is") via the host's prompt tool (`ask_question` / `form-base` / plain text). "No response" is never consent. Record `Interaction decision:` + `Original finding:` trailers (or `User-deferred interaction finding:` + `t3-cr-state.sh note` on skip so it is never re-reported).
- **5b. Fix the whole class in one pass**:
  Read cited code, sweep in-scope code for unlisted instances, fix the root pattern, add regression test, update project docs if invariants changed (note: modifying existing lines in `CLAUDE.md`/`AGENTS.md` triggers 4h `needs-human`; pure additions pass as content), run affected tests green.
- **5c. Codify at the source (mandatory for recurring classes in `RECURRING=` or named by `step-back`)**:
  Add a repository prevention artifact in order of preference: (1) lint rule, (2) source-guard / invariant test, (3) repo `REVIEW.md` entry (`Pattern / Why it's wrong / How to check / How to fix`). Include `Prevention:` trailer and run `t3-cr-state.sh note`. **Never edit `~/.claude/**`, `~/.codex/**`, or global instruction files** (only `~/.config/t3-cr-loop/config.json` is written during user-confirmed Step 0 setup).

---

## Step 6–7 — Commit & Loop

Commit each dirty round as one commit (never `--no-verify`):
```text
fix(<scope>): review round N (<purpose>) — <short summary>

C4 [P1] <class title> — fixed <k> instances (<files>)
Prevention: <artifact> (C4)
Regression: <test names>
```
Record fixed classes with `bash "$T3_STATE" note "<Cn> fixed in <short-sha> (<k> instances)"`, then loop back to step 3.

---

## Step 9 — Handoff & Final Report (Shared)

### 9a. Handoff file (on any non-converged exit)
Write `.cr-loop-handoff-round-<N>.md` at the repo root (ignored by `t3-cr-state.sh tree-clean`, auto-deleted only on successful step 8 completion). Shared stop reasons: `head-drift-during-review`, `reviewer-error`, `reviewer-partial-failure`, `rule-edits-declined`, `step-back-exhausted`, `step-back-scope-declined`, `user-stopped`. Include stop reason, `HEAD`, `START`, counters, ledger summary table, active/absent models, and exact resume instructions.

### 9b. Final report (always)
- **Rounds & Models**: rounds executed by purpose/mode, models participated per round (and any absent models on approved partial council rounds).
- **Classes**: new, reopened, recurring, codified artifacts, out-of-scope items.
- **Tests**: commands run and final green status.
- **Commits**: `git log --oneline $START..HEAD`.
- **Stop reason & handoff path** (when written) + **Confirmation** (when converged: last two rounds clean on `<sha>`, second over whole diff).
- **Business-impact summary** (中文；始终输出，不可省略):
  - **有业务可观测改动** → 3–8 行中文（首行总览 + 按 commit 顺序描述“旧行为 → 新行为”）。
  - **全部为代码层重构** → 仅输出一行固定字面值 `无业务逻辑影响`。
  - **判断模糊时按“有业务改动”处理**。
