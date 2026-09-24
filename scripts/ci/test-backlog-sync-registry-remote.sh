#!/usr/bin/env bash
# test-backlog-sync-registry-remote.sh — registry privacy contract for
# scripts/coord/backlog-sync.sh.
#
# Proves, on throwaway fixture repos only:
#   1. writer with a `registry` remote publishes state.sql THERE and leaves the
#      code repo's main untouched
#   2. writer with NO registry remote, on a code repo that no longer tracks
#      state.sql, refuses to publish (fail closed; code repo main untouched)
#   3. writer whose `registry` remote points at the code repo refuses
#   4. reader materialises .chump/state.sql from the registry remote
#   5. reader with no registry remote and no legacy tracked file fails LOUDLY
#      (non-zero) instead of silently rebuilding from nothing
#
# Isolation: HOME, CHUMP_REPO and CHUMP_BACKLOG_SYNC_TREE are all pinned under a
# mktemp dir. `chump` and `sqlite3` are stubs. Nothing under the real $HOME is
# read or written. No network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../coord/backlog-sync.sh"
PASS=0; FAILS=0
ok(){ printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad(){ printf '  [FAIL] %s\n' "$*" >&2; FAILS=$((FAILS+1)); }

TMP="$(mktemp -d -t bsync-registry.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email "fixture@example.invalid"
git config --global user.name "fixture"
git config --global init.defaultBranch main
git config --global advice.detachedHead false

# stub chump. FAITHFUL to the real CLI: it knows only the subcommands the real
# binary knows, and REJECTS anything else non-zero the way the real one does
# ("unknown subcommand"). The previous stub ended in a blanket `exit 0`, so a
# call the real binary rejects still "succeeded" here -- that is exactly how
# `chump restore --from-sql` (no such subcommand; the real one is
# `chump gap restore`) survived in reader() with this test green. A stub that
# accepts more than the real CLI cannot catch a wrong-subcommand bug.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "gap" && "${2:-}" == "dump" ]]; then
  printf 'gaps:\n- id: FIX-1\n  status: open\n  stamp: %s\n' "${FIXTURE_STAMP:-0}"
  exit 0
fi
if [[ "${1:-}" == "gap" && "${2:-}" == "restore" ]]; then
  echo restored >> "${CHUMP_REPO:-.}/.chump/restore.calls"; exit 0
fi
if [[ "${1:-}" == "gap" && "${2:-}" == "set" ]]; then
  exit 0
fi
echo "chump: unknown subcommand ${1:-} ${2:-}" >&2
exit 2
STUB
printf '#!/usr/bin/env bash\necho 0\n' > "$TMP/bin/sqlite3"
chmod +x "$TMP/bin/chump" "$TMP/bin/sqlite3"
export PATH="$TMP/bin:$PATH" CHUMP_BIN="$TMP/bin/chump"

# make_code_repo <dir> <tracked|untracked>: bare "public code" origin + a node
# checkout carrying the real scripts/coord tree.
make_code_repo() {
  local d="$1" mode="$2"
  git init -q --bare "$d/code.git"
  git clone -q "$d/code.git" "$d/seed" 2>/dev/null
  mkdir -p "$d/seed/scripts/coord/lib" "$d/seed/.chump"
  cp "$SCRIPT" "$d/seed/scripts/coord/"
  cp "$SCRIPT_DIR/../coord/lib/"*.sh "$d/seed/scripts/coord/lib/"
  printf '.chump/state.sql\n.chump/state.db\n.chump/restore.calls\n' > "$d/seed/.gitignore"
  if [[ "$mode" == tracked ]]; then
    echo "gaps: []" > "$d/seed/.chump/state.sql"
    git -C "$d/seed" add -f .chump/state.sql
  fi
  git -C "$d/seed" add -A && git -C "$d/seed" commit -q -m "seed code repo ($mode)"
  git -C "$d/seed" push -q origin HEAD:main
  git clone -q "$d/code.git" "$d/node"
}
make_registry_repo() {
  local d="$1"
  git init -q --bare "$d/registry.git"
  git clone -q "$d/registry.git" "$d/regseed" 2>/dev/null
  mkdir -p "$d/regseed/.chump"
  echo "gaps: [] # registry seed" > "$d/regseed/.chump/state.sql"
  git -C "$d/regseed" add -A && git -C "$d/regseed" commit -q -m "seed registry"
  git -C "$d/regseed" push -q origin HEAD:main
}
run_sync() { # <node> <role>
  CHUMP_REPO="$1" CHUMP_BACKLOG_SYNC_TREE="$(dirname "$1")/bsync-tree" \
    bash "$1/scripts/coord/backlog-sync.sh" "$2" > "$(dirname "$1")/$2.log" 2>&1
}

# ── 1. writer + registry remote ─────────────────────────────────────────────
A="$TMP/a"; mkdir -p "$A"; make_code_repo "$A" untracked; make_registry_repo "$A"
git -C "$A/node" remote add registry "$A/registry.git"
code_before="$(git -C "$A/code.git" rev-parse main)"
FIXTURE_STAMP=111 run_sync "$A/node" --writer; rc=$?
[[ $rc -eq 0 ]] && ok "1a: writer exits 0 with a registry remote" || bad "1a: writer rc=$rc: $(cat "$A/--writer.log")"
git -C "$A/registry.git" show main:.chump/state.sql 2>/dev/null | grep -q "stamp: 111" \
  && ok "1b: state.sql landed on the REGISTRY remote" || bad "1b: registry main lacks the new dump"
[[ "$(git -C "$A/code.git" rev-parse main)" == "$code_before" ]] \
  && ok "1c: code repo main untouched" || bad "1c: code repo main MOVED — registry leaked to the code repo"
git -C "$A/code.git" cat-file -e main:.chump/state.sql 2>/dev/null \
  && bad "1d: code repo tracks state.sql" || ok "1d: code repo still does not track state.sql"

# ── 2. writer, no registry remote, code repo no longer tracks state.sql ─────
B="$TMP/b"; mkdir -p "$B"; make_code_repo "$B" untracked
code_before="$(git -C "$B/code.git" rev-parse main)"
run_sync "$B/node" --writer; rc=$?
[[ $rc -ne 0 ]] && ok "2a: writer fails closed (rc=$rc) with no registry remote" || bad "2a: writer exited 0 with nowhere safe to publish"
[[ "$(git -C "$B/code.git" rev-parse main)" == "$code_before" ]] \
  && ok "2b: code repo main untouched" || bad "2b: code repo main MOVED"
grep -q "refusing to publish" "$B/--writer.log" && ok "2c: refusal is logged" || bad "2c: no refusal line in log"

# ── 3. registry remote aimed at the code repo ───────────────────────────────
C="$TMP/c"; mkdir -p "$C"; make_code_repo "$C" untracked
git -C "$C/node" remote add registry "$C/code.git"
code_before="$(git -C "$C/code.git" rev-parse main)"
run_sync "$C/node" --writer; rc=$?
[[ $rc -ne 0 && "$(git -C "$C/code.git" rev-parse main)" == "$code_before" ]] \
  && ok "3: registry remote == code repo is refused, main untouched" || bad "3: misaimed registry remote was accepted (rc=$rc)"

# ── 4. reader materialises from the registry ────────────────────────────────
run_sync "$A/node" --reader; rc=$?
[[ $rc -eq 0 ]] && ok "4a: reader exits 0" || bad "4a: reader rc=$rc: $(cat "$A/--reader.log")"
grep -q "stamp: 111" "$A/node/.chump/state.sql" 2>/dev/null \
  && ok "4b: node .chump/state.sql holds the registry content" || bad "4b: node state.sql missing or stale"
[[ -z "$(git -C "$A/node" status --porcelain)" ]] \
  && ok "4c: node tree stays clean (state.sql is ignored)" || bad "4c: node tree dirty: $(git -C "$A/node" status --porcelain | head -3)"
[[ -s "$A/node/.chump/restore.calls" ]] && ok "4d: restore ran after materialise" || bad "4d: restore was not invoked"

# ── 5. reader with no registry and no legacy file fails loudly ──────────────
run_sync "$B/node" --reader; rc=$?
[[ $rc -ne 0 ]] && ok "5a: reader fails loudly (rc=$rc)" || bad "5a: reader exited 0 with no registry source"
[[ ! -e "$B/node/.chump/restore.calls" ]] && ok "5b: restore NOT invoked on a missing source" || bad "5b: restore ran with no source"

# ── 6. legacy (pre-cutover) tracked layout ALSO fails closed ────────────────
# Previously asserted "legacy tracked layout still publishes". That encoded the
# pre-cutover contract, and it is the hole: the legacy leg's publish target IS
# the public code repo, which _publish_url()'s own contract forbids. Tracked and
# untracked now behave identically (cf. test 2) because they resolve to the same
# repo. Re-enabling publication is the registry-remote cutover's job, not this
# leg's.
D="$TMP/d"; mkdir -p "$D"; make_code_repo "$D" tracked
code_before="$(git -C "$D/code.git" rev-parse main)"
FIXTURE_STAMP=222 run_sync "$D/node" --writer; rc=$?
[[ $rc -ne 0 ]] && ok "6a: legacy tracked layout fails closed (rc=$rc)" || bad "6a: legacy leg published to the code repo"
[[ "$(git -C "$D/code.git" rev-parse main)" == "$code_before" ]] \
  && ok "6b: code repo main untouched" || bad "6b: code repo main MOVED — registry reached the code repo"
grep -q "refusing to publish" "$D/--writer.log" && ok "6c: refusal is logged" || bad "6c: no refusal line in log"

# Guard against a vacuous green: every assertion above must have executed.
EXPECTED=17
echo "ran $((PASS+FAILS)) assertions, expected $EXPECTED; pass=$PASS fail=$FAILS"
[[ $((PASS+FAILS)) -eq $EXPECTED ]] || { echo "[FAIL] assertion count drifted (vacuous-pass guard)" >&2; exit 1; }
[[ $FAILS -eq 0 ]] || exit 1
echo "OK: backlog-sync registry-remote contract"
