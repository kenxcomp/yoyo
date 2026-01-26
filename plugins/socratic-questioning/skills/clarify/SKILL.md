---
name: clarify
description: Explicitly invoke Socratic questioning to clarify the current request or a specific topic
argument-hint: "[optional: topic to clarify]"
---

# Explicit Clarification Command

The user has explicitly requested clarification by invoking `/clarify`. Apply the socratic-clarify methodology rigorously.

## Your Task

1. **Review Context**: Look at the current conversation and any provided arguments ($ARGUMENTS)
2. **Identify Gaps**: Determine what is unclear about the most recent request
3. **Ask ONE Question**: Use multiple choice format (A), (B), (C)
4. **Match Language**: Use English or Chinese based on user's input

## Focus Areas (Priority Order)

| Area | Key Question |
|------|--------------|
| **Purpose** | What is the user trying to achieve? |
| **Constraints** | What limitations must be respected? |
| **Success Criteria** | How will we know it's done correctly? |

## Response Format

**Always use multiple choice:**

```
To clarify your request:

[Your clarifying question here]
(A) [Option 1]
(B) [Option 2]
(C) [Option 3]
(D) Other (please specify)
```

**Chinese format:**

```
为了明确您的需求：

[您的澄清问题]
(A) [选项1]
(B) [选项2]
(C) [选项3]
(D) 其他（请说明）
```

## Important

- Even if you think you understand, **ask to confirm** - the user invoked `/clarify` because they want explicit verification
- Ask only **ONE** question at a time
- If $ARGUMENTS is provided, focus clarification on that specific topic
- If no recent request exists, ask the user what they'd like help with
