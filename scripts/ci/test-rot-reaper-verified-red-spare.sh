#!/usr/bin/env bash
# test-rot-reaper-verified-red-spare.sh — RESILIENT-311 completion (verified-red spare)
#
# PR #4606 taught the stale-pr-reaper to spare green-underneath BLOCKED PRs. But
# a SECOND reaper — the rot-reaper (scripts/ops/rot-reaper.sh, RESILIENT-311) —
# still closed good PRs whose SOLE branch-protection-required check `verified`
# (a slow AGGREGATE over cargo-test/clippy/audit/fast-checks/parity) sat RED past
# an SLO. `verified` goes red for RECOVERABLE reasons: a parity mirror reports
# late, a sub-job is CI-cancelled, a known flake trips, or CI is still finishing.
# The reaper reaped #4598/#4615/#4618 that way — a 22-min-late parity gate, a
# flake, a CI-cancel — destroying correct work that only needed a re-run.
#
# The fix REUSES the #4606 green-underneath classifier
# (scripts/ops/lib/classify-blocked-pr.py) via its opt-in `--blocking-check`
# path: before any CLASS-2 close, the rot-reaper classifies WHY verified is red
# and SPARES the recoverable verdicts (green_underneath / pending / cancelled /
# blocked_no_failure / flake_exhausted) — re-arming instead of closing, and
# escalating past a bound. Only a genuine hard_fail (a COMPLETED failure on a
# real blocking gate) or a conflict is closed.
#
# This test proves BOTH directions end-to-end against the rot-reaper's own
# selection logic (CHUMP_ROT_REAPER_PR_JSON fixture, gh/chump stubbed):
#   • a GREEN-UNDERNEATH verified-red PR is SPARED (re-armed, never closed)
#   • a pending / cancelled / flake verified-red PR is SPARED
#   • a genuine HARD-FAIL verified-red PR is still CLOSED
#   • a human-closed PR is never in the open set → never touched/reopened
# plus a direct classifier fixture matrix for the two new verdicts, and
# source-wiring + event-registration asserts.
#
# Depth tier: EDGE — pure decision-function fixtures across the verified-red
# reason matrix (green-underneath / pending / cancelled / flake / hard-fail /
# conflict) driven through the REAL reaper in --dry-run with stubbed gh/chump,
# plus classifier-unit and source-wiring asserts. Gaps: does not spin up a live
# GitHub PR, a real `verified` aggregate run, or the auto-merge-armer/operator
# escalation side effects (the re-arm/escalate glue is covered by source-wiring
# asserts + the dry-run SPARE lines, not live execution); the flake-budget
# marker path is exercised via the classifier unit, not the reaper's own dir.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
CLASSIFIER="$REPO_ROOT/scripts/ops/lib/classify-blocked-pr.py"
REGISTRY_YAML="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
for f in "$REAPER" "$CLASSIFIER" "$REGISTRY_YAML"; do
    [[ -f "$f" ]] || { echo "FAIL: required file missing: $f"; exit 1; }
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# ── stub gh + chump (dry-run reaches only `gh api user`; PR list is the fixture)
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" && "$2" == "user" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

iso() { python3 -c "from datetime import datetime,timezone,timedelta;print((datetime.now(timezone.utc)-timedelta(hours=$1)).strftime('%Y-%m-%dT%H:%M:%SZ'))"; }
OLD="$(iso 12)"   # past every age gate (realfail 8h)

# `verified` is the sole branch-protection-required check on main. Pin it so the
# reaper's REQFAIL classifier fires on a red `verified` without hitting the API.
REQ='verified'

# Keep spare state + flake markers inside TMP so the run is hermetic.
export CHUMP_ROT_REAPER_SPARE_STATE_DIR="$TMP/spare-state"
export CHUMP_ROT_REAPER_FLAKE_COOLDOWN_DIR="$TMP/flake-cooldown"

# Rollups. A real `gh` CheckRun always carries `status`; a COMPLETED failure on a
# blocking gate is a genuine hard-fail, an in-progress one is pending, etc.
#  #301 GREEN-UNDERNEATH: real gates GREEN, only the `verified` aggregate red.
GU='[{"name":"cargo-test-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"clippy-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"audit-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'
#  #302 PENDING: a real gate still running while verified reported red early.
PEND='[{"name":"cargo-test-required","status":"IN_PROGRESS","conclusion":null},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'
#  #303 CANCELLED: a real gate was CI-cancelled (superseded push), not failed.
CANC='[{"name":"fast-checks","status":"COMPLETED","conclusion":"CANCELLED"},{"name":"cargo-test-required","status":"COMPLETED","conclusion":"SUCCESS"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'
#  #304 HARD-FAIL: a real blocking gate actually FAILED → genuinely dead.
HF='[{"name":"cargo-test-required","status":"COMPLETED","conclusion":"FAILURE"},{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]'

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":301,"title":"RESILIENT-970: green-underneath, only verified aggregate red","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-970","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$GU},
  {"number":302,"title":"RESILIENT-971: verified red but a required gate still pending","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-971","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$PEND},
  {"number":303,"title":"RESILIENT-972: verified red but the failing gate was CI-cancelled","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-972","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$CANC},
  {"number":304,"title":"RESILIENT-973: verified red because a required gate really FAILED","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-973","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":$HF}
]
EOF

out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" --dry-run 2>&1)"
echo "$out"
echo "---"

# ── SPARE cases: green-underneath / pending / cancelled must NOT be closed ─────
for n in 301 302 303; do
    echo "$out" | grep -qE "would SPARE PR #$n" && ok "#$n verified-red SPARED (re-arm, never close)" \
        || bad "#$n not spared"
    echo "$out" | grep -qE "PR #$n .*→ REAP" && bad "#$n wrongly reaped (recoverable verified-red)" \
        || ok "#$n not reaped"
done
# The specific recoverable verdicts are surfaced.
echo "$out" | grep -qE 'PR #301 .*RECOVERABLE \(green_underneath\)' && ok "#301 classified green_underneath" || bad "#301 not classified green_underneath"
echo "$out" | grep -qE 'PR #303 .*RECOVERABLE \(cancelled\)'        && ok "#303 classified cancelled"        || bad "#303 not classified cancelled"

# ── CLOSE case: a genuine hard-fail is still reaped ───────────────────────────
echo "$out" | grep -qE 'PR #304 .*hard-fail.*→ REAP' && ok "#304 genuine hard-fail still REAPED" \
    || bad "#304 hard-fail not reaped (would let real failures rot)"
echo "$out" | grep -qE 'would SPARE PR #304' && bad "#304 hard-fail wrongly spared" || ok "#304 not spared"

# ── exactly ONE close this run (only the hard-fail); three spared ─────────────
echo "$out" | grep -q 'closed=1' && ok "exactly one PR reaped (closed=1: only the hard-fail)" || bad "close count wrong (expected closed=1)"
echo "$out" | grep -q 'spared=3' && ok "exactly three PRs spared (spared=3)" || bad "spare count wrong (expected spared=3)"

# ── human-closed PR is never in the OPEN set → reaper never touches it ────────
# The reaper only ever iterates the open PR list (gh pr list --state open). A
# human-closed PR (#305) is absent from the fixture, so it can be neither reaped
# nor spared nor reopened — the reaper leaves human-terminal state alone.
echo "$out" | grep -q '#305' && bad "#305 (human-closed) appeared in reaper output" || ok "#305 human-closed PR never touched (not in open set)"

# ── the spare is UNCONDITIONAL: there is NO toggle to restore close-all ───────
# The old CHUMP_ROT_REAPER_SPARE_RECOVERABLE=0 escape hatch (which restored the
# close-good-PRs behavior) was removed — a switch to turn the safety fix off is
# exactly the bypass debt the ceiling forbids. Setting the (now-inert) env var
# must NOT change behavior: still closed=1 (only the hard-fail), still spared=3.
out_toggle="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" CHUMP_ROT_REAPER_SPARE_RECOVERABLE=0 bash "$REAPER" --dry-run 2>&1)"
echo "$out_toggle" | grep -q 'closed=1' && ok "spare is unconditional: inert env var does not restore close-all (closed=1)" \
    || bad "an env var still alters spare behavior — the toggle was not fully removed"
echo "$out_toggle" | grep -q 'spared=3' && ok "spare is unconditional: still spared=3 regardless of env" \
    || bad "spare count changed under the (removed) toggle"

echo ""
echo "=== reaper end-to-end: $pass passed so far ==="

# ── direct classifier fixture matrix for the two NEW verdicts ─────────────────
BR='-required$|^audit-shard|^fast-checks$'
cl() { printf '%s' "$1" > "$TMP/r.json"; python3 "$CLASSIFIER" --rollup-file "$TMP/r.json" --mergeable "$2" --blocking-check="$BR" "${@:3}" 2>/dev/null; }
v=$(cl "$GU"   MERGEABLE);                 [[ "$v" == "green_underneath" ]] && ok "classifier: green-underneath → green_underneath" || bad "classifier GU got '$v'"
v=$(cl "$CANC" MERGEABLE);                 [[ "$v" == "cancelled" ]]        && ok "classifier: CI-cancel → cancelled"               || bad "classifier CANC got '$v'"
v=$(cl "$PEND" MERGEABLE);                 [[ "$v" == "pending" ]]          && ok "classifier: gate pending → pending"              || bad "classifier PEND got '$v'"
v=$(cl "$HF"   MERGEABLE);                 [[ "$v" == "hard_fail" ]]        && ok "classifier: real gate failure → hard_fail"        || bad "classifier HF got '$v'"
v=$(cl "$HF"   MERGEABLE --flake-exhausted 1); [[ "$v" == "flake_exhausted" ]] && ok "classifier: budget-spent flake → flake_exhausted" || bad "classifier flake got '$v'"
v=$(cl "$GU"   CONFLICTING);               [[ "$v" == "conflict" ]]         && ok "classifier: CONFLICTING → conflict"               || bad "classifier conflict got '$v'"
# A lone non-blocking failure with NO passing real gate must NOT masquerade as
# recoverable — a genuinely-empty/broken PR still reads hard_fail.
v=$(cl '[{"name":"verified","status":"COMPLETED","conclusion":"FAILURE"}]' MERGEABLE); [[ "$v" == "hard_fail" ]] && ok "classifier: lone verified-fail, no green gate → hard_fail (not spared)" || bad "classifier lone-aggr got '$v'"

# ── backward-compat: the LEGACY (no --blocking-check) path is unchanged ───────
lv() { printf '%s' "$1" > "$TMP/r.json"; python3 "$CLASSIFIER" --rollup-file "$TMP/r.json" --mergeable "$2" "${@:3}" 2>/dev/null; }
v=$(lv '[{"name":"x","status":"COMPLETED","conclusion":"CANCELLED"}]' MERGEABLE); [[ "$v" == "hard_fail" ]] && ok "legacy path: CANCELLED still hard_fail (stale-pr-reaper unchanged)" || bad "legacy CANCELLED drifted to '$v'"
v=$(lv "$GU" MERGEABLE); [[ "$v" == "hard_fail" ]] && ok "legacy path: green-underneath rollup → hard_fail (no new verdict without --blocking-check)" || bad "legacy GU drifted to '$v'"

# ── source-wiring asserts ─────────────────────────────────────────────────────
grep -q 'CHUMP_ROT_REAPER_SPARE_RECOVERABLE' "$REAPER" && bad "reaper: SPARE_RECOVERABLE toggle still present (must be removed — a switch that closes good PRs is forbidden bypass debt)" || ok "reaper: no SPARE_RECOVERABLE toggle (spare is unconditional)"
grep -q 'classify_verified_red' "$REAPER"               && ok "reaper: calls classify_verified_red before close" || bad "reaper: no classify_verified_red call"
grep -q 'classify-blocked-pr.py' "$REAPER"              && ok "reaper: reuses classify-blocked-pr.py (no second classifier)" || bad "reaper: does not reuse the #4606 classifier"
grep -q 'rearm_flake_budget' "$REAPER"                  && ok "reaper: re-arms flake budget (recovery path)" || bad "reaper: no flake re-arm path"
grep -q 'notify_operator' "$REAPER"                     && ok "reaper: escalates to operator (bounded, never fights forever)" || bad "reaper: no operator escalation"
# The spare classification must precede the CLASS-2 close in source order.
_spare_line=$(grep -n 'classify_verified_red "\$PR_NUM"' "$REAPER" | head -1 | cut -d: -f1)
_close_line=$(grep -n 'label_and_close "\$PR_NUM" "\$MSG"' "$REAPER" | tail -1 | cut -d: -f1)
if [[ -n "$_spare_line" && -n "$_close_line" && "$_spare_line" -lt "$_close_line" ]]; then
    ok "spare classification (L$_spare_line) precedes the CLASS-2 close (L$_close_line)"
else
    bad "spare classification does not precede the close (spare=$_spare_line close=$_close_line)"
fi

# ── new event kind registered in EVENT_REGISTRY.yaml ──────────────────────────
grep -qE '^\s*-\s+kind:\s*pr_reap_spared\b' "$REGISTRY_YAML" \
    && ok "event registered: pr_reap_spared" \
    || bad "event NOT registered in EVENT_REGISTRY.yaml: pr_reap_spared"

echo ""
if [[ "$fail" -eq 0 ]]; then
    echo "test-rot-reaper-verified-red-spare: ALL $pass passed"
    exit 0
else
    echo "test-rot-reaper-verified-red-spare: $pass passed, $fail failed"
    exit 1
fi
