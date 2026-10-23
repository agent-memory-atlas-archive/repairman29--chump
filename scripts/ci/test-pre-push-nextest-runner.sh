#!/usr/bin/env bash
# test-pre-push-nextest-runner.sh — CREDIBLE-278 regression tests.
#
# CREDIBLE-175 was previously marked done by a PR that never touched
# scripts/git-hooks/pre-push (proven by `git log -S nextest -- scripts/git-hooks/pre-push`
# returning EMPTY at the time). This suite is the anti-recurrence proof for
# the real fix: it captures the ACTUAL command the hook executes (via a shim
# on PATH that logs every invocation to a file), not just a grep of the hook
# source, so a future revert that keeps the string "nextest" in a comment but
# removes the runner-selection logic still fails this suite.
#
# Scenarios:
#   1. cargo-nextest present on PATH  → hook invokes `cargo nextest run ...`
#   2. cargo-nextest ABSENT from PATH → hook falls back to `cargo test ...`
#      AND prints a loud WARN naming the fallback (never silent).

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== CREDIBLE-278 nextest runner selection (pre-push Guard 0b) ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: pre-push hook not found or not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"

# Log every invocation of `cargo` (argv, one per line) to $INVOKE_LOG so we
# can assert on the ACTUAL command the hook ran, not on hook source text.
INVOKE_LOG="$TMP/invocations.log"
: > "$INVOKE_LOG"

write_cargo_mock() {
    # $1 = 1 to also install a cargo-nextest shim (simulates it being
    #      installed), 0 to omit it (simulates it being absent from PATH).
    local with_nextest="$1"
    cat > "$TMP/bin/cargo" <<MOCK
#!/usr/bin/env bash
echo "cargo \$*" >> "$INVOKE_LOG"
case "\$1" in
    fmt) exit 0 ;;
    test|nextest)
        rc="\${CHUMP_TEST_GATE_FAKE_RC:-0}"
        if [[ "\$rc" != "0" ]]; then
            echo "test failed: synthetic mock failure"
            exit "\$rc"
        fi
        echo "test result: ok. 1 passed; 0 failed"
        exit 0
        ;;
    *) exit 0 ;;
esac
MOCK
    chmod +x "$TMP/bin/cargo"

    if [[ "$with_nextest" == "1" ]]; then
        cat > "$TMP/bin/cargo-nextest" <<MOCK
#!/usr/bin/env bash
echo "cargo-nextest \$*" >> "$INVOKE_LOG"
rc="\${CHUMP_TEST_GATE_FAKE_RC:-0}"
if [[ "\$rc" != "0" ]]; then
    exit "\$rc"
fi
exit 0
MOCK
        chmod +x "$TMP/bin/cargo-nextest"
    else
        rm -f "$TMP/bin/cargo-nextest"
    fi
}

# Isolated bare "origin" + clone so the hook has refs to push against.
mkdir -p "$TMP/origin.git" && (cd "$TMP/origin.git" && git init --bare -q)
git clone -q "$TMP/origin.git" "$TMP/clone"
cd "$TMP/clone"
git config user.email t@t && git config user.name t

mkdir -p .cargo
printf '[build]\n' > .cargo/config.toml

mkdir -p src
echo "fn baseline() {}" > src/lib.rs
git add .cargo/config.toml src/lib.rs
git commit -qm "seed"
git push -q origin HEAD:main 2>/dev/null
git branch -m main 2>/dev/null || true
git push -q --set-upstream origin main 2>/dev/null

run_hook() {
    # $HOOK_PATH lets each scenario control whether a real cargo-nextest
    # elsewhere on the host PATH (e.g. ~/.cargo/bin) is visible — the
    # "absent" scenario must not see one, so it strips such dirs rather
    # than relying on our own $TMP/bin mocks being found first (`command -v`
    # searches the WHOLE PATH, not just the first hit).
    PATH="${HOOK_PATH:-$TMP/bin:$PATH}" \
    CHUMP_FMT_CHECK=0 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_REBASE_DETECT=0 \
    CHUMP_TEST_GATE_FAKE_RC="${CHUMP_TEST_GATE_FAKE_RC:-0}" \
    "$HOOK" origin "$TMP/origin.git" </dev/null 2>&1
}

# ── Test 1: cargo-nextest present → hook actually invokes it ───────────────
echo "--- Test 1: cargo-nextest on PATH → hook's ACTUAL invocation is nextest ---"
write_cargo_mock 1
: > "$INVOKE_LOG"
echo "// nextest-present change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change, nextest present"
OUT=$(HOOK_PATH="$TMP/bin:$PATH" run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && grep -qE '^cargo nextest run .*--bin chump' "$INVOKE_LOG"; then
    ok "hook's actual argv used cargo nextest, not cargo test"
else
    fail "hook should have invoked cargo nextest (rc=$RC, invoke_log=$(cat "$INVOKE_LOG"), out=$OUT)"
fi
if ! grep -qE '^cargo test' "$INVOKE_LOG"; then
    ok "hook did not ALSO fall back to cargo test when nextest is present"
else
    fail "hook should not invoke cargo test when nextest is available ($(cat "$INVOKE_LOG"))"
fi
if echo "$OUT" | grep -q "CREDIBLE-278: running cargo nextest run"; then
    ok "hook announced the nextest runner choice"
else
    fail "hook should announce it chose nextest (out=$OUT)"
fi
if grep -qE '^cargo nextest run --profile prepush ' "$INVOKE_LOG" \
   && grep -qE '^\[profile\.prepush\]' "$REPO_ROOT/.config/nextest.toml" 2>/dev/null \
   && grep -qE '^slow-timeout = .*terminate-after' "$REPO_ROOT/.config/nextest.toml"; then
    ok "INFRA-8042: hook runs nextest with the prepush profile (per-test timeout)"
else
    fail "INFRA-8042: expected 'cargo nextest run --profile prepush' and a terminating slow-timeout in .config/nextest.toml ($(cat "$INVOKE_LOG"))"
fi

# ── Test 2: cargo-nextest absent → loud fallback to cargo test ─────────────
echo "--- Test 2: cargo-nextest NOT on PATH → hook falls back to cargo test, loudly ---"
write_cargo_mock 0
: > "$INVOKE_LOG"
echo "// nextest-absent change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change, nextest absent"
# Strip any dir containing a REAL cargo-nextest (e.g. ~/.cargo/bin on a dev
# box) from PATH so `command -v cargo-nextest` inside the hook genuinely
# finds nothing — otherwise this scenario can't be reproduced on a machine
# that has cargo-nextest installed system-wide.
_CLEAN_PATH=""
IFS=':' read -ra _PATH_DIRS <<< "$PATH"
for _d in "${_PATH_DIRS[@]}"; do
    [[ -x "$_d/cargo-nextest" ]] && continue
    _CLEAN_PATH="${_CLEAN_PATH:+$_CLEAN_PATH:}$_d"
done
OUT=$(HOOK_PATH="$TMP/bin:$_CLEAN_PATH" run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && grep -qE '^cargo test .*--bin chump.* -- --test-threads=1' "$INVOKE_LOG"; then
    ok "hook's actual argv fell back to cargo test -- --test-threads=1 when nextest is absent (INFRA-8572)"
else
    fail "hook should fall back to cargo test -- --test-threads=1 (rc=$RC, invoke_log=$(cat "$INVOKE_LOG"), out=$OUT)"
fi
if echo "$OUT" | grep -q "WARN CREDIBLE-278: cargo-nextest not found on PATH"; then
    ok "hook loudly announced the fallback (never silent)"
else
    fail "hook must WARN loudly when falling back — a missing tool must never silently skip/pass (out=$OUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
