#!/usr/bin/env bash
# test-node-admission-ceiling.sh — RESILIENT-1604
#
# The installer side of the node admission ceiling, hermetic (stubbed nproc and
# pgrep on PATH, throwaway HOME / node.env, no systemd, no network):
#
#   A. scripts/setup/lib/node-admission-ceiling.sh: default = max(1, nproc/2)
#   B. chump_ensure_admission_ceiling writes both keys only when absent, is
#      idempotent (second run byte-identical), never rewrites a present key,
#      and refuses to create a node.env that does not exist
#   C. chump-node-install.sh write_node_env() writes the ceiling into a fresh
#      node.env and carries an operator-tuned value across a re-install
#   D. node-converge.sh re-asserts it through the same primitive
#   E. fleet-doctor-strict.sh check_admission_ceiling goes RED when the live
#      claude -p or cargo/rustc count exceeds the ceiling, PASS at or under it,
#      honoring env > node.env > nproc precedence

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LIB="$REPO_ROOT/scripts/setup/lib/node-admission-ceiling.sh"
INSTALLER="$REPO_ROOT/scripts/setup/chump-node-install.sh"
CONVERGE="$REPO_ROOT/scripts/ops/node-converge.sh"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
for f in "$LIB" "$INSTALLER" "$CONVERGE" "$DOCTOR"; do
    [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

TMP="$(mktemp -d "${TMPDIR:-/tmp}/chump-admission-ceiling.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

# Stubs: nproc prints $STUB_NPROC; pgrep -fc prints $STUB_CLAUDE for the
# `claude -p` pattern and $STUB_CARGO for the cargo/rustc pattern.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/nproc" <<'STUB'
#!/usr/bin/env bash
echo "${STUB_NPROC:-4}"
STUB
cat > "$TMP/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
pat="${*: -1}"
case "$pat" in
    "claude -p") n="${STUB_CLAUDE:-0}" ;;
    *cargo*) n="${STUB_CARGO:-0}" ;;
    *) n=0 ;;
esac
echo "$n"
[ "$n" -gt 0 ]
STUB
chmod +x "$TMP/bin/nproc" "$TMP/bin/pgrep"
export PATH="$TMP/bin:$PATH"
unset CHUMP_MAX_CONCURRENT_CLAUDE CHUMP_MAX_CONCURRENT_CARGO_JOBS

echo "=== RESILIENT-1604: node admission ceiling (installer + doctor) ==="

# ── A. formula ──────────────────────────────────────────────────────────────
# shellcheck source=scripts/setup/lib/node-admission-ceiling.sh disable=SC1091
. "$LIB"
for pair in 4:2 1:1 2:1 5:2 16:8; do
    cores="${pair%%:*}" want="${pair##*:}"
    got="$(STUB_NPROC="$cores" chump_admission_default_ceiling)"
    if [ "$got" = "$want" ]; then ok "A nproc=$cores -> ceiling $got"; else ko "A nproc=$cores -> $got (want $want)"; fi
done

# ── B. ensure: write-when-absent, idempotent, no rewrite ────────────────────
NE="$TMP/b/node.env"
mkdir -p "$TMP/b"
printf 'export CHUMP_STATE_DIR=/x\nexport CHUMP_NODE_MODE=work-ready' > "$NE" # no trailing newline
out="$(STUB_NPROC=4 chump_ensure_admission_ceiling "$NE")"; rc=$?
if [ "$rc" -eq 10 ] && grep -qx 'export CHUMP_MAX_CONCURRENT_CLAUDE=2' "$NE" \
    && grep -qx 'export CHUMP_MAX_CONCURRENT_CARGO_JOBS=2' "$NE" \
    && grep -qx 'export CHUMP_NODE_MODE=work-ready' "$NE"; then
    ok "B absent keys appended as nproc/2 (rc=10), last line not glued"
else
    ko "B first ensure: rc=$rc out=$out file=$(cat "$NE")"
fi
before="$(cksum < "$NE")"
out="$(STUB_NPROC=16 chump_ensure_admission_ceiling "$NE")"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(cksum < "$NE")" = "$before" ]; then
    ok "B second ensure is a no-op (rc=0, byte-identical, even with nproc changed)"
else
    ko "B second ensure changed the file: rc=$rc out=$out"
fi
NE2="$TMP/b/tuned.env"
printf 'CHUMP_MAX_CONCURRENT_CLAUDE="3" # operator\n' > "$NE2"
STUB_NPROC=4 chump_ensure_admission_ceiling "$NE2" >/dev/null; rc=$?
if [ "$rc" -eq 10 ] && [ "$(grep -c CHUMP_MAX_CONCURRENT_CLAUDE "$NE2")" -eq 1 ] \
    && [ "$(_chump_env_file_int "$NE2" CHUMP_MAX_CONCURRENT_CLAUDE)" = 3 ] \
    && grep -qx 'export CHUMP_MAX_CONCURRENT_CARGO_JOBS=2' "$NE2"; then
    ok "B present (operator-tuned) key kept; only the absent one written"
else
    ko "B tuned key handling: rc=$rc file=$(cat "$NE2")"
fi
STUB_NPROC=4 chump_ensure_admission_ceiling "$TMP/b/missing.env" >/dev/null; rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$TMP/b/missing.env" ]; then
    ok "B no node.env -> rc=2, nothing created (not an installed node)"
else
    ko "B missing node.env: rc=$rc"
fi

# ── C. installer write_node_env ─────────────────────────────────────────────
# shellcheck disable=SC2016  # the single-quoted script is expanded by the child bash
run_write_node_env() {
    local home="$1"
    env -u CHUMP_STATE_DB -u CHUMP_NODE_REPO -u CHUMP_MAX_CONCURRENT_CLAUDE \
        -u CHUMP_MAX_CONCURRENT_CARGO_JOBS \
        HOME="$home" CHUMP_NODE_DIR="$home/node" CHUMP_STATE_DIR="$home/.chump" \
        STUB_NPROC=4 INSTALLER="$INSTALLER" \
        bash -c 'set --; . "$INSTALLER" >/dev/null 2>&1; write_node_env >/dev/null 2>&1'
}
H="$TMP/c-home"
mkdir -p "$H/node/repo" "$H/.chump"
run_write_node_env "$H"
NEC="$H/.chump/node.env"
if grep -qx 'export CHUMP_MAX_CONCURRENT_CLAUDE=2' "$NEC" 2>/dev/null \
    && grep -qx 'export CHUMP_MAX_CONCURRENT_CARGO_JOBS=2' "$NEC" 2>/dev/null \
    && grep -q '^export CHUMP_STATE_DB=' "$NEC"; then
    ok "C fresh install: node.env carries worker count + cargo ceiling (nproc=4 -> 2/2)"
else
    ko "C fresh install node.env: $(cat "$NEC" 2>/dev/null)"
fi
sed -i.bak 's/^export CHUMP_MAX_CONCURRENT_CLAUDE=2$/export CHUMP_MAX_CONCURRENT_CLAUDE=1/' "$NEC"
run_write_node_env "$H"
if grep -qx 'export CHUMP_MAX_CONCURRENT_CLAUDE=1' "$NEC" \
    && [ "$(grep -c '^export CHUMP_MAX_CONCURRENT_CLAUDE=' "$NEC")" -eq 1 ] \
    && [ "$(grep -c '^export CHUMP_MAX_CONCURRENT_CARGO_JOBS=' "$NEC")" -eq 1 ]; then
    ok "C re-install keeps the tuned ceiling (1) and writes no duplicate keys"
else
    ko "C re-install: $(grep CHUMP_MAX_CONCURRENT "$NEC")"
fi

# ── D. converge wiring (structural: converge needs a live checkout + fetch) ─
conv="$(grep -n 'node-admission-ceiling.sh\|chump_ensure_admission_ceiling' "$CONVERGE" || true)"
if [ "$(printf '%s\n' "$conv" | grep -c .)" -ge 2 ]; then
    ok "D node-converge.sh sources the lib and calls chump_ensure_admission_ceiling"
else
    ko "D node-converge.sh is not wired to the ceiling lib"
fi
if bash -n "$CONVERGE" && bash -n "$INSTALLER"; then ok "D converge + installer parse"; else ko "D syntax error"; fi

# ── E. fleet-doctor check_admission_ceiling ────────────────────────────────
# shellcheck disable=SC2016  # the single-quoted script is expanded by the child bash
doctor() { # <claude> <cargo> [env assignments...] -> prints "<status>|<detail>"
    local cl="$1" cg="$2"
    shift 2
    env STUB_CLAUDE="$cl" STUB_CARGO="$cg" STUB_NPROC=4 HOME="$TMP/e-home" \
        CHUMP_STATE_DIR="$TMP/e-home/.chump" FLEET_DOCTOR_SOURCED=1 DOCTOR="$DOCTOR" "$@" \
        bash -c '. "$DOCTOR"; check_admission_ceiling; printf "%s|%s\n" "${STATUSES[0]}" "${DETAILS[0]}"'
}
mkdir -p "$TMP/e-home/.chump"
printf 'export CHUMP_MAX_CONCURRENT_CLAUDE=2\nexport CHUMP_MAX_CONCURRENT_CARGO_JOBS=2\n' > "$TMP/e-home/.chump/node.env"
r="$(doctor 2 2)"
case "$r" in pass\|*"claude -p 2/2"*) ok "E at the ceiling (2/2, 2/2) -> PASS" ;; *) ko "E at ceiling: $r" ;; esac
r="$(doctor 8 1)"
case "$r" in fail\|*"claude -p 8/2"*) ok "E cuphead receipt shape (8 claude -p on ceiling 2) -> RED" ;; *) ko "E claude over: $r" ;; esac
r="$(doctor 1 9)"
case "$r" in fail\|*"cargo/rustc 9/2"*) ok "E 9 cargo/rustc on ceiling 2 -> RED" ;; *) ko "E cargo over: $r" ;; esac
r="$(doctor 3 0 CHUMP_MAX_CONCURRENT_CLAUDE=5)"
case "$r" in pass\|*"claude -p 3/5"*) ok "E process env overrides node.env (3 on ceiling 5) -> PASS" ;; *) ko "E env precedence: $r" ;; esac
rm -f "$TMP/e-home/.chump/node.env"
r="$(doctor 3 0)"
case "$r" in fail\|*"claude -p 3/2"*) ok "E no node.env -> nproc default (4 -> 2): 3 running -> RED" ;; *) ko "E nproc default: $r" ;; esac

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
