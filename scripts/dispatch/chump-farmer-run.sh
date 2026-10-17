#!/usr/bin/env bash
# scripts/dispatch/chump-farmer-run.sh — RESILIENT-313
#
# Persistent farmer runner. The ExecStart target of chump-farmer.service, fired
# every ~30s by chump-farmer.timer. This is the "baked into the OS" scheduler the
# farmer never had: farmer.sh is a single-tick script (RESILIENT-068) and NOTHING
# on helsinki ran it on a schedule — the fleet was kept alive only by a fragile,
# hand-installed *transient* `chump-farmer-bridge` unit that this runner retires.
#
# WHY A WRAPPER (not just ExecStart=farmer.sh):
#   1. Env: systemd's minimal env lacks HOME/PATH and does not source providers.env
#      (which is `export KEY=val`, unparseable by systemd EnvironmentFile). We set
#      HOME/PATH and `source` providers.env in a login-ish shell here.
#   2. Stale-lease hygiene: farmer.sh no longer CRASHES on a stale lease
#      (RESILIENT-313 fixed the `stat -f %m` macOS-ism), but a >30min lease is
#      still dead work holding a slot. We sweep them BEFORE each tick — the same
#      hygiene the retired bridge did, now declared in the repo.
#   3. OAuth mtime (INFRA-1865): the macOS-keychain refresher
#      (oauth-token-refresh.sh) is a no-op on Linux, so ~/.chump/oauth-token.json's
#      mtime goes stale even though the token VALUE (from providers.env) is a valid
#      long-lived credential. The Rust farmer-gate RED-blocks on mtime > 3600s
#      (src/farmer_status.rs OAUTH_TOKEN_MAX_AGE_S). We re-derive the token file
#      from providers.env when its mtime is aging, which refreshes the mtime
#      HONESTLY (re-reading the live source of truth), not a blind `touch`.
#
# Pure ops glue over coreutils + farmer.sh. No network, no cargo binaries on the
# hot path (preserves farmer.sh's no-shared-failure-mode axiom).

set -uo pipefail

export HOME="${HOME:-/root}"
export USER="${USER:-root}"
# RESILIENT-376: host-aware PATH. systemd's minimal env lacks PATH, so we set a
# sane default — but a hardcoded /usr/bin:/bin has NO Termux binaries (curl,
# python3, git, even bash live under $PREFIX/bin on Android/Termux), which broke
# the auth-status.sh free-tier probe (curl -> 000 -> false RED) and every other
# coreutils call on the Pixel node. Lead with $PREFIX/bin + $HOME/.cargo/bin when
# present, keep the Linux-root defaults as fallback, and preserve any inherited
# PATH. INFRA-8194 (R5 slice 2): the run-user's own dirs come from $HOME (set by
# the rendered unit), not a baked root home: on helsinki HOME is root's home so
# the lookup order is unchanged, and on an owned node the old literal root-home
# entries were unreadable dead weight.
export PATH="${PREFIX:+$PREFIX/bin:}$HOME/.cargo/bin:$HOME/.local/bin:$HOME/bin:/usr/local/bin:/usr/bin:/bin${PATH:+:$PATH}"

# Derive the repo root from this script's OWN location — it lives at
# <repo>/scripts/dispatch/chump-farmer-run.sh — instead of a hardcoded
# /root/Projects/chump default. That default was helsinki(root)-shaped: on an
# owned node (User=ubuntu) it pointed cd at /root/Projects/chump, which the
# run-user cannot enter -> "Permission denied" -> exit 1 every 30s tick, darking
# the worker-gate heartbeat this organ exists to keep fresh (RESILIENT-313).
# BASH_SOURCE + pwd -P is host-agnostic AND resolves the bootstrap symlink to the
# real checkout, so the farmer runs correctly on helsinki, CJ, Termux, and the
# Oracle nodes alike. CHUMP_REPO still overrides (the out-of-tree farmer.sh test
# path in §4 below). On helsinki this yields /root/Projects/chump exactly as
# before — backward-compatible.
_FARMER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="${CHUMP_REPO:-$(cd "$_FARMER_SCRIPT_DIR/../.." && pwd -P)}"
LOCK_DIR="$REPO_ROOT/.chump-locks"
# Default providers.env under the run-user's HOME (set by the unit), not a
# hardcoded /root — same host-portability reason as REPO_ROOT above.
PROVIDERS_ENV="${CHUMP_PROVIDERS_ENV:-$HOME/.chump/providers.env}"
TOKEN_FILE="${CHUMP_OAUTH_TOKEN_FILE:-$HOME/.chump/oauth-token.json}"
STALE_LEASE_MIN="${CHUMP_FARMER_STALE_LEASE_MIN:-30}"
# Refresh the token file once its mtime is half-way to the 3600s gate, so the
# gate never sees a stale mtime but we don't rewrite (and bust the auth-status
# cache's freshness check) every single 30s tick.
OAUTH_REFRESH_AGE_S="${CHUMP_FARMER_OAUTH_REFRESH_AGE_S:-1800}"

_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { printf '[chump-farmer-run %s] %s\n' "$(_ts)" "$*"; }

# 1. Load fleet credentials (export-format env; source in a shell).
# providers.env may reference not-yet-set vars, so drop `set -u` around the
# source (it would abort the whole runner on the first unbound expansion — the
# retired bridge sourced with -u off and 2>/dev/null for the same reason).
# shellcheck disable=SC1090
if [[ -f "$PROVIDERS_ENV" ]]; then set +u; set -a; source "$PROVIDERS_ENV" 2>/dev/null || true; set +a; set -u; fi

# 2. Stale-lease hygiene — a >Nmin claim-*.json lease is dead work holding a slot.
if [[ -d "$LOCK_DIR" ]]; then
    find "$LOCK_DIR" -maxdepth 1 -name 'claim-*.json' -mmin "+${STALE_LEASE_MIN}" -delete 2>/dev/null || true
fi

# 3. OAuth mtime refresh (Linux-only; macOS has its own keychain refresher).
#    Re-derive ~/.chump/oauth-token.json from providers.env's long-lived
#    CLAUDE_CODE_OAUTH_TOKEN so the Rust farmer-gate's mtime check stays GREEN.
#    Honest, not a blind touch: we only (re)write when a real token is present in
#    the live source, and we only bother once the mtime is aging.
refresh_oauth_mtime() {
    [[ "$(uname -s)" == "Darwin" ]] && return 0   # macOS: keychain refresher owns this
    local tok="${CLAUDE_CODE_OAUTH_TOKEN:-}"
    [[ -n "$tok" ]] || { log "no CLAUDE_CODE_OAUTH_TOKEN in providers.env — skipping oauth mtime refresh (INFRA-1865)"; return 0; }
    local age=999999
    if [[ -f "$TOKEN_FILE" ]]; then
        local m; m="$(stat -c %Y "$TOKEN_FILE" 2>/dev/null || stat -f %m "$TOKEN_FILE" 2>/dev/null || echo 0)"
        [[ "$m" =~ ^[0-9]+$ ]] || m=0
        age=$(( $(date +%s) - m ))
    fi
    # Skip if a still-fresh file already holds the SAME token (avoid churning the
    # auth-status cache's "credential newer than cache" re-probe every tick).
    if [[ "$age" -lt "$OAUTH_REFRESH_AGE_S" && -f "$TOKEN_FILE" ]]; then
        local cur; cur="$(python3 -c "import json,sys;print(json.load(open('$TOKEN_FILE')).get('token',''))" 2>/dev/null || true)"
        [[ "$cur" == "$tok" ]] && return 0
    fi
    mkdir -p "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    chmod 700 "$(dirname "$TOKEN_FILE")" 2>/dev/null || true
    local tmp="${TOKEN_FILE}.tmp.$$"
    printf '{"token":"%s","written_at":"%s","source":"providers.env-linux"}\n' "$tok" "$(_ts)" > "$tmp" 2>/dev/null || return 0
    chmod 600 "$tmp" 2>/dev/null || true
    mv "$tmp" "$TOKEN_FILE" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    log "refreshed oauth-token.json mtime from providers.env (prev_age=${age}s, INFRA-1865)"
}
refresh_oauth_mtime

# 4. Run one farmer tick (crash-proof + writes heartbeat, RESILIENT-313).
#    CHUMP_FARMER_SH lets an out-of-tree copy of farmer.sh be exercised while
#    still writing the heartbeat into the REAL worker repo (CHUMP_REPO_ROOT) that
#    the worker binary gates on — used to validate a fix before it merges.
FARMER_SH="${CHUMP_FARMER_SH:-$REPO_ROOT/scripts/coord/farmer.sh}"
cd "$REPO_ROOT" || { log "ERROR: repo root $REPO_ROOT missing"; exit 1; }
exec env CHUMP_REPO_ROOT="$REPO_ROOT" bash "$FARMER_SH"
