#!/usr/bin/env bash
# scripts/ops/ci-qa-score.sh — INFRA-1872 (parent INFRA-1861 slice g)
#
# Daily CI-quality score: percentage of the last N merged PRs that landed
# WITHOUT any bypass signal. A bypass is one of:
#   (a) --no-verify push    → ambient kind=audit_no_verify (INFRA-1834)
#                              or kind=preflight_bypassed (existing)
#   (b) post-CI rebase      → ambient kind=pr_force_pushed_after_ci
#                              (heuristic: kind=github_api_call api~"pr update-branch"
#                               within 30 min of merge)
#   (c) cargo-test flake    → ambient kind=ci_flake_rerun  (INFRA-375)
#
# Emits exactly one ambient event per invocation:
#   {"ts":"<iso>","kind":"ci_qa_score","pct":<int>,
#    "sample_size":<n>,"bypassed":<int>,"window":"<N>"}
#
# status is one of the canonical green|amber|red|unknown vocabulary
# (INFRA-3854, parent INFRA-3841 slice 6/9) — the same vocabulary
# scripts/ops/vital-signs.sh already uses. "unknown" covers the no-data case.
#
# Exit code:
#   0 — pct >= WARN_THRESHOLD (default 95)
#   1 — pct < WARN_THRESHOLD but >= ALERT_THRESHOLD (default 80) [WARN]
#   2 — pct < ALERT_THRESHOLD [ALERT]
#
# Usage:
#   ci-qa-score.sh                        # default: window=50, emit + exit
#   ci-qa-score.sh --window 100
#   ci-qa-score.sh --json                 # machine-readable
#   ci-qa-score.sh --dry-run              # compute but don't emit ambient
#
# Bypass: CHUMP_CI_QA_SCORE=0 silently exits 0 (still emits audit line).
#
# Pairs with INFRA-1837 (bypass-frequency auditor — different metric, same
# telemetry layer): 1872 reports % clean ships; 1837 reports top-K bypass
# reasons + offenders.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

WINDOW=50
JSON=0
DRY_RUN=0
WARN_THRESHOLD="${CHUMP_CI_QA_WARN:-95}"
ALERT_THRESHOLD="${CHUMP_CI_QA_ALERT:-80}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --window) WINDOW="$2"; shift 2 ;;
        --json) JSON=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --warn) WARN_THRESHOLD="$2"; shift 2 ;;
        --alert) ALERT_THRESHOLD="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ci-qa-score: unknown flag '$1'" >&2; exit 2 ;;
    esac
done

now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
emit_ambient() { printf '%s\n' "$1" >> "$AMBIENT_LOG" 2>/dev/null || true; }

if [[ "${CHUMP_CI_QA_SCORE:-1}" == "0" ]]; then
    emit_ambient "$(printf '{"ts":"%s","kind":"ci_qa_score_bypassed","reason":"CHUMP_CI_QA_SCORE=0"}' "$(now_ts)")"
    echo "[ci-qa-score] bypassed via CHUMP_CI_QA_SCORE=0"
    exit 0
fi

# Resolve recent merged PRs (cache-first via gh shim — REST not GraphQL).
# Output: one PR number per line, newest first.
recent_prs() {
    if command -v gh >/dev/null 2>&1; then
        gh pr list --state merged --limit "$WINDOW" --json number \
            --jq '.[].number' 2>/dev/null || true
    fi
}

# Walk ambient.jsonl looking for bypass events. Returns a count of DISTINCT
# PR numbers that had at least one bypass signal in the same time window.
# We approximate "same window" as the last (WINDOW * 2) days of ambient,
# bounded by the oldest merge timestamp from recent_prs(). For the
# smoke-tested deterministic path we accept a $1 argument = path to ambient.
count_bypassed_prs() {
    local ambient_path="${1:-$AMBIENT_LOG}"
    local pr_list="$2"
    if [[ -z "$pr_list" || ! -r "$ambient_path" ]]; then
        echo 0
        return 0
    fi
    python3 - "$ambient_path" <<PYEOF
import json, sys
ambient_path = sys.argv[1]
prs = set("""$pr_list""".split())
bypass_kinds = {"audit_no_verify", "preflight_bypassed",
                "pr_force_pushed_after_ci", "ci_flake_rerun"}
bypassed = set()
try:
    with open(ambient_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                e = json.loads(line)
            except Exception:
                continue
            k = e.get("kind", "")
            if k not in bypass_kinds:
                continue
            pr = str(e.get("pr") or e.get("pr_number") or e.get("number") or "")
            if pr and pr in prs:
                bypassed.add(pr)
except FileNotFoundError:
    pass
print(len(bypassed))
PYEOF
}

PRS="$(recent_prs)"
SAMPLE_SIZE=$(echo -n "$PRS" | grep -c '^' || true)

if [[ "$SAMPLE_SIZE" -eq 0 ]]; then
    # No merged PRs in window — emit 0/0 honest signal, exit clean.
    payload="$(printf '{"ts":"%s","kind":"ci_qa_score","pct":null,"sample_size":0,"bypassed":0,"window":"%s","status":"unknown"}' "$(now_ts)" "$WINDOW")"
    [[ "$DRY_RUN" -eq 0 ]] && emit_ambient "$payload"
    if [[ "$JSON" -eq 1 ]]; then echo "$payload"; else echo "[ci-qa-score] no merged PRs in window (size $WINDOW); nothing to score"; fi
    exit 0
fi

BYPASSED=$(count_bypassed_prs "$AMBIENT_LOG" "$PRS")
CLEAN=$(( SAMPLE_SIZE - BYPASSED ))
PCT=$(( CLEAN * 100 / SAMPLE_SIZE ))

STATUS="green"
RC=0
if (( PCT < ALERT_THRESHOLD )); then
    STATUS="red"
    RC=2
elif (( PCT < WARN_THRESHOLD )); then
    STATUS="amber"
    RC=1
fi

payload="$(printf '{"ts":"%s","kind":"ci_qa_score","pct":%d,"sample_size":%d,"bypassed":%d,"window":"%s","status":"%s"}' "$(now_ts)" "$PCT" "$SAMPLE_SIZE" "$BYPASSED" "$WINDOW" "$STATUS")"
[[ "$DRY_RUN" -eq 0 ]] && emit_ambient "$payload"

if [[ "$JSON" -eq 1 ]]; then
    echo "$payload"
else
    echo "[ci-qa-score] ${STATUS}: pct=${PCT}% (${CLEAN}/${SAMPLE_SIZE} clean; ${BYPASSED} bypassed) window=${WINDOW}"
fi

exit "$RC"
