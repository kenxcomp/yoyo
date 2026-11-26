# T3 Workflow (`t3-workflow`)

A T3 Code-native orchestration plugin bundling three composable skills that work alongside [`t3-tri-plan`](../t3-tri-plan) and [`t3-cr-loop`](../t3-cr-loop) to form an end-to-end release-branch workflow:

```text
t3-branch-coordinator (interview, UI mockups, centralized dispatch via t3_thread_launch)
  └── medium/large/high-risk task session (Gemini 4 Neon high)
        ├── /t3-tri-plan        (triple-blind design + council review + Phase 6 activation)
        ├── /t3-tdd-adversarial (contract-first Red/Blue parallel worktree TDD + net-patch gate)
        ├── /t3-cr-loop         (multi-model code review + exact PR-diff & SHA pre-push gate)
        └── /t3-task-cleanup    (fail-closed file-by-file, worktree, and CAS branch wrap-up)
```

## Included Skills

| Skill | Role |
| --- | --- |
| `t3-branch-coordinator` | Bootstraps or binds `<TARGET_BRANCH>`, interviews requirements, runs dual-model UI mockups (`Gemini 4 Neon high` + `Claude Opus 5.5 medium`) for UI changes, defines completion evidence, and launches governed top-level task sessions via `t3_thread_launch` with centralized dispatch & queued reporting. |
| `t3-tdd-adversarial` | Runs contract-first, process-isolated Red/Blue TDD in parallel worktrees (Blue: `Claude Opus 5.5 medium`; Red: `Gemini 4 Hydrogen high`, escalating to `GPT-6.2 Sol high` for hardcore logic/strong-typing edge cases), enforces audited single net-patch allowlist gates, verifies per-ID observable red-to-green proof, and enforces exact PR-diff coverage & SHA refspec pushing. |
| `t3-task-cleanup` | Fail-closed, task-scoped post-merge wrap-up: enumerates tracked/untracked/ignored (`--ignored=traditional`) files before file-by-file cleanup, verifies authoritative T3 identity & exclusivity before removing ONLY this task's child worktrees, runs dry-run-checked scoped `worktree prune`, atomically deletes verified temp branches via `git update-ref -d`, and reports `git status` + `df -h .`. |

## Installation

Install all three skills into `~/.agents/skills/` (and optionally `~/.claude/skills/`):

```bash
bash plugins/t3-workflow/scripts/install-skills.sh
bash plugins/t3-workflow/scripts/install-skills.sh --target ~/.claude/skills
bash plugins/t3-workflow/scripts/install-skills.sh --check
```

To install the entire T3 Code suite from this repository:

```bash
bash plugins/t3-workflow/scripts/install-skills.sh
bash plugins/t3-tri-plan/scripts/install-skills.sh
bash plugins/t3-cr-loop/scripts/install-skills.sh
```
