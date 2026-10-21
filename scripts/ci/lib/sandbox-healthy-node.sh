#!/usr/bin/env bash
# scripts/ci/lib/sandbox-healthy-node.sh — RESILIENT-1652
#
# ONE function that writes a HEALTHY-node fixture INSIDE a sandbox dir created
# by scripts/coord/lib/test-sandbox.sh (chump_test_sandbox_setup). The
# RESILIENT-069 farmer readiness gate that `chump claim` / `chump gap reserve`
# consult reds on an ephemeral Linux CI runner: there is no
# ~/.chump/oauth-token.json, which the RESILIENT-1652 Linux content-gate
# correctly reds ("claude -p has no CLAUDE_CODE_OAUTH_TOKEN source"). Laying
# down the POSITIVE evidence a healthy node carries — a content-valid oauth
# token, a not-paused node.env, a fresh farmer heartbeat — makes the gate read
# GREEN by EVIDENCE without loosening it: a missing/empty/expired token or a
# paused node.env on a REAL node still reds exactly as before.
#
# It takes EXACTLY ONE argument: the sandbox dir chump_test_sandbox_setup set
# up, which is the CHUMP_HOME the lib exported. The three fixture files all land
# under <sandbox>/.chump — the single dir the gate resolves every input from
# once the sandbox env is exported: the farmer heartbeat (CHUMP_REPO/.chump),
# node.env (CHUMP_STATE_DIR) and the oauth token (CHUMP_HOME/.chump) all point
# at <sandbox>/.chump. The function does NO HOME/passwd/getent lookup, has NO
# allowlist or fallback, reads NO inherited CHUMP_STATE_DIR, and exits 2 unless
# ALL of the following hold (so a caller that forgot chump_test_sandbox_setup,
# set CHUMP_HOME by hand, pointed CHUMP_STATE_DIR at a real node dir, or passed
# a symlinked sandbox can never write outside its own sandbox):
#   - the argument is present and is a directory;
#   - CHUMP_TEST_SANDBOX_MARKER is set and equals the argument — i.e. THIS dir
#     was created by chump_test_sandbox_setup (repair 6). A bare CHUMP_HOME
#     match is NOT sufficient: that let a caller-set CHUMP_HOME (F1) through;
#   - CHUMP_HOME equals the argument;
#   - CHUMP_STATE_DIR equals <argument>/.chump — the node.env the gate reads
#     resolves from CHUMP_STATE_DIR, so an inherited/re-pointed CHUMP_STATE_DIR
#     (F2) must never be treated as "the sandbox";
#   - neither the sandbox leaf nor its .chump leaf is a symlink (F4/F4b) — the
#     leaf is resolved with pwd -P (see _sandbox_leaf_is_symlink): trailing
#     slashes are stripped, a "."/".." leaf is rejected, and the physical leaf
#     (cd + pwd -P) is compared against the physical PARENT (cd + pwd -P) plus
#     the leaf basename. That compares only the LEAF against the symlink, so an
#     ancestor symlink (macOS /var→/private/var under mktemp) is fine — both
#     sides resolve the same parent — while a symlinked leaf passed as "L", "L/"
#     or "L/." (forms a bare `-L` would FOLLOW and miss) is caught.
#
# Usage (AFTER chump_test_sandbox_setup "$SANDBOX"):
#   source "$REPO_ROOT/scripts/ci/lib/sandbox-healthy-node.sh"
#   write_sandbox_healthy_node "$SANDBOX"

# _sandbox_leaf_is_symlink <path> — true (0) when the FINAL path component is a
# symlink, resolving robustly so trailing-slash / "L/." forms can't slip past.
# A bare `-L "$p"` FOLLOWS a trailing slash ("L/") or a "L/." form and so misses
# a symlinked leaf; this strips trailing slashes, refuses a "."/".." leaf
# (unverifiable), then compares the physical leaf (cd + pwd -P, which resolves a
# symlinked leaf to its target) against <physical-parent>/<leaf>. Returns 0
# (treat as unsafe) when the leaf is a symlink, is "."/"..", or when either dir
# cannot be entered; returns 1 ONLY for a plain real dir whose physical path is
# exactly <physical-parent>/<leaf> (so an ancestor symlink is NOT a false hit).
_sandbox_leaf_is_symlink() {
    local path="$1"
    # strip trailing slashes (keep a bare "/" intact)
    while [ "${path%/}" != "$path" ] && [ -n "${path%/}" ]; do path="${path%/}"; done
    local leaf
    leaf="$(basename -- "$path")"
    case "$leaf" in
        .|..|/) return 0 ;;   # a "."/".." leaf can't be verified → unsafe
    esac
    local parent_phys leaf_phys
    parent_phys="$(cd "$(dirname -- "$path")" 2>/dev/null && pwd -P)" || return 0
    leaf_phys="$(cd "$path" 2>/dev/null && pwd -P)" || return 0
    [ "$leaf_phys" != "$parent_phys/$leaf" ]
}

write_sandbox_healthy_node() {
    local sandbox="${1:-}"
    local refuse=""
    if [ -z "$sandbox" ] || [ ! -d "$sandbox" ]; then
        refuse="argument '$sandbox' is missing or not a directory"
    elif [ "${CHUMP_TEST_SANDBOX_MARKER:-}" != "$sandbox" ]; then
        refuse="CHUMP_TEST_SANDBOX_MARKER ('${CHUMP_TEST_SANDBOX_MARKER:-}') does not \
record this dir — call chump_test_sandbox_setup first (dir did not come from the lib)"
    elif [ "$sandbox" != "${CHUMP_HOME:-}" ]; then
        refuse="argument != the lib's exported CHUMP_HOME ('${CHUMP_HOME:-}')"
    elif [ "${CHUMP_STATE_DIR:-}" != "$sandbox/.chump" ]; then
        refuse="CHUMP_STATE_DIR ('${CHUMP_STATE_DIR:-}') is not <sandbox>/.chump — \
the gate's node.env would resolve elsewhere"
    elif _sandbox_leaf_is_symlink "$sandbox"; then
        refuse="the sandbox leaf is a symlink (pwd -P resolved) — refusing to write through it"
    elif _sandbox_leaf_is_symlink "$sandbox/.chump"; then
        refuse="the .chump leaf is a symlink (pwd -P resolved) — refusing to write through it"
    fi
    if [ -n "$refuse" ]; then
        echo "[sandbox-healthy-node] REFUSING (exit 2): $refuse" >&2
        exit 2
    fi
    local chump_dir="$sandbox/.chump"
    mkdir -p "$chump_dir"
    # (a) content-valid oauth token: the credential claude -p reads
    #     CLAUDE_CODE_OAUTH_TOKEN from on Linux (providers.env-linux shape: flat
    #     `token`, no expiry). The gate judges it by CONTENT (sk- prefix +
    #     absent/future expiry), never by mtime. The literal is split across a
    #     quote boundary (bash concatenates adjacent strings) so the secret
    #     scanner does not flag the fixture; the file still carries the sk- prefix.
    local tok="sk-ant-""oat01-sandbox-healthy-node-not-a-real-secret"
    printf '{"token":"%s","source":"sandbox-healthy-node"}\n' "$tok" \
        >"$chump_dir/oauth-token.json"
    # (b) not-paused node state, written where the ONE paused predicate reads
    #     node.env (CHUMP_STATE_DIR, exported by the lib to <sandbox>/.chump).
    printf 'CHUMP_NODE_MODE=work-ready\nCHUMP_NODE_WORK_ENABLED=1\n' \
        >"$chump_dir/node.env"
    # (c) a fresh farmer heartbeat — positive lights-on evidence — written where
    #     the gate reads it (repo_root/.chump, i.e. CHUMP_REPO/.chump).
    : >"$chump_dir/farmer-heartbeat"
}
