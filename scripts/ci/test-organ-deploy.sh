#!/usr/bin/env bash
# test-organ-deploy.sh — RESILIENT-374. Verifies the root-privileged self-deploy
# organ: non-root is a non-fatal no-op that never touches systemd, the deploy
# path invokes install-helsinki-atc.sh --auto, and the keep-root exemption +
# manifest row that keep the organ itself User=root are in place.
set -uo pipefail
FAIL=0
ok()   { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SUT="$ROOT/scripts/ops/organ-deploy.sh"
[ -x "$SUT" ] || fail "organ-deploy.sh missing or not executable"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CALLLOG="$TMP/calls.log"; : > "$CALLLOG"
cat > "$TMP/installer.sh" <<'EOS'
#!/usr/bin/env bash
printf 'INSTALLER_CALLED %s\n' "$*" >> "$CALLLOG"
EOS
chmod +x "$TMP/installer.sh"

# id shim forcing non-root regardless of who runs the test (some sandboxes = root)
mkdir -p "$TMP/bin"
cat > "$TMP/bin/id" <<'EOS'
#!/usr/bin/env bash
[ "${1:-}" = "-u" ] && { echo 1000; exit 0; }
exec /usr/bin/id "$@"
EOS
chmod +x "$TMP/bin/id"

# 1. non-root: exit 0, non-fatal, does NOT call the installer
out="$(CALLLOG="$CALLLOG" PATH="$TMP/bin:$PATH" \
      CHUMP_ORGAN_DEPLOY_INSTALLER="$TMP/installer.sh" \
      CHUMP_REPO_ROOT="$ROOT" bash "$SUT" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "non-root must exit 0 (non-fatal), got $rc"
grep -qi "not root" <<<"$out" || fail "expected not-root message, got: $out"
[ ! -s "$CALLLOG" ] || fail "non-root must NOT invoke installer, got: $(cat "$CALLLOG")"
ok "non-root: non-fatal no-op, never invokes the privileged deploy"

# 2. deploy path (allow-nonroot + stubs): invokes install-helsinki-atc --auto
: > "$CALLLOG"
out="$(CALLLOG="$CALLLOG" \
      CHUMP_ORGAN_DEPLOY_ALLOW_NONROOT=1 \
      CHUMP_ORGAN_DEPLOY_INSTALLER="$TMP/installer.sh" \
      CHUMP_ORGAN_DEPLOY_SYSTEMCTL_BIN=true \
      CHUMP_REPO_ROOT="$ROOT" bash "$SUT" 2>&1)"; rc=$?
grep -q "INSTALLER_CALLED --auto" "$CALLLOG" \
  || fail "deploy path must call installer with --auto, got: $(cat "$CALLLOG")"
grep -q "post-deploy manifest audit" <<<"$out" \
  || fail "expected post-deploy audit line, got: $out"
ok "deploy path: invokes install-helsinki-atc.sh --auto + runs audit"

# 3. keep-root exemption + manifest row present (the wiring that keeps the organ root)
grep -q "_KEEP_ROOT_ORGANS" "$ROOT/scripts/setup/install-helsinki-atc.sh" \
  || fail "install-helsinki-atc.sh must define _KEEP_ROOT_ORGANS (keep-root exemption)"
grep -qE '^enabled[[:space:]]+chump-organ-deploy\.timer' "$ROOT/scripts/ops/organ-manifest.txt" \
  || fail "organ-manifest.txt must declare chump-organ-deploy.timer enabled"
[ -f "$ROOT/scripts/dispatch/chump-organ-deploy.service" ] || fail "missing chump-organ-deploy.service"
# INFRA-8194 (R5 slice 2): the unit is a placeholder template and carries NO
# User= literal; root is declared by NAME in both renderers' keep-root sets
# (the installer map above, and chump_provision::KEEP_ROOT_UNITS, whose
# keep_root_units_render_user_root_at_system_scope_only test proves the
# rendered system-scope unit says User=root).
grep -q "^User=" "$ROOT/scripts/dispatch/chump-organ-deploy.service" \
  && fail "chump-organ-deploy.service must not bake a User= literal (the renderer injects User=root)"
grep -qE '\[chump-organ-deploy\.service\]=1' "$ROOT/scripts/setup/install-helsinki-atc.sh" \
  || fail "install-helsinki-atc.sh _KEEP_ROOT_ORGANS must list chump-organ-deploy.service"
grep -q '"chump-organ-deploy.service"' "$ROOT/crates/chump-provision/src/lib.rs" \
  || fail "chump_provision::KEEP_ROOT_UNITS must list chump-organ-deploy.service"
ok "keep-root exemption (installer + typed renderer) + manifest row present; unit carries no User= literal"

if [ "$FAIL" -eq 0 ]; then echo "PASS test-organ-deploy"; else echo "FAILED test-organ-deploy"; exit 1; fi
