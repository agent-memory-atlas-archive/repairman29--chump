#!/usr/bin/env bash
# scripts/coord/operator-digest.sh — INFRA-1302
#
# Daily 9am digest of FEEDBACK / STUCK / DONE activity for the operator.
# Async catch-up channel: operator steps away for a day, comes back to a
# scannable summary instead of 200 raw ambient events.
#
# Aggregates from $LOCK_DIR/ambient.jsonl + feedback.jsonl over last 24h:
#   - Top FEEDBACK clusters (by distinct session count)
#   - Unresolved STUCK events (no matching DONE for the corr_id)
#   - Shipped DONE count grouped by domain
#   - Pending operator decisions (HANDOFF unaddressed in operator inbox)
#
# Output formats:
#   --human (default) — readable text
#   --json            — machine-readable
#   --discord-webhook — POST to webhook URL from .chump/discord-config.json
#
# Cron: daily at 09:00 local via launchd.
# Operator can disable via CHUMP_NO_DIGEST=1 OR operator-rules.yaml.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="$LOCK_DIR/ambient.jsonl"
FEEDBACK="$LOCK_DIR/feedback.jsonl"

FORMAT="human"
WINDOW_H=24
DISCORD=0
while [ $# -gt 0 ]; do
    case "$1" in
        --json) FORMAT="json"; shift ;;
        --human) FORMAT="human"; shift ;;
        --discord-webhook) DISCORD=1; shift ;;
        --window) WINDOW_H="$2"; shift 2 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "[operator-digest] unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ "${CHUMP_NO_DIGEST:-0}" = "1" ]; then
    echo "[operator-digest] disabled via CHUMP_NO_DIGEST=1"
    exit 0
fi

# Generate the digest JSON via python (one-shot parse of both streams).
DIGEST_JSON="$(python3 - "$AMBIENT" "$FEEDBACK" "$WINDOW_H" <<'PY'
import json, sys
from collections import Counter, defaultdict
from datetime import datetime, timezone, timedelta

ambient_path, feedback_path, window_h = sys.argv[1], sys.argv[2], int(sys.argv[3])
cutoff = datetime.now(timezone.utc) - timedelta(hours=window_h)

def read_events(path):
    out = []
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                ts = e.get("ts", "")
                try:
                    t = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except Exception:
                    continue
                if t < cutoff:
                    continue
                out.append(e)
    except FileNotFoundError:
        pass
    return out

ambient = read_events(ambient_path)
feedback = read_events(feedback_path)

# FEEDBACK clusters by (kind, subject) with distinct-session counts.
fb_clusters = defaultdict(set)
for e in feedback:
    if e.get("event") != "FEEDBACK":
        continue
    key = (e.get("kind", ""), e.get("subject", ""))
    fb_clusters[key].add(e.get("session", "?"))
top_fb = sorted(
    (
        {"kind": k[0], "subject": k[1], "n_sessions": len(s)}
        for k, s in fb_clusters.items()
    ),
    key=lambda x: -x["n_sessions"],
)[:5]

# Unresolved STUCK: no DONE with matching corr_id in window.
done_corr = {e.get("corr_id", "") for e in ambient if e.get("event") == "DONE"}
unresolved = []
for e in ambient:
    if e.get("event") != "STUCK":
        continue
    cid = e.get("corr_id", "")
    if cid and cid in done_corr:
        continue
    unresolved.append({
        "subject": e.get("subject") or e.get("gap") or "?",
        "ts": e.get("ts", ""),
        "reason": (e.get("reason") or "")[:140],
        "from_session": e.get("session", "?"),
    })
unresolved = unresolved[-10:]  # last 10 only

# DONE counts by domain (subject prefix or "OTHER").
done_by_domain = Counter()
for e in ambient:
    if e.get("event") != "DONE":
        continue
    subj = e.get("subject") or e.get("gap") or ""
    if "-" in subj:
        head = subj.split("-", 1)[0]
        if head.isupper():
            done_by_domain[head] += 1
            continue
    done_by_domain["OTHER"] += 1

# Pending HANDOFFs in any operator-* inbox (best-effort scan).
import os, glob
pending_handoffs = []
inbox_glob = os.path.join(os.path.dirname(ambient_path), "inbox", "operator-*.jsonl")
for path in glob.glob(inbox_glob):
    session = os.path.basename(path)[:-6]  # strip .jsonl
    cursor_path = path[:-6] + ".read-cursor"
    cursor = ""
    if os.path.exists(cursor_path):
        try:
            with open(cursor_path) as fh:
                cursor = fh.read().strip()
        except Exception:
            pass
    try:
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if e.get("event") != "HANDOFF":
                    continue
                ts = e.get("ts", "")
                if cursor and ts <= cursor:
                    continue
                pending_handoffs.append({
                    "operator": session,
                    "subject": e.get("subject") or e.get("gap") or "?",
                    "ts": ts,
                    "from_session": e.get("session", "?"),
                })
    except FileNotFoundError:
        pass

print(json.dumps({
    "window_hours": window_h,
    "top_feedback_clusters": top_fb,
    "unresolved_stuck": unresolved,
    "done_by_domain": dict(done_by_domain),
    "pending_operator_handoffs": pending_handoffs[-10:],
    "totals": {
        "feedback": len(feedback),
        "ambient": len(ambient),
        "done": sum(done_by_domain.values()),
        "unresolved_stuck": len(unresolved),
    },
}, indent=2))
PY
)"

if [ "$FORMAT" = "json" ]; then
    printf '%s\n' "$DIGEST_JSON"
else
    python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(f'=== Operator Digest (last {d[\"window_hours\"]}h) ===')
t = d['totals']
print(f'Totals: {t[\"feedback\"]} feedback, {t[\"done\"]} shipped, {t[\"unresolved_stuck\"]} unresolved STUCK')
print()
fb = d['top_feedback_clusters']
print(f'Top FEEDBACK clusters ({len(fb)} shown):')
if not fb:
    print('  (none)')
for c in fb:
    print(f\"  {c['n_sessions']}× {c['kind']:<10} {c['subject']}\")
print()
done = d['done_by_domain']
print(f'Shipped by domain:')
if not done:
    print('  (none)')
for dom, n in sorted(done.items(), key=lambda kv: -kv[1]):
    print(f'  {n:>3}  {dom}')
print()
us = d['unresolved_stuck']
print(f'Unresolved STUCK (top {len(us)}):')
if not us:
    print('  (none)')
for s in us:
    print(f\"  {s['subject']:<20} {s['from_session']}: {s['reason'][:80]}\")
print()
ph = d['pending_operator_handoffs']
print(f'Pending operator HANDOFFs ({len(ph)} shown):')
if not ph:
    print('  (none)')
for p in ph:
    print(f\"  {p['operator']}: {p['subject']} (from {p['from_session']})\")
" <<< "$DIGEST_JSON"
fi

# Discord delivery (best-effort; never fails the cron run).
#
# RESILIENT-1496: this used to POST ONLY to a webhook URL read from
# .chump/discord-config.json — a file that never existed on the operator's
# machine, so --discord-webhook was a silent no-op from day one (INFRA-1302).
# The canonical Discord destination that actually exists and is exercised
# daily is DISCORD_TOKEN + CHUMP_READY_DM_USER_ID via
# scripts/coord/lib/notify-operator.sh (the same path digest-beat.sh /
# RESILIENT-376 uses). Prefer the webhook file when an operator has set one up
# (kept for backward compat), else fall back to the canonical DM path so this
# flag has one working destination instead of a config file nobody wrote.
if [ "$DISCORD" = "1" ]; then
    CONTENT=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
t = d['totals']
lines = [
    f\"**Chump operator digest** — last {d['window_hours']}h\",
    f\"{t['feedback']} feedback · {t['done']} shipped · {t['unresolved_stuck']} unresolved STUCK\",
]
fb = d.get('top_feedback_clusters', [])
if fb:
    lines.append('Top feedback: ' + ', '.join(f\"{c['n_sessions']}× {c['subject']}\" for c in fb[:3]))
print('\\n'.join(lines))
" <<< "$DIGEST_JSON")

    DISCORD_CFG="$REPO_ROOT/.chump/discord-config.json"
    WEBHOOK=""
    if [ -f "$DISCORD_CFG" ]; then
        WEBHOOK="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('digest_webhook',''))" "$DISCORD_CFG" 2>/dev/null)"
    fi
    if [ -n "$WEBHOOK" ]; then
        curl -s -X POST -H 'content-type: application/json' \
            -d "$(python3 -c "import json,sys; print(json.dumps({'content': sys.argv[1]}))" "$CONTENT")" \
            "$WEBHOOK" >/dev/null 2>&1 || true
    else
        CHUMP_NOTIFY_KIND=chump_digest
        export CHUMP_NOTIFY_KIND
        # shellcheck source=lib/notify-operator.sh
        if [ -f "$SCRIPT_DIR/lib/notify-operator.sh" ]; then
            source "$SCRIPT_DIR/lib/notify-operator.sh"
            notify_operator "$CONTENT" || true
        fi
    fi
fi

# Audit event so chump kpi can track digest hygiene.
python3 -c "
import json, sys, datetime
d = json.loads(sys.argv[1])
e = {
    'ts': datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
    'kind': 'operator_digest_emitted',
    'window_hours': d['window_hours'],
    'totals': d['totals'],
    'format': sys.argv[2],
}
print(json.dumps(e))
" "$DIGEST_JSON" "$FORMAT" >> "$AMBIENT" 2>/dev/null || true
