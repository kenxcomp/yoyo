---
name: t3-tri-plan
description: "Run the T3 Code-native triple-blind Trellis planning pipeline: parallel read-only multi-model design (3 blind candidates), zero-history anonymous blind judge locking winner + surgical cherry-picks + initial design before reveal, multi-model council/default design-review convergence loop, execution plan validation, and safe Phase 6 activation."
---

# T3 Tri-Plan (Triple-Blind Trellis Planning Pipeline)

PRD → **3 Blind Read-Only Designers** (parallel `delegate_task`) → **Zero-History Anonymous Blind Judge** (locks Primary Winner + Surgical Cherry-Picks + `initial-design.md` BEFORE attribution reveal) → **Multi-Model Design Review Convergence Loop** (council on `initial-full` & `step-back`, default single model on `incremental` & `confirmation-full`, class ledger + 3-round step-back + 2 consecutive clean rounds) → `implement.md` & non-seed JSONLs → Safe Phase 6 activation.

Works across **any repository with Trellis** without modifying the repository's existing `/trellis:dual-plan`, `workflow.md`, or `continue.md`.

## Authoritative Protocol (Read First)

Resolve `PLUGIN_ROOT` by following this `SKILL.md`'s real path (`../../` from `skills/t3-tri-plan/SKILL.md`), then **read `<PLUGIN_ROOT>/references/plan-protocol.md` in full** before taking action:

```bash
PLUGIN_ROOT=$(cd -- "$(dirname "$(readlink -f -- "<skill-dir>/SKILL.md" 2>/dev/null || perl -MCwd=abs_path -e 'print abs_path(shift)' -- "<skill-dir>/SKILL.md")")/../.." && pwd -P)
TRI_STATE="$PLUGIN_ROOT/scripts/t3-tri-plan-state.sh"
```

## Entry Arguments & Overrides

- **No args**: inspect current Trellis task, run `check-freshness`, and resume from the earliest invalid/incomplete stage (including recovering open async runs or Phase 6 activation).
- **Requirement text**: append to matching active task, or create a new Trellis task per `.trellis/workflow.md` **Authorization and Completion**.
- **`<0-6>`**: execute the specified phase (delivering that phase cleanly if single-phase was requested).
- **Per-invocation model/effort overrides** (natural language or `key=value`):
  - `designers=<spec1>,<spec2>,<spec3>` (replaces Phase 1 blind designers; normal run requires 3 distinct `provider/model`)
  - `judge=<spec>` (overrides Phase 2a blind judge ONLY)
  - `model=<spec>` (overrides Phase 3 default reviewer ONLY; never changes `judge`)
  - `council=<spec1>,<spec2>,...` (replaces Phase 3 council reviewers ONLY)
  - `single=<spec>` (forces Phase 3 single reviewer ONLY; conflicts with `model=`/`council=`; never changes Phase 1 `designers` or Phase 2a `judge`)
  - `effort=<val>` (fallback effort; inline `:effort` in any `<spec>` wins)
  - `reconfigure` (re-runs interactive setup wizard for `~/.config/t3-tri-plan/config.json`)

## Critical Compatibility & Safety Rules

1. **`/t3-tri-plan` is the sole resume/re-plan entrypoint for tri-plan tasks.** Native Trellis implementation/check/finish-work entrypoints may take over ONLY after Phase 6 reaches `activated` and `check-freshness` passes (or consume `ready` as a read-only planning deliverable).
2. **Legacy `dual-plan` tasks**: `inspect-task` detects `LEGACY_DUAL_PLAN`. By default keep them on `/trellis:dual-plan`; only migrate on explicit user confirmation (`migrate-legacy --confirm`), which preserves legacy files and never auto-trusts short hashes or mismatched `user_decision` digests.
3. **Never hand-edit `planning-state.json`, `active-run.json`, or `review-ledger.md`.** Always drive state transitions through `t3-tri-plan-state.sh` so `flock`, `.pending.tx.json`, `StrictJson.pm`, `worktree_fp` v3, and `review_baseline_sha256` stay intact.
4. **Never poll `delegate_task`**. After dispatching async children (`claim-slot` → `delegate_task` → `record-dispatch`), end your turn with verbatim child thread `link`s and wait for T3 Code wakeups.
