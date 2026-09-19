#!/usr/bin/env python3
"""INFRA-415 + FLEET-046: atomic gap picker+claimer for fleet workers.

Extends _pick_gap.py with claiming logic so gap-picker returns ONLY gaps
that have already been claimed (atomically) by this invocation. Prevents
concurrent workers from picking the same gap.

FLEET-046: pillar-aware rebalancing. Reads recent ship history from
state.db to detect domain monopoly (e.g. INFRA >70% of last 20 ships)
and pillar starvation (a pillar absent from recent ships). Gaps from
underserved domains/pillars get a sort-key boost so they surface ahead
of yet-another-INFRA-fix.

MISSION-028 FIX: this file now mirrors the ranking logic from _pick_gap.py
(the CANONICAL ranking source). When changing ranking behaviour, change
_pick_gap.py first and mirror here. Key invariants:
  - Sort tuple: (prio_rank, mission_rank, wedge_rank, effort_rank, age, id)
  - prio_rank is the PRIMARY key (P0=0 < P1=1 < P2=2 < P3=3). A P0 ALWAYS
    beats any lower-priority gap — no heuristic may promote a lower-priority
    gap above a higher-priority one.
  - mission_rank=0 for MISSION-linked gaps, 1 otherwise; a within-priority-band
    tiebreak so a P0-MISSION gap beats a P0-self-maintenance gap, but a
    substrate P0 (prio_rank=0) still beats a mission P1 (prio_rank=1) because
    prio_rank is compared first.
  - wedge_rank = -(affinity_score + rebalance_boost): the affinity + FLEET-046/
    INFRA-720 pillar/domain rebalance heuristics act ONLY as a within-band
    tiebreaker (more affinity / more rebalance boost sorts earlier WITHIN the
    same priority tier). They never cross priority tiers.
  - P0+domain=MISSION gaps bypass the sonnet xs-effort gate (mirroring
    _pick_gap.py MISSION-026 fix) so xs-effort P0 MISSION gaps are never
    permanently blocked by worker tier.

INFRA-3616 FIX (the keystone): the old sort tuple led with `-affinity_score`
and folded the rebalance boost INTO priority via
`effective_prio = max(prio_rank - rebalance_boost, 0)`. That let a rebalance-
boosted P1 (or an affinity-matched P1) floor to effective_prio=0 and TIE — then
beat — a real P0, so operator-marked P0s and the active mission sat unworked
while the fleet ground low-priority gaps (e.g. P1 MISSION-055 was picked over
P0 INFRA-3616). Priority is now the pure PRIMARY key; the wedge heuristics are
demoted to a within-band tiebreaker, matching the CANONICAL _pick_gap.py order
(prio_rank, mission_rank, planner/wedge, effort, age, id).

Reads the open-gap JSON, applies fleet filters, attempts to claim each
candidate in priority order. Returns the first gap that was successfully
claimed, or nothing if all candidates are already claimed/unavailable.

Environment (same as _pick_gap.py plus):
  SESSION_ID       session identifier for lease (e.g. from CLAUDE_SESSION_ID)
  CHUMP_LOCK_DIR   override .chump-locks path (default: repo_root/.chump-locks)
  FLEET_MODEL      worker's model tier (haiku, sonnet, opus) for filtering by required_model
  CHUMP_REBALANCE  set to "0" to disable pillar/domain rebalancing (default: enabled)
  CHUMP_STATE_DB   override path to state.db (default: repo_root/.chump/state.db)
  REBALANCE_WINDOW number of recent ships to consider (default: 20)
  REBALANCE_DOMAIN_THRESHOLD  domain monopoly threshold 0-100 (default: 70)
  CHUMP_ACTIVE_MISSION  active mission outcome ID (MISSION-011); see _pick_gap.py
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dep_resolution import MalformedDepList, parse_dep_list, unresolved_deps  # noqa: E402

PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "": 9}
EFFORT_RANK = {"xs": 0, "s": 1, "m": 2, "l": 3, "xl": 4, "": 9}

# EFFECTIVE-1543: pickable = genuinely-open work ONLY.
# The queue was spinning on done work (1,943 open, 0 closed/90min while worker
# PRs kept merging): the picker trusted the JSON `status` field alone, but
# `chump gap list --json` can hand back stale / split-brain rows (the gap store
# has multiple drifting reps; observed EFFECTIVE-449 status=already_satisfied +
# closed_pr=4381 re-picked into a DUPLICATE PR). A gap is pickable ONLY when its
# status is open/ready AND it carries NO linked PR (closed_pr) and NO shipped_in
# marker. Anything already done/shipped/closed/in-flight is excluded here so a
# lying status field can never resurrect done work.
PICKABLE_STATUSES = {"open", "ready"}
_DONE_LIKE_STATUSES = {
    "already_satisfied", "done", "shipped", "superseded", "closed",
    "closed_not_a_bug", "duplicate", "wont_fix", "wontfix", "blocked",
    "in_progress", "in-progress", "in_review", "in_flight", "perpetual",
    "ready_to_ship",
}


def _is_pickable_open(g: dict) -> bool:
    """True only for genuinely-open, un-shipped, un-linked gaps.

    Belt-and-suspenders against a stale/split-brain status field: a gap that
    already has a closed_pr or shipped_in is done regardless of what `status`
    claims, and must never be re-picked.
    """
    status = (g.get("status") or "").strip().lower()
    if status not in PICKABLE_STATUSES:
        return False
    cp = g.get("closed_pr")
    if cp not in (None, "", 0, "0"):
        return False
    shipped = g.get("shipped_in")
    if isinstance(shipped, str):
        shipped = shipped.strip()
    if shipped not in (None, "", 0, "0"):
        return False
    return True

PILLAR_TAGS = {"EFFECTIVE", "CREDIBLE", "RESILIENT", "ZERO-WASTE", "MISSION"}

# MISSION-011: default active mission outcome when no explicit override is set.
# Canonical copy lives in _pick_gap.py; keep in sync.
_DEFAULT_ACTIVE_MISSION = "MISSION-010"

# RESILIENT-272: manufactured "pillar starved" self-referential gaps are
# banned by CLAUDE.md Mission-Driver §2 ("Do NOT file 1-2 gaps to refill a
# starved pillar") — filing them never actually refills the named pillar
# (they're INFRA/MISSION meta-work about the pillar, not real work IN it).
# A helsinki 2nd-host fleet observed grinding 0/10 on exactly this junk
# class (INFRA-2789 "MISSION-ZERO-WASTE: pillar starved", INFRA-2802
# "MISSION-RESILIENT: pillar starved") because these titles literally match
# the starved-pillar rebalance boost below, so the picker kept ranking them
# ahead of real work. Canonical copy lives in _pick_gap.py; keep in sync.
_MANUFACTURED_PILLAR_STARVED_RE = re.compile(
    r"^mission-(effective|credible|resilient|zero-waste):\s*.*pillar starved\b",
    re.IGNORECASE,
)


def is_manufactured_pillar_starved_junk(title: str) -> bool:
    """True when `title` is a self-referential 'pillar starved' junk gap."""
    return bool(_MANUFACTURED_PILLAR_STARVED_RE.match((title or "").lstrip()))


def extract_pillar(title: str) -> str:
    """Extract pillar tag from gap title (e.g. 'EFFECTIVE: foo bar' → 'EFFECTIVE')."""
    upper = title.lstrip().upper()
    for tag in PILLAR_TAGS:
        if upper.startswith(tag + ":"):
            return tag
    return ""


def _load_active_mission() -> str:
    """MISSION-011: return the active mission outcome ID.

    Canonical copy in _pick_gap.py — keep in sync (MISSION-028).

    Resolution order (first non-empty wins):
      1. CHUMP_ACTIVE_MISSION env var (set to "" to disable boost entirely)
      2. ~/.chump/ACTIVE_MISSION file (one line, e.g. "MISSION-010")
      3. Hard-coded default: MISSION-010
    """
    env_val = os.environ.get("CHUMP_ACTIVE_MISSION")
    if env_val is not None:
        return env_val.strip()

    mission_file = os.path.expanduser("~/.chump/ACTIVE_MISSION")
    try:
        with open(mission_file) as f:
            val = f.read().strip()
            if val:
                return val
    except OSError:
        pass

    return _DEFAULT_ACTIVE_MISSION


def _is_mission_linked(g: dict, active_mission: str) -> bool:
    """MISSION-011: return True when gap `g` is linked to the active mission.

    Canonical copy in _pick_gap.py — keep in sync (MISSION-028).

    A gap is mission-linked when ANY of these hold:
      (a) gap.outcome_id matches active_mission
      (b) gap.domain is "MISSION"
      (c) gap.id matches active_mission exactly
      (d) active_mission appears verbatim in title, notes, or description
    """
    if not active_mission:
        return False

    if (g.get("outcome_id") or "").strip() == active_mission:
        return True
    if (g.get("domain") or "").upper() == "MISSION":
        return True
    if (g.get("id") or "").strip() == active_mission:
        return True

    needle = active_mission.upper()
    for field in ("title", "notes", "description"):
        val = (g.get(field) or "").upper()
        if needle in val:
            return True

    return False


def get_ship_history(window: int) -> list[dict]:
    """Read last `window` shipped gaps from state.db. Returns [{domain, title}]."""
    repo_root = os.environ.get("REPO_ROOT", ".")
    db_path = os.environ.get("CHUMP_STATE_DB", os.path.join(repo_root, ".chump", "state.db"))
    if not os.path.exists(db_path):
        return []
    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        rows = conn.execute(
            "SELECT domain, title FROM gaps "
            "WHERE status='done' AND closed_pr IS NOT NULL "
            "ORDER BY closed_at DESC LIMIT ?",
            (window,),
        ).fetchall()
        conn.close()
        return [{"domain": r[0], "title": r[1]} for r in rows]
    except Exception:
        return []


def compute_rebalance_boosts(
    ship_history: list[dict],
    domain_threshold: int,
) -> tuple[str, set[str]]:
    """Return (monopoly_domain, starved_pillars) based on ship history imbalance.

    monopoly_domain: the domain that exceeds threshold% of recent ships (e.g.
    "INFRA" at 100%). Empty string if no monopoly. Caller boosts any gap whose
    domain != monopoly_domain.

    starved_pillars: pillar tags absent from recent ship titles. If no recent
    ship has an EFFECTIVE: prefix, EFFECTIVE-tagged gaps get a boost.
    """
    if not ship_history:
        return "", set()

    domain_counts: dict[str, int] = {}
    seen_pillars: set[str] = set()
    for s in ship_history:
        d = (s.get("domain") or "").upper()
        if d:
            domain_counts[d] = domain_counts.get(d, 0) + 1
        pillar = extract_pillar(s.get("title", ""))
        if pillar:
            seen_pillars.add(pillar)

    total = len(ship_history)
    monopoly_domain: str = ""
    for domain, count in domain_counts.items():
        pct = (count * 100) // total
        if pct >= domain_threshold:
            monopoly_domain = domain.upper()
            break

    starved_pillars = PILLAR_TAGS - seen_pillars

    return monopoly_domain, starved_pillars


def get_pillar_distribution_4h(ambient_path: str) -> tuple[dict[str, int], dict[str, float]]:
    """Read last 4 hours of session_end events from ambient.jsonl and compute pillar distribution.

    Returns (pillar_counts, pillar_percentages) where:
      - pillar_counts: {"EFFECTIVE": 5, "CREDIBLE": 2, ...}
      - pillar_percentages: {"EFFECTIVE": 62.5, "CREDIBLE": 25.0, ...}
    """
    if not os.path.exists(ambient_path):
        return {}, {}

    now = int(time.time())
    window_seconds = 4 * 3600  # 4 hours
    cutoff_time = now - window_seconds

    pillar_counts: dict[str, int] = {pillar: 0 for pillar in PILLAR_TAGS}
    total = 0

    try:
        with open(ambient_path) as f:
            for line in f:
                try:
                    event = json.loads(line.strip())
                except json.JSONDecodeError:
                    continue

                # Only count session_end events with shipped outcome.
                if event.get("kind") != "session_end":
                    continue
                if event.get("outcome") != "shipped":
                    continue

                # Check if event is within 4h window.
                ts_str = event.get("ts", "")
                if not ts_str:
                    continue
                try:
                    # Parse ISO 8601 timestamp (e.g., "2026-05-08T12:00:00Z").
                    import datetime
                    ts = datetime.datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp()
                    if ts < cutoff_time:
                        continue
                except Exception:
                    continue

                # Extract pillar from gap title (if available in event).
                title = event.get("gap_title", "")
                pillar = extract_pillar(title)
                if pillar:
                    pillar_counts[pillar] += 1
                    total += 1
    except Exception:
        pass

    # Calculate percentages.
    pillar_percentages = {}
    if total > 0:
        for pillar in PILLAR_TAGS:
            pct = (pillar_counts[pillar] * 100) / total
            pillar_percentages[pillar] = pct
    else:
        for pillar in PILLAR_TAGS:
            pillar_percentages[pillar] = 0.0

    return pillar_counts, pillar_percentages


def get_under_represented_pillars(pillar_percentages: dict[str, float], threshold: int = 20) -> set[str]:
    """Return pillars that have < threshold% representation in the last 4h.

    Default threshold is 20% (i.e., 5 pillars equally balanced would be 20% each).
    """
    under_represented = set()
    for pillar in PILLAR_TAGS:
        if pillar_percentages.get(pillar, 0.0) < threshold:
            under_represented.add(pillar)
    return under_represented


def detect_and_emit_pillar_imbalance(ambient_path: str) -> None:
    """Check if one pillar has been > 60% for 8h consecutive and emit ALERT if so.

    Scans ambient.jsonl for pillar distribution snapshots and detects sustained
    monopoly patterns.
    """
    if not os.path.exists(ambient_path):
        return

    now = int(time.time())
    window_8h = 8 * 3600
    cutoff_8h = now - window_8h

    # Simple heuristic: sample pillar distribution every hour and check consistency.
    # For now, if the most recent 4h snapshot shows >60%, emit alert.
    # In production, this would track hourly snapshots for 8h.
    _, pillar_percentages = get_pillar_distribution_4h(ambient_path)

    if not pillar_percentages:
        return

    for pillar, pct in pillar_percentages.items():
        if pct > 60.0:
            # Emit pillar_imbalance alert.
            try:
                event = {
                    "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
                    "kind": "pillar_imbalance",
                    "event": "pillar_imbalance",
                    "dominant_pillar": pillar,
                    "percentage": round(pct, 1),
                    "message": f"{pillar} has been dominant (>{60}%) for sustained period",
                }
                with open(ambient_path, "a") as f:
                    f.write(json.dumps(event) + "\n")
            except Exception:
                pass
            break  # Only emit one alert per check


def csv(env_key: str) -> list[str]:
    return [s.strip() for s in os.environ.get(env_key, "").split(",") if s.strip()]


def get_session_id() -> str:
    """Resolve session ID in priority order (same as chump claim)."""
    # Priority 1: explicit override
    if os.environ.get("CHUMP_SESSION_ID"):
        return os.environ["CHUMP_SESSION_ID"]

    # Priority 2: Claude Code SDK injection
    if os.environ.get("CLAUDE_SESSION_ID"):
        return os.environ["CLAUDE_SESSION_ID"]

    # Priority 3: worktree-scoped ID (read from .chump-locks/.wt-session-id if present)
    wt_session_path = Path(".chump-locks/.wt-session-id")
    if wt_session_path.exists():
        try:
            with open(wt_session_path) as f:
                return f.read().strip()
        except Exception:
            pass

    # Priority 4: machine-scoped fallback (read from ~/.chump/session_id)
    home = os.environ.get("HOME", os.path.expanduser("~"))
    fallback_path = Path(home) / ".chump" / "session_id"
    if fallback_path.exists():
        try:
            with open(fallback_path) as f:
                return f.read().strip()
        except Exception:
            pass

    raise ValueError("No session ID found; set CHUMP_SESSION_ID or CLAUDE_SESSION_ID")


def get_lock_dir() -> Path:
    """Get the lease lock directory.

    INFRA-467: resolve to the *main* repo's .chump-locks/, never the
    linked worktree's. Without this, a fleet spawned from
    /tmp/chump-fleet-host (a `git worktree add` of the main repo) writes
    leases into /tmp/chump-fleet-host/.chump-locks/ — invisible to siblings
    on the main repo, so cross-worktree gap-preflight breaks (INFRA-466).

    Resolution order (matches scripts/lib/repo-paths.sh):
      1. CHUMP_LOCK_DIR env override (tests, explicit)
      2. parent of `git rev-parse --git-common-dir` (main-repo root, even
         from a linked worktree — git-common-dir returns the MAIN repo's
         .git regardless of which worktree we're in)
      3. REPO_ROOT env (worker.sh sets this) / .chump-locks (legacy fallback)
      4. cwd / .chump-locks (last resort)
    """
    lock_dir = os.environ.get("CHUMP_LOCK_DIR")
    if lock_dir:
        return Path(lock_dir)

    # Try git-common-dir for main-repo resolution.
    try:
        common = subprocess.run(
            ["git", "rev-parse", "--git-common-dir"],
            capture_output=True, text=True, timeout=5,
        )
        if common.returncode == 0:
            common_dir = common.stdout.strip()
            # Linked worktree: returns absolute /path/to/main/.git
            # Main checkout: returns relative ".git"
            if common_dir == ".git":
                # Main checkout — toplevel is the main repo
                top = subprocess.run(
                    ["git", "rev-parse", "--show-toplevel"],
                    capture_output=True, text=True, timeout=5,
                )
                if top.returncode == 0:
                    return Path(top.stdout.strip()) / ".chump-locks"
            else:
                # Linked worktree — common_dir's parent is main repo root
                return Path(common_dir).resolve().parent / ".chump-locks"
    except Exception:
        pass

    # Legacy fallback: REPO_ROOT (set by worker.sh, may be the linked-worktree
    # path — preserves backward-compat for tests that explicitly set it).
    repo_root = os.environ.get("REPO_ROOT", ".")
    return Path(repo_root) / ".chump-locks"


def try_claim_gap(gap_id: str, session_id: str, lock_dir: Path) -> bool:
    """Attempt to write a lease for gap_id atomically. Return True if successful.

    Uses a two-file strategy with fcntl.flock for atomicity:
    1. gap-id.lock — canonical indicator that gap is claimed
    2. session-id.json — metadata about the claiming session

    INFRA-513: Use fcntl.flock around the check+claim pair to prevent TOCTOU race
    where two workers both scan empty leases and try to claim the same gap.
    """
    lock_dir.mkdir(parents=True, exist_ok=True)

    now = int(time.time())
    ttl_seconds = 4 * 3600
    expires_at = now + ttl_seconds

    # 2026-05-08 INFRA-713: speculative is now opt-in via CHUMP_SPECULATIVE=1
    # (per CLAUDE.md original design — speculative race is intentional, not
    # default). Hardcoded `speculative: True` caused observed collisions:
    # CREDIBLE-003 shipped twice from agent2 cycles racing each other (#1286
    # vs #1288), and worker 2 picked INFRA-710 immediately after I shipped
    # it manually (because the existing lease was speculative, picker didn't
    # treat it as exclusive). Default to exclusive; opt into race mode.
    _speculative = os.environ.get("CHUMP_SPECULATIVE", "0") == "1"
    lease = {
        "session_id": session_id,
        "gap_id": gap_id,
        "taken_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(expires_at)),
        "heartbeat_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "purpose": "fleet:pick_and_claim",
        "speculative": _speculative,
    }

    gap_lock_file = lock_dir / f".gap-{gap_id}.lock"
    session_lease_file = lock_dir / f"{session_id}.json"
    temp_lease = lock_dir / f".tmp-{session_id}-{gap_id}-{now}"
    lockfile = lock_dir / ".claim-lock"

    try:
        # Use fcntl.flock around the check+claim to prevent TOCTOU race.
        # This serializes access so only one worker can claim at a time.
        with open(lockfile, "a") as lock_f:
            fcntl.flock(lock_f.fileno(), fcntl.LOCK_EX)
            try:
                # INFRA-676: sweep stale gap locks belonging to THIS session
                # before creating a new one, so a previously-killed worker for
                # the same session_id can't block the fleet indefinitely.
                for stale in lock_dir.glob(".gap-*.lock"):
                    try:
                        first_token = stale.read_text().split()[0]
                    except Exception:
                        first_token = ""
                    if first_token == session_id:
                        try:
                            stale.unlink()
                        except Exception:
                            pass

                # Check if gap is already claimed (within the lock).
                if gap_lock_file.exists():
                    return False

                # Create the gap lock file (still within the lock).
                with open(gap_lock_file, "w") as f:
                    f.write(f"{session_id} {now}\n")

                # Gap lock created successfully. Now write the session lease.
                try:
                    with open(temp_lease, "w") as f:
                        json.dump(lease, f, indent=2)
                    temp_lease.rename(session_lease_file)
                except Exception:
                    # Lease write failed, but we already created the lock.
                    # Return True anyway since we successfully claimed the gap.
                    pass

                return True
            finally:
                fcntl.flock(lock_f.fileno(), fcntl.LOCK_UN)

    except Exception:
        return False


def cooled_down_gaps(cooldown_dir: str, worker_id: str = "") -> set[str]:
    """FLEET-051: gap IDs cooled for this worker (or cluster-wide).

    File formats:
    - ${WORKER_ID}-${GAP_ID}.json  per-worker cooldown (FLEET-051)
    - ${GAP_ID}.json               legacy / cluster-wide cooldown

    A gap is blocked when:
      (a) it has a per-worker file for *this* worker_id whose until>now, OR
      (b) it has a cluster-wide (legacy) file whose until>now, OR
      (c) it has per-worker files from >= FLEET_COOLDOWN_THRESHOLD distinct workers

    INFRA-361: expired records are cleaned up on read.
    """
    if not cooldown_dir or not os.path.isdir(cooldown_dir):
        return set()
    threshold = int(os.environ.get("FLEET_COOLDOWN_THRESHOLD", "3"))
    now = int(time.time())
    cooled: set[str] = set()
    per_worker: dict[str, set[str]] = {}

    for entry in os.listdir(cooldown_dir):
        if not entry.endswith(".json"):
            continue
        path = os.path.join(cooldown_dir, entry)
        try:
            with open(path) as f:
                rec = json.load(f)
        except Exception:
            continue
        gid = rec.get("gap_id") or ""
        until = rec.get("until", 0)
        if not gid:
            continue
        if until <= now:
            try:
                os.remove(path)
            except OSError:
                pass
            continue

        stem = entry[:-5]
        is_per_worker = stem[0].isdigit() if stem else False

        if is_per_worker:
            dash = stem.index("-")
            file_worker = stem[:dash]
            per_worker.setdefault(gid, set()).add(file_worker)
            if worker_id and file_worker == str(worker_id):
                cooled.add(gid)
        else:
            cooled.add(gid)

    for gid, workers in per_worker.items():
        if len(workers) >= threshold:
            cooled.add(gid)

    return cooled


def main() -> int:
    gap_file = os.environ.get("GAP_JSON_FILE")
    if not gap_file or not os.path.exists(gap_file):
        return 0
    try:
        with open(gap_file) as f:
            gaps = json.load(f)
    except Exception:
        return 0

    session_id = get_session_id()
    lock_dir = get_lock_dir()

    prio_filter = [p.upper() for p in csv("FLEET_PRIORITY_FILTER")]
    domain_filter = [d.lower() for d in csv("FLEET_DOMAIN_FILTER")]
    effort_filter = [e.lower() for e in csv("FLEET_EFFORT_FILTER")]
    worker_model = os.environ.get("FLEET_MODEL", "haiku").lower()
    exclude_re = re.compile(os.environ.get("EXCLUDE_RE", "^$"))
    # META-937: waste-SLO-breach corrective-keyword exception. When the fleet
    # is paused on a waste-SLO breach (.chump/fleet-paused), worker.sh sets
    # this to "corrective" so ONLY gaps whose title contains that keyword
    # remain pickable — the pause still blocks ordinary work, but a gap
    # explicitly framed as fixing the breach itself can still be claimed.
    # Unset/empty outside a pause: no restriction (default fleet behavior).
    require_title_substrs = [s.lower().strip() for s in csv("FLEET_REQUIRE_TITLE_SUBSTR") if s.strip()]
    active = set(os.environ.get("ACTIVE_GAPS", "").split())
    # RESILIENT-332 (anti-spin, Layer B): gaps that already have an open PR /
    # in-progress branch on origin must NEVER be offered — a completed-but-
    # unmerged gap (e.g. RESILIENT-327 / PR #3795) stayed pickable and got
    # re-picked into a spin (108 worker_stuck/15min, 2026-08-15). worker.sh
    # computes this set from `git ls-remote` (branch convention
    # chump/<gapid>-fleet-*) and passes it here, mirroring the ACTIVE_GAPS
    # lease-exclusion pattern. This is complementary to lease-exclusion:
    # leases cover pre-push in-flight work, branches cover post-push
    # awaiting-merge work. Empty/unset = no exclusion (graceful; Layers A+C
    # still prevent the spin on nodes where the set can't be computed).
    in_progress = set(os.environ.get("IN_PROGRESS_GAPS", "").split())
    cooled = cooled_down_gaps(
        os.environ.get("COOLDOWN_DIR", ""),
        worker_id=os.environ.get("WORKER_ID", os.environ.get("AGENT_ID", "")),
    )

    # INFRA-314: Worker skill affinity scoring.
    # CHUMP_AFFINITY=0 disables affinity matching (treats all gaps as eligible).
    affinity_enabled = os.environ.get("CHUMP_AFFINITY", "1") != "0"
    worker_skills = set(
        s.lower().strip()
        for s in os.environ.get("WORKER_SKILLS", "").split(",")
        if s.strip()
    ) if affinity_enabled else set()

    # FLEET-046: pillar/domain rebalancing.
    rebalance_enabled = os.environ.get("CHUMP_REBALANCE", "1") != "0"
    monopoly_domain: str = ""
    starved_pillars: set[str] = set()
    under_represented_pillars: set[str] = set()
    if rebalance_enabled:
        window = int(os.environ.get("REBALANCE_WINDOW", "20"))
        threshold = int(os.environ.get("REBALANCE_DOMAIN_THRESHOLD", "70"))
        ship_history = get_ship_history(window)
        monopoly_domain, starved_pillars = compute_rebalance_boosts(
            ship_history, threshold
        )

        # INFRA-720: pillar-aware bias using 4h rolling window.
        ambient_path = os.environ.get("AMBIENT_JSONL", ".chump-locks/ambient.jsonl")
        _, pillar_percentages = get_pillar_distribution_4h(ambient_path)
        under_represented_pillars = get_under_represented_pillars(pillar_percentages)

        # Check for pillar imbalance and emit alert if detected.
        detect_and_emit_pillar_imbalance(ambient_path)

    # MISSION-028: load the active mission outcome ID for mission_rank scoring.
    # Canonical logic mirrors _pick_gap.py (_load_active_mission / _is_mission_linked).
    active_mission = _load_active_mission()

    candidates = []
    for g in gaps:
        gid = g.get("id", "")
        if not gid or gid in active:
            continue
        # RESILIENT-332 (anti-spin, Layer B): skip gaps with an open PR /
        # in-progress branch on origin (see IN_PROGRESS_GAPS above).
        if gid in in_progress:
            continue
        if gid in cooled:
            continue
        if exclude_re.search(gid):
            continue
        if not _is_pickable_open(g):
            continue
        notes = (g.get("notes") or "").lstrip()
        if notes.upper().startswith("SUPERSEDED"):
            continue
        # RESILIENT-272: never pick manufactured "pillar starved" junk gaps
        # (banned by CLAUDE.md Mission-Driver §2) — see helper docstring above.
        if is_manufactured_pillar_starved_junk(g.get("title", "")):
            continue
        # META-937: waste-SLO-breach corrective-keyword exception (see
        # require_title_substrs comment above).
        if require_title_substrs:
            title_l = (g.get("title") or "").lower()
            if not any(sub in title_l for sub in require_title_substrs):
                continue
        p = (g.get("priority") or "").upper()
        if prio_filter and p not in prio_filter:
            continue
        d = (g.get("domain") or "").lower()
        if domain_filter and d not in domain_filter:
            continue
        e = (g.get("effort") or "").lower()
        if effort_filter and e not in effort_filter:
            continue
        # META-044: META-* domain is only fleet-pickable when effort=xs|s.
        # Larger efforts require human judgment on scope and strategy.
        if d == "meta" and e not in ("xs", "s"):
            continue
        # INFRA-418: skip gaps that require a different model tier.
        # If gap.required_model is not set (empty string), it's compatible with any model.
        required_model = (g.get("required_model") or "").lower()
        if required_model and required_model != worker_model:
            continue
        # INFRA-471: model-class effort gate (routing.yaml drives pick policy).
        # haiku workers refuse effort=m/l/xl — cognitive overhead exceeds capability.
        # sonnet workers refuse effort=xs — cheap models handle cleanup; don't burn frontier tokens.
        # opus is unconstrained.
        # MISSION-026/028: P0 mission-linked gaps bypass the sonnet xs-effort gate so
        # xs-effort P0 MISSION gaps (e.g. MISSION-018) are never permanently blocked
        # by worker tier. Mirrored from _pick_gap.py (canonical source).
        _is_p0_mission = (
            p == "P0"
            and (g.get("domain") or "").upper() == "MISSION"
        )
        # MISSION-047: P0 mission gaps bypass the haiku m/l/xl gate too — symmetric
        # with the sonnet-xs bypass below. Without this, a P0-MISSION effort>=m gap
        # is invisible to every haiku worker (and routing makes workers haiku), so
        # it starves forever — the literal mechanism of MISSION-026.
        if worker_model == "haiku" and e in ("m", "l", "xl") and not _is_p0_mission:
            continue
        if worker_model == "sonnet" and e == "xs" and not _is_p0_mission:
            continue
        try:
            dep_list = parse_dep_list(g.get("depends_on"))
        except MalformedDepList:
            # Malformed depends_on — skip to be safe.
            continue
        if dep_list:  # any non-empty dep array
            # INFRA-398 (mirrored, RESILIENT-1114): check if all dependencies
            # are satisfied (done or active) before skipping the gap.
            if unresolved_deps(dep_list, gaps, active):
                continue

        # INFRA-314: Extract affinity metadata (only when affinity is enabled).
        affinity_score = 0
        if affinity_enabled:
            skills_required_raw = g.get("skills_required", "")
            if isinstance(skills_required_raw, str):
                try:
                    skills_required = (
                        json.loads(skills_required_raw)
                        if skills_required_raw.strip()
                        else []
                    )
                except json.JSONDecodeError:
                    skills_required = []
            elif isinstance(skills_required_raw, list):
                skills_required = skills_required_raw
            else:
                skills_required = []

            # Normalize to lowercase for comparison.
            skills_required = {s.lower() for s in skills_required}

            preferred_backend = (g.get("preferred_backend") or "").lower()
            preferred_machine = (g.get("preferred_machine") or "").lower()

            # Hard filter: if gap requires skills, worker must have all of them.
            if skills_required and not skills_required.issubset(worker_skills):
                continue

            # Affinity scoring: backend match (3) + machine match (2) + skill matches (1 each) + priority.
            worker_backend = os.environ.get("WORKER_BACKEND", "").lower()
            if worker_backend and preferred_backend and worker_backend == preferred_backend:
                affinity_score += 3
            worker_machine = os.environ.get("WORKER_MACHINE", "").lower()
            if worker_machine and preferred_machine and worker_machine == preferred_machine:
                affinity_score += 2
            # Each matched skill adds 1 point (up to len(skills_required)).
            affinity_score += len(skills_required & worker_skills)

        # FLEET-046 + INFRA-720: rebalance boost. Gaps from underserved domains/pillars
        # get a sort-key bonus equivalent to bumping them up 2 priority
        # levels (e.g. P2 sorts like P0).
        rebalance_boost = 0
        if rebalance_enabled:
            title = g.get("title", "")
            gap_domain = d.upper()
            gap_pillar = extract_pillar(title)
            if monopoly_domain and gap_domain != monopoly_domain:
                rebalance_boost += 2
            if gap_pillar and gap_pillar in starved_pillars:
                rebalance_boost += 2
            # INFRA-720: Add +2 bonus for pillars under-represented in 4h window.
            if gap_pillar and gap_pillar in under_represented_pillars:
                rebalance_boost += 2

        # INFRA-3616: priority is the PURE PRIMARY sort key. The rebalance boost
        # is NOT folded into priority (the old `effective_prio = max(prio -
        # boost, 0)` let a boosted P1 tie/beat a P0). Instead it feeds wedge_rank
        # below as a within-band tiebreaker only.
        prio_rank = PRIO_RANK.get(p, 9)

        # MISSION-028: mission_rank = 0 for gaps linked to the active mission,
        # 1 for everything else. Placed AFTER prio_rank so a P0-MISSION gap beats
        # a P0-self-maintenance gap within the same priority band, but a
        # substrate P0 (prio_rank=0) still beats a mission P1 (prio_rank=1)
        # because prio_rank is compared first.
        mission_rank = 0 if _is_mission_linked(g, active_mission) else 1

        # INFRA-3616: wedge_rank folds the affinity + FLEET-046/INFRA-720
        # rebalance heuristics into a single within-band tiebreaker. Lower sorts
        # earlier, so a higher affinity/rebalance score (more desirable) yields a
        # more-negative wedge_rank and wins WITHIN its priority tier — never
        # across tiers. This preserves the wedge/topology "ship order" heuristic
        # (SHIP_ORDER_VISION) as a tiebreaker while priority stays authoritative.
        wedge_rank = -(affinity_score + rebalance_boost)

        # Canonical sort order matches _pick_gap.py:
        #   (prio_rank, mission_rank, wedge_rank, effort_rank, age, id)
        candidates.append(
            (
                prio_rank,
                mission_rank,
                wedge_rank,
                EFFORT_RANK.get(e, 9),
                g.get("created_at") or 0,
                gid,
            )
        )

    candidates.sort()

    if candidates:
        # Try to claim candidates in priority order. Return the first one we
        # successfully claim. This ensures no two workers return the same gap.
        try:
            worker_idx = int(os.environ.get("WORKER_INDEX", "1"))
        except ValueError:
            worker_idx = 1

        # Start from staggered offset (same logic as _pick_gap.py).
        offset = (max(worker_idx, 1) - 1) % len(candidates)

        # INFRA-569: dry-run mode — pick without claiming (no lease written).
        dry_run = os.environ.get("CHUMP_FLEET_DRY_RUN", "0") == "1"

        # Try candidates in rotated order.
        for i in range(len(candidates)):
            idx = (offset + i) % len(candidates)
            gap_id = candidates[idx][5]  # Index [5]: (prio_rank, mission_rank, wedge_rank, effort, age, gid)
            if dry_run:
                print(gap_id)
                return 0
            if try_claim_gap(gap_id, session_id, lock_dir):
                # FLEET-046 + INFRA-720: log when rebalancing influenced the pick.
                if rebalance_enabled and (monopoly_domain or starved_pillars or under_represented_pillars):
                    ambient_path = os.environ.get(
                        "AMBIENT_JSONL", ".chump-locks/ambient.jsonl"
                    )
                    try:
                        event = {
                            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                            "kind": "rebalance_active",
                            "event": "rebalance_active",
                            "picked": gap_id,
                            "monopoly_domain": monopoly_domain,
                            "starved_pillars": sorted(starved_pillars),
                            "under_represented_pillars": sorted(under_represented_pillars),
                        }
                        with open(ambient_path, "a") as f:
                            f.write(json.dumps(event) + "\n")
                    except Exception:
                        pass
                print(gap_id)
                return 0
    else:
        # INFRA-314: Emit affinity_starved if no eligible gaps found and affinity is enabled + worker has skill constraints.
        if affinity_enabled and worker_skills:
            import time

            now = int(time.time())
            ambient_event = {
                "kind": "affinity_starved",
                "event": "affinity_starved",
                "worker_skills": list(worker_skills),
                "timestamp": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)
                ),
            }
            ambient_path = os.environ.get("AMBIENT_JSONL", ".chump-locks/ambient.jsonl")
            try:
                with open(ambient_path, "a") as f:
                    f.write(json.dumps(ambient_event) + "\n")
            except Exception:
                pass

    return 0


if __name__ == "__main__":
    sys.exit(main())
