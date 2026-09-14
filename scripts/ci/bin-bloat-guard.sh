#!/usr/bin/env bash
# bin-bloat-guard.sh — EFFECTIVE-1666 (EFFECTIVE-414 slice)
#
# File-size detection for the build pipeline: scans new files under
# src/*.rs (top-level bin crate, not crates/**) added in this PR/diff,
# records their size in kilobytes, and emits a warning if any exceeds
# the configured threshold. Enforces crate-first per WHEN_TO_CRATE.md —
# large new files landing directly in the bin are a signal the code
# should live in a crate instead.
#
# Tier: C (advisory — warns, does not fail the build by default).
#
# Usage:
#   bash scripts/ci/bin-bloat-guard.sh [--base <branch>] [--threshold-kb <N>]
#
# Env overrides:
#   CHUMP_BIN_BLOAT_THRESHOLD_KB   default 40 (KB)
#   CHUMP_BIN_BLOAT_FAIL_ON_WARN   default 0 (set 1 to make warnings hard-fail)
#
# Bypass: Bin-Bloat-Guard-Bypass: <reason>  commit trailer (checked when
# CHUMP_BIN_BLOAT_FAIL_ON_WARN=1 is set and a warning would otherwise fail CI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

BASE_BRANCH="main"
THRESHOLD_KB="${CHUMP_BIN_BLOAT_THRESHOLD_KB:-40}"
FAIL_ON_WARN="${CHUMP_BIN_BLOAT_FAIL_ON_WARN:-0}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base=*)         BASE_BRANCH="${1#--base=}"; shift ;;
        --base)           BASE_BRANCH="$2"; shift 2 ;;
        --threshold-kb=*) THRESHOLD_KB="${1#--threshold-kb=}"; shift ;;
        --threshold-kb)   THRESHOLD_KB="$2"; shift 2 ;;
        *)                shift ;;
    esac
done

[[ "$BASE_BRANCH" == */* ]] && BASE_REF="$BASE_BRANCH" || BASE_REF="origin/$BASE_BRANCH"
if ! git -C "$REPO_ROOT" rev-parse "$BASE_REF" &>/dev/null; then
    BASE_REF="HEAD~1"
fi

new_files=$(git -C "$REPO_ROOT" diff --name-status "$BASE_REF..HEAD" 2>/dev/null \
    | grep '^A' \
    | awk -F'	' '{print $2}' \
    | grep -E '^src/[^/]+\.rs$' \
    || true)

if [[ -z "$new_files" ]]; then
    echo "PASS: no new top-level src/*.rs files in this diff — nothing to scan"
    exit 0
fi

WARN=0
echo "bin-bloat-guard: scanning new src/*.rs files (threshold ${THRESHOLD_KB}KB)"
echo ""

while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    full_path="$REPO_ROOT/$file"
    [[ -f "$full_path" ]] || continue

    size_bytes=$(wc -c < "$full_path" | tr -d '[:space:]')
    size_kb=$(( (size_bytes + 1023) / 1024 ))

    if (( size_kb > THRESHOLD_KB )); then
        echo "  WARN: $file — ${size_kb}KB exceeds threshold (${THRESHOLD_KB}KB) — consider a crate (see docs/process/WHEN_TO_CRATE.md)"
        WARN=$((WARN+1))
    else
        echo "  ok: $file — ${size_kb}KB"
    fi
done <<< "$new_files"

echo ""
if (( WARN > 0 )); then
    echo "bin-bloat-guard: $WARN new file(s) exceed ${THRESHOLD_KB}KB"
    if [[ "$FAIL_ON_WARN" == "1" ]]; then
        if git -C "$REPO_ROOT" log -1 --format=%B 2>/dev/null | grep -qi 'Bin-Bloat-Guard-Bypass:'; then
            echo "PASS: warnings present but bypassed via commit trailer"
            exit 0
        fi
        echo "FAIL: CHUMP_BIN_BLOAT_FAIL_ON_WARN=1 and no bypass trailer found"
        exit 1
    fi
    exit 0
fi

echo "PASS: all new src/*.rs files within ${THRESHOLD_KB}KB threshold"
exit 0
