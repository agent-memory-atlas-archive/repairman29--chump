#!/usr/bin/env bash
# install-opencode-harness.sh — EFFECTIVE-320 (born-wired)
#
# Idempotent installer that wires the opencode + Almanac worker harness so a
# fresh machine is BORN with the cheap fleet, instead of a human re-assembling
# it by hand (the 2026-07-27 session did every step below manually before this
# script existed). Opt-in: the fleet defaults to the claude harness; this wires
# the opencode path for cost-sensitive / high-volume work.
#
# What it wires (each step idempotent + auto-detected, override via env):
#   1. opencode CLI present?        (subscription tool — cannot auto-install;
#                                    prints the install hint and skips cleanly.)
#   2. almanac-mcp binary           CHUMP_ALMANAC_MCP_BIN or common locations.
#   3. almanac index for this repo  CHUMP_ALMANAC_DB or almanac/indexes/<repo>-src.db;
#                                   builds via `almanac init` when the CLI is
#                                   present and the index is missing.
#   4. opencode.json mcp.almanac    grounded context over MCP so opencode QUERIES
#                                   the index instead of self-indexing a large
#                                   repo (the RESILIENT-203 wall). Merged, never
#                                   clobbers other opencode config.
#   5. verify                       `opencode mcp list` shows almanac connected.
#
# Env overrides: CHUMP_ALMANAC_MCP_BIN, CHUMP_ALMANAC_DB, CHUMP_ALMANAC_EMBED_URL,
#   CHUMP_ALMANAC_DIR (repo root of the almanac checkout).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPO_NAME="$(basename "$REPO_ROOT")"
OC_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"

log()  { echo "[install-opencode-harness] $*"; }
skip() { log "SKIP: $*"; exit 0; }

emit() {  # kind extra_json
    local amb="$REPO_ROOT/.chump-locks/ambient.jsonl"
    [[ -d "$(dirname "$amb")" ]] || return 0
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","kind":"%s","source":"install-opencode-harness"%s}\n' \
        "$ts" "$1" "${2:+,$2}" >> "$amb" 2>/dev/null || true
}

# ── 1. opencode CLI ──────────────────────────────────────────────────────────
if ! command -v opencode >/dev/null 2>&1; then
    log "opencode CLI not found. Install it (https://opencode.ai) + authenticate"
    log "  (opencode auth login) to use the opencode worker harness, then re-run."
    emit "opencode_harness_install_skipped" '"reason":"opencode_cli_absent"'
    skip "opencode not installed (opt-in harness) — nothing to wire yet"
fi

# ── 2. almanac-mcp binary ────────────────────────────────────────────────────
ALMANAC_DIR="${CHUMP_ALMANAC_DIR:-$(dirname "$REPO_ROOT")/almanac}"
MCP_BIN="${CHUMP_ALMANAC_MCP_BIN:-}"
if [[ -z "$MCP_BIN" ]]; then
    for c in \
        "$ALMANAC_DIR/target/release/almanac-mcp" \
        "$ALMANAC_DIR/target/debug/almanac-mcp" \
        "$HOME/Projects/almanac/target/release/almanac-mcp" \
        "$HOME/Projects/almanac/target/debug/almanac-mcp" \
        "$(command -v almanac-mcp 2>/dev/null || true)"; do
        [[ -n "$c" && -x "$c" ]] && { MCP_BIN="$c"; ALMANAC_DIR="$(cd "$(dirname "$c")/../.." && pwd)"; break; }
    done
fi
if [[ -z "$MCP_BIN" || ! -x "$MCP_BIN" ]]; then
    log "almanac-mcp binary not found (looked under $ALMANAC_DIR/target, PATH)."
    log "  Build it (cd almanac && cargo build --release -p almanac-mcp) or set"
    log "  CHUMP_ALMANAC_MCP_BIN, then re-run. Wiring opencode WITHOUT almanac is"
    log "  fine for small repos; large repos need the grounded index (RESILIENT-203)."
    emit "opencode_harness_install_partial" '"reason":"almanac_mcp_absent"'
    skip "almanac-mcp absent — opencode usable for small repos; re-run to add grounded context"
fi

# ── 3. almanac index for this repo ───────────────────────────────────────────
REPO_NAME_LC="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]')"
ALMANAC_DB="${CHUMP_ALMANAC_DB:-$ALMANAC_DIR/indexes/${REPO_NAME_LC}-src.db}"
ALMANAC_EMBED_URL="${CHUMP_ALMANAC_EMBED_URL:-http://localhost:11434}"
if [[ ! -f "$ALMANAC_DB" ]]; then
    if command -v almanac >/dev/null 2>&1; then
        log "no index at $ALMANAC_DB — building via 'almanac init' (may take a few minutes)…"
        ( cd "$REPO_ROOT" && almanac init ) || log "WARN: 'almanac init' failed; wiring config anyway"
    else
        log "WARN: no index at $ALMANAC_DB and 'almanac' CLI absent — opencode will"
        log "  still start but almanac_search will be empty until the repo is indexed."
    fi
fi

# ── 4. wire opencode.json mcp.almanac (merge, idempotent) ────────────────────
mkdir -p "$(dirname "$OC_CONFIG")"
[[ -f "$OC_CONFIG" ]] || printf '{"$schema":"https://opencode.ai/config.json"}\n' > "$OC_CONFIG"

python3 - "$OC_CONFIG" "$MCP_BIN" "$ALMANAC_DB" "$ALMANAC_EMBED_URL" <<'PY'
import json, sys
cfg_path, mcp_bin, db, embed = sys.argv[1:5]
try:
    cfg = json.load(open(cfg_path))
    if not isinstance(cfg, dict):
        cfg = {}
except Exception:
    cfg = {}
cfg.setdefault("$schema", "https://opencode.ai/config.json")
mcp = cfg.setdefault("mcp", {})
mcp["almanac"] = {
    "type": "local",
    "command": [mcp_bin],
    "environment": {"ALMANAC_DB": db, "ALMANAC_EMBED_URL": embed},
    "enabled": True,
}
json.dump(cfg, open(cfg_path, "w"), indent=2)
open(cfg_path, "a").write("\n")
print("  wired mcp.almanac -> %s (db=%s)" % (mcp_bin, db))
PY
log "opencode.json updated: $OC_CONFIG"

# ── 5. verify ────────────────────────────────────────────────────────────────
if opencode mcp list 2>/dev/null | grep -qiE 'almanac.*connected|connected.*almanac'; then
    log "✓ opencode mcp list: almanac connected"
    emit "opencode_harness_installed" "\"almanac_db\":\"$ALMANAC_DB\",\"mcp_bin\":\"$MCP_BIN\""
else
    log "WARN: opencode mcp list did not report almanac connected — check:"
    log "  opencode mcp list   (and the db path: $ALMANAC_DB)"
    emit "opencode_harness_install_unverified" '"reason":"mcp_list_no_connect"'
fi

log "Done. To run the fleet on opencode: set CHUMP_WORK_BACKEND=opencode +"
log "  FLEET_MODEL=opencode-go/<model> in .env, then: chump fleet start --size 1"
