---
description: "Overview of form-base state in the current project — pending forms, recent submissions, recent responses."
---

# /form-status — Overview

Call these in parallel:
1. `form-base.list_forms` (no filter)
2. `form-base.list_responses` (no filter)

Render a short summary in this layout:

```
form-base · <project name from cwd>

Forms        N pending · M submitted · K archived
Responses    A active  · B archived
```

Then list:
- **Pending forms** (each line: `form_id  title  created  url-hint`) — these are blocking the agent waiting on the user
- **Most recent 3 submitted forms** — title + when
- **Most recent 3 active responses** — title + role default

If everything is empty, say so and suggest the user start a request that needs structured clarification (the agent will create a form on its own).
