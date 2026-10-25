#!/usr/bin/env bash
# fleet-doctor-strict.sh — INFRA-1427
#
# Single command exits non-zero if ANY fleet health check fails.
# "One number for: is the fleet healthy?"
#
# Usage
#   scripts/coord/fleet-doctor-strict.sh [--json] [--verbose]
#
# Checks (all must pass for exit 0)
#   1. binary           — chump binary exists and is not stale vs source
#   2. leases           — no expired leases older than LEASE_STALE_HOURS (default 2)
#   3. disk             — free disk >= DISK_MIN_GB (default 5)
#   4. dirty-prs        — no open PRs in DIRTY state for > DIRTY_PR_HOURS (default 24)
#   5. gap-drift        — no unresolved gap-drift (open gaps with closed PRs, etc.)
#   6. p0-budget        — open P0 gap count <= P0_MAX (default 5)
#   7. pillar-cover     — every pillar has >= PILLAR_MIN (default 2) pickable gaps
#   8. silent-fleet-death — INFRA-2040: last-merge-mtime >12h AND any com/dev.chump.*
#                           launchd daemon has last exit code != 0 → emit
#                           kind=silent_fleet_death; optional auto-heal via
#                           CHUMP_DOCTOR_AUTOHEAL=1
#   9. backlog-sync    — CREDIBLE-292: registry/main's .chump/state.sql must not be
#                        >CHUMP_BACKLOG_SYNC_STALE_HOURS (default 24) stale — a
#                        dead backlog-sync --writer is the registry split-brain
#                        precursor.
#   13. auth-probe      — CREDIBLE-119: live Anthropic auth-path validity (reuses
#                        scripts/coord/auth-status.sh, RESILIENT-086) — fails when
#                        credential PRESENCE checks would report healthy but a
#                        real authenticated call rejects both paths.
#   14. organ-roll-call-live — INFRA-3646 (TREK-20): every applicable `enabled`
#                        organ-manifest.txt line must be `systemctl is-active`
#                        RIGHT NOW, not just declared. Non-applicable organs
#                        (unmet requires=) skip; dead organs in an
#                        organ-reconcile.sh backoff cooldown are distinguished
#                        from dead-and-unowned ones in the failure detail.
#   15. self-healer-heartbeat — RESILIENT-1053 (originally scoped as RESILIENT-1052; re-filed to avoid a duplicate-PR collision with #4515): the self-healers watch every
#                        OTHER organ but nothing watched THEM (chump-organ-
#                        reconcile.timer is deliberately excluded from
#                        organ-manifest.txt). FAILs + pages
#                        (kind=self_healer_heartbeat_stale) if
#                        organ_watchdog_tick or organ_reconcile_applied/noop
#                        goes stale past its cadence, or has never ticked at
#                        all while the other has.
#   16. tracked-config-drift — RESILIENT-1106 (Track A, RESILIENT-1102 /
#                        docs/design/DESIGN_GAPS_SELF_RUNNING.md): #4593
#                        pulled worker self-heal policy into tracked
#                        scripts/setup/*.env files, but a node's hand-deployed,
#                        git-UNTRACKED launcher (~/node1-worker-run.sh,
#                        ~/.chump/providers.env) can still hard-set the SAME
#                        var to a DIFFERENT value and silently win — exactly
#                        the class of drift #4593 tried to close. FAILs +
#                        pages (kind=tracked_config_drift) when a live
#                        untracked file's literal `VAR=value` assignment
#                        disagrees with the tracked file's canonical value.
#                        Skips (not fail) when no untracked override files
#                        are present on this node — nothing outside git to
#                        drift from.
#   17. checkout-parked-off-main — RESILIENT-1512: REPO_ROOT's checked-out
#                        branch sitting on something other than `main` for
#                        longer than CHECKOUT_PARKED_STALE_S pages
#                        (kind=checkout_parked_off_main) — the hub-node
#                        failure mode where a stale/parked checkout silently
#                        degrades `gap ship` proof-of-merge and other
#                        main-relative tooling until someone notices by hand.
#   18. single-branch-refspec — INFRA-8210: REPO_ROOT's remote.origin.fetch is
#                        a single-branch refspec instead of all-branches
#                        (+refs/heads/*:refs/remotes/origin/*), so remote
#                        feature branches never fetch — the cuphead-hub failure
#                        mode that silently broke dispatch resume, salvage, and
#                        rebases (kind=checkout_single_branch_refspec).
#   19. admission-ceiling — RESILIENT-1604: RED when the live `claude -p` or
#                        cargo/rustc count on this node exceeds its admission
#                        ceiling (CHUMP_MAX_CONCURRENT_CLAUDE /
#                        CHUMP_MAX_CONCURRENT_CARGO_JOBS: env > node.env >
#                        max(1, nproc/2), the src/admit.rs precedence). Counts
#                        with the same pgrep -f patterns `chump admit` uses.
#   21. cargo-storage   — RESILIENT-1670 (RESILIENT-1657 item a'): RED when
#                        readlink -f of CARGO_HOME, CARGO_TARGET_DIR or the
#                        sccache dir lands on a block device whose `lsblk -no
#                        TRAN` is `usb` or whose RM (removable) flag is 1 — the
#                        closetjunky failure mode where ~/.cargo + the build
#                        target lived on a USB flash stick and writeback stalls
#                        wedged the whole node. Each path on a fixed disk, or
#                        absent, passes.
#   22. cargo-nextest   — INFRA-8572: RED when `cargo-nextest` is absent from
#                        PATH and `${CARGO_HOME:-$HOME/.cargo}/bin/cargo-nextest`
#                        on a Linux/macOS host (prevents silent fallback to
#                        in-process threaded `cargo test`).
#
# Thresholds (override via env)
#   LEASE_STALE_HOURS         default 2    — leases older than N hours are flagged
#   DISK_MIN_GB               default 5    — fail if free disk below N GB
#   DISK_PRESSURE_PCT         default 90   — fail if REPO_ROOT (or any path in
#                              CHUMP_DISK_PRESSURE_PATHS) is at/above N percent used
#   CHUMP_DISK_PRESSURE_PATHS default REPO_ROOT — space-separated extra mounts to check
#                              (e.g. "/ /mnt/cjdata1" on a CJ coordinator node)
#   DIRTY_PR_HOURS            default 24   — DIRTY PRs older than N hours are flagged
#   P0_MAX                    default 5    — fail if more than N open P0 gaps
#   PILLAR_MIN                default 2    — fail if any pillar has fewer than N pickable gaps
#   SILENT_DEATH_MERGE_HOURS  default 12   — last-merge older than N hours triggers check 1
#   CHUMP_DOCTOR_AUTOHEAL     default 0    — set 1 to auto-restore missing scripts + bounce daemons
#   CHUMP_CONFIG_DRIFT_TRACKED_GLOB  default "scripts/setup/*.env" — tracked
#                              config-as-code files that hold canonical policy
#   CHUMP_CONFIG_DRIFT_LIVE_GLOB     default "$HOME/*-worker-run.sh
#                              $HOME/.chump/providers.env
#                              $HOME/.chump/chumpd.env" — untracked, node-local
#                              files that may hand-set the same vars
#   CHECKOUT_PARKED_STALE_S   default 3600 — REPO_ROOT checked out on a
#                              non-main branch for longer than N seconds fails
#

# Bypass: CHUMP_FLEET_DOCTOR=0 exits 0 (for scripted contexts that want raw signal).
#
# Rust-First-Bypass: read-only health aggregator over existing CLI tools; no
#   state mutation; operator diagnostic called on demand, not in hot path.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
AMBIENT_EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
CHUMP_BIN="${CHUMP_BIN:-chump}"

# ── Thresholds ─────────────────────────────────────────────────────────────────
LEASE_STALE_HOURS="${LEASE_STALE_HOURS:-2}"
DISK_MIN_GB="${DISK_MIN_GB:-5}"
DIRTY_PR_HOURS="${DIRTY_PR_HOURS:-24}"
P0_MAX="${P0_MAX:-5}"
PILLAR_MIN="${PILLAR_MIN:-2}"
SILENT_DEATH_MERGE_HOURS="${SILENT_DEATH_MERGE_HOURS:-12}"
CHUMP_DOCTOR_AUTOHEAL="${CHUMP_DOCTOR_AUTOHEAL:-0}"

# ── Arg parsing ────────────────────────────────────────────────────────────────
OUTPUT="human"     # or "json"
VERBOSE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    OUTPUT="json"; shift ;;
        --verbose) VERBOSE=1; shift ;;
        -h|--help)
            sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 2 ;;
    esac
done

if [[ "${CHUMP_FLEET_DOCTOR:-1}" == "0" ]]; then
    exit 0
fi

# ── Check harness ─────────────────────────────────────────────────────────────
CHECKS=()       # parallel arrays: CHECK_NAME, CHECK_STATUS, CHECK_DETAIL, CHECK_REMEDY
STATUSES=()
DETAILS=()
REMEDIES=()
PASS_COUNT=0
FAIL_COUNT=0

register_check() {
    local name="$1" status="$2" detail="$3" remedy="$4"
    CHECKS+=("$name")
    STATUSES+=("$status")
    DETAILS+=("$detail")
    REMEDIES+=("$remedy")
    if [[ "$status" == "pass" ]]; then
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

# ── Check 1: Binary staleness ──────────────────────────────────────────────────
check_binary() {
    local binary_path
    binary_path="$(command -v "$CHUMP_BIN" 2>/dev/null || true)"
    if [[ -z "$binary_path" ]]; then
        register_check "binary" "fail" \
            "chump binary not found in PATH" \
            "cd $REPO_ROOT && cargo build --bin chump"
        return
    fi

    # Compare binary mtime vs most recent src/ change.
    local src_newest_mtime
    src_newest_mtime="$(find "$REPO_ROOT/src" -name '*.rs' -newer "$binary_path" \
        2>/dev/null | head -1)"

    # RESILIENT-1568: deployed binary commit vs origin/main, plus stray copies.
    local bin_sha main_sha lag="" copies="" c
    bin_sha="$("$binary_path" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || true)"
    main_sha="$(git -C "$REPO_ROOT" rev-parse --short=8 origin/main 2>/dev/null || true)"
    if [[ -n "$bin_sha" && -n "$main_sha" && "$main_sha" != "$bin_sha"* && "$bin_sha" != "$main_sha"* ]]; then
        if git -C "$REPO_ROOT" merge-base --is-ancestor "$bin_sha" origin/main 2>/dev/null; then
            lag="$(git -C "$REPO_ROOT" rev-list --count "$bin_sha..origin/main" 2>/dev/null || echo '?')"
            register_check "binary" "fail" \
                "deployed binary $bin_sha lags origin/main $main_sha by $lag commits ($binary_path)" \
                "bash $REPO_ROOT/scripts/ops/node-refresh-chump.sh"
            return
        fi
    fi
    for c in "$HOME/.cargo/bin/chump" "$HOME/.local/bin/chump" "/usr/local/bin/chump"; do
        [[ -x "$c" ]] || continue
        [[ "$(readlink -f "$c")" == "$(readlink -f "$binary_path")" ]] && continue
        copies="$copies $c"
    done
    if [[ -n "$copies" ]]; then
        register_check "binary" "fail" \
            "multiple chump binaries: PATH resolves $binary_path but stray copies exist:$copies" \
            "bash $REPO_ROOT/scripts/ops/node-refresh-chump.sh  # converges copies onto one canonical binary"
        return
    fi

    if [[ -n "$src_newest_mtime" ]]; then
        register_check "binary" "fail" \
            "binary is older than src/*.rs (source changed since last build)" \
            "cd $REPO_ROOT && cargo build --bin chump"
    else
        register_check "binary" "pass" \
            "binary is up to date ($binary_path)" \
            ""
    fi
}

# ── Check 2: Expired leases ────────────────────────────────────────────────────
check_leases() {
    local stale=()
    local now_ts
    now_ts="$(date -u +%s)"
    local cutoff_ts=$(( now_ts - LEASE_STALE_HOURS * 3600 ))

    for lock in "$REPO_ROOT"/.chump-locks/claim-*.json; do
        [[ -f "$lock" ]] || continue
        local expires gap_id
        expires="$(python3 -c "import sys,json; d=json.load(open('$lock')); print(d.get('expires_at',''))" 2>/dev/null || true)"
        gap_id="$(python3 -c "import sys,json; d=json.load(open('$lock')); print(d.get('gap_id','?'))" 2>/dev/null || true)"
        [[ -z "$expires" ]] && continue

        local expires_ts
        expires_ts="$(date -u -d "$expires" +%s 2>/dev/null \
            || python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('${expires%Z}').timestamp()))" 2>/dev/null \
            || echo 0)"

        # Lease is stale if it expired more than LEASE_STALE_HOURS ago.
        if [[ "$expires_ts" -lt "$cutoff_ts" ]]; then
            stale+=("$gap_id (expired $expires)")
        fi
    done

    if [[ "${#stale[@]}" -gt 0 ]]; then
        register_check "leases" "fail" \
            "${#stale[@]} lease(s) expired >$LEASE_STALE_HOURS h ago: ${stale[*]}" \
            "ls $REPO_ROOT/.chump-locks/claim-*.json | xargs -I{} chump --release --lease {}"
    else
        register_check "leases" "pass" \
            "no stale leases (threshold: >${LEASE_STALE_HOURS}h expired)" \
            ""
    fi
}

# ── Check 3: Disk space ────────────────────────────────────────────────────────
check_disk() {
    local free_kb free_gb
    free_kb="$(df -k "$REPO_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
    free_gb=$(( free_kb / 1024 / 1024 ))

    if [[ "$free_gb" -lt "$DISK_MIN_GB" ]]; then
        register_check "disk" "fail" \
            "only ${free_gb} GB free (threshold: >=${DISK_MIN_GB} GB)" \
            "bash $REPO_ROOT/scripts/coord/chump-target-reaper.sh --apply  # or manual cleanup"
        return
    fi

    # RESILIENT-1444: percentage-based guard — a large filesystem can clear
    # the absolute-GB floor above while still being critically full (e.g.
    # 15 GB free on a 115 GB disk is 87% used). Checks REPO_ROOT plus any
    # extra mounts in CHUMP_DISK_PRESSURE_PATHS (space-separated).
    local pressure_pct="${DISK_PRESSURE_PCT:-90}"
    local pressure_paths="${CHUMP_DISK_PRESSURE_PATHS:-$REPO_ROOT}"
    local path pct worst_path="" worst_pct=0
    for path in $pressure_paths; do
        pct="$(df -k "$path" 2>/dev/null | awk 'NR==2 { gsub(/%/,"",$5); print $5 }')"
        [[ -z "$pct" || ! "$pct" =~ ^[0-9]+$ ]] && continue
        if [[ "$pct" -gt "$worst_pct" ]]; then
            worst_pct="$pct"
            worst_path="$path"
        fi
    done

    if [[ -n "$worst_path" && "$worst_pct" -ge "$pressure_pct" ]]; then
        register_check "disk" "fail" \
            "$worst_path is ${worst_pct}% used (threshold: <${pressure_pct}%) — RESILIENT-1444 disk-pressure guard" \
            "bash $REPO_ROOT/scripts/ops/stale-worktree-reaper.sh --execute  # reap abandoned worktrees, then chump-target-reaper.sh --apply"
    else
        register_check "disk" "pass" \
            "${free_gb} GB free (threshold: >=${DISK_MIN_GB} GB); ${worst_path:-$REPO_ROOT} at ${worst_pct}% used (threshold: <${pressure_pct}%)" \
            ""
    fi
}

# ── Check 4: DIRTY PRs older than DIRTY_PR_HOURS ──────────────────────────────
check_dirty_prs() {
    local dirty_old=()
    local cutoff_ts
    cutoff_ts="$(date -u -v-"${DIRTY_PR_HOURS}"H +%s 2>/dev/null \
        || date -u -d "$DIRTY_PR_HOURS hours ago" +%s 2>/dev/null \
        || echo 0)"

    # Use GitHub cache if available, else gh pr list.
    local db="$REPO_ROOT/.chump/github_cache.db"
    if [[ -f "$db" ]]; then
        # Query for DIRTY PRs with updated_at older than threshold.
        while IFS=$'\t' read -r pr_num pr_title updated_at; do
            [[ -z "$pr_num" ]] && continue
            local updated_ts
            updated_ts="$(python3 -c "import datetime; print(int(datetime.datetime.fromisoformat('${updated_at%Z}').timestamp()))" 2>/dev/null || echo 0)"
            if [[ "$updated_ts" -lt "$cutoff_ts" && "$updated_ts" -gt 0 ]]; then
                dirty_old+=("#$pr_num ($pr_title)")
            fi
        done < <(sqlite3 -separator $'\t' "$db" \
            "SELECT number, COALESCE(title,''), COALESCE(updated_at,'') \
             FROM pr_state \
             WHERE mergeable_state = 'DIRTY' AND merged_at IS NULL \
             ORDER BY number DESC" 2>/dev/null || true)
    else
        # Fallback: direct gh api (expensive).
        while IFS=$'\t' read -r pr_num pr_title updated_at; do
            [[ -z "$pr_num" ]] && continue
            dirty_old+=("#$pr_num")
        done < <(gh pr list --repo repairman29/chump --state open \
            --json number,title,updatedAt,mergeStateStatus \
            --jq '.[] | select(.mergeStateStatus=="DIRTY") | [.number|tostring, .title, .updatedAt] | @tsv' \
            2>/dev/null || true)
    fi

    if [[ "${#dirty_old[@]}" -gt 0 ]]; then
        register_check "dirty-prs" "fail" \
            "${#dirty_old[@]} PR(s) DIRTY >$DIRTY_PR_HOURS h: ${dirty_old[*]}" \
            "scripts/coord/chump-pr-triage.sh --all | grep rebase  # then --apply <pr> rebase"
    else
        register_check "dirty-prs" "pass" \
            "no PRs DIRTY >$DIRTY_PR_HOURS h" \
            ""
    fi
}

# ── Check 5: Gap drift ─────────────────────────────────────────────────────────
check_gap_drift() {
    # Use chump gap audit-priorities if available — it detects open-with-closed-pr,
    # double-encoded depends_on, missing-dep refs, etc.
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "gap-drift" "skip" "chump binary not found — skipping" ""
        return
    fi

    local audit_out audit_rc
    audit_rc=0
    audit_out="$("$CHUMP_BIN" gap audit-priorities --json 2>/dev/null)" || audit_rc=$?

    if [[ "$audit_rc" -ne 0 ]]; then
        register_check "gap-drift" "fail" \
            "gap audit-priorities exited $audit_rc — drift detected" \
            "$CHUMP_BIN gap audit-priorities  # review output; fix open-with-closed-pr via 'chump gap ship'"
    else
        local open_closed_count
        open_closed_count="$(echo "$audit_out" | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get('open_with_closed_pr',0))
except:
    print(0)
" 2>/dev/null || echo 0)"
        if [[ "$open_closed_count" -gt 0 ]]; then
            register_check "gap-drift" "fail" \
                "$open_closed_count gap(s) have status=open but closed_pr set" \
                "$CHUMP_BIN gap audit-priorities  # then 'chump gap ship <ID>' per flagged gap"
        else
            register_check "gap-drift" "pass" \
                "no gap drift detected" \
                ""
        fi
    fi
}

# ── Check 6: P0 budget ─────────────────────────────────────────────────────────
check_p0_budget() {
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "p0-budget" "skip" "chump binary not found — skipping" ""
        return
    fi

    # Note: chump gap list --priority P0 flag is not reliably filtered by the CLI;
    # grep for the "(P0/" pattern in output instead.
    local p0_count
    p0_count="$("$CHUMP_BIN" gap list --status open 2>/dev/null \
        | grep -c "(P0/")" || p0_count=0

    if [[ "$p0_count" -gt "$P0_MAX" ]]; then
        register_check "p0-budget" "fail" \
            "$p0_count open P0 gaps (threshold: <=$P0_MAX)" \
            "$CHUMP_BIN gap audit-priorities  # demote inflated P0s to P1"
    else
        register_check "p0-budget" "pass" \
            "$p0_count open P0 gaps (threshold: <=$P0_MAX)" \
            ""
    fi
}

# ── Check 7: Pillar coverage ───────────────────────────────────────────────────
check_pillar_coverage() {
    if ! command -v "$CHUMP_BIN" &>/dev/null; then
        register_check "pillar-cover" "skip" "chump binary not found — skipping" ""
        return
    fi

    local starved_pillars=()
    for pillar in EFFECTIVE CREDIBLE RESILIENT ZERO-WASTE; do
        # Count open P0/P1 xs/s/m gaps for this pillar (pickable pool).
        local count
        count="$("$CHUMP_BIN" gap list --status open 2>/dev/null \
            | grep -i "$pillar:" \
            | grep -E "P[01].*(xs|s|m)" \
            | grep -cv "⚠")" || count=0
        if [[ "$count" -lt "$PILLAR_MIN" ]]; then
            starved_pillars+=("$pillar($count)")
        fi
        [[ "$VERBOSE" -eq 1 ]] && echo "[fleet-doctor] pillar $pillar: $count pickable gaps" >&2
    done

    if [[ "${#starved_pillars[@]}" -gt 0 ]]; then
        register_check "pillar-cover" "fail" \
            "pillar(s) below $PILLAR_MIN pickable gaps: ${starved_pillars[*]}" \
            "$CHUMP_BIN gap reserve --domain INFRA --title '<pillar>: <feature>'  # file gaps to rebalance"
    else
        register_check "pillar-cover" "pass" \
            "all pillars have >=$PILLAR_MIN pickable gaps" \
            ""
    fi
}

# ── Check 8: Silent fleet death (INFRA-2040) ───────────────────────────────────
# Condition: last merge into origin/main is >SILENT_DEATH_MERGE_HOURS old
#            AND at least one com.chump.* / dev.chump.* launchd daemon has
#            last exit code != 0.
# When BOTH conditions hold, emit kind=silent_fleet_death to ambient and
# register as FAIL.  Either condition alone is only a warning (skip level).
#
# Optional auto-heal (CHUMP_DOCTOR_AUTOHEAL=1):
#   For each daemon with exit=127 (command not found), check if the plist's
#   ProgramArguments script path exists; if missing but reachable in
#   origin/main, restore via `git checkout origin/main -- <path>` and bounce
#   the daemon with `launchctl kickstart`.
check_silent_fleet_death() {
    # ── Sub-check A: last-merge age ──────────────────────────────────────────
    local last_merge_ts
    last_merge_ts="$(git -C "$REPO_ROOT" log origin/main -1 --format="%ct" 2>/dev/null || echo 0)"
    local now_ts
    now_ts="$(date -u +%s)"
    local merge_age_h=$(( (now_ts - last_merge_ts) / 3600 ))
    local merge_stale=0
    if [[ "$last_merge_ts" -eq 0 || "$merge_age_h" -ge "$SILENT_DEATH_MERGE_HOURS" ]]; then
        merge_stale=1
    fi

    # ── Sub-check B: daemon exit codes ───────────────────────────────────────
    # Only meaningful on macOS with launchctl available.
    local dead_daemons=()
    local dead_exit_codes=()
    local daemon_scan_available=0
    if command -v launchctl &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
        daemon_scan_available=1
        # List all loaded com.chump.* and dev.chump.* labels.
        local labels=()
        while IFS= read -r label; do
            [[ -z "$label" ]] && continue
            labels+=("$label")
        done < <(launchctl list 2>/dev/null \
            | awk '{print $3}' \
            | grep -E '^(com|dev)\.chump\.' \
            || true)

        for label in "${labels[@]}"; do
            # launchctl print gui/<uid>/<label> or system/<label>.
            local uid
            uid="$(id -u)"
            local print_out
            print_out="$(launchctl print "gui/$uid/$label" 2>/dev/null \
                || launchctl print "system/$label" 2>/dev/null \
                || true)"

            # Extract "last exit code = N" from print output.
            local exit_code
            exit_code="$(echo "$print_out" \
                | grep -E 'last exit code\s*=' \
                | grep -oE '[-]?[0-9]+' \
                | head -1 \
                || true)"
            [[ -z "$exit_code" ]] && continue
            if [[ "$exit_code" != "0" ]]; then
                dead_daemons+=("$label")
                dead_exit_codes+=("$exit_code")
            fi
        done
    fi

    local daemon_fail=0
    [[ "${#dead_daemons[@]}" -gt 0 ]] && daemon_fail=1

    # ── Decision: BOTH conditions needed for silent_fleet_death ──────────────
    if [[ "$merge_stale" -eq 1 && "$daemon_fail" -eq 1 ]]; then
        local dead_list
        dead_list="$(printf '%s(exit=%s) ' "${dead_daemons[@]}" 2>/dev/null || true)"
        # Emit ambient event.
        local event_ts
        event_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        local ambient_log="$REPO_ROOT/.chump-locks/ambient.jsonl"
        if [[ -x "$AMBIENT_EMIT" ]]; then
            bash "$AMBIENT_EMIT" silent_fleet_death \
                merge_age_h="$merge_age_h" \
                dead_daemon_count="${#dead_daemons[@]}" \
                dead_daemons="${dead_list}" \
                2>/dev/null || true
        else
            # Fallback: direct printf.
            printf '{"ts":"%s","kind":"silent_fleet_death","merge_age_h":%d,"dead_daemon_count":%d,"dead_daemons":"%s","source":"fleet-doctor-strict.sh"}\n' \
                "$event_ts" "$merge_age_h" "${#dead_daemons[@]}" "${dead_list}" \
                >> "$ambient_log" 2>/dev/null || true
        fi

        # ── Optional auto-heal (CHUMP_DOCTOR_AUTOHEAL=1) ─────────────────────
        local healed_daemons=()
        if [[ "$CHUMP_DOCTOR_AUTOHEAL" == "1" ]] && command -v launchctl &>/dev/null; then
            local uid
            uid="$(id -u)"
            for i in "${!dead_daemons[@]}"; do
                local label="${dead_daemons[$i]}"
                local exit_code="${dead_exit_codes[$i]}"
                [[ "$exit_code" != "127" ]] && continue  # only heal "command not found"

                # Find the plist for this label.
                local plist_path="$HOME/Library/LaunchAgents/${label}.plist"
                [[ -f "$plist_path" ]] || continue

                # Extract ProgramArguments script path from plist.
                # Write the python snippet to a temp file to avoid heredoc-inside-$()
                # which shellcheck (SC1073) cannot parse.
                local _py_extract
                _py_extract="$(mktemp /tmp/chump-plist-extract-XXXXXX.py)"
                printf '%s\n' \
                    'import sys, plistlib' \
                    'with open(sys.argv[1], "rb") as f: pl = plistlib.load(f)' \
                    'args = pl.get("ProgramArguments", [])' \
                    'for a in args:' \
                    '    if a.startswith("/") and not a.startswith("/bin/") and not a.startswith("/usr/"):' \
                    '        print(a); break' \
                    > "$_py_extract"
                local script_path
                script_path="$(python3 "$_py_extract" "$plist_path" 2>/dev/null || true)"
                rm -f "$_py_extract"
                [[ -z "$script_path" ]] && continue
                [[ -f "$script_path" ]] && continue  # script already exists — skip

                # Check if the script exists in origin/main.
                local rel_path="${script_path#"$REPO_ROOT"/}"
                if git -C "$REPO_ROOT" cat-file -e "origin/main:${rel_path}" 2>/dev/null; then
                    [[ "$VERBOSE" -eq 1 ]] && echo "[fleet-doctor] auto-heal: restoring $rel_path from origin/main" >&2
                    git -C "$REPO_ROOT" checkout origin/main -- "$rel_path" 2>/dev/null || continue
                    chmod +x "$script_path" 2>/dev/null || true
                    # Bounce the daemon.
                    launchctl kickstart -k "gui/$uid/$label" 2>/dev/null || true
                    healed_daemons+=("$label")
                    # Emit autoheal event.
                    if [[ -x "$AMBIENT_EMIT" ]]; then
                        bash "$AMBIENT_EMIT" silent_fleet_death_autohealed \
                            label="$label" \
                            script_path="$script_path" \
                            2>/dev/null || true
                    else
                        printf '{"ts":"%s","kind":"silent_fleet_death_autohealed","label":"%s","script_path":"%s","source":"fleet-doctor-strict.sh"}\n' \
                            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" "$script_path" \
                            >> "$ambient_log" 2>/dev/null || true
                    fi
                fi
            done
        fi

        local detail="last merge ${merge_age_h}h ago (threshold: >=${SILENT_DEATH_MERGE_HOURS}h); ${#dead_daemons[@]} daemon(s) with exit!=0: ${dead_list}"
        local remedy="launchctl list | grep -E '(com|dev)\.chump'; git pull origin main; then launchctl kickstart -k gui/\$(id -u)/<label>"
        if [[ "${#healed_daemons[@]}" -gt 0 ]]; then
            detail="${detail}; auto-healed: ${healed_daemons[*]}"
            remedy="auto-heal ran — verify daemons are now running"
        fi

        register_check "silent-fleet-death" "fail" \
            "ALERT: silent-fleet-death — $detail" \
            "$remedy"

    elif [[ "$merge_stale" -eq 1 && "$daemon_scan_available" -eq 1 ]]; then
        # Merge stale but daemons OK — softer warning only (pass, with note).
        register_check "silent-fleet-death" "pass" \
            "last merge ${merge_age_h}h ago (>=${SILENT_DEATH_MERGE_HOURS}h) but all daemons exit=0 — stale branch, fleet alive" \
            ""
    elif [[ "$daemon_fail" -eq 1 ]]; then
        # Daemons failing but recent merge — likely a transient issue, not dead-floor.
        local dead_list
        dead_list="$(printf '%s(exit=%s) ' "${dead_daemons[@]}" 2>/dev/null || true)"
        register_check "silent-fleet-death" "fail" \
            "${#dead_daemons[@]} daemon(s) with exit!=0 (recent merge OK): ${dead_list}" \
            "launchctl kickstart -k gui/\$(id -u)/<label>  # or check daemon logs"
    elif [[ "$daemon_scan_available" -eq 0 ]]; then
        register_check "silent-fleet-death" "skip" \
            "launchctl not available (non-macOS or not loaded) — skipping daemon exit scan" \
            ""
    else
        register_check "silent-fleet-death" "pass" \
            "last merge ${merge_age_h}h ago; all com/dev.chump.* daemons exit=0" \
            ""
    fi
}

# ── Check 9: Required status checks non-empty (INFRA-2201) ─────────────────────
#
# admin-merge-cycle drops required_status_checks during merge; if the restore
# step fails or is skipped, main is silently unprotected. No ambient emit
# fires when this happens — only this check catches the bad state.
#
# Verifies BOTH branch-protection AND ruleset 15133729's
# required_status_checks lists are non-empty. Either being empty is a
# critical resilience breach: any operator with admin can merge unverified
# code without realizing the gate is open.
#
# Bypass: CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS=1 (use only when
# intentionally testing the empty-state pattern, e.g. CI for INFRA-2201).
check_required_status_checks() {
    if [[ "${CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS:-0}" == "1" ]]; then
        register_check "required-checks" "skip" \
            "CHUMP_FLEET_DOCTOR_SKIP_REQUIRED_CHECKS=1 bypass active" ""
        return
    fi
    if ! command -v gh &>/dev/null; then
        register_check "required-checks" "skip" "gh CLI not in PATH" ""
        return
    fi
    local repo
    repo="$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")"
    if [[ -z "$repo" ]]; then
        register_check "required-checks" "skip" \
            "could not resolve repo (no remote OR offline)" ""
        return
    fi

    # Sub-check A: branch-protection required_status_checks
    local bp_count
    bp_count="$(gh api "repos/$repo/branches/main/protection" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get("required_status_checks",{}).get("checks",[])
    print(len(c))
except Exception:
    print(0)' || echo 0)"

    # Sub-check B: ruleset required_status_checks (the rule may sit in any
    # active ruleset; sum across all rulesets matching ~DEFAULT_BRANCH).
    local rs_count=0
    local rs_ids
    rs_ids="$(gh api "repos/$repo/rulesets" 2>/dev/null \
        | python3 -c 'import json,sys
try:
    rs=json.load(sys.stdin)
    for r in rs:
        if r.get("enforcement")=="active":
            print(r.get("id",""))
except Exception:
    pass' || true)"
    while IFS= read -r rid; do
        [[ -z "$rid" ]] && continue
        local n
        n="$(gh api "repos/$repo/rulesets/$rid" 2>/dev/null \
            | python3 -c 'import json,sys
try:
    r=json.load(sys.stdin)
    for rule in r.get("rules",[]):
        if rule.get("type")=="required_status_checks":
            print(len(rule.get("parameters",{}).get("required_status_checks",[])))
            break
    else:
        print(0)
except Exception:
    print(0)' || echo 0)"
        rs_count=$(( rs_count + n ))
    done <<< "$rs_ids"

    # Resilience invariant: at least ONE of (branch-prot, ruleset) must
    # have a non-empty required-checks list. Both empty = silent open.
    local total=$(( bp_count + rs_count ))
    if [[ "$total" -eq 0 ]]; then
        # Emit ambient signal so peers / watchdogs see the open state even
        # if fleet-doctor isn't tailed. scanner-anchor: "kind":"required_status_checks_empty" (INFRA-2201)
        local _amb_path="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        local _ts; _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '{"ts":"%s","kind":"required_status_checks_empty","bp_count":%d,"ruleset_count":%d,"source":"fleet-doctor-strict"}\n' \
            "$_ts" "$bp_count" "$rs_count" >> "$_amb_path" 2>/dev/null || true
        register_check "required-checks" "fail" \
            "BOTH branch-protection AND ruleset required_status_checks are EMPTY — main is silently UNPROTECTED" \
            "Restore required checks: see scripts/ops/admin-merge-cycle.sh or docs/process/SHEPHERD_LOOP_PLAYBOOK.md Pattern 14"
    else
        register_check "required-checks" "pass" \
            "branch-prot=$bp_count, ruleset=$rs_count (≥1 required for non-empty invariant)" \
            ""
    fi
}

# ── Check 10 (CREDIBLE-122): A2A consensus OUTCOME ─────────────────────────────
# Measure the OUTCOME — does the fleet actually reach decisions? — not the signal
# (is a flag set). The previous signal-based check (INFRA-2515) glowed green
# while consensus_result was 0 fleet-wide: a dashboard lie. This FAILS when an
# open proposal has aged past the grace window with NO consensus_result for its
# corr_id — i.e. the fleet was asked to decide and didn't. Cross-platform (reads
# the logs, no launchctl dependency). A fresh proposal still inside its grace
# window does NOT fail (no crying wolf on in-flight votes).

check_almanac_freshness() {
    # INFRA-3586 slice (a): the nervous-system latch — almanac (fleet memory)
    # must be provably alive: registry readable, refresh loop recent, and a
    # known symbol answerable. Operator doctrine 2026-08-15: "it can't be
    # stale — it needs to be alive itself."
    local bin="${CHUMP_ALMANAC_BIN:-$HOME/Projects/almanac/target/release/almanac}"
    local ahome="${ALMANAC_HOME:-$HOME/.almanac}"
    if [[ ! -x "$bin" ]]; then
        register_check "almanac-freshness" "skip" "almanac CLI absent at $bin — node carries no local index" ""
        return
    fi
    if ! python3 -c "import json;json.load(open('$ahome/registry.json'))" 2>/dev/null; then
        register_check "almanac-freshness" "fail" "registry.json unreadable/corrupt at $ahome — fleet memory blind" ""
        return
    fi
    local max_h="${CHUMP_ALMANAC_STALE_HOURS:-3}" age=999
    if [[ -f "$ahome/refresh.log" ]]; then
        local mtime
        mtime="$(stat -c %Y "$ahome/refresh.log" 2>/dev/null || stat -f %m "$ahome/refresh.log" 2>/dev/null || echo 0)"
        age=$(( ( $(date +%s) - mtime ) / 3600 ))
    fi
    if (( age >= max_h )); then
        register_check "almanac-freshness" "fail" "refresh loop stale: refresh.log ${age}h old (threshold ${max_h}h) — fleet memory rotting" ""
        return
    fi
    local hits
    hits="$("$bin" search-fleet "gap_store" 2>/dev/null | head -1 | grep -oE '[0-9]+ hits' | grep -oE '^[0-9]+' || true)"
    if [[ -z "$hits" || "$hits" -eq 0 ]]; then
        register_check "almanac-freshness" "fail" "smoke query 'gap_store' returned 0 hits — index empty or degraded" ""
        return
    fi
    register_check "almanac-freshness" "pass" "registry ok, refresh ${age}h fresh, smoke query ${hits} hits" ""
}

#   9. backlog-sync    — CREDIBLE-292: the registry's .chump/state.sql (the
#                         backlog-sync --writer's published truth) must not go
#                         stale >24h. A dead writer is exactly how the
#                         2026-08-15 registry split-brain went undetected for
#                         21 days — this makes it RED within hours instead.
#                         INFRA-8193: origin/main no longer tracks the file, so
#                         only the private `registry` remote is measured.
check_backlog_sync_freshness() {
    local max_h="${CHUMP_BACKLOG_SYNC_STALE_HOURS:-24}"
    local last_epoch reg_ref="registry/main"
    # Registry privacy: the writer publishes to the private `registry` remote.
    # A configured-but-unfetchable registry is a FAIL. With no registry remote
    # there is nothing published to measure (origin/main stopped tracking
    # .chump/state.sql in INFRA-8193), so the check is skipped, not failed.
    if ! git -C "$REPO_ROOT" remote get-url registry >/dev/null 2>&1; then
        register_check "backlog-sync-freshness" "skip" \
            "no 'registry' remote — origin/main no longer tracks .chump/state.sql (INFRA-8193); nothing published to measure" ""
        return
    fi
    if ! git -C "$REPO_ROOT" fetch --quiet registry main 2>/dev/null; then
        register_check "backlog-sync-freshness" "fail" \
            "registry remote is configured but could not be fetched — cannot prove the registry is fresh" \
            "check the node's registry deploy key / network: git -C $REPO_ROOT fetch registry main"
        return
    fi
    last_epoch="$(git -C "$REPO_ROOT" log -1 --format='%ct' "$reg_ref" -- .chump/state.sql 2>/dev/null)"
    if [[ -z "$last_epoch" ]]; then
        register_check "backlog-sync-freshness" "fail" \
            "no commit history for .chump/state.sql on $reg_ref — backlog-sync writer has never published there" \
            "install the writer organ: sudo bash scripts/setup/install-helsinki-atc.sh (see chump-backlog-sync-writer.timer)"
        return
    fi
    local age_h=$(( ( $(date +%s) - last_epoch ) / 3600 ))
    if (( age_h >= max_h )); then
        register_check "backlog-sync-freshness" "fail" \
            "$reg_ref .chump/state.sql is ${age_h}h stale (threshold ${max_h}h) — backlog-sync --writer is dead or not installed, registry split-brain risk" \
            "check: systemctl status chump-backlog-sync-writer.timer; re-arm: sudo bash scripts/setup/install-helsinki-atc.sh"
        return
    fi
    register_check "backlog-sync-freshness" "pass" "$reg_ref .chump/state.sql ${age_h}h fresh (threshold ${max_h}h)" ""
}

#  14. organ-roll-call-live — INFRA-3646 (TREK-20): the static Roll-Call
#      (test-resilient-366-organ-roll-call.sh) only proves every installed
#      timer HAS a manifest line — it never asks "is the organ actually
#      running RIGHT NOW". This check closes that gap: for every `enabled`
#      organ-manifest.txt line whose `requires=` spec holds on THIS node,
#      assert `systemctl is-active` — RED with the unit name otherwise.
#      Non-applicable organs (unmet requires=) report skip, not fail. A dead
#      organ still inside its organ-reconcile.sh backoff cooldown is reported
#      distinctly from one that's dead with no backoff record at all — the
#      difference between "the healer tried and gave up, will retry" and
#      "nobody's watching this one."
#
# Applicability gate — mirrors organ-reconcile.sh's organ_is_applicable():
# bin:/env:/dep: specs, ALL must hold or the organ is not-applicable on this
# node. A separate function (rather than inline in check_organ_roll_call_live's
# loop) so its `local IFS=','` is scoped to THIS call and never leaks into the
# caller's `while read` manifest parser, which needs whitespace-splitting IFS.
_organ_roll_call_is_applicable() {
    local unit="$1" requires="$2" systemctl_bin="$3" reason_var="$4"
    [[ -z "$requires" ]] && return 0
    local rtok IFS=','
    for rtok in $requires; do
        case "$rtok" in
            bin:*)
                command -v "${rtok#bin:}" >/dev/null 2>&1 \
                    || { printf -v "$reason_var" 'missing_bin:%s' "${rtok#bin:}"; return 1; }
                ;;
            env:*)
                local var="${rtok#env:}"
                [[ -n "${!var:-}" ]] \
                    || { printf -v "$reason_var" 'missing_env:%s' "$var"; return 1; }
                ;;
            dep:*)
                "$systemctl_bin" is-active --quiet "${rtok#dep:}" 2>/dev/null \
                    || { printf -v "$reason_var" 'missing_dep:%s' "${rtok#dep:}"; return 1; }
                ;;
            file:*)
                # RESILIENT-1436: mirrors organ_is_applicable() in
                # scripts/ops/lib/organ-manifest-lib.sh — the CJ-legacy
                # chump-cj-worker/disk-monitor/sync organs declare
                # requires=...,file:~/cj-*-run.sh (a host-specific asset with
                # no tracked unit file). Before this case existed, `file:`
                # fell through to the `*)` unknown-spec branch below, which
                # marked these organs not-applicable and SKIPped them —
                # invisible to the live roll-call even when systemd-supervised.
                local fpath="${rtok#file:}"
                case "$fpath" in
                    '~/'*)     fpath="${HOME:-/root}/${fpath#\~/}" ;;
                    '$HOME/'*) fpath="${HOME:-/root}/${fpath#\$HOME/}" ;;
                esac
                [[ -e "$fpath" ]] \
                    || { printf -v "$reason_var" 'missing_file:%s' "$fpath"; return 1; }
                ;;
            *)
                printf -v "$reason_var" 'unknown_requires_spec:%s' "$rtok"; return 1 ;;
        esac
    done
    return 0
}

check_organ_roll_call_live() {
    local manifest="${CHUMP_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"
    local systemctl_bin="${CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN:-systemctl}"
    local backoff_dir="${CHUMP_ORGAN_RECONCILE_BACKOFF_DIR:-$REPO_ROOT/.chump-locks/organ-backoff}"
    local backoff_cooldown_s="${CHUMP_ORGAN_RECONCILE_BACKOFF_COOLDOWN_S:-3600}"

    if [[ ! -f "$manifest" ]]; then
        register_check "organ-roll-call-live" "skip" "organ-manifest.txt not found at $manifest — skipping live check" ""
        return
    fi
    if ! command -v "$systemctl_bin" >/dev/null 2>&1; then
        register_check "organ-roll-call-live" "skip" "systemctl unavailable on this node — not a live systemd host" ""
        return
    fi

    local state unit rest
    while read -r state unit rest; do
        [[ -z "${state:-}" ]] && continue
        [[ "$state" == \#* ]] && continue
        [[ "$state" != "enabled" ]] && continue

        # role=/requires= parsing mirrors organ-reconcile.sh's manifest reader.
        local role="brain" requires="" tok
        for tok in $rest; do
            [[ "$tok" == \#* ]] && break   # RESILIENT-1534: a trailing comment is not part of the directive
            case "$tok" in
                role=*)     role="${tok#role=}" ;;
                requires=*) requires="${tok#requires=}" ;;
            esac
        done

        local reason=""
        if ! _organ_roll_call_is_applicable "$unit" "$requires" "$systemctl_bin" reason; then
            register_check "organ-live:$unit" "skip" "not applicable on this node ($reason, role=$role)" ""
            continue
        fi

        if "$systemctl_bin" is-active --quiet "$unit" 2>/dev/null; then
            register_check "organ-live:$unit" "pass" "active (role=$role)" ""
            continue
        fi

        # Dead. Distinguish "in reconcile backoff cooldown" (the healer tried,
        # gave up, and will retry once the cooldown expires) from "dead and
        # unowned" (no backoff record at all — nobody is watching/retrying it).
        local backoff_file="$backoff_dir/${unit}.json"
        if [[ -f "$backoff_file" ]]; then
            local since br_reason age_s remain_s
            since="$(grep -o '"since":[0-9]*' "$backoff_file" 2>/dev/null | head -1 | cut -d: -f2)"
            br_reason="$(grep -o '"reason":"[^"]*"' "$backoff_file" 2>/dev/null | head -1 | cut -d: -f2 | tr -d '"')"
            if [[ "$since" =~ ^[0-9]+$ ]]; then
                age_s=$(( $(date +%s) - since ))
                if (( age_s < backoff_cooldown_s )); then
                    remain_s=$(( backoff_cooldown_s - age_s ))
                    register_check "organ-live:$unit" "fail" \
                        "$unit is inactive, IN BACKOFF COOLDOWN (healer gave up: ${br_reason:-unknown}, retries in ${remain_s}s, role=$role)" \
                        "wait for cooldown, or force a retry now: rm $backoff_file && sudo bash scripts/ops/organ-reconcile.sh --apply"
                    continue
                fi
            fi
        fi

        register_check "organ-live:$unit" "fail" \
            "$unit is inactive/failed and NOT in backoff — dead and unowned (role=$role)" \
            "systemctl status $unit; sudo bash scripts/ops/organ-reconcile.sh --apply"
    done < "$manifest"
}

check_a2a_consensus() {
    if ! command -v python3 &>/dev/null; then
        register_check "a2a-consensus" "skip" "python3 unavailable — skipping A2A outcome scan" ""
        return
    fi
    local grace_h="${A2A_PROPOSAL_GRACE_HOURS:-6}"
    local window_h="${A2A_PROPOSAL_WINDOW_HOURS:-168}"   # 7d look-back
    local fb="$REPO_ROOT/.chump-locks/feedback.jsonl"
    local amb="$REPO_ROOT/.chump-locks/ambient.jsonl"
    if [[ ! -f "$fb" && ! -f "$amb" ]]; then
        register_check "a2a-consensus" "skip" "no consensus logs present — nothing to judge" ""
        return
    fi

    local now_ts grace_cut window_cut
    now_ts="$(date -u +%s)"
    grace_cut=$(( now_ts - grace_h * 3600 ))
    window_cut=$(( now_ts - window_h * 3600 ))

    # A proposal is "starved" if it's within the look-back window, older than the
    # grace window, and has NO consensus_result for its corr_id.
    local starved
    starved="$(cat "$fb" "$amb" 2>/dev/null | python3 -c '
import sys, json, datetime
grace, window = int(sys.argv[1]), int(sys.argv[2])
def epoch(ts):
    try: return int(datetime.datetime.strptime(ts.replace("Z","+0000"),"%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception: return 0
prop={}; resolved=set()
for line in sys.stdin:
    try: d=json.loads(line)
    except Exception: continue
    c=d.get("corr_id"); k=d.get("kind")
    if not c: continue
    if k=="proposal":
        e=epoch(d.get("ts",""))
        if e>=window and (c not in prop or e<prop[c]): prop[c]=e
    elif k=="consensus_result":
        resolved.add(c)
s=[c for c,e in prop.items() if e<grace and c not in resolved]
print(len(s)); print(" ".join(s[:5]))
' "$grace_cut" "$window_cut" 2>/dev/null)"

    local n_starved which
    n_starved="$(printf '%s' "$starved" | sed -n 1p)"; n_starved="${n_starved:-0}"
    which="$(printf '%s' "$starved" | sed -n 2p)"

    if [[ "$n_starved" =~ ^[0-9]+$ ]] && (( n_starved > 0 )); then
        register_check "a2a-consensus" "fail" \
            "${n_starved} open proposal(s) aged >${grace_h}h with NO consensus_result — the fleet is not reaching decisions (e.g. ${which}). consensus_result is the OUTCOME; piling up proposals with 0 verdicts is the dashboard lie CREDIBLE-122 fixed." \
            "run the deliberator (bash scripts/coord/deliberator-loop.sh tick); make curators vote (chump vote <corr_id> +1|-1|0 --reason ...)"
        return
    fi
    register_check "a2a-consensus" "pass" \
        "no starved proposals — every open proposal aged past ${grace_h}h has a consensus_result (fleet is deciding)" ""
}

# ── Check 11 (RESILIENT-257): Ops-defect self-diagnosis + auto-file VOA ────────
#
# Broadens fleet-doctor from "is the fleet healthy" to "is the fleet's OWN ops
# tooling behaving correctly" — the factory catching its own sloppy ops
# without a human noticing. Two defect classes:
#
#   A. broken-daemon-exit  — any com/dev.chump.* launchd daemon with a
#      non-zero last exit code, independent of merge-staleness (broader than
#      check 8's silent-fleet-death gate, which only fires when BOTH
#      merge-staleness AND a dead daemon hold).
#   B. false-positive-alert — an operator_recall (AUTH_DEAD/COST_CAP/
#      CI_BROKEN/QUEUE_STARVE) alert fired in the look-back window while
#      ground truth (recent merges into origin/main) shows the fleet was
#      actually shipping — the alert lied (CREDIBLE-090 Verify-before-alarm,
#      applied as a *check* instead of a discipline a human has to remember).
#
# When either class fires, this check FAILs *and* auto-files a VOA
# (docs/gaps/VOA-NNNN.yaml + docs/voice/VOA-NNNN-FULL.yaml, no --ship/no PR)
# via `chump voice`, so the defect becomes visible without a human having to
# notice and file it by hand. Dedup: skip re-filing if a VOA with the same
# wedge_class was already filed within OPS_DEFECT_VOA_DEDUP_HOURS.
#
# Thresholds (override via env)
#   OPS_DEFECT_ALERT_WINDOW_HOURS  default 2   — look-back for operator_recall alerts
#   OPS_DEFECT_SHIP_WINDOW_HOURS   default 1   — ground-truth ship-rate window
#   OPS_DEFECT_VOA_DEDUP_HOURS     default 24  — don't re-file same wedge_class
#   CHUMP_OPS_DEFECT_AUTOFILE      default 1   — set 0 to report-only, no VOA write
#   OPS_DEFECT_DAEMON_STATUS_CMD   test hook — overrides launchctl scan; must
#                                   print `label<TAB>exit_code` lines on stdout
#   OPS_DEFECT_SHIP_COUNT_OVERRIDE test hook — overrides the git-log ship count
check_ops_defect_selfdiag() {
    local alert_window_h="${OPS_DEFECT_ALERT_WINDOW_HOURS:-2}"
    local ship_window_h="${OPS_DEFECT_SHIP_WINDOW_HOURS:-1}"
    local dedup_h="${OPS_DEFECT_VOA_DEDUP_HOURS:-24}"
    local autofile="${CHUMP_OPS_DEFECT_AUTOFILE:-1}"
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

    local defects=()
    local wedge_class=""

    # ── Sub-check A: broken daemon exit codes (any, not gated by merge-staleness) ──
    local broken_daemons=()
    if [[ -n "${OPS_DEFECT_DAEMON_STATUS_CMD:-}" ]]; then
        while IFS=$'\t' read -r label code; do
            [[ -z "$label" ]] && continue
            [[ "$code" != "0" ]] && broken_daemons+=("$label(exit=$code)")
        done < <(eval "$OPS_DEFECT_DAEMON_STATUS_CMD" 2>/dev/null || true)
    elif command -v launchctl &>/dev/null && [[ "$(uname)" == "Darwin" ]]; then
        local uid
        uid="$(id -u)"
        while IFS= read -r label; do
            [[ -z "$label" ]] && continue
            local print_out exit_code
            print_out="$(launchctl print "gui/$uid/$label" 2>/dev/null \
                || launchctl print "system/$label" 2>/dev/null \
                || true)"
            exit_code="$(echo "$print_out" \
                | grep -E 'last exit code\s*=' \
                | grep -oE '[-]?[0-9]+' \
                | head -1 \
                || true)"
            [[ -z "$exit_code" ]] && continue
            [[ "$exit_code" != "0" ]] && broken_daemons+=("$label(exit=$exit_code)")
        done < <(launchctl list 2>/dev/null \
            | awk '{print $3}' \
            | grep -E '^(com|dev)\.chump\.' \
            || true)
    fi
    if [[ "${#broken_daemons[@]}" -gt 0 ]]; then
        defects+=("broken-daemon-exit: ${broken_daemons[*]}")
        wedge_class="broken-daemon-exit"
    fi

    # ── Sub-check B: alert fired while ship-rate ground truth was healthy ─────
    local false_positive_alerts=()
    if [[ -f "$amb" ]] && command -v python3 &>/dev/null; then
        local now_ts alert_cut
        now_ts="$(date -u +%s)"
        alert_cut=$(( now_ts - alert_window_h * 3600 ))
        while IFS=$'\t' read -r cond reason; do
            [[ -z "$cond" ]] && continue
            false_positive_alerts+=("$cond ($reason)")
        done < <(python3 -c '
import sys, json, datetime
cut = int(sys.argv[1])
def epoch(ts):
    try:
        return int(datetime.datetime.strptime(ts.replace("Z","+0000"),"%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception:
        return 0
try:
    f = open(sys.argv[2])
except Exception:
    sys.exit(0)
for line in f:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("kind") != "operator_recall":
        continue
    if epoch(d.get("ts", "")) >= cut:
        cond = d.get("condition", "?")
        reason = str(d.get("reason", ""))[:60]
        print(cond + "\t" + reason)
' "$alert_cut" "$amb" 2>/dev/null || true)
    fi

    if [[ "${#false_positive_alerts[@]}" -gt 0 ]]; then
        local ship_count
        if [[ -n "${OPS_DEFECT_SHIP_COUNT_OVERRIDE:-}" ]]; then
            ship_count="$OPS_DEFECT_SHIP_COUNT_OVERRIDE"
        else
            ship_count="$(git -C "$REPO_ROOT" log origin/main --since="${ship_window_h} hours ago" --oneline 2>/dev/null | wc -l | tr -d ' ')"
        fi
        if [[ "${ship_count:-0}" -gt 0 ]]; then
            defects+=("false-positive-alert: ${false_positive_alerts[*]} fired in the last ${alert_window_h}h while ${ship_count} commit(s) merged into origin/main in the last ${ship_window_h}h (ground truth: fleet was shipping)")
            [[ -z "$wedge_class" ]] && wedge_class="false-positive-alert"
        fi
    fi

    if [[ "${#defects[@]}" -eq 0 ]]; then
        register_check "ops-defect" "pass" \
            "no broken-daemon-exit and no false-positive alerts detected (alert window ${alert_window_h}h, ship window ${ship_window_h}h)" \
            ""
        return
    fi

    local detail="ops-defect(s) detected: ${defects[*]}"
    local remedy="chump voice --wedge-class $wedge_class --minutes-lost 10 --fix-shape gate --fix '<describe fix>'"

    # ── Dedup: skip auto-file if same wedge_class VOA filed within dedup window ──
    local already_filed=0
    if [[ -f "$amb" ]] && command -v python3 &>/dev/null; then
        already_filed="$(python3 -c '
import sys, json, datetime
cut = int(sys.argv[1])
wc = sys.argv[2]
def epoch(ts):
    try:
        return int(datetime.datetime.strptime(ts.replace("Z","+0000"),"%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception:
        return 0
found = 0
try:
    f = open(sys.argv[3])
except Exception:
    print(0)
    sys.exit(0)
for line in f:
    try:
        d = json.loads(line)
    except Exception:
        continue
    if d.get("kind") != "voice_of_agent_filed":
        continue
    if d.get("wedge_class") != wc:
        continue
    if epoch(d.get("ts", "")) >= cut:
        found = 1
print(found)
' "$(( $(date -u +%s) - dedup_h * 3600 ))" "$wedge_class" "$amb" 2>/dev/null || echo 0)"
    fi

    if [[ "$autofile" == "1" && "$already_filed" != "1" ]] && command -v "$CHUMP_BIN" &>/dev/null; then
        local minutes_lost=10
        [[ "${#broken_daemons[@]}" -gt 0 && "${#false_positive_alerts[@]}" -gt 0 ]] && minutes_lost=20
        local fix_text="fleet-doctor detected ${wedge_class}: ${defects[*]}"
        fix_text="${fix_text:0:400}"
        local voice_out voice_rc
        voice_rc=0
        voice_out="$("$CHUMP_BIN" voice \
            --wedge-class "$wedge_class" \
            --minutes-lost "$minutes_lost" \
            --fix-shape gate \
            --fix "$fix_text" \
            --evidence "fleet-doctor-strict.sh" \
            --target-repo anonymous 2>&1)" || voice_rc=$?
        if [[ "$voice_rc" -eq 0 ]]; then
            local voa_id
            voa_id="$(echo "$voice_out" | grep -oE 'VOA-[0-9]+' | head -1)"
            detail="${detail}; auto-filed ${voa_id:-VOA} via 'chump voice'"
            remedy="review the auto-filed VOA under docs/gaps/${voa_id:-VOA-NNNN}.yaml and docs/voice/${voa_id:-VOA-NNNN}-FULL.yaml"
        else
            detail="${detail}; VOA auto-file FAILED (rc=$voice_rc): $(echo "$voice_out" | tail -1)"
        fi
    elif [[ "$already_filed" == "1" ]]; then
        detail="${detail}; VOA already filed for wedge_class=$wedge_class within ${dedup_h}h — not re-filing"
    fi

    register_check "ops-defect" "fail" "$detail" "$remedy"
}

# ── Check 13 (CREDIBLE-119): Live Anthropic auth-path validity ─────────────────
#
# `fleet_doctor_validate()` (src/auth.rs) only checks credential PRESENCE —
# a 108-char ANTHROPIC_API_KEY and a 3-day-stale OAUTH token both count as
# "present" even though neither authenticates. That gap let the fleet sit
# dead for ~46h (2026-06-07) while `chump fleet doctor` reported healthy;
# only run-fleet's separate INFRA-621 launch-time probe caught it.
#
# Reuse the canonical RESILIENT-086 live probe (scripts/coord/auth-status.sh)
# instead of re-implementing it: it makes a real authenticated call down
# each credential path (a cheap `claude -p`/REST call) and returns 0 only
# when the path `claude -p` would actually use is valid. rc=1 means BOTH
# paths are dead; rc=2 means a valid path exists but isn't the active one
# (the precedence trap) — both are real failures a worker will hit.
#
# No bypass env var: a host with NO credentials configured at all naturally
# SKIPs (auth-status.sh's "no credentials found" case — that absence is
# already a distinct, pre-existing signal owned by fleet_doctor_validate()
# presence checks and the farmer's AUTH_DEAD path). This check's job is
# narrower — catch CONFIGURED-but-invalid credentials — so it never forces
# a live network probe on a credential-less CI runner or fresh dev box.
check_auth_probe() {
    local probe_script="$REPO_ROOT/scripts/coord/auth-status.sh"
    if [[ ! -f "$probe_script" ]]; then
        register_check "auth-probe" "skip" "auth-status.sh not found — skipping live probe" ""
        return
    fi

    local probe_out probe_rc
    probe_rc=0
    probe_out="$(bash "$probe_script" --quiet 2>&1)" || probe_rc=$?

    if [[ "$probe_rc" -eq 0 ]]; then
        register_check "auth-probe" "pass" "$probe_out" ""
    elif [[ "$probe_out" == *"no credentials found"* ]]; then
        register_check "auth-probe" "skip" \
            "no credentials configured to probe — $probe_out" ""
    elif [[ "$probe_rc" -eq 2 ]]; then
        register_check "auth-probe" "fail" \
            "auth misconfigured: a valid credential exists but is not the active path — $probe_out" \
            "bash $probe_script --probe  # shows exact fix; workers fail until the active path is switched"
    else
        register_check "auth-probe" "fail" \
            "auth dead: both paths rejected — $probe_out" \
            "run 'claude setup-token' for a fresh oauth token, or provide a funded ANTHROPIC_API_KEY; see bash $probe_script --probe"
    fi
}

# ── Check 15 (RESILIENT-1053, originally scoped as RESILIENT-1052 — see below): self-healer heartbeat — is anyone paging when
#    the self-healers themselves go dark? ──────────────────────────────────
#
# organ-watchdog.sh and organ-reconcile.sh heal every OTHER organ, but
# nothing in this file checked THEM: organ-roll-call-live (check 14) reads
# organ-manifest.txt, and chump-organ-reconcile.timer is *intentionally*
# excluded from that manifest (see the NOTE in organ-manifest.txt — its
# liveness was left to install-helsinki-atc.sh, which only runs on deploy or
# boot, not continuously). If either healer's timer silently stops ticking
# between deploys, every organ it protects rots unattended and nothing
# pages — the exact meta-failure this check closes.
#
# Both healers emit an unconditional per-run ambient event on every
# successful cycle:
#   organ-watchdog.sh   -> kind=organ_watchdog_tick        (every ~5 min)
#   organ-reconcile.sh  -> kind=organ_reconcile_applied OR
#                          kind=organ_reconcile_noop        (every ~3 min)
# Treat the newest of those as a heartbeat: if either has never ticked while
# the OTHER has (proof ambient logging works on this node), or either has
# gone stale past its cadence + buffer, FAIL and emit a paging ambient event
# (kind=self_healer_heartbeat_stale) so the silence itself becomes visible.
# If NEITHER has ever ticked, this isn't the primary node (or a fresh
# checkout with no ambient history) — skip rather than false-alarm.
#
# Thresholds (override via env)
#   SELF_HEALER_WATCHDOG_STALE_S   default 1200 (20min) — watchdog cadence is 5min
#   SELF_HEALER_RECONCILE_STALE_S  default 1200 (20min) — reconcile cadence is 3min
check_self_healer_heartbeat() {
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    if [[ ! -f "$amb" ]]; then
        register_check "self-healer-heartbeat" "skip" "no ambient.jsonl present — nothing to check" ""
        return
    fi
    if ! command -v python3 &>/dev/null; then
        register_check "self-healer-heartbeat" "skip" "python3 unavailable — skipping self-healer heartbeat scan" ""
        return
    fi

    local watchdog_max_s="${SELF_HEALER_WATCHDOG_STALE_S:-1200}"
    local reconcile_max_s="${SELF_HEALER_RECONCILE_STALE_S:-1200}"

    local result
    result="$(python3 -c '
import sys, json, datetime
def epoch(ts):
    try: return int(datetime.datetime.strptime(ts.replace("Z","+0000"),"%Y-%m-%dT%H:%M:%S%z").timestamp())
    except Exception: return 0
last_watchdog = 0
last_reconcile = 0
for line in open(sys.argv[1], "r", errors="replace"):
    try: d = json.loads(line)
    except Exception: continue
    k = d.get("kind")
    e = epoch(d.get("ts", ""))
    if k == "organ_watchdog_tick":
        last_watchdog = max(last_watchdog, e)
    elif k in ("organ_reconcile_applied", "organ_reconcile_noop"):
        last_reconcile = max(last_reconcile, e)
print(last_watchdog)
print(last_reconcile)
' "$amb" 2>/dev/null)"

    local last_watchdog last_reconcile
    last_watchdog="$(printf '%s' "$result" | sed -n 1p)"; last_watchdog="${last_watchdog:-0}"
    last_reconcile="$(printf '%s' "$result" | sed -n 2p)"; last_reconcile="${last_reconcile:-0}"

    if [[ "$last_watchdog" -eq 0 && "$last_reconcile" -eq 0 ]]; then
        register_check "self-healer-heartbeat" "skip" \
            "no organ_watchdog_tick or organ_reconcile_applied/noop events in ambient.jsonl — self-healers have never ticked on this node (fresh checkout or not the primary node)" ""
        return
    fi

    local now_ts
    now_ts="$(date -u +%s)"
    local fails=()

    if [[ "$last_watchdog" -eq 0 ]]; then
        fails+=("chump-organ-watchdog.timer has NEVER ticked (no organ_watchdog_tick event) while organ-reconcile has — the watchdog is dead and unowned")
    else
        local watchdog_age=$(( now_ts - last_watchdog ))
        if (( watchdog_age >= watchdog_max_s )); then
            fails+=("chump-organ-watchdog.timer silent for ${watchdog_age}s (threshold ${watchdog_max_s}s) — stopped ticking")
        fi
    fi

    if [[ "$last_reconcile" -eq 0 ]]; then
        fails+=("chump-organ-reconcile.timer has NEVER ticked (no organ_reconcile_applied/noop event) while organ-watchdog has — the reconcile is dead and unowned")
    else
        local reconcile_age=$(( now_ts - last_reconcile ))
        if (( reconcile_age >= reconcile_max_s )); then
            fails+=("chump-organ-reconcile.timer silent for ${reconcile_age}s (threshold ${reconcile_max_s}s) — stopped ticking")
        fi
    fi

    if [[ "${#fails[@]}" -gt 0 ]]; then
        local detail
        detail="$(printf '%s; ' "${fails[@]}")"
        detail="${detail%; }"
        # Write directly rather than routing through ambient-emit.sh: its
        # INFRA-101 schema gate only recognizes a small legacy "event" enum
        # and rejects brand-new kinds outright (silently, via the caller's
        # `|| true`) unless CHUMP_AMBIENT_SCHEMA_CHECK=0 is threaded through —
        # exactly the kind of silent paging failure this check exists to
        # eliminate, so it must not depend on that path.
        local detail_json
        detail_json="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
            || printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"ts":"%s","kind":"self_healer_heartbeat_stale","detail":"%s","source":"fleet-doctor-strict.sh"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail_json" >> "$amb" 2>/dev/null || true
        register_check "self-healer-heartbeat" "fail" "$detail" \
            "systemctl status chump-organ-watchdog.timer chump-organ-reconcile.timer; sudo systemctl restart chump-organ-watchdog.timer chump-organ-reconcile.timer; sudo bash scripts/setup/install-helsinki-atc.sh"
        return
    fi

    register_check "self-healer-heartbeat" "pass" \
        "organ-watchdog ticked $(( now_ts - last_watchdog ))s ago, organ-reconcile ticked $(( now_ts - last_reconcile ))s ago (thresholds ${watchdog_max_s}s/${reconcile_max_s}s)" ""
}

#  16. tracked-config-drift — RESILIENT-1106: #4593 moved worker self-heal
#      policy into tracked scripts/setup/*.env config-as-code files so it
#      could be reviewed and reproduced in git. But a node's hand-deployed,
#      git-UNTRACKED launcher (~/node1-worker-run.sh) or machine-local
#      ~/.chump/providers.env can still hard-set the same var name to a
#      DIFFERENT literal value and silently win at runtime — the exact
#      "nothing in git could review, reproduce, or heal the policy" failure
#      mode #4593 closed for the UNSET case, but not for the OVERRIDDEN case.
#      This check diffs each tracked file's canonical value against any live
#      untracked file's literal (non-`:=`) assignment of the same var.
check_tracked_config_drift() {
    if ! command -v python3 &>/dev/null; then
        register_check "tracked-config-drift" "skip" "python3 unavailable — skipping config-drift scan" ""
        return
    fi

    local tracked_glob="${CHUMP_CONFIG_DRIFT_TRACKED_GLOB:-$REPO_ROOT/scripts/setup/*.env}"
    local -a tracked_files=()
    # shellcheck disable=SC2206
    tracked_files=( $tracked_glob )
    if [[ ! -e "${tracked_files[0]:-}" ]]; then
        register_check "tracked-config-drift" "skip" "no tracked config-as-code files match '$tracked_glob'" ""
        return
    fi

    local live_glob="${CHUMP_CONFIG_DRIFT_LIVE_GLOB:-$HOME/*-worker-run.sh $HOME/.chump/providers.env $HOME/.chump/chumpd.env}"
    local -a live_files=()
    local pattern
    for pattern in $live_glob; do
        # shellcheck disable=SC2206
        local -a expanded=( $pattern )
        [[ -e "${expanded[0]:-}" ]] && live_files+=( "${expanded[@]}" )
    done
    if [[ "${#live_files[@]}" -eq 0 ]]; then
        register_check "tracked-config-drift" "skip" \
            "no untracked live override files present (checked: $live_glob) — nothing outside git to drift from" ""
        return
    fi

    local drift_out
    drift_out="$(python3 -c '
import re, sys, json

tracked_paths = sys.argv[1].split("\x1e")
live_paths = sys.argv[2].split("\x1e")

# Canonical values from tracked config-as-code: both plain "VAR=value" and
# bash default-assignment ": \"${VAR:=value}\"" forms.
canon = {}
canon_src = {}
default_re = re.compile(r"^\s*:\s*\"\$\{(\w+):=([^}]*)\}\"")
plain_re = re.compile(r"^\s*(?:export\s+)?(\w+)=([^\s#]*)")
for p in tracked_paths:
    try:
        with open(p) as f:
            for line in f:
                line = line.rstrip("\n")
                m = default_re.match(line)
                if not m:
                    m = plain_re.match(line)
                if m:
                    var, val = m.group(1), m.group(2).strip()
                    canon[var] = val
                    canon_src[var] = p
    except OSError:
        continue

# Live overrides: only HARD assignments (no ":=") count as an override that
# silently wins over the tracked default. Last assignment in a file wins,
# mirroring shell semantics.
live = {}
live_src = {}
for p in live_paths:
    try:
        with open(p) as f:
            for line in f:
                line = line.rstrip("\n")
                if ":=" in line:
                    continue
                m = plain_re.match(line)
                if m:
                    var, val = m.group(1), m.group(2).strip()
                    live[var] = val
                    live_src[var] = p
    except OSError:
        continue

drifted = []
for var, cval in canon.items():
    if var in live and live[var] != cval:
        drifted.append({
            "var": var, "tracked_value": cval, "live_value": live[var],
            "tracked_file": canon_src[var], "live_file": live_src[var],
        })

print(json.dumps({"checked": len(canon), "drifted": drifted}))
' "$(IFS=$'\x1e'; echo "${tracked_files[*]}")" "$(IFS=$'\x1e'; echo "${live_files[*]}")" 2>/dev/null)"

    if [[ -z "$drift_out" ]]; then
        register_check "tracked-config-drift" "skip" "config-drift scan produced no output (parse error?)" ""
        return
    fi

    local checked_count drift_count
    checked_count="$(printf '%s' "$drift_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["checked"])' 2>/dev/null || echo 0)"
    drift_count="$(printf '%s' "$drift_out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["drifted"]))' 2>/dev/null || echo 0)"

    if [[ "$drift_count" -gt 0 ]]; then
        local detail
        detail="$(printf '%s' "$drift_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)["drifted"]
parts = []
for x in d:
    parts.append("%s: tracked=%r (%s) vs live=%r (%s)" % (x["var"], x["tracked_value"], x["tracked_file"], x["live_value"], x["live_file"]))
print("; ".join(parts))
' 2>/dev/null)"
        local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        local detail_json
        detail_json="$(printf '%s' "$detail" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
            || printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        printf '{"ts":"%s","kind":"tracked_config_drift","detail":"%s","source":"fleet-doctor-strict.sh"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$detail_json" >> "$amb" 2>/dev/null || true
        register_check "tracked-config-drift" "fail" "$detail" \
            "reconcile the live override to match the tracked value, or if the live value is intentional, update the tracked scripts/setup/*.env file and ship it so the policy is reviewable in git"
        return
    fi

    register_check "tracked-config-drift" "pass" \
        "$checked_count tracked var(s) checked against ${#live_files[@]} live file(s) — no drift" ""
}

#  17. checkout-parked-off-main — RESILIENT-1512: the canonical gap-store
#      checkout (this REPO_ROOT) was observed sitting on a feature branch
#      (fix/apex-watchdog-skip-not-always-on) with ~8.9k dirty files while
#      local main was 17 commits / 21h behind origin — invisible until a
#      `chump gap ship` refused to close a gap whose PR had already merged.
#      Tracks a marker file recording (branch, first-seen-ts) so a checkout
#      that's merely mid-rebase for a few minutes doesn't page, but one
#      parked off main for over CHECKOUT_PARKED_STALE_S does.
check_checkout_parked_off_main() {
    if [[ ! -d "$REPO_ROOT/.git" ]]; then
        register_check "checkout-parked-off-main" "skip" "no .git under REPO_ROOT" ""
        return
    fi
    local branch
    branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")"
    local marker="$REPO_ROOT/.chump-locks/checkout-off-main.marker"
    local stale_s="${CHECKOUT_PARKED_STALE_S:-3600}"
    local now_ts
    now_ts="$(date -u +%s)"

    if [[ "$branch" == "main" ]]; then
        rm -f "$marker" 2>/dev/null || true
        register_check "checkout-parked-off-main" "pass" "checkout is on main" ""
        return
    fi

    mkdir -p "$REPO_ROOT/.chump-locks" 2>/dev/null || true
    local marker_branch="" marker_ts=0
    if [[ -f "$marker" ]]; then
        marker_branch="$(sed -n 1p "$marker" 2>/dev/null)"
        marker_ts="$(sed -n 2p "$marker" 2>/dev/null)"; marker_ts="${marker_ts:-0}"
    fi

    if [[ "$marker_branch" != "$branch" ]]; then
        # Just switched onto this branch (or marker absent) — start the clock.
        printf '%s\n%s\n' "$branch" "$now_ts" > "$marker" 2>/dev/null || true
        register_check "checkout-parked-off-main" "pass" \
            "checkout on '$branch' (just detected — starting ${stale_s}s clock)" ""
        return
    fi

    local age=$(( now_ts - marker_ts ))
    if (( age >= stale_s )); then
        local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
        printf '{"ts":"%s","kind":"checkout_parked_off_main","branch":"%s","age_s":%d,"source":"fleet-doctor-strict.sh"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$branch" "$age" >> "$amb" 2>/dev/null || true
        register_check "checkout-parked-off-main" "fail" \
            "REPO_ROOT has sat on '$branch' for ${age}s (threshold ${stale_s}s) instead of main — gap ship proof-of-merge and other main-relative tooling degrade on this checkout" \
            "cd $REPO_ROOT && git status (triage/commit or stash the branch's changes), then git checkout main"
        return
    fi

    register_check "checkout-parked-off-main" "pass" \
        "checkout on '$branch' for ${age}s (threshold ${stale_s}s) — not yet stale" ""
}

#  19. canonical-checkout-dirty — RESILIENT-1686: `chump gap ship` used to run
#      `cargo hakari generate` in REPO_ROOT, rewriting Cargo.lock (-156/+18)
#      and workspace-hack/Cargo.toml on every ship. That residue then made the
#      NEXT ship refuse through the INFRA-2423 auto-fetch-on-dirty guard — a
#      ship that broke the next ship, stranding organ landings' gaps open and
#      needing a hand `git checkout --` of the residue. The generate call is
#      gone (crates/chump-gap-store/src/lib.rs, AC5), but a dirty canonical
#      checkout from ANY source must still be surfaced loudly rather than
#      silently blocking the next ship. RED when REPO_ROOT has uncommitted
#      changes to MODIFIED TRACKED files — explicitly including Cargo.lock and
#      workspace-hack/Cargo.toml (the residue class) — naming the offenders.
#      A mutant that drops Cargo.lock from the scan is killed by
#      scripts/ci/test-fleet-doctor-canonical-dirty.sh.
check_canonical_checkout_dirty() {
    if [[ ! -d "$REPO_ROOT/.git" ]]; then
        register_check "canonical-checkout-dirty" "skip" "no .git under REPO_ROOT" ""
        return
    fi
    # Tracked, modified files only (-uno: untracked state under .chump/, target/
    # etc. is expected and is not the residue class). Cargo.lock and
    # workspace-hack/Cargo.toml fall out of this porcelain naturally — the check
    # must NOT filter them out.
    local dirty
    dirty="$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no 2>/dev/null)"
    if [[ -z "$dirty" ]]; then
        register_check "canonical-checkout-dirty" "pass" \
            "canonical checkout is clean (no modified tracked files)" ""
        return
    fi
    local paths
    paths="$(printf '%s\n' "$dirty" | awk '{print $NF}' | tr '\n' ' ')"
    local lock_hit=0
    if printf '%s\n' "$dirty" | awk '{print $NF}' \
        | grep -qxE 'Cargo\.lock|workspace-hack/Cargo\.toml'; then
        lock_hit=1
    fi
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    printf '{"ts":"%s","kind":"canonical_checkout_dirty","lock_residue":%d,"paths":"%s","source":"fleet-doctor-strict.sh"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lock_hit" "$(printf '%s' "$paths" | tr '"' "'")" \
        >> "$amb" 2>/dev/null || true
    local detail="canonical checkout ($REPO_ROOT) has uncommitted changes to tracked file(s): ${paths}"
    if [[ "$lock_hit" -eq 1 ]]; then
        detail="${detail}— Cargo.lock/workspace-hack residue is exactly the RESILIENT-1686 class that makes the next chump gap ship refuse (INFRA-2423 auto-fetch-on-dirty)"
    fi
    register_check "canonical-checkout-dirty" "fail" "$detail" \
        "cd $REPO_ROOT && git checkout -- Cargo.lock workspace-hack/Cargo.toml (or git stash), then retry; if the residue keeps reappearing, something is still building cargo in the main checkout"
}

#  18. single-branch-refspec — INFRA-8210: the cuphead hub's gap-store checkout
#      was cloned with a single-branch fetch refspec
#      (+refs/heads/main:refs/remotes/origin/main), so `git fetch origin` only
#      ever updated origin/main — every remote FEATURE branch was invisible,
#      silently breaking dispatch resume, salvage, and rebases (they look for
#      remote branches that were never fetched). chump-node-install.sh and
#      node-converge now repair this to the all-branches refspec; this check
#      surfaces any checkout they have not yet reached as a finding.
check_fetch_refspec_single_branch() {
    if [[ ! -d "$REPO_ROOT/.git" ]]; then
        register_check "single-branch-refspec" "skip" "no .git under REPO_ROOT" ""
        return
    fi
    local full='+refs/heads/*:refs/remotes/origin/*'
    local current
    current="$(git -C "$REPO_ROOT" config --get-all remote.origin.fetch 2>/dev/null)"
    if [[ -z "$current" ]]; then
        # No fetch refspec at all (unusual) — a fetch would no-op. Treat as a
        # finding so the installer/converge repair gets a chance to run.
        register_check "single-branch-refspec" "fail" \
            "remote.origin.fetch is unset on $REPO_ROOT — remote branches will not fetch" \
            "git -C $REPO_ROOT config remote.origin.fetch '$full' && git -C $REPO_ROOT fetch origin"
        return
    fi
    if [[ "$current" == "$full" ]]; then
        register_check "single-branch-refspec" "pass" "fetch refspec is all-branches" ""
        return
    fi
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
    mkdir -p "$(dirname "$amb")" 2>/dev/null || true
    # Collapse any embedded newlines (multi-entry refspec) so the JSON stays one line.
    local refspec_field
    refspec_field="$(printf '%s' "$current" | tr '\n' ' ')"
    printf '{"ts":"%s","kind":"checkout_single_branch_refspec","refspec":"%s","source":"fleet-doctor-strict.sh"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$refspec_field" >> "$amb" 2>/dev/null || true
    register_check "single-branch-refspec" "fail" \
        "remote.origin.fetch on $REPO_ROOT is single-branch/narrow ('$refspec_field') — remote feature branches are invisible, breaking dispatch resume/salvage/rebases" \
        "git -C $REPO_ROOT config --replace-all remote.origin.fetch '$full' && git -C $REPO_ROOT fetch origin"
}

#  20. two-scope node — RESILIENT-1615: cuphead ran a SECOND, root/system-scope
#      chump install (out of /root/.chumpnode, 60+ enabled chump-* units under
#      /etc/systemd/system) alongside the ubuntu user-scope one for 24 days. The
#      user-scope `chump node pause` never touched the system-scope organs, so
#      cut PRs were reopened four times and converge re-enabled timers. A
#      converged node must have exactly ONE install in ONE scope. RED when
#      `chump node scopes` reports a two-scope node, naming both roots.
check_second_scope() {
    local bin
    bin="$(command -v "$CHUMP_BIN" 2>/dev/null || true)"
    if [[ -z "$bin" ]]; then
        register_check "second-scope" "skip" "chump binary not found — skipping two-scope check" ""
        return
    fi
    local out
    out="$("$bin" node scopes --json 2>/dev/null || true)"
    if [[ -z "$out" ]]; then
        register_check "second-scope" "skip" "chump node scopes produced no output" ""
        return
    fi
    local two_scope
    two_scope="$(printf '%s' "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("1" if d.get("two_scope") else "0")' 2>/dev/null || echo 0)"
    if [[ "$two_scope" == "1" ]]; then
        local roots
        roots="$(printf '%s' "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
parts = []
for s in d.get("scopes", []):
    if s.get("installed"):
        parts.append("%s=%s" % (s.get("scope"), s.get("root") or "(units only)"))
print(", ".join(parts))
' 2>/dev/null || echo "")"
        register_check "second-scope" "fail" \
            "two-scope node: a chump install exists in more than one supervisor scope [$roots] — a converged node must have exactly ONE install in ONE scope (RESILIENT-1615)" \
            "retire the second install (disable its chump-* units + remove its ~/.chumpnode or /root/.chumpnode); inspect with: chump node scopes"
        return
    fi
    register_check "second-scope" "pass" "single-scope node (no second-scope install)" ""
}

# ── Check 19 (RESILIENT-1604): node admission ceiling ──────────────────────────
# cuphead 2026-10-16: 9 worker.sh + 8 claude -p + 9 cargo/rustc on 4 cores
# (load 12-16) while node.env carried no ceiling, so the 900s subagent budget
# killed finished work. The ceiling is enforced by `chump admit` (Rust); this
# check is the read-only observer: it reads the same ceiling and counts the
# same processes, and goes RED when either class runs past its ceiling (a
# spawn site that bypasses `chump admit`). It never emits or mutates.
check_admission_ceiling() {
    # Resolve next to this script (BASH_SOURCE), so a sourced run finds it too.
    local lib
    lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../setup/lib/node-admission-ceiling.sh"
    if [[ ! -f "$lib" ]]; then
        register_check "admission-ceiling" "skip" "scripts/setup/lib/node-admission-ceiling.sh missing" ""
        return
    fi
    # shellcheck source=../setup/lib/node-admission-ceiling.sh
    source "$lib"
    if ! command -v pgrep >/dev/null 2>&1; then
        register_check "admission-ceiling" "skip" "pgrep not available" ""
        return
    fi
    local node_env="${CHUMP_STATE_DIR:-$HOME/.chump}/node.env"
    local cl_ceil cg_ceil cl_n cg_n
    cl_ceil="$(chump_admission_ceiling_for CHUMP_MAX_CONCURRENT_CLAUDE "$node_env")"
    cg_ceil="$(chump_admission_ceiling_for CHUMP_MAX_CONCURRENT_CARGO_JOBS "$node_env")"
    # pgrep -fc exits 1 on zero matches; capture, then sanitize.
    cl_n="$(pgrep -fc 'claude -p' 2>/dev/null || true)"
    cg_n="$(pgrep -fc '(^|/)(cargo|rustc)( |$)' 2>/dev/null || true)"
    cl_n="${cl_n%%$'\n'*}"
    cg_n="${cg_n%%$'\n'*}"
    case "$cl_n" in '' | *[!0-9]*) cl_n=0 ;; esac
    case "$cg_n" in '' | *[!0-9]*) cg_n=0 ;; esac
    local summary="claude -p ${cl_n}/${cl_ceil}, cargo/rustc ${cg_n}/${cg_ceil} (ceiling: env > ${node_env} > max(1, nproc/2))"
    if (( cl_n > cl_ceil || cg_n > cg_ceil )); then
        register_check "admission-ceiling" "fail" \
            "over the node admission ceiling: ${summary} — a spawn site is bypassing chump admit" \
            "pgrep -fa 'claude -p'; pgrep -fa '(^|/)(cargo|rustc)( |$)'  # find the spawner; gate it with 'chump admit <claude|cargo> --wait-s N'"
    else
        register_check "admission-ceiling" "pass" "$summary" ""
    fi
}

# ── Check 20 (INFRA-8588): node.env carries no `export` line ───────────────────
# cuphead 2026-10-18: node.env mixed `export CHUMP_NODE_WORK_ENABLED=0` with bare
# lines, so systemd EnvironmentFile units (worker, converge, gap-close) logged
# "Ignoring invalid environment assignment export ..." and never saw the pause
# knobs, while bash-sourcing organs honored them — a split-brain node config.
# node.env MUST be the single systemd-compatible form: bare KEY=VALUE, no export.
# This flags any export line so the operator rewrites it (a re-run of
# chump-node-install.sh rewrites the whole file bare).
check_node_env_no_export() {
    local node_env="${CHUMP_STATE_DIR:-$HOME/.chump}/node.env"
    if [[ ! -f "$node_env" ]]; then
        register_check "node-env-no-export" "skip" "node.env not present ($node_env — not an installed node)" ""
        return
    fi
    # grep under set -o pipefail: capture, then test (per Phase R shell rule).
    local offenders
    offenders="$(grep -nE '^[[:space:]]*export[[:space:]]' "$node_env" 2>/dev/null || true)"
    if [[ -n "$offenders" ]]; then
        local n
        n="$(printf '%s\n' "$offenders" | grep -c . || true)"
        register_check "node-env-no-export" "fail" \
            "$node_env has $n export line(s) — systemd EnvironmentFile units silently ignore them (INFRA-8588): $(printf '%s' "$offenders" | tr '\n' ';')" \
            "re-run: bash $REPO_ROOT/scripts/setup/chump-node-install.sh --role <role> --reconcile-organs-only  # rewrites node.env bare"
    else
        register_check "node-env-no-export" "pass" "$node_env is bare KEY=VALUE (no export lines)" ""
    fi
}

# ── Check 21 (CREDIBLE-1568/1570): load-aware dead-man installed + alive ──────
# RESILIENT-1611's node-level dead-man was "shipped != installed" (code-on-disk
# on zero nodes) AND silent when healthy (nothing could prove it alive). This
# check closes both: RED when chump-load-aware-deadman.timer is missing/inactive
# on a systemd host, OR when the last deadman_tick heartbeat in ambient.jsonl is
# older than 5 minutes — so a node that lacks the organ, or whose dead-man has
# gone dark, is a paged/observable condition instead of a silent hole.
# The 5-minute staleness threshold is fixed, not env-tunable (it is a safety
# input): the timer runs every 60s, so 5 minutes is five missed ticks.
check_load_aware_deadman() {
    # CREDIBLE-1570 (AC3): read the SAME canonical node log the installed
    # dead-man writes. The dead-man lives in ~/.local/bin and cannot know
    # $REPO_ROOT, so it defaults to $HOME/chump/.chump-locks/ambient.jsonl; this
    # reader must resolve identically or a healthy node false-REDs. On the main
    # checkout $REPO_ROOT already IS $HOME/chump, so this is equivalent there and
    # strictly more correct from a worktree. Derived from $HOME (not a CHUMP_*
    # path env default) so a sandbox-HOME test exercises the real default.
    local amb="${CHUMP_AMBIENT_LOG:-$HOME/chump/.chump-locks/ambient.jsonl}"
    local timer="chump-load-aware-deadman.timer"
    local stale_s=300   # 5 minutes — RED past this (AC: older than 5 minutes)

    # Non-systemd node legitimately has no timer — not applicable, skip.
    if ! command -v systemctl >/dev/null 2>&1; then
        register_check "load-aware-deadman" "skip" "systemctl unavailable — not a systemd host, dead-man not applicable" ""
        return
    fi

    # 1. Timer must be installed and active.
    if ! systemctl --user is-active --quiet "$timer" 2>/dev/null; then
        register_check "load-aware-deadman" "fail" \
            "$timer missing or inactive — the RESILIENT-1611 node dead-man is not installed/running on this node (shipped != installed)" \
            "bash scripts/setup/install-load-aware-deadman.sh; systemctl --user status $timer"
        return
    fi

    # 2. Heartbeat must be fresh (newest deadman_tick within $stale_s).
    if [[ ! -f "$amb" ]]; then
        register_check "load-aware-deadman" "fail" \
            "$timer active but no ambient.jsonl at $amb to read a deadman_tick heartbeat from — cannot prove the dead-man is alive" \
            "ls -l $amb; systemctl --user status $timer"
        return
    fi
    local tick_line ts last_tick
    tick_line="$(grep '"kind":"deadman_tick"' "$amb" 2>/dev/null | tail -1 || true)"
    if [[ -z "$tick_line" ]]; then
        register_check "load-aware-deadman" "fail" \
            "$timer active but no deadman_tick heartbeat ever seen in $amb — the dead-man is not emitting its liveness signal" \
            "journalctl --user -u $timer --no-pager | tail; systemctl --user status $timer"
        return
    fi
    ts="$(printf '%s' "$tick_line" | grep -oE '"ts":"[^"]*"' | head -1 | cut -d'"' -f4)"
    last_tick="$(date -u -d "$ts" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$ts" +%s 2>/dev/null || echo 0)"
    if [[ -z "$last_tick" || "$last_tick" -eq 0 ]]; then
        register_check "load-aware-deadman" "fail" \
            "$timer active but the newest deadman_tick timestamp ('$ts') could not be parsed — heartbeat freshness unknown" \
            "tail $amb; journalctl --user -u $timer --no-pager | tail"
        return
    fi
    local now_ts age
    now_ts="$(date -u +%s)"
    age=$(( now_ts - last_tick ))
    if (( age >= stale_s )); then
        register_check "load-aware-deadman" "fail" \
            "$timer active but last deadman_tick was ${age}s ago (threshold ${stale_s}s) — the dead-man has gone dark (heartbeat stale)" \
            "journalctl --user -u $timer --no-pager | tail; systemctl --user restart $timer"
        return
    fi
    register_check "load-aware-deadman" "pass" \
        "$timer active, last deadman_tick ${age}s ago (threshold ${stale_s}s)" ""
}

# ── Check 22 (CREDIBLE-1602): ONE canonical gap store per node ────────────────
# cuphead 2026-10-21 carried THREE live state.db on one node (the 41MB store the
# architect+reconciler actually wrote, a stale ~/.chump Oct-19 store, and the
# node clone's stale Oct-10 store). The review organ, resolving its store from
# the node-checkout cwd, shipped a gap against the WRONG one and failed. A node
# must carry exactly ONE live gap store (PHASE-R R4). A store that has been
# RETIRED is renamed aside and marked with a CHUMP_STORE_ARCHIVED marker in its
# .chump dir (scripts/coord/archive-stale-gap-store.sh); a marked archive does
# NOT count. A worktree's .chump/state.db SYMLINK into the canonical checkout is
# not a separate store and never counts (only real files are counted). Scanned
# from $HOME — NOT a CHUMP_* path env, so a sandbox-HOME test exercises the real
# default; the ephemeral/cache/backup trees under $HOME are pruned so test
# fixtures under ~/tmp never false-RED a node.
check_single_store() {
    if ! command -v find >/dev/null 2>&1; then
        register_check "single-store" "skip" "find unavailable — cannot scan for node gap stores" ""
        return
    fi
    local scan_root="$HOME"
    if [[ -z "$scan_root" || ! -d "$scan_root" ]]; then
        register_check "single-store" "skip" "\$HOME ('$scan_root') is not a directory — cannot scan for node gap stores" ""
        return
    fi
    local -a stores=() noncanonical_stores=() unmarked_stores=() chump_dirs=()
    local f d s seen canon_store=""
    if [[ -n "${CHUMP_STATE_DB:-}" && ! -L "${CHUMP_STATE_DB}" ]]; then
        d="$(dirname "${CHUMP_STATE_DB}")"
        [[ -d "$d" ]] && chump_dirs+=("$d")
    fi
    # Real files named state.db / NONCANONICAL / CHUMP_STORE_ARCHIVED at */.chump/*,
    # bounded to depth 4 (reaches ~/.chump, ~/<repo>/.chump, ~/.chumpnode/repo/.chump)
    # with ephemeral trees pruned. -type f excludes worktree symlinks.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        chump_dirs+=("$(dirname "$f")")
    done < <(find "$scan_root" -maxdepth 4 \
        \( -type d \( -name tmp -o -name '.cache' -o -name 'node_modules' -o -name '*-backup' -o -name '.cargo' -o -name '.rustup' \) -prune \) -o \
        \( -type f \( -name state.db -o -name NONCANONICAL -o -name CHUMP_STORE_ARCHIVED \) -path '*/.chump/*' -print \) 2>/dev/null)

    local -a uniq_dirs=()
    for d in "${chump_dirs[@]+"${chump_dirs[@]}"}"; do
        seen=0
        for s in "${uniq_dirs[@]+"${uniq_dirs[@]}"}"; do
            [[ "$s" == "$d" ]] && { seen=1; break; }
        done
        (( seen == 0 )) && uniq_dirs+=("$d")
    done

    for d in "${uniq_dirs[@]+"${uniq_dirs[@]}"}"; do
        f="$d/state.db"
        if [[ -e "$d/NONCANONICAL" || -e "$d/CHUMP_STORE_ARCHIVED" || -e "$f.NONCANONICAL" ]]; then
            noncanonical_stores+=("$f")
            continue
        fi
        [[ -f "$f" && ! -L "$f" ]] && stores+=("$f")
    done

    for s in "${CHUMP_STATE_DB:-}" "$scan_root/chump/.chump/state.db" "$REPO_ROOT/.chump/state.db"; do
        [[ -n "$s" ]] || continue
        for f in "${stores[@]+"${stores[@]}"}"; do
            if [[ "$f" == "$s" ]]; then
                canon_store="$f"
                break 2
            fi
        done
    done
    [[ -z "$canon_store" && "${#stores[@]}" -gt 0 ]] && canon_store="${stores[0]}"
    for f in "${stores[@]+"${stores[@]}"}"; do
        [[ "$f" == "$canon_store" ]] || unmarked_stores+=("$f")
    done

    local n="${#stores[@]}"
    local noncanon_summary="${noncanonical_stores[*]:-none}"
    local unmarked_summary="${unmarked_stores[*]:-none}"
    if (( n > 1 )); then
        register_check "single-store" "fail" \
            "node has $n live gap stores (must be exactly ONE) — canonical: ${canon_store:-none}; non-canonical: ${noncanon_summary}; UNMARKED: ${unmarked_summary} — split-brain: a process that resolves its store from cwd/node.env can ship a gap against the wrong one (CREDIBLE-1602 / RESILIENT-1650)" \
            "keep the canonical store; retire each extra with: scripts/coord/archive-stale-gap-store.sh <path> --reason <why> --canonical <canonical-store> (or drop a NONCANONICAL marker beside it)"
    else
        register_check "single-store" "pass" \
            "exactly $n live gap store(s) on this node — canonical: ${canon_store:-none}; non-canonical: ${noncanon_summary}; UNMARKED: none (0 or 1 is healthy; NONCANONICAL / CHUMP_STORE_ARCHIVED stores and symlinked worktree stores are not counted)" ""
    fi
}

# Helper for check_cargo_storage_fixed_disk: pull one KEY="value" field out of a
# single `lsblk -Pno` pairs line (pairs mode is alignment-safe even when a
# column such as a partition's TRAN is empty).
_fd_pairs_val() {
    # $1 = key, $2 = pairs line. Prepend a space and require one before the key
    # so PKNAME="" does not satisfy a lookup for NAME (substring collision).
    printf ' %s\n' "$2" | sed -n "s/.* ${1}=\"\\([^\"]*\\)\".*/\\1/p"
}

# ── Check 21 (RESILIENT-1670 / RESILIENT-1657 item a'): cargo + sccache storage
# must sit on a fixed disk, never a removable or USB-transport block device ───
# closetjunky wedged three times in five days because its ENTIRE ~/.cargo
# (CARGO_HOME) and the 25G build target lived on a 32G USB flash stick
# (readlink -f ~/.cargo = /mnt/cjdata1/cargo; lsblk TRAN=usb, RM=1). Every
# cargo build streamed gigabytes of random writes to a thumb drive, writeback
# backed up past vm.dirty_ratio, every writer blocked in D state, sshd and
# tailscaled stalled, and the node "died" with no OOM. This invariant catches
# that class before the node wedges: CARGO_HOME, CARGO_TARGET_DIR and the
# sccache dir must each resolve (readlink -f) to a fixed device or not exist at
# all — never to a device whose `lsblk -no TRAN` is `usb` or whose RM flag is 1.
#
# Uses only readlink + lsblk (no df/findmnt), so the ci test stubs exactly those
# two commands via PATH. Path→device mapping is a longest-mountpoint-prefix
# match against the `lsblk -P` table; TRAN is a whole-disk property, so a
# matched partition's parent (PKNAME) row is consulted for transport.
check_cargo_storage_fixed_disk() {
    if ! command -v lsblk >/dev/null 2>&1; then
        register_check "cargo-storage" "skip" \
            "lsblk not available (not a Linux block-device host)" ""
        return
    fi

    # The three real cargo/sccache paths, by their genuine env names + cargo
    # defaults. These are the audited inputs themselves, not a test seam.
    local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
    local specs=("CARGO_HOME=$cargo_home")
    [[ -n "${CARGO_TARGET_DIR:-}" ]] && specs+=("CARGO_TARGET_DIR=$CARGO_TARGET_DIR")
    specs+=("SCCACHE_DIR=${SCCACHE_DIR:-$HOME/.cache/sccache}")

    # One block-device snapshot (pairs mode = alignment-safe with empty columns).
    local table
    table="$(lsblk -Pno NAME,PKNAME,TRAN,RM,MOUNTPOINT 2>/dev/null || true)"

    local offenders="" checked="" spec label path resolved
    for spec in "${specs[@]}"; do
        label="${spec%%=*}"
        path="${spec#*=}"
        [[ -z "$path" ]] && continue
        # Absent is explicitly fine (AC 5: "resolve to the internal SSD or absent").
        [[ -e "$path" ]] || { checked="$checked ${label}:absent"; continue; }
        resolved="$(readlink -f "$path" 2>/dev/null || printf '%s' "$path")"

        # Longest-mountpoint-prefix match against the block-device table.
        local best_mnt="" best_name="" best_pk="" best_rm="" best_tran=""
        local line mnt
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            mnt="$(_fd_pairs_val MOUNTPOINT "$line")"
            [[ -z "$mnt" || "$mnt" == "[SWAP]" ]] && continue
            # ${mnt%/} strips a trailing slash so the root mount "/" yields the
            # glob "/*" (matches any absolute path) instead of "//*" (matches none).
            if [[ "$resolved" == "$mnt" || "$resolved" == "${mnt%/}"/* ]]; then
                if (( ${#mnt} > ${#best_mnt} )); then
                    best_mnt="$mnt"
                    best_name="$(_fd_pairs_val NAME "$line")"
                    best_pk="$(_fd_pairs_val PKNAME "$line")"
                    best_rm="$(_fd_pairs_val RM "$line")"
                    best_tran="$(_fd_pairs_val TRAN "$line")"
                fi
            fi
        done <<< "$table"

        if [[ -z "$best_name" ]]; then
            # No block device claims this path (tmpfs/overlay/unknown) — can't
            # prove it removable, so don't fail on it.
            checked="$checked ${label}:unknown-dev"
            continue
        fi

        # TRAN lives on the whole disk; a matched partition's parent (PKNAME)
        # row carries the transport (and the removable flag).
        local tran="$best_tran" disk="$best_name" pline pname prm
        if [[ -n "$best_pk" ]]; then
            disk="$best_pk"
            while IFS= read -r pline; do
                [[ -z "$pline" ]] && continue
                pname="$(_fd_pairs_val NAME "$pline")"
                if [[ "$pname" == "$best_pk" ]]; then
                    tran="$(_fd_pairs_val TRAN "$pline")"
                    prm="$(_fd_pairs_val RM "$pline")"
                    [[ "$prm" == "1" ]] && best_rm="1"
                    break
                fi
            done <<< "$table"
        fi

        if [[ "$tran" == "usb" || "$best_rm" == "1" ]]; then
            local flags=""
            [[ "$tran" == "usb" ]] && flags="TRAN=usb"
            [[ "$best_rm" == "1" ]] && flags="${flags:+$flags,}RM=1"
            offenders="$offenders ${label}=${path} (readlink -f=${resolved}, /dev/${disk}, ${flags})"
        else
            checked="$checked ${label}:/dev/${disk}(fixed)"
        fi
    done

    if [[ -n "$offenders" ]]; then
        register_check "cargo-storage" "fail" \
            "cargo/sccache storage on a removable or USB device (RESILIENT-1657 item a'):$offenders" \
            "move CARGO_HOME, CARGO_TARGET_DIR and the sccache dir onto an internal/fixed disk and retire the removable media; on closetjunky ~/.cargo belongs on the SSD and target+sccache must not live on the USB sticks"
    else
        register_check "cargo-storage" "pass" \
            "cargo/sccache storage on a fixed disk or absent:${checked:- (none set)}" ""
    fi
}

# ── Check 22 (INFRA-8572): cargo-nextest must be installed on the node ───────
# Without cargo-nextest, pre-push falls back to cargo test (single process),
# risking env-var races across tests. Every linux-systemd / mac-launchd node
# must have cargo-nextest on PATH or at ${CARGO_HOME:-$HOME/.cargo}/bin/cargo-nextest.
check_cargo_nextest() {
    if [[ -n "${PREFIX:-}" && "${PREFIX}" == *com.termux* ]]; then
        register_check "cargo-nextest" "skip" "Termux host does not run the local Rust pre-push test gate" ""
        return
    fi
    local cargo_home="${CARGO_HOME:-${HOME:-/root}/.cargo}"
    local candidate="$cargo_home/bin/cargo-nextest"
    local resolved=""
    if command -v cargo-nextest >/dev/null 2>&1; then
        resolved="$(command -v cargo-nextest)"
    elif [[ -x "$candidate" ]]; then
        resolved="$candidate"
    fi
    if [[ -n "$resolved" ]]; then
        register_check "cargo-nextest" "pass" "cargo-nextest installed ($resolved)" ""
    else
        register_check "cargo-nextest" "fail" \
            "cargo-nextest absent from PATH and $candidate (INFRA-8572)" \
            "run 'chump node ensure-nextest' or 'cargo install cargo-nextest --locked'"
    fi
}

# ── Check 23 (INFRA-8589): installed systemd units carry no foreign host literals ──
# Scans installed units in ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user on a
# Linux host for non-comment lines containing /home/<other-user>, /Users/<name>,
# /root/ (when HOME != /root), /opt/homebrew, or User=<name> (in user scope).
check_installed_unit_host_literals() {
    if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Linux" ]]; then
        register_check "unit-literals" "skip" "non-Linux host; systemd user unit literal scan not applicable" ""
        return
    fi
    local exp_home="${HOME:-/root}"
    exp_home="${exp_home%/}"
    local unit_dir="${XDG_CONFIG_HOME:-${exp_home}/.config}/systemd/user"
    if [[ ! -d "$unit_dir" ]]; then
        register_check "unit-literals" "pass" "no systemd user unit dir at $unit_dir" ""
        return
    fi
    local bad_units=()
    local f fname line
    for f in "$unit_dir"/*.service "$unit_dir"/*.timer "$unit_dir"/*.socket "$unit_dir"/*.path "$unit_dir"/*.target; do
        [[ -f "$f" && ! -L "$f" ]] || continue
        fname="$(basename "$f")"
        local unit_bad=0
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ (^|[^A-Za-z0-9_])User=[A-Za-z_] ]]; then
                unit_bad=1; break
            fi
            if [[ "$line" == *"/opt/homebrew"* ]] || [[ "$line" == *"/Users/"* ]]; then
                unit_bad=1; break
            fi
            if [[ "$exp_home" != "/root" && "$line" == *"/root/"* ]]; then
                unit_bad=1; break
            fi
            if [[ "$line" =~ /home/([a-z0-9_-]+) ]]; then
                local Rest="$line"
                while [[ "$Rest" =~ /home/([a-z0-9_-]+) ]]; do
                    local cand="/home/${BASH_REMATCH[1]}"
                    if [[ "$cand" != "$exp_home" ]]; then
                        unit_bad=1; break
                    fi
                    Rest="${Rest#*"$cand"}"
                done
                [[ "$unit_bad" -eq 1 ]] && break
            fi
        done < "$f"
        [[ "$unit_bad" -eq 1 ]] && bad_units+=("$fname")
    done
    if [[ ${#bad_units[@]} -eq 0 ]]; then
        register_check "unit-literals" "pass" "installed units in $unit_dir carry no foreign host literals" ""
    else
        register_check "unit-literals" "fail" \
            "installed unit(s) in $unit_dir carry foreign host literals (INFRA-8589): ${bad_units[*]}" \
            "run 'chump node rerender-units' or 'bash scripts/ops/node-converge.sh'"
    fi
}

# When sourced for testing (FLEET_DOCTOR_SOURCED=1), stop here — the test
# harness calls individual check_* functions directly instead of paying for
# the full (networked) sweep.
if [[ "${FLEET_DOCTOR_SOURCED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi

# ── Run all checks ─────────────────────────────────────────────────────────────
check_binary
check_leases
check_disk
check_dirty_prs
check_gap_drift
check_p0_budget
check_pillar_coverage
check_silent_fleet_death
check_a2a_consensus
check_almanac_freshness
check_backlog_sync_freshness
check_organ_roll_call_live
check_required_status_checks
check_ops_defect_selfdiag
check_auth_probe
check_self_healer_heartbeat
check_tracked_config_drift
check_checkout_parked_off_main
check_canonical_checkout_dirty
check_fetch_refspec_single_branch
check_second_scope
check_admission_ceiling
check_node_env_no_export
check_load_aware_deadman
check_single_store
check_cargo_storage_fixed_disk
check_cargo_nextest
check_installed_unit_host_literals

# ── Render output ──────────────────────────────────────────────────────────────
if [[ "$OUTPUT" == "json" ]]; then
    python3 - <<PYEOF
import json, sys
checks = []
names   = $(python3 -c "import json; print(json.dumps(${CHECKS[*]+\"${CHECKS[*]}\"})" 2>/dev/null || echo "[]")
stats   = $(python3 -c "import json; print(json.dumps(${STATUSES[*]+\"${STATUSES[*]}\"})" 2>/dev/null || echo "[]")
details = $(python3 -c "import json; print(json.dumps(${DETAILS[*]+\"${DETAILS[*]}\"})" 2>/dev/null || echo "[]")
PYEOF
    # Simpler JSON render using bash arrays directly.
    printf '{"pass":%d,"fail":%d,"checks":[' "$PASS_COUNT" "$FAIL_COUNT"
    for i in "${!CHECKS[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        python3 -c "import json; print(json.dumps({'name':'${CHECKS[$i]}','status':'${STATUSES[$i]}','detail':'${DETAILS[$i]}','remedy':'${REMEDIES[$i]}'}))" 2>/dev/null \
            || printf '{"name":"%s","status":"%s"}' "${CHECKS[$i]}" "${STATUSES[$i]}"
    done
    printf ']}\n'
else
    echo "=== chump fleet doctor --strict (INFRA-1427) ==="
    echo
    for i in "${!CHECKS[@]}"; do
        local_status="${STATUSES[$i]}"
        if [[ "$local_status" == "pass" ]]; then
            printf '  \033[0;32m✓ PASS\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
        elif [[ "$local_status" == "skip" ]]; then
            printf '  \033[0;33m– SKIP\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
        else
            printf '  \033[0;31m✗ FAIL\033[0m  %-14s %s\n' "${CHECKS[$i]}" "${DETAILS[$i]}"
            if [[ -n "${REMEDIES[$i]}" ]]; then
                printf '             \033[0;33m↳ Fix:\033[0m  %s\n' "${REMEDIES[$i]}"
            fi
        fi
    done
    echo
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
        echo "  ✅ Fleet is healthy ($PASS_COUNT checks passed)"
    else
        echo "  ❌ $FAIL_COUNT check(s) failed — fleet needs attention"
    fi
fi

# Emit ambient telemetry (INFRA-755 / kind=fleet_doctor_run).
if [[ -x "$AMBIENT_EMIT" ]]; then
    bash "$AMBIENT_EMIT" fleet_doctor_run \
        pass_count="$PASS_COUNT" fail_count="$FAIL_COUNT" \
        2>/dev/null || true
fi

# Exit non-zero if any check failed (the core contract of --strict).
[[ "$FAIL_COUNT" -eq 0 ]]
