#!/usr/bin/env bash
# scripts/ci/test-resilient-1230-duty-officer-persistent-escalation.sh
#
# RESILIENT-1230: a live 13h dark-out was rationalized by duty-officer-loop.sh
# as tier:1 verdict:healed 57x with 0 pages, and chump-fleet-health-sentinel
# (the healer-of-healers) sat in a failed state, unwatched. This test proves:
#   1. a T1 signal (e.g. worker_circuit_open) firing below the escalation
#      threshold still routes to verdict:healed (no regression).
#   2. a T1 signal firing at/above the threshold within the scan window
#      escalates T1->T3, emits verdict:paged, and pages the operator.
#   3. an active health-sentinel unit is reported healed and never pages.
#   4. a failed health-sentinel unit that revives on reset-failed+start is
#      reported healed (with the revival action recorded) and never pages.
#   5. a failed health-sentinel unit that CANNOT be revived escalates to T3,
#      emits verdict:paged, and pages the operator.
#
# Self-contained: stubs systemctl via CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD and
# notify via CHUMP_DUTY_OFFICER_NOTIFY_CMD. No real fleet state is mutated.

set -uo pipefail   # NOT -e: we check exit codes explicitly

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LOOP="$REPO_ROOT/scripts/coord/duty-officer-loop.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

_check() { # _check <label> <expected_exit> <actual_exit>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s (exit %s)\n' "$1" "$3"; PASS=$((PASS+1))
    else printf '  FAIL %s (expected exit %s, got %s)\n' "$1" "$2" "$3"; FAIL=$((FAIL+1)); fi
}
_emitted() { # _emitted <label> <ambient_file> <grep-ERE>
    if grep -qE "$3" "$2" 2>/dev/null; then printf '  ok   %s\n' "$1"; PASS=$((PASS+1))
    else printf '  FAIL %s (no match /%s/ in %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
_not_emitted() { # _not_emitted <label> <ambient_file> <grep-ERE>
    if grep -qE "$3" "$2" 2>/dev/null; then printf '  FAIL %s (unexpected match /%s/ in %s)\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
    else printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); fi
}

[[ -x "$LOOP" ]] || { printf 'FATAL: %s not found or not executable\n' "$LOOP" >&2; exit 1; }

echo "[test-1230] T1 — worker_circuit_open below threshold still heals (no regression)"
A="$TMP/below.jsonl"
for i in 1 2 3; do printf '{"ts":"x","kind":"worker_circuit_open"}\n' >> "$A"; done
NOTIFIED="$TMP/n_below.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_T1_ESCALATE_THRESHOLD=10 \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" route worker_circuit_open >/dev/null 2>&1 || rc=$?
_check "below-threshold route exits 0" 0 "$rc"
_emitted "below-threshold emits tier:1 verdict:healed" "$A" '"kind":"duty_officer_action".*"signal":"worker_circuit_open".*"tier":1,"verdict":"healed"'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL below-threshold must NOT page\n'; FAIL=$((FAIL+1))
else printf '  ok   below-threshold did not page\n'; PASS=$((PASS+1)); fi

echo "[test-1230] T1 — worker_circuit_open at/above threshold escalates T1->T3 and pages"
A="$TMP/above.jsonl"
for i in $(seq 1 12); do printf '{"ts":"x","kind":"worker_circuit_open"}\n' >> "$A"; done
NOTIFIED="$TMP/n_above.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_T1_ESCALATE_THRESHOLD=10 \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" route worker_circuit_open >/dev/null 2>&1 || rc=$?
_check "above-threshold route exits 0" 0 "$rc"
_emitted "above-threshold emits tier:3 verdict:paged" "$A" '"kind":"duty_officer_action".*"signal":"worker_circuit_open".*"tier":3,"verdict":"paged"'
_not_emitted "above-threshold does NOT emit verdict:healed" "$A" '"verdict":"healed"'
if [[ -s "$NOTIFIED" ]]; then printf '  ok   above-threshold paged the operator\n'; PASS=$((PASS+1))
else printf '  FAIL above-threshold must page (this is the RESILIENT-1230 bug: 57x healed, 0 pages)\n'; FAIL=$((FAIL+1)); fi

echo "[test-1230] watch-sentinel — active unit reports healed, never pages"
A="$TMP/sentinel_active.jsonl"; : > "$A"
NOTIFIED="$TMP/n_sa.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="true" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "active sentinel watch exits 0" 0 "$rc"
_emitted "active sentinel emits tier:1 verdict:healed" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":1,"verdict":"healed"'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL active sentinel must NOT page\n'; FAIL=$((FAIL+1))
else printf '  ok   active sentinel did not page\n'; PASS=$((PASS+1)); fi

echo "[test-1230] watch-sentinel — failed unit that revives on restart reports healed"
STUB="$TMP/systemctl-revives.sh"
cat > "$STUB" <<'EOS'
#!/usr/bin/env bash
STATE_FILE="${SENTINEL_STUB_STATE:?}"
case "$1" in
    is-active) [[ "$(cat "$STATE_FILE" 2>/dev/null)" == "active" ]] && exit 0 || exit 3 ;;
    reset-failed) exit 0 ;;
    start) echo active > "$STATE_FILE"; exit 0 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$STUB"
A="$TMP/sentinel_revives.jsonl"; : > "$A"
NOTIFIED="$TMP/n_sr.txt"; : > "$NOTIFIED"
STATE_FILE="$TMP/sentinel_state"; echo failed > "$STATE_FILE"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="$STUB" \
    SENTINEL_STUB_STATE="$STATE_FILE" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "revives sentinel watch exits 0" 0 "$rc"
_emitted "revived sentinel emits tier:1 verdict:healed with revival action" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":1,"verdict":"healed".*reset-failed\+start'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL revived sentinel must NOT page\n'; FAIL=$((FAIL+1))
else printf '  ok   revived sentinel did not page\n'; PASS=$((PASS+1)); fi

echo "[test-1230] watch-sentinel — failed unit that CANNOT be revived escalates to T3 and pages"
STUB2="$TMP/systemctl-stuck.sh"
cat > "$STUB2" <<'EOS'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 3 ;;
    reset-failed) exit 0 ;;
    start) exit 1 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$STUB2"
A="$TMP/sentinel_stuck.jsonl"; : > "$A"
NOTIFIED="$TMP/n_ss.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="$STUB2" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "stuck sentinel watch exits 0" 0 "$rc"
_emitted "stuck sentinel emits tier:3 verdict:paged" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":3,"verdict":"paged"'
if [[ -s "$NOTIFIED" ]]; then printf '  ok   stuck sentinel paged the operator (healer-of-healers must be watched)\n'; PASS=$((PASS+1))
else printf '  FAIL stuck sentinel must page\n'; FAIL=$((FAIL+1)); fi

echo
printf '[test-1230] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-1230] PASS"
