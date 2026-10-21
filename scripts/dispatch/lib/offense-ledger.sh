#!/usr/bin/env bash
# offense-ledger.sh — INFRA-3832 chronic-offender ledger, shared by the rc!=0
# branch and the rc==0 unverified_ship path (RESILIENT-1584).
# Needs: REPO_ROOT. Optional: AGENT_ID, CHUMP_SESSION_ID, CHUMP_AMBIENT_LOG.

# offense_bump GAP -> echoes the new consecutive non-ship count.
offense_bump() {
    local gap="$1" dir="$REPO_ROOT/.chump-locks/offense" n=0
    mkdir -p "$dir" 2>/dev/null || true
    [ -f "$dir/${gap}.count" ] && n=$(tr -cd '0-9' < "$dir/${gap}.count" 2>/dev/null || echo 0)
    n=$(( ${n:-0} + 1 ))
    printf '%d\n' "$n" > "$dir/${gap}.count" 2>/dev/null || true
    echo "$n"
}

# offense_clear GAP — a verified ship wipes the ledger.
offense_clear() {
    rm -f "$REPO_ROOT/.chump-locks/offense/${1}.count" 2>/dev/null || true
}

# classify_auto_block_reason KIND RC -> "Transient" or "Capability"
# Classifies whether the auto-block reason is transient (timeout/wedge) or
# a capability issue (repeated failures after model-tier escalation).
classify_auto_block_reason() {
    local kind="$1" rc="${2:-1}"
    case "$kind" in
        timeout|wedge)
            echo "Transient"
            ;;
        nonship_cooldown|unverified_ship|*)
            echo "Capability"
            ;;
    esac
}

# classify_failing_step LOGPATH -> short token naming WHERE the cycle failed.
# CREDIBLE-1578: the auto-block note recorded only rc + byte count, so a pipeline
# defect (the external-repo ~945B pre-agent failures *suspected* to have blocked
# 27 Olive gaps, with no surviving log) was invisible behind a healthy-looking
# spec. This reads the REAL cycle log and names the step ONLY from a marker that
# is literally present in the log, falling back to the last non-empty line so
# there is always a receipt-grounded reason — never a guessed cause, never just
# an rc. One concrete rc=1 pre-agent mechanism (no_onboard_scan) IS reproduced
# against the real repo name via the `chump improve` binary — receipt committed at
# scripts/ci/fixtures/credible-1578-reproduced-no-scan-cycle.log (test G8). Whether
# that mechanism accounts for ALL 27 historical Olive blocks cannot be confirmed:
# those logs did not survive (the exact hole this ledger closes), so the full
# historical decode still needs live Olive runs and is carved to a lane-1 follow-up.
# Output is sanitized to be JSON- and note-safe.
classify_failing_step() {
    local log="${1:-}"
    [ -n "$log" ] && [ -f "$log" ] || { echo "no_cycle_log"; return 0; }
    local sz
    sz=$(wc -c < "$log" 2>/dev/null | tr -d ' ' || echo 0)
    if [ "${sz:-0}" -lt 10 ]; then echo "empty_log(${sz}B)"; return 0; fi
    # Pre-agent failure markers, most-specific first. These are steps the
    # external-repo path (`chump improve` / src/improve.rs) can fail at BEFORE any
    # agent edits. The first — no_onboard_scan — is a REPRODUCED rc=1 cycle (the
    # `chump improve` binary bails at src/improve.rs:801; receipt committed at
    # scripts/ci/fixtures/credible-1578-reproduced-no-scan-cycle.log, test G8); the
    # others remain candidate signatures. A step is named ONLY when its marker is
    # literally present in the log; which (if any) of these blocked the 27 historical
    # Olive gaps is not confirmed — those logs did not survive, so the full decode
    # needs live Olive runs (CREDIBLE-1578 lane-1 follow-up). The classifier never
    # guesses: absent a marker, it reports the log tail as the receipt.
    if grep -qiE 'no onboard scan found|run .?chump onboard' "$log"; then echo "external_repo:no_onboard_scan"; return 0; fi
    if grep -qiE 'onboard scan contains no proposed gaps' "$log"; then echo "external_repo:empty_scan"; return 0; fi
    if grep -qiE 'git clone .* failed|could not fetch PR branch|git worktree add .* failed|timed out .* waiting for a concurrent clone' "$log"; then echo "external_repo:clone_or_worktree"; return 0; fi
    if grep -qiE 'staged [0-9,]+ untracked|docs/gaps/.*untracked|in-repo ship' "$log"; then echo "in_repo_ship_on_external_gap"; return 0; fi
    if grep -qiE 'Invalid authentication credentials|authentication_error|API Error: 401|credit balance is too low' "$log"; then echo "auth_or_billing"; return 0; fi
    # CREDIBLE-1578 faithfulness: only a decompose *failure* names this step. A bare
    # mention of "decompose" (a normal "Stage: decompose umbrella" progress line) is
    # NOT a precheck failure, so require a failure phrase co-occurring with the word —
    # never assert a cause the log does not actually show failing.
    if grep -qiE 'decompose.*(failed|failure|error|aborted|could not|unable)|(failed|failure|error|aborted|could not|unable).*decompose' "$log"; then echo "decompose_precheck"; return 0; fi
    # Fallback: the last non-empty line, trimmed, quote-stripped, length-capped.
    local last
    last="$(grep -v '^[[:space:]]*$' "$log" 2>/dev/null | tail -1 | tr -d '\r"\\' | tr '\t' ' ' | cut -c1-120)"
    if [ -n "$last" ]; then echo "tail: ${last}"; else echo "unclassified(${sz}B)"; fi
}

# offense_preserve_log GAP LOGPATH -> echoes a durable copy path (empty on no-op).
# CREDIBLE-1578 AC2: keep the cycle log that triggered the auto-block so the
# receipt survives the FLEET_LOG_DIR reaper ("no cycle log survives to say why").
# Copies into .chump-locks/offense/logs/ under REPO_ROOT (same root the ledger
# already uses). Best-effort: any failure yields empty output, never aborts the
# block.
offense_preserve_log() {
    local gap="$1" src="${2:-}" dir="$REPO_ROOT/.chump-locks/offense/logs"
    [ -n "$src" ] && [ -f "$src" ] || return 0
    mkdir -p "$dir" 2>/dev/null || return 0
    local ts dst
    ts="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)"
    dst="$dir/${gap}-block-${ts}.log"
    cp "$src" "$dst" 2>/dev/null || return 0
    echo "$dst"
}

# offense_maybe_block GAP N KIND RC LOGBYTES [LOGPATH] -> sets status=blocked at threshold.
# CREDIBLE-1578 AC2: LOGPATH is the cycle log that triggered this offense. When
# present it is preserved to a durable path and both its path and a classified
# failing-step are recorded in the block note / escalation event, so an
# auto-block names WHY instead of only rc + byte count.
offense_maybe_block() {
    local gap="$1" n="$2" kind="$3" rc="$4" logb="${5:-0}" logpath="${6:-}"
    local thr="${CHUMP_AUTO_BLOCK_THRESHOLD:-3}"
    [ "${CHUMP_AUTO_BLOCK_OFFENDERS:-1}" != "0" ] || return 0
    [ "${n:-0}" -ge "$thr" ] || return 0
    local classification="$(classify_auto_block_reason "$kind" "$rc")"
    local amb="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

    # CREDIBLE-1578: name the failing step from the real log + keep the log.
    local step preserved logref
    step="$(classify_failing_step "$logpath")"
    preserved="$(offense_preserve_log "$gap" "$logpath")"
    logref="${preserved:-none}"

    if [ "$classification" = "Capability" ]; then
        # RESILIENT-1344: Route capability-failure gaps to capable_agent_escalation queue.
        # Emit escalation event instead of auto-blocking, allowing the gap to remain
        # open for model-escalation paths (model upgrade, capable_agent dispatcher).
        type log >/dev/null 2>&1 && log "RESILIENT-1344: $gap escalated to capable_agent_escalation after ${n} non-ship cycles (kind=${kind}, classification=${classification}, step=${step}, cycle_log=${logref})"
        printf '{"event":"ALERT","kind":"capable_agent_escalation","ts":"%s","session":"%s","agent":"%s","gap_id":"%s","offenses":%d,"last_kind":"%s","rc":%d,"reason":"capability_failure","failing_step":"%s","cycle_log":"%s"}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_SESSION_ID:-fleet}" "${AGENT_ID:-}" "$gap" "$n" "$kind" "$rc" "$step" "$logref" \
            >> "$amb" 2>/dev/null || true
        offense_clear "$gap"
    else
        # Transient case: auto-block as before.
        local note="INFRA-3832 auto-block: ${n} consecutive non-ship cycles (last kind=${kind}, rc=${rc}, cycle_log=${logb}B, classification=${classification}). Failing step: ${step}. Cycle log kept at: ${logref}. Worker kept re-picking + looping; blocked to leave the pick pool. Un-block after fixing the spec / decomposing."
        if CHUMP_REPO="$REPO_ROOT" chump gap set "$gap" --status blocked --add-note "$note" >/dev/null 2>&1; then
            type log >/dev/null 2>&1 && log "INFRA-3832: auto-blocked $gap after ${n} non-ship cycles (kind=${kind}, classification=${classification}, step=${step}, cycle_log=${logref})"
            printf '{"event":"ALERT","kind":"gap_auto_blocked","ts":"%s","session":"%s","agent":"%s","gap_id":"%s","offenses":%d,"last_kind":"%s","classification":"%s","rc":%d,"failing_step":"%s","cycle_log":"%s"}\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CHUMP_SESSION_ID:-fleet}" "${AGENT_ID:-}" "$gap" "$n" "$kind" "$classification" "$rc" "$step" "$logref" \
                >> "$amb" 2>/dev/null || true
            offense_clear "$gap"
        else
            type log >/dev/null 2>&1 && log "INFRA-3832: WARN could not auto-block $gap (chump gap set failed); cooldown still applied"
        fi
    fi
    return 0
}
