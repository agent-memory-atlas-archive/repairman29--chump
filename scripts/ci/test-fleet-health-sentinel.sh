#!/usr/bin/env bash
# scripts/ci/test-fleet-health-sentinel.sh — RESILIENT-1052
#
# Depth: EDGE (hermetic). Exercises the sentinel's real detect/act/page logic
# against a scriptable FAKE systemctl (no live units, no ssh, no Discord), so
# CI proves the exact behavior the live fleet needs:
#   - a failed chump unit is detected and reset-failed+restarted (self-heal)
#   - an inactive present healer is re-enabled (self-heal)
#   - an ABSENT required healer is detected and PAGED (cannot self-heal)
#   - a stale sentinel heartbeat is detected by --fleet and PAGED (peer dead)
#   - dry-run detects but never heals or pages
# GAPS (not covered here, covered by the live demonstrations in the PR):
#   real systemd semantics, real ssh reachability, real notify_operator DM.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SENTINEL="$REPO_ROOT/scripts/ops/fleet-health-sentinel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_STATE="$TMP/units.state"     # lines: <unit>=<active|inactive|failed|absent>
FAKE_BIN="$TMP/bin"; mkdir -p "$FAKE_BIN"

# ── fake systemctl ───────────────────────────────────────────────────────────
cat > "$FAKE_BIN/systemctl" <<'FAKE'
#!/usr/bin/env bash
S="$FAKE_STATE"
get(){ grep -m1 "^$1=" "$S" 2>/dev/null | cut -d= -f2; }
set_(){ grep -v "^$1=" "$S" 2>/dev/null > "$S.tmp"; echo "$1=$2" >> "$S.tmp"; mv "$S.tmp" "$S"; }
cmd="$1"; shift || true
case "$cmd" in
  list-units)
    # args include a glob + --state=failed --all --no-legend
    want_failed=0; for a in "$@"; do [ "$a" = "--state=failed" ] && want_failed=1; done
    while IFS='=' read -r u st; do
      [ -z "$u" ] && continue
      case "$u" in chump-*) ;; *) continue;; esac
      if [ "$want_failed" = 1 ]; then
        [ "$st" = failed ] && echo "● $u loaded failed failed desc"
      else
        echo "$u loaded $st $st desc"
      fi
    done < "$S" ;;
  list-unit-files)
    unit="$1"; st="$(get "$unit")"
    [ -n "$st" ] && [ "$st" != absent ] && echo "$unit enabled enabled" ;;
  cat) unit="$1"; st="$(get "$unit")"; { [ -n "$st" ] && [ "$st" != absent ]; } && echo "# $unit" || exit 1 ;;
  is-active) unit="$1"; st="$(get "$unit")"; [ -z "$st" ] && st=inactive; [ "$st" = absent ] && st=inactive; echo "$st"; [ "$st" = active ] || exit 3 ;;
  reset-failed) unit="$1"; [ "$(get "$unit")" = failed ] && set_ "$unit" inactive; exit 0 ;;
  restart)  # a unit named in FAKE_STUCK fails again immediately (unhealable)
    if [ -n "${FAKE_STUCK:-}" ] && [ "$1" = "$FAKE_STUCK" ]; then set_ "$1" failed; else set_ "$1" active; fi
    exit 0 ;;
  start)    exit 0 ;;
  enable)   # enable --now <unit>
    for a in "$@"; do case "$a" in --now|--user) ;; *) unit="$a";; esac; done
    [ "$(get "$unit")" = absent ] && exit 1
    set_ "$unit" active; exit 0 ;;
  daemon-reload|list-timers) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$FAKE_BIN/systemctl"

export FAKE_STATE
export CHUMP_SYSTEMCTL="$FAKE_BIN/systemctl"
export CHUMP_STATE_DIR="$TMP/state"; mkdir -p "$CHUMP_STATE_DIR"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_SENTINEL_PAGE_SINK="$TMP/pages.tsv"
# keep required set tight + deterministic for the test
export CHUMP_SENTINEL_REQUIRED_HEALERS="chump-node-refresh.timer chump-fleet-health-sentinel.timer"
export CHUMP_SENTINEL_WATCHED_HEALERS="organ-watchdog.timer"

FAILS=0
ok(){ echo "  ok: $1"; }
bad(){ echo "  FAIL: $1"; FAILS=$((FAILS+1)); }
has(){ grep -q "$1" "$2" 2>/dev/null; }

seed(){ cat > "$FAKE_STATE" <<EOF
chump-foo.service=failed
chump-node-refresh.timer=inactive
chump-fleet-health-sentinel.timer=absent
organ-watchdog.timer=inactive
EOF
}

echo "== case 1: --dry-run detects but does NOT heal or page =="
seed; : > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
out="$(bash "$SENTINEL" --local --dry-run 2>&1)"
echo "$out" | grep -q "FAILED unit: chump-foo.service" && ok "detected failed unit" || bad "missed failed unit"
echo "$out" | grep -q "HEALER inactive: chump-node-refresh.timer" && ok "detected inactive healer" || bad "missed inactive healer"
echo "$out" | grep -q "HEALER ABSENT: chump-fleet-health-sentinel.timer" && ok "detected absent healer" || bad "missed absent healer"
[ ! -s "$CHUMP_SENTINEL_PAGE_SINK" ] && ok "no page in dry-run" || bad "dry-run paged"
has "fleet_health_self_healed" "$CHUMP_AMBIENT_LOG" && bad "dry-run self-healed" || ok "no self-heal in dry-run"
# unit must still be failed after dry-run
[ "$(grep chump-foo.service "$FAKE_STATE")" = "chump-foo.service=failed" ] && ok "unit untouched by dry-run" || bad "dry-run mutated unit"

echo "== case 2: real --local heals failed unit + inactive healer, pages absent healer =="
seed; : > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
bash "$SENTINEL" --local >/dev/null 2>&1
grep -q "chump-foo.service=active" "$FAKE_STATE" && ok "failed unit restarted to active" || bad "failed unit not healed"
has '"kind":"fleet_health_self_healed".*chump-foo.service' "$CHUMP_AMBIENT_LOG" && ok "emitted self_healed for unit" || bad "no self_healed for unit"
grep -q "chump-node-refresh.timer=active" "$FAKE_STATE" && ok "inactive healer re-enabled" || bad "healer not re-enabled"
grep -q "organ-watchdog.timer=active" "$FAKE_STATE" && ok "watched healer re-enabled" || bad "watched healer not re-enabled"
has "fleet_health_healer_down" "$CHUMP_SENTINEL_PAGE_SINK" && ok "PAGED absent required healer" || bad "did not page absent healer"
has "chump-fleet-health-sentinel.timer" "$CHUMP_SENTINEL_PAGE_SINK" && ok "page names the absent healer" || bad "page missing healer name"
has '"kind":"fleet_health_sentinel_tick"' "$CHUMP_AMBIENT_LOG" && ok "emitted heartbeat tick" || bad "no heartbeat tick"
[ -s "$CHUMP_STATE_DIR/fleet-health-sentinel.heartbeat" ] && ok "wrote heartbeat file" || bad "no heartbeat file"
grep -q '"epoch":[0-9]' "$CHUMP_STATE_DIR/fleet-health-sentinel.heartbeat" && ok "heartbeat has epoch" || bad "heartbeat missing epoch"

echo "== case 3: unhealable failed unit (fails again after restart) PAGES =="
cat > "$FAKE_STATE" <<EOF
chump-stuck.service=failed
EOF
: > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
CHUMP_SENTINEL_REQUIRED_HEALERS="" CHUMP_SENTINEL_WATCHED_HEALERS="" \
  FAKE_STUCK=chump-stuck.service bash "$SENTINEL" --local >/dev/null 2>&1 || true
has "fleet_health_unit_failed" "$CHUMP_SENTINEL_PAGE_SINK" && ok "PAGED unhealable unit" || bad "did not page unhealable unit"
has "chump-stuck.service" "$CHUMP_SENTINEL_PAGE_SINK" && ok "page names the stuck unit" || bad "page missing stuck unit name"
has '"kind":"fleet_health_self_healed"' "$CHUMP_AMBIENT_LOG" && bad "wrongly reported self-heal" || ok "no false self-heal for stuck unit"

echo "== case 4: --fleet detects a stale local heartbeat and pages peer_dead =="
NODES="$TMP/nodes.conf"; printf '%s\t\t\n' "$(hostname)" > "$NODES"
# write a heartbeat 9999s old
old=$(( $(date -u +%s) - 9999 ))
printf '{"ts":"x","epoch":%s,"node":"%s","failed":0}\n' "$old" "$(hostname)" > "$CHUMP_STATE_DIR/fleet-health-sentinel.heartbeat"
: > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
CHUMP_SENTINEL_CADENCE_MIN=5 CHUMP_SENTINEL_STALE_MULT=3 \
  bash "$SENTINEL" --fleet --nodes "$NODES" >/dev/null 2>&1 || true
has "fleet_health_sentinel_peer_dead" "$CHUMP_SENTINEL_PAGE_SINK" && ok "PAGED on stale heartbeat" || bad "did not page stale heartbeat"
has '"kind":"fleet_health_sentinel_tick".*fleet' "$CHUMP_AMBIENT_LOG" && ok "fleet grader emitted tick" || bad "no fleet tick"

echo "== case 5: --fleet stays quiet on a FRESH heartbeat =="
printf '{"ts":"x","epoch":%s,"node":"%s","failed":0}\n' "$(date -u +%s)" "$(hostname)" > "$CHUMP_STATE_DIR/fleet-health-sentinel.heartbeat"
: > "$CHUMP_SENTINEL_PAGE_SINK"
CHUMP_SENTINEL_CADENCE_MIN=5 CHUMP_SENTINEL_STALE_MULT=3 \
  bash "$SENTINEL" --fleet --nodes "$NODES" >/dev/null 2>&1 || true
[ ! -s "$CHUMP_SENTINEL_PAGE_SINK" ] && ok "no page on fresh heartbeat" || bad "false page on fresh heartbeat"

echo "== case 6: PRODUCT-376 --check-sites pages on 404 for /_vercel/insights/script.js =="
cat > "$FAKE_BIN/curl" <<'FAKECURL'
#!/usr/bin/env bash
url="${!#}"
if [[ "$url" == *"shopolive.xyz/_vercel/insights/script.js"* ]]; then
  printf '404'
else
  printf '200'
fi
FAKECURL
chmod +x "$FAKE_BIN/curl"
: > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
CHUMP_CURL="$FAKE_BIN/curl" CHUMP_SENTINEL_INSIGHTS_SITES="jeffadkins.dev shopolive.xyz" \
  bash "$SENTINEL" --check-sites >/dev/null 2>&1 || true
has "vercel_insights_missing.*shopolive.xyz" "$CHUMP_SENTINEL_PAGE_SINK" && ok "PAGED missing vercel insights on shopolive.xyz" || bad "did not page shopolive.xyz 404"
has "jeffadkins.dev" "$CHUMP_SENTINEL_PAGE_SINK" && bad "false page on healthy jeffadkins.dev" || ok "healthy site not paged"

echo "== case 7: PRODUCT-380 AC3 --check-product-trunks pages on red repairman29/olive main =="
cat > "$FAKE_BIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
echo '[{"conclusion":"failure","headSha":"deadbeef1234","url":"https://github.com/repairman29/olive/actions/runs/1"}]'
FAKEGH
chmod +x "$FAKE_BIN/gh"
: > "$CHUMP_AMBIENT_LOG"; : > "$CHUMP_SENTINEL_PAGE_SINK"
CHUMP_GH="$FAKE_BIN/gh" CHUMP_SENTINEL_PRODUCT_REPOS="repairman29/olive" \
  bash "$SENTINEL" --check-product-trunks >/dev/null 2>&1 || true
has "product_trunk_red: repairman29/olive main branch CI is RED" "$CHUMP_SENTINEL_PAGE_SINK" && ok "PAGED red main on repairman29/olive" || bad "did not page red repairman29/olive main"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "PASS: all fleet-health-sentinel assertions"; exit 0
else echo "FAIL: $FAILS assertion(s) failed"; exit 1; fi
