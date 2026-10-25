#!/usr/bin/env bash
# scripts/coord/gap-decompose-organ.sh — RESILIENT-1707 (RESILIENT-1691 slice)
#
# Periodic user-scope organ (paired with chump-gap-decompose.{service,timer},
# home=cuphead in organ-manifest) that decomposes open P0/P1 gaps with effort=l
# (or an umbrella marker) once per gap via `chump gap decompose <ID> --apply`,
# demotes the parent per the decompose contract (status=decomposed, priority=P2),
# and emits `kind=gap_decomposed` with the child IDs.
#
# Rust-First-Bypass: Thin organ wrapper around `chump gap decompose --apply` + sqlite3 query.

set -euo pipefail

REPO_ROOT="${CHUMP_REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
STATE_DB="${CHUMP_STATE_DB:-$REPO_ROOT/.chump/state.db}"
LOCK_DIR="${CHUMP_LOCK_DIR:-$REPO_ROOT/.chump-locks}"
STAMP_DIR="${CHUMP_DECOMPOSE_STAMP_DIR:-$LOCK_DIR/decomposed}"
AMBIENT_FILE="${CHUMP_AMBIENT_LOG:-${AMBIENT_JSONL:-$LOCK_DIR/ambient.jsonl}}"
CHUMP_BIN="${CHUMP_BIN:-chump}"

MODE="apply"
for arg in "$@"; do
  case "$arg" in
    --apply)   MODE="apply" ;;
    --dry-run) MODE="dry-run" ;;
    -h|--help)
      echo "Usage: $0 [--apply|--dry-run]"
      exit 0
      ;;
  esac
done

if [[ ! -f "$STATE_DB" ]]; then
  exit 0
fi

mkdir -p "$STAMP_DIR" "$(dirname "$AMBIENT_FILE")" 2>/dev/null || true

emit_gap_decomposed() {
  # Literal for EVENT_REGISTRY scanner: "kind":"gap_decomposed"
  local parent_id="$1"
  shift
  local children=("$@")
  local ts children_json
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  children_json="$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "${children[@]}")"
  local line
  line="$(python3 -c '
import json, sys
ts, parent_id, children_raw = sys.argv[1], sys.argv[2], sys.argv[3]
children = json.loads(children_raw)
print(json.dumps({
    "ts": ts,
    "event": "gap_decomposed",
    "kind": "gap_decomposed",
    "gap_id": parent_id,
    "child_ids": children,
    "children": children,
    "slice_count": len(children),
    "source": "gap-decompose-organ.sh",
}))
' "$ts" "$parent_id" "$children_json")"
  printf '%s\n' "$line" >> "$AMBIENT_FILE"
}

query_child_ids() {
  local parent_id="$1"
  local has_parent_col
  has_parent_col="$(sqlite3 "$STATE_DB" "SELECT COUNT(*) FROM pragma_table_info('gaps') WHERE name='parent_id';" 2>/dev/null || echo 0)"
  if [[ "$has_parent_col" -gt 0 ]]; then
    sqlite3 "$STATE_DB" "
      SELECT id FROM gaps
      WHERE parent_id = '$parent_id'
         OR title LIKE '%($parent_id slice)%'
      ORDER BY id ASC;
    " 2>/dev/null || true
  else
    sqlite3 "$STATE_DB" "
      SELECT id FROM gaps
      WHERE title LIKE '%($parent_id slice)%'
      ORDER BY id ASC;
    " 2>/dev/null || true
  fi
}

demote_parent_per_contract() {
  local parent_id="$1"
  shift
  local children=("$@")
  local count="${#children[@]}"
  local joined=""
  local c
  for c in "${children[@]}"; do
    if [[ -n "$joined" ]]; then
      joined="${joined}, ${c}"
    else
      joined="$c"
    fi
  done
  local note="Decomposed into ${count} slices: ${joined}"
  local esc_note="${note//\'/\'\'}"
  sqlite3 "$STATE_DB" "
    UPDATE gaps
       SET priority = 'P2',
           status = 'decomposed',
           notes = CASE
             WHEN coalesce(notes, '') = '' THEN '${esc_note}'
             WHEN instr(notes, 'Decomposed into ') > 0 THEN notes
             ELSE notes || char(10) || '${esc_note}'
           END
     WHERE id = '${parent_id}';
  " 2>/dev/null || true
}

candidates="$(sqlite3 "$STATE_DB" "
  SELECT id
  FROM gaps
  WHERE lower(coalesce(status, 'open')) = 'open'
    AND upper(coalesce(priority, '')) IN ('P0', 'P1')
    AND lower(coalesce(title, '')) NOT LIKE '% slice)%'
    AND (
      lower(trim(coalesce(effort, ''))) IN ('l', 'xl', 'large')
      OR lower(coalesce(title, '')) LIKE 'umbrella:%'
      OR lower(coalesce(title, '')) LIKE '%[umbrella]%'
      OR lower(coalesce(description, '')) LIKE '%[umbrella]%'
      OR lower(coalesce(description, '')) LIKE '%decompose at claim%'
    )
  ORDER BY CASE upper(priority) WHEN 'P0' THEN 0 ELSE 1 END, id ASC;
" 2>/dev/null || true)"

[[ -z "$candidates" ]] && exit 0

while IFS= read -r gap_id; do
  [[ -z "$gap_id" ]] && continue
  stamp_file="$STAMP_DIR/${gap_id}.stamp"
  if [[ -f "$stamp_file" ]]; then
    continue
  fi

  # Check if child slices already exist in state.db for this parent.
  existing_children=()
  while IFS= read -r cid; do
    [[ -n "$cid" ]] && existing_children+=("$cid")
  done < <(query_child_ids "$gap_id")

  if [[ "${#existing_children[@]}" -gt 0 ]]; then
    if [[ "$MODE" == "apply" ]]; then
      demote_parent_per_contract "$gap_id" "${existing_children[@]}"
      printf '%s\n' "${existing_children[@]}" > "$stamp_file"
      emit_gap_decomposed "$gap_id" "${existing_children[@]}"
    fi
    continue
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    "$CHUMP_BIN" gap decompose "$gap_id" --dry-run || true
    continue
  fi

  cmd_out=""
  if cmd_out="$("$CHUMP_BIN" gap decompose "$gap_id" --apply --json 2>&1)"; then
    :
  else
    continue
  fi

  filed_children=()
  while IFS= read -r cid; do
    [[ -n "$cid" ]] && filed_children+=("$cid")
  done < <(query_child_ids "$gap_id")

  if [[ "${#filed_children[@]}" -eq 0 && -n "$cmd_out" ]]; then
    while IFS= read -r cid; do
      [[ -n "$cid" ]] && filed_children+=("$cid")
    done < <(python3 -c '
import json, re, sys
raw = sys.argv[1]
try:
    obj = json.loads(raw)
    for k in ("slices", "child_ids", "children"):
        if isinstance(obj.get(k), list):
            for item in obj[k]:
                if isinstance(item, str) and item.strip():
                    print(item.strip())
            sys.exit(0)
except Exception:
    pass
for m in re.findall(r"\b[A-Z][A-Z0-9_-]*-[0-9]+\b", raw):
    if m != sys.argv[2]:
        print(m)
' "$cmd_out" "$gap_id")
  fi

  if [[ "${#filed_children[@]}" -gt 0 ]]; then
    demote_parent_per_contract "$gap_id" "${filed_children[@]}"
    printf '%s\n' "${filed_children[@]}" > "$stamp_file"
    emit_gap_decomposed "$gap_id" "${filed_children[@]}"
  fi
done <<<"$candidates"
