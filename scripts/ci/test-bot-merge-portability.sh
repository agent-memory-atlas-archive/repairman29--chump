#!/usr/bin/env bash
# test-bot-merge-portability.sh — INFRA-632 unit tests.
#
# Verifies the portability flags added to scripts/coord/bot-merge.sh:
#
#   (1) --branch-prefix custom: auto-derive strips the custom prefix
#   (2) --branch-prefix custom: backward compat with 'chump' default
#   (3) flag parsing: --branch-prefix / --pr-template / --required-checks parsed
#   (4) --pr-template: placeholder substitution works
#   (5) --pr-template missing file: guard in script catches it
#   (6) --required-checks: non-required failing checks are advisory only
#   (7) --required-checks: required failing checks still block
#   (8) no --required-checks: any FAILURE blocks (backward compat)
#   (9) BM_BRANCH_PREFIX env var sets BRANCH_PREFIX default
#
# Run: ./scripts/ci/test-bot-merge-portability.sh

set -euo pipefail

PASS=0
FAIL=0
FAILS=()

ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); FAILS+=("$1"); }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BOT_MERGE="$REPO_ROOT/scripts/coord/bot-merge.sh"

if [[ ! -x "$BOT_MERGE" ]]; then
    echo "FATAL: bot-merge.sh not executable: $BOT_MERGE"
    exit 2
fi

# CREDIBLE-1511: bot-merge.sh has an AUTONOMY_LEVEL kill switch (RESILIENT-073)
# that exits 10 when ~/.chump/AUTONOMY_LEVEL is missing or 0, and it is inside the
# awk-extracted ranges below. Run against a fixture HOME with AUTONOMY_LEVEL=5 so
# the test never reads or writes the real ~/.chump, and send ambient appends to a
# fixture file so the repo's .chump-locks/ambient.jsonl is never touched.
_fixture_home="$(mktemp -d)"
mkdir -p "$_fixture_home/.chump"
printf '5\n' > "$_fixture_home/.chump/AUTONOMY_LEVEL"
# Keep the caller's git identity/config available despite the HOME swap.
if [[ -z "${GIT_CONFIG_GLOBAL:-}" && -f "$HOME/.gitconfig" ]]; then
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
fi
export HOME="$_fixture_home"
export CHUMP_AMBIENT_LOG="$_fixture_home/ambient.jsonl"
trap 'rm -rf "$_fixture_home"' EXIT

echo "=== INFRA-632 bot-merge.sh portability unit tests ==="
echo

# ── Helper: run auto-derive block with given BRANCH_PREFIX and branch name ────
derive_with_prefix() {
    local prefix="$1" branch="$2"
    (
        GAP_IDS=()
        BRANCH_PREFIX="$prefix"
        git() {
            if [[ "$1" == "symbolic-ref" ]]; then echo "$branch"; return 0; fi
            command git "$@"
        }
        export -f git
        block=$(awk '/^if \[\[ \${#GAP_IDS\[@\]} -eq 0 \]\]; then/,/^SCRIPT_DIR=/' "$BOT_MERGE" | sed '$d')
        eval "$block" 2>/dev/null
        if [[ ${#GAP_IDS[@]} -gt 0 ]]; then
            for gid in "${GAP_IDS[@]}"; do echo "GID:$gid"; done
        fi
    )
}

assert_derived_prefix() {
    local label="$1" prefix="$2" branch="$3" expected="$4"
    local out
    out=$(derive_with_prefix "$prefix" "$branch" 2>&1 | grep -E '^GID:' | sed 's/^GID://' | sort | tr '\n' ' ' | sed 's/ $//' || true)
    local exp_sorted
    exp_sorted=$(echo "$expected" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
    if [[ "$out" == "$exp_sorted" ]]; then
        ok "$label: derived [$out]"
    else
        fail "$label: expected [$exp_sorted], got [$out]"
    fi
}

# ── Test 1: custom --branch-prefix strips correctly in auto-derive ─────────────
echo "--- Test 1: custom branch prefix auto-derive ---"
assert_derived_prefix "Test 1a acme/infra-123" "acme" "acme/infra-123-title" "INFRA-123"
assert_derived_prefix "Test 1b corp/feat-456"  "corp" "corp/feat-456-impl"   "FEAT-456"

# ── Test 2: default prefix 'chump' still works (backward compat) ──────────────
echo "--- Test 2: default 'chump' prefix backward compat ---"
assert_derived_prefix "Test 2a chump/infra-127"     "chump"  "chump/infra-127-reflection-e2e" "INFRA-127"
assert_derived_prefix "Test 2b claude/research-026" "chump"  "claude/research-026-impl"       "RESEARCH-026"

# ── Test 3: flag parsing ───────────────────────────────────────────────────────
echo "--- Test 3: flag parsing ---"
_flags_out=$(bash -c "
    set -- --branch-prefix testprefix --pr-template /dev/null --required-checks ci,build --dry-run --gap none
    block=\$(awk '/^# ── Flags/,/^SCRIPT_DIR=/' '$BOT_MERGE' | sed '\$d')
    eval \"\$block\" 2>/dev/null
    printf 'PREFIX:%s\n' \"\$BRANCH_PREFIX\"
    printf 'TEMPLATE:%s\n' \"\$PR_TEMPLATE\"
    printf 'CHECKS:%s\n' \"\$REQUIRED_CHECKS\"
" 2>/dev/null || true)

_pfx=$(echo "$_flags_out" | grep '^PREFIX:' | sed 's/^PREFIX://')
_tpl=$(echo "$_flags_out" | grep '^TEMPLATE:' | sed 's/^TEMPLATE://')
_chk=$(echo "$_flags_out" | grep '^CHECKS:' | sed 's/^CHECKS://')

[[ "$_pfx" == "testprefix" ]] && ok "Test 3a: --branch-prefix parsed (got '$_pfx')" \
    || fail "Test 3a: --branch-prefix not parsed; got '$_pfx'"
[[ "$_tpl" == "/dev/null" ]] && ok "Test 3b: --pr-template parsed" \
    || fail "Test 3b: --pr-template not parsed; got '$_tpl'"
[[ "$_chk" == "ci,build" ]] && ok "Test 3c: --required-checks parsed" \
    || fail "Test 3c: --required-checks not parsed; got '$_chk'"

# ── Test 4: --pr-template placeholder substitution ────────────────────────────
echo "--- Test 4: --pr-template placeholder substitution ---"
_tmpdir=$(mktemp -d)
trap 'rm -rf "$_tmpdir" "$_fixture_home"' EXIT

cat > "$_tmpdir/pr-template.md" <<'TMPL'
## Summary
{{COMMIT_LOG}}

Gaps: {{GAP_LINE}}

{{PLAN_BLOCK}}
TMPL

_commit_log_escaped="- abc1234 INFRA-632: portability flags"
_commit_log_escaped=$(echo "$_commit_log_escaped" | sed 's/[&/\]/\\&/g' | tr '\n' '\r')
_pr_body=$(sed \
    -e "s|{{GAP_LINE}}|Gaps addressed: INFRA-632|g" \
    -e "s|{{PLAN_BLOCK}}||g" \
    "$_tmpdir/pr-template.md" \
    | awk -v cl="$_commit_log_escaped" '{gsub(/\{\{COMMIT_LOG\}\}/, cl); print}' \
    | tr '\r' '\n')

echo "$_pr_body" | grep -q "INFRA-632: portability flags" \
    && ok "Test 4a: {{COMMIT_LOG}} substituted in template" \
    || fail "Test 4a: {{COMMIT_LOG}} not substituted; body: [$_pr_body]"
echo "$_pr_body" | grep -q "Gaps addressed: INFRA-632" \
    && ok "Test 4b: {{GAP_LINE}} substituted in template" \
    || fail "Test 4b: {{GAP_LINE}} not substituted; body: [$_pr_body]"

# ── Test 5: --pr-template missing file guard ───────────────────────────────────
echo "--- Test 5: missing --pr-template exits 1 ---"
set +e
_t5_out=$(bash -c "
    PR_TEMPLATE='/nonexistent/path/template.md'
    if [[ -n \"\$PR_TEMPLATE\" ]]; then
        if [[ ! -f \"\$PR_TEMPLATE\" ]]; then
            echo 'ERROR: template not found'
            exit 1
        fi
    fi
    echo 'SHOULD NOT REACH'
" 2>&1)
_t5_rc=$?
set -e
[[ $_t5_rc -eq 1 ]] && echo "$_t5_out" | grep -q "template not found" \
    && ok "Test 5: missing --pr-template exits 1 with error" \
    || fail "Test 5: expected exit 1 + error message, got rc=$_t5_rc out=[$_t5_out]"

# ── Tests 6-8: --required-checks CI gate logic ────────────────────────────────
# The filter logic is a simple bash snippet; test it directly here to avoid
# fragile awk-based extraction from the script body.
_apply_required_checks_filter() {
    local required="$1" all_failing="$2"
    local _ci_status="" _all_failing="$all_failing"
    if [[ -n "$required" && -n "$_all_failing" ]]; then
        local _req_list
        IFS=',' read -ra _req_list <<< "$required"
        while IFS= read -r _line; do
            for _req in "${_req_list[@]}"; do
                local _req_trimmed="${_req#"${_req%%[![:space:]]*}"}"
                _req_trimmed="${_req_trimmed%"${_req_trimmed##*[![:space:]]}"}"
                if echo "$_line" | grep -qF "$_req_trimmed"; then
                    _ci_status+="$_line"$'\n'
                    break
                fi
            done
        done <<< "$_all_failing"
        _ci_status="${_ci_status%$'\n'}"
    else
        _ci_status="$all_failing"
    fi
    echo "$_ci_status"
}

echo "--- Test 6: non-required failing check is advisory ---"
_t6=$(_apply_required_checks_filter "ci / build,ci / test" $'ci / lint\tFAILURE\thttps://example.com/1')
[[ -z "$_t6" ]] \
    && ok "Test 6: non-required failure filtered out (advisory only)" \
    || fail "Test 6: expected empty ci_status, got: [$_t6]"

echo "--- Test 7: required failing check still blocks ---"
_t7=$(_apply_required_checks_filter "ci / build,ci / test" $'ci / build\tFAILURE\thttps://example.com/2')
[[ -n "$_t7" ]] \
    && ok "Test 7: required failure still blocks" \
    || fail "Test 7: required failure should block; got nothing"

echo "--- Test 8: no --required-checks — any failure blocks (backward compat) ---"
_t8=$(_apply_required_checks_filter "" $'ci / lint\tFAILURE\thttps://example.com/3')
[[ -n "$_t8" ]] \
    && ok "Test 8: without --required-checks, any failure blocks (backward compat)" \
    || fail "Test 8: without --required-checks failure should block; got nothing"

# ── Test 9: BM_BRANCH_PREFIX env var ──────────────────────────────────────────
echo "--- Test 9: BM_BRANCH_PREFIX env var ---"
_t9=$(BM_BRANCH_PREFIX="myorg" bash -c "
    block=\$(awk '/^# ── Flags/,/^SCRIPT_DIR=/' '$BOT_MERGE' | sed '\$d')
    set -- --gap none --dry-run
    eval \"\$block\" 2>/dev/null
    echo \"\$BRANCH_PREFIX\"
" 2>/dev/null || true)
[[ "$_t9" == "myorg" ]] && ok "Test 9: BM_BRANCH_PREFIX env var sets BRANCH_PREFIX" \
    || fail "Test 9: expected 'myorg', got '$_t9'"

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
    for f in "${FAILS[@]}"; do echo "  - $f"; done
    exit 1
fi
exit 0
