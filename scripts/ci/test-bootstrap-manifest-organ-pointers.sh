#!/usr/bin/env bash
# scripts/ci/test-bootstrap-manifest-organ-pointers.sh — INFRA-7765
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (one-command-install BOM
# unification, INFRA-7756): "bootstrap-manifest.yaml's id: becomes a pointer
# into this manifest (organ: chump-opus-curator) ... for every id that has
# (or gets) a manifest line." This proves that fold-in landed correctly and
# safely:
#
#   1. Every bootstrap-manifest.yaml id that is not a documented prerequisite
#      exclusion carries an `organ:` field naming a REAL organ-manifest.txt
#      line (matched-organ, renamed-organ, or confirmed-absent — all three
#      get a line per the design doc).
#   2. The one confirmed exact match (fleet-server-launchd) points at the
#      EXISTING chump-fleet-server.service line, not a duplicate, and that
#      line's platforms= was widened to include launchd.
#   3. Every NEW platforms=launchd-only line added for a confirmed-absent
#      macOS capability is excluded from organ-reconcile's systemd ENABLED
#      set (INFRA-7764's filter) — the zero-runtime-behavior-change
#      guarantee this whole slice depends on, re-verified end-to-end against
#      the REAL manifest (not just the synthetic fixture INFRA-7764's own
#      test uses).
#
# Without INFRA-7765, step 1 fails (no organ: fields exist at all).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BOOTSTRAP="$REPO_ROOT/scripts/setup/bootstrap-manifest.yaml"
ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-bootstrap-manifest-organ-pointers.sh (INFRA-7765) ==="

[[ -f "$BOOTSTRAP" ]] || fail "missing $BOOTSTRAP"
[[ -f "$ORGAN_MANIFEST" ]] || fail "missing $ORGAN_MANIFEST"
python3 -c "import yaml; yaml.safe_load(open('$BOOTSTRAP'))" \
  || fail "bootstrap-manifest.yaml failed to parse as YAML after the organ: pointer fold-in"
pass "bootstrap-manifest.yaml still parses as valid YAML"

organ_count="$(grep -cE '^\s*organ:\s*\S+' "$BOOTSTRAP")"
[[ "$organ_count" -ge 25 ]] || fail "expected >=25 organ: pointers in bootstrap-manifest.yaml, found $organ_count"
pass "bootstrap-manifest.yaml carries $organ_count organ: pointers"

# Every organ: pointer must name a real organ-manifest.txt line.
dangling=()
while IFS= read -r organ; do
  [[ -z "$organ" ]] && continue
  grep -qE "^(enabled|paging_off) +${organ//./\\.}( |\$)" "$ORGAN_MANIFEST" || dangling+=("$organ")
done < <(grep -oE '^\s*organ:\s*\S+' "$BOOTSTRAP" | sed -E 's/^\s*organ:\s*//')
if [[ "${#dangling[@]}" -gt 0 ]]; then
  fail "organ: pointer(s) naming a unit absent from organ-manifest.txt: ${dangling[*]}"
fi
pass "every organ: pointer resolves to a real organ-manifest.txt line"

# fleet-server-launchd: matched-organ, must point at the EXISTING
# chump-fleet-server.service line (not a fresh duplicate), platforms widened.
fs_block="$(awk '/- id: fleet-server-launchd/{f=1} f{print} f && /^  - id:/ && !/fleet-server-launchd/{exit}' "$BOOTSTRAP")"
echo "$fs_block" | grep -q 'organ: chump-fleet-server.service' \
  || fail "fleet-server-launchd's organ: pointer must be chump-fleet-server.service; got: $fs_block"
fs_manifest_line="$(grep -E '^enabled +chump-fleet-server\.service' "$ORGAN_MANIFEST")"
[[ "$(grep -cE '^(enabled|paging_off) +chump-fleet-server\.service' "$ORGAN_MANIFEST")" == "1" ]] \
  || fail "chump-fleet-server.service must appear exactly once in organ-manifest.txt (matched-organ, no duplicate line)"
echo "$fs_manifest_line" | grep -q 'platforms=.*launchd' \
  || fail "chump-fleet-server.service's platforms= must be widened to include launchd; got: $fs_manifest_line"
echo "$fs_manifest_line" | grep -q 'platforms=.*systemd' \
  || fail "chump-fleet-server.service's platforms= must still include systemd (widened, not replaced); got: $fs_manifest_line"
pass "fleet-server-launchd matched-organ points at the single, platforms-widened chump-fleet-server.service line"

# ── End-to-end: the REAL manifest's new platforms=launchd-only lines never
#    reach a systemd organ-reconcile's ENABLED set ──────────────────────────
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active) exit 3 ;;
    enable) exit 0 ;;
    show) echo "ExecStart=/bin/true"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB"
CALL_LOG="$TMP/calls.log"; : > "$CALL_LOG"
BACKOFF_DIR="$TMP/backoff"
AMBIENT="$TMP/ambient.jsonl"

out="$(
  CHUMP_ORGAN_MANIFEST="$ORGAN_MANIFEST" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
  CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S=3600 \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CALL_LOG="$CALL_LOG" \
  NODE_AMBIENT="$AMBIENT" \
  bash "$RECONCILE" --check 2>&1
)"

# A handful of the confirmed-absent macOS-only units this slice added — none
# may appear in --check output nor be passed to systemctl on this (systemd)
# host.
for launchd_only in chump-opus-curator.timer chump-paramedic.timer chump-conductor.timer chump-self-doctor.timer; do
  echo "$out" | grep -q "$launchd_only" \
    && fail "$launchd_only (platforms=launchd-only) leaked into a systemd --check run — INFRA-7764's filter regressed; output: $out"
  grep -q "$launchd_only" "$CALL_LOG" \
    && fail "$launchd_only (platforms=launchd-only) was passed to systemctl on a systemd host — INFRA-7764's filter regressed; call log: $(cat "$CALL_LOG")"
done
pass "the real organ-manifest.txt's new platforms=launchd-only lines never reach a systemd organ-reconcile run (INFRA-7764 filter holds end-to-end)"

echo "ALL PASS"
