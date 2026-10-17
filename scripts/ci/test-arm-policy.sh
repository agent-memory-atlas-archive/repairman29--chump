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
# INFRA-8221 (shell slice) adds [c]: end-to-end with a stubbed gh and real throwaway
# git repos, armed-pr-rebaser.sh / pr-repair-rebase.sh leave a held PR's branch
# untouched while rebasing an unheld one, merge-serializer.sh and
# pr-approval-action.sh refuse to merge a held PR (and merge an unheld one), and
# closed-pr-watchdog.sh does not reopen a pr-cut / hold-labeled PR.
# Gaps: no live GitHub call; the Rust armers (crates/chump-ship, src/
# execute_gap.rs, ...) and the Python gap-gardener are not covered here (slice 2);
# the serializer's verified wait is stubbed to an instant SUCCESS.

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
# INFRA-8221: plus the rebaser, the two direct mergers, the repair loop and the
# reopener, which mutate a PR without (necessarily) calling `gh pr merge --auto`.
for f in scripts/coord/auto-merge-armer.sh scripts/ops/auto-arm-sweeper.sh scripts/ops/pr-repair-rebase.sh \
         scripts/coord/armed-pr-rebaser.sh scripts/coord/merge-serializer.sh scripts/ops/pr-approval-action.sh; do
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
            109)
                # Stateful (INFRA-8221): clean on the first policy read, HELD from the
                # second on, i.e. a hold placed while the serializer waits for verified.
                c=0; [[ -f "$STUB_LOG.n109" ]] && c="$(cat "$STUB_LOG.n109")"
                echo $((c + 1)) >"$STUB_LOG.n109"
                if [[ "$c" -ge 1 ]]; then echo '{"labels":[{"name":"no-auto-merge"}],"body":"","comments":[]}'
                else echo '{"labels":[],"body":"","comments":[]}'; fi ;;
            *) echo '{"labels":[],"body":"","comments":[]}' ;;
        esac
        exit 0
    fi
    if [[ "$args" == *"state,title"* ]]; then echo '{"state":"OPEN","title":"stub pr","url":"https://example.invalid/pr","isDraft":false}'; exit 0; fi
    if [[ "$args" == *statusCheckRollup* ]]; then
        if [[ "$args" == *--jq* ]]; then echo SUCCESS; else echo '{"statusCheckRollup":[]}'; fi
        exit 0
    fi
    exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
    if [[ "$args" == *--jq* ]]; then cat "$STUB_CANDS" 2>/dev/null; else cat "$STUB_PRLIST" 2>/dev/null; fi
    exit 0
fi
if [[ "$1 $2" == "pr checks" ]]; then printf 'test\tfail\t1m\thttps://example.invalid\n'; exit 0; fi
if [[ "$1" == "api" ]]; then
    case "$args" in
        *"pulls?state=closed"*) cat "$STUB_CLOSED" 2>/dev/null ;;
        *"-X PATCH"*) echo "REOPEN $(grep -oE 'pulls/[0-9]+' <<<"$args" | grep -oE '[0-9]+')" >>"$STUB_LOG.reopens" ;;
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
if [[ "$1 $2" == "pr merge" ]]; then
    [[ "$args" == *--disable-auto* ]] && exit 0
    if [[ "$args" == *--auto* ]]; then echo "ARMED $(pr_of "$args")" >>"$STUB_LOG.arms"
    else echo "MERGED $(pr_of "$args")" >>"$STUB_LOG.merges"; fi
    exit 0
fi
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

# ── (c) INFRA-8221: rebaser, repair loop, direct mergers, reopener ────────────
echo "[c] stubbed gh + throwaway git repos: held PRs are not rebased, merged or reopened"

export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_SYSTEM=/dev/null
: >"$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export STUB_PRLIST="$TMP/prlist.json" STUB_CANDS="$TMP/cands.tsv" STUB_CLOSED="$TMP/closed.json"
export CHUMP_MERGE_PIPELINE_LOCK_FILE="$TMP/mpl.lock"
export CHUMP_AUTO_MERGE_SPACING_S=0 CHUMP_AUTO_MERGE_REST_DIRECT=0 CHUMP_MERGE_QUEUE_ENABLED=0

# mkfix <dir>: bare origin + clone; branches heldbr/okbr fork from an older main.
mkfix() {
    local d="$1"
    rm -rf "$d"; mkdir -p "$d"
    git init -q --bare "$d/origin.git"
    git -C "$d/origin.git" symbolic-ref HEAD refs/heads/main
    git clone -q "$d/origin.git" "$d/clone" >/dev/null 2>&1
    (
        cd "$d/clone"
        git checkout -q -B main
        echo base >base.txt; git add -A; git commit -qm base; git push -q origin main
        for b in heldbr okbr; do
            git checkout -q -B "$b" main; echo "$b" >"$b.txt"; git add -A; git commit -qm "$b"
            git push -q origin "$b"
        done
        git checkout -q main; echo adv >adv.txt; git add -A; git commit -qm adv; git push -q origin main
    ) >/dev/null 2>&1
}
sha() { git -C "$1/origin.git" rev-parse "$2"; }
descends_main() { git -C "$1/origin.git" merge-base --is-ancestor main "$2" 2>/dev/null; }
held_event() { grep -q "\"kind\":\"pr_arm_skipped_hold\",\"pr\":$1,\"armer\":\"$2\"" "$CHUMP_AMBIENT_LOG"; }

# c1. armed-pr-rebaser.sh: held 101 untouched, unheld 108 rebased onto main.
F1="$TMP/fix-rebaser"; mkfix "$F1"
H0="$(sha "$F1" heldbr)"; O0="$(sha "$F1" okbr)"
cat >"$STUB_PRLIST" <<'J'
[{"number":101,"mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledBy":{"login":"x"}},"headRefName":"heldbr","labels":[],"statusCheckRollup":[]},
 {"number":108,"mergeStateStatus":"BEHIND","autoMergeRequest":{"enabledBy":{"login":"x"}},"headRefName":"okbr","labels":[],"statusCheckRollup":[]}]
J
CHUMP_REPO_ROOT="$F1/clone" CHUMP_PR_REPO=o/r bash "$REPO_ROOT/scripts/coord/armed-pr-rebaser.sh" >"$TMP/rebaser.out" 2>&1 || true
[[ "$(sha "$F1" heldbr)" == "$H0" ]] && ok "armed-pr-rebaser: held PR 101 branch not force-pushed" \
    || bad "armed-pr-rebaser: held PR 101 branch was rebased/force-pushed"
if [[ "$(sha "$F1" okbr)" != "$O0" ]] && descends_main "$F1" okbr; then
    ok "armed-pr-rebaser: unheld PR 108 rebased onto main and pushed"
else
    bad "armed-pr-rebaser: unheld PR 108 not rebased (out: $(tr '\n' ' ' <"$TMP/rebaser.out" | cut -c1-300))"
fi
held_event 101 armed-pr-rebaser.sh && ok "armed-pr-rebaser: emitted pr_arm_skipped_hold for 101" \
    || bad "armed-pr-rebaser: no pr_arm_skipped_hold for 101"
grep -q 'pr_rearmed","pr":10[18],"armer":"armed-pr-rebaser.sh"' "$CHUMP_AMBIENT_LOG" \
    && bad "armed-pr-rebaser: logged a pr_rearmed for an already-armed PR" \
    || ok "armed-pr-rebaser: no spurious pr_rearmed for already-armed PRs"

# c2. pr-repair-rebase.sh (the 30-min re-armer): held 101 skipped entirely.
F2="$TMP/fix-repair"; mkfix "$F2"
H0="$(sha "$F2" heldbr)"; O0="$(sha "$F2" okbr)"
cat >"$STUB_PRLIST" <<'J'
[{"number":101,"headRefName":"heldbr","createdAt":"2020-01-01T00:00:00Z","autoMergeRequest":null},
 {"number":108,"headRefName":"okbr","createdAt":"2020-01-01T00:00:00Z","autoMergeRequest":null}]
J
( cd "$F2/clone" && CHUMP_WORKTREE_BASE="$TMP/repair-wt" bash "$REPO_ROOT/scripts/ops/pr-repair-rebase.sh" ) >"$TMP/repair.out" 2>&1 || true
[[ "$(sha "$F2" heldbr)" == "$H0" ]] && ok "pr-repair-rebase: held PR 101 not rebased or force-pushed" \
    || bad "pr-repair-rebase: held PR 101 branch was force-pushed"
[[ ! -e "$F2/clone/.chump-locks/pr-repair-cooldown/101.ts" ]] && ok "pr-repair-rebase: held PR 101 consumed no cooldown" \
    || bad "pr-repair-rebase: held PR 101 got a cooldown stamp (it was processed)"
if [[ "$(sha "$F2" okbr)" != "$O0" ]] && descends_main "$F2" okbr; then
    ok "pr-repair-rebase: unheld PR 108 rebased and pushed"
else
    bad "pr-repair-rebase: unheld PR 108 not rebased (out: $(tr '\n' ' ' <"$TMP/repair.out" | cut -c1-300))"
fi
held_event 101 pr-repair-rebase.sh && ok "pr-repair-rebase: emitted pr_arm_skipped_hold for 101" \
    || bad "pr-repair-rebase: no pr_arm_skipped_hold for 101"

# c3. merge-serializer.sh: held 101 never rebased or merged; unheld 108 merged.
F3="$TMP/fix-serializer"; mkfix "$F3"
H0="$(sha "$F3" heldbr)"
: >"$STUB_LOG.merges"
printf '101\theldbr\tBEHIND\t2020-01-01T00:00:00Z\n108\tokbr\tBEHIND\t2020-01-02T00:00:00Z\n' >"$STUB_CANDS"
CHUMP_REPO_ROOT="$F3/clone" CHUMP_PR_REPO=o/r CHUMP_LOCK_DIR="$TMP/ser-locks" \
CHUMP_MERGE_SERIALIZER_TRUNK_GATE=0 CHUMP_MERGE_SERIALIZER_MAX_MERGES=2 CHUMP_MERGE_SERIALIZER_LOCK_WAIT_S=5 \
    bash "$REPO_ROOT/scripts/coord/merge-serializer.sh" >"$TMP/ser.out" 2>&1 || true
[[ "$(sha "$F3" heldbr)" == "$H0" ]] && ok "merge-serializer: held PR 101 not rebased or force-pushed" \
    || bad "merge-serializer: held PR 101 branch was force-pushed"
grep -q '^MERGED 101' "$STUB_LOG.merges" && bad "merge-serializer: squash-merged held PR 101" \
    || ok "merge-serializer: did not merge held PR 101"
grep -q '^MERGED 108' "$STUB_LOG.merges" && ok "merge-serializer: merged unheld PR 108" \
    || bad "merge-serializer: did not merge unheld PR 108 (out: $(tr '\n' ' ' <"$TMP/ser.out" | cut -c1-300))"
grep -q '#101: HELD (arm policy)' "$TMP/ser.out" && ok "merge-serializer: logged the hold reason for 101" \
    || bad "merge-serializer: no logged hold reason for 101"
held_event 101 merge-serializer.sh && ok "merge-serializer: emitted pr_arm_skipped_hold for 101" \
    || bad "merge-serializer: no pr_arm_skipped_hold for 101"

# c3b. a hold placed while the serializer waits for verified stops the squash-merge.
F3B="$TMP/fix-serializer-late"; mkfix "$F3B"
: >"$STUB_LOG.merges"; rm -f "$STUB_LOG.n109"
printf '109\tokbr\tBEHIND\t2020-01-01T00:00:00Z\n' >"$STUB_CANDS"
CHUMP_REPO_ROOT="$F3B/clone" CHUMP_PR_REPO=o/r CHUMP_LOCK_DIR="$TMP/ser-locks-late" \
CHUMP_MERGE_SERIALIZER_TRUNK_GATE=0 CHUMP_MERGE_SERIALIZER_LOCK_WAIT_S=5 \
    bash "$REPO_ROOT/scripts/coord/merge-serializer.sh" >"$TMP/ser2.out" 2>&1 || true
grep -q '^MERGED 109' "$STUB_LOG.merges" && bad "merge-serializer: merged PR 109 held during the verified wait" \
    || ok "merge-serializer: hold placed during the wait stopped the squash-merge"
grep -q '#109: HELD (arm policy) while waiting for verified' "$TMP/ser2.out" \
    && ok "merge-serializer: logged the late hold for 109" \
    || bad "merge-serializer: no late-hold log for 109 (out: $(tr '\n' ' ' <"$TMP/ser2.out" | cut -c1-300))"

# c4. pr-approval-action.sh: a tap on a held PR is refused, an unheld one merges.
: >"$STUB_LOG.merges"
out101="$(CHUMP_PR_MERGE_METHOD=squash bash scripts/ops/pr-approval-action.sh merge o/product 101 2>/dev/null)" && rc101=0 || rc101=$?
[[ "$rc101" -eq 1 ]] && ok "pr-approval-action: held PR 101 → exit 1" || bad "pr-approval-action: held PR 101 exit $rc101, want 1"
grep -qi 'held' <<<"$out101" && ok "pr-approval-action: status line says held" || bad "pr-approval-action: status line lacks 'held' ($out101)"
grep -q '^MERGED 101' "$STUB_LOG.merges" && bad "pr-approval-action: merged held PR 101" || ok "pr-approval-action: did not merge held PR 101"
held_event 101 pr-approval-action.sh && ok "pr-approval-action: emitted pr_arm_skipped_hold for 101" \
    || bad "pr-approval-action: no pr_arm_skipped_hold for 101"
grep -q '"kind":"pr_approval_action_refused".*"number":101.*arm_policy_hold' "$CHUMP_AMBIENT_LOG" \
    && ok "pr-approval-action: emitted pr_approval_action_refused reason=arm_policy_hold" \
    || bad "pr-approval-action: no pr_approval_action_refused for 101"
CHUMP_PR_MERGE_METHOD=squash bash scripts/ops/pr-approval-action.sh merge o/product 108 >/dev/null 2>&1 && rc108=0 || rc108=$?
{ [[ "$rc108" -eq 0 ]] && grep -q '^MERGED 108' "$STUB_LOG.merges"; } \
    && ok "pr-approval-action: unheld PR 108 merged" || bad "pr-approval-action: unheld PR 108 not merged (rc=$rc108)"

# c5. closed-pr-watchdog.sh (reopener, CHUMP_WATCHDOG_REOPEN=1): pr-cut / hold stay closed.
WD="$TMP/wd"; mkdir -p "$WD/scripts/ops" "$WD/scripts/coord/lib" "$TMP/home"
cp scripts/ops/closed-pr-watchdog.sh "$WD/scripts/ops/"
cp "$LIB" "$WD/scripts/coord/lib/"
cat >"$TMP/bin/chump" <<'CH'
#!/usr/bin/env bash
[[ "$1 $2" == "gap show" ]] && echo "  status: open"
exit 0
CH
chmod +x "$TMP/bin/chump"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$STUB_CLOSED" "$NOW" <<'PY'
import json, sys
now = sys.argv[2]
def pr(n, labels):
    return {"number": n, "title": "INFRA-91%02d stub" % (n - 100), "state": "closed", "merged_at": None,
            "updated_at": now, "closed_at": now, "head": {"ref": "chump/infra-91%02d-x" % (n - 100)},
            "labels": [{"name": l} for l in labels]}
json.dump([pr(101, ["pr-cut"]), pr(102, ["Hold"]), pr(103, ["no-auto-merge"]), pr(104, [])], open(sys.argv[1], "w"))
PY
: >"$STUB_LOG.reopens"
HOME="$TMP/home" GITHUB_REPOSITORY=o/r CHUMP_WATCHDOG_REOPEN=1 bash "$WD/scripts/ops/closed-pr-watchdog.sh" >"$TMP/wd.out" 2>&1 || true
for n in 101 102 103; do
    grep -q "^REOPEN $n\$" "$STUB_LOG.reopens" && bad "closed-pr-watchdog: reopened deliberate/held PR $n" \
        || ok "closed-pr-watchdog: left PR $n closed (pr-cut / hold label)"
done
grep -q '^REOPEN 104$' "$STUB_LOG.reopens" && ok "closed-pr-watchdog: still reopens an unlabeled bounced PR 104" \
    || bad "closed-pr-watchdog: did not reopen unlabeled PR 104 (out: $(tr '\n' ' ' <"$TMP/wd.out" | cut -c1-300))"

echo
echo "=== test-arm-policy: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
