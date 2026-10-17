#!/usr/bin/env bash
# test-subagent-pre-exit-check.sh — INFRA-1953, made hermetic by CREDIBLE-1518
#
# Drives scripts/dispatch/subagent-pre-exit-check.sh against a throwaway git
# repo with a bare origin and a stubbed `gh` on PATH. No network, no real
# ambient stream.
#
# Assertions:
#   1. missing branch arg                        → exit 4
#   2. branch not on origin                      → exit 3 + emit
#   3. branch on origin, no PR                   → exit 1 + emit
#   4. PR armed (gh GraphQL shape: mergeMethod)  → exit 0, NO emit   (CREDIBLE-1518)
#   5. PR armed (gh-shim shape: both fields)     → exit 0, NO emit
#   6. PR unarmed (autoMergeRequest: null)       → exit 2 + emit reason auto_merge_not_armed
#   7. debounce: second failing call within 5min on the same session does not re-emit

set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
HELPER="$ROOT/scripts/dispatch/subagent-pre-exit-check.sh"

if ! command -v jq >/dev/null 2>&1; then
    echo "FAIL: jq is required (the gh stub applies --jq with it)" >&2
    exit 1
fi

WORK="$(mktemp -d -t chump-pre-exit-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }

# ── fixture repo with a bare origin ─────────────────────────────────────────
git init -q --bare "$WORK/origin.git"
git init -q "$WORK/repo"
(
    cd "$WORK/repo"
    git config user.email t@example.com
    git config user.name t
    git config commit.gpgsign false
    git commit -q --allow-empty -m init
    git remote add origin "$WORK/origin.git"
    git push -q origin HEAD:refs/heads/feat-armed
    git push -q origin HEAD:refs/heads/feat-noPR
)
mkdir -p "$WORK/repo/.chump-locks"
AMBIENT="$WORK/repo/.chump-locks/ambient.jsonl"
: > "$AMBIENT"

# ── gh stub: serves fixtures, applies --jq with real jq ─────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
# Fixture-driven gh stub. GH_STUB_PR_COUNT = open PRs for the branch;
# GH_STUB_VIEW_JSON = the `gh pr view --json autoMergeRequest` document.
jq_expr="."
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "--jq" ]] && jq_expr="${args[$((i + 1))]}"
done
case "$1 $2" in
    "pr list")
        if [[ "${GH_STUB_PR_COUNT:-0}" -gt 0 ]]; then doc='[{"number":4242}]'; else doc='[]'; fi
        ;;
    "pr view")
        doc="${GH_STUB_VIEW_JSON:-{\"autoMergeRequest\":null}}"
        ;;
    *)
        echo "gh stub: unexpected call: $*" >&2
        exit 1
        ;;
esac
printf '%s' "$doc" | jq -r "$jq_expr"
STUB
chmod +x "$WORK/bin/gh"

ARMED_GQL='{"autoMergeRequest":{"authorEmail":null,"commitBody":null,"commitHeadline":null,"mergeMethod":"SQUASH","enabledAt":"2026-10-17T20:50:00Z","enabledBy":{"login":"repairman29"}}}'
ARMED_SHIM='{"autoMergeRequest":{"merge_method":"squash","mergeMethod":"SQUASH","enabled_by":{"login":"repairman29"}}}'
UNARMED='{"autoMergeRequest":null}'

# run <session> <branch> [env...] → sets RC, OUT
run() {
    local sess="$1" branch="$2"
    shift 2
    OUT="$(cd "$WORK/repo" && env PATH="$WORK/bin:$PATH" TMPDIR="$WORK" \
        CHUMP_SESSION_ID="$sess" "$@" bash "$HELPER" "$branch" 2>&1)"
    RC=$?
}
emits() { grep -c '"kind":"subagent_idle_without_pr"' "$AMBIENT" 2>/dev/null || true; }

echo "== subagent pre-exit check (INFRA-1953 / CREDIBLE-1518) =="

# 1
OUT="$(cd "$WORK/repo" && PATH="$WORK/bin:$PATH" bash "$HELPER" 2>&1)"; RC=$?
[[ "$RC" -eq 4 ]] && ok "1 no branch arg exits 4" || ko "1 expected 4, got $RC"

# 2
before=$(emits)
run "s-missing-$$" "feat-not-pushed"
after=$(emits)
[[ "$RC" -eq 3 && "$after" -gt "$before" ]] && ok "2 branch not on origin exits 3 and emits" \
    || ko "2 expected 3 + emit, got rc=$RC emits ${before}->${after}: $OUT"

# 3
before=$(emits)
run "s-nopr-$$" "feat-noPR" GH_STUB_PR_COUNT=0
after=$(emits)
[[ "$RC" -eq 1 && "$after" -gt "$before" ]] && ok "3 no PR exits 1 and emits" \
    || ko "3 expected 1 + emit, got rc=$RC emits ${before}->${after}: $OUT"

# 4
before=$(emits)
run "s-armed-$$" "feat-armed" GH_STUB_PR_COUNT=1 GH_STUB_VIEW_JSON="$ARMED_GQL"
after=$(emits)
[[ "$RC" -eq 0 ]] && ok "4 armed PR (gh mergeMethod shape) exits 0" || ko "4 expected 0, got $RC: $OUT"
[[ "$after" -eq "$before" ]] && ok "4 armed PR emits no subagent_idle_without_pr" \
    || ko "4 armed PR emitted subagent_idle_without_pr (${before}->${after})"
case "$OUT" in
    *"auto-merge=SQUASH"*) ok "4 OK line names the merge method" ;;
    *) ko "4 OK line missing auto-merge=SQUASH: $OUT" ;;
esac

# 5
before=$(emits)
run "s-shim-$$" "feat-armed" GH_STUB_PR_COUNT=1 GH_STUB_VIEW_JSON="$ARMED_SHIM"
after=$(emits)
[[ "$RC" -eq 0 && "$after" -eq "$before" ]] && ok "5 armed PR (gh-shim shape) exits 0, no emit" \
    || ko "5 expected 0 and no emit, got rc=$RC emits ${before}->${after}: $OUT"

# 6
before=$(emits)
run "s-unarmed-$$" "feat-armed" GH_STUB_PR_COUNT=1 GH_STUB_VIEW_JSON="$UNARMED"
after=$(emits)
[[ "$RC" -eq 2 ]] && ok "6 unarmed PR exits 2" || ko "6 expected 2, got $RC: $OUT"
last_reason="$(tail -1 "$AMBIENT" | jq -r '.reason' 2>/dev/null)"
[[ "$after" -gt "$before" && "$last_reason" == "auto_merge_not_armed" ]] \
    && ok "6 unarmed PR emits reason auto_merge_not_armed" \
    || ko "6 expected emit with auto_merge_not_armed, got emits ${before}->${after} reason=$last_reason"

# 7
run "s-debounce-$$" "feat-armed" GH_STUB_PR_COUNT=1 GH_STUB_VIEW_JSON="$UNARMED"
first=$(emits)
run "s-debounce-$$" "feat-armed" GH_STUB_PR_COUNT=1 GH_STUB_VIEW_JSON="$UNARMED"
second=$(emits)
[[ "$RC" -eq 2 && "$second" -eq "$first" ]] && ok "7 debounce: second call in window does not re-emit" \
    || ko "7 debounce failed: rc=$RC emits ${first}->${second}"

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
