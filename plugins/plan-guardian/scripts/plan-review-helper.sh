#!/bin/bash
# plan-review-helper.sh — pre-approvable filesystem touchpoints for the codex
# plan-review loop.
#
# Why this exists: the loop runs while the session is STILL in plan mode, where
# Write/Edit/Bash are gated exactly like default mode (they prompt). Most writes
# are plain Edit/Write into ./.plan-review/** (silenced by a single Edit/Write
# allow rule). The two awkward ones are a `mkdir` and the sentinel write, which
# is a `printf | shasum | awk > file` pipe — and piped Bash rules are fragile to
# allow precisely. Consolidating both into this one absolute-path script lets
# /plan-guardian:setup pre-approve them with a single, stable Bash() rule, the
# same pattern already used for inject-skill.sh.
#
# Subcommands:
#   init              mkdir -p ./.plan-review/codex-rounds
#   sentinel <file>   write ./.plan-review/.codex-review-done = sha256 of <file>,
#                     using the EXACT normalization codex-plan-review-trigger.sh
#                     uses (printf '%s' "$(cat <file>)" — trailing newlines
#                     stripped by command substitution), so the hook's hash
#                     comparison matches byte-for-byte.
#
# All paths are relative to the current working directory (the project root),
# matching codex-plan-review-trigger.sh.

set -euo pipefail

# Same hash function shape as the hook. Reads stdin; macOS/Linux portable. The
# digest value is independent of which binary computes it, so the shasum vs
# sha256sum fallback never breaks the hook<->sentinel match.
sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    echo "no-sha256-available"
  fi
}

cmd="${1:-}"

case "$cmd" in
  init)
    mkdir -p ./.plan-review/codex-rounds
    ;;
  sentinel)
    plan_file="${2:-}"
    if [ -z "$plan_file" ] || [ ! -f "$plan_file" ]; then
      echo "plan-review-helper: 'sentinel' requires an existing plan file path" >&2
      exit 1
    fi
    mkdir -p ./.plan-review
    printf '%s' "$(cat "$plan_file")" | sha256 > ./.plan-review/.codex-review-done
    ;;
  *)
    echo "plan-review-helper: unknown subcommand '${cmd}' (expected: init | sentinel <file>)" >&2
    exit 1
    ;;
esac
