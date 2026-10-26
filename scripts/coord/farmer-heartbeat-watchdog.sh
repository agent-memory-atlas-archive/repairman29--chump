#!/usr/bin/env bash
# RESILIENT-071: Farmer heartbeat watchdog.
# Checks ambient.jsonl for the latest event with kind=farmer_heartbeat,
# kind=farmer_tick, or session starting with "farmer" within --max-age-min
# (default: 30). When stale or absent, emits kind=operator_recall with
# reason="farmer_heartbeat_stale" and stale_minutes, and exits 1.
# Rust-First-Bypass: <100 LOC watchdog glue over ambient.jsonl for fleet-health-sentinel.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_FILE="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
MAX_AGE_MIN=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-age-min)
            MAX_AGE_MIN="${2:-30}"
            shift 2
            ;;
        -h|--help)
            cat <<'EOF'
Usage: scripts/coord/farmer-heartbeat-watchdog.sh [--max-age-min <N>]

Verify that a farmer heartbeat (kind=farmer_heartbeat, kind=farmer_tick, or
session=farmer*) has been recorded in ambient.jsonl within the last N minutes
(default: 30). Emits kind=operator_recall with reason="farmer_heartbeat_stale"
and exits 1 when stale.
EOF
            exit 0
            ;;
        *)
            echo "[farmer-heartbeat-watchdog] ERROR: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

# scanner-anchor: "kind":"operator_recall"
# scanner-anchor: "kind":"session_idle_standby"
# scanner-anchor: "kind":"vague_ac_bypass_used"
python3 - "$AMBIENT_FILE" "$MAX_AGE_MIN" <<'PY'
import datetime
import json
import pathlib
import sys

ambient_path = pathlib.Path(sys.argv[1])
max_age_min = int(sys.argv[2])
now = datetime.datetime.now(datetime.timezone.utc)

def parse_ts(ts_raw):
    if not ts_raw or not isinstance(ts_raw, str):
        return None
    try:
        s = ts_raw.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = datetime.datetime.fromisoformat(s)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except Exception:
        return None

latest_dt = None
if ambient_path.is_file():
    for line in ambient_path.read_text(errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except Exception:
            continue
        if not isinstance(ev, dict):
            continue
        kind = str(ev.get("kind") or "").strip()
        session = str(ev.get("session") or "").strip()
        if kind in ("farmer_heartbeat", "farmer_tick") or session.startswith("farmer"):
            dt = parse_ts(ev.get("ts"))
            if dt is not None and (latest_dt is None or dt > latest_dt):
                latest_dt = dt

if latest_dt is not None:
    stale_min = int((now - latest_dt).total_seconds() // 60)
    if stale_min <= max_age_min:
        print(f"[farmer-heartbeat-watchdog] OK: farmer heartbeat fresh ({stale_min}m <= {max_age_min}m)")
        sys.exit(0)
else:
    stale_min = max_age_min + 1

ambient_path.parent.mkdir(parents=True, exist_ok=True)
ts_str = now.strftime("%Y-%m-%dT%H:%M:%SZ")
payload = {
    "ts": ts_str,
    "kind": "operator_recall",
    "reason": "farmer_heartbeat_stale",
    "stale_minutes": stale_min,
    "session": "farmer-heartbeat-watchdog",
}
with ambient_path.open("a", encoding="utf-8") as af:
    af.write(json.dumps(payload) + "\n")

print(
    f"[farmer-heartbeat-watchdog] STALE: farmer heartbeat age={stale_min}m (> {max_age_min}m) — emitted operator_recall",
    file=sys.stderr,
)
sys.exit(1)
PY
