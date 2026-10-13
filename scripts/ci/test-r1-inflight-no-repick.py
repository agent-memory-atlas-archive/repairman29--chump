#!/usr/bin/env python3
"""test-r1-inflight-no-repick.py (RESILIENT-1592 / R1) — the loop-breaker.

A gap with an OPEN, un-merged PR must be reported as in-flight so the picker
skips it (no duplicate PR, no re-ship loop). A merged PR, a fix(X:) reference
PR, and a missing cache must NOT flag a gap. Depth: edge.
"""
import os
import sqlite3
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "dispatch"))
import _pick_and_claim_gap as p  # noqa: E402

fails = 0


def check(cond, msg):
    global fails
    print(("  ok: " if cond else "  FAIL: ") + msg)
    if not cond:
        fails += 1


def mkcache(path, rows):
    con = sqlite3.connect(path)
    con.execute(
        "CREATE TABLE pr_state (number INTEGER PRIMARY KEY, head_ref TEXT, "
        "merged_at TEXT, title TEXT)"
    )
    con.executemany(
        "INSERT INTO pr_state (number, head_ref, merged_at, title) VALUES (?,?,?,?)",
        rows,
    )
    con.commit()
    con.close()


d = tempfile.mkdtemp()
os.makedirs(os.path.join(d, ".chump"))
mkcache(
    os.path.join(d, ".chump", "github_cache.db"),
    [
        # open, un-merged, bare "<GAP>:" prefix -> in-flight (the 1573 case)
        (100, "chump/resilient-1573-fleet-1-x", None, "RESILIENT-1573: no-ship-loop detector"),
        # merged -> NOT in-flight (gap landed)
        (101, "chump/infra-500-x", "2026-10-13T01:00:00Z", "INFRA-500: landed thing"),
        # fix(X:) reference PR -> NOT counted (does not implement the gap)
        (102, "chump/x", None, "fix(INFRA-8112): enabler that references, does not implement"),
        # no gap id -> ignored
        (103, "chump/y", None, "chore: no gap id here"),
    ],
)

got = p._inflight_pr_gaps(d)
check("RESILIENT-1573" in got, "open un-merged bare-prefix PR -> gap is in-flight (skip re-pick)")
check("INFRA-500" not in got, "merged PR -> gap NOT in-flight (it landed)")
check("INFRA-8112" not in got, "fix(X:) reference PR -> NOT counted as in-flight")
check(len(got) == 1, "only the one genuine in-flight gap is flagged")
check(p._inflight_pr_gaps("/no/such/path") == set(), "missing cache -> empty set (fail-open, never wedge)")

print("PASS: R1 in-flight no-repick" if fails == 0 else f"FAIL: {fails} assertion(s)")
sys.exit(1 if fails else 0)
