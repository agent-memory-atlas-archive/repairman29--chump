#!/usr/bin/env bash
# install-node-housekeeping.sh — ONE COMMAND: install ChumpOS's self-management suite on ANY
# owned node so it keeps itself managed/clean/operable/hardware-aware. Idempotent + host-agnostic.
# Called by chump-node-install.sh (COTG). RESILIENT-318 / DISK_AWARE_FLEET.
#
# Installs, as supervised loop-services wrapping the TRACKED repo scripts (never reinvented):
#   node-orchestrator  — the resource-aware brain (sense cores/RAM/disk → heal/scale/place)
#   rot-reaper         — drain CONFLICTING PRs (RESILIENT-324)
#   worktree-reaper    — reclaim disk from merged/dead worktrees
#   disk-monitor       — disk headroom alarm + auto-remediate
#   reviver            — reopen closed-but-gap-open fleet PRs = work wrongly trashed by a
#                        stale-base auto-close (INFRA-2026 post-push-integrity-watch, RESILIENT-341)
#   pr-stuck-live-scan — LIVE gh-pr scan (INFRA-307 stuck-pr-filer) emitting kind=pr_stuck
#                        from real GitHub state so the OS notices PRs sitting failing/DIRTY/
#                        armed-not-merging (RESILIENT-349)
#   pr-stuck-cluster-detector — consumes kind=pr_stuck, escalates clusters/chronic stalls
#                        (INFRA-1133, RESILIENT-349)
# The orchestrator then keeps the others alive (heal loop). One install, self-managing node.
set -uo pipefail
REPO="${CHUMP_REPO_ROOT:-$HOME/Projects/chump}"
STATE="${CHUMP_STATE_DIR:-$HOME/.chump}"
USER_N="$(id -un)"
log(){ printf '  \033[36m[housekeeping]\033[0m %s\n' "$*"; }

[ -d "$REPO/.git" ] || { echo "no repo at $REPO (set CHUMP_REPO_ROOT)"; exit 1; }
mkdir -p "$STATE/organs"

# supervisor detect
if [ -n "${PREFIX:-}" ] && printf '%s' "${PREFIX:-}" | grep -q com.termux; then SUP=runit; SVDIR="$PREFIX/var/service"
elif command -v systemctl >/dev/null 2>&1 && [ -d /etc/systemd/system ]; then SUP=systemd
else SUP=nohup; fi
log "supervisor=$SUP repo=$REPO user=$USER_N"

# organ table: name|repo-relative-script[ args]|cadence-seconds (0 = script self-loops, e.g. orchestrator)
#
# INFRA-7766 (docs/strategy/ONE_COMMAND_INSTALL.md section 1, INFRA-7756):
# sourced from scripts/ops/organ-manifest.txt's housekeeping= tokens via the
# shared node-housekeeping-roster-lib.sh (falls back to the pre-INFRA-7766
# built-in roster + a WARN if the manifest is missing/old-shape) instead of
# a hardcoded heredoc here — so this roster and organ-reconcile.sh's
# self-heal roll-call are the SAME declared list instead of two that can
# silently drift apart (the exact disease this slice fixes).
# shellcheck source=lib/node-housekeeping-roster-lib.sh
source "$REPO/scripts/ops/lib/node-housekeeping-roster-lib.sh"
ORGAN_MANIFEST_FILE="${CHUMP_ORGAN_MANIFEST:-$REPO/scripts/ops/organ-manifest.txt}"
ORGANS="$(housekeeping_organs_from_manifest "$ORGAN_MANIFEST_FILE")"

# write the self-contained loop-runner for an organ (sources creds, sets PATH, loops at cadence)
write_runner() {
  local name="$1" script="$2" cadence="$3"
  cat > "$STATE/organs/$name.sh" <<RUN
#!/usr/bin/env bash
# NB: NO 'set -u' — providers.env references unbound vars; sourcing it under set -u
# terminates the shell (|| true cannot catch a set-u exit). Documented fleet gotcha.
set -o pipefail
cd "$REPO" 2>/dev/null || exit 1
set -a; . "$STATE/providers.env" 2>/dev/null || true; . "$STATE/cj.env" 2>/dev/null || true; set +a
export PATH="$REPO/target/release:\$PATH" CHUMP_REPO_ROOT="$REPO" CHUMP_STATE_DIR="$STATE" CHUMP_BINARY_STALENESS_CHECK=0
if [ "$cadence" -eq 0 ]; then exec bash "$REPO"/$script
else while true; do bash "$REPO"/$script >/dev/null 2>&1 || true; sleep $cadence; done; fi
RUN
  chmod +x "$STATE/organs/$name.sh"
}

install_systemd() {
  local name="$1"
  sudo tee /etc/systemd/system/chump-$name.service >/dev/null <<UNIT
[Unit]
Description=ChumpOS housekeeping organ: $name (RESILIENT-318)
After=network-online.target
[Service]
Type=simple
User=$USER_N
ExecStart=/bin/bash $STATE/organs/$name.sh
Restart=always
RestartSec=15
[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl enable --now "chump-$name.service" >/dev/null 2>&1
}
install_runit() {
  local name="$1"
  mkdir -p "$SVDIR/chump-$name/log"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec 2>&1\nexec bash %s\n' "$STATE/organs/$name.sh" > "$SVDIR/chump-$name/run"
  chmod +x "$SVDIR/chump-$name/run"
  printf '#!/data/data/com.termux/files/usr/bin/sh\nexec svlogd -tt %s\n' "$STATE/organs/logs/$name" > "$SVDIR/chump-$name/log/run"
  chmod +x "$SVDIR/chump-$name/log/run"; mkdir -p "$STATE/organs/logs/$name"
}

# reconcile: retire any older hand-installed timer/service variants so we don't double-run
if [ "$SUP" = systemd ]; then
  for old in chump-rot-reaper.timer chump-worktree-reaper.timer chump-cj-disk-monitor.service; do
    sudo systemctl disable --now "$old" >/dev/null 2>&1 || true
  done
fi

while IFS='|' read -r name script cadence; do
  [ -z "$name" ] && continue
  write_runner "$name" "$script" "$cadence"
  case "$SUP" in
    systemd) install_systemd "$name" ;;
    runit)   install_runit "$name"; sv up "$SVDIR/chump-$name" 2>/dev/null || true ;;
    *)       nohup bash "$STATE/organs/$name.sh" >/dev/null 2>&1 & ;;
  esac
  log "installed + up: chump-$name"
done <<EOF
$ORGANS
EOF
[ "$SUP" = systemd ] && sudo systemctl daemon-reload

# self-test
log "self-test:"
fail=0
for name in node-orchestrator rot-reaper worktree-reaper disk-monitor main-health-watchdog pr-lander cargo-sweep-gc reviver pr-stuck-live-scan pr-stuck-cluster-detector; do
  case "$SUP" in
    systemd) systemctl is-active "chump-$name.service" >/dev/null 2>&1 && log "  ✓ $name up" || { log "  ✗ $name DOWN"; fail=1; } ;;
    runit)   sv status "$SVDIR/chump-$name" 2>/dev/null | grep -q '^run' && log "  ✓ $name up" || { log "  ✗ $name DOWN"; fail=1; } ;;
  esac
done
[ -f "$STATE/resource-inventory.json" ] && log "  ✓ orchestrator sensing (resource-inventory.json present)" || log "  … inventory not written yet (orchestrator warming up)"
[ "$fail" = 0 ] && log "HOUSEKEEPING INSTALLED ✓ — node self-manages" || { log "some organs down — check logs"; exit 1; }
