#!/usr/bin/env bash
# scripts/coord/lib/calibration.sh — RESILIENT-974 (RESILIENT-422 slice)
#
# Generic Brier-score calibration component, extracted from the PR-merge-bet
# settle logic in scripts/coord/pr-book.sh (INFRA-1688 lineage). PR-merge bets
# were the first "this-will-break-to-P0" call this fleet scored — this lib
# lets ANY other prediction domain (incident-recall bets, gap-ship-success
# forecasts, NBA-engine risk calls, ...) reuse the same join+score+log
# machinery instead of re-deriving jq by hand.
#
# Source it:
#   source "$(dirname "$0")/lib/calibration.sh"
#
# API:
#   calibration_settle <ledger> <outcomes_map_json> <calib_out> <id_key> \
#                       <price_key> <prediction_kind> <summary_kind>
#     ledger            path to an append-only JSONL file; each line is a
#                       prediction record with at least {<id_key>, <price_key>}
#                       (later lines for the same id supersede earlier ones —
#                       "latest prediction wins", same as pr-book.sh)
#     outcomes_map_json JSON object mapping id (as string) -> 0 or 1
#                       (omit an id to leave it unresolved / excluded)
#     calib_out         path to (re)write the calibration log to — REWRITTEN
#                       (not appended) so repeat settles don't double-count
#     id_key            JSON field name identifying each prediction (e.g. "pr")
#     price_key         JSON field name holding the predicted probability
#                       (e.g. "price")
#     prediction_kind   "kind" value stamped on each per-prediction row
#     summary_kind      "kind" value stamped on the trailing summary row
#
#     stdout: a single JSON object —
#       {rows, predictions, resolved, matched:N, unmatched:N, brier}
#     (rows/predictions/resolved/brier mirror the shape pr-book.sh already
#     printed; matched/unmatched count outcome==1 / outcome==0 generically —
#     callers that want domain labels like "merged"/"closed" can derive them
#     from the outcome value themselves.)
#
#     Returns 0 always (an empty/no-op ledger yields brier:null, not a
#     failure) — callers decide what "nothing to settle" means for them.
#
#   brier_score <predicted_json_array> <outcomes_json_array>
#     The scorer underneath calibration_settle, exposed standalone so ANY
#     prediction type (not just a JSONL ledger keyed by id/price) can get a
#     Brier score — hand it two same-length JSON arrays and get a number
#     back. Lower is better; 0.0 is a perfect forecaster, 0.25 is what a
#     coin-flipping (p=0.5 always) forecaster scores against a 50/50 outcome
#     mix, 1.0 is maximally wrong (confident and always incorrect).
#     predicted_json_array  JSON array of probabilities in [0.0, 1.0]
#                            (e.g. '[0.9, 0.2, 0.55]')
#     outcomes_json_array   JSON array of binary outcomes, same length,
#                            0 or 1 (e.g. '[1, 0, 1]')
#     stdout: the mean squared error between predicted and outcome, rounded
#     to 4 decimal places, or the literal string "null" if either array is
#     empty or the lengths don't match (no partial/misaligned scoring).
brier_score() {
  local predicted_json="$1" outcomes_json="$2"
  jq -cn --argjson p "$predicted_json" --argjson o "$outcomes_json" '
    if ($p|length) == 0 or ($p|length) != ($o|length) then null
    else
      ([range(0; $p|length) | ($p[.] - $o[.]) * ($p[.] - $o[.])]) as $sq
      | ((($sq|add)/($sq|length))*10000|round)/10000
    end'
}

calibration_settle() {
  local ledger="$1" outcomes_json="$2" calib_out="$3" id_key="$4" \
        price_key="$5" pred_kind="$6" summary_kind="$7"
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ ! -s "$ledger" ]]; then
    jq -cn --arg ts "$ts" --arg kind "$summary_kind" \
      '{rows:[], predictions:0, resolved:0, matched:0, unmatched:0, brier:null}'
    return 0
  fi

  # INFRA-8105: support both current (.p_merge) and pre-INFRA-3850 (.price)
  # probability keys via (.[$pk] // .p_merge // .price) so legacy ledger rows
  # never resolve to predicted=null and crash brier_score.
  local joined
  if ! joined="$(jq -cn --slurpfile L "$ledger" --argjson O "$outcomes_json" --arg ts "$ts" \
    --arg idk "$id_key" --arg pk "$price_key" --arg pkind "$pred_kind" '
    ($L | reduce .[] as $r ({}; .[($r[$idk]|tostring)] = $r)) as $latest
    | [ $latest[] | (.[$idk]|tostring) as $kk
        | select($O[$kk] != null)
        | (.[$pk] // .p_merge // .price) as $pred
        | select($pred != null and ($pred | type) == "number")
        | {ts:$ts, kind:$pkind}
          + {($idk): .[$idk]}
          + {predicted:$pred, outcome:$O[$kk]} ]
      as $rows
    | { rows: $rows,
        predictions: ($latest|length),
        resolved: ($rows|length),
        matched:   ([ $rows[] | select(.outcome==1) ] | length),
        unmatched: ([ $rows[] | select(.outcome==0) ] | length) }')" || [[ -z "$joined" ]]; then
    return 1
  fi

  local predicted_arr outcomes_arr brier res
  if ! predicted_arr="$(printf '%s\n' "$joined" | jq -c '[.rows[].predicted]')" || [[ -z "$predicted_arr" ]]; then
    return 1
  fi
  if ! outcomes_arr="$(printf '%s\n' "$joined" | jq -c '[.rows[].outcome]')" || [[ -z "$outcomes_arr" ]]; then
    return 1
  fi
  if ! brier="$(brier_score "$predicted_arr" "$outcomes_arr")" || [[ -z "$brier" ]]; then
    return 1
  fi
  if ! res="$(printf '%s\n' "$joined" | jq -c --argjson brier "$brier" '. + {brier: $brier}')" || [[ -z "$res" ]]; then
    return 1
  fi

  local tmp_cal
  tmp_cal="$(mktemp "${TMPDIR:-/tmp}/calib.XXXXXX" 2>/dev/null)" || tmp_cal="$calib_out.tmp.$$"
  if ! { printf '%s\n' "$res" | jq -c '.rows[]' > "$tmp_cal" && \
         printf '%s\n' "$res" | jq -c --arg ts "$ts" --arg kind "$summary_kind" \
           '{ts:$ts, kind:$kind, brier:.brier, n:.resolved, matched:.matched, unmatched:.unmatched}' >> "$tmp_cal"; }; then
    rm -f "$tmp_cal"
    return 1
  fi
  # INFRA-8105: never overwrite an existing calibration log with a 0-byte or
  # summary-less temp file when jq fails or produces invalid output.
  if [[ ! -s "$tmp_cal" ]] || ! tail -n1 "$tmp_cal" | jq -e --arg k "$summary_kind" 'select(.kind == $k)' >/dev/null 2>&1; then
    rm -f "$tmp_cal"
    return 1
  fi
  mv -f "$tmp_cal" "$calib_out"

  printf '%s\n' "$res"
}
