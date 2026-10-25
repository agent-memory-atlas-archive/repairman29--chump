#!/usr/bin/env bash
# board-tick.sh — the board/ATC's MANDATORY wake procedure. Run FIRST every wake/tick; FOLLOW the orders it prints.
# Not exempt: the board follows orders like everyone. Ribbon-only. Dispatch, never hand-do. Stay on the ladder.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6 || true)"
[[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && REAL_HOME="${HOME:-/tmp}"
export HOME="$REAL_HOME"
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH"

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$HOME/Projects/chump")}"
if [[ ! -d "$REPO_ROOT/.git" && ! -f "$REPO_ROOT/.git" ]]; then
  for _cand in "$HOME/Projects/chump" "$HOME/chump"; do
    [[ -e "$_cand/.git" ]] && { REPO_ROOT="$_cand"; break; }
  done
fi

STATE_DIR="${CHUMP_HUB_STATE_DIR:-${CHUMP_STATE_DIR:-$HOME/.chump}}"
VITALS_JSON="${CHUMP_VITALS_OUT:-$STATE_DIR/vital-signs.json}"
export CHUMP_AMBIENT_LOG="${CHUMP_HUB_AMBIENT_LOG:-${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}}"

cd "$REPO_ROOT" 2>/dev/null || exit 1
echo "═══════════ BOARD TICK  $(date -u +%FT%TZ) ═══════════"
echo "ORDER 0 · RIBBON IS THE ONLY BAR. Everything else parked. For every action ask:"
echo "         'does this move the factory toward a HANDS-OFF Trek from a CLEAN install?' — if NO → PARK IT."
# --- read the board (regenerate the collector from MAIN, where the fixes are merged) ---
git fetch origin main -q 2>/dev/null || true
# INFRA-8097: run the collector from an EXTRACTED TREE, not a single relocated
# copy. Extract the whole scripts/ops subtree so relative layout is preserved.
VS_ERR="$STATE_DIR/vital-signs.stderr.log"
mkdir -p "$STATE_DIR" 2>/dev/null || true
VS_TMP="$(mktemp -d)"
if git archive origin/main scripts/ops 2>/dev/null | tar -x -C "$VS_TMP" 2>/dev/null; then
  CHUMP_REPO_ROOT="$REPO_ROOT" CHUMP_VITALS_OUT="$VITALS_JSON" \
    CHUMP_HUB_AMBIENT_LOG="${CHUMP_HUB_AMBIENT_LOG:-}" \
    CHUMP_HUB_STATE_DIR="${CHUMP_HUB_STATE_DIR:-}" \
    CHUMP_HUB_HOST="${CHUMP_HUB_HOST:-}" \
    bash "$VS_TMP/scripts/ops/vital-signs.sh" >>"$VS_ERR" 2>&1 || true
elif [[ -f "$REPO_ROOT/scripts/ops/vital-signs.sh" ]]; then
  CHUMP_REPO_ROOT="$REPO_ROOT" CHUMP_VITALS_OUT="$VITALS_JSON" \
    CHUMP_HUB_AMBIENT_LOG="${CHUMP_HUB_AMBIENT_LOG:-}" \
    CHUMP_HUB_STATE_DIR="${CHUMP_HUB_STATE_DIR:-}" \
    CHUMP_HUB_HOST="${CHUMP_HUB_HOST:-}" \
    bash "$REPO_ROOT/scripts/ops/vital-signs.sh" >>"$VS_ERR" 2>&1 || true
else
  echo "board-tick $(date -u +%FT%TZ): git archive origin/main scripts/ops failed" >>"$VS_ERR" 2>&1 || true
fi
rm -rf "$VS_TMP"
echo "ORDER 1 · READ THE BOARD (measure to treat, not admire):"
jq -r '.signs[]|select(.status=="red" or .status=="unknown")|"         [\(.status|ascii_upcase)] \(.name) = \(.value) \(.unit)"' "$VITALS_JSON" 2>/dev/null || echo "         (board unreadable — instrument-repair owner must fix)"
OLD=$(gh pr list --state open --json createdAt --jq 'sort_by(.createdAt)|.[0].createdAt|((now-(fromdate))/60)|floor' 2>/dev/null)
# INFRA-8097: read human_intervention from the SIGN, never re-derive it with a
# second `grep -c operator_page` over the ambient log.
HI="$(jq -r '.signs[]|select(.key=="human_intervention")|.value' "$VITALS_JSON" 2>/dev/null)"
echo "         oldest-PR=${OLD:-?}m  merges/1h=$(gh pr list --state merged --limit 40 --json mergedAt --jq '[.[].mergedAt]|map(select(.>(now-3600|todate)))|length' 2>/dev/null)  human_intervention(pages/24h)=${HI:-null}"
# --- MINE BEFORE BUILD: are the EYES (Almanac) up on THIS node? ---
ALM=DOWN
for a in almanac "$REPO_ROOT/almanac/target/release/almanac" "$HOME/.almanac/almanac" almanac/target/release/almanac; do
  command -v "$a" >/dev/null 2>&1 && { ALM=UP; break; }
  [ -x "$a" ] && { ALM=UP; break; }
done
echo "ORDER 2 · MINE BEFORE BUILD — eyes(Almanac)=$ALM. BEFORE dispatching ANY build / new organ, ask Almanac first:"
echo "         'does this ALREADY EXIST? and if it does — is it a CODE gap or a DEPLOYMENT/WIRING gap?' It almost always exists (tonight: 3 organs were written, just not deployed)."
echo "         → exists-undeployed ⇒ dispatch the WIRING, never a rebuild.  eyes=DOWN ⇒ you are BLIND: bootstrap Almanac on this node before you dispatch a build."
echo "ORDER 3 · EACH RED/UNKNOWN NEEDS A DISPATCHED OWNER. Owned → leave it. UNOWNED → DISPATCH an owner. Never hand-fix a score."
echo "ORDER 4 · HAND-TOUCH GUARD — if you are about to: rerun a check / merge or close a PR by hand / hand-code a gap / poke a PR number → STOP. You are the ATC, not a worker. Dispatch it."
echo "ORDER 5 · LADDER — what hand-crank becomes an ORGAN this tick? Is human_intervention FALLING? If you keep doing a thing by hand, transfer it into the OS and climb off."
echo "ORDER 6 · VERDICT — DISPATCH the unowned, VERIFY (live, not green) the owned, else CRISP NOOP. Surface to Jeff ONLY a red→green crossing or a compass decision."
echo "═════════════════════════════════════════════════════════"
