#!/usr/bin/env bash
# audit-done-sweep.sh — CREDIBLE-1369 (CREDIBLE-279 slice)
#
# `chump gap audit-done` (src/done_auditor.rs, INFRA-3495) re-checks closed
# gaps' PRs for over-claimed acceptance criteria and already emits
# `kind=over_claim_suspected` to ambient.jsonl per flagged gap — but nothing
# ever INVOKED it. CREDIBLE-279 named this directly: "a working watchdog
# produced zero operator signal" because it only ever ran on-demand.
#
# This wrapper is the scheduled invocation: run the audit, log the full
# render() to a location an operator already tails, and emit ONE summary
# ambient event per run (kind=audit_done_sweep_completed) so "0 flagged" is
# visible too, not just flags — ambient.jsonl is silent on a clean run
# otherwise, which looks identical to "never ran".
#
# Usage:
#   ./scripts/coord/audit-done-sweep.sh
#
# `chump gap audit-done` itself takes no flags today (bounded to 100 done
# gaps per invocation, hardcoded at src/main.rs). This wrapper just invokes
# it, logs the render(), and adds the summary ambient event.
#
# Env overrides:
#   CHUMP_AMBIENT_LOG              — path to ambient.jsonl (default .chump-locks/ambient.jsonl)
#   CHUMP_AUDIT_DONE_SWEEP_LOG     — findings log path (default /tmp/chump-audit-done-sweep.log)
#
# Emits to ambient.jsonl: kind=audit_done_sweep_completed (one per run)
#   fields: ts, kind, audited, flagged, skipped_no_pr, skipped_no_ac, fetch_errors
# (per-flag kind=over_claim_suspected is emitted by done_auditor.rs itself)
#
# Install via launchd (daily):
#   cp launchd/com.chump.audit-done-sweep.plist ~/Library/LaunchAgents/
#   launchctl load ~/Library/LaunchAgents/com.chump.audit-done-sweep.plist
#
# Or run from CI on a schedule instead — see .github/workflows/audit-done-sweep.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
_common="$(git -C "$REPO_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common" && "$_common" != ".git" ]]; then
    REPO_ROOT="$(cd "$REPO_ROOT" && git rev-parse --path-format=absolute --git-common-dir | xargs dirname 2>/dev/null || echo "$REPO_ROOT")"
fi

AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
FINDINGS_LOG="${CHUMP_AUDIT_DONE_SWEEP_LOG:-/tmp/chump-audit-done-sweep.log}"

if [[ $# -gt 0 ]]; then
    echo "audit-done-sweep.sh: unknown arg: $1" >&2
    exit 2
fi

cd "$REPO_ROOT"

CHUMP_BIN="$(command -v chump || true)"
if [[ -z "$CHUMP_BIN" && -x "$REPO_ROOT/target/release/chump" ]]; then
    CHUMP_BIN="$REPO_ROOT/target/release/chump"
fi
if [[ -z "$CHUMP_BIN" ]]; then
    echo "audit-done-sweep.sh: no chump binary on PATH or at target/release/chump" >&2
    exit 1
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
{
    echo "=== audit-done sweep: $ts ==="
} >> "$FINDINGS_LOG"

set +e
report_output="$("$CHUMP_BIN" gap audit-done 2>&1)"
audit_exit=$?
set -e

echo "$report_output" >> "$FINDINGS_LOG"

audited="$(printf '%s\n' "$report_output" | grep -oE '[0-9]+ audited' | head -1 | grep -oE '[0-9]+' || echo 0)"
flagged="$(printf '%s\n' "$report_output" | grep -oE '[0-9]+ flagged' | head -1 | grep -oE '[0-9]+' || echo 0)"
no_pr="$(printf '%s\n' "$report_output" | grep -oE '[0-9]+ no-pr' | head -1 | grep -oE '[0-9]+' || echo 0)"
no_ac="$(printf '%s\n' "$report_output" | grep -oE '[0-9]+ no-ac' | head -1 | grep -oE '[0-9]+' || echo 0)"
fetch_err="$(printf '%s\n' "$report_output" | grep -oE '[0-9]+ fetch-err' | head -1 | grep -oE '[0-9]+' || echo 0)"

audited="${audited:-0}"
flagged="${flagged:-0}"
no_pr="${no_pr:-0}"
no_ac="${no_ac:-0}"
fetch_err="${fetch_err:-0}"

mkdir -p "$(dirname "$AMBIENT_LOG")"
# scanner-anchor: "kind":"audit_done_sweep_completed"
printf '{"ts":"%s","kind":"audit_done_sweep_completed","audited":%s,"flagged":%s,"skipped_no_pr":%s,"skipped_no_ac":%s,"fetch_errors":%s}\n' \
    "$ts" "$audited" "$flagged" "$no_pr" "$no_ac" "$fetch_err" >> "$AMBIENT_LOG"

exit "$audit_exit"
