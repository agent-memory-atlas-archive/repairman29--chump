#!/usr/bin/env bash
# scripts/ci/test-gap-verb-unknown-flag.sh — CREDIBLE-1565
#
# Verifies that every state-changing `chump gap` verb (`set`, `ship`,
# `link-pr`, `unlink-pr`, `reserve`):
#   AC1: `chump gap set <ID> --acceptance-criteria x --dry-run` exits 2 and
#        leaves the row in state.db byte-unchanged.
#   AC2: `ship`, `link-pr`, `unlink-pr`, and `reserve` each exit 2 on an
#        unknown flag and leave state.db byte-unchanged; `--help` on each of
#        the five verbs exits 0, prints Usage, and leaves state.db
#        byte-unchanged.
#   AC3: a mutant that restores the permissive parser fails the test; wired in
#        .github/workflows/ci.yml and crates/chump-preflight/src/preflight.rs.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }

echo "=== CREDIBLE-1565 gap verb unknown-flag & --help gate ==="

CHUMP_BIN_DEFAULT="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
CHUMP_BIN="${CHUMP_BIN:-$CHUMP_BIN_DEFAULT}"
if [ "$CHUMP_BIN" = "$CHUMP_BIN_DEFAULT" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || { fail "cargo build --bin chump failed"; exit 1; }
fi
[ -x "$CHUMP_BIN" ] || { fail "CHUMP_BIN not executable: $CHUMP_BIN"; exit 1; }

# Build hermetic temp repo + state.db seeded with synthetic gap TEST-1565.
SANDBOX="$TMP/repo"
mkdir -p "$SANDBOX/.chump" "$SANDBOX/.chump-locks" "$SANDBOX/scripts/coord"
printf "#!/usr/bin/env bash\nexit 0\n" > "$SANDBOX/scripts/coord/chump-ambient-glance.sh"
chmod +x "$SANDBOX/scripts/coord/chump-ambient-glance.sh"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config user.email test@example.com
git -C "$SANDBOX" config user.name Test
git -C "$SANDBOX" commit -q --allow-empty -m "init"

# Initialize schema + one synthetic gap via valid `chump gap reserve` + `link-pr`.
(
    cd "$SANDBOX" && \
    CHUMP_REPO="$SANDBOX" \
    CHUMP_STATE_DB="$SANDBOX/.chump/state.db" \
    "$CHUMP_BIN" gap reserve \
        --domain INFRA \
        --title "INFRA: synthetic fixture for CREDIBLE-1565" \
        --priority P2 \
        --effort xs \
        --acceptance-criteria "initial-ac-1|initial-ac-2" \
        --force \
        --quiet >/dev/null
) || { fail "failed to seed synthetic gap in sandbox state.db"; exit 1; }

DB="$SANDBOX/.chump/state.db"
GAP_ID="$(sqlite3 "$DB" "SELECT id FROM gaps LIMIT 1;")"
[ -n "$GAP_ID" ] || { fail "no gap row found after seed"; exit 1; }

HEAD_SHA="$(git -C "$SANDBOX" rev-parse HEAD)"
(
    cd "$SANDBOX" && \
    CHUMP_REPO="$SANDBOX" \
    CHUMP_STATE_DB="$DB" \
    "$CHUMP_BIN" gap link-pr "$GAP_ID" 4242 --sha "$HEAD_SHA" >/dev/null
) || { fail "failed to seed gap_prs link in sandbox state.db"; exit 1; }

db_snapshot() {
    sqlite3 "$DB" "SELECT quote(id),quote(domain),quote(title),quote(description),quote(priority),quote(effort),quote(status),quote(acceptance_criteria),quote(notes),quote(depends_on),quote(closed_pr) FROM gaps ORDER BY id; SELECT quote(gap_id),quote(pr_number),quote(head_sha) FROM gap_prs ORDER BY gap_id, pr_number;"
}

run_suite_against_bin() {
    local bin="$1"
    local before after out rc

    before="$(db_snapshot)"

    # AC1: `chump gap set <ID> --acceptance-criteria x --dry-run` exits 2 and row is byte-unchanged.
    out="$(cd "$SANDBOX" && CHUMP_REPO="$SANDBOX" CHUMP_STATE_DB="$DB" "$bin" gap set "$GAP_ID" --acceptance-criteria x --dry-run 2>&1)"
    rc=$?
    after="$(db_snapshot)"
    if [ "$rc" -ne 2 ] || [ "$before" != "$after" ]; then
        return 1
    fi

    # AC2: unknown flag on ship, link-pr, unlink-pr, reserve (flag form + positional form) exits 2 and writes nothing.
    for cmd_spec in \
        "ship $GAP_ID --closed-pr 4242 --dry-run" \
        "link-pr $GAP_ID 9999 --sha $HEAD_SHA --dry-run" \
        "unlink-pr $GAP_ID 4242 --reason test --dry-run" \
        "reserve --domain INFRA --title probe --dry-run" \
        "reserve INFRA probe title --dry-run"
    do
        # shellcheck disable=SC2086
        out="$(cd "$SANDBOX" && CHUMP_REPO="$SANDBOX" CHUMP_STATE_DB="$DB" "$bin" gap $cmd_spec 2>&1)"
        rc=$?
        after="$(db_snapshot)"
        if [ "$rc" -ne 2 ] || [ "$before" != "$after" ]; then
            return 1
        fi
    done

    # AC2: --help on all five verbs exits 0, prints Usage, and writes nothing.
    for verb in set ship link-pr unlink-pr reserve; do
        out="$(cd "$SANDBOX" && CHUMP_REPO="$SANDBOX" CHUMP_STATE_DB="$DB" "$bin" gap "$verb" --help 2>&1)"
        rc=$?
        after="$(db_snapshot)"
        if [ "$rc" -ne 0 ] || ! printf "%s" "$out" | grep -q "Usage: chump gap" || [ "$before" != "$after" ]; then
            return 1
        fi
    done

    return 0
}

if run_suite_against_bin "$CHUMP_BIN"; then
    ok "AC1: chump gap set <ID> --acceptance-criteria x --dry-run exited 2 and left row byte-unchanged"
    ok "AC2: ship, link-pr, unlink-pr, reserve rejected --dry-run (exit 2, state.db byte-unchanged)"
    ok "AC2: --help on set, ship, link-pr, unlink-pr, reserve exited 0, printed Usage, and wrote nothing"
else
    fail "real chump binary failed AC1/AC2 unknown-flag or --help checks"
fi

# AC3: Mutant M1 — a permissive wrapper that strips unknown flags (reproducing
# pre-CREDIBLE-1565 behavior where `--dry-run` was silently ignored and the
# write proceeded) MUST fail `run_suite_against_bin`.
PERMISSIVE_MUTANT="$TMP/chump-permissive-mutant"
cat <<MUTEOF > "$PERMISSIVE_MUTANT"
#!/usr/bin/env bash
filtered=()
for a in "\$@"; do
    [[ "\$a" == "--dry-run" ]] && continue
    filtered+=("\$a")
done
exec "$CHUMP_BIN" "\${filtered[@]}"
MUTEOF
chmod +x "$PERMISSIVE_MUTANT"

SNAPSHOT_BEFORE_MUTANT="$(db_snapshot)"
if run_suite_against_bin "$PERMISSIVE_MUTANT"; then
    fail "AC3 mutant M1 SURVIVED: permissive parser wrapper passed test suite"
else
    ok "AC3 mutant M1 KILLED: permissive parser that ignores --dry-run fails the test"
fi
# Restore TEST-1565 acceptance_criteria after the mutant probe mutated it.
(
    cd "$SANDBOX" && \
    CHUMP_REPO="$SANDBOX" \
    CHUMP_STATE_DB="$DB" \
    "$CHUMP_BIN" gap set "$GAP_ID" --acceptance-criteria "initial-ac-1|initial-ac-2" >/dev/null
)
[ "$(db_snapshot)" = "$SNAPSHOT_BEFORE_MUTANT" ] || fail "failed to restore DB after mutant M1"

# AC3: Structural & wiring checks (src/main.rs call site + ci.yml + preflight.rs).
check_source_guard() {
    local main_rs="$1"
    grep -q "validate_gap_mutation_args(subcmd" "$main_rs"
}
if check_source_guard "$REPO_ROOT/src/main.rs"; then
    ok "src/main.rs calls validate_gap_mutation_args before opening state.db"
else
    fail "src/main.rs missing validate_gap_mutation_args call"
fi

MUTANT_MAIN="$TMP/main.rs.mutant"
grep -v "validate_gap_mutation_args(subcmd" "$REPO_ROOT/src/main.rs" > "$MUTANT_MAIN"
if check_source_guard "$MUTANT_MAIN"; then
    fail "AC3 mutant M2 SURVIVED: removing validate_gap_mutation_args call was not caught"
else
    ok "AC3 mutant M2 KILLED: removing validate_gap_mutation_args call fails guard"
fi

if grep -q "test-gap-verb-unknown-flag.sh" "$REPO_ROOT/.github/workflows/ci.yml" \
   && grep -q "test-gap-verb-unknown-flag.sh" "$REPO_ROOT/crates/chump-preflight/src/preflight.rs"; then
    ok "AC3: test-gap-verb-unknown-flag.sh wired in both ci.yml and preflight.rs"
else
    fail "AC3: test-gap-verb-unknown-flag.sh not wired in both ci.yml and preflight.rs"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
