#!/usr/bin/env bash
# test-t3-cr-state.sh — self-contained regression suite for plugins/t3-cr-loop (v1.0.0).
# Usage: bash plugins/t3-cr-loop/scripts/test-t3-cr-state.sh   (exit 0 = all pass)

set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
ST="$HERE/t3-cr-state.sh"
INSTALL="$HERE/install-skills.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/t3-cr-test.XXXXXX") || exit 2
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

ok()     { PASS=$((PASS + 1)); }
bad()    { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*"; }
expect() { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$2', got '$3'"; fi; }
kv()     { sed -n "s/^$1=//p" | head -n 1; }

export T3_CR_LOOP_CONFIG="$TMP/user-config/config.json"
unset CR_LOOP_ROUND_CAP CR_LOOP_MAX_STEP_BACKS CR_LOOP_SKIP_P3

# Build mock orchestrator_capabilities JSON matching real T3 Code structure
CAPS="$TMP/caps.json"
cat > "$CAPS" <<'EOF'
{
  "providers": [
    {
      "providerInstanceId": "antigravity",
      "driverKind": "antigravity",
      "canRunChildTask": true,
      "models": [
        { "id": "gemini-4-neon", "options": [{ "id": "thought_level", "values": ["low","medium","high","xhigh"], "default": "high" }] }
      ]
    },
    {
      "providerInstanceId": "claudeAgent",
      "driverKind": "claudeAgent",
      "canRunChildTask": true,
      "models": [
        { "id": "claude-opus-5-5", "options": [{ "id": "effort", "values": ["low","medium","high","xhigh","max","ultrathink"], "default": "medium" }] }
      ]
    },
    {
      "providerInstanceId": "codex",
      "driverKind": "codex",
      "canRunChildTask": true,
      "models": [
        { "id": "gpt-6.2-sol", "options": [{ "id": "reasoningEffort", "values": ["low","medium","high","xhigh","max","ultra"], "default": "low" }] }
      ]
    },
    {
      "providerInstanceId": "cursor",
      "driverKind": "cursor",
      "canRunChildTask": false,
      "models": [
        { "id": "cursor-default", "options": [] }
      ]
    }
  ]
}
EOF

R="$TMP/repo"
mkdir -p "$R/sub" && cd "$R" || exit 2
git init -q -b main . && git config user.email t@example.invalid && git config user.name t
printf 'a\n' > app.txt
printf '# REVIEW\n\n## no-sql-concat\nNever concatenate SQL.\n' > REVIEW.md
git add . && git commit -qm base
BASE_SHA=$(git rev-parse main)
git switch -qc feat/t3 && printf 'b\n' >> app.txt && git commit -qam change

# --- 1. Unconfigured detection, config-set, capability validation, effort key mapping & intersection ---
expect "unconfigured detected" "0" "$(bash "$ST" config-show | kv CONFIGURED)"

CFG_GOOD="$TMP/cfg-good.json"
cat > "$CFG_GOOD" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "claudeAgent", "codex"],
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "council": {
    "effortMode": "unified",
    "unifiedEffort": "xhigh",
    "reviewers": [
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "xhigh" },
      { "providerInstanceId": "claudeAgent", "model": "claude-opus-5-5", "effortKey": "effort", "effort": "xhigh" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "xhigh" }
    ]
  },
  "knobs": { "roundCap": 3, "maxStepBacks": 1, "skipP3": 1 }
}
EOF
bash "$ST" config-set --file "$CFG_GOOD" >/dev/null
expect "config-set succeeded" "0" "$?"
out_cfg=$(bash "$ST" config-show --capabilities "$CAPS")
expect "config valid" "1:1" "$(printf '%s\n' "$out_cfg" | kv CONFIGURED):$(printf '%s\n' "$out_cfg" | kv CONFIG_VALID)"
expect "default options mapped to reasoningEffort" '{"reasoningEffort":"high"}' "$(printf '%s\n' "$out_cfg" | kv DEFAULT_OPTIONS_JSON)"
expect "council count 3" "3" "$(printf '%s\n' "$out_cfg" | kv COUNCIL_COUNT)"
expect "council slot 1 maps thought_level" 'antigravity|gemini-4-neon|thought_level|xhigh|{"thought_level":"xhigh"}' "$(printf '%s\n' "$out_cfg" | kv COUNCIL_SLOT_1)"
expect "council slot 2 maps effort" 'claudeAgent|claude-opus-5-5|effort|xhigh|{"effort":"xhigh"}' "$(printf '%s\n' "$out_cfg" | kv COUNCIL_SLOT_2)"

# Per-call override works and maps effort key automatically
out_ov=$(bash "$ST" config-show --capabilities "$CAPS" --override-model claudeAgent/claude-opus-5-5 --override-effort max)
expect "per-call model+effort override" '{"effort":"max"}' "$(printf '%s\n' "$out_ov" | kv DEFAULT_OPTIONS_JSON)"
out_sng=$(bash "$ST" config-show --capabilities "$CAPS" --single antigravity/gemini-4-neon:high)
expect "single override sets council count 1" "1" "$(printf '%s\n' "$out_sng" | kv COUNCIL_COUNT)"

# Invalid effort (outside model enum / outside unified intersection) fails closed — no silent clamping!
bash "$ST" config-show --capabilities "$CAPS" --override-model antigravity/gemini-4-neon --override-effort max >/dev/null 2>&1
expect "invalid effort rejected without silent clamping" "3" "$?"
bash "$ST" config-show --capabilities "$CAPS" --override-model cursor/cursor-default >/dev/null 2>&1
expect "disabled provider rejected without silent swap" "3" "$?"

# Project .t3-cr-loop.json unauthorized provider gate
cat > "$R/.t3-cr-loop.json" <<'EOF'
{
  "defaultReviewer": { "providerInstanceId": "claudeAgent", "model": "claude-opus-5-5", "effortKey": "effort", "effort": "high" }
}
EOF
# Remove claudeAgent from authorizedProviders temporarily to test gate
perl -MJSON::PP -e '
  open my $fh, "<:raw", $ARGV[0] or die; local $/; my $j = JSON::PP->new->utf8->decode(<$fh>); close $fh;
  $j->{authorizedProviders} = ["codex", "antigravity"];
  open my $oh, ">:raw", $ARGV[0] or die; print $oh JSON::PP->new->utf8->encode($j); close $oh;
' "$T3_CR_LOOP_CONFIG"
out_p=$(bash "$ST" config-show --capabilities "$CAPS")
expect "project unauthorized provider flagged" "1:claudeAgent" "$(printf '%s\n' "$out_p" | kv NEEDS_PROVIDER_AUTH):$(printf '%s\n' "$out_p" | kv UNAUTHORIZED_PROVIDERS)"
bash "$ST" config-authorize-provider claudeAgent >/dev/null
expect "authorized provider clears gate" "0" "$(bash "$ST" config-show --capabilities "$CAPS" | kv NEEDS_PROVIDER_AUTH)"
rm -f "$R/.t3-cr-loop.json"

# --- Fixtures ---
F_CLEAN="$TMP/clean.json"
printf '{"summary":"all good","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}\n' > "$F_CLEAN"
F_FENCED="$TMP/fenced.txt"
cat > "$F_FENCED" <<'EOF'
```json
{
  "summary": "Found missing null guard at line 1.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1",
      "reopens": "",
      "title": "Missing null guard",
      "location": "app.txt:1",
      "pattern": "Unchecked access on input",
      "still_wrong": "",
      "instances": ["app.txt:1"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test"
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
```
EOF
F_DIRTY_S2="$TMP/dirty-s2.json"
cat > "$F_DIRTY_S2" <<'EOF'
{
  "summary": "Found missing null guard at line 2.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P2",
      "reopens": "",
      "title": "Unchecked null guard",
      "location": "app.txt:2",
      "pattern": "Unchecked access at second site",
      "still_wrong": "",
      "instances": ["app.txt:2"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test"
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
EOF
F_PROSE_WRAP="$TMP/prose.txt"
printf 'Here is my review:\n```json\n{"summary":"s","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}\n```\n' > "$F_PROSE_WRAP"
F_DUPKEY="$TMP/dupkey.json"
printf '{"summary":"s","verdict":"findings","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}\n' > "$F_DUPKEY"
F_DIRTY_MERGED="$TMP/dirty-merged.json"
cat > "$F_DIRTY_MERGED" <<'EOF'
{
  "summary": "Found one class across two models.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1",
      "reopens": "",
      "title": "Missing null guard",
      "location": "app.txt:1",
      "pattern": "Unchecked access on input at both sites",
      "still_wrong": "",
      "instances": ["app.txt:1", "app.txt:2"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test",
      "sources": ["antigravity/gemini-4-neon", "claudeAgent/claude-opus-5-5"],
      "merged_from": [
        { "slot": "s1", "index": 0 },
        { "slot": "s2", "index": 0 }
      ],
      "merge_rationale": "Both slots report the same missing null guard across app.txt:1 and app.txt:2"
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
EOF
F_REOPEN_SLOT="$TMP/reopen-slot.json"
cat > "$F_REOPEN_SLOT" <<'EOF'
{
  "summary": "C1 still missing one site.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P2",
      "reopens": "C1",
      "title": "Missing null guard",
      "location": "app.txt:2",
      "pattern": "Unchecked access",
      "still_wrong": "Second site missed",
      "instances": ["app.txt:2"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test"
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
EOF
F_REOPEN_MERGED="$TMP/reopen-merged.json"
cat > "$F_REOPEN_MERGED" <<'EOF'
{
  "summary": "C1 still missing one site.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P2",
      "reopens": "C1",
      "title": "Missing null guard",
      "location": "app.txt:2",
      "pattern": "Unchecked access",
      "still_wrong": "Second site missed",
      "instances": ["app.txt:2"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test",
      "sources": ["codex/gpt-6.2-sol"]
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
EOF

OWNER="thread-parent-1"

# --- 2. next priority table + council prepare + atomic CAS slot lifecycle + partial failure gate ---
out_n1=$(bash "$ST" next --base main)
expect "round 1 is initial-full council" "initial-full:council" "$(printf '%s\n' "$out_n1" | kv PURPOSE):$(printf '%s\n' "$out_n1" | kv PROFILE)"

out_p1=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2,s3 --owner "$OWNER")
RD1=$(printf '%s\n' "$out_p1" | kv ROUND_DIR)
expect "next while active round open returns resume" "resume" "$(bash "$ST" next --base main | kv PURPOSE)"
# Double prepare refused while active round exists
bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER" >/dev/null 2>&1
expect "duplicate prepare while active round open refused" "2" "$?"

# CAS claim-slot + double claim refused
c1=$(bash "$ST" claim-slot "$RD1" --slot s1 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{"thought_level":"xhigh"}')
expect "claim-slot s1 attempt 1" "s1:1" "$(printf '%s\n' "$c1" | kv CLAIMED):$(printf '%s\n' "$c1" | kv ATTEMPT)"
bash "$ST" claim-slot "$RD1" --slot s1 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null 2>&1
expect "double claim-slot rejected by CAS" "2" "$?"
bash "$ST" record-dispatch "$RD1" --slot s1 --attempt 1 --owner "$OWNER" --task-id t1 --child-thread-id ct1 >/dev/null
# Claim s2 & s3
bash "$ST" claim-slot "$RD1" --slot s2 --attempt 1 --owner "$OWNER" --provider claudeAgent --model claude-opus-5-5 --options-json '{"effort":"xhigh"}' >/dev/null
bash "$ST" record-dispatch "$RD1" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2 --child-thread-id ct2 >/dev/null
bash "$ST" claim-slot "$RD1" --slot s3 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{"reasoningEffort":"xhigh"}' >/dev/null
bash "$ST" record-dispatch "$RD1" --slot s3 --attempt 1 --owner "$OWNER" --task-id t3 --child-thread-id ct3 >/dev/null

# Strict JSON validation on record-result: fenced JSON ok, prose-wrapped rejected, duplicate key rejected
bash "$ST" record-result "$RD1" --slot s1 --attempt 1 --owner "$OWNER" --input "$F_FENCED" >/dev/null
expect "fenced JSON accepted" "0" "$?"
bash "$ST" record-result "$RD1" --slot s2 --attempt 1 --owner "$OWNER" --input "$F_PROSE_WRAP" >/dev/null
expect "prose outside fence rejected" "5" "$?"
# Retry s2 attempt 2 succeeds after terminal completed_invalid
bash "$ST" claim-slot "$RD1" --slot s2 --attempt 2 --owner "$OWNER" --provider claudeAgent --model claude-opus-5-5 --options-json '{"effort":"xhigh"}' >/dev/null
bash "$ST" record-dispatch "$RD1" --slot s2 --attempt 2 --owner "$OWNER" --task-id t2b --child-thread-id ct2b >/dev/null
# Stale attempt 1 result rejected by CAS
bash "$ST" record-result "$RD1" --slot s2 --attempt 1 --owner "$OWNER" --input "$F_CLEAN" >/dev/null 2>&1
expect "stale attempt 1 result rejected" "2" "$?"
bash "$ST" record-result "$RD1" --slot s2 --attempt 2 --owner "$OWNER" --input "$F_DIRTY_S2" >/dev/null
expect "attempt 2 valid JSON accepted" "0" "$?"

# s3 hits waiting (cannot retry while waiting), then interrupted (terminal -> allows retry -> fails again -> partial failure gate)
bash "$ST" update-slot "$RD1" --slot s3 --attempt 1 --owner "$OWNER" --state waiting --reason "awaiting user" >/dev/null
bash "$ST" claim-slot "$RD1" --slot s3 --attempt 2 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null 2>&1
expect "waiting slot cannot be retried" "2" "$?"
bash "$ST" update-slot "$RD1" --slot s3 --attempt 1 --owner "$OWNER" --state interrupted --reason "host interrupted" >/dev/null
bash "$ST" claim-slot "$RD1" --slot s3 --attempt 2 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD1" --slot s3 --attempt 2 --owner "$OWNER" --task-id t3b --child-thread-id ct3b >/dev/null
bash "$ST" record-result "$RD1" --slot s3 --attempt 2 --owner "$OWNER" --input "$F_DUPKEY" >/dev/null
expect "duplicate JSON key rejected" "5" "$?"

# Partial council finish refused without --partial-approved, accepted with it
bash "$ST" finish "$RD1" --merged "$F_DIRTY_MERGED" >/dev/null 2>&1
expect "partial council finish refused without approval" "2" "$?"
out_f1=$(bash "$ST" finish "$RD1" --merged "$F_DIRTY_MERGED" --partial-approved "user approved 2/3 council")
expect "partial council finish accepted with approval" "dirty:C1" "$(printf '%s\n' "$out_f1" | kv VERDICT):$(printf '%s\n' "$out_f1" | kv NEW_CLASSES)"
grep -q 'antigravity/gemini-4-neon, claudeAgent/claude-opus-5-5' "$(printf '%s\n' "$out_f1" | kv RESULT)" && ok || bad "sources rendered in review.md"
# Idempotent explicit retry
expect "explicit finish retry idempotent" "dirty" "$(bash "$ST" finish "$RD1" --merged "$F_DIRTY_MERGED" | kv VERDICT)"

# --- 3. Same HEAD after dirty -> full default; commit -> incremental default; cap 3 -> step-back council; convergence -> reset ---
expect "same HEAD after dirty -> full default" "full:default" "$(bash "$ST" next --base main | sed -n 's/^PURPOSE=//p;s/^PROFILE=//p' | paste -sd: -)"

run_single_round() { # run_single_round <purpose> <mode> <base> <merged_file> [since] [slot_file]
  local p="$1" m="$2" b="$3" mf="$4" s="${5:-}" sf="${6:-$4}"
  local po rd
  po=$(bash "$ST" prepare --purpose "$p" --mode "$m" --base "$b" ${s:+--since "$s"} --slots s1 --owner "$OWNER") || return 9
  rd=$(printf '%s\n' "$po" | kv ROUND_DIR)
  bash "$ST" claim-slot "$rd" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{"reasoningEffort":"high"}' >/dev/null || return 9
  bash "$ST" record-dispatch "$rd" --slot s1 --attempt 1 --owner "$OWNER" --task-id "t-$rd" --child-thread-id "ct-$rd" >/dev/null || return 9
  bash "$ST" record-result "$rd" --slot s1 --attempt 1 --owner "$OWNER" --input "$sf" >/dev/null || return 9
  bash "$ST" finish "$rd" --merged "$mf"
}

for i in 1 2; do
  printf 'fix %s\n' "$i" >> app.txt && git commit -qam "fix $i"
  nx=$(bash "$ST" next --base main)
  expect "incremental default round $i" "incremental:default" "$(printf '%s\n' "$nx" | kv PURPOSE):$(printf '%s\n' "$nx" | kv PROFILE)"
  out_i=$(run_single_round incremental incremental main "$F_REOPEN_MERGED" "$(printf '%s\n' "$nx" | kv SINCE)" "$F_REOPEN_SLOT")
  expect "reopen C1 round $i" "C1" "$(printf '%s\n' "$out_i" | kv REOPENED)"
done
expect "C1 marked recurring" "C1" "$(printf '%s\n' "$out_i" | kv RECURRING)"

# Cap 3 reached -> step-back council (and CR_LOOP_ROUND_CAP=0 disables cap)
printf 'fix 3\n' >> app.txt && git commit -qam "fix 3"
expect "cap 3 -> step-back council" "step-back:council" "$(bash "$ST" next --base main | sed -n 's/^PURPOSE=//p;s/^PROFILE=//p' | paste -sd: -)"
expect "CR_LOOP_ROUND_CAP=0 disables step-back" "incremental" "$(CR_LOOP_ROUND_CAP=0 bash "$ST" next --base main | kv PURPOSE)"

# Run step-back clean -> confirmation-full default -> converged -> mark-converged -> new cycle initial-full council
run_single_round step-back step-back main "$F_CLEAN" >/dev/null
expect "after 1 clean -> confirmation-full default" "confirmation-full:default" "$(bash "$ST" next --base main | sed -n 's/^PURPOSE=//p;s/^PROFILE=//p' | paste -sd: -)"
run_single_round confirmation-full full main "$F_CLEAN" >/dev/null
expect "after 2 clean (2nd full) -> converged" "converged" "$(bash "$ST" next --base main | kv PURPOSE)"
bash "$ST" mark-converged --base main >/dev/null
expect "mark-converged succeeded" "0" "$?"
printf 'next feature\n' >> app.txt && git commit -qam "next feature"
expect "new convergence cycle starts initial-full council" "initial-full:council" "$(bash "$ST" next --base main | sed -n 's/^PURPOSE=//p;s/^PROFILE=//p' | paste -sd: -)"

# Explicit post-rebase-confirmation purpose
expect "post-rebase-confirmation uses default single model" "post-rebase-confirmation:default" "$(bash "$ST" next --base main --purpose post-rebase-confirmation | sed -n 's/^PURPOSE=//p;s/^PROFILE=//p' | paste -sd: -)"

# --- 4. cancel-round ends round & blocks subsequent claim; release-state persists; untracked drift caught ---
po_c=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER")
RDC=$(printf '%s\n' "$po_c" | kv ROUND_DIR)
bash "$ST" cancel-round "$RDC" --owner "$OWNER" --reason "user stopped" >/dev/null
bash "$ST" claim-slot "$RDC" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null 2>&1
expect "cancelled round rejects new slot claim" "2" "$?"

bash "$ST" release-state set rel_pre_rebase_head="$(git rev-parse HEAD)" rel_pinned_remote_head_sha="abc123" rel_rebased_in_8_0=1 >/dev/null
expect "release-state persisted" "abc123:1" "$(bash "$ST" release-state get | sed -n 's/^PINNED_REMOTE_HEAD_SHA=//p;s/^REBASED_IN_8_0=//p' | paste -sd: -)"
bash "$ST" release-state clear >/dev/null
expect "release-state cleared" ":0" "$(bash "$ST" release-state get | sed -n 's/^PINNED_REMOTE_HEAD_SHA=//p;s/^REBASED_IN_8_0=//p' | paste -sd: -)"

po_d=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER")
RDD=$(printf '%s\n' "$po_d" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --task-id td --child-thread-id ctd >/dev/null
bash "$ST" record-result "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --input "$F_CLEAN" >/dev/null
printf 'stray\n' > stray.txt
out_dr=$(bash "$ST" finish "$RDD" --merged "$F_CLEAN"); rc=$?
expect "untracked stray file caught by tree_fp v2" "3:tree-changed" "$rc:$(printf '%s\n' "$out_dr" | kv REASON)"
rm -f stray.txt
# head-drift MUST mark round drifted and clear active_round_dir (no resume loop!)
expect "next after head-drift does NOT loop in resume" "initial-full" "$(bash "$ST" next --base main | kv PURPOSE)"
expect "drifted round status is drifted" "drifted" "$(perl -MJSON::PP -e 'open my $f,"<",$ARGV[0]; local $/; print JSON::PP->new->decode(<$f>)->{status}' "$RDD/active_round.json")"

# --- 5. Cross-repo install-skills.sh verification + foreign symlink ownership protection ---
OTHER_REPO="$TMP/other-repo"
mkdir -p "$OTHER_REPO" && (cd "$OTHER_REPO" && git init -q -b main .)
bash "$INSTALL" --project "$OTHER_REPO" >/dev/null
expect "install-skills into separate repo" "0" "$?"
out_chk=$(cd "$OTHER_REPO" && bash "$INSTALL" --project "$OTHER_REPO" --check)
expect "install-skills --check passes from separate repo" "0:3" "$?:$(printf '%s\n' "$out_chk" | grep -c '^OK ')"
bash "$INSTALL" --project "$OTHER_REPO" --uninstall >/dev/null
expect "install-skills --uninstall clean" "0" "$?"

mkdir -p "$OTHER_REPO/.agents/skills" "$TMP/foreign-t3cr"
ln -s "$TMP/foreign-t3cr" "$OTHER_REPO/.agents/skills/t3-cr-loop"
bash "$INSTALL" --project "$OTHER_REPO" >/dev/null 2>&1
expect "install-skills refuses overwriting foreign symlink" "2" "$?"
bash "$INSTALL" --project "$OTHER_REPO" --uninstall >/dev/null 2>&1
[ -L "$OTHER_REPO/.agents/skills/t3-cr-loop" ] && ok || bad "uninstall deleted foreign symlink!"
rm -f "$OTHER_REPO/.agents/skills/t3-cr-loop"
bash "$INSTALL" --target >/dev/null 2>&1
expect "install-skills missing --target value exits 2 (no hang)" "2" "$?"

# --- 6. Post-review hardening regressions (P0\n bypass, init rc=0, CAS-before-write, config, staged tree_fp, cr-tx dir conflict) ---

# 6a. Severity/verdict/reopens trailing newline MUST fail closed (never TOTAL=0 -> clean!)
F_SEV_NL="$TMP/sev-nl.json"
printf '{"summary":"p0 bug","verdict":"findings","findings":[{"severity":"P0\\n","reopens":"","title":"Drop table","location":"app.txt:1","pattern":"p","still_wrong":"","instances":["app.txt:1"],"fix":"f","prevent":"t"}],"step_back":[],"out_of_scope":[]}\n' > "$F_SEV_NL"
F_VERD_NL="$TMP/verd-nl.json"
printf '{"summary":"ok","verdict":"clean\\n","findings":[],"step_back":[],"out_of_scope":[]}\n' > "$F_VERD_NL"
F_REO_NL="$TMP/reo-nl.json"
printf '{"summary":"re","verdict":"findings","findings":[{"severity":"P1","reopens":"C1\\n","title":"Re","location":"app.txt:1","pattern":"p","still_wrong":"still","instances":["app.txt:1"],"fix":"f","prevent":"t"}],"step_back":[],"out_of_scope":[]}\n' > "$F_REO_NL"
for badf in "$F_SEV_NL" "$F_VERD_NL" "$F_REO_NL"; do
  perl "$HERE/parse-review.pl" --validate-only "$badf" >/dev/null 2>&1; rc=$?
  expect "parse-review rejects trailing newline in $(basename "$badf")" "5" "$rc"
done

# 6b. init exits 0 when no active round exists
bash "$ST" init >/dev/null
expect "init exits 0 with no active round" "0" "$?"

# 6c. CAS-before-write in record-result + traversal slot rejection + no overwrite completed_valid + legal update-slot + missing-arg shift guard
po_cas=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2 --owner "$OWNER")
RDCAS=$(printf '%s\n' "$po_cas" | kv ROUND_DIR)
# Missing flag value fails fast without hanging in Bash 3.2
bash "$ST" claim-slot "$RDCAS" --slot >/dev/null 2>&1
expect "claim-slot missing --slot value exits 2" "2" "$?"
# Illegal update-slot on unclaimed slot rejected
bash "$ST" update-slot "$RDCAS" --slot s1 --attempt 0 --owner "$OWNER" --state waiting >/dev/null 2>&1
expect "update-slot rejects unclaimed -> waiting" "2" "$?"

bash "$ST" claim-slot "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --task-id tid-cas1 --child-thread-id ctid-cas1 >/dev/null
# Wrong --task-id rejected before writing any file
bash "$ST" record-result "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --task-id wrong-tid --input "$F_CLEAN" >/dev/null 2>&1
expect "record-result rejects mismatched --task-id" "2" "$?"
[ ! -f "$RDCAS/result-s1-a1.json" ] && ok || bad "mismatched --task-id wrote result file!"
# Traversal slot name rejected before writing any file outside round dir
bash "$ST" record-result "$RDCAS" --slot "../../evil" --attempt 1 --owner "$OWNER" --input "$F_CLEAN" >/dev/null 2>&1
expect "record-result rejects traversal --slot" "2" "$?"
[ ! -f "$RDCAS/../../result-evil-a1.json" ] && ok || bad "traversal slot wrote file!"
# Valid record-result succeeds
bash "$ST" record-result "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --task-id tid-cas1 --input "$F_CLEAN" >/dev/null
expect "record-result with matching --task-id succeeds" "0" "$?"
# Duplicate identical submission is idempotent NOOP
out_dup=$(bash "$ST" record-result "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --task-id tid-cas1 --input "$F_CLEAN")
expect "identical duplicate record-result is DUPLICATE_NOOP=1" "0:1" "$?:$(printf '%s\n' "$out_dup" | kv DUPLICATE_NOOP)"
# Different payload (even invalid/bad!) MUST NOT overwrite or delete completed_valid result file!
bash "$ST" record-result "$RDCAS" --slot s1 --attempt 1 --owner "$OWNER" --task-id tid-cas1 --input "$F_PROSE_WRAP" >/dev/null 2>&1
expect "record-result refuses overwriting completed_valid with different payload" "2" "$?"
[ -s "$RDCAS/result-s1-a1.json" ] && ok || bad "failed overwrite deleted existing valid result-s1-a1.json!"
# Stale wrong-owner call MUST NOT delete or overwrite result-s1-a1.json!
bash "$ST" record-result "$RDCAS" --slot s1 --attempt 1 --owner "other-owner" --input "$F_PROSE_WRAP" >/dev/null 2>&1
expect "wrong-owner record-result rejected" "2" "$?"
[ -s "$RDCAS/result-s1-a1.json" ] && ok || bad "wrong-owner call damaged valid result-s1-a1.json!"
bash "$ST" cancel-round "$RDCAS" --owner "$OWNER" >/dev/null

# 6d. Config fixes: unifiedEffort actively overrides stale member effort, inline :effort wins over --override-effort,
#     project authorizedProviders rejected, unresolvable bare model exits 3 (not 255), --ignore-project-config, knobs effective!
cat > "$TMP/cfg-stale-eff.json" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "claudeAgent", "codex"],
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "council": {
    "effortMode": "unified",
    "unifiedEffort": "medium",
    "reviewers": [
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "" }
    ]
  },
  "knobs": { "roundCap": 2, "maxStepBacks": 0, "skipP3": 1, "requireRebased": 0, "prAutoRebase": 0 }
}
EOF
bash "$ST" config-set --file "$TMP/cfg-stale-eff.json" >/dev/null
expect "config-set accepts schema knobs requireRebased/prAutoRebase & unified empty effort" "0" "$?"
out_ue=$(bash "$ST" config-show --capabilities "$CAPS")
expect "unifiedEffort medium applied to council slot 1" 'antigravity|gemini-4-neon|thought_level|medium|{"thought_level":"medium"}' "$(printf '%s\n' "$out_ue" | kv COUNCIL_SLOT_1)"
expect "unifiedEffort medium applied to council slot 2" 'codex|gpt-6.2-sol|reasoningEffort|medium|{"reasoningEffort":"medium"}' "$(printf '%s\n' "$out_ue" | kv COUNCIL_SLOT_2)"
expect "config-show exports requireRebased=0 and prAutoRebase=0" "0:0" "$(printf '%s\n' "$out_ue" | kv KNOB_requireRebased):$(printf '%s\n' "$out_ue" | kv KNOB_prAutoRebase)"
# Inline :effort wins over global --override-effort
out_inl=$(bash "$ST" config-show --capabilities "$CAPS" --override-council "antigravity/gemini-4-neon:high,codex/gpt-6.2-sol:ultra" --override-effort medium)
expect "inline :effort preserves per-model mode" "per-model" "$(printf '%s\n' "$out_inl" | kv COUNCIL_EFFORT_MODE)"
expect "inline :ultra preserved on codex" 'codex|gpt-6.2-sol|reasoningEffort|ultra|{"reasoningEffort":"ultra"}' "$(printf '%s\n' "$out_inl" | kv COUNCIL_SLOT_2)"
# Unresolvable bare model returns CONFIG_VALID=0 + exit 3 (NOT exit 255)
out_amb=$(bash "$ST" config-show --capabilities "$CAPS" --override-model nonexistent-bare-model 2>&1); rc=$?
expect "unresolvable bare model exits 3 with CONFIG_VALID=0" "3:0" "$rc:$(printf '%s\n' "$out_amb" | kv CONFIG_VALID)"
# Project config with authorizedProviders rejected with exit 3
cat > "$R/.t3-cr-loop.json" <<'EOF'
{
  "authorizedProviders": ["evil"],
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" }
}
EOF
out_badp=$(bash "$ST" config-show --capabilities "$CAPS" 2>&1); rc=$?
expect "project config with authorizedProviders rejected (exit 3)" "3:0" "$rc:$(printf '%s\n' "$out_badp" | kv CONFIG_VALID)"
# --ignore-project-config bypasses project config cleanly
out_ign=$(bash "$ST" config-show --capabilities "$CAPS" --ignore-project-config 2>&1); rc=$?
expect "--ignore-project-config succeeds" "0:1" "$rc:$(printf '%s\n' "$out_ign" | kv PROJECT_CONFIG_IGNORED)"
rm -f "$R/.t3-cr-loop.json"
# Knobs from user config (roundCap=2, maxStepBacks=0) take effect in init when env unset!
out_ki=$(bash "$ST" init)
expect "config knobs roundCap=2 maxStepBacks=0 wired into resolve_knobs" "2:0" "$(printf '%s\n' "$out_ki" | kv ROUND_CAP):$(printf '%s\n' "$out_ki" | kv MAX_STEP_BACKS)"

# 6e. Staged-only index edit (working tree restored to HEAD) caught by tree_fp_v2!
po_st=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER")
RDST=$(printf '%s\n' "$po_st" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDST" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDST" --slot s1 --attempt 1 --owner "$OWNER" --task-id tst --child-thread-id ctst >/dev/null
bash "$ST" record-result "$RDST" --slot s1 --attempt 1 --owner "$OWNER" --input "$F_CLEAN" >/dev/null
printf 'staged-only-secret-change\n' >> app.txt
git add app.txt
git show HEAD:app.txt > app.txt
# Now git diff HEAD is EMPTY, while git diff --cached is NON-EMPTY!
[ -z "$(git diff HEAD)" ] && [ -n "$(git diff --cached)" ] && ok || bad "staged-only fixture setup failed"
out_st=$(bash "$ST" finish "$RDST" --merged "$F_CLEAN"); rc=$?
expect "staged-only index change caught by tree_fp_v2" "3:tree-changed" "$rc:$(printf '%s\n' "$out_st" | kv REASON)"
git reset -q HEAD app.txt

# 6f. cr-tx.sh directory-target conflict fails closed AND preserves pending.tx!
SD=$(bash "$ST" paths | kv STATE_DIR)
TX_BAD="$SD/tx-dir-test"
mkdir -p "$TX_BAD" "$SD/rounds/999-test/verdict"
cp "$SD/ledger.md" "$TX_BAD/ledger.full"
cp "$SD/state" "$TX_BAD/state.full"
printf 'VERDICT=clean\n' > "$TX_BAD/verdict.out"
{
  printf 'tx_dir=%s\n' "$TX_BAD"
  printf 'tx_branch=%s\n' "$(git branch --show-current)"
  printf 'tx_kind=finish\n'
  printf 'tx_round_dir=%s/rounds/999-test\n' "$SD"
} > "$SD/pending.tx"
bash "$ST" init >/dev/null 2>&1
expect "cr-tx directory target conflict fails closed" "2" "$?"
[ -f "$SD/pending.tx" ] && ok || bad "cr-tx deleted pending.tx despite directory target conflict!"
rm -rf "$SD/pending.tx" "$TX_BAD" "$SD/rounds/999-test"

# --- 7. Round 2 hardening regressions ---

# 7a. config-show with empty --capabilities (0 models) MUST fail closed (CONFIG_VALID=0, exit 3)!
CAPS_EMPTY="$TMP/caps-empty.json"
printf '{"providers":[]}\n' > "$CAPS_EMPTY"
out_ec=$(bash "$ST" config-show --capabilities "$CAPS_EMPTY" 2>&1); rc=$?
expect "empty capabilities JSON rejects models fail-closed (exit 3, CONFIG_VALID=0)" "3:0" "$rc:$(printf '%s\n' "$out_ec" | kv CONFIG_VALID)"

# 7b. config-set rejects unified effortMode with empty effortKey member OR conflicting member effort!
cat > "$TMP/cfg-bad-unif-emptykey.json" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "codex"],
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "council": {
    "effortMode": "unified",
    "unifiedEffort": "high",
    "reviewers": [
      { "providerInstanceId": "antigravity", "model": "no-effort", "effortKey": "", "effort": "" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "" }
    ]
  }
}
EOF
bash "$ST" config-set --file "$TMP/cfg-bad-unif-emptykey.json" >/dev/null 2>&1
expect "config-set rejects unified effortMode with empty effortKey member" "2" "$?"

cat > "$TMP/cfg-bad-unif-conflict.json" <<'EOF'
{
  "version": 1,
  "authorizedProviders": ["antigravity", "codex"],
  "defaultReviewer": { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "high" },
  "council": {
    "effortMode": "unified",
    "unifiedEffort": "medium",
    "reviewers": [
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "high" }
    ]
  }
}
EOF
bash "$ST" config-set --file "$TMP/cfg-bad-unif-conflict.json" >/dev/null 2>&1
expect "config-set rejects unified effortMode with conflicting member effort" "2" "$?"

# 7c. init wires requireRebased/prAutoRebase AND persists --ignore-project-config across init/next!
cat > "$R/.t3-cr-loop.json" <<'EOF'
{
  "knobs": { "roundCap": 9, "requireRebased": 1, "prAutoRebase": 1 }
}
EOF
expect "project knob roundCap=9 active before ignore" "9" "$(bash "$ST" init | kv ROUND_CAP)"
out_ign_init=$(bash "$ST" init --ignore-project-config)
expect "init --ignore-project-config restores user knobs (roundCap=2, requireRebased=0)" "2:0:0:1" \
  "$(printf '%s\n' "$out_ign_init" | kv ROUND_CAP):$(printf '%s\n' "$out_ign_init" | kv REQUIRE_REBASED):$(printf '%s\n' "$out_ign_init" | kv PR_AUTO_REBASE):$(printf '%s\n' "$out_ign_init" | kv PROJECT_CONFIG_IGNORED)"
# Subsequent init WITHOUT flag inherits persisted ignore_project_config=1!
expect "persisted ignore_project_config survives resume init" "2:1" "$(bash "$ST" init | kv ROUND_CAP):$(bash "$ST" init | kv PROJECT_CONFIG_IGNORED)"
bash "$ST" init --use-project-config >/dev/null
expect "--use-project-config re-enables project roundCap=9" "9" "$(bash "$ST" init | kv ROUND_CAP)"
rm -f "$R/.t3-cr-loop.json"

# 7d. record-result refuses pre-existing directory at canonical result path (never marks completed_valid)!
po_dir=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER")
RDDIR=$(printf '%s\n' "$po_dir" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDDIR" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDDIR" --slot s1 --attempt 1 --owner "$OWNER" --task-id tdir --child-thread-id ctdir >/dev/null
mkdir -p "$RDDIR/result-s1-a1.json"
bash "$ST" record-result "$RDDIR" --slot s1 --attempt 1 --owner "$OWNER" --task-id tdir --input "$F_CLEAN" >/dev/null 2>&1
expect "record-result rejects directory conflict at result-s1-a1.json" "2" "$?"
expect "slot NOT marked completed_valid after dir conflict" "0" "$(bash "$ST" round-summary "$RDDIR" | kv VALID_SLOTS)"
rmdir "$RDDIR/result-s1-a1.json"
bash "$ST" cancel-round "$RDDIR" --owner "$OWNER" >/dev/null

# 7e. Single-reviewer & council finish CANNOT settle blocking P1 finding as clean (without evidenced --dismissed-findings)!
F_P1_SLOT="$TMP/p1-slot.json"
cat > "$F_P1_SLOT" <<'EOF'
{
  "summary": "Real P1 bug found.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1",
      "reopens": "",
      "title": "Race condition in lock",
      "location": "app.txt:1",
      "pattern": "Unprotected write",
      "still_wrong": "",
      "instances": ["app.txt:1"],
      "fix": "Acquire flock",
      "prevent": "Concurrency test"
    }
  ],
  "step_back": [],
  "out_of_scope": []
}
EOF
po_b1=$(bash "$ST" prepare --purpose full --mode full --base main --slots s1 --owner "$OWNER")
RDB1=$(printf '%s\n' "$po_b1" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDB1" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDB1" --slot s1 --attempt 1 --owner "$OWNER" --task-id tb1 --child-thread-id ctb1 >/dev/null
bash "$ST" record-result "$RDB1" --slot s1 --attempt 1 --owner "$OWNER" --task-id tb1 --input "$F_P1_SLOT" >/dev/null
out_fake=$(bash "$ST" finish "$RDB1" --merged "$F_CLEAN"); rc=$?
expect "single-reviewer P1 CANNOT be settled as clean" "5:error" "$rc:$(printf '%s\n' "$out_fake" | kv VERDICT)"
# Omitting --merged directly consumes recorded single slot result -> dirty!
out_auto=$(bash "$ST" finish "$RDB1"); rc=$?
expect "single-reviewer auto-consumes recorded P1 -> dirty" "0:dirty:1" "$rc:$(printf '%s\n' "$out_auto" | kv VERDICT):$(printf '%s\n' "$out_auto" | kv P1)"

# Council: s1 reports P1, s2 reports clean -> clean merged rejected without --dismissed-findings, accepted with code_evidence!
po_b2=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2 --owner "$OWNER")
RDB2=$(printf '%s\n' "$po_b2" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDB2" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDB2" --slot s1 --attempt 1 --owner "$OWNER" --task-id tb2a --child-thread-id ctb2a >/dev/null
bash "$ST" record-result "$RDB2" --slot s1 --attempt 1 --owner "$OWNER" --task-id tb2a --input "$F_P1_SLOT" >/dev/null
bash "$ST" claim-slot "$RDB2" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDB2" --slot s2 --attempt 1 --owner "$OWNER" --task-id tb2b --child-thread-id ctb2b >/dev/null
bash "$ST" record-result "$RDB2" --slot s2 --attempt 1 --owner "$OWNER" --task-id tb2b --input "$F_CLEAN" >/dev/null
out_drop=$(bash "$ST" finish "$RDB2" --merged "$F_CLEAN"); rc=$?
expect "council finish rejects silently dropping P1 finding to clean" "5:error" "$rc:$(printf '%s\n' "$out_drop" | kv VERDICT)"
cat > "$TMP/dismissed-p1.json" <<'EOF'
[{ "slot": "s1", "title": "Race condition in lock", "severity": "P1", "code_evidence": "app.txt:1 is immutable constant" }]
EOF
out_dism=$(bash "$ST" finish "$RDB2" --merged "$F_CLEAN" --dismissed-findings "$TMP/dismissed-p1.json"); rc=$?
expect "council finish accepts evidenced --dismissed-findings" "0:clean" "$rc:$(printf '%s\n' "$out_dism" | kv VERDICT)"

# 7f. mark-converged emits immutable BASE_SHA and release-state get exposes CONVERGED_BASE_SHA!
run_single_round confirmation-full full main "$F_CLEAN" >/dev/null
out_mc=$(bash "$ST" mark-converged --base main)
expect "t3 mark-converged emits immutable BASE_SHA" "$BASE_SHA" "$(printf '%s\n' "$out_mc" | kv BASE_SHA)"
expect "t3 release-state get exposes CONVERGED_BASE_SHA" "$BASE_SHA" "$(bash "$ST" release-state get | kv CONVERGED_BASE_SHA)"

# 7g. tree_fp_v2 catches a SECOND edit inside an already-dirty tracked submodule!
SUB_SRC="$TMP/sub-src"
mkdir -p "$SUB_SRC"
(
  cd "$SUB_SRC" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'v1\n' > sub.txt && git add sub.txt && git commit -qm s1
)
SUB_HOST="$TMP/sub-host"
mkdir -p "$SUB_HOST"
(
  cd "$SUB_HOST" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'h1\n' > host.txt && git add host.txt && git commit -qm h1
  git -c protocol.file.allow=always submodule -q add "$SUB_SRC" vendor/sub >/dev/null 2>&1
  git commit -qm "add sub"
  git switch -qc feat/sub
  printf 'h2\n' >> host.txt && git commit -qam h2
  printf 'sub-dirty-1\n' >> vendor/sub/sub.txt
  po_sm=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER")
  RDSM=$(printf '%s\n' "$po_sm" | kv ROUND_DIR)
  bash "$ST" claim-slot "$RDSM" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
  bash "$ST" record-dispatch "$RDSM" --slot s1 --attempt 1 --owner "$OWNER" --task-id tsm --child-thread-id ctsm >/dev/null
  bash "$ST" record-result "$RDSM" --slot s1 --attempt 1 --owner "$OWNER" --task-id tsm --input "$F_CLEAN" >/dev/null
  # Second edit to SAME already-dirty submodule file!
  printf 'sub-dirty-2\n' >> vendor/sub/sub.txt
  out_sm=$(bash "$ST" finish "$RDSM" --merged "$F_CLEAN"); rc_sm=$?
  [ "$rc_sm" -eq 3 ] && [ "$(printf '%s\n' "$out_sm" | kv REASON)" = "tree-changed" ]
) && ok || bad "t3 tree_fp_v2 missed 2nd edit inside already-dirty tracked submodule!"

# =============================================================================
# 8. Round 3 Hardening Regressions (TOCTOU snapshot, 1-to-1 council & step_back,
#    config-show persisted ignore-project-config, SIGTERM UNBORN trap, unborn stderr)
# =============================================================================

# 8a. Persisted --ignore-project-config propagates to bare config-show (no flag needed)!
cat > "$R/.t3-cr-loop.json" <<'EOF'
{
  "version": 1,
  "defaultReviewer": { "providerInstanceId": "projOnlyProvider", "model": "proj-model-1", "effortKey": "effort", "effort": "high" },
  "knobs": { "roundCap": 9 }
}
EOF
bash "$ST" init --ignore-project-config >/dev/null
out_cs_ign=$(bash "$ST" config-show)
expect "bare config-show inherits persisted ignore_project_config (user reviewer, no auth prompt)" "1:codex:0" \
  "$(printf '%s\n' "$out_cs_ign" | kv PROJECT_CONFIG_IGNORED):$(printf '%s\n' "$out_cs_ign" | kv DEFAULT_PROVIDER):$(printf '%s\n' "$out_cs_ign" | kv NEEDS_PROVIDER_AUTH)"
out_cs_use=$(bash "$ST" config-show --use-project-config)
expect "config-show --use-project-config overrides persisted ignore" "projOnlyProvider:1" \
  "$(printf '%s\n' "$out_cs_use" | kv DEFAULT_PROVIDER):$(printf '%s\n' "$out_cs_use" | kv NEEDS_PROVIDER_AUTH)"
bash "$ST" init --use-project-config >/dev/null
rm -f "$R/.t3-cr-loop.json"

# 8b. record-result rejects symlink input and finish single-snapshot keeps verdict & archived JSON identical!
po_toctou=$(bash "$ST" prepare --purpose full --mode full --base main --slots s1 --owner "$OWNER")
RDT=$(printf '%s\n' "$po_toctou" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDT" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDT" --slot s1 --attempt 1 --owner "$OWNER" --task-id ttoc --child-thread-id cttoc >/dev/null
ln -sf "$F_CLEAN" "$TMP/sym-input.json"
bash "$ST" record-result "$RDT" --slot s1 --attempt 1 --owner "$OWNER" --task-id ttoc --input "$TMP/sym-input.json" >/dev/null 2>&1
expect "record-result rejects symlink --input" "2" "$?"
rm -f "$TMP/sym-input.json"
bash "$ST" record-result "$RDT" --slot s1 --attempt 1 --owner "$OWNER" --task-id ttoc --input "$F_P1_SLOT" >/dev/null
# Concurrently swap external merged file between clean and P1 while finish runs:
# single-snapshot invariant guarantees VERDICT=clean can NEVER coexist with P1 archived JSON!
RACE_F="$TMP/race-merged.json"
cp "$F_CLEAN" "$RACE_F"
(
  for _k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    cp "$F_P1_SLOT" "$RACE_F" 2>/dev/null || true
    cp "$F_CLEAN" "$RACE_F" 2>/dev/null || true
  done
) &
RACE_PID=$!
out_race=$(bash "$ST" finish "$RDT" --merged "$RACE_F" 2>/dev/null); rc_race=$?
wait "$RACE_PID" 2>/dev/null || true
v_race=$(printf '%s\n' "$out_race" | kv VERDICT)
if [ "$v_race" = "clean" ]; then
  bad "single-reviewer P1 settled as clean during TOCTOU race!"
else
  ok
fi
# Clean up unfinished round if race hit clean snapshot and errored (expected!)
if [ "$rc_race" -ne 0 ]; then
  bash "$ST" finish "$RDT" >/dev/null
fi

# 8c. Council 1-to-1 per-finding binding: 2 independent P1 findings from 1 slot CANNOT collapse into 1 merged P1!
F_TWO_P1="$TMP/two-p1-slot.json"
cat > "$F_TWO_P1" <<'EOF'
{
  "summary": "Two distinct P1 bugs.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1"
    },
    {
      "severity": "P1", "reopens": "", "title": "Bug Two", "location": "app.txt:2",
      "pattern": "p2", "still_wrong": "", "instances": ["app.txt:2"], "fix": "f2", "prevent": "t2"
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
F_ONE_P1_DOUBLE_SRC="$TMP/one-p1-double-src.json"
cat > "$F_ONE_P1_DOUBLE_SRC" <<'EOF'
{
  "summary": "Dropped Bug Two.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1",
      "sources": ["s1", "codex/gpt-6.2-sol"]
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
F_TWO_P1_MERGED="$TMP/two-p1-merged.json"
cat > "$F_TWO_P1_MERGED" <<'EOF'
{
  "summary": "Kept both P1 bugs.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1",
      "sources": ["codex/gpt-6.2-sol"],
      "merged_from": [{ "slot": "s1", "index": 0 }]
    },
    {
      "severity": "P1", "reopens": "", "title": "Bug Two", "location": "app.txt:2",
      "pattern": "p2", "still_wrong": "", "instances": ["app.txt:2"], "fix": "f2", "prevent": "t2",
      "sources": ["codex/gpt-6.2-sol"],
      "merged_from": [{ "slot": "s1", "index": 1 }]
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
po_2p1=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2 --owner "$OWNER")
RD2P1=$(printf '%s\n' "$po_2p1" | kv ROUND_DIR)
bash "$ST" claim-slot "$RD2P1" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2P1" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2p1a --child-thread-id ct2p1a >/dev/null
bash "$ST" record-result "$RD2P1" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2p1a --input "$F_TWO_P1" >/dev/null
bash "$ST" claim-slot "$RD2P1" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2P1" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2p1b --child-thread-id ct2p1b >/dev/null
bash "$ST" record-result "$RD2P1" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2p1b --input "$F_CLEAN" >/dev/null
out_collapse=$(bash "$ST" finish "$RD2P1" --merged "$F_ONE_P1_DOUBLE_SRC"); rc=$?
expect "council rejects collapsing 2 same-severity P1 findings from 1 slot into 1" "5:error" "$rc:$(printf '%s\n' "$out_collapse" | kv VERDICT)"
# Round 4 High #2: duplicate copies of Bug One (exact or tweaked) CANNOT substitute for independent Bug Two!
F_TWO_P1_DUP="$TMP/two-p1-dup.json"
cat > "$F_TWO_P1_DUP" <<'EOF'
{
  "summary": "Duplicated Bug One twice to drop Bug Two.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1",
      "sources": ["s1"]
    },
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1",
      "sources": ["s1"]
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
F_TWO_P1_DUP_TWEAK="$TMP/two-p1-dup-tweak.json"
cat > "$F_TWO_P1_DUP_TWEAK" <<'EOF'
{
  "summary": "Tweaked duplicate of Bug One to drop Bug Two.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Bug One", "location": "app.txt:1",
      "pattern": "p1", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1", "prevent": "t1",
      "sources": ["s1"]
    },
    {
      "severity": "P1", "reopens": "", "title": "Bug One copy", "location": "app.txt:1",
      "pattern": "p1 copy", "still_wrong": "", "instances": ["app.txt:1"], "fix": "f1 copy", "prevent": "t1",
      "sources": ["s1"]
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
out_dup1=$(bash "$ST" finish "$RD2P1" --merged "$F_TWO_P1_DUP"); rc=$?
expect "council rejects substituting 2 exact copies of Bug One for [Bug One, Bug Two]" "5:error" "$rc:$(printf '%s\n' "$out_dup1" | kv VERDICT)"
out_dup2=$(bash "$ST" finish "$RD2P1" --merged "$F_TWO_P1_DUP_TWEAK"); rc=$?
expect "council rejects substituting tweaked copy of Bug One for [Bug One, Bug Two]" "5:error" "$rc:$(printf '%s\n' "$out_dup2" | kv VERDICT)"
out_both=$(bash "$ST" finish "$RD2P1" --merged "$F_TWO_P1_MERGED"); rc=$?
expect "council accepts preserving both P1 findings 1-to-1" "0:dirty:2" "$rc:$(printf '%s\n' "$out_both" | kv VERDICT):$(printf '%s\n' "$out_both" | kv P1)"

# 8d. Council 1-to-1 step_back[] proposal binding: 2 step_back proposals CANNOT collapse into 1!
F_TWO_SB="$TMP/two-sb-slot.json"
cat > "$F_TWO_SB" <<'EOF'
{
  "summary": "Two structural proposals.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Proposal A", "invites_because": "a", "approach_change": "x", "prevent": "t1" },
    { "classes": ["C2"], "name": "Proposal B", "invites_because": "b", "approach_change": "y", "prevent": "t2" }
  ],
  "out_of_scope": []
}
EOF
F_ONE_SB_MERGED="$TMP/one-sb-merged.json"
cat > "$F_ONE_SB_MERGED" <<'EOF'
{
  "summary": "Dropped Proposal B.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Proposal A", "invites_because": "a", "approach_change": "x", "prevent": "t1", "sources": ["s1"] }
  ],
  "out_of_scope": []
}
EOF
F_TWO_SB_MERGED="$TMP/two-sb-merged.json"
cat > "$F_TWO_SB_MERGED" <<'EOF'
{
  "summary": "Kept both proposals.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Proposal A", "invites_because": "a", "approach_change": "x", "prevent": "t1", "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 0 }] },
    { "classes": ["C2"], "name": "Proposal B", "invites_because": "b", "approach_change": "y", "prevent": "t2", "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 1 }] }
  ],
  "out_of_scope": []
}
EOF
po_2sb=$(bash "$ST" prepare --purpose step-back --mode step-back --base main --slots s1,s2 --owner "$OWNER")
RD2SB=$(printf '%s\n' "$po_2sb" | kv ROUND_DIR)
bash "$ST" claim-slot "$RD2SB" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2SB" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2sba --child-thread-id ct2sba >/dev/null
bash "$ST" record-result "$RD2SB" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2sba --input "$F_TWO_SB" >/dev/null
bash "$ST" claim-slot "$RD2SB" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2SB" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2sbb --child-thread-id ct2sbb >/dev/null
bash "$ST" record-result "$RD2SB" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2sbb --input "$F_CLEAN" >/dev/null
out_sb1=$(bash "$ST" finish "$RD2SB" --merged "$F_ONE_SB_MERGED"); rc=$?
expect "council rejects dropping 1 of 2 step_back[] proposals" "5:error" "$rc:$(printf '%s\n' "$out_sb1" | kv VERDICT)"
out_sb2=$(bash "$ST" finish "$RD2SB" --merged "$F_TWO_SB_MERGED"); rc=$?
expect "council accepts preserving both step_back[] proposals 1-to-1" "0:clean" "$rc:$(printf '%s\n' "$out_sb2" | kv VERDICT)"

# Round 4 High #2 (step_back): 2 independent proposals covering the SAME class C1 CANNOT be replaced by 2 copies of Proposal X!
F_TWO_SB_SAME_CLS="$TMP/two-sb-same-cls.json"
cat > "$F_TWO_SB_SAME_CLS" <<'EOF'
{
  "summary": "Two independent proposals for C1.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Split FSM table", "invites_because": "a", "approach_change": "extract explicit state table", "prevent": "t1" },
    { "classes": ["C1"], "name": "Enforce lock order", "invites_because": "b", "approach_change": "acquire repo lock before task lock", "prevent": "t2" }
  ],
  "out_of_scope": []
}
EOF
F_TWO_SB_SAME_DUP="$TMP/two-sb-same-dup.json"
cat > "$F_TWO_SB_SAME_DUP" <<'EOF'
{
  "summary": "Substituted two copies of Proposal 1.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Split FSM table", "invites_because": "a", "approach_change": "extract explicit state table", "prevent": "t1", "sources": ["s1"] },
    { "classes": ["C1"], "name": "Split FSM table v2", "invites_because": "a", "approach_change": "extract explicit state table v2", "prevent": "t1", "sources": ["s1"] }
  ],
  "out_of_scope": []
}
EOF
F_TWO_SB_SAME_OK="$TMP/two-sb-same-ok.json"
cat > "$F_TWO_SB_SAME_OK" <<'EOF'
{
  "summary": "Preserved both proposals for C1.",
  "verdict": "clean",
  "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Split FSM table", "invites_because": "a", "approach_change": "extract explicit state table", "prevent": "t1", "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 0 }] },
    { "classes": ["C1"], "name": "Enforce lock order", "invites_because": "b", "approach_change": "acquire repo lock before task lock", "prevent": "t2", "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 1 }] }
  ],
  "out_of_scope": []
}
EOF
po_2sb_same=$(bash "$ST" prepare --purpose step-back --mode step-back --base main --slots s1,s2 --owner "$OWNER")
RD2SBS=$(printf '%s\n' "$po_2sb_same" | kv ROUND_DIR)
bash "$ST" claim-slot "$RD2SBS" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2SBS" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2sbsa --child-thread-id ct2sbsa >/dev/null
bash "$ST" record-result "$RD2SBS" --slot s1 --attempt 1 --owner "$OWNER" --task-id t2sbsa --input "$F_TWO_SB_SAME_CLS" >/dev/null
bash "$ST" claim-slot "$RD2SBS" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RD2SBS" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2sbsb --child-thread-id ct2sbsb >/dev/null
bash "$ST" record-result "$RD2SBS" --slot s2 --attempt 1 --owner "$OWNER" --task-id t2sbsb --input "$F_CLEAN" >/dev/null
out_sbs_dup=$(bash "$ST" finish "$RD2SBS" --merged "$F_TWO_SB_SAME_DUP"); rc=$?
expect "council rejects substituting 2 copies of Proposal 1 for 2 independent same-class step_back[] proposals" "5:error" "$rc:$(printf '%s\n' "$out_sbs_dup" | kv VERDICT)"
out_sbs_ok=$(bash "$ST" finish "$RD2SBS" --merged "$F_TWO_SB_SAME_OK"); rc=$?
expect "council accepts preserving both independent same-class step_back[] proposals" "0:clean" "$rc:$(printf '%s\n' "$out_sbs_ok" | kv VERDICT)"

# 8f. Round 5 High #1: leading '-' filename and Perl '-e...' switch-injection filename MUST NOT execute code or fail!
DASH_REPO="$TMP/dash-input-repo"
mkdir -p "$DASH_REPO"
(
  cd "$DASH_REPO" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'x\n' > app.txt && git add app.txt && git commit -qm init
  git switch -qc feat/dash
  printf 'y\n' >> app.txt && git commit -qam change
  bash "$ST" init >/dev/null
  po_d=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2 --owner "$OWNER")
  RDD=$(printf '%s\n' "$po_d" | kv ROUND_DIR)
  bash "$ST" claim-slot "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
  bash "$ST" record-dispatch "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --task-id td1 --child-thread-id ctd1 >/dev/null
  cp -- "$F_CLEAN" "-review.json"
  bash "$ST" record-result "$RDD" --slot s1 --attempt 1 --owner "$OWNER" --task-id td1 --input "-review.json" >/dev/null || exit 31
  bash "$ST" claim-slot "$RDD" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
  bash "$ST" record-dispatch "$RDD" --slot s2 --attempt 1 --owner "$OWNER" --task-id td2 --child-thread-id ctd2 >/dev/null
  POC_NAME='-eBEGIN{open(my $f,">","INJECTED_RCE");print $f "bad";close $f;exit 9}'
  cp -- "$F_CLEAN" "$POC_NAME"
  bash "$ST" record-result "$RDD" --slot s2 --attempt 1 --owner "$OWNER" --task-id td2 --input "$POC_NAME" >/dev/null || exit 32
  [ ! -e "INJECTED_RCE" ] || exit 33
) && ok || bad "leading-dash or -e switch filename failed or executed Perl code in record-result"

# 8g. Round 5 High #3: different root causes on the SAME line CANNOT merge into one entry; same-name distinct step_back[] proposals CAN coexist!
F_AUTH_S1="$TMP/auth-s1.json"
cat > "$F_AUTH_S1" <<'EOF'
{
  "summary": "Missing auth check.",
  "verdict": "findings",
  "findings": [{
    "severity": "P1", "reopens": "", "title": "Missing auth check", "location": "app.txt:1",
    "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "",
    "instances": ["app.txt:1"], "fix": "verify session token before handler", "prevent": "add authz test"
  }],
  "step_back": [], "out_of_scope": []
}
EOF
F_STREAM_S2="$TMP/stream-s2.json"
cat > "$F_STREAM_S2" <<'EOF'
{
  "summary": "Stream leak on error path.",
  "verdict": "findings",
  "findings": [{
    "severity": "P1", "reopens": "", "title": "Stream not closed", "location": "app.txt:1",
    "pattern": "file stream leaks descriptor on error return path", "still_wrong": "",
    "instances": ["app.txt:1"], "fix": "close stream handle in finally block", "prevent": "add leak test"
  }],
  "step_back": [], "out_of_scope": []
}
EOF
F_BAD_CROSS_MERGE="$TMP/bad-cross-merge.json"
cat > "$F_BAD_CROSS_MERGE" <<'EOF'
{
  "summary": "Improperly collapsed auth and stream leak.",
  "verdict": "findings",
  "findings": [{
    "severity": "P1", "reopens": "", "title": "Missing auth check", "location": "app.txt:1",
    "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "",
    "instances": ["app.txt:1"], "fix": "verify session token before handler", "prevent": "add authz test",
    "sources": ["s1", "s2"],
    "merged_from": [{ "slot": "s1", "index": 0 }, { "slot": "s2", "index": 0 }],
    "merge_rationale": "same line app.txt:1"
  }],
  "step_back": [], "out_of_scope": []
}
EOF
F_GOOD_CROSS_SEP="$TMP/good-cross-sep.json"
cat > "$F_GOOD_CROSS_SEP" <<'EOF'
{
  "summary": "Kept both distinct root causes on app.txt:1.",
  "verdict": "findings",
  "findings": [
    {
      "severity": "P1", "reopens": "", "title": "Missing auth check", "location": "app.txt:1",
      "pattern": "handler accepts unauthenticated request without authz guard", "still_wrong": "",
      "instances": ["app.txt:1"], "fix": "verify session token before handler", "prevent": "add authz test",
      "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 0 }]
    },
    {
      "severity": "P1", "reopens": "", "title": "Stream not closed", "location": "app.txt:1",
      "pattern": "file stream leaks descriptor on error return path", "still_wrong": "",
      "instances": ["app.txt:1"], "fix": "close stream handle in finally block", "prevent": "add leak test",
      "sources": ["s2"], "merged_from": [{ "slot": "s2", "index": 0 }]
    }
  ],
  "step_back": [], "out_of_scope": []
}
EOF
po_h3=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1,s2 --owner "$OWNER")
RDH3=$(printf '%s\n' "$po_h3" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDH3" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDH3" --slot s1 --attempt 1 --owner "$OWNER" --task-id th3a --child-thread-id cth3a >/dev/null
bash "$ST" record-result "$RDH3" --slot s1 --attempt 1 --owner "$OWNER" --task-id th3a --input "$F_AUTH_S1" >/dev/null
bash "$ST" claim-slot "$RDH3" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDH3" --slot s2 --attempt 1 --owner "$OWNER" --task-id th3b --child-thread-id cth3b >/dev/null
bash "$ST" record-result "$RDH3" --slot s2 --attempt 1 --owner "$OWNER" --task-id th3b --input "$F_STREAM_S2" >/dev/null
out_h3_bad=$(bash "$ST" finish "$RDH3" --merged "$F_BAD_CROSS_MERGE"); rc=$?
expect "council rejects merging different root causes (auth vs stream leak) on the same line" "5:error" "$rc:$(printf '%s\n' "$out_h3_bad" | kv VERDICT)"
out_h3_ok=$(bash "$ST" finish "$RDH3" --merged "$F_GOOD_CROSS_SEP"); rc=$?
expect "council accepts keeping both distinct same-line root causes separately" "0:dirty:2" "$rc:$(printf '%s\n' "$out_h3_ok" | kv VERDICT):$(printf '%s\n' "$out_h3_ok" | kv P1)"

F_SB_NAME_S1="$TMP/sb-same-name-s1.json"
cat > "$F_SB_NAME_S1" <<'EOF'
{
  "summary": "Centralize HTTP error handling.", "verdict": "clean", "findings": [],
  "step_back": [{ "classes": ["C1"], "name": "Refactor error handling", "invites_because": "scattered", "approach_change": "centralize error middleware at HTTP gateway boundary", "prevent": "t1" }],
  "out_of_scope": []
}
EOF
F_SB_NAME_S2="$TMP/sb-same-name-s2.json"
cat > "$F_SB_NAME_S2" <<'EOF'
{
  "summary": "Worker boundary retries.", "verdict": "clean", "findings": [],
  "step_back": [{ "classes": ["C1"], "name": "Refactor error handling", "invites_because": "retries lost", "approach_change": "handle retries explicitly at each worker queue boundary", "prevent": "t2" }],
  "out_of_scope": []
}
EOF
F_SB_NAME_BAD="$TMP/sb-same-name-bad.json"
cat > "$F_SB_NAME_BAD" <<'EOF'
{
  "summary": "Collapsed same-name proposals.", "verdict": "clean", "findings": [],
  "step_back": [{
    "classes": ["C1"], "name": "Refactor error handling", "invites_because": "scattered",
    "approach_change": "centralize error middleware at HTTP gateway boundary", "prevent": "t1",
    "sources": ["s1", "s2"],
    "merged_from": [{ "slot": "s1", "index": 0 }, { "slot": "s2", "index": 0 }],
    "merge_rationale": "same proposal name"
  }],
  "out_of_scope": []
}
EOF
F_SB_NAME_OK="$TMP/sb-same-name-ok.json"
cat > "$F_SB_NAME_OK" <<'EOF'
{
  "summary": "Kept both same-name proposals with distinct approaches.", "verdict": "clean", "findings": [],
  "step_back": [
    { "classes": ["C1"], "name": "Refactor error handling", "invites_because": "scattered", "approach_change": "centralize error middleware at HTTP gateway boundary", "prevent": "t1", "sources": ["s1"], "merged_from": [{ "slot": "s1", "index": 0 }] },
    { "classes": ["C1"], "name": "Refactor error handling", "invites_because": "retries lost", "approach_change": "handle retries explicitly at each worker queue boundary", "prevent": "t2", "sources": ["s2"], "merged_from": [{ "slot": "s2", "index": 0 }] }
  ],
  "out_of_scope": []
}
EOF
po_sbn=$(bash "$ST" prepare --purpose step-back --mode step-back --base main --slots s1,s2 --owner "$OWNER")
RDSBN=$(printf '%s\n' "$po_sbn" | kv ROUND_DIR)
bash "$ST" claim-slot "$RDSBN" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDSBN" --slot s1 --attempt 1 --owner "$OWNER" --task-id tsbn1 --child-thread-id ctsbn1 >/dev/null
bash "$ST" record-result "$RDSBN" --slot s1 --attempt 1 --owner "$OWNER" --task-id tsbn1 --input "$F_SB_NAME_S1" >/dev/null
bash "$ST" claim-slot "$RDSBN" --slot s2 --attempt 1 --owner "$OWNER" --provider antigravity --model gemini-4-neon --options-json '{}' >/dev/null
bash "$ST" record-dispatch "$RDSBN" --slot s2 --attempt 1 --owner "$OWNER" --task-id tsbn2 --child-thread-id ctsbn2 >/dev/null
bash "$ST" record-result "$RDSBN" --slot s2 --attempt 1 --owner "$OWNER" --task-id tsbn2 --input "$F_SB_NAME_S2" >/dev/null
out_sbn_bad=$(bash "$ST" finish "$RDSBN" --merged "$F_SB_NAME_BAD"); rc=$?
expect "council rejects collapsing same-name step_back[] proposals with different approach_change" "5:error" "$rc:$(printf '%s\n' "$out_sbn_bad" | kv VERDICT)"
out_sbn_ok=$(bash "$ST" finish "$RDSBN" --merged "$F_SB_NAME_OK"); rc=$?
expect "council accepts keeping same-name step_back[] proposals with distinct approach_change" "0:clean" "$rc:$(printf '%s\n' "$out_sbn_ok" | kv VERDICT)"

# 8e. SIGTERM on submodule git rev-parse HEAD fails closed & unborn nested gitdir leaks ZERO stderr!
SIG_BIN="$TMP/t3-git-sigterm"
mkdir -p "$SIG_BIN"
REAL_GIT=$(command -v git)
cat > "$SIG_BIN/git" <<EOF
#!/usr/bin/env bash
is_sub=0; is_rp=0; is_head=0
for arg in "\$@"; do
  case "\$arg" in
    *vendor/sub*) is_sub=1 ;;
    rev-parse) is_rp=1 ;;
    HEAD) is_head=1 ;;
  esac
done
if [ "\$is_sub" = 1 ] && [ "\$is_rp" = 1 ] && [ "\$is_head" = 1 ]; then
  kill -TERM \$\$
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SIG_BIN/git"
(
  cd "$SUB_HOST" || exit 2
  PATH="$SIG_BIN:$PATH" bash "$ST" prepare --purpose full --mode full --base main --slots s1 --owner "$OWNER" >/dev/null 2>&1
)
[ "$?" -ne 0 ] && ok || bad "t3 prepare exited 0 despite SIGTERM on submodule rev-parse HEAD!"

UNB_HOST="$TMP/t3-unborn-host"
mkdir -p "$UNB_HOST/nested-unb"
(
  cd "$UNB_HOST" || exit 2
  git init -q -b main . && git config user.email t@example.invalid && git config user.name t
  printf 'h1\n' > h.txt && git add h.txt && git commit -qm h1
  git switch -qc feat/unb
  printf 'h2\n' >> h.txt && git commit -qam h2
  (cd nested-unb && git init -q -b main .)
  printf 'u1\n' > nested-unb/x.txt
  err_u=$(bash "$ST" prepare --purpose initial-full --mode full --base main --slots s1 --owner "$OWNER" 2>&1 >/dev/null)
  rc_u=$?
  [ "$rc_u" -eq 0 ] && ! printf '%s' "$err_u" | grep -q "fatal: Needed a single revision"
) && ok || bad "t3 prepare leaked unborn stderr or failed on unborn nested gitdir"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
