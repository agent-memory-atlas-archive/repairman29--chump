#!/usr/bin/env bash
# test-auto-merge-armer-red-head.sh — INFRA-8180
#
# Fixes the WRITE side of the landing-organ arm/disarm war: auto-merge-armer.sh
# must refuse to (re-)arm a PR whose CURRENT head already has a FAILED
# required check. Arming such a head is a guaranteed no-op — GitHub disables
# auto-merge again within seconds and attributes the disable to the enabling
# token, which is exactly the false "bot disarm" signal INFRA-8178's
# human-vs-bot classifier misread and re-armed on, manufacturing a 5-minute
# arm/disarm loop (PR #5414, 2026-10-15T11:25Z-16:20Z, 9 cycles).
#
# Tests (all synthetic — no real GitHub calls):
#   1. Red head (one check with conclusion FAILURE) is NOT armed — `gh pr
#      merge` is never invoked for it.
#   2. Red head refusal is logged once per head SHA — running the armer
#      twice against the same red head appends exactly one
#      auto_merge_arm_skipped(reason=required_check_failed) event, not two.
#   3. Pending head (no FAILURE conclusion yet) IS armed — `gh pr merge` IS
#      invoked for it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ARMER="${REPO_ROOT}/scripts/coord/auto-merge-armer.sh"
AMBIENT_LOG="${REPO_ROOT}/.chump-locks/ambient.jsonl"

ok()   { echo "  [ok] $*"; }
fail() { echo "  [FAIL] $*" >&2; exit 1; }

echo "[test-auto-merge-armer-red-head] INFRA-8180 — refuse to arm a red head"

RED_PR=90201
RED_SHA="aaaa1111deadbeefcafefeed0123456789abcdef"
PENDING_PR=90202
PENDING_SHA="bbbb2222deadbeefcafefeed0123456789abcdef"

MARKER_RED="${REPO_ROOT}/.chump-locks/auto-merge-armer-red-head-${RED_PR}.last"
MARKER_PENDING="${REPO_ROOT}/.chump-locks/auto-merge-armer-red-head-${PENDING_PR}.last"

cleanup() {
    rm -f "${MARKER_RED}" "${MARKER_PENDING}" 2>/dev/null || true
}
trap cleanup EXIT

# Synthetic statusCheckRollup fixtures.
RED_ROLLUP='{"statusCheckRollup":[{"name":"fast-checks","status":"COMPLETED","conclusion":"FAILURE"},{"name":"clippy","status":"COMPLETED","conclusion":"SUCCESS"}]}'
PENDING_ROLLUP='{"statusCheckRollup":[{"name":"fast-checks","status":"IN_PROGRESS","conclusion":null},{"name":"clippy","status":"COMPLETED","conclusion":"SUCCESS"}]}'

TMPDIR_TEST="$(mktemp -d)"
MERGE_CALL_LOG="${TMPDIR_TEST}/merge-calls.log"
: > "${MERGE_CALL_LOG}"

FAKE_GH="${TMPDIR_TEST}/gh"
cat > "$FAKE_GH" << GHEOF
#!/usr/bin/env bash
# Synthetic gh stub — no network. Branches on PR number embedded in either
# a \`repos/.../pulls/<N>\` API path or a \`pr view|merge <N>\` argv position.
args=("\$@")
combined="\${args[*]}"

pr_num=""
if [[ "\${args[0]:-}" == "pr" && ( "\${args[1]:-}" == "view" || "\${args[1]:-}" == "merge" ) ]]; then
    pr_num="\${args[2]:-}"
elif [[ "\$combined" =~ pulls/([0-9]+) ]]; then
    pr_num="\${BASH_REMATCH[1]}"
fi

if [[ "\$combined" == *"auto_merge != null"* ]]; then
    echo "false"
elif [[ "\$combined" == *".head.sha"* ]]; then
    if [[ "\$pr_num" == "${RED_PR}" ]]; then
        echo "${RED_SHA}"
    else
        echo "${PENDING_SHA}"
    fi
elif [[ "\$combined" == *".state"* ]]; then
    echo "open"
elif [[ "\${args[0]:-}" == "pr" && "\${args[1]:-}" == "view" ]]; then
    if [[ "\$pr_num" == "${RED_PR}" ]]; then
        echo '${RED_ROLLUP}'
    else
        echo '${PENDING_ROLLUP}'
    fi
elif [[ "\$combined" == *"pr merge"* ]]; then
    echo "merge-called:\${pr_num}" >> "${MERGE_CALL_LOG}"
    echo "auto-merge enabled"
else
    echo "stub-gh: unhandled: \$combined" >&2
    exit 1
fi
GHEOF
chmod +x "$FAKE_GH"

export PATH="${TMPDIR_TEST}:${PATH}"
export GITHUB_REPOSITORY="test-owner/test-repo"
export CHUMP_MERGE_QUEUE_ENABLED=0
export CHUMP_AUTO_MERGE_REST_DIRECT=0

mkdir -p "$(dirname "${AMBIENT_LOG}")"
touch "${AMBIENT_LOG}"

# ── 1. Red head is not armed ──────────────────────────────────────────────────
echo
echo "[1. Red head (FAILURE conclusion) is not armed]"
bash "$ARMER" --pr "${RED_PR}" >/dev/null 2>&1 || true

if grep -q "merge-called:${RED_PR}" "${MERGE_CALL_LOG}" 2>/dev/null; then
    fail "red-head PR #${RED_PR} was armed — gh pr merge was called"
else
    ok "red-head PR #${RED_PR} was NOT armed"
fi

skipped_count_after_first="$(grep -c "\"auto_merge_arm_skipped\".*\"pr\":${RED_PR}\b" "${AMBIENT_LOG}" 2>/dev/null || true)"
skipped_count_after_first="${skipped_count_after_first:-0}"
if [[ "${skipped_count_after_first}" -ge 1 ]]; then
    ok "auto_merge_arm_skipped(reason=required_check_failed) emitted for PR #${RED_PR}"
else
    fail "expected at least one auto_merge_arm_skipped event for PR #${RED_PR}"
fi
if grep -q "reason=required_check_failed" "${AMBIENT_LOG}"; then
    ok "emitted event carries reason=required_check_failed"
else
    fail "emitted event missing reason=required_check_failed"
fi

# ── 2. Dedup — same head sha only logged once ─────────────────────────────────
echo
echo "[2. Red-head refusal logged once per head SHA, not per tick]"
bash "$ARMER" --pr "${RED_PR}" >/dev/null 2>&1 || true

skipped_count_after_second="$(grep -c "\"auto_merge_arm_skipped\".*\"pr\":${RED_PR}\b" "${AMBIENT_LOG}" 2>/dev/null || true)"
skipped_count_after_second="${skipped_count_after_second:-0}"
if [[ "${skipped_count_after_second}" -eq "${skipped_count_after_first}" ]]; then
    ok "second tick against the same head SHA did not emit a duplicate event (count stayed ${skipped_count_after_second})"
else
    fail "expected dedup: count stayed at ${skipped_count_after_first}, got ${skipped_count_after_second}"
fi
if grep -q "merge-called:${RED_PR}" "${MERGE_CALL_LOG}" 2>/dev/null; then
    fail "red-head PR #${RED_PR} was armed on the second tick"
else
    ok "red-head PR #${RED_PR} still not armed on the second tick"
fi

# ── 3. Pending head IS armed ──────────────────────────────────────────────────
echo
echo "[3. Pending head (no FAILURE conclusion) is armed]"
bash "$ARMER" --pr "${PENDING_PR}" >/dev/null 2>&1 || true

if grep -q "merge-called:${PENDING_PR}" "${MERGE_CALL_LOG}" 2>/dev/null; then
    ok "pending-head PR #${PENDING_PR} was armed"
else
    fail "pending-head PR #${PENDING_PR} was not armed — gh pr merge was never called"
fi

rm -rf "${TMPDIR_TEST}"
echo
echo "[test-auto-merge-armer-red-head] All checks passed."
