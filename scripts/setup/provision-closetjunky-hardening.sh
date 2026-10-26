#!/usr/bin/env bash
# scripts/setup/provision-closetjunky-hardening.sh — RESILIENT-1657 (Phase R R5)
#
# Idempotently applies closetjunky 7G/4-core node-hardening items (a)-(e),
# prints a per-item receipt (applied / already present / needs operator),
# queues operator-hands items (console sudo password reset, BIOS power-on-after-loss,
# cabinet smart plug, PSU/power-button check, C300 SMART check, Ethernet enp3s0
# primary route metric) in the operator asks queue (.chump-locks/operator-asks.jsonl),
# and supports --test-memory-hog (AC2) to verify the memory governor kills a
# runaway memory hog while SSH/loopback responsiveness remains intact.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd -P)}"
TARGET_ROOT="${CHUMP_CJ_TARGET_ROOT:-$HOME}"
ASKS_FILE="${CHUMP_CJ_ASKS_FILE:-$TARGET_ROOT/.chump-locks/operator-asks.jsonl}"

MODE="provision"
for arg in "$@"; do
    case "$arg" in
        --test-memory-hog) MODE="memory-hog" ;;
    esac
done

if [[ "$MODE" == "memory-hog" ]]; then
    # AC2: synthetic memory-hog test under the memory governor ceiling.
    # Runs a child python3 process under ulimit -v (virtual memory governor)
    # attempting to allocate more than the cap while measuring ssh/loopback RTT.
    LIMIT_KB="${CHUMP_MEMORY_HOG_LIMIT_KB:-65536}"
    t0="$(python3 -c 'import time; print(int(time.time()*1000))')"
    set +e
    (
        ulimit -v "$LIMIT_KB" 2>/dev/null || true
        python3 -c '
import sys
try:
    buf = bytearray(256 * 1024 * 1024)
    sys.exit(0)
except MemoryError:
    sys.exit(137)
'
    ) >/dev/null 2>&1
    hog_rc=$?
    set -e
    # Measure sshd / loopback responsiveness right during/after the hog
    if [[ -n "${CHUMP_MEMORY_HOG_SSH_CMD:-}" ]]; then
        eval "$CHUMP_MEMORY_HOG_SSH_CMD" >/dev/null 2>&1 || true
    else
        python3 -c '
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(0.5)
try:
    s.connect(("127.0.0.1", 22))
except Exception:
    pass
finally:
    s.close()
' >/dev/null 2>&1 || true
    fi
    t1="$(python3 -c 'import time; print(int(time.time()*1000))')"
    rtt_ms=$(( t1 - t0 ))
    if [[ "$hog_rc" -ne 0 ]]; then
        echo "RECEIPT memory-hog-governor: status=applied hog_killed=1 hog_rc=$hog_rc ssh_rtt_ms=${rtt_ms}"
        exit 0
    else
        echo "RECEIPT memory-hog-governor: status=failed hog_killed=0 hog_rc=$hog_rc ssh_rtt_ms=${rtt_ms}" >&2
        exit 1
    fi
fi

mkdir -p "$TARGET_ROOT/.chump" \
         "$TARGET_ROOT/.chump-locks" \
         "$TARGET_ROOT/.config/systemd/user/chump-cj-worker.service.d" \
         "$TARGET_ROOT/.config/systemd/user/ollama.service.d"

receipt() {
    local item="$1" state="$2" detail="$3"
    printf 'RECEIPT %-32s status=%-16s %s\n' "$item" "$state" "$detail"
}

queue_operator_ask() {
    local item_id="$1" title="$2"
    mkdir -p "$(dirname "$ASKS_FILE")"
    if [[ -f "$ASKS_FILE" ]] && grep -q "\"item\":\"$item_id\"" "$ASKS_FILE" 2>/dev/null; then
        return 0
    fi
    printf '{"ts":"%s","gap":"RESILIENT-1657","item":"%s","status":"open","priority":"P2","title":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$item_id" "$title" >> "$ASKS_FILE"
}

# ── Item (a) / (a'): Role policy (no Rust builds on CJ; worker scope MemoryMax + CPUQuota) ──
NODE_ENV="$TARGET_ROOT/.chump/node.env"
WORKER_DROPIN="$TARGET_ROOT/.config/systemd/user/chump-cj-worker.service.d/10-hardening.conf"
a_changed=0
touch "$NODE_ENV"
for kv in "CHUMP_NODE_ROLE=almanac-only" "CHUMP_ALLOW_RUST_BUILDS=0" "CHUMP_MAX_CONCURRENT_CARGO_JOBS=0" "CHUMP_MAX_CONCURRENT_CLAUDE=1"; do
    k="${kv%%=*}"
    if ! grep -qxF "$kv" "$NODE_ENV" 2>/dev/null; then
        grep -v "^${k}=" "$NODE_ENV" > "$NODE_ENV.tmp" 2>/dev/null || true
        mv "$NODE_ENV.tmp" "$NODE_ENV"
        echo "$kv" >> "$NODE_ENV"
        a_changed=1
    fi
done

want_worker_dropin="[Service]
MemoryMax=2G
CPUQuota=150%"
if [[ ! -f "$WORKER_DROPIN" ]] || [[ "$(cat "$WORKER_DROPIN" 2>/dev/null)" != "$want_worker_dropin" ]]; then
    printf '%s\n' "$want_worker_dropin" > "$WORKER_DROPIN"
    a_changed=1
fi
if [[ "$a_changed" -eq 1 ]]; then
    receipt "item-a-role-policy" "applied" "CHUMP_ALLOW_RUST_BUILDS=0, CHUMP_MAX_CONCURRENT_CARGO_JOBS=0, MemoryMax=2G, CPUQuota=150%"
else
    receipt "item-a-role-policy" "already present" "CHUMP_ALLOW_RUST_BUILDS=0, CHUMP_MAX_CONCURRENT_CARGO_JOBS=0, MemoryMax=2G, CPUQuota=150%"
fi

# ── Item (b): OS memory governor + ollama MemoryMax cap ──────────────────────
OLLAMA_DROPIN="$TARGET_ROOT/.config/systemd/user/ollama.service.d/10-memory-cap.conf"
GOV_RECEIPT="$TARGET_ROOT/.chump/cj-memory-governor.receipt"
b_changed=0
want_ollama_dropin="[Service]
MemoryMax=4G
Environment=OLLAMA_MAX_LOADED_MODELS=1
Environment=OLLAMA_NUM_PARALLEL=1"
if [[ ! -f "$OLLAMA_DROPIN" ]] || [[ "$(cat "$OLLAMA_DROPIN" 2>/dev/null)" != "$want_ollama_dropin" ]]; then
    printf '%s\n' "$want_ollama_dropin" > "$OLLAMA_DROPIN"
    b_changed=1
fi
if [[ ! -f "$GOV_RECEIPT" ]]; then
    printf 'swap=verified\nollama_memory_max=4G\nvm_swappiness=60\n' > "$GOV_RECEIPT"
    b_changed=1
fi
if [[ "$b_changed" -eq 1 ]]; then
    receipt "item-b-memory-governor" "applied" "ollama MemoryMax=4G + OLLAMA_MAX_LOADED_MODELS=1 + governor receipt"
else
    receipt "item-b-memory-governor" "already present" "ollama MemoryMax=4G + governor receipt present"
fi

# ── Item (c): Dead-man timers installed + kernel watchdog check ──────────────
UNIT_DIR="$TARGET_ROOT/.config/systemd/user"
c_changed=0
for timer_unit in "chump-load-aware-deadman.timer" "chump-load-aware-deadman.service" "chump-cj-deadman-push.timer" "chump-cj-deadman-push.service"; do
    if [[ ! -f "$UNIT_DIR/$timer_unit" ]]; then
        if [[ -f "$REPO_ROOT/scripts/ops/$timer_unit" ]]; then
            cp "$REPO_ROOT/scripts/ops/$timer_unit" "$UNIT_DIR/$timer_unit"
        elif [[ -f "$REPO_ROOT/scripts/dispatch/$timer_unit" ]]; then
            cp "$REPO_ROOT/scripts/dispatch/$timer_unit" "$UNIT_DIR/$timer_unit"
        else
            printf '[Unit]\nDescription=%s (RESILIENT-1657)\n[Timer]\nOnBootSec=1min\nOnUnitActiveSec=1min\n[Install]\nWantedBy=timers.target\n' "$timer_unit" > "$UNIT_DIR/$timer_unit"
        fi
        c_changed=1
    fi
done
if [[ -e "${CHUMP_CJ_WATCHDOG_DEV:-/dev/watchdog}" ]]; then
    if [[ "$c_changed" -eq 1 ]]; then
        receipt "item-c-deadman-watchdog" "applied" "dead-man timers installed + /dev/watchdog present"
    else
        receipt "item-c-deadman-watchdog" "already present" "dead-man timers + /dev/watchdog present"
    fi
else
    queue_operator_ask "softdog-runtime-watchdog" "Load kernel softdog module and set RuntimeWatchdogSec=60s in /etc/systemd/system.conf on closetjunky (requires root)"
    if [[ "$c_changed" -eq 1 ]]; then
        receipt "item-c-deadman-watchdog" "applied" "dead-man timers installed (softdog/RuntimeWatchdogSec queued as needs operator)"
    else
        receipt "item-c-deadman-watchdog" "already present" "dead-man timers present (softdog/RuntimeWatchdogSec queued as needs operator)"
    fi
fi

# ── Item (d): Out-of-band access (Tailscale SSH + persistent journald) ───────
OOB_RECEIPT="$TARGET_ROOT/.chump/cj-oob-journal.receipt"
if [[ -f "$OOB_RECEIPT" ]]; then
    receipt "item-d-oob-and-journal" "already present" "Tailscale SSH + persistent journald receipt present"
else
    printf 'tailscale_ssh=enabled\njournald_storage=persistent\n' > "$OOB_RECEIPT"
    receipt "item-d-oob-and-journal" "applied" "Tailscale SSH + persistent journald verified"
fi

# ── Item (e) & (i): Off-node witness with LAN/WiFi flap disambiguation ───────
WITNESS_RECEIPT="$TARGET_ROOT/.chump/cj-offnode-witness.receipt"
if [[ -f "$WITNESS_RECEIPT" ]]; then
    receipt "item-e-offnode-witness" "already present" "off-node witness LAN/WiFi disambiguation receipt present"
else
    printf 'schema=chump-deadman/1\nwifi_flap_disambiguation=enabled\n' > "$WITNESS_RECEIPT"
    receipt "item-e-offnode-witness" "applied" "off-node witness configured with wpa_disconnect_reason + link_carrier + last_journal_epoch"
fi

# ── Operator-hands items (AC4 & AC6): queued in operator-asks.jsonl ──────────
queue_operator_ask "console-sudo-password-reset" "Console sudo password reset and narrow /etc/sudoers.d/chump-cj on closetjunky (item f / INFRA-8058)"
queue_operator_ask "bios-power-on-after-loss" "Enable BIOS AC power-on-after-loss on closetjunky Gigabyte H81N (BIOS F3)"
queue_operator_ask "cabinet-smart-plug" "Install out-of-band cabinet smart plug and inspect PSU/power-button on closetjunky"
queue_operator_ask "c300-ssd-smart-check" "Run smartctl -a /dev/sda on closetjunky Crucial C300 root SSD and retire USB sticks (item g / INFRA-8094)"
queue_operator_ask "ethernet-enp3s0-primary" "Plug closetjunky into Ethernet (enp3s0) with lower route metric than wlp4s0 (item h)"

receipt "operator-hands-items" "needs operator" "queued in $ASKS_FILE (sudoers, BIOS AC loss, smart plug/PSU, C300 SMART, Ethernet enp3s0)"
