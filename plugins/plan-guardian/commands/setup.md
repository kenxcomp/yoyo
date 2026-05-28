---
description: Add permission allow-rules so plan-guardian's state writes stop prompting inside plan mode
---

# /plan-guardian:setup

Silence the permission prompts plan-guardian triggers **while the session is in plan mode**.

## Why prompts happen (and why moving the directory does NOT help)

plan-guardian's codex review gate (`/plan-guardian:codex-plan-review`) runs *while you are still in plan mode* — the `ExitPlanMode` hook denies the exit and hands control to the loop before the mode changes. In plan mode, **Write / Edit / Bash are gated exactly like `default` mode: they prompt** (official docs: plan mode is "reads only", "permission prompts still apply the same as default mode"). The loop does several such writes per round (round prompt/decision files, plan edits, `codex exec`, the sentinel), so you get asked to allow each one.

This is **not** caused by the *location* `./.plan-review/`. The path is irrelevant to the prompt — every non-read write prompts in plan mode regardless of where it lands. In fact, moving state into `.claude/` would be **worse**: `.claude` is a Claude Code **protected path** whose writes are *never* auto-approved in any mode except `bypassPermissions` — not even an allow rule overrides it. `./.plan-review/` is a normal, non-protected project directory, which is exactly why allow rules *can* pre-approve it.

The fix is permission **allow rules**, which layer on top of any mode (plan included) to pre-approve specific tools on specific paths.

## Rules this command adds

| Rule | Covers |
|------|--------|
| `Edit(.plan-review/**)` | plan revisions to `yoplan-pending.md` |
| `Write(.plan-review/**)` | `round-<N>-prompt.md`, `round-<N>-decisions.md`, `review-status.md` |
| `Bash(codex exec *)` | the per-round `codex exec` review call |
| `Bash(<install-dir>/plan-guardian/*/scripts/plan-review-helper.sh *)` | `init` (mkdir) + `sentinel` write |

`.plan-review/**` is anchored to the **current working directory** (gitignore-style relative pattern), so a single rule set in your global `~/.claude/settings.json` works in *every* project. Reads are omitted on purpose — reads inside the cwd never prompt.

**Why the helper rule wildcards a path segment:** Claude Code expands `${CLAUDE_PLUGIN_ROOT}` in command bodies *before* the model sees them, and for an installed plugin that resolves to a **version-stamped** directory (e.g. `…/cache/<marketplace>/plan-guardian/1.4.0`). A rule pinned to that exact path would stop matching the moment the plugin updates. So the version segment is replaced with `*` (`…/plan-guardian/*/scripts/plan-review-helper.sh`), which survives updates. This is also why there is no separate literal-`${CLAUDE_PLUGIN_ROOT}` rule — that form never reaches the permission matcher.

## Step 0 — Guard

```bash
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  echo "CLAUDE_PLUGIN_ROOT is unset — run this as the /plan-guardian:setup command, not a raw shell."
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "jq is required for safe JSON merging. Install jq and re-run."; exit 1; }
```

## Step 1 — Compute which rules are missing

Default target is the **user** settings file (applies across all projects). If the user explicitly wants project-only scope, use `./.claude/settings.local.json` instead and tell them it only affects this project.

```bash
SETTINGS="$HOME/.claude/settings.json"

# Claude Code expands ${CLAUDE_PLUGIN_ROOT} in this command body before you see it,
# resolving to the (version-stamped) install dir, e.g.
#   .../plugins/cache/<marketplace>/plan-guardian/1.4.0
# Wildcard the version segment so the allow rule survives plugin updates.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
HELPER_GLOB="$(dirname "$PLUGIN_ROOT")/*/scripts/plan-review-helper.sh"

DESIRED="$(jq -nc --arg hg "$HELPER_GLOB" '[
  "Edit(.plan-review/**)",
  "Write(.plan-review/**)",
  "Bash(codex exec *)",
  "Bash(\($hg) *)"
]')"

if [ -f "$SETTINGS" ]; then
  EXISTING="$(jq -c '.permissions.allow // []' "$SETTINGS")"
else
  EXISTING="[]"
fi

MISSING="$(jq -nc --argjson want "$DESIRED" --argjson have "$EXISTING" '$want - $have')"
echo "Missing rules:"; echo "$MISSING" | jq -r '.[]'
```

If `MISSING` is `[]`, print `plan-guardian already configured — no permission rules to add.` and stop.

## Step 2 — Confirm before writing (MANDATORY)

`~/.claude/settings.json` is the user's hand-maintained global config. **Do not modify it without explicit confirmation in the current turn.** Show the user the exact `MISSING` rules and the target file, then ask: apply automatically (backup + `jq` merge), or print the snippet for manual paste? Proceed to Step 3 only on an explicit "yes / apply".

## Step 3a — Apply automatically (only after "yes")

```bash
TS="$(date +%Y%m%d%H%M%S)"
[ -f "$SETTINGS" ] || { mkdir -p "$(dirname "$SETTINGS")"; echo '{}' > "$SETTINGS"; }
cp -p "$SETTINGS" "$SETTINGS.bak.$TS"

jq --argjson add "$MISSING" \
  '.permissions.allow = ((.permissions.allow // []) + $add)' \
  "$SETTINGS" > "$SETTINGS.tmp"

if jq empty "$SETTINGS.tmp" 2>/dev/null; then
  mv "$SETTINGS.tmp" "$SETTINGS"
  echo "Added $(echo "$MISSING" | jq 'length') rule(s). Backup: $SETTINGS.bak.$TS"
else
  rm -f "$SETTINGS.tmp"
  echo "Refusing to write: merged JSON failed validation. Original untouched."
fi
```

Only the **missing** rules are appended, preserving the existing order — no reordering, no duplicates. Report the backup path so the user can revert with a single `mv`.

## Step 3b — Manual paste (if the user declined auto-apply)

Print the `MISSING` array and tell them to add the entries to `permissions.allow` in `~/.claude/settings.json` (or via the `/permissions` UI). They take effect on the next session, or immediately after `/permissions` reload.

## Step 4 — Verify

Tell the user to enter plan mode and trigger an `ExitPlanMode`; the codex loop's `.plan-review/` writes and `codex exec` should now run without prompts.

## Notes & caveats

- **Honest caveat:** there are open Claude Code reports where the allow-list intermittently fails to suppress Write/Edit prompts under mode toggles. If prompts persist on your version after setup, that is the upstream bug, not a mis-config — `/permissions` shows whether the rules are loaded.
- The `codex exec` rule allows any `codex exec` invocation (the plugin always runs it `--sandbox read-only`). If you want it scoped tighter, replace it with an exact-match rule for the full command — but that is fragile across plan lengths.
- Reverting: `mv ~/.claude/settings.json.bak.<TS> ~/.claude/settings.json`, or delete the five rules from `permissions.allow`.
- Opt-out of the whole gate instead: set `CODEX_PLAN_REVIEW=0` (then these rules are unused and can be removed).
