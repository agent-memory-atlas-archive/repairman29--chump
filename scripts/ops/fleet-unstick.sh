#!/usr/bin/env bash
# fleet-unstick.sh — ATC's runbook for a stalled fleet. Deterministic procedures,
# in order of what actually unsticks it (learned 2026-08-12: a 12h ship-drought
# was musher.py reading the STALE docs/gaps.yaml monolith after the store moved to
# per-file + state.db). Run on a ship-drought alarm or by hand. Escalates if the
# deterministic steps don't restore pickability.
#   Usage: fleet-unstick.sh        # run the procedures
#          fleet-unstick.sh --check # diagnose only, no changes
set -uo pipefail
REPO_ROOT="${CHUMP_REPO_ROOT:-/root/Projects/chump}"
cd "$REPO_ROOT" 2>/dev/null || { echo "[unstick] no repo root"; exit 1; }
CHECK_ONLY=0; [ "${1:-}" = "--check" ] && CHECK_ONLY=1
ts(){ date -u +%Y-%m-%dT%H:%M:%SZ; }
say(){ echo "[fleet-unstick $(ts)] $*"; }
emit(){ printf '%s\n' "$1" >> "$REPO_ROOT/.chump-locks/ambient.jsonl" 2>/dev/null || true; }

# STEP 0 — is the fleet actually stuck? (musher finds nothing to pick)
pick_before="$(python3 scripts/coord/musher.py --pick 2>&1 | grep -oiE 'PICK|No available' | head -1)"
say "musher pick (before): ${pick_before:-unknown}"
[ "$CHECK_ONLY" = 1 ] && { say "check-only, stopping"; exit 0; }

# STEP 1 — regenerate the selector's source (the #1 real cause: stale monolith)
if command -v chump >/dev/null 2>&1; then
  chump gap dump --out docs/gaps.yaml >/dev/null 2>&1 && say "regenerated docs/gaps.yaml from the store" || say "WARN dump failed"
fi

# STEP 2 — retired (INFRA-8193): YAML no longer writes back into state.db
# (`gap sync --pull` is a hard error). Reconcile stores with
# `chump store reconcile` (INFRA-8222) once it lands.

# STEP 3 — release stale claims/leases (dead PIDs holding gaps)
released=0
for f in "$REPO_ROOT"/.chump-locks/*.json; do
  [ -f "$f" ] || continue
  pid="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('pid',''))" "$f" 2>/dev/null)"
  [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null && { rm -f "$f" 2>/dev/null && released=$((released+1)); }
done
[ "$released" -gt 0 ] && say "released $released stale claim(s)"

# STEP 4 — did it work? re-check musher
pick_after="$(python3 scripts/coord/musher.py --pick 2>&1 | grep -oiE 'PICK|No available' | head -1)"
say "musher pick (after): ${pick_after:-unknown}"

# STEP 5 — escalate if still stuck
if echo "$pick_after" | grep -qi "No available"; then
  say "STILL STUCK after procedures — escalating to operator"
  emit "{\"ts\":\"$(ts)\",\"kind\":\"fleet_unstick_failed\",\"released\":$released}"
  if [ -f scripts/coord/lib/notify-operator.sh ]; then
    source scripts/coord/lib/notify-operator.sh 2>/dev/null
    notify_operator "🚨 fleet-unstick ran but the fleet is STILL stuck (musher finds no pickable gap after regenerate+sync+claim-release). Needs a human/board look — likely a NEW selector-vs-store drift class." 2>/dev/null || true
  fi
  exit 2
fi
say "fleet unstuck — musher can pick again"
emit "{\"ts\":\"$(ts)\",\"kind\":\"fleet_unstick_ran\",\"released\":$released,\"result\":\"ok\"}"
exit 0
