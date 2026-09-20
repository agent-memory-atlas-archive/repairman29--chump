#!/usr/bin/env bash
# scripts/setup/install-cj-core-organs.sh — RESILIENT-1436
#
# CJ's three core organs (chump-cj-worker, chump-cj-disk-monitor, chump-cj-sync
# — the ones that claim+execute gaps, watch disk, and sync state.db from
# origin/main) have run since 2026-09-16 as unsupervised bare backgrounded
# bash procs: no systemd unit loaded, no restart-on-crash, no is-active signal
# to alarm on. organ-manifest.txt already DECLARES them (with
# requires=...,file:~/cj-*-run.sh) so organ-reconcile.sh and fleet-doctor's
# organ-roll-call-live check *look* for real systemd units — but nothing ever
# installed one, so the requires=file: gate was met (the hand-placed
# ~/cj-*-run.sh scripts exist) while the units themselves never did. This
# script closes that hole: it wraps each existing ~/cj-*-run.sh in a real
# `systemd --user` unit with Restart=on-failure, so a crash restarts instead
# of silently dying, and `systemctl --user is-active` becomes a real signal
# fleet-doctor's organ-roll-call-live check (RESILIENT-1436) can read.
#
# This does NOT reimplement cj-worker-run.sh/cj-disk-monitor-run.sh/
# cj-sync-run.sh — those are CJ's own hand-placed host scripts (per
# organ-manifest.txt's file: requires= comment) and are left exactly as-is.
# It only gives them a supervisor.
#
# Idempotent: re-running rewrites the three unit files and re-enables them.
# Safe no-op per-organ when the corresponding ~/cj-*-run.sh is absent on this
# node (e.g. run on a non-CJ box) — skipped with a message, not a hard fail,
# so a fleet-wide re-run of this installer never errors on nodes that were
# never CJ.
#
# Usage: bash scripts/setup/install-cj-core-organs.sh

set -uo pipefail

USER_N="${USER:-$(id -un 2>/dev/null || echo root)}"
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

# name|run-script|description
ORGANS="chump-cj-worker|$HOME/cj-worker-run.sh|CJ core organ: worker (claims+executes gaps)
chump-cj-disk-monitor|$HOME/cj-disk-monitor-run.sh|CJ core organ: disk-monitor (disk headroom alarm)
chump-cj-sync|$HOME/cj-sync-run.sh|CJ core organ: sync (coherence-sync state.db from origin/main)"

installed=0
skipped=0

write_unit() {
    local name="$1" run_script="$2" desc="$3"
    {
        echo "[Unit]"
        echo "Description=$desc (RESILIENT-1436)"
        echo "After=network-online.target"
        echo ""
        echo "[Service]"
        echo "Type=simple"
        echo "ExecStart=/usr/bin/env bash $run_script"
        echo "Restart=on-failure"
        echo "RestartSec=15"
        echo ""
        echo "[Install]"
        echo "WantedBy=default.target"
    } > "$UNIT_DIR/$name.service"
    echo "wrote: $UNIT_DIR/$name.service"
}

while IFS='|' read -r name run_script desc; do
    [[ -z "$name" ]] && continue
    if [[ ! -f "$run_script" ]]; then
        echo "SKIP $name — $run_script not present on this node (not applicable here)"
        skipped=$((skipped + 1))
        continue
    fi
    write_unit "$name" "$run_script" "$desc"
    installed=$((installed + 1))
done <<EOF
$ORGANS
EOF

if [[ "$installed" -eq 0 ]]; then
    echo "no CJ core organ run-scripts found on this node — nothing to supervise (installed=0 skipped=$skipped)"
    exit 0
fi

if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$USER_N" 2>/dev/null \
        && echo "linger enabled for $USER_N" \
        || echo "WARN: could not enable linger — run once: sudo loginctl enable-linger $USER_N" >&2
fi

systemctl --user daemon-reload
while IFS='|' read -r name run_script desc; do
    [[ -z "$name" ]] && continue
    [[ -f "$run_script" ]] || continue
    systemctl --user enable --now "$name.service" >/dev/null 2>&1 \
        && echo "enabled+started: $name.service" \
        || echo "WARN: failed to enable/start $name.service" >&2
done <<EOF
$ORGANS
EOF

echo ""
echo "=== status ==="
while IFS='|' read -r name run_script desc; do
    [[ -z "$name" ]] && continue
    [[ -f "$run_script" ]] || continue
    systemctl --user is-active "$name.service" 2>/dev/null | sed "s/^/$name: /"
done <<EOF
$ORGANS
EOF

echo ""
echo "installed=$installed skipped=$skipped"
echo "Logs:    journalctl --user -u chump-cj-worker.service -n 50 --no-pager"
echo "Disable: systemctl --user disable --now chump-cj-worker.service chump-cj-disk-monitor.service chump-cj-sync.service"
