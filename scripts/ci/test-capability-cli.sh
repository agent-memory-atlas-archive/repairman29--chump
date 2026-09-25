#!/usr/bin/env bash
# scripts/ci/test-capability-cli.sh — INFRA-5765
#
# Verifies scripts/coord/capability.sh register/query end-to-end:
#   1. register writes a manifest with role + skills
#   2. query --skill returns the matching session id
#   3. query --skill with no match exits 1
#   4. stale manifests are excluded from query results

set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CAP="$REPO_ROOT/scripts/coord/capability.sh"
[[ -x "$CAP" ]] || { echo "FAIL: $CAP not executable"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_LOCK_DIR="$TMP/.chump-locks"

failures=0
fail() { echo "FAIL: $1"; failures=$((failures+1)); }

# ── 1. register ─────────────────────────────────────────────────────────
CHUMP_SESSION_ID="cli-test-1" "$CAP" register --role curator-cli-test --skills rust,docs,sql
manifest="$CHUMP_LOCK_DIR/capabilities/cli-test-1.json"
[[ -f "$manifest" ]] || fail "register: did not create $manifest"
grep -q '"role": "curator-cli-test"' "$manifest" || fail "register: missing role"
grep -q '"sql"' "$manifest" || fail "register: missing skill sql"

# ── 2. query matches ────────────────────────────────────────────────────
out="$("$CAP" query --skill sql)"
echo "$out" | grep -q "cli-test-1" || fail "query: expected cli-test-1 to match skill=sql"

# ── 3. query no-match exits 1 ───────────────────────────────────────────
if "$CAP" query --skill nonexistent-skill >/dev/null 2>&1; then
    fail "query: expected non-zero exit for no-match skill"
fi

# ── 4. stale manifests excluded ─────────────────────────────────────────
python3 - "$manifest" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    doc = json.load(f)
doc["updated_at"] = "2000-01-01T00:00:00Z"
with open(path, "w") as f:
    json.dump(doc, f)
PYEOF
if "$CAP" query --skill sql >/dev/null 2>&1; then
    fail "query: stale manifest (year 2000) should have been filtered out"
fi

[[ $failures -gt 0 ]] && { echo "FAIL INFRA-5765: $failures"; exit 1; }
echo "OK INFRA-5765: capability.sh register + query work end-to-end"
