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

### UserPromptSubmit Hook

This plugin uses a **UserPromptSubmit hook** to automatically evaluate every user prompt for clarity before proceeding. When unclear points are detected, Claude will:

1. Identify what information is missing or ambiguous
2. Ask ONE focused Socratic question to clarify the most critical point
3. Wait for user response before proceeding
4. Repeat until the request is clear enough for action

### Clarity Criteria

The hook evaluates prompts against these criteria:

| Criterion | Description |
|-----------|-------------|
| **Specificity** | Are vague terms like "better", "improve", "fix" defined? |
| **Context** | Is sufficient scope, environment, or background provided? |
| **Requirements** | Are expected outcomes or acceptance criteria clear? |
| **Assumptions** | Are implicit assumptions that need confirmation identified? |
| **Constraints** | Are limitations or boundaries specified when relevant? |
| **Edge Cases** | For technical tasks, are error handling requirements mentioned? |

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
UserPromptSubmit hook evaluates clarity
        ↓
┌──────────────────────────────────┐
│ Is the prompt clear enough?      │
├──────────┬───────────────────────┤
│  YES     │  NO                   │
│  ↓       │  ↓                    │
│ Proceed  │ Ask ONE Socratic      │
│ normally │ question              │
└──────────┴───────────────────────┘
                    ↓
           User responds
                    ↓
           Re-evaluate clarity
                    ↓
           (Loop until clear)
```

## Example Interactions

### Example 1: Vague Request

**User**: "Fix the login bug"

**Claude**: "To help fix this bug effectively, I need to understand it better. What specific behavior are you experiencing when trying to log in - for example, does the page crash, show an error message, or fail silently?"

### Example 2: Missing Context

**User**: "Add a new feature"

**Claude**: "I'd like to help you add this feature. What specific functionality should this new feature provide?"

### Example 3: Clear Request (No Questions)

**User**: "Add a logout button to the navigation bar in `src/components/Nav.tsx` that calls the `logout()` function from `auth.ts`"

**Claude**: *Proceeds directly with implementation*

## Socratic Question Types

| Type | Purpose | Example |
|------|---------|---------|
| **Clarifying** | Understand what was said | "When you say 'better performance', what metrics matter most?" |
| **Probing assumptions** | Expose hidden beliefs | "What makes you certain this approach will work?" |
| **Probing reasons** | Understand the why | "What led you to this conclusion?" |
| **Questioning viewpoints** | Explore alternatives | "Have you considered approaching this differently?" |
| **Probing implications** | Explore consequences | "If we do this, what might be affected?" |

## Configuration

The hook uses LLM-based evaluation with the following settings:
- **Timeout**: 30 seconds for evaluation
- **Triggers on**: Every user prompt submission
- **Language**: Auto-detected from user input

## Use Cases

1. **Feature Development**: Ensures all requirements are captured before coding
2. **Bug Fixing**: Clarifies reproduction steps and expected behavior
3. **Refactoring**: Confirms scope and constraints before making changes
4. **Problem Analysis**: Gathers complete context before providing solutions
5. **Technical Decisions**: Explores alternatives and implications before recommending

## License

MIT
