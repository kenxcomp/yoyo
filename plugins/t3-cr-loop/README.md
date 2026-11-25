# t3-cr-loop

T3 Code-native multi-model code review convergence loops, forked from `codex-cr-loop` v1.8.1 to avoid conflicts and take full advantage of T3 Code's cross-provider orchestration (`orchestrator_capabilities`, parallel `delegate_task`, native `pull_request_*` tools, and interactive prompts).

## Three Independent Skills

| Skill | After Convergence |
|---|---|
| `t3-cr-loop` | **Stops locally.** No push, no PR, no merge. |
| `t3-cr-loop-merge` | **Merges** into the local default branch (`CR_MERGE_TARGET`). Worktree-aware, never pushes. |
| `t3-cr-loop-pr` | **Auto-rebases** onto the latest PR target (default ON) + 1 `full` confirmation round, pushes with explicit reviewed SHA refspec (and pre-rebase pinned `--force-with-lease` if updating an existing PR), and opens/updates the PR via T3 Code `pull_request_*` tools (`gh` fallback). |

## Multi-Model Council & First-Run Setup

1. **Dynamic host discovery**: calls T3 Code `orchestrator_capabilities` (with `search` when `omittedModels > 0`) to inspect enabled providers (`canRunChildTask == true`), exact model IDs, and each provider's real effort option key (`thought_level` for Antigravity, `effort` for Claude, `reasoningEffort` for Codex).
2. **First-run onboarding** (when `~/.config/t3-cr-loop/config.json` does not exist, or when `reconfigure` is passed):
   - Choose a **default single reviewer** + effort (used on `incremental`, 2nd-round `confirmation-full`, and PR 8.0 `post-rebase-confirmation` rounds).
   - Multi-select **council reviewers** for `initial-full` (Round 1) and `step-back` rounds (pre-recommends available `antigravity/gemini-4-neon`, `claudeAgent/claude-opus-5-5`, and `codex/gpt-6.2-sol`).
   - Choose **unified effort** (strict intersection of allowed values across selected models, never silently clamped) or **per-model effort**.
   - Persists only user-confirmed settings to `~/.config/t3-cr-loop/config.json` (overridable by `T3_CR_LOOP_CONFIG`, repo `.t3-cr-loop.json`, and per-invocation args).
3. **Per-invocation overrides**:
   ```text
   Run t3-cr-loop model=claudeAgent/claude-opus-5-5 effort=xhigh
   Run t3-cr-loop council=antigravity/gemini-4-neon:xhigh,claudeAgent/claude-opus-5-5:max,codex/gpt-6.2-sol:high
   Run t3-cr-loop single=codex/gpt-6.2-sol:high
   Run t3-cr-loop reconfigure
   ```
   Unavailable models or invalid effort values fail explicitly — the loop never silently swaps providers/models.

## Installing in T3 Code

### Option 1: Install skills into `~/.agents/skills/` (recommended for local checkout)

```bash
bash plugins/t3-cr-loop/scripts/install-skills.sh
bash plugins/t3-cr-loop/scripts/install-skills.sh --check
```

Then run **"Restart agent session"** in T3 Code so the three skills (`t3-cr-loop`, `t3-cr-loop-merge`, `t3-cr-loop-pr`) register in the `/` and `$` menus. Use `--project /path/to/repo` for project-local installation or `--uninstall` to remove symlinks.

### Option 2: Add via `.agents/plugins/marketplace.json`

Add this repository (`git@github.com:kenxcomp/yoyo.git`, ref `main`) as a plugin marketplace with sparse paths `.agents/plugins` and `plugins/t3-cr-loop`.

## Security Boundary (`isolation: "shared"`)

Child review delegates run with `role: "review"`, `mode: "async"`, and `isolation: "shared"`. Unlike CLI `codex exec --sandbox read-only -c project_doc_max_bytes=0`:

- T3 `delegate_task` does not provide OS-level read-only sandboxing or suppress provider startup loading of working-tree `AGENTS.md`/`CLAUDE.md`.
- `t3-cr-loop` instead enforces:
  1. Base-pinned rules (`git show <BASE_SHA>:<path>`) in the prompt, treating working-tree rules as untrusted content.
  2. Deterministic host rule inspection (`scripts/review-rules.sh`, raw git modes & blobs, immune to `.gitattributes` and `diff.relative=true`) blocking removed/rewritten/deleted/binary/symlink/gitlink rule edits with `VERDICT=needs-human` until explicitly approved via `ack-rules`.
  3. JSON-only child responses validated fail-closed (`scripts/parse-review.pl`), plus start/finish `tree_fp` (v2) drift checks covering tracked diffs and non-ignored, non-handoff untracked files (gitignored files, edited-and-reverted files, git metadata, and startup-loaded instructions are outside `tree_fp`'s visibility).
  4. Project `.t3-cr-loop.json` provider authorization: any `providerInstanceId` not in the user's `authorizedProviders` requires explicit user approval before sending repo context.

## Running Regression Tests

```bash
bash plugins/t3-cr-loop/scripts/test-t3-cr-state.sh
```
