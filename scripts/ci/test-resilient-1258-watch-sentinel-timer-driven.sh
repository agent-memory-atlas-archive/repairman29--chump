#!/usr/bin/env bash
# scripts/ci/test-resilient-1258-watch-sentinel-timer-driven.sh
#
# RESILIENT-1258: watch-sentinel checked is-active on the sentinel .SERVICE,
# but chump-fleet-health-sentinel is a TIMER-driven oneshot whose .service is
# CORRECTLY inactive between runs. That false-positived "dead" every tick,
# causing reset-failed+start spam and a T3 could-not-revive page even while
# the .timer was active and firing every 5min. This test proves:
#   1. .service inactive + .timer active -> healed, NO revive attempt, NO page
#      (this is the exact false-positive scenario from the bug report).
#   2. .service failed + .timer active -> still healed, NO page (service
#      failure alone must not page as long as the timer is armed).
#   3. .timer failed/dead -> revive attempted on the TIMER; if it comes back,
#      healed; if not, T3 page (the real outage case is preserved).
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

echo "[test-1258] watch-sentinel — .service inactive (oneshot idle) + .timer active -> healed, no page"
STUB1="$TMP/systemctl-service-idle.sh"
cat > "$STUB1" <<'EOS'
#!/usr/bin/env bash
# is-active <unit>: the SERVICE (no .timer suffix) is inactive (oneshot idle
# between runs, as chump-fleet-health-sentinel.service correctly is); the
# TIMER (*.timer) is active and firing.
case "$1" in
    is-active)
        case "$2" in
            *.timer) exit 0 ;;
            *) exit 3 ;;
        esac
        ;;
    reset-failed) exit 0 ;;
    start) exit 0 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$STUB1"
A="$TMP/sentinel_service_idle.jsonl"; : > "$A"
NOTIFIED="$TMP/n_si.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="$STUB1" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "service-idle+timer-active watch exits 0" 0 "$rc"
_emitted "service-idle+timer-active emits tier:1 verdict:healed" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":1,"verdict":"healed"'
_not_emitted "service-idle+timer-active does NOT emit reset-failed+start (no needless revive)" "$A" 'action=reset-failed\+start'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL service-idle+timer-active must NOT page (this is the RESILIENT-1258 false-positive)\n'; FAIL=$((FAIL+1))
else printf '  ok   service-idle+timer-active did not page\n'; PASS=$((PASS+1)); fi

echo "[test-1258] watch-sentinel — .service failed + .timer active -> still healed, no page"
STUB2="$TMP/systemctl-service-failed.sh"
cat > "$STUB2" <<'EOS'
#!/usr/bin/env bash
case "$1" in
    is-active)
        case "$2" in
            *.timer) exit 0 ;;
            *) exit 3 ;;
        esac
        ;;
    reset-failed) exit 0 ;;
    start) exit 0 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$STUB2"
A="$TMP/sentinel_service_failed.jsonl"; : > "$A"
NOTIFIED="$TMP/n_sf.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="$STUB2" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "service-failed+timer-active watch exits 0" 0 "$rc"
_emitted "service-failed+timer-active emits tier:1 verdict:healed" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":1,"verdict":"healed"'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL service-failed+timer-active must NOT page\n'; FAIL=$((FAIL+1))
else printf '  ok   service-failed+timer-active did not page\n'; PASS=$((PASS+1)); fi

echo "[test-1258] watch-sentinel — .timer dead/stalled -> revive attempted on timer; still dead -> T3 page"
STUB3="$TMP/systemctl-timer-dead.sh"
cat > "$STUB3" <<'EOS'
#!/usr/bin/env bash
case "$1" in
    is-active) exit 3 ;;
    reset-failed) exit 0 ;;
    start) exit 1 ;;
    *) exit 0 ;;
esac
EOS
chmod +x "$STUB3"
A="$TMP/sentinel_timer_dead.jsonl"; : > "$A"
NOTIFIED="$TMP/n_td.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD="$STUB3" \
    CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" watch-sentinel >/dev/null 2>&1 || rc=$?
_check "timer-dead watch exits 0" 0 "$rc"
_emitted "timer-dead emits tier:3 verdict:paged mentioning timer" "$A" '"kind":"duty_officer_action".*"signal":"chump_fleet_health_sentinel".*"tier":3,"verdict":"paged".*timer='
if [[ -s "$NOTIFIED" ]]; then printf '  ok   timer-dead paged the operator (real outage still caught)\n'; PASS=$((PASS+1))
else printf '  FAIL timer-dead must page\n'; FAIL=$((FAIL+1))
fi

echo
printf '[test-1258] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-1258] PASS"
