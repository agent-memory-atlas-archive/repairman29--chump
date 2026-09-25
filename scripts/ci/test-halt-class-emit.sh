#!/usr/bin/env bash
# test-halt-class-emit.sh — CREDIBLE-513 (CREDIBLE-108 slice): unit coverage
# for halt_class_emit / halt_class_categorize in scripts/lib/halt-class-emit.sh.
#
# Verifies the three execution states (success/failure/timeout) are emitted
# as structured halt_class_emit events, and that failure/timeout reasons are
# categorized into the transient/permanent taxonomy.

set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
LIB="$REPO_ROOT/scripts/lib/halt-class-emit.sh"

if [[ ! -f "$LIB" ]]; then
    echo "FAIL: $LIB not found" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$LIB"

_pass=0
_fail=0
_ok()   { echo "  ✓ $*"; (( _pass++ )) || true; }
_bad()  { echo "  ✗ FAIL: $*" >&2; (( _fail++ )) || true; }

# Run inside an isolated throwaway git repo so _halt_class_lock_dir resolves
# to a scratch .chump-locks/ambient.jsonl instead of the real fleet stream.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
( cd "$WORKDIR" && git init -q . )
cd "$WORKDIR"
AMBIENT="$WORKDIR/.chump-locks/ambient.jsonl"

_last_event_field() {
    local kind="$1" field="$2"
    python3 -c "
import json, sys
kind, field = sys.argv[1], sys.argv[2]
last = None
with open(sys.argv[3]) as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        if rec.get('kind') == kind:
            last = rec
if last is None:
    sys.exit(1)
print(last.get(field, ''))
" "$kind" "$field" "$AMBIENT"
}

_event_count() {
    grep -cE '"kind":[[:space:]]*"halt_class_emit"' "$AMBIENT" 2>/dev/null || true
}

# ── Execution-state coverage: success / failure / timeout ──────────────────

halt_class_emit "unit-test-detector" success "" '{"probe":"direct"}'
status="$(_last_event_field halt_class_emit status || true)"
failure_class="$(_last_event_field halt_class_emit failure_class || true)"
if [[ "$status" == "success" ]]; then
    _ok "halt_class_emit success -> status=success recorded"
else
    _bad "halt_class_emit success -> unexpected status '$status'"
fi
if [[ "$failure_class" == "none" ]]; then
    _ok "halt_class_emit success -> failure_class=none"
else
    _bad "halt_class_emit success -> unexpected failure_class '$failure_class'"
fi

halt_class_emit "unit-test-detector" failure "connection refused" '{"probe":"direct"}'
status="$(_last_event_field halt_class_emit status || true)"
failure_class="$(_last_event_field halt_class_emit failure_class || true)"
if [[ "$status" == "failure" ]]; then
    _ok "halt_class_emit failure -> status=failure recorded"
else
    _bad "halt_class_emit failure -> unexpected status '$status'"
fi
if [[ "$failure_class" == "transient" ]]; then
    _ok "halt_class_emit failure(connection refused) -> failure_class=transient"
else
    _bad "halt_class_emit failure(connection refused) -> unexpected failure_class '$failure_class'"
fi

halt_class_emit "unit-test-detector" timeout "step=init exceeded 900s" '{"probe":"direct"}'
status="$(_last_event_field halt_class_emit status || true)"
if [[ "$status" == "timeout" ]]; then
    _ok "halt_class_emit timeout -> status=timeout recorded"
else
    _bad "halt_class_emit timeout -> unexpected status '$status'"
fi

if [[ "$(_event_count)" -eq 3 ]]; then
    _ok "3 halt_class_emit events recorded (success, failure, timeout)"
else
    _bad "expected 3 halt_class_emit events, got $(_event_count)"
fi

# Invalid status must be rejected, not silently swallowed.
if halt_class_emit "unit-test-detector" bogus "whatever" 2>/dev/null; then
    _bad "halt_class_emit accepted an invalid status"
else
    _ok "halt_class_emit rejects an invalid status"
fi

# ── Failure taxonomy: transient vs permanent categorization ────────────────

for reason in "rate limit exceeded" "connection reset" "503 service unavailable" "lock contention" "network blip"; do
    got="$(halt_class_categorize "$reason")"
    if [[ "$got" == "transient" ]]; then
        _ok "halt_class_categorize('$reason') -> transient"
    else
        _bad "halt_class_categorize('$reason') -> expected transient, got '$got'"
    fi
done

for reason in "authentication failed" "401 unauthorized" "permission denied" "missing required credential" "fatal: bad config"; do
    got="$(halt_class_categorize "$reason")"
    if [[ "$got" == "permanent" ]]; then
        _ok "halt_class_categorize('$reason') -> permanent"
    else
        _bad "halt_class_categorize('$reason') -> expected permanent, got '$got'"
    fi
done

# Unrecognized reason defaults to transient (cheap retry beats a false halt).
got="$(halt_class_categorize "some brand new unrecognized reason")"
if [[ "$got" == "transient" ]]; then
    _ok "halt_class_categorize(unrecognized) -> defaults to transient"
else
    _bad "halt_class_categorize(unrecognized) -> expected transient default, got '$got'"
fi

echo ""
echo "halt-class-emit: $_pass passed, $_fail failed"
[[ "$_fail" -eq 0 ]]
