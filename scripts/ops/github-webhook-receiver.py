#!/usr/bin/env python3
"""github-webhook-receiver.py — INFRA-1081

Tiny HTTP server (Python stdlib only) that accepts GitHub webhook deliveries
on POST /webhook, validates X-Hub-Signature-256 HMAC-SHA256 against
CHUMP_GITHUB_WEBHOOK_SECRET, and writes events into .chump/github_cache.db.

Designed for laptop fleet operator setup via smee.io tunnel:
  smee --url $CHUMP_SMEE_URL --target http://localhost:9097/webhook
  → forwards GitHub webhook deliveries to this local receiver
  → no public IP / DNS needed

Handled events (others 200-OK ignored):
  - pull_request (any action): upsert pr_state by .pull_request.number
  - check_suite (completed): bump fetched_at_local on referenced PRs
  - push (refs/heads/main only): mark all open PRs as stale
  - workflow_run (completed): same as check_suite

Schema: see _ensure_schema().

Run:
  CHUMP_WEBHOOK_PORT=9097 CHUMP_GITHUB_WEBHOOK_SECRET=... python3 scripts/ops/github-webhook-receiver.py

Env:
  CHUMP_WEBHOOK_PORT (default 9097)
  CHUMP_GITHUB_WEBHOOK_SECRET (required; HMAC-SHA256 key)
  CHUMP_CACHE_DB (default {repo_root}/.chump/github_cache.db)
  CHUMP_AMBIENT_LOG (default {repo_root}/.chump-locks/ambient.jsonl)

INFRA-1081.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("github-webhook-receiver")


def _repo_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


CACHE_DB = Path(os.environ.get("CHUMP_CACHE_DB", str(_repo_root() / ".chump" / "github_cache.db")))
AMBIENT = Path(os.environ.get("CHUMP_AMBIENT_LOG", str(_repo_root() / ".chump-locks" / "ambient.jsonl")))
SECRET = os.environ.get("CHUMP_GITHUB_WEBHOOK_SECRET", "")
PORT = int(os.environ.get("CHUMP_WEBHOOK_PORT", "9097"))


def _ensure_schema(conn: sqlite3.Connection) -> None:
    """Create pr_state + check_runs tables + indexes if missing. Idempotent."""
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS pr_state (
            number              INTEGER PRIMARY KEY,
            head_ref            TEXT,
            head_sha            TEXT,
            base_ref            TEXT,
            base_sha            TEXT,
            mergeable_state     TEXT,
            auto_merge_enabled  INTEGER NOT NULL DEFAULT 0,
            draft               INTEGER NOT NULL DEFAULT 0,
            merged_at           TEXT,
            title               TEXT,
            user_login          TEXT,
            updated_at_api      TEXT NOT NULL,
            fetched_at_local    TEXT NOT NULL,
            raw_payload_json    TEXT
        );
        CREATE INDEX IF NOT EXISTS pr_state_behind_armed
            ON pr_state(mergeable_state, auto_merge_enabled);
        """
    )
    # INFRA-1368: add merge_state_status column (idempotent — ignore duplicate-column error).
    # Stores the webhook pull_request.mergeable_state value so consumers can
    # look it up from the column rather than parsing the raw_payload_json blob
    # (which has inconsistent shape between webhook and REST sources).
    try:
        conn.execute("ALTER TABLE pr_state ADD COLUMN merge_state_status TEXT")
        conn.commit()
    except Exception:
        pass  # column already exists — safe to ignore
    conn.executescript(
        """
        -- INFRA-1107: per (head_sha, check_name) CI status, populated by
        -- check_suite.completed + workflow_run.completed webhook events.
        -- Unlocks bot-merge's per-PR check_runs polling.
        CREATE TABLE IF NOT EXISTS check_runs (
            head_sha          TEXT NOT NULL,
            name              TEXT NOT NULL,
            status            TEXT,
            conclusion        TEXT,
            started_at        TEXT,
            completed_at      TEXT,
            fetched_at_local  TEXT NOT NULL,
            PRIMARY KEY (head_sha, name)
        );
        CREATE INDEX IF NOT EXISTS check_runs_sha
            ON check_runs(head_sha);
        """
    )
    conn.commit()


def _upsert_check_runs(conn: sqlite3.Connection, head_sha: str, runs: list) -> int:
    """INFRA-1107: write/update check_runs rows for a given head SHA."""
    if not head_sha or not runs:
        return 0
    now = _now_iso()
    n = 0
    for r in runs:
        name = r.get("name") or r.get("check_run", {}).get("name")
        if not name:
            continue
        conn.execute(
            """
            INSERT INTO check_runs (head_sha, name, status, conclusion, started_at, completed_at, fetched_at_local)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(head_sha, name) DO UPDATE SET
                status           = excluded.status,
                conclusion       = excluded.conclusion,
                started_at       = excluded.started_at,
                completed_at     = excluded.completed_at,
                fetched_at_local = excluded.fetched_at_local
            """,
            (head_sha, name, r.get("status"), r.get("conclusion"),
             r.get("started_at"), r.get("completed_at"), now),
        )
        n += 1
    conn.commit()
    return n


def _emit_ambient(event: dict) -> None:
    """Append one JSON line to ambient.jsonl. Best-effort; never raises."""
    try:
        AMBIENT.parent.mkdir(parents=True, exist_ok=True)
        with AMBIENT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
    except Exception as e:
        log.warning("ambient emit failed: %s", e)


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _notify_operator_escalation(kind: str, message: str) -> None:
    """CREDIBLE-275: route a destructive-class ambient event through the
    RESILIENT-263 escalation channel (scripts/coord/lib/notify-operator.sh),
    not just ambient.jsonl.

    Why this exists: EVENT_REGISTRY.yaml declared consumers=[fleet-brief,
    ops-audit, waste-tally] for gap_flipped_done_on_merge, but none of those
    tools ever read the kind — 30 auto-flips across 8 PRs went unnoticed
    (CREDIBLE-268). notify_operator is a real, grep-verifiable consumer: it
    reads CHUMP_NOTIFY_KIND, consults scripts/coord/operator-escalation-registry.txt,
    and either DMs the operator or (quiet-by-default) writes a distinct
    operator_notify_suppressed ambient event — either way, something acts on
    the signal instead of it sitting unread.

    Best-effort; a broken notifier must not break the receiver it reports on.
    """
    lib = _repo_root() / "scripts" / "coord" / "lib" / "notify-operator.sh"
    if not lib.is_file():
        return
    try:
        subprocess.run(
            ["bash", "-c", 'source "$0" && notify_operator "$1"', str(lib), message],
            cwd=str(_repo_root()),
            env={**os.environ, "CHUMP_NOTIFY_KIND": kind},
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (subprocess.SubprocessError, OSError) as e:
        log.warning("CREDIBLE-275: notify_operator errored for kind=%s: %s", kind, e)


def _extract_gap_ids(pr: dict) -> list[str]:
    """Extract gap IDs from the PR title only.

    Looks for patterns like 'INFRA-1234' or 'CREDIBLE-001' in the PR title
    (an explicit 'Closes: ID' trailer written INTO the title is caught by
    the same pattern — no separate body scan is needed or performed).

    CREDIBLE-1072: the PR body is never scanned. A gap ID that appears only
    in the body (prose, an AC cross-reference, a `Closes:` trailer) must NOT
    be extracted here — that class of over-match previously affected the
    closure path too (see _extract_gap_ids_for_closure/CREDIBLE-268) and this
    function is now held to the same title-only discipline.

    Returns a deduped list preserving first-seen order.

    Used by _auto_release_sibling_leases (lease release is non-destructive —
    freeing a lease that cites a gap in passing is harmless). NOT used by
    _auto_flip_gaps_done, which needs a tighter signal — see
    _extract_gap_ids_for_closure below (CREDIBLE-268).
    """
    import re

    pattern = re.compile(r"\b([A-Z][A-Z-]+-\d+)\b")

    seen: set[str] = set()
    ordered: list[str] = []

    title = pr.get("title") or ""
    for match in pattern.findall(title):
        if match not in seen:
            seen.add(match)
            ordered.append(match)

    return ordered


def _extract_gap_ids_for_closure(pr: dict) -> list[str]:
    """CREDIBLE-268 FIX 1: extract gap IDs that a merged PR is entitled to
    CLOSE — deliberately narrower than _extract_gap_ids.

    The full title+body scan over-matched: any gap merely CITED in a PR body
    (a "why this matters" link, an AC cross-reference, a doc analyzing a past
    incident) got flipped to done alongside the gap the PR actually shipped.
    30 flips across 8 PRs on 2026-08-09, ~22 of them collateral.

    Two signals only, both opt-in by construction:
      1. PR TITLE — gap IDs named in the title are the PR's stated intent
         (the convention every ship already follows: "GAP-ID: short title").
      2. Explicit `Closes: ID[, ID2, ...]` trailer, one per line, anywhere in
         the body — an explicit author assertion, not an incidental mention.

    Body text OUTSIDE a `Closes:` trailer is never scanned. Cross-references
    remain free-form prose (nothing to change about how authors write ACs or
    handoff docs) — they just no longer double as a closure signal.
    """
    import re

    pattern = re.compile(r"\b([A-Z][A-Z-]+-\d+)\b")
    closes_pattern = re.compile(r"(?im)^closes:\s*(.+)$")

    seen: set[str] = set()
    ordered: list[str] = []

    title = pr.get("title") or ""
    for match in pattern.findall(title):
        if match not in seen:
            seen.add(match)
            ordered.append(match)

    body = pr.get("body") or ""
    for trailer_line in closes_pattern.findall(body):
        for match in pattern.findall(trailer_line):
            if match not in seen:
                seen.add(match)
                ordered.append(match)

    return ordered


def _auto_release_sibling_leases(pr: dict, payload: dict) -> int:
    """INFRA-1444: on a merged PR, release any sibling lease matching the
    gap ID(s) parsed from the PR title/body.

    Behavior:
    - Only fires when action=closed AND merged=true.
    - For each gap ID found in the PR title/body, scans .chump-locks/claim-*.json
      for files whose gap_id field matches.
    - Identifies the "PR author session" via the PR head commit author email
      heuristic (CHUMP_LEASE_RELEASE_KEEP_AUTHOR=1 to preserve the original
      claimant's lease if they were the actual PR shipper); default: release ALL
      matching leases since the gap is done regardless of who shipped it.
    - Deletes matched lease files and emits kind=lease_orphaned_by_sibling_merge
      for each release.

    Returns the count of leases released.

    Bypass: CHUMP_LEASE_NO_AUTO_RELEASE=1 disables entirely.
    """
    if os.environ.get("CHUMP_LEASE_NO_AUTO_RELEASE") == "1":
        return 0
    if payload.get("action") != "closed" or not pr.get("merged"):
        return 0

    gap_ids = _extract_gap_ids(pr)
    if not gap_ids:
        return 0

    locks_dir = _repo_root() / ".chump-locks"
    if not locks_dir.is_dir():
        return 0

    released = 0
    pr_number = pr.get("number")
    for lease_file in locks_dir.glob("claim-*.json"):
        try:
            with lease_file.open("r", encoding="utf-8") as f:
                lease = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        lease_gap_id = lease.get("gap_id") or ""
        if lease_gap_id not in gap_ids:
            continue
        lease_session_id = lease.get("session_id") or "unknown"
        try:
            lease_file.unlink()
            released += 1
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "lease_orphaned_by_sibling_merge",
                "gap_id": lease_gap_id,
                "released_session_id": lease_session_id,
                "merged_pr": pr_number,
                "lease_file": lease_file.name,
            })
            log.info("released orphaned lease: gap=%s session=%s (merged via PR #%s)",
                     lease_gap_id, lease_session_id, pr_number)
        except OSError as e:
            log.warning("failed to release lease %s: %s", lease_file, e)
    return released


def _auto_flip_gaps_done(pr: dict, payload: dict) -> int:
    """CREDIBLE-092: on a merged PR, flip each referenced gap to status=done in
    the canonical .chump/state.db. This runs LOCALLY in the webhook receiver,
    which has filesystem access to state.db — fixing the root cause of the broken
    .github/workflows/auto-flip-on-merge.yml, which runs in CI where the canonical
    state.db does not exist, so merged gaps stayed 'open' and got re-claimed (the
    ghost-gap waste pattern).

    CREDIBLE-268 FIX 1: gap-id extraction uses _extract_gap_ids_for_closure
    (title + explicit `Closes:` trailer only), NOT the broad title+body scan
    used by _auto_release_sibling_leases — a PR merely CITING a gap must not
    be able to close it.

    CREDIBLE-268 FIX 2: routes through `chump gap ship`, not `chump gap set
    --status done`. `gap set` bypassed the INFRA-1392 PROOF-OF-MERGE guard
    (which lives on the ship path only) and never wrote closed_date — both
    of which produced the falsely-closed gaps' exact fingerprint (closed_pr
    set, closed_date empty, no PROOF-OF-MERGE check run). `gap ship` closes
    both gaps in one change.

    Only fires on action=closed AND merged=true. Idempotent: re-shipping an
    already-done gap is harmless (a non-zero rc is logged, not raised). Emits
    kind=gap_flipped_done_on_merge per flip. To disable, stop the receiver
    (no env escape hatch on purpose — the EFFECTIVE-094 bypass-var ceiling
    ratchets down, and stopping the local receiver is the same lever).

    Returns the count of gaps flipped to done.
    """
    if payload.get("action") != "closed" or not pr.get("merged"):
        return 0
    gap_ids = _extract_gap_ids_for_closure(pr)
    if not gap_ids:
        return 0
    # CREDIBLE-268 (interim SUPPRESS, operator decision 2026-08-09): kept in
    # place even after the title/Closes: extraction fix landed — the fix
    # removes the over-match, but re-enabling by default is a separate
    # operator call. Re-enable via CHUMP_WEBHOOK_AUTOFLIP=1 once the fixed
    # extraction has run in production without incident.
    if os.environ.get("CHUMP_WEBHOOK_AUTOFLIP", "0") != "1":
        _emit_ambient({
            "ts": _now_iso(),
            "kind": "gap_autoflip_suppressed",
            "merged_pr": pr.get("number"),
            "would_have_flipped": gap_ids,
            "reason": "CREDIBLE-268 over-match; suppressed pending durable fix",
        })
        log.info("CREDIBLE-268: auto-flip SUPPRESSED for PR #%s (would have flipped %s)",
                 pr.get("number"), gap_ids)
        return 0
    pr_number = pr.get("number")
    chump_bin = os.environ.get("CHUMP_BIN", "chump")
    flipped = 0
    for gid in gap_ids:
        try:
            result = subprocess.run(
                [chump_bin, "gap", "ship", gid,
                 "--closed-pr", str(pr_number),
                 "--session", "webhook-auto-flip"],
                cwd=str(_repo_root()),
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (subprocess.SubprocessError, OSError) as e:
            log.warning("CREDIBLE-092: flip gap %s errored: %s", gid, e)
            continue
        if result.returncode == 0:
            flipped += 1
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "gap_flipped_done_on_merge",
                "gap_id": gid,
                "merged_pr": pr_number,
            })
            log.info("CREDIBLE-092: flipped gap %s -> done (merged via PR #%s)",
                     gid, pr_number)
            _notify_operator_escalation(
                "gap_flipped_done_on_merge",
                f"Gap {gid} auto-flipped to done on merge of PR "
                f"#{pr_number} (github.com/repairman29/chump/pull/{pr_number}).",
            )
        else:
            log.warning("CREDIBLE-092: flip gap %s failed (rc=%s): %s",
                        gid, result.returncode, (result.stderr or "").strip()[:200])
    return flipped


def _auto_prune_worktree_on_merge(pr: dict, payload: dict) -> int:
    """INFRA-1705: on a merged PR, prune the corresponding /tmp/chump-<slug>/
    worktree immediately instead of waiting for the periodic prune-worktrees.sh
    sweep.

    Fires AFTER _auto_release_sibling_leases (which clears the lease entry for
    this gap), so the lease-check safety condition is already satisfied. Other
    safety checks:
      - head_ref must match chump/<slug>-claim convention (otherwise we don't
        know where the worktree lives)
      - worktree directory must exist under /tmp/
      - no uncommitted changes (git diff --quiet HEAD)

    Emits kind=worktree_orphan_pruned (success) or kind=worktree_orphan_skipped
    (safety-check blocked) — same kinds the periodic sweep emits — with an
    extra `trigger: pr_merge_webhook` field so consumers can distinguish.

    Returns 1 if pruned, 0 otherwise.

    Bypass: CHUMP_NO_AUTO_PRUNE_WORKTREE=1
    """
    if os.environ.get("CHUMP_NO_AUTO_PRUNE_WORKTREE") == "1":
        return 0
    if payload.get("action") != "closed" or not pr.get("merged"):
        return 0
    head_ref = (pr.get("head") or {}).get("ref") or ""
    if not (head_ref.startswith("chump/") and head_ref.endswith("-claim")):
        return 0
    slug = head_ref[len("chump/"):-len("-claim")]
    if not slug:
        return 0
    worktree_path = Path("/tmp") / f"chump-{slug}"
    if not worktree_path.is_dir():
        return 0
    pr_number = pr.get("number")
    repo_root = _repo_root()

    # Safety: skip if there are uncommitted changes in the worktree.
    try:
        diff = subprocess.run(
            ["git", "-C", str(worktree_path), "diff", "--quiet", "HEAD"],
            check=False,
            capture_output=True,
            timeout=10,
        )
        if diff.returncode != 0:
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "worktree_orphan_skipped",
                "path": str(worktree_path),
                "branch": head_ref,
                "reason": "uncommitted_changes",
                "trigger": "pr_merge_webhook",
                "merged_pr": pr_number,
            })
            log.info("INFRA-1705: skipped prune of %s — uncommitted changes (PR #%s)",
                     worktree_path, pr_number)
            return 0
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("INFRA-1705: git diff check failed for %s: %s", worktree_path, e)
        return 0

    # Primary path: git worktree remove --force (also prunes the linked-worktree
    # gitdir back-reference under .git/worktrees/).
    method = "git_worktree_remove"
    try:
        result = subprocess.run(
            ["git", "worktree", "remove", "--force", str(worktree_path)],
            cwd=str(repo_root),
            check=False,
            capture_output=True,
            timeout=15,
        )
        if result.returncode != 0:
            # Fallback: rm + git worktree prune. Mirrors the bash sweep's
            # fallback path for worktrees whose gitdir back-ref is corrupt.
            method = "rm_fallback"
            shutil.rmtree(worktree_path, ignore_errors=True)
            subprocess.run(
                ["git", "worktree", "prune"],
                cwd=str(repo_root),
                check=False,
                timeout=10,
            )
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("INFRA-1705: worktree remove failed for %s: %s", worktree_path, e)
        return 0

    if worktree_path.exists():
        log.warning("INFRA-1705: worktree %s still present after prune attempt", worktree_path)
        return 0

    _emit_ambient({
        "ts": _now_iso(),
        "kind": "worktree_orphan_pruned",
        "path": str(worktree_path),
        "branch": head_ref,
        "trigger": "pr_merge_webhook",
        "merged_pr": pr_number,
        "method": method,
    })
    log.info("INFRA-1705: pruned worktree %s after PR #%s merge", worktree_path, pr_number)
    return 1


# RESILIENT-152: runtime paths whose staleness in the fleet's main checkout
# breaks autonomous shipping. Scoped TIGHTLY on purpose:
#   - scripts/                  → the executable fleet surface (worker.sh,
#                                 run-fleet.sh, bot-merge.sh, _pick_gap.py, …)
#   - docs/dispatch/routing.yaml → the per-gap model routing table
# DELIBERATELY EXCLUDED: src/ + crates/ (Rust — a stale .rs needs a *rebuild*,
# not a file swap; hot-swapping source under a running binary fixes nothing and
# is a separate concern), and ALL canonical state — .chump/ (state.db,
# github_cache.db), .chump-locks/ (leases, ambient.jsonl), docs/gaps/*.yaml —
# which the fleet mutates continuously and must NEVER be clobbered.
_SELF_SYNC_PATHS = ("scripts", "docs/dispatch/routing.yaml")


def _self_sync_fleet_scripts(payload: dict) -> int:
    """RESILIENT-152: on a push to origin/main, surgically refresh the fleet's
    runtime scripts in the main checkout so a merged script fix actually reaches
    the RUNNING fleet — without a human hand running
    'git checkout origin/main -- <script>'.

    WHY this exists: the fleet mutates state.db / ambient.jsonl / docs/gaps/*.yaml
    continuously, so the main checkout's working tree is PERMANENTLY dirty →
    'git pull' refuses → merged script fixes land on origin/main but never deploy.
    Proof (2026-06-21): after MISSION-047 merged, the running fleet kept using the
    OLD picker until a human ran the checkout by hand. This closes that gap, which
    is *why* nothing self-heals end-to-end. Sibling of the auto-flip / auto-release
    handlers above — all are "the system getting its own updates to itself".

    SAFETY (load-bearing — a bug here could clobber canonical state):
      - Only the tightly-scoped _SELF_SYNC_PATHS are touched. State paths are
        never in scope, so state.db / leases / gap YAMLs are never written.
      - Uses 'git checkout origin/main -- <path>' (a working-tree update of the
        NAMED paths only), then unstages. NEVER 'reset --hard', NEVER 'checkout .',
        NEVER 'pull' — any full-tree op would destroy the dirty state files.
      - Per-path diff guard ⇒ an unchanged path is a no-op, so the call is
        idempotent and every push to main re-asserts "fleet scripts == origin/main"
        (this self-heals a sync that was missed while the receiver was down).

    Returns the number of runtime paths updated. Best-effort; never raises.

    Intentionally ALWAYS-ON — no disable-flag env var. The operation is
    scoped + idempotent + safe (proven by test-self-sync-fleet.sh), so there is
    nothing to gate; and a per-feature kill-switch would add bypass-var debt
    (EFFECTIVE-094 ceiling). To halt it in an emergency, stop the receiver daemon
    (launchctl), which is the existing escape hatch for every receiver function.
    """
    if payload.get("ref") != "refs/heads/main":
        return 0
    repo_root = _repo_root()

    # Bring origin/main up to date so the working tree can be compared against it.
    try:
        fetch = subprocess.run(
            ["git", "-C", str(repo_root), "fetch", "origin", "main"],
            check=False, capture_output=True, timeout=30,
        )
        if fetch.returncode != 0:
            log.warning("RESILIENT-152: git fetch origin main failed rc=%s: %s",
                        fetch.returncode,
                        (fetch.stderr or b"").decode("utf-8", "replace")[:200])
            return 0
    except (subprocess.TimeoutExpired, OSError) as e:
        log.warning("RESILIENT-152: git fetch failed: %s", e)
        return 0

    updated = []
    for path in _SELF_SYNC_PATHS:
        try:
            # Does the working tree differ from origin/main at this path?
            differs = subprocess.run(
                ["git", "-C", str(repo_root), "diff", "--quiet", "origin/main", "--", path],
                check=False, capture_output=True, timeout=15,
            ).returncode != 0
            if not differs:
                continue
            co = subprocess.run(
                ["git", "-C", str(repo_root), "checkout", "origin/main", "--", path],
                check=False, capture_output=True, timeout=20,
            )
            if co.returncode != 0:
                log.warning("RESILIENT-152: checkout of %s failed: %s", path,
                            (co.stderr or b"").decode("utf-8", "replace")[:200])
                continue
            # Unstage: the main checkout never commits (work happens in worktrees);
            # the running fleet only reads the working tree, so keep the index clean.
            subprocess.run(
                ["git", "-C", str(repo_root), "reset", "-q", "--", path],
                check=False, capture_output=True, timeout=15,
            )
            updated.append(path)
        except (subprocess.TimeoutExpired, OSError) as e:
            log.warning("RESILIENT-152: self-sync of %s failed: %s", path, e)
            continue

    if updated:
        _emit_ambient({
            "ts": _now_iso(),
            "kind": "fleet_self_sync",
            "paths": updated,
            "trigger": "push_to_main_webhook",
            "after": (payload.get("after") or "")[:12],
        })
        log.info("RESILIENT-152: self-synced %d runtime path(s) to origin/main: %s",
                 len(updated), ", ".join(updated))
    return len(updated)


def _trigger_checkout_sync(payload: dict) -> None:
    """RESILIENT-629: on push to origin/main, kick off scripts/ops/checkout-sync.sh
    immediately instead of waiting for the next cron tick (up to 60s away —
    see scripts/setup/install-checkout-sync-launchd.sh). This is the "webhook
    endpoint triggers an immediate pull" half of RESILIENT-629 AC2; the cron
    job is the fallback that guarantees convergence even if a webhook delivery
    is dropped.

    Fire-and-forget: checkout-sync.sh does its own fetch/ff-only-merge and
    ambient logging (kind=checkout_synced / checkout_sync_failed /
    checkout_sync_skipped — AC4), so this only needs to launch it, not wait
    for or interpret the result. Never raises — a launch failure here must
    not fail the webhook response.
    """
    if payload.get("ref") != "refs/heads/main":
        return
    repo_root = _repo_root()
    sync_script = repo_root / "scripts" / "ops" / "checkout-sync.sh"
    if not sync_script.exists():
        return
    try:
        subprocess.Popen(
            ["/bin/bash", str(sync_script)],
            cwd=str(repo_root),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        log.info("RESILIENT-629: launched checkout-sync.sh for immediate pull on push to main")
    except OSError as e:
        log.warning("RESILIENT-629: failed to launch checkout-sync.sh: %s", e)


def _verify_signature(secret: str, payload: bytes, header: str | None) -> bool:
    """Verify GitHub's X-Hub-Signature-256 header. Constant-time compare."""
    if not secret or not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def _upsert_pr(conn: sqlite3.Connection, pr: dict, payload: dict) -> None:
    """Upsert a pull_request row into pr_state."""
    now = _now_iso()
    # INFRA-1368: store merge_state_status in its own column so the gh-shim can
    # look it up directly without parsing raw_payload_json (whose format differs
    # between webhook and REST sources). pr.get("mergeable_state") is the correct
    # path inside the pull_request sub-object of a GitHub pull_request webhook.
    merge_state_status = pr.get("mergeable_state")
    conn.execute(
        """
        INSERT INTO pr_state (
            number, head_ref, head_sha, base_ref, base_sha,
            mergeable_state, auto_merge_enabled, draft, merged_at,
            title, user_login, updated_at_api, fetched_at_local, raw_payload_json,
            merge_state_status
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(number) DO UPDATE SET
            head_ref           = excluded.head_ref,
            head_sha           = excluded.head_sha,
            base_ref           = excluded.base_ref,
            base_sha           = excluded.base_sha,
            mergeable_state    = excluded.mergeable_state,
            auto_merge_enabled = excluded.auto_merge_enabled,
            draft              = excluded.draft,
            merged_at          = excluded.merged_at,
            title              = excluded.title,
            user_login         = excluded.user_login,
            updated_at_api     = excluded.updated_at_api,
            fetched_at_local   = excluded.fetched_at_local,
            raw_payload_json   = excluded.raw_payload_json,
            merge_state_status = excluded.merge_state_status
        """,
        (
            pr.get("number"),
            (pr.get("head") or {}).get("ref"),
            (pr.get("head") or {}).get("sha"),
            (pr.get("base") or {}).get("ref"),
            (pr.get("base") or {}).get("sha"),
            pr.get("mergeable_state"),
            1 if pr.get("auto_merge") else 0,
            1 if pr.get("draft") else 0,
            pr.get("merged_at"),
            pr.get("title"),
            (pr.get("user") or {}).get("login"),
            pr.get("updated_at") or _now_iso(),
            now,
            json.dumps(payload),
            merge_state_status,
        ),
    )
    conn.commit()
    # INFRA-1873: emit once per _upsert_pr so dashboards can distinguish
    # webhook-driven cache freshness from REST-driven freshness.
    _emit_ambient({
        "ts": _now_iso(),
        "kind": "webhook_cache_write",
        "target": "pr",
        "number": pr.get("number"),
        "head_sha": (pr.get("head") or {}).get("sha"),
        "action": payload.get("action"),
    })


def _mark_open_prs_stale(conn: sqlite3.Connection) -> int:
    """On push to main, every open PR may have become BEHIND. Mark all open PRs
    as fetched_at_local=NULL so the next cache_lookup forces a re-fetch."""
    cur = conn.execute("UPDATE pr_state SET fetched_at_local = '1970-01-01T00:00:00Z' WHERE merged_at IS NULL")
    conn.commit()
    return cur.rowcount


# INFRA-1110: process-lifetime counters for /health endpoint.
_health_started_at = _now_iso()
_health_events_received_total = 0
_health_last_event_at: str | None = None


class Handler(BaseHTTPRequestHandler):
    server_version = "ChumpWebhookReceiver/1.0"

    def log_message(self, format: str, *args) -> None:  # type: ignore[override]
        log.info("%s - %s", self.address_string(), format % args)

    def _respond(self, status: int, body: str = "", content_type: str = "text/plain; charset=utf-8") -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body.encode("utf-8"))

    def do_GET(self) -> None:  # noqa: N802
        # INFRA-1110: /health for operator liveness probe.
        if self.path == "/health":
            from datetime import timedelta
            stale_threshold_s = 24 * 3600
            status_ok = True
            if _health_last_event_at:
                try:
                    last = datetime.strptime(_health_last_event_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
                    if (datetime.now(timezone.utc) - last).total_seconds() > stale_threshold_s:
                        status_ok = False
                except Exception:
                    pass
            body = json.dumps({
                "status": "ok" if status_ok else "stale",
                "pid": os.getpid(),
                "started_at": _health_started_at,
                "events_received_total": _health_events_received_total,
                "last_event_at": _health_last_event_at,
                "cache_db_path": str(CACHE_DB),
            }, indent=2) + "\n"
            self._respond(200 if status_ok else 503, body, content_type="application/json")
            return
        self._respond(404, "not found\n")

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler convention)
        if self.path != "/webhook":
            self._respond(404, "not found\n")
            return

        length = int(self.headers.get("Content-Length", "0"))
        payload_bytes = self.rfile.read(length)
        sig_header = self.headers.get("X-Hub-Signature-256")

        if not _verify_signature(SECRET, payload_bytes, sig_header):
            _emit_ambient({
                "ts": _now_iso(),
                "kind": "webhook_event_rejected",
                "reason": "hmac_mismatch",
                "source_ip": self.client_address[0],
            })
            self._respond(401, "invalid signature\n")
            return

        event_type = self.headers.get("X-GitHub-Event", "unknown")
        try:
            payload = json.loads(payload_bytes.decode("utf-8"))
        except json.JSONDecodeError:
            self._respond(400, "invalid json\n")
            return

        try:
            with sqlite3.connect(str(CACHE_DB)) as conn:
                _ensure_schema(conn)
                if event_type == "pull_request":
                    pr = payload.get("pull_request") or {}
                    if pr:
                        _upsert_pr(conn, pr, payload)
                        _emit_ambient({
                            "ts": _now_iso(),
                            "kind": "webhook_event_received",
                            "event_type": event_type,
                            "action": payload.get("action"),
                            "pr_number": pr.get("number"),
                        })
                        # INFRA-1444: on PR merge, auto-release sibling leases
                        # whose gap_id matches a gap referenced in the PR title/body.
                        # Closes the "orphan lease + worktree after sibling shipped
                        # the same gap" pattern observed today (2026-05-15).
                        released = _auto_release_sibling_leases(pr, payload)
                        if released > 0:
                            log.info("INFRA-1444: auto-released %d orphaned lease(s) for PR #%s",
                                     released, pr.get("number"))
                        # CREDIBLE-092: on PR merge, flip referenced gaps to
                        # status=done in the canonical state.db (the webhook
                        # receiver has state.db access; the CI auto-flip workflow
                        # does not — that's why merged gaps stayed open + got
                        # re-claimed as ghosts).
                        flipped = _auto_flip_gaps_done(pr, payload)
                        if flipped > 0:
                            log.info("CREDIBLE-092: flipped %d gap(s) to done for PR #%s",
                                     flipped, pr.get("number"))
                        # INFRA-1705: on PR merge, prune the corresponding
                        # /tmp/chump-<slug>/ worktree immediately so the
                        # 5-10min "orphan window" before the next periodic
                        # prune sweep is closed.
                        pruned = _auto_prune_worktree_on_merge(pr, payload)
                        if pruned > 0:
                            log.info("INFRA-1705: auto-pruned worktree for PR #%s",
                                     pr.get("number"))
                elif event_type in ("check_suite", "workflow_run"):
                    # Touch fetched_at_local for referenced PRs so consumers re-fetch.
                    suite = payload.get(event_type) or {}
                    prs = suite.get("pull_requests") or []
                    for pr in prs:
                        conn.execute(
                            "UPDATE pr_state SET fetched_at_local = ? WHERE number = ?",
                            (_now_iso(), pr.get("number")),
                        )
                    conn.commit()
                    # INFRA-1107: cache check_runs per head SHA so bot-merge can
                    # read CI status from sqlite instead of polling gh api.
                    # The check_suite payload's `check_runs` URL points at a list;
                    # the workflow_run payload has `jobs` with similar shape. For
                    # check_suite, we use the head_sha + the workflow conclusion
                    # as a single check-row (named after the workflow).
                    head_sha = suite.get("head_sha") or suite.get("head_commit", {}).get("id")
                    runs_to_cache = []
                    if event_type == "check_suite":
                        # check_suite payload has aggregate status/conclusion;
                        # use the workflow name(s) as check_run names.
                        name = suite.get("app", {}).get("slug") or "check_suite"
                        runs_to_cache.append({
                            "name": name,
                            "status": suite.get("status"),
                            "conclusion": suite.get("conclusion"),
                            "started_at": suite.get("created_at"),
                            "completed_at": suite.get("updated_at"),
                        })
                    elif event_type == "workflow_run":
                        runs_to_cache.append({
                            "name": suite.get("name") or "workflow_run",
                            "status": suite.get("status"),
                            "conclusion": suite.get("conclusion"),
                            "started_at": suite.get("run_started_at"),
                            "completed_at": suite.get("updated_at"),
                        })
                        # INFRA-1870: emit ci_cascade_cancelled when a workflow_run
                        # is cancelled (concurrency cancel-in-progress per ci.yml).
                        # action=completed + conclusion=cancelled → cascade or user cancel.
                        # reason heuristic:
                        #   - "superseded": GitHub cancel-in-progress (standard concurrency group)
                        #   - "user": manual cancellation (no automated concurrency signal available
                        #             from the payload; GH does not expose the trigger in webhook)
                        #   - "timeout": job-level timeout exceeded (also surfaces as cancelled)
                        # All three cases: conclusion=cancelled; we use "superseded" as the
                        # default because it is by far the most common cause in this repo
                        # (ci.yml cancel-in-progress on PR fixup pushes).  A future slice
                        # can add finer discrimination once GH exposes the cancel source.
                        if payload.get("action") == "completed" and suite.get("conclusion") == "cancelled":
                            wf_pr_list = suite.get("pull_requests") or []
                            wf_pr_number = wf_pr_list[0].get("number") if wf_pr_list else None
                            # predecessor_sha: the commit that was running before this cancellation.
                            # The head_commit of the workflow_run that got cancelled IS the predecessor
                            # from the perspective of the superseding run.  We expose head_sha here.
                            predecessor_sha = suite.get("head_sha") or None
                            _emit_ambient({
                                "ts": _now_iso(),
                                "kind": "ci_cascade_cancelled",
                                "workflow_run_id": suite.get("id"),
                                "pr_number": wf_pr_number,
                                "predecessor_sha": predecessor_sha,
                                "reason": "superseded",
                            })
                            log.info(
                                "INFRA-1870: ci_cascade_cancelled workflow_run_id=%s pr=%s sha=%s",
                                suite.get("id"), wf_pr_number, predecessor_sha,
                            )
                    cached_n = _upsert_check_runs(conn, head_sha or "", runs_to_cache)
                    # INFRA-1873: emit once per _upsert_check_runs call so dashboards
                    # can distinguish webhook-driven check_runs freshness from REST.
                    if cached_n > 0:
                        _emit_ambient({
                            "ts": _now_iso(),
                            "kind": "webhook_cache_write",
                            "target": "check_runs",
                            "number": (prs[0].get("number") if prs else None),
                            "head_sha": head_sha or None,
                            "runs_count": cached_n,
                            "action": payload.get("action"),
                        })
                    _emit_ambient({
                        "ts": _now_iso(),
                        "kind": "webhook_event_received",
                        "event_type": event_type,
                        "action": payload.get("action"),
                        "pr_number": None,
                        "check_runs_cached": cached_n,
                    })
                elif event_type == "push":
                    if payload.get("ref") == "refs/heads/main":
                        n = _mark_open_prs_stale(conn)
                        # RESILIENT-152: a push to main may carry merged script
                        # fixes that the running fleet (reading from this same
                        # checkout) won't see until the working tree is updated.
                        # Surgically sync runtime scripts now so cures auto-deploy.
                        synced = _self_sync_fleet_scripts(payload)
                        if synced > 0:
                            log.info("RESILIENT-152: self-synced %d runtime path(s) on push to main", synced)
                        # RESILIENT-629: also kick an immediate full checkout
                        # sync (fetch + ff-only merge) rather than waiting for
                        # the next 60s cron tick.
                        _trigger_checkout_sync(payload)
                        _emit_ambient({
                            "ts": _now_iso(),
                            "kind": "webhook_event_received",
                            "event_type": event_type,
                            "action": "push_to_main",
                            "pr_number": None,
                            "marked_stale_count": n,
                        })
                # Unknown event types: 200 OK, no DB write — GitHub retries forever
                # on non-2xx, so don't fail.
            # INFRA-1110: bump counters AFTER successful processing.
            global _health_events_received_total, _health_last_event_at
            _health_events_received_total += 1
            _health_last_event_at = _now_iso()
        except Exception as e:
            log.error("DB write failed: %s", e)
            self._respond(500, "internal\n")
            return

        self._respond(200, "ok\n")


def main() -> None:
    if not SECRET:
        log.error("CHUMP_GITHUB_WEBHOOK_SECRET is required")
        sys.exit(2)
    CACHE_DB.parent.mkdir(parents=True, exist_ok=True)
    log.info("listening on :%d cache=%s ambient=%s", PORT, CACHE_DB, AMBIENT)
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("shutting down")


if __name__ == "__main__":
    main()
