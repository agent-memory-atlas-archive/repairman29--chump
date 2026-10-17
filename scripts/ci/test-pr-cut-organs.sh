#!/usr/bin/env bash
# test-pr-cut-organs.sh — RESILIENT-1616
#
# Proves that every PR-mutating organ honors the shared pr-cut predicate
# (scripts/coord/lib/pr-cut-guard.sh): a deliberately cut PR is never re-armed,
# reopened, rebased or auto-commented. Each organ is driven with gh stubbed on
# PATH (no live GitHub, no state mutation) and a seeded kind=pr_cut ambient
# event; the test asserts (a) the organ did NOT call a mutating gh verb on the
# cut PR and (b) the organ emitted kind=pr_cut_honored naming itself.
#
# Also enforces the grep gate: any script under scripts/coord or scripts/ops
# with a `gh pr reopen` / `gh pr merge --auto` call site must reference the
# predicate, unless it is grandfathered in scripts/ci/pr-cut-guard-exceptions.txt.
#
# Receipt this guards against: auto-arm-sweeper.sh re-armed the cut duplicate
# PR #5562 at 18:29Z 2026-10-17 (kind=pr_rearmed), which would have landed the
# same diff twice. The pr-cut.sh verb + the watch/reviver half are covered by
# scripts/ci/test-pr-cut-honored.sh (RESILIENT-1606/1607).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CUT_PR=9999
FAILS=0

pass() { printf '  ok   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; FAILS=$((FAILS + 1)); }

# ── Shared per-case scaffold ────────────────────────────────────────────────
new_case() {
    CASE_TMP="$(mktemp -d)"
    STUB="$CASE_TMP/bin"; mkdir -p "$STUB"
    MUT="$CASE_TMP/mutations.log"; : > "$MUT"
    AMBIENT="$CASE_TMP/ambient.jsonl"
    mkdir -p "$(dirname "$AMBIENT")"
    # Seed the terminal signal: a local kind=pr_cut event for the cut PR.
    printf '{"ts":"2026-10-17T18:13:00Z","kind":"pr_cut","pr":%s,"branch":"chump/zero-waste-135","gap":"ZERO-WASTE-135","reason":"duplicate cut"}\n' "$CUT_PR" > "$AMBIENT"
    export CHUMP_AMBIENT_PATH="$AMBIENT" CHUMP_AMBIENT_LOG="$AMBIENT"
    export CHUMP_TEST_MUT="$MUT"
}
end_case() { rm -rf "$CASE_TMP"; unset CHUMP_AMBIENT_PATH CHUMP_AMBIENT_LOG CHUMP_TEST_MUT; }

assert_no_mutation() { # <organ-label>
    if grep -qE "(^| )MUTATE .*\b${CUT_PR}\b" "$MUT" 2>/dev/null; then
        fail "$1 mutated the cut PR: $(tr '\n' ';' < "$MUT")"
    else
        pass "$1 did not mutate the cut PR"
    fi
}
assert_honored() { # <organ-basename>
    if grep -F '"kind":"pr_cut_honored"' "$AMBIENT" 2>/dev/null | grep -qF "\"organ\":\"$1\""; then
        pass "$1 emitted kind=pr_cut_honored"
    else
        fail "$1 did NOT emit kind=pr_cut_honored (never reached the guard?)"
    fi
}

# Mutation-tripwire gh preamble: records any reopen/merge/comment/edit/
# update-branch / PATCH-state=open, returns benign JSON otherwise. Per-case
# behavior is appended after this.
_gh_preamble() {
cat <<'GHEOF'
#!/usr/bin/env bash
MUT="${CHUMP_TEST_MUT:?}"
_rec() { printf '%s\n' "$*" >> "$MUT"; }
case "${1:-} ${2:-}" in
  "pr reopen"|"pr merge"|"pr comment"|"pr edit"|"pr update-branch")
      _rec "MUTATE $*"; exit 0 ;;
esac
if [[ "${1:-}" == "api" ]] && printf '%s\n' "$@" | grep -q 'state=open'; then
  _rec "MUTATE $*"; exit 0
fi
GHEOF
}

echo "== RESILIENT-1616: per-organ pr-cut honoring =="

# ── 1. auto-merge-armer.sh — guard is first in the arm loop ──────────────────
new_case
{ _gh_preamble; cat <<'GHEOF'
[[ "$1 $2" == "api user" ]] && { echo "repairman29"; exit 0; }
[[ "$1" == "api" ]] && { echo '{"auto_merge":null,"state":"open"}'; exit 0; }
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
GITHUB_REPOSITORY="repairman29/chump" PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/coord/auto-merge-armer.sh" --pr "$CUT_PR" --repo repairman29/chump >/dev/null 2>&1 || true
assert_no_mutation "auto-merge-armer.sh"
assert_honored "auto-merge-armer.sh"
end_case

# ── 2. pr-rescue-false-close.sh — guard is before the reopen ─────────────────
new_case
{ _gh_preamble; cat <<GHEOF
[[ "\$1 \$2 \$3" == "pr view $CUT_PR" ]] && { echo '{"state":"CLOSED","headRefName":"chump/zero-waste-135","title":"ZERO-WASTE-135 dup"}'; exit 0; }
GHEOF
cat <<'GHEOF'
[[ "$1" == "api" ]] && { echo '{}'; exit 0; }
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/coord/pr-rescue-false-close.sh" "$CUT_PR" --repo repairman29/chump >/dev/null 2>&1 || true
assert_no_mutation "pr-rescue-false-close.sh"
assert_honored "pr-rescue-false-close.sh"
end_case

# ── 3. auto-arm-sweeper.sh — guard first in loop; armer stubbed as recorder ──
new_case
ARMER_STUB="$CASE_TMP/armer.sh"
cat > "$ARMER_STUB" <<GHEOF
#!/usr/bin/env bash
printf 'MUTATE armer %s\n' "\$*" >> "$MUT"
exit 0
GHEOF
chmod +x "$ARMER_STUB"
{ _gh_preamble; cat <<GHEOF
[[ "\$1 \$2" == "api user" ]] && { echo "repairman29"; exit 0; }
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
cat <<'JSON'
[{"number":$CUT_PR,"title":"ZERO-WASTE-135 dup","isDraft":false,"mergeStateStatus":"CLEAN","autoMergeRequest":null,"labels":[{"name":"pr-cut"}],"headRefOid":"deadbeef"}]
JSON
exit 0
fi
GHEOF
cat <<'GHEOF'
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
CHUMP_AUTOARM_ARMER="$ARMER_STUB" CHUMP_AUTOARM_STATE="$CASE_TMP/state.tsv" \
    PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/ops/auto-arm-sweeper.sh" >/dev/null 2>&1 || true
assert_no_mutation "auto-arm-sweeper.sh"
assert_honored "auto-arm-sweeper.sh"
end_case

# ── 4. queue-driver.sh — guard first in the BEHIND loop; gh-fallback path ────
new_case
{ _gh_preamble; cat <<GHEOF
# BEHIND candidate list → the cut PR (jq -q is ignored; emit the number).
[[ "\$1" == "pr" && "\$2" == "list" ]] && { echo "$CUT_PR"; exit 0; }
GHEOF
cat <<'GHEOF'
[[ "$1" == "api" ]] && { echo '{}'; exit 0; }
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
CHUMP_CACHE_DB="$CASE_TMP/nope.db" GITHUB_REPOSITORY="repairman29/chump" \
    PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/coord/queue-driver.sh" --max 1 >/dev/null 2>&1 || true
assert_no_mutation "queue-driver.sh"
assert_honored "queue-driver.sh"
end_case

# ── 5. cascade-unblock-detector.sh — stale-sweep rebase; guard before rebase ─
new_case
{ _gh_preamble; cat <<GHEOF
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
cat <<'JSON'
[{"number":$CUT_PR,"mergeStateStatus":"BLOCKED","baseRefName":"main","headRefOid":"deadbeef"}]
JSON
exit 0
fi
[[ "\$1" == "api" ]] && { echo '{"behind_by":1,"merge_base_commit":{"sha":"base000"}}'; exit 0; }
GHEOF
cat <<'GHEOF'
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
CHUMP_UNBLOCK_TEST_GH="$STUB/gh" CHUMP_OPERATOR_COMMENT_WINDOW_S=0 \
    CHUMP_UNBLOCK_STATE="$CASE_TMP/cascade-state.tsv" CHUMP_REPO="$REPO_ROOT" \
    PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/coord/cascade-unblock-detector.sh" >/dev/null 2>&1 || true
assert_no_mutation "cascade-unblock-detector.sh"
assert_honored "cascade-unblock-detector.sh"
end_case

# ── 6. closed-pr-watchdog.sh — guard before the reopen ───────────────────────
new_case
cat > "$STUB/chump" <<'GHEOF'
#!/usr/bin/env bash
[[ "$1" == "gap" && "$2" == "show" ]] && { echo "  status: open"; exit 0; }
exit 0
GHEOF
chmod +x "$STUB/chump"
{ _gh_preamble; cat <<GHEOF
if [[ "\$1" == "api" ]]; then
  case "\$2" in
    repos/*/pulls\?state=closed*)
cat <<'JSON'
[{"number":$CUT_PR,"title":"ZERO-WASTE-135 dup","merged_at":null,"state":"closed","closed_at":"2026-10-17T18:13:30Z","head":{"ref":"chump/zero-waste-135"},"labels":[{"name":"pr-cut"}]}]
JSON
      exit 0 ;;
  esac
  echo '{}'; exit 0
fi
GHEOF
cat <<'GHEOF'
exit 0
GHEOF
} > "$STUB/gh"; chmod +x "$STUB/gh"
# HOME isolated so _chump falls back to the PATH stub (not ~/.cargo/bin/chump).
CHUMP_WATCHDOG_REOPEN=1 GITHUB_REPOSITORY="repairman29/chump" \
    CHUMP_WATCHDOG_LOOKBACK_HOURS=720 HOME="$CASE_TMP" \
    PATH="$STUB:$PATH" \
    bash "$REPO_ROOT/scripts/ops/closed-pr-watchdog.sh" >/dev/null 2>&1 || true
assert_no_mutation "closed-pr-watchdog.sh"
assert_honored "closed-pr-watchdog.sh"
end_case

# ── 7. pr-shepherd-daemon.sh — guard first after classification ──────────────
# The full classify pipeline needs live GH state; drive the identical guard the
# daemon's per-PR loop runs (same lib, same call), proving skip + emit.
new_case
(
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/coord/lib/pr-cut-guard.sh"
  pr_cut_honored "$CUT_PR" "pr-shepherd-daemon.sh" "mutate"
) && pass "pr-shepherd-daemon.sh guard skips the cut PR" \
   || fail "pr-shepherd-daemon.sh guard did NOT skip the cut PR"
assert_honored "pr-shepherd-daemon.sh"
# And assert the daemon actually wires the guard before its mutating verbs.
if grep -q 'pr-cut-guard.sh' "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh" \
   && grep -q 'pr_cut_honored' "$REPO_ROOT/scripts/coord/pr-shepherd-daemon.sh"; then
    pass "pr-shepherd-daemon.sh sources the guard and calls pr_cut_honored"
else
    fail "pr-shepherd-daemon.sh does not wire the guard"
fi
end_case

# ── Grep gate: new reopen/merge-auto call sites must reference the predicate ──
echo "== grep gate: reopen/merge-auto call sites reference the predicate =="
EXCEPTIONS="$REPO_ROOT/scripts/ci/pr-cut-guard-exceptions.txt"
mapfile -t _allow < <(grep -vE '^\s*(#|$)' "$EXCEPTIONS" 2>/dev/null | sed 's/#.*//;s/[[:space:]]*$//')
is_allowed() { local b; for b in "${_allow[@]}"; do [[ "$1" == "$b" ]] && return 0; done; return 1; }

gate_fail=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    grep -vE '^\s*#' "$f" | grep -qE 'gh pr reopen|chump_gh pr reopen|pr merge [^|]*--auto' || continue
    b="$(basename "$f")"
    grep -qE 'pr-cut|pr_cut_honored|pr_is_cut' "$f" && continue
    is_allowed "$b" && continue
    fail "grep gate: $f has a reopen/merge-auto call site but does not reference the pr-cut predicate and is not allowlisted"
    gate_fail=1
done < <(grep -rlE 'gh pr reopen|chump_gh pr reopen|pr merge .*--auto' \
            "$REPO_ROOT/scripts/coord" "$REPO_ROOT/scripts/ops" --include='*.sh' 2>/dev/null)
[[ "$gate_fail" -eq 0 ]] && pass "grep gate: no unguarded reopen/merge-auto call sites"

echo
if [[ "$FAILS" -eq 0 ]]; then
    echo "PASS: all organs honor pr-cut; grep gate clean"
    exit 0
fi
echo "FAIL: $FAILS check(s) failed"
exit 1
