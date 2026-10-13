#!/usr/bin/env bash
# test-no-ship-with-free.sh — operator rule: WE DON'T SHIP WITH FREE.
# Guards worker.sh's backend selection: a worker with no sub auth must NOT
# silently default to the free-tier floor (chump-local). It must honor an
# explicit backend (cheap non-ship sweep opt-in) or fail loud (exit 78).
#
# Depth: edge. Mirrors the decision block in scripts/dispatch/worker.sh and
# asserts the live script carries the refusal guard (tripwire).
set -u

WORKER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/dispatch/worker.sh"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# resolve_backend <has_auth 0|1> <FLEET_BACKEND> <CHUMP_WORK_BACKEND>
# prints the chosen backend, or "REFUSE" when the worker would fail loud.
# Mirrors worker.sh:150-172 — KEEP IN SYNC.
resolve_backend() {
    local has_auth="$1" fb="$2" cwb="$3"
    if [ "$has_auth" = "0" ]; then
        if [ -n "$fb" ] || [ -n "$cwb" ]; then
            printf '%s' "${fb:-$cwb}"
        else
            printf 'REFUSE'
        fi
    else
        printf '%s' "${fb:-${cwb:-claude}}"
    fi
}

# 1. auth present, nothing explicit → claude (sub). (the normal fleet path)
[ "$(resolve_backend 1 '' '')" = "claude" ] && ok "auth present → claude (sub)" || bad "auth present should → claude"
# 2. NO auth, nothing explicit → REFUSE (never silent free-tier ship). THE RULE.
[ "$(resolve_backend 0 '' '')" = "REFUSE" ] && ok "no auth, no explicit backend → REFUSE (no silent free ship)" || bad "no-auth default must REFUSE, not chump-local"
# 3. NO auth, explicit chump-local (operator sweep opt-in) → honored.
[ "$(resolve_backend 0 'chump-local' '')" = "chump-local" ] && ok "explicit chump-local sweep opt-in honored" || bad "explicit chump-local should be honored"
# 4. auth present but operator forced chump-local → honored (explicit wins).
[ "$(resolve_backend 1 'chump-local' '')" = "chump-local" ] && ok "explicit backend wins even with auth" || bad "explicit FLEET_BACKEND should win"
# 5. CHUMP_WORK_BACKEND respected under no-auth when explicit.
[ "$(resolve_backend 0 '' 'chump-local')" = "chump-local" ] && ok "CHUMP_WORK_BACKEND explicit honored under no-auth" || bad "CHUMP_WORK_BACKEND explicit should be honored"

# Tripwire: live worker.sh must carry the refusal guard (not the old silent default).
grep -q "worker_refused_free_ship" "$WORKER" && ok "worker.sh has the no-free-ship refusal guard" || bad "worker.sh missing refusal guard"
grep -qE "FLEET_BACKEND=.\\\$\{FLEET_BACKEND:-\\\$\{CHUMP_WORK_BACKEND:-chump-local\}\}" "$WORKER" && bad "worker.sh STILL silently defaults to chump-local" || ok "no silent chump-local default remains"

if [ "$fails" -eq 0 ]; then echo "PASS: no-ship-with-free"; else echo "FAIL: $fails"; exit 1; fi
