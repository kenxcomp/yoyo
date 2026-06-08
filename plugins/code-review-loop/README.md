# Code Review Loop

Codex-native review-loop skills modeled after yoyo's Claude Code `codex-cr-loop` commands, but implemented as Codex plugin skills.

The plugin provides three entry points:

- `code-review-loop`: review, fix, test, commit, and stop after two consecutive clean rounds.
- `code-review-loop-pr`: same convergence loop, then push the current feature branch and create or update a pull request.
- `code-review-loop-merge`: same convergence loop, then merge the reviewed feature branch into a local target branch without pushing.

Each skill uses the local `code-reviewer` skill as its review rubric when available at `/Users/kennethx/.codex/skills/code-reviewer/SKILL.md`. A round is clean only when no Critical, High, Medium, or Low findings remain. Nit-only findings are treated as clean unless the user asks for strict mode.

## Usage

Ask Codex for one of the skills by name:

```text
Use code-review-loop against origin/main.
Use code-review-loop-pr for this branch.
Use code-review-loop-merge into local main.
```

## Install From Codex

In Codex, use **Add marketplace** with:

```text
Source:
git@github.com:kenxcomp/yoyo.git

Git ref:
main

Sparse paths:
.agents/plugins
plugins/code-review-loop
```

Leaving sparse paths blank also works, but the two paths above keep the install checkout small.

## Shared Guarantees

- The working tree must be clean before the loop starts.
- The branch must be based on the selected review base unless the user explicitly disables that gate.
- Two consecutive clean rounds against the same HEAD are required before the post-review action.
- Findings are fixed in severity order and verified with focused tests before a fix commit.
- Any user-visible interaction change pauses for explicit user confirmation.
- `--force`, `--force-with-lease`, and `--no-verify` are forbidden.
- Non-converged exits write `.cr-loop-handoff-round-<N>.md` in the repository root.
- The final report always includes a Chinese business-impact summary; internal-only work must use the exact line `无业务逻辑影响`.
