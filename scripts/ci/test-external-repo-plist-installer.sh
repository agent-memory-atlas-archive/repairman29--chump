#!/usr/bin/env bash
# test-external-repo-plist-installer.sh — INFRA-2275 smoke test
#
# Verifies `chump onboard --schedule / --unschedule / --list-scheduled`
# installs, loads, lists, unloads, and removes a per-repo launchd plist.
#
# Requirements:
#   - macOS with launchctl (INFRA-1542: skip cleanly on Linux)
#   - chump binary built and in PATH or CHUMP_BIN set
#   - CHUMP_REPO_ROOT set (or discovered via binary walk-up)
#
# Runtime target: <30s

set -euo pipefail
# CREDIBLE-1527: ensure temp-repo git commits succeed on runners without global git identity.
export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-chump-ci-test}" GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-ci-test@chump.local}" GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-chump-ci-test}" GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-ci-test@chump.local}"


SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# RESILIENT-090: scrub GIT_DIR / GIT_WORK_TREE so git commands inside this
# test cannot accidentally reference the parent worktree.
# shellcheck source=scripts/lib/scrub-git-env.sh
source "$REPO_ROOT/scripts/lib/scrub-git-env.sh"

export CHUMP_REPO_ROOT="$REPO_ROOT"

# ── macOS guard ────────────────────────────────────────────────────────────
if ! command -v launchctl &>/dev/null; then
    echo "[test-external-repo-plist-installer] SKIP: launchctl not found (not macOS)"
    exit 0
fi

# ── Binary resolution ──────────────────────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-}"
if [[ -z "$CHUMP_BIN" ]]; then
    # Try cargo target directory
    for candidate in \
        "$REPO_ROOT/target/debug/chump" \
        "$REPO_ROOT/target/release/chump"; do
        if [[ -x "$candidate" ]]; then
            CHUMP_BIN="$candidate"
            break
        fi
    done
fi
if [[ -z "$CHUMP_BIN" ]] && command -v chump &>/dev/null; then
    CHUMP_BIN="$(command -v chump)"
fi
if [[ -z "$CHUMP_BIN" || ! -x "$CHUMP_BIN" ]]; then
    echo "[test-external-repo-plist-installer] SKIP: chump binary not found (run cargo build first)" >&2
    exit 0
fi

echo "[test-external-repo-plist-installer] using binary: $CHUMP_BIN"

# ── Temp repo setup ────────────────────────────────────────────────────────
TMP_REPO="$(mktemp -d /tmp/chump-plist-test-XXXXXX)"
TMP_SCHEDULE_STATE="$(mktemp /tmp/chump-plist-schedule-XXXXXX.json)"
# Use a test-specific state file so we don't pollute the real schedule
export HOME_ORIG="$HOME"
TMP_HOME="$(mktemp -d /tmp/chump-plist-home-XXXXXX)"
export HOME="$TMP_HOME"

# Compute expected label before cleanup trap so it's available in trap body
EXPECTED_LABEL="com.chump.external-repo.$(echo "$TMP_REPO" | tr '/' '-' | sed 's/^-//')"

# ── Cleanup trap ───────────────────────────────────────────────────────────
cleanup() {
    local exit_code=$?
    echo "[test-external-repo-plist-installer] cleanup (exit=$exit_code)"
    # Unload the plist if still loaded (best-effort)
    local plist_path="$TMP_HOME/Library/LaunchAgents/${EXPECTED_LABEL}.plist"
    if [[ -f "$plist_path" ]]; then
        launchctl unload -w "$plist_path" 2>/dev/null || true
        rm -f "$plist_path" 2>/dev/null || true
    fi
    # Remove temp dirs
    rm -rf "$TMP_REPO" "$TMP_SCHEDULE_STATE" "$TMP_HOME" 2>/dev/null || true
    # Restore HOME
    export HOME="$HOME_ORIG"
    if [[ $exit_code -ne 0 ]]; then
        echo "[test-external-repo-plist-installer] FAIL (exit=$exit_code)"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

# ── Scaffold a minimal git repo ────────────────────────────────────────────
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" commit --allow-empty -m "init" -q

echo "[test-external-repo-plist-installer] tmp repo: $TMP_REPO"
echo "[test-external-repo-plist-installer] expected label: $EXPECTED_LABEL"

# ── Assertion 1: --schedule exits 0 ───────────────────────────────────────
echo "[test-external-repo-plist-installer] [1/5] chump onboard --schedule $TMP_REPO ..."
"$CHUMP_BIN" onboard --schedule "$TMP_REPO"
echo "[test-external-repo-plist-installer] [1/5] PASS: --schedule exited 0"

# ── Assertion 2: launchctl list shows the label ────────────────────────────
echo "[test-external-repo-plist-installer] [2/5] checking launchctl list ..."
if ! launchctl list | grep -qF "$EXPECTED_LABEL"; then
    echo "[test-external-repo-plist-installer] [2/5] FAIL: label '$EXPECTED_LABEL' not found in launchctl list" >&2
    exit 1
fi
echo "[test-external-repo-plist-installer] [2/5] PASS: label found in launchctl list"

# ── Assertion 3: --list-scheduled includes the tmp repo ───────────────────
echo "[test-external-repo-plist-installer] [3/5] checking --list-scheduled ..."
LIST_OUT="$("$CHUMP_BIN" onboard --list-scheduled)"
if ! echo "$LIST_OUT" | grep -qF "$TMP_REPO"; then
    echo "[test-external-repo-plist-installer] [3/5] FAIL: $TMP_REPO not in --list-scheduled output" >&2
    echo "Output was:" >&2
    echo "$LIST_OUT" >&2
    exit 1
fi
echo "[test-external-repo-plist-installer] [3/5] PASS: --list-scheduled contains repo"

# ── Assertion 4: --unschedule exits 0 ─────────────────────────────────────
echo "[test-external-repo-plist-installer] [4/5] chump onboard --unschedule $TMP_REPO ..."
"$CHUMP_BIN" onboard --unschedule "$TMP_REPO"
echo "[test-external-repo-plist-installer] [4/5] PASS: --unschedule exited 0"

# ── Assertion 5: label no longer in launchctl list ────────────────────────
echo "[test-external-repo-plist-installer] [5/5] verifying label removed from launchctl ..."
if launchctl list | grep -qF "$EXPECTED_LABEL"; then
    echo "[test-external-repo-plist-installer] [5/5] FAIL: label '$EXPECTED_LABEL' still present in launchctl list after unschedule" >&2
    exit 1
fi
echo "[test-external-repo-plist-installer] [5/5] PASS: label absent from launchctl list"

echo ""
echo "[test-external-repo-plist-installer] ALL 5 assertions PASSED"
