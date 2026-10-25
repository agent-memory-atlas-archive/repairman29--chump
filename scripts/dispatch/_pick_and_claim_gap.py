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

INFRA-8224: this file is now THE CANONICAL picker (one-picker consolidation).
It exposes a no-claim preview path via `--dry-run` (print the single top gap)
and `--list` (print every pickable gap-id in ranked order); the legacy
`CHUMP_FLEET_DRY_RUN=1` env is kept as an alias for `--dry-run`. Callers:
  - worker.sh                → claim path (writes a lease; unchanged by INFRA-8224)
  - curator-jit-scheduler.sh → `--dry-run` (migrated off _pick_gap.py)
  - _pick_gap.py             → thin deprecated shim: execs this file --dry-run
The ranking logic is single-sourced HERE. When changing ranking behaviour,
change it here (the shim and curator-jit inherit it). Guards ported from the
old _pick_gap.py (loop-stop sentinel, sync-overhead ceiling, inbox handoff-first,
vague-AC skip, picker_mission_boost emit) fire ONLY on the no-claim path so the
live worker claim path is byte-for-byte unchanged. Key invariants:
  - Sort tuple: (prio_rank, mission_rank, wedge_rank, age, effort_rank, id)
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
(prio_rank, mission_rank, planner/wedge, age, effort, id).

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
  MERGED_RECENT_GAPS    RESILIENT-1510: space-separated gap IDs whose PR merged
                        into origin/main recently (computed by worker.sh from
                        commit subjects) — never re-offered even if the
                        gap-store status hasn't flipped to done yet
  WORKER_SKILLS_HARD    INFRA-8176: "1" restores the HARD skill filter (a gap
                        whose skills_required is not a subset of WORKER_SKILLS
                        is excluded). Default (unset/0): skills are a SOFT
                        affinity: matching gaps sort first within their
                        priority band, non-matching gaps are still offered.
  CHUMP_PICKER_OPEN_PR_FALLBACK  INFRA-8176: "1" (worker.sh sets it) enables
                        the gh fallback for the open-PR anti-spin when the
                        github_cache.db pr_state table is absent. Unset in unit
                        tests so they never touch the network.
  CHUMP_OPEN_PR_LOOKUP_TTL_S  INFRA-8176: on-disk TTL (s) of the per-gap gh
                        open-PR lookup cache (default 600).
  CHUMP_PICKER_OPEN_PR_GH_MAX  INFRA-8176: max gh fallback lookups per cycle
                        (default 8); cached answers do not count.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _dep_resolution import (  # noqa: E402
    MalformedDepList,
    PICKABLE_STATUSES,
    parse_dep_list,
    unresolved_deps,
)

PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2, "P3": 3, "": 9}
# INFRA-8176: wedge_rank penalty for a soft skill mismatch; larger than any
# reachable affinity_score + rebalance_boost so mismatches sort last in-band.
SOFT_SKILL_PENALTY = 1000
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
#
# PICKABLE_STATUSES and _DONE_LIKE_STATUSES are imported from _dep_resolution
# (the shared picker module) so this file, _pick_gap.py, and the dependency
# resolver all share ONE definition and cannot drift (RESILIENT-1114).


def _pr_row_is_open(raw: object) -> bool:
    """INFRA-8176: a pr_state row with merged_at NULL is only in flight while
    the PR is still OPEN. The webhook receiver stores the whole event payload
    (state under .pull_request.state) and the REST refill stores the PR object
    (state at top level); a closed-unmerged PR keeps merged_at NULL forever, so
    without this check its gap would stay excluded (a permanent wedge). A row
    with no parseable state is treated as open (the old behaviour)."""
    if not raw:
        return True
    try:
        d = json.loads(raw) if isinstance(raw, str) else raw
    except Exception:
        return True
    if not isinstance(d, dict):
        return True
    st = d.get("state")
    if st is None and isinstance(d.get("pull_request"), dict):
        st = d["pull_request"].get("state")
    return st in (None, "open")


def _inflight_pr_gaps_or_none(repo_root: str):
    """INFRA-8176: like _inflight_pr_gaps, but returns None (not an empty set)
    when the cache DB or its pr_state table is ABSENT or unreadable, so the
    caller can tell "no open PRs" apart from "no data" and fall back to gh.
    RESILIENT-1427 was re-picked in worker cycles 24/27/28 (~708s of claude
    each) while PR #5456 sat open, because the table was missing and this
    check silently failed open."""
    cache = os.path.join(repo_root, ".chump", "github_cache.db")
    if not os.path.exists(cache):
        return None
    out: set = set()
    try:
        import sqlite3
        pat = re.compile(r"^([A-Z][A-Z0-9]*-\d+):")
        con = sqlite3.connect(f"file:{cache}?mode=ro", uri=True)
        try:
            cols = {r[1] for r in con.execute("PRAGMA table_info(pr_state)").fetchall()}
            if "title" not in cols or "merged_at" not in cols:
                return None
            raw_col = "raw_payload_json" if "raw_payload_json" in cols else "NULL"
            rows = con.execute(
                f"SELECT title, {raw_col} FROM pr_state "
                "WHERE merged_at IS NULL AND title IS NOT NULL"
            ).fetchall()
        finally:
            con.close()
        for title, raw in rows:
            if not _pr_row_is_open(raw):
                continue
            m = pat.match((title or "").lstrip())
            if m:
                out.add(m.group(1))
    except Exception:
        return None
    return out


def _inflight_pr_gaps(repo_root: str) -> set:
    """R1 (RESILIENT-1592) — gap-ids that already have an OPEN, un-merged PR.

    Such a gap must NOT be re-picked: re-picking spawns a duplicate PR and IS the
    re-ship loop (RESILIENT-1573 churned 37 cycles and 3 PRs — #5312/#5315 left
    orphaned open — before #5320 finally landed). A gap leaves this set when its
    PR merges (-> gap done) or the PR is closed by the dup/orphan closers
    (-> re-pickable), so this never permanently wedges a genuinely-failed gap.

    Keyed on the bare "<GAP-ID>:" ship-title convention — identical to
    check-gap-status-flip.sh:34 and gap-doctor-reconcile.py:576 — so a
    `fix(X:)` *reference* PR (which does not implement the gap) never counts.
    Returns an empty set when the cache is missing; main() uses
    _inflight_pr_gaps_or_none() so a missing table triggers the gh fallback
    (INFRA-8176) instead of failing open.
    """
    got = _inflight_pr_gaps_or_none(repo_root)
    return got if got is not None else set()


_GAP_ID_SAFE = re.compile(r"^[A-Z][A-Z0-9]*-\d+$")


def _gh_open_pr_lookup(repo_root: str, gap_id: str):
    """INFRA-8176: the open-PR fallback when pr_state is absent. Calls
    cache_gap_open_prs in scripts/coord/lib/github_cache.sh (which wraps
    `gh pr list --state open --search "<GAP-ID> in:title"` behind a 10-minute
    on-disk cache). Returns True (open PR exists), False (known: none), or
    None (lookup failed: unknown)."""
    if not _GAP_ID_SAFE.match(gap_id or ""):
        return None
    lib = os.path.join(repo_root, "scripts", "coord", "lib", "github_cache.sh")
    if not os.path.exists(lib):
        lib = str(Path(__file__).resolve().parent.parent / "coord" / "lib" / "github_cache.sh")
    env = dict(os.environ)
    env.setdefault("REPO_ROOT", repo_root)
    try:
        r = subprocess.run(
            ["bash", "-c", 'source "$1" && cache_gap_open_prs "$2"', "_", lib, gap_id],
            cwd=repo_root if os.path.isdir(repo_root) else None,
            env=env,
            capture_output=True,
            text=True,
            timeout=int(os.environ.get("CHUMP_PICKER_OPEN_PR_GH_TIMEOUT_S", "20")),
        )
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return bool(r.stdout.strip())


def _emit_ambient(event: dict) -> None:
    """Best-effort append of one event to AMBIENT_JSONL (never raises)."""
    path = os.environ.get("AMBIENT_JSONL", ".chump-locks/ambient.jsonl")
    event.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    try:
        with open(path, "a") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
    except Exception:
        pass


def _emit_skipped_open_pr(gaps: list, source: str) -> None:
    """INFRA-8176: one event per cycle naming every gap skipped because it
    already has an open un-merged PR, so re-pick churn is measurable."""
    if not gaps:
        return
    _emit_ambient(
        {"kind":"picker_skipped_open_pr",  # literal kind at the emit site (EVENT_REGISTRY scanner)
            "event": "picker_skipped_open_pr",
            "gaps": sorted(set(gaps)),
            "count": len(set(gaps)),
            "source": source,
            "worker": os.environ.get("WORKER_ID", os.environ.get("AGENT_ID", "")),
        }
    )


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


def _resolve_chump_bin() -> str:
    """Resolve the `chump` CLI binary for `--lease-only` delegation.

    Checks CHUMP_BIN first, then worktree-local target dirs, then the freshest
    compiled binary across shared/host target dirs, then PATH (`shutil.which`).
    """
    import shutil

    explicit = os.environ.get("CHUMP_BIN", "").strip()
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit

    script_repo = Path(__file__).resolve().parents[2]
    for local_cand in (
        script_repo / "target" / "release" / "chump",
        script_repo / "target" / "debug" / "chump",
    ):
        try:
            if local_cand.is_file() and os.access(local_cand, os.X_OK):
                return str(local_cand)
        except OSError:
            continue

    home = Path.home()
    shared_candidates = [
        home / ".cargo" / "chump-shared-target" / "release" / "chump",
        home / ".cargo" / "chump-shared-target" / "debug" / "chump",
        home / "chump" / "target" / "release" / "chump",
        home / "chump" / "target" / "debug" / "chump",
        home / ".cargo" / "bin" / "chump",
    ]
    existing = []
    for cand in shared_candidates:
        try:
            if cand.is_file() and os.access(cand, os.X_OK):
                existing.append((cand.stat().st_mtime, str(cand)))
        except OSError:
            continue
    if existing:
        existing.sort(reverse=True)
        return existing[0][1]

    found = shutil.which("chump")
    return found if found else "chump"

def try_claim_gap(gap_id: str, session_id: str, lock_dir: Path) -> bool:
    """Attempt to claim a lease for gap_id atomically via `chump claim --lease-only`.

    INFRA-8580 (PHASE-R R6, INFRA-8195 AC2): _pick_and_claim_gap.py no longer
    writes `.gap-<gap>.lock` or `<session>.json` directly; `crates/chump-atomic-claim`
    is the single lease writer across the fleet. Prior INFRA-676 same-session
    stale marker cleanup is performed inside `chump claim --lease-only`.
    """
    lock_dir.mkdir(parents=True, exist_ok=True)
    chump_bin = _resolve_chump_bin()
    env = os.environ.copy()
    env["CHUMP_LOCK_DIR"] = str(lock_dir)
    try:
        res = subprocess.run(
            [
                chump_bin,
                "claim",
                gap_id,
                "--role",
                "fleet",
                "--session",
                session_id,
                "--lease-only",
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=15,
        )
        return res.returncode == 0
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


# ── INFRA-8224: one-picker consolidation ─────────────────────────────────────
# This file is now THE canonical picker. _pick_gap.py is a thin deprecated shim
# that execs this file with --dry-run; curator-jit-scheduler.sh calls --dry-run
# directly. The helpers below were ported from _pick_gap.py so the shimmed
# (no-claim) path preserves its behavior exactly — see _one_picker_notes in the
# module docstring region. The live worker CLAIM path is deliberately untouched:
# the behavior-changing guards (handoff-first, AC-vague skip, picker_mission_boost
# emit) fire ONLY in the no-claim (--dry-run / --list / CHUMP_FLEET_DRY_RUN) path,
# so worker.sh picks exactly as it did before this change.


def _resolve_ambient_path() -> str:
    """Ambient log path, honoring the curator/test env the shim forwards.

    Resolution order: CHUMP_AMBIENT_LOG → AMBIENT_JSONL → <repo>/.chump-locks/
    ambient.jsonl, where <repo> is CHUMP_REPO → REPO_ROOT → cwd. CHUMP_AMBIENT_LOG
    is what test-mission-picker.sh (and the _pick_gap.py callers) set.
    """
    p = os.environ.get("CHUMP_AMBIENT_LOG")
    if p:
        return p
    p = os.environ.get("AMBIENT_JSONL")
    if p:
        return p
    root = os.environ.get("CHUMP_REPO") or os.environ.get("REPO_ROOT") or os.getcwd()
    return os.path.join(root, ".chump-locks", "ambient.jsonl")


def _emit_picker_event(kind: str, **fields: object) -> None:
    """Best-effort ambient emit (ported from _pick_gap.py). Never break the
    picker on log failure; silently no-op when the ambient dir is absent."""
    ambient = _resolve_ambient_path()
    if not os.path.isdir(os.path.dirname(ambient)):
        return
    # scanner-anchor: "kind":"picker_mission_boost"
    rec = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "kind": kind,
        **{k: v for k, v in fields.items() if v is not None},
    }
    try:
        with open(ambient, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def _picker_policy(key: str):
    """INFRA-8060 (ported): read `key` from scripts/dispatch/picker-policy.json —
    the single-source policy file shared with the Rust GapBriefing. Looks in
    CHUMP_REPO first, then the repo this script lives in. Returns None when
    absent/null/unreadable. An env var named after the key (upper-case) still
    overrides it for one run."""
    roots = []
    if os.environ.get("CHUMP_REPO"):
        roots.append(os.environ["CHUMP_REPO"])
    roots.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
    for root in roots:
        try:
            with open(os.path.join(root, "scripts", "dispatch", "picker-policy.json")) as f:
                return json.load(f).get(key)
        except (OSError, ValueError, AttributeError):
            continue
    return None


def _sync_overhead_guard() -> int | None:
    """CREDIBLE-167 (ported from _pick_gap.py): refuse to pick when automated
    coherence syncs crowd the last 50 commits past the ceiling. Ceiling from
    SYNC_OVERHEAD_CEILING env, else `sync_overhead_ceiling` in picker-policy.json
    (committed value is null → off in production). Returns 1 to abort, None to
    continue. Applies in every mode: a global pick-abort the worker should honor
    too, and a no-op whenever the ceiling is unset (the production default)."""
    raw = os.environ.get("SYNC_OVERHEAD_CEILING", "").strip()
    if not raw:
        raw = str(_picker_policy("sync_overhead_ceiling") or "")
    if not raw:
        return None
    try:
        ceiling = float(raw)
    except ValueError:
        return None
    log_file = os.environ.get("SYNC_OVERHEAD_LOG_FILE")
    try:
        if log_file:
            with open(log_file) as f:
                subjects = f.read().splitlines()[:50]
        else:
            out = subprocess.run(
                ["git", "-C", os.environ.get("CHUMP_REPO", os.getcwd()),
                 "log", "-n", "50", "--format=%s"],
                capture_output=True, text=True, timeout=30, check=True,
            )
            subjects = out.stdout.splitlines()
    except Exception:
        return None
    if not subjects:
        return None
    ratio = sum("coherence sync" in s.lower() for s in subjects) / len(subjects)
    if ratio > ceiling:
        print(
            f"Sync overhead {ratio * 100:.0f}% exceeds ceiling {ceiling * 100:.0f}%",
            file=sys.stderr,
        )
        return 1
    return None


def _is_acceptance_criteria_vague(ac: str) -> bool:
    """INFRA-1259 (ported from _pick_gap.py): True when acceptance_criteria is
    empty, all-TODO, or all-TBD. Used ONLY in the no-claim path so the live
    worker claim path keeps its prior (no AC filter) behavior."""
    if not ac:
        return True
    try:
        arr = json.loads(ac)
        if isinstance(arr, list):
            if not arr:
                return True
            return all(
                isinstance(item, str) and item.upper() in ("TODO", "TBD")
                for item in arr
            )
    except (json.JSONDecodeError, TypeError):
        pass
    upper = ac.upper()
    return upper in ("TODO", "TBD") or (
        len(ac) < 50 and upper.count("TODO") == 1 and len(ac.split()) <= 2
    )


def _inbox_handoff_pick(gaps):
    """INFRA-1254 (ported from _pick_gap.py): inbox-first picker. Returns the
    gap-id of an unread HANDOFF event for this session when the named gap is
    still open, else None. No-claim path only (the claim path never short-circuits
    the atomic claim). Operator opt-out: CHUMP_IGNORE_INBOX=1."""
    if os.environ.get("CHUMP_IGNORE_INBOX", "0") == "1":
        return None
    session = (
        os.environ.get("CHUMP_SESSION_ID")
        or os.environ.get("CLAUDE_SESSION_ID")
        or ""
    )
    if not session:
        return None
    lock_dir = os.environ.get("CHUMP_LOCK_DIR")
    if not lock_dir:
        repo_root = os.environ.get("CHUMP_REPO") or os.getcwd()
        lock_dir = os.path.join(repo_root, ".chump-locks")
    inbox_file = os.path.join(lock_dir, "inbox", f"{session}.jsonl")
    if not os.path.isfile(inbox_file):
        return None
    by_id = {g.get("id"): g for g in gaps if isinstance(g, dict)}
    try:
        with open(inbox_file) as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    evt = json.loads(raw)
                except Exception:
                    continue
                if evt.get("event") != "HANDOFF":
                    continue
                gid = evt.get("gap") or evt.get("corr_id") or ""
                if not gid:
                    continue
                g = by_id.get(gid)
                if not g or g.get("status") != "open":
                    continue
                return gid
    except Exception:
        return None
    return None


def _load_planner_priority(
    repo_root: str, max_age_s: int = 7200
) -> tuple[dict, str]:
    """INFRA-1258 (ported from _pick_gap.py): read
    .chump-locks/gap-priority.json written by the INFRA-1257 hourly planner.
    Returns (gap_id -> rank, status_tag) where status_tag is one of
    absent/stale/invalid/ok. Used ONLY in curator_mode (the --dry-run / --list
    preview path), matching where the old _pick_gap.py consumed it."""
    path = os.path.join(repo_root, ".chump-locks", "gap-priority.json")
    if not os.path.exists(path):
        return {}, "absent"
    try:
        mtime = os.path.getmtime(path)
    except OSError:
        return {}, "invalid"
    if (time.time() - mtime) > max_age_s:
        return {}, "stale"
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return {}, "invalid"
    items = data.get("items") if isinstance(data, dict) else None
    if not isinstance(items, list):
        return {}, "invalid"
    out: dict = {}
    for item in items:
        if not isinstance(item, dict):
            continue
        gid = item.get("gap_id")
        rank = item.get("rank")
        if isinstance(gid, str) and isinstance(rank, int):
            out[gid] = rank
    return out, "ok"


def _parse_skills_required(raw) -> list[str]:
    if not raw:
        return []
    if isinstance(raw, list):
        return [str(s).strip() for s in raw if str(s).strip()]
    if isinstance(raw, str):
        s = raw.strip()
        if not s:
            return []
        if s.startswith("["):
            try:
                parsed = json.loads(s)
                if isinstance(parsed, list):
                    return [str(x).strip() for x in parsed if str(x).strip()]
            except Exception:
                pass
        return [t.strip() for t in s.split(",") if t.strip()]
    return []


def _is_external_repo_skill(s: str) -> bool:
    sl = s.strip().lower()
    return sl == "external_repo" or sl.startswith("external_repo:")


def _has_external_repo_tag(g: dict) -> bool:
    return any(_is_external_repo_skill(s) for s in _parse_skills_required(g.get("skills_required", "")))


def _record_external_repo_cycle(
    gate_open: bool, skipped_count: int, blocked_count: int, lock_dir: str | None
) -> None:
    if not gate_open:
        if skipped_count > 0:
            sys.stderr.write(f"{skipped_count} external gaps skipped: gate closed\n")
        sys.stderr.write(f"external_repo gate: closed ({blocked_count} gaps blocked)\n")
    else:
        sys.stderr.write("external_repo gate: open\n")

    target_lock_dir = lock_dir or os.environ.get("CHUMP_LOCK_DIR")
    if not target_lock_dir:
        repo_root = os.environ.get("CHUMP_REPO") or os.environ.get("REPO_ROOT")
        if repo_root:
            target_lock_dir = os.path.join(repo_root, ".chump-locks")
    if not target_lock_dir:
        return
    try:
        sub = os.path.join(target_lock_dir, "external-repo-skipped")
        os.makedirs(sub, exist_ok=True)
        wid = (
            os.environ.get("WORKER_ID")
            or os.environ.get("AGENT_ID")
            or os.environ.get("CHUMP_SESSION_ID")
            or "default"
        )
        safe_wid = re.sub(r"[^A-Za-z0-9_.-]", "_", str(wid))
        rec = {
            "worker_id": str(wid),
            "external_repo_gate": "open" if gate_open else "closed",
            "skipped_external_gaps": skipped_count,
            "blocked_external_gaps": blocked_count,
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        with open(os.path.join(sub, f"{safe_wid}.json"), "w") as f:
            json.dump(rec, f)
    except Exception:
        pass


def main() -> int:
    # INFRA-8224: CLI flags for the no-claim (preview/ranking) path that the
    # _pick_gap.py shim and curator-jit-scheduler call.
    argv = sys.argv[1:]
    # INFRA-8224: two distinct no-claim surfaces, each preserving the historical
    # behavior of the picker it replaces:
    #   curator_mode (--dry-run / --list CLI flags) → the OLD _pick_gap.py
    #     curator picker: planner-betweenness tiebreak (INFRA-1258), vague-AC
    #     skip (INFRA-1259), inbox handoff-first (INFRA-1254), picker_* emits,
    #     NO affinity/rebalance/skill-filter. This is what the _pick_gap.py shim
    #     and curator-jit-scheduler invoke.
    #   claim_preview (legacy CHUMP_FLEET_DRY_RUN=1 env, no CLI flag) → the
    #     worker's OWN claim ranking (wedge = affinity + FLEET-046/INFRA-720
    #     rebalance) without writing a lease — so a dry-run of the worker still
    #     previews exactly what the worker would claim.
    # Both skip the lease write; only the ranking + curator guards differ.
    list_mode = "--list" in argv
    curator_mode = list_mode or ("--dry-run" in argv)
    claim_preview = (not curator_mode) and os.environ.get(
        "CHUMP_FLEET_DRY_RUN", "0"
    ) == "1"
    no_claim = curator_mode or claim_preview

    # INFRA-1737 (ported): loop-stop sentinel — halt dispatch within one cycle.
    # Applies in all modes (normally absent → no-op).
    repo_root_for_stop = (
        os.environ.get("CHUMP_REPO") or os.environ.get("REPO_ROOT") or os.getcwd()
    )
    stop_sentinel = os.path.join(
        repo_root_for_stop, ".chump-locks", "loop-stop-requested"
    )
    if os.path.exists(stop_sentinel):
        print(
            "stop requested: .chump-locks/loop-stop-requested exists, exiting",
            file=sys.stderr,
        )
        return 0

    # CREDIBLE-167 (ported): sync-overhead guard — no-op when ceiling unset.
    overhead_rc = _sync_overhead_guard()
    if overhead_rc is not None:
        return overhead_rc

    gap_file = os.environ.get("GAP_JSON_FILE")
    if not gap_file or not os.path.exists(gap_file):
        return 0
    try:
        with open(gap_file) as f:
            gaps = json.load(f)
    except Exception:
        return 0

    # INFRA-1254 (ported): inbox-first handoff — curator single-pick only.
    # In --list mode we rank everything, so the handoff short-circuit (which
    # hides the ranking) is restricted to the --dry-run curator single-pick.
    if curator_mode and not list_mode:
        handoff_gid = _inbox_handoff_pick(gaps)
        if handoff_gid:
            print(handoff_gid)
            return 0

    # Session + lease dir are only needed when we actually claim. The no-claim
    # (--dry-run / --list) path must run without a session id (curator-jit and
    # the picker CI fixtures do not set one), so resolve lazily.
    session_id = ""
    lock_dir = None
    if not no_claim:
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
    # RESILIENT-1510: gaps whose PR already merged into origin/main recently
    # (worker.sh scans commit subjects), so a gap-store propagation lag can
    # never cause an immediate re-pick of just-shipped work.
    merged_recent = set(os.environ.get("MERGED_RECENT_GAPS", "").split())
    # R1 (RESILIENT-1592): gaps with an in-flight open PR are not re-pickable —
    # the loop-breaker. Unconditional (no opt-out bypass, per INFRA-2429); the
    # helper already fails-open to an empty set on any cache error, so a missing
    # or locked cache degrades to prior behaviour without a kill-switch.
    repo_root = os.environ.get("REPO_ROOT", ".")
    inflight_or_none = _inflight_pr_gaps_or_none(repo_root)
    inflight = inflight_or_none if inflight_or_none is not None else set()
    # INFRA-8176: when pr_state is absent, the per-candidate gh fallback runs
    # at claim time (only for gaps we are about to offer, capped per cycle).
    gh_fallback = (
        inflight_or_none is None
        and os.environ.get("CHUMP_PICKER_OPEN_PR_FALLBACK", "0") == "1"
    )
    try:
        gh_fallback_max = int(os.environ.get("CHUMP_PICKER_OPEN_PR_GH_MAX", "8"))
    except ValueError:
        gh_fallback_max = 8
    skipped_open_pr: list = []
    cooled = cooled_down_gaps(
        os.environ.get("COOLDOWN_DIR", ""),
        worker_id=os.environ.get("WORKER_ID", os.environ.get("AGENT_ID", "")),
    )

    # INFRA-314: Worker skill affinity scoring.
    # CHUMP_AFFINITY=0 disables affinity matching (treats all gaps as eligible).
    # INFRA-8224: affinity + skill hard-filter belong to the worker claim path
    # only — the old _pick_gap.py curator picker had neither, so curator_mode
    # disables them to reproduce that behavior exactly.
    affinity_enabled = (
        (not curator_mode) and os.environ.get("CHUMP_AFFINITY", "1") != "0"
    )
    worker_skills = set(
        s.lower().strip()
        for s in os.environ.get("WORKER_SKILLS", "").split(",")
        if s.strip()
    ) if affinity_enabled else set()
    # INFRA-8176: skills_required is a SOFT affinity by default. The old hard
    # subset filter starved node1 (WORKER_SKILLS=rust,docs,shell,scripts,md):
    # INFRA-8174 (rust,bash,vercel) and whole tag classes (vercel/nats/systemd/
    # bash/ci/coord) were excluded forever and their priority never evaluated.
    # Specialized nodes opt back into hard filtering with WORKER_SKILLS_HARD=1.
    skills_hard = os.environ.get("WORKER_SKILLS_HARD", "0") == "1"
    soft_demoted: dict = {}

    # FLEET-046: pillar/domain rebalancing.
    # INFRA-8224: rebalance (and its wedge_rank) is the claim-path tiebreaker;
    # curator_mode uses planner_rank instead (loaded below), so skip rebalance
    # entirely in curator_mode — matching the old _pick_gap.py.
    rebalance_enabled = (
        (not curator_mode) and os.environ.get("CHUMP_REBALANCE", "1") != "0"
    )
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

    # INFRA-1258 (ported, INFRA-8224): planner-betweenness tiebreak — curator_mode
    # ONLY (the --dry-run / --list preview the _pick_gap.py shim + curator-jit
    # use). Loaded from .chump-locks/gap-priority.json; on absent/stale/invalid we
    # fall back to legacy ordering and emit kind=picker_priority_stale once.
    planner_ranks: dict = {}
    planner_status = "absent"
    if curator_mode:
        planner_repo_root = os.environ.get("CHUMP_REPO", os.getcwd())
        planner_ranks, planner_status = _load_planner_priority(planner_repo_root)
        if planner_status != "ok":
            _emit_picker_event(
                "picker_priority_stale",
                reason=planner_status,
                worker_id=os.environ.get("WORKER_ID", ""),
            )

    # RESILIENT-1509: per-exclusion-reason counters. An empty cycle used to
    # log a bare "no pickable gap" with no way to tell "467 gaps all
    # genuinely blocked" from "the picker threw/over-excluded and nobody
    # noticed" apart. worker.sh dumps this dict (via --dump-reasons / stderr)
    # on every empty cycle so the operator/curator can see WHY.
    reasons: Counter[str] = Counter()
    external_repo_gate_open = os.environ.get(
        "CHUMP_EXTERNAL_REPO_PICK_OK", ""
    ).strip().lower() in ("1", "true")
    skipped_external_gaps = 0

    candidates = []
    for g in gaps:
        gid = g.get("id", "")
        if not gid or gid in active:
            reasons["active_or_missing_id"] += 1
            continue
        # RESILIENT-332 (anti-spin, Layer B): skip gaps with an open PR /
        # in-progress branch on origin (see IN_PROGRESS_GAPS above).
        if gid in in_progress:
            reasons["in_progress_branch"] += 1
            continue
        # RESILIENT-1510: skip gaps whose PR merged recently (see
        # MERGED_RECENT_GAPS above) even if the gap-store status field hasn't
        # caught up to "done" yet.
        if gid in merged_recent:
            continue
        if gid in inflight:
            # R1 (RESILIENT-1592): an open un-merged PR already exists for this
            # gap — wait for it to land or be closed; do not spawn a duplicate.
            reasons["inflight_pr"] += 1
            skipped_open_pr.append(gid)
            continue
        if gid in cooled:
            reasons["cooled_down"] += 1
            continue
        if exclude_re.search(gid):
            reasons["excluded_by_regex"] += 1
            continue
        if not _is_pickable_open(g):
            reasons["not_pickable_status"] += 1
            continue
        # INFRA-8602 / INFRA-8603: external_repo gate. Skip external_repo-tagged
        # gaps when CHUMP_EXTERNAL_REPO_PICK_OK is not enabled ("1" or "true").
        if _has_external_repo_tag(g) and not external_repo_gate_open:
            reasons["external_repo_gate_closed"] += 1
            skipped_external_gaps += 1
            continue
        # INFRA-1259 (ported, INFRA-8224): skip vague / TODO-only AC gaps.
        # curator_mode ONLY (mirrors the old _pick_gap.py). The worker claim /
        # claim-preview path keeps its prior behavior (it never filtered on AC),
        # so this cannot shrink the fleet's pickable set in the hot path.
        if curator_mode and _is_acceptance_criteria_vague(
            (g.get("acceptance_criteria") or "").strip()
        ):
            reasons["vague_acceptance_criteria"] += 1
            continue
        notes = (g.get("notes") or "").lstrip()
        if notes.upper().startswith("SUPERSEDED"):
            reasons["superseded"] += 1
            continue
        # RESILIENT-272: never pick manufactured "pillar starved" junk gaps
        # (banned by CLAUDE.md Mission-Driver §2) — see helper docstring above.
        if is_manufactured_pillar_starved_junk(g.get("title", "")):
            reasons["manufactured_pillar_junk"] += 1
            continue
        # META-937: waste-SLO-breach corrective-keyword exception (see
        # require_title_substrs comment above).
        if require_title_substrs:
            title_l = (g.get("title") or "").lower()
            if not any(sub in title_l for sub in require_title_substrs):
                reasons["title_substr_required"] += 1
                continue
        p = (g.get("priority") or "").upper()
        if prio_filter and p not in prio_filter:
            reasons["priority_filter"] += 1
            continue
        d = (g.get("domain") or "").lower()
        if domain_filter and d not in domain_filter:
            reasons["domain_filter"] += 1
            continue
        e = (g.get("effort") or "").lower()
        if effort_filter and e not in effort_filter:
            reasons["effort_filter"] += 1
            continue
        # META-044: META-* domain is only fleet-pickable when effort=xs|s.
        # Larger efforts require human judgment on scope and strategy.
        if d == "meta" and e not in ("xs", "s"):
            reasons["meta_large_effort"] += 1
            continue
        # INFRA-418: skip gaps that require a different model tier.
        # If gap.required_model is not set (empty string), it's compatible with any model.
        required_model = (g.get("required_model") or "").lower()
        if required_model and required_model != worker_model:
            reasons["required_model_mismatch"] += 1
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
        # RESILIENT-612: deepseek tier gate. flash takes xs/s, pro takes m,
        # l/xl are refused by both (they go to decompose first).
        if worker_model == "flash" and e in ("m", "l", "xl") and not _is_p0_mission:
            reasons["model_effort_gate"] += 1
            continue
        if worker_model == "pro" and e in ("xs", "s", "l", "xl") and not _is_p0_mission:
            reasons["model_effort_gate"] += 1
            continue
        # RESILIENT-1138: haiku/sonnet effort gates retired; only deepseek tiers gate.
        try:
            dep_list = parse_dep_list(g.get("depends_on"))
        except MalformedDepList:
            # Malformed depends_on — skip to be safe.
            reasons["malformed_depends_on"] += 1
            continue
        if dep_list:  # any non-empty dep array
            # INFRA-398 (mirrored, RESILIENT-1114): check if all dependencies
            # are satisfied (done or active) before skipping the gap.
            if unresolved_deps(dep_list, gaps, active):
                reasons["unresolved_deps"] += 1
                continue

        # INFRA-314: Extract affinity metadata (only when affinity is enabled).
        affinity_score = 0
        if affinity_enabled:
            skills_required = {
                s.lower()
                for s in _parse_skills_required(g.get("skills_required", ""))
                if not _is_external_repo_skill(s)
            }

            preferred_backend = (g.get("preferred_backend") or "").lower()
            preferred_machine = (g.get("preferred_machine") or "").lower()

            # INFRA-8176: hard filter only when the worker opts in
            # (WORKER_SKILLS_HARD=1). Otherwise a non-matching gap stays a
            # candidate but sorts after every matching gap in its priority band
            # (SOFT_SKILL_PENALTY in wedge_rank below).
            skill_mismatch = bool(skills_required) and not skills_required.issubset(worker_skills)
            if skill_mismatch and skills_hard:
                reasons["skills_mismatch"] += 1
                continue
            if skill_mismatch:
                soft_demoted[gid] = sorted(skills_required - worker_skills)

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

        # INFRA-756 (ported, INFRA-8224): curator_mode downranks gaps whose AC
        # carries obs-placeholder markers (keeps them pickable but below
        # fully-specified gaps). Claim path keeps prio_rank pristine.
        if curator_mode:
            ac_upper = (g.get("acceptance_criteria") or "").strip().upper()
            if ac_upper and (
                "TODO" in ac_upper or "TBD" in ac_upper or "<FILL IN>" in ac_upper
            ):
                prio_rank += 5

        # MISSION-028: mission_rank = 0 for gaps linked to the active mission,
        # 1 for everything else. Placed AFTER prio_rank so a P0-MISSION gap beats
        # a P0-self-maintenance gap within the same priority band, but a
        # substrate P0 (prio_rank=0) still beats a mission P1 (prio_rank=1)
        # because prio_rank is compared first.
        mission_rank = 0 if _is_mission_linked(g, active_mission) else 1

        # INFRA-8224: the third sort key is mode-dependent, preserving the
        # historical tiebreaker of each picker this file consolidates:
        #   claim / claim-preview → wedge_rank (INFRA-3616: affinity + FLEET-046/
        #     INFRA-720 rebalance folded into one within-band tiebreaker; lower =
        #     more desirable, never crosses a priority tier).
        #   curator_mode          → planner_rank (INFRA-1258 betweenness; lower =
        #     better, unranked gaps get a 10_000 sentinel so they sort after
        #     planner-ranked gaps within the SAME priority band).
        # Both are strictly within-band — prio_rank + mission_rank are compared
        # first, so neither can override priority or the mission invariant.
        if curator_mode:
            third_rank = planner_ranks.get(gid, 10_000)
        else:
            third_rank = -(affinity_score + rebalance_boost)
            # INFRA-8176: soft skill filter. A skill-mismatched gap gets a penalty
            # larger than any affinity+rebalance score, so within its priority
            # band it sorts after every matching gap, but it never drops below a
            # lower priority tier (prio_rank and mission_rank stay authoritative;
            # the tuple layout is unchanged). Claim modes only: the curator
            # path's planner_rank is not a skill surface.
            if gid in soft_demoted:
                third_rank += SOFT_SKILL_PENALTY

        # Sort order: (prio_rank, mission_rank, third_rank, age, effort_rank, id)
        candidates.append(
            (
                prio_rank,
                mission_rank,
                third_rank,
                g.get("created_at") or 0,
                EFFORT_RANK.get(e, 9),
                gid,
            )
        )

    candidates.sort()

    # INFRA-8224: --list — print every pickable gap-id in ranked order, no claim.
    # The curator/preview surface for "what would the fleet pick next, in order".
    if list_mode:
        for c in candidates:
            print(c[5])
        return 0

    _record_external_repo_cycle(
        external_repo_gate_open,
        skipped_external_gaps,
        skipped_external_gaps,
        lock_dir,
    )

    if candidates:
        # Try to claim candidates in priority order. Return the first one we
        # successfully claim. This ensures no two workers return the same gap.
        try:
            worker_idx = int(os.environ.get("WORKER_INDEX", "1"))
        except ValueError:
            worker_idx = 1

        # Start from staggered offset (same logic as _pick_gap.py).
        offset = (max(worker_idx, 1) - 1) % len(candidates)

        # INFRA-8176: events for the gap actually offered this cycle.
        def _emit_pick_events(gap_id: str) -> None:
            _emit_skipped_open_pr(skipped_open_pr, "gh" if gh_fallback else "pr_state")
            if gap_id in soft_demoted:
                _emit_ambient(
                    {"kind":"picker_soft_skill_demoted",  # literal kind at the emit site (EVENT_REGISTRY scanner)
                        "event": "picker_soft_skill_demoted",
                        "picked": gap_id,
                        "missing_skills": soft_demoted[gap_id],
                        "worker_skills": sorted(worker_skills),
                        "worker": os.environ.get("WORKER_ID", os.environ.get("AGENT_ID", "")),
                    }
                )

        # INFRA-569 / INFRA-8224: no-claim single-pick — print WITHOUT writing a
        # lease. Covers --dry-run (curator_mode) and the legacy CHUMP_FLEET_DRY_RUN
        # env (claim_preview). The picker_* ambient emits fire ONLY in curator_mode
        # (the _pick_gap.py shim + curator-jit path), so the worker's own dry-run
        # preview keeps its historical quiet emit surface.
        if no_claim:
            # INFRA-8176: the worker's no-claim preview (CHUMP_FLEET_DRY_RUN) still
            # honours the open-PR gh fallback, exactly like the claim loop below,
            # so a gap with an open un-merged PR is never offered as a preview
            # either. The curator path (--dry-run) has no gh budget and keeps the
            # plain candidates[offset] pick.
            picked = None
            for _k in range(len(candidates)):
                _cand = candidates[(offset + _k) % len(candidates)]
                if not curator_mode and gh_fallback:
                    if gh_fallback_max > 0:
                        gh_fallback_max -= 1
                        _has_pr = _gh_open_pr_lookup(repo_root, _cand[5])
                    else:
                        _has_pr = None
                    if _has_pr:
                        reasons["inflight_pr"] += 1
                        skipped_open_pr.append(_cand[5])
                        continue
                    if _has_pr is None:
                        reasons["open_pr_lookup_unknown"] += 1
                picked = _cand
                break
            if picked is None:
                _emit_pick_events("")
                return 1
            picked_prio_rank = picked[0]
            picked_mission_rank = picked[1]
            picked_third_rank = picked[2]
            picked_gid = picked[5]
            if curator_mode:
                # INFRA-1258 (ported): attribution when the planner influenced
                # this pick (rank < sentinel).
                if planner_status == "ok" and picked_third_rank < 10_000:
                    _emit_picker_event(
                        "picker_used_priority",
                        gap_id=picked_gid,
                        planner_rank=picked_third_rank,
                        worker_id=os.environ.get("WORKER_ID", ""),
                    )
                # MISSION-011/028 (ported): emit picker_mission_boost when the
                # mission tiebreaker displaced an equal-priority substrate gap,
                # so the mission-picker gate can observe it.
                if picked_mission_rank == 0 and active_mission:
                    displaced = any(
                        c[0] == picked_prio_rank and c[1] == 1
                        for c in candidates
                        if c[5] != picked_gid
                    )
                    if displaced:
                        _emit_picker_event(
                            "picker_mission_boost",
                            gap_id=picked_gid,
                            active_mission=active_mission,
                            worker_id=os.environ.get("WORKER_ID", ""),
                        )
            else:
                # INFRA-8176: the worker's own no-claim preview keeps its events
                # for the gap actually offered (soft-skill demotion, skipped
                # open-PR gaps); the curator path has its own emit surface above.
                _emit_pick_events(picked_gid)
            print(picked_gid)
            return 0

        # Try candidates in rotated order.
        for i in range(len(candidates)):
            idx = (offset + i) % len(candidates)
            gap_id = candidates[idx][5]  # Index [5]: (prio_rank, mission_rank, wedge_rank, effort, age, gid)
            # INFRA-8176: pr_state absent -> ask gh (via the cache helper's
            # 10-minute on-disk cache) before offering. A gap with an open
            # un-merged PR is never offered; an unknown answer (gh down or
            # lookup budget spent) fails open so an offline node never wedges.
            if gh_fallback:
                if gh_fallback_max > 0:
                    gh_fallback_max -= 1
                    has_pr = _gh_open_pr_lookup(repo_root, gap_id)
                else:
                    has_pr = None
                if has_pr:
                    reasons["inflight_pr"] += 1
                    skipped_open_pr.append(gap_id)
                    continue
                if has_pr is None:
                    reasons["open_pr_lookup_unknown"] += 1
            if not try_claim_gap(gap_id, session_id, lock_dir):
                # RESILIENT-1509: a candidate that passed every filter but
                # lost the atomic claim race (another worker got there
                # first). Distinct from the filter-reason counters above —
                # surfaces as "claim_race_lost" so a cycle that silently
                # loses every race reads differently from one with zero
                # candidates to begin with.
                reasons["claim_race_lost"] += 1
                continue
            _emit_pick_events(gap_id)
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

    _emit_skipped_open_pr(skipped_open_pr, "gh" if gh_fallback else "pr_state")
    # RESILIENT-1509: reaching here means no gap was returned this cycle.
    # Dump the per-reason exclusion counts to stderr so worker.sh (which no
    # longer redirects this to /dev/null) can log WHY instead of a bare
    # "no pickable gap" — the root cause of the 5h/276-cycle cuphead
    # starvation was that this information was silently discarded.
    sys.stderr.write(
        json.dumps(
            {
                "pick_empty_cycle": True,
                "total_gaps": len(gaps),
                "candidates": len(candidates),
                "skipped_external_gaps": skipped_external_gaps,
                "external_repo_gate": "open" if external_repo_gate_open else "closed",
                "exclusion_reasons": dict(reasons),
            }
        )
        + "\n"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
