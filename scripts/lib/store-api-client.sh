#!/usr/bin/env bash
# scripts/lib/store-api-client.sh — RESILIENT-1700 (RESILIENT-1691 slice)
#
# Reusable store-over-API client library for Phase-2 organs.
# Exposes:
#   chump_store_query_gaps [--status S] [--priority P] [--domain D] [--limit N] [--order id|priority]
#   chump_store_get_gap <gap_id>
#
# When CHUMP_STORE_API_URL is set, queries ${CHUMP_STORE_API_URL}/api/store/gaps
# via `curl -fsSL`. When CHUMP_STORE_API_URL is unset, falls back to local
# `sqlite3 -json "$CHUMP_STATE_DB"` using the exact same canonical 15-column
# projection and ordering.

_chump_store_resolve_db() {
  if [[ -n "${CHUMP_STATE_DB:-}" ]]; then
    printf '%s\n' "$CHUMP_STATE_DB"
    return 0
  fi
  local root="${REPO_ROOT:-${CHUMP_REPO_ROOT:-}}"
  if [[ -z "$root" ]]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  fi
  if [[ -f "$root/.chump/state.db" ]]; then
    printf '%s\n' "$root/.chump/state.db"
    return 0
  fi
  if [[ -f "$root/state.db" ]]; then
    printf '%s\n' "$root/state.db"
    return 0
  fi
  printf '%s\n' "${HOME:-}/.chump/state.db"
}

_chump_store_select_cols() {
  local db="$1"
  local existing
  existing="$(sqlite3 "$db" "PRAGMA table_info(gaps);" 2>/dev/null | cut -d'|' -f2)"
  [[ -n "$existing" ]] || return 1
  local col cols=()
  for col in id title description domain priority status effort skills_required acceptance_criteria depends_on parent_id notes closed_pr closed_date created_at; do
    if grep -qxF "$col" <<<"$existing"; then
      cols+=("$col")
    else
      cols+=("NULL AS $col")
    fi
  done
  local IFS=", "
  printf '%s\n' "${cols[*]}"
}

_chump_store_in_clause() {
  local col="$1"
  local raw="$2"
  local tok esc parts=()
  local IFS=","
  read -ra _toks <<<"$raw"
  for tok in "${_toks[@]}"; do
    tok="${tok#"${tok%%[![:space:]]*}"}"
    tok="${tok%"${tok##*[![:space:]]}"}"
    [[ -n "$tok" ]] || continue
    esc="${tok//\'/\'\'}"
    parts+=("LOWER(${col}) = LOWER('${esc}')")
  done
  [[ ${#parts[@]} -gt 0 ]] || return 1
  local joined=""
  local p
  for p in "${parts[@]}"; do
    if [[ -z "$joined" ]]; then
      joined="$p"
    else
      joined="$joined OR $p"
    fi
  done
  printf '(%s)\n' "$joined"
}

chump_store_query_gaps() {
  local status="" priority="" domain="" limit="" order="id"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status) status="${2:-}"; shift 2 ;;
      --status=*) status="${1#*=}"; shift ;;
      --priority) priority="${2:-}"; shift 2 ;;
      --priority=*) priority="${1#*=}"; shift ;;
      --domain) domain="${2:-}"; shift 2 ;;
      --domain=*) domain="${1#*=}"; shift ;;
      --limit) limit="${2:-}"; shift 2 ;;
      --limit=*) limit="${1#*=}"; shift ;;
      --order) order="${2:-id}"; shift 2 ;;
      --order=*) order="${1#*=}"; shift ;;
      *) shift ;;
    esac
  done

  if [[ -n "${CHUMP_STORE_API_URL:-}" ]]; then
    local base="${CHUMP_STORE_API_URL%/}"
    local qs="" sep="?"
    if [[ -n "$status" ]]; then
      qs="${qs}${sep}status=${status}"
      sep="&"
    fi
    if [[ -n "$priority" ]]; then
      qs="${qs}${sep}priority=${priority}"
      sep="&"
    fi
    if [[ -n "$domain" ]]; then
      qs="${qs}${sep}domain=${domain}"
      sep="&"
    fi
    if [[ -n "$limit" ]]; then
      qs="${qs}${sep}limit=${limit}"
      sep="&"
    fi
    if [[ -n "$order" ]]; then
      qs="${qs}${sep}order=${order}"
    fi
    curl -fsSL "${base}/api/store/gaps${qs}"
    return $?
  fi

  local db
  db="$(_chump_store_resolve_db)"
  if [[ ! -f "$db" ]]; then
    printf '[]\n'
    return 0
  fi

  local select_cols
  if ! select_cols="$(_chump_store_select_cols "$db")"; then
    printf '[]\n'
    return 0
  fi

  local where_parts=() cond=""
  if [[ -n "$status" && "${status,,}" != "all" ]]; then
    if cond="$(_chump_store_in_clause "status" "$status")"; then
      where_parts+=("$cond")
    fi
  fi
  if [[ -n "$priority" && "${priority,,}" != "all" ]]; then
    if cond="$(_chump_store_in_clause "priority" "$priority")"; then
      where_parts+=("$cond")
    fi
  fi
  if [[ -n "$domain" && "${domain,,}" != "all" ]]; then
    if cond="$(_chump_store_in_clause "domain" "$domain")"; then
      where_parts+=("$cond")
    fi
  fi

  local where_sql=""
  if [[ ${#where_parts[@]} -gt 0 ]]; then
    local w
    for w in "${where_parts[@]}"; do
      if [[ -z "$where_sql" ]]; then
        where_sql=" WHERE $w"
      else
        where_sql="${where_sql} AND $w"
      fi
    done
  fi

  local order_sql=" ORDER BY id ASC"
  if [[ "${order,,}" == "priority" ]]; then
    order_sql=" ORDER BY CASE LOWER(priority) WHEN 'p0' THEN 0 WHEN 'critical' THEN 0 WHEN 'p1' THEN 1 WHEN 'high' THEN 1 WHEN 'p2' THEN 2 WHEN 'medium' THEN 2 WHEN 'p3' THEN 3 WHEN 'low' THEN 3 WHEN 'p4' THEN 4 ELSE 99 END ASC, id ASC"
  fi

  local limit_sql=""
  if [[ -n "$limit" && "$limit" =~ ^[0-9]+$ ]]; then
    limit_sql=" LIMIT $limit"
  fi

  local out
  out="$(sqlite3 -json "$db" "SELECT ${select_cols} FROM gaps${where_sql}${order_sql}${limit_sql};" 2>/dev/null)" || return 1
  if [[ -z "$out" ]]; then
    printf '[]\n'
  else
    printf '%s\n' "$out"
  fi
}

chump_store_get_gap() {
  local gap_id="${1:-}"
  [[ -n "$gap_id" ]] || return 1

  if [[ -n "${CHUMP_STORE_API_URL:-}" ]]; then
    local base="${CHUMP_STORE_API_URL%/}"
    curl -fsSL "${base}/api/store/gaps/${gap_id}"
    return $?
  fi

  local db
  db="$(_chump_store_resolve_db)"
  [[ -f "$db" ]] || return 1
  local select_cols
  select_cols="$(_chump_store_select_cols "$db")" || return 1
  local esc="${gap_id//\'/\'\'}"
  local out
  out="$(sqlite3 -json "$db" "SELECT ${select_cols} FROM gaps WHERE id = '${esc}' LIMIT 1;" 2>/dev/null)" || return 1
  [[ -n "$out" && "$out" != "[]" ]] || return 1
  python3 -c 'import json, sys; arr = json.loads(sys.stdin.read()); print(json.dumps(arr[0], separators=(",", ":")))' <<<"$out"
}
