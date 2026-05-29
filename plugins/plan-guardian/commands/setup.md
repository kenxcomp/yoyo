---
description: Add permission allow-rules so plan-guardian's two plan-mode Bash calls (codex exec + digest helper) stop prompting
---

# /plan-guardian:setup

Silence the permission prompts plan-guardian's codex review gate triggers **while the session is in plan mode**.

## Why prompts happen (v1.5.0)

plan-guardian's codex review gate (`/plan-guardian:codex-plan-review`) runs *while you are still in plan mode* — the `ExitPlanMode` hook denies the exit and hands control to the loop before the mode changes. In plan mode, **Write / Edit / Bash are gated exactly like `default` mode: they prompt** (official docs: plan mode is "reads only", "permission prompts still apply the same as default mode").

**v1.5.0 removed all Write/Edit from the loop.** The "reviewed" proof is now an inline marker carried inside the plan text (`<!-- codex-reviewed:<token> -->`), which travels to the hook through `tool_input.plan` — no files are written during plan mode. That deliberately sidesteps the open Claude Code bug where the allow-list *intermittently fails to suppress Write/Edit prompts* under mode toggles: there are no Write/Edit calls left to mis-prompt.

What remains in plan mode is exactly **two Bash calls** per loop:

1. `codex exec …` — the per-round review.
2. `plan-review-helper.sh digest` — minting the marker token on convergence.

Both prompt without an allow-rule. This command pre-approves those two, and nothing else. (Bash allow-rules are far more reliable than Write/Edit under mode toggles, which is the other reason v1.5.0 moved the proof out of a written file.)

## Rules this command adds

| Rule | Covers |
|------|--------|
| `Bash(codex exec *)` | the per-round `codex exec` review call |
| `Bash(<install-dir>/plan-guardian/*/scripts/plan-review-helper.sh *)` | the `digest` marker mint |

No `Edit`/`Write` rules are needed anymore — the loop writes nothing in plan mode. (If you ran an older setup, the leftover `Edit(.plan-review/**)` / `Write(.plan-review/**)` rules are now unused and harmless; you may delete them.)

**Why the helper rule wildcards a path segment:** Claude Code expands `${CLAUDE_PLUGIN_ROOT}` in command bodies *before* the model sees them, and for an installed plugin that resolves to a **version-stamped** directory (e.g. `…/cache/<marketplace>/plan-guardian/1.5.0`). A rule pinned to that exact path would stop matching the moment the plugin updates. So the version segment is replaced with `*` (`…/plan-guardian/*/scripts/plan-review-helper.sh`), which survives updates. This is also why there is no separate literal-`${CLAUDE_PLUGIN_ROOT}` rule — that form never reaches the permission matcher.

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
#   .../plugins/cache/<marketplace>/plan-guardian/1.5.0
# Wildcard the version segment so the allow rule survives plugin updates.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
HELPER_GLOB="$(dirname "$PLUGIN_ROOT")/*/scripts/plan-review-helper.sh"

DESIRED="$(jq -nc --arg hg "$HELPER_GLOB" '[
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

## Step 4 — (Optional) signing key for the marker

**You usually don't need to do anything here (v1.5.1).** The marker is content-bound **by default**: the helper auto-generates a per-machine key at `~/.claude/plan-guardian/secret` (mode 600) on first use, so revising a reviewed plan invalidates its marker and re-arms the gate — no setup. The literal fallback (`l1:none`, spoofable) only appears if no key can be established at all (unwritable `HOME` and no random source).

Set `CODEX_REVIEW_SECRET` only if you want to **override** that auto key — e.g. share one key across machines, scope it per-project, or keep the key out of `~/.claude/`. It must be visible to **both** the hook and the slash command (same shell environment Claude Code launches in). Do **not** write either without explicit confirmation:

- Shell profile (every Claude Code session): fish → `set -gx CODEX_REVIEW_SECRET "<random>"` in `~/.config/fish/config.fish` (or `set -Ux ...` once); bash/zsh → `export CODEX_REVIEW_SECRET="<random>"`.
- Claude Code settings env: add `"env": { "CODEX_REVIEW_SECRET": "<random>" }` to `settings.json`.

(`CODEX_REVIEW_SECRET_FILE` can also point the auto key file elsewhere.) Mention this as optional; content-binding already works out of the box.

## Step 5 — Verify

Tell the user to enter plan mode and trigger an `ExitPlanMode`. It will be denied (no marker yet); running `/plan-guardian:codex-plan-review` should now run `codex exec` and the digest mint **without prompts**, and the subsequent `ExitPlanMode` (with the marked plan) should be allowed.

## Notes & caveats

- v1.5.0 no longer depends on Write/Edit allow-rules, so the upstream flaky-allow-list bug no longer affects the gate's core. Only the two Bash rules matter; `/permissions` shows whether they are loaded.
- The `codex exec` rule allows any `codex exec` invocation (the plugin always runs it `--sandbox read-only`). If you want it scoped tighter, replace it with an exact-match rule for the full command — but that is fragile across plan lengths.
- Reverting: `mv ~/.claude/settings.json.bak.<TS> ~/.claude/settings.json`, or delete the two rules from `permissions.allow`.
- Opt-out of the whole gate instead: set `CODEX_PLAN_REVIEW=0` (then these rules are unused and can be removed).
