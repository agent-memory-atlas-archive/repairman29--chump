#!/usr/bin/env bash
# scripts/dispatch/gap-drain.sh — EFFECTIVE-464 — the DRAIN LOOP.
#
# GATE 2 toward the ribbon: keep the cheap DeepSeek floor fed with LANDABLE
# work. The floor (EFFECTIVE-445, deepseek-v4-flash/pro) lands SURGICAL
# single-change gaps first-try but SPINS on vague gaps (rejected at claim) and
# FAILS verify on broad/multi-file gaps. So this organ converts the OPEN backlog
# into concrete surgical gaps on a timer, two levers:
#
#   thin  -> ENRICH   (chump-gap-enricher <ID> --apply, driven per-gap): Almanac
#            file:line + deepseek-v4-pro rewrites a thin gap IN PLACE into a
#            concrete, file-pointed spec. Never manufactures new gaps (anti-bloat).
#   broad -> DECOMPOSE (chump gap decompose --apply): an effort=m/l gap whose AC
#            is multi-part/multi-file is not flash-landable as-is; slice it into
#            xs/s surgical sub-gaps (one file, one edit, one testable AC each) —
#            the shape proven to land first-try — and demote the parent.
#
# Both LLM calls route to deepseek-v4-pro via the OPENAI_API_BASE override below
# (ProviderCascade slot 0), NOT the contended local ollama that owns slot 0 on
# CJ by default (which hangs the call for minutes). deepseek-v4-pro ~ $0.0035/gap.
#
# Idempotent, budget-bounded, host-agnostic. Paired with chump-gap-drain.timer,
# rostered in install-helsinki-atc.sh + organ-manifest.txt so organ-reconcile
# keeps it alive (RESILIENT-366 Roll-Call).
set -uo pipefail

REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd -P)}"
cd "$REPO_ROOT" || exit 1

# ── provider wiring: pin deepseek-v4-pro as cascade slot 0 ───────────────────
# providers.env carries OPENROUTER_API_KEY + CHUMP_MODEL_ESCALATION_LADDER; it is
# sourced by the systemd unit, but source here too for hand-runs.
set -a
[ -f "$HOME/.chump/providers.env" ] && source "$HOME/.chump/providers.env" 2>/dev/null
[ -f "$HOME/.chump/cj.env" ] && source "$HOME/.chump/cj.env" 2>/dev/null
set +a
# INFRA: pick the decompose/enrich provider. Prefer OpenRouter deepseek-v4-pro,
# but fall to a capable FREE tier (Google gemini-3.6-flash, then Groq
# gpt-oss-120b) when OpenRouter credits are exhausted (402 on full requests) —
# the floor is unaffected but this path would otherwise go dead. The SAME
# selector backs the worker.sh decompose reflex, so both stay consistent.
source "$(dirname "$0")/lib/decompose-provider.sh"
pick_decompose_provider
# Almanac binary (the file:line source the enricher grounds on). The enricher
# defaults to `almanac` on PATH; on the owned nodes it is symlinked into
# ~/.cargo/bin from the separate ~/Projects/almanac checkout. Only pin an
# explicit CHUMP_ALMANAC_BIN if `almanac` is NOT resolvable on PATH — a WRONG
# path silently yields hits=0 and un-groundable (empty) enrichment.
if [ -z "${CHUMP_ALMANAC_BIN:-}" ] && ! command -v almanac >/dev/null 2>&1; then
  for cand in "$HOME/Projects/almanac/target/release/almanac" "$REPO_ROOT/almanac/target/release/almanac"; do
    [ -x "$cand" ] && { export CHUMP_ALMANAC_BIN="$cand"; break; }
  done
fi

CHUMP="${CHUMP_BIN:-chump}"
ENRICHER="${CHUMP_ENRICHER_BIN:-chump-gap-enricher}"

# ── budget knobs ─────────────────────────────────────────────────────────────
ENRICH_LIMIT="${CHUMP_DRAIN_ENRICH_LIMIT:-6}"      # thin gaps enriched per tick
# Decompose defaults to 1/tick: it is the slow lever (~2-3 min/gap incl. the
# 8192-token retry) and EACH decomposition already yields ~9 surgical sub-gaps,
# so 1 keeps the whole tick comfortably under the unit's TimeoutStartSec while
# still flooding the floor with landable work. Bump via env on a fast/idle node.
DECOMPOSE_LIMIT="${CHUMP_DRAIN_DECOMPOSE_LIMIT:-1}" # broad (m/l) gaps decomposed per tick
LEDGER="${CHUMP_DRAIN_LEDGER:-$HOME/.chump/gap-drain.ledger}"
STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log() { printf '[gap-drain %s] %s\n' "$STAMP" "$*"; }

command -v "$CHUMP" >/dev/null 2>&1 || { log "FATAL: chump not on PATH"; exit 1; }

open_json="$($CHUMP gap list --status open --json 2>/dev/null)"
open_before="$(printf '%s' "$open_json" | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(len(d if isinstance(d,list) else d.get("gaps",[])))
except Exception:
    print(-1)')"
log "open_before=$open_before enrich_limit=$ENRICH_LIMIT decompose_limit=$DECOMPOSE_LIMIT"

# ── attempt-cooldown ledger (shared by decompose + enrich) ───────────────────
# A gap we already TRIED this window is skipped so a persistently-failing broad
# gap (decompose timeout) or un-groundable thin gap (almanac finds nothing)
# can't monopolise a slot every single tick and burn the budget on dead work.
ATTEMPTED="${CHUMP_DRAIN_ATTEMPTED:-$HOME/.chump/gap-drain-attempted.tsv}"
COOLDOWN_S="${CHUMP_DRAIN_ATTEMPT_COOLDOWN_S:-86400}"  # 24h
touch "$ATTEMPTED" 2>/dev/null || true
now_epoch="$(date -u +%s)"

# ── STEP A: broad -> decompose surgical ─────────────────────────────────────
# Pick open effort=m/l gaps — the ONLY shape `chump gap decompose` accepts (it
# refuses xs/s with "nothing to decompose"). An AC-heavy but effort=s gap is
# mis-sized, not decompose-able, so we DON'T feed it here (that just burns a
# no-op call); the enrich step handles the small ones. Priority P0..P2 first,
# skip gaps attempted within the cooldown window.
mapfile -t BROAD_IDS < <(printf '%s' "$open_json" | python3 -c '
import sys,json,time
N=int(sys.argv[1]); cooldown=int(sys.argv[2]); ledger=sys.argv[3]
try:
    d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("gaps",[])
except Exception:
    rows=[]
now=int(time.time()); recent=set()
try:
    for ln in open(ledger):
        p=ln.rstrip("\n").split("\t")
        if len(p)>=2 and now-int(p[1])<cooldown: recent.add(p[0])
except Exception: pass
def broad(g):
    return str(g.get("effort","")).strip().lower() in ("m","l","xl")   # case-insensitive; decompose accepts all but xs/s
prio={"P0":0,"P1":1,"P2":2,"P3":3}
cand=[g for g in rows if broad(g) and g.get("id") not in recent]
cand.sort(key=lambda g:(prio.get(g.get("priority","P3"),9), g.get("id","")))
for g in cand[:N]:
    print(g["id"])
' "$DECOMPOSE_LIMIT" "$COOLDOWN_S" "$ATTEMPTED")

decomposed=0
for gid in "${BROAD_IDS[@]:-}"; do
  [ -z "$gid" ] && continue
  printf '%s\t%s\n' "$gid" "$now_epoch" >>"$ATTEMPTED" 2>/dev/null || true
  log "decompose $gid ..."
  # deepseek-v4-pro reasoning blows past the 4096 budget and auto-retries at
  # 8192, so a full decompose can run ~2-3 min; give it real headroom.
  dlog="/tmp/drain-decompose-$gid.log"
  if timeout "${CHUMP_DRAIN_DECOMPOSE_TIMEOUT:-300}" "$CHUMP" gap decompose "$gid" --apply >"$dlog" 2>&1; then
    # decompose exits 0 even on the "nothing to decompose"/"not open" no-op —
    # only count a decomposition that actually FILED sub-gaps.
    if grep -qiE "nothing to decompose|is not open|no.*slices|no candidates" "$dlog"; then
      log "decompose $gid no-op ($(grep -oiE "nothing to decompose|is not open" "$dlog" | head -1))"
    else
      decomposed=$((decomposed+1))
      log "decompose $gid OK ($(grep -coiE "filed|EFFECTIVE-|INFRA-|CREDIBLE-|RESILIENT-|COG-|META-" "$dlog") slice-lines)"
    fi
  else
    log "decompose $gid FAILED (exit $?) — see $dlog"
    # Provider outage is not the gap's fault: refund the cooldown slot.
    if grep -q "LLM call failed" "$dlog" 2>/dev/null && [ -f "$ATTEMPTED" ]; then
      grep -vxF "$(printf '%s\t%s' "$gid" "$now_epoch")" "$ATTEMPTED" >"$ATTEMPTED.tmp" 2>/dev/null
      mv "$ATTEMPTED.tmp" "$ATTEMPTED" 2>/dev/null || true
      log "decompose $gid LLM unreachable — cooldown refunded"
    fi
  fi
done

# ── STEP B: thin -> enrich concrete ─────────────────────────────────────────
# We DRIVE the enricher per-gap (not its bulk --scan) so we can skip gaps we
# already tried recently. `--scan` re-picks the THINNEST gaps every tick;
# successful enrichments self-remove (they gain a file pointer + concrete AC),
# but an UN-GROUNDABLE gap (almanac finds nothing → model returns no usable
# spec → applied:false) stays thinnest-ranked forever and would burn an LLM
# call every single tick. The attempted-ledger (shared with Step A, set up
# above) gives each gap a cooldown so the budget rotates onto fresh candidates
# instead of re-spinning on dead ones.
enriched=0
if command -v "$ENRICHER" >/dev/null 2>&1; then
  # Candidate thin gaps not attempted within the cooldown, thinnest-first.
  mapfile -t THIN_IDS < <(printf '%s' "$open_json" | python3 -c '
import sys,json,os,time
N=int(sys.argv[1]); cooldown=int(sys.argv[2]); ledger=sys.argv[3]
try:
    d=json.load(sys.stdin); rows=d if isinstance(d,list) else d.get("gaps",[])
except Exception:
    rows=[]
now=int(time.time()); recent=set()
try:
    for ln in open(ledger):
        p=ln.rstrip("\n").split("\t")
        if len(p)>=2 and now-int(p[1])<cooldown: recent.add(p[0])
except Exception: pass
def vague(ac):
    s=(ac or "").strip().lower()
    return (s=="" or s in ("[]","null") or "todo" in s or "tbd" in s)
def has_ptr(t):
    import re
    return bool(re.search(r"[\w/.-]+\.(rs|py|sh|ts|js|md|toml|yaml|yml|txt|rb|go)\b", t or ""))
def thin_score(g):
    s=0; ac=g.get("acceptance_criteria") or ""; desc=(g.get("description") or "").strip()
    if vague(ac): s+=1
    if len(desc)<120: s+=1
    blob=desc+"\n"+ac+"\n"+(g.get("title") or "")
    if not has_ptr(blob): s+=1
    return s
cand=[]
for g in rows:
    if g.get("id") in recent: continue
    # m/l gaps are BROAD — enriching them only makes them concrete-but-still-
    # multi-file (flash still fails verify). They belong to the decompose step.
    if g.get("effort","") in ("m","l"): continue
    sc=thin_score(g)
    if sc<=0: continue
    # need SOME anchor text to ground almanac on: title or description with real words.
    anchor=((g.get("title") or "")+" "+(g.get("description") or "")).strip()
    if len(anchor)<15: continue
    cand.append((sc,g.get("id")))
cand.sort(key=lambda x:(-x[0], x[1]))
for _,gid in cand[:N]:
    print(gid)
' "$ENRICH_LIMIT" "$COOLDOWN_S" "$ATTEMPTED")

  for gid in "${THIN_IDS[@]:-}"; do
    [ -z "$gid" ] && continue
    printf '%s\t%s\n' "$gid" "$now_epoch" >>"$ATTEMPTED" 2>/dev/null || true
    log "enrich $gid ..."
    if timeout "${CHUMP_DRAIN_ENRICH_TIMEOUT:-180}" "$ENRICHER" "$gid" --apply --json >/tmp/drain-enrich-$gid.json 2>/tmp/drain-enrich-$gid.log; then
      ap="$(python3 -c 'import json,sys
try:
    d=json.load(open("/tmp/drain-enrich-'"$gid"'.json"))
    e=d.get("enriched",[]); print(1 if (e and e[0].get("applied")) else 0)
except Exception: print(0)')"
      if [ "$ap" = "1" ]; then enriched=$((enriched+1)); log "enrich $gid APPLIED"; else log "enrich $gid no-op (un-groundable)"; fi
    else
      log "enrich $gid FAILED (exit $?) — see /tmp/drain-enrich-$gid.log"
    fi
  done
  # Trim the ledger to the last 5000 lines so it can't grow unbounded.
  tail -n 5000 "$ATTEMPTED" >"$ATTEMPTED.tmp" 2>/dev/null && mv "$ATTEMPTED.tmp" "$ATTEMPTED" 2>/dev/null || true
else
  log "WARN: $ENRICHER not on PATH — skipping enrich step"
fi

open_after="$($CHUMP gap list --status open --json 2>/dev/null | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin); print(len(d if isinstance(d,list) else d.get("gaps",[])))
except Exception:
    print(-1)')"

log "DONE decomposed=$decomposed enriched=$enriched open_before=$open_before open_after=$open_after"
printf '%s decomposed=%s enriched=%s open_before=%s open_after=%s\n' \
  "$STAMP" "$decomposed" "$enriched" "$open_before" "$open_after" >>"$LEDGER" 2>/dev/null || true

# Ambient event so the board/duty-officer can see the drain is beating.
EMIT="$REPO_ROOT/scripts/dev/ambient-emit.sh"
if [ -x "$EMIT" ]; then
  "$EMIT" gap_drain_tick \
    "decomposed=$decomposed" "enriched=$enriched" \
    "open_before=$open_before" "open_after=$open_after" >/dev/null 2>&1 || true
fi
exit 0
