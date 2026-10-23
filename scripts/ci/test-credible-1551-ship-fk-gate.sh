#!/usr/bin/env bash
# test-credible-1551-ship-fk-gate.sh — PHASE-R R2 (CREDIBLE-1551, completes the
# CREDIBLE-1550 umbrella AC2).
#
# Drives the real `chump` binary against a throwaway repo whose origin/main
# carries the squash commit of PR #4242, so the PHASE-R R1 proof-of-merge gate
# is satisfied and the NEW gap_prs FK gate is what is under test. Hermetic: bare
# local origin, stubbed `gh`, no CHUMP_STATE_DB / CHUMP_GAP_SERVER.
#
#   AC2a  `chump gap ship <gap> --closed-pr 4242` with NO gap_prs row linking
#         PR #4242 to <gap> is REFUSED (rc != 0, row stays open, the message
#         names CREDIBLE-1550 AC2). Proof-of-merge alone is not enough.
#   AC2b  after `chump gap link-pr <gap> 4242`, the same ship SUCCEEDS and the
#         row's gap_prs.state flips open -> merged (mark_pr_merged).
#   AC2c  `chump gap gaps-for-pr 4242` prints <gap> (the reverse lookup the two
#         converted title-regex closers resolve the gap from), exit 0.
#   AC2d  the no-title-regex-gap-closer gate passes with a TRUE-ZERO allowlist
#         (both legacy closers converted to the FK).
#
# Fails without the change: on a binary lacking the FK gate, AC2a's ship would
# SUCCEED (proof-of-merge passes for #4242), so the refuse assertion fails.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
TMP="$(mktemp -d -t chump-c1551-XXXXXX)"
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
# An absolute path is required: the chump() wrapper below cd's into the fixture.
case "$CHUMP_BIN" in /*) : ;; *) CHUMP_BIN="$REPO_ROOT/$CHUMP_BIN" ;; esac
command -v sqlite3 >/dev/null 2>&1 || die "sqlite3 required"

# ── fixture: origin/main carries "(#4242)" ──────────────────────────────────
git init -q --bare "$TMP/origin.git"
git clone -q "$TMP/origin.git" "$TMP/repo" 2>/dev/null || die "clone failed"
R="$TMP/repo"
git -C "$R" config user.email t@example.com
git -C "$R" config user.name t
git -C "$R" config commit.gpgsign false
git -C "$R" checkout -q -b main
git -C "$R" commit -q --allow-empty -m "CREDIBLE-1551: the fix that landed (#4242)"
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
status_of() { sqlite3 "$DB" "SELECT status FROM gaps WHERE id='$1'"; }
link_state_of() {
    sqlite3 "$DB" "SELECT state FROM gap_prs WHERE gap_id='$1' AND pr_number=$2" 2>/dev/null || true
}

G="$(chump gap reserve --domain RESILIENT --title "c1551 fixture: FK-gated ship" \
    --priority P2 --effort s --force 2>/dev/null | tail -1)"
[[ "$G" =~ ^RESILIENT-[0-9]+$ ]] || die "reserve failed: '$G'"

# A SECOND gap B — never linked to PR #4242 — pins that the FK gate checks the
# (gap, PR) PAIR, not merely "some gap links PR #4242" (kills mutant MS3).
B="$(chump gap reserve --domain RESILIENT --title "c1551 fixture: unpaired gap B" \
    --priority P2 --effort s --force 2>/dev/null | tail -1)"
[[ "$B" =~ ^RESILIENT-[0-9]+$ ]] || die "reserve of gap B failed: '$B'"
[[ "$B" != "$G" ]] || die "gap B collided with gap A ($G)"

echo "== PHASE-R R2: ship refuses without a gap_prs FK (CREDIBLE-1551 / 1550 AC2) =="

# ── AC2a: no link → refuse ───────────────────────────────────────────────────
out="$(chump gap ship "$G" --closed-pr 4242 --update-yaml 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$(status_of "$G")" == "open" && "$out" == *"CREDIBLE-1550 AC2"* ]]; then
    ok "AC2a ship of PR #4242 with no gap_prs row is refused (rc=$rc), row stays open"
else
    ko "AC2a expected refuse+open+message: rc=$rc status=$(status_of "$G") out=${out:0:300}"
fi

# ── AC2c: gaps-for-pr empty before the link ──────────────────────────────────
before="$(chump gap gaps-for-pr 4242 2>/dev/null || true)"
if [[ -z "$before" ]]; then
    ok "AC2c gaps-for-pr 4242 is empty before the link"
else
    ko "AC2c gaps-for-pr 4242 should be empty before the link, got: $before"
fi

# ── AC2b: link then ship → success + state=merged ────────────────────────────
chump gap link-pr "$G" 4242 --sha "$(git -C "$R" rev-parse HEAD)" >/dev/null 2>&1 \
    || ko "link-pr exited non-zero (regression: the arm must return Ok, not fall through)"
if [[ "$(link_state_of "$G" 4242)" == "open" ]]; then
    ok "AC2b gap_prs row starts in state=open after link-pr"
else
    ko "AC2b expected state=open after link, got: '$(link_state_of "$G" 4242)'"
fi
out="$(chump gap ship "$G" --closed-pr 4242 --update-yaml 2>&1)"; rc=$?
if [[ $rc -eq 0 && "$(status_of "$G")" == "done" ]]; then
    ok "AC2b ship succeeds once the gap_prs row exists"
else
    ko "AC2b linked ship refused: rc=$rc status=$(status_of "$G") out=${out:0:300}"
fi
if [[ "$(link_state_of "$G" 4242)" == "merged" ]]; then
    ok "AC2b gap_prs.state flipped open -> merged on the landed ship"
else
    ko "AC2b expected state=merged after ship, got: '$(link_state_of "$G" 4242)'"
fi

# ── AC2c: gaps-for-pr resolves the gap after the link ────────────────────────
after="$(chump gap gaps-for-pr 4242 2>/dev/null || true)"
if [[ "$after" == "$G" ]]; then
    ok "AC2c gaps-for-pr 4242 resolves to $G (the reverse lookup the closers use)"
else
    ko "AC2c gaps-for-pr 4242 expected '$G', got: '$after'"
fi

# ── AC2c': gaps-for-pr early return (the arm exits 0 and does NOT fall through
# to main's "unknown subcommand 'gap'" catch-all, exit 2). The closers depend on
# a clean exit 0 to read the FK; a fall-through would exit 2 AFTER printing.
gfp_err="$(chump gap gaps-for-pr 4242 2>&1 >/dev/null)"; gfp_rc=$?
if [[ $gfp_rc -eq 0 ]]; then
    ok "AC2c' gaps-for-pr exits 0 (no fall-through to the unknown-subcommand catch-all)"
else
    ko "AC2c' gaps-for-pr exited $gfp_rc (regression: the arm fell through to exit 2)"
fi
if [[ "$gfp_err" != *"unknown subcommand"* ]]; then
    ok "AC2c' gaps-for-pr does not print 'unknown subcommand'"
else
    ko "AC2c' gaps-for-pr printed the unknown-subcommand catch-all: $gfp_err"
fi

# ── AC2e: the gate checks the (gap, PR) PAIR, not any link for the PR (MS3) ───
# PR #4242 is linked to gap A ($G) and merged. A different, unpaired gap B must
# still be REFUSED when it tries to ride #4242's link — proof-of-merge passes
# for #4242, and a link for #4242 EXISTS, but it is not a link to B. A mutant
# that accepts "any gap_prs row for PR #4242" (rather than the (B, 4242) pair)
# would wrongly CLOSE B here; the real gate must refuse and leave B open.
out="$(chump gap ship "$B" --closed-pr 4242 --update-yaml 2>&1)"; rc=$?
if [[ $rc -ne 0 && "$(status_of "$B")" == "open" ]]; then
    ok "AC2e ship of gap B via PR #4242 (linked to A, not B) is refused (rc=$rc), B stays open"
else
    ko "AC2e MS3: a PR linked to A wrongly closed B — rc=$rc status=$(status_of "$B") out=${out:0:300}"
fi
# And the refusal must name the FK requirement, same as AC2a (not some other error).
if [[ "$out" == *"CREDIBLE-1550 AC2"* ]]; then
    ok "AC2e refusal names the gap_prs FK requirement (CREDIBLE-1550 AC2), not an unrelated error"
else
    ko "AC2e refusal did not name CREDIBLE-1550 AC2: ${out:0:300}"
fi

# ── AC2f: an AUTO-RESOLVED closed_pr (no --closed-pr flag) still requires the FK ─
# On a feature branch whose merged PR is in the GitHub cache, `chump gap ship C`
# with NO --closed-pr auto-resolves that PR from the cache (CREDIBLE-1489) — and
# the FK gate holds the auto-resolved PR to the SAME (gap, PR) link requirement
# as an explicit --closed-pr. Reuse #4242 (its "(#4242)" marker is already on
# origin/main so proof-of-merge passes); it is linked to A ($G), not C, so the
# auto-resolved close of C must be refused with a message that names BOTH the
# auto-resolution and the FK requirement.
Cgap="$(chump gap reserve --domain RESILIENT --title "c1551 fixture: autoresolve FK" \
    --priority P2 --effort s --force 2>/dev/null | tail -1)"
if [[ "$Cgap" =~ ^RESILIENT-[0-9]+$ ]]; then
    git -C "$R" checkout -q -b c1551-autoresolve 2>/dev/null
    mkdir -p "$R/.chump"
    sqlite3 "$R/.chump/github_cache.db" \
        "CREATE TABLE IF NOT EXISTS pr_state(number INTEGER PRIMARY KEY, head_ref TEXT, merged_at TEXT, title TEXT, raw_payload_json TEXT);
         INSERT OR REPLACE INTO pr_state(number,head_ref,merged_at,title,raw_payload_json)
         VALUES(4242,'c1551-autoresolve','2026-10-01T00:00:00Z','$Cgap autoresolve fixture','');"
    out="$(chump gap ship "$Cgap" --update-yaml 2>&1)"; rc=$?
    if [[ $rc -ne 0 && "$(status_of "$Cgap")" == "open" ]]; then
        ok "AC2f ship with NO --closed-pr (branch's merged PR #4242 in cache) is refused (rc=$rc), $Cgap stays open"
    else
        ko "AC2f auto-resolved close was NOT refused: rc=$rc status=$(status_of "$Cgap") out=${out:0:300}"
    fi
    if [[ "$out" == *"auto-resolved"* && "$out" == *"4242"* ]]; then
        ok "AC2f message names the auto-resolved PR #4242 (not a mysterious refusal)"
    else
        ko "AC2f message did not name the auto-resolved PR: ${out:0:300}"
    fi
    if [[ "$out" == *"CREDIBLE-1550 AC2"* ]]; then
        ok "AC2f refusal names the gap_prs FK requirement (auto-resolve held to the same gate)"
    else
        ko "AC2f refusal did not name CREDIBLE-1550 AC2: ${out:0:300}"
    fi
    git -C "$R" checkout -q main 2>/dev/null
    rm -f "$R/.chump/github_cache.db"
else
    ko "AC2f reserve of gap C failed: '$Cgap'"
fi

# ── AC2d: the no-title-closer gate passes with a true-zero allowlist ──────────
# grep -c prints "0" and EXITS 1 when nothing matches, so capture the count
# directly (no `|| echo 1`, which would append a stray line) under this test's
# set -uo pipefail (no -e, so grep's exit 1 does not abort).
nonblank="$(grep -vcE '^\s*(#|$)' "$REPO_ROOT/scripts/ci/no-title-regex-gap-closers-allowlist.txt" 2>/dev/null)"
nonblank="${nonblank:-0}"
if [[ "$nonblank" -eq 0 ]]; then
    ok "AC2d no-title-closer allowlist has zero path entries (both legacy closers converted)"
else
    ko "AC2d allowlist still has $nonblank path entry/entries — convert the closer to the FK instead"
fi
if bash "$REPO_ROOT/scripts/ci/test-no-title-regex-gap-closers.sh" >/dev/null 2>&1; then
    ok "AC2d scripts/ci/test-no-title-regex-gap-closers.sh passes with the empty allowlist"
else
    ko "AC2d the no-title-closer gate FAILED — a title-regex closer remains"
fi

printf '\n== %d passed, %d failed ==\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
