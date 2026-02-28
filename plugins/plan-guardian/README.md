# plan-guardian

A Claude Code plugin that enforces rigorous plan review before execution. Consolidates the plan-review workflow (agent, hooks, context injection) into a single distributable plugin.

## Features

- **Plan-reviewer agent** — A dedicated agent that reviews plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent alignment)
- **ExitPlanMode hook** — Blocks exiting plan mode until the plan-reviewer has completed and approved the plan
- **EnterPlanMode hook** — Clears the previous review state when entering a new planning session
- **SessionStart injection** — Automatically injects Plan Mode Rules into every session as additionalContext
- **/plan-review skill** — Manually trigger a plan review at any time

## How It Works

1. When you enter plan mode, the `EnterPlanMode` hook clears any previous review state in `.plan-review/yoplan.md`.
2. You write your plan to `.plan-review/yoplan.md`.
3. You launch the `plan-reviewer` agent, which evaluates the plan against all 8 criteria.
4. If the plan passes, the agent marks `- [x] Have I reviewed this plan?` in the file.
5. The `ExitPlanMode` hook checks for this checkbox — only allowing you to exit plan mode if the review passed.

## Review Criteria

The plan-reviewer agent evaluates:

1. **Edge Cases** — Boundary conditions, null inputs, race conditions
2. **High-Impact Abnormal Scenarios** — Failure modes, data loss, security risks
3. **Syntax & Style Consistency** — Alignment with existing codebase patterns
4. **Logical Consistency** — No contradictions, circular dependencies, or impossible orderings
5. **Verification Steps** — Specific, measurable acceptance criteria
6. **Unclear Intentions** — No ambiguous goals or unstated assumptions
7. **Semantic Ambiguity** — No language that can be interpreted multiple ways
8. **User's Core Intent** — Plan delivers what was actually requested

## File Layout

```
plan-guardian/
├── .claude-plugin/
│   └── plugin.json
├── agents/
│   └── plan-reviewer.md
├── hooks/
│   └── hooks.json
├── skills/
│   └── plan-review/
│       └── SKILL.md
├── scripts/
│   └── inject-skill.sh
├── commands/
│   └── .gitkeep
└── README.md
```

## Notes

- The `.plan-review/` directory is created in the project working directory. Consider adding it to `.gitignore`.
- The plan-reviewer agent uses `memory: user` for persistent learning across sessions.
- Version: 1.0.0
