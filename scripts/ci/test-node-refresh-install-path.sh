#!/usr/bin/env bash
# scripts/ci/test-node-refresh-install-path.sh — RESILIENT-378
#
# Proves node-refresh-chump.sh installs the rebuilt binary where the FLEET's
# PATH actually resolves `chump` — an existing ~/.cargo/bin/chump — and NOT the
# old hardcoded ~/.local/bin/chump that the worker PATH shadows.
#
# LIVE ROOT CAUSE (closetjunky 2026-08-23): the RESILIENT-200 organ ran every
# cycle and rebuilt a CURRENT binary, but installed it to ~/.local/bin/chump
# (the old default), which is NOT on the worker PATH. Workers ran a STALE
# ~/.cargo/bin/chump for 5 days and drained the gap queue on old code. The
# refresh "ran" but did not do its job.
#
# Fails without RESILIENT-378: pre-change node-refresh-chump.sh hardcodes
# TARGET_BIN="${CHUMP_NODE_BIN:-$HOME/.local/bin/chump}", so with CHUMP_NODE_BIN
# UNSET it installs to ~/.local/bin/chump and leaves the pre-existing
# ~/.cargo/bin/chump stale — exactly the shadowing bug. Test 1's assertion that
# ~/.cargo/bin/chump was refreshed then fails.

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

# ── Fixture: bare origin + mirror clone with a single (green) commit ────────
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

# ── Fake cargo: writes a stub binary reporting the CURRENT HEAD sha ─────────
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'EOF'
#!/usr/bin/env bash
mkdir -p target/release
sha="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
printf '#!/usr/bin/env bash\necho "chump 0.0.0-test (%s built now)"\n' "$sha" > target/release/chump
chmod +x target/release/chump
exit 0
EOF
chmod +x "$TMP/bin/cargo"

# ── Fake HOME with a STALE ~/.cargo/bin/chump already present ───────────────
# The fleet PATH resolves chump here; the organ must refresh THIS file.
FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME/.cargo/bin"
cat > "$FAKEHOME/.cargo/bin/chump" <<'INNER'
#!/usr/bin/env bash
echo "chump 0.0.0-test (staleaaaaaaaa built old)"
INNER
chmod +x "$FAKEHOME/.cargo/bin/chump"

AMBIENT="$TMP/.chump-locks/ambient.jsonl"
mkdir -p "$TMP/.chump-locks"

# ── Test 1: CHUMP_NODE_BIN UNSET → installs to ~/.cargo/bin, not ~/.local/bin ─
# PATH deliberately excludes any real `chump` so `command -v chump` misses and
# resolution falls through to the ~/.cargo/bin/chump that exists under HOME.
env -u CHUMP_NODE_BIN \
CHUMP_NODE_REPO="$MIRROR" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out1.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "run exited $rc: $(cat "$TMP/out1.log")"

# The fleet-PATH binary must now report the green sha (refreshed in place).
CARGO_VER="$("$FAKEHOME/.cargo/bin/chump" --version 2>/dev/null || echo none)"
case "$CARGO_VER" in
    *"${GREEN_SHA:0:12}"*)
        ok "refresh installed to ~/.cargo/bin/chump (the fleet PATH), now current" ;;
    *"stale"*)
        fail "~/.cargo/bin/chump left STALE ($CARGO_VER) — organ installed elsewhere (the shadowing bug)" ;;
    *)
        fail "unexpected ~/.cargo/bin/chump version: $CARGO_VER" ;;
esac

# The old default location must NOT have been used when ~/.cargo/bin exists.
if [ -e "$FAKEHOME/.local/bin/chump" ]; then
    fail "organ wrote to shadowed ~/.local/bin/chump instead of the fleet ~/.cargo/bin path"
fi
ok "organ did NOT write to the shadowed ~/.local/bin/chump"

# ── Test 2: explicit CHUMP_NODE_BIN override still wins ─────────────────────
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
OVERRIDE="$TMP/custom/chump"
env CHUMP_NODE_BIN="$OVERRIDE" \
CHUMP_NODE_REPO="$MIRROR" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs2" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out2.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "override run exited $rc: $(cat "$TMP/out2.log")"
[ -x "$OVERRIDE" ] || fail "explicit CHUMP_NODE_BIN override was ignored"
ok "explicit CHUMP_NODE_BIN override still wins (precedence #1 preserved)"

# ── Test 3: on-PATH ~/.local/bin/chump must NOT shadow ~/.cargo/bin/chump ────
# LIVE ROOT CAUSE (closetjunky 2026-09-14): the refresh loop's OWN PATH had
# ~/.local/bin ahead of ~/.cargo/bin, so `command -v chump` resolved to
# ~/.local/bin/chump. Step 2 trusted that ambient answer and kept ~/.local/bin
# current every cycle, while the workers (PATH=~/.cargo/bin first;
# /usr/local/bin/chump -> ~/.cargo/bin/chump) ran a STALE ~/.cargo/bin/chump for
# 2 days. Here a REAL ~/.local/bin/chump is on PATH AND a ~/.cargo/bin/chump
# exists; the organ must refresh the ~/.cargo/bin binary, not the shadow.
git -C "$MIRROR" checkout -q -B main "$GREEN_SHA"
# Restore a stale ~/.cargo/bin/chump (Test 1 refreshed it to green) and plant a
# real ~/.local/bin/chump that PATH will resolve first.
cat > "$FAKEHOME/.cargo/bin/chump" <<'INNER'
#!/usr/bin/env bash
echo "chump 0.0.0-test (staleaaaaaaaa built old)"
INNER
chmod +x "$FAKEHOME/.cargo/bin/chump"
mkdir -p "$FAKEHOME/.local/bin"
cat > "$FAKEHOME/.local/bin/chump" <<'INNER'
#!/usr/bin/env bash
echo "chump 0.0.0-test (localbbbbbbbb built old)"
INNER
chmod +x "$FAKEHOME/.local/bin/chump"

env -u CHUMP_NODE_BIN \
CHUMP_NODE_REPO="$MIRROR" \
NODE_AMBIENT="$AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/logs3" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$GREEN_SHA" \
HOME="$FAKEHOME" \
PATH="$FAKEHOME/.local/bin:$TMP/bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out3.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "shadow-rot run exited $rc: $(cat "$TMP/out3.log")"

CARGO_VER="$("$FAKEHOME/.cargo/bin/chump" --version 2>/dev/null || echo none)"
case "$CARGO_VER" in
    *"${GREEN_SHA:0:12}"*)
        ok "refresh updated the worker-canonical ~/.cargo/bin/chump despite ~/.local/bin on PATH" ;;
    *"stale"*)
        fail "~/.cargo/bin/chump left STALE ($CARGO_VER) — organ refreshed the shadow ~/.local/bin/chump (the closetjunky rot)" ;;
    *)
        fail "unexpected ~/.cargo/bin/chump version: $CARGO_VER" ;;
esac

# ── Test 4 (CREDIBLE-1568/1570): node-refresh installs + verifies the dead-man ─
# RESILIENT-1611's load-aware dead-man was "shipped != installed" — the installer
# existed but nothing in node-refresh called it, so it was code-on-disk on zero
# nodes. node-refresh must now run install-load-aware-deadman.sh EVERY cycle and
# verify chump-load-aware-deadman.timer is active. A mutant that drops that call
# leaves no installed dead-man and no verification event → this test fails.
#
# Self-contained fixture: the installer (and the files it copies) must live IN
# the mirror, because node-refresh resolves it under its REPO_ROOT and
# `converge_mirror_hard_reset` git-resets the mirror (wiping any uncommitted
# seed). So we commit the real deadman files into the mirror + push to origin.
DM_ORIGIN="$TMP/dm-origin.git"
DM_MIRROR="$TMP/dm-mirror"
git init --bare -q "$DM_ORIGIN"
git clone -q "$DM_ORIGIN" "$DM_MIRROR"
git -C "$DM_MIRROR" config user.email test@example.com
git -C "$DM_MIRROR" config user.name "Test"
mkdir -p "$DM_MIRROR/scripts/setup" "$DM_MIRROR/scripts/ops/systemd"
cp "$REPO_ROOT/scripts/setup/install-load-aware-deadman.sh" "$DM_MIRROR/scripts/setup/"
cp "$REPO_ROOT/scripts/ops/load-aware-deadman.sh" "$DM_MIRROR/scripts/ops/"
cp "$REPO_ROOT/scripts/ops/systemd/chump-load-aware-deadman.service" "$DM_MIRROR/scripts/ops/systemd/"
cp "$REPO_ROOT/scripts/ops/systemd/chump-load-aware-deadman.timer" "$DM_MIRROR/scripts/ops/systemd/"
echo "v1" > "$DM_MIRROR/f.txt"
git -C "$DM_MIRROR" add -A
git -C "$DM_MIRROR" commit -q -m "seed deadman organ"
git -C "$DM_MIRROR" push -q origin HEAD:main
DM_GREEN_SHA="$(git -C "$DM_MIRROR" rev-parse HEAD)"

# Stub systemctl: `--user is-active --quiet <timer>` succeeds (dead-man active);
# every other systemctl call (daemon-reload/enable/start/status) is a no-op 0.
mkdir -p "$TMP/dm-bin"
cat > "$TMP/dm-bin/systemctl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == "is-active" ]] && exit 0; done
exit 0
STUB
chmod +x "$TMP/dm-bin/systemctl"
cp "$TMP/bin/cargo" "$TMP/dm-bin/cargo"

DM_HOME="$TMP/dm-home"
mkdir -p "$DM_HOME/.cargo/bin"
DM_AMBIENT="$TMP/dm-ambient.jsonl"
mkdir -p "$TMP/dm-locks"

env -u CHUMP_NODE_BIN \
CHUMP_NODE_REPO="$DM_MIRROR" \
NODE_AMBIENT="$DM_AMBIENT" \
CHUMP_NODE_REFRESH_LOGDIR="$TMP/dm-logs" \
CHUMP_NODE_REFRESH_TEST_GREEN_SHA="$DM_GREEN_SHA" \
HOME="$DM_HOME" \
PATH="$TMP/dm-bin:/usr/bin:/bin" \
    bash "$SCRIPT" > "$TMP/out4.log" 2>&1
rc=$?
[ "$rc" -eq 0 ] || fail "deadman run exited $rc: $(cat "$TMP/out4.log")"

# The installer must have copied the dead-man script into the fake HOME.
if [ -x "$DM_HOME/.local/bin/load-aware-deadman.sh" ]; then
    ok "node-refresh ran install-load-aware-deadman.sh (dead-man installed under HOME)"
else
    fail "node-refresh did NOT run the dead-man installer — load-aware-deadman.sh missing from \$HOME/.local/bin (AC1)"
fi

# And it must have VERIFIED the timer is active (emitting node_deadman_verified).
if grep -q '"kind":"node_deadman_verified"' "$DM_AMBIENT" 2>/dev/null; then
    ok "node-refresh verified chump-load-aware-deadman.timer is active (node_deadman_verified emitted)"
else
    fail "node-refresh did not emit node_deadman_verified — the timer-active verification is missing (AC1)"
fi

# ── Test 5 (CREDIBLE-1609): node-refresh installs chumpd + worker.sh prefers deployed sibling over target/debug ─
if [ -x "$FAKEHOME/.cargo/bin/chumpd" ]; then
    ok "CREDIBLE-1609: node-refresh installed deployed sibling ~/.cargo/bin/chumpd alongside ~/.cargo/bin/chump"
else
    fail "CREDIBLE-1609: node-refresh did not install ~/.cargo/bin/chumpd"
fi

C1609_DIR="$TMP/c1609"
mkdir -p "$C1609_DIR/home/.cargo/bin" "$C1609_DIR/chump-shared-target/debug" "$C1609_DIR/repo/.chump-locks"
git init -q "$C1609_DIR/repo"
cat > "$C1609_DIR/home/.cargo/bin/chump" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$C1609_DIR/home/.cargo/bin/chumpd" <<EOF
#!/usr/bin/env bash
echo "deployed:\$*" > "$C1609_DIR/which-chumpd"
exit 0
EOF
cat > "$C1609_DIR/chump-shared-target/debug/chumpd" <<EOF
#!/usr/bin/env bash
echo "stale-debug:\$*" > "$C1609_DIR/which-chumpd"
exit 0
EOF
chmod +x "$C1609_DIR/home/.cargo/bin/chump" "$C1609_DIR/home/.cargo/bin/chumpd" "$C1609_DIR/chump-shared-target/debug/chumpd"

env -u CHUMPD_BIN -u CHUMP_WORKER_SINGLE_TICK \
    HOME="$C1609_DIR/home" \
    REPO_ROOT="$C1609_DIR/repo" \
    CARGO_TARGET_DIR="$C1609_DIR/chump-shared-target" \
    CHUMP_AMBIENT_FILE="$C1609_DIR/repo/.chump-locks/ambient.jsonl" \
    PATH="$C1609_DIR/home/.cargo/bin:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/dispatch/worker.sh" >/dev/null 2>&1

if grep -q '^deployed:worker$' "$C1609_DIR/which-chumpd" 2>/dev/null; then
    ok "CREDIBLE-1609: worker.sh chose deployed sibling chumpd ahead of chump-shared-target/debug/chumpd"
else
    fail "CREDIBLE-1609: worker.sh did not choose deployed sibling chumpd (got: $(cat "$C1609_DIR/which-chumpd" 2>/dev/null || echo none))"
fi
if grep -q '"kind":"worker_dev_binary"' "$C1609_DIR/repo/.chump-locks/ambient.jsonl" 2>/dev/null; then
    fail "CREDIBLE-1609: worker_dev_binary should not emit when deployed chumpd is used"
else
    ok "CREDIBLE-1609: no worker_dev_binary emitted when deployed sibling chumpd is chosen"
fi

# Now remove deployed chumpd so only the target fallback exists; assert worker_dev_binary emits.
rm -f "$C1609_DIR/home/.cargo/bin/chumpd" "$C1609_DIR/which-chumpd" "$C1609_DIR/repo/.chump-locks/ambient.jsonl"
env -u CHUMPD_BIN -u CHUMP_WORKER_SINGLE_TICK \
    HOME="$C1609_DIR/home" \
    REPO_ROOT="$C1609_DIR/repo" \
    CARGO_TARGET_DIR="$C1609_DIR/chump-shared-target" \
    CHUMP_AMBIENT_FILE="$C1609_DIR/repo/.chump-locks/ambient.jsonl" \
    PATH="$C1609_DIR/home/.cargo/bin:/usr/bin:/bin" \
    bash "$REPO_ROOT/scripts/dispatch/worker.sh" >/dev/null 2>&1

if grep -q '^stale-debug:worker$' "$C1609_DIR/which-chumpd" 2>/dev/null \
   && grep -q '"kind":"worker_dev_binary"' "$C1609_DIR/repo/.chump-locks/ambient.jsonl" 2>/dev/null \
   && grep -q '"reason":"target_fallback"' "$C1609_DIR/repo/.chump-locks/ambient.jsonl" 2>/dev/null; then
    ok "CREDIBLE-1609: target/ fallback emits kind=worker_dev_binary (reason=target_fallback)"
else
    fail "CREDIBLE-1609: target/ fallback did not emit kind=worker_dev_binary (ambient: $(cat "$C1609_DIR/repo/.chump-locks/ambient.jsonl" 2>/dev/null || echo none))"
fi

exit 0
