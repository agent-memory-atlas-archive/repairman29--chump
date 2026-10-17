#!/usr/bin/env python3
# INFRA-155: gap-store drift detector + repair tool.
#
# State.db (canonical since INFRA-059) and docs/gaps/<ID>.yaml (human-readable
# per-file mirrors) routinely disagree because pre-INFRA-152 close PRs hand-edited
# YAML without updating state.db. Cold Water reads state.db via
# `chump gap list --status open`, so YAML closures invisible to the DB show
# up as OPEN-BUT-LANDED in the audit. Issue #8 named this as 65/88 (74%) of
# all open gaps; this tool drains the existing backlog and reports residual
# drift so the next sweep is targeted.
#
# Modes (all read-only by default; pass --apply to mutate):
#
#   doctor          Print a 4-bucket drift report:
#                     1. DB done / YAML open  — DB ahead of YAML, regen needed
#                     2. DB open / YAML done  — pre-INFRA-152 hand-edit; DB
#                                                missed the closure
#                     3. DB-only IDs          — gaps in state.db with no YAML
#                                                row (orphans)
#                     4. YAML-only IDs        — gaps in YAML with no DB row
#                                                (skipped on import)
#
#   sync-from-yaml  For bucket 2 (DB open / YAML done): UPDATE state.db
#                   rows to match YAML's status='done', pulling closed_at,
#                   closed_date, closed_pr from the YAML entry. Idempotent.
#
#   sync-from-db    For bucket 1 (DB done / YAML open): rewrite per-file YAML
#                   rows from the DB. Implemented by calling `chump gap dump
#                   --per-file --out-dir docs/gaps` (post-INFRA-188).
#
# Read-only by default. Use --apply to actually mutate.
#
# Usage:
#   scripts/coord/gap-doctor.py doctor
#   scripts/coord/gap-doctor.py sync-from-yaml [--apply]
#   scripts/coord/gap-doctor.py sync-from-db [--apply]

# INFRA-353: defer annotation evaluation so `int | None` (PEP 604) and
# similar 3.10+ syntax doesn't error on Python 3.7-3.9. With this future
# import, all annotations become strings and are not evaluated at runtime.
# Cheap forward-compat: works back to 3.7 (PEP 563), no behavior change.
from __future__ import annotations

# INFRA-2000 Phase 1 feature-flag shim (META-107 Rust-first migration).
# When CHUMP_GAP_MAINTENANCE_RUST=1 the Rust binary handles the call; the
# legacy Python body below stays in tree for 1-week parallel-run discipline.
import os as _infra2000_os
import sys as _infra2000_sys
if _infra2000_os.environ.get("CHUMP_GAP_MAINTENANCE_RUST") == "1":
    _infra2000_os.execvp("chump-gap-doctor", ["chump-gap-doctor", *_infra2000_sys.argv[1:]])

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    import yaml
except ImportError:
    print("error: PyYAML not installed (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------
# INFRA-1424: gap_drift alert source deduplication
# ---------------------------------------------------------------------------

_DRIFT_ALERT_STATE_FILE = "drift-alert-state.json"
# Default dedup window: 60 minutes. Override via CHUMP_DRIFT_ALERT_WINDOW_MIN.
_DEFAULT_DRIFT_ALERT_WINDOW_MIN = 60


def _drift_alert_window_min() -> int:
    """Return the dedup window in minutes (env-configurable)."""
    try:
        return int(os.environ.get("CHUMP_DRIFT_ALERT_WINDOW_MIN", _DEFAULT_DRIFT_ALERT_WINDOW_MIN))
    except (ValueError, TypeError):
        return _DEFAULT_DRIFT_ALERT_WINDOW_MIN


def _subject_hash(kind: str, ids: list) -> str:
    """Stable hash for (kind, sorted-ids) — same alert always → same hash."""
    payload = kind + "\x00" + "\x00".join(sorted(ids))
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def _load_drift_alert_state(locks_dir: Path) -> dict:
    """Load {subject_hash: last_emit_ts_unix} from drift-alert-state.json.

    Returns empty dict on any read/parse error (fail-open: let the emit happen).
    """
    state_path = locks_dir / _DRIFT_ALERT_STATE_FILE
    if not state_path.exists():
        return {}
    try:
        return json.loads(state_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}


def _save_drift_alert_state(locks_dir: Path, state: dict) -> None:
    """Atomically write drift-alert-state.json (write-tmp, rename)."""
    locks_dir.mkdir(parents=True, exist_ok=True)
    state_path = locks_dir / _DRIFT_ALERT_STATE_FILE
    tmp_fd, tmp_name = tempfile.mkstemp(dir=locks_dir, prefix=".drift-alert-state-", suffix=".tmp")
    try:
        with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
            json.dump(state, f, separators=(",", ":"))
            f.write("\n")
        os.replace(tmp_name, state_path)
    except OSError:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass


def _prune_drift_alert_state(state: dict, window_min: int) -> dict:
    """Remove entries older than 2× the dedup window to keep the file small."""
    cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - (window_min * 2 * 60)
    return {k: v for k, v in state.items() if v >= cutoff}


def should_emit_drift_alert(
    locks_dir: Path,
    kind: str,
    ids: list,
) -> tuple:
    """Return (should_emit, subject_hash) and update state if emitting.

    Only emits if (kind, subject_hash) was not emitted within the last
    CHUMP_DRIFT_ALERT_WINDOW_MIN minutes (default 60).

    This function is idempotent on the "no" path — it only mutates state
    when it returns should_emit=True.
    """
    window_min = _drift_alert_window_min()
    shash = _subject_hash(kind, ids)
    state = _load_drift_alert_state(locks_dir)
    state = _prune_drift_alert_state(state, window_min)

    last_emit = state.get(shash)
    now_ts = dt.datetime.now(dt.timezone.utc).timestamp()
    if last_emit is not None and (now_ts - last_emit) < (window_min * 60):
        return False, shash

    # Mark this hash as emitted now, then save
    state[shash] = now_ts
    _save_drift_alert_state(locks_dir, state)
    return True, shash


# ---------------------------------------------------------------------------


def repo_root() -> Path:
    """Return the directory whose `.chump/state.db` is canonical.

    Linked worktrees each have their own `.chump/` directory but the chump
    binary writes to the *main* worktree's state.db (its `repo_root` is
    baked at install time). Walk `git worktree list --porcelain` to find
    the first listed worktree (= the main one) and use that. If that
    state.db doesn't exist, fall back to the current worktree's root.
    """
    porcelain = subprocess.check_output(
        ["git", "worktree", "list", "--porcelain"], text=True
    )
    main_path = None
    for line in porcelain.splitlines():
        if line.startswith("worktree "):
            main_path = Path(line[len("worktree "):])
            break
    if main_path and (main_path / ".chump" / "state.db").exists():
        size = (main_path / ".chump" / "state.db").stat().st_size
        if size > 0:
            return main_path
    out = subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True)
    return Path(out.strip())


def load_yaml_status(root: Path) -> dict:
    """Returns {gap_id: yaml_dict_for_that_gap}. Reads per-file YAML only.

    INFRA-389: post-INFRA-188 the canonical mirror is the per-file directory
    docs/gaps/<ID>.yaml, not the monolithic docs/gaps.yaml (which is now
    .gitignored as a side-effect of stale chump binaries). Only read from
    the per-file directory.
    """
    out = {}
    per_file_dir = root / "docs" / "gaps"

    if not per_file_dir.is_dir():
        return out

    # Each docs/gaps/<ID>.yaml is the chump-gap-dump-per-file shape:
    # a one-element list whose first entry is the gap dict.
    for path in sorted(per_file_dir.glob("*.yaml")):
        try:
            data = yaml.safe_load(path.read_text(encoding="utf-8"))
        except Exception:
            continue
        entries = data if isinstance(data, list) else [data]
        for g in entries:
            if not isinstance(g, dict):
                continue
            gid = g.get("id")
            if gid:
                out[gid] = g
    return out


def load_db_status(root: Path) -> dict:
    """Returns {gap_id: row_dict}."""
    db = root / ".chump" / "state.db"
    conn = sqlite3.connect(str(db))
    conn.row_factory = sqlite3.Row
    cur = conn.execute(
        "SELECT id, status, closed_at, closed_date, closed_pr FROM gaps"
    )
    out = {row["id"]: dict(row) for row in cur}
    conn.close()
    return out


def cmd_doctor(args, root: Path) -> int:
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)

    db_done_yaml_open = []
    db_open_yaml_done = []
    db_only = []
    yaml_only = []

    all_ids = set(yaml_view) | set(db_view)
    for gid in sorted(all_ids):
        y = yaml_view.get(gid)
        d = db_view.get(gid)
        if d is None:
            yaml_only.append(gid)
            continue
        if y is None:
            db_only.append(gid)
            continue
        if d["status"] == "done" and y.get("status") != "done":
            db_done_yaml_open.append(gid)
        elif d["status"] == "open" and y.get("status") == "done":
            db_open_yaml_done.append(gid)

    print("== gap-doctor: drift report ==")
    print(f"  Total gaps in YAML : {len(yaml_view)}")
    print(f"  Total gaps in DB   : {len(db_view)}")
    print()
    print(
        f"  Bucket 1 — DB done / YAML open   : {len(db_done_yaml_open):3} "
        "(regenerate YAML)"
    )
    for gid in db_done_yaml_open:
        print(f"      {gid}")
    print(
        f"  Bucket 2 — DB open / YAML done   : {len(db_open_yaml_done):3} "
        "(sync DB from YAML)"
    )
    for gid in db_open_yaml_done:
        print(f"      {gid}")
    print(
        f"  Bucket 3 — DB-only / YAML missing: {len(db_only):3} "
        "(orphan rows in DB)"
    )
    for gid in db_only:
        print(f"      {gid}")
    print(
        f"  Bucket 4 — YAML-only / DB missing: {len(yaml_only):3} "
        "(import skipped)"
    )
    for gid in yaml_only[:20]:
        print(f"      {gid}")
    if len(yaml_only) > 20:
        print(f"      ... {len(yaml_only) - 20} more")

    drift_total = (
        len(db_done_yaml_open) + len(db_open_yaml_done)
        + len(db_only) + len(yaml_only)
    )
    print()
    print(f"  Total drift entries: {drift_total}")
    return 0 if drift_total == 0 else 1


def parse_iso_to_unix(s: str) -> int:
    """ISO YYYY-MM-DD -> unix epoch (UTC midnight). Returns 0 on parse fail."""
    if not s:
        return 0
    try:
        dtobj = dt.datetime.strptime(s.strip().strip("'").strip('"'), "%Y-%m-%d")
        dtobj = dtobj.replace(tzinfo=dt.timezone.utc)
        return int(dtobj.timestamp())
    except ValueError:
        return 0


def coerce_int(v) -> int | None:
    if v is None:
        return None
    if isinstance(v, int):
        return v if v > 0 else None
    if isinstance(v, str):
        s = v.strip().strip("'").strip('"')
        try:
            n = int(s)
            return n if n > 0 else None
        except ValueError:
            return None
    return None


def cmd_sync_from_yaml(args, root: Path) -> int:
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)

    db = root / ".chump" / "state.db"
    conn = sqlite3.connect(str(db))
    cur = conn.cursor()

    plan = []
    for gid, y in yaml_view.items():
        if y.get("status") != "done":
            continue
        d = db_view.get(gid)
        if d is None:
            # Bucket 4 — DB doesn't even have the row. Skipped here; that's
            # an import problem, not a status sync problem.
            continue
        if d["status"] == "done":
            continue
        # YAML done, DB open. Build the UPDATE.
        cd_raw = y.get("closed_date")
        if isinstance(cd_raw, dt.date):
            closed_date = cd_raw.isoformat()
        elif isinstance(cd_raw, str):
            closed_date = cd_raw.strip().strip("'").strip('"')
        else:
            closed_date = ""
        closed_pr = coerce_int(y.get("closed_pr"))
        closed_at = parse_iso_to_unix(closed_date)
        plan.append((gid, closed_date, closed_pr, closed_at))

    print(f"== sync-from-yaml: {len(plan)} rows to update ==")
    for gid, cd, cp, ca in plan:
        print(f"  {gid:14}  status open->done  closed_date={cd!r:14}  closed_pr={cp}")

    if not args.apply:
        print()
        print("(dry-run — pass --apply to mutate state.db)")
        return 0

    if not plan:
        print("nothing to do")
        return 0

    for gid, cd, cp, ca in plan:
        try:
            cmd = ["chump", "gap", "ship", gid]
            if cp:
                cmd.extend(["--closed-pr", str(cp)])
            subprocess.run(
                cmd,
                check=True, capture_output=True, text=True
            )
        except (FileNotFoundError, subprocess.CalledProcessError) as e:
            print(f"  WARN {gid}: chump gap ship failed, falling back to direct DB update: {str(e)[:60]}", file=sys.stderr)
            cur.execute(
                "UPDATE gaps SET status='done', closed_at=?, closed_date=?, closed_pr=? "
                "WHERE id=? AND status='open'",
                (ca if ca > 0 else None, cd, cp, gid),
            )
    conn.commit()
    conn.close()
    print(f"applied: {len(plan)} rows")

    # INFRA-8193: .chump/state.sql left git; no dump is regenerated here.
    return 0


def cmd_sync_from_db(args, root: Path) -> int:
    """Regenerate the per-file docs/gaps/<ID>.yaml mirrors from state.db.
    Closes Bucket 1 (DB done / YAML open) by overwriting YAML rows with DB
    truth.

    INFRA-389: post-INFRA-188 the monolithic docs/gaps.yaml is gone — the
    canonical mirror is the per-file directory. Pre-fix this command wrote
    to the deleted path and either failed or recreated a stale monolithic
    file (chump dump's monolithic-by-default footgun before --per-file).
    """
    out_dir = root / "docs" / "gaps"
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)
    plan = [
        gid for gid, d in db_view.items()
        if d["status"] == "done"
        and yaml_view.get(gid, {}).get("status") != "done"
    ]

    if not args.apply:
        print(f"== sync-from-db: {len(plan)} rows would flip in YAML ==")
        for gid in plan:
            print(f"  {gid}")
        print()
        print(f"(dry-run — pass --apply to regenerate per-file YAMLs in {out_dir}/)")
        return 0

    r = subprocess.run(
        ["chump", "gap", "dump", "--per-file", "--out-dir", str(out_dir)],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"chump gap dump --per-file failed: {r.stderr}", file=sys.stderr)
        return 1
    print(f"regenerated per-file YAMLs in {out_dir}/ ({len(plan)} flipped)")
    return 0


def _prune_yaml_orphans(root: Path, candidate_ids: list) -> None:
    """EFFECTIVE-219: delete docs/gaps/<ID>.yaml ONLY when a fresh state.db
    re-check confirms the row is absent. STATE WINS — never trust the
    caller's snapshot for the actual delete decision; a sibling session
    could have reserved the ID in the window between the snapshot and now.

    For any candidate whose state.db row turns out to exist after all
    (divergence caught by the re-check), the YAML is rewritten from
    state.db instead of deleted, and a note is printed so the operator can
    see the near-miss.
    """
    import subprocess

    db_view_fresh = load_db_status(root)
    gaps_dir = root / "docs" / "gaps"

    try:
        common_dir = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            cwd=root, capture_output=True, text=True, check=True
        ).stdout.strip()
        main_repo = root if common_dir == ".git" else Path(common_dir).parent.resolve()
    except subprocess.CalledProcessError:
        main_repo = root
    ambient = main_repo / ".chump-locks" / "ambient.jsonl"
    locks_dir = ambient.parent
    locks_dir.mkdir(parents=True, exist_ok=True)

    from datetime import datetime, timezone
    pruned = 0
    for gid in candidate_ids:
        yaml_path = gaps_dir / f"{gid}.yaml"
        if gid in db_view_fresh:
            # Divergence since the snapshot: a row now exists. State wins —
            # rewrite from DB rather than delete.
            print(f"[safe-sweep] {gid}: state.db row appeared since snapshot — rewriting YAML, not deleting")
            cmd_sync_from_db(argparse.Namespace(apply=True), root)
            continue
        if not yaml_path.exists():
            continue
        yaml_path.unlink()
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        evt = {
            "ts": ts, "event": "INFO", "kind": "yaml_orphan_pruned",
            "gap_id": gid, "file_path": str(yaml_path.relative_to(root)),
            "reason": "yaml_only_no_db_row", "daemon_name": "gap-doctor-safe-sweep",
        }
        with ambient.open("a") as f:
            f.write(json.dumps(evt, separators=(",", ":")) + "\n")
        pruned += 1
        print(f"[safe-sweep] pruned orphan {yaml_path.relative_to(root)} (no state.db row)")
    if pruned:
        print(f"\n[safe-sweep] pruned {pruned} orphan YAML(s)")


def cmd_safe_sweep(args, root: Path) -> int:
    """INFRA-308: cron-friendly safe drift sweep.

    Auto-applies BOTH sync-from-yaml AND sync-from-db (the two safe buckets).
    Bucket 3 (DB-only orphans) and Bucket 4 (YAML-only) are NOT auto-fixed —
    they emit ALERT events to ambient.jsonl so an operator can review.

    Designed to run as a launchd cron every 15 min. Idempotent. Exits 0
    on clean / safe-fixed; non-zero only on errors.
    """
    import subprocess
    import os

    # Pre-state: capture buckets before any sync
    yaml_view = load_yaml_status(root)
    db_view = load_db_status(root)
    common = set(yaml_view) & set(db_view)
    bucket1 = sorted(g for g in common if db_view[g]["status"] == "done" and yaml_view[g].get("status") != "done")
    bucket2 = sorted(g for g in common if db_view[g]["status"] == "open" and yaml_view[g].get("status") == "done")

    # CREDIBLE-012 (2026-05-08): rescope bucket3 to OPEN gaps only.
    #
    # Pre-rescope, bucket3 = "every gap in state.db with no YAML mirror" — which
    # included 1300+ done/superseded historical gaps that don't need a mirror.
    # The alert was 92% noise. Worse: INFRA-760 made the YAML mirror OPTIONAL
    # for the briefing-prompt path (state.db is now canonical), so even open
    # gaps don't strictly require a YAML for fleet operation — only for
    # human-readable browsing of `docs/gaps/`.
    #
    # Rescope: emit ALERT only when an OPEN gap has no YAML, since that's the
    # only case where a human (or git-blame archeologist) would notice the
    # absence and lose context. Done/superseded gaps need no mirror.
    #
    # bucket3_all preserves the legacy total for the print summary; only
    # bucket3_open triggers the actual ALERT emit below.
    bucket3_all = sorted(set(db_view) - set(yaml_view))
    bucket3 = sorted(g for g in bucket3_all if db_view[g].get("status") == "open")
    bucket4 = sorted(set(yaml_view) - set(db_view))

    print(f"== gap-doctor safe-sweep (INFRA-308) ==")
    print(f"  Bucket 1 (DB done / YAML open) : {len(bucket1)} → auto sync-from-db")
    print(f"  Bucket 2 (DB open / YAML done) : {len(bucket2)} → auto sync-from-yaml")
    print(f"  Bucket 3 (DB-only orphans)     : {len(bucket3_all)} total / {len(bucket3)} OPEN → ALERT on open only (CREDIBLE-012)")
    print(f"  Bucket 4 (YAML-only / missing) : {len(bucket4)} → ALERT (manual review)")

    # Apply safe buckets (these are no-ops if --dry-run)
    if not args.dry_run:
        if bucket1:
            # Per-file YAML rewrite (post-INFRA-188 canonical path).
            # cmd_sync_from_db delegates to `chump gap dump --out` which
            # writes the legacy monolithic docs/gaps.yaml; that's wrong
            # for our post-INFRA-188 layout. Rewrite per-file YAMLs in
            # place instead.
            print(f"\n-- syncing {len(bucket1)} per-file YAMLs from DB --")
            for gid in bucket1:
                yaml_path = root / "docs" / "gaps" / f"{gid}.yaml"
                row = db_view[gid]
                # Read existing YAML to preserve any operator-added fields.
                existing = yaml_view.get(gid, {})
                existing["status"] = "done"
                if row.get("closed_date"):
                    existing["closed_date"] = row["closed_date"]
                if row.get("closed_pr") is not None:
                    existing["closed_pr"] = row["closed_pr"]
                yaml_path.write_text(
                    yaml.safe_dump([existing], default_flow_style=False, sort_keys=False, allow_unicode=True, width=120),
                    encoding="utf-8",
                )
                print(f"  {gid} → status=done")
        if bucket2:
            print("\n-- applying sync-from-yaml --")
            sub_args = argparse.Namespace(apply=True)
            cmd_sync_from_yaml(sub_args, root)

    # Emit ambient ALERTs for unsafe buckets (non-blocking; skipped in dry-run).
    if (bucket3 or bucket4) and not args.dry_run:
        # Resolve main-repo .chump-locks via git-common-dir (INFRA-109).
        try:
            common_dir = subprocess.run(
                ["git", "rev-parse", "--git-common-dir"],
                cwd=root, capture_output=True, text=True, check=True
            ).stdout.strip()
            if common_dir == ".git":
                main_repo = root
            else:
                main_repo = Path(common_dir).parent.resolve()
        except subprocess.CalledProcessError:
            main_repo = root
        ambient = main_repo / ".chump-locks" / "ambient.jsonl"
        locks_dir = ambient.parent
        if not locks_dir.exists():
            locks_dir.mkdir(parents=True, exist_ok=True)
        from datetime import datetime, timezone
        ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        emitted = 0
        if bucket3:
            # CREDIBLE-012: ids/note only mention OPEN gaps now. The alert is
            # actionable (low cardinality, real signal), not a noise floor.
            #
            # INFRA-1424: source dedup — only emit once per window per unique
            # subject (kind + sorted IDs). Avoids 20+ identical alerts per hour
            # when gap-doctor runs every 15 min and the same orphan persists.
            do_emit, shash = should_emit_drift_alert(locks_dir, "gap_drift_orphan", bucket3)
            if do_emit:
                evt = {"ts": ts, "event": "ALERT", "kind": "gap_drift_orphan",
                       "source": "gap-doctor-safe-sweep", "ids": bucket3,
                       "subject_hash": shash,
                       "note": f"{len(bucket3)} OPEN gap(s) in state.db with no YAML mirror (per CREDIBLE-012, done/superseded gaps no longer counted; YAML is optional post-INFRA-760)"}
                with ambient.open("a") as f:
                    f.write(json.dumps(evt, separators=(",", ":")) + "\n")
                emitted += 1
            else:
                window_min = _drift_alert_window_min()
                print(f"[safe-sweep] gap_drift_orphan suppressed (dedup window {window_min}m, hash={shash})")
        if bucket4:
            do_emit, shash = should_emit_drift_alert(locks_dir, "gap_drift_yaml_only", bucket4)
            if do_emit:
                evt = {"ts": ts, "event": "ALERT", "kind": "gap_drift_yaml_only",
                       "source": "gap-doctor-safe-sweep", "ids": bucket4,
                       "subject_hash": shash,
                       "note": f"{len(bucket4)} gaps in YAML with no DB row (likely YAML-direct fallback collision)"}
                with ambient.open("a") as f:
                    f.write(json.dumps(evt, separators=(",", ":")) + "\n")
                emitted += 1
            else:
                window_min = _drift_alert_window_min()
                print(f"[safe-sweep] gap_drift_yaml_only suppressed (dedup window {window_min}m, hash={shash})")
        if emitted:
            print(f"\n[safe-sweep] emitted {emitted} ALERT event(s) to {ambient}")

    # EFFECTIVE-219: opt-in orphan pruning for bucket 4 (YAML-only, no DB
    # row at all). STATE WINS — this branch only ever deletes a
    # docs/gaps/<ID>.yaml when a *fresh* re-check confirms state.db has NO
    # row for that ID (not merely status:done/status:closed — literally
    # absent). If state.db diverges from the bucket-4 snapshot taken above
    # (e.g. a sibling session reserved the same ID mid-sweep), the file is
    # rewritten from state.db instead of deleted. Off by default: bucket 4
    # is reported via ALERT (see above) so an operator can review before
    # any destructive sweep runs against the accumulated backlog.
    if getattr(args, "prune_orphans", False) and not args.dry_run and bucket4:
        _prune_yaml_orphans(root, bucket4)

    print(f"\n[safe-sweep] complete (auto-fixed: {len(bucket1) + len(bucket2)}, alerted: {len(bucket3) + len(bucket4)})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="gap-store drift detector + repair (INFRA-155)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("doctor", help="print drift report (read-only)")

    p1 = sub.add_parser("sync-from-yaml", help="UPDATE DB rows where YAML says done")
    p1.add_argument("--apply", action="store_true", help="actually mutate state.db")

    p2 = sub.add_parser("sync-from-db", help="regenerate per-file YAML mirrors from DB (post-INFRA-188)")
    p2.add_argument("--apply", action="store_true", help="actually rewrite docs/gaps/<ID>.yaml files")

    # INFRA-308: cron-friendly safe sweep (auto-fix safe buckets, ALERT on unsafe).
    p3 = sub.add_parser("safe-sweep", help="cron-friendly: auto-fix safe drift, ALERT unsafe")
    p3.add_argument("--dry-run", action="store_true", help="show what would happen without mutating")
    p3.add_argument("--prune-orphans", action="store_true",
                     help="EFFECTIVE-219: delete bucket-4 (YAML-only, no state.db row) files, "
                          "state-checked immediately before each delete. Opt-in; default sweep "
                          "only ALERTs on bucket 4.")

    args = ap.parse_args()
    root = repo_root()

    # INFRA-499: post-INFRA-498 the per-file docs/gaps/<ID>.yaml mirrors
    # are deleted from origin/main entirely (state.db is canonical;
    # INFRA-8193: no tracked dump either). gap-doctor's
    # drift checks compare state.db against those YAMLs — with no
    # tracked YAMLs the entire purpose is moot.
    #
    # Short-circuit only when the working tree's docs/gaps/ has no
    # YAMLs at all. Test fixtures (test-gap-doctor-safe-sweep.sh)
    # create their own tempdir-scoped docs/gaps/ + state.db pair to
    # exercise the drift detection — those still need to work.
    gaps_dir = root / "docs" / "gaps"
    has_yamls = gaps_dir.is_dir() and any(gaps_dir.glob("*.yaml"))
    if not has_yamls:
        print(
            "[gap-doctor] post-INFRA-498: docs/gaps/*.yaml deleted — "
            "no drift to detect. state.db is the only truth (INFRA-8193). "
            "Use 'chump gap show <ID>' for "
            "human-readable per-gap inspection.",
            file=sys.stderr,
        )
        return 0

    handlers = {
        "doctor": cmd_doctor,
        "sync-from-yaml": cmd_sync_from_yaml,
        "sync-from-db": cmd_sync_from_db,
        "safe-sweep": cmd_safe_sweep,
    }
    return handlers[args.cmd](args, root)


if __name__ == "__main__":
    sys.exit(main())
