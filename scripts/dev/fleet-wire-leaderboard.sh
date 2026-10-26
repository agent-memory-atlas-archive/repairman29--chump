#!/usr/bin/env bash
# CREDIBLE-081: Fleet-wire / broadcast / inbox message-type leaderboard.
# Rust-First-Bypass: <150 LOC read-only reporting glue over ambient.jsonl + EVENT_REGISTRY.yaml.
#
# Usage:
#   scripts/dev/fleet-wire-leaderboard.sh [--window 24h] [--json]
#
# Flags any message type with published_count > 10 and consumer_count == 0 as ZERO_CONSUMER.
# When CHUMP_FLEET_WIRE_ALERT_EMIT=1, appends kind=fleet_wire_zero_consumer to ambient.jsonl.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
AMBIENT_FILE="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REGISTRY_FILE="${REPO_ROOT}/docs/observability/EVENT_REGISTRY.yaml"

WINDOW="24h"
JSON_OUT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window)
            WINDOW="${2:-24h}"
            shift 2
            ;;
        --json)
            JSON_OUT=1
            shift
            ;;
        -h|--help)
            cat <<'EOF'
Usage: scripts/dev/fleet-wire-leaderboard.sh [--window <Nh|Nd|Nm>] [--json]

Report fleet-wire / broadcast / inbox message types published within the time
window alongside their consumer / ack count.

Options:
  --window <T>   Time window (e.g. 60m, 24h, 7d; default: 24h)
  --json         Emit JSON array instead of a markdown/ASCII table
  -h, --help     Show this help message

Example:
  bash scripts/dev/fleet-wire-leaderboard.sh --window 24h --json
EOF
            exit 0
            ;;
        *)
            echo "[fleet-wire-leaderboard] ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# scanner-anchor: "kind":"fleet_wire_zero_consumer"
python3 - "$REPO_ROOT" "$AMBIENT_FILE" "$REGISTRY_FILE" "$WINDOW" "$JSON_OUT" "${CHUMP_FLEET_WIRE_ALERT_EMIT:-0}" <<'PY'
import datetime
import json
import os
import pathlib
import re
import sys

repo_root = pathlib.Path(sys.argv[1])
ambient_path = pathlib.Path(sys.argv[2])
registry_path = pathlib.Path(sys.argv[3])
window_str = sys.argv[4]
json_out = sys.argv[5] == "1"
alert_emit = sys.argv[6] == "1"

m = re.match(r"^(\d+)([smhd])$", window_str.strip())
if not m:
    seconds = 24 * 3600
else:
    val = int(m.group(1))
    unit = m.group(2)
    mult = {"s": 1, "m": 60, "h": 3600, "d": 86400}[unit]
    seconds = val * mult

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(seconds=seconds)

# 1. Load consumer counts from EVENT_REGISTRY.yaml
reg_consumers = {}
if registry_path.is_file():
    cur_kind = None
    in_consumers = False
    for raw in registry_path.read_text(errors="replace").splitlines():
        km = re.match(r"^\s*-\s*kind:\s*([A-Za-z0-9_.-]+)\s*$", raw)
        if km:
            cur_kind = km.group(1)
            reg_consumers.setdefault(cur_kind, set())
            in_consumers = False
            continue
        if cur_kind:
            cm_inline = re.match(r"^\s*consumers:\s*\[(.*)\]\s*$", raw)
            if cm_inline:
                items = [
                    x.strip().strip("'\"")
                    for x in cm_inline.group(1).split(",")
                    if x.strip() and x.strip() not in ("none", "[]")
                ]
                reg_consumers[cur_kind].update(items)
                in_consumers = False
                continue
            if re.match(r"^\s*consumers:\s*$", raw):
                in_consumers = True
                continue
            if in_consumers:
                lm = re.match(r"^\s*-\s*(.+)$", raw)
                if lm:
                    item = lm.group(1).strip().strip("'\"")
                    if item and item != "none":
                        reg_consumers[cur_kind].add(item)
                    continue
                elif re.match(r"^\s*[A-Za-z0-9_]+:", raw):
                    in_consumers = False

# 2. Scan ambient.jsonl within window for fleet_wire_*, broadcast*, inbox_message, dm_sent, nats_*
WIRE_RE = re.compile(r"^(fleet_wire_|broadcast|inbox_|dm_sent|nats_|chump\.events\.)")
published = {}
ack_counts = {}

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
        dt = parse_ts(ev.get("ts"))
        if dt is not None and dt < cutoff:
            continue
        kind = str(ev.get("kind") or "").strip()
        subj = str(ev.get("subject") or ev.get("msg_type") or "").strip()
        key = subj if (subj and kind in ("broadcast", "broadcast_sent", "nats_publish")) else kind
        if not key:
            continue
        if WIRE_RE.search(key) or WIRE_RE.search(kind):
            if key.endswith("_ack") or key.endswith("_received") or kind in ("inbox_read", "broadcast_ack", "fleet_wire_ack"):
                target = str(ev.get("ack_for") or subj or key).replace("_ack", "").replace("_received", "")
                ack_counts[target] = ack_counts.get(target, 0) + 1
            else:
                published[key] = published.get(key, 0) + 1

# Seed known wire message types from broadcast.sh / registry if none in window
for k in sorted(reg_consumers.keys()):
    if WIRE_RE.search(k):
        published.setdefault(k, 0)

rows = []
for key in sorted(published.keys()):
    pub = published.get(key, 0)
    cons_set = set(reg_consumers.get(key, set()))
    # Strip generic self/ambient placeholders when counting real consumers if ack_counts is 0
    real_cons = [c for c in cons_set if c not in ("", "none")]
    cons_count = len(real_cons) + ack_counts.get(key, 0)
    if pub > 10 and cons_count == 0:
        status = "ZERO_CONSUMER"
    elif pub == 0:
        status = "IDLE"
    else:
        status = "HEALTHY"
    rows.append({
        "subject_or_kind": key,
        "published_count": pub,
        "consumer_count": cons_count,
        "ack_count": ack_counts.get(key, 0),
        "status": status,
    })

if alert_emit:
    ambient_path.parent.mkdir(parents=True, exist_ok=True)
    ts_now = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    with ambient_path.open("a", encoding="utf-8") as af:
        for r in rows:
            if r["status"] == "ZERO_CONSUMER":
                payload = {
                    "ts": ts_now,
                    "kind": "fleet_wire_zero_consumer",
                    "subject_or_kind": r["subject_or_kind"],
                    "published_count": r["published_count"],
                    "consumer_count": r["consumer_count"],
                    "window": window_str,
                }
                af.write(json.dumps(payload) + "\n")

if json_out:
    print(json.dumps(rows, indent=2))
else:
    print(f"# Fleet-Wire Message Leaderboard (window={window_str})")
    print(f"{'SUBJECT_OR_KIND':<36} {'PUBLISHED':>10} {'CONSUMERS':>10} {'STATUS':<15}")
    print("-" * 75)
    for r in rows:
        print(f"{r['subject_or_kind']:<36} {r['published_count']:>10} {r['consumer_count']:>10} {r['status']:<15}")
PY
