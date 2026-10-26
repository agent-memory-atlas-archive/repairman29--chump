#!/usr/bin/env bash
# ambient-emit.sh — append one event to .chump-locks/ambient.jsonl
#
# Usage:
#   scripts/dev/ambient-emit.sh <event_kind> [key=value ...]
#
# Examples:
#   scripts/dev/ambient-emit.sh session_start gap=FLEET-004a
#   scripts/dev/ambient-emit.sh file_edit path=src/foo.rs
#   scripts/dev/ambient-emit.sh commit sha=abc1234 msg="feat: add thing" gap=FLEET-004a
#   scripts/dev/ambient-emit.sh ALERT kind=lease_overlap sessions=a,b path=src/main.rs
#
# The file is written with a file-lock (flock) so concurrent writers never
# produce interleaved JSON. Falls back to no-lock on systems without flock.
#
# Environment:
#   CHUMP_SESSION_ID    / CLAUDE_SESSION_ID  — used for the session field
#   CHUMP_AMBIENT_LOG   — override the output path (default: .chump-locks/ambient.jsonl)
#   CHUMP_AGENT_HARNESS — harness identity (opencode / opencode-bigpickle /
#                         fleet-dispatcher / claude-code-ide / manual / unknown)
#   --harness <name>    — one-shot override for the harness field

set -euo pipefail

# INFRA-1600: source flock-discovery helper at top of script — sets $FLOCK_BIN
# to absolute path of flock binary (handles brew util-linux keg-only case on
# self-hosted runners). Helper exits with diagnostic if flock not found.
# shellcheck source=../lib/discover-flock.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/discover-flock.sh"

# ── CREDIBLE-037: harness attribution ─────────────────────────────────────────
_HARNESS="${CHUMP_AGENT_HARNESS:-unknown}"
_HARNESS_ALERTED=false
_HARNESS_ALERT_FILE=""


for arg in "$@"; do
    if [[ "$arg" == "--harness" ]]; then
        _HARNESS_SPECIFIED=true
    fi
done
if [[ "${_HARNESS_SPECIFIED:-false}" != "true" ]]; then
    # Check if --harness was passed as a flag
    set +u
    for ((i=1; i<=$#; i++)); do
        if [[ "${!i}" == "--harness" ]]; then
            next=$((i+1))
            if [[ $next -le $# ]]; then
                _HARNESS="${!next}"
            fi
        fi
    done
    set -u
fi

# One-shot missing_attribution alert per session when harness is unknown.
if [[ "$_HARNESS" == "unknown" ]]; then
    _alert_session="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
    _HARNESS_ALERT_FILE="/tmp/chump-harness-alerted-${_alert_session}"
    if [[ ! -f "$_HARNESS_ALERT_FILE" ]]; then
        touch "$_HARNESS_ALERT_FILE"
        _HARNESS_ALERTED=true
    fi
fi

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 <event_kind> [key=value ...] [--harness <name>]" >&2
    exit 1
fi

# Consume --harness flag from args so it doesn't leak into EXTRA_JSON.
_filtered_args=()
_skip_next=false
for arg in "$@"; do
    if $_skip_next; then _skip_next=false; continue; fi
    if [[ "$arg" == "--harness" ]]; then _skip_next=true; continue; fi
    _filtered_args+=("$arg")
done
set -- "${_filtered_args[@]}"

EVENT_KIND="$1"
shift

# ── Paths ─────────────────────────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# Linked worktrees have a separate --show-toplevel but share --git-common-dir.
# Resolve the main repo root so all agents write to the same ambient.jsonl.
_GIT_COMMON="$(git rev-parse --git-common-dir 2>/dev/null || echo ".git")"
if [[ "$_GIT_COMMON" == ".git" ]]; then
    MAIN_REPO="$REPO_ROOT"
else
    MAIN_REPO="$(cd "$_GIT_COMMON/.." && pwd)"
fi
LOCK_DIR="$MAIN_REPO/.chump-locks"
# Worktree-local lock dir: session ID files are scoped per worktree, not shared.
LOCAL_LOCK_DIR="$REPO_ROOT/.chump-locks"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCK_DIR/ambient.jsonl}"

mkdir -p "$LOCK_DIR"

# ── Session ID (same precedence as gap-claim.sh) ──────────────────────────────
SESSION_ID="${CHUMP_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"
if [[ -z "$SESSION_ID" ]]; then
    WT_SESSION_CACHE="$LOCAL_LOCK_DIR/.wt-session-id"
    if [[ -f "$WT_SESSION_CACHE" ]]; then
        SESSION_ID="$(cat "$WT_SESSION_CACHE")"
    else
        # INFRA-3002: mint a stable per-worktree session id and PERSIST it
        # immediately, rather than minting a fresh timestamp-based id on
        # every call. Without this, an interactive session with no
        # CHUMP_SESSION_ID/CLAUDE_SESSION_ID set gets a distinct session id
        # per ambient-emit.sh invocation, so chump-ambient-glance.sh's
        # self-exclusion (matching on session id) never matches and the
        # invoking session's own prior events are misread as sibling
        # collisions under --check-overlap.
        SESSION_ID="chump-$(basename "$REPO_ROOT")-$(date +%s)-$$"
        mkdir -p "$LOCAL_LOCK_DIR"
        printf '%s' "$SESSION_ID" > "$WT_SESSION_CACHE" 2>/dev/null || true
    fi
fi

# ── Worktree label ────────────────────────────────────────────────────────────
WORKTREE="$(basename "$REPO_ROOT")"

# ── Timestamp ─────────────────────────────────────────────────────────────────
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ── Build extra fields from key=value args ────────────────────────────────────
EXTRA_JSON=""
for arg in "$@"; do
    KEY="${arg%%=*}"
    VAL="${arg#*=}"
    # Escape value for JSON: backslash, double-quote, control chars
    VAL_ESC="$(printf '%s' "$VAL" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])'  2>/dev/null || printf '%s' "$VAL" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    EXTRA_JSON="${EXTRA_JSON},\"${KEY}\":\"${VAL_ESC}\""
done

# ── Build the JSON line (CREDIBLE-037: include harness field) ─────────────────
# INFRA-1159: dual-write both "kind" (canonical per EVENT_REGISTRY.yaml) and
# "event" (legacy alias, kept for backward-compat with existing consumers that
# grep for .event). Consumers should migrate to "kind"; "event" will be
# removed in a future cleanup once all consumers are updated.
JSON_LINE="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"harness\":\"${_HARNESS}\",\"kind\":\"${EVENT_KIND}\",\"event\":\"${EVENT_KIND}\"${EXTRA_JSON}}"

# ── INFRA-1889: kind-schema gate ───────────────────────────────────────────────
# Reject a free-text "kind" (e.g. a full English sentence dropped in by
# mistake — see 2026-05-23 curator-opus-handoff incident) before it ever
# lands in ambient.jsonl. A kind passes if it is either a registered
# EVENT_REGISTRY.yaml / event-registry-reserved.txt slug, OR merely
# slug-shaped (unregistered-but-plausible kinds still flow through so a new
# emitter isn't blocked before its registry entry lands).
_ambient_append() {
    # $1 = target file, $2 = line
    if command -v "$FLOCK_BIN" &>/dev/null; then
        ( "$FLOCK_BIN" -x 200; printf '%s\n' "$2" >> "$1" ) 200>"${1}.lock"
    else
        printf '%s\n' "$2" >> "$1"
    fi
}

REGISTRY_PATH=""
if [[ -f "$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml" ]]; then
    REGISTRY_PATH="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
elif [[ -f "$MAIN_REPO/docs/observability/EVENT_REGISTRY.yaml" ]]; then
    REGISTRY_PATH="$MAIN_REPO/docs/observability/EVENT_REGISTRY.yaml"
fi
RESERVED_PATH=""
if [[ -f "$REPO_ROOT/scripts/ci/event-registry-reserved.txt" ]]; then
    RESERVED_PATH="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
elif [[ -f "$MAIN_REPO/scripts/ci/event-registry-reserved.txt" ]]; then
    RESERVED_PATH="$MAIN_REPO/scripts/ci/event-registry-reserved.txt"
fi

_kind_registered() {
    local k="$1"
    if [[ -n "$REGISTRY_PATH" ]] && grep -qxF "  - kind: ${k}" "$REGISTRY_PATH" 2>/dev/null; then
        return 0
    fi
    if [[ -n "$RESERVED_PATH" ]]; then
        local _reserved_toks
        _reserved_toks="$(awk '!/^#/ && NF > 0 {print $1}' "$RESERVED_PATH" 2>/dev/null || true)"
        if grep -qxF "$k" <<<"$_reserved_toks"; then
            return 0
        fi
    fi
    return 1
}

_KIND_VALID=true
if [[ ! "$EVENT_KIND" =~ ^[a-z][a-z0-9_]+$ ]] && ! _kind_registered "$EVENT_KIND"; then
    _KIND_VALID=false
fi

if [[ "$_KIND_VALID" == "false" ]]; then
    if [[ "${CHUMP_AMBIENT_KIND_LAX:-0}" == "1" ]]; then
        # Migration-safety bypass: restore accept-anything, but flag once per
        # session so the operator can size the migration.
        _LAX_ALERT_FILE="/tmp/chump-ambient-lax-alerted-${SESSION_ID}"
        if [[ ! -f "$_LAX_ALERT_FILE" ]]; then
            touch "$_LAX_ALERT_FILE" 2>/dev/null || true
            # scanner-anchor: "kind":"ambient_schema_lax"
            _lax_json="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"harness\":\"${_HARNESS}\",\"kind\":\"ambient_schema_lax\",\"event\":\"ambient_schema_lax\",\"hint\":\"CHUMP_AMBIENT_KIND_LAX=1 accepted a non-registry, non-slug-shaped kind\"}"
            mkdir -p "$LOCK_DIR"
            _ambient_append "$AMBIENT_LOG" "$_lax_json"
        fi
        # fall through: original JSON_LINE (with the free-text kind) still
        # gets written by the normal append path below.
    else
        mkdir -p "$LOCK_DIR"
        REJECTED_LOG="${CHUMP_AMBIENT_REJECTED_LOG:-$LOCK_DIR/ambient-rejected.jsonl}"
        _ambient_append "$REJECTED_LOG" "$JSON_LINE"
        BAD_KIND_ESC="$(printf '%s' "$EVENT_KIND" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read())[1:-1])' 2>/dev/null \
            || printf '%s' "$EVENT_KIND" | sed 's/\\/\\\\/g; s/"/\\"/g')"
        # scanner-anchor: "kind":"ambient_kind_rejected"
        _REJECTED_JSON="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"harness\":\"${_HARNESS}\",\"kind\":\"ambient_kind_rejected\",\"event\":\"ambient_kind_rejected\",\"bad_kind\":\"${BAD_KIND_ESC}\"}"
        _ambient_append "$AMBIENT_LOG" "$_REJECTED_JSON"
        # Quarantined: the malformed event never reaches ambient.jsonl, and
        # the replacement forensic event has already been written above —
        # skip the harness-alert / schema-validate / atomic-append / NATS
        # steps below, which all assume a well-formed kind.
        exit 0
    fi
fi

# ── CREDIBLE-037: emit one-shot missing_attribution alert ─────────────────────
if [[ "${_HARNESS_ALERTED:-false}" == "true" ]]; then
    _alert_json="{\"ts\":\"${TS}\",\"session\":\"${SESSION_ID}\",\"worktree\":\"${WORKTREE}\",\"kind\":\"missing_attribution\",\"event\":\"ALERT\",\"harness\":\"$_HARNESS\",\"hint\":\"CHUMP_AGENT_HARNESS not set; defaulting to 'unknown'. Set via env var or --harness flag.\"}"
    if command -v "$FLOCK_BIN" &>/dev/null; then
        ( "$FLOCK_BIN" -x 200; printf '%s\n' "$_alert_json" >> "$AMBIENT_LOG" ) 200>"${AMBIENT_LOG}.lock"
    else
        printf '%s\n' "$_alert_json" >> "$AMBIENT_LOG"
    fi
fi

# ── INFRA-101: validate against docs/ambient-schema.json before append ───────
# Catches the schema drift the 2026-04-26 audit flagged (INTENT rows with
# reordered keys + nonstandard shape) at write time, not at parse time.
# Disable with CHUMP_AMBIENT_SCHEMA_CHECK=0 (e.g. when emitting a brand-new
# event kind whose schema entry hasn't landed yet).
if [[ "${CHUMP_AMBIENT_SCHEMA_CHECK:-1}" != "0" ]] && command -v python3 >/dev/null 2>&1; then
    # Worktree first (lets a fresh schema land before merge), main second.
    if [[ -f "$REPO_ROOT/docs/ambient-schema.json" ]]; then
        SCHEMA_PATH="$REPO_ROOT/docs/ambient-schema.json"
    elif [[ -f "$MAIN_REPO/docs/ambient-schema.json" ]]; then
        SCHEMA_PATH="$MAIN_REPO/docs/ambient-schema.json"
    else
        SCHEMA_PATH=""
    fi
    if [[ -n "$SCHEMA_PATH" ]]; then
        validation_err="$(JSON_LINE="$JSON_LINE" SCHEMA_PATH="$SCHEMA_PATH" python3 - <<'PYEOF' 2>&1
import json, os, sys, re

line = os.environ["JSON_LINE"]
schema = json.load(open(os.environ["SCHEMA_PATH"]))

# Parse the assembled line.
try:
    obj = json.loads(line)
except json.JSONDecodeError as e:
    print(f"ambient JSON malformed: {e}")
    sys.exit(1)

# Required base fields.
for f in schema.get("required", []):
    if f not in obj:
        print(f"missing required base field: {f}")
        sys.exit(1)

# Base-field type/format checks.
props = schema.get("properties", {})
for name, spec in props.items():
    if name not in obj:
        continue
    val = obj[name]
    if spec.get("type") == "string" and not isinstance(val, str):
        print(f"field {name} must be string, got {type(val).__name__}")
        sys.exit(1)
    pat = spec.get("pattern")
    if pat and not re.match(pat, str(val)):
        print(f"field {name}={val!r} does not match pattern {pat}")
        sys.exit(1)
    enum = spec.get("enum")
    if enum and val not in enum:
        print(f"field {name}={val!r} not in enum {enum}")
        sys.exit(1)

# Per-event-kind branch: pick the matching oneOf entry by event value
# and check its required fields.
event = obj.get("event")
for branch in schema.get("oneOf", []):
    bp = branch.get("properties", {}).get("event", {})
    matches = (bp.get("const") == event) or (event in (bp.get("enum") or []))
    if not matches:
        continue
    for f in branch.get("required", []):
        if f not in obj:
            print(f"event={event} requires field {f!r}")
            sys.exit(1)
    # Per-field type / pattern checks within the branch.
    for name, spec in branch.get("properties", {}).items():
        if name == "event" or name not in obj:
            continue
        val = obj[name]
        if spec.get("type") == "string" and not isinstance(val, str):
            print(f"event={event} field {name} must be string")
            sys.exit(1)
        pat = spec.get("pattern")
        if pat and not re.match(pat, str(val)):
            print(f"event={event} field {name}={val!r} does not match pattern {pat}")
            sys.exit(1)
    break
else:
    # No branch matched the event kind. event enum check above should
    # have caught this; fall through silently if user disabled enum.
    pass

sys.exit(0)
PYEOF
        )"
        if [[ -n "$validation_err" ]]; then
            echo "[ambient-emit] schema validation failed (INFRA-101):" >&2
            printf '  %s\n' "$validation_err" >&2
            echo "[ambient-emit] line: $JSON_LINE" >&2
            echo "[ambient-emit] schema: $SCHEMA_PATH" >&2
            echo "[ambient-emit] bypass: CHUMP_AMBIENT_SCHEMA_CHECK=0 $0 ..." >&2
            exit 1
        fi
    fi
fi

# ── Atomic append ("$FLOCK_BIN" if available, plain >> otherwise) ───────────────────
if command -v "$FLOCK_BIN" &>/dev/null; then
    (
        "$FLOCK_BIN" -x 200
        printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
    ) 200>"${AMBIENT_LOG}.lock"
else
    # macOS: no flock, use noclobber trick — races are rare enough at human timescales
    printf '%s\n' "$JSON_LINE" >> "$AMBIENT_LOG"
fi

# ── FLEET-006: best-effort NATS dual-emit ─────────────────────────────────────
# When chump-coord is on PATH, fan the same event out to JetStream so
# remote machines (and Cold Water) can see it. No-op when chump-coord or
# NATS are unavailable — file append above is the durable record.
if [[ "${CHUMP_AMBIENT_NATS:-1}" != "0" ]] && command -v chump-coord &>/dev/null; then
    # Translate event kind to upper-case for chump.events.<lower> subject
    # consistency with broadcast.sh; pass-through key=value args.
    CHUMP_SESSION_ID="$SESSION_ID" \
        chump-coord emit "$EVENT_KIND" "$@" >/dev/null 2>&1 || true
fi
