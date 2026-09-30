#!/usr/bin/env bash
# digest-delivery-liveness.sh — RESILIENT-1496.
#
# WHY THIS EXISTS. digest-beat.sh (RESILIENT-376) used to treat notify_operator's
# 0 exit code as "delivered" — but notify_operator also returns 0 for
# deliberate no-op paths (CHUMP_OPERATOR_AUTOPOST_DM kill-switch off,
# DISCORD_TOKEN/CHUMP_READY_DM_USER_ID unset, curation-queue defer). That is how
# the digest organ ran on a schedule and reached nobody while logging success
# every cycle (the 0/106-delivered incident this gap was filed over). This PR
# made digest-beat.sh emit kind=chump_digest_suppressed instead of
# chump_digest_posted whenever the send was a no-op; this script reads that
# distinction and alarms when the organ is firing but not actually landing on
# the phone.
#
# NOT an alarm when CHUMP_OPERATOR_AUTOPOST_DM is off: that is the operator's
# own 2026-09-13 "kill everything automated" decision, so suppression is the
# intended state — reported as healthy-and-quiet, not broken.
#
# Usage:
#   bash scripts/coord/digest-delivery-liveness.sh          # check + report
#   bash scripts/coord/digest-delivery-liveness.sh --quiet  # exit code only
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT="$LOCK_DIR/ambient.jsonl"

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

autopost_enabled() {
    case "$(printf '%s' "${CHUMP_OPERATOR_AUTOPOST_DM:-}" | tr '[:upper:]' '[:lower:]')" in
        1 | true | on | yes) return 0 ;;
        *) return 1 ;;
    esac
}

if ! autopost_enabled; then
    [[ $QUIET -eq 1 ]] || echo "[digest-liveness] OK — CHUMP_OPERATOR_AUTOPOST_DM is off, digest suppression is expected (quiet-by-design)"
    exit 0
fi

# Autopost is supposed to be on: the LAST digest-cycle event recorded must be
# an actual delivery (chump_digest_posted), not a suppressed no-op.
last_event="$(python3 - "$AMBIENT" <<'PY'
import json, sys

path = sys.argv[1]
last = None
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
            if e.get("kind") in ("chump_digest_posted", "chump_digest_suppressed"):
                last = e
except FileNotFoundError:
    pass
print(json.dumps(last) if last else "")
PY
)"

if [[ -z "$last_event" ]]; then
    [[ $QUIET -eq 1 ]] || echo "[digest-liveness] UNKNOWN — no digest cycle recorded yet in ambient.jsonl"
    exit 0
fi

kind="$(printf '%s' "$last_event" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("kind",""))' 2>/dev/null)"

if [[ "$kind" == "chump_digest_posted" ]]; then
    [[ $QUIET -eq 1 ]] || echo "[digest-liveness] OK — last digest cycle delivered"
    exit 0
fi

[[ $QUIET -eq 1 ]] || echo "[digest-liveness] ALARM — CHUMP_OPERATOR_AUTOPOST_DM is on but the last digest cycle was suppressed (not delivered): ${last_event}" >&2
printf '{"ts":"%s","kind":"digest_delivery_broken","last_event":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$last_event" >>"$AMBIENT" 2>/dev/null || true
exit 1
