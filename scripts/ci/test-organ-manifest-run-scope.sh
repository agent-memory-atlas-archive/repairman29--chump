#!/usr/bin/env bash
# scripts/ci/test-organ-manifest-run-scope.sh — INFRA-8194 (Phase R, R5)
#
# organ-manifest.txt gains a `run-scope=user|system|any` field so an installer
# only places what the typed Host enum's manager scope allows. Proves:
#   1. organ_manifest_parse: the 8th (optional) nameref captures run-scope=,
#      omitted defaults to `any`; the 5/6/7-arg call signatures still work.
#   2. organ_run_scope_matches: any/empty match everything; user|system match
#      only themselves.
#   3. organ-reconcile.sh (system scope) skips a run-scope=user line with a
#      logged reason and never hands it to systemctl, while a run-scope=system
#      line and an untagged line are still reconciled (no regression).
#   4. The real manifest tags chump-organ-deploy.timer run-scope=system (a
#      root-only organ a --user bring-up must skip).
# Hermetic: stub systemctl, no root, platform pinned to systemd so it also runs
# on a macOS dev box.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
RECONCILE="$REPO_ROOT/scripts/ops/organ-reconcile.sh"

pass() { echo "  ok $*"; }
fail() { echo "  FAIL $*" >&2; exit 1; }

echo "=== test-organ-manifest-run-scope.sh (INFRA-8194) ==="
bash -n "$LIB" || fail "organ-manifest-lib.sh bash -n"
bash -n "$RECONCILE" || fail "organ-reconcile.sh bash -n"
# shellcheck source=/dev/null
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

M="$TMP/manifest.txt"
cat > "$M" <<'EOF'
enabled  chump-plain.service       role=brain
enabled  chump-root-only.timer     role=janitor run-scope=system
enabled  chump-user-only.timer     role=data run-scope=user  # run-scope=system in a comment must not count
paging_off  chump-pager.service
EOF

# ── 1. parse ────────────────────────────────────────────────────────────────
OFF=(); EN=(); declare -A ROLE REQ PLAT NODE SCOPE
organ_manifest_parse "$M" OFF EN ROLE REQ || fail "5-arg parse must still succeed"
[[ "${#EN[@]}" == 3 ]] || fail "5-arg parse must see 3 enabled lines; got ${#EN[@]}"
organ_manifest_parse "$M" OFF EN ROLE REQ PLAT NODE || fail "7-arg parse must still succeed"
organ_manifest_parse "$M" OFF EN ROLE REQ PLAT NODE SCOPE || fail "8-arg parse must succeed"
[[ "${SCOPE[chump-plain.service]}" == any ]] || fail "omitted run-scope= must default to any; got '${SCOPE[chump-plain.service]}'"
[[ "${SCOPE[chump-root-only.timer]}" == system ]] || fail "run-scope=system not captured"
[[ "${SCOPE[chump-user-only.timer]}" == user ]] || fail "trailing comment must not overwrite run-scope=user; got '${SCOPE[chump-user-only.timer]}'"
[[ "${PLAT[chump-root-only.timer]}" == systemd ]] || fail "platforms= default must be unaffected by run-scope="
pass "organ_manifest_parse: 8th nameref captures run-scope=, defaults to any, comment-safe, older signatures intact"

# ── 2. matcher ──────────────────────────────────────────────────────────────
organ_run_scope_matches any user && organ_run_scope_matches any system \
  && organ_run_scope_matches "" user || fail "any/empty must match every scope"
organ_run_scope_matches system system && organ_run_scope_matches user user || fail "a scope must match itself"
organ_run_scope_matches system user && fail "run-scope=system must NOT match a user install"
organ_run_scope_matches user system && fail "run-scope=user must NOT match a system install"
[[ "$(CHUMP_ORGAN_MANIFEST_RUN_SCOPE=user organ_current_run_scope)" == user ]] || fail "CHUMP_ORGAN_MANIFEST_RUN_SCOPE override ignored"
pass "organ_run_scope_matches + organ_current_run_scope override"

# ── 3. reconcile (system scope) ─────────────────────────────────────────────
STUB="$TMP/systemctl"; CALLS="$TMP/calls.log"; ACTIVE="$TMP/active.txt"; : > "$ACTIVE"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$CALLS"
case "\$1" in
  is-active) grep -qxF "\${@: -1}" "$ACTIVE" && exit 0 || exit 3 ;;
  enable) echo "\${@: -1}" >> "$ACTIVE"; exit 0 ;;
  show) echo "ExecStart=/bin/true"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$STUB"
: > "$CALLS"
out="$(CHUMP_ORGAN_MANIFEST="$M" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST_PLATFORM=systemd \
  NODE_AMBIENT="$TMP/ambient.jsonl" \
  bash "$RECONCILE" --check 2>&1)"
echo "$out" | grep -q "skip chump-user-only.timer: run-scope=user" \
  || fail "reconcile must log a run-scope skip for the user-only organ; got: $out"
grep -q "chump-user-only" "$CALLS" && fail "run-scope=user organ must never reach systemctl; calls: $(cat "$CALLS")"
echo "$out" | grep -q "chump-root-only.timer" || fail "run-scope=system organ must still be reconciled at system scope; got: $out"
echo "$out" | grep -q "chump-plain.service" || fail "untagged organ must still be reconciled (no regression); got: $out"
pass "organ-reconcile.sh skips run-scope=user with a logged reason, keeps system + untagged organs"

# ── 4. the real manifest ────────────────────────────────────────────────────
grep -Eq '^enabled[[:space:]]+chump-organ-deploy\.timer[[:space:]].*run-scope=system' "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
  || fail "chump-organ-deploy.timer must be tagged run-scope=system (root-only organ)"
pass "real manifest tags the root-only chump-organ-deploy.timer run-scope=system"

# ── 5. RESILIENT-1644: retired state + paused-timers.txt honoured ───────────
M_RET="$TMP/manifest-retired.txt"
cat > "$M_RET" <<'EOF'
enabled  chump-active-organ.timer       role=brain
enabled  chump-paused-by-file.timer     role=brain
retired  chump-armed-pr-rebaser.timer   role=brain  # retired: done by the GitHub merge queue (PHASE-R R3)
retired  chump-rot-reaper.timer         role=brain  # retired: done by the GitHub merge queue (PHASE-R R3)
EOF
PAUSED_FILE="$TMP/paused-timers.txt"
cat > "$PAUSED_FILE" <<'EOF'
# Paused by operator / PHASE-R R3
chump-paused-by-file.timer
armed-pr-rebaser
pr-auto-rebase
rot-reaper
stale-pr-reaper
auto-arm-sweeper
auto-merge-armer
EOF

RET_ARR=()
organ_manifest_parse "$M_RET" OFF EN ROLE REQ PLAT NODE SCOPE RET_ARR || fail "9-arg parse with retired state failed"
[[ "${#EN[@]}" == 2 ]] || fail "retired units must not enter ENABLED; got ${#EN[@]} (${EN[*]})"
[[ "${#RET_ARR[@]}" == 2 ]] || fail "9th nameref must capture 2 retired units; got ${#RET_ARR[@]} (${RET_ARR[*]})"
organ_is_paused_or_retired "chump-armed-pr-rebaser.timer" "$M_RET" "$PAUSED_FILE" \
  || fail "organ_is_paused_or_retired must match manifest-retired unit"
organ_is_paused_or_retired "chump-paused-by-file.timer" "$M_RET" "$PAUSED_FILE" \
  || fail "organ_is_paused_or_retired must match paused-timers.txt unit"
organ_is_paused_or_retired "chump-active-organ.timer" "$M_RET" "$PAUSED_FILE" \
  && fail "organ_is_paused_or_retired must NOT match active un-paused unit"

: > "$CALLS"
: > "$ACTIVE"
out_ret="$(CHUMP_ORGAN_MANIFEST="$M_RET" \
  CHUMP_PAUSED_TIMERS_FILE="$PAUSED_FILE" \
  CHUMP_ORGAN_RECONCILE_SYSTEMCTL_BIN="$STUB" \
  CHUMP_ORGAN_RECONCILE_ALLOW_NONROOT=1 \
  CHUMP_ORGAN_RECONCILE_BACKOFF_DIR="$TMP/backoff" \
  CHUMP_ORGAN_RECONCILE_VERIFY_DELAY_S=0 \
  CHUMP_ORGAN_MANIFEST_PLATFORM=systemd \
  NODE_AMBIENT="$TMP/ambient.jsonl" \
  bash "$RECONCILE" --apply 2>&1)"
grep -q "enable.*chump-armed-pr-rebaser" "$CALLS" \
  && fail "organ-reconcile must never re-enable retired chump-armed-pr-rebaser; calls: $(cat "$CALLS")"
grep -q "enable.*chump-rot-reaper" "$CALLS" \
  && fail "organ-reconcile must never re-enable retired chump-rot-reaper; calls: $(cat "$CALLS")"
grep -q "enable.*chump-paused-by-file" "$CALLS" \
  && fail "organ-reconcile must never re-enable paused-timers.txt unit; calls: $(cat "$CALLS")"
grep -q "enable.*chump-active-organ.timer" "$CALLS" \
  || fail "organ-reconcile must still enable non-retired chump-active-organ.timer; out=$out_ret calls=$(cat "$CALLS")"

for retired_base in pr-auto-rebase rot-reaper stale-pr-reaper auto-arm-sweeper auto-merge-armer; do
  grep -Eq "^retired[[:space:]]+chump-${retired_base}\\.(timer|service).*retired: done by the GitHub merge queue \\(PHASE-R R3\\)" "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "real organ-manifest.txt must mark chump-${retired_base} retired with PHASE-R R3 reason"
  grep -Eq "^enabled[[:space:]]+chump-${retired_base}\\.(timer|service)" "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    && fail "real organ-manifest.txt must not leave chump-${retired_base} enabled"
done
pass "RESILIENT-1644: retired state + paused-timers.txt honoured by parser, organ-reconcile, and real organ-manifest.txt"

# ── 6. INFRA-8126 / INFRA-8144 / INFRA-8146: Linux-ported organs ─────────────
for ported_organ in branch-reaper stale-branch-reaper armed-pr-rebaser dup-pr-detector pr-book ghost-pr-closer github-liaison daemon-activator; do
  [[ -f "$REPO_ROOT/scripts/dispatch/chump-${ported_organ}.service" ]] \
    || fail "missing systemd service unit scripts/dispatch/chump-${ported_organ}.service"
  [[ -f "$REPO_ROOT/scripts/dispatch/chump-${ported_organ}.timer" ]] \
    || fail "missing systemd timer unit scripts/dispatch/chump-${ported_organ}.timer"
  grep -Eq "^enabled[[:space:]]+chump-${ported_organ}\\.timer.*platforms=systemd,launchd" "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    || fail "organ-manifest.txt must declare chump-${ported_organ}.timer enabled with platforms=systemd,launchd"
  organ_is_paused_or_retired "chump-${ported_organ}.timer" "$REPO_ROOT/scripts/ops/organ-manifest.txt" \
    && fail "chump-${ported_organ}.timer must NOT be marked paused or retired in organ-manifest.txt"
done
pass "INFRA-8126 / INFRA-8144 / INFRA-8146: all 8 Linux-ported organs have tracked systemd .service+.timer units and enabled platforms=systemd,launchd manifest entries"

# ── 7. RESILIENT-1694: organ-manifest home field & fleet-doctor verification ─
MANIFEST_TXT="$REPO_ROOT/scripts/ops/organ-manifest.txt"
MANIFEST_YAML="$REPO_ROOT/scripts/ops/organ-manifest.yaml"
DOCTOR="$REPO_ROOT/scripts/coord/fleet-doctor-strict.sh"
DECOMPOSE_ORGAN="$REPO_ROOT/scripts/coord/gap-decompose-organ.sh"
PICKER="$REPO_ROOT/scripts/dispatch/_pick_and_claim_gap.py"

[[ -f "$MANIFEST_YAML" ]] || fail "scripts/ops/organ-manifest.yaml missing"
pass "scripts/ops/organ-manifest.yaml exists"

if grep -qE '^\s*home:' "$MANIFEST_YAML" && grep -q 'required:.*home' "$MANIFEST_YAML"; then
  pass "organ-manifest.yaml schema includes required 'home' field"
else
  fail "organ-manifest.yaml schema missing required 'home' field"
fi

declare -a R1694_PAGING_OFF=() R1694_ENABLED=() R1694_RETIRED=()
declare -A R1694_ROLE=() R1694_REQUIRES=() R1694_PLATFORMS=() R1694_NODE=() R1694_SCOPE=() R1694_HOME_MAP=()
organ_manifest_parse "$MANIFEST_TXT" R1694_PAGING_OFF R1694_ENABLED R1694_ROLE R1694_REQUIRES R1694_PLATFORMS R1694_NODE R1694_SCOPE R1694_RETIRED R1694_HOME_MAP

all_units=("${R1694_ENABLED[@]}" "${R1694_PAGING_OFF[@]}" "${R1694_RETIRED[@]}")
missing_home=0
for u in "${all_units[@]}"; do
  h="${R1694_HOME_MAP[$u]:-}"
  if [[ -z "$h" ]]; then
    fail "organ-manifest.txt unit '$u' missing home= field"
    missing_home=1
  elif ! organ_home_matches "$h" "cuphead" && ! organ_home_matches "$h" "slim" && ! organ_home_matches "$h" "mac" && ! organ_home_matches "$h" "closetjunky"; then
    fail "organ-manifest.txt unit '$u' has invalid home='$h'"
    missing_home=1
  fi
done
if [[ "$missing_home" -eq 0 && "${#all_units[@]}" -gt 0 ]]; then
  pass "all ${#all_units[@]} organs in organ-manifest.txt have a valid home= field via organ_manifest_parse"
fi

run_doctor_home_check() {
  local manifest_override="$1"
  local active_organs="$2"
  local node_name="${3:-cuphead}"
  (
    export CHUMP_ORGAN_MANIFEST="$manifest_override"
    export CHUMP_ORGAN_MANIFEST_YAML="$MANIFEST_YAML"
    export CHUMP_DOCTOR_ACTIVE_ORGANS="$active_organs"
    export CHUMP_DOCTOR_NODE_NAME="$node_name"
    export FLEET_DOCTOR_SOURCED=1
    set --
    # shellcheck source=/dev/null
    source "$DOCTOR"
    CHECKS=()
    STATUSES=()
    DETAILS=()
    REMEDIES=()
    PASS_COUNT=0
    FAIL_COUNT=0
    check_organ_home_placement
    printf '%s|%s\n' "${STATUSES[0]:-none}" "${DETAILS[0]:-}"
  )
}

green_out="$(run_doctor_home_check "$MANIFEST_TXT" "chump-pr-lander.timer:cuphead,chump-duty-officer.timer:slim,chump-gap-decompose.timer:cuphead" "cuphead")"
if [[ "${green_out%%|*}" == "pass" ]] && grep -q "GREEN" <<<"$green_out"; then
  pass "fleet-doctor returns GREEN when all organs have home set and run on their home nodes"
else
  fail "fleet-doctor expected GREEN/pass, got: $green_out"
fi

red_misplaced="$(run_doctor_home_check "$MANIFEST_TXT" "chump-duty-officer.timer:cuphead,chump-pr-lander.timer:slim" "cuphead")"
if [[ "${red_misplaced%%|*}" == "fail" ]] && grep -q "RED" <<<"$red_misplaced"; then
  pass "fleet-doctor returns RED when an organ runs on a node different from its home"
else
  fail "fleet-doctor expected RED/fail on misplaced organ, got: $red_misplaced"
fi

MUTANT_MANIFEST="$TMP/organ-manifest-missing-home.txt"
sed 's/ home=cuphead//' "$MANIFEST_TXT" > "$MUTANT_MANIFEST"
red_missing="$(run_doctor_home_check "$MUTANT_MANIFEST" "chump-duty-officer.timer:slim" "slim")"
if [[ "${red_missing%%|*}" == "fail" ]] && grep -q "missing or invalid home field" <<<"$red_missing"; then
  pass "fleet-doctor returns RED when any organ in manifest is missing its home field"
else
  fail "fleet-doctor expected RED/fail on missing home field, got: $red_missing"
fi

# ── 8. RESILIENT-1707: decompose organ & picker gap_skipped_needs_decompose ─
if [[ "${R1694_HOME_MAP[chump-gap-decompose.timer]:-}" == "cuphead" && "${R1694_SCOPE[chump-gap-decompose.timer]:-}" == "user" ]]; then
  pass "chump-gap-decompose.timer registered in organ-manifest with run-scope=user and home=cuphead"
else
  fail "chump-gap-decompose.timer missing or misconfigured in organ-manifest"
fi

if [[ -f "$REPO_ROOT/scripts/dispatch/chump-gap-decompose.service" && -f "$REPO_ROOT/scripts/dispatch/chump-gap-decompose.timer" && -x "$DECOMPOSE_ORGAN" ]]; then
  pass "chump-gap-decompose.{service,timer} and executable gap-decompose-organ.sh present"
else
  fail "chump-gap-decompose units or gap-decompose-organ.sh missing"
fi

PICK_TMP="$TMP/picker"
mkdir -p "$PICK_TMP/.chump-locks"
cat > "$PICK_TMP/gaps.json" <<'JSON'
[
  {
    "id": "TEST-UMB-1",
    "title": "Synthetic large umbrella gap",
    "status": "open",
    "priority": "P1",
    "domain": "RESILIENT",
    "effort": "l"
  },
  {
    "id": "TEST-SMALL-2",
    "title": "Synthetic small slice",
    "status": "open",
    "priority": "P1",
    "domain": "RESILIENT",
    "effort": "s"
  }
]
JSON

FAKE_BIN="$PICK_TMP/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/chump" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$FAKE_BIN/chump"

picked_id="$(
  GAP_JSON_FILE="$PICK_TMP/gaps.json" \
  CHUMP_LOCK_DIR="$PICK_TMP/.chump-locks" \
  AMBIENT_JSONL="$PICK_TMP/.chump-locks/ambient.jsonl" \
  CHUMP_BIN="$FAKE_BIN/chump" \
  FLEET_PRIORITY_FILTER="P0,P1" \
  FLEET_EFFORT_FILTER="xs,s,m" \
  WORKER_ID="w-test" \
  python3 "$PICKER" 2>/dev/null
)"
[[ "$picked_id" == "TEST-SMALL-2" ]] || fail "picker expected TEST-SMALL-2, got '$picked_id'"
pass "picker skipped effort=l TEST-UMB-1 and picked effort=s TEST-SMALL-2"

if [[ -f "$PICK_TMP/.chump-locks/ambient.jsonl" ]] \
  && grep -q '"kind":"gap_skipped_needs_decompose"' "$PICK_TMP/.chump-locks/ambient.jsonl" \
  && grep -q '"gap_id":"TEST-UMB-1"' "$PICK_TMP/.chump-locks/ambient.jsonl"; then
  pass "picker emitted kind=gap_skipped_needs_decompose with gap_id=TEST-UMB-1"
else
  fail "picker did not emit kind=gap_skipped_needs_decompose for TEST-UMB-1"
fi

DEC_TMP="$TMP/decompose"
mkdir -p "$DEC_TMP/.chump" "$DEC_TMP/.chump-locks" "$DEC_TMP/bin"
DEC_DB="$DEC_TMP/.chump/state.db"
sqlite3 "$DEC_DB" <<'SQL'
CREATE TABLE gaps (
  id TEXT PRIMARY KEY,
  title TEXT,
  description TEXT,
  acceptance TEXT,
  priority TEXT,
  status TEXT,
  domain TEXT,
  effort TEXT,
  parent_id TEXT,
  notes TEXT
);
INSERT INTO gaps (id, title, description, acceptance, priority, status, domain, effort, parent_id, notes)
VALUES (
  'TEST-UMB-100',
  'Synthetic effort=l P1 umbrella gap',
  'Umbrella description',
  '- Slice A\n- Slice B\n- Slice C',
  'P1',
  'open',
  'RESILIENT',
  'l',
  NULL,
  ''
);
INSERT INTO gaps (id, title, description, acceptance, priority, status, domain, effort, parent_id, notes)
VALUES
  ('RESILIENT-1691', 'Umbrella: 2-host fleet layout (cuphead + slim)', 'Umbrella', '', 'P2', 'decomposed', 'RESILIENT', 'l', NULL, 'Decomposed into 3 slices: RESILIENT-1694, RESILIENT-1702, RESILIENT-1707'),
  ('RESILIENT-1694', 'Add home field to organ-manifest and fleet-doctor verification (RESILIENT-1691 slice)', 'Slice 1', '', 'P1', 'open', 'RESILIENT', 's', 'RESILIENT-1691', ''),
  ('RESILIENT-1702', 'Optimize duty-officer and architect loop for 4GB memory constraint (RESILIENT-1691 slice)', 'Slice 2', '', 'P1', 'open', 'RESILIENT', 'm', 'RESILIENT-1691', ''),
  ('RESILIENT-1707', 'large umbrellas never decompose on their own (RESILIENT-1691 slice)', 'Slice 3', '', 'P1', 'open', 'RESILIENT', 'm', 'RESILIENT-1691', '');
SQL

cat > "$DEC_TMP/bin/chump" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "gap" && "${2:-}" == "decompose" ]]; then
  parent_id="${3:-}"
  echo "$parent_id" >> "$CHUMP_DECOMPOSE_CALL_LOG"
  sqlite3 "$CHUMP_STATE_DB" "
    INSERT INTO gaps (id, title, description, acceptance, priority, status, domain, effort, parent_id, notes)
    VALUES
      ('${parent_id}-A', 'Slice A (${parent_id} slice)', 'Child A', '- AC1', 'P1', 'open', 'RESILIENT', 's', '${parent_id}', ''),
      ('${parent_id}-B', 'Slice B (${parent_id} slice)', 'Child B', '- AC2', 'P1', 'open', 'RESILIENT', 's', '${parent_id}', '');
    UPDATE gaps
       SET priority = 'P2',
           status = 'decomposed',
           notes = 'Decomposed into 2 slices: ${parent_id}-A, ${parent_id}-B'
     WHERE id = '${parent_id}';
  "
  printf '{"parent":"%s","slices":["%s-A","%s-B"]}\n' "$parent_id" "$parent_id" "$parent_id"
  exit 0
fi
exit 0
SH
chmod +x "$DEC_TMP/bin/chump"

CHUMP_STATE_DB="$DEC_DB" \
CHUMP_LOCK_DIR="$DEC_TMP/.chump-locks" \
CHUMP_AMBIENT_LOG="$DEC_TMP/.chump-locks/ambient.jsonl" \
CHUMP_BIN="$DEC_TMP/bin/chump" \
CHUMP_DECOMPOSE_CALL_LOG="$DEC_TMP/calls.log" \
bash "$DECOMPOSE_ORGAN" --apply

parent_state="$(sqlite3 "$DEC_DB" "SELECT status || '|' || priority FROM gaps WHERE id='TEST-UMB-100';")"
child_count="$(sqlite3 "$DEC_DB" "SELECT COUNT(*) FROM gaps WHERE parent_id='TEST-UMB-100';")"
res1691_children="$(sqlite3 "$DEC_DB" "SELECT COUNT(*) FROM gaps WHERE parent_id='RESILIENT-1691';")"
[[ "$parent_state" == "decomposed|P2" && "$child_count" -eq 2 && "$res1691_children" -eq 3 ]] \
  || fail "unexpected state after tick 1: parent_state=$parent_state child_count=$child_count res1691_children=$res1691_children"
pass "decompose organ filed children within one tick, demoted parent to status=decomposed/P2, and verified RESILIENT-1691 child receipts"

if grep -q '"kind": "gap_decomposed"\|"kind":"gap_decomposed"' "$DEC_TMP/.chump-locks/ambient.jsonl" \
  && grep -q 'TEST-UMB-100-A' "$DEC_TMP/.chump-locks/ambient.jsonl" \
  && grep -q 'TEST-UMB-100-B' "$DEC_TMP/.chump-locks/ambient.jsonl"; then
  pass "decompose organ emitted kind=gap_decomposed with child IDs"
else
  fail "decompose organ did not emit kind=gap_decomposed with child IDs"
fi

CHUMP_STATE_DB="$DEC_DB" \
CHUMP_LOCK_DIR="$DEC_TMP/.chump-locks" \
CHUMP_AMBIENT_LOG="$DEC_TMP/.chump-locks/ambient.jsonl" \
CHUMP_BIN="$DEC_TMP/bin/chump" \
CHUMP_DECOMPOSE_CALL_LOG="$DEC_TMP/calls.log" \
bash "$DECOMPOSE_ORGAN" --apply

call_lines="$(wc -l < "$DEC_TMP/calls.log" | tr -d ' ')"
[[ "$call_lines" -eq 1 ]] || fail "expected 1 decompose invocation across 2 ticks, got $call_lines"
pass "decompose organ runs chump gap decompose --apply at most once per gap"

# ── 9. RESILIENT-1702: 4GB memory constraints for duty-officer and architect ─
for unit_file in \
  "$REPO_ROOT/scripts/dispatch/chump-duty-officer.service" \
  "$REPO_ROOT/scripts/dispatch/chump-architect-tick.service"; do
  bname="$(basename "$unit_file")"
  if grep -q '^MemoryHigh=3072M$' "$unit_file" \
    && grep -q '^MemoryMax=3584M$' "$unit_file" \
    && grep -q '^Environment=CHUMP_ADMISSION_MAX_CONCURRENT=1$' "$unit_file"; then
    pass "$bname declares MemoryHigh=3072M, MemoryMax=3584M (<4GB with headroom), and CHUMP_ADMISSION_MAX_CONCURRENT=1"
  else
    fail "$bname missing 4GB memory constraints"
  fi
done

if grep -q 'CHUMP_DUTY_OFFICER_MAX_TOKENS' "$REPO_ROOT/scripts/coord/duty-officer-loop.sh" \
  && grep -q 'CHUMP_DUTY_OFFICER_MAX_TURNS' "$REPO_ROOT/scripts/coord/duty-officer-loop.sh" \
  && grep -q -- '--max-turns' "$REPO_ROOT/scripts/coord/duty-officer-loop.sh" \
  && grep -q -- '--max-budget-usd' "$REPO_ROOT/scripts/coord/duty-officer-loop.sh"; then
  pass "duty-officer-loop.sh bounds model calls (tokens, turns, budget)"
else
  fail "duty-officer-loop.sh missing model call bounds"
fi

if grep -qiE 'sqlite3.*(INSERT|UPDATE|DELETE|REPLACE|ALTER|DROP)[[:space:]]' \
  "$REPO_ROOT/scripts/coord/duty-officer-loop.sh" \
  "$REPO_ROOT/scripts/dispatch/architect-ro.sh" \
  "$REPO_ROOT/scripts/dispatch/architect-tick.sh"; then
  fail "found store write SQL in duty-officer-loop.sh or architect scripts"
else
  pass "zero canonical store write SQL operations in duty-officer-loop.sh, architect-ro.sh, and architect-tick.sh"
fi

if [[ -f "$REPO_ROOT/docs/operations/SLIM_4GB_THINKING_ORGANS.md" ]] \
  && grep -q 'MemoryMax' "$REPO_ROOT/docs/operations/SLIM_4GB_THINKING_ORGANS.md" \
  && grep -q 'Tuning Recommendations' "$REPO_ROOT/docs/operations/SLIM_4GB_THINKING_ORGANS.md"; then
  pass "docs/operations/SLIM_4GB_THINKING_ORGANS.md records profiling results and tuning recommendations"
else
  fail "docs/operations/SLIM_4GB_THINKING_ORGANS.md missing or incomplete"
fi

echo "ALL PASS"
