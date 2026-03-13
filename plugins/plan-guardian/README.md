# plan-guardian

A Claude Code plugin that provides rigorous plan review capabilities. Claude autonomously decides when to invoke the reviewer based on plan complexity and risk, or users can trigger it manually via `/plan-review`.

## Features

- **Plan-reviewer agent** — A dedicated agent that reviews plans against 8 quality criteria (edge cases, abnormal scenarios, style consistency, logical consistency, verification steps, unclear intentions, semantic ambiguity, user intent alignment)
- **EnterPlanMode hook** — Clears the previous review state when entering a new planning session
- **SessionStart injection** — Injects plan review guidelines into every session as additionalContext
- **/plan-review skill** — Manually trigger a plan review at any time

## How It Works

1. When you enter plan mode, the `EnterPlanMode` hook clears any previous review state.
2. You write your plan.
3. Claude may autonomously launch the `plan-reviewer` agent based on its judgment, or you can invoke `/plan-review` manually.
4. The agent evaluates the plan against all 8 criteria, proposes fixes for any issues, and reports results.
5. ExitPlanMode is **not blocked** — the review is advisory, not a gate.

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
- Version: 1.2.0
