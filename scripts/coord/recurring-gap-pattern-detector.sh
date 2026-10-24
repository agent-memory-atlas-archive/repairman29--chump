#!/usr/bin/env bash
# recurring-gap-pattern-detector.sh — INFRA-249 / RESILIENT-365
#
# Surfaces clusters of recently-filed gaps that share significant title
# keywords, signaling a meta-pattern that probably deserves a META-* RCA gap
# covering the class.
#
# Why: reactive filing (file the symptom you observed) misses recurring
# patterns because each incident looks unique in the moment. Per AGENTS.md
# "Filing meta-patterns" section, the periodic RCA pass catches what flow-
# mode misses. This script automates the cluster-detection half so the human
# RCA pass becomes "review the ALERT list" instead of "scan from memory."
#
# RESILIENT-365: the detector was DARK (0 organ units) — it only emitted a
# human-facing ALERT line and stopped there. Nothing opened the RCA, nothing
# filed the root gap, nothing stopped the next symptom PR from shipping.
# This turns the ALERT into a reflex:
#   1. Detect cluster (unchanged INFRA-249 logic above)
#   2. Idempotently file a META RCA gap for the cluster (dedup by keyword,
#      state tracked in pattern-detector-state.json — mirrors
#      cluster-detector.sh's INFRA-1987 dedup pattern)
#   3. Write a symptom-cluster hold record so `gap-reserve.sh` can block (or
#      require explicit linkage to) further gaps that match the same
#      keyword while the RCA is still open — see
#      scripts/coord/gap-pattern-hold-check.sh
#
# Algorithm (deliberately simple):
#   1. Walk docs/gaps/<ID>.yaml, parse opened_date + title for each gap
#   2. Filter to last N days (default 7)
#   3. Tokenize titles: lowercase, drop stopwords, keep words ≥4 chars
#   4. Count keyword frequency across the window
#   5. Cluster = keyword appearing in ≥THRESHOLD gaps (default 3)
#   6. Print + emit ambient ALERT line per cluster
#   7. File (or update) the cluster's META RCA gap + write the hold record
#
# Usage:
#   recurring-gap-pattern-detector.sh [--days 7] [--threshold 3] [--quiet] [--no-rca]
#   recurring-gap-pattern-detector.sh probe   # CREDIBLE-401/227: probe_slot_health —
#                                              # GET /v1/models per enabled CHUMP_PROVIDER_N_*
#                                              # slot, prints one JSON line per slot with
#                                              # rate-limit headers + model existence.
#
# Env:
#   CHUMP_PATTERN_DETECTOR_QUIET=1     # same as --quiet (suppresses stdout, only emits ALERTs)
#   CHUMP_PATTERN_DETECTOR_ALERT_ONLY=1    # same as --no-rca (skip gap-filing + hold reflex; ALERT only)
#   CHUMP_RCA_REFLEX_ENABLED=1         # RESILIENT-365: master kill-switch for the auto-file +
#                                       # auto-block reflex (gap reserve + depends_on wiring).
#                                       # Default OFF (0) for first ship — the organ/timer runs on
#                                       # a cadence with no human in the loop, so misfire blast
#                                       # radius (wrong root gap, wrongly-blocked symptoms) is
#                                       # higher than the old manual/CLI-invoked path. Detection +
#                                       # ambient ALERT always fire regardless of this flag; only
#                                       # the auto-file/auto-block half is gated. Turning this on
#                                       # is a tracked toggle — see
#                                       # docs/process/CAPABILITY_DECISIONS.md.
#   CHUMP_RCA_REFLEX_LLM_DISABLED=1        # skip the `claude -p` evidence call, use the deterministic
#                                       # fallback evidence blob (tests / offline / no `claude` bin)
#   CHUMP_AMBIENT_LOG=<path>           # override ambient.jsonl path (test fixture uses this)
#   CHUMP_PATTERN_DETECTOR_STATE=<path> # override state file path (test fixture uses this)
#   CHUMP_PATTERN_DETECTOR_HOLD=<path>  # override hold file path (test fixture uses this)

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# ── CREDIBLE-401 (CREDIBLE-227 slice): probe_slot_health ────────────────────
# Iterates the enabled provider-cascade slots (CHUMP_PROVIDER_<N>_* in .env —
# same numbered-slot convention used by scripts/ci/check-providers.sh; no
# slot names are hardcoded here, discovery is purely env-var-driven), issues
# a cheap GET <base>/models per slot, and prints one JSON line per slot with
# the rate-limit headers, model existence, and deprecation status. This is
# the "probe" half of CREDIBLE-227 (rate-limit + model-health telemetry) —
# it does not file gaps or mutate any state, it only observes and logs.
probe_slot_health() {
    local env_file="$REPO_ROOT/.env"
    if [ -f "$env_file" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$env_file"
        set +a
    fi

    local max_slots="${CHUMP_PATTERN_DETECTOR_MAX_SLOTS:-20}"
    local i enabled_var name_var base_var key_var model_var
    local enabled name base key model

    for i in $(seq 1 "$max_slots"); do
        enabled_var="CHUMP_PROVIDER_${i}_ENABLED"
        name_var="CHUMP_PROVIDER_${i}_NAME"
        base_var="CHUMP_PROVIDER_${i}_BASE"
        key_var="CHUMP_PROVIDER_${i}_KEY"
        model_var="CHUMP_PROVIDER_${i}_MODEL"

        enabled="${!enabled_var:-}"
        [ "$enabled" = "1" ] || continue

        name="${!name_var:-slot_$i}"
        base="${!base_var:-}"
        key="${!key_var:-}"
        model="${!model_var:-}"
        [ -n "$base" ] || continue

        local header_file body_file http_code
        header_file="$(mktemp)"
        body_file="$(mktemp)"

        if [ -n "$key" ]; then
            http_code=$(curl -s -o "$body_file" -D "$header_file" -w '%{http_code}' --max-time 10 \
                -H "Authorization: Bearer $key" "${base}/models" 2>/dev/null) || http_code=""
        else
            http_code=$(curl -s -o "$body_file" -D "$header_file" -w '%{http_code}' --max-time 10 \
                "${base}/models" 2>/dev/null) || http_code=""
        fi
        [ -n "$http_code" ] || http_code="000"

        local ratelimit_limit ratelimit_remaining retry_after
        ratelimit_limit=$( (grep -i '^x-ratelimit-limit-requests:' "$header_file" || true) | tail -1 | cut -d':' -f2- | tr -d ' \t\r\n')
        ratelimit_remaining=$( (grep -i '^x-ratelimit-remaining:' "$header_file" || true) | tail -1 | cut -d':' -f2- | tr -d ' \t\r\n')
        retry_after=$( (grep -i '^retry-after:' "$header_file" || true) | tail -1 | cut -d':' -f2- | tr -d ' \t\r\n')

        local model_exists="false"
        local model_deprecated="false"
        if [ "$http_code" = "200" ] && [ -n "$model" ]; then
            if command -v jq >/dev/null 2>&1; then
                if jq -e --arg m "$model" '(.data // []) | any(.id == $m)' "$body_file" >/dev/null 2>&1; then
                    model_exists="true"
                fi
                if jq -e --arg m "$model" '(.data // []) | any(.id == $m and (.deprecated == true))' "$body_file" >/dev/null 2>&1; then
                    model_deprecated="true"
                fi
            else
                if grep -q "\"id\"[[:space:]]*:[[:space:]]*\"$model\"" "$body_file" 2>/dev/null; then
                    model_exists="true"
                fi
            fi
        fi

        local status="failure"
        if [ "$http_code" = "200" ] && [ "$model_exists" = "true" ] && [ "$model_deprecated" = "false" ]; then
            status="success"
        fi

        local limit_json remaining_json retry_json
        case "$ratelimit_limit" in ''|*[!0-9]*) limit_json="null" ;; *) limit_json="$ratelimit_limit" ;; esac
        case "$ratelimit_remaining" in ''|*[!0-9]*) remaining_json="null" ;; *) remaining_json="$ratelimit_remaining" ;; esac
        case "$retry_after" in ''|*[!0-9]*) retry_json="null" ;; *) retry_json="$retry_after" ;; esac

        printf '{"slot":"%s","model":"%s","http_code":"%s","x-ratelimit-limit-requests":%s,"x-ratelimit-remaining":%s,"retry-after":%s,"model_exists":%s,"model_deprecated":%s,"status":"%s"}\n' \
            "$name" "$model" "$http_code" "$limit_json" "$remaining_json" "$retry_json" "$model_exists" "$model_deprecated" "$status"

        rm -f "$header_file" "$body_file"
    done
}

if [ "${1:-}" = "probe" ]; then
    shift
    probe_slot_health
    exit 0
fi

DAYS=7
THRESHOLD=3
QUIET=0
NO_RCA=0
if [ "${CHUMP_PATTERN_DETECTOR_QUIET:-}" = "1" ]; then
    QUIET=1
fi
if [ "${CHUMP_PATTERN_DETECTOR_ALERT_ONLY:-}" = "1" ]; then
    NO_RCA=1
fi

# RESILIENT-365: the auto-file/auto-block reflex is gated behind an explicit
# opt-in, independent of --no-rca (which is the CLI-caller's own choice).
# Default OFF: detection + ambient ALERT still fire either way; only the
# "reserve a gap + block symptoms" side effects require this flag.
RCA_REFLEX_ENABLED=0
if [ "${CHUMP_RCA_REFLEX_ENABLED:-0}" = "1" ]; then
    RCA_REFLEX_ENABLED=1
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --days)      DAYS="$2"; shift 2 ;;
        --threshold) THRESHOLD="$2"; shift 2 ;;
        --quiet)     QUIET=1; shift ;;
        --no-rca)    NO_RCA=1; shift ;;
        --help|-h)
            sed -n '2,40p' "$0"
            exit 0
            ;;
        *) echo "unknown flag: $1" >&2; exit 2 ;;
    esac
done

GAPS_DIR="$REPO_ROOT/docs/gaps"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
STATE_FILE="${CHUMP_PATTERN_DETECTOR_STATE:-$REPO_ROOT/.chump-locks/pattern-detector-state.json}"
HOLD_FILE="${CHUMP_PATTERN_DETECTOR_HOLD:-$REPO_ROOT/.chump-locks/pattern-detector-hold.json}"

if [ ! -d "$GAPS_DIR" ]; then
    echo "[pattern-detector] ERROR: $GAPS_DIR not found" >&2
    exit 1
fi

# Cutoff date: today minus DAYS.
if [ "$(uname -s)" = "Darwin" ]; then
    CUTOFF=$(date -u -v-"${DAYS}"d +%Y-%m-%d)
else
    CUTOFF=$(date -u -d "$DAYS days ago" +%Y-%m-%d)
fi
TODAY=$(date -u +%Y-%m-%d)

# Stopwords (common English + Chump jargon that shouldn't anchor a cluster).
# Keep this list small — false positives from over-aggressive stopwording are
# worse than a few noise clusters. Items here are words that appear in many
# gap titles regardless of topic.
STOPWORDS="the and for with from into onto upon over under than that this those these when where what which who whom how why because while during after before above below between among through within without your their there here gaps gap have been into onto over still need needs needed should would could might must will may shall pass fails fail does did done from chump claude cursor goose aider tool tools test tests gone open close closed status field fields make made like more most less item items thing things path paths name names line lines infra only also even just both"

is_stopword() {
    case " $STOPWORDS " in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

# Walk recent gaps, build keyword → count + IDs map in a temp file.
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT
COUNTS_FILE="$TMPDIR_BASE/counts"
touch "$COUNTS_FILE"

recent_gap_count=0

for yaml_path in "$GAPS_DIR"/*.yaml; do
    [ -f "$yaml_path" ] || continue
    gap_id="$(basename "$yaml_path" .yaml)"

    opened="$(awk '/^[[:space:]]*opened_date:/ {gsub(/[[:space:]]*opened_date:[[:space:]]*/,""); gsub(/[[:space:]'\''"]+/,""); print; exit}' "$yaml_path" 2>/dev/null || true)"

    # Only consider gaps with an opened_date in the window. Gaps with no
    # opened_date (legacy / pre-INFRA-188) are skipped — they're old.
    [ -n "$opened" ] || continue

    if ! [ "$opened" \> "$CUTOFF" ] && [ "$opened" != "$CUTOFF" ]; then
        continue
    fi

    recent_gap_count=$((recent_gap_count + 1))

    title="$(awk '/^[[:space:]]*title:/ {sub(/^[[:space:]]*title:[[:space:]]*/,""); gsub(/^["'\'']/,""); gsub(/["'\'']$/,""); print; exit}' "$yaml_path" 2>/dev/null || true)"
    [ -n "$title" ] || continue

    # Tokenize: lowercase, replace non-alpha with spaces, split.
    tokens=$(echo "$title" | tr 'A-Z' 'a-z' | tr -c 'a-z' ' ')
    for tok in $tokens; do
        # Filter: ≥4 chars, not a stopword.
        [ ${#tok} -ge 4 ] || continue
        if is_stopword "$tok"; then continue; fi
        echo "$tok|$gap_id" >> "$COUNTS_FILE"
    done
done

if [ "$QUIET" -eq 0 ]; then
    echo "[pattern-detector] scanned $recent_gap_count gaps opened in last $DAYS days"
fi

# ── RESILIENT-365 reflex: idempotently file the RCA gap + write the hold ────
# record for a detected cluster. Dedup is keyed by keyword in STATE_FILE so
# a keyword that's still clustering doesn't refile a new RCA gap every run —
# the existing RCA gap's id + gap_ids list are just refreshed.
# RESILIENT-365 AC3: root-cause hypothesis is an LLM pass producing a
# COMMAND/OUTPUT/THEORY/ALT evidence blob (same shape the decompose/architect
# engine and every hand-filed P0/P1 gap in this repo use — see AGENTS.md
# evidence convention) so the reserved root gap passes the CREDIBLE-106/107
# evidence+outcome gate. Reuses the fleet's standard `claude -p` invocation
# (the same mechanism worker.sh/handoff dispatch use, per SUBAGENT_DISPATCH.md)
# rather than re-implementing a bespoke LLM client in shell. Falls back to a
# deterministic evidence blob when `claude` isn't on PATH (offline node, CI,
# or CHUMP_RCA_REFLEX_LLM_DISABLED=1 for tests) so the reflex never hard-fails for
# lack of an LLM.
_generate_rca_evidence() {
    keyword="$1"
    cnt="$2"
    id_list="$3"

    if [ "${CHUMP_RCA_REFLEX_LLM_DISABLED:-0}" != "1" ]; then
        prompt="Recurring-gap-pattern detector found $cnt gaps opened in the last ${DAYS}d that share the title keyword \"$keyword\": $id_list. Produce a root-cause hypothesis for a fleet gap-tracking system in EXACTLY this 4-line format, one line each, no extra commentary: COMMAND: <the diagnostic command/grep an operator would run to confirm> / OUTPUT: <what that command would show, generically> / THEORY: <the suspected structural root cause explaining why this keyword keeps recurring> / ALT: <the rejected alternative (usually 'keep filing symptom gaps individually') and why it's rejected>."
        resp=""
        if [ "${CHUMP_BYOK_PRIMARY:-0}" = "1" ] && command -v chump >/dev/null 2>&1; then
            resp="$(printf '%s\n' "$prompt" | timeout 60 chump llm-complete --model sonnet --max-tokens 500 2>/dev/null || true)"
        fi
        if [ -z "$resp" ] && command -v claude >/dev/null 2>&1; then
            resp="$(timeout 60 claude -p "$prompt" --model claude-sonnet-4-6 2>/dev/null || true)"
        fi
        if [ -z "$resp" ] && command -v chump >/dev/null 2>&1; then
            resp="$(printf '%s\n' "$prompt" | timeout 60 chump llm-complete --model sonnet --max-tokens 500 2>/dev/null || true)"
        fi
        resp="$(printf '%s' "$resp" | grep -E '^(COMMAND|OUTPUT|THEORY|ALT):' || true)"
        if [ -n "$resp" ]; then
            printf '%s\n' "$resp"
            return 0
        fi
    fi

    # Deterministic fallback — still a valid COMMAND/OUTPUT/THEORY/ALT blob.
    printf 'COMMAND: recurring-gap-pattern-detector.sh --days %s --threshold %s (keyword=%s)\n' "$DAYS" "$THRESHOLD" "$keyword"
    printf 'OUTPUT: %s gaps opened in the last %sd share title keyword "%s": %s\n' "$cnt" "$DAYS" "$keyword" "$id_list"
    printf 'THEORY: repeat symptom-filing under keyword "%s" with no shared root-cause fix — a structural bug or missing process step is producing the same class of incident each time.\n' "$keyword"
    printf 'ALT: keep filing individual symptom gaps under "%s" — rejected, that is the exact reactive-filing SPOF this reflex exists to close (INFRA-249).\n' "$keyword"
}

_file_or_update_rca_gap() {
    keyword="$1"
    cnt="$2"
    id_list="$3"

    existing_gap=""
    if [ -f "$STATE_FILE" ]; then
        existing_gap="$(python3 -c '
import json, sys
try:
    s = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
k = s.get("keywords", {}).get(sys.argv[2])
if k:
    print(k.get("gap_id", ""))
' "$STATE_FILE" "$keyword" 2>/dev/null || true)"
    fi

    gap_id="$existing_gap"
    if [ -z "$gap_id" ]; then
        title="RCA: recurring gap pattern \"$keyword\" — $cnt gaps in ${DAYS}d [$id_list]"
        evidence="$(_generate_rca_evidence "$keyword" "$cnt" "$id_list")"
        gap_id="$(CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            chump gap reserve --domain META \
                --title "$title" --priority P1 --effort s \
                --description "$evidence" --evidence "$evidence" \
                --force-duplicate 2>/dev/null | tail -1)"
        gap_id="${gap_id:-UNFILED}"
        if [ "$QUIET" -eq 0 ]; then
            echo "[pattern-detector] RCA: filed $gap_id for keyword \"$keyword\" ($cnt gaps: $id_list)" >&2
        fi
    else
        if [ "$QUIET" -eq 0 ]; then
            echo "[pattern-detector] RCA: keyword \"$keyword\" already has $gap_id — refreshing" >&2
        fi
    fi

    # RESILIENT-365 AC4: block the symptom cluster — each symptom gap gets
    # depends_on the root gap so the fleet's pickable-gap gate stops handing
    # out the Nth symptom while the root is still open. Best-effort per-id;
    # one bad id (already closed, already deleted) must not abort the sweep.
    # Idempotent: `chump gap set --depends-on` overwrites the field with the
    # same value on every re-run, which is a no-op update, not a duplicate.
    old_ifs="$IFS"
    IFS=','
    for symptom_id in $id_list; do
        IFS="$old_ifs"
        [ -n "$symptom_id" ] || continue
        chump gap set "$symptom_id" --depends-on "$gap_id" >/dev/null 2>&1 || true
        IFS=','
    done
    IFS="$old_ifs"

    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    python3 -c '
import json, sys
path, keyword, gap_id, ts, cnt, id_list = sys.argv[1:7]
try:
    s = json.load(open(path))
except Exception:
    s = {"keywords": {}}
s.setdefault("keywords", {})
prev = s["keywords"].get(keyword, {})
s["keywords"][keyword] = {
    "gap_id": gap_id,
    "first_seen": prev.get("first_seen", ts),
    "last_seen": ts,
    "gap_count": int(cnt),
    "gap_ids": id_list,
}
json.dump(s, open(path, "w"), indent=2)
' "$STATE_FILE" "$keyword" "$gap_id" "$ts" "$cnt" "$id_list" 2>/dev/null || true

    # Block symptom cluster: write/refresh the hold record so gap-reserve.sh
    # (via gap-pattern-hold-check.sh) can require new gaps that still match
    # this keyword to reference the RCA gap instead of shipping the next
    # symptom PR blind.
    mkdir -p "$(dirname "$HOLD_FILE")" 2>/dev/null || true
    python3 -c '
import json, sys
path, keyword, gap_id, ts, cnt, id_list = sys.argv[1:7]
try:
    h = json.load(open(path))
except Exception:
    h = {"holds": {}}
h.setdefault("holds", {})
h["holds"][keyword] = {
    "rca_gap": gap_id,
    "since": ts,
    "gap_count": int(cnt),
    "gap_ids": id_list,
    "advisory": "New gaps titled with \"" + keyword + "\" should reference " + gap_id + " (depends_on) instead of filing another symptom.",
}
json.dump(h, open(path, "w"), indent=2)
' "$HOLD_FILE" "$keyword" "$gap_id" "$ts" "$cnt" "$id_list" 2>/dev/null || true

    ralert_line=$(printf '{"ts":"%s","session":"%s","worktree":"%s","kind":"recurring_gap_pattern_rca_filed","keyword":"%s","gap_count":%d,"window_days":%d,"gap_ids":"%s","rca_gap":"%s"}' \
        "$ts" "${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-pattern-detector}}" "$(basename "$REPO_ROOT")" "$keyword" "$cnt" "$DAYS" "$id_list" "$gap_id")
    echo "$ralert_line" >> "$AMBIENT_LOG" 2>/dev/null || true
}

# Group by keyword, count distinct gap IDs per keyword.
clusters_found=0
sort -u "$COUNTS_FILE" | awk -F'|' '
    { count[$1]++; ids[$1] = ids[$1] "," $2 }
    END {
        for (k in count) {
            if (count[k] >= '"$THRESHOLD"') {
                gsub(/^,/, "", ids[k])
                print count[k] "\t" k "\t" ids[k]
            }
        }
    }
' | sort -rn | while IFS=$'\t' read -r cnt keyword id_list; do
    clusters_found=$((clusters_found + 1))
    if [ "$QUIET" -eq 0 ]; then
        echo "[pattern-detector] CLUSTER: \"$keyword\" appears in $cnt gaps in last $DAYS days: $id_list"
    fi
    # Emit ambient ALERT line — JSON shape matches the adversary alert /
    # closer-batcher convention. Best-effort; failure here doesn't fail
    # the script.
    mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    session=${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-pattern-detector}}
    line=$(printf '{"ts":"%s","session":"%s","worktree":"%s","event":"ALERT","kind":"recurring_gap_pattern","keyword":"%s","gap_count":%d,"window_days":%d,"gap_ids":"%s","note":"%d gaps in last %d days share keyword \"%s\" — consider META-* RCA gap covering the class"}' \
        "$ts" "$session" "$(basename "$REPO_ROOT")" "$keyword" "$cnt" "$DAYS" "$id_list" "$cnt" "$DAYS" "$keyword")
    echo "$line" >> "$AMBIENT_LOG" 2>/dev/null || true

    # RESILIENT-365: turn the ALERT into a reflex — file the RCA gap and
    # write the symptom-cluster hold record. Best-effort: failures here
    # (chump binary unavailable, python3 missing) must not fail the sweep.
    # Gated behind CHUMP_RCA_REFLEX_ENABLED (default OFF) independently of
    # --no-rca — detection/ALERT always run; auto-file/auto-block requires
    # both "caller didn't pass --no-rca" AND "operator opted the reflex in".
    if [ "$NO_RCA" -eq 0 ] && [ "$RCA_REFLEX_ENABLED" -eq 1 ]; then
        _file_or_update_rca_gap "$keyword" "$cnt" "$id_list" || true
    fi
done

if [ "$QUIET" -eq 0 ] && [ "$clusters_found" -eq 0 ]; then
    echo "[pattern-detector] no clusters found (threshold=$THRESHOLD)"
fi

exit 0
