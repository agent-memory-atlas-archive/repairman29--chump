#!/usr/bin/env bash
# RESILIENT-1206 (RESILIENT-1205 slice): reproducible local environment for
# the RESILIENT-1189 node-refresh failure that RESILIENT-1205 fixed.
#
# Original failure (RESILIENT-1205 commit message, CJ receipts):
#   node-refresh-chump.sh green-pinned the WORKING TREE to the last-green
#   main pointer, which lags origin/main HEAD whenever green lands on a
#   commit with no build artifact (e.g. a "chore(backlog): coherence sync"
#   commit). The checkout was permanently reset back to a stale parent
#   commit every ~5 min, so a merged bash-organ fix on HEAD (like the
#   RESILIENT-1189 node-converge organ itself) never reached the tree the
#   deploy reads from — merged != deployed.
#
# This script builds the same hermetic git fixture CI uses
# (scripts/ci/test-node-refresh-green-main.sh) and runs the PRE-RESILIENT-1205
# version of node-refresh-chump.sh (extracted via `git show` from the commit
# immediately before the fix) against it, so the original failure reproduces
# on demand without reverting any tracked file. All output is captured under
# a logdir printed at the end for follow-up debugging (AC 2).
#
# Usage: scripts/dev/reproduce-resilient-1189-node-refresh-pin-lag.sh
# Exit 0 when the original failure reproduces (tree stuck behind HEAD) or
# when it is confirmed absent on the CURRENT (post-1205) script — REPRO_RESULT
# line carries the signal, mirroring reproduce-infra1655-checkout-flake.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
PRE_FIX_COMMIT="c9c9a81d4^"   # parent of the RESILIENT-1205 fix commit
FIXED_SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"

RUN_DIR="$(mktemp -d)"
LOGDIR="$HOME/.chump/repro-logs/resilient-1206-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo now)"
mkdir -p "$LOGDIR"
trap 'rm -rf "$RUN_DIR"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; }

echo "== RESILIENT-1206: reproduce the RESILIENT-1189/RESILIENT-1205 pin-lag failure =="
echo "run dir: $RUN_DIR"
echo "logs:    $LOGDIR"
echo

PRE_FIX_SCRIPT="$RUN_DIR/node-refresh-chump-PRE-1205.sh"
if ! git -C "$REPO_ROOT" show "$PRE_FIX_COMMIT:scripts/ops/node-refresh-chump.sh" > "$PRE_FIX_SCRIPT" 2>"$LOGDIR/git-show.log"; then
    echo "REPRO_RESULT=fixture_error"
    fail "could not extract pre-fix node-refresh-chump.sh from $PRE_FIX_COMMIT"
    cat "$LOGDIR/git-show.log" >&2
    exit 0
fi
chmod +x "$PRE_FIX_SCRIPT"

# ── Fixture: bare origin + mirror clone with a GREEN commit then a BAD one ──
# (same shape as scripts/ci/test-node-refresh-green-main.sh so this stays a
# faithful local mirror of what CI exercises)
ORIGIN="$RUN_DIR/origin.git"
MIRROR="$RUN_DIR/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

echo "v1" > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "green commit"
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

echo "v2-bash-organ-fix" > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "merged bash-organ fix (would never reach the tree pre-1205)"
git -C "$MIRROR" push -q origin HEAD:main
HEAD_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

# ── Fake cargo: stub PATH so no real build runs (fast + hermetic) ──────────
mkdir -p "$RUN_DIR/bin" "$MIRROR/target/release"
cat > "$RUN_DIR/bin/cargo" <<'EOF'
#!/usr/bin/env bash
out="${CARGO_TARGET_DIR:-target}/release"
mkdir -p "$out"
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > "$out/chump"
chmod +x "$out/chump"
exit 0
EOF
chmod +x "$RUN_DIR/bin/cargo"

AMBIENT="$RUN_DIR/.chump-locks/ambient.jsonl"
mkdir -p "$RUN_DIR/.chump-locks"

run_variant() {
    local label="$1" script="$2" logfile="$3"
    git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
    CHUMP_NODE_REPO="$MIRROR" \
    CHUMP_NODE_BIN="$RUN_DIR/installed-chump-$label" \
    NODE_AMBIENT="$AMBIENT" \
    CHUMP_NODE_REFRESH_LOGDIR="$RUN_DIR/logs-$label" \
    CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
    HOME="$RUN_DIR/fakehome-$label" \
    PATH="$RUN_DIR/bin:$PATH" \
        bash "$script" > "$logfile" 2>&1
    git -C "$MIRROR" rev-parse HEAD
}

echo "-- running PRE-RESILIENT-1205 script (the original failure) --"
PRE_LOG="$LOGDIR/pre-1205-run.log"
LANDED_PRE="$(run_variant pre "$PRE_FIX_SCRIPT" "$PRE_LOG")"
cp "$PRE_FIX_SCRIPT" "$LOGDIR/node-refresh-chump-PRE-1205.sh"

if [ "$LANDED_PRE" = "$GREEN_SHA" ]; then
    ok "REPRODUCED: pre-1205 script left the source tree pinned at green ($GREEN_SHA), never reaching origin/main HEAD ($HEAD_SHA)"
    PRE_RESULT="reproduced"
else
    fail "expected pre-1205 script to reproduce the pin-lag bug (land on $GREEN_SHA) but it landed on $LANDED_PRE"
    PRE_RESULT="not_reproduced"
fi

echo
echo "-- running CURRENT (post-RESILIENT-1205) script for contrast --"
FIXED_LOG="$LOGDIR/post-1205-run.log"
LANDED_FIXED="$(run_variant fixed "$FIXED_SCRIPT" "$FIXED_LOG")"

if [ "$LANDED_FIXED" = "$HEAD_SHA" ]; then
    ok "CONFIRMED FIXED: current script converges the tree to origin/main HEAD ($HEAD_SHA) regardless of the green pin"
    FIXED_RESULT="fixed"
else
    fail "current script landed on $LANDED_FIXED, expected origin/main HEAD $HEAD_SHA"
    FIXED_RESULT="unexpected"
fi

cp "$AMBIENT" "$LOGDIR/ambient.jsonl" 2>/dev/null || true

echo
echo "REPRO_RESULT=${PRE_RESULT}"
echo "FIX_RESULT=${FIXED_RESULT}"
echo "logs captured under: $LOGDIR"
echo "  pre-1205 run log:   $LOGDIR/pre-1205-run.log"
echo "  post-1205 run log:  $LOGDIR/post-1205-run.log"
echo "  ambient stream:     $LOGDIR/ambient.jsonl"
echo "  pre-1205 script:    $LOGDIR/node-refresh-chump-PRE-1205.sh"

[ "$PRE_RESULT" = "reproduced" ] && [ "$FIXED_RESULT" = "fixed" ]
exit 0
