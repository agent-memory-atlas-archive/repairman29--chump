#!/usr/bin/env bash
# board-tick.sh — the board/ATC's MANDATORY wake procedure. Run FIRST every wake/tick; FOLLOW the orders it prints.
# Not exempt: the board follows orders like everyone. Ribbon-only. Dispatch, never hand-do. Stay on the ladder.
set -uo pipefail
export PATH=/usr/local/bin:/usr/bin:/bin:$HOME/.cargo/bin:$PATH HOME=/home/jeff
export CHUMP_AMBIENT_LOG=/home/jeff/Projects/chump/.chump-locks/ambient.jsonl
cd "$HOME/Projects/chump" 2>/dev/null || exit 1
echo "═══════════ BOARD TICK  $(date -u +%FT%TZ) ═══════════"
echo "ORDER 0 · RIBBON IS THE ONLY BAR. Everything else parked. For every action ask:"
echo "         'does this move the factory toward a HANDS-OFF Trek from a CLEAN install?' — if NO → PARK IT."
# --- read the board (regenerate the collector from MAIN, where the fixes are merged) ---
# was: origin/infra-vital-signs-collector (a STALE feature branch) — sourcing the
# collector from there REGENERATED the board with the OLD collector every tick and
# clobbered merged_not_running true value (95.8) to spurious null. main is the source
# of truth after merge; read it so the board reads TRUE. (honest-instrument fix)
git fetch origin main -q 2>/dev/null || true
# INFRA-8097: run the collector from an EXTRACTED TREE, not a single relocated
# copy. Copying only vital-signs.sh to ~/.chump/_vs.sh orphaned it from
# scripts/ops/lib (merges-24h.sh, operator-pages-24h.sh) and from
# scripts/ops/capability-lifecycle.sh, so every tick ran a collector that
# sourced nothing and silently reported merge_throughput=null. Extract the whole
# scripts/ops subtree so the relative layout is preserved. stderr is LOGGED
# (it used to be >/dev/null 2>&1, which hid the breakage completely).
VS_ERR="$HOME/.chump/vital-signs.stderr.log"
VS_TMP="$(mktemp -d)"
if git archive origin/main scripts/ops 2>/dev/null | tar -x -C "$VS_TMP" 2>/dev/null; then
  CHUMP_REPO_ROOT="$HOME/Projects/chump" bash "$VS_TMP/scripts/ops/vital-signs.sh" >>"$VS_ERR" 2>&1 || true
else
  echo "board-tick $(date -u +%FT%TZ): git archive origin/main scripts/ops failed" >>"$VS_ERR" 2>&1 || true
fi
rm -rf "$VS_TMP"
echo "ORDER 1 · READ THE BOARD (measure to treat, not admire):"
jq -r '.signs[]|select(.status=="red" or .status=="unknown")|"         [\(.status|ascii_upcase)] \(.name) = \(.value) \(.unit)"' /home/jeff/.chump/vital-signs.json 2>/dev/null || echo "         (board unreadable — instrument-repair owner must fix)"
OLD=$(gh pr list --state open --json createdAt --jq 'sort_by(.createdAt)|.[0].createdAt|((now-(fromdate))/60)|floor' 2>/dev/null)
# INFRA-8097: read human_intervention from the SIGN, never re-derive it with a
# second `grep -c operator_page` over the ambient log. The sign is the canonical
# number (lib/operator-pages-24h.sh, shared with faculty-collector.sh) and this
# line was a second, unreconciled computation that could disagree with it.
HI="$(jq -r '.signs[]|select(.key=="human_intervention")|.value' /home/jeff/.chump/vital-signs.json 2>/dev/null)"
echo "         oldest-PR=${OLD:-?}m  merges/1h=$(gh pr list --state merged --limit 40 --json mergedAt --jq '[.[].mergedAt]|map(select(.>(now-3600|todate)))|length' 2>/dev/null)  human_intervention(pages/24h)=${HI:-null}"
# --- MINE BEFORE BUILD: are the EYES (Almanac) up on THIS node? (factory-blind guard — the eyes ran only on the Mac once; a build-node with no eyes builds blind) ---
ALM=DOWN
for a in almanac "$HOME/Projects/chump/almanac/target/release/almanac" "$HOME/.almanac/almanac" almanac/target/release/almanac; do
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
