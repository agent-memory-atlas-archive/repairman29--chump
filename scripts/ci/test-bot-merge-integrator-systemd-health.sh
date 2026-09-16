#!/usr/bin/env bash
# scripts/ci/test-bot-merge-integrator-systemd-health.sh — INFRA-6988
#
# The Batched Merge Train go-live target (CJ, the sole coordinator) runs the
# chump-integrator daemon as chump-integrator.{service,timer} via
# install-integrator-daemon-systemd.sh, NOT launchd. Before INFRA-6988,
# _bm_integrator_healthy() in scripts/coord/bot-merge.sh only understood the
# macOS launchd probe (plist + `launchctl list`); on a systemd host it fell
# through to a `~/.cargo/bin/chump-integrator` existence check and then
# ALWAYS failed the `launchctl` probe (the binary doesn't exist on Linux),
# so bot-merge permanently fail-opened Mode A -> Mode B (INFRA-2523) even
# after the daemon was flipped LIVE — silently defeating the go-live.
#
# This proves the new _bm_integrator_healthy_systemd() helper: it must
# report healthy only when systemctl reports the timer active, the unit's
# binary is executable, and the last run's Result was "success" — and it
# must report unhealthy on each failure mode independently.

set -uo pipefail
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; cd "$ROOT" || exit 2
BM=scripts/coord/bot-merge.sh
P=0; F=0
p(){ echo "[PASS] $1"; P=$((P+1)); }
f(){ echo "[FAIL] $1"; F=$((F+1)); }

echo "=== test-bot-merge-integrator-systemd-health.sh (INFRA-6988) ==="

bash -n "$BM" 2>/dev/null && p "bot-merge.sh parses (bash -n)" || f "bot-merge.sh SYNTAX ERROR"

grep -q '_bm_integrator_healthy_systemd' "$BM" 2>/dev/null \
  && p "systemd health helper present" || f "no _bm_integrator_healthy_systemd — go-live health check is launchd-only"

fn="$(sed -n '/^_bm_integrator_healthy_systemd() {/,/^}/p' "$BM")"
if [ -z "$fn" ]; then
  f "could not extract _bm_integrator_healthy_systemd()"
  echo ""; echo "=== $P passed, $F failed ==="; exit 1
fi

if printf '%s' "$fn" | grep -qE 'curl|wget|nc |sleep|gh api'; then
  f "systemd health probe not bounded (network/sleep present)"
else
  p "systemd health probe is bounded (no network/sleep)"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

_run_with_fake_binary() {
    # $1 = fake systemctl body (bash case-statement source, already includes
    # everything between "case ..." lines), $2 = whether the fake integrator
    # binary should be executable (1/0)
    local fake_bin="$WORKDIR/chump-integrator"
    if [ "$2" = "1" ]; then
        printf '#!/usr/bin/env bash\ntrue\n' > "$fake_bin"; chmod +x "$fake_bin"
    else
        rm -f "$fake_bin"
    fi
    cat > "$WORKDIR/systemctl" <<EOF
#!/usr/bin/env bash
$1
EOF
    chmod +x "$WORKDIR/systemctl"
    PATH="$WORKDIR:$PATH" bash -c "
        $fn
        _bm_integrator_healthy_systemd
    "
    return $?
}

# ── Case 1: no systemctl on PATH at all -> unhealthy ──────────────────────────
NOBIN_DIR="$WORKDIR/nobin"
mkdir -p "$NOBIN_DIR"
ln -sf "$(command -v bash)" "$NOBIN_DIR/bash"
PATH="$NOBIN_DIR" "$NOBIN_DIR/bash" -c "$fn"$'\n'"_bm_integrator_healthy_systemd"
c1=$?
[ "$c1" = 1 ] && p "no systemctl on PATH -> unhealthy (rc=1)" || f "expected rc=1 with no systemctl, got rc=$c1"

# ── Case 2: timer active + binary executable + Result=success -> healthy ─────
_run_with_fake_binary '
case "$1 $2" in
  "is-active --quiet") exit 0 ;;
esac
if [ "$1" = "is-active" ]; then exit 0; fi
if [ "$1" = "cat" ]; then echo "ExecStart='"$WORKDIR"'/chump-integrator --once"; exit 0; fi
if [ "$1" = "show" ]; then echo "success"; exit 0; fi
exit 1
' 1
c2=$?
[ "$c2" = 0 ] && p "timer active + binary present + Result=success -> healthy (rc=0)" || f "expected rc=0, got rc=$c2"

# ── Case 3: timer inactive -> unhealthy ───────────────────────────────────────
_run_with_fake_binary '
if [ "$1" = "is-active" ]; then exit 3; fi
if [ "$1" = "cat" ]; then echo "ExecStart='"$WORKDIR"'/chump-integrator --once"; exit 0; fi
if [ "$1" = "show" ]; then echo "success"; exit 0; fi
exit 1
' 1
c3=$?
[ "$c3" = 1 ] && p "timer inactive -> unhealthy (rc=1)" || f "expected rc=1 with inactive timer, got rc=$c3"

# ── Case 4: binary missing/non-executable -> unhealthy ────────────────────────
_run_with_fake_binary '
if [ "$1" = "is-active" ]; then exit 0; fi
if [ "$1" = "cat" ]; then echo "ExecStart='"$WORKDIR"'/chump-integrator --once"; exit 0; fi
if [ "$1" = "show" ]; then echo "success"; exit 0; fi
exit 1
' 0
c4=$?
[ "$c4" = 1 ] && p "binary missing -> unhealthy (rc=1)" || f "expected rc=1 with missing binary, got rc=$c4"

# ── Case 5: last run Result != success (crashed) -> unhealthy ────────────────
_run_with_fake_binary '
if [ "$1" = "is-active" ]; then exit 0; fi
if [ "$1" = "cat" ]; then echo "ExecStart='"$WORKDIR"'/chump-integrator --once"; exit 0; fi
if [ "$1" = "show" ]; then echo "exit-code"; exit 0; fi
exit 1
' 1
c5=$?
[ "$c5" = 1 ] && p "last Result=exit-code -> unhealthy (rc=1)" || f "expected rc=1 with failed last run, got rc=$c5"

echo ""
echo "=== $P passed, $F failed ==="
[ "$F" -eq 0 ] || exit 1
