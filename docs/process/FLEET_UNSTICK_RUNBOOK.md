# ATC Fleet-Unstick Runbook

ATC's job is to keep work flowing. When the fleet stalls (ship-drought, `fleet_starved`
spam, workers logging "no pickable gap" while open gaps exist), run the procedures.
Executable: `scripts/ops/fleet-unstick.sh` (`--check` to diagnose only). Runs every 20m
via `chump-fleet-unstick.timer`; also run by hand.

## The procedures (in the order that actually unsticks it)

0. **Confirm the stall.** `musher.py --pick` returns "No available gaps" while
   `chump gap list --status open` shows many. That mismatch is the tell.
1. **Regenerate the selector source.** ROOT CAUSE 2026-08-12: `musher.py` reads the
   monolith `docs/gaps.yaml`, which went stale when the store moved to per-file +
   state.db. `chump gap dump --out docs/gaps.yaml` fixes it. This is the #1 cause.
2. **Reconcile stores.** `chump store reconcile` (INFRA-8222). `chump gap sync --pull`
   is retired (INFRA-8193): the YAML mirror is export-only and never writes back.
3. **Release stale claims.** Dead-PID leases in `.chump-locks/*.json` lock gaps.
4. **Re-check `musher --pick`.** If it picks now, the fleet flows.
5. **Escalate if still stuck.** Emit `fleet_unstick_failed` + notify the operator —
   it's a NEW drift class needing a human/board look.

## Prevention
The timer runs steps 1-3 every 20m preventatively, so `docs/gaps.yaml` never goes
stale enough to starve the fleet. A ship-drought alarm (0 merges in N h) should also
trigger this — see the board's ship-rate scorecard.
