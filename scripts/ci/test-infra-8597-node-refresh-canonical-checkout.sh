#!/usr/bin/env bash
# scripts/ci/test-infra-8597-node-refresh-canonical-checkout.sh — INFRA-8597 (PHASE-R R5)
#
# Proves install-node-refresh-systemd.sh bakes the node's CANONICAL checkout into
# the rendered units' ExecStart — never the disposable `.claude/worktrees/*`
# linked worktree it may have been invoked from.
#
# LIVE ROOT CAUSE (cuphead, since ~2026-10-17): the installer ran from inside a
# claimed worktree and the old `$(dirname "$0")/..` candidate baked that path:
#   ExecStart=.../.claude/worktrees/infra-8571/scripts/ops/node-refresh-chump.sh
# The worktree was later reaped, so chump-node-refresh.service exited 127 every
# 30 min and the installed binary only moved when the architect chain ran a local
# cargo build --release (ICE risk on a damaged shared target tree).
#
# Fails without INFRA-8597: the pre-change candidate loop resolves
# `$(dirname "$0")/../ops/node-refresh-chump.sh` to the worktree copy, so the
# canonical-path assertion below trips.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
INSTALLER="$REPO_ROOT/scripts/setup/install-node-refresh-systemd.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

[ -f "$INSTALLER" ] || fail "missing installer: $INSTALLER"
bash -n "$INSTALLER" || fail "syntax error in installer"
ok "bash -n passes"

# ── Fixture: a canonical checkout with a linked worktree under .claude/worktrees ──
CANON="$TMP/chump"           # the canonical, durable node checkout
mkdir -p "$CANON"
git init -q "$CANON"
git -C "$CANON" config user.email test@example.com
git -C "$CANON" config user.name "Test"

# Minimal tree the installer resolves + copies of the real installer and the
# three ExecStart targets, so we exercise the shipped resolver logic.
mkdir -p "$CANON/scripts/setup" "$CANON/scripts/ops" "$CANON/scripts/coord"
cp "$INSTALLER" "$CANON/scripts/setup/install-node-refresh-systemd.sh"
for s in scripts/ops/node-refresh-chump.sh scripts/ops/node-script-host-refresh.sh scripts/coord/node-deploy-lag-watchdog.sh; do
    printf '#!/usr/bin/env bash\n: node refresh target stub\n' > "$CANON/$s"
    chmod +x "$CANON/$s"
done
git -C "$CANON" add -A
git -C "$CANON" commit -q -m "fixture"

# The reaped-worktree trap: invoke the installer from INSIDE a linked worktree.
WT="$CANON/.claude/worktrees/infra-test"
git -C "$CANON" worktree add -q "$WT" HEAD 2>/dev/null \
    || { git -C "$CANON" worktree add -q -b infra-test-wt "$WT" HEAD; }
[ -f "$WT/scripts/setup/install-node-refresh-systemd.sh" ] || fail "worktree missing installer copy"
ok "linked worktree created under .claude/worktrees/"

# ── Stub systemctl/loginctl/chump so the installer renders without touching the host ──
STUB="$TMP/bin"
mkdir -p "$STUB"
for c in systemctl loginctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/$c"; chmod +x "$STUB/$c"
done
# No `chump` on PATH → install target falls through to the ~/.local/bin default.

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME"

# Run the installer FROM the worktree, with CHUMP_NODE_REPO UNSET so resolution
# must fall through to the git-common-dir (main worktree) path — the exact
# cuphead condition.
( cd "$WT" && \
  env -u CHUMP_NODE_REPO HOME="$FAKE_HOME" PATH="$STUB:$PATH" \
      bash "$WT/scripts/setup/install-node-refresh-systemd.sh" ) \
  > "$TMP/install.log" 2>&1 \
  || { cat "$TMP/install.log"; fail "installer exited non-zero"; }
ok "installer rendered units from inside a worktree"

UNIT_DIR="$FAKE_HOME/.config/systemd/user"
assert_canonical_unit() {
    local unit="$1"
    local f="$UNIT_DIR/$unit"
    [ -f "$f" ] || fail "$unit not rendered"
    local execline
    execline="$(grep -E '^ExecStart=' "$f" || true)"
    [ -n "$execline" ] || fail "$unit has no ExecStart"
    case "$execline" in
        *".claude/worktrees/"*) fail "$unit ExecStart baked a disposable worktree path: $execline" ;;
    esac
    case "$execline" in
        *"$CANON/scripts/"*) ok "$unit ExecStart points at the canonical checkout" ;;
        *) fail "$unit ExecStart does not point at canonical checkout $CANON: $execline" ;;
    esac
}

assert_canonical_unit chump-node-refresh.service
assert_canonical_unit chump-node-deploy-lag-watchdog.service
assert_canonical_unit chump-script-host-refresh.service

# Belt-and-suspenders: NO rendered unit anywhere may carry a worktree path.
# One direct grep (no pipe into grep -q, which is unsafe under set -o pipefail).
if grep -REq '^(ExecStart|WorkingDirectory|Environment)=.*\.claude/worktrees/' "$UNIT_DIR" 2>/dev/null; then
    fail "a rendered unit carries a .claude/worktrees/ path"
fi
ok "no rendered unit carries a .claude/worktrees/ path"

# INFRA-8597 (R2 repair): the rendered Environment= values must be the RESOLVED
# canonical checkout ($CANON) EXACTLY — never the caller's raw CHUMP_NODE_REPO
# or a relative token. Kills the surviving mutant (renderer wrote the caller's
# raw value into Environment= instead of the resolved CANON_REPO).
assert_env_equals() {
    local unit="$1" key="$2" want="$3"
    local f="$UNIT_DIR/$unit" got
    [ -f "$f" ] || fail "$unit not rendered (cannot check Environment=$key=)"
    got="$(sed -n "s/^Environment=${key}=//p" "$f")"
    [ "$got" = "$want" ] || fail "$unit Environment=$key= is '$got', expected exactly '$want'"
    ok "$unit Environment=$key= equals canonical $want exactly"
}
assert_env_equals chump-node-refresh.service CHUMP_NODE_REPO "$CANON"
assert_env_equals chump-node-deploy-lag-watchdog.service CHUMP_REPO_ROOT "$CANON"

# A RELATIVE CHUMP_NODE_REPO must be rendered as the ABSOLUTE canonical path.
# From cwd=$TMP, `chump` resolves to $TMP/chump == $CANON; the unit must carry
# the absolute $CANON, never the literal relative token "chump". A renderer that
# echoes the caller's raw value would write "chump" and fail here.
HOME_REL="$TMP/home-rel"; mkdir -p "$HOME_REL"
( cd "$TMP" && env CHUMP_NODE_REPO=chump HOME="$HOME_REL" PATH="$STUB:$PATH" \
    bash "$CANON/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/rel.log" 2>&1 \
    || { cat "$TMP/rel.log"; fail "relative CHUMP_NODE_REPO=chump: installer exited non-zero"; }
UNIT_REL="$HOME_REL/.config/systemd/user"
got_rel="$(sed -n 's/^Environment=CHUMP_NODE_REPO=//p' "$UNIT_REL/chump-node-refresh.service" 2>/dev/null)"
[ "$got_rel" = "$CANON" ] \
    || { cat "$TMP/rel.log"; fail "relative CHUMP_NODE_REPO=chump rendered '$got_rel', expected absolute '$CANON'"; }
ok "relative CHUMP_NODE_REPO=chump renders the absolute canonical $CANON"

# ─────────────────────────────────────────────────────────────────────────────
# REFUSAL-PATH CASES (INFRA-8597 PR #5606 repair). Each must FAIL under the
# matching deliberate break so the reviewer's surviving mutants die:
#   M3 — existence check removed from assert_canonical_path   → killed by (d)
#   M5 — $0-relative fallback reintroduced in the resolver    → killed by (c)
#   M6 — worktree check removed from assert_canonical_path    → killed by (a)
# plus the blocking-#1 silent-fall-through fix → (b), and the blocking-#3
# no-secret-in-unit fix → (e).
# ─────────────────────────────────────────────────────────────────────────────

# (a) M6: from the worktree with CHUMP_NODE_REPO pointing AT the worktree, no
#     rendered unit may bake a .claude/worktrees/ path into ExecStart,
#     WorkingDirectory OR Environment. The installer refuses (FATAL exit 1,
#     assert_canonical_path's worktree guard). Removing that guard (M6) renders
#     the worktree path + exits 0 → both assertions below fire.
HOME_A="$TMP/home-a"; mkdir -p "$HOME_A"
( cd "$WT" && env CHUMP_NODE_REPO="$WT" HOME="$HOME_A" PATH="$STUB:$PATH" \
    bash "$WT/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/a.log" 2>&1
rc_a=$?
UNIT_A="$HOME_A/.config/systemd/user"
# One direct grep (no pipe into grep -q, which is unsafe under set -o pipefail).
if grep -REq '^(ExecStart|WorkingDirectory|Environment)=.*\.claude/worktrees/' "$UNIT_A" 2>/dev/null; then
    cat "$TMP/a.log"; fail "(a) a rendered unit baked a .claude/worktrees/ path from CHUMP_NODE_REPO=\$WT"
fi
[ "$rc_a" -eq 1 ] || { cat "$TMP/a.log"; fail "(a) installer must refuse with exit 1 when CHUMP_NODE_REPO is a worktree; got $rc_a"; }
grep -q 'disposable worktree path' "$TMP/a.log" || { cat "$TMP/a.log"; fail "(a) expected assert_canonical_path worktree FATAL in output"; }
ok "(a) worktree CHUMP_NODE_REPO refused (exit 1 + FATAL); no worktree path in ExecStart/WorkingDirectory/Environment"

# (b) blocking #1: a set-but-missing CHUMP_NODE_REPO must stop with exit 1, not
#     silently fall through to the git-common-dir / well-known resolution (which
#     from the worktree would resolve canonically and exit 0).
HOME_B="$TMP/home-b"; mkdir -p "$HOME_B"
( cd "$WT" && env CHUMP_NODE_REPO="/nonexistent/chump" HOME="$HOME_B" PATH="$STUB:$PATH" \
    bash "$WT/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/b.log" 2>&1
rc_b=$?
[ "$rc_b" -eq 1 ] || { cat "$TMP/b.log"; fail "(b) CHUMP_NODE_REPO=/nonexistent must exit 1; got $rc_b"; }
ok "(b) CHUMP_NODE_REPO=/nonexistent exits 1 (no silent fall-through)"

# (c) M5: a non-git copy with an empty HOME — the git-common-dir resolver fails
#     (not a repo) and the well-known checkouts don't exist (empty HOME), so the
#     installer MUST refuse and write no units. A reintroduced $0-relative
#     fallback (M5) resolves to $COPY (which HAS the scripts) and renders units,
#     making the "no units / non-zero" assertions below fail.
COPY="$TMP/nogit"
mkdir -p "$COPY/scripts/setup" "$COPY/scripts/ops" "$COPY/scripts/coord"
cp "$INSTALLER" "$COPY/scripts/setup/install-node-refresh-systemd.sh"
for s in scripts/ops/node-refresh-chump.sh scripts/ops/node-script-host-refresh.sh scripts/coord/node-deploy-lag-watchdog.sh; do
    printf '#!/usr/bin/env bash\n: node refresh target stub\n' > "$COPY/$s"; chmod +x "$COPY/$s"
done
HOME_C="$TMP/home-c"; mkdir -p "$HOME_C"
( cd "$COPY" && env -u CHUMP_NODE_REPO -u CHUMP_SCRIPT_HOST_REPO HOME="$HOME_C" PATH="$STUB:$PATH" \
    bash "$COPY/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/c.log" 2>&1
rc_c=$?
[ "$rc_c" -ne 0 ] || { cat "$TMP/c.log"; fail "(c) non-git copy with empty HOME must exit non-zero; got 0"; }
UNIT_C="$HOME_C/.config/systemd/user"
if [ -d "$UNIT_C" ] && [ -n "$(ls -A "$UNIT_C" 2>/dev/null)" ]; then
    cat "$TMP/c.log"; fail "(c) non-git copy with empty HOME wrote unit files: $(ls "$UNIT_C")"
fi
ok "(c) non-git copy + empty HOME refuses and writes no unit files"

# (d) M3: a canonical git checkout missing one referenced ExecStart script
#     (node-refresh-chump.sh) must trip assert_canonical_path's existence guard
#     (FATAL exit 1). Removing that guard (M3) renders a unit whose ExecStart
#     points at a non-existent script and exits 0.
MISS="$TMP/missing"
mkdir -p "$MISS/scripts/setup" "$MISS/scripts/ops" "$MISS/scripts/coord"
git init -q "$MISS"
git -C "$MISS" config user.email test@example.com
git -C "$MISS" config user.name "Test"
cp "$INSTALLER" "$MISS/scripts/setup/install-node-refresh-systemd.sh"
# Intentionally OMIT scripts/ops/node-refresh-chump.sh (the primary ExecStart target).
printf '#!/usr/bin/env bash\n: stub\n' > "$MISS/scripts/ops/node-script-host-refresh.sh"
printf '#!/usr/bin/env bash\n: stub\n' > "$MISS/scripts/coord/node-deploy-lag-watchdog.sh"
chmod +x "$MISS/scripts/ops/node-script-host-refresh.sh" "$MISS/scripts/coord/node-deploy-lag-watchdog.sh"
git -C "$MISS" add -A
git -C "$MISS" commit -q -m "fixture (missing node-refresh-chump.sh)"
HOME_D="$TMP/home-d"; mkdir -p "$HOME_D"
( cd "$MISS" && env CHUMP_NODE_REPO="$MISS" HOME="$HOME_D" PATH="$STUB:$PATH" \
    bash "$MISS/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/d.log" 2>&1
rc_d=$?
[ "$rc_d" -ne 0 ] || { cat "$TMP/d.log"; fail "(d) missing ExecStart script must trip the canonical-path assertion (non-zero); got 0"; }
grep -q 'non-existent path' "$TMP/d.log" || { cat "$TMP/d.log"; fail "(d) expected assert_canonical_path existence FATAL in output"; }
ok "(d) checkout missing node-refresh-chump.sh trips the existence assertion"

# (e) blocking #3: with GH_TOKEN (and GITHUB_TOKEN) set in the environment, NO
#     rendered unit may contain GH_TOKEN. node-refresh-chump.sh reads the token
#     from ~/.chump/providers.env at runtime instead. Reintroducing any
#     Environment=GH_TOKEN= line makes the grep below fire.
HOME_E="$TMP/home-e"; mkdir -p "$HOME_E"
( cd "$WT" && env -u CHUMP_NODE_REPO GH_TOKEN="ghp_SECRETTESTTOKEN" GITHUB_TOKEN="ghp_SECRETTESTTOKEN" \
    HOME="$HOME_E" PATH="$STUB:$PATH" \
    bash "$WT/scripts/setup/install-node-refresh-systemd.sh" ) > "$TMP/e.log" 2>&1
rc_e=$?
[ "$rc_e" -eq 0 ] || { cat "$TMP/e.log"; fail "(e) installer should render from worktree (git-common-dir path); got $rc_e"; }
UNIT_E="$HOME_E/.config/systemd/user"
if grep -REn 'GH_TOKEN|ghp_SECRETTESTTOKEN' "$UNIT_E" 2>/dev/null; then
    fail "(e) a rendered unit leaked GH_TOKEN into a systemd unit"
fi
ok "(e) GH_TOKEN present in env but never written into any rendered unit"

echo "ALL PASS — install-node-refresh-systemd.sh renders canonical ExecStart paths (INFRA-8597)"
