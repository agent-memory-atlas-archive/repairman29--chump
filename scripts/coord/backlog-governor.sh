#!/usr/bin/env bash
# backlog-governor.sh — INFRA-8175 (NODE-SHIPS)
#
# Autonomous backlog governor organ:
#   1. Computes open gap counts by priority (P0..P3) and 24h net burn
#      (net_burn_24h = shipped_24h - filed_24h) from state.db.
#   2. Detects wedges (starved P0/P1 tiers, stale in_progress claims, expired
#      .chump-locks/claim-*.json leases).
#   3. Under --apply (or CHUMP_BACKLOG_GOVERNOR_APPLY=1), heals expired leases
#      and resets stale in_progress claims to open.
#   4. Stays silent (never pages the operator) when net-burn-positive.
#   5. Emits kind=backlog_governor_tick to .chump-locks/ambient.jsonl.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
LOCKS_DIR="${CHUMP_LOCKS_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCKS_DIR/ambient.jsonl}"
STATE_DB="${CHUMP_STATE_DB:-$LOCKS_DIR/state.db}"
if [[ ! -f "$STATE_DB" && -f "${HOME:-}/.chump/state.db" ]]; then
  STATE_DB="${HOME}/.chump/state.db"
fi

APPLY="${CHUMP_BACKLOG_GOVERNOR_APPLY:-0}"
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --json) shift ;;
    *) shift ;;
  esac
done

STALE_SECS="${CHUMP_BACKLOG_STALE_LEASE_SECS:-7200}"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TICK_JSON="$(python3 - "$STATE_DB" "$LOCKS_DIR" "$APPLY" "$DRY_RUN" "$STALE_SECS" "$NOW_ISO" <<'PY'
import datetime, glob, json, os, sqlite3, sys, time

state_db, locks_dir, apply_flag, dry_run_flag, stale_secs, now_iso = (
    sys.argv[1],
    sys.argv[2],
    int(sys.argv[3]) == 1,
    int(sys.argv[4]) == 1,
    int(sys.argv[5]),
    sys.argv[6],
)

now_ts = time.time()
cut_dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=24)
cut_iso = cut_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
cut_sql = cut_dt.strftime("%Y-%m-%d %H:%M:%S")
stale_cut_dt = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=stale_secs)
stale_cut_iso = stale_cut_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

open_counts = {"P0": 0, "P1": 0, "P2": 0, "P3": 0}
in_progress_counts = {"P0": 0, "P1": 0, "P2": 0, "P3": 0}
filed_24h = 0
shipped_24h = 0
wedges = []
healed_leases = 0

# 1. Inspect and optionally reap expired claim-*.json leases in locks_dir
active_leased_gaps = set()
if os.path.isdir(locks_dir):
    for lpath in sorted(glob.glob(os.path.join(locks_dir, "claim-*.json"))):
        try:
            with open(lpath, "r", encoding="utf-8") as fh:
                ldata = json.load(fh)
        except Exception:
            ldata = {}
        gap_id = str(ldata.get("gap_id") or ldata.get("gap") or "")
        exp = str(ldata.get("expires_at") or "")
        hb = str(ldata.get("heartbeat_at") or ldata.get("claimed_at") or "")
        mtime = os.path.getmtime(lpath)
        is_expired = False
        if exp and exp < now_iso:
            is_expired = True
        elif hb and hb < stale_cut_iso:
            is_expired = True
        elif (now_ts - mtime) > stale_secs:
            is_expired = True

        if is_expired:
            wedges.append(f"expired_lease:{os.path.basename(lpath)}")
            if apply_flag and not dry_run_flag:
                try:
                    os.remove(lpath)
                    healed_leases += 1
                except OSError:
                    pass
        elif gap_id:
            active_leased_gaps.add(gap_id)

# 2. Query state.db for open priorities, 24h filed vs shipped, and stale in_progress claims
if os.path.isfile(state_db):
    try:
        conn = sqlite3.connect(state_db, timeout=5.0)
        cur = conn.cursor()
        cur.execute("PRAGMA table_info(gaps)")
        cols = {row[1] for row in cur.fetchall()}
        if "status" in cols and "priority" in cols:
            cur.execute(
                "SELECT UPPER(COALESCE(priority, 'P2')), LOWER(COALESCE(status, 'open')), COUNT(*) "
                "FROM gaps WHERE LOWER(COALESCE(status, 'open')) IN ('open', 'in_progress', 'claimed') "
                "GROUP BY 1, 2"
            )
            for prio, st, cnt in cur.fetchall():
                p = prio if prio in open_counts else "P2"
                open_counts[p] += int(cnt)
                if st in ("in_progress", "claimed"):
                    in_progress_counts[p] += int(cnt)

            created_col = "created_at" if "created_at" in cols else ("opened_date" if "opened_date" in cols else None)
            if created_col:
                cur.execute(
                    f"SELECT COUNT(*) FROM gaps WHERE {created_col} >= ? OR {created_col} >= ?",
                    (cut_iso, cut_sql),
                )
                filed_24h = int(cur.fetchone()[0] or 0)

            ship_cols = [c for c in ("completed_at", "shipped_at", "closed_at", "closed_date", "updated_at", "created_at") if c in cols]
            if ship_cols:
                coalesce_expr = ship_cols[0] if len(ship_cols) == 1 else f"COALESCE({', '.join(ship_cols)})"
                cur.execute(
                    f"SELECT COUNT(*) FROM gaps WHERE LOWER(status) IN ('done', 'closed', 'shipped') AND ({coalesce_expr} >= ? OR {coalesce_expr} >= ?)",
                    (cut_iso, cut_sql),
                )
                shipped_24h = int(cur.fetchone()[0] or 0)

            # Detect stale in_progress claims without an active lease
            id_col = "id" if "id" in cols else ("gap_id" if "gap_id" in cols else None)
            ts_col = "updated_at" if "updated_at" in cols else ("claimed_at" if "claimed_at" in cols else created_col)
            if id_col:
                ts_expr = ts_col if ts_col else "''"
                cur.execute(
                    f"SELECT {id_col}, {ts_expr} FROM gaps WHERE LOWER(status) IN ('in_progress', 'claimed')"
                )
                stale_ids = []
                for gid, gts in cur.fetchall():
                    gid_s = str(gid or "")
                    gts_s = str(gts or "")
                    if gid_s not in active_leased_gaps and (not gts_s or gts_s < stale_cut_iso):
                        wedges.append(f"stale_in_progress:{gid_s}")
                        stale_ids.append(gid_s)
                if stale_ids and apply_flag and not dry_run_flag:
                    for sid in stale_ids:
                        cur.execute(f"UPDATE gaps SET status = 'open' WHERE {id_col} = ?", (sid,))
                        healed_leases += 1
                    conn.commit()
        conn.close()
    except Exception as exc:
        wedges.append(f"state_db_error:{type(exc).__name__}")

if open_counts["P0"] > 0 and in_progress_counts["P0"] == 0:
    wedges.append("starved_tier:P0")
if open_counts["P1"] > 0 and in_progress_counts["P0"] == 0 and in_progress_counts["P1"] == 0 and (in_progress_counts["P2"] + in_progress_counts["P3"]) > 0:
    wedges.append("priority_inversion:P2_P3_active_while_P1_waiting")

open_total = sum(open_counts.values())
net_burn_24h = shipped_24h - filed_24h
burn_state = "net_burn_positive" if net_burn_24h > 0 else ("steady" if net_burn_24h == 0 else "accumulating")

out = {
    "ts": now_iso,
    "kind": "backlog_governor_tick",
    "open_total": open_total,
    "open_p0": open_counts["P0"],
    "open_p1": open_counts["P1"],
    "open_p2": open_counts["P2"],
    "open_p3": open_counts["P3"],
    "filed_24h": filed_24h,
    "shipped_24h": shipped_24h,
    "net_burn_24h": net_burn_24h,
    "burn_state": burn_state,
    "wedges": wedges,
    "healed_leases": healed_leases,
    "operator_paged": False,
}
print(json.dumps(out, separators=(",", ":")))
PY
)"

if [[ "$DRY_RUN" -eq 0 ]]; then
  mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
  printf '%s\n' "$TICK_JSON" >> "$AMBIENT_LOG" 2>/dev/null || true
fi

printf '%s\n' "$TICK_JSON"
