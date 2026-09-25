#!/usr/bin/env bash
# test-stale-binary-ship-blocked.sh — INFRA-825 CI gate
#
# Asserts that the remaining destructive bulk-YAML operation
# (`chump gap dump --per-file`) refuses to run when the chump binary is
# stale relative to the gap-store-affecting code on HEAD.
#
# PR #1444 silently reverted META-044 because a 9-commit-stale chump binary
# regenerated all gap YAMLs from an outdated state.db. This test ensures
# that failure mode is blocked at the binary level, not just warned about.
#
# ZERO-WASTE-020 (2026-07-19): `chump gap ship --update-yaml` no longer
# writes anything (per-file YAML mirrors are retired — state.db is
# canonical, .chump/state.sql is the tracked dump) so it is a documented
# no-op and no longer needs the staleness guard: a no-op can't regenerate
# a stale YAML from an outdated state.db, because it doesn't regenerate
# anything. Only `gap dump --per-file` remains a genuine destructive
# bulk-YAML write (used for ad-hoc offline browsing exports) and stays
# guarded.
#
# The authoritative replay of #1444's failure mode lives in
# src/version.rs::tests::pr_1444_replay_refuses_without_override (and the
# ambient-override emitter test). This script ensures those unit tests
# stay green AND that the binary actually wires them in.
#
# CREDIBLE-237 / CREDIBLE-274: Test 2 grep target was src/main.rs; after
# INFRA-1965 moved gap command code to src/commands/gap.rs, the grep
# became vacuous. Target updated to scan both files so the gate can no
# longer pass silently.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

pass() { printf '[PASS] %s\n' "$*"; }
fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

# CREDIBLE-1079 (CREDIBLE-237 slice): guard helper for negative-assertion
# checks below. A negative assertion (grep -v, ! test -e, "pattern absent")
# against a target that silently doesn't exist passes vacuously — the check
# never actually ran. Call this BEFORE any negative assertion so a missing
# target aborts the script instead of masquerading as a pass.
ensure_target_exists() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        printf 'ERROR : target %s not found\n' "$target"
        return 1
    fi
    return 0
}

if ensure_target_exists "/nonexistent-target-$$-ensure-target-exists-selftest"; then
    fail "ensure_target_exists incorrectly succeeded for a missing target"
fi
pass "ensure_target_exists correctly fails (and prints ERROR) for a missing target"

cd "$REPO_ROOT"

# ── Test 1: src/version.rs unit tests cover #1444's failure mode ────────────
# pr_1444_replay_refuses_without_override asserts that a stale-shaped check
# returns Stale (which the caller maps to Refuse).
# override_event_emitted_to_ambient_jsonl asserts ambient telemetry fires.
if ! cargo test --bin chump version::tests::pr_1444_replay_refuses_without_override 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "pr_1444_replay_refuses_without_override failed — INFRA-825's hard-fail semantics broken"
fi
pass "pr_1444_replay_refuses_without_override (src/version.rs unit test)"

if ! cargo test --bin chump version::tests::override_event_emitted_to_ambient_jsonl 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "override_event_emitted_to_ambient_jsonl failed — ambient telemetry broken"
fi
pass "override_event_emitted_to_ambient_jsonl (src/version.rs unit test)"

if ! cargo test --bin chump version::tests::override_env_recognized 2>&1 | tail -3 | grep -q "test result: ok"; then
    fail "override_env_recognized failed — escape hatch env var not wired"
fi
pass "override_env_recognized (src/version.rs unit test)"

# ── Test 2: main.rs OR commands/gap.rs wires fail_if_stale_for_destructive
#    into the remaining destructive path ───────────────────────────────────
# CREDIBLE-237 / CREDIBLE-274: after INFRA-1965 moved gap commands to
# src/commands/gap.rs, Test 2 was grepping only src/main.rs and became a
# vacuous pass. Now scan both files so the gate cannot silently rot.
GAP_GUARD_FILES=("$REPO_ROOT/src/main.rs" "$REPO_ROOT/src/commands/gap.rs")
found_guard=false
for f in "${GAP_GUARD_FILES[@]}"; do
    if [[ -f "$f" ]] && grep -q "fail_if_stale_for_destructive" "$f"; then
        found_guard=true
        gap_site="$f"
        break
    fi
done
if ! $found_guard; then
    fail "fail_if_stale_for_destructive not found in main.rs or commands/gap.rs — INFRA-825 wiring missing"
fi
gap_dump_count=$(grep -c 'fail_if_stale_for_destructive(&repo_root, "gap dump --per-file")' "$gap_site" || true)
if [[ "$gap_dump_count" -lt 1 ]]; then
    fail "$gap_site: gap dump --per-file is not guarded by fail_if_stale_for_destructive"
fi
pass "$gap_site wires the hard-fail into the remaining destructive path (gap dump --per-file)"

# ── Test 3 (ZERO-WASTE-020): gap ship --update-yaml is a documented no-op,
#    not a guarded destructive path — the guard call was removed along with
#    the write it used to protect. Assert it's NOT wired to the staleness
#    check, so a future re-introduction of a real write there without the
#    guard gets caught by Test 2's positive-wiring pattern above instead of
#    silently reusing this no-op's text.
#
# CREDIBLE-274: scan both main.rs and commands/gap.rs so the negative
# assertion doesn't vacuous-pass when the target file is absent.
ensure_target_exists "$gap_site" \
    || fail "$gap_site: target for Test 3's negative-assertion check is missing — cannot verify gap ship --update-yaml is correctly unguarded"

found_ship_guard=false
for f in "${GAP_GUARD_FILES[@]}"; do
    if [[ -f "$f" ]] \
        && grep -q 'fail_if_stale_for_destructive(&repo_root,$' "$f" \
        && grep -A1 'fail_if_stale_for_destructive(&repo_root,$' "$f" | grep -q '"gap ship --update-yaml"'; then
        found_ship_guard=true
        break
    fi
done
if $found_ship_guard; then
    fail "gap ship --update-yaml is still wired to fail_if_stale_for_destructive — ZERO-WASTE-020 removed the write this guarded; if a real write came back, it needs the guard back too"
fi
pass "gap ship --update-yaml is a documented no-op (ZERO-WASTE-020), correctly unguarded"

echo
pass "INFRA-825 CI gate — the remaining destructive bulk-YAML op is gated by staleness check"
echo "    PR #1444's silent-revert failure mode is replayed by the version.rs"
echo "    unit tests above; main.rs / commands/gap.rs wiring is verified by grep."
