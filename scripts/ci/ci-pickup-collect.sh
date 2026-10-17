#!/usr/bin/env bash
# ci-pickup-collect.sh (CREDIBLE-1512) — sample CI runner pickup latency.
#
# Hosted-runner starvation (ubuntu-latest jobs sitting at `runner=none` for
# 20-40 min while GitHub status reads clean) is invisible to every status
# page. This collector turns it into data the KPI layer can percentile:
#
#   .chump/metrics/ci_pickup.jsonl   — one line per CI job in the last N runs:
#       {"ts":<job created_at>,"pickup_s":<started_at - created_at>,"run_id":N,"job":"..."}
#   .chump/metrics/ci_runs_queued    — live count of workflow runs in `queued` state
#
# The github webhook cache (.chump/github_cache.db) stores check_runs
# started_at/completed_at but NOT the job created_at (enqueue time) needed for
# queue-wait, so per the CREDIBLE-1512 AC this falls back to
# `gh api .../actions/runs/<id>/jobs` (created_at vs started_at). Pure data
# collection — glue only; the percentile + starvation logic lives in Rust
# (crates/chump-kpi-report/src/ci_pickup.rs), read via `chump kpi report
# --ci-pickup`.
#
# Usage:
#   scripts/ci/ci-pickup-collect.sh                 # collect into .chump/metrics/
#   CHUMP_CI_PICKUP_RUNS=30 scripts/ci/ci-pickup-collect.sh
#   scripts/ci/ci-pickup-collect.sh --emit          # collect, then run the
#                                                   #   Rust starvation detector
#
# Intended to run periodically from launchd/cron (every ~5-10 min).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
METRICS_DIR="$REPO_ROOT/.chump/metrics"
SAMPLES="$METRICS_DIR/ci_pickup.jsonl"
QUEUED_FILE="$METRICS_DIR/ci_runs_queued"
RUNS="${CHUMP_CI_PICKUP_RUNS:-50}"
GH_REPO="${GH_REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo repairman29/chump)}"

mkdir -p "$METRICS_DIR"

if ! command -v gh >/dev/null 2>&1; then
  echo "ci-pickup-collect: gh CLI not found; cannot sample" >&2
  exit 1
fi

# 1. Live queued-run count (ci_runs_queued). `status=queued` returns runs that
#    have no runner assigned yet — the direct starvation signal.
queued="$(gh api "repos/$GH_REPO/actions/runs?per_page=100&status=queued" \
  --jq '.total_count' 2>/dev/null || echo 0)"
printf '%s\n' "$queued" > "$QUEUED_FILE"

# 2. Last N *completed* runs → per-job pickup samples. We sample completed runs
#    (not the newest, which are mostly still queued) because pickup = started_at
#    - created_at is only known once a runner has picked the job up. A job that
#    waited 30 min in the queue then ran carries that 30 min once it completes —
#    so completed runs are where past starvation is actually observable. jq's
#    fromdateiso8601 parses the "2026-10-17T04:58:00Z" GitHub timestamps to epoch
#    seconds, so pickup is a plain subtraction (no date(1) portability dance).
run_ids="$(gh api "repos/$GH_REPO/actions/runs?per_page=$RUNS&status=completed" \
  --jq '.workflow_runs[].id' 2>/dev/null || true)"

tmp="$(mktemp "${TMPDIR:-/tmp}/ci-pickup.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

count=0
for id in $run_ids; do
  gh api "repos/$GH_REPO/actions/runs/$id/jobs?per_page=100" --jq '
    .jobs[]
    | select(.started_at != null and .created_at != null)
    | {ts: .created_at,
       pickup_s: ((.started_at|fromdateiso8601) - (.created_at|fromdateiso8601)),
       run_id: '"$id"',
       job: .name}
    | select(.pickup_s >= 0)' 2>/dev/null >> "$tmp" || true
  count=$((count + 1))
done

# Atomic replace: each collection fully re-derives the last-N-runs window, so we
# rewrite (not append) to avoid duplicate samples and unbounded growth. The KPI
# window filter (default 24h) bounds the view further.
mv "$tmp" "$SAMPLES"
trap - EXIT

n_samples="$(wc -l < "$SAMPLES" | tr -d ' ')"
echo "ci-pickup-collect: $n_samples pickup samples from $count runs; ci_runs_queued=$queued" >&2

# Optional: run the Rust starvation detector (emits kind=ci_runner_starved when
# the trailing-30-min p50 pickup exceeds 10 min). Kept opt-in so the pure
# collector never pages on its own.
if [[ "${1:-}" == "--emit" ]]; then
  CHUMP_BIN="${CHUMP_BIN:-chump}"
  if command -v "$CHUMP_BIN" >/dev/null 2>&1; then
    "$CHUMP_BIN" kpi report --ci-pickup --emit-if-starved >/dev/null || true
  else
    echo "ci-pickup-collect: --emit requested but '$CHUMP_BIN' not on PATH" >&2
  fi
fi
