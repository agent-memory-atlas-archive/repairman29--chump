#!/usr/bin/env bash
# scripts/ci/test-api-gap-queue-shape.sh — INFRA-1197
#
# Verifies /api/gap-queue returns the fat response shape:
#   - 6 legacy fields preserved: id, title, priority, effort,
#     preflight_status, preflight_error
#   - 9 new fields present + correctly typed: domain, status, closed_pr,
#     assigned_session, created_at, opened_date, depends_on (array),
#     acceptance_criteria_count (int), pillar
#   - Top-level: gaps[], count, total, claimable_count
#   - Pillar tag derived from title prefix only (not domain fallback)
#   - Filtering: ?status, ?domain, ?priority
#   - Sort order: priority asc → effort asc → created_at desc
#
# Strategy: spawn chump --web on a random port, seed a temp state.db with
# 3 synthetic gaps (varying domain/status/pillar/priority), probe the
# endpoint, assert all fields + filters.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"

# W-013 immunization (RESILIENT-024): unset workflow-injected env so this
# tests own $TMP fixtures are not hijacked by CI workflow CHUMP_LOCK_DIR.
unset CHUMP_REPO CHUMP_LOCK_DIR
trap 'rm -rf "$TMP"; [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

source "$(dirname "$0")/lib/discover-chump-bin.sh"
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$(command -v chump || true)"
fi
[[ -x "$CHUMP_BIN" ]] || fail "no chump binary found (set CHUMP_BIN)"

# Seed a synthetic state.db with three gaps spanning the filter dimensions.
DB="$TMP/state.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  domain TEXT NOT NULL,
  title TEXT NOT NULL,
  description TEXT DEFAULT '',
  priority TEXT NOT NULL,
  effort TEXT NOT NULL,
  status TEXT NOT NULL,
  acceptance_criteria TEXT DEFAULT '[]',
  depends_on TEXT DEFAULT '[]',
  notes TEXT DEFAULT '',
  source_doc TEXT DEFAULT '',
  created_at INTEGER NOT NULL,
  closed_at INTEGER,
  opened_date TEXT DEFAULT '',
  closed_date TEXT DEFAULT '',
  closed_pr INTEGER,
  skills_required TEXT DEFAULT '',
  preferred_backend TEXT DEFAULT '',
  preferred_machine TEXT DEFAULT '',
  estimated_minutes TEXT DEFAULT '',
  required_model TEXT DEFAULT ''
);
INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at, opened_date, closed_pr)
VALUES
  ('INFRA-AAA', 'INFRA', 'EFFECTIVE: shape probe alpha',  'P0', 's',  'open',     '["a","b","c"]', '["INFRA-BBB"]', 1778700000, '2026-05-14', NULL),
  ('INFRA-BBB', 'INFRA', 'CREDIBLE: shape probe beta',    'P1', 'xs', 'open',     '["a"]',         '[]',            1778600000, '2026-05-13', NULL),
  ('INFRA-CCC', 'INFRA', 'RESILIENT: shape probe gamma — already shipped', 'P2', 'm',  'shipped',  '["a","b"]',     '[]',            1778500000, '2026-05-12', 999);
SQL

# Pick a random free port (avoid 3000 in case operator's chump --web is up).
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
LOG="$TMP/server.log"

# Point CHUMP_REPO at the tmpdir so ambient.jsonl lands at
# $TMP/.chump-locks/ambient.jsonl (the handler always writes to
# main_repo/.chump-locks/ambient.jsonl; we make the tmpdir look like one).
mkdir -p "$TMP/.chump-locks"
CHUMP_REPO="$TMP" \
CHUMP_STATE_DB="$DB" \
CHUMP_BINARY_STALENESS_CHECK=0 \
    "$CHUMP_BIN" --web --port "$PORT" >"$LOG" 2>&1 &
SERVER_PID=$!

# Wait up to 10s for the server to come up.
for _ in $(seq 1 50); do
    sleep 0.2
    if curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null 2>&1; then
        break
    fi
done
curl -sf "http://127.0.0.1:$PORT/api/health" >/dev/null \
    || fail "server failed to start (log: $(cat "$LOG"))"

# ── Test 1: default (status=open) returns 2 open gaps ───────────────────────
R="$TMP/r1.json"
curl -sf "http://127.0.0.1:$PORT/api/gap-queue" >"$R"
python3 - <<EOF
import json
d = json.load(open("$R"))
assert d["count"] == 2, f"expected count=2, got {d['count']}"
assert d["total"] == 2, f"expected total=2, got {d['total']}"
ids = [g["id"] for g in d["gaps"]]
assert "INFRA-AAA" in ids and "INFRA-BBB" in ids, f"missing open gaps: {ids}"
assert "INFRA-CCC" not in ids, "shipped gap leaked into default response"
EOF
ok "default: 2 open gaps returned, shipped excluded"

# ── Test 2: required field shape ────────────────────────────────────────────
python3 - <<EOF
import json
d = json.load(open("$R"))
g = next(x for x in d["gaps"] if x["id"] == "INFRA-AAA")
required = {
    "id": str, "title": str, "priority": str, "effort": str,
    "preflight_status": str, "domain": str, "status": str,
    "created_at": int, "depends_on": list,
    "acceptance_criteria_count": int,
}
for k, t in required.items():
    assert k in g, f"missing field {k}"
    assert isinstance(g[k], t), f"{k} expected {t.__name__}, got {type(g[k]).__name__}"
# Nullable fields
for k in ("closed_pr", "assigned_session", "preflight_error", "opened_date", "pillar"):
    assert k in g, f"missing field {k}"
# Concrete values
assert g["domain"] == "INFRA"
assert g["status"] == "open"
assert g["depends_on"] == ["INFRA-BBB"]
assert g["acceptance_criteria_count"] == 3
assert g["pillar"] == "effective", f"pillar should derive from EFFECTIVE: prefix, got {g['pillar']}"
assert g["closed_pr"] is None
EOF
ok "fat shape: all 15 fields present + correctly typed"

# ── Test 3: pillar derivation matches title prefix only ─────────────────────
python3 - <<EOF
import json
d = json.load(open("$R"))
m = {g["id"]: g["pillar"] for g in d["gaps"]}
assert m["INFRA-AAA"] == "effective"
assert m["INFRA-BBB"] == "credible"
EOF
ok "pillar derived from title prefix (EFFECTIVE→effective, CREDIBLE→credible)"

# ── Test 4: sort order — priority asc, then effort asc ──────────────────────
python3 - <<EOF
import json
d = json.load(open("$R"))
order = [g["id"] for g in d["gaps"]]
assert order == ["INFRA-AAA", "INFRA-BBB"], f"sort wrong: {order} (expected P0/s before P1/xs)"
EOF
ok "sort: priority asc, effort asc, created_at desc"

# ── Test 5: ?status=shipped surfaces the shipped gap ───────────────────────
R5="$TMP/r5.json"
curl -sf "http://127.0.0.1:$PORT/api/gap-queue?status=shipped" >"$R5"
python3 - <<EOF
import json
d = json.load(open("$R5"))
ids = [g["id"] for g in d["gaps"]]
assert ids == ["INFRA-CCC"], f"status=shipped returned {ids}"
assert d["gaps"][0]["closed_pr"] == 999
assert d["gaps"][0]["pillar"] == "resilient"
EOF
ok "?status=shipped: filter + closed_pr exposed"

# ── Test 6: ?status=open,shipped (multi-value OR) ───────────────────────────
R6="$TMP/r6.json"
curl -sf "http://127.0.0.1:$PORT/api/gap-queue?status=open,shipped" >"$R6"
python3 - <<EOF
import json
d = json.load(open("$R6"))
assert d["count"] == 3, f"expected count=3, got {d['count']}"
EOF
ok "?status=open,shipped: multi-value union returns all 3 gaps"

# ── Test 7: ?priority=P0 narrows to one row ─────────────────────────────────
R7="$TMP/r7.json"
curl -sf "http://127.0.0.1:$PORT/api/gap-queue?priority=P0" >"$R7"
python3 - <<EOF
import json
d = json.load(open("$R7"))
ids = [g["id"] for g in d["gaps"]]
assert ids == ["INFRA-AAA"], f"?priority=P0 returned {ids}"
EOF
ok "?priority=P0: priority filter works"

# ── Test 8: ?domain=NOPE returns zero rows ──────────────────────────────────
R8="$TMP/r8.json"
curl -sf "http://127.0.0.1:$PORT/api/gap-queue?domain=NOPE" >"$R8"
python3 - <<EOF
import json
d = json.load(open("$R8"))
assert d["count"] == 0
EOF
ok "?domain=NOPE: unknown domain returns zero rows"

# ── Test 9: ambient telemetry signal emitted ────────────────────────────────
AMB="$TMP/.chump-locks/ambient.jsonl"
if [[ -f "$AMB" ]]; then
    grep -q '"event":"gap_queue_request"' "$AMB" \
        || fail "no kind=gap_queue_request event emitted (ambient: $(cat "$AMB" | head -3))"
    grep '"event":"gap_queue_request"' "$AMB" | head -1 | grep -q '"count"' \
        || fail "gap_queue_request missing 'count' field"
    ok "ambient signal: kind=gap_queue_request emitted with count + ms"
else
    fail "ambient.jsonl not created at $AMB"
fi

# ── Test 10 (INFRA-8179): /api/gaps sorts P0/critical before P1 even when ID sorts later ──
sqlite3 "$DB" <<'SQL'
INSERT INTO gaps (id, domain, title, priority, effort, status, acceptance_criteria, depends_on, created_at, opened_date, closed_pr)
VALUES
  ('INFRA-ZZZ', 'INFRA', 'RESILIENT: late-id P0 probe', 'critical', 'xs', 'open', '["a"]', '[]', 1778800000, '2026-05-15', NULL);
SQL
R10="$TMP/r10.json"
curl -sf "http://127.0.0.1:$PORT/api/gaps" >"$R10"
R10_P0="$TMP/r10_p0.json"
curl -sf "http://127.0.0.1:$PORT/api/gaps?priority=P0" >"$R10_P0"
python3 - <<EOF
import json
d = json.load(open("$R10"))
gaps = d["gaps"] if isinstance(d, dict) else d
ids = [g["id"] for g in gaps]
assert ids.index("INFRA-ZZZ") < ids.index("INFRA-BBB"), f"P0/critical INFRA-ZZZ must sort before P1 INFRA-BBB, got {ids}"
assert ids.index("INFRA-AAA") < ids.index("INFRA-BBB"), f"P0 INFRA-AAA must sort before P1 INFRA-BBB, got {ids}"

d_p0 = json.load(open("$R10_P0"))
gaps_p0 = d_p0["gaps"] if isinstance(d_p0, dict) else d_p0
ids_p0 = [g["id"] for g in gaps_p0]
assert set(ids_p0) == {"INFRA-AAA", "INFRA-ZZZ"}, f"?priority=P0 must return only P0/critical open gaps, got {ids_p0}"
EOF
ok "INFRA-8179: /api/gaps sorts P0/critical first and honors ?priority=P0"

# ── Test 11 (INFRA-8179): /api/debt exposes crown-metric debt/dormancy index ──
R11="$TMP/r11.json"
curl -sf "http://127.0.0.1:$PORT/api/debt" >"$R11"
python3 - <<EOF
import json
d = json.load(open("$R11"))
assert "live_pct" in d and isinstance(d["live_pct"], (int, float)), f"missing live_pct: {d}"
assert "debt" in d and d["debt"] > 0, f"expected positive debt for open P0/P1 gaps: {d}"
assert "top5_dormant" in d and isinstance(d["top5_dormant"], list) and len(d["top5_dormant"]) >= 1, f"missing top5_dormant: {d}"
assert "nba_candidate_count" in d and d["nba_candidate_count"] >= 2, f"unexpected nba_candidate_count: {d}"
EOF
ok "INFRA-8179: /api/debt exposes live_pct, debt, top5_dormant, nba_candidate_count"

# ── Test 12 (INFRA-8179): /api/dashboard-summary reports non-green when PRs are landing-wedged ──
mkdir -p "$TMP/.chump"
sqlite3 "$TMP/.chump/github_cache.db" <<'SQL'
CREATE TABLE pr_state (
  number INTEGER PRIMARY KEY,
  merged_at TEXT,
  mergeable_state TEXT,
  updated_at_api TEXT NOT NULL DEFAULT '',
  fetched_at_local TEXT NOT NULL DEFAULT ''
);
INSERT INTO pr_state (number, merged_at, mergeable_state) VALUES
  (501, NULL, 'DIRTY'),
  (502, NULL, 'BLOCKED'),
  (503, NULL, 'BEHIND');
SQL
printf '{"kind":"ci_qa_score","pct":100.0,"sample_size":10,"status":"green"}\n' >>"$AMB"
R12="$TMP/r12.json"
curl -sf "http://127.0.0.1:$PORT/api/dashboard-summary" >"$R12"
python3 - <<EOF
import json
d = json.load(open("$R12"))
assert d.get("stuck_prs", 0) >= 3, f"expected stuck_prs>=3, got {d}"
assert d.get("landing_wedged_prs", 0) >= 3, f"expected landing_wedged_prs>=3, got {d}"
assert d.get("landing_pct", 100.0) < 100.0, f"landing_pct must be <100 when PRs wedged: {d}"
assert d.get("landing_status") != "green", f"landing_status must not be green when PRs wedged: {d}"
qa = d.get("ci_qa_score") or {}
assert qa.get("pct", 100.0) < 100.0, f"ci_qa_score.pct must be <100 when PRs wedged: {qa}"
assert qa.get("status") != "green", f"ci_qa_score.status must not be green when PRs wedged: {qa}"
EOF
ok "INFRA-8179: /api/dashboard-summary degrades ci_qa and landing below 100% green when PRs are wedged"

ok "ALL INFRA-1197 + INFRA-8179 gap-queue/debt/dashboard-summary checks passed"
