#!/usr/bin/env bash
# test-fleet-doctor-ops-defect.sh — RESILIENT-257
#
# Verifies fleet-doctor-strict.sh's ops-defect self-diagnosis check
# (check_ops_defect_selfdiag):
#   1. No defects → pass.
#   2. Broken daemon exit code → fail, no auto-file when CHUMP_OPS_DEFECT_AUTOFILE=0.
#   3. False-positive alert (operator_recall fired while fleet was shipping) → fail.
#   4. Real defect + autofile=1 → auto-files a VOA via `chump voice` (docs/gaps +
#      docs/voice written into an isolated CHUMP_REPO_ROOT, never the real repo).
#   5. Dedup — a VOA already filed for the same wedge_class within the dedup
#      window suppresses re-filing.
#
# This proves the RESILIENT-257 behavior and fails without it (the check
# function + auto-file wiring did not exist before this gap).
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$DOCTOR" ]] || fail "fleet-doctor-strict.sh missing"

TMPDIR_BASE="$(mktemp -d -t test-fleet-doctor-ops-defect-XXXXXX)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Source the doctor script for direct function access (skips the full networked sweep).
export FLEET_DOCTOR_SOURCED=1
# shellcheck disable=SC1090
source "$DOCTOR"

last_status() { printf '%s' "${STATUSES[-1]:-}"; }
last_detail() { printf '%s' "${DETAILS[-1]:-}"; }

# ── Test 1: no defects → pass ────────────────────────────────────────────────
AMB_EMPTY="$TMPDIR_BASE/ambient-empty.jsonl"
: > "$AMB_EMPTY"
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_EMPTY" \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "pass" ]]; then
    pass "no defects → pass"
else
    fail "expected pass with no defects, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 2: broken daemon exit code → fail (report-only, no autofile) ───────
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
CHUMP_AMBIENT_LOG="$AMB_EMPTY" \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"broken-daemon-exit"* ]]; then
    pass "broken daemon exit code → fail, detail names broken-daemon-exit"
else
    fail "expected fail/broken-daemon-exit, got status=$(last_status) detail=$(last_detail)"
fi
if [[ "$(last_detail)" == *"auto-filed"* ]]; then
    fail "CHUMP_OPS_DEFECT_AUTOFILE=0 must not auto-file a VOA"
fi
pass "autofile=0 does not file a VOA"

# ── Test 3: false-positive alert (operator_recall fired while fleet shipped) ─
AMB_ALERT="$TMPDIR_BASE/ambient-alert.jsonl"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","kind":"operator_recall","condition":"AUTH_DEAD","reason":"fleet_auth_storm threshold"}\n' \
    "$now_iso" > "$AMB_ALERT"
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_ALERT" \
OPS_DEFECT_SHIP_COUNT_OVERRIDE=5 \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"false-positive-alert"* ]] && [[ "$(last_detail)" == *"AUTH_DEAD"* ]]; then
    pass "operator_recall fired while shipping → fail, detail names false-positive-alert"
else
    fail "expected fail/false-positive-alert/AUTH_DEAD, got status=$(last_status) detail=$(last_detail)"
fi

# Sanity: same alert but ZERO ship-rate (fleet genuinely idle) → not a false
# positive by this check's definition → pass.
CHUMP_OPS_DEFECT_AUTOFILE=0 \
OPS_DEFECT_DAEMON_STATUS_CMD="true" \
CHUMP_AMBIENT_LOG="$AMB_ALERT" \
OPS_DEFECT_SHIP_COUNT_OVERRIDE=0 \
    check_ops_defect_selfdiag
if [[ "$(last_status)" == "pass" ]]; then
    pass "alert with zero ship-rate ground truth → not flagged as false-positive"
else
    fail "expected pass when ship-rate is genuinely zero, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 4: real defect + autofile=1 → auto-files a VOA (isolated repo root) ─
FAKE_REPO="$TMPDIR_BASE/fake-repo"
mkdir -p "$FAKE_REPO/docs/gaps" "$FAKE_REPO/docs/voice"
if ! command -v chump &>/dev/null; then
    echo "SKIP: chump binary not on PATH — cannot exercise live auto-file path" >&2
else
    AMB_ISOLATED="$TMPDIR_BASE/ambient-isolated.jsonl"
    : > "$AMB_ISOLATED"
    CHUMP_OPS_DEFECT_AUTOFILE=1 \
    OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
    CHUMP_AMBIENT_LOG="$AMB_ISOLATED" \
    CHUMP_REPO_ROOT="$FAKE_REPO" \
    CHUMP_VOICE_TEST_ID="VOA-TEST257" \
        check_ops_defect_selfdiag
    if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"auto-filed"* ]]; then
        pass "real defect + autofile=1 → detail reports auto-filed"
    else
        fail "expected auto-filed in detail, got status=$(last_status) detail=$(last_detail)"
    fi
    if [[ -f "$FAKE_REPO/docs/gaps/VOA-TEST257.yaml" && -f "$FAKE_REPO/docs/voice/VOA-TEST257-FULL.yaml" ]]; then
        pass "chump voice wrote docs/gaps/VOA-TEST257.yaml and docs/voice/VOA-TEST257-FULL.yaml"
    else
        fail "expected VOA-TEST257 yaml files under $FAKE_REPO, not found"
    fi
    if grep -q '"kind":"voice_of_agent_filed"' "$AMB_ISOLATED" 2>/dev/null; then
        pass "voice_of_agent_filed emitted to isolated ambient log"
    else
        fail "expected kind=voice_of_agent_filed in $AMB_ISOLATED"
    fi

    # ── Test 5: dedup — same wedge_class already filed → skip re-filing ─────
    CHUMP_OPS_DEFECT_AUTOFILE=1 \
    OPS_DEFECT_DAEMON_STATUS_CMD='printf "com.chump.testdaemon\t127\n"' \
    CHUMP_AMBIENT_LOG="$AMB_ISOLATED" \
    CHUMP_REPO_ROOT="$FAKE_REPO" \
    CHUMP_VOICE_TEST_ID="VOA-TEST257B" \
        check_ops_defect_selfdiag
    if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"already filed"* ]]; then
        pass "dedup suppresses re-filing within window"
    else
        fail "expected 'already filed' dedup message, got status=$(last_status) detail=$(last_detail)"
    fi
    if [[ -f "$FAKE_REPO/docs/gaps/VOA-TEST257B.yaml" ]]; then
        fail "dedup should have prevented a second VOA-TEST257B.yaml from being written"
    fi
    pass "no second VOA file written on dedup"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Tests 6-8 (RESILIENT-1670 / RESILIENT-1657 item a'): cargo + sccache storage
# must sit on a fixed disk, never a removable or USB-transport block device
# (check_cargo_storage_fixed_disk). A node self-provisioned onto a USB flash
# stick is an operational defect of exactly the class this file diagnoses —
# closetjunky's ~/.cargo + 25G build target lived on a 32G USB stick and
# writeback stalls wedged the whole box three times in five days.
#
# Seam: lsblk + readlink are stubbed via PATH (the real check function runs
# unchanged); CARGO_HOME / CARGO_TARGET_DIR / SCCACHE_DIR are the genuine cargo
# env vars, set to sandbox paths. No CHUMP_* safety-input override exists.
# ─────────────────────────────────────────────────────────────────────────────
STUB="$TMPDIR_BASE/stub-bin"
mkdir -p "$STUB"

# Stub lsblk: ignore args, emit a fixed `-Pno NAME,PKNAME,TRAN,RM,MOUNTPOINT`
# table from a per-scenario file.
cat > "$STUB/lsblk" <<EOF
#!/usr/bin/env bash
cat "$STUB/lsblk.table"
EOF
# Stub readlink: map its last arg through a TSV (real<TAB>fake); identity on miss.
cat > "$STUB/readlink" <<EOF
#!/usr/bin/env bash
target="\${@: -1}"
if [[ -f "$STUB/readlink.map" ]]; then
    while IFS=\$'\t' read -r real fake; do
        [[ "\$target" == "\$real" ]] && { printf '%s\n' "\$fake"; exit 0; }
    done < "$STUB/readlink.map"
fi
printf '%s\n' "\$target"
EOF
chmod +x "$STUB/lsblk" "$STUB/readlink"

# CARGO_TARGET_DIR is not part of these scenarios; keep it out of the audited
# set so the check only inspects CARGO_HOME + SCCACHE_DIR below.
unset CARGO_TARGET_DIR

# ── Test 6: CARGO_HOME resolves onto a USB stick → fail, names the var + flags ──
CJ_CARGO="$TMPDIR_BASE/cj-cargo"
mkdir -p "$CJ_CARGO"
cat > "$STUB/lsblk.table" <<'EOF'
NAME="sda" PKNAME="" TRAN="" RM="0" MOUNTPOINT=""
NAME="sda1" PKNAME="sda" TRAN="" RM="0" MOUNTPOINT="/"
NAME="sde" PKNAME="" TRAN="usb" RM="1" MOUNTPOINT=""
NAME="sde1" PKNAME="sde" TRAN="" RM="1" MOUNTPOINT="/mnt/cjdata1"
EOF
printf '%s\t%s\n' "$CJ_CARGO" "/mnt/cjdata1/cargo" > "$STUB/readlink.map"

PATH="$STUB:$PATH" \
    CARGO_HOME="$CJ_CARGO" \
    SCCACHE_DIR="$TMPDIR_BASE/does-not-exist-sccache" \
    check_cargo_storage_fixed_disk
if [[ "$(last_status)" == "fail" ]] \
    && [[ "$(last_detail)" == *"CARGO_HOME"* ]] \
    && [[ "$(last_detail)" == *"/mnt/cjdata1/cargo"* ]] \
    && [[ "$(last_detail)" == *"TRAN=usb"* ]]; then
    pass "CARGO_HOME on a USB stick → fail, detail names var + resolved path + TRAN=usb"
else
    fail "expected USB fail naming CARGO_HOME, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 7: all paths on a fixed (sata) disk or absent → pass ──────────────────
FIXED_CARGO="$TMPDIR_BASE/fixed-cargo"
mkdir -p "$FIXED_CARGO"
cat > "$STUB/lsblk.table" <<'EOF'
NAME="sda" PKNAME="" TRAN="" RM="0" MOUNTPOINT=""
NAME="sda1" PKNAME="sda" TRAN="" RM="0" MOUNTPOINT="/"
NAME="sdb" PKNAME="" TRAN="sata" RM="0" MOUNTPOINT=""
NAME="sdb1" PKNAME="sdb" TRAN="" RM="0" MOUNTPOINT="/data"
EOF
printf '%s\t%s\n' "$FIXED_CARGO" "/data/cargo" > "$STUB/readlink.map"

PATH="$STUB:$PATH" \
    CARGO_HOME="$FIXED_CARGO" \
    SCCACHE_DIR="$TMPDIR_BASE/does-not-exist-sccache" \
    check_cargo_storage_fixed_disk
if [[ "$(last_status)" == "pass" ]]; then
    pass "cargo on a fixed sata disk + sccache absent → pass"
else
    fail "expected pass for fixed-disk cargo, got status=$(last_status) detail=$(last_detail)"
fi

# ── Test 8: a removable-flagged (RM=1) disk with no USB transport → fail ───────
# Proves the RM=1 arm independently of TRAN=usb (an eSATA/removable bay).
RM_CARGO="$TMPDIR_BASE/rm-cargo"
mkdir -p "$RM_CARGO"
cat > "$STUB/lsblk.table" <<'EOF'
NAME="sda" PKNAME="" TRAN="" RM="0" MOUNTPOINT=""
NAME="sda1" PKNAME="sda" TRAN="" RM="0" MOUNTPOINT="/"
NAME="sdf" PKNAME="" TRAN="sata" RM="1" MOUNTPOINT=""
NAME="sdf1" PKNAME="sdf" TRAN="" RM="1" MOUNTPOINT="/mnt/removable"
EOF
printf '%s\t%s\n' "$RM_CARGO" "/mnt/removable/cargo" > "$STUB/readlink.map"

PATH="$STUB:$PATH" \
    CARGO_HOME="$RM_CARGO" \
    SCCACHE_DIR="$TMPDIR_BASE/does-not-exist-sccache" \
    check_cargo_storage_fixed_disk
if [[ "$(last_status)" == "fail" ]] \
    && [[ "$(last_detail)" == *"CARGO_HOME"* ]] \
    && [[ "$(last_detail)" == *"RM=1"* ]]; then
    pass "CARGO_HOME on a removable (RM=1) disk → fail, detail names RM=1"
else
    fail "expected RM=1 fail, got status=$(last_status) detail=$(last_detail)"
fi

# ── Tests 9-10 (INFRA-8572): check_cargo_nextest fails when absent, passes when present ──
_NO_NEXTEST_PATH=""
IFS=: read -ra _PDIRS <<< "$PATH"
for _d in "${_PDIRS[@]}"; do
    [[ -x "$_d/cargo-nextest" ]] && continue
    _NO_NEXTEST_PATH="${_NO_NEXTEST_PATH:+$_NO_NEXTEST_PATH:}$_d"
done
EMPTY_CARGO="$TMPDIR_BASE/empty-cargo"
mkdir -p "$EMPTY_CARGO/bin"
PATH="$_NO_NEXTEST_PATH" CARGO_HOME="$EMPTY_CARGO" HOME="$TMPDIR_BASE/empty-home" check_cargo_nextest
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"cargo-nextest absent"* ]]; then
    pass "check_cargo_nextest fails RED when cargo-nextest is absent from PATH and CARGO_HOME/bin (INFRA-8572)"
else
    fail "expected check_cargo_nextest fail when absent, got status=$(last_status) detail=$(last_detail)"
fi

printf '#!/usr/bin/env bash\nexit 0\n' > "$EMPTY_CARGO/bin/cargo-nextest"
chmod +x "$EMPTY_CARGO/bin/cargo-nextest"
PATH="$_NO_NEXTEST_PATH" CARGO_HOME="$EMPTY_CARGO" HOME="$TMPDIR_BASE/empty-home" check_cargo_nextest
if [[ "$(last_status)" == "pass" ]] && [[ "$(last_detail)" == *"cargo-nextest installed"* ]]; then
    pass "check_cargo_nextest passes when cargo-nextest is present in CARGO_HOME/bin (INFRA-8572)"
else
    fail "expected check_cargo_nextest pass when present, got status=$(last_status) detail=$(last_detail)"
fi

# ── Tests 11-12 (INFRA-8589): check_installed_unit_host_literals flags foreign host literals ──
UNIT_HOME="/home/ubuntu"
UNIT_XDG="$TMPDIR_BASE/xdg-units"
FOREIGN_HOME="/home/""otherhost"
mkdir -p "$UNIT_XDG/systemd/user"
cat > "$UNIT_XDG/systemd/user/chump-gap-close-decomposed.service" <<EOF
[Service]
WorkingDirectory=${FOREIGN_HOME}/chump
Environment=PATH=${FOREIGN_HOME}/bin:/opt/homebrew/bin
EOF
HOME="$UNIT_HOME" XDG_CONFIG_HOME="$UNIT_XDG" check_installed_unit_host_literals
if [[ "$(last_status)" == "fail" ]] && [[ "$(last_detail)" == *"chump-gap-close-decomposed.service"* ]]; then
    pass "check_installed_unit_host_literals fails RED naming unit with foreign home + /opt/homebrew (INFRA-8589)"
else
    fail "expected check_installed_unit_host_literals fail naming chump-gap-close-decomposed.service, got status=$(last_status) detail=$(last_detail)"
fi

cat > "$UNIT_XDG/systemd/user/chump-gap-close-decomposed.service" <<'EOF'
[Service]
WorkingDirectory=/home/ubuntu/chump
Environment=PATH=/home/ubuntu/.cargo/bin:/usr/bin
EOF
HOME="$UNIT_HOME" XDG_CONFIG_HOME="$UNIT_XDG" check_installed_unit_host_literals
if [[ "$(last_status)" == "pass" ]]; then
    pass "check_installed_unit_host_literals passes when installed units only reference current HOME (INFRA-8589)"
else
    fail "expected check_installed_unit_host_literals pass for clean unit, got status=$(last_status) detail=$(last_detail)"
fi

echo "=== all ops-defect self-diagnosis + cargo-storage tests passed ==="
