#!/usr/bin/env bash
# scripts/ci/test-organ-manifest-platforms-field.sh — INFRA-7764
#
# docs/strategy/ONE_COMMAND_INSTALL.md section 1 (INFRA-7756, one-command-
# install BOM unification) extends organ-manifest.txt with a `platforms=`
# field so bootstrap-manifest.yaml's macOS-only capabilities and
# install-node-housekeeping.sh's roster can fold into ONE declared roster
# (INFRA-7765/INFRA-7766) instead of three unlinked files. The design
# explicitly requires "zero runtime behavior change" for this slice — this
# test proves that requirement two ways:
#
#   1. Parity: a manifest with only pre-existing-style `enabled` lines (no
#      platforms= token) reconciles byte-for-byte the way it did before this
#      gap — the omitted field defaults to platforms=systemd.
#   2. New capability, no regression: a `platforms=launchd`-only line NEVER
#      reaches organ-reconcile.sh's ENABLED set (and is therefore never
#      `systemctl enable`'d, never reported as DRIFT, never attempted) when
#      the host's detected platform is systemd — the exact regression the
#      design doc warns folding in mac-only capabilities could cause without
#      this filter.
#   3. The filter is genuinely platform-driven (not a coincidence): flipping
#      CHUMP_ORGAN_MANIFEST_PLATFORM to launchd reverses which of two lines
#      in the SAME manifest gets attempted.
#
# Without INFRA-7764's platforms= support in organ-manifest-lib.sh and the
# reconcile-side filter, this test fails to parse (organ_current_platform /
# organ_platform_matches undefined) or the launchd-only line leaks into
# ENABLED and gets a live `systemctl enable --now` attempted against it.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-organ-manifest-platforms-field.sh (INFRA-7764) ==="

[[ -f "$RECONCILE" ]] || fail "reconcile script missing: $RECONCILE"
[[ -f "$LIB" ]] || fail "organ-manifest-lib.sh missing: $LIB"
bash -n "$RECONCILE" || fail "reconcile bash -n failed"
bash -n "$LIB" || fail "organ-manifest-lib.sh bash -n failed"
pass "scripts present, syntax clean"

# ── 1. Library-level unit tests for the new helpers ─────────────────────────
# shellcheck disable=SC1090
source "$LIB"

[[ "$(organ_current_platform)" == "systemd" ]] \
    || fail "organ_current_platform on a Linux CI runner (no PREFIX/com.termux, uname != Darwin) must default to systemd; got $(organ_current_platform)"
pass "organ_current_platform defaults to systemd on a plain Linux host"

CHUMP_ORGAN_MANIFEST_PLATFORM=launchd organ_current_platform | grep -qx launchd \
    || fail "CHUMP_ORGAN_MANIFEST_PLATFORM override must be honored"
pass "organ_current_platform honors CHUMP_ORGAN_MANIFEST_PLATFORM override"

organ_platform_matches "" systemd || fail "empty platforms= must default-match systemd"
organ_platform_matches "systemd" systemd || fail "explicit platforms=systemd must match systemd"
organ_platform_matches "launchd" systemd && fail "platforms=launchd must NOT match systemd"
organ_platform_matches "systemd,launchd" launchd || fail "platforms=systemd,launchd must match launchd"
organ_platform_matches "" launchd && fail "empty platforms= (implicit systemd) must NOT match launchd"
pass "organ_platform_matches: default-systemd, explicit match, explicit no-match, multi-value, cross-platform no-match"

# organ_manifest_parse: 5-arg call (pre-existing signature) must still work
# untouched — this is the back-compat contract every existing caller relies on.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PARSE_MANIFEST="$TMP/parse-manifest.txt"
cat > "$PARSE_MANIFEST" <<'EOF'
enabled  chump-plain.service  role=muscle requires=bin:git
enabled  chump-tagged.service  role=brain platforms=launchd
paging_off  chump-pager.service
EOF

P_OFF=(); P_EN=(); declare -A P_ROLE; declare -A P_REQ
organ_manifest_parse "$PARSE_MANIFEST" P_OFF P_EN P_ROLE P_REQ \
    || fail "5-arg organ_manifest_parse call must still succeed (back-compat)"
[[ "${#P_EN[@]}" == 2 ]] || fail "5-arg parse must still see both enabled lines; got ${#P_EN[@]}"
pass "organ_manifest_parse: 5-arg (pre-INFRA-7764) call signature unaffected"

# 6-arg call: platforms populated, default applied when omitted
P_OFF=(); P_EN=(); declare -A P_ROLE; declare -A P_REQ; declare -A P_PLAT
organ_manifest_parse "$PARSE_MANIFEST" P_OFF P_EN P_ROLE P_REQ P_PLAT \
    || fail "6-arg organ_manifest_parse call must succeed"
[[ "${P_PLAT[chump-plain.service]:-}" == "systemd" ]] \
    || fail "omitted platforms= must default to systemd; got '${P_PLAT[chump-plain.service]:-}'"
[[ "${P_PLAT[chump-tagged.service]:-}" == "launchd" ]] \
    || fail "explicit platforms=launchd must be captured verbatim; got '${P_PLAT[chump-tagged.service]:-}'"
pass "organ_manifest_parse: 6-arg call captures platforms=, defaults omitted lines to systemd"

# ── 2. End-to-end: organ-reconcile.sh --check parity + platform filtering ──
STUB="$TMP/systemctl-stub"
CALL_LOG="$TMP/calls.log"
ACTIVE_FILE="$TMP/active.txt"
touch "$ACTIVE_FILE"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    enable)
        unit="${@: -1}"
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    show) echo "ExecStart=/bin/true"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
chmod +x "$STUB"

BACKOFF_DIR="$TMP/backoff"
AMBIENT="$TMP/ambient.jsonl"

run_reconcile() {  # manifest mode [platform-override]
    : > "$CALL_LOG"; : > "$ACTIVE_FILE"; rm -rf "$BACKOFF_DIR"
    CHUMP_ORGAN_MANIFEST="$1" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S=3600 \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST_PLATFORM="${3:-}" \
    NODE_AMBIENT="$AMBIENT" \
    bash "$RECONCILE" "$2"
}

# 2a. Parity: an all-default (no platforms=) manifest behaves exactly as
#     pre-INFRA-7764 — every enabled line is attempted, DRIFT reported when
#     inactive.
PARITY_MANIFEST="$TMP/parity.txt"
cat > "$PARITY_MANIFEST" <<'EOF'
enabled  chump-parity-a.service  role=brain
enabled  chump-parity-b.service  role=brain
EOF
out="$(run_reconcile "$PARITY_MANIFEST" --check)"
echo "$out" | grep -q "DRIFT: chump-parity-a.service is not active" || fail "parity: chump-parity-a.service must still be checked/DRIFT-flagged with no platforms= token"
echo "$out" | grep -q "DRIFT: chump-parity-b.service is not active" || fail "parity: chump-parity-b.service must still be checked/DRIFT-flagged with no platforms= token"
pass "parity: manifest with no platforms= tokens reconciles exactly as before (both lines checked)"

# 2b. platforms=launchd-only line is invisible to a systemd reconcile — never
#     reaches ENABLED, never reported as DRIFT, never systemctl-attempted.
MIXED_MANIFEST="$TMP/mixed.txt"
cat > "$MIXED_MANIFEST" <<'EOF'
enabled  chump-systemd-organ.service  role=brain platforms=systemd
enabled  chump-launchd-only.service   role=brain platforms=launchd
EOF
out="$(run_reconcile "$MIXED_MANIFEST" --check)"
echo "$out" | grep -q "chump-systemd-organ.service is not active" \
    || fail "platforms=systemd line must still be checked on a systemd host; got: $out"
echo "$out" | grep -q "chump-launchd-only" \
    && fail "platforms=launchd-only line must NEVER appear in --check output on a systemd host (regression this gap exists to prevent); got: $out"
grep -q "chump-launchd-only" "$CALL_LOG" \
    && fail "platforms=launchd-only line must NEVER be passed to systemctl on a systemd host; call log: $(cat "$CALL_LOG")"
pass "platforms=launchd-only line is fully excluded from a systemd reconcile: no DRIFT report, no systemctl call"

# 2c. The filter is genuinely platform-driven: flip CHUMP_ORGAN_MANIFEST_PLATFORM
#     to launchd against the SAME mixed manifest and the exclusion reverses.
out="$(run_reconcile "$MIXED_MANIFEST" --check launchd)"
echo "$out" | grep -q "chump-launchd-only.service is not active" \
    || fail "under platform override=launchd, chump-launchd-only.service must now be checked; got: $out"
echo "$out" | grep -q "chump-systemd-organ" \
    && fail "under platform override=launchd, chump-systemd-organ.service (platforms=systemd) must now be excluded; got: $out"
pass "platform filter is genuinely platform-driven: overriding the detected platform reverses which line is attempted"

echo "ALL PASS"
