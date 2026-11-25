---
name: t3-cr-loop
description: Run a T3 Code-native multi-model code review convergence loop (council on Round 1 and step-back via parallel delegate_task, default single model on incremental and confirmation rounds) until two consecutive clean rounds on the same HEAD, then stop without pushing, opening a PR, or merging.
---

# T3 CR Loop (Review Only — Local Convergence)

Run multi-model review rounds in T3 Code against `<base-ref>`, fix every bug **class** reported, commit, and repeat until **two consecutive rounds are clean on the same HEAD** (the second covering the whole diff), then **stop**. No push, no PR, no merge.

## Shared Protocol (Authoritative — Read First)

Resolve `PLUGIN_ROOT` by following this `SKILL.md`'s real path (`../../` from `skills/t3-cr-loop/SKILL.md`), then **read `<PLUGIN_ROOT>/references/review-protocol.md` in full** before step 2. It defines:
- Step 0: live model discovery (`orchestrator_capabilities`), first-run onboarding (`~/.config/t3-cr-loop/config.json`), project `.t3-cr-loop.json` provider authorization, and per-invocation `model=` / `effort=` / `council=` / `single=` / `reconfigure` overrides
- Steps 2–7: `scripts/t3-cr-state.sh`, parallel `delegate_task` (`isolation: "shared"`, `role: "review"`), strict JSON validation, retry & partial-failure handling, council synthesis, base-sourced rule gate (4h), 3-round council `step-back`, always-on interaction guard (5a), and codify-at-source (5c)
- Step 9: handoff file and final report with mandatory Chinese business-impact summary

## Procedure

1. **Step 0 — Capabilities & Configuration**: run protocol Step 0 (`orchestrator_capabilities` + `t3-cr-state.sh config-show`, guiding first-time setup if `CONFIGURED=0` or `reconfigure`).
2. **Step 1 — Preflight**:
   - **Resolve `BASE`** (local ref read, no network):
     ```bash
     DEFAULT_BRANCH=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
     if [ -z "$DEFAULT_BRANCH" ]; then
       if   git rev-parse --verify --quiet refs/remotes/origin/main   >/dev/null; then DEFAULT_BRANCH=main
       elif git rev-parse --verify --quiet refs/remotes/origin/master >/dev/null; then DEFAULT_BRANCH=master
       else DEFAULT_BRANCH=main
       fi
     fi
     BASE="${EXPLICIT_BASE:-origin/$DEFAULT_BRANCH}"
     ```
   - If `BASE` is a `<remote>/<branch>` ref, refresh via `git fetch <remote> <branch> --quiet` (abort on failure). Skip fetch if local ref.
   - Check clean working tree via `bash "$T3_STATE" tree-clean` (must print `TREE=clean`; ignores only untracked root `.cr-loop-handoff-round-<N>.md`).
   - Record `START=$(git rev-parse HEAD)` and `FEATURE_BRANCH=$(git branch --show-current)` (abort on detached HEAD).
   - Verify `git rev-parse --verify "$BASE"`.
   - **Base-currency gate** (`CR_LOOP_REQUIRE_REBASED=1`, set `0` to skip): check `git merge-base --is-ancestor "$BASE" HEAD`. On exit 1 (stale branch), pause and ask the user (host prompt tool / A–B, no "review anyway"): **(A) Rebase first** (print `git rebase "$BASE"` + re-invocation, stop — never auto-rebase) or **(B) Abort**.
3. **Steps 2–7 — Review Loop**: run protocol Steps 2–7 with `BASE` from step 1.
4. **Step 8 — Verify Final State & Stop** (entered after convergence):
   - Check **(a)** `bash "$T3_STATE" tree-clean` prints `TREE=clean`, and **(b)** `git rev-parse HEAD` equals `$LAST_REVIEWED_HEAD`.
   - **No remote interaction, no checkout, no merge.** Worktree and branch stay untouched.
   - If both (a) and (b) hold, delete stale `.cr-loop-handoff-round-*.md` at repo root (`rm -f`) and note cleanup count; keep the ledger. If either drifted, do NOT delete handoffs and report the deviation clearly.
5. **Step 9 — Report / Handoff**: output protocol Step 9b lines (including mandatory Chinese business-impact summary), plus final state, `Worktree: preserved at <pwd>`, and informational next-step hints (`git push`, `t3-cr-loop-pr`, `t3-cr-loop-merge`).
