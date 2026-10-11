#!/usr/bin/env bash
# cooldown-transient-sweep.sh — INFRA-471 cooldown / auto-block audit.
#
# THE PROBLEM: worker.sh benches a gap two ways when a cycle fails:
#   (1) a time-boxed COOLDOWN file in .chump-locks/cooldown/<id>.json (self-GCs
#       on expiry), and
#   (2) after CHUMP_AUTO_BLOCK_THRESHOLD consecutive non-ship cycles, a DURABLE
#       state.db status=blocked with an "INFRA-3832 auto-block" note (never
#       expires — stays out of the pick pool until something re-opens it).
#
# Both paths fire on TRANSIENT infra failures too — a timeout (rc=124), a wedge
# (0-byte cycle log = backend/MCP hang), or a backend-outage window where a dead
# sub/floor made every gap "fail". Those gaps are not bad; the infra was. They
# should get another shot. Genuine repeat-failers (ordinary rc!=0, or a gap that
# was re-opened and auto-blocked AGAIN) must STAY benched.
#
# This sweep classifies both benches and re-enables ONLY the transient ones.
#
# Transient (re-enable) — infra failures with NO signal the gap itself is bad:
#   - cooldown file  kind=timeout | kind=wedge
#   - auto-blocked   last kind=timeout | last kind=wedge
# Kept benched (genuine) — conservative by design; we never un-block on a weak
# signal, because a wrongly un-blocked bad gap re-enters the pick pool and burns
# cycles:
#   - cooldown / auto-block kind=rc=* (ordinary non-zero exit — likely a real
#     bug in the gap as specified; NOT re-enabled by this sweep).
#   - any gap whose notes contain 2+ "INFRA-3832 auto-block" stamps (it was
#     already given a second chance and failed again).
#
# USAGE (from the node's chump checkout):
#   bash scripts/ops/cooldown-transient-sweep.sh            # report only (default)
#   bash scripts/ops/cooldown-transient-sweep.sh --apply    # actually re-enable
set -uo pipefail

MODE="report"
case "${1:-}" in
  --apply)            MODE="apply" ;;
  ""|--report|--dry)  MODE="report" ;;
  -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
  *) echo "unknown arg: $1 (use --apply | --report)" >&2; exit 2 ;;
esac

REPO_ROOT="${CHUMP_REPO:-${REPO_ROOT:-}}"
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi
COOLDOWN_DIR="${CHUMP_COOLDOWN_DIR:-$REPO_ROOT/.chump-locks/cooldown}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"

is_transient_kind() { # $1=kind  -> 0 if transient infra
  case "$1" in
    timeout|wedge) return 0 ;;
    *) return 1 ;;
  esac
}

json_field() { # $1=file $2=key  (flat string/number JSON, no nesting)
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | head -1
}

echo "=== cooldown-transient-sweep.sh (INFRA-471) ==="
echo "  repo       : $REPO_ROOT"
echo "  mode       : $MODE"
echo

# ── PART A: time-boxed cooldown files ───────────────────────────────────────
cd_total=0; cd_transient=0; cd_genuine=0
CD_REENABLE=""
if [ -d "$COOLDOWN_DIR" ]; then
  for f in "$COOLDOWN_DIR"/*.json; do
    [ -e "$f" ] || continue
    cd_total=$(( cd_total + 1 ))
    gid="$(json_field "$f" gap_id)"
    kind="$(json_field "$f" kind)"
    [ -z "$kind" ] && kind="$(json_field "$f" reason)"
    if is_transient_kind "$kind"; then
      cd_transient=$(( cd_transient + 1 ))
      CD_REENABLE="${CD_REENABLE}${f}	${gid}	${kind}
"
    else
      cd_genuine=$(( cd_genuine + 1 ))
    fi
  done
fi
echo "PART A — cooldown files ($COOLDOWN_DIR):"
echo "  total=$cd_total  transient(timeout/wedge)=$cd_transient  kept(rc/other)=$cd_genuine"

# ── PART B: durable auto-blocked gaps in state.db ───────────────────────────
ab_total=0; ab_transient=0; ab_repeat=0; ab_rc=0
AB_REENABLE=""
have_sqlite=0
command -v sqlite3 >/dev/null 2>&1 && [ -f "$STATE_DB" ] && have_sqlite=1
if [ "$have_sqlite" = 1 ]; then
  # id<TAB>notes for every currently-blocked auto-blocked gap.
  rows="$(sqlite3 -separator '	' "$STATE_DB" \
    "select id, replace(replace(notes,char(10),' '),char(13),' ') from gaps \
     where status='blocked' and notes like '%INFRA-3832 auto-block%';" 2>/dev/null)"
  while IFS='	' read -r gid notes; do
    [ -z "$gid" ] && continue
    ab_total=$(( ab_total + 1 ))
    # Count auto-block stamps: 2+ => already re-tried and re-blocked => genuine.
    stamps="$(printf '%s' "$notes" | grep -o 'INFRA-3832 auto-block' | wc -l | tr -d ' ')"
    # Latest "last kind=..." wins (take the last match).
    lastkind="$(printf '%s' "$notes" | grep -o 'last kind=[a-z0-9=]*' | tail -1 | sed 's/last kind=//')"
    if [ "${stamps:-0}" -ge 2 ]; then
      ab_repeat=$(( ab_repeat + 1 ))
      continue
    fi
    case "$lastkind" in
      timeout|wedge)
        ab_transient=$(( ab_transient + 1 ))
        AB_REENABLE="${AB_REENABLE}${gid}	${lastkind}
" ;;
      *) ab_rc=$(( ab_rc + 1 )) ;;
    esac
  done <<EOF
$rows
EOF
  echo
  echo "PART B — auto-blocked gaps (state.db):"
  echo "  total=$ab_total  transient(timeout/wedge)=$ab_transient  kept-rc/other=$ab_rc  kept-repeat-offender=$ab_repeat"
else
  echo
  echo "PART B — auto-blocked gaps: SKIPPED (need sqlite3 + $STATE_DB)"
fi

TOTAL_TRANSIENT=$(( cd_transient + ab_transient ))
echo
echo "SUMMARY: $TOTAL_TRANSIENT transiently-benched gap(s) re-enablable; genuine repeat-failers kept benched."

if [ "$MODE" = "report" ]; then
  echo
  echo "  REPORT ONLY — nothing changed. Re-run with --apply to re-enable the transient set."
  exit 0
fi

# ── apply: re-enable the transient set ──────────────────────────────────────
CHUMP_BIN="${CHUMP_BIN:-chump}"
# shellcheck source=scripts/lib/safe-reopen-gap.sh
. "$(dirname "$0")/../lib/safe-reopen-gap.sh"
# A) remove transient cooldown files (worker picks them again next cycle).
printf '%s' "$CD_REENABLE" | while IFS='	' read -r f gid kind; do
  [ -z "$f" ] && continue
  rm -f "$f" && echo "  cooldown cleared: ${gid:-?} (kind=$kind)"
done
# B) re-open transient auto-blocked gaps via the canonical mutation.
if [ "$have_sqlite" = 1 ] && command -v "$CHUMP_BIN" >/dev/null 2>&1; then
  _note="cooldown-transient-sweep (INFRA-471): re-opened — previous auto-block was a TRANSIENT infra failure (timeout/wedge/outage), not a spec defect. Re-blocks on repeat via INFRA-3832."
  printf '%s' "$AB_REENABLE" | while IFS='	' read -r gid kind; do
    [ -z "$gid" ] && continue
    CHUMP_REPO="$REPO_ROOT" gap_reopen_allowed "$gid" || { echo "  skipped (operator-blocked): $gid"; continue; }
    if CHUMP_REPO="$REPO_ROOT" "$CHUMP_BIN" gap set "$gid" --status open --add-note "$_note" >/dev/null 2>&1; then
      echo "  re-opened: $gid (last kind=$kind)"
    else
      echo "  WARN could not re-open $gid (chump gap set failed)"
    fi
  done
elif [ -n "$AB_REENABLE" ]; then
  echo "  NOTE: $ab_transient auto-blocked gap(s) are transient but 'chump' CLI unavailable — re-open manually:"
  printf '%s' "$AB_REENABLE" | while IFS='	' read -r gid kind; do
    [ -z "$gid" ] && continue
    echo "    chump gap set $gid --status open"
  done
fi
echo
echo "DONE."
exit 0
