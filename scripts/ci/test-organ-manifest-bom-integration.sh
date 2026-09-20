#!/usr/bin/env bash
# scripts/ci/test-organ-manifest-bom-integration.sh — INFRA-7768
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (INFRA-7756, one-command-
# install BOM unification, slice A). INFRA-7764/7765/7766/7767 each got their
# own unit test (platforms= parsing, bootstrap-manifest.yaml pointers, the
# housekeeping roster derivation, the renderer) but nothing proved the FOUR
# consumers agree with each other against the SAME manifest — that's the
# actual "unified" claim slice A makes: one declared roster, not four that
# happen to individually parse. This test is that integration proof:
#
#   1. A synthetic manifest exercising platforms=/housekeeping=/role=
#      together is parsed identically by organ-manifest-lib.sh (the shared
#      parser), render-organ-roster.sh (the renderer) and
#      node-housekeeping-roster-lib.sh (the housekeeping-organ deriver) —
#      the three independent call sites this slice unified.
#   2. A malformed/missing BOM degrades the way the design requires:
#      organ_manifest_parse and render-organ-roster.sh fail closed (exit
#      non-zero) while housekeeping_organs_from_manifest() fails OPEN with a
#      visible WARN + its documented built-in fallback roster — proving the
#      difference is deliberate, not an accident of three unrelated scripts.
#   3. Against the REAL organ-manifest.txt: every housekeeping= organ is
#      ALSO visible in the systemd renderer's output — the same manifest
#      line drives both consumers, so this fails the moment the two diverge
#      (e.g. a housekeeping= organ mistakenly tagged platforms=launchd-only).
#
# Without INFRA-7764 (platforms=) + INFRA-7766 (housekeeping= roster lib) +
# INFRA-7767 (renderer) all present and mutually consistent, this test fails
# to source the libraries, mis-parses the synthetic manifest, or finds a
# housekeeping organ missing from the renderer's real-manifest output.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MANIFEST_LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
HK_LIB="$REPO_ROOT/scripts/ops/lib/node-housekeeping-roster-lib.sh"
RENDERER="$REPO_ROOT/scripts/ops/render-organ-roster.sh"
REAL_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
BOOTSTRAP="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-organ-manifest-bom-integration.sh (INFRA-7768) ==="

for f in "$MANIFEST_LIB" "$HK_LIB" "$RENDERER" "$REAL_MANIFEST" "$BOOTSTRAP"; do
  [[ -e "$f" ]] || fail "missing $f"
done
bash -n "$MANIFEST_LIB" || fail "organ-manifest-lib.sh bash -n failed"
bash -n "$HK_LIB" || fail "node-housekeeping-roster-lib.sh bash -n failed"
bash -n "$RENDERER" || fail "render-organ-roster.sh bash -n failed"
pass "all four BOM consumers present, syntax clean"

# shellcheck disable=SC1090
source "$MANIFEST_LIB"
# shellcheck disable=SC1090
source "$HK_LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. One synthetic manifest, three consumers, must agree ──────────────────
SYN="$TMP/synthetic.txt"
cat > "$SYN" <<'EOF'
enabled  chump-janitor-hk.service  role=janitor housekeeping=scripts/ops/fake-janitor.sh|300|
enabled  chump-mac-only.timer      role=brain platforms=launchd
enabled  chump-both-hk.service     role=data platforms=systemd,launchd housekeeping=scripts/ops/fake-both.sh|60|--flag
paging_off  chump-pager.service
EOF

# 1a. organ-manifest-lib.sh: platforms captured correctly for all three.
P_OFF=(); P_EN=(); declare -A P_ROLE; declare -A P_REQ; declare -A P_PLAT
organ_manifest_parse "$SYN" P_OFF P_EN P_ROLE P_REQ P_PLAT \
  || fail "organ_manifest_parse failed against the synthetic BOM"
[[ "${#P_EN[@]}" == 3 ]] || fail "expected 3 enabled lines, got ${#P_EN[@]}"
[[ "${P_PLAT[chump-janitor-hk.service]:-}" == "systemd" ]] || fail "chump-janitor-hk.service must default to platforms=systemd"
[[ "${P_PLAT[chump-mac-only.timer]:-}" == "launchd" ]] || fail "chump-mac-only.timer must be platforms=launchd"
[[ "${P_PLAT[chump-both-hk.service]:-}" == "systemd,launchd" ]] || fail "chump-both-hk.service must be platforms=systemd,launchd"
pass "organ-manifest-lib.sh parses the synthetic BOM's platforms= consistently"

# 1b. render-organ-roster.sh: systemd render includes the two systemd-
#     applicable units, excludes the launchd-only one.
out_sys="$("$RENDERER" --platform systemd --manifest "$SYN")"
echo "$out_sys" | grep -q "chump-janitor-hk.service" || fail "renderer(systemd) must include chump-janitor-hk.service"
echo "$out_sys" | grep -q "chump-both-hk.service" || fail "renderer(systemd) must include chump-both-hk.service"
echo "$out_sys" | grep -q "chump-mac-only.timer" && fail "renderer(systemd) must EXCLUDE chump-mac-only.timer"
out_lnc="$("$RENDERER" --platform launchd --manifest "$SYN")"
echo "$out_lnc" | grep -q "chump-mac-only.timer" || fail "renderer(launchd) must include chump-mac-only.timer"
echo "$out_lnc" | grep -q "chump-janitor-hk.service" && fail "renderer(launchd) must EXCLUDE chump-janitor-hk.service (systemd-default-only)"
pass "render-organ-roster.sh filters the same synthetic BOM consistently with organ-manifest-lib.sh"

# 1c. node-housekeeping-roster-lib.sh: derives housekeeping= organs only —
#     the launchd-only, non-housekeeping line never appears.
hk_out="$(housekeeping_organs_from_manifest "$SYN")"
echo "$hk_out" | grep -q "^janitor-hk|scripts/ops/fake-janitor.sh|300$" || fail "housekeeping lib must derive janitor-hk|script|cadence from housekeeping= token; got: $hk_out"
echo "$hk_out" | grep -q "^both-hk|scripts/ops/fake-both.sh --flag|60$" || fail "housekeeping lib must fold trailing args into the script field; got: $hk_out"
echo "$hk_out" | grep -q "mac-only" && fail "housekeeping lib must NOT derive an organ from a line with no housekeeping= token; got: $hk_out"
# the two documented collision carve-outs (INFRA-7772) are always appended
echo "$hk_out" | grep -q "^pr-lander|" || fail "housekeeping lib must still append the pr-lander carve-out"
echo "$hk_out" | grep -q "^rot-reaper|" || fail "housekeeping lib must still append the rot-reaper carve-out"
pass "node-housekeeping-roster-lib.sh derives exactly the housekeeping= tagged organs (+ documented carve-outs) from the same synthetic BOM"

# ── 2. Malformed / missing BOM: fail-closed parser+renderer, fail-open housekeeping ──
MISSING="$TMP/does-not-exist.txt"
organ_manifest_parse "$MISSING" P_OFF P_EN P_ROLE P_REQ P_PLAT \
  && fail "organ_manifest_parse must fail (non-zero) on a missing manifest"
pass "organ_manifest_parse fails closed on a missing BOM"

"$RENDERER" --manifest "$MISSING" >/dev/null 2>&1 \
  && fail "render-organ-roster.sh must exit non-zero on a missing BOM"
pass "render-organ-roster.sh fails closed on a missing BOM"

hk_missing_out="$(housekeeping_organs_from_manifest "$MISSING" 2>"$TMP/hk-missing.err")"
grep -q "WARN (INFRA-7766)" "$TMP/hk-missing.err" \
  || fail "housekeeping_organs_from_manifest must WARN on stderr when the BOM is missing"
echo "$hk_missing_out" | grep -q "^node-orchestrator|" \
  || fail "housekeeping_organs_from_manifest must fall back to its built-in roster on a missing BOM"
pass "housekeeping_organs_from_manifest fails open (WARN + built-in fallback) on a missing BOM — deliberately different from the parser/renderer, by design"

# A BOM that EXISTS but has been stripped of every housekeeping= token
# (the "malformed" case a bad edit could produce) must trigger the same
# fallback — not silently install zero organs.
STRIPPED="$TMP/stripped.txt"
cat > "$STRIPPED" <<'EOF'
enabled  chump-mac-only.timer  role=brain platforms=launchd
EOF
hk_stripped_out="$(housekeeping_organs_from_manifest "$STRIPPED" 2>"$TMP/hk-stripped.err")"
grep -q "WARN (INFRA-7766)" "$TMP/hk-stripped.err" \
  || fail "housekeeping_organs_from_manifest must WARN when the BOM exists but has zero housekeeping= lines"
echo "$hk_stripped_out" | grep -q "^node-orchestrator|" \
  || fail "housekeeping_organs_from_manifest must fall back to the built-in roster when the BOM has zero housekeeping= lines (not silently install nothing)"
pass "a present-but-housekeeping-stripped BOM is caught the same way (WARN + fallback), not silently emptied"

# ── 3. Against the REAL manifest: parser, renderer and housekeeping lib agree ──
real_hk_names="$(housekeeping_organs_from_manifest "$REAL_MANIFEST" | awk -F'|' '{print $1}')"
real_sys_units="$("$RENDERER" --platform systemd --manifest "$REAL_MANIFEST" | awk '{print $1}')"
[[ -n "$real_hk_names" ]] || fail "real manifest produced zero housekeeping organs — INFRA-7766 fold-in regressed"
[[ -n "$real_sys_units" ]] || fail "real manifest produced zero systemd-applicable units — renderer regressed"

missing_from_render=()
while IFS= read -r name; do
  case "$name" in pr-lander|rot-reaper) continue ;; esac  # INFRA-7772 documented carve-out, not organ-manifest.txt lines
  unit="chump-${name}.service"
  echo "$real_sys_units" | grep -qxF "$unit" || missing_from_render+=("$unit")
done <<< "$real_hk_names"
if [[ "${#missing_from_render[@]}" -gt 0 ]]; then
  fail "housekeeping organ(s) derived from organ-manifest.txt but absent from the systemd renderer's output (BOM consumers diverged): ${missing_from_render[*]}"
fi
pass "every real housekeeping= organ (minus the documented INFRA-7772 carve-out) is also visible to the systemd renderer — the two consumers read the SAME manifest line consistently"

echo "ALL PASS"
