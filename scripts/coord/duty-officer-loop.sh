#!/usr/bin/env bash
# scripts/coord/duty-officer-loop.sh — RESILIENT-274
#
# The standing loop that makes docs/design/DUTY_OFFICER.md real: reads
# firing health signals, looks each up in docs/process/PLAYBOOK_REGISTRY.yaml,
# and routes it T1 (executable auto-heal) -> T2 (agent-run runbook) ->
# T3 (escalate) — paging the operator ONLY at T3, and only through the quiet
# gate (scripts/coord/operator-escalation-registry.txt).
#
# Usage:
#   duty-officer-loop.sh tick              # one scan of recent ambient signals
#   duty-officer-loop.sh route <signal>    # route a single named signal (manual/test)
#   duty-officer-loop.sh heartbeat         # emit kind=duty_officer_heartbeat
#   duty-officer-loop.sh watch-sentinel    # check/revive/page chump-fleet-health-sentinel.service
#   duty-officer-loop.sh judgment-tick     # RESILIENT-1497: cadenced Opus peer-mind
#                                           judgment tick (file gaps/dispatch/
#                                           reprioritize/digest — non-gated only)
#   duty-officer-loop.sh status            # print registry coverage summary
#   duty-officer-loop.sh help
#
# Every routed signal emits kind=duty_officer_action to ambient with
# {signal, tier, verdict, detail}. verdict is one of:
#   healed        — T1 action ran (verify is the operator's job to confirm; this
#                   loop logs that the action fired, not that verify passed)
#   refuted       — T2 reality-check said the signal is a false positive; dropped
#   runbook_needed — T2 signal confirmed real; an agent must run the runbook
#   suppressed    — T3 signal has a page=false playbook entry; logged, not paged
#   paged         — T3 signal paged the operator via notify-operator.sh
#   unregistered  — signal has no registry entry; treated as T3/page (novel)
#
# Env overrides (mirrors the *-loop.sh pattern; all optional):
#   CHUMP_AMBIENT_LOG                    ambient.jsonl path
#   CHUMP_DUTY_OFFICER_REGISTRY          PLAYBOOK_REGISTRY.yaml path
#   CHUMP_DUTY_OFFICER_ESCALATION_REGISTRY  operator-escalation-registry.txt path
#   CHUMP_DUTY_OFFICER_REALITY_CHECK_CMD reality-check command (T2 gate)
#   CHUMP_DUTY_OFFICER_NOTIFY_CMD        notify command (T3 page)
#   CHUMP_DUTY_OFFICER_WINDOW_N          how many recent ambient lines to scan (default 200)
#   CHUMP_DUTY_OFFICER_EXECUTE           1 = actually run T1 action scripts (default 0 = log-only)
#   CHUMP_DUTY_OFFICER_T1_ESCALATE_THRESHOLD  raw firings of a T1 signal within the ambient
#                                         window before it's treated as NOT actually healing
#                                         and escalated T1->T3 + paged (default 10; RESILIENT-1230
#                                         — a live 13h dark-out was rationalized as
#                                         tier:1 verdict:healed 57x with 0 pages)
#   CHUMP_DUTY_OFFICER_SENTINEL_UNIT     health-sentinel systemd .service unit name
#                                         (default chump-fleet-health-sentinel.service)
#   CHUMP_DUTY_OFFICER_SENTINEL_TIMER    health-sentinel systemd .timer unit name
#                                         (default: SENTINEL_UNIT with .service ->
#                                         .timer; RESILIENT-1258 — the sentinel is a
#                                         timer-driven oneshot, so watch-sentinel
#                                         health is defined by timer is-active, not
#                                         service is-active, which is correctly
#                                         inactive between runs)
#   CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD     systemctl invocation (default "systemctl --user";
#                                         override for tests / non-systemd environments)
#
# judgment-tick (RESILIENT-1497 / RESILIENT-1702) env overrides:
#   CHUMP_PEER_MODEL              model passed to `claude -p` (default "opus"; allowlist opus|sonnet|haiku)
#   CHUMP_PEER_EXECUTE            1 = actually invoke `claude -p` (default 0 = dry-run
#                                  log-only, so CI/local runs never spend real budget)
#   CHUMP_PEER_BUDGET_USD         per-tick cost cap (default 1.00)
#   CHUMP_PEER_TIMEOUT_S          wall-clock bound per tick (default 300)
#   CHUMP_DUTY_OFFICER_MAX_TOKENS max output tokens per model call (default 4096; prevents unbounded Sonnet/Opus inference on 4GB slim)
#   CHUMP_DUTY_OFFICER_MAX_TURNS  max turns per judgment tick (default 6)
#   CHUMP_PEER_CLAUDE_BIN         override the `claude` binary (tests stub this)
#   CHUMP_PEER_MEMORY_DB          override chump_memory.db path (see lib/peer-memory.sh)
#
# 4GB memory constraint (RESILIENT-1702): runs under MemoryHigh=3072M /
# MemoryMax=3584M on slim with zero canonical store (state.db) write operations.
#
# Rust-First-Bypass: bash glue over existing ambient/registry/notify primitives,
#   mirrors the observability/fresh-eyes loop shape, no state mutation beyond
#   ambient emit — same class as those two already-shipped loops.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AMBIENT="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
REGISTRY="${CHUMP_DUTY_OFFICER_REGISTRY:-$REPO_ROOT/docs/process/PLAYBOOK_REGISTRY.yaml}"
ESCALATION_REGISTRY="${CHUMP_DUTY_OFFICER_ESCALATION_REGISTRY:-$REPO_ROOT/scripts/coord/operator-escalation-registry.txt}"
REALITY_CHECK_CMD="${CHUMP_DUTY_OFFICER_REALITY_CHECK_CMD:-}"
NOTIFY_CMD="${CHUMP_DUTY_OFFICER_NOTIFY_CMD:-}"
WINDOW_N="${CHUMP_DUTY_OFFICER_WINDOW_N:-200}"
EXECUTE="${CHUMP_DUTY_OFFICER_EXECUTE:-0}"
T1_ESCALATE_THRESHOLD="${CHUMP_DUTY_OFFICER_T1_ESCALATE_THRESHOLD:-10}"
SENTINEL_UNIT="${CHUMP_DUTY_OFFICER_SENTINEL_UNIT:-chump-fleet-health-sentinel.service}"
SENTINEL_TIMER="${CHUMP_DUTY_OFFICER_SENTINEL_TIMER:-${SENTINEL_UNIT%.service}.timer}"
SYSTEMCTL_CMD="${CHUMP_DUTY_OFFICER_SYSTEMCTL_CMD:-systemctl --user}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# RESILIENT-1297: the .service unit hardcoded XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS
# for a single UID (RESILIENT-1294), which breaks the moment the unit runs as a
# different user. Fall back to values derived from the running UID whenever the
# systemd unit (or any other launcher) didn't already set them.
_ensure_user_bus_env() {
    if [[ -z "${XDG_RUNTIME_DIR:-}" ]]; then
        export XDG_RUNTIME_DIR="/run/user/$(id -u)"
    fi
    if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
    fi
}
_ensure_user_bus_env

# scanner-anchor: "kind":"duty_officer_action"
_emit_action() {
    local signal="$1" tier="$2" verdict="$3" detail="$4"
    local line
    line="$(printf '{"ts":"%s","kind":"duty_officer_action","signal":"%s","tier":%s,"verdict":"%s","detail":"%s"}\n' \
        "$(_ts)" "$signal" "$tier" "$verdict" "$detail")"
    echo "$line"
    [[ -n "$AMBIENT" ]] && echo "$line" >> "$AMBIENT" 2>/dev/null || true
}

# scanner-anchor: "kind":"duty_officer_heartbeat"
cmd_heartbeat() {
    local n_signals
    n_signals="$(_registry_signal_count)"
    local line
    line="$(printf '{"ts":"%s","kind":"duty_officer_heartbeat","registry_signals":%s}\n' "$(_ts)" "$n_signals")"
    echo "$line"
    [[ -n "$AMBIENT" ]] && echo "$line" >> "$AMBIENT" 2>/dev/null || true
}

_registry_signal_count() {
    [[ -f "$REGISTRY" ]] || { echo 0; return; }
    # RESILIENT-281: grep -c already prints "0" on zero matches; `|| echo 0`
    # appended a duplicate line, corrupting the JSON heartbeat below.
    grep -cE '^\s*-\s*signal:' "$REGISTRY" 2>/dev/null || true
}

# Extract the registry block for a named signal (from its "- signal:" line up
# to the next "- signal:" line or EOF).
_registry_block() {
    local sig="$1"
    [[ -f "$REGISTRY" ]] || return 1
    awk -v sig="$sig" '
        /^\s*-\s*signal:/ {
            if (found) exit
            line=$0; sub(/^\s*-\s*signal:\s*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line)
            if (line == sig) { found=1; print; next }
            found=0; next
        }
        found { print }
    ' "$REGISTRY"
}

_registry_field() { # _registry_field <block> <field-name>
    printf '%s\n' "$1" | grep -E "^\s*${2}:" | head -1 | sed -E "s/^\s*${2}:\s*//" | sed -E 's/^"|"$//g'
}

# Look up the page/suppress verdict from the quiet gate for T3 signals.
_escalation_verdict() {
    local sig="$1"
    [[ -f "$ESCALATION_REGISTRY" ]] || { echo page; return; }
    while read -r k verdict _rest; do
        [[ -z "$k" || "$k" == \#* ]] && continue
        if [[ "$sig" == "$k" ]]; then
            [[ "$verdict" == "suppress" ]] && echo suppress || echo page
            return
        fi
    done < "$ESCALATION_REGISTRY"
    echo page
}

_reality_check() { # returns 0 CONFIRMED, 1 REFUTED, 2 UNVERIFIED
    if [[ -n "$REALITY_CHECK_CMD" ]]; then
        eval "$REALITY_CHECK_CMD"
        return $?
    fi
    if [[ -x "$REPO_ROOT/scripts/dev/reality-check.sh" ]]; then
        "$REPO_ROOT/scripts/dev/reality-check.sh" "duty-officer signal fired" --detector "$1" 2>/dev/null
        return $?
    fi
    return 2
}

# Count raw firings of a signal (ambient kind=<sig>, NOT our own
# duty_officer_action wrapper) within the scan window. A T1 signal that keeps
# firing faster than it can plausibly be resolved is evidence the action
# isn't actually healing anything — RESILIENT-1230.
_signal_repeat_count() {
    local sig="$1"
    [[ -f "$AMBIENT" ]] || { echo 0; return; }
    tail -n "$WINDOW_N" "$AMBIENT" 2>/dev/null | grep -cF "\"kind\":\"${sig}\"" || true
}

_notify() {
    local msg="$1" sig="$2"
    if [[ -n "$NOTIFY_CMD" ]]; then
        eval "$NOTIFY_CMD" "$msg"
        return
    fi
    # shellcheck source=/dev/null
    if [[ -f "$REPO_ROOT/scripts/coord/lib/notify-operator.sh" ]]; then
        # shellcheck disable=SC1091
        source "$REPO_ROOT/scripts/coord/lib/notify-operator.sh"
        CHUMP_NOTIFY_KIND="$sig" notify_operator "$msg" 2>/dev/null || true
    fi
}

# Route a single signal through the registry. This is the load-bearing
# T1 -> T2 -> T3 decision made real (DUTY_OFFICER.md §4).
cmd_route() {
    local sig="${1:?signal required}"
    local block; block="$(_registry_block "$sig")"

    if [[ -z "$block" ]]; then
        _emit_action "$sig" 3 unregistered "no registry entry — novel signal, defaults to page"
        _notify "duty-officer: unregistered signal fired: $sig" "$sig"
        return 0
    fi

    local tier action fp_class
    tier="$(_registry_field "$block" tier)"
    action="$(_registry_field "$block" action)"
    fp_class="$(_registry_field "$block" false_positive_class)"

    case "$tier" in
        1)
            local repeat_n; repeat_n="$(_signal_repeat_count "$sig")"
            if [[ "$repeat_n" -ge "$T1_ESCALATE_THRESHOLD" ]]; then
                # RESILIENT-1230: a T1 signal that keeps re-firing faster than
                # its action can plausibly resolve it is NOT healed — treat as
                # T3 and page. This intentionally bypasses the quiet-gate
                # suppress verdict: a suppression like worker_circuit_open's
                # ("auto-cools-down and retries") is an assumption that firing
                # ${T1_ESCALATE_THRESHOLD}x within one scan window disproves —
                # that's exactly the 13h-dark-out-rationalized-as-healed bug.
                _emit_action "$sig" 3 paged "action=${action} persistent_count=${repeat_n} — fired ${repeat_n}x without resolving, escalated T1->T3 (quiet-gate bypassed: persistence disproves the suppress assumption)"
                _notify "duty-officer T3 (escalated from T1): ${sig} fired ${repeat_n}x unresolved — ${action}" "$sig"
                return 0
            fi
            local action_script="$REPO_ROOT/${action#./}"
            if [[ "$EXECUTE" == "1" && -x "$action_script" ]]; then
                "$action_script" >/dev/null 2>&1 || true
            fi
            _emit_action "$sig" 1 healed "action=${action}"
            ;;
        2)
            if [[ -n "$fp_class" && "$fp_class" != "none" ]]; then
                if ! _reality_check "$sig"; then
                    _emit_action "$sig" 2 refuted "false_positive_class=${fp_class}"
                    return 0
                fi
            fi
            _emit_action "$sig" 2 runbook_needed "runbook=${action}"
            ;;
        3)
            local verdict; verdict="$(_escalation_verdict "$sig")"
            if [[ "$verdict" == suppress ]]; then
                _emit_action "$sig" 3 suppressed "action=${action}"
            else
                _emit_action "$sig" 3 paged "action=${action}"
                _notify "duty-officer T3: ${sig} — ${action}" "$sig"
            fi
            ;;
        *)
            _emit_action "$sig" 0 unregistered "malformed registry tier for signal=${sig}"
            ;;
    esac
}

# Scan the last N ambient lines, route every kind that has a registry entry.
cmd_tick() {
    [[ -f "$AMBIENT" ]] || { echo "[duty-officer] no ambient stream at $AMBIENT — nothing to scan"; return 0; }
    local kinds
    kinds="$(tail -n "$WINDOW_N" "$AMBIENT" 2>/dev/null | grep -oE '"kind":"[a-zA-Z0-9_]+"' | sed -E 's/"kind":"([a-zA-Z0-9_]+)"/\1/' | sort -u)"
    [[ -z "$kinds" ]] && { echo "[duty-officer] tick: no signals in window"; return 0; }
    local any=0
    while read -r k; do
        [[ -z "$k" ]] && continue
        _registry_block "$k" >/dev/null 2>&1
        if [[ -n "$(_registry_block "$k")" ]]; then
            cmd_route "$k"
            any=1
        fi
    done <<< "$kinds"
    [[ "$any" == 0 ]] && echo "[duty-officer] tick: no registered signals fired this window"
    # RESILIENT-1230: the healer-of-healers gets watched every tick, not just
    # when it happens to emit an ambient kind of its own.
    cmd_watch_sentinel
    return 0
}

_sentinel_timer_is_active() {
    $SYSTEMCTL_CMD is-active "$SENTINEL_TIMER" >/dev/null 2>&1
}

# Watch the healer-of-healers: chump-fleet-health-sentinel is a TIMER-driven
# oneshot. Its .service is CORRECTLY inactive between runs — that is not a
# failure signal. Health is defined by the .timer: if the timer is active
# (armed to fire every cycle), the sentinel is healthy regardless of the
# service's between-runs idle state. If it's the timer that's failed, attempt
# a revival (reset-failed + start); if that doesn't bring it back, this is a
# T3 — the thing meant to catch every other outage is itself down, so it must
# page rather than sit silently unwatched (RESILIENT-1230, RESILIENT-1258).
# scanner-anchor: "kind":"duty_officer_action" signal="chump_fleet_health_sentinel"
cmd_watch_sentinel() {
    local sig="chump_fleet_health_sentinel"

    if _sentinel_timer_is_active; then
        _emit_action "$sig" 1 healed "timer=${SENTINEL_TIMER} active (service oneshot idle between runs is expected)"
        return 0
    fi

    $SYSTEMCTL_CMD reset-failed "$SENTINEL_TIMER" >/dev/null 2>&1 || true
    $SYSTEMCTL_CMD start "$SENTINEL_TIMER" >/dev/null 2>&1 || true

    if _sentinel_timer_is_active; then
        _emit_action "$sig" 1 healed "timer=${SENTINEL_TIMER} action=reset-failed+start revived"
        return 0
    fi

    local verdict; verdict="$(_escalation_verdict "$sig")"
    if [[ "$verdict" == suppress ]]; then
        _emit_action "$sig" 3 suppressed "timer=${SENTINEL_TIMER} failed and could not be revived"
    else
        _emit_action "$sig" 3 paged "timer=${SENTINEL_TIMER} failed and could not be revived after reset-failed+start"
        _notify "duty-officer T3: ${SENTINEL_TIMER} (healer-of-healers timer) is failed and could not be revived" "$sig"
    fi
    return 0
}

# RESILIENT-1497: the free Opus peer MIND. Unlike cmd_tick (reactive —
# fires only when a registered ambient signal appears), judgment-tick is
# PROACTIVE and cadenced: it wakes on a timer (chump-peer-mind.timer, ~20
# min) or on an inbound nudge, reads fleet state + ambient + its own running
# memory, forms a chief-of-staff judgment, and acts on non-gated fleet work
# (file gaps, dispatch, reprioritize, update the daily digest). Gated
# actions (repo visibility, spend, credentials, deletes, outward sends) are
# never in its tool allowlist — see lib/peer-guardrails.sh; the Bash
# allowlist passed to `claude -p` IS the enforcement, not just a prompt
# instruction. The peer is never an approver of its own risky actions
# (META-901).
cmd_judgment_tick() {
    local model="${CHUMP_PEER_MODEL:-opus}"
    local execute="${CHUMP_PEER_EXECUTE:-0}"
    local budget="${CHUMP_PEER_BUDGET_USD:-1.00}"
    local timeout_s="${CHUMP_PEER_TIMEOUT_S:-300}"
    local max_tokens="${CHUMP_DUTY_OFFICER_MAX_TOKENS:-4096}"
    local max_turns="${CHUMP_DUTY_OFFICER_MAX_TURNS:-6}"
    local claude_bin="${CHUMP_PEER_CLAUDE_BIN:-claude}"

    # RESILIENT-1702: bound model selection and token/turn budget to prevent
    # unbounded Sonnet/Opus inference on 4GB slim.
    case "$model" in
        opus|sonnet|haiku|claude-*) ;;
        *) model="sonnet" ;;
    esac
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$max_tokens"

    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/coord/lib/peer-memory.sh" 2>/dev/null || true
    peer_memory_init 2>/dev/null || true
    local recent_context
    recent_context="$(peer_memory_recent_episodes 5 2>/dev/null)"

    if [[ "$execute" != "1" ]]; then
        _emit_action "peer_judgment" 0 skipped "CHUMP_PEER_EXECUTE!=1 (dry-run) — not invoking $model"
        return 0
    fi

    if ! command -v "$claude_bin" >/dev/null 2>&1; then
        _emit_action "peer_judgment" 0 skipped "claude_bin=$claude_bin not found on PATH"
        return 0
    fi

    # CREDIBLE-1567: route git history and GitHub cache reads through
    # scripts/dispatch/architect-ro.sh instead of raw git/sqlite3, and explicitly
    # deny escape-capable binaries and write/merge paths.
    local allowed=(
        'Bash(scripts/dispatch/architect-ro.sh *)' 'Bash(git status*)'
        'Bash(gh pr list*)' 'Bash(gh pr view*)'
        'Bash(chump gap list*)' 'Bash(chump gap view*)' 'Bash(chump gap reserve*)'
        'Bash(chump gap set*)' 'Bash(chump dispatch*)'
        'Bash(scripts/coord/broadcast.sh*)' 'Bash(scripts/coord/lib/notify-operator.sh*)'
        'Bash(tail*)' 'Bash(cat*)' 'Bash(printf*)'
    )
    local denied=(
        'Edit' 'Write' 'NotebookEdit'
        'Bash(gh pr merge*)' 'Bash(gh api*)' 'Bash(git push*)'
        'Bash(bash*)' 'Bash(sh*)' 'Bash(zsh*)' 'Bash(env*)' 'Bash(sudo*)'
        'Bash(python*)' 'Bash(perl*)' 'Bash(eval*)' 'Bash(exec*)' 'Bash(xargs*)'
        'Bash(sqlite3*)' 'Bash(git fetch*)' 'Bash(git log*)' 'Bash(git diff*)' 'Bash(git -c*)'
    )

    local prompt
    prompt="You are the free Opus peer (RESILIENT-1497) inside ChumpOS — a \
chief-of-staff MIND, not a gap-worker. This is one cadenced judgment tick, \
not a loop: read, judge, act on NON-GATED work, then stop.

Recent peer memory (your own running context from prior ticks):
${recent_context}

1. Read fleet state you need: 'chump gap list --status open', the tail of \
.chump-locks/ambient.jsonl, open PRs (cache-first per CLAUDE.md).
2. Form a chief-of-staff judgment: is anything stuck, mis-prioritized, or \
missing a gap? Act on it ONLY via: 'chump gap reserve', 'chump gap set', \
'chump dispatch', or 'scripts/coord/broadcast.sh' (A2A proposal) — these are \
the only mutating commands in your allowlist.
3. GUARDRAIL (non-negotiable, enforced by your tool allowlist, not just this \
prompt): you have NO path to repo-visibility changes, spend/billing, \
credential rotation, deletes, or outward sends. If judgment surfaces one of \
those as needed, do NOT attempt it — say so in your final notify_operator \
message so Jeff/first-mate can approve. You are never the approver of your \
own risky action.
4. Before stopping, call 'scripts/coord/lib/notify-operator.sh' with a \
one-line summary of what you judged + did (or chose not to do), via: \
'CHUMP_NOTIFY_KIND=peer_judgment_tick scripts/coord/lib/notify-operator.sh \"<summary>\"'.
5. Do not call ScheduleWakeup. Do not loop. One tick, then stop."

    local out rc=0
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout "${timeout_s}s" "$claude_bin" -p "$prompt" \
            --tools "Read,Grep,Glob,Bash" \
            --allowedTools "${allowed[@]}" \
            --disallowedTools "${denied[@]}" \
            --permission-mode dontAsk \
            --max-turns "$max_turns" \
            --max-budget-usd "$budget" \
            --model "$model" 2>&1)" || rc=$?
    else
        out="$("$claude_bin" -p "$prompt" \
            --tools "Read,Grep,Glob,Bash" \
            --allowedTools "${allowed[@]}" \
            --disallowedTools "${denied[@]}" \
            --permission-mode dontAsk \
            --max-turns "$max_turns" \
            --max-budget-usd "$budget" \
            --model "$model" 2>&1)" || rc=$?
    fi

    if grep -qiE 'rate.?limit|overloaded|429' <<< "$out"; then
        _emit_action "peer_judgment" 0 rate_limited "model=$model — backed off, no retry this tick"
        peer_memory_save_episode "peer judgment tick rate-limited" "model=$model" "peer,rate_limited" "neutral" 2>/dev/null || true
        return 0
    fi

    local verdict="healed"
    [[ "$rc" != 0 ]] && verdict="errored"
    _emit_action "peer_judgment" 1 "$verdict" "model=$model exit_code=$rc"
    peer_memory_save_episode "peer judgment tick (${verdict})" "model=${model} exit_code=${rc}" "peer,judgment" \
        "$([[ "$verdict" == healed ]] && echo neutral || echo frustrating)" 2>/dev/null || true
    return 0
}

cmd_status() {
    local n; n="$(_registry_signal_count)"
    echo "PLAYBOOK_REGISTRY.yaml: $REGISTRY"
    echo "registered signals: $n"
    [[ -f "$REGISTRY" ]] && grep -E '^\s*-\s*signal:|^\s*tier:' "$REGISTRY" | paste - - | sed 's/^\s*//'
}

cmd_help() {
    sed -n '2,25p' "$0" | grep -E '^#' | sed 's/^# \{0,1\}//'
}

main() {
    local sub="${1:-tick}"
    # INFRA-1798: mandatory Glance phase — drain + act on inbox before any work.
    if [[ "$sub" != "help" && "$sub" != "-h" && "$sub" != "--help" ]]; then
        source "$(dirname "$0")/lib/inbox-glance.sh" 2>/dev/null && chump_inbox_glance "duty-officer" || true
    fi
    case "$sub" in
        tick)      cmd_tick ;;
        route)     shift; cmd_route "${1:-}" ;;
        heartbeat) cmd_heartbeat ;;
        watch-sentinel) cmd_watch_sentinel ;;
        judgment-tick) cmd_judgment_tick ;;
        status)    cmd_status ;;
        help|-h|--help) cmd_help; exit 0 ;;
        *) echo "[duty-officer] unknown subcommand: $sub" >&2; cmd_help >&2; exit 2 ;;
    esac
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    main "$@"
fi
