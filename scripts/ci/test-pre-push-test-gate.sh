#!/usr/bin/env bash
# test-pre-push-test-gate.sh — INFRA-761 regression tests.
#
# Verifies the pre-push hook's Guard 0b (cargo-test full-suite gate)
# fires correctly under each scenario:
#
#   1. No .rs change in push → guard SKIPS (no cargo invocation)
#   2. .rs change + tests pass → guard PASSES + writes cache marker
#   3. .rs change + tests fail → guard BLOCKS with diagnostic
#   4. CHUMP_TEST_GATE=0 → guard SKIPS regardless
#   5. Cache marker exists for current tree → guard SKIPS (cache hit)
#
# Strategy: stub `cargo` on PATH with a controllable mock so we don't pay
# the 4-min real test runtime. The mock reads $CHUMP_TEST_GATE_FAKE_RC
# to decide pass/fail. The hook only needs `cargo` for fmt + test, both
# of which we mock. We exercise just Guard 0b — Guard 0 (fmt) is also
# mocked-pass to isolate.

set -uo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

echo "=== INFRA-761 cargo-test gate (pre-push Guard 0b) ==="
echo

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/scripts/git-hooks/pre-push"

if [[ ! -x "$HOOK" ]]; then
    echo "FATAL: pre-push hook not found or not executable: $HOOK"
    exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Mock cargo ──────────────────────────────────────────────────────────────
# The mock honours CHUMP_TEST_GATE_FAKE_RC for the test subcommand.
# fmt --check always passes (Guard 0 already covered in INFRA-749 tests).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/cargo" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    fmt) exit 0 ;;
    test|nextest)
        # Honour CHUMP_TEST_GATE_FAKE_RC; default green. CREDIBLE-278:
        # `nextest` mocked identically to `test` so this suite stays hermetic
        # regardless of which runner the pre-push hook picks.
        rc="${CHUMP_TEST_GATE_FAKE_RC:-0}"
        if [[ "$rc" != "0" ]]; then
            echo "test failed: synthetic mock failure"
            exit "$rc"
        fi
        echo "test result: ok. 1 passed; 0 failed"
        exit 0
        ;;
    *) exit 0 ;;
esac
MOCK
chmod +x "$TMP/bin/cargo"

# CREDIBLE-278: also shadow the real `cargo-nextest` plugin binary (if the
# host has one installed) so `command -v cargo-nextest` inside the hook
# resolves to this hermetic no-op rather than a real toolchain, keeping the
# suite deterministic regardless of what's installed on the machine running it.
cat > "$TMP/bin/cargo-nextest" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$TMP/bin/cargo-nextest"

# Set up an isolated bare "origin" + clone so the hook has refs to push.
mkdir -p "$TMP/origin.git" && (cd "$TMP/origin.git" && git init --bare -q)
git clone -q "$TMP/origin.git" "$TMP/clone"
cd "$TMP/clone"
git config user.email t@t && git config user.name t

# Seed a minimal .cargo/config.toml so the hook's awk probe (INFRA-2184) does
# not fail with exit 2 on a missing file.  The real Chump repo has this file;
# the bare clone does not.  No rustc-wrapper line → _PREPUSH_WRAPPER_BIN=""
# → wrapper probe is skipped entirely.  (INFRA-2297)
mkdir -p .cargo
printf '[build]\n' > .cargo/config.toml

# Seed a baseline commit so origin/main exists.
mkdir -p src
echo "fn baseline() {}" > src/lib.rs
git add .cargo/config.toml src/lib.rs
git commit -qm "seed"
git push -q origin HEAD:main 2>/dev/null
git branch -m main 2>/dev/null || true
git push -q --set-upstream origin main 2>/dev/null

# Helper: invoke the hook with mocked cargo on PATH.
# Stdin format isn't required — our gate falls back to origin/main diff.
run_hook() {
    PATH="$TMP/bin:$PATH" \
    CHUMP_FMT_CHECK=0 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_CLIPPY_MIN_DISK_KB=0 \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_REBASE_DETECT=0 \
    CHUMP_TEST_GATE_FAKE_RC="${CHUMP_TEST_GATE_FAKE_RC:-0}" \
    "$HOOK" origin "$TMP/origin.git" </dev/null 2>&1
}

# Helper: invoke the hook with an explicit pre-push stdin ref list. Mirrors
# run_hook's env so the full-gate path behaves identically; the only change is
# that real refs are fed on stdin (needed to exercise the RESILIENT-1668
# refs/stash-only fast path, which decides from the refspec alone).
run_hook_stdin() {
    local _stdin="$1"
    PATH="$TMP/bin:$PATH" \
    CHUMP_FMT_CHECK=0 \
    CHUMP_GAP_CHECK=0 \
    CHUMP_CLIPPY_MIN_DISK_KB=0 \
    CHUMP_AUTOMERGE_OVERRIDE=1 \
    CHUMP_FORCE_LEASE_CHECK=0 \
    CHUMP_REBASE_DETECT=0 \
    CHUMP_TEST_GATE_FAKE_RC="${CHUMP_TEST_GATE_FAKE_RC:-0}" \
    "$HOOK" origin "$TMP/origin.git" <<<"$_stdin" 2>&1
}

ZERO_SHA="0000000000000000000000000000000000000000"

# ── Test 1: no .rs change → skip ────────────────────────────────────────────
echo "--- Test 1: docs-only change → guard skips (no cargo test invocation) ---"
echo "x" > README.md
git add README.md
git commit -qm "docs only"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -qE "(INFRA-761: running cargo test|CREDIBLE-278: running cargo nextest)"; then
    ok "docs-only push skipped the test gate"
else
    fail "docs-only push should skip (rc=$RC, out=$OUT)"
fi

# ── Test 2: .rs change + tests pass ─────────────────────────────────────────
echo "--- Test 2: .rs change + tests pass → guard passes + writes marker ---"
# Append a benign comment — compiles cleanly regardless of imports, still a
# real .rs diff that triggers the test gate's .rs-change branch (INFRA-2297).
echo "// test-pre-push-test-gate.sh synthetic change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change passing"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && grep -q "full suite green" <<<"$OUT"; then
    ok "rs-change-passing push allowed and cached"
else
    fail "rs-change-passing should pass (rc=$RC, out=$OUT)"
fi

TREE_SHA="$(git rev-parse HEAD^{tree})"
MARKER=".chump-locks/test-gate-cache/${TREE_SHA}.ok"
if [[ -f "$MARKER" ]]; then
    ok "cache marker created at $MARKER"
else
    fail "cache marker missing at $MARKER"
fi

# ── Test 3: cache hit → skip ────────────────────────────────────────────────
echo "--- Test 3: re-push of same tree → cache hit, guard skips ---"
OUT=$(run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! grep -qE "running cargo (test|nextest)" <<<"$OUT"; then
    ok "cache hit silently skipped re-test"
else
    fail "cache hit should skip (rc=$RC, out=$OUT)"
fi

# ── Test 4: .rs change + tests fail → block ─────────────────────────────────
echo "--- Test 4: .rs change + tests fail → guard blocks with diagnostic ---"
# Benign comment append — same rationale as Test 2 (INFRA-2297).
echo "// test-pre-push-test-gate.sh synthetic failing-case change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change failing"
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "BLOCKED: cargo test" <<<"$OUT"; then
    ok "test failure blocks push with diagnostic"
else
    fail "test failure should block (rc=$RC, out=$OUT)"
fi

# Cache marker for the failing tree should NOT be written.
TREE_SHA_FAIL="$(git rev-parse HEAD^{tree})"
FAIL_MARKER=".chump-locks/test-gate-cache/${TREE_SHA_FAIL}.ok"
if [[ ! -f "$FAIL_MARKER" ]]; then
    ok "no cache marker written on failure"
else
    fail "cache marker should NOT exist for failed tests"
fi

# ── Test 5: bypass env → requires Test-Gate-Bypass: trailer & non-fleet actor (CREDIBLE-1610) ──
echo "--- Test 5: CHUMP_TEST_GATE=0 requires Test-Gate-Bypass: trailer and forbids fleet sessions ---"
rm -f .chump-locks/ambient.jsonl
OUT_NOTRAILER=$(CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC_NOTRAILER=$?
if [[ "$RC_NOTRAILER" -ne 0 ]] && grep -q "requires a Test-Gate-Bypass:" <<<"$OUT_NOTRAILER"; then
    ok "CREDIBLE-1610: CHUMP_TEST_GATE=0 without Test-Gate-Bypass: trailer is refused (rc=$RC_NOTRAILER)"
else
    fail "CREDIBLE-1610: CHUMP_TEST_GATE=0 without trailer should be refused (rc=$RC_NOTRAILER, out=$OUT_NOTRAILER)"
fi

git commit --amend -qm "$(printf 'rs change failing\n\nTest-Gate-Bypass: emergency human override for red test\n')"
OUT_FLEET_TG=$(FLEET_AGENT_ID=agent-1 CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC_FLEET_TG=$?
_bm_pfx="CHUMP"
_bm_var="${_bm_pfx}_BYPASS_BOT_MERGE"
OUT_FLEET_BM=$(
    export FLEET_AGENT_ID=agent-1
    export "${_bm_var}=1"
    CHUMP_TEST_GATE_FAKE_RC=0 run_hook
)
RC_FLEET_BM=$?
if [[ "$RC_FLEET_TG" -ne 0 ]] && [[ "$RC_FLEET_BM" -ne 0 ]] \
   && grep -q "forbidden in fleet agent sessions" <<<"$OUT_FLEET_TG" \
   && grep -q "forbidden in fleet agent sessions" <<<"$OUT_FLEET_BM"; then
    ok "CREDIBLE-1610: fleet agent sessions cannot set CHUMP_TEST_GATE=0 (even with trailer) or bot-merge bypass"
else
    fail "CREDIBLE-1610: fleet session bypass was not refused (rc_tg=$RC_FLEET_TG, rc_bm=$RC_FLEET_BM)"
fi

rm -f .chump-locks/ambient.jsonl
OUT=$(
    unset CHUMP_DISPATCH_GAP CHUMP_FLEET_SESSION FLEET_AGENT_ID CHUMP_WORKER_TICK
    CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=101 run_hook
)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -qE "(INFRA-761: running cargo test|CREDIBLE-278: running cargo nextest)"; then
    ok "bypass env with Test-Gate-Bypass: trailer skipped the gate"
else
    fail "bypass env with trailer should skip (rc=$RC, out=$OUT)"
fi
if grep -q '"kind":"test_gate_bypassed"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"reason":"emergency human override for red test"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"uid":' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "CREDIBLE-1610: test_gate_bypassed logs reason and actor.uid"
else
    fail "CREDIBLE-1610: test_gate_bypassed missing reason or actor.uid: $(cat .chump-locks/ambient.jsonl 2>/dev/null)"
fi

# ── Test 6: CHUMP_BOT_MERGE_IN_PROGRESS=1 → skip (RESILIENT-1550) ──────────
echo "--- Test 6: bot-merge-initiated push → guard skips, emits ambient event ---"
echo "// test-pre-push-test-gate.sh synthetic bot-merge-skip change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change under bot-merge"
rm -f .chump-locks/ambient.jsonl
OUT=$(CHUMP_BOT_MERGE_IN_PROGRESS=1 CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -qE "(INFRA-761: running cargo test|CREDIBLE-278: running cargo nextest)"; then
    ok "bot-merge-in-progress push skipped the full-suite re-run"
else
    fail "bot-merge-in-progress push should skip (rc=$RC, out=$OUT)"
fi
if grep -q '"kind":"prepush_test_gate_skipped_botmerge"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "ambient event prepush_test_gate_skipped_botmerge recorded with reason"
else
    fail "ambient event prepush_test_gate_skipped_botmerge missing"
fi
BOTMERGE_TREE_SHA="$(git rev-parse HEAD^{tree})"
BOTMERGE_MARKER=".chump-locks/test-gate-cache/${BOTMERGE_TREE_SHA}.ok"
if [[ ! -f "$BOTMERGE_MARKER" ]]; then
    ok "bot-merge skip path does not write a cache marker (tree-hash cache unchanged)"
else
    fail "bot-merge skip path should not write a cache marker"
fi

# ── Test 7: direct push (no bot-merge env) still runs full suite ───────────
echo "--- Test 7: direct push without CHUMP_BOT_MERGE_IN_PROGRESS still runs full suite ---"
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qE "(running cargo test|running cargo nextest)"; then
    ok "direct push still runs the full nextest suite"
else
    fail "direct push should still run the full suite (rc=$RC, out=$OUT)"
fi

# ══════════════════════════════════════════════════════════════════════════
# RESILIENT-1668: refs/stash-only fast path
# ══════════════════════════════════════════════════════════════════════════
# A push whose every updated ref is under refs/stash/ skips fmt/clippy/test but
# still runs the origin-protecting scans. Decided from the refspec alone — no
# env var can enable it for a branch push.

# ── Test 8: stash-only push skips the test gate + emits prepush_stash_only ──
echo "--- Test 8: refs/stash-only push skips fmt/clippy/test, emits prepush_stash_only ---"
echo "// test-pre-push-test-gate.sh stash-only skip change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change pushed to a stash ref"
STASH_HEAD="$(git rev-parse HEAD)"
rm -f .chump-locks/ambient.jsonl
# FAKE_RC=101 would BLOCK if the test gate ran — the fast path must not reach it.
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 run_hook_stdin "refs/heads/wip ${STASH_HEAD} refs/stash/RESILIENT-1668-wip ${ZERO_SHA}")
RC=$?
if [[ "$RC" -eq 0 ]] && ! echo "$OUT" | grep -qE "running cargo (test|nextest)"; then
    ok "stash-only push skipped the build-bearing gates (rc=0, no cargo test)"
else
    fail "stash-only push should skip the gates (rc=$RC, out=$OUT)"
fi
if grep -q '"kind":"prepush_stash_only"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "ambient event prepush_stash_only emitted"
else
    fail "ambient event prepush_stash_only missing"
fi

# ── Test 9: stash-only push containing a secret is REFUSED (AC3) ────────────
# A mutant that skips the secret scan (removes the exit 1) makes this fail.
echo "--- Test 9: stash-only push containing a secret is refused ---"
# Assemble the fake key at runtime so no credential-shaped literal is committed
# into this test file (the repo's own pre-commit credential guard would block it).
SECRET="ghp_$(printf 'a%.0s' {1..36})"
printf 'token = %s\n' "$SECRET" > leaked.txt
git add leaked.txt
git commit -qm "wip with a secret"
SECRET_HEAD="$(git rev-parse HEAD)"
rm -f .chump-locks/ambient.jsonl
OUT=$(run_hook_stdin "refs/heads/wip ${SECRET_HEAD} refs/stash/RESILIENT-1668-wip ${ZERO_SHA}")
RC=$?
if [[ "$RC" -ne 0 ]] && grep -q "secret scan" <<<"$OUT"; then
    ok "stash-only push with a secret is refused by the secret scan"
else
    fail "stash-only push with a secret should be refused (rc=$RC, out=$OUT)"
fi
# Clean up the leaked fixture so later ranges don't re-trip the scan.
git rm -q leaked.txt
git commit -qm "drop secret fixture"

# ── Test 10: mixed push (stash ref + branch ref) runs the FULL gate (AC2) ───
# A mutant that fast-paths mixed pushes makes this fail (the gate would be
# skipped, so FAKE_RC=101 would not block).
echo "--- Test 10: mixed stash+branch push runs every gate (no fast path) ---"
echo "// test-pre-push-test-gate.sh mixed-push change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change for mixed push"
MIXED_HEAD="$(git rev-parse HEAD)"
rm -f .chump-locks/ambient.jsonl
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 run_hook_stdin \
    "refs/heads/wip ${MIXED_HEAD} refs/stash/RESILIENT-1668-wip ${ZERO_SHA}
refs/heads/wip ${MIXED_HEAD} refs/heads/wip ${ZERO_SHA}")
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qE "running cargo (test|nextest)"; then
    ok "mixed push ran the full test gate (did not fast-path)"
else
    fail "mixed push should run every gate (rc=$RC, out=$OUT)"
fi
if ! grep -q '"kind":"prepush_stash_only"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "mixed push did not emit prepush_stash_only"
else
    fail "mixed push should NOT emit prepush_stash_only"
fi

# ── Test 11: no env var can enable the fast path for a branch push (AC4) ────
echo "--- Test 11: branch push cannot be fast-pathed by any env var ---"
rm -f .chump-locks/ambient.jsonl
# Set invented knobs that a future bypass might use — the code reads none of
# them, so a branch push must still run the full gate and refuse FAKE_RC=101.
OUT=$(CHUMP_TEST_GATE_FAKE_RC=101 \
      CHUMP_PREPUSH_STASH_ONLY=1 \
      CHUMP_STASH_FAST_PATH=1 \
      CHUMP_PREPUSH_STASH=1 \
      run_hook_stdin "refs/heads/wip ${MIXED_HEAD} refs/heads/wip ${ZERO_SHA}")
RC=$?
if [[ "$RC" -ne 0 ]] && echo "$OUT" | grep -qE "running cargo (test|nextest)"; then
    ok "branch push ran the full gate despite stash-flavored env vars"
else
    fail "env vars must not enable the fast path for a branch push (rc=$RC, out=$OUT)"
fi
if ! grep -q '"kind":"prepush_stash_only"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "branch push did not emit prepush_stash_only"
else
    fail "branch push should NOT emit prepush_stash_only"
fi

# ── Test 12 (RESILIENT-1656): zero-bypass stash-before-kill refspec + secret mutant ──
echo "--- Test 12 (RESILIENT-1656): dispatch stash-before-kill refspec passes with ZERO bypass env vars + secret-scan mutant check ---"
if grep -q 'let stash_ref = format!("refs/stash/{slug}-{ts}");' "$REPO_ROOT/src/dispatch.rs"; then
    ok "RESILIENT-1656: src/dispatch.rs stash-before-kill targets refs/stash/<gap>-<ts>"
else
    fail "RESILIENT-1656: src/dispatch.rs missing refs/stash/{slug}-{ts} target"
fi

# (a) Clean WIP pushed to refs/stash/<gap>-<ts> and refs/stash/<gap>-wip with ZERO
#     CHUMP_* bypass env vars (and CHUMP_TEST_GATE_FAKE_RC=101 so a full gate would fail).
rm -f .chump-locks/ambient.jsonl
OUT_ZERO=$(env -u CHUMP_FMT_CHECK -u CHUMP_GAP_CHECK -u CHUMP_AUTOMERGE_OVERRIDE \
    -u CHUMP_FORCE_LEASE_CHECK -u CHUMP_REBASE_DETECT -u CHUMP_TEST_GATE \
    -u CHUMP_OPERATOR_RECOVERY -u CHUMP_BYPASS_BOT_MERGE \
    PATH="$TMP/bin:$PATH" CHUMP_TEST_GATE_FAKE_RC=101 \
    "$HOOK" origin "$TMP/origin.git" \
    <<<"HEAD ${MIXED_HEAD} refs/stash/resilient-1656-20261024-120000 ${ZERO_SHA}" 2>&1)
RC_ZERO=$?
if [[ "$RC_ZERO" -eq 0 ]] && grep -q '"kind":"prepush_stash_only"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "RESILIENT-1656: refs/stash/<gap>-<ts> passes pre-push fast-path with zero bypass env vars"
else
    fail "RESILIENT-1656: zero-bypass stash push should pass (rc=$RC_ZERO, out=$OUT_ZERO)"
fi

# (b) Mutant check: a stash-only push (refs/stash/RESILIENT-1656-wip) with a secret is
#     refused with zero bypass env vars, whereas a mutated hook with the secret-scan
#     exit disabled would let it through.
SECRET2="sk-ant-$(printf 'b%.0s' {1..36})"
printf 'api_key = %s\n' "$SECRET2" > leaked_r1656.txt
git add leaked_r1656.txt
git commit -qm "wip with secret for RESILIENT-1656"
SECRET2_HEAD="$(git rev-parse HEAD)"
OUT_SEC_ZERO=$(env -u CHUMP_FMT_CHECK -u CHUMP_GAP_CHECK -u CHUMP_AUTOMERGE_OVERRIDE \
    -u CHUMP_FORCE_LEASE_CHECK -u CHUMP_REBASE_DETECT -u CHUMP_TEST_GATE \
    -u CHUMP_OPERATOR_RECOVERY -u CHUMP_BYPASS_BOT_MERGE \
    PATH="$TMP/bin:$PATH" \
    "$HOOK" origin "$TMP/origin.git" \
    <<<"HEAD ${SECRET2_HEAD} refs/stash/RESILIENT-1656-wip ${ZERO_SHA}" 2>&1)
RC_SEC_ZERO=$?
sed '/RESILIENT-1668 secret scan/,/exit 1/s/exit 1/: # mutant/' "$HOOK" > "$TMP/pre-push-mutant"
chmod +x "$TMP/pre-push-mutant"
OUT_MUT=$(PATH="$TMP/bin:$PATH" "$TMP/pre-push-mutant" origin "$TMP/origin.git" \
    <<<"HEAD ${SECRET2_HEAD} refs/stash/RESILIENT-1656-wip ${ZERO_SHA}" 2>&1)
RC_MUT=$?
if [[ "$RC_SEC_ZERO" -ne 0 ]] && grep -q "secret scan" <<<"$OUT_SEC_ZERO" && [[ "$RC_MUT" -eq 0 ]]; then
    ok "RESILIENT-1656: zero-bypass stash push with secret refused by secret scan (mutant killed)"
else
    fail "RESILIENT-1656: secret scan or mutant check failed (rc_real=$RC_SEC_ZERO, rc_mut=$RC_MUT, out=$OUT_SEC_ZERO)"
fi
git rm -q leaked_r1656.txt
git commit -qm "drop RESILIENT-1656 secret fixture"

# ══════════════════════════════════════════════════════════════════════════
# INFRA-8154: incremental pre-push cargo test scope (touched pkgs + rdeps)
# ══════════════════════════════════════════════════════════════════════════
echo "--- Test 13 (INFRA-8154): incremental package scope + rdeps + workspace triggers + mutant checks ---"
PKG_SCOPE_LIB="$REPO_ROOT/scripts/lib/pre-push-pkg-scope.sh"
CARGO_TARGET_LIB="$REPO_ROOT/scripts/lib/cargo-target-dir.sh"
if [[ -f "$PKG_SCOPE_LIB" && -f "$CARGO_TARGET_LIB" ]]; then
    ok "INFRA-8154: scripts/lib/pre-push-pkg-scope.sh and scripts/lib/cargo-target-dir.sh exist"
else
    fail "INFRA-8154: missing pre-push-pkg-scope.sh or cargo-target-dir.sh"
fi

# (a) One-crate change -> selects that crate + its reverse dependencies
SCOPE_ONE="$( CHUMP_REPO_ROOT="$REPO_ROOT" bash "$PKG_SCOPE_LIB" --files $'crates/chump-cancel/src/lib.rs' )"
if grep -q -- "-p chump-cancel" <<<"$SCOPE_ONE" && grep -q -- "-p chump" <<<"$SCOPE_ONE" && [[ "$SCOPE_ONE" != "--workspace" ]]; then
    ok "INFRA-8154: 1-crate change selects crate + reverse dependencies ($SCOPE_ONE)"
else
    fail "INFRA-8154: expected -p chump-cancel and -p chump (not --workspace), got '$SCOPE_ONE'"
fi

# (b) Changes to Cargo.lock, Cargo.toml, workspace-hack/*, or scripts/git-hooks/pre-push -> --workspace
for _wf in "Cargo.lock" "Cargo.toml" "workspace-hack/Cargo.toml" "scripts/git-hooks/pre-push"; do
    _ws_out="$( CHUMP_REPO_ROOT="$REPO_ROOT" bash "$PKG_SCOPE_LIB" --files "$_wf" )"
    if [[ "$_ws_out" == "--workspace" ]]; then
        ok "INFRA-8154: '$_wf' triggers --workspace"
    else
        fail "INFRA-8154: expected '$_wf' to trigger --workspace, got '$_ws_out'"
    fi
done

# (c) Docs-only or scripts-only diff -> none
for _nf in $'docs/README.md\ndocs/ROADMAP.md' $'scripts/ops/vital-signs.sh\nscripts/coord/board-tick.sh'; do
    _n_out="$( CHUMP_REPO_ROOT="$REPO_ROOT" bash "$PKG_SCOPE_LIB" --files "$_nf" )"
    if [[ "$_n_out" == "none" ]]; then
        ok "INFRA-8154: non-Rust diff (${_nf%%$'\n'*}) selects 'none'"
    else
        fail "INFRA-8154: expected 'none' for non-Rust diff, got '$_n_out'"
    fi
done

# (d) Mutant checks:
#     Mutant 1: dropping rdeps expansion (# INFRA-8154:RDEPS-EXPANSION) must fail the rdeps check
sed '/# INFRA-8154:RDEPS-EXPANSION/d' "$PKG_SCOPE_LIB" > "$TMP/pkg-scope-mutant-no-rdeps.sh"
chmod +x "$TMP/pkg-scope-mutant-no-rdeps.sh"
MUT_RDEPS_OUT="$( CHUMP_REPO_ROOT="$REPO_ROOT" bash "$TMP/pkg-scope-mutant-no-rdeps.sh" --files $'crates/chump-cancel/src/lib.rs' )"
if grep -q -- "-p chump-cancel" <<<"$MUT_RDEPS_OUT" && ! grep -q -- "-p chump " <<<"$MUT_RDEPS_OUT"; then
    ok "INFRA-8154: mutant dropping rdeps expansion caught (missed reverse dep 'chump': $MUT_RDEPS_OUT)"
else
    fail "INFRA-8154: mutant dropping rdeps expansion was not caught ($MUT_RDEPS_OUT)"
fi

#     Mutant 2: dropping workspace-wide trigger (# INFRA-8154:WORKSPACE-TRIGGER) must fail the Cargo.lock check
sed '/# INFRA-8154:WORKSPACE-TRIGGER/d' "$PKG_SCOPE_LIB" > "$TMP/pkg-scope-mutant-no-ws.sh"
chmod +x "$TMP/pkg-scope-mutant-no-ws.sh"
MUT_WS_OUT="$( CHUMP_REPO_ROOT="$REPO_ROOT" bash "$TMP/pkg-scope-mutant-no-ws.sh" --files "Cargo.lock" )"
if [[ "$MUT_WS_OUT" != "--workspace" ]]; then
    ok "INFRA-8154: mutant dropping workspace trigger caught (Cargo.lock produced '$MUT_WS_OUT' != '--workspace')"
else
    fail "INFRA-8154: mutant dropping workspace trigger was not caught"
fi

# ══════════════════════════════════════════════════════════════════════════
# INFRA-8174: canonical Vercel project/domain resolver (vercel-resolve.sh)
# ══════════════════════════════════════════════════════════════════════════
echo "--- Test 14 (INFRA-8174): vercel-resolve.sh resolves olive -> cartpilot/shopolive.xyz and rejects madeupname ---"
VERCEL_RESOLVE="$REPO_ROOT/scripts/ops/vercel-resolve.sh"
VERCEL_TARGETS="$REPO_ROOT/config/vercel-targets.json"
if [[ -f "$VERCEL_RESOLVE" && -f "$VERCEL_TARGETS" ]]; then
    ok "INFRA-8174: scripts/ops/vercel-resolve.sh and config/vercel-targets.json exist"
else
    fail "INFRA-8174: missing vercel-resolve.sh or config/vercel-targets.json"
fi

VR_OLIVE_OUT="$( CHUMP_VERCEL_RESOLVE_OFFLINE=1 bash "$VERCEL_RESOLVE" --json olive 2>&1 )"
VR_OLIVE_RC=$?
if [[ "$VR_OLIVE_RC" -eq 0 ]] \
   && [[ "$(printf '%s' "$VR_OLIVE_OUT" | jq -r '.project_name // empty')" == "cartpilot" ]] \
   && [[ "$(printf '%s' "$VR_OLIVE_OUT" | jq -r '.prod_domain // empty')" == "shopolive.xyz" ]]; then
    ok "INFRA-8174: vercel-resolve.sh olive -> cartpilot + shopolive.xyz (rc=0)"
else
    fail "INFRA-8174: vercel-resolve.sh olive failed (rc=$VR_OLIVE_RC, out=$VR_OLIVE_OUT)"
fi

VR_BAD_STDOUT="$( CHUMP_VERCEL_RESOLVE_OFFLINE=1 bash "$VERCEL_RESOLVE" madeupname 2>"$TMP/vr-bad.stderr" )"
VR_BAD_RC=$?
VR_BAD_STDERR="$(cat "$TMP/vr-bad.stderr" 2>/dev/null)"
if [[ "$VR_BAD_RC" -ne 0 ]] \
   && [[ -z "$VR_BAD_STDOUT" ]] \
   && ! grep -q "madeupname" <<<"$VR_BAD_STDOUT" \
   && grep -qi "Resolution instructions" <<<"$VR_BAD_STDERR"; then
    ok "INFRA-8174: vercel-resolve.sh madeupname exits non-zero ($VR_BAD_RC) with resolution instructions on stderr"
else
    fail "INFRA-8174: vercel-resolve.sh madeupname should fail cleanly (rc=$VR_BAD_RC, stdout='$VR_BAD_STDOUT', stderr='$VR_BAD_STDERR')"
fi

# ══════════════════════════════════════════════════════════════════════════
# RESILIENT-1693: upfront pre-push ETA line + prepush_budget telemetry
# ══════════════════════════════════════════════════════════════════════════
echo "--- Test 15 (RESILIENT-1693): upfront ETA line and prepush_budget telemetry ---"
echo "// test-pre-push-test-gate.sh RESILIENT-1693 change $(date +%s)" >> src/lib.rs
git add src/lib.rs
git commit -qm "rs change for RESILIENT-1693"
rm -f .chump-locks/ambient.jsonl
OUT_1693=$(CHUMP_TEST_GATE_FAKE_RC=0 run_hook)
RC_1693=$?
if [[ "$RC_1693" -eq 0 ]] && grep -q '\[pre-push\] ETA: clippy + incremental test gate may take 180-360s' <<<"$OUT_1693"; then
    ok "RESILIENT-1693: upfront ETA line printed before clippy/test gate"
else
    fail "RESILIENT-1693: missing upfront ETA line (rc=$RC_1693, out=$OUT_1693)"
fi
if grep -q '"kind":"prepush_budget"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"clippy_s":' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"test_s":' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"total_s":' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "RESILIENT-1693: prepush_budget event emitted with clippy_s, test_s, total_s"
else
    fail "RESILIENT-1693: prepush_budget event missing or incomplete: $(cat .chump-locks/ambient.jsonl 2>/dev/null)"
fi

# ══════════════════════════════════════════════════════════════════════════
# CREDIBLE-1566: CHUMP_DISPATCH_GAP refuses bypass env vars & bypass trailers
# in pre-push and commit-msg, emits kind=agent_bypass_refused, and repair
# lease .branch allows repair branch without Off-Rails-Bypass:
# ══════════════════════════════════════════════════════════════════════════
echo "--- Test 16 (CREDIBLE-1566): dispatch bypass refusal + repair lease branch ---"
rm -f .chump-locks/ambient.jsonl
OUT_1566_ENV=$(CHUMP_DISPATCH_GAP=INFRA-9999 CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=101 run_hook)
RC_1566_ENV=$?
if [[ "$RC_1566_ENV" -ne 0 ]] \
   && grep -q '"kind":"agent_bypass_refused"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"bypass":"CHUMP_TEST_GATE=0"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "CREDIBLE-1566: pre-push refuses CHUMP_TEST_GATE=0 under CHUMP_DISPATCH_GAP and emits agent_bypass_refused"
else
    fail "CREDIBLE-1566: pre-push did not refuse CHUMP_TEST_GATE=0 under CHUMP_DISPATCH_GAP (rc=$RC_1566_ENV, out=$OUT_1566_ENV)"
fi

rm -f .chump-locks/ambient.jsonl
git commit --amend -qm "$(printf 'rs change for CREDIBLE-1566\n\nOff-Rails-Bypass: attempted agent trailer bypass\n')"
OUT_1566_TR=$(CHUMP_DISPATCH_GAP=INFRA-9999 CHUMP_TEST_GATE_FAKE_RC=0 run_hook)
RC_1566_TR=$?
if [[ "$RC_1566_TR" -ne 0 ]] \
   && grep -q '"kind":"agent_bypass_refused"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"bypass":"Off-Rails-Bypass:"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "CREDIBLE-1566: pre-push refuses Off-Rails-Bypass: trailer on HEAD under CHUMP_DISPATCH_GAP and emits agent_bypass_refused"
else
    fail "CREDIBLE-1566: pre-push did not refuse Off-Rails-Bypass: trailer under CHUMP_DISPATCH_GAP (rc=$RC_1566_TR, out=$OUT_1566_TR)"
fi
git commit --amend -qm "rs change for CREDIBLE-1566"

# Test commit-msg hook under CHUMP_DISPATCH_GAP
COMMIT_MSG_HOOK="$REPO_ROOT/scripts/git-hooks/commit-msg"
MSG_1566="$TMP/msg-1566.txt"
printf 'fix(INFRA-9999): test commit\n\nTest-Gate-Bypass: agent trying to skip tests\n' > "$MSG_1566"
rm -f .chump-locks/ambient.jsonl
OUT_CM_1566="$(CHUMP_DISPATCH_GAP=INFRA-9999 bash "$COMMIT_MSG_HOOK" "$MSG_1566" 2>&1)"
RC_CM_1566=$?
if [[ "$RC_CM_1566" -ne 0 ]] \
   && grep -q '"kind":"agent_bypass_refused"' .chump-locks/ambient.jsonl 2>/dev/null \
   && grep -q '"hook":"commit-msg"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "CREDIBLE-1566: commit-msg refuses Test-Gate-Bypass: under CHUMP_DISPATCH_GAP and emits agent_bypass_refused"
else
    fail "CREDIBLE-1566: commit-msg did not refuse bypass trailer under CHUMP_DISPATCH_GAP (rc=$RC_CM_1566, out=$OUT_CM_1566)"
fi

# Verify repair lease .branch is honored by lease.sh::get_active_claim_file
REPAIR_BRANCH_ORIG="$(git rev-parse --abbrev-ref HEAD)"
git checkout -qb claude/repair-pr-9999
cat > .chump-locks/dispatch-infra-9999.json <<'EOF'
{
  "session_id": "dispatch-infra-9999",
  "paths": ["src/"],
  "taken_at": "2026-10-25T00:00:00Z",
  "expires_at": "2099-10-25T00:00:00Z",
  "heartbeat_at": "2099-10-25T00:00:00Z",
  "purpose": "dispatch",
  "worktree": "",
  "gap_id": "INFRA-9999",
  "branch": "claude/repair-pr-9999"
}
EOF
RESOLVED_CLAIM="$(
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/coord/lib/lease.sh"
    get_active_claim_file "$TMP/clone"
)"
rm -f .chump-locks/dispatch-infra-9999.json
git checkout -q "$REPAIR_BRANCH_ORIG"
if [[ "$RESOLVED_CLAIM" == *"dispatch-infra-9999.json" ]]; then
    ok "CREDIBLE-1566: lease.sh resolves repair lease by .branch without needing chump/<gap>-claim naming or Off-Rails-Bypass:"
else
    fail "CREDIBLE-1566: lease.sh failed to resolve repair lease by .branch (got '$RESOLVED_CLAIM')"
fi

# ── Test 17 (INFRA-8643 / INFRA-8644 / INFRA-8645): bot-merge push + legitimate architectural trailers in dispatch sessions ──
echo "--- Test 17 (INFRA-8643/8644/8645): bot-merge push & Rust-First-Bypass in dispatch sessions ---"
rm -f .chump-locks/ambient.jsonl .chump-locks/test-gate-cache/* 2>/dev/null || true
git commit --amend -qm "$(printf 'rs change for INFRA-8643\n\nRust-First-Bypass: small glue script\nShared-Service-Bypass: test fixture\n')"
export CHUMP_BOT_MERGE_IN_PROGRESS=1
OUT_8643_BM="$(CHUMP_DISPATCH_GAP=INFRA-9999 CHUMP_TEST_GATE=0 CHUMP_TEST_GATE_FAKE_RC=0 run_hook)"
RC_8643_BM=$?
unset CHUMP_BOT_MERGE_IN_PROGRESS
if [[ "$RC_8643_BM" -eq 0 ]] && ! grep -q '"kind":"agent_bypass_refused"' .chump-locks/ambient.jsonl 2>/dev/null; then
    ok "INFRA-8643/8644/8645: bot-merge push (CHUMP_BOT_MERGE_IN_PROGRESS) and Rust-First-Bypass/Shared-Service-Bypass succeed under CHUMP_DISPATCH_GAP"
else
    fail "INFRA-8643/8644/8645: bot-merge push under CHUMP_DISPATCH_GAP was falsely refused (rc=$RC_8643_BM, out=$OUT_8643_BM)"
fi
# Commit-msg hook also permits Rust-First-Bypass and Shared-Service-Bypass under CHUMP_DISPATCH_GAP
printf 'feat: glue script\n\nRust-First-Bypass: legitimate glue\nShared-Service-Bypass: legitimate test\n' > "$TMP/cmsg-8643.txt"
OUT_CM_8643="$(CHUMP_DISPATCH_GAP=INFRA-9999 bash "$COMMIT_MSG_HOOK" "$TMP/cmsg-8643.txt" 2>&1)"
RC_CM_8643=$?
if [[ "$RC_CM_8643" -eq 0 ]]; then
    ok "INFRA-8643/8644/8645: commit-msg allows Rust-First-Bypass and Shared-Service-Bypass under CHUMP_DISPATCH_GAP"
else
    fail "INFRA-8643/8645: commit-msg rejected Rust-First-Bypass/Shared-Service-Bypass under CHUMP_DISPATCH_GAP (rc=$RC_CM_8643, out=$OUT_CM_8643)"
fi
git commit --amend -qm "rs change for INFRA-8643"

# ── Test 18 (CREDIBLE-1569): path-matched scripts/ci/test-*.sh in pre-push + mutant kill ──
echo "--- Test 18 (CREDIBLE-1569): path-matched scripts/ci/test-*.sh in pre-push ---"
SCOPE_HELPER="$REPO_ROOT/scripts/lib/pre-push-pkg-scope.sh"
SHELL_FARMER="$(bash "$SCOPE_HELPER" --shell-tests $'src/farmer_status.rs')"
SHELL_DOCS="$(bash "$SCOPE_HELPER" --shell-tests $'docs/ROADMAP.md\nREADME.md')"
if [[ "$SHELL_FARMER" == "scripts/ci/test-fleet-kill-switch.sh scripts/ci/test-outcome-gate.sh scripts/ci/test-state-db-yaml-sync.sh" ]] \
   && [[ "$SHELL_DOCS" == "none" ]]; then
    ok "CREDIBLE-1569: pre-push-pkg-scope.sh --shell-tests maps src/farmer_status.rs to the 3 CI shell tests and docs-only to none"
else
    fail "CREDIBLE-1569: unexpected --shell-tests output (farmer='$SHELL_FARMER', docs='$SHELL_DOCS')"
fi

mkdir -p "$TMP/clone/scripts/lib" "$TMP/clone/scripts/ci"
cp "$SCOPE_HELPER" "$TMP/clone/scripts/lib/pre-push-pkg-scope.sh"
cat > "$TMP/clone/scripts/ci/test-fleet-kill-switch.sh" <<'EOF'
#!/usr/bin/env bash
echo "simulated test-fleet-kill-switch failure" >&2
exit 1
EOF
chmod +x "$TMP/clone/scripts/ci/test-fleet-kill-switch.sh"
echo "// farmer change" >> "$TMP/clone/src/farmer_status.rs"
git add src/farmer_status.rs scripts/ci/test-fleet-kill-switch.sh scripts/lib/pre-push-pkg-scope.sh
git commit -qm "touch farmer_status.rs for CREDIBLE-1569"
rm -f .chump-locks/test-gate-cache/* 2>/dev/null || true
OUT_1569_FAIL="$(CHUMP_TEST_GATE_FAKE_RC=0 run_hook)"
RC_1569_FAIL=$?
if [[ "$RC_1569_FAIL" -ne 0 ]] && grep -q "BLOCKED (CREDIBLE-1569): matched CI shell test failed: scripts/ci/test-fleet-kill-switch.sh" <<<"$OUT_1569_FAIL"; then
    ok "CREDIBLE-1569: pre-push blocks push when path-matched scripts/ci/test-fleet-kill-switch.sh fails"
else
    fail "CREDIBLE-1569: pre-push did not block failing path-matched shell test (rc=$RC_1569_FAIL, out=$OUT_1569_FAIL)"
fi

# Mutant check: strip CREDIBLE-1569:SHELL-TEST-GATE lines from pre-push -> mutant fails to block
MUTANT_1569="$TMP/pre-push.mutant-1569"
grep -v 'CREDIBLE-1569:SHELL-TEST-GATE' "$HOOK" > "$MUTANT_1569"
chmod +x "$MUTANT_1569"
rm -f .chump-locks/test-gate-cache/* 2>/dev/null || true
OUT_1569_MUT="$(HOOK="$MUTANT_1569" CHUMP_TEST_GATE_FAKE_RC=0 run_hook)"
RC_1569_MUT=$?
if [[ "$RC_1569_MUT" -eq 0 ]]; then
    ok "CREDIBLE-1569 (mutant killed): removing SHELL-TEST-GATE from pre-push allows broken shell test through"
else
    fail "CREDIBLE-1569 (mutant survived): mutant pre-push still exited non-zero (rc=$RC_1569_MUT, out=$OUT_1569_MUT)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
