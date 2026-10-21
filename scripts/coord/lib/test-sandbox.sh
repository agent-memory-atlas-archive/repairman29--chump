#!/usr/bin/env bash
# scripts/coord/lib/test-sandbox.sh — INFRA-2088
#
# Single canonical sandbox primitive for CI/test scripts that need to run
# `chump` commands fully isolated from the real .chump/state.db. Centralizes
# the "which env vars must be set to isolate from real state" list in ONE
# place so a future new isolation var (e.g. CHUMP_SOMETHING_DB) is added once
# here and every test inherits the fix — killing the INFRA-2080 drift class
# where CHUMP_REPO_ROOT vs CHUMP_HOME drift let a sandbox bleed into the
# real state.db.
#
# Usage:
#   source "$REPO_ROOT/scripts/coord/lib/test-sandbox.sh"
#   chump_test_sandbox_setup "$TMP_SANDBOX" --seed-yaml "$FIXTURE_YAML"
#   ... run chump commands; they resolve against $TMP_SANDBOX ...
#   chump_test_sandbox_cleanup "$TMP_SANDBOX"

# chump_test_sandbox_setup <sandbox-dir> [--seed-yaml <fixture-yaml-path>]
#
# Creates <sandbox-dir>/.chump/state.db (optionally seeded from a fixture
# gaps YAML via `chump gap import`) and exports every env var required to
# fully isolate `chump` invocations from the real repo's state.
#
# <fixture-yaml-path> may be a single per-gap YAML file (bare list, e.g.
# `docs/gaps/INFRA-NNNN.yaml` style) or a directory of such files — either
# way it's copied into <sandbox-dir>/docs/gaps/ before import, since
# `chump gap import` only derives the right repo-root when the --yaml path
# itself ends in docs/gaps(.yaml).
chump_test_sandbox_setup() {
    local sandbox="$1"
    shift
    local seed_yaml=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --seed-yaml)
                seed_yaml="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    mkdir -p "$sandbox/.chump" "$sandbox/.chump-locks"

    # CRITICAL (INFRA-2080 class): this is the ONE place that lists every
    # env var `chump` reads to resolve repo-root / state.db / lock-dir.
    # Add new isolation vars here, not per-test.
    export CHUMP_HOME="$sandbox"
    export CHUMP_REPO="$sandbox"
    export CHUMP_REPO_ROOT="$sandbox"
    export CHUMP_STATE_DB="$sandbox/.chump/state.db"
    export CHUMP_LOCK_DIR="$sandbox/.chump-locks"
    # RESILIENT-1652: the farmer readiness gate resolves the node STATE dir
    # (where node.env + the node pause sentinel live) from CHUMP_STATE_DIR first
    # (src/farmer_status.rs resolve_node_state_dir). An INHERITED CHUMP_STATE_DIR
    # — a fleet node's installer exports it to the REAL state dir — would make
    # the gate read the real, possibly paused, node.env from inside a sandbox.
    # Pin it to the sandbox's .chump so the sandbox is hermetic against that
    # inherited env (and so write_sandbox_healthy_node's node.env lands exactly
    # where the gate reads it). Added here (not per-test) per the INFRA-2080
    # one-place-for-isolation-vars rule.
    export CHUMP_STATE_DIR="$sandbox/.chump"
    # RESILIENT-1652 (repair 6): record, as a marker, the exact sandbox THIS lib
    # created. write_sandbox_healthy_node refuses unless this marker is present
    # AND equals the dir it is asked to write into — proving the dir came from
    # the lib (an ephemeral mktemp sandbox), not a caller-set CHUMP_HOME that
    # might point at a real node's home. A bare CHUMP_HOME match is NOT enough:
    # test-fleet-kill-switch sets CHUMP_HOME inline, and a symlinked CHUMP_HOME
    # could resolve into a real node dir. The marker is the lib's own signature.
    export CHUMP_TEST_SANDBOX_MARKER="$sandbox"

    if [ -n "$seed_yaml" ]; then
        # `chump gap import --yaml <path>` derives repo-root from <path> by
        # stripping a trailing docs/gaps(.yaml) suffix — it only resolves
        # correctly when <path> itself ends in docs/gaps or docs/gaps.yaml.
        # So fixtures are copied into sandbox/docs/gaps/ before import,
        # regardless of where the caller's fixture dir/file actually lives.
        mkdir -p "$sandbox/docs/gaps"
        if [ -d "$seed_yaml" ]; then
            cp "$seed_yaml"/*.yaml "$sandbox/docs/gaps/" 2>/dev/null || true
        else
            cp "$seed_yaml" "$sandbox/docs/gaps/" 2>/dev/null || true
        fi
        CHUMP_GAP_IMPORT_NO_SIMILARITY=1 \
            chump gap import --yaml "$sandbox/docs/gaps" >/dev/null 2>&1 || true
    fi
}

# chump_test_sandbox_cleanup <sandbox-dir>
#
# Unsets every isolation var set by chump_test_sandbox_setup and removes
# the sandbox dir atomically.
chump_test_sandbox_cleanup() {
    local sandbox="$1"
    unset CHUMP_HOME CHUMP_REPO CHUMP_REPO_ROOT CHUMP_STATE_DB CHUMP_LOCK_DIR CHUMP_STATE_DIR CHUMP_TEST_SANDBOX_MARKER
    if [ -n "$sandbox" ] && [ -d "$sandbox" ]; then
        rm -rf "$sandbox"
    fi
}
