---
name: socratic-clarify
description: Clarify unclear requirements using Socratic multiple choice questions. Use when user requests are vague, ambiguous, or missing key information about purpose, constraints, or success criteria.
---

# Socratic Clarification Skill

Guide Claude to ask targeted clarifying questions when requirements are unclear.

## When to Use This Skill

**Invoke this skill when:**
- User's request is vague (e.g., "improve the code", "fix the bug", "optimize this")
- Missing critical information: Purpose, Constraints, or Success Criteria
- Multiple interpretations are possible
- User explicitly invokes `/clarify`

**DO NOT use when:**
- Request is already specific and actionable
- User says "just do it" or "proceed with your judgment"
- Following up on an established task with clear context
- Simple greetings, confirmations, or built-in commands (starting with `/`)

## Core Principle

**NEVER assume or infer** - even when you think you understand, ask to confirm. The goal is to help users articulate their actual needs, not to guess what they might mean.

## Questioning Methodology

### Step 1: Gather Context First

Before asking questions, quickly assess:
- Current project state (files, architecture)
- Recent conversation history
- Any relevant documentation (README, etc.)

This context helps form more relevant, specific questions rather than generic ones.

### Step 2: Identify the Gap

Focus on ONE of these areas (in priority order):

| Area | When to Ask | Example Gap |
|------|-------------|-------------|
| **Purpose** | "What" is unclear | "Improve performance" - what aspect? |
| **Constraints** | "How" is unclear | "Add feature" - any limitations? |
| **Success Criteria** | "Done" is unclear | "Fix bug" - what is correct behavior? |

### Step 3: Ask ONE Multiple Choice Question

**CRITICAL: Always use (A), (B), (C) format**

This is REQUIRED, not optional. Users respond better to concrete options.

#### English Format:
```
To help you better, I need to clarify one thing:

What type of [improvement/fix/feature] are you looking for?
(A) [Specific option 1]
(B) [Specific option 2]
(C) [Specific option 3]
(D) Other (please specify)
```

#### Chinese Format:
```
为了更好地帮助您，我需要确认一点：

您希望进行哪种[改进/修复/功能]？
(A) [具体选项1]
(B) [具体选项2]
(C) [具体选项3]
(D) 其他（请说明）
```

## One Question Per Message Rule

- Ask **ONE question at a time** - never multiple questions
- If a topic needs more exploration, break it into sequential questions
- Wait for the answer before asking the next question
- This makes it easier for users to respond clearly

## Response Examples

### Example 1: Vague Performance Request

**User:** "Make this faster"

**Claude's Response:**
```
I'd be happy to help optimize this. To focus on the right area:

What aspect of performance is most important?
(A) Reduce initial load time
(B) Decrease memory usage
(C) Improve response speed for user interactions
(D) All of the above - comprehensive optimization
```

### Example 2: Unclear Bug Fix (Chinese)

**User:** "修复登录问题"

**Claude's Response:**
```
我来帮您修复登录问题。请先确认一下：

您遇到的是哪种情况？
(A) 页面崩溃或显示错误
(B) 登录失败但没有错误提示
(C) 登录成功但立即退出
(D) 其他问题（请描述）
```

### Example 3: Unclear Scope

**User:** "Add error handling"

**Claude's Response:**
```
I'd like to add error handling. Should the changes be:
(A) Limited to the specific file you're working with
(B) Across the entire module
(C) Project-wide implementation
```

### Example 4: Clear Request (No Questions Needed)

**User:** "Add a logout button to the Nav component in src/components/Nav.tsx that calls the logout() function from auth.ts"

**Claude's Response:**
```
I'll add the logout button to Nav.tsx right away.
[Proceeds directly with implementation]
```

## Question Types (Socratic Style)

| Type | Purpose | Example |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'improve', do you mean: (A) faster, (B) cleaner, or (C) fewer bugs?" |
| **Probing assumptions** | Expose hidden beliefs | "Are you assuming: (A) users have network, (B) offline needed, or (C) hybrid?" |
| **Probing reasons** | Understand the why | "What led you to this approach?" (open-ended, rare) |
| **Questioning viewpoints** | Explore alternatives | "Have you considered: (A) alternative A, (B) alternative B?" |

## Bilingual Detection

- **English input** → English questions
- **Chinese input** → Chinese questions (中文输入 → 中文提问)
- **Mixed input** → Use the dominant language

## Anti-Patterns to Avoid

| DO NOT | DO INSTEAD |
|--------|------------|
| Ask open-ended questions | Always provide (A), (B), (C) options |
| Ask multiple questions at once | Ask ONE question, wait for answer |
| Re-ask if user already answered | Proceed with user's choice |
| Question clear requests | Just execute them |
| Assume without asking | Clarify first, then act |
| Ask generic questions | Check project context first |

## When to Stop Questioning

- User has provided explicit, actionable details
- User explicitly says "just do it" or "proceed with your judgment"
- Context from conversation history makes the intent clear
- The request is a simple follow-up to an established task
- Project context (files, docs, commits) provides sufficient clarity
