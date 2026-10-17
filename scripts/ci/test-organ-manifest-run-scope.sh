#!/usr/bin/env bash
# scripts/ci/test-organ-manifest-run-scope.sh — INFRA-8194 (Phase R, R5)
#
# organ-manifest.txt gains a `run-scope=user|system|any` field so an installer
# only places what the typed Host enum's manager scope allows. Proves:
#   1. organ_manifest_parse: the 8th (optional) nameref captures run-scope=,
#      omitted defaults to `any`; the 5/6/7-arg call signatures still work.
#   2. organ_run_scope_matches: any/empty match everything; user|system match
#      only themselves.
#   3. organ-reconcile.sh (system scope) skips a run-scope=user line with a
#      logged reason and never hands it to systemctl, while a run-scope=system
#      line and an untagged line are still reconciled (no regression).
#   4. The real manifest tags chump-organ-deploy.timer run-scope=system (a
#      root-only organ a --user bring-up must skip).
# Hermetic: stub systemctl, no root, platform pinned to systemd so it also runs
# on a macOS dev box.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ok $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-organ-manifest-run-scope.sh (INFRA-8194) ==="
bash -n "$LIB" || fail "organ-manifest-lib.sh bash -n"
bash -n "$RECONCILE" || fail "organ-reconcile.sh bash -n"
# shellcheck source=/dev/null
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

M="$TMP/manifest.txt"
cat > "$M" <<'EOF'
enabled  chump-plain.service       role=brain
enabled  chump-root-only.timer     role=janitor run-scope=system
enabled  chump-user-only.timer     role=data run-scope=user  # run-scope=system in a comment must not count
paging_off  chump-pager.service
EOF

# ── 1. parse ────────────────────────────────────────────────────────────────
OFF=(); EN=(); declare -A ROLE REQ PLAT NODE SCOPE
organ_manifest_parse "$M" OFF EN ROLE REQ || fail "5-arg parse must still succeed"
[[ "${#EN[@]}" == 3 ]] || fail "5-arg parse must see 3 enabled lines; got ${#EN[@]}"
organ_manifest_parse "$M" OFF EN ROLE REQ PLAT NODE || fail "7-arg parse must still succeed"
organ_manifest_parse "$M" OFF EN ROLE REQ PLAT NODE SCOPE || fail "8-arg parse must succeed"
[[ "${SCOPE[chump-plain.service]}" == any ]] || fail "omitted run-scope= must default to any; got '${SCOPE[chump-plain.service]}'"
[[ "${SCOPE[chump-root-only.timer]}" == system ]] || fail "run-scope=system not captured"
[[ "${SCOPE[chump-user-only.timer]}" == user ]] || fail "trailing comment must not overwrite run-scope=user; got '${SCOPE[chump-user-only.timer]}'"
[[ "${PLAT[chump-root-only.timer]}" == systemd ]] || fail "platforms= default must be unaffected by run-scope="
pass "organ_manifest_parse: 8th nameref captures run-scope=, defaults to any, comment-safe, older signatures intact"

# ── 2. matcher ──────────────────────────────────────────────────────────────
organ_run_scope_matches any user && organ_run_scope_matches any system \
  && organ_run_scope_matches "" user || fail "any/empty must match every scope"
organ_run_scope_matches system system && organ_run_scope_matches user user || fail "a scope must match itself"
organ_run_scope_matches system user && fail "run-scope=system must NOT match a user install"
organ_run_scope_matches user system && fail "run-scope=user must NOT match a system install"
[[ "$(CHUMP_ORGAN_MANIFEST_RUN_SCOPE=user organ_current_run_scope)" == user ]] || fail "CHUMP_ORGAN_MANIFEST_RUN_SCOPE override ignored"
pass "organ_run_scope_matches + organ_current_run_scope override"

# ── 3. reconcile (system scope) ─────────────────────────────────────────────
STUB="$TMP/systemctl"; CALLS="$TMP/calls.log"; ACTIVE="$TMP/active.txt"; : > "$ACTIVE"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
  is-active) grep -qxF "\${@: -1}" "$ACTIVE" && exit 0 || exit 3 ;;
  enable) echo "\${@: -1}" >> "$ACTIVE"; exit 0 ;;
  show) echo "ExecStart=/bin/true"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB"
: > "$CALLS"
out="$(CHUMP_ORGAN_MANIFEST="$M" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST_PLATFORM=systemd \
  NODE_AMBIENT="$TMP/ambient.jsonl" \
  bash "$RECONCILE" --check 2>&1)"
echo "$out" | grep -q "skip chump-user-only.timer: run-scope=user" \
  || fail "reconcile must log a run-scope skip for the user-only organ; got: $out"
grep -q "chump-user-only" "$CALLS" && fail "run-scope=user organ must never reach systemctl; calls: $(cat "$CALLS")"
echo "$out" | grep -q "chump-root-only.timer" || fail "run-scope=system organ must still be reconciled at system scope; got: $out"
echo "$out" | grep -q "chump-plain.service" || fail "untagged organ must still be reconciled (no regression); got: $out"
pass "organ-reconcile.sh skips run-scope=user with a logged reason, keeps system + untagged organs"

# ── 4. the real manifest ────────────────────────────────────────────────────
grep -Eq '^enabled[[:space:]]+chump-organ-deploy\.timer[[:space:]].*run-scope=system' "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
  || fail "chump-organ-deploy.timer must be tagged run-scope=system (root-only organ)"
pass "real manifest tags the root-only chump-organ-deploy.timer run-scope=system"

echo "ALL PASS"
