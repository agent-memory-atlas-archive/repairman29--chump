#!/usr/bin/env bash
# scripts/ci/test-organ-reconcile.sh — RESILIENT-347
#
# Proves the per-node-applicable organ reconcile: an `enabled` organ whose
# manifest `requires=` spec is unmet on this node is SKIPPED (never even
# attempted), and an applicable organ that fails to enable/verify is backed
# off (disabled + cooldown-recorded) instead of being re-attempted — and
# therefore re-failed — on every single reconcile cycle. Without RESILIENT-347
# the reconcile called `systemctl enable --now` unconditionally on every
# `enabled` manifest line and re-tried a permanently-broken unit forever
# (the pre-347 churn on integrator/sla-scorecard/backlog-sync-writer/farmer).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ✓ $*"; }
fail() { echo "  ✗ $*" >&2; exit 1; }

echo "=== test-organ-reconcile.sh (RESILIENT-347) ==="

# ── 1. Source contract ───────────────────────────────────────────────────────
[[ -f "$RECONCILE" ]] || fail "reconcile script missing: $RECONCILE"
[[ -x "$RECONCILE" ]] || fail "reconcile script not executable: $RECONCILE"
bash -n "$RECONCILE" || fail "reconcile bash -n failed"
pass "script present, syntax clean"

# ── 2. Real manifest declares role= / requires= on the previously-churning
#       organs (integrator/backlog-sync-writer/farmer/rot-reaper) ───────────
REAL_MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"
for unit in chump-integrator.timer chump-farmer.timer chump-backlog-sync-writer.timer; do
    line="$(grep -E "^enabled +${unit//./\\.}" "$REAL_MANIFEST")"
    [[ -n "$line" ]] || fail "real manifest missing enabled line for $unit"
    echo "$line" | grep -q 'role=' || fail "real manifest line for $unit has no role="
    echo "$line" | grep -q 'requires=' || fail "real manifest line for $unit has no requires="
done
pass "real organ-manifest.txt declares role+requires on the previously-churning organs"

# ── 2b. RESILIENT-356: the healer itself is a peer-supervised organ ────────
# chump-organ-watchdog.timer heals every OTHER organ; without a manifest line
# for it, chump-organ-reconcile.timer (an independent peer on its own cadence)
# never notices if the watchdog's own timer goes inactive/disabled, so nothing
# restarts the healer. This line is what makes the watchdog "supervised by a
# peer heartbeat" (RESILIENT-356 AC2) — same mechanism as every other organ.
watchdog_line="$(grep -E '^enabled +chump-organ-watchdog\.timer' "$REAL_MANIFEST")"
[[ -n "$watchdog_line" ]] || fail "real manifest missing 'enabled chump-organ-watchdog.timer' — the healer itself is unsupervised"
pass "real organ-manifest.txt declares chump-organ-watchdog.timer as a peer-supervised organ (RESILIENT-356)"

# ── 2c. RESILIENT-360: conflict-resolution consumer is a peer-supervised organ
# The systemd unit/timer shipped in RESILIENT-360's first PR (#4049) but was
# never added to organ-manifest.txt, so armed_pr_needs_conflict_resolution
# signals still had no revivable consumer on CJ — a dead unit would sit dead
# forever since nothing in the manifest told organ-reconcile to keep it alive
# (real-conflict DIRTY PRs #4033/4036/4037/4040/4041 rotted). Without this
# manifest line, this check fails.
crc_line="$(grep -E '^enabled +chump-conflict-resolution-consumer\.timer' "$REAL_MANIFEST")"
[[ -n "$crc_line" ]] || fail "real manifest missing 'enabled chump-conflict-resolution-consumer.timer' — REAL-conflict DIRTY PRs have no revivable consumer"
echo "$crc_line" | grep -q 'role=' || fail "real manifest line for chump-conflict-resolution-consumer.timer has no role="
echo "$crc_line" | grep -q 'requires=' || fail "real manifest line for chump-conflict-resolution-consumer.timer has no requires="
[[ -f "$REPO_ROOT/scripts/dispatch/chump-conflict-resolution-consumer.service" ]] \
    || fail "manifest declares chump-conflict-resolution-consumer.timer but the tracked .service unit is missing"
[[ -f "$REPO_ROOT/scripts/dispatch/chump-conflict-resolution-consumer.timer" ]] \
    || fail "manifest declares chump-conflict-resolution-consumer.timer but the tracked .timer unit is missing"
pass "real organ-manifest.txt declares chump-conflict-resolution-consumer.timer as a peer-supervised organ (RESILIENT-360), tracked units present"

# ── 2d. INFRA-3642 (TREK-16): owned-node factory organs (worker,
# coherence-sync, self-hosted gap-store/postgrest) are peer-supervised ─────
# These ran only as hand-installed units on CJ (chump-worker@1.service,
# chump-cj-sync.timer, chump-postgrest.service) with no organ-manifest.txt
# line — the same "designed/installed but never wired into the revivable
# gate" blind spot RESILIENT-366 closed above; without a manifest line a dead
# unit stays dead forever since organ-reconcile only acts on lines here.
for unit in "chump-worker@1.service" "chump-cj-sync.timer" "chump-postgrest.service"; do
    line="$(grep -E "^enabled +${unit//./\\.}" "$REAL_MANIFEST")"
    [[ -n "$line" ]] || fail "real manifest missing enabled line for $unit (INFRA-3642)"
    echo "$line" | grep -q 'role=' || fail "real manifest line for $unit has no role="
    echo "$line" | grep -q 'requires=' || fail "real manifest line for $unit has no requires="
done
pass "real organ-manifest.txt declares worker/coherence-sync/gap-store as peer-supervised organs (INFRA-3642)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"
CALL_LOG="$TMP/calls.log"
ACTIVE_FILE="$STATE_DIR/active.txt"
ENABLE_FAIL_FILE="$STATE_DIR/enable_fail.txt"
VERIFY_FAIL_FILE="$STATE_DIR/verify_fail.txt"
touch "$ACTIVE_FILE" "$ENABLE_FAIL_FILE" "$VERIFY_FAIL_FILE"

STUB="$TMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    enable)
        # enable --now UNIT
        unit="${@: -1}"
        if grep -qxF "$unit" "$ENABLE_FAIL_FILE" 2>/dev/null; then
            exit 1
        fi
        if grep -qxF "$unit" "$VERIFY_FAIL_FILE" 2>/dev/null; then
            # enable itself "succeeds" but the unit never shows active — the
            # oneshot-fails-inside-ExecStart case organ-reconcile must verify.
            exit 0
        fi
        echo "$unit" >> "$ACTIVE_FILE"
        exit 0
        ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" 2>/dev/null
        mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE" 2>/dev/null || true
        exit 0
        ;;
    stop|daemon-reload)
        exit 0
        ;;
    show)
        echo "ExecStart=/bin/true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB"

BACKOFF_DIR="$TMP/organ-backoff"
AMBIENT="$TMP/ambient.jsonl"

run_reconcile() {  # mode
    : > "$CALL_LOG"
    STATE_DIR="$STATE_DIR" CALL_LOG="$CALL_LOG" \
    ACTIVE_FILE="$ACTIVE_FILE" ENABLE_FAIL_FILE="$ENABLE_FAIL_FILE" VERIFY_FAIL_FILE="$VERIFY_FAIL_FILE" \
    CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
    CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
    CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
    CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S=3600 \
    CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
    CHUMP_ORGAN_MANIFEST="$MANIFEST" \
    NODE_AMBIENT="$AMBIENT" \
    PATH="$TMP/bins:$PATH" \
    bash "$RECONCILE" "$1"
}

mkdir -p "$TMP/bins"

# ── 3. requires=bin:<missing> → SKIP, never attempted, --check treats it as
#       applicability-N/A rather than DRIFT ─────────────────────────────────
MANIFEST="$TMP/manifest-notapplicable.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-fake-organ.service  role=muscle requires=bin:chump-fake-binary-that-does-not-exist
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"

out="$(run_reconcile --check)"
echo "$out" | grep -q "SKIP.*chump-fake-organ.service.*not applicable" \
    || fail "--check must report an unmet requires= as SKIP not-applicable; got: $out"
echo "$out" | grep -q "DRIFT" && fail "--check must NOT flag a not-applicable organ as DRIFT; got: $out"

: > "$AMBIENT"
run_reconcile --apply >/dev/null
grep -q "enable --now chump-fake-organ.service" "$CALL_LOG" \
    && fail "reconcile must NEVER attempt enable on an organ whose requires= is unmet; calls: $(cat "$CALL_LOG")"
grep -q '"kind":"organ_reconcile_not_applicable"' "$AMBIENT" \
    || fail "expected organ_reconcile_not_applicable in ambient; got: $(cat "$AMBIENT")"
pass "3: unmet requires= → organ is SKIPPED, never attempted (curated per-node, not blast-all)"

# ── 4. applicable + enable succeeds + verifies active → started, no backoff ──
MANIFEST="$TMP/manifest-ok.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-good-organ.service  role=brain requires=bin:chump-good-binary
EOF
cat > "$TMP/bins/chump-good-binary" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bins/chump-good-binary"
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
grep -q "enable --now chump-good-organ.service" "$CALL_LOG" \
    || fail "expected an enable --now attempt for the applicable+healthy organ"
grep -qxF "chump-good-organ.service" "$ACTIVE_FILE" \
    || fail "organ should have been started (present in stub's active set)"
[[ -f "$BACKOFF_DIR/chump-good-organ.service.json" ]] \
    && fail "a successfully-started organ must not have a backoff record"
pass "4: applicable + healthy organ starts normally, no backoff recorded"

# ── 5. applicable but enable fails → backed off (disabled, cooldown-recorded)
#       AND the second reconcile cycle does NOT re-attempt it (churn proof) ─
MANIFEST="$TMP/manifest-fail.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-broken-organ.service  role=muscle requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"
echo "chump-broken-organ.service" > "$ENABLE_FAIL_FILE"
: > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
[[ -f "$BACKOFF_DIR/chump-broken-organ.service.json" ]] \
    || fail "a failed-to-enable organ must be recorded in backoff"
grep -q '"kind":"organ_reconcile_backoff"' "$AMBIENT" \
    || fail "expected organ_reconcile_backoff in ambient; got: $(cat "$AMBIENT")"
first_call_count="$(grep -c "enable --now chump-broken-organ.service" "$CALL_LOG")"
[[ "$first_call_count" -ge 1 ]] || fail "expected at least one enable attempt on the first cycle"

# Second cycle, same cooldown window: must skip re-attempting the enable —
# this is the exact churn (re-install-every-cycle) RESILIENT-347 kills.
run_reconcile --apply >/dev/null
grep -q "enable --now chump-broken-organ.service" "$CALL_LOG" \
    && fail "second reconcile cycle within backoff cooldown must NOT re-attempt enable; calls: $(cat "$CALL_LOG")"
grep -q '"kind":"organ_reconcile_backoff_skip"' "$AMBIENT" \
    || fail "expected organ_reconcile_backoff_skip on the cooled-down cycle; got: $(cat "$AMBIENT")"
pass "5: enable failure -> backoff recorded; SECOND cycle skips re-attempt entirely (no per-cycle churn)"

# ── 6. applicable + enable succeeds but never verifies active → backoff too ─
MANIFEST="$TMP/manifest-verifyfail.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-flaky-organ.service  role=data requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"
echo "chump-flaky-organ.service" > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
[[ -f "$BACKOFF_DIR/chump-flaky-organ.service.json" ]] \
    || fail "an enable-ok-but-never-active organ must be backed off after verify fails"
grep -q "disable --now chump-flaky-organ.service" "$CALL_LOG" \
    || fail "verify-failed organ must be disabled (stop churning), not left half-enabled"
pass "6: enable succeeds but unit never verifies active -> disabled + backed off (not left churning)"

# ── 7. backoff cooldown expiry retries the organ ─────────────────────────────
MANIFEST="$TMP/manifest-retry.txt"
cat > "$MANIFEST" <<EOF
enabled  chump-recovered-organ.service  role=muscle requires=bin:chump-good-binary
EOF
: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"
rm -rf "$BACKOFF_DIR"; mkdir -p "$BACKOFF_DIR"
old_since=$(( $(date +%s) - 999999 ))
printf '{"unit":"chump-recovered-organ.service","since":%d,"reason":"enable_failed"}\n' "$old_since" \
    > "$BACKOFF_DIR/chump-recovered-organ.service.json"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
grep -q "enable --now chump-recovered-organ.service" "$CALL_LOG" \
    || fail "an EXPIRED backoff must allow the organ to be retried"
grep -qxF "chump-recovered-organ.service" "$ACTIVE_FILE" \
    || fail "the retried organ should have started successfully this time"
pass "7: expired backoff cooldown retries the organ (not a permanent disable)"

# ── 8. INFRA-3642: kill-then-reconcile proof for the REAL manifest lines of
#       the owned-node factory organs — extract the ACTUAL declared lines
#       (not a hand-typed copy) so this proves organ-reconcile treats each as
#       applicable on a node with their dependency binaries present, and
#       re-enables each one when found inactive ("killed").
MANIFEST="$TMP/manifest-owned-node.txt"
: > "$MANIFEST"
for unit in "chump-worker@1.service" "chump-cj-sync.timer" "chump-postgrest.service"; do
    grep -E "^enabled +${unit//./\\.}" "$REAL_MANIFEST" >> "$MANIFEST"
done
[[ -s "$MANIFEST" ]] || fail "could not extract owned-node organ lines from real manifest for kill-then-reconcile"

mkdir -p "$TMP/bins"
for bin in chump git postgrest; do
    cat > "$TMP/bins/$bin" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$TMP/bins/$bin"
done

: > "$ACTIVE_FILE"; : > "$ENABLE_FAIL_FILE"; : > "$VERIFY_FAIL_FILE"   # all three start "killed" (inactive)
rm -rf "$BACKOFF_DIR"
: > "$AMBIENT"

run_reconcile --apply >/dev/null
for unit in "chump-worker@1.service" "chump-cj-sync.timer" "chump-postgrest.service"; do
    grep -q "enable --now $unit" "$CALL_LOG" \
        || fail "kill-then-reconcile: $unit's requires= are satisfied but reconcile never attempted to enable it"
    grep -qxF "$unit" "$ACTIVE_FILE" \
        || fail "kill-then-reconcile: $unit was killed (inactive) but reconcile did not re-enable it"
    [[ -f "$BACKOFF_DIR/${unit}.json" ]] \
        && fail "kill-then-reconcile: $unit should have started cleanly, not backed off"
done
pass "8: kill-then-reconcile — worker/coherence-sync/gap-store organs are applicable when their dependency binaries are present and get re-enabled when found inactive (INFRA-3642)"

# ── 9. INFRA-7838: organ_registry_parse / organ_registry_check / the
#       --check-process-organs CLI mode. These read scripts/ops/organ-registry.txt
#       (INFRA-7586's generated CJ process-organ registry, launcher=/pgrep=/
#       heartbeat= format) — a file that was generated and CI-shape-tested but
#       never actually PARSED by any live loop until this gap.
REAL_PROCESS_REGISTRY="$REPO_ROOT/scripts/ops/organ-registry.txt"
[[ -f "$REAL_PROCESS_REGISTRY" ]] || fail "scripts/ops/organ-registry.txt missing — generate via scripts/ops/generate-organ-registry.sh"

# The pgrep pattern must be findable in a real process's argv (pgrep -f
# matches the command line, not environment variables) — so the "alive"
# fixture is a uniquely-named throwaway script file, backgrounded via `bash
# <path>`, whose path itself is the pgrep=/detector pattern.
MARKER_SCRIPT="$TMP/organ-reconcile-test-marker-$$.sh"
cat > "$MARKER_SCRIPT" <<'EOF'
sleep 9999
EOF
bash "$MARKER_SCRIPT" &
SLEEP_PID=$!
trap 'kill "$SLEEP_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

# 9a. A synthetic registry with one ALIVE and one DEAD organ parses without
#     error and reports each correctly via --check-process-organs.
FAKE_REGISTRY="$TMP/fake-organ-registry.txt"
cat > "$FAKE_REGISTRY" <<EOF
# synthetic registry for test-organ-reconcile.sh section 9
enabled  fake-alive-organ  launcher=~/.chump/organs/fake-alive-organ.sh  pgrep=$MARKER_SCRIPT  heartbeat=60  # wraps a test fixture
enabled  fake-dead-organ   launcher=~/.chump/organs/fake-dead-organ.sh   pgrep=organ-reconcile-test-definitely-not-running-$$  heartbeat=60  # wraps a test fixture
EOF

check_out="$(CHUMP_PROCESS_ORGAN_REGISTRY_FILE="$FAKE_REGISTRY" bash "$RECONCILE" --check-process-organs 2>&1)"
check_rc=$?

echo "$check_out" | grep -q 'DETECTED-ALIVE: fake-alive-organ' \
    || fail "organ_registry_check: fake-alive-organ should have been DETECTED-ALIVE — got: $check_out"
echo "$check_out" | grep -q 'DETECTED-DEAD: fake-dead-organ' \
    || fail "organ_registry_check: fake-dead-organ should have been DETECTED-DEAD — got: $check_out"
[[ "$check_rc" -eq 1 ]] || fail "--check-process-organs should exit 1 when any organ is DETECTED-DEAD (got rc=$check_rc)"
pass "9a: organ_registry_parse/organ_registry_check correctly distinguish alive vs dead organs, --check-process-organs exits 1"

# 9b. A registry with only alive organs exits 0.
ALL_ALIVE_REGISTRY="$TMP/fake-organ-registry-alive.txt"
cat > "$ALL_ALIVE_REGISTRY" <<EOF
enabled  fake-alive-organ  launcher=~/.chump/organs/fake-alive-organ.sh  pgrep=$MARKER_SCRIPT  heartbeat=60  # wraps a test fixture
EOF
alive_rc=0
CHUMP_PROCESS_ORGAN_REGISTRY_FILE="$ALL_ALIVE_REGISTRY" bash "$RECONCILE" --check-process-organs >/dev/null 2>&1 || alive_rc=$?
[[ "$alive_rc" -eq 0 ]] || fail "--check-process-organs should exit 0 when every organ is DETECTED-ALIVE (got rc=$alive_rc)"
pass "9b: --check-process-organs exits 0 when every registered organ is alive"

# 9c. Missing registry exits 2, not a hard crash.
missing_rc=0
CHUMP_PROCESS_ORGAN_REGISTRY_FILE="$TMP/does-not-exist.txt" bash "$RECONCILE" --check-process-organs >/dev/null 2>&1 || missing_rc=$?
[[ "$missing_rc" -eq 2 ]] || fail "--check-process-organs should exit 2 for a missing registry (got rc=$missing_rc)"
pass "9c: --check-process-organs exits 2 for a missing registry file"

# 9d. The REAL organ-registry.txt (generated by generate-organ-registry.sh)
#     parses without error against the new helper — proves AC5 (no parse
#     errors) against production content, not just a synthetic fixture.
real_check_rc=0
bash "$RECONCILE" --check-process-organs >/dev/null 2>&1 || real_check_rc=$?
[[ "$real_check_rc" -ne 2 ]] || fail "organ_registry_parse failed to parse the real scripts/ops/organ-registry.txt without error"
pass "9d: the real scripts/ops/organ-registry.txt parses cleanly via organ_registry_parse (AC5)"

echo "ALL PASS"
