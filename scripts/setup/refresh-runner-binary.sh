#!/usr/bin/env bash
# scripts/setup/refresh-runner-binary.sh — CREDIBLE-076
#
# Rebuild the chump binary from current origin/main and hardcopy it to
# /opt/homebrew/bin/chump so the 4 self-hosted CI runners always run against
# a current binary. Without this, every fast-checks test that greps `chump`
# subcommand output fails because the runner's binary lags origin/main.
#
# Designed for launchd; runs every 30 minutes via
# scripts/setup/install-refresh-runner-binary-launchd.sh.
#
# Idempotent: if the installed binary's build SHA matches origin/main's HEAD,
# skips the rebuild entirely (fast no-op, no cargo invocation).
#
# Emits ambient kinds:
#   runner_binary_refreshed         — successful rebuild + install
#   runner_binary_refresh_skipped   — binary already current (no-op)
#   runner_binary_refresh_failed    — build or install error
#
# Bypass: CHUMP_SKIP_BINARY_REFRESH=1 short-circuits to exit 0.

set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-/Users/jeffadkins/Projects/Chump}"
TARGET_BIN="${CHUMP_RUNNER_BIN:-/opt/homebrew/bin/chump}"
CARGO_BIN="${CHUMP_CARGO_BIN:-$HOME/.cargo/bin/chump}"
AMBIENT="$REPO_ROOT/.chump-locks/ambient.jsonl"
LOG_DIR="$REPO_ROOT/.chump-locks/binary-refresh-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else
        line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"
    fi
    printf '%s\n' "$line" >> "$AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# Bypass for forensics
if [[ "${CHUMP_SKIP_BINARY_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_BINARY_REFRESH=1"
    exit 0
fi

# ── INFRA-3716: --almanac mode ──────────────────────────────────────────────
# When invoked with --almanac, this script handles the almanac binary instead
# of the chump binary.  SHA-idempotent: if the installed almanac binary's
# build SHA matches almanac origin/main HEAD, it logs "almanac binary healthy"
# and exits 0 (no-op).  If the binary is missing or the SHA mismatches, it
# delegates to install-almanac-organ.sh for the rebuild.
# ────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--almanac" ]]; then
    shift
    ALMANAC_REPO="${ALMANAC_REPO:-$HOME/Projects/almanac}"
    ALMANAC_BIN="${ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
    ALMANAC_KNOWN_GOOD_HASH_FILE="${ALMANAC_KNOWN_GOOD_HASH_FILE:-$ALMANAC_REPO/.chump-locks/almanac-known-good.sha256}"
    ALMANAC_MARKER="${ALMANAC_MARKER:-${ALMANAC_REPO}.last-indexed-commit}"
    ALMANAC_MCP_BIN="${ALMANAC_MCP_BIN:-$(dirname "$ALMANAC_BIN")/almanac-mcp}"
    ALMANAC_HEALTH_REPO="${ALMANAC_HEALTH_REPO:-chump}"

    log "INFRA-3716: almanac mode — checking $ALMANAC_BIN"

    # INFRA-7319 (INFRA-3638 slice): emit a measurable "eyes-alive" almanac_health
    # probe every liveness cycle of this script's --almanac mode — binary
    # presence, indexed file count, index freshness, and almanac-mcp
    # reachability. Mirrors scripts/ops/almanac-liveness-refresh.sh's probe so
    # the same dashboard/scanner logic covers both the launchd and systemd
    # refresh organs.
    _health_binary_present=0
    [[ -x "$ALMANAC_BIN" ]] && _health_binary_present=1

    _health_indexed_files=0
    if [[ "$_health_binary_present" == "1" ]] && command -v timeout >/dev/null 2>&1; then
        _health_stats_out="$(timeout 10 "$ALMANAC_BIN" stats "$ALMANAC_HEALTH_REPO" 2>/dev/null || true)"
        _health_files_line="$(printf '%s\n' "$_health_stats_out" | awk '/^files:/{print $2}')"
        [[ "$_health_files_line" =~ ^[0-9]+$ ]] && _health_indexed_files="$_health_files_line"
    fi

    _health_last_index_age_s=0
    if [[ -f "$ALMANAC_MARKER" ]]; then
        _health_marker_mtime="$(stat -c %Y "$ALMANAC_MARKER" 2>/dev/null || stat -f %m "$ALMANAC_MARKER" 2>/dev/null || echo 0)"
        _health_now_epoch="$(date -u +%s)"
        _health_last_index_age_s=$(( _health_now_epoch - _health_marker_mtime ))
    fi

    _health_mcp_reachable=0
    [[ -x "$ALMANAC_MCP_BIN" ]] && _health_mcp_reachable=1

    log "almanac_health: binary_present=$_health_binary_present indexed_files=$_health_indexed_files last_index_age_s=$_health_last_index_age_s mcp_reachable=$_health_mcp_reachable"
    # scanner-anchor: "kind":"almanac_health"  (INFRA-7319/INFRA-3638; measurable
    # eyes-alive probe emitted every liveness cycle of --almanac mode)
    emit almanac_health "\"indexed_files\":$_health_indexed_files,\"last_index_age_s\":$_health_last_index_age_s,\"binary_present\":$([[ $_health_binary_present == 1 ]] && echo true || echo false),\"mcp_reachable\":$([[ $_health_mcp_reachable == 1 ]] && echo true || echo false)"

    # Determine known-good SHA from almanac repo origin/main
    if [[ -d "$ALMANAC_REPO/.git" ]]; then
        git -C "$ALMANAC_REPO" fetch origin main --quiet 2>/dev/null || true
        ALMANAC_MAIN_SHA="$(git -C "$ALMANAC_REPO" rev-parse --short=12 origin/main 2>/dev/null || git -C "$ALMANAC_REPO" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
    else
        ALMANAC_MAIN_SHA="unknown"
    fi
    log "almanac origin/main = $ALMANAC_MAIN_SHA"

    # Check installed binary build SHA (git) + SHA256 (file integrity)
    INSTALLED_ALMANAC_SHA="none"
    INSTALLED_ALMANAC_SHA256="none"
    if [[ -x "$ALMANAC_BIN" ]]; then
        INSTALLED_ALMANAC_SHA="$("$ALMANAC_BIN" --version 2>/dev/null | grep -oE '[a-f0-9]{7,12}' | head -1)"
        [[ -n "$INSTALLED_ALMANAC_SHA" ]] || INSTALLED_ALMANAC_SHA="unknown"
        if command -v shasum >/dev/null 2>&1; then
            INSTALLED_ALMANAC_SHA256="$(shasum -a 256 "$ALMANAC_BIN" 2>/dev/null | awk '{print $1}')"
            [[ -n "$INSTALLED_ALMANAC_SHA256" ]] || INSTALLED_ALMANAC_SHA256="unknown"
        else
            INSTALLED_ALMANAC_SHA256="unavailable"
        fi
        log "installed almanac sha = $INSTALLED_ALMANAC_SHA  sha256 = $INSTALLED_ALMANAC_SHA256"
    fi

    # Idempotency: if binary present and SHA matches, no-op.
    # Also check SHA256 against the known-good hash file (INFRA-3716).
    if [[ "$INSTALLED_ALMANAC_SHA" != "none" && "$INSTALLED_ALMANAC_SHA" != "unknown" ]] && \
       [[ "$INSTALLED_ALMANAC_SHA" == "$ALMANAC_MAIN_SHA"* || "$ALMANAC_MAIN_SHA" == "$INSTALLED_ALMANAC_SHA"* ]]; then
        # SHA256 known-good check: if the hash file exists and the binary's
        # SHA256 matches it, we are truly idempotent. If the hash file is
        # missing or mismatched, force a rebuild (binary may be corrupt).
        if [[ -f "$ALMANAC_KNOWN_GOOD_HASH_FILE" && "$INSTALLED_ALMANAC_SHA256" != "unavailable" ]]; then
            KNOWN_GOOD="$(head -1 "$ALMANAC_KNOWN_GOOD_HASH_FILE" | awk '{print $1}')"
            if [[ "$INSTALLED_ALMANAC_SHA256" == "$KNOWN_GOOD" ]]; then
                log "almanac binary healthy ($INSTALLED_ALMANAC_SHA matches main $ALMANAC_MAIN_SHA, sha256=$INSTALLED_ALMANAC_SHA256 matches known-good)"
                emit almanac_binary_healthy "\"sha\":\"$INSTALLED_ALMANAC_SHA\",\"main_sha\":\"$ALMANAC_MAIN_SHA\",\"sha256\":\"$INSTALLED_ALMANAC_SHA256\""
                exit 0
            else
                log "almanac SHA256 mismatch (installed=$INSTALLED_ALMANAC_SHA256, known-good=$KNOWN_GOOD) — forcing rebuild"
            fi
        else
            log "almanac binary healthy ($INSTALLED_ALMANAC_SHA matches main $ALMANAC_MAIN_SHA, sha256=$INSTALLED_ALMANAC_SHA256)"
            emit almanac_binary_healthy "\"sha\":\"$INSTALLED_ALMANAC_SHA\",\"main_sha\":\"$ALMANAC_MAIN_SHA\",\"sha256\":\"$INSTALLED_ALMANAC_SHA256\""
            exit 0
        fi
    fi

    # Binary missing or SHA mismatch — rebuild via install-almanac-organ.sh
    log "almanac binary needs rebuild (installed=$INSTALLED_ALMANAC_SHA sha256=$INSTALLED_ALMANAC_SHA256, main=$ALMANAC_MAIN_SHA)"

    if [[ ! -d "$ALMANAC_REPO/.git" ]]; then
        log "FATAL: almanac repo not found at $ALMANAC_REPO"
        emit almanac_binary_refresh_failed "\"reason\":\"almanac_repo_absent\""
        exit 1
    fi

    if [[ -x "$ALMANAC_REPO/scripts/install-almanac-organ.sh" ]]; then
        log "running install-almanac-organ.sh …"
        if ! "$ALMANAC_REPO/scripts/install-almanac-organ.sh" >>"$LOG" 2>&1; then
            log "FATAL: install-almanac-organ.sh failed"
            emit almanac_binary_refresh_failed "\"reason\":\"install_almanac_organ_failed\""
            exit 1
        fi
    else
        log "FATAL: install-almanac-organ.sh not found at $ALMANAC_REPO/scripts/install-almanac-organ.sh"
        emit almanac_binary_refresh_failed "\"reason\":\"install_script_missing\""
        exit 1
    fi

    NEW_ALMANAC_SHA="$("$ALMANAC_BIN" --version 2>/dev/null | grep -oE '[a-f0-9]{7,12}' | head -1 || echo unknown)"
    # Record the fresh SHA256 as the known-good value for future idempotency checks.
    if command -v shasum >/dev/null 2>&1 && [[ -x "$ALMANAC_BIN" ]]; then
        NEW_ALMANAC_SHA256="$(shasum -a 256 "$ALMANAC_BIN" 2>/dev/null | awk '{print $1}')"
        mkdir -p "$(dirname "$ALMANAC_KNOWN_GOOD_HASH_FILE")" 2>/dev/null || true
        printf '%s  %s\n' "$NEW_ALMANAC_SHA256" "$ALMANAC_BIN" > "$ALMANAC_KNOWN_GOOD_HASH_FILE" 2>/dev/null || true
    else
        NEW_ALMANAC_SHA256="unavailable"
    fi
    log "OK: almanac binary refreshed ($INSTALLED_ALMANAC_SHA -> $NEW_ALMANAC_SHA, sha256=$NEW_ALMANAC_SHA256)"
    emit almanac_binary_refreshed "\"prev_sha\":\"$INSTALLED_ALMANAC_SHA\",\"new_sha\":\"$NEW_ALMANAC_SHA\",\"main_sha\":\"$ALMANAC_MAIN_SHA\",\"sha256\":\"$NEW_ALMANAC_SHA256\""
    exit 0
fi

cd "$REPO_ROOT" || { log "FATAL: cannot cd to $REPO_ROOT"; emit runner_binary_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

# Fetch latest main without disturbing the working tree
git fetch origin main --quiet 2>/dev/null || {
    log "WARN: git fetch failed (offline?); proceeding with local main"
}

MAIN_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || git rev-parse --short=12 HEAD)"
log "origin/main = $MAIN_SHA"

# Check installed binary build SHA (chump prints 'chump 0.1.2 (<sha> built <date>)')
INSTALLED_SHA="none"
if [[ -x "$TARGET_BIN" ]]; then
    INSTALLED_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "installed $TARGET_BIN sha = $INSTALLED_SHA"
fi

# Idempotency: if SHAs match, skip
if [[ "$INSTALLED_SHA" == "$MAIN_SHA"* || "$MAIN_SHA" == "$INSTALLED_SHA"* ]] && [[ "$INSTALLED_SHA" != "none" && "$INSTALLED_SHA" != "unknown" ]]; then
    log "SKIP: binary already current ($INSTALLED_SHA matches main $MAIN_SHA)"
    emit runner_binary_refresh_skipped "\"reason\":\"already_current\",\"sha\":\"$INSTALLED_SHA\""
    exit 0
fi

# Resolve cargo on PATH.
# PRODUCT-169: the rustup shim at ~/.cargo/bin/cargo reads rust-toolchain.toml
# and resolves to whatever channel is pinned there. A prior fallback candidate
# hardcoded a specific "stable" toolchain path (e.g.
# ~/.rustup/toolchains/stable-aarch64-apple-darwin/bin/cargo) — that bypasses
# the pin entirely, so this cron would build with whatever "stable" happened
# to be installed while interactive sessions built with the pinned channel,
# doubling compile artifacts across the shared target dir. Only the rustup
# shim (pin-aware) and a generic PATH lookup (also pin-aware, since rustup
# installs its shim onto PATH) are safe fallbacks here.
CARGO=""
for candidate in "$HOME/.cargo/bin/cargo" "$(command -v cargo)"; do
    if [[ -x "$candidate" ]]; then
        CARGO="$candidate"
        break
    fi
done
if [[ -z "$CARGO" ]]; then
    log "FATAL: cargo not found in PATH or known locations"
    emit runner_binary_refresh_failed "\"reason\":\"no_cargo\""
    exit 1
fi
log "using cargo: $CARGO"

# INFRA-2101 fix: build from a detached worktree at origin/main HEAD instead of
# the operator's local working tree. Pre-fix, `cargo install --path "$REPO_ROOT"`
# built from the local checkout — when the operator had WIP and main was 100+
# commits behind origin/main (the operationalization-debt case), the "refresh"
# emitted prev_sha==new_sha forever. Operator's installed binary stuck at the
# stale local sha while origin/main advanced. Wizard-retirement criterion #1
# was met on paper, broken in production.
BUILD_WORKTREE="${CHUMP_BINARY_REFRESH_WORKTREE:-/tmp/chump-binary-refresh-$$}"
log "creating detached worktree at origin/main ($MAIN_SHA) → $BUILD_WORKTREE"
# RESILIENT-348: a prior run killed mid-build (timeout / SIGKILL / systemctl stop)
# leaves a registered worktree at a FIXED BUILD_WORKTREE path (the EXIT trap below
# never fired), and `worktree add` then fails "already exists" — silently freezing
# self-deploy until a human clears it. Proactively remove any stale worktree at this
# path BEFORE creating a fresh one.
git -C "$REPO_ROOT" worktree remove --force "$BUILD_WORKTREE" >>"$LOG" 2>&1 || true
rm -rf "$BUILD_WORKTREE" >>"$LOG" 2>&1 || true
git -C "$REPO_ROOT" worktree prune >>"$LOG" 2>&1 || true
if ! git -C "$REPO_ROOT" worktree add -d -f "$BUILD_WORKTREE" "origin/main" >>"$LOG" 2>&1; then
    log "FATAL: failed to create build worktree at $BUILD_WORKTREE"
    emit runner_binary_refresh_failed "\"reason\":\"worktree_add_failed\""
    exit 1
fi
# RESILIENT-107: drop a .chump-no-reap sentinel so stale-worktree-reaper.sh and
# active-target-reaper.sh skip this worktree while cargo build is running. Without
# this, the 10-12 min release build races against /tmp/chump-* scanners and gets
# its target/release/deps/ rm -rf'd mid-compile (verified 2026-06-05: two
# consecutive auto-deploy ticks failed with "couldn't create a temp dir at
# /tmp/chump-binary-refresh-<PID>/target/release/deps/rustc<hash>").
touch "$BUILD_WORKTREE/.chump-no-reap" 2>>"$LOG" || true

# Always tear down the worktree on exit (success OR failure path)
trap 'git -C "$REPO_ROOT" worktree remove --force "$BUILD_WORKTREE" >>"$LOG" 2>&1 || true' EXIT

# Build --release in the detached worktree. Use cargo build (not cargo install)
# so we write to BUILD_WORKTREE/target/release/chump and nothing else.
# RESILIENT-199: build into the WARM shared target dir ($REPO_ROOT/target),
# not the cold BUILD_WORKTREE/target. A detached /tmp worktree does not inherit
# the repo's .cargo/config shared target-dir, so it compiled from scratch every
# run — the ~26-min cold build that got SIGKILL'd on 2026-07-05 and left the
# auto-deploy dead + disabled. Reusing the warm target makes this an incremental
# ~1-2 min build. The auto-deploy is serialized (one launchd job), so sharing
# the target with the main checkout is safe here.
# RESILIENT-408: honor an externally-provided CARGO_TARGET_DIR instead of
# hard-overriding to REPO_ROOT/target unconditionally. Building the deploy
# binary into the same warm target dir that workers build into invites lock
# contention; a caller that needs isolation (e.g. auto-deploy.sh running
# concurrently with worker cargo builds) can now opt out by pre-setting
# CARGO_TARGET_DIR before invoking this script.
SHARED_TARGET="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
log "cargo build --release --bin chump (worktree $BUILD_WORKTREE, target dir $SHARED_TARGET) …"
if ! PATH="$(dirname "$CARGO"):$PATH" CARGO_TARGET_DIR="$SHARED_TARGET" \
     "$CARGO" build --release --bin chump --manifest-path "$BUILD_WORKTREE/Cargo.toml" >>"$LOG" 2>&1; then
    log "FATAL: cargo build failed; see $LOG"
    emit runner_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
    exit 1
fi

BUILT_BIN="$SHARED_TARGET/release/chump"
if [[ ! -x "$BUILT_BIN" ]]; then
    log "FATAL: $BUILT_BIN missing after cargo build"
    emit runner_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    exit 1
fi

# Hardcopy build artifact → /opt/homebrew/bin (atomic via tempfile + rename).
log "hardcopy $BUILT_BIN → $TARGET_BIN"
if ! cp -f "$BUILT_BIN" "$TARGET_BIN.new" 2>>"$LOG"; then
    log "FATAL: cp to $TARGET_BIN.new failed"
    emit runner_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi
chmod +x "$TARGET_BIN.new"
# RESILIENT-198: ad-hoc code-sign on macOS BEFORE the atomic rename. A freshly
# copied unsigned binary makes macOS syspolicyd re-scan it on EVERY exec, hanging
# each `chump` invocation 90s+ — which wedges every git hook, launchd daemon, and
# fleet script that shells out to chump. Ad-hoc signing (`--sign -`) drops that to
# sub-second. Sign the tempfile so the live binary is only ever swapped to a
# signed one. No-op on Linux (no codesign); warn but don't fail the deploy.
if [[ "$(uname)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
    if ! codesign --force --sign - "$TARGET_BIN.new" 2>>"$LOG"; then
        log "WARN: codesign failed — installed binary may hang on first exec (syspolicyd)"
    fi
fi
mv -f "$TARGET_BIN.new" "$TARGET_BIN"

# RESILIENT-355: the deploy used to build+install ONLY `chump`. Aux
# merge-critical binaries (chump-integrator — the batched merge train) were never
# installed here, so when one vanished from the bin dir NOTHING reinstalled it:
# chump-integrator went missing 2026-08-20 and the merge train sat dead 16h while
# PRs jammed. Build + install the merge-critical aux binaries alongside chump.
# Best-effort: a missing/broken aux warns + emits, but never fails the chump
# deploy (chump is the critical path and is already installed above).
CHUMP_AUX_MERGE_BINS="${CHUMP_AUX_MERGE_BINS:-chump-integrator}"
INSTALL_DIR="$(dirname "$TARGET_BIN")"
for _aux in $CHUMP_AUX_MERGE_BINS; do
    if PATH="$(dirname "$CARGO"):$PATH" CARGO_TARGET_DIR="$SHARED_TARGET" \
         "$CARGO" build --release --bin "$_aux" --manifest-path "$BUILD_WORKTREE/Cargo.toml" >>"$LOG" 2>&1 \
       && [[ -x "$SHARED_TARGET/release/$_aux" ]]; then
        if cp -f "$SHARED_TARGET/release/$_aux" "$INSTALL_DIR/$_aux.new" 2>>"$LOG"; then
            chmod +x "$INSTALL_DIR/$_aux.new"
            if [[ "$(uname)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
                codesign --force --sign - "$INSTALL_DIR/$_aux.new" 2>>"$LOG" || true
            fi
            mv -f "$INSTALL_DIR/$_aux.new" "$INSTALL_DIR/$_aux"
            log "RESILIENT-355: installed aux merge binary $_aux → $INSTALL_DIR/$_aux"
        else
            log "WARN (RESILIENT-355): cp of aux binary $_aux failed"
            emit runner_binary_refresh_failed "\"reason\":\"aux_cp_failed\",\"bin\":\"$_aux\""
        fi
    else
        log "WARN (RESILIENT-355): aux merge binary $_aux failed to build — merge train may lack it"
        emit runner_binary_refresh_failed "\"reason\":\"aux_build_failed\",\"bin\":\"$_aux\""
    fi
done

# RESILIENT-355: the deploy used to build+install ONLY `chump`. Aux
# merge-critical binaries (chump-integrator — the batched merge train) were never
# installed here, so when one vanished from the bin dir NOTHING reinstalled it:
# chump-integrator went missing 2026-08-20 and the merge train sat dead 16h while
# PRs jammed. Build + install the merge-critical aux binaries alongside chump.
# Best-effort: a missing/broken aux warns + emits, but never fails the chump
# deploy (chump is the critical path and is already installed above).
CHUMP_AUX_MERGE_BINS="${CHUMP_AUX_MERGE_BINS:-chump-integrator}"
INSTALL_DIR="$(dirname "$TARGET_BIN")"
for _aux in $CHUMP_AUX_MERGE_BINS; do
    if PATH="$(dirname "$CARGO"):$PATH" CARGO_TARGET_DIR="$SHARED_TARGET" \
         "$CARGO" build --release --bin "$_aux" --manifest-path "$BUILD_WORKTREE/Cargo.toml" >>"$LOG" 2>&1 \
       && [[ -x "$SHARED_TARGET/release/$_aux" ]]; then
        if cp -f "$SHARED_TARGET/release/$_aux" "$INSTALL_DIR/$_aux.new" 2>>"$LOG"; then
            chmod +x "$INSTALL_DIR/$_aux.new"
            if [[ "$(uname)" == "Darwin" ]] && command -v codesign >/dev/null 2>&1; then
                codesign --force --sign - "$INSTALL_DIR/$_aux.new" 2>>"$LOG" || true
            fi
            mv -f "$INSTALL_DIR/$_aux.new" "$INSTALL_DIR/$_aux"
            log "RESILIENT-355: installed aux merge binary $_aux → $INSTALL_DIR/$_aux"
        else
            log "WARN (RESILIENT-355): cp of aux binary $_aux failed"
            emit runner_binary_refresh_failed "\"reason\":\"aux_cp_failed\",\"bin\":\"$_aux\""
        fi
    else
        log "WARN (RESILIENT-355): aux merge binary $_aux failed to build — merge train may lack it"
        emit runner_binary_refresh_failed "\"reason\":\"aux_build_failed\",\"bin\":\"$_aux\""
    fi
done

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"

# INFRA-2101 guard: detect the silent-failure mode (prev_sha == new_sha despite
# origin/main advance). If we built from origin/main and new_sha STILL matches
# the prior installed sha, something is wrong — either:
#   - origin/main didn't actually advance (no commits since last run; OK)
#   - the build produced the same artifact (genuinely no source change; OK)
#   - the cp/mv silently no-op'd (BAD; new file should win)
# Emit a separate kind=runner_binary_advance with delta_commits so the
# operator can audit whether the daemon is making forward progress.
DELTA_COMMITS="$(git -C "$REPO_ROOT" rev-list --count "${INSTALLED_SHA}..origin/main" 2>/dev/null || echo unknown)"
if [[ "$NEW_SHA" == "$INSTALLED_SHA" && "$DELTA_COMMITS" != "0" && "$DELTA_COMMITS" != "unknown" ]]; then
    log "WARN: prev_sha == new_sha ($NEW_SHA) despite $DELTA_COMMITS commits on origin/main since last install — possible silent staleness"
    emit runner_binary_refresh_failed "\"reason\":\"silent_staleness\",\"prev_sha\":\"$INSTALLED_SHA\",\"main_sha\":\"$MAIN_SHA\",\"delta_commits\":$DELTA_COMMITS"
    exit 1
fi

log "OK: $TARGET_BIN now at sha $NEW_SHA (origin/main = $MAIN_SHA, delta_commits=$DELTA_COMMITS)"
emit runner_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""
emit runner_binary_advance "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\",\"delta_commits\":\"$DELTA_COMMITS\""

# Emit almanac_health probe (INFRA-7831)
ALMANAC_REPO="${ALMANAC_REPO:-$HOME/Projects/almanac}"
ALMANAC_BIN="${ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
ALMANAC_MARKER="${ALMANAC_MARKER:-${ALMANAC_REPO}.last-indexed-commit}"
ALMANAC_MCP_BIN="${ALMANAC_MCP_BIN:-$(dirname "$ALMANAC_BIN")/almanac-mcp}"
ALMANAC_HEALTH_REPO="${ALMANAC_HEALTH_REPO:-chump}"

_health_binary_present=0
[[ -x "$ALMANAC_BIN" ]] && _health_binary_present=1

_health_indexed_files=0
if [[ "$_health_binary_present" == "1" ]] && command -v timeout >/dev/null 2>&1; then
    _health_stats_out="$(timeout 10 "$ALMANAC_BIN" stats "$ALMANAC_HEALTH_REPO" 2>/dev/null || true)"
    _health_files_line="$(printf '%s\n' "$_health_stats_out" | awk '/^files:/{print $2}')"
    [[ "$_health_files_line" =~ ^[0-9]+$ ]] && _health_indexed_files="$_health_files_line"
fi

_health_last_index_age_s=0
if [[ -f "$ALMANAC_MARKER" ]]; then
    _health_marker_mtime="$(stat -c %Y "$ALMANAC_MARKER" 2>/dev/null || stat -f %m "$ALMANAC_MARKER" 2>/dev/null || echo 0)"
    _health_now_epoch="$(date -u +%s)"
    _health_last_index_age_s=$(( _health_now_epoch - _health_marker_mtime ))
fi

_health_mcp_reachable=0
[[ -x "$ALMANAC_MCP_BIN" ]] && _health_mcp_reachable=1

emit almanac_health "\"indexed_files\":$_health_indexed_files,\"last_index_age_s\":$_health_last_index_age_s,\"binary_present\":$([[ $_health_binary_present == 1 ]] && echo true || echo false),\"mcp_reachable\":$([[ $_health_mcp_reachable == 1 ]] && echo true || echo false)"

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -I{} rm -f {} 2>/dev/null || true

exit 0
