#!/usr/bin/env bash
# test-resilient-1571-user-scope-no-user.sh — RESILIENT-1571
#
# A systemd --user manager is unprivileged and cannot switch identity, so a
# user-scope unit carrying ANY User=/Group= line dies at spawn with
# "Failed to determine supplementary groups: Operation not permitted"
# (status=216/GROUP) on every tick. chump-node-install.sh places organ units
# into ~/.config/systemd/user via organ_unit_host_rewrite, which used to bake
# (and inject) User=<run-user>; on cuphead that crash-looped 44 organs incl.
# pr-shepherd and ci-health-gate. Depth: adversarial on the rewriter (every
# source-user shape, keep_root, Group=, no [Service] User), plus a sweep of
# every tracked scripts/dispatch/*.service, plus a static check that the
# user-scope placer actually passes scope=user. Gap: does not run systemd.

set -uo pipefail
FAIL=0
ok()   { echo "ok: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
LIB="$ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
NODEINST="$ROOT/scripts/setup/chump-node-install.sh"
[[ -f "$LIB" ]] || { echo "FAIL: lib missing" >&2; exit 1; }
# organ_unit_host_rewrite uses GNU `sed -i`; the static check still runs on
# non-GNU sed, the transform checks run for real on Linux/CI.
if ! sed --version 2>/dev/null | grep -qi gnu; then
  grep -qE 'organ_unit_host_rewrite .*"\$keep" "\$repo" user' "$NODEINST" \
    || { echo "FAIL: chump-node-install.sh no longer passes scope=user" >&2; exit 1; }
  echo "SKIP transforms (non-GNU sed; Linux-deploy-only). static scope=user check ok"
  exit 0
fi
# shellcheck source=/dev/null
source "$LIB"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

mk() { # <file> <extra-service-lines...>
  local f="$1"; shift
  { printf '[Unit]\nDescription=x\n[Service]\n'; printf '%s\n' "$@"; printf 'ExecStart=/bin/true\n'; } > "$f"
}
has_ug() { grep -qE '^(User|Group)=' "$1"; }

# 1. INFRA-8571: a source carrying a baked User= is a host literal and now
# fails the rewrite LOUDLY (the gate is the only path — no silent patch/strip).
# The RESILIENT-1571 invariant still holds for a Group= source (Group= is not a
# host literal, so the rewrite accepts it and the user-scope strip removes it)
# and for a clean no-identity template (the production shape: nothing to strip).
for shape in "User=root" "User=jeff" "User=ubuntu"; do
  mk "$TMP/s.service" "$shape"
  organ_unit_host_rewrite "$TMP/s.service" "$TMP/o.service" ubuntu /home/ubuntu 0 "" user 2>/dev/null \
    && fail "a baked [$shape] source must be refused (host literal), not silently stripped"
done
ok "scope=user: a baked User= source is refused loudly (INFRA-8571), not patched"

for shape in "Group=adm" "Type=oneshot" ""; do
  mk "$TMP/s.service" "$shape"
  organ_unit_host_rewrite "$TMP/s.service" "$TMP/o.service" ubuntu /home/ubuntu 0 "" user || fail "rewrite rc!=0 for [$shape]"
  has_ug "$TMP/o.service" && fail "scope=user left User=/Group= for source shape [$shape]"
done
ok "scope=user: no User=/Group= for Group=/typed/clean (literal-free) sources"

# 2. keep_root=1 must NOT resurrect User= in user scope (clean template source)
mk "$TMP/s.service" "Type=oneshot"
organ_unit_host_rewrite "$TMP/s.service" "$TMP/o.service" ubuntu /home/ubuntu 1 "" user
has_ug "$TMP/o.service" && fail "keep_root=1 in scope=user must not emit User="
ok "scope=user ignores keep_root"

# 3. the rest of the rewrite still happens (HOME / PATH / WorkingDirectory / node.env)
grep -q '^Environment=HOME=/home/ubuntu$' "$TMP/o.service" || fail "user scope lost Environment=HOME"
grep -q '^WorkingDirectory=' "$TMP/o.service" || fail "user scope lost WorkingDirectory"
grep -q '^EnvironmentFile=.*node\.env' "$TMP/o.service" || fail "user scope lost node.env EnvironmentFile"
grep -q '^ExecStart=/bin/true$' "$TMP/o.service" || fail "user scope mangled ExecStart"
ok "scope=user keeps HOME/WorkingDirectory/node.env injection"

# 4. system scope (default + explicit) is unchanged: User injected from a clean
# template (no baked User=), keep_root forces root.
mk "$TMP/s.service" "Type=oneshot"
organ_unit_host_rewrite "$TMP/s.service" "$TMP/o.service" ubuntu /home/ubuntu 0
grep -q '^User=ubuntu$' "$TMP/o.service" || fail "default scope must inject User=ubuntu"
organ_unit_host_rewrite "$TMP/s.service" "$TMP/o.service" ubuntu /home/ubuntu 1 "" system
grep -q '^User=root$' "$TMP/o.service" || fail "system scope keep_root regressed"
mk "$TMP/n.service" "Type=oneshot"
organ_unit_host_rewrite "$TMP/n.service" "$TMP/o.service" ubuntu /home/ubuntu 0
grep -q '^User=ubuntu$' "$TMP/o.service" || fail "system scope no longer injects User="
ok "system scope unchanged (inject, rewrite, keep_root)"

# 5. sweep: every tracked dispatch unit renders User-free in user scope
n=0
for f in "$ROOT"/scripts/dispatch/*.service; do
  [[ -f "$f" ]] || continue
  organ_unit_host_rewrite "$f" "$TMP/sweep.service" ubuntu /home/ubuntu 1 "$ROOT" user || fail "sweep rc!=0 $f"
  has_ug "$TMP/sweep.service" && fail "sweep: $(basename "$f") rendered with User=/Group= in user scope"
  n=$((n+1))
done
ok "sweep: $n tracked dispatch units render User/Group-free in user scope"

# 6. the user-scope placer passes scope=user (static)
grep -qE 'organ_unit_host_rewrite .*"\$keep" "\$repo" user' "$NODEINST" \
  || fail "chump-node-install.sh no longer passes scope=user to organ_unit_host_rewrite"
ok "chump-node-install.sh passes scope=user"

[[ "$FAIL" = 0 ]] && { echo "PASS: test-resilient-1571-user-scope-no-user"; exit 0; }
exit 1
