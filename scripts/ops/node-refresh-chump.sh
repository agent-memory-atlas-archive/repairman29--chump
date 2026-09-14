#!/usr/bin/env bash
# scripts/ops/node-refresh-chump.sh — RESILIENT-200
#
# Linux-node counterpart of scripts/setup/refresh-runner-binary.sh (which is the
# macOS launchd auto-deploy path). Keeps a fleet node's installed `chump` binary
# current with origin/main by rebuilding from a local mirror checkout and
# installing to the node's chump path.
#
# WHY a separate script: refresh-runner-binary.sh hardcodes macOS assumptions —
# /opt/homebrew/bin target, codesign-before-swap (syspolicyd), aarch64 cargo
# paths. The Linux fleet nodes (closetjunky, Helsinki) have none of those: no
# codesign, x86_64, and a per-user ~/.local/bin (or root /usr/local/bin) target.
# This script is the Linux-shaped equivalent, driven by a systemd --user timer
# (see scripts/setup/install-node-refresh-systemd.sh).
#
# PAUSE SAFETY (RESILIENT-073): this script ONLY refreshes the binary. It never
# reads, writes, or bumps ~/.chump/AUTONOMY_LEVEL, and never starts fleet work.
# A paused node (AUTONOMY_LEVEL=0) stays paused across refreshes — the binary
# gets current, the fleet stays off until the operator flips the switch.
#
# Idempotent: if the installed binary's build SHA already matches the
# green-main pointer, skips the rebuild entirely (fast no-op, no cargo
# invocation).
#
# BUILD-SPEED (INFRA-3677): when the binary IS out of date, this script first
# tries to PULL the prebuilt binary that free GH-hosted CI already built for the
# green-main commit (.github/workflows/build-fleet-binaries.yml → per-SHA
# artifact), installing it in seconds instead of a ~30-min local cargo build. It
# falls back to a local `cargo build --release --bin chump` only when no artifact
# exists for the SHA (gh unavailable, unknown arch, integrity/version mismatch),
# so a node is never worse off — just faster when the artifact is there.
#
# Emits (appended to $NODE_AMBIENT if it exists, else logfile only):
#   node_binary_refreshed         — successful rebuild + install
#   node_binary_refresh_skipped   — binary already current (no-op)
#   node_binary_refresh_failed    — build or install error
#
# Bypass: CHUMP_SKIP_NODE_REFRESH=1 short-circuits to exit 0.
#
# GREEN-MAIN PIN (RESILIENT-327): this script does NOT advance the live node
# to raw origin/main HEAD. It advances to the last commit that passed the
# full CI gate (the "green-main pointer"), found the same way
# scripts/coord/blame-bot.sh finds its baseline: most-recent SUCCESS run of
# the required workflow on branch main. A bad HEAD (red main) never reaches
# the live node — the node just stays pinned at the last-known-green sha
# until CI goes green again. Workers that branch off this node's mirror
# checkout therefore branch off the pinned green base, not a shifting HEAD.
#
# Env overrides:
#   CHUMP_NODE_REPO   repo mirror to build from   (default: first of
#                     ~/chump-host, ~/Projects/Chump, ~/chump that exists)
#   CHUMP_NODE_BIN    install destination         (default: ~/.local/bin/chump)
#   NODE_AMBIENT      ambient stream to append to (default: <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_NODE_REFRESH_CI_WORKFLOW      required-gate workflow file (default: ci.yml)
#   CHUMP_NODE_REFRESH_GREEN_LOOKBACK   runs to scan for the green sha (default: 30)
#   CHUMP_NODE_REFRESH_TEST_GREEN_SHA   test injection: skip gh lookup, use this sha

set -uo pipefail

# --- sanctioned gh wrapper (INFRA-1274) --------------------------------------
# Route every GitHub call through chump_gh (scripts/coord/lib/github.sh) so it
# inherits the fleet's throttle + secondary-rate-limit backoff + criticality
# tagging, instead of a raw `gh` that the raw-gh-lint hot-path gate forbids.
_NODE_REFRESH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../coord/lib/github.sh
source "$_NODE_REFRESH_DIR/../coord/lib/github.sh" 2>/dev/null || true
# RESILIENT-1041: halt-class signal on the two silent-degradation paths this
# script can take when gh is present but not authenticated (unauthed gh in a
# systemd --user timer env, with no interactive login and no GH_TOKEN export —
# fixed below by the RESILIENT-1043 (tracking RESILIENT-1040's root-cause fix,
# shipped in #4484) GH_TOKEN-from-providers.env export, so this halt-class
# signal now only fires when providers.env itself is missing/empty). Both
# _find_green_main_sha and
# _try_artifact_pull/_find_build_artifact_sha look like a plain "no data
# found" to this script, which previously only recorded a soft ambient emit —
# nothing paged, so red-main-reaches-a-live-node and a 30-min cold build on a
# 2-core node both went unalarmed.
# shellcheck source=../lib/halt-class-emit.sh
source "$_NODE_REFRESH_DIR/../lib/halt-class-emit.sh" 2>/dev/null || true
# RESILIENT-001: the shared jam-proof mirror-converge primitive. Both
# mirror-advancing organs (this script + scripts/coord/backlog-sync.sh --reader)
# converge through ONE implementation so neither can regress to a merge-based
# advance that aborts on an untracked docs/gaps/*.yaml collision.
# shellcheck source=../coord/lib/converge-mirror.sh
source "$_NODE_REFRESH_DIR/../coord/lib/converge-mirror.sh" 2>/dev/null || true
if ! command -v converge_mirror_hard_reset >/dev/null 2>&1; then
    converge_mirror_hard_reset() { git reset --hard "${1:?}"; }
fi

# --- RESILIENT-1040: ensure gh is authenticated in THIS context -------------
# ROOT CAUSE of the 5-gap self-sustain saga (1036-1039): this script is
# launched by a systemd --user timer with no interactive login shell and no
# inherited `gh auth login` session. Without GH_TOKEN in the environment, gh
# is installed but NOT authed here — every gh call below (_find_green_main_sha,
# _try_artifact_pull, _find_build_artifact_sha) silently returns empty, which
# looks exactly like "gh unavailable" and falls through to a cold local cargo
# build EVERY cycle. RESILIENT-1037's nearest-ancestor sha logic was correct
# all along; it never got a chance to run because gh had no credentials.
# Fix: export GH_TOKEN from ~/.chump/providers.env (the fleet's canonical
# secret store, RESILIENT-173) before any gh call, same pattern already used
# by chump-node-install.sh for authenticated clones. A node that already has
# GH_TOKEN/GITHUB_TOKEN in its environment (e.g. operator export, systemd
# Environment=) is left alone — providers.env is a fallback, not an override.
CHUMP_PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"
if [[ -z "${GH_TOKEN:-}" && -z "${GITHUB_TOKEN:-}" && -f "$CHUMP_PROVIDERS_ENV" ]]; then
    _creds_gh_token="$(grep -E '^(export )?GH_TOKEN=' "$CHUMP_PROVIDERS_ENV" 2>/dev/null \
        | tail -1 | sed -E 's/^(export )?GH_TOKEN=//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/')"
    if [[ -n "$_creds_gh_token" ]]; then
        export GH_TOKEN="$_creds_gh_token"
    fi
    unset _creds_gh_token
fi

# --- resolve the mirror checkout to build from -------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for candidate in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$candidate/.git" ]]; then REPO_ROOT="$candidate"; break; fi
    done
fi
# --- resolve the install destination (RESILIENT-378) -------------------------
# CRITICAL: install where the FLEET's PATH actually resolves `chump`, not a
# fixed ~/.local/bin that the PATH may shadow. The original RESILIENT-200
# default (~/.local/bin/chump) silently rotted the fleet on closetjunky: the
# organ rebuilt a CURRENT binary into ~/.local/bin every cycle, but the
# workers (cj-worker-run.sh) run PATH=~/.cargo/bin:...:target/release, so they
# executed a STALE ~/.cargo/bin/chump — 5 days behind origin/main — and drained
# the gap queue on old code. The refresh "ran" but did not do its job.
# Resolution order:
#   1. explicit CHUMP_NODE_BIN override (operator / unit Environment)
#   2. the chump already on PATH — the exact binary the fleet runs — unless it
#      is the repo's own target/release build (never install onto the build out)
#   3. ~/.cargo/bin/chump if it exists (cargo-install canonical on Linux nodes)
#   4. ~/.local/bin/chump (last resort, original default)
_resolve_target_bin() {
    if [[ -n "${CHUMP_NODE_BIN:-}" ]]; then printf '%s' "$CHUMP_NODE_BIN"; return; fi
    local onpath; onpath="$(command -v chump 2>/dev/null || true)"
    # RESILIENT-378 follow-up (closetjunky 2026-09-14): `command -v` reflects the
    # REFRESHER's PATH, which is not always the WORKER's PATH. On closetjunky the
    # refresh loop runs with ~/.local/bin ahead of ~/.cargo/bin, so `command -v
    # chump` resolved to ~/.local/bin/chump and the organ kept THAT current every
    # cycle (artifact-pull succeeded) — while the workers (PATH=~/.cargo/bin
    # first, and /usr/local/bin/chump -> ~/.cargo/bin/chump) ran a STALE
    # ~/.cargo/bin/chump for 2 days. The last-resort ~/.local/bin default must
    # never shadow an existing ~/.cargo/bin/chump (the cargo-install canonical on
    # Linux nodes, step 3), so drop that on-PATH answer through to step 3 rather
    # than pinning the refresh to a binary the fleet does not execute.
    local shadow_rot=0
    if [[ "$onpath" == "$HOME/.local/bin/chump" && -x "$HOME/.cargo/bin/chump" ]]; then
        shadow_rot=1
    fi
    if [[ -n "$onpath" && "$onpath" != *"/target/release/chump" \
          && "$onpath" != *"/target/debug/chump" && "$shadow_rot" == "0" ]]; then
        printf '%s' "$onpath"; return
    fi
    if [[ -x "$HOME/.cargo/bin/chump" ]]; then printf '%s' "$HOME/.cargo/bin/chump"; return; fi
    printf '%s' "$HOME/.local/bin/chump"
}
TARGET_BIN="$(_resolve_target_bin)"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LOG_DIR="${CHUMP_NODE_REFRESH_LOGDIR:-$HOME/.chump/node-refresh-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/refresh-$(date -u +%Y%m%dT%H%M%SZ).log"

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s\n' "$ts" "$kind" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# RESILIENT-1041: emit a halt-class signal via THIS script's own emit() (and
# therefore its own $NODE_AMBIENT), rather than scripts/lib/halt-class-emit.sh
# directly — that library resolves its ambient path from `git
# rev-parse --show-toplevel`, which on a node whose $NODE_AMBIENT override
# points somewhere other than the mirror checkout's own .chump-locks (or in
# tests, a throwaway mirror with no matching ambient dir) would silently write
# to a DIFFERENT file than every other event this script emits. Reuses the
# library's failure_class taxonomy when available so the event shape matches
# halt_class_emit's schema (name/status/reason/failure_class/detail) exactly.
_node_refresh_halt_class() {
    local name="$1" reason="$2" detail="${3:-{}}"
    local failure_class="permanent"
    if command -v halt_class_categorize >/dev/null 2>&1; then
        failure_class="$(halt_class_categorize "$reason")"
    fi
    local esc_reason; esc_reason="$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    emit halt_class_emit "\"name\":\"$name\",\"status\":\"failure\",\"reason\":\"$esc_reason\",\"failure_class\":\"$failure_class\",\"detail\":$detail"
}

# --- RESILIENT-1035: role-organ reconcile (the last hop) --------------------
# WHY: the pre-existing chain (git reset -> artifact-pull-or-build -> install
# binary) keeps `chump` current, but a merge can also change what ORGANS a
# role should run (e.g. RESILIENT-1016's worker.sh self-clean reconcile) —
# and nothing here ever re-ran chump-node-install.sh to pick that up. VERIFIED
# on mugman: HEAD lacked a merged organ fix an hour after merge, self-reap
# never activated, because this script only ever deployed the BINARY and (on
# helsinki only) the ATC roster's systemd units — never the role's organ set
# (worker.sh etc.) that chump-node-install.sh --role <role> materializes.
# `--reconcile-organs-only` (added alongside this fix) skips the slow
# clone/creds/binary/substrate/eyes phases and just re-writes + restarts the
# role-scoped organs from the mirror this script just fast-forwarded — so
# "merged" reaches "running" for organs, not just for the chump binary.
#
# CHUMP_NODE_ROLE selects which organ set to converge (default: muscle, the
# class of node — mugman, cuphead — this gap was filed against). Best-effort:
# a failure here must never fail the binary refresh that already succeeded.
NODE_ROLE="${CHUMP_NODE_ROLE:-muscle}"
_reconcile_role_organs() {
    local installer="$REPO_ROOT/scripts/setup/chump-node-install.sh"
    if [[ ! -f "$installer" ]]; then
        log "WARN: $installer not found; skipping role-organ reconcile"
        return 0
    fi
    if CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}" \
         bash "$installer" --role "$NODE_ROLE" --reconcile-organs-only >>"$LOG" 2>&1; then
        log "OK: role-organ reconcile complete (role=$NODE_ROLE)"
        emit node_organs_reconciled "\"role\":\"$NODE_ROLE\""
    else
        log "WARN: chump-node-install.sh --reconcile-organs-only exited non-zero (non-fatal, role=$NODE_ROLE)"
        emit node_organs_reconcile_failed "\"role\":\"$NODE_ROLE\""
    fi
}

# --- atomic install helper (INFRA-3677) --------------------------------------
# Install the binary at $1 to $TARGET_BIN via tempfile + rename. No codesign on
# Linux. Returns non-zero on failure. Shared by the artifact-pull path and the
# local-build path so the two never diverge.
_install_binary() {
    local src="$1"
    mkdir -p "$(dirname "$TARGET_BIN")" 2>/dev/null || true
    cp -f "$src" "$TARGET_BIN.new" 2>>"$LOG" || return 1
    chmod +x "$TARGET_BIN.new"
    mv -f "$TARGET_BIN.new" "$TARGET_BIN" || return 1
}

# --- INFRA-3677: prebuilt-artifact pull --------------------------------------
# The build-speed payoff: instead of a ~30-min local `cargo build --release`,
# fetch the binary the free GH-hosted CI already built for this exact commit
# (.github/workflows/build-fleet-binaries.yml → per-SHA Actions artifact named
# chump-<target>-<full-sha>) and install it. Falls back to a local build (the
# code after this in main flow) when no artifact exists for the SHA, gh is
# unavailable, the arch is unknown, or any integrity/version check fails — so a
# node is never worse off than before, only faster when the artifact is there.
#
# Env overrides:
#   CHUMP_NODE_ARTIFACT_WORKFLOW    workflow file to query (default build-fleet-binaries.yml)
#   CHUMP_NODE_TARGET               force the rust target triple (default: uname -m mapping)
#   CHUMP_NODE_SKIP_ARTIFACT_PULL=1 force the local-build path (skip the pull)
CHUMP_NODE_ARTIFACT_WORKFLOW="${CHUMP_NODE_ARTIFACT_WORKFLOW:-build-fleet-binaries.yml}"

_resolve_rust_target() {
    if [[ -n "${CHUMP_NODE_TARGET:-}" ]]; then printf '%s' "$CHUMP_NODE_TARGET"; return; fi
    case "$(uname -m)" in
        x86_64|amd64)  printf 'x86_64-unknown-linux-gnu' ;;
        aarch64|arm64) printf 'aarch64-unknown-linux-gnu' ;;
        *)             printf '' ;;
    esac
}

# Try to fetch + install the prebuilt binary for $1 (full sha), verified against
# $2 (short green sha the --version must embed). Returns 0 on success (installed),
# non-zero to fall through to the local build. Consumes globals: TARGET_BIN, LOG,
# INSTALLED_SHA (for the emit), plus emit()/log().
_try_artifact_pull() {
    local full_sha="$1" green_short="$2"
    [[ "${CHUMP_NODE_SKIP_ARTIFACT_PULL:-0}" == "1" ]] && { log "artifact-pull: disabled (CHUMP_NODE_SKIP_ARTIFACT_PULL=1)"; return 1; }
    command -v gh >/dev/null 2>&1 || { log "artifact-pull: gh unavailable → local build"; return 1; }
    local target; target="$(_resolve_rust_target)"
    [[ -z "$target" ]] && { log "artifact-pull: unknown arch $(uname -m) → local build"; return 1; }
    [[ -z "$full_sha" || "$full_sha" == "unknown" ]] && { log "artifact-pull: no full sha → local build"; return 1; }

    local _gh_cmd="gh"; command -v chump_gh >/dev/null 2>&1 && _gh_cmd="chump_gh"
    local run_id
    run_id="$(CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" api \
        "repos/{owner}/{repo}/actions/workflows/${CHUMP_NODE_ARTIFACT_WORKFLOW}/runs?head_sha=${full_sha}&status=success&per_page=1" \
        --jq '.workflow_runs[0].id' 2>>"$LOG" | grep -vE '^(null)?$' || true)"
    if [[ -z "$run_id" ]]; then
        log "artifact-pull: no successful $CHUMP_NODE_ARTIFACT_WORKFLOW run for $full_sha → local build"
        emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"no_run\""
        return 1
    fi

    local dl aname pulled
    dl="$(mktemp -d)"
    aname="chump-${target}-${full_sha}"
    if ! CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" run download "$run_id" -n "$aname" --dir "$dl" >>"$LOG" 2>&1; then
        log "artifact-pull: download $aname (run $run_id) failed → local build"
        emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"download_failed\",\"run_id\":\"$run_id\""
        rm -rf "$dl"; return 1
    fi
    pulled="$dl/chump"
    if [[ ! -f "$pulled" ]]; then
        log "artifact-pull: $aname held no chump binary → local build"
        emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"no_binary_in_artifact\""
        rm -rf "$dl"; return 1
    fi
    chmod +x "$pulled" 2>/dev/null || true

    # Integrity: verify sha256 if the artifact shipped one.
    if [[ -f "$dl/chump.sha256" ]] && command -v sha256sum >/dev/null 2>&1; then
        local want got
        want="$(awk '{print $1}' "$dl/chump.sha256" 2>/dev/null)"
        got="$(sha256sum "$pulled" 2>/dev/null | awk '{print $1}')"
        if [[ -n "$want" && "$want" != "$got" ]]; then
            log "artifact-pull: sha256 mismatch (want $want got $got) → local build"
            emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"sha256_mismatch\""
            rm -rf "$dl"; return 1
        fi
    fi

    # Verify the pulled binary runs on THIS host and its version SHA matches the
    # green pointer. A cross-arch or corrupt binary fails here → local build.
    local pulled_ver
    pulled_ver="$("$pulled" --version 2>/dev/null || echo unrunnable)"
    if [[ "$pulled_ver" != *"$green_short"* ]]; then
        log "artifact-pull: version '$pulled_ver' != green $green_short → local build"
        emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"version_mismatch\",\"got\":\"$pulled_ver\""
        rm -rf "$dl"; return 1
    fi

    if ! _install_binary "$pulled"; then
        log "artifact-pull: install to $TARGET_BIN failed → local build"
        emit node_binary_artifact_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"install_failed\""
        rm -rf "$dl"; return 1
    fi
    rm -rf "$dl"

    local new_sha
    new_sha="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "OK: pulled prebuilt $target artifact for $green_short → $TARGET_BIN (skipped local cargo build)"
    emit node_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$new_sha\",\"main_sha\":\"$green_short\",\"method\":\"artifact_pull\",\"target\":\"$target\",\"run_id\":\"$run_id\""
    return 0
}

# --- RESILIENT-1044: owned-built release-asset pull --------------------------
# The SECOND owned/free source, tried before any cold build. The Pixel (owned
# aarch64 iron, 8 real cores) builds the release `chump` binary in an Ubuntu
# 22.04 (glibc 2.35) proot and publishes it as a GitHub Release asset named
# chump-<target>-<full-sha> — see scripts/ops/build-on-pixel.sh +
# scripts/ops/pixel-build-and-publish.sh. This path fetches that owned-built
# asset and installs it with the SAME sha256 + version checks as the CI-artifact
# path, so a node that missed the RENTED GitHub-hosted CI artifact still installs
# a verified binary from OWNED iron instead of falling through to a ~30-min local
# `cargo build --release` — which starves the live fleet on the 2-core brain
# nodes (cuphead/mugman) and is FORBIDDEN. Same "never worse off" contract: any
# miss/failure just falls through to the next path.
#
# scanner-anchor: "kind":"node_binary_release_miss"
#
# Env:
#   CHUMP_NODE_RELEASE_TAG          release tag to pull from    (default: fleet-binaries)
#   CHUMP_NODE_SKIP_RELEASE_PULL=1  skip this source (force the next path)
CHUMP_NODE_RELEASE_TAG="${CHUMP_NODE_RELEASE_TAG:-fleet-binaries}"

_try_release_pull() {
    local full_sha="$1" green_short="$2"
    [[ "${CHUMP_NODE_SKIP_RELEASE_PULL:-0}" == "1" ]] && { log "release-pull: disabled (CHUMP_NODE_SKIP_RELEASE_PULL=1)"; return 1; }
    command -v gh >/dev/null 2>&1 || { log "release-pull: gh unavailable → next"; return 1; }
    local target; target="$(_resolve_rust_target)"
    [[ -z "$target" ]] && { log "release-pull: unknown arch $(uname -m) → next"; return 1; }
    [[ -z "$full_sha" || "$full_sha" == "unknown" ]] && { log "release-pull: no full sha → next"; return 1; }

    local _gh_cmd="gh"; command -v chump_gh >/dev/null 2>&1 && _gh_cmd="chump_gh"
    local asset="chump-${target}-${full_sha}"
    local dl; dl="$(mktemp -d)"
    if ! CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" release download "$CHUMP_NODE_RELEASE_TAG" \
            -p "$asset" -p "$asset.sha256" --dir "$dl" --clobber >>"$LOG" 2>&1; then
        log "release-pull: no owned-built $asset in release $CHUMP_NODE_RELEASE_TAG → next"
        emit node_binary_release_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"asset_absent\""
        rm -rf "$dl"; return 1
    fi
    local pulled="$dl/$asset"
    if [[ ! -f "$pulled" ]]; then
        log "release-pull: release held no $asset binary → next"
        emit node_binary_release_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"no_binary_in_release\""
        rm -rf "$dl"; return 1
    fi
    chmod +x "$pulled" 2>/dev/null || true

    # Integrity: verify sha256 if the sidecar rode along.
    if [[ -f "$dl/$asset.sha256" ]] && command -v sha256sum >/dev/null 2>&1; then
        local want got
        want="$(awk '{print $1}' "$dl/$asset.sha256" 2>/dev/null)"
        got="$(sha256sum "$pulled" 2>/dev/null | awk '{print $1}')"
        if [[ -n "$want" && "$want" != "$got" ]]; then
            log "release-pull: sha256 mismatch (want $want got $got) → next"
            emit node_binary_release_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"sha256_mismatch\""
            rm -rf "$dl"; return 1
        fi
    fi

    # Verify it runs on THIS host and its version SHA matches the green pointer.
    local pulled_ver
    pulled_ver="$("$pulled" --version 2>/dev/null || echo unrunnable)"
    if [[ "$pulled_ver" != *"$green_short"* ]]; then
        log "release-pull: version '$pulled_ver' != green $green_short → next"
        emit node_binary_release_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"version_mismatch\",\"got\":\"$pulled_ver\""
        rm -rf "$dl"; return 1
    fi

    if ! _install_binary "$pulled"; then
        log "release-pull: install to $TARGET_BIN failed → next"
        emit node_binary_release_miss "\"sha\":\"$full_sha\",\"target\":\"$target\",\"reason\":\"install_failed\""
        rm -rf "$dl"; return 1
    fi
    rm -rf "$dl"

    local new_sha
    new_sha="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "OK: pulled owned-built release asset $asset → $TARGET_BIN (skipped local cargo build)"
    emit node_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$new_sha\",\"main_sha\":\"$green_short\",\"method\":\"release_pull\",\"target\":\"$target\",\"tag\":\"$CHUMP_NODE_RELEASE_TAG\""
    return 0
}

# --- RESILIENT-1037: nearest-ancestor artifact discovery ---------------------
# build-fleet-binaries.yml only triggers on push-to-main when the diff touches
# `paths:` that can change the binary (src/**, crates/**, build.rs, Cargo.*).
# The green-main pointer (found below by _find_green_main_sha, keyed off
# ci.yml which runs on EVERY push) has no such filter — a doc-only /
# state.sql-only commit (the recurring "chore(backlog): coherence sync" ships
# this repo produces constantly) advances green-main to a SHA that never had a
# build-fleet-binaries run at all. An exact-sha artifact lookup against that
# pointer always misses ("no green-main sha found"-adjacent symptom: the pull
# path degrades to a local cargo build every cycle even though CI already
# built an identical binary for the last source-changing ancestor commit),
# which is unsafe on a 2-core node (VERIFIED live on mugman: 4 cargo procs).
#
# Fix: instead of asking "is there a build for THIS exact sha", ask "what is
# the newest sha, reachable as an ancestor of (or equal to) this ref, that DID
# get a successful build-fleet-binaries run" — since no buildable path changed
# between that ancestor and the ref (or build-fleet-binaries would have fired
# on every intervening commit too), the binary content is identical and safe
# to pull + install under the ref's tree.
#
# Prints the found sha, or empty when gh is unavailable / no candidate run is
# an ancestor of $1 within the lookback window (caller falls back to the old
# exact-sha behavior, so this is additive-only — never worse than before).
CHUMP_NODE_ARTIFACT_LOOKBACK="${CHUMP_NODE_ARTIFACT_LOOKBACK:-30}"
_find_build_artifact_sha() {
    local ref_sha="$1"
    [[ "${CHUMP_NODE_SKIP_ARTIFACT_PULL:-0}" == "1" ]] && { echo ""; return; }
    command -v gh >/dev/null 2>&1 || { echo ""; return; }
    [[ -z "$ref_sha" || "$ref_sha" == "unknown" ]] && { echo ""; return; }

    local _gh_cmd="gh"; command -v chump_gh >/dev/null 2>&1 && _gh_cmd="chump_gh"
    local shas
    shas="$(CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" api \
        "repos/{owner}/{repo}/actions/workflows/${CHUMP_NODE_ARTIFACT_WORKFLOW}/runs?branch=main&status=success&per_page=${CHUMP_NODE_ARTIFACT_LOOKBACK}" \
        --jq '.workflow_runs[].head_sha' 2>/dev/null)"
    [[ -z "$shas" ]] && { echo ""; return; }

    local candidate
    while IFS= read -r candidate; do
        [[ -z "$candidate" ]] && continue
        if git merge-base --is-ancestor "$candidate" "$ref_sha" 2>/dev/null; then
            echo "$candidate"
            return
        fi
    done <<< "$shas"
    echo ""
}

# --- RESILIENT-327: last-GREEN main pointer, not raw HEAD --------------------
# Returns the full sha of the most-recent SUCCESS run of the required-gate
# workflow on branch main. Falls back to raw origin/main HEAD (old behavior,
# logged loudly) when gh is unavailable or no green run can be found — a node
# with no way to know what's green must still be able to refresh, but the
# fallback is explicit rather than silent so it's auditable in the log/ambient.
CI_WORKFLOW="${CHUMP_NODE_REFRESH_CI_WORKFLOW:-ci.yml}"
GREEN_LOOKBACK="${CHUMP_NODE_REFRESH_GREEN_LOOKBACK:-30}"
_find_green_main_sha() {
    if [[ -n "${CHUMP_NODE_REFRESH_TEST_GREEN_SHA:-}" ]]; then
        echo "$CHUMP_NODE_REFRESH_TEST_GREEN_SHA"
        return
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo ""
        return
    fi
    # INFRA-1274: raw `gh` is banned in hot-path scripts — route through the
    # sanctioned chump_gh wrapper. Fall back to raw gh only if the lib failed to
    # source (chump_gh undefined), so a node with a partial checkout still works.
    local _gh_cmd="gh"
    command -v chump_gh >/dev/null 2>&1 && _gh_cmd="chump_gh"
    CHUMP_GH_CALL_CRITICALITY=background "$_gh_cmd" api \
        "repos/{owner}/{repo}/actions/workflows/${CI_WORKFLOW}/runs?branch=main&status=success&per_page=${GREEN_LOOKBACK}" \
        --jq '[.workflow_runs[] | select(.conclusion=="success")][0].head_sha' 2>/dev/null \
        | grep -vE '^(null|)$' || echo ""
}

if [[ "${CHUMP_SKIP_NODE_REFRESH:-0}" == "1" ]]; then
    log "BYPASS: CHUMP_SKIP_NODE_REFRESH=1"; exit 0
fi

if [[ -z "$REPO_ROOT" ]] || ! git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log "FATAL: no chump mirror checkout found (set CHUMP_NODE_REPO)"
    emit node_binary_refresh_failed "\"reason\":\"no_repo\""
    exit 1
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_binary_refresh_failed "\"reason\":\"cwd_failed\""; exit 1; }

# --- RESILIENT-1041 (fix a): gh-auth precondition ---------------------------
# A gh binary that's present but unauthenticated (no GH_TOKEN, no `gh auth
# login` — the exact state a headless systemd --user timer starts in unless
# the unit exports GH_TOKEN) is indistinguishable, deep inside
# _find_green_main_sha / _find_build_artifact_sha, from "main genuinely never
# went green" — both just come back empty and get diagnosed by their generic
# halt-class names below. Checking auth ONCE up front names the actual root
# cause instead of making the operator infer it from two unrelated-looking
# downstream fallbacks. Best-effort only: it does not change control flow —
# RESILIENT-327's raw-HEAD fallback and the artifact-pull miss path already
# cover "gh answered nothing" regardless of why, so this only sharpens the
# diagnosis, never blocks the refresh.
_check_gh_auth_precondition() {
    command -v gh >/dev/null 2>&1 || return 0
    if ! gh auth status >/dev/null 2>&1; then
        log "WARN: gh present but not authenticated (gh auth status failed) — green-lookup and artifact-pull will both fall back"
        _node_refresh_halt_class "node-refresh-gh-auth" \
            "gh is on PATH but 'gh auth status' failed (no GH_TOKEN / no gh auth login in this timer env) — green-lookup and artifact-pull will both degrade to their fallback paths" \
            "{\"node_repo\":\"$REPO_ROOT\"}"
    fi
}
_check_gh_auth_precondition

# --- fetch + advance the mirror to the last-GREEN main, not raw HEAD --------
# These nodes are pure BUILD MIRRORS (no operator WIP), so a hard reset to the
# green pointer is the correct "make current" operation (RESILIENT-001: the
# converge MUST be a reset, never a merge — a merge aborts on the untracked
# docs/gaps/*.yaml mirrors the fleet drops into this tree). If a node ever grows
# a real working tree, guard this behind a clean-tree check.
git fetch origin main --quiet 2>>"$LOG" || log "WARN: git fetch failed (offline?); building local main"

# BUILD_PIN_SHA is the sha the BINARY is built/pulled from — the RESILIENT-327
# green-main pin (never a red HEAD). It is DISTINCT from where the working tree
# is checked out: RESILIENT-1205 requires the SOURCE tree track origin/main HEAD
# (so merged bash-organ fixes reach the iron), while the compiled binary stays
# pinned to green. Conflating the two — resetting the working tree to the green
# pin — was the merged-!=-deployed keystone bug: whenever green lagged HEAD
# (e.g. a coherence-sync commit that never gets a build artifact), this script
# permanently pinned the checkout behind HEAD AND fought chump-node-converge
# (RESILIENT-1189), which resets the same tree to origin/main every 10 min.
RAW_HEAD_SHA="$(git rev-parse --short=12 origin/main 2>/dev/null || git rev-parse --short=12 HEAD)"
GREEN_SHA="$(_find_green_main_sha)"
if [[ -n "$GREEN_SHA" ]]; then
    BUILD_PIN_SHA="$GREEN_SHA"
    MAIN_SHA="$(git rev-parse --short=12 "$GREEN_SHA" 2>/dev/null || echo "${GREEN_SHA:0:12}")"
    log "green-main = $MAIN_SHA  (raw origin/main HEAD = $RAW_HEAD_SHA, repo: $REPO_ROOT)"
    if [[ "$RAW_HEAD_SHA" != "$MAIN_SHA"* ]]; then
        log "PIN: raw HEAD ($RAW_HEAD_SHA) is ahead of green-main ($MAIN_SHA) — binary pinned to green, source tree tracks HEAD"
        emit node_refresh_green_pin_behind_head "\"green_sha\":\"$MAIN_SHA\",\"raw_head_sha\":\"$RAW_HEAD_SHA\""
    fi
else
    BUILD_PIN_SHA="origin/main"
    MAIN_SHA="$RAW_HEAD_SHA"
    log "WARN: no green-main sha found (gh unavailable or no successful $CI_WORKFLOW run); falling back to raw origin/main HEAD = $MAIN_SHA"
    emit node_refresh_green_lookup_failed "\"fallback_sha\":\"$MAIN_SHA\""
    # RESILIENT-1041: this is the raw-HEAD-fallback halt-class condition — a
    # gh that's present but can't answer (unauthed, unreachable, or no
    # workflow runs at all) is indistinguishable here from "main is red and
    # never went green"; either way this node is about to build/run
    # unverified HEAD instead of the pinned green sha (RESILIENT-327's whole
    # point). A soft ambient emit alone was silently swallowed — nothing
    # paged the operator.
    _node_refresh_halt_class "node-refresh-green-lookup" \
        "gh unavailable/unauthenticated or no successful $CI_WORKFLOW run found; falling back to raw origin/main HEAD instead of the pinned green-main sha" \
        "{\"fallback_sha\":\"$MAIN_SHA\",\"node_repo\":\"$REPO_ROOT\"}"
fi

# --- RESILIENT-1205: converge the SOURCE TREE to origin/main HEAD ------------
# Unconditionally (every cycle, before the binary-idempotency skip below) reset
# the working checkout to origin/main HEAD — the SAME target and shared
# converge_mirror_hard_reset primitive chump-node-converge (RESILIENT-1189)
# uses, so the two organs can never race to different tree states. This is what
# makes a merged BASH-organ fix (which never bumps the binary SHA, so the
# idempotency skip fires) actually reach the iron. Deferred while a git
# operation is in progress so it never yanks the tree from under a rebase/merge.
_git_op_in_progress() {
    local gd; gd="$(git rev-parse --git-dir 2>/dev/null)" || return 1
    [[ -d "$gd/rebase-merge" || -d "$gd/rebase-apply" || -f "$gd/MERGE_HEAD" \
       || -f "$gd/CHERRY_PICK_HEAD" || -f "$gd/BISECT_LOG" ]]
}
if _git_op_in_progress; then
    log "DEFER: git operation in progress — skipping source-tree converge this cycle (will retry next tick)"
else
    if converge_mirror_hard_reset origin/main >>"$LOG" 2>&1; then
        log "converged source tree to origin/main HEAD ($RAW_HEAD_SHA)"
    else
        log "FATAL: converge (git reset --hard) of source tree to origin/main failed"
        emit node_binary_refresh_failed "\"reason\":\"reset_failed\",\"target\":\"origin/main\""
        exit 1
    fi
fi

INSTALLED_SHA="none"
if [[ -x "$TARGET_BIN" ]]; then
    INSTALLED_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
    log "installed $TARGET_BIN sha = $INSTALLED_SHA"
fi

# Idempotency: binary SHA already matches the green pin → skip the build (no
# cargo). The SOURCE tree was already converged to origin/main HEAD above, so a
# skip here still leaves the checkout current — this is precisely the bash-only-
# merge case (binary unchanged, scripts changed) that must still reach the iron.
if [[ "$INSTALLED_SHA" == "$MAIN_SHA"* || "$MAIN_SHA" == "$INSTALLED_SHA"* ]] \
   && [[ "$INSTALLED_SHA" != "none" && "$INSTALLED_SHA" != "unknown" ]]; then
    log "SKIP: binary already current ($INSTALLED_SHA); source tree already at origin/main HEAD"
    emit node_binary_refresh_skipped "\"reason\":\"already_current\",\"sha\":\"$INSTALLED_SHA\""
    _reconcile_role_organs
    exit 0
fi

# --- INFRA-3593: auto-deploy any changed chump-*.service/.timer organ units --
# The mirror just landed whatever merged into origin/main, including any
# chump-*.service/.timer edits (RESILIENT-300 roster). Hand off to
# install-helsinki-atc.sh --auto so a merge auto-installs on helsinki with no
# human step — same "keep current with origin/main" contract this script
# already applies to the binary, extended to the systemd units. Best-effort:
# a failure here must not block the binary refresh above.
DEPLOY_ORGANS="$REPO_ROOT/scripts/setup/install-helsinki-atc.sh"
if [[ -f "$DEPLOY_ORGANS" ]]; then
    NODE_AMBIENT="$NODE_AMBIENT" bash "$DEPLOY_ORGANS" --auto >>"$LOG" 2>&1 \
        || log "WARN: install-helsinki-atc.sh --auto exited non-zero (non-fatal)"
else
    log "WARN: $DEPLOY_ORGANS not found; skipping organ-unit auto-deploy"
fi

# --- INFRA-3677: prebuilt-artifact pull (the build-speed payoff) -------------
# Before spending ~30 min on a local cargo build, try to install the binary CI
# already built for the green pin. On success we're done — no cargo invoked at
# all. On any miss/failure we fall through to the local build below.
# RESILIENT-1205: key the artifact/build off the GREEN PIN (BUILD_PIN_SHA), NOT
# the checked-out HEAD — the working tree now tracks origin/main HEAD, but the
# binary must stay pinned to the last green sha (RESILIENT-327). Building/pulling
# from a HEAD that is ahead of green would deploy an unverified (possibly red)
# binary, the exact regression the green pin exists to prevent.
FULL_SHA="$(git rev-parse "$BUILD_PIN_SHA" 2>/dev/null || echo unknown)"

# RESILIENT-1037: prefer the nearest ancestor sha that actually has a
# build-fleet-binaries run (see _find_build_artifact_sha above) — an exact
# match against FULL_SHA alone misses whenever the green pointer landed on a
# doc-only commit that never triggered a build. Falls back to FULL_SHA itself
# (old exact-match behavior) when no ancestor candidate is found.
ARTIFACT_SHA="$(_find_build_artifact_sha "$FULL_SHA")"
if [[ -n "$ARTIFACT_SHA" && "$ARTIFACT_SHA" != "$FULL_SHA" ]]; then
    log "artifact-pull: $MAIN_SHA has no direct build; using nearest built ancestor $(git rev-parse --short=12 "$ARTIFACT_SHA" 2>/dev/null || echo "${ARTIFACT_SHA:0:12}")"
elif [[ -z "$ARTIFACT_SHA" ]]; then
    ARTIFACT_SHA="$FULL_SHA"
fi
ARTIFACT_SHA_SHORT="$(git rev-parse --short=12 "$ARTIFACT_SHA" 2>/dev/null || echo "${ARTIFACT_SHA:0:12}")"

if _try_artifact_pull "$ARTIFACT_SHA" "$ARTIFACT_SHA_SHORT"; then
    _reconcile_role_organs
    ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

# --- RESILIENT-1044: owned-built release-asset pull (before any cold build) ---
# The rented GitHub-hosted CI artifact was unavailable for this sha. Before
# paying a ~30-min local cargo build on the (often 2-core) brain node, try the
# binary the OWNED Pixel already built + published to the fleet-binaries release.
# The owned builder publishes for the green-main sha itself, so try the green
# pointer (FULL_SHA / MAIN_SHA) first, then the nearest built ancestor.
if _try_release_pull "$FULL_SHA" "$MAIN_SHA"; then
    _reconcile_role_organs
    ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi
if [[ "$ARTIFACT_SHA" != "$FULL_SHA" ]] && _try_release_pull "$ARTIFACT_SHA" "$ARTIFACT_SHA_SHORT"; then
    _reconcile_role_organs
    ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

log "artifact-pull + release-pull unavailable or missed for $MAIN_SHA (artifact sha $ARTIFACT_SHA_SHORT) — building locally"
# RESILIENT-1041: cold-build-revert halt-class condition — this node is about
# to pay a ~30-min local `cargo build --release` on constrained (often
# 2-core) fleet hardware instead of the seconds-long artifact pull. On an
# unauthed-gh timer this is the routine outcome (every green-lookup AND
# artifact-lookup call silently comes back empty), so it happens every
# refresh cycle rather than as an occasional fallback — worth a halt-class
# signal, not just the log line above.
_node_refresh_halt_class "node-refresh-cold-build" \
    "prebuilt artifact unavailable for $MAIN_SHA; falling back to a local cargo build --release (~30min on constrained fleet hardware)" \
    "{\"main_sha\":\"$MAIN_SHA\",\"artifact_sha\":\"$ARTIFACT_SHA_SHORT\",\"node_repo\":\"$REPO_ROOT\"}"

# --- resolve cargo -----------------------------------------------------------
CARGO=""
for candidate in "$HOME/.cargo/bin/cargo" "$(command -v cargo 2>/dev/null)" "/usr/local/bin/cargo"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then CARGO="$candidate"; break; fi
done
if [[ -z "$CARGO" ]]; then
    log "FATAL: cargo not found"; emit node_binary_refresh_failed "\"reason\":\"no_cargo\""; exit 1
fi
log "using cargo: $CARGO"

# RESILIENT-1205: build the GREEN PIN, never the checked-out HEAD. The working
# tree now tracks origin/main HEAD (so bash organs run current), but RESILIENT-327
# still requires the compiled binary come from the last green sha. When green ==
# HEAD (the fallback / no-divergence case) build in place; otherwise build from a
# DETACHED worktree pinned at the green sha so the main checkout stays at HEAD.
# Both builds share the repo's warm target dir via CARGO_TARGET_DIR, so a
# detached-worktree build is no slower than the in-place one.
CARGO_TARGET_DIR_ABS="$REPO_ROOT/target"
BUILD_DIR="$REPO_ROOT"
_BUILD_WT=""
_PIN_FULL="$(git rev-parse "$BUILD_PIN_SHA" 2>/dev/null || echo "")"
_HEAD_FULL="$(git rev-parse HEAD 2>/dev/null || echo "")"
if [[ -n "$_PIN_FULL" && "$_PIN_FULL" != "$_HEAD_FULL" ]]; then
    _BUILD_WT="$(mktemp -d)"
    if git worktree add --detach -q "$_BUILD_WT" "$_PIN_FULL" >>"$LOG" 2>&1; then
        BUILD_DIR="$_BUILD_WT"
        log "cold-build: building green pin $MAIN_SHA in a detached worktree (main tree stays at origin/main HEAD)"
    else
        log "WARN: could not add detached worktree at $BUILD_PIN_SHA; building in place"
        rm -rf "$_BUILD_WT"; _BUILD_WT=""
    fi
fi
_cleanup_build_wt() { [[ -n "$_BUILD_WT" ]] && { git worktree remove --force "$_BUILD_WT" >>"$LOG" 2>&1 || rm -rf "$_BUILD_WT"; }; _BUILD_WT=""; }

log "cargo build --release --bin chump (warm target $CARGO_TARGET_DIR_ABS, source $BUILD_DIR) …"
if ! ( cd "$BUILD_DIR" && PATH="$(dirname "$CARGO"):$PATH" CARGO_TARGET_DIR="$CARGO_TARGET_DIR_ABS" "$CARGO" build --release --bin chump ) >>"$LOG" 2>&1; then
    log "FATAL: cargo build failed; see $LOG"
    emit node_binary_refresh_failed "\"reason\":\"cargo_build_failed\""
    _cleanup_build_wt
    exit 1
fi
BUILT_BIN="$CARGO_TARGET_DIR_ABS/release/chump"
if [[ ! -x "$BUILT_BIN" ]]; then
    log "FATAL: $BUILT_BIN missing after build"
    emit node_binary_refresh_failed "\"reason\":\"binary_missing_post_build\""
    _cleanup_build_wt
    exit 1
fi
_cleanup_build_wt

# --- atomic install (tempfile + rename); no codesign on Linux ----------------
log "install $BUILT_BIN → $TARGET_BIN"
if ! _install_binary "$BUILT_BIN"; then
    log "FATAL: install of $BUILT_BIN → $TARGET_BIN failed"
    emit node_binary_refresh_failed "\"reason\":\"cp_failed\""
    exit 1
fi

NEW_SHA="$("$TARGET_BIN" --version 2>/dev/null | grep -oE '\(([a-f0-9]+) built' | head -1 | sed 's/[( ]//g;s/built//' || echo unknown)"
log "OK: $TARGET_BIN now at sha $NEW_SHA (green-main = $MAIN_SHA)"
emit node_binary_refreshed "\"prev_sha\":\"$INSTALLED_SHA\",\"new_sha\":\"$NEW_SHA\",\"main_sha\":\"$MAIN_SHA\""
_reconcile_role_organs

# Prune old logs (keep last 24)
ls -t "$LOG_DIR"/refresh-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
