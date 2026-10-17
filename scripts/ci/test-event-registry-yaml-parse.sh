#!/usr/bin/env bash
# test-event-registry-yaml-parse.sh — CREDIBLE-1516
#
# Parses docs/observability/EVENT_REGISTRY.yaml and docs/observability/
# SELF_REPORTS.yaml as real YAML (yaml.safe_load), failing on any illegal
# scalar. Until this gate, every registry gate (test-event-registry-coverage.sh,
# the pre-commit registry hook, event-registry-audit) only grepped `kind:`
# lines and NEVER parsed the document — so an illegal backtick scalar landed in
# #3472 (INFRA-3495) at EVENT_REGISTRY.yaml line 137 and sat on main for months.
# It was invisible to the Mac (no PyYAML) and to CI, but the new union merge
# driver (INFRA-8223) DOES call yaml.safe_load when PyYAML is present, so every
# rebase touching the registry failed on nodes that have it (the Phase R train
# #5561 fast-checks failure, 2026-10-17 19:05Z).
#
# This is the authoritative CI gate. It is mirrored into `chump preflight`
# (crates/chump-preflight/src/preflight.rs discover_test_scripts candidates) and
# the same parse runs in the pre-commit registry hook when PyYAML is present.
#
# PyYAML handling:
#   - If `import yaml` succeeds, the gate parses for real.
#   - If it fails, the script attempts a single quiet `pip install pyyaml`
#     (CI runners may lack it). If that succeeds, it parses for real.
#   - If PyYAML is still absent (offline / no pip), the script prints a LOUD
#     skip and exits 0 — the gate cannot run without the parser, and a false
#     failure on a host that simply lacks PyYAML would erode trust.
#
# Exit 0 — all present registry files parse (or PyYAML genuinely unavailable).
# Exit 1 — a registry file failed to parse as YAML, OR the backtick-fixture
#          regression assertion did not fire (the gate would be a no-op).

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "[registry-yaml-parse] CREDIBLE-1516 — YAML-parse gate for observability registries"

# ── Ensure PyYAML, or loud-skip ──────────────────────────────────────────────
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "[registry-yaml-parse] PyYAML not importable — attempting one quiet install"
    python3 -m pip install --quiet pyyaml >/dev/null 2>&1 || true
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo "[registry-yaml-parse] SKIP (LOUD): PyYAML is absent and could not be installed."
    echo "[registry-yaml-parse]   This gate requires PyYAML to parse the registry. On CI"
    echo "[registry-yaml-parse]   PyYAML is installed; a local host without it skips here."
    echo "[registry-yaml-parse]   Install with: python3 -m pip install pyyaml"
    exit 0
fi

REGISTRIES=(
    "docs/observability/EVENT_REGISTRY.yaml"
    "docs/observability/SELF_REPORTS.yaml"
)

rc=0

# ── Parse each present registry file ─────────────────────────────────────────
for rel in "${REGISTRIES[@]}"; do
    abs="$REPO_ROOT/$rel"
    if [[ ! -f "$abs" ]]; then
        echo "[registry-yaml-parse] skip (not present): $rel"
        continue
    fi
    parse_err=""
    if ! parse_err="$(python3 -c '
import sys, yaml
try:
    with open(sys.argv[1]) as fh:
        yaml.safe_load(fh)
except yaml.YAMLError as e:
    sys.stderr.write(str(e))
    sys.exit(1)
' "$abs" 2>&1)"; then
        echo "[registry-yaml-parse] FAIL: $rel does not parse as YAML:" >&2
        printf '%s\n' "$parse_err" | sed 's/^/[registry-yaml-parse]   /' >&2
        rc=1
    else
        echo "[registry-yaml-parse] PASS: $rel parses cleanly"
    fi
done

# ── Regression: a backtick scalar MUST be rejected ───────────────────────────
# Proves the gate actually catches the illegal class it was built for, rather
# than silently passing because (e.g.) safe_load was never called.
fixture="$(mktemp)"
trap 'rm -f "$fixture"' EXIT
cat > "$fixture" <<'YAML'
events:
  - kind: fixture_illegal_scalar
    trigger: `chump gap audit-done` finds a DONE gap (backtick-led scalar — YAML forbids)
YAML

fixture_rc=0
python3 -c '
import sys, yaml
with open(sys.argv[1]) as fh:
    yaml.safe_load(fh)
' "$fixture" >/dev/null 2>&1 || fixture_rc=$?

if [[ "$fixture_rc" -ne 0 ]]; then
    echo "[registry-yaml-parse] PASS: backtick-scalar fixture is rejected (gate is live)"
else
    echo "[registry-yaml-parse] FAIL: backtick-scalar fixture PARSED — gate is a no-op" >&2
    rc=1
fi

if [[ "$rc" -eq 0 ]]; then
    echo "[registry-yaml-parse] OK — all present registries parse and the gate is live"
fi
exit "$rc"
