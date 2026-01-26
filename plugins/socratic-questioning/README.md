# Socratic Questioning Plugin

A plugin that guides Claude to use Socratic questioning methods for requirement clarification. Instead of making assumptions about unclear user prompts, Claude will ask focused multiple choice questions to ensure accurate understanding before taking action.

## What's New in v2.0.0

**Major Architecture Change:** Migrated from hook-based to skill-based approach.

| v1.x (Hook-based) | v2.0 (Skill-based) |
|-------------------|-------------------|
| `UserPromptSubmit` hook blocks input | Skill guides Claude's natural responses |
| Questions appear as blocking prompts | Questions appear in Claude's reply |
| Answering "A" could trigger loops | Natural conversation flow |
| Context lost between evaluations | Full conversation history preserved |

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

### Skill-Based Approach

This plugin uses a **skill-based architecture** that guides Claude's behavior naturally:

1. **SessionStart Hook**: Injects skill awareness when a session begins
2. **socratic-clarify Skill**: Teaches Claude how to ask clarifying questions
3. **`/clarify` Command**: Allows explicit invocation of clarification

### How It Works

```
┌─────────────────────────────────────────────────────┐
│                  SKILL-BASED FLOW                   │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Session Starts                                     │
│       │                                             │
│       ▼                                             │
│  Skill awareness injected into context              │
│       │                                             │
│       ▼                                             │
│  User: "优化性能" ──────────────────────────────►   │
│       │                                             │
│       ▼                                             │
│  Claude evaluates clarity internally                │
│       │                                             │
│       ├─── Clear ───► Execute directly              │
│       │                                             │
│       └─── Unclear ──► Ask (A)(B)(C) in response    │
│                           │                         │
│                           ▼                         │
│  User: "A" ─────────────────────────────────────►   │
│       │                                             │
│       ▼                                             │
│  Claude continues (full context preserved)          │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### Context-Aware Questioning

Before asking clarification questions, Claude gathers context:
- **Project State**: Reviews files, directory structure, and codebase architecture
- **Conversation History**: Understands ongoing discussion context
- **Documentation**: Checks README and relevant docs

### Focus Areas

The skill evaluates prompts against three key areas:

| Area | Description |
|------|-------------|
| **Purpose** | What is the user trying to achieve? What problem are they solving? |
| **Constraints** | What limitations, boundaries, or requirements must be respected? |
| **Success Criteria** | How will we know when this is done correctly? |

### Multiple Choice Questions (Required)

The plugin **always uses multiple choice questions** with (A), (B), (C) options:

```
What aspect of performance is most important?
(A) Reduce initial load time
(B) Decrease memory usage
(C) Improve response speed
(D) All of the above
```

```
您希望进行哪种分析：
(A) 个股基本面分析
(B) 技术指标分析
(C) 投资组合分析
(D) 综合分析？
```

### One Question Per Message

- Claude asks **ONE question at a time** - never multiple questions
- This makes it easier for users to respond clearly
- Follow-up questions are asked sequentially as needed

### `/clarify` Command

Explicitly invoke clarification when needed:

```
/clarify
/clarify what performance optimization?
```

### Bilingual Support

The plugin automatically detects the user's input language and responds accordingly:
- English input → English questions
- Chinese input → Chinese questions (中文输入 → 中文提问)

### What It Does NOT Do

- **Does not block**: Questions appear naturally in Claude's response
- **Does not loop**: Answering "A"/"B"/"C" flows naturally without re-triggering
- **Does not over-question**: Clear requests proceed without delay

## Directory Structure

```
socratic-questioning/
├── .claude-plugin/
│   └── plugin.json           # Plugin metadata (v2.0.0)
├── hooks/
│   └── hooks.json            # SessionStart hook for skill injection
├── scripts/
│   └── inject-skill.sh       # Context injection script
├── skills/
│   ├── socratic-clarify/
│   │   └── SKILL.md          # Main questioning methodology skill
│   └── clarify/
│       └── SKILL.md          # /clarify command skill
├── commands/                 # Reserved
├── agents/                   # Reserved
└── README.md                 # This file
```

## Example Interactions

### Example 1: Multiple Choice Question

**User**: "Improve the performance"

**Claude**:
```
I'd be happy to help optimize this. To focus on the right area:

What aspect of performance is most important?
(A) Reduce initial load time
(B) Decrease memory usage
(C) Improve response speed for user interactions
(D) All of the above - comprehensive optimization
```

**User**: "A"

**Claude**: *Proceeds to optimize load time*

### Example 2: Bug Report Clarification

**User**: "Fix the login bug"

**Claude**:
```
To help fix this bug, what behavior are you experiencing:
(A) Page crashes or shows error
(B) Login fails silently (no error message)
(C) Incorrect credentials are accepted
(D) Session expires immediately after login?
```

### Example 3: Clear Request (No Questions)

**User**: "Add a logout button to the navigation bar in `src/components/Nav.tsx` that calls the `logout()` function from `auth.ts`"

**Claude**: *Proceeds directly with implementation*

## Socratic Question Types

| Type | Purpose | Example |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'improve', do you mean: (A) faster, (B) cleaner, or (C) fewer bugs?" |
| **Probing assumptions** | Expose hidden beliefs | "Are you assuming: (A) users have network, (B) offline needed, or (C) hybrid?" |
| **Probing reasons** | Understand the why | "What led you to this approach?" |
| **Questioning viewpoints** | Explore alternatives | "Have you considered alternative approaches?" |

## Migration from v1.x

If upgrading from v1.x:

1. **Behavior Change**: Questions now appear in Claude's response, not as blocking prompts
2. **No More Loops**: The "A"/"B"/"C" infinite loop issue is resolved
3. **New Command**: `/clarify` available for explicit clarification requests
4. **Context Preserved**: Conversation history is maintained throughout

## Use Cases

1. **Feature Development**: Ensures all requirements are captured before coding
2. **Bug Fixing**: Clarifies reproduction steps and expected behavior
3. **Refactoring**: Confirms scope and constraints before making changes
4. **Problem Analysis**: Gathers complete context before providing solutions
5. **Technical Decisions**: Explores alternatives and implications before recommending

## License

MIT
