#!/usr/bin/env bash
# faculty-collector.sh — the DATA SOURCE behind the OS self-portrait.
#
# Reads the REAL live endpoints for the 11 faculties of the ChumpOS "self"
# (the contract enum: build see resolve know_score verify heal remember aim
# communicate conscience learn) and writes ~/.chump/faculty-status.json in the
# SHARED JSON CONTRACT shape, plus a vision_acuity-style ambient heartbeat
# (kind=faculty_status) to .chump-locks/ambient.jsonl so a dead collector is
# itself observable and the portrait never silently freezes.
#
# It is an ORGAN, not a one-shot: chump-faculty-collector.service/.timer drive
# it every 15m, it is registered in scripts/ops/organ-manifest.txt, and it must
# survive a roll-call (systemctl is-active on the timer).
#
# ── POSITION RULE (the load-bearing law of the portrait) ────────────────────
# Every faculty's dot sits on an OURS(0) -> PEER(1) track. Its position is
# derived, never hardcoded:
#   1. STATE picks the BAND —   ours 0.02–0.24 | hand 0.25–0.49 |
#                               organ 0.50–0.74 | peer 0.75–0.97
#   2. the REAL SIGNAL places it WITHIN the band via a 0..1 fraction, and the
#      mapping is MONOTONE: a better signal => a higher fraction => a higher
#      dot. (See = avg(symbol%,summary%); Heal = active/manifest ratio;
#      Build = merges/24h saturating; Verify = 1 - false-fails saturating,
#      because FEWER false-fails is better.)
# bandpos() is the single implementation of step 1+2; no caller may bypass it
# with a literal position, or the portrait would lie about a faculty that got
# better or worse.
#
# Usage:
#   scripts/ops/faculty-collector.sh            # collect + write once
#   scripts/ops/faculty-collector.sh --dry-run  # print JSON to stdout, no writes
#
# Env overrides (all optional):
#   CHUMP_REPO_ROOT / REPO_ROOT     repo checkout root
#   CHUMP_FACULTY_OUT               output json path (default ~/.chump/faculty-status.json)
#   CHUMP_AMBIENT_LOG               ambient jsonl (default REPO_ROOT/.chump-locks/ambient.jsonl)
#   CHUMP_GH_REPO                   owner/repo for gh (default repairman29/chump)
#   CHUMP_ALMANAC_REPO / _BIN       almanac checkout / binary
#   CHUMP_PR_BOOK_CALIB             pr-book calibration log (default ~/.chump/pr-book-calibration.log)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"

# HOST-ASSUMPTION GOTCHA (2026-08-22): the fleet's service convention hardcodes
# `Environment=HOME=/root` even when `User=jeff` on an owned node (verified on
# every live /etc/systemd/system/chump-*.service on CJ). Under that env HOME=/root
# but the process runs as jeff, so EVERY tool that reads a per-user config from
# $HOME breaks silently and the portrait LIES:
#   - gh   -> reads /root/.config/gh -> "permission denied" -> 0 merges / 0 false-fails
#   - almanac -> reads /root/.almanac -> sees 0 repos -> reports a fake "100%" coverage
#   - our own OUT -> /root/.chump -> unwritable
# Resolve the RUN-USER's REAL home from the passwd db (root->/root on helsinki,
# jeff->/home/jeff on CJ) and RESET HOME to it. This one line fixes gh, almanac,
# chump and our outputs at once, and is host-agnostic (no hardcoded path).
REAL_HOME="$(getent passwd "$(id -un)" 2>/dev/null | cut -d: -f6)"
[[ -z "$REAL_HOME" || ! -d "$REAL_HOME" ]] && REAL_HOME="$HOME"
export HOME="$REAL_HOME"

# PATH-HARDENING: under systemd the PATH is minimal (/usr/bin:/bin) so gh
# resolves but chump/almanac (in ~/.cargo/bin) DO NOT — an unhardened run
# silently read 0 gaps and the portrait LIED. Prepend the run-user's cargo/local
# bins so every endpoint resolves regardless of the caller's PATH.
export PATH="$REAL_HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

# shellcheck source=scripts/ops/lib/merges-24h.sh
source "$SCRIPT_DIR/lib/merges-24h.sh"
# shellcheck source=scripts/ops/lib/operator-pages-24h.sh
source "$SCRIPT_DIR/lib/operator-pages-24h.sh"

OUT="${CHUMP_FACULTY_OUT:-$REAL_HOME/.chump/faculty-status.json}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$REPO_ROOT/.chump-locks/ambient.jsonl}"
GH_REPO="${CHUMP_GH_REPO:-repairman29/chump}"
ALMANAC_REPO="${CHUMP_ALMANAC_REPO:-$REAL_HOME/Projects/almanac}"
ALMANAC_BIN="${CHUMP_ALMANAC_BIN:-$ALMANAC_REPO/target/release/almanac}"
MANIFEST="$REPO_ROOT/scripts/ops/organ-manifest.txt"

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CUTOFF_24H="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"

command -v jq >/dev/null 2>&1 || { echo "[faculty-collector] FATAL: jq not found" >&2; exit 1; }

# ── position math ───────────────────────────────────────────────────────────
# bandpos STATE FRAC -> a float in [0.02,0.97]. FRAC is clamped to [0,1].
bandpos() {
  awk -v s="$1" -v f="$2" 'BEGIN{
    if (f=="" || f=="nan") f=0; f=f+0;
    if (f<0) f=0; if (f>1) f=1;
    if      (s=="ours")  { lo=0.02; hi=0.24 }
    else if (s=="hand")  { lo=0.25; hi=0.49 }
    else if (s=="organ") { lo=0.50; hi=0.74 }
    else if (s=="peer")  { lo=0.75; hi=0.97 }
    else                 { lo=0.02; hi=0.24 }
    printf "%.3f", lo + (hi-lo)*f
  }'
}
# frac helper: min(1, n/d)
sat() { awk -v n="$1" -v d="$2" 'BEGIN{ if(d<=0){print 0; exit} r=(n+0)/(d+0); if(r>1)r=1; if(r<0)r=0; printf "%.4f", r }'; }

FAC=()  # each element is one complete faculty JSON object (jq-escaped)
mkfac() { # key name question value unit position state organ note
  jq -n \
    --arg key "$1" --arg name "$2" --arg q "$3" --arg v "$4" --arg unit "$5" \
    --arg pos "$6" --arg state "$7" --arg organ "$8" --arg note "$9" \
    '{key:$key, name:$name, question:$q,
      value:($v|tonumber? // $v), unit:$unit,
      position:($pos|tonumber), state:$state, organ:$organ, note:$note}'
}

# ── 1. BUILD — intent -> shipped work (merges/24h) ──────────────────────────
merges="$(merges_24h "$REPO_ROOT" "$GH_REPO")"
[[ "$merges" =~ ^[0-9]+$ ]] || merges=0
# saturate at 60 merges/24h — a full owned-node factory day
b_frac="$(sat "$merges" 60)"
FAC+=("$(mkfac build "Build" "intent -> shipped work" \
        "$merges" "merges/24h" "$(bandpos organ "$b_frac")" organ \
        "run-fleet · workers · integrator" \
        "$merges PRs merged in the last 24h; saturates toward peer at ~60/day.")")

# ── 2. SEE — code the OS can actually read (almanac coverage) ───────────────
# Parse the SPECIFIC lines. embeddings line = symbol%, summaries line =
# summary%. GOTCHA (2026-08-22): a naive `grep = N%` grabs the 11% inside the
# summaries parenthetical or crosses the two X/Y pairs. Anchor on ^embeddings:
# and ^summaries: and take the field after "= ".
sym=""; sum=""
if [[ -x "$ALMANAC_BIN" ]]; then
  COV="$( ( cd "$ALMANAC_REPO" 2>/dev/null && "$ALMANAC_BIN" coverage ) 2>/dev/null )"
  sym="$(printf '%s\n' "$COV" | awk -F'= ' '/^embeddings:/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  sum="$(printf '%s\n' "$COV" | awk -F'= ' '/^summaries:/ {gsub(/[^0-9]/,"",$2); print $2; exit}')"
fi
[[ "$sym" =~ ^[0-9]+$ ]] || sym=0
[[ "$sum" =~ ^[0-9]+$ ]] || sum=0
see_avg="$(awk -v a="$sym" -v b="$sum" 'BEGIN{printf "%d", (a+b)/2}')"
s_frac="$(awk -v x="$see_avg" 'BEGIN{printf "%.4f", x/100}')"
FAC+=("$(mkfac see "See" "code the OS can read" \
        "$see_avg" "% coverage (sym/sum avg)" "$(bandpos organ "$s_frac")" organ \
        "almanac · liveness-keeper" \
        "symbols ${sym}%, summaries ${sum}%; summary coverage is the drag.")")

# ── 3. RESOLVE — merge conflicts drained without a human ────────────────────
# ORGAN only if BOTH: consumer timer running AND the RESILIENT-301 rebase
# upgrade (#4137) is merged to main. Else HAND (it runs but can't rebase).
res_timer="$(systemctl is-active chump-conflict-resolution-consumer.timer 2>/dev/null || echo inactive)"
res_pr="$(gh pr view 4137 --repo "$GH_REPO" --json state --jq '.state' 2>/dev/null || echo UNKNOWN)"
res_running=0; [[ "$res_timer" == "active" ]] && res_running=1
res_capable=0; [[ "$res_pr" == "MERGED" ]] && res_capable=1
res_cap="$(awk -v a="$res_running" -v b="$res_capable" 'BEGIN{printf "%.2f", (a+b)/2}')"
if   [[ "$res_running" == 1 && "$res_capable" == 1 ]]; then res_state=organ; res_organ="conflict-resolution-consumer + rebase"
elif [[ "$res_running" == 1 ]];                        then res_state=hand;  res_organ="conflict-resolution-consumer (no rebase; RESILIENT-301 #4137)"
else                                                        res_state=ours;  res_organ="RESILIENT-301 #4137"; fi
FAC+=("$(mkfac resolve "Resolve" "merge conflicts drained without a human" \
        "$res_cap" "capability 0..1 (running+rebase)/2" "$(bandpos "$res_state" "$res_cap")" "$res_state" \
        "$res_organ" \
        "consumer=${res_timer}, #4137=${res_pr}; organ only when both true.")")

# ── 4. KNOW_SCORE — does the OS know how good its own calls are (Brier) ──────
CAL_LOG="${CHUMP_PR_BOOK_CALIB:-$REAL_HOME/.chump/pr-book-calibration.log}"
brier=""; ks_val=""; ks_frac=0
if [[ -f "$CAL_LOG" ]]; then
  brier="$(tail -n1 "$CAL_LOG" 2>/dev/null | \
    jq -r 'select(.kind=="pr_book_calibration") | .brier // empty' 2>/dev/null)"
fi
odds="$(grep -c 'pr_book_odds' "$AMBIENT_LOG" 2>/dev/null || echo 0)"
[[ "$odds" =~ ^[0-9]+$ ]] || odds=0
if [[ -n "$brier" ]]; then
  ks_state=organ; ks_val="$brier"
  # lower Brier is better -> frac = 1 - brier (Brier in [0,1])
  ks_frac="$(awk -v b="$brier" 'BEGIN{v=1-b; if(v<0)v=0; if(v>1)v=1; printf "%.4f", v}')"
  ks_organ="pr-book calibration log"
  ks_note="Brier=${brier} from last calibration line; ${odds} odds logged."
elif [[ "$odds" -gt 0 ]]; then
  ks_state=hand; ks_val="$odds"
  ks_frac="$(sat "$odds" 20)"       # predicting but never scoring itself
  ks_organ="pr-book (odds emitted, unscored)"
  ks_note="no calibration log yet; ${odds} pr_book_odds logged but Brier unmeasured."
else
  ks_state=ours; ks_val="0"; ks_frac=0.2
  ks_organ="pr-book (dark)"
  ks_note="no odds, no calibration log — the OS does not score its own calls."
fi
ks_unit="Brier (lower=better)"; [[ "$ks_state" != organ ]] && ks_unit="pr_book_odds logged"
FAC+=("$(mkfac know_score "Know score" "does it know how good its own calls are" \
        "$ks_val" "$ks_unit" "$(bandpos "$ks_state" "$ks_frac")" "$ks_state" \
        "$ks_organ" "$ks_note")")

# ── 5. VERIFY — the 'verified' gate telling the truth (false-fails) ─────────
# Count open PRs whose 'verified' check == FAILURE — these are false-fails that
# erode trust in the gate. FEWER is better, so the fraction inverts.
ff="$(gh pr list --repo "$GH_REPO" --state open --limit 200 --json number,statusCheckRollup \
      --jq '[.[]|select(any(.statusCheckRollup[]?; .name=="verified" and .conclusion=="FAILURE"))]|length' 2>/dev/null)"
[[ "$ff" =~ ^[0-9]+$ ]] || ff=0
v_frac="$(awk -v f="$(sat "$ff" 20)" 'BEGIN{printf "%.4f", 1-f}')"   # invert: fewer false-fails => higher
FAC+=("$(mkfac verify "Verify" "the gate tells the truth" \
        "$ff" "false-fails (open PRs, verified=FAILURE)" "$(bandpos organ "$v_frac")" organ \
        "CI · verified check" \
        "${ff} open PR(s) with a red 'verified' check; fewer false-fails => higher.")")

# ── 6. HEAL — organs kept alive vs the manifest that declares them ──────────
heal_active=0; heal_total=0
if [[ -f "$MANIFEST" ]]; then
  while read -r _line; do
    u="$(awk '{print $2}' <<<"$_line")"
    [[ -z "$u" ]] && continue
    heal_total=$((heal_total+1))
    [[ "$(systemctl is-active "$u" 2>/dev/null)" == active ]] && heal_active=$((heal_active+1))
  done < <(grep -E '^enabled' "$MANIFEST")
fi
medic="$(systemctl is-active chump-process-organ-heal.timer 2>/dev/null || echo inactive)"
heal_frac="$(sat "$heal_active" "$heal_total")"
# a dead medic caps the heal signal — self-healing that can't run isn't organ-grade
heal_state=organ; [[ "$medic" != active ]] && heal_state=hand
FAC+=("$(mkfac heal "Heal" "organs stay alive without a human" \
        "$heal_active" "active organs (of ${heal_total})" "$(bandpos "$heal_state" "$heal_frac")" "$heal_state" \
        "process-organ-heal · organ-watchdog" \
        "${heal_active}/${heal_total} manifest organs active; medic(process-organ-heal)=${medic}.")")

# ── 7. REMEMBER — the gap store reachable + a drift proxy ────────────────────
# GOTCHA (2026-08-22): `chump gap list` reads the REPO-LOCAL .chump/state.db, so
# it is cwd-sensitive. Under systemd the cwd is / (no WorkingDirectory set) and
# it returned 0 gaps — a false "degraded". Query from inside REPO_ROOT, which
# holds the canonical store.
gaps="$( ( cd "$REPO_ROOT" 2>/dev/null && chump gap list --status open --json 2>/dev/null ) | grep -c '"id"' 2>/dev/null || echo 0)"
[[ "$gaps" =~ ^[0-9]+$ ]] || gaps=0
if [[ "$gaps" -gt 0 ]]; then
  rem_state=organ; rem_frac=0.5   # reachable, but drift is only a partial (uncomputed) proxy
  rem_note="gap store reachable, ${gaps} open gaps; drift=partial (count-only proxy)."
else
  rem_state=hand; rem_frac=0.3
  rem_note="gap store returned 0 gaps — unreachable or empty; treat as degraded."
fi
FAC+=("$(mkfac remember "Remember" "durable memory the OS can query" \
        "$gaps" "open gaps" "$(bandpos "$rem_state" "$rem_frac")" "$rem_state" \
        "gap-store (chump gap)" "$rem_note")")

# ── 8. AIM — who sets the targets (still mostly human) ───────────────────────
FAC+=("$(mkfac aim "Aim" "who chooses what to build" \
        "human" "target-setter" "$(bandpos ours 0.35)" ours \
        "Jeff + board (human)" \
        "targets are still human-set; the OS proposes but does not choose the mission.")")

# ── 9. COMMUNICATE — outward voice / 24h (operator pages) ────────────────────
# INFRA-3848: operator_pages_24h() in lib/operator-pages-24h.sh is the SINGLE
# canonical computation, shared with vital-signs.sh (sign human_intervention)
# — both readers now count the same kind-set: {operator_page, operator_paged,
# pager_notified}.
msgs="$(operator_pages_24h "$AMBIENT_LOG" "$CUTOFF_24H")"
if [[ "$msgs" -gt 0 ]]; then
  com_state=hand; com_frac="$(sat "$msgs" 20)"
  com_note="${msgs} operator page(s) in 24h — one-way curated voice; two-way DM still gated."
else
  com_state=ours; com_frac=0.1
  com_note="dark: 0 operator pages in 24h; the OS is not speaking outward."
fi
FAC+=("$(mkfac communicate "Communicate" "the OS speaks to people" \
        "$msgs" "operator pages/24h" "$(bandpos "$com_state" "$com_frac")" "$com_state" \
        "notify-operator · discord-gateway" "$com_note")")

# ── 10. CONSCIENCE — logged pushbacks against the OS's own plans ─────────────
pb="$(grep -ciE 'pushback|"kind":"conscience' "$AMBIENT_LOG" 2>/dev/null || echo 0)"
[[ "$pb" =~ ^[0-9]+$ ]] || pb=0
if [[ "$pb" -gt 0 ]]; then
  con_state=hand; con_frac="$(sat "$pb" 10)"; con_note="${pb} logged OS-pushback(s)."
else
  con_state=ours; con_frac=0.05; con_note="missing: 0 logged pushbacks — no standing/conscience organ yet."
fi
FAC+=("$(mkfac conscience "Conscience" "the OS pushes back when it should" \
        "$pb" "logged pushbacks" "$(bandpos "$con_state" "$con_frac")" "$con_state" \
        "(none yet)" "$con_note")")

# ── 11. LEARN — self-forged skills/fixes (skill-foundry outputs) ─────────────
learn="$(grep -ciE 'skill_forged|skill_foundry|"kind":"self_fix' "$AMBIENT_LOG" 2>/dev/null || echo 0)"
[[ "$learn" =~ ^[0-9]+$ ]] || learn=0
if [[ "$learn" -gt 0 ]]; then
  ln_state=hand; ln_frac="$(sat "$learn" 10)"; ln_note="${learn} self-forged skill/fix event(s) logged."
else
  ln_state=ours; ln_frac=0.08; ln_note="dark: 0 skill-foundry outputs — the OS is not yet forging its own tools."
fi
FAC+=("$(mkfac learn "Learn" "the OS forges its own new tools" \
        "$learn" "self-forged skills/fixes" "$(bandpos "$ln_state" "$ln_frac")" "$ln_state" \
        "skill-foundry" "$ln_note")")

# ── assemble ────────────────────────────────────────────────────────────────
FRONTIER='{"crossing":["see","resolve","know_score","verify"],"ours":["aim","communicate","conscience","learn"]}'
faculties_json="$(printf '%s\n' "${FAC[@]}" | jq -s '.')"
# INFRA-7142 (INFRA-3841 slice): surface the BUILD faculty's merge count
# under the canonical `merges_24h` column name, shared with vital-signs.sh's
# top-level `merges_24h` and dashboard.rs's `DashboardSummary.merges_24h`.
DOC="$(jq -n \
      --arg ts "$NOW" \
      --argjson f "$faculties_json" \
      --argjson fr "$FRONTIER" \
      --argjson merges24h "$merges" \
      '{generated_at:$ts, faculties:$f, frontier:$fr, merges_24h:$merges24h}')"

if [[ "$DRY_RUN" == 1 ]]; then
  printf '%s\n' "$DOC"
  exit 0
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
tmp="$(mktemp "${TMPDIR:-$REAL_HOME/.chump}/faculty-status.XXXXXX.json" 2>/dev/null || echo "$OUT.tmp")"
printf '%s\n' "$DOC" > "$tmp" && mv -f "$tmp" "$OUT"

# vision_acuity-style ambient heartbeat — a dead collector is observable, and
# the portrait's freshness is provable from the ambient stream alone.
mkdir -p "$(dirname "$AMBIENT_LOG")" 2>/dev/null || true
n_fac="$(printf '%s' "$DOC" | jq '.faculties|length')"
avg_pos="$(printf '%s' "$DOC" | jq -r '[.faculties[].position]|add/length|.*1000|round/1000')"
printf '{"ts":"%s","kind":"faculty_status","faculties":%s,"avg_position":%s,"build_merges_24h":%s,"merges_24h":%s,"see_avg_pct":%s,"out":"%s"}\n' \
  "$NOW" "$n_fac" "$avg_pos" "$merges" "$merges" "$see_avg" "$OUT" >> "$AMBIENT_LOG" 2>/dev/null || true

echo "[faculty-collector] wrote $OUT (${n_fac} faculties, avg_position=${avg_pos}) @ $NOW"
