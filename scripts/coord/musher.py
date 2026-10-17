#!/usr/bin/env python3.12
"""
musher.py — Chump multi-agent dispatcher (python3 port, replaces bash musher.sh)

Usage:
  python3.12 scripts/coord/musher.py --pick
  python3.12 scripts/coord/musher.py --check <GAP-ID>
  python3.12 scripts/coord/musher.py --assign <N>
  python3.12 scripts/coord/musher.py --status
  python3.12 scripts/coord/musher.py --why <GAP-ID>

INFRA-8224 (one-picker consolidation): the `--pick` arm here is a priority-only
dispatcher view over docs/gaps.yaml and is NOT the fleet's ranking picker. The
single canonical picker is scripts/dispatch/_pick_and_claim_gap.py (use
`--dry-run` for a no-claim preview). `--pick` is DEPRECATED for ranking; it is
kept only because musher's other arms (--check/--assign/--status/--why) and its
callers (the MCP coord server `musher_pick`, war-room, fleet-unstick) still rely
on musher's text surface + docs/gaps.yaml data source. Do not add ranking
heuristics here — change the canonical picker instead.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# ── Repo root / paths ─────────────────────────────────────────────────────────
REPO_ROOT = Path(
    subprocess.check_output(["git", "rev-parse", "--show-toplevel"],
                            stderr=subprocess.DEVNULL).decode().strip()
)
LOCK_DIR = Path(
    os.environ.get("CHUMP_LOCK_DIR", str(REPO_ROOT / ".chump-locks"))
)
GAPS_YAML = REPO_ROOT / "docs" / "gaps.yaml"
NOW       = int(time.time())

def _parse_ts(v) -> int | None:
    """Best-effort epoch-seconds parse. Accepts int, numeric string, or ISO-8601Z."""
    if v is None or v == "":
        return None
    if isinstance(v, (int, float)):
        return int(v)
    s = str(v).strip()
    if s.isdigit():
        return int(s)
    from datetime import datetime, timezone
    try:
        dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return int(dt.timestamp())
    except Exception:
        return None

# ── Session ID ────────────────────────────────────────────────────────────────
SESSION_ID = (
    os.environ.get("CHUMP_SESSION_ID")
    or os.environ.get("CLAUDE_SESSION_ID")
    or (LOCK_DIR / ".wt-session-id").read_text().strip()
       if (LOCK_DIR / ".wt-session-id").exists() else None
    or (Path.home() / ".chump" / "session_id").read_text().strip()
       if (Path.home() / ".chump" / "session_id").exists() else None
    or f"unknown-{os.getpid()}"
)

# ── ANSI helpers ──────────────────────────────────────────────────────────────
def _c(code, s): return f"\033[{code}m{s}\033[0m"
def bold(s):   return _c("1", s)
def cyan(s):   return _c("0;36", s)
def yellow(s): return _c("0;33", s)
def red(s):    return _c("0;31", s)
def green(s):  return _c("0;32", s)
def dim(s):    return _c("2", s)

# ── Domain → file-scope heuristic ────────────────────────────────────────────
DOMAIN_FILES = {
    "COG":     "src/reflection.rs,src/reflection_db.rs,src/consciousness_tests.rs,src/neuromod",
    "EVAL":    "scripts/ab-harness/,tests/fixtures/,docs/CONSCIOUSNESS_AB_RESULTS.md",
    "COMP":    "src/browser_tool.rs,src/acp_server.rs,src/acp.rs,desktop/",
    "INFRA":   ".github/workflows/,scripts/",
    "AGT":     "src/agent_loop/,src/autonomy_loop.rs,src/orchestrator",
    "MEM":     "crates/chump-memory-db/src/memory_db.rs,src/memory_tool.rs,src/memory_graph.rs",
    "AUTO":    "src/tool_middleware.rs,scripts/",
    "DOC":     "docs/,CLAUDE.md,AGENTS.md",
    "QUALITY": "src/,Cargo.toml",
    "PRODUCT": "docs/,src/",
    "FLEET":   "src/,scripts/",
}

def gap_files(gid: str, gap: dict | None = None) -> list[str]:
    """File-scope prefixes for conflict detection.

    If the gap YAML declares an inline ``file_scope: "path/,other/"`` field,
    that override wins — use it to narrow (e.g. analysis-only gaps that touch
    only ``docs/eval/``) or to widen the default domain prefix. Fall back to
    the coarse ``DOMAIN_FILES`` table otherwise.
    """
    if gap and gap.get("file_scope"):
        raw = gap["file_scope"]
    else:
        prefix = gid.split("-")[0]
        raw = DOMAIN_FILES.get(prefix, "")
    return [f for f in raw.split(",") if f]

# ── 1. Load open gaps ─────────────────────────────────────────────────────────
def load_gaps() -> list[dict]:
    if not GAPS_YAML.exists():
        return []
    content = GAPS_YAML.read_text()
    gaps = []
    for block in re.split(r'\n- id: ', content):
        if "status: open" not in block:
            continue
        gid = block.split("\n")[0].strip()
        if not gid or not re.match(r'^[A-Z][A-Z0-9]+-\d+$', gid):
            continue

        def extract(pattern, default="?"):
            m = re.search(pattern, block)
            return m.group(1).strip() if m else default

        # depends_on: may be multi-line list or inline
        deps = []
        dep_block = re.search(r'depends_on:\s*\[([^\]]*)\]', block)
        if dep_block:
            deps = [d.strip() for d in dep_block.group(1).split(",") if d.strip()]
        else:
            for m in re.finditer(r'depends_on:.*\n((?:\s+-\s+\S+\n?)+)', block):
                deps = re.findall(r'-\s+(\S+)', m.group(1))

        file_scope_m = re.search(r'file_scope:\s*["\']?([^"\'\n]+)["\']?', block)
        file_scope = file_scope_m.group(1).strip() if file_scope_m else ""
        gaps.append({
            "id":     gid,
            "title":  extract(r'title:\s*["\']?([^"\'\\n]+)'),
            "prio":   extract(r'priority:\s*(\S+)'),
            "effort": extract(r'effort:\s*(\S+)'),
            "domain": extract(r'domain:\s*(\S+)'),
            "deps":   deps,
            "file_scope": file_scope,
        })
    return gaps

PRIO_RANK = {"critical": 0, "p0": 0, "high": 1, "p1": 1,
             "medium": 2, "p2": 2, "m": 2, "low": 3, "p3": 3, "s": 3}

def sorted_gaps(gaps: list[dict]) -> list[dict]:
    return sorted(gaps, key=lambda g: PRIO_RANK.get(g["prio"].lower(), 9))

# ── 2. Load active leases ─────────────────────────────────────────────────────
def load_leases() -> list[dict]:
    leases = []
    for f in LOCK_DIR.glob("*.json"):
        try:
            d = json.loads(f.read_text())
        except Exception:
            continue
        hb_raw = d.get("heartbeat", d.get("heartbeat_at", d.get("created_at", 0)))
        hb = _parse_ts(hb_raw)
        if hb is None:
            continue
        if (NOW - hb) > 900:
            continue
        sess = d.get("session_id", "")
        gap  = d.get("gap_id", "")
        if not sess:
            continue
        leases.append({"session": sess, "gap": gap,
                       "files": d.get("files", []), "age": NOW - hb})
    return leases

# ── 3. Load recent INTENTs ────────────────────────────────────────────────────
def load_intents() -> list[dict]:
    ambient = LOCK_DIR / "ambient.jsonl"
    if not ambient.exists():
        return []
    cutoff = NOW - 120
    intents = []
    lines = ambient.read_text().splitlines()[-300:]
    for line in lines:
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("event") != "INTENT":
            continue
        ts_str = d.get("ts", "")
        try:
            from datetime import datetime, timezone
            ts = int(datetime.fromisoformat(ts_str.replace("Z", "+00:00")).timestamp())
        except Exception:
            continue
        if ts < cutoff:
            continue
        intents.append({"session": d.get("session", ""), "gap": d.get("gap", ""),
                        "files": d.get("files", ""), "age": NOW - ts})
    return intents

# ── 4. Load open PRs ──────────────────────────────────────────────────────────
def load_prs() -> list[dict]:
    try:
        out = subprocess.check_output(
            ["gh", "pr", "list", "--state", "open", "--json",
             "number,title,headRefName,files",
             "--jq", r'.[] | "\(.number)|\(.title[:45])|\(.headRefName)|" + ([.files[].path] | join(","))'],
            stderr=subprocess.DEVNULL, cwd=str(REPO_ROOT)
        ).decode().strip()
    except Exception:
        return []
    prs = []
    for line in out.splitlines()[:30]:
        parts = line.split("|", 3)
        if len(parts) < 4:
            continue
        prs.append({"num": parts[0], "title": parts[1],
                    "branch": parts[2], "files": parts[3]})
    return prs

# ── Conflict detection ────────────────────────────────────────────────────────
# Set by --ignore-file-conflicts. Self-heal escape hatch: the merge queue
# rebases + re-runs CI, so prefix-level false positives (e.g. an EVAL docs-only
# gap blocked by an EVAL harness PR that only conflicts on the `scripts/ab-
# harness/` prefix) rarely materialise as real merge conflicts.
IGNORE_FILE_CONFLICTS = False

# Files where prefix collisions almost always resolve as disjoint line-level
# edits the merge queue handles without human intervention. Excluded from
# file-scope conflict detection by default.
LOW_CONFLICT_FILES = {"docs/gaps.yaml"}

def first_conflict(gid: str, leases, intents, prs, gap: dict | None = None) -> str:
    if IGNORE_FILE_CONFLICTS:
        return ""
    likely = gap_files(gid, gap)
    if not likely:
        return ""
    prefixes = [f.rstrip("*") for f in likely if f not in LOW_CONFLICT_FILES]

    for pr in prs:
        pr_files = pr["files"]
        for pfx in prefixes:
            if pfx and pfx in pr_files:
                return f"pr:{pr['num']}"

    for lease in leases:
        if lease["session"] == SESSION_ID:
            continue
        if lease["gap"] == gid:
            continue
        lease_files = gap_files(lease["gap"])
        for gp in prefixes:
            for lp in [lf.rstrip("*") for lf in lease_files]:
                if gp and lp and (gp.startswith(lp) or lp.startswith(gp)):
                    return f"lease:{lease['session']}"

    return ""

def has_unmet_deps(gap: dict, open_ids: set) -> list[str]:
    return [d for d in gap["deps"] if d in open_ids]

# ── Classify ──────────────────────────────────────────────────────────────────
def classify(gap: dict, leases, intents, prs, open_ids: set) -> tuple[str, str]:
    gid = gap["id"]

    if gap["effort"].upper() == "XL":
        return "effort-xl", ""

    unmet = has_unmet_deps(gap, open_ids)
    if unmet:
        return "deps", ",".join(unmet)

    for lease in leases:
        if lease["gap"] == gid:
            if lease["session"] == SESSION_ID:
                return "available", ""
            return "claimed", lease["session"]

    for intent in intents:
        if intent["gap"] == gid and intent["session"] != SESSION_ID:
            return "intended", intent["session"]

    conflict = first_conflict(gid, leases, intents, prs, gap)
    if conflict:
        return "conflict", conflict

    return "available", ""

# ── Modes ─────────────────────────────────────────────────────────────────────
def cmd_pick(gaps, leases, intents, prs, open_ids):
    for gap in sorted_gaps(gaps):
        status, detail = classify(gap, leases, intents, prs, open_ids)
        if status == "available":
            print(f"  {green('→ PICK')}  {bold(gap['id'])}  "
                  f"({gap['prio']} priority, {gap['effort']} effort)  "
                  f"{dim(gap['title'])}")
            print(f"  {dim('Run: scripts/coord/gap-preflight.sh ' + gap['id'])}")
            return 0
    print(f"  {red('No available gaps — everything claimed, conflicted, or done.')}")
    return 1


def cmd_check(target, gaps, leases, intents, prs, open_ids):
    gap = next((g for g in gaps if g["id"] == target), None)
    if not gap:
        print(f"  {red(f'Gap {target} not found in open gaps.')}")
        return 1
    print()
    print(bold(f"MUSHER CHECK: {target}"))
    print()
    status, detail = classify(gap, leases, intents, prs, open_ids)
    if status == "available":
        print(f"  {green('✓ Available — no conflicts detected.')}")
    elif status == "claimed":
        print(f"  {red('✗ BLOCKED')}  claimed by session: {yellow(detail)}")
    elif status == "intended":
        print(f"  {yellow('⚠ INTENT')}  session {cyan(detail)} announced INTENT in last 120s")
        print(f"  {dim('Wait 30s and re-check, or coordinate with that session.')}")
    elif status == "conflict":
        kind, ref = detail.split(":", 1) if ":" in detail else (detail, "")
        if kind == "pr":
            print(f"  {yellow('⚠ CONFLICT')}  PR #{ref} touches the same file domains")
        else:
            print(f"  {yellow('⚠ CONFLICT')}  session {ref} holds a lease on overlapping files")
    elif status == "deps":
        print(f"  {yellow('⚠ BLOCKED')}  unmet dependencies: {detail}")
        print(f"  {dim('Ship the dependency gaps first.')}")
    elif status == "effort-xl":
        print(f"  {yellow('⚠ XL')}  XL effort — do not auto-assign (manual decision required)")

    likely = gap_files(target)
    if likely:
        print()
        print(f"  {dim('File domains:')} {dim(', '.join(likely))}")
        for pr in prs:
            for pfx in [f.rstrip("*") for f in likely]:
                if pfx and pfx in pr["files"]:
                    print(f"  {yellow('  ↳')} PR #{pr['num']} ({pr['branch']}) touches {pfx}")
    return 0


def cmd_assign(n, gaps, leases, intents, prs, open_ids):
    print()
    print(bold(f"MUSHER ASSIGN: {n} slot(s)"))
    print()
    assigned = 0
    used_domains: set[str] = set()
    for gap in sorted_gaps(gaps):
        if assigned >= n:
            break
        status, _ = classify(gap, leases, intents, prs, open_ids)
        if status != "available":
            continue
        domain = gap["domain"]
        if domain in used_domains:
            continue
        used_domains.add(domain)
        print(f"  {green('→')}  [slot {assigned + 1}] {bold(gap['id'])}  "
              f"({gap['prio']} / {gap['effort']})  {dim(gap['title'])}")
        assigned += 1
    if assigned == 0:
        print(f"  {red('No available gaps to assign.')}")
        return 1
    return 0


def cmd_status(gaps, leases, intents, prs, open_ids):
    print()
    print(bold("MUSHER STATUS TABLE"))
    print(f"  {'GAP':<12} {'PRIO':<8} {'EFFORT':<6} {'STATUS':<12} DETAIL")
    print(f"  {dim('─' * 61)}")
    for gap in sorted_gaps(gaps):
        gid    = gap["id"]
        prio   = gap["prio"]
        effort = gap["effort"]
        status, detail = classify(gap, leases, intents, prs, open_ids)
        if status == "available":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {green('available')}")
        elif status == "claimed":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {yellow('claimed')}     {dim(detail)}")
        elif status == "intended":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {yellow('intent')}      {dim(detail)}")
        elif status == "conflict":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {yellow('conflict')}    {dim(detail)}")
        elif status == "deps":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {dim('blocked')}     {dim('deps:' + detail)}")
        elif status == "effort-xl":
            print(f"  {gid:<12} {prio:<8} {effort:<6} {dim('XL-skip')}")
    print()
    return 0


def cmd_why(target, gaps, leases, intents, prs, open_ids):
    gap = next((g for g in gaps if g["id"] == target), None)
    if not gap:
        print(f"  {red(f'Gap {target} not found in open gaps.')}")
        return 1
    status, detail = classify(gap, leases, intents, prs, open_ids)
    print()
    print(bold(f"{target} — {gap['title']}"))
    print(f"  priority={gap['prio']}  effort={gap['effort']}  deps={gap['deps'] or 'none'}")
    print(f"  classification: {bold(status + (':' + detail if detail else ''))}")
    print()
    if status == "available":
        print(f"  {green('✓ Open, unclaimed, no file-scope conflicts.')}")
    elif status == "claimed":
        print(f"  Lease for session '{detail}' lists gap_id='{target}'.")
        print(f"  Check: ls .chump-locks/*.json | xargs grep -l '{target}'")
    elif status == "intended":
        print(f"  Session '{detail}' posted INTENT for '{target}' in the last 120s.")
        print("  Check: tail -50 .chump-locks/ambient.jsonl | grep INTENT")
    elif status == "conflict":
        kind, ref = detail.split(":", 1) if ":" in detail else (detail, "")
        if kind == "pr":
            print(f"  PR #{ref} is open and touches the same file domain as {target}.")
        else:
            print(f"  Session '{ref}' holds a lease on overlapping file domains.")
        print(f"  Domain files: {gap_files(target)}")
    elif status == "deps":
        print(f"  Unmet dependency gaps still open: {detail}")
        print("  Ship those first, then re-run --check.")
    elif status == "effort-xl":
        print("  XL effort — musher never auto-assigns XL gaps.")
        print("  Pick it manually when you have the bandwidth.")
    return 0


# ── Main ──────────────────────────────────────────────────────────────────────
def main():
    global IGNORE_FILE_CONFLICTS
    args = sys.argv[1:]
    if "--ignore-file-conflicts" in args:
        IGNORE_FILE_CONFLICTS = True
        args = [a for a in args if a != "--ignore-file-conflicts"]
    mode = args[0] if args else "--pick"

    gaps    = load_gaps()
    leases  = load_leases()
    intents = load_intents()
    prs     = load_prs()
    open_ids = {g["id"] for g in gaps}

    if mode == "--pick":
        sys.exit(cmd_pick(gaps, leases, intents, prs, open_ids))

    elif mode == "--check":
        target = args[1] if len(args) > 1 else ""
        if not target:
            print("Usage: musher.py --check <GAP-ID>", file=sys.stderr)
            sys.exit(1)
        sys.exit(cmd_check(target, gaps, leases, intents, prs, open_ids))

    elif mode == "--assign":
        n = int(args[1]) if len(args) > 1 else 1
        sys.exit(cmd_assign(n, gaps, leases, intents, prs, open_ids))

    elif mode == "--status":
        sys.exit(cmd_status(gaps, leases, intents, prs, open_ids))

    elif mode == "--why":
        target = args[1] if len(args) > 1 else ""
        if not target:
            print("Usage: musher.py --why <GAP-ID>", file=sys.stderr)
            sys.exit(1)
        sys.exit(cmd_why(target, gaps, leases, intents, prs, open_ids))

    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
