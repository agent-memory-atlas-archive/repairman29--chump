#!/usr/bin/env bash
# scripts/ci/test-duty-officer-loop.sh — RESILIENT-274 smoke test for duty-officer-loop.sh
#
# Self-contained: exercises T1/T2/T3 routing against the real
# docs/process/PLAYBOOK_REGISTRY.yaml (signal names must stay in sync — that
# coupling is intentional, it catches registry/loop drift) with a synthetic
# ambient log and stubbed reality-check/notify commands. No real fleet state
# is mutated; runs offline in well under a second.

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

[[ -x "$LOOP" ]] || { printf 'FATAL: %s not found or not executable\n' "$LOOP" >&2; exit 1; }

echo "[test-duty-officer] subcommand contract"
rc=0; bash "$LOOP" help    >/dev/null 2>&1 || rc=$?; _check "help exits 0" 0 "$rc"
rc=0; bash "$LOOP" bogus   >/dev/null 2>&1 || rc=$?; _check "bad subcommand exits 2" 2 "$rc"

HB="$TMP/hb.jsonl"; : > "$HB"
rc=0; CHUMP_AMBIENT_LOG="$HB" bash "$LOOP" heartbeat >/dev/null 2>&1 || rc=$?
_check "heartbeat exits 0" 0 "$rc"
_emitted "heartbeat emits duty_officer_heartbeat" "$HB" '"kind":"duty_officer_heartbeat"'

echo "[test-duty-officer] T1 — disk_critical routes to healed"
A="$TMP/t1.jsonl"; : > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" bash "$LOOP" route disk_critical >/dev/null 2>&1 || rc=$?
_check "T1 route exits 0" 0 "$rc"
_emitted "T1 emits tier:1 verdict:healed" "$A" '"kind":"duty_officer_action".*"tier":1,"verdict":"healed"'

echo "[test-duty-officer] T2 — fleet_wedge (no false_positive_class) routes to runbook_needed"
A="$TMP/t2.jsonl"; : > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" bash "$LOOP" route fleet_wedge >/dev/null 2>&1 || rc=$?
_check "T2 route exits 0" 0 "$rc"
_emitted "T2 emits tier:2 verdict:runbook_needed" "$A" '"kind":"duty_officer_action".*"tier":2,"verdict":"runbook_needed"'

echo "[test-duty-officer] T2 — pr_pipeline_wedged with reality-check REFUTED drops the signal"
A="$TMP/t2b.jsonl"; : > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_REALITY_CHECK_CMD='false' \
    bash "$LOOP" route pr_pipeline_wedged >/dev/null 2>&1 || rc=$?
_check "T2 refuted route exits 0" 0 "$rc"
_emitted "T2 emits verdict:refuted" "$A" '"kind":"duty_officer_action".*"verdict":"refuted"'

echo "[test-duty-officer] T3 — farmer_auth_dead is quiet-gate suppressed, never pages"
A="$TMP/t3a.jsonl"; : > "$A"
NOTIFIED="$TMP/notified.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" route farmer_auth_dead >/dev/null 2>&1 || rc=$?
_check "T3 suppressed route exits 0" 0 "$rc"
_emitted "T3 emits verdict:suppressed" "$A" '"kind":"duty_officer_action".*"verdict":"suppressed"'
if [[ -s "$NOTIFIED" ]]; then printf '  FAIL suppressed signal must NOT page\n'; FAIL=$((FAIL+1))
else printf '  ok   suppressed signal did not page\n'; PASS=$((PASS+1)); fi

echo "[test-duty-officer] T3 — unregistered signal defaults to page (novel = loud)"
A="$TMP/t3b.jsonl"; : > "$A"
NOTIFIED="$TMP/notified2.txt"; : > "$NOTIFIED"
rc=0; CHUMP_AMBIENT_LOG="$A" CHUMP_DUTY_OFFICER_NOTIFY_CMD="echo notified >> $NOTIFIED #" \
    bash "$LOOP" route some_totally_novel_signal >/dev/null 2>&1 || rc=$?
_check "T3 unregistered route exits 0" 0 "$rc"
_emitted "T3 emits verdict:unregistered" "$A" '"kind":"duty_officer_action".*"verdict":"unregistered"'
if [[ -s "$NOTIFIED" ]]; then printf '  ok   unregistered signal paged\n'; PASS=$((PASS+1))
else printf '  FAIL unregistered signal must page\n'; FAIL=$((FAIL+1)); fi

echo "[test-duty-officer] tick — scans ambient window and routes every registered kind seen"
A="$TMP/tick.jsonl"
printf '{"ts":"x","kind":"disk_critical"}\n{"ts":"x","kind":"some_unrelated_kind_not_in_registry"}\n' > "$A"
rc=0; CHUMP_AMBIENT_LOG="$A" bash "$LOOP" tick >/dev/null 2>&1 || rc=$?
_check "tick exits 0" 0 "$rc"
_emitted "tick routes disk_critical" "$A" '"kind":"duty_officer_action".*"signal":"disk_critical"'
if grep -q '"signal":"some_unrelated_kind_not_in_registry"' "$A"; then
    printf '  FAIL tick must not route unregistered ambient noise\n'; FAIL=$((FAIL+1))
else
    printf '  ok   tick ignored unregistered ambient noise\n'; PASS=$((PASS+1))
fi

echo "[test-duty-officer] status reflects registry signal count"
out="$(bash "$LOOP" status 2>&1)"
if echo "$out" | grep -qE 'registered signals: [0-9]+'; then
    printf '  ok   status prints registered signal count\n'; PASS=$((PASS+1))
else
    printf '  FAIL status did not print a signal count\n'; FAIL=$((FAIL+1))
fi

echo "[test-duty-officer] RESILIENT-1297 — user-bus env fallback populates unset vars"
out="$(env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS bash -c \
    "source '$LOOP' >/dev/null 2>&1; printf '%s|%s' \"\$XDG_RUNTIME_DIR\" \"\$DBUS_SESSION_BUS_ADDRESS\"")"
xdg="${out%%|*}"; dbus="${out##*|}"
if [[ "$xdg" == "/run/user/$(id -u)" ]]; then
    printf '  ok   XDG_RUNTIME_DIR fallback derived from UID (%s)\n' "$xdg"; PASS=$((PASS+1))
else
    printf '  FAIL XDG_RUNTIME_DIR fallback wrong (got %s)\n' "$xdg"; FAIL=$((FAIL+1))
fi
if [[ "$dbus" == "unix:path=/run/user/$(id -u)/bus" ]]; then
    printf '  ok   DBUS_SESSION_BUS_ADDRESS fallback derived from UID (%s)\n' "$dbus"; PASS=$((PASS+1))
else
    printf '  FAIL DBUS_SESSION_BUS_ADDRESS fallback wrong (got %s)\n' "$dbus"; FAIL=$((FAIL+1))
fi

echo "[test-duty-officer] RESILIENT-1297 — pre-set vars are left unchanged"
out="$(XDG_RUNTIME_DIR=/run/user/9999 DBUS_SESSION_BUS_ADDRESS='unix:path=/custom/bus' bash -c \
    "source '$LOOP' >/dev/null 2>&1; printf '%s|%s' \"\$XDG_RUNTIME_DIR\" \"\$DBUS_SESSION_BUS_ADDRESS\"")"
xdg="${out%%|*}"; dbus="${out##*|}"
if [[ "$xdg" == "/run/user/9999" && "$dbus" == "unix:path=/custom/bus" ]]; then
    printf '  ok   pre-set user-bus env left unchanged\n'; PASS=$((PASS+1))
else
    printf '  FAIL pre-set user-bus env was overwritten (got %s|%s)\n' "$xdg" "$dbus"; FAIL=$((FAIL+1))
fi

echo
printf '[test-duty-officer] %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "[test-duty-officer] PASS"
