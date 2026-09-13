#!/usr/bin/env bash
# test-rot-reaper.sh — RESILIENT-324 + RESILIENT-311 (no-abandon janitor)
#
# Proves the rot-reaper's SELECTION logic across every terminal-drive class:
#   • CONFLICTING + old            → REAP (close+requeue+label)          [324]
#   • CONFLICTING + fresh          → left for owner/rebaser              [324]
#   • BLOCKED-but-mergeable, no
#     required-check failure        → left (needs CI/approval)           [324]
#   • MERGEABLE + REQUIRED check
#     FAILED (completed HARD-fail on
#     a blocking gate) + old         → REAP (the raw-gh/bypass rot class) [311]
#     NB: a required-red PR is now classified before reap (verified-red spare);
#     only a genuine hard_fail reaps — green-underneath / pending / cancelled /
#     flake are SPARED. The reap fixtures below carry a COMPLETED FAILURE on a
#     blocking (`*-required`) gate so they are genuine hard_fails. The spare
#     path is proven in test-rot-reaper-verified-red-spare.sh.
#   • MERGEABLE + REQUIRED check
#     FAILED + fresh                → left (may be a flake, give it time)[311]
#   • MERGEABLE + green + UNARMED
#     + old                         → ARM (backstop the pr-lander)       [311]
#   • gap-filing PR                 → never touched                      [324]
#   • past-deadline non-terminal
#     hidden class                  → counted in no-abandon backlog      [311]
#
# Runs scripts/ops/rot-reaper.sh in --dry-run against a synthetic PR fixture
# (CHUMP_ROT_REAPER_PR_JSON) with gh/chump stubbed on PATH — no live GitHub,
# no state mutation. The required-check set is pinned via env so the test does
# not hit branch-protection.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAPER="$REPO_ROOT/scripts/ops/rot-reaper.sh"
[[ -f "$REAPER" ]] || { echo "FAIL: $REAPER not found"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# stub gh (only `gh api user` is reached in dry-run; PR list comes from the
# fixture) + chump (no gaps known → `gap show` prints nothing)
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
OLD="$(iso 12)"     # past every age gate (conflict 4h, realfail 8h, arm 15m)
MID="$(iso 5)"      # past conflict gate, INSIDE realfail gate
FRESH="$(iso 1)"    # past arm gate only

REQ='audit-required'   # pinned required-check set for the test

# RESILIENT-339 resolve-first: the reaper reaps a CONFLICTING PR ONLY when the
# conflict-resolution-consumer has already exhausted its attempts (state dir).
# Point the reaper at an empty temp state dir so a CONFLICTING PR with NO state
# is treated as still-savable (handed off + deferred), and seed one PR (#211)
# whose state shows attempts>=MAX so it is genuinely-unresolvable → reaped.
CSTATE="$TMP/conflict-state"; mkdir -p "$CSTATE"
export CHUMP_ROT_REAPER_CONFLICT_STATE_DIR="$CSTATE"
printf '{"pr":211,"attempts":3,"first_seen":"2026-08-20T00:00:00Z"}\n' > "$CSTATE/211.json"

FIX="$TMP/prs.json"
cat > "$FIX" <<EOF
[
  {"number":201,"title":"RESILIENT-900: real conflicting work","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-900","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":202,"title":"RESILIENT-901: fresh conflict, owner may be rebasing","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$FRESH","headRefName":"rs-901","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":203,"title":"RESILIENT-902: blocked but mergeable, only pending CI (no required FAILURE)","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-902","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"audit-required","conclusion":null,"status":"IN_PROGRESS"}]},
  {"number":204,"title":"RESILIENT-903: clean, green, UNARMED","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-903","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[{"name":"audit-required","conclusion":"SUCCESS"}]},
  {"number":205,"title":"chore(gaps): file RESILIENT-904","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"file-rs904","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]},
  {"number":206,"title":"RESILIENT-905: mergeable but required check RED, old","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-905","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"audit-required","conclusion":"FAILURE","status":"COMPLETED"}]},
  {"number":207,"title":"RESILIENT-906: mergeable but required check RED, still fresh","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$MID","headRefName":"rs-906","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"audit-required","conclusion":"FAILURE","status":"COMPLETED"}]},
  {"number":208,"title":"RESILIENT-907: an ADVISORY (non-required) check is red — must NOT reap","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-907","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"PWA visual diff (advisory)","conclusion":"FAILURE"},{"name":"audit-required","conclusion":"SUCCESS"}]},
  {"number":211,"title":"RESILIENT-908: conflicting, old, resolution EXHAUSTED by consumer","mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","createdAt":"$OLD","headRefName":"rs-911","isDraft":false,"autoMergeRequest":null,"statusCheckRollup":[]}
]
EOF

out="$(CHUMP_ROT_REAPER_PR_JSON="$FIX" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" bash "$REAPER" --dry-run 2>&1)"
echo "$out"
echo "---"

pass=0; fail=0
ok()  { echo "  ok: $1"; pass=$((pass+1)); }
bad() { echo "  FAIL: $1"; fail=$((fail+1)); }

# #201: old CONFLICTING, resolution NOT yet exhausted → HANDED OFF + DEFERRED (RESILIENT-339), never reaped
echo "$out" | grep -q 'PR #201 — CONFLICTING, .*conflict-resolution NOT yet exhausted' && ok "#201 savable-conflict handed off + deferred" || bad "#201 not deferred (resolve-first)"
echo "$out" | grep -qE 'PR #201 .*→ REAP' && bad "#201 wrongly reaped while still savable" || ok "#201 not reaped (savable)"
# #211: old CONFLICTING, resolution EXHAUSTED by the consumer → NOW reaped
echo "$out" | grep -qE 'PR #211 — CONFLICTING, .*EXHAUSTED.*→ REAP' && ok "#211 exhausted-conflict reaped" || bad "#211 not reaped after resolution exhausted"
# #202: fresh CONFLICTING → skipped by age gate
echo "$out" | grep -q 'PR #202 — CONFLICTING but only' && ok "#202 fresh-conflict skipped" || bad "#202 not skipped by age"
echo "$out" | grep -qE 'PR #202 .*→ REAP' && bad "#202 wrongly reaped" || ok "#202 not reaped"
# #203: BLOCKED-but-MERGEABLE, only pending CI → not reaped, not armed (already armed)
echo "$out" | grep -qE 'PR #203 .*(REAP|ARM)' && bad "#203 wrongly reaped/armed" || ok "#203 left alone (armed, pending CI)"
# #204: clean green UNARMED old → ARMED (lander backstop)
echo "$out" | grep -qE 'would ARM green-unarmed PR #204' && ok "#204 green-unarmed armed" || bad "#204 not armed"
# #205: filing PR → skipped even though CONFLICTING+old
echo "$out" | grep -q 'PR #205 — filing PR, skipping' && ok "#205 filing PR skipped" || bad "#205 filing PR not skipped"
# #206: mergeable + required RED + old → REAPED
echo "$out" | grep -qE 'PR #206 — MERGEABLE but REQUIRED check RED .*[0-9]+h old → REAP' && ok "#206 required-red (hard-fail) reaped" || bad "#206 not reaped"
# #207: mergeable + required RED but fresh → left
echo "$out" | grep -q 'PR #207 — failing a required check but only' && ok "#207 fresh required-red skipped" || bad "#207 not skipped"
echo "$out" | grep -qE 'PR #207 .*→ REAP' && bad "#207 wrongly reaped" || ok "#207 not reaped"
# #208: only an ADVISORY check red (required is green) → must NOT reap
echo "$out" | grep -qE 'PR #208 .*→ REAP' && bad "#208 advisory-red wrongly reaped" || ok "#208 advisory-red left alone"
# exactly two closes (#211 exhausted-conflict + #206 required-red); #201 is DEFERRED, not closed
echo "$out" | grep -q 'closed=2' && ok "exactly two PRs reaped (closed=2: exhausted-conflict + required-red)" || bad "close count wrong (expected 2)"
# no-abandon backlog metric emitted (0 here — every past-deadline PR was driven)
echo "$out" | grep -q 'NO-ABANDON BACKLOG: 0' && ok "no-abandon backlog is 0 (nothing rots)" || bad "backlog metric wrong/absent"

echo ""
echo "=== rot-reaper selection: $pass passed, $fail failed ==="

# ── EFFECTIVE-434: respawn-cap escalation ─────────────────────────────────────
# A second run with a `chump` stub that answers `gap show` per gap-id (instead
# of the always-empty stub above) proves the respawn cap: a gap already
# carrying RESPAWN_CAP (2, here) prior "rot-reaper: PR #... auto-closed" notes
# must NOT be re-queued again — the reaper escalates to the operator instead —
# while a gap with zero prior notes re-queues normally.
STUB2="$TMP/bin2"; mkdir -p "$STUB2"
cat > "$STUB2/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "api" && "$2" == "user" ]] && { echo "repairman29"; exit 0; }
exit 0
EOF
cat > "$STUB2/chump" <<'EOF'
#!/usr/bin/env bash
# Minimal `chump gap show <ID> [--field notes]` stub keyed by gap id.
if [[ "$1" == "gap" && "$2" == "show" ]]; then
    gid="$3"
    field=""
    [[ "$4" == "--field" ]] && field="$5"
    notes=""
    if [[ "$gid" == "RESILIENT-951" ]]; then
        notes=$'rot-reaper: PR #100 auto-closed (required-check-red, 9h) 2026-08-01; re-attempt on fresh main.\nrot-reaper: PR #150 auto-closed (required-check-red, 9h) 2026-08-05; re-attempt on fresh main.'
    fi
    if [[ "$field" == "notes" ]]; then
        printf '%s\n' "$notes"
    else
        printf -- '- id: %s\n  status: open\n  notes: |\n' "$gid"
    fi
    exit 0
fi
exit 0
EOF
chmod +x "$STUB2"/*

FIX2="$TMP/prs2.json"
cat > "$FIX2" <<EOF
[
  {"number":209,"title":"RESILIENT-950: mergeable but required check RED, old, fresh gap","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-950","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"audit-required","conclusion":"FAILURE","status":"COMPLETED"}]},
  {"number":210,"title":"RESILIENT-951: mergeable but required check RED, old, gap already recycled twice","mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","createdAt":"$OLD","headRefName":"rs-951","isDraft":false,"autoMergeRequest":{"enabledAt":"x"},"statusCheckRollup":[{"name":"audit-required","conclusion":"FAILURE","status":"COMPLETED"}]}
]
EOF

out2="$(PATH="$STUB2:$PATH" CHUMP_ROT_REAPER_PR_JSON="$FIX2" CHUMP_ROT_REAPER_REQUIRED_CHECKS="$REQ" CHUMP_ROT_REAPER_RESPAWN_CAP=2 bash "$REAPER" --dry-run 2>&1)"
echo "$out2"
echo "---"

# #209: fresh gap (0 prior recycles) → normal re-queue path, no escalation
echo "$out2" | grep -qE 'PR #209 .*→ REAP' && ok "#209 fresh-gap reaped" || bad "#209 not reaped"
echo "$out2" | grep -q 'RESILIENT-950 respawn cap reached' && bad "#209 wrongly hit respawn cap" || ok "#209 did not hit respawn cap"
echo "$out2" | grep -q 'would re-queue RESILIENT-950' && ok "#209 re-queue attempted (fresh gap)" || bad "#209 re-queue not attempted"

# #210: gap already has 2 prior recycles, cap=2 → escalate, do NOT re-queue
echo "$out2" | grep -qE 'PR #210 .*→ REAP' && ok "#210 still reaped (PR itself always closes)" || bad "#210 not reaped"
echo "$out2" | grep -q 'RESILIENT-951 respawn cap reached (2 >= 2)' && ok "#210 respawn cap escalation fired" || bad "#210 respawn cap escalation missing"
echo "$out2" | grep -q 'would re-queue RESILIENT-951' && bad "#210 wrongly re-queued past its cap" || ok "#210 not re-queued past its cap"

echo ""
echo "=== rot-reaper respawn-cap: $pass passed, $fail failed ==="
[[ "$fail" -eq 0 ]]
