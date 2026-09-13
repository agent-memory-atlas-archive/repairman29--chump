#!/usr/bin/env bash
# scripts/ci/test-node-refresh-green-main.sh — RESILIENT-327
#
# Proves node-refresh-chump.sh keeps the BINARY pinned to the last-GREEN main
# pointer while the SOURCE TREE tracks origin/main HEAD (RESILIENT-327 +
# RESILIENT-1205). With a green sha OLDER than HEAD injected via
# CHUMP_NODE_REFRESH_TEST_GREEN_SHA:
#   * the working tree must land on origin/main HEAD (the "bad" tip) — so a
#     merged BASH-organ fix on HEAD actually reaches the iron and this script
#     never fights chump-node-converge (RESILIENT-1189) over the tree SHA;
#   * the INSTALLED BINARY must still report the GREEN sha (built from a detached
#     worktree at the green pin), never the unverified HEAD binary.
# Also proves the explicit (non-silent) fallback to raw HEAD when no green sha
# can be found.
#
# RESILIENT-1205 regression guard: the pre-1205 script reset the WORKING TREE to
# the green pin, which permanently pinned the checkout behind HEAD whenever green
# lagged (a coherence-sync commit with no build artifact) — the merged-!=-deployed
# keystone. This test now asserts the tree tracks HEAD and only the binary is
# green-pinned.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SCRIPT="$REPO_ROOT/scripts/ops/node-refresh-chump.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -x "$SCRIPT" ] || fail "missing or not executable"
bash -n "$SCRIPT" || fail "syntax error"
ok "bash -n passes"

# ── Fixture: bare origin + mirror clone with a GREEN commit then a BAD one ──
ORIGIN="$TMP/origin.git"
MIRROR="$TMP/mirror"
git init --bare -q "$ORIGIN"
git clone -q "$ORIGIN" "$MIRROR"
git -C "$MIRROR" config user.email test@example.com
git -C "$MIRROR" config user.name "Test"

echo "v1" > "$MIRROR/f.txt"
git -C "$MIRROR" add f.txt
git -C "$MIRROR" commit -q -m "green commit"
git -C "$MIRROR" push -q origin HEAD:main
GREEN_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

echo "v2-bad" > "$MIRROR/f.txt"
git -C "$MIRROR" commit -q -am "bad commit (red main, would fail CI)"
git -C "$MIRROR" push -q origin HEAD:main
BAD_SHA="$(git -C "$MIRROR" rev-parse HEAD)"

# Reset the mirror's local main back so the script's own `git fetch` +
# `git reset --hard` is exercised against a real remote-ahead-of-local state.
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"

# ── Fake cargo: stub PATH so no real build runs (fast + hermetic) ──────────
mkdir -p "$TMP/bin" "$MIRROR/target/release"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
# Fake `cargo build --release --bin chump`: writes a stub binary that reports
# the sha of the BUILD cwd's HEAD via `chump --version`, mirroring the real
# binary's "(<sha> built ...)" format closely enough for the refresh script's
# grep. Honors CARGO_TARGET_DIR (RESILIENT-1205: node-refresh builds the green
# pin in a detached worktree while reusing the repo's warm target dir).
out="${CARGO_TARGET_DIR:-target}/release"
mkdir -p "$out"
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
# portable (no sed -i, which differs on BSD/macOS vs GNU): bake the sha directly.
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > "$out/chump"
chmod +x "$out/chump"
exit 0
EOF
chmod +x "$TMP/bin/cargo"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

# ── Test 1: green sha older than HEAD → TREE lands on HEAD, BINARY on green ─
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "green-pin run exited $rc: $(cat "$TMP/out1.log")"

# RESILIENT-1205: the SOURCE tree tracks origin/main HEAD (the bad tip), so
# merged bash-organ fixes reach the iron and node-converge is never fought.
LANDED_SHA="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA" = "$BAD_SHA" ] \
    || fail "source tree landed on $LANDED_SHA, expected origin/main HEAD $BAD_SHA (green pin was $GREEN_SHA)"
ok "node-refresh converges the source tree to origin/main HEAD (RESILIENT-1205)"

# RESILIENT-327: the installed BINARY must still be the GREEN one, built from a
# detached worktree at the green pin — never the unverified HEAD binary.
INSTALLED_VER="$("$TMP/installed-chump" --version 2>/dev/null || echo none)"
case "$INSTALLED_VER" in
    *"${GREEN_SHA:0:12}"*) ok "installed binary is green-pinned ($INSTALLED_VER), not the HEAD binary" ;;
    *"${BAD_SHA:0:12}"*)   fail "installed binary is the HEAD/bad sha ($INSTALLED_VER) — green pin violated" ;;
    *)                     fail "installed binary version unexpected: $INSTALLED_VER" ;;
esac

grep -q "PIN: raw HEAD" "$TMP/out1.log" \
    || fail "expected a loud PIN log line noting raw HEAD is ahead of green-main"
grep -q '"kind":"node_refresh_green_pin_behind_head"' "$AMBIENT" \
    || fail "expected node_refresh_green_pin_behind_head emitted: $(cat "$AMBIENT")"
ok "divergence between raw HEAD and the green pin is logged loudly, not silently"

# ── Test 2: no green sha available → explicit, non-silent fallback to HEAD ─
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
CHUMP_NODE_REPO="$MIRROR" \
CHUMP_NODE_BIN="$TMP/installed-chump2" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs2" \
HOME="$TMP/fakehome" \
PATH="$TMP/bin:$PATH" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "fallback run exited $rc: $(cat "$TMP/out2.log")"

LANDED_SHA2="$(git -C "$MIRROR" rev-parse HEAD)"
[ "$LANDED_SHA2" = "$BAD_SHA" ] \
    || fail "fallback (no gh) run should land on raw HEAD ($BAD_SHA), got $LANDED_SHA2"
grep -q '"kind":"node_refresh_green_lookup_failed"' "$AMBIENT" \
    || fail "expected node_refresh_green_lookup_failed emitted on fallback: $(cat "$AMBIENT")"
ok "with no green sha resolvable, falls back to raw HEAD and emits it loudly (non-silent)"

exit 0
