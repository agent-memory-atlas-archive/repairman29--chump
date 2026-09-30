#!/usr/bin/env bash
# scripts/coord/infra-watcher-loop.sh — SRE-lane substrate health auditor
# META-102: productize curator-opus-infra-watcher
#
# Harness-neutral CLI. Subcommands:
#   tick           — one full audit cycle (all subchecks in order)
#   audit-daemons  — launchd plist health (StartInterval / StartCalendarInterval)
#   check-runners  — self-hosted runner ghost-online detection
#   check-disk     — /tmp + /private/tmp + .chump-locks disk pressure
#   check-disk-headroom — proactive $HOME free-GB margin alarm (INFRA-7890),
#                    pages BEFORE the cargo-target-reaper's 20GB critical floor
#   check-procs    — claude process count + load avg
#   check-ptys     — pty allocation vs kern.tty.ptmx_max (RESILIENT-092)
#
# Emits kind=infra_watcher_finding with {category, severity, detail} to ambient.jsonl
#
# Rust-First-Bypass: bash-glue across launchctl/gh/df/pgrep; coherent with other
# curator-loop.sh shapes in scripts/coord/. No state mutation, no hot-path call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow REPO_ROOT override for testing
REPO_ROOT="${REPO_ROOT:-$(cd "${SCRIPT_DIR}/../.." && pwd)}"
AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"

# ── Helpers ──────────────────────────────────────────────────────────────────

_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# INFRA-2210: no-idle finding counter — cmd_tick reads this after all
# subchecks run to decide whether the cycle was genuinely quiet.
_NON_OK_FINDING_COUNT=0

_emit_finding() {
    local category="$1"
    local severity="$2"  # critical | warning | ok
    local detail="$3"
    local ts
    ts="$(_ts)"
    # Sanitize detail for JSON (escape backslash, double-quote, newline)
    local safe_detail
    safe_detail="$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/g' | tr -d '\n' | sed 's/\\n$//')"
    printf '{"ts":"%s","kind":"infra_watcher_finding","category":"%s","severity":"%s","detail":"%s"}\n' \
        "$ts" "$category" "$severity" "$safe_detail" \
        >> "$AMBIENT_LOG"
    if [[ "$severity" == "critical" ]]; then
        printf '[infra-watcher] CRITICAL %s: %s\n' "$category" "$detail" >&2
        _NON_OK_FINDING_COUNT=$((_NON_OK_FINDING_COUNT + 1))
    elif [[ "$severity" == "warning" ]]; then
        printf '[infra-watcher] %s %s: %s\n' "$severity" "$category" "$detail"
        _NON_OK_FINDING_COUNT=$((_NON_OK_FINDING_COUNT + 1))
    else
        printf '[infra-watcher] %s %s: %s\n' "$severity" "$category" "$detail"
    fi
}

# INFRA-2210: no-idle substrate scan. Runs only when the tick's subchecks
# found nothing critical/warning (substrate health check passes). Looks for
# filing-worthy weaknesses — launchd plists with no matching
# scripts/ci/test-*-watchdog.sh coverage — and files a P2 gap per weakness
# found (P2 is permissionless per CLAUDE.md intake firewall; no --outcome
# required). Dedupes against gaps already filed for the same plist by
# grepping ambient.jsonl for a prior infra_watcher_filed_gap on that plist
# in the last 24h, so a quiet substrate doesn't refile every tick.
_no_idle_substrate_scan() {
    local plist_dir="${REPO_ROOT}/scripts/launchd"
    [[ -d "$plist_dir" ]] || return 1
    local acted=0
    local plist base name cutoff_epoch now_epoch
    now_epoch="$(date -u +%s)"
    cutoff_epoch=$((now_epoch - 86400))
    for plist in "$plist_dir"/*.plist; do
        [[ -f "$plist" ]] || continue
        base="$(basename "$plist" .plist)"
        name="${base#com.chump.}"
        if grep -rlq "$name" "${REPO_ROOT}/scripts/ci/"test-*watchdog*.sh 2>/dev/null; then
            continue
        fi
        if grep -q "\"kind\":\"infra_watcher_filed_gap\".*\"plist\":\"${base}\"" "$AMBIENT_LOG" 2>/dev/null; then
            local last_ts last_epoch
            last_ts="$(grep "\"kind\":\"infra_watcher_filed_gap\".*\"plist\":\"${base}\"" "$AMBIENT_LOG" 2>/dev/null | tail -1 | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')"
            last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_ts" +%s 2>/dev/null || echo 0)"
            (( last_epoch > cutoff_epoch )) && continue
        fi
        printf '[infra-watcher] no-idle: %s has no watchdog test coverage — filing gap\n' "$base"
        chump gap reserve --domain INFRA --priority P2 \
            --title "RESILIENT: watchdog test coverage for launchd plist ${base}" \
            >/dev/null 2>&1 || true
        printf '{"ts":"%s","kind":"infra_watcher_filed_gap","plist":"%s"}\n' \
            "$(_ts)" "$base" >> "$AMBIENT_LOG" 2>/dev/null || true
        acted=1
    done
    (( acted == 1 )) && return 0
    return 1
}

_header() { printf '\n=== infra-watcher: %s ===\n' "$1"; }

# ── audit-daemons ─────────────────────────────────────────────────────────────
# Verify every com.chump.*.plist has StartInterval OR StartCalendarInterval.
# Optionally verify the associated process has heartbeated recently.
cmd_audit_daemons() {
    _header "audit-daemons"
    local plist_dir="${CHUMP_INFRA_WATCHER_PLIST_DIR:-${HOME}/Library/LaunchAgents}"
    local found_any=0
    local findings=0

    if [[ ! -d "$plist_dir" ]]; then
        printf '[infra-watcher] audit-daemons: LaunchAgents dir not found: %s\n' "$plist_dir"
        return 0
    fi

    while IFS= read -r -d '' plist; do
        found_any=1
        local basename
        basename="$(basename "$plist" .plist)"

        # Check for StartInterval or StartCalendarInterval or KeepAlive=true.
        # KeepAlive=true long-runners (actions-runners, nats-server, smee-tunnel,
        # fleet-daemon, curator-jit-scheduler, github-webhook-receiver) are
        # legitimately always-on and don't need a StartInterval.
        if grep -q "StartInterval\|StartCalendarInterval" "$plist" 2>/dev/null; then
            printf '[infra-watcher] OK daemon=%s has scheduling key\n' "$basename"
        elif grep -q "<key>KeepAlive</key>" "$plist" 2>/dev/null && \
             grep -A1 "<key>KeepAlive</key>" "$plist" 2>/dev/null | grep -q "<true/>"; then
            printf '[infra-watcher] OK daemon=%s is KeepAlive=true long-runner (no StartInterval needed)\n' "$basename"
        else
            findings=$((findings + 1))
            _emit_finding "daemon_plist_missing_interval" "critical" \
                "plist ${plist} has neither StartInterval nor StartCalendarInterval nor KeepAlive=true — daemon will never fire automatically"
        fi
    done < <(find "${CHUMP_INFRA_WATCHER_PLIST_DIR:-$plist_dir}" \
                  -maxdepth 1 -name "com.chump.*.plist" -print0 2>/dev/null)

    if [[ "$found_any" -eq 0 ]]; then
        printf '[infra-watcher] audit-daemons: no com.chump.*.plist files found in %s\n' \
            "${CHUMP_INFRA_WATCHER_PLIST_DIR:-$plist_dir}"
    fi

    if [[ "$findings" -eq 0 && "$found_any" -gt 0 ]]; then
        printf '[infra-watcher] audit-daemons: all plists OK\n'
    fi
    return 0
}

# ── audit-daemon-health ───────────────────────────────────────────────────────
# RESILIENT-168: plist-key audits above can't see RUNTIME state. The June
# merge-queue outage hid behind three runtime failures no check covered:
# (a) service disabled in launchd's override DB (survives every reinstall),
# (b) plist present but service never loaded, (c) loaded but repeatedly
# exiting non-zero (integrator exit=127 for ~32h). Check all three.
cmd_audit_daemon_health() {
    _header "audit-daemon-health"
    local plist_dir="${HOME}/Library/LaunchAgents"
    local findings=0
    local uid_n
    uid_n="$(id -u)"

    local disabled_list
    disabled_list="$(launchctl print-disabled "gui/${uid_n}" 2>/dev/null || true)"

    while IFS= read -r -d '' plist; do
        local label
        label="$(basename "$plist" .plist)"

        if grep -q "\"${label}\" => disabled" <<< "$disabled_list"; then
            findings=$((findings + 1))
            _emit_finding "daemon_disabled" "critical" \
                "${label} is DISABLED in launchd override DB — survives reinstalls; fix: launchctl enable gui/${uid_n}/${label} && launchctl bootstrap gui/${uid_n} ${plist}"
            continue
        fi

        local row
        row="$(launchctl list 2>/dev/null | awk -v l="$label" '$3 == l {print $1, $2}')"
        if [[ -z "$row" ]]; then
            findings=$((findings + 1))
            _emit_finding "daemon_not_loaded" "critical" \
                "${label} plist exists but service is not loaded — fix: launchctl bootstrap gui/${uid_n} ${plist}"
            continue
        fi

        local pid exit_code
        pid="${row%% *}"
        exit_code="${row##* }"
        if [[ "$pid" == "-" && "$exit_code" != "0" ]]; then
            findings=$((findings + 1))
            _emit_finding "daemon_failing" "critical" \
                "${label} last exit=${exit_code} (not running) — exit 127 means ProgramArguments binary missing; exit 78 means script path gone (stale temp-clone plist)"
        fi
    done < <(find "$plist_dir" -maxdepth 1 \
                  \( -name "com.chump.*.plist" -o -name "dev.chump.*.plist" \) \
                  -print0 2>/dev/null)

    if [[ "$findings" -eq 0 ]]; then
        printf '[infra-watcher] audit-daemon-health: all loaded, enabled, exit-0\n'
    fi
    return 0
}

# ── check-runners ─────────────────────────────────────────────────────────────
# Detect ghost-online: ≥1 job queued >5min AND ≥1 runner online+idle.
# Invokes META-100 detection script if it exists.
cmd_check_runners() {
    _header "check-runners"

    # Delegate to META-100 runner-monitor if it exists
    local runner_monitor="${REPO_ROOT}/scripts/ops/runner-ghost-monitor.sh"
    if [[ -x "$runner_monitor" ]]; then
        printf '[infra-watcher] check-runners: delegating to %s\n' "$runner_monitor"
        bash "$runner_monitor" && return 0 || true
    fi

    # Standalone ghost-online detection
    local gh_bin="${CHUMP_GH_BIN:-gh}"
    local repo_slug
    repo_slug="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
        | sed 's|.*github.com[:/]||; s|\.git$||')"

    # Get runner state — fail gracefully if gh unavailable
    local runners_json
    if ! runners_json="$("$gh_bin" api "repos/${repo_slug}/actions/runners" --paginate 2>/dev/null)"; then
        printf '[infra-watcher] check-runners: gh api unavailable — skipping runner check\n'
        return 0
    fi

    # Count idle online runners
    local idle_count
    idle_count="$(printf '%s' "$runners_json" \
        | python3 -c "
import json,sys
d=json.load(sys.stdin)
runners=d.get('runners',d) if isinstance(d,dict) else d
print(sum(1 for r in runners if r.get('status')=='online' and r.get('busy')==False))
" 2>/dev/null || echo 0)"

    if [[ "$idle_count" -eq 0 ]]; then
        printf '[infra-watcher] check-runners: no idle online runners — cannot be ghost-online\n'
        return 0
    fi

    # Check for queued runs older than 5 minutes. INFRA-2464: `gh run list`
    # is a GraphQL call; the REST equivalent (actions/runs?status=queued)
    # hits the REST bucket instead, which stays healthy during GraphQL
    # exhaustion — and reuses repo_slug resolved above instead of a second
    # lookup.
    local queued_json
    if ! queued_json="$("$gh_bin" api "repos/${repo_slug}/actions/runs?status=queued&per_page=20" \
        --jq '.workflow_runs' 2>/dev/null)"; then
        printf '[infra-watcher] check-runners: cannot read queued runs — skipping\n'
        return 0
    fi

    local ghost_count
    ghost_count="$(printf '%s' "$queued_json" \
        | python3 -c "
import json,sys
from datetime import datetime, timezone, timedelta
runs=json.load(sys.stdin)
cutoff=datetime.now(timezone.utc) - timedelta(minutes=5)
old=[r for r in runs if datetime.fromisoformat(r['created_at'].replace('Z','+00:00')) < cutoff]
print(len(old))
" 2>/dev/null || echo 0)"

    if [[ "$ghost_count" -gt 0 ]]; then
        _emit_finding "runner_ghost_online" "critical" \
            "${ghost_count} job(s) queued >5min with ${idle_count} runner(s) online+idle — ghost-online condition; runs may wedge indefinitely"
    else
        printf '[infra-watcher] check-runners: OK — %d idle runner(s), no queued runs >5min\n' "$idle_count"
    fi
    return 0
}

# ── check-disk ────────────────────────────────────────────────────────────────
# Flag any watched path >85% used.
cmd_check_disk() {
    _header "check-disk"

    local threshold="${CHUMP_INFRA_WATCHER_DISK_THRESHOLD:-85}"
    local locks_dir="${REPO_ROOT}/.chump-locks"

    # Paths to check — fall back gracefully if path missing
    local paths=()
    for p in /tmp /private/tmp "$locks_dir"; do
        [[ -e "$p" ]] && paths+=("$p")
    done

    if [[ "${#paths[@]}" -eq 0 ]]; then
        printf '[infra-watcher] check-disk: no paths to check\n'
        return 0
    fi

    local any_critical=0
    while IFS= read -r line; do
        # Parse df -h output: filesystem, size, used, avail, pct, mountpoint
        local pct
        pct="$(printf '%s' "$line" | awk '{print $5}' | tr -d '%')"
        local mountpoint
        mountpoint="$(printf '%s' "$line" | awk '{print $NF}')"
        if [[ "$pct" =~ ^[0-9]+$ ]] && [[ "$pct" -ge "$threshold" ]]; then
            any_critical=1
            local severity="warning"
            [[ "$pct" -ge 95 ]] && severity="critical"
            _emit_finding "disk_pressure" "$severity" \
                "path=${mountpoint} at ${pct}% (threshold=${threshold}%) — disk pressure detected"
        else
            printf '[infra-watcher] check-disk: OK %s at %s%%\n' "$mountpoint" "${pct:-?}"
        fi
    done < <("${CHUMP_DF_BIN:-df}" -h "${paths[@]}" 2>/dev/null | tail -n +2)

    [[ "$any_critical" -eq 0 ]] && printf '[infra-watcher] check-disk: all paths below %d%% threshold\n' "$threshold"
    return 0
}

# ── check-disk-headroom ─────────────────────────────────────────────────────
# INFRA-7890: disk defense was reactive-only — nothing paged until the
# cargo-target-reaper's own DISK_CRITICAL_GB (default 20) free-GB floor was
# already breached, at which point the reaper's aggressive mode is the first
# and only signal. This check pages BEFORE that floor: it trends free-GB on
# $HOME against the same DISK_CRITICAL_GB floor plus a margin, so an operator
# (or the reaper) gets advance warning while there's still headroom to act.
cmd_check_disk_headroom() {
    _header "check-disk-headroom"

    local critical_gb="${CHUMP_DISK_CRITICAL_GB:-20}"
    local margin_gb="${CHUMP_INFRA_WATCHER_DISK_MARGIN_GB:-15}"
    local warn_floor=$(( critical_gb + margin_gb ))

    local free_kb free_gb
    free_kb="$("${CHUMP_DF_BIN:-df}" -k "$HOME" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ ! "$free_kb" =~ ^[0-9]+$ ]]; then
        printf '[infra-watcher] check-disk-headroom: could not read free space for %s — skipping\n' "$HOME"
        return 0
    fi
    free_gb=$(( free_kb / 1024 / 1024 ))

    if [[ "$free_gb" -lt "$critical_gb" ]]; then
        _emit_finding "disk_headroom" "critical" \
            "free=${free_gb}GB on \$HOME is BELOW the cargo-target-reaper critical floor (${critical_gb}GB) — reaper aggressive mode should already be engaged; page if it is not"
    elif [[ "$free_gb" -lt "$warn_floor" ]]; then
        _emit_finding "disk_headroom" "warning" \
            "free=${free_gb}GB on \$HOME is trending toward the ${critical_gb}GB critical floor (margin=${margin_gb}GB, warn_floor=${warn_floor}GB) — proactive action recommended before the reactive reaper kicks in"
    else
        printf '[infra-watcher] check-disk-headroom: OK free=%dGB (warn_floor=%dGB, critical_floor=%dGB)\n' \
            "$free_gb" "$warn_floor" "$critical_gb"
    fi
    return 0
}

# ── check-procs ───────────────────────────────────────────────────────────────
# Flag if claude proc count >100 OR load_avg_1m >10.
cmd_check_procs() {
    _header "check-procs"

    local proc_threshold="${CHUMP_INFRA_WATCHER_PROC_THRESHOLD:-100}"
    local load_threshold="${CHUMP_INFRA_WATCHER_LOAD_THRESHOLD:-10}"

    # Claude process count
    local claude_count=0
    if command -v pgrep >/dev/null 2>&1; then
        claude_count="$("${CHUMP_PGREP_BIN:-pgrep}" -f 'MacOS/claude' 2>/dev/null | wc -l | tr -d ' ')"
    fi

    # Load average (1-minute)
    local load_avg_1m="0"
    if [[ -f /proc/loadavg ]]; then
        load_avg_1m="$(awk '{print $1}' /proc/loadavg)"
    elif command -v sysctl >/dev/null 2>&1; then
        load_avg_1m="$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}' || echo 0)"
    fi

    printf '[infra-watcher] check-procs: claude_count=%d load_avg_1m=%s\n' "$claude_count" "$load_avg_1m"

    local findings=0

    if [[ "$claude_count" -gt "$proc_threshold" ]]; then
        findings=$((findings + 1))
        _emit_finding "process_bloat" "critical" \
            "claude process count=${claude_count} exceeds threshold=${proc_threshold} — possible proc leak or runaway reaper"
    fi

    # Compare load avg as integer (truncate)
    local load_int
    load_int="${load_avg_1m%%.*}"
    load_int="${load_int:-0}"
    if [[ "$load_int" =~ ^[0-9]+$ ]] && [[ "$load_int" -gt "$load_threshold" ]]; then
        findings=$((findings + 1))
        _emit_finding "process_bloat" "warning" \
            "load_avg_1m=${load_avg_1m} exceeds threshold=${load_threshold} — system under heavy load"
    fi

    [[ "$findings" -eq 0 ]] && printf '[infra-watcher] check-procs: OK\n'
    return 0
}

# ── check-ptys ────────────────────────────────────────────────────────────────
# RESILIENT-092: a long Claude-Code /loop session leaked 505 master ptys ->
# kern.tty.ptmx_max=511 EXHAUSTED -> forkpty 'Device not configured'
# MACHINE-WIDE -> terminals unusable + fleet down ~2h. This check detects the
# same class of pressure BEFORE forkpty actually fails, and pages the
# operator (not just logs a finding) once usage crosses the threshold — the
# existing claude-reaper pressure mode (INFRA-1851) reacts by reaping faster
# but never escalates to the operator, so a leak outside the reaper's reach
# (e.g. the Claude.app GUI process itself, which the reaper won't touch)
# would silently run the machine to exhaustion again.
#
# Cross-platform: macOS reports the ceiling via `sysctl -n kern.tty.ptmx_max`
# and allocation via counting /dev/ttys??? device files. Linux reports both
# directly via /proc/sys/kernel/pty/{max,nr}. If neither probe resolves, the
# check no-ops rather than guessing (same safe-by-default posture as the
# reaper's pressure block).
#
# scanner-anchor: "kind":"infra_watcher_finding" category=pty_exhaustion
cmd_check_ptys() {
    _header "check-ptys"

    local threshold="${CHUMP_INFRA_WATCHER_PTY_THRESHOLD:-80}"
    local limit="" alloc=""

    if [[ -n "${CHUMP_PTY_LIMIT_OVERRIDE:-}" ]]; then
        limit="$CHUMP_PTY_LIMIT_OVERRIDE"
    elif [[ -f /proc/sys/kernel/pty/max ]]; then
        limit="$(cat /proc/sys/kernel/pty/max 2>/dev/null || true)"
    elif command -v "${CHUMP_SYSCTL_BIN:-sysctl}" >/dev/null 2>&1; then
        limit="$("${CHUMP_SYSCTL_BIN:-sysctl}" -n kern.tty.ptmx_max 2>/dev/null || true)"
    fi

    if [[ -n "${CHUMP_PTY_ALLOC_OVERRIDE:-}" ]]; then
        alloc="$CHUMP_PTY_ALLOC_OVERRIDE"
    elif [[ -f /proc/sys/kernel/pty/nr ]]; then
        alloc="$(cat /proc/sys/kernel/pty/nr 2>/dev/null || true)"
    else
        alloc="$(ls /dev/ttys??? 2>/dev/null | wc -l | tr -d ' ')"
    fi

    if [[ -z "$limit" || -z "$alloc" || ! "$limit" =~ ^[0-9]+$ || ! "$alloc" =~ ^[0-9]+$ || "$limit" -eq 0 ]]; then
        printf '[infra-watcher] check-ptys: unable to determine pty limit/allocation (limit=%s alloc=%s) — skipping\n' \
            "${limit:-?}" "${alloc:-?}"
        return 0
    fi

    local pct=$(( alloc * 100 / limit ))
    printf '[infra-watcher] check-ptys: allocated=%s limit=%s pct=%d%% (threshold=%d%%)\n' \
        "$alloc" "$limit" "$pct" "$threshold"

    if [[ "$pct" -ge "$threshold" ]]; then
        local severity="warning"
        [[ "$pct" -ge 95 ]] && severity="critical"
        _emit_finding "pty_exhaustion" "$severity" \
            "allocated=${alloc} limit=${limit} pct=${pct}% (threshold=${threshold}%) — forkpty exhaustion imminent; restart the leaking Claude Code app or raise kern.tty.ptmx_max"

        # Scream: page the operator directly via the halt-class recall
        # channel BEFORE forkpty actually fails machine-wide, rather than
        # relying on a downstream consumer to notice the critical finding.
        local recall_script="${SCRIPT_DIR}/../dispatch/operator-recall.sh"
        if [[ -f "$recall_script" ]]; then
            bash "$recall_script" --condition PTY_EXHAUSTION \
                --reason "pty allocation ${alloc}/${limit} (${pct}%) >= ${threshold}% threshold — forkpty failure imminent, restart leaking Claude Code app" \
                >/dev/null 2>&1 || true
        fi
    else
        printf '[infra-watcher] check-ptys: OK\n'
    fi
    return 0
}

# ── check-repo-vars ───────────────────────────────────────────────────────────
# Compare live gh variable list against expected-repo-vars.yaml.
# Emits kind=repo_var_stale_after_incident when a variable has deviated from its
# expected value for more than CHUMP_INFRA_WATCHER_REPO_VAR_DRIFT_SECS (default 7200s = 2h).
# State is tracked in .chump-locks/repo-var-divergence-state.json so each
# infra-watcher tick can measure elapsed drift time without external timestamps.
#
# INFRA-1976: root cause — CHUMP_SELF_HOSTED_ENABLED=false sat unrecovered 4 days.
cmd_check_repo_vars() {
    _header "check-repo-vars"

    local expected_yaml="${REPO_ROOT}/scripts/setup/expected-repo-vars.yaml"
    local state_file="${REPO_ROOT}/.chump-locks/repo-var-divergence-state.json"
    local drift_threshold="${CHUMP_INFRA_WATCHER_REPO_VAR_DRIFT_SECS:-7200}"
    local gh_bin="${CHUMP_GH_BIN:-gh}"
    local repo_slug

    # Resolve repo slug from git remote (fail gracefully).
    # CHUMP_INFRA_WATCHER_REPO_SLUG overrides for testing.
    if [[ -n "${CHUMP_INFRA_WATCHER_REPO_SLUG:-}" ]]; then
        repo_slug="$CHUMP_INFRA_WATCHER_REPO_SLUG"
    else
        repo_slug="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
            | sed 's|.*github.com[:/]||; s|\.git$||')" || true
    fi

    if [[ -z "$repo_slug" ]]; then
        printf '[infra-watcher] check-repo-vars: cannot resolve repo slug — skipping\n'
        return 0
    fi

    if [[ ! -f "$expected_yaml" ]]; then
        printf '[infra-watcher] check-repo-vars: expected-repo-vars.yaml not found at %s — skipping\n' \
            "$expected_yaml"
        return 0
    fi

    # Fetch live variable list (fail gracefully — gh may be offline)
    local live_vars_json
    if ! live_vars_json="$("$gh_bin" variable list \
            --repo "$repo_slug" --json name,value 2>/dev/null)"; then
        printf '[infra-watcher] check-repo-vars: gh variable list failed — skipping\n'
        return 0
    fi

    # Read current divergence state (empty object if missing)
    local state_json="{}"
    [[ -f "$state_file" ]] && state_json="$(cat "$state_file" 2>/dev/null || echo "{}")"

    local now_epoch
    now_epoch="$(date -u +%s)"

    local new_state_json="{}"
    local findings=0

    # Parse expected vars from YAML using python3 (already required by other checks).
    # Pass the YAML path as argv[1] to avoid heredoc-vs-redirect ambiguity.
    local expected_pairs
    expected_pairs="$(python3 -c '
import sys, re

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        content = f.read()
except Exception:
    sys.exit(0)

# Simple YAML parse: extract name/expected pairs under repo_vars:
in_vars = False
current_name = ""
for line in content.splitlines():
    stripped = line.strip()
    if stripped == "repo_vars:":
        in_vars = True
        continue
    if not in_vars:
        continue
    m = re.match(r"- name:\s+\"?([^\"]+)\"?\s*$", stripped)
    if m:
        current_name = m.group(1).strip()
        continue
    m = re.match(r"expected:\s+\"?([^\"#]+)\"?\s*$", stripped)
    if m and current_name:
        print(current_name + "\t" + m.group(1).strip())
        current_name = ""
' "$expected_yaml" 2>/dev/null)" || true

    if [[ -z "$expected_pairs" ]]; then
        printf '[infra-watcher] check-repo-vars: no entries parsed from %s — skipping\n' \
            "$expected_yaml"
        return 0
    fi

    while IFS=$'\t' read -r var_name expected_val; do
        [[ -z "$var_name" ]] && continue

        # Look up live value
        local actual_val
        actual_val="$(printf '%s' "$live_vars_json" \
            | python3 -c "
import json, sys
data = json.load(sys.stdin)
for v in data:
    if v.get('name','') == '${var_name}':
        print(v.get('value',''))
        sys.exit(0)
print('')
" 2>/dev/null || echo "")"

        if [[ "$actual_val" == "$expected_val" ]]; then
            # Variable matches expected — clear any tracked divergence for this var
            new_state_json="$(printf '%s' "$new_state_json" \
                | python3 -c "
import json, sys
s = json.load(sys.stdin)
s.pop('${var_name}', None)
print(json.dumps(s))
" 2>/dev/null || echo "$new_state_json")"
            printf '[infra-watcher] check-repo-vars: OK %s=%s\n' "$var_name" "$actual_val"
            continue
        fi

        # Mismatch — check how long it has diverged
        local first_seen_epoch
        first_seen_epoch="$(printf '%s' "$state_json" \
            | python3 -c "
import json, sys
s = json.load(sys.stdin)
print(s.get('${var_name}', {}).get('first_seen_epoch', 0))
" 2>/dev/null || echo 0)"

        if [[ "$first_seen_epoch" -eq 0 ]]; then
            # First detection — record but don't alert yet
            first_seen_epoch="$now_epoch"
            printf '[infra-watcher] check-repo-vars: NEW DIVERGENCE %s: expected=%s actual=%s (monitoring for %ds before alerting)\n' \
                "$var_name" "$expected_val" "$actual_val" "$drift_threshold"
        fi

        # Persist divergence timestamp
        new_state_json="$(printf '%s' "$new_state_json" \
            | python3 -c "
import json, sys
s = json.load(sys.stdin)
s['${var_name}'] = {'first_seen_epoch': ${first_seen_epoch}, 'expected': '${expected_val}', 'actual': '${actual_val}'}
print(json.dumps(s))
" 2>/dev/null || echo "$new_state_json")"

        local elapsed_secs=$(( now_epoch - first_seen_epoch ))

        if [[ "$elapsed_secs" -ge "$drift_threshold" ]]; then
            findings=$((findings + 1))
            local diverged_since
            diverged_since="$(date -u -r "$first_seen_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
                || python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp(${first_seen_epoch}, timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" 2>/dev/null \
                || echo "unknown")"
            local elapsed_h=$(( elapsed_secs / 3600 ))
            local ts
            ts="$(_ts)"
            printf '{"ts":"%s","kind":"repo_var_stale_after_incident","var_name":"%s","expected_value":"%s","actual_value":"%s","diverged_since":"%s","elapsed_hours":%d}\n' \
                "$ts" "$var_name" "$expected_val" "$actual_val" "$diverged_since" "$elapsed_h" \
                >> "$AMBIENT_LOG"
            printf '[infra-watcher] ALERT check-repo-vars: %s expected=%s actual=%s diverged_since=%s (%dh)\n' \
                "$var_name" "$expected_val" "$actual_val" "$diverged_since" "$elapsed_h" >&2
        else
            local remaining=$(( drift_threshold - elapsed_secs ))
            printf '[infra-watcher] check-repo-vars: DIVERGENCE %s expected=%s actual=%s elapsed=%ds (alert in %ds)\n' \
                "$var_name" "$expected_val" "$actual_val" "$elapsed_secs" "$remaining"
        fi
    done <<< "$expected_pairs"

    # Write updated state file
    printf '%s\n' "$new_state_json" > "$state_file" 2>/dev/null || true

    [[ "$findings" -eq 0 ]] && printf '[infra-watcher] check-repo-vars: audit complete — no stale vars above drift threshold\n'
    return 0
}

# ── check-oauth-freshness ────────────────────────────────────────────────────
# INFRA-2124: verify ~/.chump/oauth-token.json is fresh. If the file is older
# than CHUMP_OAUTH_STALE_S (default 900s = 15 min) AND launchd shows the
# com.chump.oauth-refresh plist loaded, emit
# kind=oauth_token_stale_despite_daemon — refresher daemon is wedged. If the
# file is stale and the plist is NOT loaded, that's just "operator hasn't
# installed it yet" — emit a warning but a different (less alarming) kind.
#
# RESILIENT-056: also parse expires_at (claudeAiOauth.expiresAt, captured by
# oauth-token-refresh.sh) so a token gets flagged from its own claimed expiry
# even when mtime alone still looks fresh — a refresh can write a token that
# was already near-expired (short-lived reissue, clock skew, etc). Either
# signal (mtime > stale_s OR expiry within CHUMP_OAUTH_EXPIRY_WARN_S) emits a
# single unified kind=auth_token_stale event within one 15-min tick, which
# widens the operator-recall AUTH_DEAD trigger (scripts/dispatch/operator-recall.sh).
# scanner-anchor: "kind":"oauth_token_stale_despite_daemon"
# scanner-anchor: "kind":"auth_token_stale"
cmd_check_oauth_freshness() {
    _header "check-oauth-freshness"
    local token_file="${CHUMP_OAUTH_TOKEN_FILE:-${HOME}/.chump/oauth-token.json}"
    local stale_s="${CHUMP_OAUTH_STALE_S:-900}"
    local expiry_warn_s="${CHUMP_OAUTH_EXPIRY_WARN_S:-600}"
    local plist_label="com.chump.oauth-refresh"

    if [[ ! -f "$token_file" ]]; then
        printf '[infra-watcher] check-oauth-freshness: token file not present: %s\n' "$token_file"
        return 0
    fi

    local now mtime age
    now="$(date +%s)"
    if stat -f %m "$token_file" >/dev/null 2>&1; then
        mtime="$(stat -f %m "$token_file")"
    else
        mtime="$(stat -c %Y "$token_file")"
    fi
    age=$((now - mtime))

    # expires_at may be an ISO-8601 string or an epoch (seconds or ms) —
    # accept either shape since the source Keychain blob's format isn't
    # contractually fixed. Absence (empty string) is not an error: older
    # token files predate RESILIENT-056 and simply skip the expiry check.
    local expires_epoch
    expires_epoch="$(python3 -c "
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open('${token_file}'))
    exp = d.get('expires_at', '')
    if not exp:
        sys.exit(0)
    try:
        v = float(exp)
        if v > 1e12:
            v = v / 1000.0
        print(int(v))
        sys.exit(0)
    except ValueError:
        pass
    s = str(exp).rstrip('Z')
    dt = datetime.fromisoformat(s).replace(tzinfo=timezone.utc)
    print(int(dt.timestamp()))
except Exception:
    pass
" 2>/dev/null)"

    local expiry_secs_left="" expiry_stale=0
    if [[ -n "$expires_epoch" ]]; then
        expiry_secs_left=$((expires_epoch - now))
        (( expiry_secs_left <= expiry_warn_s )) && expiry_stale=1
    fi

    local mtime_stale=0
    (( age > stale_s )) && mtime_stale=1

    printf '[infra-watcher] check-oauth-freshness: %s age=%ds (threshold=%ds) expires_in=%ss (threshold=%ds)\n' \
        "$token_file" "$age" "$stale_s" "${expiry_secs_left:-n/a}" "$expiry_warn_s"

    if (( mtime_stale == 0 && expiry_stale == 0 )); then
        return 0
    fi

    # Is the refresh daemon supposedly loaded?
    local daemon_loaded=0
    if launchctl list 2>/dev/null | grep -q "$plist_label"; then
        daemon_loaded=1
    fi

    local reason="expiry"
    if (( mtime_stale == 1 && expiry_stale == 1 )); then
        reason="mtime_and_expiry"
    elif (( mtime_stale == 1 )); then
        reason="mtime"
    fi

    local ts
    ts="$(_ts)"
    printf '{"ts":"%s","kind":"auth_token_stale","token_file":"%s","age_seconds":%d,"stale_threshold_s":%d,"expiry_secs_left":%s,"daemon_loaded":%s,"reason":"%s"}\n' \
        "$ts" "$token_file" "$age" "$stale_s" "${expiry_secs_left:-null}" \
        "$([[ "$daemon_loaded" -eq 1 ]] && echo true || echo false)" "$reason" \
        >> "$AMBIENT_LOG"
    printf '[infra-watcher] ALERT check-oauth-freshness: auth_token_stale reason=%s age=%ds expiry_secs_left=%s daemon_loaded=%s\n' \
        "$reason" "$age" "${expiry_secs_left:-n/a}" "$daemon_loaded" >&2

    if (( daemon_loaded == 1 )); then
        _emit_finding "oauth_token_stale_despite_daemon" "critical" \
            "token_file=${token_file} age=${age}s daemon=${plist_label}/loaded reason=${reason} — refresher is wedged, manual investigation required"
    else
        _emit_finding "oauth_token_stale_no_daemon" "warning" \
            "token_file=${token_file} age=${age}s daemon=${plist_label}/not-loaded reason=${reason} — install via scripts/setup/install-oauth-refresh-launchd.sh"
    fi
}

# ── tick ──────────────────────────────────────────────────────────────────────
# One full audit cycle: all subchecks in order.
cmd_tick() {
    local ts
    ts="$(_ts)"
    printf '[infra-watcher] tick start ts=%s\n' "$ts"
    cmd_audit_daemons
    cmd_audit_daemon_health
    cmd_check_runners
    cmd_check_disk
    cmd_check_disk_headroom
    cmd_check_procs
    cmd_check_ptys
    cmd_check_repo_vars
    cmd_check_oauth_freshness

    # INFRA-2210: no-idle — substrate health check passed (no critical/
    # warning findings this cycle) means we go looking for filing-worthy
    # weaknesses instead of just exiting quiet.
    if (( _NON_OK_FINDING_COUNT == 0 )); then
        # shellcheck source=/dev/null
        if source "$(dirname "$0")/lib/no-idle.sh" 2>/dev/null && _no_idle_substrate_scan; then
            printf '{"ts":"%s","kind":"curator_no_op_avoided","session":"%s","role":"infra-watcher","action":"substrate_scan"}\n' \
                "$(_ts)" "${CHUMP_SESSION_ID:-infra-watcher-$$}" >> "$AMBIENT_LOG" 2>/dev/null || true
            printf '[infra-watcher] no-op avoided — filed substrate weakness gap(s) instead of idling\n'
        else
            printf '[infra-watcher] substrate healthy, no filing-worthy weaknesses found\n'
        fi
    fi

    printf '[infra-watcher] tick complete ts=%s\n' "$(_ts)"
}

# ── main ──────────────────────────────────────────────────────────────────────
CMD="${1:-tick}"
shift || true

# INFRA-1798: mandatory Glance phase — drain + act on inbox before any work.
if [[ "$CMD" != "help" && "$CMD" != "-h" && "$CMD" != "--help" ]]; then
    source "$(dirname "$0")/lib/inbox-glance.sh" 2>/dev/null && chump_inbox_glance "infra-watcher" || true
fi

case "$CMD" in
    tick)                    cmd_tick "$@" ;;
    audit-daemons)           cmd_audit_daemons "$@" ;;
    audit-daemon-health)     cmd_audit_daemon_health "$@" ;;
    check-runners)           cmd_check_runners "$@" ;;
    check-disk)              cmd_check_disk "$@" ;;
    check-disk-headroom)     cmd_check_disk_headroom "$@" ;;
    check-procs)             cmd_check_procs "$@" ;;
    check-ptys)              cmd_check_ptys "$@" ;;
    check-repo-vars)         cmd_check_repo_vars "$@" ;;
    check-oauth-freshness)   cmd_check_oauth_freshness "$@" ;;
    *)
        printf 'Usage: %s {tick|audit-daemons|check-runners|check-disk|check-disk-headroom|check-procs|check-ptys|check-repo-vars|check-oauth-freshness}\n' \
            "$(basename "$0")" >&2
        exit 1
        ;;
esac
