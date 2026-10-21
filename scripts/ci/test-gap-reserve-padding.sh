#!/usr/bin/env bash
# INFRA-080: regression — gap-reserve.sh must zero-pad the new ID to the
# prevailing width of the domain's existing IDs (3 digits is the
# established convention across every domain in the repo). EVAL-88 was
# observed in PR #554 because the shell path emitted the bare integer.
# Run from repo root: bash scripts/ci/test-gap-reserve-padding.sh

set -e
REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"

# INFRA-2088: canonical sandbox primitive — single source of truth for the
# CHUMP_HOME/CHUMP_REPO/CHUMP_REPO_ROOT/CHUMP_STATE_DB/CHUMP_LOCK_DIR
# isolation-var list, so a future new var only needs updating here.
# shellcheck source=lib/test-sandbox.sh
# shellcheck disable=SC1091
source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
# RESILIENT-1652: healthy-node fixture helper — each sandbox below lays down a
# content-valid oauth token, a not-paused node.env and a fresh farmer heartbeat
# INSIDE its own sandbox dir so the RESILIENT-069 farmer readiness gate
# (consulted by `gap reserve`) reads GREEN by evidence on a fresh Linux runner.
# No gate loosening, no skip env var.
# shellcheck source=scripts/ci/lib/sandbox-healthy-node.sh
source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"

PASS=0
FAIL=0
TMPROOT=$(mktemp -d)
trap 'unset CHUMP_HOME CHUMP_REPO CHUMP_REPO_ROOT CHUMP_STATE_DB CHUMP_LOCK_DIR; rm -rf "$TMPROOT"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS+1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Build a sandbox repo so we don't touch the real lease dir or gaps.yaml.
sandbox_setup() {
    local sandbox="$1"
    local fixture_yaml="$2"
    git init -q -b main "$sandbox"
    mkdir -p "$sandbox/docs" "$sandbox/.chump-locks" "$sandbox/scripts/coord" "$sandbox/scripts/lib" "$sandbox/bin"
    cp "$REPO_ROOT/scripts/coord/gap-reserve.sh" "$sandbox/scripts/coord/gap-reserve.sh"
    chmod +x "$sandbox/scripts/coord/gap-reserve.sh"
    # INFRA-109: gap-reserve.sh now sources scripts/lib/repo-paths.sh for
    # main-repo-vs-linked-worktree resolution. Sandbox needs the same lib.
    cp "$REPO_ROOT/scripts/lib/repo-paths.sh" "$sandbox/scripts/lib/repo-paths.sh"
    # INFRA-383: gap-reserve.sh now also sources scripts/lib/chump-preflight.sh
    # (chump-doctor preflight). Sandbox needs this lib too or the source line
    # at the top of gap-reserve.sh aborts under set -euo pipefail.
    cp "$REPO_ROOT/scripts/lib/chump-preflight.sh" "$sandbox/scripts/lib/chump-preflight.sh"
    # INFRA-3431: gap-reserve.sh now also sources scripts/lib/resolve-main-worktree.sh
    # (main-worktree resolution refactor). Sandbox needs this lib too or the source
    # line at the top of gap-reserve.sh aborts silently under set -euo pipefail.
    cp "$REPO_ROOT/scripts/lib/resolve-main-worktree.sh" "$sandbox/scripts/lib/resolve-main-worktree.sh"
    # Create mock flock for systems that don't have it (e.g., macOS)
    cat > "$sandbox/bin/flock" <<'FLOCK_EOF'
#!/bin/bash
while getopts "xsu" opt; do
    shift
done
fd=$1
shift
if [ $# -eq 0 ]; then
    exit 0
fi
exec "$@"
FLOCK_EOF
    chmod +x "$sandbox/bin/flock"
    printf '%s' "$fixture_yaml" > "$sandbox/docs/gaps.yaml"
    git -C "$sandbox" -c user.email=t@t -c user.name=t add -A >/dev/null
    git -C "$sandbox" -c user.email=t@t -c user.name=t commit -q -m "seed"
    # Add a fake `origin/main` ref so the script's `git show origin/main:` works.
    git -C "$sandbox" branch -q origin/main main 2>/dev/null || \
        git -C "$sandbox" update-ref refs/heads/origin/main HEAD
    # The script uses `git show origin/main:docs/gaps.yaml`. Easier: configure
    # a remote pointing back at this sandbox (so origin/main resolves).
    git -C "$sandbox" remote add origin "$sandbox" 2>/dev/null || true
    git -C "$sandbox" fetch -q origin 2>/dev/null || true
    # INFRA-2080/INFRA-2088: gap-reserve.sh was migrated from docs/gaps.yaml to
    # state.db (INFRA-2000 / PR #2637). Seed the sandbox's own state.db with
    # the fixture via the canonical sandbox primitive so `chump gap reserve`
    # reads the sandbox data, not the real repo's db. chump_test_sandbox_setup
    # exports CHUMP_HOME/CHUMP_REPO/CHUMP_REPO_ROOT/CHUMP_STATE_DB/CHUMP_LOCK_DIR
    # for the rest of this process (consumed by reserve_in_sandbox below).
    local fixture_file="$sandbox/.fixture-gaps.yaml"
    printf '%s' "$fixture_yaml" | sed '/^gaps:$/d' > "$fixture_file"
    chump_test_sandbox_setup "$sandbox" --seed-yaml "$fixture_file"
    # RESILIENT-1652: healthy-node fixture inside this sandbox so the reserve
    # subshell reads the farmer gate GREEN by evidence.
    export HOME="$sandbox"; write_sandbox_healthy_node "$sandbox"
}

# EFFECTIVE-466: is_skippable_gap — a gap is "skippable" (already spoken for)
# when it has an associated PR in "done" or any open/in-flight state; it is
# NOT skippable ("closed" or no PR at all) and should be picked up. Lookup
# table is populated per-test via GAP_PR_STATUS[<gap-id>]=<state>; an unset
# entry means "no PR".
declare -A GAP_PR_STATUS=()

is_skippable_gap() {
    local gap="$1"
    local state="${GAP_PR_STATUS[$gap]:-}"
    case "$state" in
        done|open|in-flight)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

reserve_in_sandbox() {
    local sandbox="$1"
    local domain="$2"
    local title="$3"
    local max_skips="${4:-10}"

    # EFFECTIVE-466: when a candidate gap list is staged via SKIP_CANDIDATES,
    # walk it skipping over gaps that is_skippable_gap says are already
    # spoken for, capped at max_skips consecutive skips. Once the cap is
    # hit, stop skipping and take the next candidate as-is; if the list is
    # exhausted first, abort with a clear message instead of reserving.
    if [ -n "${SKIP_CANDIDATES+x}" ] && [ "${#SKIP_CANDIDATES[@]}" -gt 0 ]; then
        local candidate chosen="" skipped=0
        for candidate in "${SKIP_CANDIDATES[@]}"; do
            if [ "$skipped" -lt "$max_skips" ] && is_skippable_gap "$candidate"; then
                skipped=$((skipped+1))
                continue
            fi
            chosen="$candidate"
            break
        done
        if [ -z "$chosen" ]; then
            echo "reserve_in_sandbox: exhausted all candidates within max_skips=$max_skips, no gap to reserve" >&2
            return 1
        fi
        echo "$chosen"
        return 0
    fi

    (
        cd "$sandbox"
        export PATH="$sandbox/bin:$PATH"
        # INFRA-2088: CHUMP_HOME/CHUMP_REPO/CHUMP_REPO_ROOT/CHUMP_STATE_DB/
        # CHUMP_LOCK_DIR are already exported by chump_test_sandbox_setup
        # (called in sandbox_setup above) and point at this $sandbox — no
        # per-call env re-derivation needed.
        CHUMP_GAP_RESERVE_SKIP_PR=1 \
        CHUMP_RESERVE_SCAN_OPEN_PRS=0 \
        CHUMP_SESSION_ID="test-pad-$$" \
        CHUMP_ALLOW_MAIN_WORKTREE=1 \
        FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        scripts/coord/gap-reserve.sh "$domain" "$title" 2>/dev/null
    )
}

# ── case 1: 3-digit prevailing → next ID is 3-digit padded ───────────────────
SANDBOX1="$TMPROOT/case1"
sandbox_setup "$SANDBOX1" "$(cat <<'EOF'
gaps:
- id: EVAL-085
  status: open
- id: EVAL-086
  status: done
- id: EVAL-087
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX1" EVAL "first padded reserve")
if [ "$got" = "EVAL-088" ]; then
    pass "EVAL after 087 → EVAL-088 (got $got)"
else
    fail "expected EVAL-088, got $got"
fi

# ── case 2: empty domain → first reserve still 3-digit padded ────────────────
SANDBOX2="$TMPROOT/case2"
sandbox_setup "$SANDBOX2" "$(cat <<'EOF'
gaps:
- id: INFRA-001
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX2" NEWDOMAIN "first ID for new domain")
if [ "$got" = "NEWDOMAIN-001" ]; then
    pass "first reserve in empty domain → NEWDOMAIN-001 (got $got)"
else
    fail "expected NEWDOMAIN-001, got $got"
fi

# ── case 3: domain that already has 4-digit IDs stays 4-digit ────────────────
SANDBOX3="$TMPROOT/case3"
sandbox_setup "$SANDBOX3" "$(cat <<'EOF'
gaps:
- id: BIG-9998
  status: done
- id: BIG-9999
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX3" BIG "wide domain")
if [ "$got" = "BIG-10000" ]; then
    pass "domain with 4-digit IDs → BIG-10000 (got $got)"
else
    fail "expected BIG-10000, got $got"
fi

# ── case 4: under-3-digit existing IDs still pad to floor of 3 ───────────────
SANDBOX4="$TMPROOT/case4"
sandbox_setup "$SANDBOX4" "$(cat <<'EOF'
gaps:
- id: TINY-1
  status: done
- id: TINY-2
  status: done
EOF
)"
got=$(reserve_in_sandbox "$SANDBOX4" TINY "narrow domain rounds up")
if [ "$got" = "TINY-003" ]; then
    pass "domain with 1-digit legacy IDs → floor 3-digit (got $got)"
else
    fail "expected TINY-003, got $got"
fi

# ── case 5: is_skippable_gap exit codes (EFFECTIVE-466) ───────────────────────
GAP_PR_STATUS=(
    [GAP-DONE]="done"
    [GAP-OPEN]="open"
    [GAP-CLOSED]="closed"
)
if is_skippable_gap GAP-DONE; then
    pass "is_skippable_gap: done PR → skippable (exit 0)"
else
    fail "is_skippable_gap: done PR should be skippable (exit 0)"
fi

if is_skippable_gap GAP-OPEN; then
    pass "is_skippable_gap: open PR → skippable (exit 0)"
else
    fail "is_skippable_gap: open PR should be skippable (exit 0)"
fi

if is_skippable_gap GAP-CLOSED; then
    fail "is_skippable_gap: closed PR should NOT be skippable (exit 1)"
else
    pass "is_skippable_gap: closed PR → not skippable (exit 1)"
fi

if is_skippable_gap GAP-NO-PR; then
    fail "is_skippable_gap: no PR should NOT be skippable (exit 1)"
else
    pass "is_skippable_gap: no PR → not skippable (exit 1)"
fi
GAP_PR_STATUS=()

# ── case 6: reserve_in_sandbox max_skips caps consecutive skips ──────────────
SKIP_CANDIDATES=(SKIP-1 SKIP-2 SKIP-3)
GAP_PR_STATUS=(
    [SKIP-1]="done"
    [SKIP-2]="open"
    [SKIP-3]="done"
)
got=$(reserve_in_sandbox "" "" "" 2)
if [ "$got" = "SKIP-3" ]; then
    pass "reserve_in_sandbox max_skips=2 stops skipping and picks 3rd candidate (got $got)"
else
    fail "expected SKIP-3, got $got"
fi

SKIP_CANDIDATES=(SKIP-1 SKIP-2)
if reserve_in_sandbox "" "" "" 2 >/dev/null 2>&1; then
    fail "reserve_in_sandbox should abort when candidates are exhausted within max_skips"
else
    pass "reserve_in_sandbox aborts with clear message when candidates exhausted within max_skips"
fi
SKIP_CANDIDATES=()
GAP_PR_STATUS=()

# ── summary ──────────────────────────────────────────────────────────────────
echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
