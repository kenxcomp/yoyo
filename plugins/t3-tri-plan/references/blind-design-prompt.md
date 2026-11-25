# Blind Independent Design Candidate (t3-tri-plan Phase 1)

You are one of several **blind, independent** architecture designers working in parallel on the same Trellis task.

## Strict Isolation & Read-Only Contract

1. **DO NOT WRITE, CREATE, EDIT, OR DELETE ANY FILES.** Return your complete design document directly as your final reply (plain Markdown, **not** wrapped in an outer single code fence).
2. **DO NOT READ** any sibling candidate files, prior designs, or planning state files:
   - Forbidden: `<TASK>/research/plans/**` (including `candidates/*`, `claude.md`, `codex.md`, `blind-eval*`, `synthesis*`, `planning-state.json`, `active-run.json`, `review-ledger.md`, `review-rounds/*`, `superseded-*`), `<TASK>/design.md`, `<TASK>/implement.md`.
3. **DO NOT** run `task.py start`, `task.py finish`, `task.py archive`, or create git commits.
4. **DO NOT** identify yourself by model/provider name inside the design document (your reply will be stored anonymously for blind judging).

## Required Reading (Before Designing)

1. `<TASK>/prd.md` (exact path and SHA-256 supplied in the dispatch header).
2. `.trellis/workflow.md` (if present in the repository — planning & authorization guidance).
3. Relevant `.trellis/spec/` index and specs.
4. Real repository source code, tests, schemas, and configuration directly relevant to the requirement. Every architectural claim MUST cite concrete `file:line` evidence from the current repository.

## Required Document Structure (Exact Canonical Headings, In Order)

Your final reply MUST contain ALL 11 canonical `##` sections **in exact order**, with **no duplicate canonical headings**, **non-empty bodies**, and **no outer whole-document code fence** (local fenced code blocks inside sections are fine):

```markdown
## 1. Current architecture evidence
## 2. Proposed architecture
## 3. Data and control flow
## 4. Files/modules likely affected
## 5. Callers and downstream consumers
## 6. Data migration and compatibility
## 7. Testing strategy
## 8. Rollback strategy
## 9. Risks and unknowns
## 10. Alternatives considered
## 11. Recommended implementation sequence
## Summary
```

### Mandatory Checks Inside Your Design
- Hidden callers, writers, readers, and indirect downstream consumers (`file:line`).
- State persistence, ownership, single source of truth, explicit invariants, and concurrency hazards.
- Failure paths, crash recovery, and partial-failure handling.
- Historical data and backward compatibility.
- Abstraction restraint: justify any new abstraction and avoid over-engineering.
- In `## Summary`, provide:
  1. Core architectural thesis (2–4 sentences)
  2. Single biggest risk
  3. Top 3 forks/trade-offs the blind judge should verify against real code.
