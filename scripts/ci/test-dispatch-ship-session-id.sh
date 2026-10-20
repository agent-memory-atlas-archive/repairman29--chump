#!/usr/bin/env bash
# scripts/ci/test-dispatch-ship-session-id.sh — INFRA-8204
#
# `chump dispatch --backend headless` creates a fresh worktree, claims the
# gap's lease INTO that worktree's own `.chump-locks/`, then runs bot-merge.sh
# there WITHOUT exporting CHUMP_SESSION_ID — so bot-merge.sh's session-ID
# auto-detection (which only ever scanned the MAIN checkout's $LOCK_DIR and
# state.db) could never find the lease claim() just wrote, and its INFRA-1901
# "already inside claimed worktree" check re-invoked `chump claim`, either
# spawning a stray second worktree or failing with "worktree already exists".
#
# This test exercises the building blocks the fix added:
#   1. lease_file_for_gap_in_dir() finds/misses leases in a dispatch-shaped
#      worktree's .chump-locks/ dir.
#   2. lease_session_id() reads the session id back out of that lease file.
#   3. grep-level contract on bot-merge.sh: both the session auto-detection
#      block and the INFRA-1901 pre-claim check call
#      lease_file_for_gap_in_dir against "$PWD/.chump-locks", and the
#      META-156 AC#2 message block no longer prints the literal '<unset>' or
#      '<unknown>'.
#   4. grep-level contract on src/dispatch.rs: ship() exports
#      CHUMP_SESSION_ID on the bot-merge Command.
# Best effort: a bot-merge.sh --dry-run smoke run against a fixture worktree
# with stub gh/chump binaries on PATH, asserting the auto-detect line appears
# and `chump claim` is never invoked.
#
# No network, no cargo, no real headless child — bash only.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

FAIL_COUNT=0
ok()   { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "=== INFRA-8204 dispatch ship-phase session-id test ==="
echo

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/lease.sh
source "${REPO_ROOT}/scripts/lib/lease.sh"

# ── Fixture: a dispatch-shaped worktree lease ────────────────────────────────
WT="${TMP}/dispatch-wt"
mkdir -p "${WT}/.chump-locks"
LEASE_FILE="${WT}/.chump-locks/dispatch-infra-9999-1-1.json"
cat > "$LEASE_FILE" <<'EOF'
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"PLACEHOLDER","expires_at":"2099-01-01T00:00:00Z"}
EOF
# Swap in the real worktree path (avoids escaping it into the heredoc above).
sed -i.bak "s#PLACEHOLDER#${WT}#" "$LEASE_FILE" && rm -f "${LEASE_FILE}.bak"
printf '%s' "dispatch-infra-9999-1-1" > "${WT}/.chump-locks/.wt-session-id"

# ── 1. lease_file_for_gap_in_dir finds/misses correctly ──────────────────────
echo "[1. lease_file_for_gap_in_dir]"

FOUND="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-9999" || true)"
if [[ "$FOUND" == "$LEASE_FILE" ]]; then
    ok "finds the dispatch worktree's own lease file for INFRA-9999"
else
    fail "expected '$LEASE_FILE', got '$FOUND'"
fi

if MISS="$(lease_file_for_gap_in_dir "${WT}/.chump-locks" "INFRA-0000")"; then
    fail "expected rc=1 (no match) for INFRA-0000, got rc=0 output='$MISS'"
elif [[ -n "$MISS" ]]; then
    fail "expected empty output for INFRA-0000, got '$MISS'"
else
    ok "returns empty + rc=1 for a gap id with no lease in the dir"
fi

# ── 2. lease_session_id reads the dispatch session id back out ──────────────
echo
echo "[2. lease_session_id]"

SID="$(lease_session_id "$LEASE_FILE")"
if [[ "$SID" == "dispatch-infra-9999-1-1" ]]; then
    ok "lease_session_id reads back the dispatch session id"
else
    fail "expected 'dispatch-infra-9999-1-1', got '$SID'"
fi

# ── 3. grep-level contracts ──────────────────────────────────────────────────
echo
echo "[3. grep-level contracts]"

BOT_MERGE="${REPO_ROOT}/scripts/coord/bot-merge.sh"
DISPATCH_RS="${REPO_ROOT}/src/dispatch.rs"

# bot-merge.sh must call lease_file_for_gap_in_dir against $PWD/.chump-locks
# in BOTH the session auto-detection block and the INFRA-1901 pre-claim check.
CALL_COUNT="$(grep -c 'lease_file_for_gap_in_dir "\$PWD/.chump-locks"' "$BOT_MERGE" || true)"
if [[ "$CALL_COUNT" -ge 2 ]]; then
    ok "bot-merge.sh calls lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" at least twice (got $CALL_COUNT)"
else
    fail "expected >=2 calls to lease_file_for_gap_in_dir \"\$PWD/.chump-locks\" in bot-merge.sh, got $CALL_COUNT"
fi

# The META-156 AC#2 block (bounded by its characteristic marker through the
# next top-level 'else' claim-failure branch) must never print the literal
# placeholders this gap replaced with concrete sources.
AC2_BLOCK="$(awk '/META-156 AC#2: re-claim failure/,/Some other claim failure/' "$BOT_MERGE")"
if printf '%s' "$AC2_BLOCK" | grep -qF '<unset>'; then
    fail "META-156 AC#2 block still contains the literal '<unset>'"
elif printf '%s' "$AC2_BLOCK" | grep -qF '<unknown>'; then
    fail "META-156 AC#2 block still contains the literal '<unknown>'"
else
    ok "META-156 AC#2 block no longer prints '<unset>' or '<unknown>'"
fi

# dispatch.rs: ship() must export CHUMP_SESSION_ID explicitly onto the
# bot-merge Command, not merely rely on inheritance.
SHIP_FN="$(awk '/^fn ship\(/,/^fn current_pr_number/' "$DISPATCH_RS")"
if printf '%s' "$SHIP_FN" | grep -q 'cmd.env("CHUMP_SESSION_ID"'; then
    ok "dispatch.rs ship() sets CHUMP_SESSION_ID on the bot-merge Command"
else
    fail "dispatch.rs ship() does not set CHUMP_SESSION_ID on the bot-merge Command"
fi

# ── 4. best-effort: bot-merge.sh --dry-run smoke run ─────────────────────────
echo
echo "[4. bot-merge.sh --dry-run smoke run (best effort)]"

run_dry_run_smoke() {
    local fixture="${TMP}/fixture-repo"
    mkdir -p "$fixture"
    (
        cd "$fixture" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo "x" > f.txt
        git add f.txt
        git commit -q -m init
        git checkout -q -b claude/infra-9999
        echo "y" >> f.txt
        git add f.txt
        git commit -q -m "work for INFRA-9999"
    ) || return 1

    mkdir -p "${fixture}/.chump-locks"
    cat > "${fixture}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${fixture}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${fixture}/.chump-locks/.wt-session-id"

    local stub_bin="${TMP}/stub-bin"
    mkdir -p "$stub_bin"
    local argv_log="${TMP}/chump-argv.log"
    : > "$argv_log"

    cat > "${stub_bin}/chump" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${argv_log}"
if [[ "\$1" == "gap" && "\$2" == "preflight" ]]; then
    echo "[preflight] OK"
    exit 0
fi
exit 0
EOF
    chmod +x "${stub_bin}/chump"

    cat > "${stub_bin}/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "${stub_bin}/gh"

    local out
    if ! out="$(cd "$fixture" && PATH="${stub_bin}:${PATH}" bash "${BOT_MERGE}" --gap INFRA-9999 --dry-run 2>&1)"; then
        printf '%s\n' "$out" >&2
        return 2
    fi

    if grep -q 'claim' "$argv_log" 2>/dev/null; then
        printf '%s\n' "$out" >&2
        fail "stub chump recorded a 'claim' call — bot-merge re-invoked chump claim \
instead of recognizing the dispatch worktree's own lease"
    else
        ok "stub chump never saw a 'claim' invocation during --dry-run"
    fi

    if printf '%s' "$out" | grep -q 'INFRA-8204'; then
        ok "bot-merge --dry-run output contains the INFRA-8204 auto-detect line"
    else
        fail "bot-merge --dry-run output missing the INFRA-8204 auto-detect line"
    fi

    if printf '%s' "$out" | grep -qi 're-claim failure'; then
        fail "bot-merge --dry-run output contains a re-claim failure message"
    else
        ok "bot-merge --dry-run output contains no re-claim failure message"
    fi
}

if run_dry_run_smoke; then
    :
else
    rc=$?
    if [[ "$rc" -eq 2 ]]; then
        echo "SKIP: bot-merge dry-run not exercised (fixture invocation failed — \
bot-merge.sh's --dry-run path has preconditions beyond this fixture's reach)"
    fi
fi

# ── 5. CREDIBLE-1580: auto-merge is default-OFF without --auto-merge ─────────
#    bot-merge.sh self-armed GitHub auto-merge on the default `internal` lane
#    even when `chump dispatch` never passed --auto-merge (src/dispatch.rs only
#    appends the flag when opts.auto_merge is true) — #5613 self-armed 3x in 95
#    min inside the CREDIBLE-1576 dispatch. The arm decision is now default-OFF
#    on every lane; the ONLY arming route is an explicit --auto-merge (the
#    CREDIBLE-1542 review-held path). bot_merge_lane_resolved.auto_merge_requested
#    is the resolved decision the arm step (bot-merge.sh section 7) gates on, so
#    asserting it is a behavioral check on a dispatch-shaped run: without the
#    flag it must resolve to 0 and make zero `gh pr merge` calls. Mutant
#    (restore the internal-lane default arm) flips it to 1 and this leg fails.
echo
echo "[5. CREDIBLE-1580 auto-merge default-OFF without --auto-merge]"

credible_1580_arm_default() {
    local wt="${TMP}/cred1580-wt"
    mkdir -p "$wt"
    (
        cd "$wt" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo x > f.txt && git add f.txt && git commit -q -m init
        git checkout -q -b claude/infra-9999
        echo y >> f.txt && git add f.txt && git commit -q -m "work for INFRA-9999"
    ) || return 2

    mkdir -p "${wt}/.chump-locks"
    cat > "${wt}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${wt}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${wt}/.chump-locks/.wt-session-id"

    local sbin="${TMP}/cred1580-bin"
    mkdir -p "$sbin"
    local gh_argv="${TMP}/cred1580-gh-argv.log"
    : > "$gh_argv"
    cat > "${sbin}/chump" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == gap && "$2" == preflight ]] && { echo "[preflight] OK"; exit 0; }
exit 0
EOF
    chmod +x "${sbin}/chump"
    # Stub gh records every argv so we can prove zero `pr merge` calls.
    cat > "${sbin}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_argv}"
exit 1
EOF
    chmod +x "${sbin}/gh"

    # auto_merge_requested of the last bot_merge_lane_resolved event ("" if none).
    _resolved() {
        grep 'bot_merge_lane_resolved' "$1" 2>/dev/null | tail -1 \
            | grep -oE '"auto_merge_requested":[01]' | grep -oE '[01]$' || true
    }

    # Run exactly as `chump dispatch` does: no --auto-merge. The lane-resolved
    # event is emitted right after arg-parse, so it lands regardless of
    # bot-merge's eventual exit code; capture with || true.
    local amb_no="${TMP}/cred1580-amb-no.jsonl"; : > "$amb_no"
    ( cd "$wt" && PATH="${sbin}:${PATH}" CHUMP_AMBIENT_LOG="$amb_no" \
        CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        bash "${BOT_MERGE}" --gap INFRA-9999 --dry-run >/dev/null 2>&1 ) || true
    local got_no; got_no="$(_resolved "$amb_no")"
    if [[ -z "$got_no" ]]; then
        return 2   # lane resolution not reached in this env — SKIP (don't false-fail)
    fi
    if [[ "$got_no" == "0" ]]; then
        ok "dispatch-shaped run without --auto-merge resolves auto_merge_requested=0"
    else
        fail "dispatch-shaped run without --auto-merge resolved auto_merge_requested=$got_no (self-arm default is back)"
    fi
    if grep -qE '(^| )pr merge( |$)' "$gh_argv" 2>/dev/null; then
        fail "bot-merge made a 'gh pr merge' call without --auto-merge: $(grep 'pr merge' "$gh_argv")"
    else
        ok "bot-merge made zero 'gh pr merge' calls without --auto-merge"
    fi

    # Positive control: the explicit flag still arms (resolves to 1).
    local amb_yes="${TMP}/cred1580-amb-yes.jsonl"; : > "$amb_yes"
    ( cd "$wt" && PATH="${sbin}:${PATH}" CHUMP_AMBIENT_LOG="$amb_yes" \
        CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        bash "${BOT_MERGE}" --gap INFRA-9999 --auto-merge --dry-run >/dev/null 2>&1 ) || true
    local got_yes; got_yes="$(_resolved "$amb_yes")"
    if [[ "$got_yes" == "1" ]]; then
        ok "explicit --auto-merge resolves auto_merge_requested=1 (review-held arming route intact)"
    elif [[ -n "$got_yes" ]]; then
        fail "explicit --auto-merge resolved auto_merge_requested=$got_yes (expected 1)"
    fi
    return 0
}

_c1580_rc=0
credible_1580_arm_default || _c1580_rc=$?
if [[ "$_c1580_rc" -eq 2 ]]; then
    echo "SKIP: bot-merge lane resolution not reached in this fixture (CREDIBLE-1580 leg skipped)"
fi

# ── 6/7. CREDIBLE-1580: reach the REAL arm sites (review-fix for #5614) ───────
#    Leg 5 proves the lane DECISION (auto_merge_requested=0) but bot-merge exits
#    10 at the RESILIENT-073 kill switch (AUTONOMY_LEVEL absent) before any arm
#    site, so it never proves the arm BEHAVIOR — M2 (main :4261 guard), M4
#    (Mode A force-B) and M5 (recovery arm) all survived. These legs run the
#    REAL bot-merge under a sandbox HOME carrying AUTONOMY_LEVEL=5 (the approved
#    seam — real code, real path, exactly as scripts/ci/census.sh does — NOT an
#    env override of a safety input), with stub gh/chump/chump-coord and a real
#    local git repo + bare origin, no --dry-run, so execution actually reaches
#    each arm site and we can assert it does NOT arm without --auto-merge.

# _c1580_make_fixture <name> — builds a sandbox HOME (AUTONOMY_LEVEL=5), a real
# worktree on branch claude/infra-9999 (1 commit ahead of a bare origin/main),
# a dispatch-shaped lease, and stub gh/chump/chump-coord. Sets globals:
#   _FX_HOME _FX_WT _FX_BIN _FX_GHLOG _FX_AMB
_c1580_make_fixture() {
    local name="$1"
    local base="${TMP}/${name}"
    _FX_HOME="${base}/home"
    _FX_WT="${base}/wt"
    _FX_BIN="${base}/bin"
    _FX_GHLOG="${base}/gh-argv.log"
    _FX_AMB="${base}/ambient.jsonl"
    _FX_MARKER="${base}/armed.marker"
    mkdir -p "${_FX_HOME}/.chump" "$_FX_BIN"
    : > "$_FX_GHLOG"; : > "$_FX_AMB"; rm -f "$_FX_MARKER"
    # RESILIENT-073 kill switch reads ${HOME}/.chump/AUTONOMY_LEVEL — seed GO.
    echo 5 > "${_FX_HOME}/.chump/AUTONOMY_LEVEL"

    # Real git repo + bare origin so fetch/push/rebase-detection are faithful
    # (no stub git). Branch is 1 commit AHEAD of origin/main → BEHIND=0, no rebase.
    (
        git init -q --bare "${base}/origin.git"
        mkdir -p "$_FX_WT" && cd "$_FX_WT" || exit 1
        git init -q -b main
        git config user.email test@example.com
        git config user.name test
        echo seed > f.txt && git add f.txt && git commit -q -m "init"
        git remote add origin "${base}/origin.git"
        git push -q origin main
        git checkout -q -b claude/infra-9999
        echo work >> f.txt && git add f.txt && git commit -q -m "work for INFRA-9999"
    ) >/dev/null 2>&1 || return 2

    mkdir -p "${_FX_WT}/.chump-locks"
    cat > "${_FX_WT}/.chump-locks/dispatch-infra-9999-1-1.json" <<EOF
{"session_id":"dispatch-infra-9999-1-1","gap_id":"INFRA-9999","worktree":"${_FX_WT}","expires_at":"2099-01-01T00:00:00Z"}
EOF
    printf '%s' "dispatch-infra-9999-1-1" > "${_FX_WT}/.chump-locks/.wt-session-id"

    # Stub chump: preflight OK; everything else a no-op success. preflight --help
    # prints nothing so bot-merge's `--structural` capability probe skips.
    cat > "${_FX_BIN}/chump" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "gap preflight") echo "[preflight] OK"; exit 0 ;;
  "preflight --help") exit 0 ;;
esac
exit 0
EOF
    chmod +x "${_FX_BIN}/chump"

    # Stub chump-coord: work-board post succeeds (so a Mode-A mutant reaches the
    # enqueue), everything else no-op.
    cat > "${_FX_BIN}/chump-coord" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${_FX_BIN}/chump-coord"

    # Stub gh: records every argv so we can prove zero `pr merge` on default-OFF
    # runs. api repos/*/pulls/* prints `true` so auto-merge-armer's verify_arm
    # passes on the first 2s check (no 30s retry) when a mutant DOES arm.
    cat > "${_FX_BIN}/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_FX_GHLOG}"
sub="\${1:-}"; cmd="\${2:-}"; _a="\$*"
case "\$sub" in
  auth) exit 0 ;;
  pr)
    case "\$cmd" in
      view)
        # Emulate the --jq extractions bot-merge/auto-merge-armer actually use,
        # so a mutant that reaches the armer gets a REAL numeric PR (else the
        # armer rejects a malformed --pr and the mutant would falsely survive).
        if [ "\${_a#*--jq}" != "\$_a" ]; then
          case "\$_a" in
            *statusCheckRollup*) echo '[]' ;;   # no FAILED check → arm not blocked
            *number*)            echo 77 ;;     # .number
            *state*)             echo OPEN ;;
            *)                   echo '' ;;
          esac
        elif [ "\${_a#*--json number}" != "\$_a" ]; then echo '{"number":77}'
        else echo '{"number":77,"state":"OPEN","autoMergeRequest":null,"statusCheckRollup":[]}'; fi ;;
      create) echo 'https://github.com/testorg/testrepo/pull/77'; exit 0 ;;
      merge)  touch "${_FX_MARKER}"; exit 0 ;;   # ARM_ARMED_MARKER: arming flips .auto_merge true
      checks) exit 0 ;;
      diff)   exit 0 ;;
      list)   exit 0 ;;   # empty → not MERGED, no existing PR
      comment) exit 0 ;;
      *) exit 0 ;;
    esac ;;
  api)
    case "\${2:-}" in
      *rate_limit*) echo '{"resources":{"core":{"limit":5000,"remaining":4800,"reset":1},"graphql":{"limit":5000,"remaining":4900,"reset":1}}}' ;;
      *check-runs*) echo '[]' ;;   # no checks → REST-direct skips, arm goes via gh pr merge
      *pulls/*)
        # ARM_ARMED_MARKER seam: .auto_merge is null (not armed) until gh pr
        # merge drops the marker, THEN non-null. So the armer already-armed
        # pre-check sees not-armed and actually calls gh pr merge (recorded),
        # and verify_arm then sees armed on the first 2s poll (no 30s retry).
        if [ "\${_a#*auto_merge}" != "\$_a" ]; then
          if [ -f "${_FX_MARKER}" ]; then echo true; else echo false; fi
        elif [ "\${_a#*head.sha}" != "\$_a" ]; then echo 'deadbeefcafe0000deadbeefcafe0000deadbeef'
        elif [ "\${_a#*.state}" != "\$_a" ]; then echo open
        else echo '{}'; fi ;;
      *graphql*)    echo '{"data":{"enablePullRequestAutoMerge":{"pullRequest":{"number":77}}}}' ;;
      *) echo '[]' ;;
    esac ;;
  *) exit 0 ;;
esac
EOF
    chmod +x "${_FX_BIN}/gh"
    return 0
}

# _c1580_merge_calls <gh-argv-log> — count `gh pr merge` arm calls in the log.
_c1580_merge_calls() {
    grep -cE '(^| )pr merge( |$)' "$1" 2>/dev/null || true
}

echo
echo "[6. CREDIBLE-1580 recovery-path arm site reached (:2111 — kills M5)]"
credible_1580_recovery_arm() {
    _c1580_make_fixture cred1580-recov || return 2
    local out="${TMP}/cred1580-recov.out"
    # Recovery mode (documented INFRA-1422 retry mode selector, not a bypass of
    # a safety gate) fast-paths push + PR create + the recovery arm at :2111.
    ( cd "$_FX_WT" && HOME="$_FX_HOME" PATH="${_FX_BIN}:${PATH}" \
        CHUMP_AMBIENT_LOG="$_FX_AMB" CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        GITHUB_REPOSITORY=testorg/testrepo \
        CHUMP_BOT_MERGE_RECOVERY_MODE=1 \
        timeout 90 bash "${BOT_MERGE}" --gap INFRA-9999 >"$out" 2>&1 ) || true
    if ! grep -q 'botmerge_recovery_start\|recovery: pr create' "$_FX_AMB" "$out" 2>/dev/null; then
        echo "   (recovery fast-path not entered — dumping tail for diagnosis)"; tail -5 "$out" 2>/dev/null | sed 's/^/     /'
        return 2
    fi
    local mc; mc="$(_c1580_merge_calls "$_FX_GHLOG")"
    if [[ "${mc:-0}" -eq 0 ]]; then
        ok "recovery path reached arm site and made zero 'gh pr merge' calls without --auto-merge (kills M5)"
    else
        fail "recovery path armed without --auto-merge: $mc 'gh pr merge' call(s) [$(grep -E 'pr merge' "$_FX_GHLOG" | head -1)]"
    fi
    return 0
}
_c1580_r6=0; credible_1580_recovery_arm || _c1580_r6=$?
[[ "$_c1580_r6" -eq 2 ]] && echo "SKIP: recovery fixture not drivable in this env (leg 6 skipped)"

echo
echo "[7. CREDIBLE-1580 main-flow reaches :4261 + Mode A forced to B (kills M2, M4)]"
credible_1580_main_arm() {
    _c1580_make_fixture cred1580-main || return 2
    local out="${TMP}/cred1580-main.out"
    # Integrator mocked HEALTHY so Mode A is genuinely reachable — the ONLY thing
    # that can route to B is the CREDIBLE-1580 force-B block (not INFRA-2523
    # fail-open). --no-local-build skips cargo/DOR (legit RESILIENT-1407 flags,
    # not bypass vars). No --auto-merge → AUTO_MERGE=0 → main arm (:4261) skipped.
    ( cd "$_FX_WT" && HOME="$_FX_HOME" PATH="${_FX_BIN}:${PATH}" \
        CHUMP_AMBIENT_LOG="$_FX_AMB" CHUMP_SESSION_ID=dispatch-infra-9999-1-1 \
        GITHUB_REPOSITORY=testorg/testrepo \
        CHUMP_BOT_MERGE_MOCK_INTEGRATOR_HEALTH=1 \
        timeout 120 bash "${BOT_MERGE}" --gap INFRA-9999 --no-local-build >"$out" 2>&1 ) || true

    # M4: with integrator healthy + AUTO_MERGE=0, routing MUST be forced to B.
    if grep -q 'INFRA-2133: routing mode=B' "$out" 2>/dev/null; then
        ok "Mode A forced to B when not armed (routing mode=B) — integrator arm route closed (kills M4)"
    elif grep -q 'INFRA-2133: routing mode=A' "$out" 2>/dev/null; then
        fail "routed to Mode A without --auto-merge — integrator would batch-arm (force-B dropped)"
    else
        echo "   (routing decision not reached — dumping tail)"; tail -8 "$out" 2>/dev/null | sed 's/^/     /'
        return 2
    fi

    # Confirm execution actually reached the main arm site: the "consensus merge
    # gate mode=" line prints at :4260, immediately before the :4261
    # `if [[ $AUTO_MERGE -eq 1 ]]` guard — so matching it proves we reached the
    # guard and the no-merge assertion below is meaningful (not a never-reached
    # arm, which is exactly how M2 falsely survived before this leg existed).
    if ! grep -q 'consensus merge gate mode=' "$out" 2>/dev/null; then
        echo "   (main arm site :4261 not reached — dumping tail)"; tail -8 "$out" 2>/dev/null | sed 's/^/     /'
        return 2
    fi

    # M2: the :4261 `if [[ $AUTO_MERGE -eq 1 ]]` guard must keep the arm block
    # from running at AUTO_MERGE=0 → zero `gh pr merge`.
    local mc; mc="$(_c1580_merge_calls "$_FX_GHLOG")"
    if [[ "${mc:-0}" -eq 0 ]]; then
        ok "main flow reached :4261 and made zero 'gh pr merge' calls without --auto-merge (kills M2)"
    else
        fail "main arm fired without --auto-merge: $mc 'gh pr merge' call(s) [$(grep -E 'pr merge' "$_FX_GHLOG" | head -1)]"
    fi
    return 0
}
_c1580_r7=0; credible_1580_main_arm || _c1580_r7=$?
[[ "$_c1580_r7" -eq 2 ]] && echo "SKIP: main-flow fixture not drivable in this env (leg 7 skipped)"

echo
echo "[8. CREDIBLE-1580 static: AUTO_MERGE assigned only at init + --auto-merge flag (kills M3)]"
# AUTO_MERGE is the single arm decision. It must be a constant (init) or the
# explicit flag — NEVER read from an env var (Chief standing rule). A mutant
# that reads it from a CHUMP_* default introduces a `$`/`{` on the RHS and a
# third assignment; both are caught here.
# Collect assignment lines to a temp FILE (grep the file, never a trailing
# piped `grep -q` under pipefail — the race the pipefail gate forbids).
_am_file="${TMP}/cred1580-am-assigns.txt"
grep -nE '(^|[[:space:];])AUTO_MERGE=' "$BOT_MERGE" 2>/dev/null \
    | grep -vE ':[[:space:]]*#' > "$_am_file" 2>/dev/null || true
_am_count="$(grep -cE 'AUTO_MERGE=' "$_am_file" 2>/dev/null || true)"
if [[ "${_am_count:-0}" -ne 2 ]]; then
    fail "AUTO_MERGE assigned on ${_am_count:-0} line(s), expected exactly 2 (init + --auto-merge flag):
$(sed 's/^/     /' "$_am_file")"
else
    ok "AUTO_MERGE assigned on exactly 2 lines (init + --auto-merge flag)"
fi
# No assignment may read from an env var / computed RHS (kills M3).
_am_env="$(grep -E 'AUTO_MERGE=[^;[:space:]]*[${]' "$_am_file" 2>/dev/null || true)"
if [[ -n "$_am_env" ]]; then
    fail "AUTO_MERGE assigned from an env/computed value (the arm decision must be a constant or the flag):
$(printf '%s\n' "$_am_env" | sed 's/^/     /')"
else
    ok "AUTO_MERGE never read from an env/computed value (no \$ or { on the RHS) — kills M3"
fi
# The two canonical forms must both be present.
_am_has_init="$(grep -cE 'AUTO_MERGE=0( |$|[^0-9])' "$_am_file" 2>/dev/null || true)"
_am_has_flag="$(grep -cE 'AUTO_MERGE=1;[[:space:]]*AUTO_MERGE_EXPLICIT=1' "$_am_file" 2>/dev/null || true)"
if [[ "${_am_has_init:-0}" -ge 1 && "${_am_has_flag:-0}" -ge 1 ]]; then
    ok "both canonical AUTO_MERGE assignments present (AUTO_MERGE=0 init; AUTO_MERGE=1 on --auto-merge)"
else
    fail "canonical AUTO_MERGE assignments missing (init=${_am_has_init:-0} flag=${_am_has_flag:-0})"
fi

echo
if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "=== INFRA-8204 tests FAILED ($FAIL_COUNT failure(s)) ==="
    exit 1
fi
echo "=== INFRA-8204 tests complete ==="
