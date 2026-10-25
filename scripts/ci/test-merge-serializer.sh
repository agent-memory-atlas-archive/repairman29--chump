#!/usr/bin/env bash
# test-merge-serializer.sh — RESILIENT-372 smoke/structure gate for the
# merge-serializer organ. Static + bypass + dry-run only: NEVER pushes or merges.
#
# Depth: smoke + structure. Gaps (NOT covered here): the live rebase→verified→merge
# path (proven once by hand on a real PR at ship time, recorded in the PR), the
# bot-merge.lock contention path, and the verified-timeout branch.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SER="$ROOT/scripts/coord/merge-serializer.sh"
pass=0; fail=0
ok()   { echo "  ok: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }

echo "=== merge-serializer structure ==="
[[ -f "$SER" ]] && ok "script present" || { bad "script missing: $SER"; echo "$pass ok / $fail fail"; exit 1; }
[[ -x "$SER" ]] && ok "script executable" || bad "script not executable"
bash -n "$SER" && ok "bash -n clean (syntax)" || bad "syntax error"

echo "=== reuse of shared plumbing (mine-before-build) ==="
grep -q "discover-flock.sh" "$SER"      && ok "reuses discover-flock.sh (FLOCK_BIN)"      || bad "does not source discover-flock.sh"
grep -q "repo-paths.sh"     "$SER"      && ok "reuses repo-paths.sh (LOCK_DIR)"           || bad "does not source repo-paths.sh"
grep -q "bot-merge.lock"    "$SER"      && ok "reuses INFRA-860 bot-merge.lock for mutations" || bad "does not reuse bot-merge.lock"

echo "=== core behaviors present ==="
grep -q "sort_by(.created)"          "$SER" && ok "oldest-first selection"        || bad "no oldest-first sort"
grep -q "rebase origin/main"         "$SER" && ok "rebases onto latest main"      || bad "no rebase-onto-main"
grep -q "_wait_verified"             "$SER" && ok "waits for verified (bounded)"  || bad "no verified wait"
grep -q "_verified_state"            "$SER" && ok "early-fail on failed blocking sub-check" || bad "no early-fail detection"
grep -q "merge .* --squash"          "$SER" && ok "squash-merges"                 || bad "no squash merge"
grep -q "_trunk_red"                 "$SER" && ok "trunk-RED gate present"        || bad "no trunk-red gate"
grep -q "merge-serializer.lock"      "$SER" && ok "single-instance self-lock"     || bad "no self-lock"
grep -q "force-with-lease --no-verify" "$SER" && ok "push --force-with-lease --no-verify" || bad "unsafe push"

echo "=== bypass exits 0 immediately ==="
if CHUMP_MERGE_SERIALIZER_DISABLED=1 bash "$SER" >/dev/null 2>&1; then ok "bypass exits 0"; else bad "bypass did not exit 0"; fi

echo "=== bounded / idempotent knobs ==="
grep -q "CHUMP_MERGE_SERIALIZER_MAX_MERGES"        "$SER" && ok "MAX_MERGES knob"        || bad "no MAX_MERGES"
grep -q "CHUMP_MERGE_SERIALIZER_VERIFY_TIMEOUT_S"  "$SER" && ok "VERIFY_TIMEOUT knob"    || bad "no verify timeout"

echo "=== units present ==="
for u in chump-merge-serializer.service chump-merge-serializer.timer; do
    [[ -f "$ROOT/scripts/dispatch/$u" ]] && ok "$u present" || bad "$u missing"
done
grep -q "chump-merge-serializer.timer" "$ROOT/scripts/ops/organ-manifest.txt" && ok "manifest row present" || bad "no manifest row"

echo "=== RESILIENT-1537 (BEHIND update-branch) & RESILIENT-1511 (shepherd timer OnActiveSec=10s) ==="
grep -q 'pr update-branch "\$pr" --repo "\$REPO" --rebase' "$SER" && ok "RESILIENT-1537: merge-serializer calls pr update-branch --rebase on BEHIND PRs" || bad "RESILIENT-1537: missing pr update-branch --rebase in merge-serializer.sh"
grep -q 'RESILIENT-1537' "$SER" && ok "RESILIENT-1537: annotated in merge-serializer.sh" || bad "RESILIENT-1537: missing annotation in merge-serializer.sh"
SHEPHERD_TIMER="$ROOT/scripts/dispatch/chump-pr-shepherd.timer"
[[ -f "$SHEPHERD_TIMER" ]] && grep -q '^OnActiveSec=10s$' "$SHEPHERD_TIMER" && ok "RESILIENT-1511: chump-pr-shepherd.timer has OnActiveSec=10s" || bad "RESILIENT-1511: chump-pr-shepherd.timer missing OnActiveSec=10s"

echo
echo "$pass ok / $fail fail"
[[ "$fail" -eq 0 ]]
