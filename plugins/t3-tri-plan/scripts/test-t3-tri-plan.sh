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

printf '\n========================================\n'
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
printf '========================================\n'
[ "$FAIL" -eq 0 ]
