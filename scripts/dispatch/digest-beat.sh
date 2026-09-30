#!/usr/bin/env bash
# digest-beat.sh — RESILIENT-376: the DISCORD DIGEST organ.
#
# WHY THIS EXISTS. Jeff wants a multi-day operating model where he does NOT
# have to sit over a terminal or ping a session to know how the factory is
# doing. The board CEO-briefing (INFRA-3601) fires a Sonnet agent for STRATEGY;
# this organ is the cheaper, deterministic HUMAN-INTERFACE pulse: a short,
# phone-readable digest pushed to Jeff's Discord DM twice a day. No LLM, no
# tokens — pure state read + one DM. It replaces terminal-pinging.
#
# THE DIGEST (four scannable sections, bullets only, no walls of text):
#   SHIPPED         — merges + notable gaps closed since the last digest.
#   THE NUMBER      — Debt Index: organ-liveness (N/total firing) + signal-in-use
#                     (distinct ambient kinds/24h) + today_ships + ci_qa_score.
#   STUCK           — open PRs blocked >2h, main red, any dark (enabled-but-down)
#                     organ.
#   NEEDS-YOUR-CALL — anything requiring Jeff's decision (paged events,
#                     credential/credit asks) in the window.
#
# Send path: REUSES scripts/coord/lib/notify-operator.sh (the exact mechanism
# the board briefing uses — src/discord_dm.rs's REST calls mirrored in bash,
# DISCORD_TOKEN + CHUMP_READY_DM_USER_ID from providers.env/.env). Classified
# CHUMP_NOTIFY_KIND=chump_digest, registered `direct` in the escalation registry
# so it DELIVERS every time but is NOT an escalation (never inflates page-rate,
# never cries wolf — a scheduled owed-message, per RESILIENT-274 discipline).
#
# Cadence: twice daily (09:00 + 18:00 America/Denver) via chump-digest.timer.
#
# Off-switch: CHUMP_DIGEST_ENABLED=0 (default on).
#
# Usage:
#   bash scripts/dispatch/digest-beat.sh            # gather + post
#   bash scripts/dispatch/digest-beat.sh --dry-run  # print, do not post
set -uo pipefail

[[ "${CHUMP_DIGEST_ENABLED:-1}" == "0" ]] && { echo "[digest] disabled via CHUMP_DIGEST_ENABLED=0 — exit"; exit 0; }

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
cd "$REPO_ROOT" || { echo "[digest] cannot cd repo root" >&2; exit 1; }

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { printf '[digest %s] %s\n' "$(ts)" "$*" >&2; }

LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
STATE_DB="$REPO_ROOT/.chump/state.db"
MARKER="$LOCK_DIR/last-digest.ts"
mkdir -p "$LOCK_DIR" 2>/dev/null || true

# ── window: since the last posted digest, floored to 6h and capped at 26h so a
#    first run (or a long outage) still produces a sane, non-empty window. ─────
now_epoch="$(date -u +%s)"
if [[ -f "$MARKER" ]] && last_epoch="$(cat "$MARKER" 2>/dev/null)" && [[ "$last_epoch" =~ ^[0-9]+$ ]]; then
    since_epoch="$last_epoch"
else
    since_epoch=$((now_epoch - 43200))   # default 12h
fi
window_s=$((now_epoch - since_epoch))
(( window_s < 21600 )) && { since_epoch=$((now_epoch - 21600)); window_s=21600; }   # floor 6h
(( window_s > 93600 )) && { since_epoch=$((now_epoch - 93600)); window_s=93600; }   # cap 26h
window_h=$(( (window_s + 1800) / 3600 ))
since_iso="$(date -u -d "@$since_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$since_epoch" +"%Y-%m-%dT%H:%M:%SZ")"

git fetch origin main -q 2>/dev/null || true

# ── SHIPPED: merges (PR-squash commits carry "(#NNNN)") + notable gaps closed ──
# Filter the coherence-sync noise; a merge is a subject ending in (#NNNN).
merges_raw="$(git log origin/main --since="$since_iso" --pretty='%s' 2>/dev/null \
    | grep -vE '^(chore\(backlog\)|Merge (branch|pull|remote))' || true)"
merge_lines="$(printf '%s\n' "$merges_raw" | grep -E '\(#[0-9]+\)$' || true)"
merge_count="$(printf '%s\n' "$merge_lines" | grep -c . || true)"
notable="$(printf '%s\n' "$merge_lines" | head -5 \
    | sed -E 's/ \(#[0-9]+\)$//; s/^(.{72}).+/\1…/; s/^/  • /')"

gaps_closed="0"; gaps_sample=""
if [[ -f "$STATE_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
    gaps_closed="$(sqlite3 "$STATE_DB" \
        "SELECT COUNT(*) FROM gaps WHERE closed_at >= $since_epoch;" 2>/dev/null || echo 0)"
    gaps_sample="$(sqlite3 -separator ' ' "$STATE_DB" \
        "SELECT id, substr(title,1,48) FROM gaps WHERE closed_at >= $since_epoch ORDER BY closed_at DESC LIMIT 4;" 2>/dev/null \
        | sed -E 's/^/  • /')"
fi

# ── THE NUMBER: Debt Index ────────────────────────────────────────────────────
# dashboard-summary for today_ships + ci_qa_score.
dash="$(curl -s --max-time 6 localhost:7070/api/dashboard-summary 2>/dev/null || echo '{}')"
today_ships="$(printf '%s' "$dash" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("today_ships","?"))' 2>/dev/null || echo '?')"
ci_qa="$(printf '%s' "$dash" | python3 -c 'import sys,json
d=json.load(sys.stdin).get("ci_qa_score",{})
print("{}% (n={})".format(d.get("pct","?"), d.get("sample_size","?")))' 2>/dev/null || echo '?')"

# Organ-liveness: from the manifest's `enabled` lines, how many units are active.
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
organs_total=0; organs_up=0; dark_organs=""
if [[ -f "$MANIFEST" ]]; then
    while read -r _state unit _rest; do
        [[ "$_state" == "enabled" ]] || continue
        [[ -n "$unit" ]] || continue
        # Skip units not installed on THIS node — the manifest is the primary
        # (helsinki) roster and CJ carries a subset. A unit whose file is absent
        # here is not-applicable, not dark, so it must not inflate the ratio.
        systemctl cat "$unit" >/dev/null 2>&1 || continue
        organs_total=$((organs_total + 1))
        # A .timer that is active (waiting) is healthy even though its oneshot
        # .service sits inactive between fires; is-active on the .timer unit is
        # the right liveness probe for timer organs, and on the .service for
        # long-running ones. The manifest lists the unit form we must check.
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            organs_up=$((organs_up + 1))
        else
            dark_organs+="${unit} "
        fi
    done < <(grep -E '^enabled' "$MANIFEST")
fi

# Signal-in-use: distinct ambient kinds seen in the last 24h across rotated logs.
signal_kinds="$(python3 - "$LOCK_DIR" <<'PY' 2>/dev/null || echo '?'
import json, glob, gzip, os, sys
from datetime import datetime, timezone, timedelta
lock = sys.argv[1]
cut = datetime.now(timezone.utc) - timedelta(hours=24)
kinds = set()
for f in sorted(glob.glob(os.path.join(lock, "ambient.jsonl*"))):
    if f.endswith(".lock"):
        continue
    op = gzip.open if f.endswith(".gz") else open
    try:
        for line in op(f, "rt", errors="ignore"):
            try:
                e = json.loads(line)
                t = datetime.fromisoformat(e.get("ts", "").replace("Z", "+00:00"))
            except Exception:
                continue
            if t >= cut:
                kinds.add(e.get("kind", ""))
    except Exception:
        pass
print(len(kinds))
PY
)"

# ── STUCK: open PRs blocked >2h, main red, dark organs ───────────────────────
pr_blocked="?"
if command -v gh >/dev/null 2>&1; then
    pr_blocked="$(gh pr list --repo repairman29/chump --state open \
        --json number,createdAt,isDraft --limit 100 2>/dev/null \
        | python3 -c '
import sys,json,datetime
try: d=json.load(sys.stdin)
except Exception: print("?"); raise SystemExit
now=datetime.datetime.now(datetime.timezone.utc)
b=[p for p in d if not p.get("isDraft") and (now-datetime.datetime.fromisoformat(p["createdAt"].replace("Z","+00:00"))).total_seconds()>7200]
print(len(b))' 2>/dev/null || echo '?')"
fi

main_red="unknown"
if command -v gh >/dev/null 2>&1; then
    main_red="$(gh run list --repo repairman29/chump --branch main --limit 15 \
        --json conclusion,status 2>/dev/null \
        | python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: print("unknown"); raise SystemExit
for r in d:
    if r.get("status")!="completed": continue
    c=r.get("conclusion")
    if c in ("skipped","cancelled",None): continue
    print("RED" if c=="failure" else "green"); break
else: print("green")' 2>/dev/null || echo 'unknown')"
fi

dark_count="$(printf '%s' "$dark_organs" | wc -w | tr -d ' ')"
dark_show="$(printf '%s' "$dark_organs" | tr ' ' '\n' | grep -v '^$' | head -5 | tr '\n' ' ')"

# ── NEEDS-YOUR-CALL: paged / credential / credit events in the window ─────────
needs_call="$(python3 - "$LOCK_DIR" "$since_iso" <<'PY' 2>/dev/null || true
import json, glob, gzip, os, sys
from datetime import datetime
lock, since = sys.argv[1], sys.argv[2]
cut = datetime.fromisoformat(since.replace("Z", "+00:00"))
WANT = ("operator_paged", "credential_rotation_needed", "operator_decision_required",
        "security_incident", "credit", "openrouter", "top_up", "top-up", "balance")
seen = {}
for f in sorted(glob.glob(os.path.join(lock, "ambient.jsonl*"))):
    if f.endswith(".lock"):
        continue
    op = gzip.open if f.endswith(".gz") else open
    try:
        for line in op(f, "rt", errors="ignore"):
            try:
                e = json.loads(line)
                t = datetime.fromisoformat(e.get("ts", "").replace("Z", "+00:00"))
            except Exception:
                continue
            if t < cut:
                continue
            k = e.get("kind", "")
            if any(w in k for w in WANT):
                sig = e.get("signal", e.get("class", ""))
                key = f"{k}:{sig}"
                seen[key] = seen.get(key, 0) + 1
    except Exception:
        pass
for key, n in sorted(seen.items(), key=lambda x: -x[1])[:5]:
    k, sig = (key.split(":", 1) + [""])[:2]
    tail = f" ({sig})" if sig else ""
    print(f"  • {k}{tail} ×{n}")
PY
)"

# ── assemble ─────────────────────────────────────────────────────────────────
[[ -z "$notable" ]] && notable="  • (no notable merges)"
[[ -z "$gaps_sample" ]] && gaps_sample=""
[[ "$dark_count" == "0" || -z "$dark_count" ]] && dark_line="dark organs: none" || dark_line="dark organs: ${dark_count} → ${dark_show}"
[[ -z "$needs_call" ]] && needs_call="  • nothing needs your call"

debt_index="organs ${organs_up}/${organs_total} firing · ${signal_kinds} signal-kinds/24h"

read -r -d '' DIGEST <<EOF || true
📟 CHUMP DIGEST · $(date -u -d "@$now_epoch" +"%b %-d %H:%MZ" 2>/dev/null || date -u +"%b %-d %H:%MZ") · last ${window_h}h

SHIPPED
  ${merge_count} merge(s), ${gaps_closed} gap(s) closed
${notable}
$( [[ -n "$gaps_sample" ]] && printf '  closed gaps:\n%s\n' "$gaps_sample" )
THE NUMBER (Debt Index)
  ${debt_index}
  today_ships: ${today_ships} · ci_qa: ${ci_qa}

STUCK
  • PRs blocked >2h: ${pr_blocked}
  • main: ${main_red}
  • ${dark_line}

NEEDS-YOUR-CALL
${needs_call}
EOF

printf '%s\n' "$DIGEST"

if (( DRY_RUN )); then
    log "dry-run — not posting"
    exit 0
fi

# ── post via the shared operator DM path ─────────────────────────────────────
# Register verdict `direct` (delivered, not an escalation) via CHUMP_NOTIFY_KIND.
#
# RESILIENT-1496: notify_operator returns 0 not only on a real Discord send but
# also for deliberate no-op paths — CHUMP_OPERATOR_AUTOPOST_DM kill-switch off,
# DISCORD_TOKEN/CHUMP_READY_DM_USER_ID unset, curation-queue defer. Treating
# that 0 as "posted" is exactly how this organ could run 106 times and reach
# nobody while every cycle logged success. Capture notify-operator's own stderr
# (it already says "delivered" only on a real send) and record which one
# actually happened, so a liveness check downstream can tell "organ didn't run"
# apart from "organ ran, nothing reached the phone".
export CHUMP_NOTIFY_KIND=chump_digest
NOTIFY_OUT="$(mktemp)"
if source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh" && notify_operator "$DIGEST" 2>"$NOTIFY_OUT"; then
    cat "$NOTIFY_OUT" >&2
    printf '%s' "$now_epoch" > "$MARKER"
    if grep -q '\[notify-operator\] delivered' "$NOTIFY_OUT"; then
        # scanner-anchor: "kind":"chump_digest_posted"
        EVENT_KIND="chump_digest_posted"
        log "posted + marker updated"
    else
        # scanner-anchor: "kind":"chump_digest_suppressed"
        EVENT_KIND="chump_digest_suppressed"
        log "digest NOT actually delivered (see notify-operator output above) — recording as suppressed, not posted"
    fi
    rm -f "$NOTIFY_OUT"
    printf '{"ts":"%s","kind":"%s","merges":%s,"gaps_closed":%s,"organs_up":%s,"organs_total":%s}\n' \
        "$(ts)" "$EVENT_KIND" "${merge_count:-0}" "${gaps_closed:-0}" "${organs_up:-0}" "${organs_total:-0}" \
        >> "$LOCK_DIR/ambient.jsonl" 2>/dev/null || true
    exit 0
else
    cat "$NOTIFY_OUT" >&2
    rm -f "$NOTIFY_OUT"
    log "notify_operator FAILED — marker NOT advanced (will retry next beat)"
    exit 1
fi
