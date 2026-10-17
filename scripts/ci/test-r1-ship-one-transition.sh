#!/usr/bin/env bash
# test-r1-ship-one-transition.sh — PHASE-R R1 (CREDIBLE-1491)
#
# Drives the real `chump` binary against a throwaway repo whose origin/main
# carries the squash commit of PR #4242 (and nothing for #999). Hermetic:
# bare local origin, stubbed `gh`, no CHUMP_STATE_DB / CHUMP_GAP_SERVER.
#
#   AC5  `chump gap set --status done` with no --closed-pr, or one that does
#        not resolve to a landing receipt (#999), exits non-zero with the
#        PHASE-R R1 message and leaves the row open; #4242 succeeds.
#   AC2  `chump gap ship --closed-pr 999` (never landed) is refused: row
#        open, no ship_landed.
#   AC3  a second ship is a no-op: row, YAML mirror and ambient stream are
#        byte-identical after it.
#   AC4  RESILIENT-1562 replay: 87 ships of one gap (2026-10-12 receipt)
#        record exactly one gap_status_done_written and one ship_landed.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d -t chump-r1-XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  PASS %s\n' "$*"; }
ko() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$*"; }
die() { printf 'FAIL %s\n' "$*"; exit 1; }

# Resolve the binary the way the fast-checks steps do; build when absent.
CHUMP_BIN="${CHUMP_BIN:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/chump}"
if ! [ -x "$CHUMP_BIN" ]; then
    (cd "$REPO_ROOT" && PATH="$HOME/.cargo/bin:$PATH" cargo build --quiet --bin chump) \
        || die "cargo build --bin chump failed"
fi
[ -x "$CHUMP_BIN" ] || die "CHUMP_BIN not executable: $CHUMP_BIN"
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 required"

# ── fixture: origin/main carries "(#4242)" ──────────────────────────────────
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null || die "clone failed"
R="$TMP/repo"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
git -C "$R" checkout -q -b main
git -C "$R" commit -q --allow-empty -m "RESILIENT-1562: the fix that landed (#4242)"
git -C "$R" push -q origin main || die "push failed"

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\necho "gh stub: offline" >&2\nexit 1\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

chump() {
    (cd "$R" && env -u CHUMP_STATE_DB -u CHUMP_REPO -u CHUMP_GAP_SERVER \
        PATH="$TMP/bin:$PATH" CHUMP_BINARY_STALENESS_CHECK=0 \
        CHUMP_RESERVE_SCAN_OPEN_PRS=0 "$CHUMP_BIN" "$@")
}
DB="$R/.chump/state.db"
AMB="$R/.chump-locks/ambient.jsonl"
status_of() { sqlite3 "$DB" "SELECT status FROM gaps WHERE id='$1'"; }
row_of() { sqlite3 "$DB" "SELECT status, closed_at, closed_date, closed_pr, landing_receipt_json FROM gaps WHERE id='$1'"; }
count_kind() {
    local hits
    hits="$(grep -F "\"kind\":\"$1\"" "$AMB" 2>/dev/null || true)"
    [[ -z "$hits" ]] && { echo 0; return; }
    printf '%s\n' "$hits" | grep -cF "\"gap_id\":\"$2\"" || true
}
digest() { if [ -f "$1" ]; then shasum "$1" | cut -d' ' -f1; else echo absent; fi; }
reserve() { chump gap reserve --domain RESILIENT --title "$1" --priority P2 --effort s --force 2>/dev/null | tail -1; }

G_SHIP="$(reserve 'r1 replay fixture: the 1562 re-ship loop')"
G_SET="$(reserve 'r1 fixture: gap set needs a resolvable closed_pr')"
G_UNLANDED="$(reserve 'r1 fixture: a PR that never landed')"
for g in "$G_SHIP" "$G_SET" "$G_UNLANDED"; do
    [[ "$g" =~ ^RESILIENT-[0-9]+$ ]] || die "reserve failed: '$G_SHIP' '$G_SET' '$G_UNLANDED'"
done

echo "== PHASE-R R1: ship is one receipt-gated transition (CREDIBLE-1491) =="

# ── AC5 ─────────────────────────────────────────────────────────────────────
out="$(chump gap set "$G_SET" --status "done" 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"PHASE-R R1"* ]]; then
    ok "AC5 gap set --status done without --closed-pr exits $rc with the R1 message"
else
    ko "AC5 no --closed-pr: rc=$rc out=${out:0:300}"
fi
out="$(chump gap set "$G_SET" --status "done" --closed-pr 999 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$out" == *"PHASE-R R1"* && "$out" == *"#999"* ]]; then
    ok "AC5 gap set --status done --closed-pr 999 (never landed) exits $rc with the R1 message"
else
    ko "AC5 unresolvable --closed-pr: rc=$rc out=${out:0:300}"
fi
if [[ "$(status_of "$G_SET")" == "open" ]]; then
    ok "AC5 refused writes leave the row open"
else
    ko "AC5 row mutated by a refused write: $(status_of "$G_SET")"
fi
out="$(chump gap set "$G_SET" --status "done" --closed-pr 4242 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$(status_of "$G_SET")" == "done" ]]; then
    ok "AC5 gap set --closed-pr 4242 (landed) succeeds"
else
    ko "AC5 resolvable --closed-pr refused: rc=$rc out=${out:0:300}"
fi

# ── AC2 ─────────────────────────────────────────────────────────────────────
out="$(chump gap ship "$G_UNLANDED" --closed-pr 999 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$(status_of "$G_UNLANDED")" == "open" && "$(count_kind ship_landed "$G_UNLANDED")" -eq 0 ]]; then
    ok "AC2 ship of a PR with no squash commit on origin/main is refused (rc=$rc)"
else
    ko "AC2 unlanded ship: rc=$rc status=$(status_of "$G_UNLANDED") out=${out:0:300}"
fi

# ── AC3 + AC4 ───────────────────────────────────────────────────────────────
out="$(chump gap ship "$G_SHIP" --closed-pr 4242 --update-yaml 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(status_of "$G_SHIP")" == "done" ]] || die "first ship failed: rc=$rc out=${out:0:300}"
ok "first ship lands the transition"
YAML="$R/docs/gaps/$G_SHIP.yaml"
row1="$(row_of "$G_SHIP")"
amb1="$(digest "$AMB")"
yaml1="$(digest "$YAML")"

bad=0
for _ in $(seq 2 87); do
    chump gap ship "$G_SHIP" --closed-pr 4242 --update-yaml >/dev/null 2>&1 || bad=$((bad + 1))
done
if [[ $bad -eq 0 ]]; then ok "AC3 ships 2..87 all exit 0"; else ko "AC3 $bad of 86 re-ships exited non-zero"; fi
if [[ "$(row_of "$G_SHIP")" == "$row1" ]]; then
    ok "AC3 status, closed_at and receipt unchanged by 86 re-ships"
else
    ko "AC3 row changed: '$row1' -> '$(row_of "$G_SHIP")'"
fi
if [[ "$(digest "$AMB")" == "$amb1" ]]; then
    ok "AC3 zero new ambient events from 86 re-ships"
else
    ko "AC3 ambient changed: $(tail -3 "$AMB")"
fi
yaml2="$(digest "$YAML")"
if [[ "$yaml2" == "$yaml1" ]]; then
    ok "AC3 zero YAML churn (docs/gaps/$G_SHIP.yaml: $yaml1)"
else
    ko "AC3 YAML mirror rewritten: $yaml1 -> $yaml2"
fi

n_done="$(count_kind gap_status_done_written "$G_SHIP")"
n_landed="$(count_kind ship_landed "$G_SHIP")"
if [[ "$n_done" -eq 1 && "$n_landed" -eq 1 ]]; then
    ok "AC4 RESILIENT-1562 replay: 87 ships -> 1 gap_status_done_written, 1 ship_landed"
else
    ko "AC4 replay: gap_status_done_written=$n_done ship_landed=$n_landed (want 1 and 1)"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
