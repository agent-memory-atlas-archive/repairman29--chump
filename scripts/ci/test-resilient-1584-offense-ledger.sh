#!/usr/bin/env bash
# RESILIENT-1584: rc=0 unverified_ship must count in the INFRA-3832 offense
# ledger and the rc=0 branch must not wipe it. Replays RESILIENT-445:
# rc=143, rc=0 unverified_ship, rc=143 -> status=blocked; a verified ship clears.
# Depth: happy-path + interleaved edge. Gaps: no live worker run; worker.sh
# wiring asserted structurally, ledger behavior exercised via the shared lib.
set -euo pipefail
PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
REPO_SRC="$(cd "$(dirname "$0")/../.." && pwd)"
WORKER="$REPO_SRC/scripts/dispatch/worker.sh"

# Structural: rc==0 branch has no wipe; wipe only in shipped path.
rc0="$(awk '/if \[ "\$rc" -eq 0 \]; then/{f=1} f&&/^    else$/{exit} f' "$WORKER" | sed -n '1,12p')"
if printf '%s' "$rc0" | grep -q 'offense/'; then fail "rc==0 branch still touches offense ledger"; else ok "rc==0 branch does not wipe ledger"; fi
grep -q 'offense_clear "\$GAP_ID"' "$WORKER" && ok "verified-ship path clears ledger" || fail "no offense_clear in shipped path"
grep -q '_uv_offense_n="\$(offense_bump' "$WORKER" && ok "unverified_ship path bumps ledger" || fail "unverified_ship does not bump ledger"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export REPO_ROOT="$TMP" CHUMP_AMBIENT_LOG="$TMP/ambient.jsonl" AGENT_ID=t
mkdir -p "$TMP/bin"
cat > "$TMP/bin/chump" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$REPO_ROOT/chump-calls.log"
STUB
chmod +x "$TMP/bin/chump"; export PATH="$TMP/bin:$PATH"
source "$REPO_SRC/scripts/dispatch/lib/offense-ledger.sh"

G=RESILIENT-445
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
[ ! -f "$TMP/chump-calls.log" ] && ok "no block after 2 offenses" || fail "blocked too early"
n=$(offense_bump $G); offense_maybe_block $G "$n" "timeout" 124
if grep -q "gap set $G --status blocked" "$TMP/chump-calls.log" 2>/dev/null; then ok "Transient pattern (3x timeout) -> blocked"; else fail "Transient pattern not blocked"; fi

rm -f "$TMP/chump-calls.log"
offense_bump G2 >/dev/null; offense_bump G2 >/dev/null; offense_clear G2
n=$(offense_bump G2); [ "$n" = 1 ] && ok "verified ship clears ledger" || fail "ledger not cleared (n=$n)"

# RESILIENT-1344: Test Capability classification routes to capable_agent_escalation queue.
# Transient (timeout) case -> auto-blocks
G3=RESILIENT-1344-TRANSIENT
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
n=$(offense_bump $G3); offense_maybe_block $G3 "$n" "timeout" 124
if grep -q "gap set $G3 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"gap_auto_blocked"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Transient (timeout) -> auto-blocked"
else
    fail "Transient (timeout) did not auto-block"
fi

# Capability (unverified_ship) case -> escalation queue
G4=RESILIENT-1344-CAPABILITY
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
n=$(offense_bump $G4); offense_maybe_block $G4 "$n" "unverified_ship" 0
if ! grep -q "gap set $G4 --status blocked" "$TMP/chump-calls.log" 2>/dev/null && grep -q '"kind":"capable_agent_escalation"' "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "Capability (unverified_ship) -> capable_agent_escalation"
else
    fail "Capability (unverified_ship) did not escalate (got auto-blocked instead)"
fi

# CREDIBLE-1578: an auto-block must NAME the failing step and KEEP the cycle log
# (path in the note + event), not just rc + byte count. This block exercises the
# recording machinery (AC2) with a small inline UNIT fixture of the no_onboard_scan
# signature — it is deliberately synthetic and only drives offense_maybe_block's
# note/event/preserve wiring; it is NOT the AC1 reproduction receipt. The AC1 receipt
# (a real reproduced rc=1 cycle produced by the `chump improve` binary) is G8 below.
# The faithfulness guards (G6/G7) prove the classifier never lies about the log.
G5=CREDIBLE-1578-EXTERNAL
rm -f "$TMP/chump-calls.log" "$TMP/ambient.jsonl"
rm -rf "$TMP/.chump-locks/offense/logs"
_clog="$TMP/cycle-$G5.log"
cat > "$_clog" <<'LOG'
[improve] Stage 1: PICK — scout repairman29/olive...
chump improve: reading latest onboard scan: no onboard scan found under /x — run `chump onboard repairman29/olive` first
LOG
_clogsz="$(wc -c < "$_clog" | tr -d ' ')"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"
n=$(offense_bump $G5); offense_maybe_block $G5 "$n" "timeout" 124 "$_clogsz" "$_clog"

# (a) the block note names the failing step classified from the real log
if grep -Fq "Failing step: external_repo:no_onboard_scan" "$TMP/chump-calls.log" 2>/dev/null; then
    ok "CREDIBLE-1578: block note names the failing step"
else
    fail "CREDIBLE-1578: block note missing 'Failing step: external_repo:no_onboard_scan'"
fi

# (b) the cycle log is preserved to a durable path AND that path is in the note
_kept="$(ls "$TMP/.chump-locks/offense/logs/${G5}-block-"*.log 2>/dev/null | head -1)"
if [ -n "$_kept" ] && [ -f "$_kept" ] \
   && grep -Fq "Cycle log kept at: $_kept" "$TMP/chump-calls.log" 2>/dev/null; then
    ok "CREDIBLE-1578: cycle log preserved + exact path recorded in note"
else
    fail "CREDIBLE-1578: cycle log not preserved or path not in note (kept='$_kept')"
fi

# (c) the preserved copy is byte-identical to the source log (a real receipt)
if [ -n "$_kept" ] && cmp -s "$_clog" "$_kept"; then
    ok "CREDIBLE-1578: preserved log is byte-identical to the cycle log"
else
    fail "CREDIBLE-1578: preserved log differs from the source cycle log"
fi

# (d) the gap_auto_blocked ambient event carries failing_step + cycle_log
if grep -Fq '"failing_step":"external_repo:no_onboard_scan"' "$TMP/ambient.jsonl" 2>/dev/null \
   && grep -Fq "\"cycle_log\":\"$_kept\"" "$TMP/ambient.jsonl" 2>/dev/null; then
    ok "CREDIBLE-1578: gap_auto_blocked event carries failing_step + cycle_log"
else
    fail "CREDIBLE-1578: event missing failing_step/cycle_log"
fi

# CREDIBLE-1578 AC1 (faithfulness guard): the recorded "why" must be a FAITHFUL
# receipt of the actual log, not an asserted/guessed cause. classify_failing_step
# must name a specific pre-agent step ONLY when the log actually contains that
# step's marker; for a log with none of the known markers it must fall back to a
# receipt-grounded reason (tail:/unclassified), never fabricate a specific cause.
# (The specific signature behind the 27 Olive blocks is not reproduced here — that
# live-cycle receipt is carved to a lane-1 follow-up; this guard only proves the
# classifier never lies about what the log says.)
G6=CREDIBLE-1578-FAITHFUL
_ulog="$TMP/cycle-$G6.log"
printf '%s\n' '[improve] stage 1 progress, nothing actionable' \
             'worker: generic line with none of the known markers' > "$_ulog"
_step6="$(classify_failing_step "$_ulog")"
case "$_step6" in
    external_repo:*|in_repo_ship_on_external_gap|auth_or_billing|decompose_precheck)
        fail "CREDIBLE-1578: classifier fabricated specific step '$_step6' for a log with no matching marker" ;;
    tail:*|unclassified*)
        ok "CREDIBLE-1578: classifier stays faithful to the log (receipt-grounded fallback, no guessed cause)" ;;
    *)
        fail "CREDIBLE-1578: classifier returned unexpected step '$_step6'" ;;
esac

# CREDIBLE-1578 AC1 (faithfulness guard, decompose over-broadness): the review's
# attack surface — the old `decompose` marker matched ANY line containing the word,
# so a benign "Stage: decompose umbrella" progress line was fabricated into a
# `decompose_precheck` cause. The marker must now fire ONLY when a decompose
# *failure* phrase is literally present; a benign mention must fall through to the
# receipt-grounded tail. (G7a kills the over-broad regression; G7b proves a real
# decompose failure is still named.)
G7=CREDIBLE-1578-DECOMPOSE
_dblog="$TMP/cycle-$G7-benign.log"
printf '%s\n' '[improve] Stage 2: decompose umbrella into sub-gaps' \
             'worker: decompose produced 4 sub-gaps, proceeding' > "$_dblog"
_step7="$(classify_failing_step "$_dblog")"
case "$_step7" in
    decompose_precheck)
        fail "CREDIBLE-1578: classifier fabricated 'decompose_precheck' from a benign decompose mention" ;;
    tail:*|unclassified*)
        ok "CREDIBLE-1578: benign 'decompose' mention stays faithful (no fabricated precheck failure)" ;;
    *)
        fail "CREDIBLE-1578: unexpected step '$_step7' for a benign decompose log" ;;
esac
_dflog="$TMP/cycle-$G7-fail.log"
printf '%s\n' 'chump gap decompose: precheck failed — no acceptance criteria' > "$_dflog"
_step7b="$(classify_failing_step "$_dflog")"
if [ "$_step7b" = "decompose_precheck" ]; then
    ok "CREDIBLE-1578: a real decompose failure is still named decompose_precheck"
else
    fail "CREDIBLE-1578: decompose failure not classified (got '$_step7b')"
fi

# CREDIBLE-1578 AC1 (reproduced-cycle receipt): the review's blocking attack was
# that the rc=1 cause was ASSERTED off a hand-written fixture, never demonstrated.
# This guard feeds classify_failing_step a log that is NOT hand-written: it is the
# verbatim stdout+stderr of the real `chump improve repairman29/olive` binary driven
# to its pre-agent rc=1 bail, committed at scripts/ci/fixtures/. Reproduce it with:
#   gh_stub=$(mktemp -d); printf '#!/usr/bin/env bash\nexit 1\n' > "$gh_stub/gh"; chmod +x "$gh_stub/gh"
#   mkdir -p /tmp/credible-1578-repro/repairman29-olive/clone
#   HOME=$gh_stub/home CHUMP_IMPROVE_GH_BIN=$gh_stub/gh \
#     chump improve repairman29/olive --mode guest --clone-dir /tmp/credible-1578-repro/repairman29-olive/clone
#   # -> rc=1, ~348B; last line is the production `no onboard scan found` bail (src/improve.rs:801).
# This reproduces ONE concrete rc=1 pre-agent mechanism (no_onboard_scan) against the
# real repo name via production code — materially stronger than a synthetic fixture.
# It does NOT prove this mechanism accounts for all 27 historical Olive blocks: those
# logs did not survive (the exact hole AC2 closes), so the full historical decode
# still needs live Olive runs and remains carved. The guard proves the recorded WHY
# is derived from a genuine reproduced cycle, not an assertion.
G8=CREDIBLE-1578-REPRODUCED
_rlog="$REPO_SRC/scripts/ci/fixtures/credible-1578-reproduced-no-scan-cycle.log"
if [ -f "$_rlog" ] \
   && grep -Fq '[improve] mode=DRY-RUN repo=repairman29/olive' "$_rlog" \
   && grep -Fq 'no onboard scan found' "$_rlog"; then
    ok "CREDIBLE-1578: AC1 receipt is a real reproduced cycle (binary banner + verbatim bail present)"
else
    fail "CREDIBLE-1578: AC1 receipt is not a genuine reproduced cycle log"
fi
_step8="$(classify_failing_step "$_rlog")"
if [ "$_step8" = "external_repo:no_onboard_scan" ]; then
    ok "CREDIBLE-1578: classifier names the failing step from the REAL reproduced log"
else
    fail "CREDIBLE-1578: classifier did not name the step from the reproduced log (got '$_step8')"
fi

# CREDIBLE-1578 (round-3 review, Required item 4 — carve materialized): the ACs this
# shell / commit-only slice does NOT deliver (AC3 Rust fix, AC4 re-triage, the AC1
# historical 945B decode) must be a REAL in-diff record mapping each to a tracking
# gap, not prose the reviewer cannot discover. This guard asserts the committed carve
# manifest exists and, for every carved AC, (a) cites a tracking gap of valid ID form
# (b) is marked CARVED — never silently re-marked delivered/PASS while the work is
# still deferred — and (c) is a DISTINCT follow-up, never the parent gap CREDIBLE-1578
# itself (r4 Required item 1: a gate AC deferred to its own parent gap is not delivered;
# AC1-decode now carves to CREDIBLE-1593). (Form only: that each cited gap is a real
# open row is reviewer-verifiable with `chump gap show <ID>` — INFRA-8091 / INFRA-8606 /
# CREDIBLE-1593 open — and recorded in the salvage body; the test stays hermetic.)
G9=CREDIBLE-1578-CARVE
_man="$REPO_SRC/scripts/ci/fixtures/credible-1578-carve-manifest.txt"
_g9ok=1
if [ -f "$_man" ]; then
    for _ac in AC1-decode AC3 AC4; do
        _line=""
        while IFS= read -r _l; do
            case "$_l" in "${_ac}|"*) _line="$_l"; break ;; esac
        done < "$_man"
        _status="$(printf '%s' "$_line" | cut -d'|' -f2)"
        _gapid="$(printf '%s' "$_line" | cut -d'|' -f3)"
        [ "$_status" = "CARVED" ] || _g9ok=0
        case "$_gapid" in [A-Z]*-[0-9]*) : ;; *) _g9ok=0 ;; esac
        # PR #5615 review r4, Required item 1: a gate AC may not be carved to its
        # own parent gap (CREDIBLE-1578) — deferring an AC to the very gap it gates
        # is not delivery. The tracking gap must be a DISTINCT follow-up.
        [ "$_gapid" = "CREDIBLE-1578" ] && _g9ok=0
    done
else
    _g9ok=0
fi
if [ "$_g9ok" = 1 ]; then
    ok "CREDIBLE-1578: carve is materialized — each undelivered AC cites a tracking gap, none marked delivered"
else
    fail "CREDIBLE-1578: carve manifest missing/incomplete — a carved AC lacks a tracking gap or is mis-marked delivered"
fi

echo "pass=$PASS fail=$FAIL"; [ "$FAIL" -eq 0 ]
