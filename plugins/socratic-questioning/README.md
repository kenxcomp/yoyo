# Socratic Questioning Plugin

A plugin that guides Claude to use Socratic questioning methods for requirement clarification. Instead of making assumptions about unclear user prompts, Claude will ask focused questions to ensure accurate understanding before taking action.

## Installation

### Method 1: Via Marketplace (Recommended)

```
/plugin marketplace add kenxcomp/yoyo
/plugin install socratic-questioning@kenxcomp-yoyo
```

### Method 2: Local Development

```bash
git clone https://github.com/kenxcomp/yoyo
claude --plugin-dir ./yoyo/plugins/socratic-questioning
```

> **Note**: Requires Claude Code version 1.0.33 or later.

## Features

### Context-Aware Questioning

Before asking clarification questions, Claude first gathers context:
- **Project State**: Reviews files, directory structure, and codebase architecture
- **Documentation**: Checks README, CHANGELOG, and relevant docs
- **Recent Commits**: Examines commit history to understand project direction

This context helps form more relevant, specific questions rather than generic ones.

### UserPromptSubmit Hook

This plugin uses a **UserPromptSubmit hook** to automatically evaluate every user prompt for clarity. When unclear points are detected, Claude will:

1. Gather project context (files, docs, recent commits)
2. Identify what information is missing or ambiguous
3. Ask **ONE multiple choice question** with (A), (B), (C) options
4. Wait for user response before proceeding
5. Repeat until the request is clear enough for action

### Focus Areas

The hook evaluates prompts against three key areas:

| Area | Description |
|------|-------------|
| **Purpose** | What is the user trying to achieve? What problem are they solving? |
| **Constraints** | What limitations, boundaries, or requirements must be respected? |
| **Success Criteria** | How will we know when this is done correctly? |

### Multiple Choice Questions (Required)

The plugin **always uses multiple choice questions** with (A), (B), (C) options:

```
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
 (C) Visualization charts?"
```

Open-ended questions are only used when options genuinely cannot be enumerated (rare).

### One Question Per Message

- Claude asks **ONE question at a time** - never multiple questions
- If a topic needs more exploration, it breaks into sequential questions
- This makes it easier for users to respond clearly

### Bilingual Support

The plugin automatically detects the user's input language and responds accordingly:
- English input → English questions
- Chinese input → Chinese questions (中文输入 → 中文提问)

### What It Does NOT Do

- **Does not infer**: Even if Claude can guess the likely intent, it will ask to confirm
- **Does not over-question**: Simple, clear requests and follow-ups pass through without delay
- **Does not block**: Greetings, confirmations, and ongoing conversation context are recognized as clear

## Directory Structure

```
socratic-questioning/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata
├── hooks/
│   └── hooks.json            # UserPromptSubmit hook definition
├── skills/
│   └── socratic-clarify/SKILL.md   # Questioning methodology skill
├── commands/                 # Custom commands (reserved)
├── agents/                   # Custom agents (reserved)
└── README.md                 # This file
```

## How It Works

```
User submits prompt
        ↓
Claude gathers context (files, docs, commits)
        ↓
UserPromptSubmit hook evaluates clarity
        ↓
┌──────────────────────────────────────────────┐
│ Is the prompt clear enough?                   │
├──────────┬───────────────────────────────────┤
│  YES     │  NO                               │
│  ↓       │  ↓                                │
│ Proceed  │ Ask ONE multiple choice           │
│ normally │ question with (A)(B)(C) options   │
└──────────┴───────────────────────────────────┘
                    ↓
           User responds
                    ↓
           Re-evaluate clarity
                    ↓
           (Loop until clear)
```

## Example Interactions

### Example 1: Multiple Choice Question

**User**: "Improve the performance"

**Claude**: "To help improve performance, I'd like to understand your priority. Which aspect should I focus on:
(A) Reduce load time
(B) Decrease memory usage
(C) Improve response speed
(D) All of the above?"

### Example 2: Scope Clarification

**User**: "Add error handling"

**Claude**: "I'd like to add error handling. Should the changes be:
(A) Limited to the specific file you're working with
(B) Across the entire module
(C) Project-wide?"

### Example 3: Bug Report Clarification

**User**: "Fix the login bug"

**Claude**: "To help fix this bug, what behavior are you experiencing:
(A) Page crashes or shows error
(B) Login fails silently (no error message)
(C) Incorrect credentials are accepted
(D) Session expires immediately after login?"

### Example 4: Clear Request (No Questions)

**User**: "Add a logout button to the navigation bar in `src/components/Nav.tsx` that calls the `logout()` function from `auth.ts`"

**Claude**: *Proceeds directly with implementation*

## Socratic Question Types

| Type | Purpose | Example |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'improve', do you mean: (A) faster, (B) cleaner, or (C) fewer bugs?" |
| **Probing assumptions** | Expose hidden beliefs | "Are you assuming: (A) users have network, (B) offline needed, or (C) hybrid?" |
| **Probing reasons** | Understand the why | "What led you to this approach?" |
| **Questioning viewpoints** | Explore alternatives | "Have you considered alternative approaches?" |
| **Probing implications** | Explore consequences | "If we do this, what might be affected?" |

## Configuration

The hook uses LLM-based evaluation with the following settings:
- **Timeout**: 30 seconds for evaluation
- **Triggers on**: Every user prompt submission
- **Language**: Auto-detected from user input
- **Context Gathering**: Automatic review of project state before questioning

## Use Cases

1. **Feature Development**: Ensures all requirements are captured before coding
2. **Bug Fixing**: Clarifies reproduction steps and expected behavior
3. **Refactoring**: Confirms scope and constraints before making changes
4. **Problem Analysis**: Gathers complete context before providing solutions
5. **Technical Decisions**: Explores alternatives and implications before recommending

## License

MIT
