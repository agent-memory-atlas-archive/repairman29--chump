#!/usr/bin/env bash
# test-resilient-1436-cj-core-organs-install.sh — RESILIENT-1436
#
# Proves scripts/setup/install-cj-core-organs.sh:
#   1. writes a real systemd --user unit (Type=simple, Restart=on-failure) for
#      each CJ core organ whose ~/cj-*-run.sh is present on the node, wrapping
#      the EXACT existing run-script (never reimplementing it);
#   2. skips (does not fail) an organ whose run-script is absent — a fleet-wide
#      re-run on a non-CJ node must be a clean no-op, not an error;
#   3. is idempotent — running it twice produces the same unit content.
#
# Runs entirely against a stubbed $HOME + a `systemctl`/`loginctl` PATH stub so
# it needs no live systemd session and is safe on any CI runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/install-cj-core-organs.sh"

pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[[ -f "$INSTALLER" ]] || fail "missing $INSTALLER"

TMP="$(mktemp -d -t test-cj-core-organs-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

# Only the worker + sync run-scripts exist on this fake node; disk-monitor's
# is deliberately absent to exercise the skip-not-fail path.
cat > "$FAKE_HOME/cj-worker-run.sh" <<'EOF'
#!/usr/bin/env bash
echo worker
EOF
cat > "$FAKE_HOME/cj-sync-run.sh" <<'EOF'
#!/usr/bin/env bash
echo sync
EOF
chmod +x "$FAKE_HOME"/cj-*-run.sh

# Stub systemctl/loginctl so the installer's --user calls are no-ops on a
# runner with no live user systemd session.
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *is-active*) echo active; exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$STUB_BIN/loginctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$STUB_BIN/systemctl" "$STUB_BIN/loginctl"

run_installer() {
    HOME="$FAKE_HOME" USER="cj-test-user" PATH="$STUB_BIN:$PATH" bash "$INSTALLER"
}

OUT1="$(run_installer)" || fail "installer exited non-zero on first run: $OUT1"

UNIT_DIR="$FAKE_HOME/.config/systemd/user"

# ── 1. worker + sync got real systemd --user units ──────────────────────────
for name in chump-cj-worker chump-cj-sync; do
    unit="$UNIT_DIR/$name.service"
    [[ -f "$unit" ]] || fail "$unit was not written"
    grep -q '^Type=simple$' "$unit" || fail "$unit missing Type=simple"
    grep -q '^Restart=on-failure$' "$unit" || fail "$unit missing Restart=on-failure (RESILIENT-1436 AC: restart-on-crash)"
    grep -q "ExecStart=.*$FAKE_HOME/cj-${name#chump-cj-}-run.sh" "$unit" \
        || fail "$unit ExecStart does not wrap the existing $FAKE_HOME/cj-${name#chump-cj-}-run.sh (must not reimplement it)"
done
pass "chump-cj-worker.service + chump-cj-sync.service written with Restart=on-failure, wrapping the existing run-scripts"

# ── 2. disk-monitor (run-script absent) → skipped, not a hard fail ──────────
[[ -f "$UNIT_DIR/chump-cj-disk-monitor.service" ]] && fail "chump-cj-disk-monitor.service was written despite its run-script being absent — should have been skipped"
printf '%s' "$OUT1" | grep -q 'SKIP chump-cj-disk-monitor' || fail "installer did not report SKIP for the absent disk-monitor run-script"
pass "chump-cj-disk-monitor skipped cleanly (run-script absent) — no unit written, no failure"

# ── 3. idempotent: second run reproduces identical unit content ────────────
cp "$UNIT_DIR/chump-cj-worker.service" "$TMP/worker-unit-run1"
run_installer >/dev/null || fail "installer exited non-zero on second (idempotent) run"
diff -q "$TMP/worker-unit-run1" "$UNIT_DIR/chump-cj-worker.service" >/dev/null \
    || fail "chump-cj-worker.service content changed between two installer runs — not idempotent"
pass "installer is idempotent — re-run reproduces identical unit content"

echo "ALL PASS"
