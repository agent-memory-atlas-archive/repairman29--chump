#!/usr/bin/env bash
# shellcheck disable=SC2015  # `check && ok || bad`: ok() never fails
# scripts/ci/test-arm-policy.sh — RESILIENT-1613 (PHASE-R R3)
#
# One arm policy for every armer: a `no-auto-merge` label or an
# `Auto-merge: hold` line in the PR body/comments is honored by every armer.
# Receipt: #5494 was disarmed by the architect at 02:27Z and re-armed by the
# repairman29 token at 02:52:37Z, ten seconds after a force-push.
#
# Depth: (a) structural gate over every shell arm call site; (b) behavioural,
# stubbed gh: labeled / body-marker / comment-marker PRs are held (and emit
# pr_arm_skipped_hold), an unlabeled PR is allowed, gh failure fails open, a
# re-arm after a disarm emits pr_rearmed, and auto-merge-armer.sh end to end
# skips a labeled PR and arms an unlabeled one.
# Gaps: no live GitHub call; the Rust armers (crates/chump-ship, src/
# execute_gap.rs, ...) and the Python gap-gardener are not covered here.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
LIB="$REPO_ROOT/scripts/coord/lib/arm-policy.sh"
ALLOW="$REPO_ROOT/scripts/ci/arm-policy-allowlist.txt"
ARMER="$REPO_ROOT/scripts/coord/auto-merge-armer.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

[[ -f "$LIB" ]] || { echo "FAIL: $LIB missing" >&2; exit 1; }

# ── (a) every shell armer sources the policy ─────────────────────────────────
echo "[a] shell arm call sites must source arm-policy.sh"

# Executable `gh pr merge ... --auto` lines (not --auto-merge, not --disable-auto),
# excluding comments, operator-instruction strings and doc placeholders — the
# same heuristics as scripts/ci/test-no-direct-auto-merge-arm.sh.
arm_sites() {
    grep -rEn '(chump_)?gh pr merge[^|;#]*--auto([[:space:]]|$|")' scripts \
        --include='*.sh' 2>/dev/null \
    | while IFS= read -r line; do
        file="${line%%:*}"; rest="${line#*:}"; content="${rest#*:}"
        case "${file##*/}" in test-*) continue ;; esac
        trimmed="${content#"${content%%[![:space:]]*}"}"
        [[ "$trimmed" == "#"* ]] && continue
        printf '%s' "$trimmed" | grep -qE '^(red|green|yellow|info|log|say|echo|warn|err|printf)[[:space:]]+["'"'"']' && continue
        printf '%s' "$trimmed" | grep -qE '^["'"'"']' && continue
        # String assignment (msg="... gh pr merge --auto ..."), not a command.
        printf '%s' "$trimmed" | grep -qE '^(local[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=["'"'"']' && continue
        printf '%s' "$trimmed" | grep -qE '<[A-Z][A-Z#_-]*>|<[a-z][a-z_-]+>' && continue
        echo "$file"
    done | sort -u
}

allowed() { grep -qE "^${1//./\\.}([[:space:]]|$)" "$ALLOW" 2>/dev/null; }

sites="$(arm_sites)"
n_sites=0
while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    n_sites=$((n_sites + 1))
    if allowed "$f"; then
        ok "$f allowlisted ($(grep -E "^${f//./\\.}" "$ALLOW" | sed 's/.*# reason: //' | cut -c1-70))"
        continue
    fi
    if grep -qE '^[[:space:]]*(source|\.)[[:space:]].*arm-policy\.sh' "$f" \
        && grep -q 'arm_policy_allows' "$f"; then
        ok "$f sources arm-policy.sh and calls arm_policy_allows"
    else
        bad "$f calls gh pr merge --auto without sourcing scripts/coord/lib/arm-policy.sh + arm_policy_allows"
    fi
done <<<"$sites"
[[ "$n_sites" -ge 10 ]] && ok "found $n_sites shell arm call sites (sanity floor 10)" \
    || bad "only $n_sites shell arm call sites found — detector regex broke?"

# Shrink-only: every allowlist entry must still be a real, unwired arm site.
while IFS= read -r entry; do
    [[ -z "$entry" || "$entry" == \#* ]] && continue
    path="${entry%%[[:space:]]*}"
    if ! grep -qxF "$path" <<<"$sites"; then
        bad "allowlist entry $path is stale (no longer a direct arm site) — delete it"
    elif grep -q 'arm_policy_allows' "$path"; then
        bad "allowlist entry $path now calls arm_policy_allows — delete it"
    fi
done < "$ALLOW"

# The central armer and the sweeper (which route bot-merge, pr-repair-rebase,
# trunk-recovery-reviver, rot-reaper arms) must call the policy too.
for f in scripts/coord/auto-merge-armer.sh scripts/ops/auto-arm-sweeper.sh scripts/ops/pr-repair-rebase.sh; do
    grep -q 'arm_policy_allows' "$f" && ok "$f calls arm_policy_allows" \
        || bad "$f does not call arm_policy_allows"
done

# Emit sites carry the literal kinds; both are registered.
for k in pr_arm_skipped_hold pr_rearmed; do
    grep -q "\"kind\":\"$k\"" "$LIB" && ok "literal \"kind\":\"$k\" at emit site" \
        || bad "no literal \"kind\":\"$k\" in $LIB"
    grep -q "kind: $k\$" docs/observability/EVENT_REGISTRY.yaml && ok "$k registered" \
        || bad "$k missing from EVENT_REGISTRY.yaml"
done

# ── (b) behaviour with a stubbed gh ──────────────────────────────────────────
echo "[b] stubbed gh: held PRs are skipped, unlabeled PRs armed"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
export STUB_LOG="$TMP/gh.log"
: >"$STUB_LOG"

# PR fixtures (gh pr view --json labels,body,comments shape):
#   101 labeled no-auto-merge   102 unlabeled, clean   103 body marker
#   104 comment marker          105 gh view fails      106 legacy `hold` label
#   107 "Auto-merge: holding" (not a hold)
cat >"$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
args="$*"
pr_of() { grep -oE '(^| )(10[0-9])( |$)' <<<"$1" | tr -d ' ' | head -1; }
if [[ "$1 $2" == "pr view" ]]; then
    n="$(pr_of "$args")"
    if [[ "$args" == *"labels,body,comments"* ]]; then
        case "$n" in
            101) echo '{"labels":[{"name":"No-Auto-Merge"}],"body":"x","comments":[]}' ;;
            102) echo '{"labels":[{"name":"pr:parallel-safe"}],"body":"plain","comments":[{"body":"lgtm"}]}' ;;
            103) printf '%s\n' '{"labels":[],"body":"Summary\nauto-merge: HOLD until CREDIBLE-1508","comments":[]}' ;;
            104) echo '{"labels":[],"body":"plain","comments":[{"body":"Architect: Auto-merge: hold"},{"body":"  Auto-merge: hold"}]}' ;;
            105) exit 1 ;;
            106) echo '{"labels":[{"name":"hold"}],"body":"","comments":[]}' ;;
            107) echo '{"labels":[],"body":"Auto-merge: holding pattern explained","comments":[]}' ;;
            *) echo '{"labels":[],"body":"","comments":[]}' ;;
        esac
        exit 0
    fi
    if [[ "$args" == *statusCheckRollup* ]]; then echo '{"statusCheckRollup":[]}'; exit 0; fi
    exit 0
fi
if [[ "$1" == "api" ]]; then
    case "$args" in
        *"/issues/102/timeline"*) printf 'auto_squash_enabled\trepairman29\t2026-10-17T02:20:25Z\nauto_merge_disabled\tarchitect\t2026-10-17T02:27:18Z\n' ;;
        *timeline*) : ;;
        *"auto_merge != null"*)
            n="$(grep -oE 'pulls/[0-9]+' <<<"$args" | grep -oE '[0-9]+')"
            if grep -q "^ARMED $n\$" "$STUB_LOG.arms" 2>/dev/null; then echo true; else echo false; fi ;;
        *".state"*) echo open ;;
        *".head.sha"*) echo deadbeefcafe ;;
        *check-runs*) echo '{"check_runs":[]}' ;;
        *graphql*) echo false ;;
        *) : ;;
    esac
    exit 0
fi
if [[ "$1 $2" == "pr merge" ]]; then echo "ARMED $(pr_of "$args")" >>"$STUB_LOG.arms"; exit 0; fi
exit 0
GH
chmod +x "$TMP/bin/gh"

export PATH="$TMP/bin:$PATH"
export CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl"
export CHUMP_CACHE_DB="$TMP/nonexistent-cache.db"   # force the gh fallback path
: >"$CHUMP_AMBIENT_LOG"

# Run in a subshell per call so the double-source guard does not leak.
# shellcheck source=scripts/coord/lib/arm-policy.sh
allows() { ( unset _CHUMP_ARM_POLICY_SOURCED; source "$LIB"; arm_policy_allows "$@" ) 2>/dev/null; }

for spec in "101:held:label:No-Auto-Merge" "103:held:marker:body" "104:held:marker:comment" "106:held:label:hold" \
            "102:allowed" "105:allowed" "107:allowed"; do
    IFS=: read -r pr want reason_k reason_v <<<"$spec"
    if allows "$pr" "test-armer" "o/r"; then got=allowed; else got=held; fi
    if [[ "$got" == "$want" ]]; then
        ok "PR $pr → $got${reason_k:+ ($reason_k:$reason_v)}"
    else
        bad "PR $pr → $got, want $want"
    fi
    if [[ "$want" == held ]]; then
        grep -q "\"kind\":\"pr_arm_skipped_hold\",\"pr\":$pr,\"armer\":\"test-armer\",\"reason\":\"$reason_k:$reason_v\"" "$CHUMP_AMBIENT_LOG" \
            && ok "PR $pr emitted pr_arm_skipped_hold reason=$reason_k:$reason_v" \
            || bad "PR $pr: no pr_arm_skipped_hold with reason $reason_k:$reason_v in ambient"
    fi
done

grep -q '"kind":"pr_rearmed","pr":102,"armer":"test-armer","disarm_actor":"architect","disarmed_at":"2026-10-17T02:27:18Z"' "$CHUMP_AMBIENT_LOG" \
    && ok "PR 102 (last timeline event = disarm) emitted pr_rearmed naming armer + disarm actor" \
    || bad "PR 102: pr_rearmed missing"
grep -q '"kind":"pr_rearmed","pr":107' "$CHUMP_AMBIENT_LOG" \
    && bad "PR 107 has no disarm in its timeline but emitted pr_rearmed" \
    || ok "no pr_rearmed for a PR whose timeline has no disarm"
CHUMP_ARM_POLICY_REARM_AUDIT=0 allows 102 "audit-off" "o/r" || true
grep -q '"armer":"audit-off"' "$CHUMP_AMBIENT_LOG" \
    && bad "CHUMP_ARM_POLICY_REARM_AUDIT=0 still emitted pr_rearmed" \
    || ok "CHUMP_ARM_POLICY_REARM_AUDIT=0 skips the timeline lookup"

# End to end through the central armer: labeled 101 skipped, unlabeled 102 armed.
: >"$STUB_LOG.arms"
CHUMP_AUTO_MERGE_SPACING_S=0 CHUMP_AUTO_MERGE_REST_DIRECT=0 CHUMP_MERGE_QUEUE_ENABLED=0 \
GITHUB_REPOSITORY="o/r" LOCKS_DIR="$TMP" \
    bash "$ARMER" --pr 101 --pr 102 >"$TMP/armer.out" 2>&1 || true
if grep -q '^ARMED 101' "$STUB_LOG.arms"; then
    bad "auto-merge-armer.sh armed held PR 101"
else
    ok "auto-merge-armer.sh did not arm labeled PR 101"
fi
if grep -q '^ARMED 102' "$STUB_LOG.arms"; then
    ok "auto-merge-armer.sh armed unlabeled PR 102"
else
    bad "auto-merge-armer.sh did not arm unlabeled PR 102 (out: $(tr '\n' ' ' <"$TMP/armer.out" | cut -c1-300))"
fi
grep -q 'PR #101: held' "$TMP/armer.out" && ok "armer logged the hold for PR 101" \
    || bad "armer did not log the hold for PR 101"

echo
echo "=== test-arm-policy: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
