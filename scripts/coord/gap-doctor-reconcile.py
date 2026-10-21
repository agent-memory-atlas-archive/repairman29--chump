#!/usr/bin/env python3
"""gap-doctor-reconcile.py — INFRA-303

Bidirectional reconciler between state.db (canonical SQLite store) and
docs/gaps/<ID>.yaml (human-readable mirror). Fills missing state.db fields
from the YAML mirror so a subsequent `chump gap dump --per-file` produces
ZERO diff against the working tree.

## Why

State.db is the canonical store post-INFRA-059, but it's been drifting
from the YAML mirror. Many gaps have description / acceptance_criteria /
notes / source_doc / opened_date in their YAML files but NULL in state.db
(because pre-INFRA-200 raw-YAML edits bypassed the chump CLI, and some
older `chump gap reserve` calls only stored title/domain/priority/effort).

Symptom from 2026-05-02 dogfood: a fresh `chump gap dump --per-file`
produced 189 changed YAML files with 922 insertions / 3701 deletions —
the deletions were content state.db didn't know about.

## Strategy

For each YAML file:
  1. Parse all fields.
  2. Look up the gap in state.db.
  3. For each field, if state.db is empty/null AND YAML has a value,
     write YAML→DB via `chump gap set --<field>`.
  4. Never overwrite a non-empty state.db field with a YAML value
     (operator-curated state.db wins; YAML mirror is regen-only).

After: `chump gap dump --per-file && git diff docs/gaps/` produces 0 diff
(modulo gaps where state.db has a curated value the YAML doesn't reflect —
those are healed in the OTHER direction by the dump).

## Usage

  python3 scripts/coord/gap-doctor-reconcile.py --dry-run    # report only
  python3 scripts/coord/gap-doctor-reconcile.py              # apply

Fields reconciled: description, acceptance_criteria, notes, source_doc,
opened_date, closed_date, closed_pr, depends_on. (status, title, priority,
effort, domain are always populated by `chump gap reserve`.)
"""

import argparse
import glob
import importlib.util
import json
import sqlite3
import os
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"]).decode().strip()
)
GAPS_DIR = REPO_ROOT / "docs" / "gaps"
DISPATCH_DIR = REPO_ROOT / "scripts" / "dispatch"

# Fields we'll reconcile (state.db field name → CLI flag name).
RECONCILABLE_FIELDS = {
    "description": "--description",
    "notes": "--notes",
    "source_doc": "--source-doc",
    "opened_date": "--opened-date",
    "closed_date": "--closed-date",
    "closed_pr": "--closed-pr",
    # acceptance_criteria + depends_on are list-shaped; handled specially below.
}


def load_db() -> dict:
    """Returns {gap_id: row_dict} from `chump gap list --json`."""
    out = subprocess.check_output(["chump", "gap", "list", "--json"]).decode()
    return {g["id"]: g for g in json.loads(out)}


def parse_yaml_file(path: Path) -> dict:
    """Parse a docs/gaps/<ID>.yaml file. Uses PyYAML if available; falls
    back to a tiny regex parser for fields we care about. Returns a dict
    with the keys we reconcile (description/notes/etc.)."""
    text = path.read_text(encoding="utf-8")
    try:
        import yaml  # type: ignore

        data = yaml.safe_load(text)
        if isinstance(data, list):
            data = data[0] if data else {}
        return data if isinstance(data, dict) else {}
    except Exception:
        # Regex fallback (won't capture multi-line description well — best-effort).
        import re

        out = {}
        for field in [
            "description",
            "notes",
            "source_doc",
            "opened_date",
            "closed_date",
            "closed_pr",
        ]:
            m = re.search(rf"^\s*{field}:\s*['\"]?(.+?)['\"]?\s*$", text, re.M)
            if m:
                out[field] = m.group(1)
        return out


def is_empty(v) -> bool:
    """Treat None / empty-string / empty-list as empty for reconciliation."""
    return v is None or v == "" or v == [] or v == "null"


def normalize(v) -> str:
    """Normalize a value to string for comparison."""
    if isinstance(v, list):
        return "|".join(str(x) for x in v)
    return str(v) if v is not None else ""


def is_yaml_richer(yaml_v, db_v) -> bool:
    """INFRA-316: heuristic for "YAML has materially more content than DB."

    Returns True when YAML's value is significantly longer than DB's (>= 3x
    length OR has multi-line content while DB is single-line). This catches
    the SECURITY-005 / META-011 class of drift where state.db has a
    truncated one-line summary but YAML has the full multi-paragraph
    description.

    Conservative: simple length compare only on stringy fields. Lists and
    None are caller-handled before this gets called.
    """
    if yaml_v is None or db_v is None:
        return False
    ys, ds = str(yaml_v), str(db_v)
    if not ys.strip() or not ds.strip():
        return False
    # Multi-line YAML over single-line DB is an automatic win.
    if "\n" in ys and "\n" not in ds:
        return True
    # Length-based: 3x is the conservative threshold.
    return len(ys) >= 3 * len(ds) and len(ys) - len(ds) >= 100


def reconcile_one(gid: str, yaml_data: dict, db_row: dict, dry_run: bool) -> list:
    """Return a list of (field, action, value) for each reconciliation."""
    actions = []

    for field, flag in RECONCILABLE_FIELDS.items():
        yaml_v = yaml_data.get(field)
        db_v = db_row.get(field)
        # Two reasons to write YAML→DB:
        #   1. DB is empty and YAML has a value (original INFRA-303 case)
        #   2. INFRA-316: YAML is materially richer (DB has a truncated stub)
        should_write = (not is_empty(yaml_v) and is_empty(db_v)) or is_yaml_richer(
            yaml_v, db_v
        )
        if should_write:
            value = str(yaml_v).strip()
            tag = "set" if is_empty(db_v) else "overwrite-richer"
            actions.append((field, tag, value))
            if not dry_run:
                cmd = ["chump", "gap", "set", gid, flag, value]
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode != 0:
                    print(
                        f"  WARN {gid} {field}: chump gap set failed: {r.stderr.strip()[:80]}",
                        file=sys.stderr,
                    )

    # acceptance_criteria — pipe-separated list
    yaml_ac = yaml_data.get("acceptance_criteria")
    db_ac = db_row.get("acceptance_criteria")
    # YAML list → "a|b|c"; DB stores as JSON array string sometimes.
    if isinstance(yaml_ac, list) and yaml_ac and is_empty(db_ac):
        joined = "|".join(str(x).strip() for x in yaml_ac)
        actions.append(("acceptance_criteria", "set", joined))
        if not dry_run:
            r = subprocess.run(
                ["chump", "gap", "set", gid, "--acceptance-criteria", joined],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(
                    f"  WARN {gid} acceptance_criteria: {r.stderr.strip()[:80]}",
                    file=sys.stderr,
                )

    # depends_on — comma-separated
    yaml_dep = yaml_data.get("depends_on")
    db_dep = db_row.get("depends_on")
    if isinstance(yaml_dep, list) and yaml_dep and is_empty(db_dep):
        joined = ",".join(str(x).strip() for x in yaml_dep)
        actions.append(("depends_on", "set", joined))
        if not dry_run:
            r = subprocess.run(
                ["chump", "gap", "set", gid, "--depends-on", joined],
                capture_output=True,
                text=True,
            )
            if r.returncode != 0:
                print(
                    f"  WARN {gid} depends_on: {r.stderr.strip()[:80]}",
                    file=sys.stderr,
                )

    return actions


def check_closure_drift(db: dict, ambient_path: Path, dry_run: bool) -> int:
    """META-059: surface gaps where status=open BUT closed_pr is set and that
    PR is state=merged. Emits kind=gap_closure_drift to ambient.jsonl for each.
    Uses REST (gh api repos/.../pulls/N) so this works during GraphQL exhaustion.

    Returns number of drift cases found.
    """
    candidates = [
        (gid, row)
        for gid, row in db.items()
        if row.get("status") == "open" and row.get("closed_pr")
    ]
    if not candidates:
        print("closure-drift: no open gaps with closed_pr set — clean")
        return 0

    # Resolve owner/repo via gh — survives GraphQL exhaustion (gh repo view
    # uses REST under the hood for nameWithOwner).
    try:
        repo = subprocess.check_output(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            text=True,
        ).strip()
    except subprocess.CalledProcessError:
        print("closure-drift: cannot resolve gh repo (offline?) — skipping", file=sys.stderr)
        return 0

    drift = 0
    ambient_path.parent.mkdir(parents=True, exist_ok=True)
    from datetime import datetime, timezone

    for gid, row in candidates:
        pr_num = row["closed_pr"]
        # REST endpoint — costs core bucket, NOT graphql.
        r = subprocess.run(
            ["gh", "api", f"repos/{repo}/pulls/{pr_num}",
             "--jq", '"\\(.state) \\(.merged_at // "-")"'],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            print(f"  WARN {gid} PR #{pr_num}: gh api failed ({r.stderr.strip()[:60]})",
                  file=sys.stderr)
            continue
        parts = r.stdout.strip().split(None, 1)
        if len(parts) < 2:
            continue
        state, merged_at = parts[0], parts[1]
        if state != "closed" or merged_at == "-":
            continue
        drift += 1
        print(f"  DRIFT {gid}: status=open BUT PR #{pr_num} merged {merged_at[:10]}")
        if not dry_run:
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            ev = {
                "ts": ts, "kind": "gap_closure_drift",
                "gap_id": gid, "pr_number": pr_num,
                "merged_at": merged_at, "source": "gap-doctor-reconcile",
            }
            with ambient_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(ev, separators=(",", ":")) + "\n")
            # INFRA-303 backstop: don't just DETECT the drift, RESOLVE it. GitHub is
            # the ground truth here — the PR merged, so the gap IS done. Close it via
            # the canonical path (records closed_pr + syncs yaml via ZERO-WASTE-056).
            # This is the safety net for the fragile bot-merge auto-close step
            # (CREDIBLE-295), which silently skips and leaves OPEN-BUT-LANDED ghosts.
            # Best-effort: a failure just re-tries next cycle (idempotent).
            # Write the canonical store directly (state.db) — a bookkeeping close of
            # an already-merged PR must not go through the ship-workflow CLI (which
            # guards on current-main). This reconciler IS the state.db owner. The
            # sibling field-reconcile pass keeps the YAML mirror in sync.
            try:
                subprocess.run(
                    ["chump", "gap", "ship", gid, "--closed-pr", str(pr_num)],
                    check=True, capture_output=True, text=True
                )
                print(f"  CLOSED {gid} (PR #{pr_num} merged {merged_at[:10]}) — drift resolved")
            except (subprocess.CalledProcessError, FileNotFoundError) as _e:
                print(f"  WARN could not close {gid}: {_e}")

    if dry_run:
        print(f"  (dry-run — {drift} drift case(s) would emit kind=gap_closure_drift)")
    else:
        print(f"  emitted {drift} gap_closure_drift event(s) to {ambient_path}")
    return drift


# ─────────────────────────────────────────────────────────────────────────────
# INFRA-3826 — already-satisfied backstop (the OTHER half of the closure blind
# spot). check_closure_drift above only sees open gaps that ALREADY have
# closed_pr set. The looping/covered gaps never got linked to the PR that
# happened to implement them, so their closed_pr is NULL and they are invisible
# to it — they get re-picked forever, re-burning a Sonnet cycle each time just to
# re-conclude "already shipped." INFRA-3808's worker.sh:detect_already_satisfied
# catches the strongest cases LIVE, but only in the moment the cycle ends; this
# is the durable periodic backstop for the ones it misses (dirty worktree at the
# time, CLI close failed, or gaps that pre-date the live detector).
# ─────────────────────────────────────────────────────────────────────────────


def resolve_state_db() -> Path:
    """Ground-truth gap-store path, read DIRECTLY (not via `chump gap list`).

    The chump CLI resolves its store through the chumpd socket / CHUMP_REPO /
    cwd (repo_path::repo_root) and can end up reading a DIFFERENT — often empty —
    SQLite file than the one the workers write. Observed on CJ: `chump gap list`
    reports an empty/mismatched store while the workers' state.db is full. So the
    backstop reads the canonical file directly, the same file the drift-resolver
    close above already writes to (CHUMP_STATE_DB, else
    CHUMP_REPO_ROOT/.chump/state.db, else the repo checkout's .chump/state.db).
    """
    p = os.environ.get("CHUMP_STATE_DB")
    if p:
        return Path(p)
    root = os.environ.get("CHUMP_REPO_ROOT")
    if root:
        return Path(root) / ".chump" / "state.db"
    return REPO_ROOT / ".chump" / "state.db"


def open_gaps_without_closed_pr(state_db: Path) -> list:
    """Open gaps with NO covering PR linked — the class check_closure_drift is
    blind to. Read straight from SQLite (see resolve_state_db). Returns a list of
    {id, title} dicts. A missing DB is not fatal (returns [])."""
    if not state_db.exists():
        print(
            f"already-satisfied: state.db not found at {state_db} — skipping",
            file=sys.stderr,
        )
        return []
    try:
        con = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    except sqlite3.Error as e:
        print(f"already-satisfied: cannot open {state_db}: {e}", file=sys.stderr)
        return []
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            "SELECT id, title FROM gaps "
            "WHERE status='open' AND (closed_pr IS NULL OR closed_pr=0)"
        ).fetchall()
    except sqlite3.Error as e:
        print(f"already-satisfied: sqlite read failed: {e}", file=sys.stderr)
        return []
    finally:
        con.close()
    return [dict(r) for r in rows]


def load_detector():
    """Import scripts/dispatch/detect_already_satisfied.py so we reuse the EXACT
    3-factor already-satisfied signal the worker uses live (INFRA-3768:
    already-done phrase + no-op phrase + a covering PR reference), rather than
    re-deriving its regex vocabulary here and letting the two drift apart."""
    path = DISPATCH_DIR / "detect_already_satisfied.py"
    if not path.exists():
        return None
    try:
        spec = importlib.util.spec_from_file_location("detect_already_satisfied", path)
        if spec is None or spec.loader is None:
            return None
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return mod
    except Exception as e:  # pragma: no cover - defensive
        print(f"already-satisfied: could not load detector: {e}", file=sys.stderr)
        return None


def find_latest_cycle_log(gap_id: str) -> "Path | None":
    """Newest worker cycle log for this gap, or None. worker.sh writes
    $FLEET_LOG_DIR/agent-<ID>-cycle<N>-<GAP_ID>.log; FLEET_LOG_DIR defaults to
    /tmp/chump-fleet-<sid>. These live in /tmp and rotate away, so this is
    best-effort — a missing log means "no evidence this run," not a failure.
    Extra dirs can be supplied via CHUMP_FLEET_LOG_GLOBS (colon-separated)."""
    globs = []
    env_dir = os.environ.get("FLEET_LOG_DIR")
    if env_dir:
        globs.append(f"{env_dir}/*-{gap_id}.log")
    extra = os.environ.get("CHUMP_FLEET_LOG_GLOBS")
    if extra:
        globs.extend(f"{d}/*-{gap_id}.log" for d in extra.split(":") if d)
    globs.append(f"/tmp/chump-fleet-*/*-{gap_id}.log")
    candidates = []
    for pat in globs:
        candidates.extend(glob.glob(pat))
    if not candidates:
        return None
    return Path(max(candidates, key=lambda p: os.path.getmtime(p)))


def resolve_gh_repo() -> "str | None":
    """owner/repo via gh (REST under the hood — survives GraphQL exhaustion)."""
    try:
        return subprocess.check_output(
            ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
            text=True,
        ).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


def github_cache_db() -> Path:
    """Path to the local webhook-fed GitHub cache (INFRA-1081). Reads here are
    <100ms and don't touch the GraphQL/REST rate limit — so the merged-state
    check is cache-first, REST only on a cache miss (CLAUDE.md §Cache-first)."""
    return REPO_ROOT / ".chump" / "github_cache.db"


def cache_pr_merged(pr_num) -> "str | None":
    """Cache-first merged check: returns merged_at (ISO str) iff the local
    github_cache.db positively shows PR <pr_num> MERGED, else None (miss / not
    merged / cache absent). Only a POSITIVE merged hit short-circuits REST — a
    cache 'not merged' or miss falls through to REST ground truth so a stale
    cache can never permanently block a legitimate close."""
    db = github_cache_db()
    if not db.exists() or db.stat().st_size == 0:
        return None
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    except sqlite3.Error:
        return None
    try:
        row = con.execute(
            "SELECT merged_at FROM pr_state WHERE number=?1", (int(pr_num),)
        ).fetchone()
    except (sqlite3.Error, ValueError):
        return None
    finally:
        con.close()
    if row and row[0]:
        return str(row[0])
    return None


def pr_merged(repo: str, pr_num) -> tuple:
    """(is_merged, merged_at) for a PR, cache-first then REST ground truth.

    is_merged is tri-state:
      True   — PR is verified MERGED (cache positive hit, or REST state=closed
               AND merged_at is a real timestamp). merged_at carries the ISO ts.
      False  — PR is verified NOT merged (open, or closed-unmerged).
      None   — the merged-flag fetch ERRORED (gh non-zero / unparseable). The
               caller MUST fail closed (close nothing) and emit an event.

    Cache reads cost nothing against the rate limit; REST costs the core bucket,
    NOT graphql. A closed-unmerged PR is never evidence the work landed."""
    cached = cache_pr_merged(pr_num)
    if cached is not None:
        return (True, cached)
    r = subprocess.run(
        ["gh", "api", f"repos/{repo}/pulls/{pr_num}",
         "--jq", '"\\(.state) \\(.merged_at // "-")"'],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return (None, "")
    parts = r.stdout.strip().split(None, 1)
    if len(parts) < 2:
        return (None, "")
    state, merged_at = parts[0], parts[1]
    if state == "closed" and merged_at != "-":
        return (True, merged_at)
    return (False, "")


def _emit(ambient_path: Path, event: dict) -> None:
    ambient_path.parent.mkdir(parents=True, exist_ok=True)
    with ambient_path.open("a", encoding="utf-8") as f:
        f.write(json.dumps(event, separators=(",", ":")) + "\n")


def check_already_satisfied(state_db: Path, ambient_path: Path, dry_run: bool) -> tuple:
    """INFRA-3826 backstop. Close open gaps whose work is ALREADY on main but
    that were never linked to the covering PR (closed_pr NULL).

    HIGH confidence → auto-close already_satisfied:
      the gap's latest worker cycle log fires the 3-factor already-satisfied
      signal (already-done + no-op + covering PR), AND that PR is verified MERGED
      on GitHub. Mirrors worker.sh's live INFRA-3808 close (status +
      closed_pr + evidence receipt). Emits kind=gap_already_satisfied_closed.

    LOW confidence → FLAG only, never close (a wrong auto-close discards real
    work): the detector fired but the PR is not merged / unresolvable, or gh is
    unavailable so we cannot verify. Emits kind=gap_already_satisfied_flagged
    with a reason. Leaves the gap open for a human/operator to adjudicate.

    Returns (closed_count, flagged_count).
    """
    gaps = open_gaps_without_closed_pr(state_db)
    if not gaps:
        print("already-satisfied: no open gaps without closed_pr — nothing to scan")
        return (0, 0)
    print(f"already-satisfied: scanning {len(gaps)} open gap(s) with no closed_pr…")

    detector = load_detector()
    if detector is None:
        print(
            "already-satisfied: detector unavailable — cannot evaluate safely, skipping",
            file=sys.stderr,
        )
        return (0, 0)

    repo = resolve_gh_repo()
    if repo is None:
        print(
            "already-satisfied: gh repo unresolved (offline?) — will FLAG matches, "
            "not close (cannot verify PR merge)",
            file=sys.stderr,
        )

    from datetime import datetime, timezone

    closed = flagged = 0
    for gap in gaps:
        gid = gap["id"]
        log = find_latest_cycle_log(gid)
        if log is None:
            continue
        cov_pr = detector.detect(detector.final_assistant_text(str(log)))
        if not cov_pr:
            continue

        merged, merged_at = (False, "")
        reason = "gh_unavailable"
        if repo is not None:
            merged, merged_at = pr_merged(repo, cov_pr)
            reason = "pr_not_merged"

        if merged:
            print(
                f"  SATISFIED {gid}: cycle log {log.name} reports work already "
                f"shipped in PR #{cov_pr} (merged {merged_at[:10]})"
            )
            if not dry_run:
                evidence = (
                    f"already-satisfied backstop (INFRA-3826): worker cycle log "
                    f"{log.name} reports the work already shipped in PR #{cov_pr} "
                    f"(merged {merged_at[:10]}); worktree had no diff to ship. "
                    f"Auto-closed by gap-doctor-reconcile --check-already-satisfied."
                )
                try:
                    subprocess.run(
                        ["chump", "gap", "ship", gid, "--closed-pr", str(int(cov_pr))],
                        check=True, capture_output=True, text=True
                    )
                    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    _emit(ambient_path, {
                        "ts": ts, "kind": "gap_already_satisfied_closed",
                        "gap_id": gid, "pr_number": int(cov_pr),
                        "merged_at": merged_at, "source": "gap-doctor-reconcile",
                    })
                    closed += 1
                    print(f"  CLOSED {gid} already_satisfied (covered by PR #{cov_pr})")
                except (subprocess.CalledProcessError, FileNotFoundError) as e:
                    print(f"  WARN could not close {gid}: {e}", file=sys.stderr)
            else:
                closed += 1
        else:
            # Signal fired but we can't stand behind an auto-close. FLAG it.
            print(
                f"  FLAG {gid}: cycle log {log.name} looks already-satisfied "
                f"(PR #{cov_pr}) but {reason} — flagging for review, NOT closing"
            )
            flagged += 1
            if not dry_run:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                _emit(ambient_path, {
                    "ts": ts, "kind": "gap_already_satisfied_flagged",
                    "gap_id": gid, "pr_number": int(cov_pr),
                    "reason": reason, "cycle_log": log.name,
                    "source": "gap-doctor-reconcile",
                })

    if dry_run:
        print(f"  (dry-run — {closed} would close, {flagged} would flag; no writes)")
    else:
        print(f"  closed {closed} already_satisfied, flagged {flagged} for review")
    return (closed, flagged)



# ─────────────────────────────────────────────────────────────────────────────
# CREDIBLE-1550 (Phase R R2, AC1/AC5) — merged-PR-LINK closure (typed-FK only).
#
# This pass closes the async-merge ghost class (real work shipped, PR merged
# after the worker cycle ended, canonical state.db left open). It USED to match
# the gap ID against the merged PR *title* — which on 2026-10-18 falsely closed
# the R3 umbrella CREDIBLE-1492 from a docs-only receipt PR (#5580) and closed
# CREDIBLE-1520 whole from its AC1-only slice PR (#5582). A title is not proof
# the PR implemented the gap. So this pass now trusts ONLY the typed gap_prs FK
# written at PR-open (CREDIBLE-1520 AC1): a gap closes iff a gap_prs row links a
# MERGED PR to THAT gap. A slice PR links to its slice gap, never the umbrella,
# so the umbrella is structurally protected (AC1 fixture). A docs-only PR titled
# with a gap ID but with no gap_prs row closes nothing (AC5); a merged
# title-named PR with no row emits a report-only pr_without_gap_link instead.
# The title-regex path (_GAP_TITLE_RE / merged_pr_gap_map) is
# deleted; CI grep gate scripts/ci/test-no-title-regex-gap-closers.sh fails on
# any reintroduction.
# ─────────────────────────────────────────────────────────────────────────────

# CREDIBLE-1552 (Phase R R2): the PARTIAL-body heuristic was DELETED here, not
# hardened. A closer must not infer partial-ness from prose — that is how an
# "AC1 only" slice PR was mistaken for a whole-gap close in the first place. The
# rule that replaces it is structural: a PR closes exactly the gap(s) its
# gap_prs rows link; a partial delivery is a SLICE gap with its own id; an
# umbrella closes only through gap-close-decomposed. So this reconcile reads the
# gap_prs FK plus GitHub's merged state (cache-first REST) and NOTHING else — no
# body regex, no title match. If the merged-flag fetch errors, it closes nothing
# and emits kind=gap_close_skipped_merge_fetch_error (fail closed).


def gap_pr_links(state_db: Path) -> dict:
    """gap_id -> [pr_number, ...] from the typed gap_prs table (CREDIBLE-1520
    AC1), read straight from canonical SQLite. Empty dict when the table is
    absent (old store) or unreadable — the closer then simply drains nothing,
    which is the safe outcome (a title match is never used as a fallback)."""
    if not state_db.exists():
        return {}
    try:
        con = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    except sqlite3.Error as e:
        print(f"merged-pr-links: cannot open {state_db}: {e}", file=sys.stderr)
        return {}
    try:
        rows = con.execute(
            "SELECT gap_id, pr_number FROM gap_prs ORDER BY opened_at DESC"
        ).fetchall()
    except sqlite3.Error:
        # No gap_prs table yet, or schema mismatch — nothing to drain.
        return {}
    finally:
        con.close()
    out: dict = {}
    for gid, pr in rows:
        out.setdefault(gid, []).append(pr)
    return out


def open_gap_ids(state_db: Path) -> list:
    """All status=open gap ids, read straight from canonical SQLite."""
    if not state_db.exists():
        print(f"merged-pr-titles: state.db not found at {state_db} — skipping",
              file=sys.stderr)
        return []
    try:
        con = sqlite3.connect(f"file:{state_db}?mode=ro", uri=True)
    except sqlite3.Error as e:
        print(f"merged-pr-titles: cannot open {state_db}: {e}", file=sys.stderr)
        return []
    try:
        rows = con.execute("SELECT id FROM gaps WHERE status='open'").fetchall()
    except sqlite3.Error as e:
        print(f"merged-pr-titles: sqlite read failed: {e}", file=sys.stderr)
        return []
    finally:
        con.close()
    return [r[0] for r in rows]


def check_merged_pr_links(state_db: Path, ambient_path: Path, dry_run: bool) -> int:
    """CREDIBLE-1550 (AC1/AC5): close open gaps that a typed gap_prs row links to
    a MERGED PR. Returns count closed.

    The ONLY closure proof is the gap_prs FK (written at PR-open, CREDIBLE-1520
    AC1) — never a PR title, never a PARTIAL-body regex (CREDIBLE-1552 deleted
    that heuristic). For each open gap that has gap_prs row(s), the most recently
    opened linked PR that is verified MERGED on GitHub closes exactly THAT gap
    (status=done + closed_pr + evidence), emitting kind=gap_closed_from_merged_pr.
    A slice PR links its slice gap, so an umbrella with no row of its own is never
    closed (AC1 fixture); a docs-only PR with no row closes nothing (AC5). If the
    merged-flag fetch ERRORS, the gap is left untouched and
    kind=gap_close_skipped_merge_fetch_error is emitted (fail closed).
    """
    from datetime import datetime, timezone

    repo = resolve_gh_repo()
    if repo is None:
        print("merged-pr-links: gh repo unresolved (offline?) — cannot verify "
              "merges, skipping", file=sys.stderr)
        return 0
    open_ids = set(open_gap_ids(state_db))
    if not open_ids:
        print("merged-pr-links: no open gaps — nothing to drain")
        return 0
    links = gap_pr_links(state_db)
    # Only open gaps that carry at least one typed PR link are candidates.
    candidates = {gid: links[gid] for gid in open_ids if gid in links}
    if not candidates:
        print(f"merged-pr-links: scanned {len(open_ids)} open gap(s) — none carry "
              f"a gap_prs row (title matching is not a fallback), clean")
        return 0
    print(f"merged-pr-links: {len(candidates)} open gap(s) carry a gap_prs row — "
          f"checking each linked PR for a merged close")
    closed = 0
    for gid in sorted(candidates):
        for pr_num in candidates[gid]:
            merged, merged_at = pr_merged(repo, pr_num)
            if merged is None:
                # Fail closed: the merged-flag fetch errored. Close NOTHING and
                # emit so the skipped close is visible. A later cycle retries.
                print(f"  SKIP {gid}: linked PR #{pr_num} merged-flag fetch "
                      f"errored — not closing (fail closed)")
                if not dry_run:
                    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                    _emit(ambient_path, {
                        "ts": ts, "kind": "gap_close_skipped_merge_fetch_error",
                        "gap_id": gid, "pr_number": int(pr_num),
                        "source": "gap-doctor-reconcile",
                    })
                continue  # an older link may still be fetchable + merged
            if not merged:
                continue
            cd = (merged_at or "")[:10]
            print(f"  GHOST {gid}: gap_prs-linked PR #{pr_num} merged {cd} — gap still open")
            if dry_run:
                closed += 1
                break
            try:
                subprocess.run(
                    ["chump", "gap", "ship", gid, "--closed-pr", str(int(pr_num))],
                    check=True, capture_output=True, text=True
                )
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                _emit(ambient_path, {
                    "ts": ts, "kind": "gap_closed_from_merged_pr",
                    "gap_id": gid, "pr_number": int(pr_num),
                    "merged_at": merged_at, "source": "gap-doctor-reconcile",
                })
                closed += 1
                print(f"  CLOSED {gid} done (gap_prs-linked PR #{pr_num} merged {cd})")
            except (subprocess.CalledProcessError, FileNotFoundError) as e:
                print(f"  WARN could not close {gid}: {e}", file=sys.stderr)
            break  # one close per gap; newest linked merged PR wins
    if dry_run:
        print(f"  (dry-run — {closed} would close; no writes)")
    else:
        print(f"  drained {closed} merged-but-open ghost(s) via gap_prs links")
    return closed


# CREDIBLE-1598: head-branch backstop. A lane branch deterministically encodes
# the one gap it was cut for (`claude/<gap-lowercase>-…`, legacy `chump/<GAP>-…`,
# or a bare id) — this is the branch/lease gap-id the no-title-regex gate
# (CREDIBLE-1550) explicitly BLESSES as a legitimate close source, NOT the PR
# title it bans. Mirrors scripts/dispatch/review-organ-tick.sh:derive_gap_from_branch.
_BRANCH_GAP_RE = re.compile(r"^(?:chump/|claude/)?([A-Za-z]+-[0-9]+)")


def gap_from_branch(branch: str) -> "str | None":
    m = _BRANCH_GAP_RE.match(branch or "")
    return m.group(1).upper() if m else None


def recent_merged_prs_with_branch(repo: str, limit: int = 100) -> list:
    """Recently merged PRs as [(number, head_ref, merged_at), ...], cache-first
    then REST. Fetches the HEAD BRANCH (never the title), so the no-title-regex
    gate (CREDIBLE-1550) stays green: closing keys on the lane branch, not prose.
    Returns [] on any failure — the head-branch pass then has nothing to scan."""
    db = github_cache_db()
    if db.exists() and db.stat().st_size > 0:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                rows = con.execute(
                    "SELECT number, COALESCE(head_ref,''), COALESCE(merged_at,'') "
                    "FROM pr_state WHERE merged_at IS NOT NULL "
                    "ORDER BY merged_at DESC LIMIT ?1",
                    (int(limit),),
                ).fetchall()
            finally:
                con.close()
            if rows:
                return [(int(n), str(h), str(m)) for n, h, m in rows]
        except sqlite3.Error:
            pass  # fall through to REST
    r = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--state", "merged",
         "--limit", str(int(limit)), "--json", "number,headRefName,mergedAt"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return []
    return [(int(d["number"]), str(d.get("headRefName", "")),
             str(d.get("mergedAt", ""))) for d in data]


def check_merged_pr_head_branch(state_db: Path, ambient_path: Path, dry_run: bool,
                                limit: int = 100) -> int:
    """CREDIBLE-1598 (AC2/AC4): close an open gap whose MERGED PR is identified by
    its HEAD BRANCH, even with NO gap_prs FK. This is the exact class the organ
    left behind (merge without link/ship) that check_merged_pr_links (needs the
    FK) and check_closure_drift (needs closed_pr) both miss. Keys on the lane
    branch `claude/<gap>-…` — the deterministic id the worker cut the branch for,
    not a title — and ships the still-open gap through `chump gap ship --closed-pr`
    (never a direct state.db write), logging a gap_closed_from_merged_pr receipt
    tagged via=head_branch. Reports the drift it fixes; prints 'clean' ONLY when
    no merged-PR head branch names an open gap (AC4 — never 'clean' while a
    merged-PR gap is open). Returns the count of drift cases found."""
    from datetime import datetime, timezone

    repo = resolve_gh_repo()
    if repo is None:
        print("merged-pr-head-branch: gh repo unresolved (offline?) — skipping",
              file=sys.stderr)
        return 0
    open_ids = {r["id"] for r in open_gaps_without_closed_pr(state_db)}
    if not open_ids:
        print("merged-pr-head-branch: no open gaps without closed_pr — clean")
        return 0
    merged = recent_merged_prs_with_branch(repo, limit)
    if not merged:
        print("merged-pr-head-branch: no recently merged PRs resolvable — "
              "nothing to scan")
        return 0
    found = 0
    closed = 0
    for pr_num, head_ref, merged_at in merged:
        gid = gap_from_branch(head_ref)
        if gid is None or gid not in open_ids:
            continue
        found += 1
        open_ids.discard(gid)  # one close per gap even if two branches name it
        cd = (merged_at or "")[:10]
        print(f"  GHOST {gid}: head-branch '{head_ref}' PR #{pr_num} merged {cd} "
              f"— gap still open, no closed_pr")
        if dry_run:
            continue
        try:
            subprocess.run(
                ["chump", "gap", "ship", gid, "--closed-pr", str(int(pr_num))],
                check=True, capture_output=True, text=True,
            )
            ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            _emit(ambient_path, {
                "ts": ts, "kind": "gap_closed_from_merged_pr",
                "gap_id": gid, "pr_number": int(pr_num),
                "merged_at": merged_at or "", "source": "gap-doctor-reconcile",
                "via": "head_branch",
            })
            closed += 1
            print(f"  CLOSED {gid} done (head-branch PR #{pr_num} merged {cd})")
        except (subprocess.CalledProcessError, FileNotFoundError) as e:
            print(f"  WARN could not close {gid}: {e}", file=sys.stderr)
    if found == 0:
        print(f"merged-pr-head-branch: scanned {len(merged)} merged PR(s) — "
              f"no open gap matches a merged PR's head branch, clean")
    elif dry_run:
        print(f"  (dry-run — {found} head-branch ghost(s) would close; no writes)")
    else:
        print(f"  found {found} head-branch merged-but-open ghost(s), closed {closed}")
    return found


# CREDIBLE-1552 (Phase R R2, AC1/AC5): gap IDs look like INFRA-123 / CREDIBLE-9.
# Used ONLY by the report-only pass below to name the open gap a merged PR
# titles — never to CLOSE anything (closes route exclusively through the
# gap_prs FK). gap-doctor-reconcile.py is allowlisted in
# scripts/ci/no-title-regex-gap-closers-allowlist.txt for exactly this reason.
_GAP_ID_RE = re.compile(r"\b[A-Z][A-Z0-9]*-[0-9]+\b")


def recent_merged_prs(repo: str, limit: int = 100) -> list:
    """Recently merged PRs as [(number, title), ...], cache-first then REST.

    Cache-first: the webhook-fed github_cache.db (INFRA-1081) carries merged_at,
    so a read here costs nothing against the rate limit. REST fallback uses
    `gh pr list --state merged` (core bucket). Returns [] on any failure — the
    report pass then simply has nothing to say (it never closes, so an empty
    list is always safe)."""
    db = github_cache_db()
    if db.exists() and db.stat().st_size > 0:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            try:
                rows = con.execute(
                    "SELECT number, COALESCE(title,'') FROM pr_state "
                    "WHERE merged_at IS NOT NULL "
                    "ORDER BY merged_at DESC LIMIT ?1",
                    (int(limit),),
                ).fetchall()
            finally:
                con.close()
            if rows:
                return [(int(n), str(t)) for n, t in rows]
        except sqlite3.Error:
            pass  # fall through to REST
    r = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--state", "merged",
         "--limit", str(int(limit)), "--json", "number,title"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout or "[]")
    except json.JSONDecodeError:
        return []
    return [(int(d["number"]), str(d.get("title", ""))) for d in data]


def check_unlinked_merged_prs(state_db: Path, ambient_path: Path, dry_run: bool,
                              limit: int = 100) -> int:
    """CREDIBLE-1552 (Phase R R2): REPORT-ONLY pass. Lists recently merged PRs
    (cache-first) and, for any merged PR whose TITLE names an OPEN gap that has
    NO gap_prs row linking this PR to it, prints 'UNLINKED <gid> PR #N, not
    closing' and emits kind=pr_without_gap_link. This surfaces the gaps the old
    title heuristic would have closed but the FK closer (correctly) will not —
    so an operator can add the missing gap_prs link (chump gap link-pr) or let
    CREDIBLE-1551 backfill it. It NEVER closes anything.

    Returns the count of unlinked (merged-PR, open-gap) pairs reported."""
    from datetime import datetime, timezone

    repo = resolve_gh_repo()
    if repo is None:
        print("unlinked-merged: gh repo unresolved (offline?) — skipping report",
              file=sys.stderr)
        return 0
    open_ids = set(open_gap_ids(state_db))
    if not open_ids:
        print("unlinked-merged: no open gaps — nothing to report")
        return 0
    links = gap_pr_links(state_db)  # gap_id -> [pr_number, ...]
    merged = recent_merged_prs(repo, limit)
    if not merged:
        print("unlinked-merged: no recently merged PRs resolvable — nothing to report")
        return 0

    reported = 0
    for pr_num, title in merged:
        for gid in set(_GAP_ID_RE.findall(title)):
            if gid not in open_ids:
                continue  # PR names a gap that isn't open — not our concern
            if pr_num in links.get(gid, []):
                continue  # already FK-linked — the closer handles it
            reported += 1
            print(f"  UNLINKED {gid} PR #{pr_num}, not closing")
            if not dry_run:
                ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
                _emit(ambient_path, {
                    "ts": ts, "kind": "pr_without_gap_link",
                    "gap_id": gid, "pr_number": int(pr_num),
                    "source": "gap-doctor-reconcile",
                })
    if reported == 0:
        print(f"unlinked-merged: scanned {len(merged)} merged PR(s) — "
              f"every title-named open gap is FK-linked, clean")
    else:
        print(f"unlinked-merged: reported {reported} merged PR(s) that name an "
              f"open gap with no gap_prs row (report-only, closed nothing)")
    return reported


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="report without writing")
    ap.add_argument(
        "--limit", type=int, default=0, help="cap to first N gaps (debugging)"
    )
    ap.add_argument(
        "--check-closure-drift", action="store_true",
        help="META-059: scan open gaps with closed_pr set and emit "
             "kind=gap_closure_drift when the PR is merged",
    )
    ap.add_argument(
        "--check-already-satisfied", action="store_true",
        help="INFRA-3826: scan open gaps with NO closed_pr; close "
             "already_satisfied when a worker cycle log shows the work already "
             "shipped in a merged PR, else FLAG low-confidence matches",
    )
    ap.add_argument(
        "--check-merged-pr-links", "--check-merged-pr-titles",
        dest="check_merged_pr_links", action="store_true",
        help="CREDIBLE-1550: close open gaps that a typed gap_prs row links to a "
             "MERGED PR (the async-merge ghost class closed_pr-drift "
             "+ already-satisfied both miss). The gap_prs FK is the ONLY proof — "
             "a PR title is never used. (--check-merged-pr-titles is a deprecated "
             "alias kept so the gap-closure-reconcile service keeps working.)",
    )
    ap.add_argument(
        "--merged-pr-limit", type=int, default=0,
        help="DEPRECATED/ignored (CREDIBLE-1550): the link-based closer reads the "
             "gap_prs FK, not a merged-PR-list scan, so there is no limit to tune. "
             "Accepted for backward compatibility with stale callers.",
    )
    args = ap.parse_args()

    # INFRA-3826: the already-satisfied backstop reads the canonical state.db
    # DIRECTLY (resolve_state_db) and does not need — and must not depend on —
    # the possibly-lying `chump gap list` load_db(). Handle it before that call.
    if args.check_merged_pr_links:
        state_db = resolve_state_db()
        ambient = REPO_ROOT / ".chump-locks" / "ambient.jsonl"
        print(f"Reading gap store directly: {state_db}")
        check_merged_pr_links(state_db, ambient, args.dry_run)
        # CREDIBLE-1598: head-branch backstop — close an open gap whose MERGED PR
        # is identified by its lane head branch even when NO gap_prs FK exists
        # (the organ-merge-without-link class the FK pass above can't see). Keyed
        # on the branch, never the title, so it ships+reports instead of
        # report-only. Runs AFTER the FK pass so FK-linked gaps are already done.
        check_merged_pr_head_branch(state_db, ambient, args.dry_run)
        # CREDIBLE-1552: report-only companion — surface merged PRs that name an
        # open gap but carry no gap_prs row (the closer never closes from a
        # title, so these would otherwise be silently invisible). Closes nothing.
        check_unlinked_merged_prs(state_db, ambient, args.dry_run)
        # Self-healing oneshot: a clean run (even one that closed gaps) is SUCCESS.
        sys.exit(0)

    if args.check_already_satisfied:
        state_db = resolve_state_db()
        ambient = REPO_ROOT / ".chump-locks" / "ambient.jsonl"
        print(f"Reading gap store directly: {state_db}")
        check_already_satisfied(state_db, ambient, args.dry_run)
        # Self-healing mode: a clean run — even one that closed gaps — is SUCCESS
        # (exit 0) so the systemd oneshot stays green. Flags are informational,
        # not failures. Only an unhandled exception (crash) exits non-zero.
        sys.exit(0)

    if not GAPS_DIR.is_dir():
        print(f"ERROR: {GAPS_DIR} not a directory", file=sys.stderr)
        sys.exit(2)

    print(f"Loading state.db…")
    db = load_db()
    print(f"  {len(db)} rows")

    if args.check_closure_drift:
        ambient = REPO_ROOT / ".chump-locks" / "ambient.jsonl"
        n = check_closure_drift(db, ambient, args.dry_run)
        # Non-zero exit on drift so callers (cron, CI) can alert.
        sys.exit(0 if n == 0 else 3)

    yaml_files = sorted(GAPS_DIR.glob("*.yaml"))
    if args.limit:
        yaml_files = yaml_files[: args.limit]
    print(f"Scanning {len(yaml_files)} YAML files…")

    total_actions = 0
    gaps_touched = 0
    skipped_no_db = 0
    for path in yaml_files:
        gid = path.stem
        if gid not in db:
            skipped_no_db += 1
            continue
        yaml_data = parse_yaml_file(path)
        actions = reconcile_one(gid, yaml_data, db[gid], args.dry_run)
        if actions:
            gaps_touched += 1
            total_actions += len(actions)
            if args.dry_run:
                fields = ", ".join(a[0] for a in actions)
                print(f"  {gid}: would set {fields}")

    print()
    print(f"Summary:")
    print(f"  YAML files scanned   : {len(yaml_files)}")
    print(f"  Skipped (no DB row)  : {skipped_no_db}")
    print(f"  Gaps touched         : {gaps_touched}")
    print(f"  Total field updates  : {total_actions}")
    if args.dry_run:
        print(f"  (dry-run — no writes)")
    else:
        print(f"  (writes applied; verify via gap-doctor + chump gap dump --per-file)")


if __name__ == "__main__":
    main()
