#!/usr/bin/env bash
# scripts/ci/test-resilient-1636-farmer-gate-ship-wall.sh — RESILIENT-1636
#
# The cuphead ship wall: on a paused Linux node, bot-merge's re-claim of work a
# dispatch already holds died at the farmer RED gate (stale ~/.chump/oauth-token.json
# mirror mtime + stale heartbeat), so every dispatch shipped only through salvage.
#
# This fixture reproduces that exact host state hermetically — a PAUSED farmer
# (node.env CHUMP_NODE_MODE=paused), a STALE heartbeat, a STALE oauth-token.json
# mirror, and a VALID ~/.claude credential (the path claude -p actually uses),
# in a non-login shell with no mirror refresher — and proves the invariant:
#
#   AC1  a gap whose dispatch ALREADY holds the claim is ADMITTED past the
#        farmer gate (bot-merge reaches the push step), proven by `chump claim`
#        printing the re-entry admission instead of refusing.
#   AC2  the gate is NOT weakened: a NEW claim (no live lease for that session)
#        is still refused, printing "no new claims admitted".
#   AC3  the farmer oauth check reads OK from the credential path claude -p uses
#        (valid ~/.claude/.credentials.json) even with a STALE mirror — the
#        mirror mtime is never consulted (RESILIENT-086, CREDIBLE-147).
#   AC(b) a paused farmer is reported PAUSED, not stale.
#   AC6  no automated caller uses --skip-farmer-gate (grep gate).
#
# Independent-review hardening (RESILIENT-1636): a ship gate relaxes ONLY for a
# deliberately-paused node, and pause excuses ONLY the (expected) stale
# heartbeat — every genuinely-RED case still refuses even with a live lease:
#   RED1  unpaused node + stale heartbeat + live session lease → refuse (RED).
#   RED2  paused + <repo>/.chump/fleet-paused sentinel + live lease → refuse.
#   RED3  paused + fresh auth-status cache rc=1 (probed BROKEN) + live lease → refuse.
#   RED4  the AC3 GREEN check, repeated with an EXPIRED non-refreshable
#         .credentials.json, must NOT be GREEN (dead credential still reds).
#   MAL   CHIEF RULE 8 — a lease with missing OR unparseable expires_at is
#         MALFORMED (not live) and refuses with its own distinct reason.
#
# Zero network. Pure local: chump binary + git + python3 (for mtime back-dating).

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }

# Resolve the binary the way the fast-checks steps do (precedent:
# test-resilient-1614-node-pause-invariant.sh). An explicit CHUMP_BIN is honored
# as-is; otherwise we target the cargo debug binary AND always (re)build it so we
# exercise THIS branch's chump — never a stale target/debug/chump left over from
# main. (The cuphead ship-wall: bot-merge's local citest ran a stale binary that
# predated `farmer status --json`'s `paused`/`green`/`oauth_fresh` fields, and the
# fixture died with a Python KeyError instead of a clear FAIL. `cargo build` is a
# cheap no-op when the binary is already up to date with the branch sources.)
CHUMP_BIN_DEFAULT="${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump"
CHUMP_BIN="${CHUMP_BIN:-$CHUMP_BIN_DEFAULT}"
if [ "$CHUMP_BIN" = "$CHUMP_BIN_DEFAULT" ]; then
    ( cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump ) \
        || fail "cargo build --bin chump failed"
fi
[ -x "$CHUMP_BIN" ] || fail "CHUMP_BIN not found or not executable: $CHUMP_BIN"

# Non-login Linux shell: no launchctl (Linux), stub it + systemctl empty so the
# exit-78 / node-pause supervisor scans stay hermetic on any runner.
STUB="$TMP/stub"; mkdir -p "$STUB"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/launchctl"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/systemctl"
chmod +x "$STUB/launchctl" "$STUB/systemctl"

# back-date a file's mtime by N seconds (portable).
backdate() { python3 -c "import os,sys,time; t=time.time()-int(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }

# ── Build the cuphead ship-wall fixture ──────────────────────────────────────
REPO="$TMP/repo"; HOMEDIR="$TMP/home"; STATE="$TMP/state"
mkdir -p "$REPO/.chump" "$REPO/.chump-locks" "$HOMEDIR/.chump" "$HOMEDIR/.claude" "$STATE"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@e.com
git -C "$REPO" config user.name T
git -C "$REPO" commit -q --allow-empty -m init

# PAUSED farmer: node.env says paused (chump node pause's durable signal).
printf 'export CHUMP_NODE_MODE=paused\n' > "$STATE/node.env"
# STALE heartbeat: the farmer daemon is idle because it is paused.
printf 'x\n' > "$REPO/.chump/farmer-heartbeat"; backdate "$REPO/.chump/farmer-heartbeat" 80000
# STALE oauth-token.json mirror: the macOS-only refresher never ran on Linux.
printf '{"accessToken":"old"}\n' > "$HOMEDIR/.chump/oauth-token.json"; backdate "$HOMEDIR/.chump/oauth-token.json" 80000
# VALID ~/.claude credential: the path claude -p actually reads (future expiry).
printf '{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}\n' \
    > "$HOMEDIR/.claude/.credentials.json"

# Env a dispatch's bot-merge re-claim runs under on cuphead. CHUMP_REPO pins the
# repo root (wins over the chumpd socket), CHUMP_HOME feeds the oauth reads,
# CHUMP_STATE_DIR locates node.env. No API key / oauth-token env / auth cache.
run_chump() {
    env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
        CHUMP_REPO="$REPO" CHUMP_HOME="$HOMEDIR" CHUMP_STATE_DIR="$STATE" \
        "$@"
}

# ── AC(b) + AC3: farmer status reports PAUSED, oauth reads OK ─────────────────
STATUS_JSON="$(run_chump "$CHUMP_BIN" farmer status --json 2>/dev/null)" || true
python3 - "$STATUS_JSON" <<'PY' || fail "farmer status did not report PAUSED + oauth_fresh"
import json,sys
raw=sys.argv[1]
try:
    s=json.loads(raw)
except Exception as e:
    # Loud failure instead of a bare traceback: an empty/garbage payload means
    # `farmer status --json` errored or the binary is stale (see the build note).
    sys.exit(f"farmer status --json did not emit valid JSON ({e!r}); raw payload: {raw!r}")
for k in ("paused","green","oauth_fresh"):
    if k not in s:
        sys.exit(f"farmer status --json is missing key {k!r} — stale chump binary "
                 f"lacking this field? got: {s}")
assert s["paused"] is True, f"paused should be True: {s}"
assert s["green"] is False, f"green should be False (paused is not lights-on): {s}"
assert s["oauth_fresh"] is True, f"oauth_fresh should be True (valid ~/.claude creds, stale mirror ignored): {s}"
PY
ok "AC(b)/AC3: farmer status PAUSED, green=false, oauth_fresh=true (stale mirror ignored)"

# A paused farmer is reported PAUSED, not stale.
STATUS_TXT="$(run_chump "$CHUMP_BIN" farmer status 2>/dev/null)" || true
grep -q 'PAUSED' <<<"$STATUS_TXT" || fail "farmer status text should say PAUSED: $STATUS_TXT"
grep -qi 'paused by node mode' <<<"$STATUS_TXT" || fail "status should cite node-mode pause: $STATUS_TXT"
grep -qi 'heartbeat stale' <<<"$STATUS_TXT" && fail "paused farmer must NOT report 'heartbeat stale': $STATUS_TXT"
ok "AC(b): paused farmer reported PAUSED, not stale"

# ── AC1: re-entry of already-claimed work reaches the push step ──────────────
# The dispatch already holds the lease for GAP-RE-1 under session sess-A.
cat > "$REPO/.chump-locks/sess-A.json" <<'JSON'
{"session_id":"sess-A","gap_id":"GAP-RE-1","expires_at":"2999-01-01T00:00:00Z","paths":[]}
JSON
REENTRY_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)" || true
grep -qi 'admitting re-entry' <<<"$REENTRY_OUT" \
    || fail "re-entry claim was NOT admitted past the farmer gate: $REENTRY_OUT"
grep -qi 'no new claims admitted' <<<"$REENTRY_OUT" \
    && fail "re-entry claim was refused by the farmer gate (ship wall not fixed): $REENTRY_OUT"
ok "AC1: dispatch-held gap admitted past the farmer gate (bot-merge reaches push)"

# ── AC2: the gate is NOT weakened — a NEW claim is still refused ──────────────
# Same paused farmer, same session, but NO live lease for GAP-NEW-2.
NEW_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-NEW-2 --role fleet-worker --skip-doctor --skip-import 2>&1)"; NEW_RC=$?
grep -qi 'no new claims admitted' <<<"$NEW_OUT" \
    || fail "NEW claim should be refused by the farmer gate: $NEW_OUT"
grep -qi 'PAUSED' <<<"$NEW_OUT" || fail "refusal should name the PAUSED state: $NEW_OUT"
[ "$NEW_RC" -ne 0 ] || fail "NEW claim should exit non-zero when refused (rc=$NEW_RC)"
ok "AC2: NEW claim still refused under the paused farmer (gate not weakened)"

# A new claim with NO session at all is likewise refused.
NOSESS_OUT="$(run_chump "$CHUMP_BIN" claim GAP-RE-1 --role fleet-worker --skip-doctor --skip-import 2>&1)" || true
grep -qi 'no new claims admitted' <<<"$NOSESS_OUT" \
    || fail "claim with no CHUMP_SESSION_ID should be refused: $NOSESS_OUT"
ok "AC2: claim with no session is refused (no re-entry anchor)"

# ── CHIEF RULE 8: a lease with missing OR unparseable expires_at is MALFORMED ─
# (not live) and refuses with its own distinct reason — even on a paused,
# otherwise-healthy farmer where a GOOD live lease would have been admitted.
cat > "$REPO/.chump-locks/sess-M.json" <<'JSON'
{"session_id":"sess-M","gap_id":"GAP-MAL-1","paths":[]}
JSON
MAL_OUT="$(run_chump CHUMP_SESSION_ID=sess-M "$CHUMP_BIN" claim GAP-MAL-1 --role bot-merge --skip-doctor --skip-import 2>&1)"; MAL_RC=$?
grep -qi 'no new claims admitted' <<<"$MAL_OUT" || fail "lease missing expires_at must refuse: $MAL_OUT"
grep -qi 'admitting re-entry'    <<<"$MAL_OUT" && fail "malformed lease must NOT admit re-entry: $MAL_OUT"
grep -qi 'lease malformed'       <<<"$MAL_OUT" || fail "refusal should cite the malformed-lease reason: $MAL_OUT"
[ "$MAL_RC" -ne 0 ] || fail "missing-expires_at claim should exit non-zero (rc=$MAL_RC)"
ok "CHIEF RULE 8: lease with missing expires_at is not live (malformed) → refused"

cat > "$REPO/.chump-locks/sess-U.json" <<'JSON'
{"session_id":"sess-U","gap_id":"GAP-MAL-2","expires_at":"not-a-date","paths":[]}
JSON
UNP_LEASE_OUT="$(run_chump CHUMP_SESSION_ID=sess-U "$CHUMP_BIN" claim GAP-MAL-2 --role bot-merge --skip-doctor --skip-import 2>&1)"; UNP_LEASE_RC=$?
grep -qi 'no new claims admitted' <<<"$UNP_LEASE_OUT" || fail "lease with unparseable expires_at must refuse: $UNP_LEASE_OUT"
grep -qi 'admitting re-entry'    <<<"$UNP_LEASE_OUT" && fail "unparseable-lease must NOT admit re-entry: $UNP_LEASE_OUT"
grep -qi 'lease malformed'       <<<"$UNP_LEASE_OUT" || fail "refusal should cite the malformed-lease reason: $UNP_LEASE_OUT"
[ "$UNP_LEASE_RC" -ne 0 ] || fail "unparseable-expires_at claim should exit non-zero (rc=$UNP_LEASE_RC)"
ok "CHIEF RULE 8: lease with unparseable expires_at is not live (malformed) → refused"
rm -f "$REPO/.chump-locks/sess-M.json" "$REPO/.chump-locks/sess-U.json"

# ── RESILIENT-1636: paused + <repo>/.chump/fleet-paused sentinel + live lease ─
# must still REFUSE. A paused node may excuse only its stale heartbeat; the
# fleet-paused sentinel is a genuine RED that re-entry does NOT relax.
touch "$REPO/.chump/fleet-paused"
SENT_OUT="$(run_chump CHUMP_SESSION_ID=sess-A "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)"; SENT_RC=$?
grep -qi 'no new claims admitted' <<<"$SENT_OUT" || fail "paused + fleet-paused sentinel + live lease must refuse: $SENT_OUT"
grep -qi 'admitting re-entry'    <<<"$SENT_OUT" && fail "fleet-paused sentinel must NOT admit re-entry: $SENT_OUT"
[ "$SENT_RC" -ne 0 ] || fail "sentinel-present claim should exit non-zero (rc=$SENT_RC)"
ok "RESILIENT-1636: paused + fleet-paused sentinel + live lease → refused (genuine RED, not heartbeat)"
rm -f "$REPO/.chump/fleet-paused"

# ── AC3 (positive GREEN): valid creds + stale mirror ⇒ GREEN when not paused ─
REPO2="$TMP/repo2"; STATE2="$TMP/state2"
mkdir -p "$REPO2/.chump" "$REPO2/.chump-locks" "$STATE2"
git -C "$REPO2" init -q; git -C "$REPO2" config user.email t@e.com; git -C "$REPO2" config user.name T
git -C "$REPO2" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=work-ready\n' > "$STATE2/node.env"
printf 'x\n' > "$REPO2/.chump/farmer-heartbeat"   # fresh heartbeat (not back-dated)
GREEN_RC=0
env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
    CHUMP_REPO="$REPO2" CHUMP_HOME="$HOMEDIR" CHUMP_STATE_DIR="$STATE2" \
    "$CHUMP_BIN" farmer status --quiet >/dev/null 2>&1 || GREEN_RC=$?
[ "$GREEN_RC" -eq 0 ] || fail "farmer should be GREEN with valid creds + stale mirror + fresh heartbeat (rc=$GREEN_RC)"
ok "AC3: stale mirror + valid ~/.claude creds ⇒ farmer GREEN (mirror mtime never gates)"

# ── AC3 (negative): the SAME GREEN check, but with an EXPIRED non-refreshable ─
# .credentials.json, must NOT be GREEN. A dead credential still reds — this is
# the restored stale_token_reds_by_default invariant at the check level.
HOME5="$TMP/home5"; REPO5="$TMP/repo5"; STATE5="$TMP/state5"
mkdir -p "$HOME5/.chump" "$HOME5/.claude" "$REPO5/.chump" "$STATE5"
git -C "$REPO5" init -q; git -C "$REPO5" config user.email t@e.com; git -C "$REPO5" config user.name T
git -C "$REPO5" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=work-ready\n' > "$STATE5/node.env"
printf 'x\n' > "$REPO5/.chump/farmer-heartbeat"   # fresh heartbeat (not back-dated)
# Expired (expiresAt in the past) AND no refreshToken ⇒ claude -p cannot auth.
printf '{"claudeAiOauth":{"accessToken":"sk-x","expiresAt":1}}\n' > "$HOME5/.claude/.credentials.json"
EXP_RC=0
env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOME5" \
    CHUMP_REPO="$REPO5" CHUMP_HOME="$HOME5" CHUMP_STATE_DIR="$STATE5" \
    "$CHUMP_BIN" farmer status --quiet >/dev/null 2>&1 || EXP_RC=$?
[ "$EXP_RC" -ne 0 ] || fail "farmer must NOT be GREEN with expired non-refreshable .credentials.json (rc=$EXP_RC)"
ok "AC3 (negative): expired non-refreshable creds ⇒ farmer NOT GREEN (dead credential still reds)"

# ── RESILIENT-1636: unpaused node + stale heartbeat + live session lease ─────
# must refuse — pause is the ONLY thing that excuses a stale heartbeat. A live
# lease does not admit re-entry on an UN-paused (genuinely RED) node.
REPO3="$TMP/repo3"; STATE3="$TMP/state3"
mkdir -p "$REPO3/.chump" "$REPO3/.chump-locks" "$STATE3"
git -C "$REPO3" init -q; git -C "$REPO3" config user.email t@e.com; git -C "$REPO3" config user.name T
git -C "$REPO3" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=work-ready\n' > "$STATE3/node.env"   # UN-paused
printf 'x\n' > "$REPO3/.chump/farmer-heartbeat"; backdate "$REPO3/.chump/farmer-heartbeat" 80000  # STALE
cat > "$REPO3/.chump-locks/sess-A.json" <<'JSON'
{"session_id":"sess-A","gap_id":"GAP-RE-1","expires_at":"2999-01-01T00:00:00Z","paths":[]}
JSON
UNP_OUT="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOMEDIR" \
    CHUMP_REPO="$REPO3" CHUMP_HOME="$HOMEDIR" CHUMP_STATE_DIR="$STATE3" CHUMP_SESSION_ID=sess-A \
    "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)"; UNP_RC=$?
grep -qi 'no new claims admitted' <<<"$UNP_OUT" || fail "unpaused + stale heartbeat + live lease must refuse: $UNP_OUT"
grep -qi 'admitting re-entry'    <<<"$UNP_OUT" && fail "unpaused node must NOT admit re-entry: $UNP_OUT"
grep -qi 'RED'                   <<<"$UNP_OUT" || fail "unpaused refusal should name the RED state: $UNP_OUT"
[ "$UNP_RC" -ne 0 ] || fail "unpaused-stale claim should exit non-zero (rc=$UNP_RC)"
ok "RESILIENT-1636: unpaused + stale heartbeat + live lease → refused RED (pause is the only heartbeat excuse)"

# ── RESILIENT-1636: paused + FRESH auth-status cache that probed rc=1 + live ─
# lease must refuse. A BROKEN oauth probe (CREDIBLE-147 authority) is a genuine
# RED; pause excuses only the heartbeat, never a dead credential.
HOME4="$TMP/home4"; REPO4="$TMP/repo4"; STATE4="$TMP/state4"
mkdir -p "$HOME4/.chump" "$HOME4/.claude" "$REPO4/.chump" "$REPO4/.chump-locks" "$STATE4"
git -C "$REPO4" init -q; git -C "$REPO4" config user.email t@e.com; git -C "$REPO4" config user.name T
git -C "$REPO4" commit -q --allow-empty -m init
printf 'export CHUMP_NODE_MODE=paused\n' > "$STATE4/node.env"       # paused
printf 'x\n' > "$REPO4/.chump/farmer-heartbeat"; backdate "$REPO4/.chump/farmer-heartbeat" 80000
# Valid creds — so the ONLY RED signal is the probed-BROKEN cache, not the creds.
printf '{"claudeAiOauth":{"accessToken":"sk-x","refreshToken":"rt","expiresAt":9999999999999}}\n' \
    > "$HOME4/.claude/.credentials.json"
# FRESH auth-status cache (epoch-seconds then rc) that recorded rc=1 (BROKEN).
printf '%s\n1\n' "$(date -u +%s)" > "$HOME4/.chump/auth-status-cache"
cat > "$REPO4/.chump-locks/sess-A.json" <<'JSON'
{"session_id":"sess-A","gap_id":"GAP-RE-1","expires_at":"2999-01-01T00:00:00Z","paths":[]}
JSON
CACHE_OUT="$(env -i PATH="$STUB:/usr/bin:/bin" HOME="$HOME4" \
    CHUMP_REPO="$REPO4" CHUMP_HOME="$HOME4" CHUMP_STATE_DIR="$STATE4" CHUMP_SESSION_ID=sess-A \
    "$CHUMP_BIN" claim GAP-RE-1 --role bot-merge --skip-doctor --skip-import 2>&1)"; CACHE_RC=$?
grep -qi 'no new claims admitted' <<<"$CACHE_OUT" || fail "paused + rc=1 auth cache + live lease must refuse: $CACHE_OUT"
grep -qi 'admitting re-entry'    <<<"$CACHE_OUT" && fail "BROKEN oauth probe must NOT admit re-entry: $CACHE_OUT"
grep -qi 'BROKEN'                <<<"$CACHE_OUT" || fail "refusal should cite the BROKEN auth-status cache: $CACHE_OUT"
[ "$CACHE_RC" -ne 0 ] || fail "BROKEN-cache claim should exit non-zero (rc=$CACHE_RC)"
ok "RESILIENT-1636: paused + fresh auth-status cache rc=1 + live lease → refused (BROKEN oauth is genuine RED)"

# ── AC6: no automated caller uses --skip-farmer-gate ─────────────────────────
# Scan every scripts/ caller EXCEPT this fixture (which names the flag in its
# own doc + grep). Any surviving hit is a real automated bypass → fail.
AC6_HITS="$(grep -rIn -- '--skip-farmer-gate' "$REPO_ROOT/scripts" 2>/dev/null \
    | grep -v 'test-resilient-1636-farmer-gate-ship-wall.sh' || true)"
[ -z "$AC6_HITS" ] \
    || fail "an automated scripts/ caller uses --skip-farmer-gate (banned, RESILIENT-1636 AC6):
$AC6_HITS"
ok "AC6: no automated scripts/ caller uses --skip-farmer-gate"

echo ""
echo "All RESILIENT-1636 farmer-gate ship-wall tests passed!"
