#!/usr/bin/env python3
"""DEPRECATED (INFRA-8224): thin shim over the canonical picker.

Historically (INFRA-203) this was a second gap picker that ran its own
filter+rank pipeline in parallel with the worker's live picker
(_pick_and_claim_gap.py). The two drifted — #3055 fixed the mission ordering
in THIS file by mistake while the worker kept picking the old way — which is
exactly the one-picker consolidation INFRA-8224 removes.

There is now ONE picker: scripts/dispatch/_pick_and_claim_gap.py. This file
remains only so existing callers (and the CI gates that invoke it by path)
keep working: it execs the canonical picker in its no-claim `--dry-run` mode,
forwarding the full environment and any CLI args. The canonical picker carries
the ported guards this file used to own (loop-stop sentinel, sync-overhead
ceiling, inbox handoff-first, vague-AC skip, planner-betweenness tiebreak,
picker_* emits), so the ranking + guard behavior on the no-claim path is
preserved. Curator preview additionally inherits the worker's in-flight /
merged-recent / cooldown exclusions (these are input-gated — no effect unless
IN_PROGRESS_GAPS / MERGED_RECENT_GAPS / a github_cache.db are present — and are
a safety improvement over the old standalone picker, which could re-offer a gap
that already had an open PR).

New code should call `_pick_and_claim_gap.py --dry-run` (single top gap) or
`--list` (all pickable gaps, ranked) directly, not this shim.

Behavior delta vs. the pre-INFRA-8224 standalone implementation: the INFRA-1258
planner-betweenness tiebreaker (`gap-priority.json`) is no longer consulted —
the consolidated picker uses the single sort tuple
(prio_rank, mission_rank, wedge_rank, created_at, effort_rank, id). Priority and
mission ordering are unchanged; only the within-band planner tiebreak was dropped.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

_CANONICAL = Path(__file__).resolve().parent / "_pick_and_claim_gap.py"


def main() -> int:
    argv = sys.argv[1:]
    # Default to --dry-run (no claim) — this shim never writes a lease, matching
    # the pre-consolidation _pick_gap.py contract (it only ever printed a gap-id).
    if "--dry-run" not in argv and "--list" not in argv:
        argv = ["--dry-run", *argv]
    os.execv(sys.executable, [sys.executable, str(_CANONICAL), *argv])
    return 0  # unreachable (execv replaces the process)


if __name__ == "__main__":
    sys.exit(main())
