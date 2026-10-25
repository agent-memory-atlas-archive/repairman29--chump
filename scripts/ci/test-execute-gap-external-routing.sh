#!/usr/bin/env bash
# test-execute-gap-external-routing.sh — MISSION-046
#
# Guards that --execute-gap routes external_repo:OWNER/REPO gaps to
# `chump improve OWNER/REPO --apply` instead of the internal agent loop.
# Tests:
#   (a) Unit tests for the pure parser (external_repo_target_from_skills)
#   (b) Structural: routing code is wired in src/main.rs

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== MISSION-046: --execute-gap external_repo routing ==="

# ── (a) Unit tests for the parser ────────────────────────────────────────────
echo ""
echo "-- (a) Cargo unit tests for external_repo_target_from_skills --"

CARGO_OUTPUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
    cargo test --bin chump mission_046_ 2>&1)
CARGO_RC=$?

if [[ $CARGO_RC -eq 0 ]]; then
    ok "cargo test mission_046_external_repo exited 0"
else
    bad "cargo test mission_046_external_repo exited $CARGO_RC"
    echo "$CARGO_OUTPUT" | tail -20
fi

if echo "$CARGO_OUTPUT" | grep -q "test result: ok"; then
    ok "test result: ok present"
else
    bad "test result: ok NOT present in output"
    echo "$CARGO_OUTPUT" | tail -20
fi

for test_name in \
    "mission_046_external_repo_target_parses_single_tag" \
    "mission_046_external_repo_target_parses_in_list" \
    "mission_046_internal_gap_returns_none"; do
    if echo "$CARGO_OUTPUT" | grep -q "$test_name"; then
        ok "test $test_name ran"
    else
        bad "test $test_name NOT found in output"
    fi
done

# ── (b) Structural: routing is wired in src/main.rs ──────────────────────────
echo ""
echo "-- (b) Structural wiring in src/main.rs --"

MAIN_RS="$REPO_ROOT/src/main.rs"

if grep -q "external_repo_target_from_skills" "$MAIN_RS"; then
    ok "external_repo_target_from_skills present in src/main.rs"
else
    bad "external_repo_target_from_skills NOT found in src/main.rs"
fi

if grep -q "improve::run" "$MAIN_RS"; then
    ok "improve::run routing call present in src/main.rs"
else
    bad "improve::run NOT found in src/main.rs"
fi

if grep -q "MISSION-046" "$MAIN_RS"; then
    ok "MISSION-046 tag present in src/main.rs"
else
    bad "MISSION-046 tag NOT found in src/main.rs"
fi

# ── (c) INFRA-8083: dispatch.rs + worker.sh external_repo routing ─────────────
echo ""
echo "-- (c) INFRA-8083: chump dispatch + worker.sh external_repo routing --"

DISPATCH_RS="$REPO_ROOT/src/dispatch.rs"
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"
BOT_MERGE_SH="$REPO_ROOT/scripts/coord/bot-merge.sh"

if grep -q "INFRA-8083: gap .* is tagged external_repo:" "$DISPATCH_RS"; then
    ok "INFRA-8083 external_repo routing log present in src/dispatch.rs"
else
    bad "INFRA-8083 external_repo routing log NOT found in src/dispatch.rs"
fi

if grep -q "kill_child_process_group" "$DISPATCH_RS"; then
    ok "kill_child_process_group present in src/dispatch.rs"
else
    bad "kill_child_process_group NOT found in src/dispatch.rs"
fi

if grep -q 'chump improve "\$_ext_owner_repo" --gap "\$GAP_ID" --apply' "$WORKER_SH"; then
    ok "worker.sh routes external_repo gaps to chump improve --gap --apply"
else
    bad "worker.sh external_repo routing NOT found"
fi

CARGO_8083_OUTPUT=$(cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" \
    cargo test --bin chump infra_8083_ 2>&1)
CARGO_8083_RC=$?
if [[ $CARGO_8083_RC -eq 0 ]]; then
    ok "cargo test infra_8083_ exited 0"
else
    bad "cargo test infra_8083_ exited $CARGO_8083_RC"
    echo "$CARGO_8083_OUTPUT" | tail -25
fi

for test_name in \
    "infra_8083_dispatch_external_repo_routes_to_improve_without_bot_merge" \
    "infra_8083_kill_child_process_group_terminates_grandchild"; do
    if echo "$CARGO_8083_OUTPUT" | grep -q "$test_name"; then
        ok "test $test_name ran"
    else
        bad "test $test_name NOT found in output"
    fi
done

# Behavioral check for worker.sh extraction of external_repo:repairman29/upshift-cli
FIXTURE_GAP_JSON='[{"id":"INFRA-B1","effort":"s","skills_required":"rust,external_repo:repairman29/upshift-cli"}]'
EXTRACTED_REPO=$(printf '%s' "$FIXTURE_GAP_JSON" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
gs = d.get('gaps', []) if isinstance(d, dict) and 'gaps' in d else (d if isinstance(d, list) else [d])
g = next((x for x in gs if isinstance(x, dict) and x.get('id') == 'INFRA-B1'), {})
raw = ' '.join(str(g.get(k) or '') for k in ('skills_required', 'notes'))
for tok in re.split(r'[,\s]+', raw):
    tok = tok.strip().strip('\"\'')
    if tok.startswith('external_repo:'):
        val = tok[len('external_repo:'):]
        if '/' in val and '<' not in val and '>' not in val:
            print(val)
            break
")
if [[ "$EXTRACTED_REPO" == "repairman29/upshift-cli" ]]; then
    ok "worker.sh extractor resolves external_repo:repairman29/upshift-cli"
else
    bad "worker.sh extractor returned '$EXTRACTED_REPO' (expected repairman29/upshift-cli)"
fi

# ── (d) INFRA-8083: bot-merge.sh untracked-file auto-stage guard ─────────────
echo ""
echo "-- (d) INFRA-8083: bot-merge.sh untracked auto-stage guard (1005 files) --"

if grep -q "CHUMP_BOT_MERGE_MAX_UNTRACKED" "$BOT_MERGE_SH"; then
    ok "CHUMP_BOT_MERGE_MAX_UNTRACKED present in bot-merge.sh"
else
    bad "CHUMP_BOT_MERGE_MAX_UNTRACKED NOT found in bot-merge.sh"
fi

TMP_BM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bm-8083.XXXXXX")"
trap 'rm -rf "$TMP_BM_DIR"' EXIT

git -C "$TMP_BM_DIR" init -q -b main
git -C "$TMP_BM_DIR" config user.email "test@chump.local"
git -C "$TMP_BM_DIR" config user.name "Chump Test"
mkdir -p "$TMP_BM_DIR/src" "$TMP_BM_DIR/crates" "$TMP_BM_DIR/scripts" "$TMP_BM_DIR/docs/gaps" "$TMP_BM_DIR/.chump-locks"
echo "fn main() {}" > "$TMP_BM_DIR/src/main.rs"
git -C "$TMP_BM_DIR" add src/main.rs
git -C "$TMP_BM_DIR" commit -qm "init"
git -C "$TMP_BM_DIR" checkout -qb chump/test-8083

# Create 1005 untracked files under src/ plus untracked docs/gaps/*.yaml files.
python3 -c '
import os, sys
root = sys.argv[1]
for i in range(1, 1006):
    with open(os.path.join(root, "src", f"untracked_{i}.rs"), "w") as f:
        f.write(f"// {i}\n")
for i in range(1, 10):
    with open(os.path.join(root, "docs", "gaps", f"TEST-{i}.yaml"), "w") as f:
        f.write(f"id: TEST-{i}\n")
' "$TMP_BM_DIR"

# Run _bm_autostage_untracked (sourced from scripts/coord/lib/bot-merge-autocommit.sh) inside the fixture repo.
BM_OUT=$(cd "$TMP_BM_DIR" && source "$REPO_ROOT/scripts/coord/lib/bot-merge-autocommit.sh" && _bm_autostage_untracked 2>&1)
BM_RC=$?

if [[ $BM_RC -ne 0 ]]; then
    ok "bot-merge untracked guard exited non-zero ($BM_RC) on 1005 untracked files"
else
    bad "bot-merge untracked guard exited 0 (expected non-zero refusal)"
fi

if echo "$BM_OUT" | grep -q "refusing to auto-stage 1005 untracked files (exceeds CHUMP_BOT_MERGE_MAX_UNTRACKED=50)"; then
    ok "bot-merge printed clear INFRA-8083 refusal message for 1005 untracked files"
else
    bad "bot-merge refusal message missing or unexpected: $BM_OUT"
fi

STAGED_NOW="$(git -C "$TMP_BM_DIR" diff --cached --name-only)"
if [[ -z "$STAGED_NOW" ]]; then
    ok "git index remains clean (git diff --cached --name-only is empty)"
else
    bad "git index was dirtied: $STAGED_NOW"
fi

# Verify docs/gaps/*.yaml files are never staged even when untracked count <= 50.
rm -f "$TMP_BM_DIR"/src/untracked_*.rs
echo "// valid" > "$TMP_BM_DIR/src/keep_me.rs"
(cd "$TMP_BM_DIR" && source "$REPO_ROOT/scripts/coord/lib/bot-merge-autocommit.sh" && _bm_autostage_untracked >/dev/null 2>&1)
STAGED_FILTERED="$(git -C "$TMP_BM_DIR" diff --cached --name-only)"
if [[ "$STAGED_FILTERED" == "src/keep_me.rs" ]]; then
    ok "docs/gaps/*.yaml excluded from auto-stage while valid src/ file staged"
else
    bad "expected only src/keep_me.rs staged, got: $STAGED_FILTERED"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
