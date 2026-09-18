#!/usr/bin/env bash
# install-sccache.sh — INFRA-202: shared compilation cache for fleet worktrees.
# INFRA-3660: activated for CJ WORKERS (not just the pre-push probe), cache
# lives on LOCAL disk only — a USB-mounted data drive on Ubuntu CJ, never a
# cloud/R2 path. See docs/process/SCCACHE_R2_CACHE.md for the separate,
# opt-in CI+R2 remote-cache path — that is NOT what this script wires.
#
# Each linked worktree under .claude/worktrees/ has its own target/ dir.
# Without a shared compilation cache, every fresh worktree pays a 5-15 min
# cold-build cost when bot-merge.sh runs cargo check / clippy / test. With
# sccache as a rustc wrapper, the rustc invocations are cached at the
# crate-compilation level — second worktree to build a given crate version
# gets it from cache in seconds.
#
# What this script does:
#   1. Install sccache — `cargo install sccache` on Linux (Ubuntu CJ has no
#      brew), `brew install sccache` on macOS. Idempotent — skips if present.
#   2. Write .cargo/config.toml with rustc-wrapper=sccache + a LOCAL cache
#      dir (prefers a mounted external/USB data disk over the root disk so
#      the cache doesn't compete with the OS drive for space — INFRA-3660
#      found cjdata1 full at its 13G target while cjdata3 had 13G free).
#      mold / cranelift are only written into the config when the machine
#      actually has them, so a host missing either can't get a broken build.
#   3. Verify with `cargo check --bin chump` and report cache hit rate.
#
# Run this once per machine. .cargo/config.toml is .gitignored so each
# machine controls its own cache config — feel free to tune the cache size
# or disable by removing the file.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

log()  { echo "[install-sccache] $*"; }
warn() { echo "[install-sccache] WARN: $*" >&2; }

OS_KIND="$(uname -s)"

# ── dir-selection helpers — defined up top so scripts/ci/test-sccache-dir-selection.sh
# can `source` this file (BASH_SOURCE guard below skips the install/write/verify
# side effects) and exercise detect_sccache_dir() directly against a faked
# $HOME + df output. INFRA-7113.
# Never a cloud path (no Cloudflare/R2 — see docs/process/SCCACHE_R2_CACHE.md
# for that separate, CI-only, opt-in mechanism).
# INFRA-3661: generalized past the INFRA-3660 cjdata3-specific pin — any
# future owned node should default to $HOME's disk when it has headroom, and
# only reach for a mounted USB/external data disk when $HOME is tight.
SCCACHE_HOME_FREE_THRESHOLD_KB=$((25 * 1024 * 1024))  # 25G, matches AC

# _sccache_dir_writable — REAL write probe, not a permission-bit check.
# A mount can be `-w` (mounted rw, perms fine) yet fail *every* write with
# EBADMSG when the underlying ext4 metadata is corrupt. CJ 2026-08-22:
# /mnt/cjdata3's root inode (#2) failed its directory-block checksum, so
# `touch /mnt/cjdata3/sccache/x` returned "Bad message" and sccache logged
# 100% cache write errors (0% hit rate) — while `-d && -w` still passed.
# Probe with an actual create+unlink so a dead/corrupt disk is skipped.
_sccache_dir_writable() {
    local d="$1" probe
    mkdir -p "$d" 2>/dev/null || return 1
    probe="$d/.sccache-write-probe.$$"
    if ( : > "$probe" ) 2>/dev/null; then
        rm -f "$probe" 2>/dev/null
        return 0
    fi
    return 1
}

detect_sccache_dir() {
    if [[ -n "${SCCACHE_DIR:-}" ]]; then
        echo "$SCCACHE_DIR"
        return
    fi
    local home_avail_kb
    home_avail_kb="$(df -Pk /home 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -n "$home_avail_kb" ]] && (( home_avail_kb >= SCCACHE_HOME_FREE_THRESHOLD_KB )) \
       && _sccache_dir_writable "$HOME/.cache/sccache"; then
        echo "$HOME/.cache/sccache"
        return
    fi
    # /home tight (< 25G), undeterminable, or unwritable — fall back to a
    # mounted USB/data disk. Pick the /mnt|/media filesystem (excluding root)
    # with the most free space THAT PASSES A REAL WRITE PROBE.
    #
    # INFRA-3660 originally hard-pinned /mnt/cjdata3 by name and only tested
    # `-d && -w`. That was fragile: when cjdata3's ext4 went corrupt
    # (2026-08-22) the name-pin kept selecting the dead drive and `-w` never
    # noticed, so the cache silently 100%-write-errored for the whole fleet.
    # Never name-pin a device — health-probe every candidate and skip the
    # dead ones, so a disk failure self-heals to the next good drive.
    # Restrict to real data filesystems (ext*/xfs/btrfs): a bare "most free
    # /mnt path" would happily pick a printer/thumb-drive vfat mount like
    # /mnt/print1, which has no unix perms and bad filename semantics for a
    # compile cache.
    local root_fs
    root_fs="$(df -P / 2>/dev/null | awk 'NR==2{print $1}')"
    local best="" best_avail_kb=0
    while read -r fs fstype avail_kb mnt; do
        [[ "$fs" == "$root_fs" ]] && continue
        case "$fstype" in ext4|ext3|ext2|xfs|btrfs) ;; *) continue ;; esac
        _sccache_dir_writable "$mnt/sccache" || continue
        if (( avail_kb > best_avail_kb )); then
            best_avail_kb=$avail_kb
            best="$mnt"
        fi
    done < <(df -PkT /mnt/* /media/*/* 2>/dev/null | awk 'NR>1{print $1, $2, $5, $7}')
    if [[ -n "$best" ]]; then
        echo "$best/sccache"
    else
        # Last resort: $HOME even if tight — a working cache beats none.
        echo "$HOME/.cache/sccache"
    fi
}

# Everything below has side effects (installs sccache, writes .cargo/config.toml,
# runs cargo check) — skip it when this file is sourced (e.g. by the test
# harness above) so tests can call detect_sccache_dir() in isolation.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0
fi

# ── 1. install sccache ──────────────────────────────────────────────────
log "checking for sccache …"
if ! command -v sccache >/dev/null 2>&1; then
    case "$OS_KIND" in
        Linux)
            log "sccache not found — installing via 'cargo install sccache' (Ubuntu CJ has no brew)"
            cargo install sccache --locked
            ;;
        Darwin)
            log "sccache not found — installing via brew"
            brew install sccache
            ;;
        *)
            warn "unrecognized OS '$OS_KIND' — install sccache manually (cargo install sccache)"
            exit 1
            ;;
    esac
else
    log "sccache already installed ($(sccache --version | head -1))"
fi

# ── 2. pick a LOCAL cache dir — prefer an external/USB data disk ────────
# (helpers defined above, before the sourced-guard)
SCCACHE_DIR_RESOLVED="$(detect_sccache_dir)"
SCCACHE_CACHE_SIZE_RESOLVED="${SCCACHE_CACHE_SIZE:-10G}"
log "cache dir: $SCCACHE_DIR_RESOLVED (cap $SCCACHE_CACHE_SIZE_RESOLVED)"
mkdir -p "$SCCACHE_DIR_RESOLVED"

# ── availability-gate mold + cranelift (INFRA-3660) ─────────────────────
# INFRA-2242 originally wrote these unconditionally; on a host missing the
# binary/component that broke the build outright. Only emit each block when
# this machine actually has the thing.
MOLD_BLOCK=""
if command -v mold >/dev/null 2>&1; then
    log "mold found — enabling fast linker for linux targets"
    MOLD_BLOCK='
# INFRA-2242 / INFRA-3660: mold linker — written only because `mold` is on
# PATH on this machine. Linux-only (macOS does not get this section).
# Drops link phase 10-15% on warm rebuilds.
[target.x86_64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-fuse-ld=mold"]

[target.aarch64-unknown-linux-gnu]
rustflags = ["-C", "link-arg=-fuse-ld=mold"]
'
else
    log "mold not found — omitting fast-linker section (build stays on the default linker)"
fi

CRANELIFT_BLOCK=""
if rustup component list --installed 2>/dev/null | grep -q '^rustc-codegen-cranelift'; then
    log "cranelift codegen backend found — enabling for dev profile"
    CRANELIFT_BLOCK='
# INFRA-2242 / INFRA-3660: cranelift codegen backend — DEV-PROFILE ONLY,
# written only because rustc-codegen-cranelift is installed on this machine.
# Release builds stay on llvm (cranelift release codegen is not
# production-ready). Saves 5-10% on debug compile wall-clock.
[profile.dev]
codegen-backend = "cranelift"

# Required for the per-profile codegen-backend syntax above.
[unstable]
codegen-backend = true
'
else
    log "cranelift component not installed — omitting codegen-backend section"
fi

log "writing .cargo/config.toml"
mkdir -p .cargo
{
cat <<EOF
# INFRA-202: sccache as rustc wrapper for fleet worktrees.
# INFRA-3660: LOCAL disk cache only (USB on Ubuntu CJ) — no Cloudflare/R2.
# mold/cranelift sections below are availability-gated at generation time so
# a config written on one machine can't break a build on another.
# Generated by scripts/setup/install-sccache.sh — do not edit by hand,
# re-run the script if you need to regenerate.
#
# .gitignore'd because per-machine: a CI runner without sccache would
# break here.
#
# Linux / Docker cross-build gotcha (INFRA-2104 / INFRA-2105):
#   This rustc-wrapper breaks \`cargo build\` inside containers that don't
#   have sccache on PATH. To cross-build chump-coord for Linux without
#   the env-var dance, use:
#       bash scripts/dev/cross-build-linux.sh
#   It sets CARGO_BUILD_RUSTC_WRAPPER="" automatically and uses an
#   isolated target dir so failed runs don't poison state.
[build]
rustc-wrapper = "sccache"
EOF
[[ -n "$MOLD_BLOCK" ]] && printf '%s' "$MOLD_BLOCK"
[[ -n "$CRANELIFT_BLOCK" ]] && printf '%s' "$CRANELIFT_BLOCK"
cat <<EOF

[env]
# Cache size cap — kept small enough to fit a USB data disk alongside other
# fleet data (INFRA-3660: 13G free on cjdata3 after cjdata1 filled up at its
# old 13G target). Tune via \$SCCACHE_CACHE_SIZE if your machine differs.
SCCACHE_CACHE_SIZE = "$SCCACHE_CACHE_SIZE_RESOLVED"
# LOCAL disk cache only — never a cloud path. Override with SCCACHE_DIR=/path
# and re-run this script if you want a different location.
SCCACHE_DIR = "$SCCACHE_DIR_RESOLVED"
EOF
} > .cargo/config.toml

# ── 3. verify (best-effort) ──────────────────────────────────────────────
# Not a hard gate: on a live multi-worker fleet host, concurrent builds in
# sibling worktrees can hold the shared target/ build-directory lock
# (INFRA-1374) for minutes — that contention is a separate, known issue,
# not a failure of this install. The config is written and correct either
# way; this step is just a convenience smoke test when the lock is free.
log "verifying with cargo check (best-effort, 60s cap) …"
export SCCACHE_DIR="$SCCACHE_DIR_RESOLVED"
export SCCACHE_CACHE_SIZE="$SCCACHE_CACHE_SIZE_RESOLVED"
sccache --zero-stats >/dev/null 2>&1 || true
if timeout 60 cargo check --bin chump >/tmp/install-sccache-check.log 2>&1; then
    log "cargo check OK"
    log "sccache stats:"
    sccache --show-stats | grep -E "compile requests|cache hits|cache misses" | sed 's/^/  /'
elif grep -q "Blocking waiting for file lock" /tmp/install-sccache-check.log 2>/dev/null; then
    warn "cargo check is waiting on the shared build-directory lock (sibling worktree build in progress) — config is in place; re-run this script later to verify, or check manually with 'sccache --show-stats'"
else
    warn "cargo check didn't complete within 60s; see /tmp/install-sccache-check.log"
    warn "config is in place regardless — this step is a smoke test, not a gate"
fi

log "done. Future cargo invocations in any worktree will use sccache."
log "To opt out on this machine: rm .cargo/config.toml"
