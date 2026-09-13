#!/usr/bin/env bash
# INFRA-021: concurrent reservations allocate one distinct ID per invocation.
#
# This test deliberately uses a fresh git repository and state.db. It exercises
# the SQLite reservation transaction and the shell wrapper's shared lock only;
# fleet-health admission, live Almanac dedupe, and PR/ambient checks have their
# own tests and must not make an atomicity test depend on this machine's state.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHUMP_BIN="${CHUMP_BIN:-$ROOT/target/debug/chump}"

if [[ ! -x "$CHUMP_BIN" ]]; then
    echo "FAIL: expected built chump binary at $CHUMP_BIN (set CHUMP_BIN or run cargo build --bin chump)" >&2
    exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

git init -q -b main "$SANDBOX"
git -C "$SANDBOX" config user.email "ci@example.invalid"
git -C "$SANDBOX" config user.name "Chump CI"
mkdir -p "$SANDBOX/bin" "$SANDBOX/docs/gaps" \
    "$SANDBOX/.chump-locks" "$SANDBOX/scripts/coord" "$SANDBOX/scripts/lib"

# Keep the production wrapper and its sourceable dependencies in the isolated
# repository, so its worktree and lock-path resolution are tested as installed.
cp "$ROOT/scripts/coord/gap-reserve.sh" "$SANDBOX/scripts/coord/gap-reserve.sh"
cp "$ROOT/scripts/lib/chump-preflight.sh" "$SANDBOX/scripts/lib/chump-preflight.sh"
cp "$ROOT/scripts/lib/repo-paths.sh" "$SANDBOX/scripts/lib/repo-paths.sh"
cp "$ROOT/scripts/lib/resolve-main-worktree.sh" "$SANDBOX/scripts/lib/resolve-main-worktree.sh"
chmod +x "$SANDBOX/scripts/coord/gap-reserve.sh"
ln -s "$CHUMP_BIN" "$SANDBOX/bin/chump"

touch "$SANDBOX/.gitkeep"
git -C "$SANDBOX" add .gitkeep
git -C "$SANDBOX" commit -q -m "seed isolated reserve fixture"

N="${1:-5}"
if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: reservation count must be a positive integer (got '$N')" >&2
    exit 2
fi

export PATH="$SANDBOX/bin:$PATH"
export CHUMP_HOME="$SANDBOX"
export CHUMP_REPO="$SANDBOX"
export CHUMP_WORKTREE_ROOT="$SANDBOX"
export CHUMP_LOCK_DIR="$SANDBOX/.chump-locks"
export CHUMP_ALLOW_MAIN_WORKTREE=1
export CHUMP_GAP_RESERVE_SKIP_PR=1
export CHUMP_RESERVE_SCAN_OPEN_PRS=0
export CHUMP_GAP_RESERVE_NO_SIMILARITY=1
export CHUMP_DISABLE_OFFLINE_CHECK=1
export CHUMP_PILLAR_BALANCE_DISABLE=1
export FLEET_029_AMBIENT_GLANCE_SKIP=1
export CHUMP_GAP_SERVER=""

pids=()
for ((i = 1; i <= N; i++)); do
    (
        cd "$SANDBOX"
        export CHUMP_SESSION_ID="gap-reserve-conc-${i}-$$"
        scripts/coord/gap-reserve.sh INFRA "concurrency smoke seq$i" >"$SANDBOX/id-$i.txt"
    ) &
    pids+=($!)
done

for p in "${pids[@]}"; do
    wait "$p"
done

ids="$(sort "$SANDBOX"/id-*.txt)"
unique_count="$(printf '%s\n' "$ids" | sort -u | wc -l | tr -d '[:space:]')"
if [[ "$unique_count" != "$N" ]]; then
    echo "FAIL: expected $N unique IDs, got $unique_count (duplicates or missing output)" >&2
    printf '%s\n' "$ids" | uniq -c >&2
    exit 1
fi

if ! printf '%s\n' "$ids" | grep -qE '^INFRA-[0-9]+$'; then
    echo "FAIL: reservation output contained a non-INFRA ID" >&2
    printf '%s\n' "$ids" >&2
    exit 1
fi

echo "OK: $N distinct INFRA-* reservations in an isolated state.db"
