#!/usr/bin/env bash
# scripts/ops/muscle-role-rollout.sh — RESILIENT-1090
#
# Packages the SAFE ROLLOUT procedure from RESILIENT-1090 into one auditable,
# idempotent command instead of four hand-run steps copy-pasted from a gap
# description. RESILIENT-1087 shipped the MECHANISM (organ-reconcile.sh
# self-derives its role from ~/.chump/node.env's CHUMP_NODE_ROLE, and
# RESILIENT-1016/1055 already made the drift-removal pass classify "out of
# role" purely from the manifest's role= tags + NODE_LOCAL_ORGAN_BASES). What
# was missing was a single command an operator can run ON a live muscle node
# (mugman, CJ, ...) that:
#
#   1. seeds ~/.chump/node.env's CHUMP_NODE_ROLE=muscle (durable — outside the
#      repo, survives `git reset --hard`), idempotently (updates the existing
#      line rather than duplicating it);
#   2. runs the muscle-scoped organ-reconcile.sh --check (READ ONLY) and
#      captures the full reap set;
#   3. classifies every flagged unit as either a manifest-tagged non-muscle
#      organ (SAFE — the intended brain-coordination reap target) or a true
#      manifest-orphan stray (UNKNOWN — needs a human to confirm it isn't
#      node-lifecycle infra before anything proceeds to --apply);
#   4. only runs the muscle-scoped --apply (the actual reap) when --apply was
#      passed AND no UNKNOWN units were found, then prints a before/after
#      is-active receipt for the node-lifecycle infra that must survive.
#
# Default mode is --check-only (steps 1-3, nothing mutates systemd). Pass
# --apply to also run step 4.
#
# Usage:
#   scripts/ops/muscle-role-rollout.sh                # seed node.env + check (read-only)
#   scripts/ops/muscle-role-rollout.sh --apply         # ...then reap if the check is clean
#   scripts/ops/muscle-role-rollout.sh --role brain    # (for symmetry / testing; muscle is the RESILIENT-1090 default)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"
LIB_ORGAN_MANIFEST="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
MANIFEST="${CHUMP_ORGAN_MANIFEST:-$REPO_ROOT/scripts/ops/organ-manifest.txt}"

[[ -f "$RECONCILE" ]] || { echo "ERROR: missing $RECONCILE" >&2; exit 1; }
[[ -f "$LIB_ORGAN_MANIFEST" ]] || { echo "ERROR: missing $LIB_ORGAN_MANIFEST" >&2; exit 1; }
# shellcheck source=/dev/null
source "$LIB_ORGAN_MANIFEST"

ROLE="muscle"
APPLY=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --role) : ;;  # value consumed below
    --role=*) ROLE="${arg#--role=}" ;;
    *) [[ "${prev:-}" == "--role" ]] && ROLE="$arg" ;;
  esac
  prev="$arg"
done

STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}"
NODE_ENV="$STATE_DIR/node.env"

echo "=== muscle-role-rollout.sh (RESILIENT-1090) — role=$ROLE apply=$APPLY ==="

# ── step 1: seed node.env's CHUMP_NODE_ROLE (idempotent) ────────────────────
# INFRA-8588 / RESILIENT-1684 / INFRA-8104: write bare KEY=VALUE (no `export`)
# on EVERY assignment line so systemd EnvironmentFile= units and shell callers
# see identical values, and only keep CHUMP_STORE_BACKEND / CHUMP_TEAM_URL /
# CHUMP_TEAM_API_KEY when a store actually listens at CHUMP_TEAM_URL.
mkdir -p "$STATE_DIR"
touch "$NODE_ENV"
_mrr_tmp="$(mktemp "${NODE_ENV}.XXXXXX")"
if grep -qE '^[[:space:]]*(export[[:space:]]+)?CHUMP_NODE_ROLE=' "$NODE_ENV" 2>/dev/null; then
  sed -E "s/^[[:space:]]*(export[[:space:]]+)?CHUMP_NODE_ROLE=.*/CHUMP_NODE_ROLE=$ROLE/" "$NODE_ENV" > "$_mrr_tmp" && mv -f "$_mrr_tmp" "$NODE_ENV"
else
  rm -f "$_mrr_tmp"
  printf 'CHUMP_NODE_ROLE=%s\n' "$ROLE" >> "$NODE_ENV"
fi
# Strip any remaining `export ` prefixes across node.env.
_mrr_tmp="$(mktemp "${NODE_ENV}.XXXXXX")"
sed -E 's/^[[:space:]]*export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*=)/\1/' "$NODE_ENV" > "$_mrr_tmp" && mv -f "$_mrr_tmp" "$NODE_ENV"
# Gate team-store keys on a live listener at CHUMP_TEAM_URL (never flipped blind).
_mrr_team_url="$(grep -E '^CHUMP_TEAM_URL=' "$NODE_ENV" 2>/dev/null | tail -1 | sed -E 's/^CHUMP_TEAM_URL=//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' || true)"
_mrr_store_ok=0
if [[ "${CHUMP_TEAM_STORE_LISTENING:-}" == "1" ]]; then
  _mrr_store_ok=1
elif [[ "${CHUMP_TEAM_STORE_LISTENING:-}" == "0" ]]; then
  _mrr_store_ok=0
elif [[ -n "$_mrr_team_url" ]]; then
  if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "${_mrr_team_url%/}/health" >/dev/null 2>&1; then
    _mrr_store_ok=1
  elif command -v python3 >/dev/null 2>&1 && python3 - "$_mrr_team_url" <<'PY' >/dev/null 2>&1
import socket, sys, urllib.parse
u = urllib.parse.urlparse(sys.argv[1] if "://" in sys.argv[1] else "http://" + sys.argv[1])
host = u.hostname or ""
port = u.port or (443 if u.scheme == "https" else 80)
if not host:
    sys.exit(1)
with socket.create_connection((host, port), timeout=1.0):
    pass
PY
  then
    _mrr_store_ok=1
  fi
fi
if [[ "$_mrr_store_ok" -ne 1 ]]; then
  _mrr_tmp="$(mktemp "${NODE_ENV}.XXXXXX")"
  grep -vE '^(CHUMP_STORE_BACKEND|CHUMP_TEAM_URL|CHUMP_TEAM_API_KEY)=' "$NODE_ENV" > "$_mrr_tmp" || true
  mv -f "$_mrr_tmp" "$NODE_ENV"
fi
echo "step 1/4: $NODE_ENV now carries CHUMP_NODE_ROLE=$ROLE"

# ── step 2: muscle-scoped --check (READ ONLY) ────────────────────────────────
ROLE_FILTER="$(organ_role_filter_for "$ROLE")"
echo "step 2/4: running role-scoped organ-reconcile.sh --check (role-filter=[${ROLE_FILTER:-all}])..."
CHECK_OUT="$(CHUMP_ORGAN_RECONCILE_ROLE="$ROLE_FILTER" bash "$RECONCILE" --check 2>&1)" || true
echo "$CHECK_OUT"

# ── step 3: classify the reap set ────────────────────────────────────────────
PAGING_OFF=(); ENABLED=(); declare -A ORGAN_ROLE ORGAN_REQUIRES
organ_manifest_parse "$MANIFEST" PAGING_OFF ENABLED ORGAN_ROLE ORGAN_REQUIRES || exit 1

SAFE_REAP=()
UNKNOWN=()
while IFS= read -r line; do
  [[ "$line" == "DRIFT: "*"out-of-role"* ]] || continue
  unit="$(awk '{print $2}' <<<"$line")"
  base="${unit%.service}"; base="${base%.timer}"
  # Manifest-tagged (any role) -> the intended reap target (a brain-coordination
  # daemon leaking onto a muscle node). Absent from the manifest entirely -> a
  # true stray that needs a human to confirm it isn't undeclared infra.
  if [[ -n "${ORGAN_ROLE[${base}.service]:-${ORGAN_ROLE[${base}.timer]:-}}" ]]; then
    SAFE_REAP+=("$unit")
  else
    UNKNOWN+=("$unit")
  fi
done <<<"$CHECK_OUT"

echo "step 3/4: classified reap set — ${#SAFE_REAP[@]} safe (manifest-tagged brain/data/janitor/trust), ${#UNKNOWN[@]} unknown"
[[ "${#SAFE_REAP[@]}" -gt 0 ]] && printf '  SAFE:    %s\n' "${SAFE_REAP[@]}"
[[ "${#UNKNOWN[@]}" -gt 0 ]] && printf '  UNKNOWN: %s (extend organ-manifest.txt or NODE_LOCAL_ORGAN_BASES before --apply)\n' "${UNKNOWN[@]}"

if [[ "$APPLY" != 1 ]]; then
  echo "step 4/4: skipped (pass --apply to reap after reviewing the classification above)"
  [[ "${#UNKNOWN[@]}" -gt 0 ]] && exit 2
  exit 0
fi

if [[ "${#UNKNOWN[@]}" -gt 0 ]]; then
  echo "REFUSING --apply: ${#UNKNOWN[@]} unclassified unit(s) in the reap set (see UNKNOWN above)." >&2
  exit 2
fi

# ── step 4: apply (only reached with a clean classification) ───────────────
echo "step 4/4: applying role-scoped reconcile (will reap ${#SAFE_REAP[@]} unit(s))..."
CHUMP_ORGAN_RECONCILE_ROLE="$ROLE_FILTER" bash "$RECONCILE" --apply

echo "receipt: node-lifecycle infra after reconcile:"
for base in "${NODE_LOCAL_ORGAN_BASES[@]}"; do
  state="inactive"
  systemctl is-active --quiet "${base}.service" 2>/dev/null && state="active(service)"
  systemctl is-active --quiet "${base}.timer" 2>/dev/null && state="active(timer)"
  echo "  $base: $state"
done
echo "receipt: reaped units: ${SAFE_REAP[*]:-none}"
