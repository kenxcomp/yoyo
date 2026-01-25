---
name: socratic-clarify
description: Guide multi-round Socratic questioning for requirement clarification
---

# Socratic Clarification Skill

When the UserPromptSubmit hook detects an unclear prompt, use this skill to guide the clarification process.

## Core Principle

**NEVER assume or infer** - even when you think you understand, ask to confirm. The goal is to help users articulate their actual needs, not to guess what they might mean.

## Questioning Methodology

### Phase 1: Identify the Core Intent
- "What problem are you trying to solve?" / "您想要解决什么问题？"
- "What is the desired end state?" / "期望的最终状态是什么？"

### Phase 2: Clarify Scope and Boundaries
- "What is included in this task, and what is explicitly excluded?" / "这个任务包含什么，明确排除什么？"
- "Are there any constraints I should be aware of?" / "有什么限制条件需要注意吗？"

### Phase 3: Define Success Criteria
- "How will we know when this is done correctly?" / "如何判断任务正确完成？"
- "What would a successful outcome look like?" / "成功的结果应该是什么样的？"

### Phase 4: Uncover Assumptions
- "I'm assuming X - is that correct?" / "我假设X是正确的，对吗？"
- "Are there any implicit requirements I should know about?" / "有什么隐含的需求我需要了解吗？"

## Question Types (Socratic Style)

| Type | Purpose | Example |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'better performance', what metrics matter most?" |
| **Probing assumptions** | Expose hidden beliefs | "What makes you certain this approach will work?" |
| **Probing reasons** | Understand the why | "What led you to this conclusion?" |
| **Questioning viewpoints** | Explore alternatives | "Have you considered approaching this differently?" |
| **Probing implications** | Explore consequences | "If we do this, what might be affected?" |
| **About the question** | Meta-level clarity | "Why is this question important to you now?" |

## Dialogue Flow

```
User submits prompt
     ↓
Hook evaluates clarity
     ↓
[UNCLEAR] → Ask ONE focused question (based on language detected)
     ↓
User responds
     ↓
Evaluate response clarity
     ↓
[Still unclear] → Ask next focused question
     ↓
[Clear enough] → Proceed with action
```

## Bilingual Interaction

- **Detect language**: Match the user's input language
- **English input** → English questions
- **Chinese input** → Chinese questions
- **Mixed input** → Prefer the dominant language

## Anti-Patterns to Avoid

1. ❌ Asking multiple questions at once
2. ❌ Making assumptions and proceeding
3. ❌ Leading questions that suggest answers
4. ❌ Over-questioning simple, clear requests
5. ❌ Ignoring context from ongoing conversation

## When to Stop Questioning

- User has provided explicit, actionable details
- User explicitly says "just do it" or "proceed with your judgment"
- Context from conversation history makes the intent clear
- The request is a simple follow-up to an established task
