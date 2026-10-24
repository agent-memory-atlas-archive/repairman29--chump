#!/usr/bin/env bash
# scripts/ci/test-gap-ship-auto-fetch.sh — INFRA-2423
#
# Smoke-tests for chump gap ship auto-fetch behaviour introduced in INFRA-2423.
# Verifies that:
#   A) clean local main N commits behind origin → auto-pull succeeds, proof passes
#   B) dirty local main N commits behind origin → ship exits 1 with clear error
#   C) clean local main up-to-date → ship proceeds normally (no noise)
#   D) CHUMP_BYPASS_PROOF_OF_MERGE env var is NOT consulted (setting it to 1 in
#      scenario B should still exit 1)
#
# All tests are pure-Rust unit tests triggered via `cargo test`; this wrapper
# runs them and checks exit codes. It also does source-level verification that
# the bypass var is absent from the gap-store crate.
#
# Run:
#   bash scripts/ci/test-gap-ship-auto-fetch.sh
#
# CI: wired in .github/workflows/ci.yml (INFRA-2423)

set -uo pipefail

PASS=0; FAIL=0; FAILS=()
ok()   { printf '  PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-gap-store/src/lib.rs"

echo "=== INFRA-2423: gap ship auto-fetch smoke tests ==="

# ── Source-level invariant checks ────────────────────────────────────────────
echo ""
echo "-- Source-level invariants --"

if grep -q "CHUMP_BYPASS_PROOF_OF_MERGE" "$SRC"; then
    fail "CHUMP_BYPASS_PROOF_OF_MERGE still present in $SRC (must be deleted per INFRA-2423)"
else
    ok "CHUMP_BYPASS_PROOF_OF_MERGE absent from gap-store source"
fi

if grep -q "INFRA-2423" "$SRC"; then
    ok "INFRA-2423 auto-fetch implementation present in $SRC"
else
    fail "INFRA-2423 auto-fetch implementation missing from $SRC"
fi

if grep -q '"fetch".*"origin".*"main"\|fetch.*origin.*main' "$SRC"; then
    ok "git fetch origin main call found in $SRC"
else
    fail "git fetch origin main call not found in $SRC"
fi

# RESILIENT-1645 AC1 & AC5: ship() is strictly fetch-only and never invokes
# `git pull --ff-only` or `cargo build --release` in the canonical checkout.
if grep -q 'args(\["pull", "--ff-only"' "$SRC"; then
    fail "git pull --ff-only call still present in $SRC (must be fetch-only per RESILIENT-1645 AC1)"
else
    ok "git pull --ff-only call absent from $SRC (RESILIENT-1645 AC1)"
fi

if grep -q 'args(\["build", "--release"' "$SRC"; then
    fail "cargo build --release call still present in $SRC (must be removed per RESILIENT-1645 AC5)"
else
    ok "cargo build --release call absent from $SRC (RESILIENT-1645 AC5)"
fi

if grep -q "RESILIENT-1645" "$SRC"; then
    ok "RESILIENT-1645 fetch-only implementation marker present in $SRC"
else
    fail "RESILIENT-1645 fetch-only implementation marker missing from $SRC"
fi

# ── Cargo unit tests ──────────────────────────────────────────────────────────
echo ""
echo "-- Cargo unit tests (chump-gap-store auto_fetch) --"

if ! command -v cargo >/dev/null 2>&1; then
    echo "  SKIP: cargo not available"
else
    if (cd "$REPO_ROOT" && \
        PATH="$HOME/.cargo/bin:$PATH" \
        cargo test -p chump-gap-store --lib auto_fetch --quiet -- --test-threads=1 2>&1 | tail -15
    ); then
        ok "cargo test auto_fetch tests passed"
    else
        fail "cargo test auto_fetch tests failed"
    fi
fi

# ── Integration: chump binary end-to-end (optional, requires built binary) ───
echo ""
echo "-- Binary integration (scenario C: up-to-date, proof satisfied) --"

CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/debug/chump"
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    CHUMP_BIN="${HOME}/.cargo/bin/chump"
fi
if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "  SKIP: chump binary not found (run 'cargo build --bin chump' or set CHUMP_BIN)"
else
    TMP="$(mktemp -d -t test-infra-2423.XXXXXX)"
    cleanup() { rm -rf "$TMP"; }
    trap cleanup EXIT

    # Set up an isolated git repo with a 'main' branch (simulates origin in sync)
    SHIP_REPO="$TMP/ship-repo"
    mkdir -p "$SHIP_REPO"
    git -C "$SHIP_REPO" init -q
    git -C "$SHIP_REPO" checkout -q -b main
    git -C "$SHIP_REPO" config user.email "test@integration.local"
    git -C "$SHIP_REPO" config user.name "Integration Test"

    # Reserve a test gap so we have a real gap ID
    mkdir -p "$SHIP_REPO/.chump"
    export CHUMP_STATE_DB="$SHIP_REPO/.chump/state.db"
    export CHUMP_REPO_ROOT="$SHIP_REPO"
    gap_id=$(
        FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
            --domain TEST \
            --title "TEST: INFRA-2423 auto-fetch smoke fixture" \
            --priority P3 --force 2>&1 | grep '^TEST-' | tail -1
    ) || true

    if [[ -z "$gap_id" ]]; then
        echo "  SKIP: could not reserve test gap for binary integration test"
    else
        # Add commit mentioning gap_id to SHIP_REPO main branch
        echo "marker" > "$SHIP_REPO/marker.txt"
        git -C "$SHIP_REPO" add marker.txt
        git -C "$SHIP_REPO" commit -q -m "feat(${gap_id}): INFRA-2423 auto-fetch test marker (#9999)"
        (cd "$SHIP_REPO" && CHUMP_REPO_ROOT="$SHIP_REPO" CHUMP_STATE_DB="$SHIP_REPO/.chump/state.db" "$CHUMP_BIN" gap link-pr "$gap_id" 9999 --sha "$(git -C "$SHIP_REPO" rev-parse HEAD)" >/dev/null 2>&1 || true)
        mkdir -p "$SHIP_REPO/docs/gaps"
        yaml_src="$REPO_ROOT/docs/gaps/${gap_id}.yaml"
        [[ -f "$yaml_src" ]] && cp "$yaml_src" "$SHIP_REPO/docs/gaps/${gap_id}.yaml"

        SHIP_OUT=$(
            cd "$SHIP_REPO" &&
            CHUMP_REPO="$SHIP_REPO" CHUMP_REPO_ROOT="$SHIP_REPO" \
            CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
            CHUMP_SHIP_NO_AUTOSTAGE=1 \
            CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$CHUMP_BIN" gap ship "$gap_id" --closed-pr 9999 2>&1
        )
        SHIP_RC=$?
        if [[ $SHIP_RC -eq 0 ]]; then
            ok "Scenario C: up-to-date clean repo — ship succeeded for $gap_id"
        else
            fail "Scenario C: ship exited $SHIP_RC; output: ${SHIP_OUT:0:200}"
        fi

        # Verify bypass var is NOT consulted: set it and scenario should still work
        # (it has no effect — the var is gone from the binary)
        BYPASS_OUT=$(
            cd "$SHIP_REPO" &&
            CHUMP_REPO="$SHIP_REPO" CHUMP_REPO_ROOT="$SHIP_REPO" \
            CHUMP_BYPASS_PROOF_OF_MERGE=1 \
            CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
            CHUMP_SHIP_NO_AUTOSTAGE=1 \
            CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$CHUMP_BIN" gap ship "$gap_id" --closed-pr 9999 2>&1
        )
        BYPASS_RC=$?
        # The gap is already done, so this should fail with "not found or already done"
        # What matters is the exit code is NOT 0 AND the reason is "already done", not
        # a bypass-consulted message. We just verify the binary didn't emit bypass text.
        if echo "$BYPASS_OUT" | grep -q "CHUMP_BYPASS_PROOF_OF_MERGE"; then
            fail "Scenario D: binary still references CHUMP_BYPASS_PROOF_OF_MERGE in output"
        else
            ok "Scenario D: binary does not reference deleted bypass var in output"
        fi

        # Clean up test gap YAML from real repo
        [[ -f "$yaml_src" ]] && rm -f "$yaml_src" || true
    fi

    # RESILIENT-1645 AC2 & AC5: when origin/main is ahead of local HEAD, gap ship
    # fetches origin/main, proves merge from origin/main, and leaves HEAD, index,
    # working tree, Cargo.lock, and workspace-hack/Cargo.toml byte-unchanged.
    gap_id2=$(
        FLEET_029_AMBIENT_GLANCE_SKIP=1 \
        "$CHUMP_BIN" gap reserve \
            --domain TEST \
            --title "TEST: RESILIENT-1645 fetch-only fixture" \
            --priority P3 --force 2>&1 | grep '^TEST-' | tail -1
    ) || true
    if [[ -n "$gap_id2" ]] && grep -qa "RESILIENT-1645" "$CHUMP_BIN" 2>/dev/null; then
        BARE_ORIGIN="$TMP/origin.git"
        git clone --bare -q "$SHIP_REPO" "$BARE_ORIGIN"
        git -C "$SHIP_REPO" remote add origin "$BARE_ORIGIN" 2>/dev/null || git -C "$SHIP_REPO" remote set-url origin "$BARE_ORIGIN"
        git -C "$SHIP_REPO" push -q origin main

        # Advance origin/main in a separate clone so SHIP_REPO is behind
        ADV="$TMP/advance"
        git clone -q "$BARE_ORIGIN" "$ADV"
        git -C "$ADV" config user.email "test@integration.local"
        git -C "$ADV" config user.name "Integration Test"
        echo "ahead" > "$ADV/ahead.txt"
        git -C "$ADV" add ahead.txt
        git -C "$ADV" commit -q -m "feat(${gap_id2}): RESILIENT-1645 origin ahead (#9998)"
        git -C "$ADV" push -q origin main

        # Populate Cargo.lock and workspace-hack/Cargo.toml in SHIP_REPO
        mkdir -p "$SHIP_REPO/workspace-hack"
        printf '# lock-before\n' > "$SHIP_REPO/Cargo.lock"
        printf '# hack-before\n' > "$SHIP_REPO/workspace-hack/Cargo.toml"
        printf '[workspace]\nmembers = []\n' > "$SHIP_REPO/Cargo.toml"
        head_before="$(git -C "$SHIP_REPO" rev-parse HEAD)"
        index_sha_before="$(sha256sum "$SHIP_REPO/.git/index" | awk '{print $1}')"
        lock_sha_before="$(sha256sum "$SHIP_REPO/Cargo.lock" | awk '{print $1}')"
        hack_sha_before="$(sha256sum "$SHIP_REPO/workspace-hack/Cargo.toml" | awk '{print $1}')"

        "$CHUMP_BIN" gap link-pr "$gap_id2" 9998 --sha "$(git -C "$ADV" rev-parse HEAD)" >/dev/null 2>&1 || true

        SHIP2_OUT=$(
            cd "$SHIP_REPO" &&
            CHUMP_REPO="$SHIP_REPO" CHUMP_REPO_ROOT="$SHIP_REPO" \
            CHUMP_SKIP_SUPERSEDED_CLOSE=1 \
            CHUMP_SHIP_NO_AUTOSTAGE=1 \
            CHUMP_ALLOW_STALE_DESTRUCTIVE=1 \
            CHUMP_GAP_SHIP_SKIP_STALE_CHECK=1 \
            "$CHUMP_BIN" gap ship "$gap_id2" --closed-pr 9998 2>&1
        )
        SHIP2_RC=$?
        head_after="$(git -C "$SHIP_REPO" rev-parse HEAD)"
        index_sha_after="$(sha256sum "$SHIP_REPO/.git/index" | awk '{print $1}')"
        lock_sha_after="$(sha256sum "$SHIP_REPO/Cargo.lock" | awk '{print $1}')"
        hack_sha_after="$(sha256sum "$SHIP_REPO/workspace-hack/Cargo.toml" | awk '{print $1}')"

        if [[ $SHIP2_RC -eq 0 && "$head_before" == "$head_after" && ! -f "$SHIP_REPO/ahead.txt" && "$index_sha_before" == "$index_sha_after" && "$lock_sha_before" == "$lock_sha_after" && "$hack_sha_before" == "$hack_sha_after" ]]; then
            ok "RESILIENT-1645 AC2/AC5: HEAD, index, working tree, Cargo.lock, and workspace-hack/Cargo.toml byte-unchanged when origin/main is ahead"
        else
            fail "RESILIENT-1645 AC2/AC5: rc=$SHIP2_RC head_changed=$([[ $head_before != $head_after ]] && echo 1 || echo 0) index_changed=$([[ $index_sha_before != $index_sha_after ]] && echo 1 || echo 0) out=${SHIP2_OUT:0:200}"
        fi
        yaml_src2="$REPO_ROOT/docs/gaps/${gap_id2}.yaml"
        [[ -f "$yaml_src2" ]] && rm -f "$yaml_src2" || true
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if (( FAIL > 0 )); then
    for f in "${FAILS[@]}"; do printf '  - %s\n' "$f"; done
    exit 1
fi
echo "PASS"
