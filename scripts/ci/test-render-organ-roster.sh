#!/usr/bin/env bash
# scripts/ci/test-render-organ-roster.sh — INFRA-7767
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1: "One renderer per
# supervisor ... slice A only unions the DATA, slice B teaches the renderer
# to also target --user scope and the other two supervisors." This proves
# slice A's renderer utility (scripts/ops/render-organ-roster.sh) exists and
# applies the SAME platform/role filter organ-reconcile.sh applies inline
# (INFRA-7764), so a future slice-B renderer (or a human auditing the
# roster) has one shared, tested utility instead of re-deriving the filter.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RENDERER="$REPO_ROOT/scripts/ops/render-organ-roster.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-render-organ-roster.sh (INFRA-7767) ==="

[[ -f "$RENDERER" ]] || fail "missing $RENDERER"
[[ -x "$RENDERER" ]] || fail "$RENDERER not executable"
bash -n "$RENDERER" || fail "render-organ-roster.sh bash -n failed"
pass "renderer present, executable, syntax clean"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MANIFEST="$TMP/manifest.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-sysA.service  role=brain requires=bin:git
enabled  chump-sysB.timer    role=data platforms=systemd,launchd
enabled  chump-macOnly.timer role=brain platforms=launchd
paging_off  chump-pager.service
EOF

out_systemd="$("$RENDERER" --platform systemd --manifest "$MANIFEST")"
echo "$out_systemd" | grep -q "chump-sysA.service" || fail "--platform systemd must include chump-sysA.service (default systemd); got: $out_systemd"
echo "$out_systemd" | grep -q "chump-sysB.timer" || fail "--platform systemd must include chump-sysB.timer (systemd,launchd); got: $out_systemd"
echo "$out_systemd" | grep -q "chump-macOnly.timer" && fail "--platform systemd must EXCLUDE chump-macOnly.timer (launchd-only); got: $out_systemd"
pass "--platform systemd renders the systemd-applicable subset only"

out_launchd="$("$RENDERER" --platform launchd --manifest "$MANIFEST")"
echo "$out_launchd" | grep -q "chump-macOnly.timer" || fail "--platform launchd must include chump-macOnly.timer; got: $out_launchd"
echo "$out_launchd" | grep -q "chump-sysA.service" && fail "--platform launchd must EXCLUDE chump-sysA.service (systemd-default-only); got: $out_launchd"
echo "$out_launchd" | grep -q "chump-sysB.timer" || fail "--platform launchd must include chump-sysB.timer (systemd,launchd); got: $out_launchd"
pass "--platform launchd renders the launchd-applicable subset only"

out_role="$("$RENDERER" --platform systemd --role data --manifest "$MANIFEST")"
echo "$out_role" | grep -q "chump-sysB.timer" || fail "--role data must include chump-sysB.timer; got: $out_role"
echo "$out_role" | grep -q "chump-sysA.service" && fail "--role data must EXCLUDE chump-sysA.service (role=brain); got: $out_role"
pass "--role filters further within a platform"

# Against the REAL manifest: every line render-organ-roster.sh prints for
# --platform systemd must ALSO be a line organ-reconcile.sh would attempt
# (cross-check the two independent filter implementations agree).
REAL_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
real_out="$("$RENDERER" --platform systemd --manifest "$REAL_MANIFEST" | awk '{print $1}')"
[[ -n "$real_out" ]] || fail "renderer produced zero lines against the real organ-manifest.txt"
echo "$real_out" | grep -q "chump-opus-curator.timer" && fail "renderer must exclude platforms=launchd-only lines from the real manifest under --platform systemd; chump-opus-curator.timer leaked"
echo "$real_out" | grep -q "chump-board-cycle.timer" || fail "renderer must include a known real systemd-default organ (chump-board-cycle.timer) under --platform systemd"
pass "against the real organ-manifest.txt, the renderer excludes launchd-only lines and includes known systemd organs"

echo "ALL PASS"
