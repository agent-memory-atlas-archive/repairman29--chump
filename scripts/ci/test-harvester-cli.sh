#!/usr/bin/env bash
# test-harvester-cli.sh — INFRA-1823 AC8
#
# Smoke-tests `chump harvest <scan|check|brief|deep-scan>` against a
# synthetic fixture repo (CHUMP_REPO override) so it never touches the real
# `docs/arsenal/` catalog or hits the live GitHub API. `scan`'s happy path
# is exercised via a fake `gh` shim on PATH that returns canned JSON.
#
# Each subcommand: exit 0 on synthetic happy path, exit 2 on bad input
# (missing required argument / unknown subcommand).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS=0
FAIL=0
ok()  { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-1823: chump harvest CLI smoke test ==="

# Resolve the chump binary the same way other CI smoke tests do — prefer a
# pre-built debug/release binary, else `cargo run`.
BIN=""
for candidate in \
    "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" \
    "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/release/chump" \
    "$HOME/.cargo/chump-shared-target/debug/chump" \
    "$HOME/.cargo/chump-shared-target/release/chump"; do
    if [ -x "$candidate" ]; then
        BIN="$candidate"
        break
    fi
done
if [ -z "$BIN" ]; then
    echo "no pre-built chump binary found — building (this may take a minute)..." >&2
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --bin chump >/dev/null 2>&1 )
    BIN="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
fi
if [ ! -x "$BIN" ]; then
    echo "FATAL: could not locate or build the chump binary" >&2
    exit 1
fi
echo "using binary: $BIN"

# ── Fixture repo: isolated CHUMP_REPO so scan/check/brief/deep-scan never
#    touch the real docs/arsenal/ catalog. ──────────────────────────────────
FIXTURE="$(mktemp -d)"
# The harvester keeps the operator's full catalog OUTSIDE the repo (default ~/.chump/arsenal).
# Point it at the fixture, or this test would read, and `scan` would overwrite, a developer's real
# private catalog. Same for the exclude list and the curation file.
export CHUMP_ARSENAL_DIR="$FIXTURE/.private-arsenal"
export CHUMP_ARSENAL_EXCLUDE_FILE="$FIXTURE/.no-exclude-list"
export CHUMP_ARSENAL_CURATION="$FIXTURE/.no-curation.json"
trap 'rm -rf "$FIXTURE"' EXIT

mkdir -p "$FIXTURE/docs/arsenal/raw" "$FIXTURE/docs/arsenal/cross-pollination" "$FIXTURE/scripts/arsenal" "$FIXTURE/.chump-locks"
cp "$REPO_ROOT/scripts/arsenal/harvest.sh" "$FIXTURE/scripts/arsenal/harvest.sh"
cp "$REPO_ROOT/scripts/arsenal/build.py" "$FIXTURE/scripts/arsenal/build.py"
chmod +x "$FIXTURE/scripts/arsenal/harvest.sh"

cat > "$FIXTURE/docs/arsenal/GLOBAL_ARSENAL.json" <<'JSON'
{
  "metadata": {"generated_at": "2026-01-01T00:00:00Z", "fleet_size_github": 2},
  "clusters": {
    "test-cluster": {"count": 1, "repos": ["fixture-repo"], "active_last_30d": 1}
  },
  "duplications": [],
  "alerts": [],
  "primitives_index": {"auth": ["fixture-repo"]},
  "repos_by_name": {
    "fixture-repo": {
      "name": "fixture-repo",
      "description": "synthetic fixture for INFRA-1823 smoke test",
      "language": "Rust",
      "pushed_at": "2026-01-01",
      "archived": false,
      "local_clone": null,
      "primitives": ["auth"],
      "extracted_primitives": ["fixture primitive for testing"]
    }
  },
  "unmatched_local_roots": []
}
JSON

echo
echo "--- check ---"
if CHUMP_REPO="$FIXTURE" "$BIN" harvest check auth >/dev/null 2>&1; then
    ok "check <topic>: exit 0 on match"
else
    bad "check <topic>: expected exit 0 on match"
fi
if CHUMP_REPO="$FIXTURE" "$BIN" harvest check nonexistent-topic-xyz >/dev/null 2>&1; then
    bad "check <no-match-topic>: expected non-zero exit"
else
    ok "check <no-match-topic>: non-zero exit as expected"
fi
CHUMP_REPO="$FIXTURE" "$BIN" harvest check >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "check (missing topic): exit 2" || bad "check (missing topic): expected exit 2, got $rc"

echo
echo "--- brief ---"
if CHUMP_REPO="$FIXTURE" "$BIN" harvest brief fixture-repo new-target >/dev/null 2>&1; then
    ok "brief <src> <target>: exit 0"
else
    bad "brief <src> <target>: expected exit 0"
fi
CHUMP_REPO="$FIXTURE" "$BIN" harvest brief only-src >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "brief (missing target): exit 2" || bad "brief (missing target): expected exit 2, got $rc"

echo
echo "--- deep-scan ---"
if CHUMP_REPO="$FIXTURE" "$BIN" harvest deep-scan test-cluster >/dev/null 2>&1; then
    ok "deep-scan <cluster>: exit 0"
else
    bad "deep-scan <cluster>: expected exit 0"
fi
CHUMP_REPO="$FIXTURE" "$BIN" harvest deep-scan >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "deep-scan (missing cluster): exit 2" || bad "deep-scan (missing cluster): expected exit 2, got $rc"

echo
echo "--- scan (fake gh shim) ---"
SHIM_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE" "$SHIM_DIR"' EXIT
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/usr/bin/env bash
if [ "$1" = "repo" ] && [ "$2" = "list" ]; then
  echo '[{"name":"fixture-repo","description":"synthetic","primaryLanguage":{"name":"Rust"},"visibility":"PUBLIC","pushedAt":"2026-01-01","isArchived":false,"isFork":false,"sshUrl":"git@example.com:x/fixture-repo.git","url":"https://example.com/fixture-repo","createdAt":"2026-01-01","updatedAt":"2026-01-01","diskUsage":10,"repositoryTopics":[]}]'
  exit 0
fi
exit 1
SHIM
chmod +x "$SHIM_DIR/gh"

if CHUMP_REPO="$FIXTURE" PATH="$SHIM_DIR:$PATH" "$BIN" harvest scan >/tmp/harvest-scan-smoke.out 2>&1; then
    ok "scan: exit 0 on synthetic happy path"
else
    bad "scan: expected exit 0 (see /tmp/harvest-scan-smoke.out)"
fi
if [ -f "$FIXTURE/docs/arsenal/GLOBAL_ARSENAL.json" ] && grep -q '"extracted_primitives"' "$FIXTURE/docs/arsenal/GLOBAL_ARSENAL.json"; then
    ok "scan: rebuilt catalog carries extracted_primitives field"
else
    bad "scan: rebuilt catalog missing extracted_primitives field"
fi

RAW_MTIME_BEFORE=$(date -r "$FIXTURE/docs/arsenal/raw/github_repos.json" +%s 2>/dev/null || echo 0)
sleep 1
CHUMP_REPO="$FIXTURE" PATH="$SHIM_DIR:$PATH" "$BIN" harvest scan >/dev/null 2>&1
RAW_MTIME_AFTER=$(date -r "$FIXTURE/docs/arsenal/raw/github_repos.json" +%s 2>/dev/null || echo 0)
if [ "$RAW_MTIME_AFTER" -gt "$RAW_MTIME_BEFORE" ]; then
    ok "scan (INFRA-6616 AC1): docs/arsenal/raw/github_repos.json timestamp changes"
else
    bad "scan (INFRA-6616 AC1): raw/github_repos.json timestamp did not change"
fi

echo
echo "--- scan (INFRA-6616 AC3: high-severity alert -> non-zero exit) ---"
ALERT_FIXTURE="$(mktemp -d)"
mkdir -p "$ALERT_FIXTURE/docs/arsenal/raw" "$ALERT_FIXTURE/scripts/arsenal"
cp "$REPO_ROOT/scripts/arsenal/harvest.sh" "$ALERT_FIXTURE/scripts/arsenal/harvest.sh"
chmod +x "$ALERT_FIXTURE/scripts/arsenal/harvest.sh"
cat > "$ALERT_FIXTURE/scripts/arsenal/build.py" <<'PY'
import json, pathlib
out = {
    "metadata": {}, "clusters": {}, "duplications": [],
    "alerts": [{"severity": "high", "kind": "embedded_token", "action": "rotate"}],
    "primitives_index": {}, "repos_by_name": {}, "unmatched_local_roots": [],
}
pathlib.Path("docs/arsenal/GLOBAL_ARSENAL.json").write_text(json.dumps(out))
PY
if CHUMP_REPO="$ALERT_FIXTURE" PATH="$SHIM_DIR:$PATH" "$BIN" harvest scan >/dev/null 2>&1; then
    bad "scan (INFRA-6616 AC3): expected non-zero exit on high-severity alert"
else
    ok "scan (INFRA-6616 AC3): non-zero exit on high-severity alert"
fi
rm -rf "$ALERT_FIXTURE"

echo
echo "--- unknown subcommand ---"
CHUMP_REPO="$FIXTURE" "$BIN" harvest bogus-subcommand >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && ok "unknown subcommand: exit 2" || bad "unknown subcommand: expected exit 2, got $rc"

echo
echo "--- help ---"
if CHUMP_REPO="$FIXTURE" "$BIN" harvest help >/dev/null 2>&1; then
    ok "help: exit 0"
else
    bad "help: expected exit 0"
fi

echo
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
