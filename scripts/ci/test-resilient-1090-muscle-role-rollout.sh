#!/usr/bin/env bash
# scripts/ci/test-resilient-1090-muscle-role-rollout.sh — RESILIENT-1090
#
# Proves scripts/ops/muscle-role-rollout.sh — the packaged safe-rollout command
# for activating node-identity role-scoping (RESILIENT-1087) on a live muscle
# node — behaves correctly against a mugman-shaped scenario: a mix of
# manifest-tagged brain-coordination daemons (the intended reap target),
# node-local infra that must never be touched, and a true manifest-orphan
# stray unit that must block --apply until a human classifies it.
#
# Assertions:
#   (a) step 1 seeds ~/.chump/node.env's CHUMP_NODE_ROLE=muscle idempotently
#       (no duplicate lines on a second run).
#   (b) default (--check-only) mode never calls systemctl disable/stop —
#       read-only, per the gap's "SAFE ROLLOUT" step (2).
#   (c) manifest-tagged out-of-role units are classified SAFE; a unit with no
#       manifest entry at all is classified UNKNOWN.
#   (d) --apply REFUSES (exit 2, no disable calls) while an UNKNOWN unit is
#       present in the reap set.
#   (e) once the manifest covers every out-of-role unit, --apply reaps only
#       the SAFE set and never touches node-local infra or the worker.

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROLLOUT="$REPO_ROOT/scripts/ops/muscle-role-rollout.sh"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

echo "=== test-resilient-1090-muscle-role-rollout.sh (RESILIENT-1090) ==="

[[ -f "$ROLLOUT" ]] || { echo "FAIL: missing $ROLLOUT"; exit 1; }
bash -n "$ROLLOUT" || { echo "FAIL: bash -n $ROLLOUT"; exit 1; }
pass "syntax clean"

RTMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-1090-rollout-test.XXXXXX")"
trap 'rm -rf "$RTMP"' EXIT

STATE_DIR="$RTMP/state"
ACTIVE_FILE="$RTMP/active.txt"
ENABLED_FILE="$RTMP/enabled.txt"
UNITFILES_FILE="$RTMP/unitfiles.txt"
CALL_LOG="$RTMP/calls.log"
BACKOFF_DIR="$RTMP/backoff"

# mugman-shaped scenario: a muscle worker + node-local infra (must survive),
# two manifest-tagged brain daemons (SAFE reap target), and one true stray
# with NO manifest entry at all (must block --apply as UNKNOWN).
cat > "$UNITFILES_FILE" <<'EOF'
chump-node1-worker.service
chump-oauth-refresh.timer
chump-farmer.timer
chump-organ-watchdog.timer
chump-mystery-stray.service
EOF
cp "$UNITFILES_FILE" "$ACTIVE_FILE"
cp "$UNITFILES_FILE" "$ENABLED_FILE"

STUB="$RTMP/systemctl-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALL_LOG"
case "$1" in
    list-unit-files)
        awk '{print $1"  enabled"}' "$UNITFILES_FILE"
        exit 0
        ;;
    is-active)
        unit="${@: -1}"
        grep -qxF "$unit" "$ACTIVE_FILE" 2>/dev/null && exit 0 || exit 3
        ;;
    is-enabled)
        unit="${@: -1}"
        grep -qxF "$unit" "$ENABLED_FILE" 2>/dev/null && exit 0 || exit 1
        ;;
    is-failed)
        echo "inactive"; exit 0
        ;;
    disable)
        unit="${@: -1}"
        grep -vxF "$unit" "$ACTIVE_FILE" > "$ACTIVE_FILE.tmp" 2>/dev/null; mv "$ACTIVE_FILE.tmp" "$ACTIVE_FILE"
        grep -vxF "$unit" "$ENABLED_FILE" > "$ENABLED_FILE.tmp" 2>/dev/null; mv "$ENABLED_FILE.tmp" "$ENABLED_FILE"
        exit 0
        ;;
    stop|daemon-reload|reset-failed|cat)
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

MANIFEST="$RTMP/organ-manifest.txt"
cat > "$MANIFEST" <<'EOF'
enabled  chump-farmer.timer          role=brain requires=
enabled  chump-organ-watchdog.timer  role=brain requires=
EOF
# chump-mystery-stray.service is deliberately absent from the manifest — a true
# stray with no role declaration at all.

run_rollout() {  # extra-args...
  : > "$CALL_LOG"
  rm -rf "$BACKOFF_DIR"
  CHUMP_STATE_DIR="$STATE_DIR" \
  ACTIVE_FILE="$ACTIVE_FILE" ENABLED_FILE="$ENABLED_FILE" UNITFILES_FILE="$UNITFILES_FILE" CALL_LOG="$CALL_LOG" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$BACKOFF_DIR" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST="$MANIFEST" \
  PATH="$RTMP:$PATH" \
  bash "$ROLLOUT" "$@" 2>&1
}
# organ-reconcile.sh's own systemctl calls are stubbed via
# CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN; the rollout script's OWN receipt-printing
# `systemctl` calls (step 4) shell out to plain `systemctl`, so also shadow it
# on PATH with the same stub.
ln -sf "$STUB" "$RTMP/systemctl"

# ── (a) idempotent node.env seeding ─────────────────────────────────────────
out1="$(run_rollout)"
out2="$(run_rollout)"
node_env="$STATE_DIR/node.env"
# INFRA-8588: node.env is bare KEY=VALUE (no export).
[[ -f "$node_env" ]] && grep -q '^CHUMP_NODE_ROLE=muscle$' "$node_env" \
  && pass "node.env seeded with CHUMP_NODE_ROLE=muscle" \
  || fail "node.env missing CHUMP_NODE_ROLE=muscle: $(cat "$node_env" 2>/dev/null)"
lines="$(grep -c '^CHUMP_NODE_ROLE=' "$node_env" 2>/dev/null || echo 0)"
[[ "$lines" == 1 ]] && pass "seeding node.env twice does not duplicate the CHUMP_NODE_ROLE line" \
  || fail "expected exactly 1 CHUMP_NODE_ROLE line after two runs, got $lines"

# ── (b) default mode is read-only ───────────────────────────────────────────
grep -q '^disable ' "$CALL_LOG" \
  && fail "default (--check-only) mode must never call systemctl disable; calls: $(cat "$CALL_LOG")" \
  || pass "default (--check-only) mode never calls systemctl disable"

# ── (c) classification ──────────────────────────────────────────────────────
echo "$out2" | grep -q 'SAFE:.*chump-farmer.timer' \
  && pass "manifest-tagged chump-farmer.timer classified SAFE" \
  || fail "expected chump-farmer.timer in SAFE list; got: $out2"
echo "$out2" | grep -q 'SAFE:.*chump-organ-watchdog.timer' \
  && pass "manifest-tagged chump-organ-watchdog.timer classified SAFE" \
  || fail "expected chump-organ-watchdog.timer in SAFE list; got: $out2"
echo "$out2" | grep -q 'UNKNOWN:.*chump-mystery-stray.service' \
  && pass "manifest-orphan chump-mystery-stray.service classified UNKNOWN" \
  || fail "expected chump-mystery-stray.service in UNKNOWN list; got: $out2"

# ── (d) --apply refuses while UNKNOWN present ───────────────────────────────
cp "$UNITFILES_FILE" "$ACTIVE_FILE"; cp "$UNITFILES_FILE" "$ENABLED_FILE"
run_rollout --apply >/tmp/rollout_apply_1090.out 2>&1
rc=$?
[[ "$rc" == 2 ]] && pass "--apply exits 2 while an UNKNOWN unit remains" \
  || fail "expected exit 2 with an UNKNOWN unit present, got $rc"
grep -q '^disable ' "$CALL_LOG" \
  && fail "--apply must not disable anything while UNKNOWN units remain; calls: $(cat "$CALL_LOG")" \
  || pass "--apply makes no disable calls while UNKNOWN units remain"

# ── (e) once fully classified, --apply reaps only the SAFE set ─────────────
cat >> "$MANIFEST" <<'EOF'
enabled  chump-mystery-stray.service  role=brain requires=
EOF
cp "$UNITFILES_FILE" "$ACTIVE_FILE"; cp "$UNITFILES_FILE" "$ENABLED_FILE"
run_rollout --apply >/tmp/rollout_apply_2090.out 2>&1
rc=$?
[[ "$rc" == 0 ]] && pass "--apply exits 0 once every out-of-role unit is manifest-classified" \
  || fail "expected exit 0 once classification is clean, got $rc; out: $(cat /tmp/rollout_apply_2090.out)"
grep -q '^disable --now chump-farmer.timer$' "$CALL_LOG" \
  && grep -q '^disable --now chump-organ-watchdog.timer$' "$CALL_LOG" \
  && grep -q '^disable --now chump-mystery-stray.service$' "$CALL_LOG" \
  && pass "--apply reaped all three now-classified out-of-role units" \
  || fail "expected disable calls for all three units; calls: $(cat "$CALL_LOG")"
grep -q 'disable --now chump-node1-worker.service' "$CALL_LOG" \
  && fail "--apply must NEVER disable the muscle node's worker; calls: $(cat "$CALL_LOG")" \
  || pass "--apply never touches the node's worker unit"
grep -q 'disable --now chump-oauth-refresh.timer' "$CALL_LOG" \
  && fail "--apply must NEVER disable node-local oauth-refresh infra; calls: $(cat "$CALL_LOG")" \
  || pass "--apply never touches node-local oauth-refresh infra"
grep -qxF "chump-node1-worker.service" "$ACTIVE_FILE" \
  && pass "worker still active after --apply" \
  || fail "worker should still be active; active file: $(cat "$ACTIVE_FILE")"
grep -qxF "chump-oauth-refresh.timer" "$ACTIVE_FILE" \
  && pass "oauth-refresh still active after --apply" \
  || fail "oauth-refresh should still be active; active file: $(cat "$ACTIVE_FILE")"

echo "=== $fails failure(s) ==="
exit "$fails"
