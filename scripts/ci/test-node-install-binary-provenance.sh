#!/usr/bin/env bash
# test-node-install-binary-provenance.sh
#
# Regression test for the COTG node-install BINARY-phase provenance gate
# (ribbon: bare box -> one command -> outcome). Guards two properties of
# scripts/setup/chump-node-install.sh:
#
#   1. host_target_triple maps this host to the cargo triple the release
#      workflow publishes, and refuses android/unknown hosts (they build).
#   2. binary_provenance_ok ACCEPTS a release-sha-verified or built-from-HEAD
#      binary and REJECTS a foreign / stale / tampered one — the check that
#      kills the old freeload false-pass (any on-PATH `chump` reported
#      INSTALLED without build or verification).
#
# Network-free + deterministic: it sources the installer (whose top-level run
# is guarded by BASH_SOURCE!=$0) and drives the functions directly with fake
# binaries. Safe to run anywhere; touches only a private temp dir.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
[ -f "$INSTALLER" ] || { echo "FAIL: installer not found: $INSTALLER"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-prov-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export CHUMP_NODE_DIR="$TMP/node"
export CHUMP_STATE_DIR="$TMP/state"
mkdir -p "$CHUMP_NODE_DIR/bin"

fails=0
pass(){ printf '  ok   %s\n' "$*"; }
fail(){ printf '  FAIL %s\n' "$*"; fails=$((fails+1)); }

# Source the installer without triggering an install run (BASH_SOURCE guard).
# Clear positional params first so its arg parser sees none.
set --
# shellcheck disable=SC1090
. "$INSTALLER"

# ---- 1. host_target_triple ----
ARCH=x86_64 OS=Linux  HOST_KIND=linux-systemd t="$(host_target_triple)" \
  && [ "$t" = "x86_64-unknown-linux-gnu" ] && pass "triple linux/x86_64 -> $t" || fail "triple linux/x86_64 (got '${t:-}')"
ARCH=aarch64 OS=Linux  HOST_KIND=linux-systemd t="$(host_target_triple)" \
  && [ "$t" = "aarch64-unknown-linux-gnu" ] && pass "triple linux/aarch64 -> $t" || fail "triple linux/aarch64 (got '${t:-}')"
ARCH=arm64 OS=Darwin HOST_KIND=macos t="$(host_target_triple)" \
  && [ "$t" = "aarch64-apple-darwin" ] && pass "triple macos/arm64 -> $t" || fail "triple macos/arm64 (got '${t:-}')"
if ARCH=aarch64 OS=Linux HOST_KIND=termux host_target_triple >/dev/null 2>&1; then
  fail "termux should have no release triple (must build from source)"
else
  pass "termux correctly has no release triple"
fi

# ---- 2. binary_provenance_ok ----
BIN="$CHUMP_NODE_DIR/bin/chump"   # what the installer verifies

# (a) foreign binary: executable, no provenance marker, version SHA unrelated
#     to any repo HEAD -> MUST be rejected (the false-pass case).
cat > "$BIN" <<'EOF'
#!/usr/bin/env bash
echo "chump 9.9.9 (deadbeefcafe built 1999-01-01)"
EOF
chmod +x "$BIN"
rm -f "$BIN.provenance"
if binary_provenance_ok "$BIN"; then fail "foreign binary was ACCEPTED (false-pass not fixed)"
else pass "foreign binary rejected (no provenance, unrelated SHA)"; fi

# (b) valid release provenance: marker records the binary's own sha256 -> ACCEPT.
realsha="$(sha256_hex "$BIN")"
printf 'source=release\ntag=v0.1.2\ntriple=x86_64-unknown-linux-gnu\nbinsha256=%s\n' "$realsha" > "$BIN.provenance"
if binary_provenance_ok "$BIN"; then pass "release-sha-verified binary accepted"
else fail "release-sha-verified binary was rejected"; fi

# (c) tampered release binary: sha no longer matches recorded binsha256 -> REJECT.
echo "# tampered" >> "$BIN"
if binary_provenance_ok "$BIN"; then fail "tampered release binary was ACCEPTED (sha not enforced)"
else pass "tampered release binary rejected (sha mismatch)"; fi

# (d) built-from-repo-HEAD: version SHA is a prefix of the repo's real HEAD.
head_full="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '')"
if [ -n "$head_full" ]; then
  short="${head_full:0:12}"
  mkdir -p "$CHUMP_NODE_DIR/repo"
  # Point NODE_DIR/repo at this real checkout so the HEAD lookup resolves.
  rm -rf "$CHUMP_NODE_DIR/repo"; ln -s "$REPO_ROOT" "$CHUMP_NODE_DIR/repo"
  cat > "$BIN" <<EOF
#!/usr/bin/env bash
echo "chump 0.2.0 ($short built 2026-08-27)"
EOF
  chmod +x "$BIN"; rm -f "$BIN.provenance"
  if binary_provenance_ok "$BIN"; then pass "built-from-HEAD binary accepted (SHA prefixes HEAD)"
  else fail "built-from-HEAD binary rejected (SHA $short vs HEAD $head_full)"; fi
  rm -f "$CHUMP_NODE_DIR/repo"
else
  pass "skip built-from-HEAD case (not in a git checkout)"
fi

# ---- 3. ensure_chumpd_binary (INFRA-8582 AC1) ----
CHUMPD_BIN="$CHUMP_NODE_DIR/bin/chumpd"
rm -f "$CHUMPD_BIN"
dry_out="$(DRY=1 ensure_chumpd_binary)"
if printf '%s\n' "$dry_out" | grep -qF "DRY: install chumpd alongside chump -> $CHUMPD_BIN"; then
  pass "ensure_chumpd_binary --dry-run renders install -> $CHUMPD_BIN"
else
  fail "ensure_chumpd_binary --dry-run did not render expected line (got '$dry_out')"
fi

FAKE_TARGET="$TMP/shared-target"
mkdir -p "$FAKE_TARGET/release"
cat > "$FAKE_TARGET/release/chumpd" <<'EOF'
#!/usr/bin/env bash
echo "chumpd 0.2.0"
EOF
chmod +x "$FAKE_TARGET/release/chumpd"
DRY=0 CARGO_TARGET_DIR="$FAKE_TARGET" ensure_chumpd_binary >/dev/null
if [ -x "$CHUMPD_BIN" ]; then
  pass "ensure_chumpd_binary installs executable chumpd alongside chump ($CHUMPD_BIN)"
else
  fail "ensure_chumpd_binary did not install executable chumpd at $CHUMPD_BIN"
fi

if grep -qE 'CHUMP_AUX_MERGE_BINS=.*chumpd' "$REPO_ROOT/scripts/setup/refresh-runner-binary.sh"; then
  pass "refresh-runner-binary.sh includes chumpd in CHUMP_AUX_MERGE_BINS"
else
  fail "refresh-runner-binary.sh missing chumpd in CHUMP_AUX_MERGE_BINS"
fi

echo
if [ "$fails" -eq 0 ]; then echo "PASS: binary provenance gate holds ($0)"; exit 0
else echo "FAIL: $fails assertion(s) failed"; exit 1; fi
