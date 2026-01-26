---
name: socratic-clarify
description: Guide multi-round Socratic questioning for requirement clarification
---

# Socratic Clarification Skill

When the UserPromptSubmit hook detects an unclear prompt, use this skill to guide the clarification process.

## Core Principle

**NEVER assume or infer** - even when you think you understand, ask to confirm. The goal is to help users articulate their actual needs, not to guess what they might mean.

## Understanding the Idea (Before Questioning)

**IMPORTANT**: Before asking clarification questions, Claude should first gather context:

1. **Check Project State**
   - Review current files and directory structure
   - Understand the codebase architecture
   - Identify relevant components or modules

2. **Review Documentation**
   - Read README, CHANGELOG, or relevant docs
   - Understand existing conventions and patterns
   - Note any documented constraints or guidelines

3. **Examine Recent Commits**
   - Look at recent commit history
   - Understand the project direction
   - Identify ongoing work or recent changes

This context helps form more relevant, specific questions rather than generic ones.

## Questioning Methodology

### Focus Areas (In Priority Order)

| Area | Key Questions | Example |
|------|---------------|---------|
| **Purpose** | What problem are you solving? What's the goal? | "What should this feature accomplish?" |
| **Constraints** | What limitations must be respected? | "Are there performance/compatibility requirements?" |
| **Success Criteria** | How do we know it's done correctly? | "What would a successful outcome look like?" |

### Question Format: Multiple Choice is REQUIRED

**CRITICAL: You MUST use multiple choice format with (A), (B), (C) options.**

This is NOT optional. Every clarification question MUST provide concrete options for the user to choose from.

```
CORRECT Format (REQUIRED):
"您希望进行哪种分析：
 (A) 个股基本面分析
 (B) 技术指标分析
 (C) 投资组合分析
 (D) 综合分析？"

"Which approach do you prefer:
 (A) Optimize for speed
 (B) Optimize for readability
 (C) Balance both?"

"What output format do you need:
 (A) Summary report
 (B) Detailed analysis
 (C) Visualization charts
 (D) Raw data export?"
```

```
WRONG Format (DO NOT USE):
❌ "What specific analysis do you want to perform?"
❌ "What is the desired output?"
❌ "Can you provide more details about what you need?"
```

**Open-ended questions are only acceptable when you genuinely cannot enumerate ANY reasonable options** (this should be extremely rare - most questions can have options).

### One Question Per Message Rule

- Ask **ONE question at a time** - never multiple questions
- If a topic needs more exploration, break it into sequential questions
- Wait for the answer before asking the next question
- This makes it easier for users to respond clearly

## Dialogue Flow

```
User submits prompt
     ↓
Claude gathers context (files, docs, commits)
     ↓
Hook evaluates clarity
     ↓
[UNCLEAR] → Ask ONE multiple choice question with (A), (B), (C) options
     ↓
User responds
     ↓
Evaluate response clarity
     ↓
[Still unclear on same topic] → Ask follow-up question
[New topic unclear] → Ask about new topic
[Clear enough] → Proceed with action
```

## Question Types (Socratic Style)

| Type | Purpose | Example (Multiple Choice When Possible) |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'improve', do you mean: (A) faster, (B) cleaner code, or (C) fewer bugs?" |
| **Probing assumptions** | Expose hidden beliefs | "Are you assuming: (A) users always have network, (B) offline support is needed, or (C) hybrid approach?" |
| **Probing reasons** | Understand the why | "What led you to this approach?" (open-ended) |
| **Questioning viewpoints** | Explore alternatives | "Have you considered: (A) alternative A, (B) alternative B, or (C) current approach is best?" |
| **Probing implications** | Explore consequences | "If we do this, what might be affected?" (open-ended) |

## Bilingual Interaction

- **Detect language**: Match the user's input language
- **English input** → English questions
- **Chinese input** → Chinese questions
- **Mixed input** → Prefer the dominant language

### Chinese Multiple Choice Examples

```
"您希望采用哪种方式：
 (A) 优先考虑性能
 (B) 优先考虑可读性
 (C) 两者兼顾？"

"改动范围应该是：
 (A) 仅限当前文件
 (B) 整个模块
 (C) 全项目？"
```

## Anti-Patterns to Avoid

1. ❌ **Using open-ended questions** - ALWAYS use multiple choice format with (A), (B), (C) options
2. ❌ Asking multiple questions at once
3. ❌ Making assumptions and proceeding
4. ❌ Skipping context gathering before questioning
5. ❌ Over-questioning simple, clear requests
6. ❌ Ignoring context from ongoing conversation
7. ❌ Asking generic questions without checking project context first

## When to Stop Questioning

- User has provided explicit, actionable details
- User explicitly says "just do it" or "proceed with your judgment"
- Context from conversation history makes the intent clear
- The request is a simple follow-up to an established task
- Project context (files, docs, commits) provides sufficient clarity
