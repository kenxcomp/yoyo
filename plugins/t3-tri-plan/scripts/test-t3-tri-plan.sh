#!/usr/bin/env bash
# test-t3-tri-plan.sh — Comprehensive regression test suite for t3-tri-plan v1.0.0 (Plan v4.1).
# Covers all state machine invariants, crash recovery paths, and Round 1–4 review counterexamples.

set -u

HERE=$(cd "$(dirname "$0")" && pwd -P)
PLUGIN_ROOT=$(cd "$HERE/.." && pwd -P)
STATE="$HERE/t3-tri-plan-state.sh"
VAL_CAND="$HERE/validate-candidate.pl"
VAL_JUDGE="$HERE/validate-blind-eval.pl"
PARSE_REV="$HERE/parse-design-review.pl"
INSTALLER="$HERE/install-skills.sh"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  [FAIL] %s\n' "$1" >&2; }

assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$desc"
  else fail "$desc (got='$got', want='$want')"; fi
}

assert_contains() {
  local desc="$1" hay="$2" needle="$3"
  if printf '%s\n' "$hay" | grep -Fq -- "$needle"; then ok "$desc"
  else fail "$desc (missing '$needle' in: $hay)"; fi
}

assert_rc() {
  local desc="$1" got="$2" want="$3"
  if [ "$got" -eq "$want" ]; then ok "$desc"
  else fail "$desc (rc=$got, want=$want)"; fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t3-tri-plan-test.XXXXXX")
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Helper: create a valid 12-section blind design candidate Markdown file.
write_valid_candidate() {
  local out="$1" tag="$2"
  cat > "$out" <<EOF
# Design Proposal ($tag)

## 1. Current architecture evidence
Verified in \`src/app.py:12\` and \`REVIEW.md\`.
\`\`\`markdown
## 1. Fake heading inside fenced code block must be ignored
\`\`\`

## 2. Proposed architecture
Clean single-owner design for $tag.

## 3. Data and control flow
Request -> validator -> store.

## 4. Files/modules likely affected
- \`src/app.py\`

## 5. Callers and downstream consumers
- \`src/cli.py:5\`

## 6. Data migration and compatibility
Backward compatible schema.

## 7. Testing strategy
Real entrypoint test via CLI.

## 8. Rollback strategy
Revert single commit cleanly.

## 9. Risks and unknowns
Low risk if invariant I-1 holds.

## 10. Alternatives considered
Rejected complex middleware.

## 11. Recommended implementation sequence
1. Add guard. 2. Add test.

## Summary
- Core thesis: keep it minimal ($tag).
- Biggest risk: missed caller.
- Top forks: error code shape.
EOF
}

# Helper: create a fake Trellis repo with configurable mock task.py.
make_repo() {
  local dir="$1"
  mkdir -p "$dir/src" "$dir/.trellis/scripts/common" "$dir/.trellis/spec" "$dir/.trellis/tasks"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test"
  cat > "$dir/src/app.py" <<'EOF'
def run():
    return "ok"
EOF
  cat > "$dir/REVIEW.md" <<'EOF'
# Repository Review Rules

## No Raw SQL
Never execute unsanitized raw SQL queries.

## Atomic State Writes
Always write state via temp file and rename.
EOF
  cat > "$dir/.trellis/spec/core.md" <<'EOF'
# Core Spec
All handlers validate inputs.
EOF
  cat > "$dir/.trellis/.gitignore" <<'EOF'
.current-task
.runtime/
.mock-ptrs/
**/__pycache__/
**/*.pyc
EOF
  cat > "$dir/.trellis/config.yaml" <<'EOF'
hooks:
  after_start: []
EOF
  cat > "$dir/.trellis/scripts/common/config.py" <<'EOF'
def get_hooks(event, repo_root=None):
    return []
EOF
  cat > "$dir/.trellis/scripts/task.py" <<'PY'
#!/usr/bin/env python3
import json, os, signal, sys, time
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
ptr_dir = repo / ".trellis" / ".mock-ptrs"

def ptr_file():
    ctx = os.environ.get("TRELLIS_CONTEXT_ID", "")
    if not ctx:
        return None
    return ptr_dir / f"{ctx}.txt"

def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print("usage: task.py {create,current,validate,start}")
        return 0
    cmd = args[0]
    if cmd == "current":
        if "--help" in args or "-h" in args:
            print("usage: task.py current [--json] [--source]")
            return 0
        if os.environ.get("MOCK_CURRENT_MODE", "") == "broken":
            print("not-valid-json")
            return 2
        if os.environ.get("MOCK_CURRENT_MODE", "") == "exit7_null":
            print(json.dumps({"current_task": None, "source": "session", "stale": False}))
            return 7
        if os.environ.get("MOCK_CURRENT_MODE", "") == "exit2_error":
            print(json.dumps({"error": "trellis state corrupted"}))
            return 2
        if os.environ.get("MOCK_CURRENT_MODE", "") == "exit0_missing_key":
            print(json.dumps({"error": "missing current_task key"}))
            return 0
        if os.environ.get("MOCK_CURRENT_MODE", "") == "exit0_null_error":
            print(json.dumps({"current_task": None, "error": "context backend failed"}))
            return 0
        pf = ptr_file()
        tdir = pf.read_text().strip() if (pf and pf.is_file()) else None
        if "--json" in args:
            obj = {"dir": tdir, "status": "in_progress"} if tdir else None
            print(json.dumps({"current_task": obj, "source": "session" if pf else "none", "stale": False}))
            return 0 if tdir else 1
        print(tdir or "(none)")
        return 0 if tdir else 1
    if cmd == "validate":
        return 0
    if cmd == "start":
        task_arg = Path(args[1]).resolve()
        rel = task_arg.relative_to(repo.resolve()).as_posix()
        mode = os.environ.get("MOCK_START_MODE", "ok")
        pid_out = os.environ.get("MOCK_START_PID_FILE", "")
        if pid_out:
            Path(pid_out).write_text(str(os.getpid()))
        if mode == "sleep_long":
            time.sleep(float(os.environ.get("MOCK_START_SLEEP", "2.5")))
        pf = ptr_file()
        if pf:
            pf.parent.mkdir(parents=True, exist_ok=True)
            pf.write_text(rel)
        if mode == "crash_after_ptr":
            sys.exit(1)
        tj = task_arg / "task.json"
        if tj.is_file():
            data = json.loads(tj.read_text())
            data["status"] = "in_progress"
            tj.write_text(json.dumps(data, indent=2))
        if mode == "sigkill_self":
            os.kill(os.getpid(), signal.SIGKILL)
        if mode == "hook_warn_exit0":
            sys.stderr.write("\x1b[33m[WARN] Hook failed (after_start): false\x1b[0m\n")
            return 0
        if mode == "clear_ptr_exit0":
            if pf and pf.is_file():
                pf.unlink()
            return 0
        return 0
    return 0

sys.exit(main())
PY
  chmod +x "$dir/.trellis/scripts/task.py"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "init repo"
}

# =============================================================================
printf '\n=== Group A: StrictJson, Config Schemas, Overrides & Provider Auth ===\n'
# =============================================================================

CAPS="$TMP/caps.json"
cat > "$CAPS" <<'EOF'
{
  "inheritedProviderInstanceId": "antigravity",
  "providers": [
    {
      "providerInstanceId": "antigravity",
      "driverKind": "antigravity",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "gemini-4-neon", "options": [{ "id": "thought_level", "values": ["low", "medium", "high", "xhigh"], "default": "high" }] }
      ]
    },
    {
      "providerInstanceId": "claudeAgent",
      "driverKind": "claudeAgent",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "claude-opus-5-5", "options": [{ "id": "effort", "values": ["low", "medium", "high", "xhigh", "max"], "default": "medium" }] }
      ]
    },
    {
      "providerInstanceId": "codex",
      "driverKind": "codex",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "gpt-6.2-sol", "options": [{ "id": "reasoningEffort", "values": ["low", "medium", "high", "xhigh", "max", "ultra"], "default": "low" }] }
      ]
    },
    {
      "providerInstanceId": "nocross",
      "driverKind": "nocross",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": false,
      "models": [
        { "id": "local-only", "options": [{ "id": "effort", "values": ["low", "high"], "default": "low" }] }
      ]
    }
  ]
}
EOF

export T3_TRI_PLAN_CONFIG="$TMP/user-config.json"

# 1. Duplicate key rejected in config-set
cat > "$TMP/dup-cfg.json" <<'EOF'
{
  "version": 1,
  "version": 1,
  "authorizedProviders": ["antigravity"],
  "designers": { "effortMode": "unified", "unifiedEffort": "high", "members": [] },
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "reviewCouncil": { "effortMode": "unified", "unifiedEffort": "high", "members": [] }
}
EOF
out=$(bash "$STATE" config-set --file "$TMP/dup-cfg.json" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "StrictJson rejects duplicate keys in config" "$out" "duplicate JSON object key" || fail "duplicate key should fail"

# 2. Valid user config with unifiedEffort='xhigh' (applied to all members!)
cat > "$TMP/good-cfg.json" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "claudeAgent", "codex"],
  "designers": {
    "effortMode": "unified",
    "unifiedEffort": "xhigh",
    "members": [
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "" },
      { "providerInstanceId": "claudeAgent", "model": "claude-opus-5-5", "effortKey": "effort", "effort": "" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "" }
    ]
  },
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "reviewCouncil": {
    "effortMode": "unified",
    "unifiedEffort": "high",
    "members": [
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "" },
      { "providerInstanceId": "claudeAgent", "model": "claude-opus-5-5", "effortKey": "effort", "effort": "" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "" }
    ]
  },
  "knobs": { "roundCap": 3, "maxStepBacks": 1 }
}
EOF
out=$(bash "$STATE" config-set --file "$TMP/good-cfg.json" 2>&1); rc=$?
assert_rc "config-set succeeds on valid config" "$rc" 0

REPO_A="$TMP/repo-a"
make_repo "$REPO_A"

out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" 2>&1); rc=$?
assert_rc "config-show valid" "$rc" 0
assert_contains "unifiedEffort xhigh actively applied to designer 1" "$out" 'DESIGNER_1_OPTIONS={"thought_level":"xhigh"}'
assert_contains "unifiedEffort xhigh actively applied to designer 2" "$out" 'DESIGNER_2_OPTIONS={"effort":"xhigh"}'
assert_contains "unifiedEffort xhigh actively applied to designer 3" "$out" 'DESIGNER_3_OPTIONS={"reasoningEffort":"xhigh"}'
assert_contains "judge inherits config defaultReviewer" "$out" "JUDGE_MODEL=gpt-6.2-sol"

# 3. single= conflicts with model= and council=
out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" --single codex/gpt-6.2-sol:high --override-model antigravity/gemini-4-neon 2>&1); rc=$?
assert_rc "single= + model= conflicts (exit 3)" "$rc" 3
assert_contains "conflict error reported" "$out" "conflicts with --override-model"

# 4. single= does NOT alter judge (judge stays config defaultReviewer = codex/gpt-6.2-sol:high)!
out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" --single claudeAgent/claude-opus-5-5:max 2>&1); rc=$?
assert_rc "single= valid" "$rc" 0
assert_contains "single= overrides Phase 3 defaultReviewer" "$out" "DEFAULT_REVIEWER_MODEL=claude-opus-5-5"
assert_contains "single= overrides Phase 3 council count to 1" "$out" "COUNCIL_COUNT=1"
assert_contains "single= does NOT mutate Phase 2a judge" "$out" "JUDGE_MODEL=gpt-6.2-sol"
assert_contains "single= does NOT mutate Phase 1 designers" "$out" "DESIGNERS_COUNT=3"

# 5. Inline :effort beats global effort=, and out-of-intersection unified effort fails (no clamping!)
out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" --override-council "antigravity/gemini-4-neon:high,codex/gpt-6.2-sol:ultra" --override-effort medium 2>&1); rc=$?
assert_rc "inline :effort overrides global effort=" "$rc" 0
assert_contains "inline :effort kept ultra on codex" "$out" 'COUNCIL_2_OPTIONS={"reasoningEffort":"ultra"}'

out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" --override-council "antigravity/gemini-4-neon,codex/gpt-6.2-sol" --override-effort ultra 2>&1); rc=$?
assert_rc "unified effort outside strict intersection fails (exit 3)" "$rc" 3
assert_contains "no silent clamping on gemini-4-neon" "$out" "invalid for antigravity/gemini-4-neon"

# 6. Cross-provider child capability check
out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" --override-judge nocross/local-only:low 2>&1); rc=$?
assert_rc "canRunCrossProviderChildTask=false rejected (exit 3)" "$rc" 3
assert_contains "cross-provider rejection message" "$out" "cannot run cross-provider child tasks"

# 7. Project config forbidding authorizedProviders & gating new provider
cat > "$REPO_A/.t3-tri-plan.json" <<'EOF'
{ "authorizedProviders": ["codex"] }
EOF
out=$(bash "$STATE" config-show --repo "$REPO_A" --capabilities "$CAPS" 2>&1); rc=$?
assert_rc "project config with authorizedProviders rejected (exit 3)" "$rc" 3
assert_contains "project authorizedProviders error" "$out" "MUST NOT contain 'authorizedProviders'"
rm -f "$REPO_A/.t3-tri-plan.json"

# =============================================================================
printf '\n=== Group B: Fence-Aware Candidate Validator ===\n'
# =============================================================================

write_valid_candidate "$TMP/cand-ok.md" "A"
out=$(perl "$VAL_CAND" --input "$TMP/cand-ok.md" 2>&1); rc=$?
assert_rc "valid 12-section candidate with internal fence passes" "$rc" 0
assert_contains "VALID=1" "$out" "VALID=1"

{ printf '```markdown\n'; cat "$TMP/cand-ok.md"; printf '```\n'; } > "$TMP/cand-wrap.md"
out=$(perl "$VAL_CAND" --input "$TMP/cand-wrap.md" 2>&1); rc=$?
assert_rc "outer whole-document code fence rejected" "$rc" 1
assert_contains "outer fence error" "$out" "outer whole-document code fence"

sed 's/## 8. Rollback strategy/## 8. Rollback strategy\n\n## 8. Rollback strategy/' "$TMP/cand-ok.md" > "$TMP/cand-dup.md"
out=$(perl "$VAL_CAND" --input "$TMP/cand-dup.md" 2>&1); rc=$?
assert_rc "duplicate canonical section rejected" "$rc" 1
assert_contains "duplicate section error" "$out" "duplicate canonical section"

# =============================================================================
printf '\n=== Group C: Async Slots, Title-Changed Reconcile, Takeover & Stale Callback Zero-Write ===\n'
# =============================================================================

REPO="$TMP/repo-main"
make_repo "$REPO"
TASK="$REPO/.trellis/tasks/01-tri-test"
mkdir -p "$TASK"
cat > "$TASK/task.json" <<'EOF'
{ "id": "01-tri-test", "title": "Tri Test", "status": "planning" }
EOF
cat > "$TASK/prd.md" <<'EOF'
# PRD: Tri Test
Must validate input cleanly and preserve backward compatibility.
EOF

out=$(bash "$STATE" commit-phase0 --task "$TASK" --repo "$REPO" --authorization "plan-and-implement" 2>&1); rc=$?
assert_rc "Phase 0 initial commit" "$rc" 0

cat > "$TMP/designers.json" <<'EOF'
[
  { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "xhigh" },
  { "providerInstanceId": "claudeAgent", "model": "claude-opus-5-5", "effortKey": "effort", "effort": "xhigh" },
  { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "xhigh" }
]
EOF

# Pre-create existing M tracked file and existing ?? untracked file to test worktree_fp v3!
printf '\n# existing dirty edit\n' >> "$REPO/src/app.py"
printf 'existing untracked v1\n' > "$REPO/existing-untracked.txt"

out=$(bash "$STATE" prepare-design --task "$TASK" --repo "$REPO" --slots-json "$TMP/designers.json" --owner "thread-parent-1" 2>&1); rc=$?
assert_rc "prepare-design succeeds" "$rc" 0
RUN_ID=$(printf '%s\n' "$out" | sed -n 's/^RUN_ID=//p')

# Claim candidate-a (lost taskId before record-dispatch!) -> reconcile-and-record-result in single tx!
out=$(bash "$STATE" claim-slot --task "$TASK" --run-id "$RUN_ID" --slot candidate-a --owner "thread-parent-1" --owner-gen 1 --generation 1 2>&1); rc=$?
assert_rc "claim candidate-a" "$rc" 0
assert_contains "correlation marker embedded" "$out" "[tri-plan:$RUN_ID:g1:og1:candidate-a:a1:cid"

write_valid_candidate "$TMP/cand-a.md" "SlotA"
write_valid_candidate "$TMP/cand-b.md" "SlotB"
write_valid_candidate "$TMP/cand-c.md" "SlotC"

# Reconcile candidate-a directly from dispatching (simulating title changed, verified via prompt marker!)
out=$(bash "$STATE" reconcile-and-record-result --task "$TASK" --run-id "$RUN_ID" --generation 1 \
  --owner "thread-parent-1" --owner-gen 1 --slot candidate-a --attempt 1 \
  --child-thread-id "child-a-renamed-title" --child-run-id "crun-a-1" --input "$TMP/cand-a.md" 2>&1); rc=$?
assert_rc "reconcile-and-record-result binds & ingests in 1 tx" "$rc" 0

# Duplicate callback is NOOP
out=$(bash "$STATE" reconcile-and-record-result --task "$TASK" --run-id "$RUN_ID" --generation 1 \
  --owner "thread-parent-1" --owner-gen 1 --slot candidate-a --attempt 1 \
  --child-thread-id "child-a-renamed-title" --child-run-id "crun-a-1" --input "$TMP/cand-a.md" 2>&1); rc=$?
assert_rc "duplicate callback returns 0" "$rc" 0
assert_contains "DUPLICATE_NOOP=1" "$out" "DUPLICATE_NOOP=1"

# Claim candidate-b -> test reconcile-terminal-error (failed with NO body!) then re-claim attempt 2!
bash "$STATE" claim-slot --task "$TASK" --run-id "$RUN_ID" --slot candidate-b --owner "thread-parent-1" --owner-gen 1 --generation 1 >/dev/null
out=$(bash "$STATE" reconcile-terminal-error --task "$TASK" --run-id "$RUN_ID" --generation 1 \
  --owner "thread-parent-1" --owner-gen 1 --slot candidate-b --attempt 1 \
  --child-thread-id "child-b-dead" --child-run-id "crun-b-1" --state failed --reason "provider timeout" 2>&1); rc=$?
assert_rc "reconcile-terminal-error handles body-less failed child" "$rc" 0

# Claim candidate-c -> test needs_reconcile -> reconcile-abandon -> re-claim
bash "$STATE" claim-slot --task "$TASK" --run-id "$RUN_ID" --slot candidate-c --owner "thread-parent-1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" update-slot --task "$TASK" --run-id "$RUN_ID" --generation 1 --owner "thread-parent-1" --owner-gen 1 --slot candidate-c --attempt 1 --state needs_reconcile --reason "ambiguous" >/dev/null

# Now simulate takeover-run crashing RIGHT AFTER commit_marker!
# Old owner callback arrives BEFORE tx replay -> MUST return STALE_CALLBACK=1 WITHOUT replaying .pending.tx.json!
T3_TRI_PLAN_TEST_CRASH_TX=after_commit_marker bash "$STATE" takeover-run --task "$TASK" --new-owner "thread-parent-2" --reason "parent died" >/dev/null 2>&1
rc_crash=$?
[ "$rc_crash" -ne 0 ] && ok "simulated crash after takeover commit_marker" || fail "expected simulated crash"
[ -f "$TASK/research/plans/.pending.tx.json" ] && ok ".pending.tx.json remains on disk" || fail "missing .pending.tx.json"

# Old owner callback tries record-dispatch on candidate-c while committed takeover tx is UNREPLAYED!
out=$(bash "$STATE" record-dispatch --task "$TASK" --run-id "$RUN_ID" --generation 1 \
  --owner "thread-parent-1" --owner-gen 1 --slot candidate-c --attempt 1 \
  --task-id "late-tid" --child-thread-id "late-ct" --child-run-id "late-cr" 2>&1); rc=$?
assert_rc "stale callback against committed-unreplayed takeover tx exits 4" "$rc" 4
assert_contains "STALE_CALLBACK=1 reported" "$out" "STALE_CALLBACK=1"
[ -f "$TASK/research/plans/.pending.tx.json" ] && ok "stale callback did NOT replay .pending.tx.json (zero disk writes!)" || fail "stale callback unexpectedly replayed tx!"

# Now normal run-summary replays takeover tx cleanly and shows orphaned needs_reconcile attempt!
out=$(bash "$STATE" run-summary --task "$TASK" 2>&1); rc=$?
assert_rc "run-summary recovers committed takeover tx cleanly" "$rc" 0
assert_contains "active run closed by takeover" "$out" "ACTIVE_RUN=0"
assert_contains "orphaned unresolved slot preserved" "$out" "ORPHANED_COUNT=1"
[ ! -f "$TASK/research/plans/.pending.tx.json" ] && ok ".pending.tx.json cleaned after recovery" || fail ".pending.tx.json still present"

# =============================================================================
printf '\n=== Group D: Phase 1 worktree_fp v3 Drift, Phase 2a Pre-Reveal Lock & Phase 2b Anti-Tamper ===\n'
# =============================================================================

# Start fresh Phase 1 run under generation=2, owner_gen=2
out=$(bash "$STATE" prepare-design --task "$TASK" --repo "$REPO" --slots-json "$TMP/designers.json" --owner "thread-parent-2" 2>&1); rc=$?
assert_rc "prepare-design gen 2" "$rc" 0
RUN_ID=$(printf '%s\n' "$out" | sed -n 's/^RUN_ID=//p')

for pair in "candidate-a:$TMP/cand-a.md" "candidate-b:$TMP/cand-b.md" "candidate-c:$TMP/cand-c.md"; do
  sl="${pair%%:*}"; cf="${pair#*:}"
  bash "$STATE" claim-slot --task "$TASK" --run-id "$RUN_ID" --slot "$sl" --owner "thread-parent-2" --owner-gen 2 --generation 2 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK" --run-id "$RUN_ID" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot "$sl" --attempt 1 --task-id "tid-$sl" --child-thread-id "ct-$sl" --child-run-id "cr-$sl" >/dev/null
  bash "$STATE" record-result --task "$TASK" --run-id "$RUN_ID" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot "$sl" --attempt 1 --task-id "tid-$sl" --child-run-id "cr-$sl" --input "$cf" >/dev/null
done

# Re-edit pre-existing M file AND pre-existing ?? file during Phase 1!
printf '\n# sneaky second edit to already-M file\n' >> "$REPO/src/app.py"
printf 're-edited untracked v2\n' > "$REPO/existing-untracked.txt"
out=$(bash "$STATE" commit-phase1 --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "worktree_fp v3 catches re-edit of existing M and ?? files" "$rc" 3
assert_contains "catches src/app.py re-edit" "$out" "src/app.py"
assert_contains "catches existing-untracked.txt re-edit" "$out" "existing-untracked.txt"

# Restore both to start-of-run content -> commit-phase1 succeeds!
git -C "$REPO" checkout -- src/app.py
printf '\n# existing dirty edit\n' >> "$REPO/src/app.py"
printf 'existing untracked v1\n' > "$REPO/existing-untracked.txt"
out=$(bash "$STATE" commit-phase1 --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "commit-phase1 succeeds once drift resolved" "$rc" 0

# Regression (P0 #1): published candidates MUST be non-empty and match original bytes/SHA (NOT empty e3b0c442...)!
EMPTY_SHA="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
for pair in "candidate-a:$TMP/cand-a.md" "candidate-b:$TMP/cand-b.md" "candidate-c:$TMP/cand-c.md"; do
  sl="${pair%%:*}"; orig="${pair#*:}"
  pub="$TASK/research/plans/candidates/$sl.md"
  [ -s "$pub" ] && ok "published $sl.md is non-empty" || fail "published $sl.md is empty!"
  psha=$(shasum -a 256 "$pub" | awk '{print $1}')
  osha=$(shasum -a 256 "$orig" | awk '{print $1}')
  [ "$psha" != "$EMPTY_SHA" ] && ok "$sl.md SHA != empty SHA" || fail "$sl.md wrote empty SHA!"
  assert_eq "$sl.md SHA matches original candidate bytes" "$psha" "$osha"
done

# Clean repo dirty files before Phase 2/3 tests
git -C "$REPO" checkout -- src/app.py
rm -f "$REPO/existing-untracked.txt"

# reveal-blind-map BEFORE commit-phase2a MUST fail!
out=$(bash "$STATE" reveal-blind-map --task "$TASK" 2>&1); rc=$?
assert_rc "reveal-blind-map blocked before Phase 2a lock" "$rc" 3

SHA_A=$(shasum -a 256 "$TASK/research/plans/candidates/candidate-a.md" | awk '{print $1}')
SHA_B=$(shasum -a 256 "$TASK/research/plans/candidates/candidate-b.md" | awk '{print $1}')
SHA_C=$(shasum -a 256 "$TASK/research/plans/candidates/candidate-c.md" | awk '{print $1}')

# Bad blind-eval: cherry-pick citing a fact_check belonging to candidate-c while source_slot is candidate-b!
cat > "$TMP/bad-be.json" <<EOF
{
  "candidate_set": [
    { "slot": "candidate-a", "sha256": "$SHA_A" },
    { "slot": "candidate-b", "sha256": "$SHA_B" },
    { "slot": "candidate-c", "sha256": "$SHA_C" }
  ],
  "fact_checks": [
    { "id": "F1", "candidate_slot": "candidate-c", "claim": "src/app.py:1 returns ok", "status": "CONFIRMED", "file_line_evidence": "src/app.py:1" }
  ],
  "axis_matrix": {
    "architecture_fit": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "ssot_invariants": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "hidden_callers": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "migration_compat": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "real_entrypoint_tests": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "abstraction_restraint": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "prd_scope_fidelity": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "rollback_viability": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "unique_risks": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "key_assumptions": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "dependency_order": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "failure_recovery_acceptance": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}}
  },
  "primary_winner": "candidate-a",
  "winner_rationale": "Cleanest invariants.",
  "eliminated": [
    { "slot": "candidate-b", "rationale": "Extra indirection." },
    { "slot": "candidate-c", "rationale": "Missing rollback." }
  ],
  "cherry_picks": [
    { "source_slot": "candidate-b", "gap_description": "Handle empty input", "evidence_fact_check_id": "F1", "evidence_quote": "src/app.py:1", "compatible_with_winner_architecture": true }
  ],
  "rejected_ideas": [],
  "product_forks": [],
  "product_decisions": [],
  "synthesis_body_markdown": "# Blind Synthesis\nWinner: candidate-a.",
  "initial_design_markdown": "# Design\nBackbone: candidate-a.\n\n## 不变量\n- I-1: validate input.\n"
}
EOF
out=$(bash "$STATE" commit-phase2a --task "$TASK" --repo "$REPO" --input "$TMP/bad-be.json" 2>&1); rc=$?
assert_rc "commit-phase2a rejects cross-slot fact_check citation in cherry_pick" "$rc" 3
assert_contains "cross-slot citation error" "$out" "belonging to 'candidate-c', not source_slot 'candidate-b'"

# Valid blind-eval -> commit-phase2a locks blind-eval.json, synthesis-body-locked.md, and initial-design.md!
sed 's/"source_slot": "candidate-b"/"source_slot": "candidate-c"/' "$TMP/bad-be.json" > "$TMP/good-be.json"
out=$(bash "$STATE" commit-phase2a --task "$TASK" --repo "$REPO" --input "$TMP/good-be.json" 2>&1); rc=$?
assert_rc "commit-phase2a locks valid blind-eval + initial-design" "$rc" 0

out=$(bash "$STATE" reveal-blind-map --task "$TASK" 2>&1); rc=$?
assert_rc "reveal-blind-map succeeds after Phase 2a lock" "$rc" 0
assert_contains "blind map revealed" "$out" "BLIND_MAP_REVEALED=1"

# Post-reveal tamper test: keep synthesis-body-locked.md intact, swap design.md!
cp "$TASK/research/plans/synthesis-body-locked.md" "$TASK/research/plans/synthesis.md"
printf '\n## Attribution Reveal\nTest\n' >> "$TASK/research/plans/synthesis.md"
printf '# Tampered Design: swapped to candidate-b!\n' > "$TASK/design.md"
out=$(bash "$STATE" commit-phase2b --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "commit-phase2b rejects post-reveal design.md swap" "$rc" 3
assert_contains "POST_REVEAL_TAMPER caught" "$out" "POST_REVEAL_TAMPER"

# Mechanical --assemble writes exact locked design.md + synthesis.md with Attribution Reveal!
out=$(bash "$STATE" commit-phase2b --task "$TASK" --repo "$REPO" --assemble 2>&1); rc=$?
assert_rc "commit-phase2b --assemble succeeds" "$rc" 0
assert_contains "synthesis.md has Attribution Reveal" "$(cat "$TASK/research/plans/synthesis.md")" "## Attribution Reveal"

# =============================================================================
printf '\n=== Group E: Phase 3-4 Review Loop, Step-Back Reset, Baseline Drift, Wording & Manual Redesign ===\n'
# =============================================================================

cat > "$TMP/single-rev.json" <<'EOF'
[
  { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" }
]
EOF

# Round 1: initial-full (dirty, citing valid frozen REVIEW.md#no-raw-sql!)
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "Round 1 routes to initial-full (council)" "$out" "PURPOSE=initial-full"

out=$(bash "$STATE" prepare-review --task "$TASK" --repo "$REPO" --purpose initial-full --mode full --slots-json "$TMP/single-rev.json" --owner "thread-parent-2" 2>&1); rc=$?
assert_rc "prepare-review Round 1" "$rc" 0
R1_RUN=$(printf '%s\n' "$out" | sed -n 's/^RUN_ID=//p')
D1_SHA=$(printf '%s\n' "$out" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
LM1=$(printf '%s\n' "$out" | sed -n 's/^LEDGER_MANIFEST=//p')

# Test parse-design-review semantic rejections first:
cat > "$TMP/rev-bad-rule.json" <<EOF
{
  "summary": "Bad rule anchor",
  "mode": "full",
  "reviewed_design_sha256": "$D1_SHA",
  "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "Raw SQL", "location": "design.md:1",
    "pattern": "unsanitized query", "still_wrong": "", "instances": ["design.md:1 -> src/app.py:1"],
    "fix": "use bound params", "prevent": "lint", "evidence": "src/app.py:1",
    "violates_review_md_rule": "REVIEW.md#nonexistent-anchor"
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
out=$(perl "$PARSE_REV" --input "$TMP/rev-bad-rule.json" --expected-mode full --expected-design-sha "$D1_SHA" --ledger-manifest "$LM1" 2>&1); rc=$?
assert_rc "fabricated REVIEW.md rule anchor rejected" "$rc" 1
assert_contains "UNKNOWN_RULE_ANCHOR" "$out" "UNKNOWN_RULE_ANCHOR"

# Valid dirty Round 1 citing real frozen REVIEW.md#no-raw-sql
sed 's/REVIEW.md#nonexistent-anchor/REVIEW.md#no-raw-sql/' "$TMP/rev-bad-rule.json" > "$TMP/rev-r1.json"
bash "$STATE" claim-slot --task "$TASK" --run-id "$R1_RUN" --slot slot1 --owner "thread-parent-2" --owner-gen 2 --generation 2 >/dev/null
bash "$STATE" record-dispatch --task "$TASK" --run-id "$R1_RUN" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-r1" --child-thread-id "c-r1" --child-run-id "cr-r1" >/dev/null
bash "$STATE" record-result --task "$TASK" --run-id "$R1_RUN" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-r1" --child-run-id "cr-r1" --input "$TMP/rev-r1.json" >/dev/null
out=$(bash "$STATE" finish-review-round --task "$TASK" --repo "$REPO" --merged-input "$TMP/rev-r1.json" 2>&1); rc=$?
assert_rc "finish-review-round Round 1 dirty" "$rc" 0
assert_contains "dirty_since_step_back=1" "$out" "DIRTY_SINCE_STEP_BACK=1"

# Must route to disposition-required BEFORE another review round!
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "open blocking class forces disposition-required" "$out" "PURPOSE=disposition-required"

# Also verify contradictory verified + reopens AND unresolved council dispute blocking clean!
# Prepare a quick synthetic ledger-manifest with D1 to test parser semantics directly.
cat > "$TMP/lm-with-d1.json" <<'EOF'
{ "known_classes": { "D1": { "status": "open" } }, "rule_files": { "REVIEW.md": 1 }, "rules_index": { "REVIEW.md#no-raw-sql": 1 } }
EOF
cat > "$TMP/rev-contra.json" <<EOF
{
  "summary": "Contradiction", "mode": "full", "reviewed_design_sha256": "$D1_SHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "D1", "title": "Raw SQL", "location": "design.md:1",
    "pattern": "x", "still_wrong": "still broken", "instances": ["design.md:1"],
    "fix": "fix", "prevent": "test", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [{ "id": "D1", "note": "actually fine" }], "step_back": [], "out_of_scope": []
}
EOF
out=$(perl "$PARSE_REV" --input "$TMP/rev-contra.json" --expected-mode full --expected-design-sha "$D1_SHA" --ledger-manifest "$TMP/lm-with-d1.json" 2>&1); rc=$?
assert_rc "contradictory verified + reopens rejected" "$rc" 1
assert_contains "CONTRADICTORY_VERIFIED_AND_REOPEN" "$out" "CONTRADICTORY_VERIFIED_AND_REOPEN"

cat > "$TMP/rev-unres.json" <<EOF
{
  "summary": "Unresolved council dispute", "mode": "full", "reviewed_design_sha256": "$D1_SHA", "verdict": "clean",
  "findings": [], "verified": [], "step_back": [], "out_of_scope": [],
  "disputes": [{
    "class_id": "D1",
    "reviewer_positions": [
      { "slot": "slot1", "position": "reopen", "evidence": "src/app.py:1" },
      { "slot": "slot2", "position": "verified", "evidence": "src/app.py:2" }
    ],
    "resolution": "unresolved", "code_evidence": ""
  }]
}
EOF
out=$(perl "$PARSE_REV" --input "$TMP/rev-unres.json" --expected-mode full --expected-design-sha "$D1_SHA" --ledger-manifest "$TMP/lm-with-d1.json" --merged 2>&1); rc=$?
assert_rc "unresolved council dispute cannot claim clean" "$rc" 1

# Phase 4 revision: D1 violated REVIEW.md -> recurring! Must require codified.{invariant_id, guard_test}!
cat > "$TMP/disp-nocod.json" <<'EOF'
[{ "id": "D1", "disposition": "adopted", "note": "fixed in design" }]
EOF
out=$(bash "$STATE" commit-phase4-revision --task "$TASK" --repo "$REPO" --dispositions-json "$TMP/disp-nocod.json" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "recurring class without codified rejected" "$out" "MUST provide codified" || fail "expected codified rejection"

printf '\n- I-2: Parameterized queries only (guard: test_no_raw_sql).\n' >> "$TASK/design.md"
cat > "$TMP/disp-r1.json" <<'EOF'
[{
  "id": "D1", "disposition": "adopted", "note": "added I-2",
  "codified": { "invariant_id": "I-2", "guard_test": "test_no_raw_sql", "review_md_entry": "REVIEW.md#no-raw-sql" }
}]
EOF
out=$(bash "$STATE" commit-phase4-revision --task "$TASK" --repo "$REPO" --dispositions-json "$TMP/disp-r1.json" 2>&1); rc=$?
assert_rc "commit-phase4-revision records disposition + design_revisions[]" "$rc" 0
assert_contains "DESIGN_CHANGED=1" "$out" "DESIGN_CHANGED=1"

# Verify Phase 4 controlled revision did NOT invalidate Phase 2!
out=$(bash "$STATE" check-freshness --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_contains "Phase 4 revision preserves Phase 2 (routes to phase3, not phase2)" "$out" "NEXT_STAGE=phase3"

# Helper to run a quick single-reviewer round with given verdict/mode
run_review_round() {
  local purpose="$1" mode="$2" payload_file="$3"
  local pout r_id d_sha
  pout=$(bash "$STATE" prepare-review --task "$TASK" --repo "$REPO" --purpose "$purpose" --mode "$mode" --slots-json "$TMP/single-rev.json" --owner "thread-parent-2") || return 1
  r_id=$(printf '%s\n' "$pout" | sed -n 's/^RUN_ID=//p')
  d_sha=$(printf '%s\n' "$pout" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
  sed "s/__DESIGN_SHA__/$d_sha/g" "$payload_file" > "$TMP/inst-rev.json"
  bash "$STATE" claim-slot --task "$TASK" --run-id "$r_id" --slot slot1 --owner "thread-parent-2" --owner-gen 2 --generation 2 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK" --run-id "$r_id" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$r_id" --child-thread-id "c-$r_id" --child-run-id "cr-$r_id" >/dev/null
  bash "$STATE" record-result --task "$TASK" --run-id "$r_id" --generation 2 --owner "thread-parent-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$r_id" --child-run-id "cr-$r_id" --input "$TMP/inst-rev.json" >/dev/null
  bash "$STATE" finish-review-round --task "$TASK" --repo "$REPO" --merged-input "$TMP/inst-rev.json"
}

# Dirty Rounds 2 & 3 -> triggers step-back!
cat > "$TMP/tpl-dirty-inc.json" <<'EOF'
{
  "summary": "Dirty incremental", "mode": "incremental", "reviewed_design_sha256": "__DESIGN_SHA__", "verdict": "findings",
  "findings": [{
    "severity": "SHOULD_FIX", "reopens": "", "title": "Edge case", "location": "design.md:3",
    "pattern": "missing check", "still_wrong": "", "instances": ["design.md:3"],
    "fix": "add check", "prevent": "test", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
out=$(run_review_round "incremental" "incremental" "$TMP/tpl-dirty-inc.json" 2>&1); rc=$?
assert_rc "Round 2 dirty committed" "$rc" 0
cat > "$TMP/disp-d2.json" <<'EOF'
[{ "id": "D2", "disposition": "adopted", "note": "fixed" }]
EOF
printf '\n- rev2 note\n' >> "$TASK/design.md"
bash "$STATE" commit-phase4-revision --task "$TASK" --repo "$REPO" --dispositions-json "$TMP/disp-d2.json" >/dev/null

out=$(run_review_round "incremental" "incremental" "$TMP/tpl-dirty-inc.json" 2>&1); rc=$?
assert_rc "Round 3 dirty committed" "$rc" 0
cat > "$TMP/disp-d3.json" <<'EOF'
[{ "id": "D3", "disposition": "adopted", "note": "fixed" }]
EOF
printf '\n- rev3 note\n' >> "$TASK/design.md"
bash "$STATE" commit-phase4-revision --task "$TASK" --repo "$REPO" --dispositions-json "$TMP/disp-d3.json" >/dev/null

# Now dirty_since_step_back == 3 -> next-review MUST return step-back!
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "3 dirty rounds trigger step-back" "$out" "PURPOSE=step-back"

# Step-back round with EMPTY findings[] but structural step_back[] item:
# MUST reset dirty_since_step_back=0, increment step_backs_done=1, AND still require Phase 4c assessment!
cat > "$TMP/tpl-sb-empty.json" <<'EOF'
{
  "summary": "Structural step-back recommendation", "mode": "step-back", "reviewed_design_sha256": "__DESIGN_SHA__", "verdict": "clean",
  "findings": [], "verified": [],
  "step_back": [{
    "classes": ["D1"], "name": "Single validation gateway",
    "invites_because": "checks scattered", "approach_change": "central validator", "prevent": "I-2 guard"
  }],
  "out_of_scope": []
}
EOF
out=$(run_review_round "step-back" "step-back" "$TMP/tpl-sb-empty.json" 2>&1); rc=$?
assert_rc "step-back round committed" "$rc" 0
assert_contains "STEP-BACK BUG FIXED: dirty_since_step_back reset to 0" "$out" "DIRTY_SINCE_STEP_BACK=0"
assert_contains "step_backs_done=1" "$out" "STEP_BACKS_DONE=1"

# Even with empty findings[], step-back MUST require Phase 4c assessment before next review!
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "empty-findings step-back still requires Phase 4c disposition" "$out" "PURPOSE=disposition-required"

printf '\n- structural step-back update\n' >> "$TASK/design.md"
bash "$STATE" commit-phase4-revision --task "$TASK" --repo "$REPO" --step-back-assessment-done >/dev/null

# After step-back assessment done, next-review MUST NOT stop (proving dual-plan bug is fixed!)
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "post-step-back routes to incremental (NOT stop!)" "$out" "PURPOSE=incremental"

# Clean Round 1 (incremental)
cat > "$TMP/tpl-clean-inc.json" <<'EOF'
{
  "summary": "Clean incremental", "mode": "incremental", "reviewed_design_sha256": "__DESIGN_SHA__", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "verified" }], "step_back": [], "out_of_scope": []
}
EOF
out=$(run_review_round "incremental" "incremental" "$TMP/tpl-clean-inc.json" 2>&1); rc=$?
assert_rc "clean round 1 (incremental)" "$rc" 0
assert_contains "clean_streak=1" "$out" "CLEAN_STREAK=1"

# Counterexample: source code changes between Clean Round 1 and Clean Round 2 while design.md is UNCHANGED!
printf '\n# source changed between clean rounds\n' >> "$REPO/src/app.py"
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
if printf '%s\n' "$out" | grep -Fq "PURPOSE=confirmation-full"; then
  fail "source change between clean rounds MUST invalidate confirmation-full!"
else
  ok "source change between clean rounds invalidates clean_streak (not confirmation-full)"
fi
# Restore src/app.py -> confirmation-full returns!
git -C "$REPO" checkout -- src/app.py
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "confirmation-full restored when source clean" "$out" "PURPOSE=confirmation-full"

# Clean Round 2 (confirmation-full) -> CONVERGED!
cat > "$TMP/tpl-clean-full.json" <<'EOF'
{
  "summary": "Clean confirmation full", "mode": "full", "reviewed_design_sha256": "__DESIGN_SHA__", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "verified full" }], "step_back": [], "out_of_scope": []
}
EOF
out=$(run_review_round "confirmation-full" "full" "$TMP/tpl-clean-full.json" 2>&1); rc=$?
assert_rc "clean round 2 (confirmation-full) converges" "$rc" 0
assert_contains "CONVERGED=1" "$out" "CONVERGED=1"

# Counterexample: simultaneous PRD wording edit + REVIEW.md edit -> ack-wording-closure MUST REJECT!
printf '\nMinor wording polish only.\n' >> "$TASK/prd.md"
bash "$STATE" commit-phase0 --task "$TASK" --repo "$REPO" --change-kind wording --evidence "clarified phrasing only" >/dev/null
printf '\n## Extra Unreviewed Rule\nSomething new.\n' >> "$REPO/REVIEW.md"
out=$(bash "$STATE" ack-wording-closure --task "$TASK" --repo "$REPO" --evidence "trying to bypass rule change" 2>&1); rc=$?
assert_rc "ack-wording-closure rejects when REVIEW.md ALSO changed" "$rc" 3
assert_contains "non_prd_baseline_sha256 drift caught" "$out" "non_prd_baseline_sha256 drifted"

# Restore REVIEW.md -> ack-wording-closure succeeds cleanly!
git -C "$REPO" checkout -- REVIEW.md
out=$(bash "$STATE" ack-wording-closure --task "$TASK" --repo "$REPO" --evidence "only PRD wording changed; non-PRD baseline identical" 2>&1); rc=$?
assert_rc "ack-wording-closure succeeds when non-PRD baseline identical" "$rc" 0
assert_contains "REBOUND=converged" "$out" "REBOUND=converged"

# Counterexample: manual_redesign MUST beat converged!
bash "$STATE" record-user-decision --task "$TASK" --repo "$REPO" --choice manual_redesign --reason "human takeover" >/dev/null
out=$(bash "$STATE" next-review --task "$TASK" --repo "$REPO" 2>&1)
assert_contains "manual_redesign beats converged in next-review" "$out" "PURPOSE=blocked-manual-redesign"
out=$(bash "$STATE" check-freshness --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "manual_redesign blocks freshness gate" "$rc" 1
assert_contains "NEXT_STAGE=blocked-manual-redesign" "$out" "NEXT_STAGE=blocked-manual-redesign"

# Clear manual_redesign, re-run 2 clean rounds to re-converge cleanly for Phase 5/6!
bash "$STATE" clear-manual-redesign --task "$TASK" --reason "human handed back design" >/dev/null
run_review_round "full" "full" "$TMP/tpl-clean-full.json" >/dev/null
run_review_round "confirmation-full" "full" "$TMP/tpl-clean-full.json" >/dev/null

# =============================================================================
printf '\n=== Group F: Phase 5 Non-Seed JSONL/Codification + Phase 6 Activation & Hook/Pointer Traps ===\n'
# =============================================================================

# Missing check.jsonl and seed-only implement.jsonl MUST fail Phase 5!
cat > "$TASK/implement.md" <<'EOF'
# Implement Plan
- Implement I-2 with guard test `test_no_raw_sql` and update `REVIEW.md#no-raw-sql` in implementation PR.
EOF
cat > "$TASK/implement.jsonl" <<'EOF'
{"_example": "seed row only"}
EOF
out=$(bash "$STATE" commit-phase5 --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "Phase 5 rejects seed-only implement.jsonl" "$rc" 3
assert_contains "seed-only error" "$out" "zero non-seed entries"

# Valid non-seed implement.jsonl + check.jsonl -> Phase 5 & Phase 6 ready pass!
cat > "$TASK/implement.jsonl" <<'EOF'
{"file": ".trellis/spec/core.md", "reason": "Core spec"}
EOF
cat > "$TASK/check.jsonl" <<'EOF'
{"file": ".trellis/spec/core.md", "reason": "Check spec"}
EOF
out=$(bash "$STATE" commit-phase5 --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "Phase 5 passes with non-seed JSONLs & codification" "$rc" 0

out=$(bash "$STATE" commit-phase6-ready --task "$TASK" --repo "$REPO" --authorization "authorized-impl" 2>&1); rc=$?
assert_rc "Phase 6 ready committed" "$rc" 0

# Test unreadable .trellis/config.yaml -> AFTER_START_HOOKS=unknown (fail-closed!)
chmod 000 "$REPO/.trellis/config.yaml"
out=$(bash "$STATE" preflight-trellis --repo "$REPO" 2>&1)
assert_contains "unreadable config.yaml reports AFTER_START_HOOKS=unknown" "$out" "AFTER_START_HOOKS=unknown"
chmod 644 "$REPO/.trellis/config.yaml"

# Test 6a: Concurrent starter blocked while .activation.lock held!
export TRELLIS_CONTEXT_ID="ctx-session-1"
T3_TRI_PLAN_TEST_HOLD_ACT_LOCK_SECS=2 bash "$STATE" activate-task --task "$TASK" --repo "$REPO" --owner "parent-A" --authorization "impl" >"$TMP/act1.out" 2>&1 &
PID_ACT1=$!
sleep 0.5
out2=$(bash "$STATE" activate-task --task "$TASK" --repo "$REPO" --owner "parent-B" --authorization "impl" 2>&1); rc2=$?
assert_rc "concurrent starter blocked by .activation.lock (exit 5)" "$rc2" 5
assert_contains "ACTIVATION_IN_PROGRESS=1" "$out2" "ACTIVATION_IN_PROGRESS=1"
wait "$PID_ACT1"; rc1=$?
assert_rc "first starter completes cleanly -> activated" "$rc1" 0
assert_contains "ACTIVATED=1" "$(cat "$TMP/act1.out")" "ACTIVATED=1"
out=$(bash "$STATE" check-freshness --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "post-activation freshness passes" "$rc" 0
assert_contains "NEXT_STAGE=done" "$out" "NEXT_STAGE=done"

# Regression: commit-phase6-ready MUST refuse downgrading a valid activated state back to ready!
out=$(bash "$STATE" commit-phase6-ready --task "$TASK" --repo "$REPO" --authorization "impl" 2>&1); rc=$?
assert_rc "commit-phase6-ready refuses downgrading valid activated -> ready" "$rc" 3
assert_contains "downgrade refusal message" "$out" "refusing to downgrade activated to ready"

# Test 6b: after_start clears active pointer while start exits 0 with in_progress and ZERO warnings!
# Legally re-arm Phase 6 by updating implement.md and re-committing Phase 5 + Phase 6 ready.
cat > "$TASK/task.json" <<'EOF'
{ "id": "01-tri-test", "title": "Tri Test", "status": "planning" }
EOF
rm -rf "$REPO/.trellis/.mock-ptrs"
printf '\n- Note: re-armed for Test 6b.\n' >> "$TASK/implement.md"
bash "$STATE" commit-phase5 --task "$TASK" --repo "$REPO" >/dev/null
bash "$STATE" commit-phase6-ready --task "$TASK" --repo "$REPO" --authorization "impl" >/dev/null
out=$(MOCK_START_MODE=clear_ptr_exit0 bash "$STATE" activate-task --task "$TASK" --repo "$REPO" --owner "parent-A" --authorization "impl" 2>&1); rc=$?
assert_rc "cleared pointer despite exit 0 + no warnings enters activation_uncertain" "$rc" 3
assert_contains "PHASE6_STATE=activation_uncertain (cleared pointer)" "$out" "PHASE6_STATE=activation_uncertain"

# Manual resolve-activation --resolution confirmed_activated MUST ALSO REJECT the cleared pointer!
out=$(bash "$STATE" resolve-activation --task "$TASK" --repo "$REPO" --resolution confirmed_activated --evidence "human tried anyway" 2>&1); rc=$?
assert_rc "resolve-activation ALSO refuses cleared pointer (shared postcondition!)" "$rc" 3
assert_contains "pointer empty/cleared rejected" "$out" "active task pointer is empty/cleared"

# Test 6c: start exits 0 with hook warning -> activation_uncertain!
cat > "$TASK/task.json" <<'EOF'
{ "id": "01-tri-test", "title": "Tri Test", "status": "planning" }
EOF
rm -rf "$REPO/.trellis/.mock-ptrs"
bash "$STATE" resolve-activation --task "$TASK" --repo "$REPO" --resolution reset_to_ready --evidence "rolled back" >/dev/null
out=$(MOCK_START_MODE=hook_warn_exit0 bash "$STATE" activate-task --task "$TASK" --repo "$REPO" --owner "parent-A" --authorization "impl" 2>&1); rc=$?
assert_rc "hook warning despite exit 0 enters activation_uncertain" "$rc" 3
assert_contains "hook warning detected" "$out" "after_start hook warning detected"
# Once human verifies pointer & in_progress are intact, resolve-activation confirmed_activated passes!
out=$(bash "$STATE" resolve-activation --task "$TASK" --repo "$REPO" --resolution confirmed_activated --evidence "human verified hook manually" 2>&1); rc=$?
assert_rc "resolve-activation passes when pointer + in_progress + freshness all hold" "$rc" 0

# Test 6d: crash between set_active_task (pointer set) and write_json (status still planning) -> recover-activation -> activation_uncertain!
cat > "$TASK/task.json" <<'EOF'
{ "id": "01-tri-test", "title": "Tri Test", "status": "planning" }
EOF
rm -rf "$REPO/.trellis/.mock-ptrs"
printf '\n- Note: re-armed for Test 6d.\n' >> "$TASK/implement.md"
bash "$STATE" commit-phase5 --task "$TASK" --repo "$REPO" >/dev/null
bash "$STATE" commit-phase6-ready --task "$TASK" --repo "$REPO" --authorization "impl" >/dev/null
MOCK_START_MODE=crash_after_ptr T3_TRI_PLAN_TEST_CRASH_AFTER_START=1 bash "$STATE" activate-task --task "$TASK" --repo "$REPO" --owner "parent-A" --authorization "impl" >/dev/null 2>&1
out=$(bash "$STATE" recover-activation --task "$TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "crash with pointer set + status planning -> activation_uncertain" "$rc" 3
assert_contains "RECOVERY_CASE=partial_pointer_only" "$out" "RECOVERY_CASE=partial_pointer_only"

# =============================================================================
printf '\n=== Group G: PRD Material Supersedence Crash & Recreated Source Conflict + Legacy Migration ===\n'
# =============================================================================

# First resolve Test 6d's activation_uncertain via the explicit human-verified exit path before PRD material pivot!
rm -rf "$REPO/.trellis/.mock-ptrs"
bash "$STATE" resolve-activation --task "$TASK" --repo "$REPO" --resolution reset_to_ready --evidence "human cleared partial pointer before PRD pivot" >/dev/null
assert_rc "resolve-activation reset_to_ready exits activation_uncertain cleanly before PRD pivot" "$?" 0

# Simulate crash right after moving candidates/ during PRD material change!
printf '\nBREAKING PRD CHANGE: new architecture required.\n' >> "$TASK/prd.md"
T3_TRI_PLAN_TEST_CRASH_AFTER_OP=2 bash "$STATE" commit-phase0 --task "$TASK" --repo "$REPO" --change-kind material --reason "major scope change" >/dev/null 2>&1
rc_m=$?
[ "$rc_m" -ne 0 ] && ok "simulated crash mid-PRD archive move" || fail "expected mid-archive crash"

# External writer recreates research/plans/candidates/ while archive tx is still pending!
mkdir -p "$TASK/research/plans/candidates"
printf 'recreated external file\n' > "$TASK/research/plans/candidates/rogue.md"
out=$(bash "$STATE" check-freshness --task "$TASK" --repo "$REPO" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "recover_tx catches recreated archive source as EXTERNAL_CONFLICT" "$out" "EXTERNAL_CONFLICT" || fail "expected EXTERNAL_CONFLICT"

# Remove recreated rogue dir -> recover_tx completes idempotently across next_generation!
rm -rf "$TASK/research/plans/candidates"
out=$(bash "$STATE" inspect-task --task "$TASK" 2>&1); rc=$?
assert_rc "recover_tx completes PRD material archive idempotently" "$rc" 0
assert_contains "TX_RECOVERED=2" "$out" "TX_RECOVERED=2"
assert_contains "generation incremented to 3" "$out" "GENERATION=3"

# Legacy dual-plan task (modeled on archived 11-18-caret-report-offset: short hashes + mismatched user_decision!)
LEG_TASK="$REPO/.trellis/tasks/02-legacy"
mkdir -p "$LEG_TASK/research/plans"
printf '# Legacy PRD\n' > "$LEG_TASK/prd.md"
printf '# Legacy Design (current bytes -> sha != a49a1871)\n' > "$LEG_TASK/design.md"
printf '# Claude\n' > "$LEG_TASK/research/plans/claude.md"
printf '# Codex\n' > "$LEG_TASK/research/plans/codex.md"
cat > "$LEG_TASK/research/plans/planning-state.json" <<'EOF'
{
  "phases": { "0": { "prd": "deadbeef" } },
  "review": {
    "rounds": [
      { "n": 3, "mode": "incremental", "sha": "7d50cdb44616", "verdict": "dirty" }
    ],
    "user_decision": {
      "choice": "B narrow PR",
      "design_sha256": "a49a18718347de868b2c4b3b6fd29be2e8cf426920fc6ac45cb3f04be9159e83"
    }
  }
}
EOF
out=$(bash "$STATE" inspect-task --task "$LEG_TASK" 2>&1); rc=$?
assert_rc "inspect-task classifies legacy task" "$rc" 0
assert_contains "TASK_KIND=LEGACY_DUAL_PLAN" "$out" "TASK_KIND=LEGACY_DUAL_PLAN"

out=$(bash "$STATE" migrate-legacy --task "$LEG_TASK" --confirm 2>&1); rc=$?
assert_rc "migrate-legacy imports legacy task safely" "$rc" 0
assert_contains "legacy user_decision mismatch flagged unproven" "$out" "legacy_user_decision"
out=$(bash "$STATE" commit-phase6-ready --task "$LEG_TASK" --repo "$REPO" 2>&1); rc=$?
assert_rc "migrated legacy task CANNOT auto-pass Phase 6" "$rc" 3

# =============================================================================
printf '\n=== Group H: install-skills.sh Symlink Ownership Protection ===\n'
# =============================================================================

INST_DIR="$TMP/skills-dir"
mkdir -p "$INST_DIR" "$TMP/foreign-skill"
ln -s "$TMP/foreign-skill" "$INST_DIR/t3-tri-plan"
out=$(bash "$INSTALLER" --target "$INST_DIR" 2>&1); rc=$?
assert_rc "install refuses to overwrite foreign symlink" "$rc" 2
assert_contains "foreign symlink warning" "$out" "foreign symlink"

out=$(bash "$INSTALLER" --target "$INST_DIR" --uninstall 2>&1); rc=$?
assert_rc "uninstall skips foreign symlink cleanly" "$rc" 0
[ -L "$INST_DIR/t3-tri-plan" ] && ok "foreign symlink preserved on uninstall" || fail "foreign symlink was deleted!"

rm -f "$INST_DIR/t3-tri-plan"
out=$(bash "$INSTALLER" --target "$INST_DIR" 2>&1); rc=$?
assert_rc "install succeeds on clean target" "$rc" 0
out=$(bash "$INSTALLER" --target "$INST_DIR" --check 2>&1); rc=$?
assert_rc "install --check passes" "$rc" 0
out=$(bash "$INSTALLER" --target "$INST_DIR" --uninstall 2>&1); rc=$?
assert_rc "uninstall removes owned symlink" "$rc" 0
[ ! -e "$INST_DIR/t3-tri-plan" ] && ok "owned symlink removed cleanly" || fail "owned symlink remained"
out=$(bash "$INSTALLER" --target 2>&1); rc=$?
assert_rc "install-skills missing --target value fails fast without hang" "$rc" 2

# =============================================================================
printf '\n=== Group I: Post-Review Hardening Regressions (UTF-8, Phase2a Lock/Forks, Takeover Revisions, Phase6 Child Lock & Signals) ===\n'
# =============================================================================

# I1. Full Chinese 12-section candidate + Chinese REVIEW.md heading anchor + Chinese evidence_quote
cat > "$TMP/cand-zh.md" <<'EOF'
# 设计方案（中文）

## 1. 现状代码证据
已验证 `src/app.py:1` 中的入口行为。

## 2. 推荐架构
单一状态所有者架构，避免双写分叉。

## 3. 数据与控制流
请求 -> 校验器 -> 原子事务 -> 状态存储。

## 4. 涉及文件与模块
- `src/app.py`

## 5. 调用方与下游消费者
- `src/cli.py:5`

## 6. 数据迁移与兼容性
保持 schema_version=2 向后兼容。

## 7. 测试策略
通过真实 CLI 入口执行端到端回归测试。

## 8. 回滚策略
单提交可干净回滚。

## 9. 风险与未知项
确保不变量 I-1 始终成立。

## 10. 备选方案
放弃无锁并发写入方案。

## 11. 实施顺序
1. 补齐校验；2. 补齐回归测试。

## Summary
- 核心论点：中文方案验证完整保留字节。
- 最大风险：编码处理不当。
- 关键分叉：无。
EOF
out=$(perl "$VAL_CAND" --input "$TMP/cand-zh.md" --write-canonical "$TMP/cand-zh-out.md" 2>&1); rc=$?
assert_rc "Chinese 12-section candidate passes validation" "$rc" 0
assert_contains "Chinese candidate VALID=1" "$out" "VALID=1"
[ -s "$TMP/cand-zh-out.md" ] && cmp -s "$TMP/cand-zh.md" "$TMP/cand-zh-out.md" && ok "Chinese candidate bytes preserved verbatim (no empty file)" || fail "Chinese candidate bytes altered or empty"
if printf '%s\n' "$out" | grep -Fq "Wide character"; then fail "unexpected Wide character warning"; else ok "no Wide character warning on Chinese candidate"; fi

# I2. Config hardening: --ignore-project-config, *_DRIVER_KIND, omit unifiedEffort on per-model, reject effort on no-effort model, knobs effective
CAPS_NOEFF="$TMP/caps-noeff.json"
cat > "$CAPS_NOEFF" <<'EOF'
{
  "inheritedProviderInstanceId": "antigravity",
  "providers": [
    {
      "providerInstanceId": "antigravity",
      "driverKind": "antigravity-drv",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "gemini-4-neon", "options": [{ "id": "thought_level", "values": ["low","medium","high","xhigh"], "default": "high" }] },
        { "id": "no-effort-model", "options": [] }
      ]
    },
    {
      "providerInstanceId": "claudeAgent",
      "driverKind": "claude-drv",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "claude-opus-5-5", "options": [{ "id": "effort", "values": ["low","medium","high","xhigh","max"], "default": "medium" }] }
      ]
    },
    {
      "providerInstanceId": "codex",
      "driverKind": "codex-drv",
      "canRunChildTask": true,
      "canRunCrossProviderChildTask": true,
      "models": [
        { "id": "gpt-6.2-sol", "options": [{ "id": "reasoningEffort", "values": ["low","medium","high","xhigh","max","ultra"], "default": "low" }] }
      ]
    }
  ]
}
EOF
REPO_I="$TMP/repo-i"
make_repo "$REPO_I"
printf '\n## 禁止裸写SQL\n任何查询均须参数化。\n' >> "$REPO_I/REVIEW.md"
git -C "$REPO_I" add REVIEW.md && git -C "$REPO_I" commit -q -m "add chinese review rule"

cat > "$REPO_I/.t3-tri-plan.json" <<'EOF'
{
  "version": 1,
  "knobs": { "roundCap": 1, "maxStepBacks": 0 }
}
EOF
out=$(bash "$STATE" config-show --repo "$REPO_I" --capabilities "$CAPS_NOEFF" 2>&1); rc=$?
assert_rc "config-show with DRIVER_KIND + project knobs passes" "$rc" 0
assert_contains "DEFAULT_REVIEWER_DRIVER_KIND emitted" "$out" "DEFAULT_REVIEWER_DRIVER_KIND=codex-drv"
assert_contains "DESIGNER_1_DRIVER_KIND emitted" "$out" "DESIGNER_1_DRIVER_KIND=antigravity-drv"
assert_contains "project knob roundCap=1 applied" "$out" "KNOB_ROUND_CAP=1"
assert_contains "project knob maxStepBacks=0 applied" "$out" "KNOB_MAX_STEP_BACKS=0"

out=$(bash "$STATE" config-show --repo "$REPO_I" --capabilities "$CAPS_NOEFF" --ignore-project-config 2>&1); rc=$?
assert_rc "config-show --ignore-project-config succeeds" "$rc" 0
assert_contains "PROJECT_CONFIG_IGNORED=1" "$out" "PROJECT_CONFIG_IGNORED=1"
assert_contains "default roundCap=3 restored when project config ignored" "$out" "KNOB_ROUND_CAP=3"

out=$(bash "$STATE" config-show --repo "$REPO_I" --capabilities "$CAPS_NOEFF" --single antigravity/gemini-4-neon:high 2>&1); rc=$?
assert_rc "config-show --single succeeds" "$rc" 0
if printf '%s\n' "$out" | grep -Fq '"unifiedEffort":null'; then
  fail "EFFECTIVE_JSON emitted invalid unifiedEffort:null on per-model group"
else
  ok "EFFECTIVE_JSON omits unifiedEffort on per-model group"
fi

out=$(bash "$STATE" config-show --repo "$REPO_I" --capabilities "$CAPS_NOEFF" --override-model antigravity/no-effort-model --override-effort high 2>&1); rc=$?
assert_rc "non-empty effort rejected on model with empty effortKey" "$rc" 3
assert_contains "model does not support effort options" "$out" "does not support effort options"

# I3. Fresh task in REPO_I: Phase 1 -> Phase 2a product_forks -> completed_forks_pending -> 2nd judge -> lock -> immutability -> Phase 3/4 takeover + Chinese anchor + live PRD/ledger/synthesis drift!
TASK_I="$REPO_I/.trellis/tasks/01-hardening"
mkdir -p "$TASK_I"
printf '# PRD\nSupport Chinese & hardening checks.\n' > "$TASK_I/prd.md"
cat > "$TASK_I/task.json" <<'EOF'
{ "id": "01-hardening", "title": "Hardening", "status": "planning" }
EOF
bash "$STATE" commit-phase0 --task "$TASK_I" --repo "$REPO_I" >/dev/null
p1_out=$(bash "$STATE" prepare-design --task "$TASK_I" --repo "$REPO_I" --slots-json "$TMP/designers.json" --owner "owner-1")
P1_RUN=$(printf '%s\n' "$p1_out" | sed -n 's/^RUN_ID=//p')

# Test update-slot rejects illegal pending -> waiting transition (exit 4)
out=$(bash "$STATE" update-slot --task "$TASK_I" --run-id "$P1_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot candidate-a --attempt 0 --state waiting 2>&1); rc=$?
assert_rc "update-slot rejects illegal pending -> waiting transition" "$rc" 4

# Test claim-slot without --generation still rejects stale owner before recover_tx (exit 4)
out=$(bash "$STATE" claim-slot --task "$TASK_I" --run-id "$P1_RUN" --slot candidate-a --owner "wrong-owner" --owner-gen 1 2>&1); rc=$?
assert_rc "claim-slot without --generation rejects wrong owner" "$rc" 4

for pair in "candidate-a:$TMP/cand-zh.md" "candidate-b:$TMP/cand-b.md" "candidate-c:$TMP/cand-c.md"; do
  sl="${pair%%:*}"; cf="${pair#*:}"
  bash "$STATE" claim-slot --task "$TASK_I" --run-id "$P1_RUN" --slot "$sl" --owner "owner-1" --owner-gen 1 --generation 1 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$P1_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot "$sl" --attempt 1 --task-id "ti-$sl" --child-thread-id "cti-$sl" --child-run-id "cri-$sl" >/dev/null
  bash "$STATE" record-result --task "$TASK_I" --run-id "$P1_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot "$sl" --attempt 1 --task-id "ti-$sl" --child-run-id "cri-$sl" --input "$cf" >/dev/null
done
bash "$STATE" commit-phase1 --task "$TASK_I" --repo "$REPO_I" >/dev/null

# Phase 2a: prepare-judge -> 1st judge returns product_forks -> completed_forks_pending -> 2nd judge resolves -> lock -> overwrite refused!
cat > "$TMP/judge-target.json" <<'EOF'
{ "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" }
EOF
pj_out=$(bash "$STATE" prepare-judge --task "$TASK_I" --repo "$REPO_I" --target-json "$TMP/judge-target.json" --owner "owner-1")
PJ_RUN=$(printf '%s\n' "$pj_out" | sed -n 's/^RUN_ID=//p')

ISHA_A=$(shasum -a 256 "$TASK_I/research/plans/candidates/candidate-a.md" | awk '{print $1}')
ISHA_B=$(shasum -a 256 "$TASK_I/research/plans/candidates/candidate-b.md" | awk '{print $1}')
ISHA_C=$(shasum -a 256 "$TASK_I/research/plans/candidates/candidate-c.md" | awk '{print $1}')

cat > "$TMP/be-forks.json" <<EOF
{
  "candidate_set": [
    { "slot": "candidate-a", "sha256": "$ISHA_A" },
    { "slot": "candidate-b", "sha256": "$ISHA_B" },
    { "slot": "candidate-c", "sha256": "$ISHA_C" }
  ],
  "fact_checks": [
    { "id": "F1", "candidate_slot": "candidate-c", "claim": "验证入口 src/app.py:1", "status": "CONFIRMED", "file_line_evidence": "src/app.py:1 验证入口" }
  ],
  "axis_matrix": {
    "architecture_fit": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "ssot_invariants": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "hidden_callers": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "migration_compat": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "real_entrypoint_tests": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "abstraction_restraint": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "prd_scope_fidelity": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "rollback_viability": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "unique_risks": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "key_assumptions": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "dependency_order": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "failure_recovery_acceptance": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}}
  },
  "primary_winner": "candidate-a",
  "winner_rationale": "清晰不变量。",
  "eliminated": [
    { "slot": "candidate-b", "rationale": "冗余层。" },
    { "slot": "candidate-c", "rationale": "缺少回滚。" }
  ],
  "cherry_picks": [
    { "source_slot": "candidate-c", "gap_description": "中文证据引用", "evidence_fact_check_id": "F1", "evidence_quote": "验证入口", "compatible_with_winner_architecture": true }
  ],
  "rejected_ideas": [],
  "product_forks": [
    { "id": "FK1", "question": "错误码格式？", "options": ["JSON 对象", "纯文本"], "trade_offs": "JSON 更利于机器解析，纯文本更简单。" }
  ],
  "product_decisions": [],
  "synthesis_body_markdown": "# 盲评综合\n胜出：candidate-a。",
  "initial_design_markdown": "# 设计\n主干：candidate-a。\n\n## 不变量\n- I-1: 参数化查询。\n"
}
EOF
bash "$STATE" claim-slot --task "$TASK_I" --run-id "$PJ_RUN" --slot judge --owner "owner-1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$PJ_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot judge --attempt 1 --task-id "tj-1" --child-thread-id "ctj-1" --child-run-id "crj-1" >/dev/null
out=$(bash "$STATE" record-result --task "$TASK_I" --run-id "$PJ_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot judge --attempt 1 --task-id "tj-1" --child-run-id "crj-1" --input "$TMP/be-forks.json" 2>&1); rc=$?
assert_rc "judge with product_forks records cleanly (exit 0)" "$rc" 0
assert_contains "judge slot transitions to completed_forks_pending" "$out" "SLOT_STATE=completed_forks_pending"
assert_contains "FORKS=1 emitted" "$out" "FORKS=1"

out=$(bash "$STATE" commit-phase2a --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "commit-phase2a refuses completed_forks_pending" "$rc" 3

# Claim attempt 2 from completed_forks_pending & resolve forks!
out=$(bash "$STATE" claim-slot --task "$TASK_I" --run-id "$PJ_RUN" --slot judge --owner "owner-1" --owner-gen 1 --generation 1 2>&1); rc=$?
assert_rc "claim-slot succeeds from completed_forks_pending (attempt 2)" "$rc" 0
assert_contains "ATTEMPT=2" "$out" "ATTEMPT=2"

python3 -c '
import json
d = json.load(open("'"$TMP/be-forks.json"'"))
d["product_forks"] = []
d["product_decisions"] = [{"fork_id": "FK1", "chosen_option": "JSON 对象", "user_answer": "选择 JSON 对象格式"}]
json.dump(d, open("'"$TMP/be-final.json"'", "w"), ensure_ascii=False, indent=2)
d2 = dict(d)
d2["winner_rationale"] = "Tampered rationale"
json.dump(d2, open("'"$TMP/be-tamper.json"'", "w"), ensure_ascii=False, indent=2)
'
bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$PJ_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot judge --attempt 2 --task-id "tj-2" --child-thread-id "ctj-2" --child-run-id "crj-2" >/dev/null
out=$(bash "$STATE" record-result --task "$TASK_I" --run-id "$PJ_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot judge --attempt 2 --task-id "tj-2" --child-run-id "crj-2" --input "$TMP/be-final.json" 2>&1); rc=$?
assert_rc "resolved judge attempt 2 passes (Chinese evidence_quote accepted)" "$rc" 0
assert_contains "SLOT_STATE=completed_valid" "$out" "SLOT_STATE=completed_valid"
assert_contains "FORKS=0" "$out" "FORKS=0"

out=$(bash "$STATE" commit-phase2a --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "commit-phase2a locks resolved blind-eval" "$rc" 0

# Phase 2a immutability: refusing different payload AND refusing prepare-judge after lock!
out=$(bash "$STATE" commit-phase2a --task "$TASK_I" --repo "$REPO_I" --input "$TMP/be-tamper.json" 2>&1); rc=$?
assert_rc "commit-phase2a refuses overwriting locked Phase 2a with different payload" "$rc" 3
assert_contains "already locked error" "$out" "Phase 2a is already locked"
out=$(bash "$STATE" prepare-judge --task "$TASK_I" --repo "$REPO_I" --target-json "$TMP/judge-target.json" --owner "owner-1" 2>&1); rc=$?
assert_rc "prepare-judge refuses after Phase 2a is locked" "$rc" 3

bash "$STATE" commit-phase2b --task "$TASK_I" --repo "$REPO_I" --assemble >/dev/null

# I4. Phase 3 Chinese REVIEW.md anchor + configured knobs (roundCap=1, maxStepBacks=0) + Phase 4 design_revisions[] surviving takeover-run!
pr_out=$(bash "$STATE" prepare-review --task "$TASK_I" --repo "$REPO_I" --purpose initial-full --mode full --slots-json "$TMP/single-rev.json" --owner "owner-1")
PR_RUN=$(printf '%s\n' "$pr_out" | sed -n 's/^RUN_ID=//p')
PR_DSHA=$(printf '%s\n' "$pr_out" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
cat > "$TMP/rev-zh.json" <<EOF
{
  "summary": "中文规则锚点命中", "mode": "full", "reviewed_design_sha256": "$PR_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "违反中文规则", "location": "design.md:1",
    "pattern": "裸写 SQL", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "使用参数化查询", "prevent": "单测保护", "evidence": "src/app.py:1",
    "violates_review_md_rule": "REVIEW.md#禁止裸写sql"
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_I" --run-id "$PR_RUN" --slot slot1 --owner "owner-1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$PR_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tr-1" --child-thread-id "ctr-1" --child-run-id "crr-1" >/dev/null
out=$(bash "$STATE" record-result --task "$TASK_I" --run-id "$PR_RUN" --generation 1 --owner "owner-1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tr-1" --child-run-id "crr-1" --input "$TMP/rev-zh.json" 2>&1); rc=$?
assert_rc "Chinese REVIEW.md#禁止裸写sql anchor accepted by parse-design-review" "$rc" 0
bash "$STATE" finish-review-round --task "$TASK_I" --repo "$REPO_I" --merged-input "$TMP/rev-zh.json" >/dev/null

printf '\n- I-99: 参数化查询守卫 (guard: test_zh_sql)。\n' >> "$TASK_I/design.md"
cat > "$TMP/disp-i.json" <<'EOF'
[{ "id": "D1", "disposition": "adopted", "note": "已修复", "codified": { "invariant_id": "I-99", "guard_test": "test_zh_sql" } }]
EOF
bash "$STATE" commit-phase4-revision --task "$TASK_I" --repo "$REPO_I" --dispositions-json "$TMP/disp-i.json" >/dev/null

# Configured project knobs (roundCap=1, maxStepBacks=0) MUST cause 1 dirty round -> stop!
out=$(bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1)
assert_contains "configured knobs (roundCap=1, maxStepBacks=0) take effect -> PURPOSE=stop" "$out" "PURPOSE=stop"

# Remove project knobs override so we can verify takeover-run + design_revisions[] + convergence cleanly
rm -f "$REPO_I/.t3-tri-plan.json"
bash "$STATE" takeover-run --task "$TASK_I" --new-owner "owner-2" --reason "parent thread restarted" >/dev/null
out=$(bash "$STATE" check-freshness --task "$TASK_I" --repo "$REPO_I" 2>&1)
if printf '%s\n' "$out" | grep -Fq "generation mismatch"; then
  fail "takeover-run bricked design_revisions[]!"
else
  ok "takeover-run preserves design_revisions[] validity across generation increment"
fi

# Converge TASK_I cleanly under owner-2 / gen 2!
for purp in "full" "confirmation-full"; do
  po=$(bash "$STATE" prepare-review --task "$TASK_I" --repo "$REPO_I" --purpose "$purp" --mode full --slots-json "$TMP/single-rev.json" --owner "owner-2")
  rid=$(printf '%s\n' "$po" | sed -n 's/^RUN_ID=//p')
  dsh=$(printf '%s\n' "$po" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
  sed "s/__DESIGN_SHA__/$dsh/g" "$TMP/tpl-clean-full.json" > "$TMP/inst-i.json"
  bash "$STATE" claim-slot --task "$TASK_I" --run-id "$rid" --slot slot1 --owner "owner-2" --owner-gen 2 --generation 2 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$rid" --generation 2 --owner "owner-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$rid" --child-thread-id "c-$rid" --child-run-id "cr-$rid" >/dev/null
  bash "$STATE" record-result --task "$TASK_I" --run-id "$rid" --generation 2 --owner "owner-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$rid" --child-run-id "cr-$rid" --input "$TMP/inst-i.json" >/dev/null
  bash "$STATE" finish-review-round --task "$TASK_I" --repo "$REPO_I" --merged-input "$TMP/inst-i.json" >/dev/null
done
out=$(bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1)
assert_contains "TASK_I converged after takeover-run" "$out" "PURPOSE=converged"

# I5. Drift & Security Regressions: live prd.md, converged_ledger_sha256, synthesis-body-locked.md, manual_redesign overwrite, JSONL traversal, TriTx traversal, GIT_INDEX_FILE fail-closed!
cp "$TASK_I/prd.md" "$TMP/prd-i.bak"
printf '\nUncommitted PRD change\n' >> "$TASK_I/prd.md"
out=$(bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1)
assert_contains "live uncommitted prd.md edit -> PURPOSE=prd-changed" "$out" "PURPOSE=prd-changed"
out=$(bash "$STATE" commit-phase5 --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "commit-phase5 refuses uncommitted prd.md edit" "$rc" 3
cp "$TMP/prd-i.bak" "$TASK_I/prd.md"

cp "$TASK_I/research/plans/review-ledger.md" "$TMP/led-i.bak"
printf '\nTampered ledger\n' >> "$TASK_I/research/plans/review-ledger.md"
out=$(bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1)
if printf '%s\n' "$out" | grep -Fq "PURPOSE=converged"; then fail "ledger tamper did not break converged!"; else ok "tampered review-ledger.md invalidates converged"; fi
cp "$TMP/led-i.bak" "$TASK_I/research/plans/review-ledger.md"

cp "$TASK_I/research/plans/synthesis-body-locked.md" "$TMP/syn-i.bak"
printf '\nTampered locked synthesis\n' >> "$TASK_I/research/plans/synthesis-body-locked.md"
out=$(bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1)
if printf '%s\n' "$out" | grep -Fq "PURPOSE=converged"; then fail "synthesis-body-locked.md tamper did not break converged!"; else ok "tampered synthesis-body-locked.md invalidates converged"; fi
cp "$TMP/syn-i.bak" "$TASK_I/research/plans/synthesis-body-locked.md"

bash "$STATE" record-user-decision --task "$TASK_I" --repo "$REPO_I" --choice manual_redesign --reason "pause for human" >/dev/null
out=$(bash "$STATE" record-user-decision --task "$TASK_I" --repo "$REPO_I" --choice dispose_and_close_review --reason "trying to bypass manual_redesign" 2>&1); rc=$?
assert_rc "record-user-decision refuses overwriting active manual_redesign" "$rc" 3
bash "$STATE" clear-manual-redesign --task "$TASK_I" --reason "resuming" >/dev/null
# Re-converge after clear-manual-redesign
for purp in "full" "confirmation-full"; do
  po=$(bash "$STATE" prepare-review --task "$TASK_I" --repo "$REPO_I" --purpose "$purp" --mode full --slots-json "$TMP/single-rev.json" --owner "owner-2")
  rid=$(printf '%s\n' "$po" | sed -n 's/^RUN_ID=//p')
  dsh=$(printf '%s\n' "$po" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
  sed "s/__DESIGN_SHA__/$dsh/g" "$TMP/tpl-clean-full.json" > "$TMP/inst-i.json"
  bash "$STATE" claim-slot --task "$TASK_I" --run-id "$rid" --slot slot1 --owner "owner-2" --owner-gen 2 --generation 2 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_I" --run-id "$rid" --generation 2 --owner "owner-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$rid" --child-thread-id "c-$rid" --child-run-id "cr-$rid" >/dev/null
  bash "$STATE" record-result --task "$TASK_I" --run-id "$rid" --generation 2 --owner "owner-2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "t-$rid" --child-run-id "cr-$rid" --input "$TMP/inst-i.json" >/dev/null
  bash "$STATE" finish-review-round --task "$TASK_I" --repo "$REPO_I" --merged-input "$TMP/inst-i.json" >/dev/null
done

# JSONL path traversal rejected
cat > "$TASK_I/implement.md" <<'EOF'
# Implement Plan
- Implement I-99 with guard test `test_zh_sql`.
EOF
cat > "$TASK_I/implement.jsonl" <<'EOF'
{"file": "../../../../../../etc/hosts", "reason": "escape attempt"}
EOF
cat > "$TASK_I/check.jsonl" <<'EOF'
{"file": ".trellis/spec/core.md", "reason": "ok"}
EOF
out=$(bash "$STATE" commit-phase5 --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "Phase 5 rejects path-traversal entry in implement.jsonl" "$rc" 3

# Corrupt GIT_INDEX_FILE fails closed (non-zero)
printf 'corrupt-index' > "$TMP/bad-git-index"
out=$(GIT_INDEX_FILE="$TMP/bad-git-index" bash "$STATE" next-review --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "corrupt GIT_INDEX_FILE fails closed (rc=$rc)" || fail "corrupt GIT_INDEX_FILE returned 0!"

# Tampered .pending.tx.json with ../escape rejected fail-closed!
cat > "$TASK_I/research/plans/.pending.tx.json" <<'EOF'
{
  "tx_id": "tx-evil",
  "expected_generation": 2,
  "next_generation": 2,
  "commit_marker": true,
  "ops": [
    { "type": "write_file", "dst": "../escape.txt", "staged_rel": "s0", "expected_pre_kind": "absent", "expected_pre_sha256": null, "post_sha256": "0000000000000000000000000000000000000000000000000000000000000000" }
  ]
}
EOF
out=$(bash "$STATE" inspect-task --task "$TASK_I" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "TriTx rejects path-traversal in .pending.tx.json" || fail "TriTx allowed ../ in .pending.tx.json!"
rm -f "$TASK_I/research/plans/.pending.tx.json"

# Fix implement.jsonl -> commit Phase 5 & Phase 6 ready!
cat > "$TASK_I/implement.jsonl" <<'EOF'
{"file": ".trellis/spec/core.md", "reason": "ok"}
EOF
bash "$STATE" commit-phase5 --task "$TASK_I" --repo "$REPO_I" >/dev/null
bash "$STATE" commit-phase6-ready --task "$TASK_I" --repo "$REPO_I" --authorization "impl" >/dev/null

# I6. Phase 6 hardening: (a) SIGKILLed task.py -> rc=137 -> activation_uncertain (NOT exit 0!);
#     (b) _probe_trellis_current failure -> fail-closed;
#     (c) Surviving child task.py holds .activation.lock even AFTER parent Perl wrapper is SIGKILLed!
export TRELLIS_CONTEXT_ID="ctx-hardening"
out=$(MOCK_START_MODE=sigkill_self bash "$STATE" activate-task --task "$TASK_I" --repo "$REPO_I" --owner "owner-2" --authorization "impl" 2>&1); rc=$?
assert_rc "SIGKILLed task.py enters activation_uncertain (NOT exit 0!)" "$rc" 3
assert_contains "signal exit code 137 reported" "$out" "exited 137"

# Broken task.py current --json -> resolve-activation reset_to_ready fails closed (exit 3)!
cat > "$TASK_I/task.json" <<'EOF'
{ "id": "01-hardening", "title": "Hardening", "status": "planning" }
EOF
rm -rf "$REPO_I/.trellis/.mock-ptrs"
out=$(MOCK_CURRENT_MODE=broken bash "$STATE" resolve-activation --task "$TASK_I" --repo "$REPO_I" --resolution reset_to_ready --evidence "test" 2>&1); rc=$?
assert_rc "resolve-activation reset_to_ready fails closed when current --json fails" "$rc" 3

# Reset cleanly, then test child lock inheritance across parent SIGKILL!
bash "$STATE" resolve-activation --task "$TASK_I" --repo "$REPO_I" --resolution reset_to_ready --evidence "clean reset" >/dev/null
MOCK_PID_FILE="$TMP/child-taskpy.pid"
rm -f "$MOCK_PID_FILE"
MOCK_START_MODE=sleep_long MOCK_START_SLEEP=3 MOCK_START_PID_FILE="$MOCK_PID_FILE" \
  perl "$HERE/t3-tri-plan-state.pl" activate-task --task "$TASK_I" --repo "$REPO_I" --owner "owner-2" --authorization "impl" >"$TMP/act-kill.out" 2>&1 &
PERL_WRAP_PID=$!
# Wait up to 3s for python3 task.py child to start and write its PID
for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -s "$MOCK_PID_FILE" ] && break
  sleep 0.1
done
CHILD_PY_PID=$(cat "$MOCK_PID_FILE" 2>/dev/null || true)
[ -n "$CHILD_PY_PID" ] && ok "mock task.py child spawned (pid=$CHILD_PY_PID)" || fail "mock task.py child never wrote pid"
# Kill ONLY the parent Perl wrapper with SIGKILL!
kill -9 "$PERL_WRAP_PID" 2>/dev/null || true
wait "$PERL_WRAP_PID" 2>/dev/null || true
sleep 0.2

# While child task.py is still alive, .activation.lock MUST remain held (recover-activation, commit-phase5, commit-phase0 material ALL exit 5)!
out=$(bash "$STATE" recover-activation --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "recover-activation blocked (exit 5) while orphaned task.py still holds inherited .activation.lock" "$rc" 5
assert_contains "ACTIVATION_IN_PROGRESS=1 after parent SIGKILL" "$out" "ACTIVATION_IN_PROGRESS=1"

out=$(bash "$STATE" commit-phase5 --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "commit-phase5 blocked (exit 5) while .activation.lock held" "$rc" 5

printf '\nMaterial PRD while activating\n' >> "$TASK_I/prd.md"
out=$(bash "$STATE" commit-phase0 --task "$TASK_I" --repo "$REPO_I" --change-kind material --reason "race" 2>&1); rc=$?
assert_rc "commit-phase0 --change-kind material blocked (exit 5) while .activation.lock held" "$rc" 5
cp "$TMP/prd-i.bak" "$TASK_I/prd.md"

# Wait for child task.py to exit -> lock releases -> broken probe fails closed -> healthy probe recovers!
while kill -0 "$CHILD_PY_PID" 2>/dev/null; do sleep 0.2; done
out=$(MOCK_CURRENT_MODE=broken bash "$STATE" recover-activation --task "$TASK_I" --repo "$REPO_I" 2>&1); rc=$?
assert_rc "recover-activation fails closed (activation_uncertain) when pointer probe fails" "$rc" 3
assert_contains "RECOVERY_CASE=probe_failed" "$out" "RECOVERY_CASE=probe_failed"

# =============================================================================
printf '\n=== Group J: Round 2 Hardening Regressions (All 19 Consolidated Findings) ===\n'
# =============================================================================

# J1. config-show with empty --capabilities (0 models) MUST fail closed (exit 3, CONFIG_VALID=0)!
CAPS_EMPTY="$TMP/caps-empty-tri.json"
printf '{"providers":[]}\n' > "$CAPS_EMPTY"
out=$(bash "$STATE" config-show --repo "$REPO_I" --capabilities "$CAPS_EMPTY" 2>&1); rc=$?
assert_rc "empty capabilities JSON fails closed (exit 3)" "$rc" 3
assert_contains "CONFIG_VALID=0 on empty capabilities" "$out" "CONFIG_VALID=0"

# J2. config-set rejects unified effortMode with empty effortKey member!
cat > "$TMP/cfg-tri-unif-emptykey.json" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "codex"],
  "designers": {
    "effortMode": "unified",
    "unifiedEffort": "high",
    "members": [
      { "providerInstanceId": "antigravity", "model": "no-effort", "effortKey": "", "effort": "" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "" }
    ]
  },
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "reviewCouncil": {
    "effortMode": "per-model",
    "members": [
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" }
    ]
  }
}
EOF
out=$(bash "$STATE" config-set --file "$TMP/cfg-tri-unif-emptykey.json" 2>&1); rc=$?
assert_rc "config-set rejects unified group with empty effortKey member" "$rc" 3

# J3. Fresh repo with non-ASCII Git path (中文/REVIEW.md), project knobs, --ignore-project-config persistence,
#     Latin-1 \u00a7/\u00e9 judge output, Phase 2a default-path SHA check, Phase 2b no-overwrite of Phase 4,
#     single/council blocking finding traceability, Chinese codification, UTF-8 CLI args, Phase 5 idempotency,
#     Phase 6 activation lock blocking takeover-run, _probe_trellis_current exit 7/2, and TriTx::_git SIGTERM!
REPO_J="$TMP/repo-j"
make_repo "$REPO_J"
mkdir -p "$REPO_J/中文"
cat > "$REPO_J/中文/REVIEW.md" <<'EOF'
# 中文审查规则

## 禁止裸写SQL
严禁拼接原始 SQL。
EOF
git -C "$REPO_J" add -A && git -C "$REPO_J" commit -q -m "add non-ascii REVIEW.md"

cat > "$REPO_J/.t3-tri-plan.json" <<'EOF'
{
  "version": 1,
  "knobs": { "roundCap": 1, "maxStepBacks": 0 }
}
EOF

TASK_J="$REPO_J/.trellis/tasks/01-r2"
mkdir -p "$TASK_J"
printf '# PRD R2\nSupport Chinese codification & full hardening.\n' > "$TASK_J/prd.md"
cat > "$TASK_J/task.json" <<'EOF'
{ "id": "01-r2", "title": "R2 Hardening", "status": "planning" }
EOF

# Persist --ignore-project-config in Phase 0 so commit-phase1 and next-review ignore project roundCap=1!
out=$(bash "$STATE" commit-phase0 --task "$TASK_J" --repo "$REPO_J" --ignore-project-config 2>&1); rc=$?
assert_rc "commit-phase0 --ignore-project-config succeeds" "$rc" 0
assert_contains "PROJECT_CONFIG_IGNORED=1 persisted" "$out" "PROJECT_CONFIG_IGNORED=1"

# Phase 1 -> commit-phase1
p1j=$(bash "$STATE" prepare-design --task "$TASK_J" --repo "$REPO_J" --slots-json "$TMP/designers.json" --owner "owner-j1")
P1J_RUN=$(printf '%s\n' "$p1j" | sed -n 's/^RUN_ID=//p')
for pair in "candidate-a:$TMP/cand-zh.md" "candidate-b:$TMP/cand-b.md" "candidate-c:$TMP/cand-c.md"; do
  sl="${pair%%:*}"; cf="${pair#*:}"
  bash "$STATE" claim-slot --task "$TASK_J" --run-id "$P1J_RUN" --slot "$sl" --owner "owner-j1" --owner-gen 1 --generation 1 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$P1J_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot "$sl" --attempt 1 --task-id "tj-$sl" --child-thread-id "ctj-$sl" --child-run-id "crj-$sl" >/dev/null
  bash "$STATE" record-result --task "$TASK_J" --run-id "$P1J_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot "$sl" --attempt 1 --task-id "tj-$sl" --child-run-id "crj-$sl" --input "$cf" >/dev/null
done
bash "$STATE" commit-phase1 --task "$TASK_J" --repo "$REPO_J" >/dev/null

# Phase 2a: Latin-1 \u00a7/\u00e9 escape in synthesis/design + default-path tampered result_sha256 rejection!
pjj=$(bash "$STATE" prepare-judge --task "$TASK_J" --repo "$REPO_J" --target-json "$TMP/judge-target.json" --owner "owner-j1")
PJJ_RUN=$(printf '%s\n' "$pjj" | sed -n 's/^RUN_ID=//p')
JSHA_A=$(shasum -a 256 "$TASK_J/research/plans/candidates/candidate-a.md" | awk '{print $1}')
JSHA_B=$(shasum -a 256 "$TASK_J/research/plans/candidates/candidate-b.md" | awk '{print $1}')
JSHA_C=$(shasum -a 256 "$TASK_J/research/plans/candidates/candidate-c.md" | awk '{print $1}')
cat > "$TMP/be-latin1.json" <<EOF
{
  "candidate_set": [
    { "slot": "candidate-a", "sha256": "$JSHA_A" },
    { "slot": "candidate-b", "sha256": "$JSHA_B" },
    { "slot": "candidate-c", "sha256": "$JSHA_C" }
  ],
  "fact_checks": [
    { "id": "F1", "candidate_slot": "candidate-c", "claim": "src/app.py:1 ok", "status": "CONFIRMED", "file_line_evidence": "src/app.py:1" }
  ],
  "axis_matrix": {
    "architecture_fit": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "ssot_invariants": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "hidden_callers": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "migration_compat": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "real_entrypoint_tests": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "abstraction_restraint": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "prd_scope_fidelity": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "rollback_viability": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "unique_risks": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "key_assumptions": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "dependency_order": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "failure_recovery_acceptance": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}}
  },
  "primary_winner": "candidate-a",
  "winner_rationale": "Cleanest invariants.",
  "eliminated": [
    { "slot": "candidate-b", "rationale": "Extra layer." },
    { "slot": "candidate-c", "rationale": "Missing rollback." }
  ],
  "cherry_picks": [
    { "source_slot": "candidate-c", "gap_description": "Check", "evidence_fact_check_id": "F1", "evidence_quote": "src/app.py:1", "compatible_with_winner_architecture": true }
  ],
  "rejected_ideas": [],
  "product_forks": [],
  "product_decisions": [],
  "synthesis_body_markdown": "# Synthesis \\u00a71 R\\u00e9sum\\u00e9\\nWinner: candidate-a.",
  "initial_design_markdown": "# Design \\u00a71 R\\u00e9sum\\u00e9\\nBackbone: candidate-a.\\n"
}
EOF
bash "$STATE" claim-slot --task "$TASK_J" --run-id "$PJJ_RUN" --slot judge --owner "owner-j1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$PJJ_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot judge --attempt 1 --task-id "tjj-1" --child-thread-id "ctjj-1" --child-run-id "crjj-1" >/dev/null
rr_j=$(bash "$STATE" record-result --task "$TASK_J" --run-id "$PJJ_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot judge --attempt 1 --task-id "tjj-1" --child-run-id "crjj-1" --input "$TMP/be-latin1.json")
J_RES_FILE=$(printf '%s\n' "$rr_j" | sed -n 's/^RESULT_FILE=//p')
cp "$J_RES_FILE" "$TMP/j-res.bak"
# Tamper recorded judge slot file on disk and invoke commit-phase2a WITHOUT --input!
python3 -c '
import json
p = "'"$J_RES_FILE"'"
d = json.load(open(p))
d["winner_rationale"] = "TAMPERED ON DISK"
json.dump(d, open(p, "w"))
'
out=$(bash "$STATE" commit-phase2a --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "commit-phase2a default path (no --input) catches tampered result_sha256" "$rc" 3
assert_contains "tampered digest message" "$out" "digest mismatch"
cp "$TMP/j-res.bak" "$J_RES_FILE"

out=$(bash "$STATE" commit-phase2a --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "commit-phase2a locks valid Latin-1 escaped judge payload" "$rc" 0
# Verify Latin-1 \u00a7 and \u00e9 were properly UTF-8 encoded (valid UTF-8 file)!
python3 -c '
t = open("'"$TASK_J/research/plans/initial-design.md"'", "r", encoding="utf-8").read()
assert "\u00a71 R\u00e9sum\u00e9" in t, f"bad utf8 text: {t!r}"
' && ok "Latin-1 U+0080..U+00FF JSON strings encoded as valid UTF-8 (no utf8::is_utf8 skip)" || fail "Latin-1 UTF-8 encoding failed!"

bash "$STATE" commit-phase2b --task "$TASK_J" --repo "$REPO_J" --assemble >/dev/null
# Write-free idempotent retry BEFORE any Phase 4 revision succeeds!
out=$(bash "$STATE" commit-phase2b --task "$TASK_J" --repo "$REPO_J" --assemble 2>&1); rc=$?
assert_rc "commit-phase2b immediate retry is idempotent" "$rc" 0
assert_contains "PHASE2B_IDEMPOTENT=1" "$out" "PHASE2B_IDEMPOTENT=1"

# Phase 3 Round 1: non-ASCII Git path 中文/REVIEW.md#禁止裸写sql in rules_index + single-reviewer BLOCKER cannot settle clean!
pr_j1=$(bash "$STATE" prepare-review --task "$TASK_J" --repo "$REPO_J" --purpose initial-full --mode full --slots-json "$TMP/single-rev.json" --owner "owner-j1")
PRJ1_RUN=$(printf '%s\n' "$pr_j1" | sed -n 's/^RUN_ID=//p')
PRJ1_DSHA=$(printf '%s\n' "$pr_j1" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
PRJ1_LM=$(printf '%s\n' "$pr_j1" | sed -n 's/^LEDGER_MANIFEST=//p')
python3 -c '
import json
lm = json.load(open("'"$PRJ1_LM"'", "r", encoding="utf-8"))
rf = lm["rule_files"]
ri = lm["rules_index"]
assert "中文/REVIEW.md" in rf, f"missing non-ascii rule_files: {rf}"
assert "中文/REVIEW.md#禁止裸写sql" in ri, f"missing non-ascii rules_index: {ri}"
' && ok "non-ASCII Git path 中文/REVIEW.md decoded cleanly in rules_index (zero mojibake)" || fail "non-ASCII Git path mojibaked in rules_index!"

cat > "$TMP/rev-j1-blocker.json" <<EOF
{
  "summary": "命中中文路径规则", "mode": "full", "reviewed_design_sha256": "$PRJ1_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "中文规则冲突", "location": "design.md:1",
    "pattern": "裸写 SQL", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "使用参数化", "prevent": "并发锁测试", "evidence": "src/app.py:1",
    "violates_review_md_rule": "中文/REVIEW.md#禁止裸写sql"
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-j1-clean-fake.json" <<EOF
{
  "summary": "Fake clean", "mode": "full", "reviewed_design_sha256": "$PRJ1_DSHA", "verdict": "clean",
  "findings": [], "verified": [], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_J" --run-id "$PRJ1_RUN" --slot slot1 --owner "owner-j1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$PRJ1_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tj-r1" --child-thread-id "ctj-r1" --child-run-id "crj-r1" >/dev/null
out=$(bash "$STATE" record-result --task "$TASK_J" --run-id "$PRJ1_RUN" --generation 1 --owner "owner-j1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tj-r1" --child-run-id "crj-r1" --input "$TMP/rev-j1-blocker.json" 2>&1); rc=$?
assert_rc "non-ASCII path 中文/REVIEW.md#禁止裸写sql accepted by parse-design-review" "$rc" 0

# Attempting to settle single-reviewer BLOCKER as clean MUST fail closed!
out=$(bash "$STATE" finish-review-round --task "$TASK_J" --repo "$REPO_J" --merged-input "$TMP/rev-j1-clean-fake.json" 2>&1); rc=$?
assert_rc "single-reviewer BLOCKER cannot be settled as clean (exit 3)" "$rc" 3
assert_contains "divergence error reported" "$out" "diverges from recorded canonical slot result"

# Auto-consuming single slot without --merged-input succeeds and records dirty!
out=$(bash "$STATE" finish-review-round --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "finish-review-round auto-consumes single valid slot -> dirty" "$rc" 0
assert_contains "VERDICT=dirty" "$out" "VERDICT=dirty"

# Phase 4: whitespace-only codified MUST fail; Chinese codified MUST pass!
cat > "$TMP/disp-j-blank.json" <<'EOF'
[{ "id": "D1", "disposition": "adopted", "note": "x", "codified": { "invariant_id": "   ", "guard_test": " " } }]
EOF
out=$(bash "$STATE" commit-phase4-revision --task "$TASK_J" --repo "$REPO_J" --dispositions-json "$TMP/disp-j-blank.json" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "commit-phase4-revision rejects whitespace-only codified.{invariant_id,guard_test}" || fail "accepted whitespace codified!"

printf '\n## 不变量-1\n确保不变量-1 与 回归测试-并发锁 落地。\n' >> "$TASK_J/design.md"
cat > "$TMP/disp-j-zh.json" <<'EOF'
[{ "id": "D1", "disposition": "adopted", "note": "已固化", "codified": { "invariant_id": "不变量-1", "guard_test": "回归测试-并发锁", "review_md_entry": "中文/REVIEW.md#禁止裸写sql" } }]
EOF
out=$(bash "$STATE" commit-phase4-revision --task "$TASK_J" --repo "$REPO_J" --dispositions-json "$TMP/disp-j-zh.json" 2>&1); rc=$?
assert_rc "Phase 4 Chinese codified recorded cleanly" "$rc" 0

# Re-running commit-phase2b --assemble AFTER Phase 4 revision MUST fail closed (never overwrite design.md or clear design_revisions[])!
DES_SHA_P4=$(shasum -a 256 "$TASK_J/design.md" | awk '{print $1}')
out=$(bash "$STATE" commit-phase2b --task "$TASK_J" --repo "$REPO_J" --assemble 2>&1); rc=$?
assert_rc "commit-phase2b refuses overwriting Phase 4 design_revisions[] (exit 3)" "$rc" 3
assert_eq "design.md untouched after refused Phase 2b re-run" "$(shasum -a 256 "$TASK_J/design.md" | awk '{print $1}')" "$DES_SHA_P4"

# Persisted --ignore-project-config ignores project roundCap=1,maxStepBacks=0 -> next-review does NOT stop after 1 dirty round!
out=$(bash "$STATE" next-review --task "$TASK_J" --repo "$REPO_J" 2>&1)
if printf '%s\n' "$out" | grep -Fq "PURPOSE=stop"; then
  fail "persisted --ignore-project-config was ignored by next-review (stopped at project roundCap=1)!"
else
  ok "persisted --ignore-project-config propagates to next-review (ignores project roundCap=1)"
fi

# UTF-8 CLI arg decoding: takeover-run --reason "中文接管原因" writes real UTF-8 (ZERO double-encoding)!
out=$(bash "$STATE" takeover-run --task "$TASK_J" --new-owner "owner-j2" --reason "中文接管原因" 2>&1); rc=$?
assert_rc "takeover-run with Chinese --reason succeeds" "$rc" 0
python3 -c '
import json
st = json.load(open("'"$TASK_J/research/plans/planning-state.json"'", "r", encoding="utf-8"))
got = st["last_takeover"]["reason"]
assert got == "中文接管原因", f"double-encoded or corrupted reason: {got!r}"
' && ok "CLI UTF-8 --reason stored verbatim without double-encoding" || fail "CLI UTF-8 --reason was double-encoded!"

# manual_redesign MUST NOT be silently cleared by prepare-design or commit-phase1!
bash "$STATE" record-user-decision --task "$TASK_J" --repo "$REPO_J" --choice manual_redesign --reason "人工接管" >/dev/null
out=$(bash "$STATE" prepare-design --task "$TASK_J" --repo "$REPO_J" --slots-json "$TMP/designers.json" --owner "owner-j2" 2>&1); rc=$?
assert_rc "prepare-design blocked while manual_redesign is active (exit 3)" "$rc" 3
bash "$STATE" clear-manual-redesign --task "$TASK_J" --reason "恢复" >/dev/null

# Council 2-reviewer traceability check + convergence!
cat > "$TMP/two-rev.json" <<'EOF'
[
  { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "high" }
]
EOF
pr_jc=$(bash "$STATE" prepare-review --task "$TASK_J" --repo "$REPO_J" --purpose full --mode full --slots-json "$TMP/two-rev.json" --owner "owner-j2")
PRJC_RUN=$(printf '%s\n' "$pr_jc" | sed -n 's/^RUN_ID=//p')
PRJC_DSHA=$(printf '%s\n' "$pr_jc" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
cat > "$TMP/rev-jc-blk.json" <<EOF
{
  "summary": "Blocker", "mode": "full", "reviewed_design_sha256": "$PRJC_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "Council blocker", "location": "design.md:1",
    "pattern": "p", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "f", "prevent": "t", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-jc-clean.json" <<EOF
{
  "summary": "Clean", "mode": "full", "reviewed_design_sha256": "$PRJC_DSHA", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "ok" }], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_J" --run-id "$PRJC_RUN" --slot slot1 --owner "owner-j2" --owner-gen 2 --generation 2 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$PRJC_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "tjc-1" --child-thread-id "ctjc-1" --child-run-id "crjc-1" >/dev/null
bash "$STATE" record-result --task "$TASK_J" --run-id "$PRJC_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "tjc-1" --child-run-id "crjc-1" --input "$TMP/rev-jc-blk.json" >/dev/null
bash "$STATE" claim-slot --task "$TASK_J" --run-id "$PRJC_RUN" --slot slot2 --owner "owner-j2" --owner-gen 2 --generation 2 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$PRJC_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot2 --attempt 1 --task-id "tjc-2" --child-thread-id "ctjc-2" --child-run-id "crjc-2" >/dev/null
bash "$STATE" record-result --task "$TASK_J" --run-id "$PRJC_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot2 --attempt 1 --task-id "tjc-2" --child-run-id "crjc-2" --input "$TMP/rev-jc-clean.json" >/dev/null
out=$(bash "$STATE" finish-review-round --task "$TASK_J" --repo "$REPO_J" --merged-input "$TMP/rev-jc-clean.json" 2>&1); rc=$?
assert_rc "council finish-review-round rejects dropping BLOCKER without --dismissed-findings" "$rc" 3
cat > "$TMP/dism-jc.json" <<'EOF'
[{ "slot": "slot1", "title": "Council blocker", "severity": "BLOCKER", "code_evidence": "src/app.py:1 verified safe" }]
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_J" --repo "$REPO_J" --merged-input "$TMP/rev-jc-clean.json" --dismissed-findings "$TMP/dism-jc.json" 2>&1); rc=$?
assert_rc "council finish-review-round accepts evidenced --dismissed-findings (clean round 1)" "$rc" 0

# Confirmation full clean round 2 -> converged!
pr_jc2=$(bash "$STATE" prepare-review --task "$TASK_J" --repo "$REPO_J" --purpose confirmation-full --mode full --slots-json "$TMP/single-rev.json" --owner "owner-j2")
PRJC2_RUN=$(printf '%s\n' "$pr_jc2" | sed -n 's/^RUN_ID=//p')
bash "$STATE" claim-slot --task "$TASK_J" --run-id "$PRJC2_RUN" --slot slot1 --owner "owner-j2" --owner-gen 2 --generation 2 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_J" --run-id "$PRJC2_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "tjc2-1" --child-thread-id "ctjc2-1" --child-run-id "crjc2-1" >/dev/null
bash "$STATE" record-result --task "$TASK_J" --run-id "$PRJC2_RUN" --generation 2 --owner "owner-j2" --owner-gen 2 --slot slot1 --attempt 1 --task-id "tjc2-1" --child-run-id "crjc2-1" --input "$TMP/rev-jc-clean.json" >/dev/null
out=$(bash "$STATE" finish-review-round --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "confirmation full round converges cleanly" "$rc" 0
assert_contains "CONVERGED=1" "$out" "CONVERGED=1"

# Phase 5 with Chinese invariant_id / guard_test / review_md_entry MUST PASS!
cat > "$TASK_J/implement.md" <<'EOF'
# 实施计划
- 实现 不变量-1，补充 回归测试-并发锁，并在实施 PR 中更新 中文/REVIEW.md#禁止裸写sql。
EOF
cat > "$TASK_J/implement.jsonl" <<'EOF'
{"file": "中文/REVIEW.md", "reason": "Chinese path JSONL verification"}
EOF
cat > "$TASK_J/check.jsonl" <<'EOF'
{"file": ".trellis/spec/core.md", "reason": "Check spec"}
EOF
out=$(bash "$STATE" commit-phase5 --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "Phase 5 passes Chinese codified invariant/guard_test/review_md_entry & non-ASCII JSONL path" "$rc" 0

# Phase 6 ready + activate-task with concurrent takeover-run blocked by .activation.lock!
bash "$STATE" commit-phase6-ready --task "$TASK_J" --repo "$REPO_J" --authorization "impl" >/dev/null
export TRELLIS_CONTEXT_ID="ctx-r2"
MOCK_PID_J="$TMP/j-taskpy.pid"
rm -f "$MOCK_PID_J"
MOCK_START_MODE=sleep_long MOCK_START_SLEEP=1.5 MOCK_START_PID_FILE="$MOCK_PID_J" \
  bash "$STATE" activate-task --task "$TASK_J" --repo "$REPO_J" --owner "owner-j2" --authorization "impl" >"$TMP/act-j.out" 2>&1 &
ACT_J_PID=$!
for _w in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  [ -s "$MOCK_PID_J" ] && break
  sleep 0.1
done
# While task.py start is running, takeover-run AND other write entrypoints MUST be blocked (exit 5) and NEVER bump generation!
out_tk=$(bash "$STATE" takeover-run --task "$TASK_J" --new-owner "owner-j3" --reason "concurrent takeover" 2>&1); rc_tk=$?
assert_rc "takeover-run blocked (exit 5) while Phase 6 holds .activation.lock" "$rc_tk" 5
assert_contains "ACTIVATION_IN_PROGRESS=1 on takeover-run" "$out_tk" "ACTIVATION_IN_PROGRESS=1"
out_p4r=$(bash "$STATE" commit-phase4-revision --task "$TASK_J" --repo "$REPO_J" 2>&1); rc_p4r=$?
assert_rc "commit-phase4-revision blocked (exit 5) while Phase 6 holds .activation.lock" "$rc_p4r" 5
wait "$ACT_J_PID"; rc_aj=$?
assert_rc "activate-task finishes cleanly without generation mismatch" "$rc_aj" 0
assert_contains "ACTIVATED=1" "$(cat "$TMP/act-j.out")" "ACTIVATED=1"

# Re-running commit-phase5 with identical inputs MUST be idempotent and PRESERVE activated state (preventing duplicate after_start)!
out_p5i=$(bash "$STATE" commit-phase5 --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "re-running commit-phase5 with identical inputs is idempotent (exit 0)" "$rc" 0
assert_contains "PHASE5_IDEMPOTENT=1" "$out_p5i" "PHASE5_IDEMPOTENT=1"
assert_contains "PHASE6_STATE=activated preserved" "$out_p5i" "PHASE6_STATE=activated"
out_p6d=$(bash "$STATE" commit-phase6-ready --task "$TASK_J" --repo "$REPO_J" --authorization "impl" 2>&1); rc=$?
assert_rc "commit-phase6-ready still refuses downgrading preserved activated state" "$rc" 3
# Editing implement.md while task.json.status is STILL in_progress MUST ALSO refuse wiping activated!
cp "$TASK_J/implement.md" "$TMP/imp-j.bak"
printf '\n- Extra edit while already in_progress\n' >> "$TASK_J/implement.md"
out_p5w=$(bash "$STATE" commit-phase5 --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "commit-phase5 refuses wiping activated while task.json.status is in_progress" "$rc" 3
cp "$TMP/imp-j.bak" "$TASK_J/implement.md"

# _probe_trellis_current exit-code & key checks: exit 7 + {"current_task":null} AND exit 2 + {"error":...} MUST fail closed!
# Set up an activation_uncertain state cleanly (task.json back to planning + new implement.md + crash_after_ptr)
cat > "$TASK_J/task.json" <<'EOF'
{ "id": "01-r2", "title": "R2 Hardening", "status": "planning" }
EOF
rm -rf "$REPO_J/.trellis/.mock-ptrs"
printf '\n- Re-arm for probe exit-code test\n' >> "$TASK_J/implement.md"
bash "$STATE" commit-phase5 --task "$TASK_J" --repo "$REPO_J" >/dev/null
bash "$STATE" commit-phase6-ready --task "$TASK_J" --repo "$REPO_J" --authorization "impl" >/dev/null
MOCK_START_MODE=crash_after_ptr T3_TRI_PLAN_TEST_CRASH_AFTER_START=1 bash "$STATE" activate-task --task "$TASK_J" --repo "$REPO_J" --owner "owner-j2" --authorization "impl" >/dev/null 2>&1
# While state is 'activating' (lock released after simulated crash), takeover-run MUST STILL fail closed (exit 3)!
out_tka=$(bash "$STATE" takeover-run --task "$TASK_J" --new-owner "owner-j3" --reason "during activating" 2>&1); rc=$?
assert_rc "takeover-run blocked (exit 3) while Phase 6 is activating" "$rc" 3
# Probe exit 2 with {"error":...} -> recover-activation MUST fail closed as probe_failed (NOT unstarted)!
rm -rf "$REPO_J/.trellis/.mock-ptrs"
out=$(MOCK_CURRENT_MODE=exit2_error bash "$STATE" recover-activation --task "$TASK_J" --repo "$REPO_J" 2>&1); rc=$?
assert_rc "recover-activation fails closed on exit 2 JSON error object" "$rc" 3
assert_contains "RECOVERY_CASE=probe_failed on exit2_error" "$out" "RECOVERY_CASE=probe_failed"
# Probe exit 7 with {"current_task":null} -> resolve-activation reset_to_ready MUST fail closed (exit 3)!
out=$(MOCK_CURRENT_MODE=exit7_null bash "$STATE" resolve-activation --task "$TASK_J" --repo "$REPO_J" --resolution reset_to_ready --evidence "probe test" 2>&1); rc=$?
assert_rc "resolve-activation reset_to_ready rejects exit 7 even with valid null JSON" "$rc" 3
# Probe exit 0 with missing current_task key -> ALSO fails closed!
out=$(MOCK_CURRENT_MODE=exit0_missing_key bash "$STATE" resolve-activation --task "$TASK_J" --repo "$REPO_J" --resolution reset_to_ready --evidence "probe test" 2>&1); rc=$?
assert_rc "resolve-activation reset_to_ready rejects JSON missing current_task key" "$rc" 3
# And while activation_uncertain, takeover-run MUST still be blocked (exit 3)!
out=$(bash "$STATE" takeover-run --task "$TASK_J" --new-owner "owner-j3" --reason "during uncertain" 2>&1); rc=$?
assert_rc "takeover-run blocked (exit 3) while Phase 6 is activation_uncertain" "$rc" 3

# J4. TriTx::_git fails closed on SIGTERM (does NOT treat $? >> 8 == 0 as success)!
SHIM_BIN="$TMP/git-sigterm-bin"
mkdir -p "$SHIM_BIN"
REAL_GIT=$(command -v git)
cat > "$SHIM_BIN/git" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "diff-index" ]; then
    kill -TERM \$\$
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM_BIN/git"
out=$(PATH="$SHIM_BIN:$PATH" perl -I"$HERE/lib" -MTriTx=compute_worktree_fp -e 'compute_worktree_fp($ARGV[0], "")' "$REPO_J" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "TriTx::_git SIGTERM fails closed with rc=143" "$out" "rc=143" || fail "TriTx::_git treated SIGTERM as rc=0!"

# =============================================================================
printf '\n=== Group K: Round 3 Hardening Regressions ===\n'
# =============================================================================

# K1. activation_uncertain: exit 0 with {"current_task":null,"error":...} AND commit-phase0 --change-kind material MUST both fail closed!
out=$(MOCK_CURRENT_MODE=exit0_null_error bash "$STATE" resolve-activation --task "$TASK_J" --repo "$REPO_J" --resolution reset_to_ready --evidence "error probe test" 2>&1); rc=$?
assert_rc "resolve-activation reset_to_ready rejects exit 0 JSON with current_task:null + error key" "$rc" 3
cp "$TASK_J/prd.md" "$TMP/prd-j.bak"
printf '\n- Material change attempted while activation_uncertain\n' >> "$TASK_J/prd.md"
out=$(bash "$STATE" commit-phase0 --task "$TASK_J" --repo "$REPO_J" --change-kind material --reason "try bypassing activation_uncertain" 2>&1); rc=$?
assert_rc "commit-phase0 --change-kind material blocked while Phase 6 is activation_uncertain (exit 3)" "$rc" 3
out_insp=$(bash "$STATE" inspect-task --task "$TASK_J" 2>&1)
assert_contains "Phase 6 remains activation_uncertain after refused material PRD change" "$out_insp" "PHASE6_STATE=activation_uncertain"
cp "$TMP/prd-j.bak" "$TASK_J/prd.md"

# K2. FIFO at .activation.lock or .tri-plan.lock MUST fail immediately (EXTERNAL_CONFLICT, NEVER hang)!
REPO_FIFO="$TMP/repo-fifo"
make_repo "$REPO_FIFO"
TASK_FIFO="$REPO_FIFO/.trellis/tasks/01-fifo"
mkdir -p "$TASK_FIFO/research/plans"
printf '# PRD\n' > "$TASK_FIFO/prd.md"
mkfifo "$TASK_FIFO/research/plans/.activation.lock"
out=$(bash "$STATE" commit-phase0 --task "$TASK_FIFO" --repo "$REPO_FIFO" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "FIFO at .activation.lock fails fast with EXTERNAL_CONFLICT" "$out" "EXTERNAL_CONFLICT" || fail "FIFO at .activation.lock did not fail!"
rm -f "$TASK_FIFO/research/plans/.activation.lock" "$TASK_FIFO/research/plans/.tri-plan.lock"
mkfifo "$TASK_FIFO/research/plans/.tri-plan.lock"
out=$(bash "$STATE" commit-phase0 --task "$TASK_FIFO" --repo "$REPO_FIFO" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "FIFO at .tri-plan.lock fails fast with EXTERNAL_CONFLICT" "$out" "EXTERNAL_CONFLICT" || fail "FIFO at .tri-plan.lock did not fail!"
rm -f "$TASK_FIFO/research/plans/.tri-plan.lock"

# K3. Chinese task directory (.trellis/tasks/01-中文) works end-to-end with ZERO EXTERNAL_CONFLICT and ZERO double-encoded STDOUT paths!
REPO_K="$TMP/repo-k"
make_repo "$REPO_K"
mkdir -p "$REPO_K/src"
printf 'print(1)\n' > "$REPO_K/src/app.py"
printf 'numeric file test\n' > "$REPO_K/709"
cat > "$REPO_K/.t3-tri-plan.json" <<'EOF'
{
  "version": 1,
  "knobs": { "roundCap": 1, "maxStepBacks": 0 }
}
EOF
git -C "$REPO_K" add -A && git -C "$REPO_K" commit -q -m "add app, numeric file, and project roundCap=1"

TASK_K="$REPO_K/.trellis/tasks/01-中文"
mkdir -p "$TASK_K"
printf '# 中文 PRD\n- 核心目标\n' > "$TASK_K/prd.md"
cat > "$TASK_K/task.json" <<'EOF'
{ "id": "01-中文", "title": "中文任务", "status": "planning" }
EOF

out_ik=$(bash "$STATE" inspect-task --task "$TASK_K" 2>&1); rc=$?
assert_rc "inspect-task on Chinese task dir 01-中文 succeeds" "$rc" 0
TDIR_OUT=$(printf '%s\n' "$out_ik" | sed -n 's/^TASK_DIR=//p')
[ -d "$TDIR_OUT" ] && ok "inspect-task TASK_DIR prints exact valid UTF-8 path (no mojibake): $TDIR_OUT" || fail "inspect-task TASK_DIR mojibaked: $TDIR_OUT"

# Initialize WITH project config active (roundCap=1, maxStepBacks=0) AND Chinese --authorization
# so planning-state.json has non-ASCII UTF-8 strings from Phase 0 onward (Round 4 High #1 regression!).
out=$(bash "$STATE" commit-phase0 --task "$TASK_K" --repo "$REPO_K" --authorization "用户批准中文规划" 2>&1); rc=$?
assert_rc "commit-phase0 on Chinese task dir 01-中文 with Chinese --authorization succeeds" "$rc" 0

# Phase 1 -> Phase 2a -> Phase 2b on Chinese task dir!
pd_k=$(bash "$STATE" prepare-design --task "$TASK_K" --repo "$REPO_K" --slots-json "$TMP/designers.json" --owner "owner-k1")
PDK_RUN=$(printf '%s\n' "$pd_k" | sed -n 's/^RUN_ID=//p')
for sn in candidate-a candidate-b candidate-c; do
  bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PDK_RUN" --slot "$sn" --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PDK_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot "$sn" --attempt 1 --task-id "tk-$sn" --child-thread-id "ctk-$sn" --child-run-id "crk-$sn" >/dev/null
  rr_k=$(bash "$STATE" record-result --task "$TASK_K" --run-id "$PDK_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot "$sn" --attempt 1 --task-id "tk-$sn" --child-run-id "crk-$sn" --input "$TMP/cand-ok.md")
  RF_K=$(printf '%s\n' "$rr_k" | sed -n 's/^RESULT_FILE=//p')
  [ -f "$RF_K" ] || fail "record-result RESULT_FILE mojibaked on Chinese task dir: $RF_K"
done
ok "Phase 1 record-result RESULT_FILE paths exist verbatim on Chinese task dir"
bash "$STATE" commit-phase1 --task "$TASK_K" --repo "$REPO_K" >/dev/null
assert_rc "commit-phase1 on Chinese task dir succeeds" "$?" 0

pj_k=$(bash "$STATE" prepare-judge --task "$TASK_K" --repo "$REPO_K" --target-json "$TMP/judge-target.json" --owner "owner-k1")
PJK_RUN=$(printf '%s\n' "$pj_k" | sed -n 's/^RUN_ID=//p')
CM_K=$(printf '%s\n' "$pj_k" | sed -n 's/^CANDIDATES_MANIFEST=//p')
[ -f "$CM_K" ] && ok "prepare-judge CANDIDATES_MANIFEST path exists verbatim on Chinese task dir" || fail "CANDIDATES_MANIFEST mojibaked: $CM_K"
CA_K=$(shasum -a 256 "$TASK_K/research/plans/candidates/candidate-a.md" | awk '{print $1}')
CB_K=$(shasum -a 256 "$TASK_K/research/plans/candidates/candidate-b.md" | awk '{print $1}')
CC_K=$(shasum -a 256 "$TASK_K/research/plans/candidates/candidate-c.md" | awk '{print $1}')
cat > "$TMP/judge-k.json" <<EOF
{
  "candidate_set": [
    { "slot": "candidate-a", "sha256": "$CA_K" },
    { "slot": "candidate-b", "sha256": "$CB_K" },
    { "slot": "candidate-c", "sha256": "$CC_K" }
  ],
  "fact_checks": [
    { "id": "F1", "candidate_slot": "candidate-c", "claim": "src/app.py:1 ok", "status": "CONFIRMED", "file_line_evidence": "src/app.py:1" }
  ],
  "axis_matrix": {
    "architecture_fit": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "ssot_invariants": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "hidden_callers": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "migration_compat": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "real_entrypoint_tests": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "abstraction_restraint": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "prd_scope_fidelity": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "rollback_viability": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "unique_risks": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "key_assumptions": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "dependency_order": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}},
    "failure_recovery_acceptance": {"candidate-a":{"rating":"strong","evidence_note":"ok"},"candidate-b":{"rating":"acceptable","evidence_note":"ok"},"candidate-c":{"rating":"acceptable","evidence_note":"ok"}}
  },
  "primary_winner": "candidate-a",
  "winner_rationale": "Cleanest invariants.",
  "eliminated": [
    { "slot": "candidate-b", "rationale": "Extra layer." },
    { "slot": "candidate-c", "rationale": "Missing rollback." }
  ],
  "cherry_picks": [],
  "rejected_ideas": [],
  "product_forks": [],
  "product_decisions": [],
  "synthesis_body_markdown": "# Synthesis\nWinner: candidate-a.",
  "initial_design_markdown": "# Design\n- Core design for Chinese task dir (mentions 701 and 703).\n"
}
EOF
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PJK_RUN" --slot judge --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PJK_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot judge --attempt 1 --task-id "tk-j" --child-thread-id "ctk-j" --child-run-id "crk-j" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PJK_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot judge --attempt 1 --task-id "tk-j" --child-run-id "crk-j" --input "$TMP/judge-k.json" >/dev/null
bash "$STATE" commit-phase2a --task "$TASK_K" --repo "$REPO_K" >/dev/null
bash "$STATE" commit-phase2b --task "$TASK_K" --repo "$REPO_K" --assemble >/dev/null
assert_rc "Phase 2a + 2b succeed cleanly on Chinese task dir" "$?" 0

# K4a. prepare-review on Chinese task dir (previously crashed with EXTERNAL_CONFLICT!) + 2-BLOCKER collapse rejection!
pr_k1=$(bash "$STATE" prepare-review --task "$TASK_K" --repo "$REPO_K" --purpose initial-full --mode full --slots-json "$TMP/two-rev.json" --owner "owner-k1" 2>&1); rc=$?
assert_rc "prepare-review succeeds on Chinese task dir 01-中文 (no EXTERNAL_CONFLICT)" "$rc" 0
PRK1_RUN=$(printf '%s\n' "$pr_k1" | sed -n 's/^RUN_ID=//p')
PRK1_DSHA=$(printf '%s\n' "$pr_k1" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
PRK1_SNAP=$(printf '%s\n' "$pr_k1" | sed -n 's/^DESIGN_SNAPSHOT=//p')
PRK1_LM=$(printf '%s\n' "$pr_k1" | sed -n 's/^LEDGER_MANIFEST=//p')
[ -f "$PRK1_SNAP" ] && [ -f "$PRK1_LM" ] && ok "prepare-review STDOUT paths exist verbatim on Chinese task dir" || fail "prepare-review STDOUT paths mojibaked: $PRK1_SNAP | $PRK1_LM"

cat > "$TMP/rev-k1-two-blk.json" <<EOF
{
  "summary": "Two independent blockers", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql"
    },
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker Two", "location": "design.md:2",
      "pattern": "p2", "still_wrong": "", "instances": ["design.md:2"],
      "fix": "f2", "prevent": "t2", "evidence": "src/app.py:1", "violates_review_md_rule": ""
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-k1-clean.json" <<EOF
{
  "summary": "Clean", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "clean",
  "findings": [], "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-k1-collapsed.json" <<EOF
{
  "summary": "Dropped Blocker Two", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1", "codex/gpt-6.2-sol"]
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-k1-both.json" <<EOF
{
  "summary": "Both blockers preserved", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 0 }]
    },
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker Two", "location": "design.md:2",
      "pattern": "p2", "still_wrong": "", "instances": ["design.md:2"],
      "fix": "f2", "prevent": "t2", "evidence": "src/app.py:1", "violates_review_md_rule": "",
      "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 1 }]
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRK1_RUN" --slot slot1 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRK1_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-r1a" --child-thread-id "ctk-r1a" --child-run-id "crk-r1a" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRK1_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-r1a" --child-run-id "crk-r1a" --input "$TMP/rev-k1-two-blk.json" >/dev/null
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRK1_RUN" --slot slot2 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRK1_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-r1b" --child-thread-id "ctk-r1b" --child-run-id "crk-r1b" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRK1_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-r1b" --child-run-id "crk-r1b" --input "$TMP/rev-k1-clean.json" >/dev/null

out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k1-collapsed.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects collapsing 2 independent BLOCKERs from 1 slot into 1 (exit 3)" "$rc" 3
# Round 4 High #2: duplicating Blocker One (exact or tweaked) CANNOT substitute for independent Blocker Two!
cat > "$TMP/rev-k1-dup.json" <<EOF
{
  "summary": "Duplicated Blocker One twice", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1"]
    },
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1"]
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-k1-dup-tweak.json" <<EOF
{
  "summary": "Tweaked duplicate of Blocker One", "mode": "full", "reviewed_design_sha256": "$PRK1_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One", "location": "design.md:1",
      "pattern": "p1", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1"]
    },
    {
      "severity": "BLOCKER", "reopens": "", "title": "Blocker One copy", "location": "design.md:1",
      "pattern": "p1 copy", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "f1 copy", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "REVIEW.md#no-raw-sql",
      "sources": ["slot1"]
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k1-dup.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects substituting 2 exact copies of Blocker One for [Blocker One, Blocker Two] (exit 3)" "$rc" 3
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k1-dup-tweak.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects substituting tweaked copy of Blocker One for [Blocker One, Blocker Two] (exit 3)" "$rc" 3
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k1-both.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council accepts preserving both BLOCKERs 1-to-1" "$rc" 0

# K6a. Phase 4 MUST reject numeric codified.{invariant_id, guard_test}!
cat > "$TMP/disp-k-num.json" <<'EOF'
[
  { "id": "D1", "disposition": "adopted", "note": "ok", "codified": { "invariant_id": 701, "guard_test": 703 } },
  { "id": "D2", "disposition": "adopted", "note": "ok" }
]
EOF
out=$(bash "$STATE" commit-phase4-revision --task "$TASK_K" --repo "$REPO_K" --dispositions-json "$TMP/disp-k-num.json" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "Phase 4 rejects numeric JSON codified.{invariant_id, guard_test}" || fail "Phase 4 accepted numeric codified!"

printf '\n- I-K1: parameterized SQL (guard: test_k1).\n' >> "$TASK_K/design.md"
cat > "$TMP/disp-k-ok.json" <<'EOF'
[
  { "id": "D1", "disposition": "adopted", "note": "fixed", "codified": { "invariant_id": "I-K1", "guard_test": "test_k1" } },
  { "id": "D2", "disposition": "adopted", "note": "fixed" }
]
EOF
bash "$STATE" commit-phase4-revision --task "$TASK_K" --repo "$REPO_K" --dispositions-json "$TMP/disp-k-ok.json" >/dev/null

# K5. With project roundCap=1, maxStepBacks=0, 1 dirty round -> PURPOSE=stop;
#     toggling commit-phase0 --ignore-project-config on unchanged PRD MUST recompute thresholds -> PURPOSE=incremental!
out_stop=$(bash "$STATE" next-review --task "$TASK_K" --repo "$REPO_K" 2>&1)
assert_contains "project roundCap=1,maxStepBacks=0 triggers PURPOSE=stop" "$out_stop" "PURPOSE=stop"
out_ign=$(bash "$STATE" commit-phase0 --task "$TASK_K" --repo "$REPO_K" --ignore-project-config 2>&1); rc=$?
assert_rc "commit-phase0 --ignore-project-config on unchanged PRD succeeds" "$rc" 0
assert_contains "PROJECT_CONFIG_IGNORED=1 emitted on toggle" "$out_ign" "PROJECT_CONFIG_IGNORED=1"
out_cs_k=$(bash "$STATE" config-show --task "$TASK_K" --repo "$REPO_K" 2>&1)
assert_contains "config-show --task inherits persisted ignore_project_config" "$out_cs_k" "PROJECT_CONFIG_IGNORED=1"
out_nr_k=$(bash "$STATE" next-review --task "$TASK_K" --repo "$REPO_K" 2>&1)
assert_contains "toggling --ignore-project-config recomputes thresholds -> PURPOSE=incremental (NOT stop!)" "$out_nr_k" "PURPOSE=incremental"

# K4b. Council disputes[] hardening: reject fabricated ghost slots AND reject resolution:reopen BLOCKER->OPTIONAL downgrade!
pr_k2=$(bash "$STATE" prepare-review --task "$TASK_K" --repo "$REPO_K" --purpose full --mode full --slots-json "$TMP/two-rev.json" --owner "owner-k1")
PRK2_RUN=$(printf '%s\n' "$pr_k2" | sed -n 's/^RUN_ID=//p')
PRK2_DSHA=$(printf '%s\n' "$pr_k2" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
cat > "$TMP/rev-k2-reopen.json" <<EOF
{
  "summary": "Reopen D1", "mode": "full", "reviewed_design_sha256": "$PRK2_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "D1", "title": "D1 still broken", "location": "design.md:1",
    "pattern": "p1", "still_wrong": "still raw", "instances": ["design.md:1"],
    "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-k2-ver.json" <<EOF
{
  "summary": "Verified D1", "mode": "full", "reviewed_design_sha256": "$PRK2_DSHA", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "looks good" }], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRK2_RUN" --slot slot1 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRK2_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-r2a" --child-thread-id "ctk-r2a" --child-run-id "crk-r2a" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRK2_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-r2a" --child-run-id "crk-r2a" --input "$TMP/rev-k2-reopen.json" >/dev/null
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRK2_RUN" --slot slot2 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRK2_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-r2b" --child-thread-id "ctk-r2b" --child-run-id "crk-r2b" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRK2_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-r2b" --child-run-id "crk-r2b" --input "$TMP/rev-k2-ver.json" >/dev/null

# (i) Fabricated ghost slots in disputes[] with resolution=verified -> MUST FAIL!
cat > "$TMP/rev-k2-ghost-dispute.json" <<EOF
{
  "summary": "Ghost dispute", "mode": "full", "reviewed_design_sha256": "$PRK2_DSHA", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "verified" }], "step_back": [], "out_of_scope": [],
  "disputes": [{
    "class_id": "D1",
    "reviewer_positions": [
      { "slot": "ghost1", "position": "reopen", "evidence": "src/app.py:1" },
      { "slot": "ghost2", "position": "verified", "evidence": "src/app.py:1" }
    ],
    "resolution": "verified", "code_evidence": "src/app.py:1"
  }]
}
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k2-ghost-dispute.json" 2>&1); rc=$?
assert_rc "disputes[] citing nonexistent ghost slots rejected (exit 3)" "$rc" 3

# (ii) Valid slots with resolution=reopen BUT downgraded D1 to OPTIONAL -> MUST FAIL!
cat > "$TMP/rev-k2-reopen-downgrade.json" <<EOF
{
  "summary": "Downgraded reopen", "mode": "full", "reviewed_design_sha256": "$PRK2_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "OPTIONAL", "reopens": "D1", "title": "D1 downgraded", "location": "design.md:1",
    "pattern": "p1", "still_wrong": "minor", "instances": ["design.md:1"],
    "fix": "f1", "prevent": "t1", "evidence": "src/app.py:1", "violates_review_md_rule": "",
    "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 0 }]
  }],
  "verified": [], "step_back": [], "out_of_scope": [],
  "disputes": [{
    "class_id": "D1",
    "reviewer_positions": [
      { "slot": "slot1", "position": "reopen", "evidence": "src/app.py:1" },
      { "slot": "slot2", "position": "verified", "evidence": "src/app.py:1" }
    ],
    "resolution": "reopen", "code_evidence": "src/app.py:1"
  }]
}
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k2-reopen-downgrade.json" 2>&1); rc=$?
assert_rc "disputes[] resolution=reopen CANNOT downgrade reopened BLOCKER to OPTIONAL (exit 3)" "$rc" 3

# (ii-b) Round 4 High #3: disputes[] resolution=reopen + contradictory --dismissed-findings CANNOT downgrade to OPTIONAL / clean!
cat > "$TMP/disp-k2-contradict.json" <<'EOF'
[
  {
    "slot": "slot1",
    "title": "D1 still broken",
    "severity": "BLOCKER",
    "reopens": "D1",
    "code_evidence": "src/app.py:1"
  }
]
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k2-reopen-downgrade.json" --dismissed-findings "$TMP/disp-k2-contradict.json" 2>&1); rc=$?
assert_rc "disputes[] resolution=reopen + contradictory --dismissed-findings rejected (exit 3, never clean)" "$rc" 3

# (iii) Valid slots with genuine reopen-vs-verified disagreement resolved 'verified' -> PASSES!
cat > "$TMP/rev-k2-valid-dispute.json" <<EOF
{
  "summary": "Real verified dispute", "mode": "full", "reviewed_design_sha256": "$PRK2_DSHA", "verdict": "clean",
  "findings": [], "verified": [{ "id": "D1", "note": "verified in code" }], "step_back": [], "out_of_scope": [],
  "disputes": [{
    "class_id": "D1",
    "reviewer_positions": [
      { "slot": "slot1", "position": "reopen", "evidence": "src/app.py:1" },
      { "slot": "slot2", "position": "verified", "evidence": "src/app.py:1" }
    ],
    "resolution": "verified", "code_evidence": "src/app.py:1 checked directly"
  }]
}
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-k2-valid-dispute.json" 2>&1); rc=$?
assert_rc "disputes[] with real verified slot positions accepted cleanly" "$rc" 0

# K4c. Council step-back: 2 step_back[] proposals from 1 slot CANNOT collapse into 1!
pr_ksb=$(bash "$STATE" prepare-review --task "$TASK_K" --repo "$REPO_K" --purpose step-back --mode step-back --slots-json "$TMP/two-rev.json" --owner "owner-k1")
PRKSB_RUN=$(printf '%s\n' "$pr_ksb" | sed -n 's/^RUN_ID=//p')
PRKSB_DSHA=$(printf '%s\n' "$pr_ksb" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
cat > "$TMP/rev-ksb-two.json" <<EOF
{
  "summary": "Two step-back proposals", "mode": "step-back", "reviewed_design_sha256": "$PRKSB_DSHA", "verdict": "clean",
  "findings": [], "verified": [],
  "step_back": [
    { "classes": ["D1"], "name": "Prop 1", "invites_because": "a", "approach_change": "x", "prevent": "t1" },
    { "classes": ["D2"], "name": "Prop 2", "invites_because": "b", "approach_change": "y", "prevent": "t2" }
  ],
  "out_of_scope": []
}
EOF
cat > "$TMP/rev-ksb-clean.json" <<EOF
{
  "summary": "No proposals", "mode": "step-back", "reviewed_design_sha256": "$PRKSB_DSHA", "verdict": "clean",
  "findings": [], "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-ksb-one.json" <<EOF
{
  "summary": "Dropped Prop 2", "mode": "step-back", "reviewed_design_sha256": "$PRKSB_DSHA", "verdict": "clean",
  "findings": [], "verified": [],
  "step_back": [
    { "classes": ["D1"], "name": "Prop 1", "invites_because": "a", "approach_change": "x", "prevent": "t1", "sources": ["slot1"] }
  ],
  "out_of_scope": []
}
EOF
cat > "$TMP/rev-ksb-both.json" <<EOF
{
  "summary": "Kept both proposals", "mode": "step-back", "reviewed_design_sha256": "$PRKSB_DSHA", "verdict": "clean",
  "findings": [], "verified": [],
  "step_back": [
    { "classes": ["D1"], "name": "Prop 1", "invites_because": "a", "approach_change": "x", "prevent": "t1", "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 0 }] },
    { "classes": ["D2"], "name": "Prop 2", "invites_because": "b", "approach_change": "y", "prevent": "t2", "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 1 }] }
  ],
  "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRKSB_RUN" --slot slot1 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRKSB_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-sba" --child-thread-id "ctk-sba" --child-run-id "crk-sba" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRKSB_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-sba" --child-run-id "crk-sba" --input "$TMP/rev-ksb-two.json" >/dev/null
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRKSB_RUN" --slot slot2 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRKSB_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-sbb" --child-thread-id "ctk-sbb" --child-run-id "crk-sbb" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRKSB_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-sbb" --child-run-id "crk-sbb" --input "$TMP/rev-ksb-clean.json" >/dev/null
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-ksb-one.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects dropping 1 of 2 step_back[] proposals (exit 3)" "$rc" 3
# Round 4 High #2 (step_back): 2 copies of Prop 1 covering superset classes ["D1","D2"] CANNOT substitute for [Prop 1, Prop 2]!
cat > "$TMP/rev-ksb-dup.json" <<EOF
{
  "summary": "Duplicated Prop 1 with superset classes", "mode": "step-back", "reviewed_design_sha256": "$PRKSB_DSHA", "verdict": "clean",
  "findings": [], "verified": [],
  "step_back": [
    { "classes": ["D1", "D2"], "name": "Prop 1", "invites_because": "a", "approach_change": "x", "prevent": "t1", "sources": ["slot1"] },
    { "classes": ["D1", "D2"], "name": "Prop 1 copy", "invites_because": "a", "approach_change": "x copy", "prevent": "t1", "sources": ["slot1"] }
  ],
  "out_of_scope": []
}
EOF
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-ksb-dup.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects substituting 2 copies of Prop 1 (superset classes) for [Prop 1, Prop 2] (exit 3)" "$rc" 3
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-ksb-both.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council accepts preserving both step_back[] proposals 1-to-1" "$rc" 0

# K4d. Round 5 High #3 + Round 6 High #2: different root causes on SAME line (even with IDENTICAL title!) CANNOT collapse into 1 merged finding!
pr_kh3=$(bash "$STATE" prepare-review --task "$TASK_K" --repo "$REPO_K" --purpose full --mode full --slots-json "$TMP/two-rev.json" --owner "owner-k1")
PRKH3_RUN=$(printf '%s\n' "$pr_kh3" | sed -n 's/^RUN_ID=//p')
PRKH3_DSHA=$(printf '%s\n' "$pr_kh3" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
cat > "$TMP/rev-kh3-s1.json" <<EOF
{
  "summary": "Auth check missing", "mode": "full", "reviewed_design_sha256": "$PRKH3_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "Input handling bug", "location": "design.md:1",
    "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "verify session token before handler", "prevent": "add authz test", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-kh3-s2.json" <<EOF
{
  "summary": "Stream not closed", "mode": "full", "reviewed_design_sha256": "$PRKH3_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "Input handling bug", "location": "design.md:1",
    "pattern": "file stream leaks descriptor on error return path", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "close stream handle in finally block", "prevent": "add leak test", "evidence": "src/app.py:1", "violates_review_md_rule": ""
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-kh3-bad-merge.json" <<EOF
{
  "summary": "Collapsed distinct root causes despite same title", "mode": "full", "reviewed_design_sha256": "$PRKH3_DSHA", "verdict": "findings",
  "findings": [{
    "severity": "BLOCKER", "reopens": "", "title": "Input handling bug", "location": "design.md:1",
    "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "", "instances": ["design.md:1"],
    "fix": "verify session token before handler", "prevent": "add authz test", "evidence": "src/app.py:1", "violates_review_md_rule": "",
    "sources": ["slot1", "slot2"],
    "merged_from": [{ "slot": "slot1", "index": 0 }, { "slot": "slot2", "index": 0 }],
    "merge_rationale": "same line and same title"
  }],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
cat > "$TMP/rev-kh3-good-sep.json" <<EOF
{
  "summary": "Preserved both distinct same-line root causes", "mode": "full", "reviewed_design_sha256": "$PRKH3_DSHA", "verdict": "findings",
  "findings": [
    {
      "severity": "BLOCKER", "reopens": "", "title": "Input handling bug", "location": "design.md:1",
      "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "verify session token before handler", "prevent": "add authz test", "evidence": "src/app.py:1", "violates_review_md_rule": "",
      "sources": ["slot1"], "merged_from": [{ "slot": "slot1", "index": 0 }]
    },
    {
      "severity": "BLOCKER", "reopens": "", "title": "Input handling bug", "location": "design.md:1",
      "pattern": "file stream leaks descriptor on error return path", "still_wrong": "", "instances": ["design.md:1"],
      "fix": "close stream handle in finally block", "prevent": "add leak test", "evidence": "src/app.py:1", "violates_review_md_rule": "",
      "sources": ["slot2"], "merged_from": [{ "slot": "slot2", "index": 0 }]
    }
  ],
  "verified": [], "step_back": [], "out_of_scope": []
}
EOF
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRKH3_RUN" --slot slot1 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRKH3_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-h3a" --child-thread-id "ctk-h3a" --child-run-id "crk-h3a" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRKH3_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-h3a" --child-run-id "crk-h3a" --input "$TMP/rev-kh3-s1.json" >/dev/null
bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRKH3_RUN" --slot slot2 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRKH3_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-h3b" --child-thread-id "ctk-h3b" --child-run-id "crk-h3b" >/dev/null
bash "$STATE" record-result --task "$TASK_K" --run-id "$PRKH3_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot2 --attempt 1 --task-id "tk-h3b" --child-run-id "crk-h3b" --input "$TMP/rev-kh3-s2.json" >/dev/null
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-kh3-bad-merge.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council rejects merging different root causes on the same line (exit 3)" "$rc" 3
out=$(bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" --merged-input "$TMP/rev-kh3-good-sep.json" 2>&1); rc=$?
assert_rc "t3-tri-plan council accepts keeping distinct same-line root causes separately" "$rc" 0

# Finish convergence on TASK_K for K6b Phase 5 numeric JSON rejection!
# (D2 was promoted to recurring by K4c step_back[], and D3/D4 were opened by K4d, so dispose D2/D3/D4 cleanly!)
printf '\n- I-K2: centralize guard (guard: test_k2).\n' >> "$TASK_K/design.md"
cat > "$TMP/disp-k-sb.json" <<'EOF'
[
  { "id": "D2", "disposition": "adopted", "note": "codified after step-back", "codified": { "invariant_id": "I-K2", "guard_test": "test_k2" } },
  { "id": "D3", "disposition": "adopted", "note": "fixed auth check" },
  { "id": "D4", "disposition": "adopted", "note": "fixed stream close" }
]
EOF
bash "$STATE" commit-phase4-revision --task "$TASK_K" --repo "$REPO_K" --step-back-assessment-done --dispositions-json "$TMP/disp-k-sb.json" >/dev/null
for _c in 1 2; do
  pr_kc=$(bash "$STATE" prepare-review --task "$TASK_K" --repo "$REPO_K" --purpose full --mode full --slots-json "$TMP/single-rev.json" --owner "owner-k1")
  PRKC_RUN=$(printf '%s\n' "$pr_kc" | sed -n 's/^RUN_ID=//p')
  PRKC_DSHA=$(printf '%s\n' "$pr_kc" | sed -n 's/^REVIEWED_DESIGN_SHA256=//p')
  cat > "$TMP/rev-kc.json" <<EOF
{ "summary": "Clean", "mode": "full", "reviewed_design_sha256": "$PRKC_DSHA", "verdict": "clean", "findings": [], "verified": [{ "id": "D1", "note": "ok" }], "step_back": [], "out_of_scope": [] }
EOF
  bash "$STATE" claim-slot --task "$TASK_K" --run-id "$PRKC_RUN" --slot slot1 --owner "owner-k1" --owner-gen 1 --generation 1 >/dev/null
  bash "$STATE" record-dispatch --task "$TASK_K" --run-id "$PRKC_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-c$_c" --child-thread-id "ctk-c$_c" --child-run-id "crk-c$_c" >/dev/null
  bash "$STATE" record-result --task "$TASK_K" --run-id "$PRKC_RUN" --generation 1 --owner "owner-k1" --owner-gen 1 --slot slot1 --attempt 1 --task-id "tk-c$_c" --child-run-id "crk-c$_c" --input "$TMP/rev-kc.json" >/dev/null
  bash "$STATE" finish-review-round --task "$TASK_K" --repo "$REPO_K" >/dev/null
done

# K6b. Phase 5 MUST reject numeric JSONL file:709 AND numeric codified invariant_id:701 / guard_test:703!
cat > "$TASK_K/implement.md" <<'EOF'
# Implement
- I-K1 guard test_k1 and I-K2 guard test_k2 (also mentions 701 and 703)
EOF
printf '{"file": 709, "reason": "numeric file path"}\n' > "$TASK_K/implement.jsonl"
printf '{"file": ".trellis/spec/core.md", "reason": "ok"}\n' > "$TASK_K/check.jsonl"
out=$(bash "$STATE" commit-phase5 --task "$TASK_K" --repo "$REPO_K" 2>&1); rc=$?
assert_rc "Phase 5 rejects numeric JSONL file:709 (exit 3)" "$rc" 3

printf '{"file": ".trellis/spec/core.md", "reason": "ok"}\n' > "$TASK_K/implement.jsonl"
cp "$TASK_K/research/plans/planning-state.json" "$TMP/ps-k.bak"
python3 -c '
import json
p = "'"$TASK_K/research/plans/planning-state.json"'"
d = json.load(open(p, "r", encoding="utf-8"))
d["review"]["classes"]["D1"]["codified"] = {"invariant_id": 701, "guard_test": 703, "review_md_entry": ""}
open(p, "w", encoding="utf-8").write(json.dumps(d, indent=2))
'
out=$(bash "$STATE" commit-phase5 --task "$TASK_K" --repo "$REPO_K" 2>&1); rc=$?
assert_rc "Phase 5 rejects numeric codified invariant_id:701 / guard_test:703 in planning-state.json (exit 3)" "$rc" 3
cp "$TMP/ps-k.bak" "$TASK_K/research/plans/planning-state.json"
out=$(bash "$STATE" commit-phase5 --task "$TASK_K" --repo "$REPO_K" 2>&1); rc=$?
assert_rc "Phase 5 succeeds on Chinese task dir once valid string JSONL & codified restored" "$rc" 0

# Round 4 High #1: extend Chinese task dir (01-中文 with non-ASCII state) all the way through Phase 6 activation!
out=$(bash "$STATE" commit-phase6-ready --task "$TASK_K" --repo "$REPO_K" --authorization "用户批准启动中文任务" 2>&1); rc=$?
assert_rc "commit-phase6-ready succeeds on Chinese task dir 01-中文" "$rc" 0
out=$(TRELLIS_CONTEXT_ID="ctx-k-zh" bash "$STATE" activate-task --task "$TASK_K" --repo "$REPO_K" --owner "owner-k1" --authorization "用户批准启动中文任务" 2>&1); rc=$?
assert_rc "activate-task on Chinese task dir 01-中文 succeeds cleanly (never activation_uncertain)" "$rc" 0
assert_contains "activate-task on Chinese task dir emits ACTIVATED=1" "$out" "ACTIVATED=1"
out_cfk=$(bash "$STATE" check-freshness --task "$TASK_K" --repo "$REPO_K" 2>&1); rc=$?
assert_rc "check-freshness after Phase 6 activation on Chinese task dir succeeds" "$rc" 0
assert_contains "check-freshness after Phase 6 activation on Chinese task dir reports NEXT_STAGE=done" "$out_cfk" "NEXT_STAGE=done"

# K7. TriTx::_git SIGTERM on rev-parse HEAD fails closed (NEVER returns UNBORN!) + TriTx catches 2nd edit to untracked file inside submodule!
SHIM_HEAD="$TMP/git-sigterm-head"
mkdir -p "$SHIM_HEAD"
cat > "$SHIM_HEAD/git" <<EOF
#!/usr/bin/env bash
is_rp=0; is_head=0
for arg in "\$@"; do
  case "\$arg" in
    rev-parse) is_rp=1 ;;
    HEAD) is_head=1 ;;
  esac
done
if [ "\$is_rp" = 1 ] && [ "\$is_head" = 1 ]; then
  kill -TERM \$\$
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM_HEAD/git"
out=$(PATH="$SHIM_HEAD:$PATH" perl -I"$HERE/lib" -MTriTx=compute_worktree_fp -e 'compute_worktree_fp($ARGV[0], "")' "$REPO_K" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "TriTx compute_worktree_fp fails closed on rev-parse HEAD SIGTERM (never UNBORN)" "$out" "rc=143" || fail "TriTx returned UNBORN on SIGTERM!"
out=$(PATH="$SHIM_HEAD:$PATH" perl -I"$HERE/lib" -MTriTx=scan_repo_rules -e 'scan_repo_rules($ARGV[0])' "$REPO_K" 2>&1); rc=$?
[ "$rc" -ne 0 ] && assert_contains "TriTx scan_repo_rules fails closed on rev-parse HEAD SIGTERM" "$out" "rc=143" || fail "TriTx scan_repo_rules swallowed SIGTERM!"

# Submodule untracked file 2nd edit caught by TriTx::compute_worktree_fp!
SUB_K_SRC="$TMP/tri-sub-src"
SUB_K_HOST="$TMP/tri-sub-host"
mkdir -p "$SUB_K_SRC" "$SUB_K_HOST"
(cd "$SUB_K_SRC" && git init -q -b main . && git config user.email t@t && git config user.name t && echo s1 > s.txt && git add s.txt && git commit -qm s1)
(
  cd "$SUB_K_HOST" && git init -q -b main . && git config user.email t@t && git config user.name t && echo h1 > h.txt && git add h.txt && git commit -qm h1
  git -c protocol.file.allow=always submodule -q add "$SUB_K_SRC" vendor/sub >/dev/null 2>&1
  git commit -qm "add sub"
)
printf 'untr-v1\n' > "$SUB_K_HOST/vendor/sub/untr.txt"
FP1=$(perl -I"$HERE/lib" -MTriTx=compute_worktree_fp -e 'print compute_worktree_fp($ARGV[0], "")->{digest}' "$SUB_K_HOST")
printf 'untr-v2\n' > "$SUB_K_HOST/vendor/sub/untr.txt"
FP2=$(perl -I"$HERE/lib" -MTriTx=compute_worktree_fp -e 'print compute_worktree_fp($ARGV[0], "")->{digest}' "$SUB_K_HOST")
[ -n "$FP1" ] && [ -n "$FP2" ] && [ "$FP1" != "$FP2" ] && ok "TriTx compute_worktree_fp catches 2nd edit to untracked file inside tracked submodule" || fail "TriTx missed 2nd edit to submodule untracked file! ($FP1 == $FP2)"

# K8. Round 6 High #1: t3-tri-plan install-skills.sh handles leading '-' and '-e;BEGIN{...}' target dirs safely!
INST_TRI_DASH="$TMP/inst-tri-dash"
mkdir -p "$INST_TRI_DASH"
(
  cd "$INST_TRI_DASH" || exit 2
  bash "$INSTALLER" --target "-foo" >/dev/null || exit 51
  [ -L "-foo/t3-tri-plan" ] || exit 52
  bash "$INSTALLER" --uninstall --target "-foo" >/dev/null || exit 53
  [ ! -L "-foo/t3-tri-plan" ] || exit 54
  POC_DIR='-e;BEGIN{open(my $f,">","INJECTED_TRI");print $f "bad";close $f}#'
  bash "$INSTALLER" --target "$POC_DIR" >/dev/null || exit 55
  bash "$INSTALLER" --uninstall --target "$POC_DIR" >/dev/null || exit 56
  [ ! -e "INJECTED_TRI" ] && [ ! -L "$POC_DIR/t3-tri-plan" ] || exit 57
) && ok "t3-tri-plan install-skills.sh handles leading-dash and -e target dirs safely" || fail "t3-tri-plan install-skills.sh failed or executed Perl switch code"

printf '\n========================================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" -eq 0 ]
