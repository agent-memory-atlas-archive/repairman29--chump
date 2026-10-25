#!/usr/bin/env bash
# run-feature-smokes.sh — INFRA-396: detect silent failures in load-bearing features.
#
# Each smoke asserts 'feature produces non-trivial output for a known input'.
# Run via launchd cron (see docs/gaps/INFRA-396.yaml) or before fleet launch.
# Exits 1 if any smoke fails; each failure emits ALERT kind=feature_silent_failure
# to .chump-locks/ambient.jsonl.
#
# Env overrides for testing:
#   CHUMP_BIN   — path to chump binary  (default: target/debug/chump or chump on PATH)
#   REPO_ROOT   — repo root             (default: two dirs up from this script)

set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
CHUMP="${CHUMP_BIN:-}"

# Resolve chump binary
if [[ -z "$CHUMP" ]]; then
    if [[ -x "${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump" ]]; then
        CHUMP="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
    elif command -v chump &>/dev/null; then
        CHUMP="$(command -v chump)"
    else
        echo "[run-feature-smokes] ERROR: chump binary not found (set CHUMP_BIN or build first)" >&2
        exit 2
    fi
fi

FAIL=0

emit_alert() {
    local feature="$1" reason="$2"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$AMBIENT")"
    printf '{"ts":"%s","event":"ALERT","kind":"feature_silent_failure","feature":"%s","reason":"%s"}\n' \
        "$ts" "$feature" "$reason" \
        >> "$AMBIENT"
    echo "[FAIL] feature_silent_failure: $feature — $reason" >&2
    FAIL=1
}

# ── Smoke A: chump --briefing ──────────────────────────────────────────────
# AC: produces structured output with all expected sections for a known gap ID.
# Silent-failure mode this caught: INFRA-188 deleted docs/gaps.yaml; --briefing
# early-exited silently, disabling lessons-injection for ~weeks.
smoke_briefing() {
    local gap_id="${INFRA396_SMOKE_GAP:-INFRA-396}"
    local out exit_code=0
    out=$("$CHUMP" --briefing "$gap_id" 2>/dev/null) || exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        emit_alert "chump_briefing" \
            "--briefing $gap_id exited $exit_code (expected 0)"
        return
    fi
    if [[ -z "$out" ]]; then
        emit_alert "chump_briefing" \
            "--briefing $gap_id produced empty output (silent failure)"
        return
    fi
    if ! grep -q "## Reflections" <<<"$out"; then
        emit_alert "chump_briefing" \
            "--briefing $gap_id missing '## Reflections' section — output truncated or broken"
        return
    fi
    if ! grep -q "## Acceptance Criteria\|## Recent Activity\|Metadata" <<<"$out"; then
        emit_alert "chump_briefing" \
            "--briefing $gap_id missing expected metadata sections — render path broken"
        return
    fi
    echo "[OK] smoke_briefing($gap_id): structured output with all sections ✓"
}

# ── Smoke D: bot-merge.sh --dry-run ───────────────────────────────────────
# AC: --dry-run exits 0 and emits expected stage labels (git fetch, git push).
# Silent-failure mode: script crashes early without reaching key stages.
smoke_bot_merge_dry_run() {
    local bot_merge="$REPO_ROOT/scripts/coord/bot-merge.sh"
    if [[ ! -f "$bot_merge" ]]; then
        emit_alert "bot_merge_sh" \
            "bot-merge.sh not found at $bot_merge — file deleted or moved"
        return
    fi
    # Run with a dummy gap so the script does not attempt a real git push.
    local out
    # CREDIBLE-1584: isolate bot-merge.sh in a temp git repo so it never touches the caller checkout.
    local _bm_iso; _bm_iso="$(mktemp -d)"
    git -C "$_bm_iso" init -q -b main
    git -C "$_bm_iso" config user.email "t@chump.local"
    git -C "$_bm_iso" config user.name "t"
    git -C "$_bm_iso" commit -q --allow-empty -m "base" --no-verify
    git -C "$_bm_iso" update-ref refs/remotes/origin/main HEAD
    git -C "$_bm_iso" checkout -q -b feat/smoke-dry-run
    git -C "$_bm_iso" commit -q --allow-empty -m "INFRA-000: smoke" --no-verify
    out=$(cd "$_bm_iso" && CHUMP_REPO_ROOT="$_bm_iso" bash "$bot_merge" --dry-run --gap none 2>&1 || true)
    rm -rf "$_bm_iso"
    # Key stages that must appear regardless of git state:
    local required_stages=("git fetch" "git push")
    for stage in "${required_stages[@]}"; do
        if ! grep -q "$stage" <<<"$out"; then
            emit_alert "bot_merge_sh" \
                "--dry-run output missing expected stage '$stage' — script broken before that stage"
            return
        fi
    done
    echo "[OK] smoke_bot_merge_dry_run: stage labels present ✓"
}

echo "[run-feature-smokes] chump=$CHUMP repo=$REPO_ROOT"
smoke_briefing
smoke_bot_merge_dry_run

if [[ $FAIL -eq 0 ]]; then
    echo "[run-feature-smokes] All feature smokes passed."
fi
exit $FAIL
