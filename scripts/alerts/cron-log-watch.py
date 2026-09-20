#!/usr/bin/env python3
"""cron-log-watch.py — PRODUCT-250

The 2026-08-17 first-mate-brief weekly reconcile (a launchd/cron job that
shells out to a for-loop around `dig`) blocked on an unanswered permission
prompt and sat in a "running" state until 2026-09-19 — 33 days, five missed
weekly runs — with nothing alarming. The allow-rule that caused the prompt
was fixed 2026-09-19; what was missing was a watcher that notices a
scheduled task has gone quiet, independent of whether any given run's own
exit code is ever reported.

This script reads a JSONL cron-run log and alerts on two independent
signals, either of which would have caught the incident:

  1. **stale task** — a named task has no `succeeded` run within
     `--stale-days` (default 9) of `--now`. A weekly job missing 5 runs in
     a row is stale at 9 days regardless of whether it ever posted a
     terminal status for the stuck run.
  2. **stuck session** — a `running` entry with no matching terminal
     (`succeeded`/`failed`) entry for the same `session_id`, started more
     than `--running-hours` (default 24) before `--now`. Catches a hung
     session even for a task that has *never* succeeded, before the
     9-day stale threshold would fire.

Log format — one JSON object per line:
    {"ts": "2026-08-17T09:00:00Z", "task": "first-mate-brief",
     "session_id": "abc123", "status": "running"}
    {"ts": "2026-08-17T09:05:00Z", "task": "first-mate-brief",
     "session_id": "abc123", "status": "succeeded"}

`status` is one of "running", "succeeded", "failed". Lines that fail to
parse as JSON, or lack `task`/`status`/`ts`, are skipped.

`--now` overrides "the current time" for deterministic testing; real
invocations (cron/launchd) omit it and get `datetime.now(timezone.utc)`.

Exit code is non-zero iff at least one alert fired — a supervising loop
(or cron's own MAILTO) notices instead of a silent rc=0 masking a stuck
task the way the original incident did.
"""

import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

TERMINAL_STATUSES = {"succeeded", "failed"}


def parse_ts(raw: str) -> datetime:
    ts = raw.strip()
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def load_runs(log_path: str) -> list:
    runs = []
    with open(log_path, "r") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not all(k in record for k in ("ts", "task", "status")):
                continue
            try:
                record["_ts"] = parse_ts(record["ts"])
            except (ValueError, TypeError):
                continue
            runs.append(record)
    return runs


def find_stale_tasks(runs: list, now: datetime, stale_days: int) -> list:
    threshold = now - timedelta(days=stale_days)
    tasks = sorted({r["task"] for r in runs})
    alerts = []
    for task in tasks:
        task_runs = [r for r in runs if r["task"] == task]
        succeeded = [r for r in task_runs if r["status"] == "succeeded"]
        last_success = max((r["_ts"] for r in succeeded), default=None)
        if last_success is None or last_success < threshold:
            alerts.append({
                "kind": "cron_task_stale",
                "task": task,
                "last_succeeded": last_success.isoformat() if last_success else None,
                "stale_days": stale_days,
                "now": now.isoformat(),
            })
    return alerts


def find_stuck_sessions(runs: list, now: datetime, running_hours: int) -> list:
    threshold = now - timedelta(hours=running_hours)
    by_session = {}
    for r in runs:
        session_id = r.get("session_id")
        if session_id is None:
            continue
        by_session.setdefault(session_id, []).append(r)

    alerts = []
    for session_id, session_runs in sorted(by_session.items()):
        has_terminal = any(r["status"] in TERMINAL_STATUSES for r in session_runs)
        if has_terminal:
            continue
        running = [r for r in session_runs if r["status"] == "running"]
        if not running:
            continue
        started = min(r["_ts"] for r in running)
        if started < threshold:
            alerts.append({
                "kind": "cron_session_stuck",
                "task": running[0]["task"],
                "session_id": session_id,
                "started": started.isoformat(),
                "running_hours": running_hours,
                "now": now.isoformat(),
            })
    return alerts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", required=True, help="path to the JSONL cron-run log")
    parser.add_argument("--now", default=None, help="ISO8601 override for the current time (testing)")
    parser.add_argument("--stale-days", type=int, default=9, help="days without a succeeded run before alerting (default 9)")
    parser.add_argument("--running-hours", type=int, default=24, help="hours a session may stay running before alerting (default 24)")
    args = parser.parse_args()

    now = parse_ts(args.now) if args.now else datetime.now(timezone.utc)

    try:
        runs = load_runs(args.log)
    except FileNotFoundError:
        print(json.dumps({"kind": "cron_log_missing", "log": args.log}))
        return 1

    alerts = find_stale_tasks(runs, now, args.stale_days) + find_stuck_sessions(runs, now, args.running_hours)

    for alert in alerts:
        print(json.dumps(alert))

    return 1 if alerts else 0


if __name__ == "__main__":
    sys.exit(main())
