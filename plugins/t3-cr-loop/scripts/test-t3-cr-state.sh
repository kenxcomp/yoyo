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
printf '```json\n{"summary":"all good","verdict":"clean","findings":[],"step_back":[],"out_of_scope":[]}\n```\n' > "$F_FENCED"
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
      "pattern": "Unchecked access",
      "still_wrong": "",
      "instances": ["app.txt:1", "app.txt:2"],
      "fix": "Validate at boundary",
      "prevent": "Add invariant test",
      "sources": ["antigravity/gemini-4-neon", "claudeAgent/claude-opus-5-5"]
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
bash "$ST" record-result "$RD1" --slot s2 --attempt 2 --owner "$OWNER" --input "$F_CLEAN" >/dev/null
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

run_single_round() { # run_single_round <purpose> <mode> <base> <merged_file> [since]
  local p="$1" m="$2" b="$3" mf="$4" s="${5:-}"
  local po rd
  po=$(bash "$ST" prepare --purpose "$p" --mode "$m" --base "$b" ${s:+--since "$s"} --slots s1 --owner "$OWNER") || return 9
  rd=$(printf '%s\n' "$po" | kv ROUND_DIR)
  bash "$ST" claim-slot "$rd" --slot s1 --attempt 1 --owner "$OWNER" --provider codex --model gpt-6.2-sol --options-json '{"reasoningEffort":"high"}' >/dev/null || return 9
  bash "$ST" record-dispatch "$rd" --slot s1 --attempt 1 --owner "$OWNER" --task-id "t-$rd" --child-thread-id "ct-$rd" >/dev/null || return 9
  bash "$ST" record-result "$rd" --slot s1 --attempt 1 --owner "$OWNER" --input "$F_CLEAN" >/dev/null || return 9
  bash "$ST" finish "$rd" --merged "$mf"
}

for i in 1 2; do
  printf 'fix %s\n' "$i" >> app.txt && git commit -qam "fix $i"
  nx=$(bash "$ST" next --base main)
  expect "incremental default round $i" "incremental:default" "$(printf '%s\n' "$nx" | kv PURPOSE):$(printf '%s\n' "$nx" | kv PROFILE)"
  out_i=$(run_single_round incremental incremental main "$F_REOPEN_MERGED" "$(printf '%s\n' "$nx" | kv SINCE)")
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
      { "providerInstanceId": "antigravity", "model": "gemini-4-neon", "effortKey": "thought_level", "effort": "high" },
      { "providerInstanceId": "codex", "model": "gpt-6.2-sol", "effortKey": "reasoningEffort", "effort": "ultra" }
    ]
  },
  "knobs": { "roundCap": 2, "maxStepBacks": 0, "skipP3": 1 }
}
EOF
bash "$ST" config-set --file "$TMP/cfg-stale-eff.json" >/dev/null
out_ue=$(bash "$ST" config-show --capabilities "$CAPS")
expect "unifiedEffort medium applied to council slot 1" 'antigravity|gemini-4-neon|thought_level|medium|{"thought_level":"medium"}' "$(printf '%s\n' "$out_ue" | kv COUNCIL_SLOT_1)"
expect "unifiedEffort medium applied to council slot 2" 'codex|gpt-6.2-sol|reasoningEffort|medium|{"reasoningEffort":"medium"}' "$(printf '%s\n' "$out_ue" | kv COUNCIL_SLOT_2)"
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

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
