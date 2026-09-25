#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-open-pr-abort.sh — INFRA-1503
#
# Verifies that `chump claim` aborts non-zero, with the expected
# diagnostic, when a non-draft OPEN PR already exists on the canonical
# `chump/<gap>-claim` branch. Mocks the `gh` CLI via a PATH shim so the
# test runs offline / unauthenticated.
#
# Coverage:
#   1. SOURCE-level shape checks (helpers, ambient emit, bypass plumbing)
#   2. BINARY-level integration: claim against a real worktree with mocked
#      gh returning a synthetic open PR for the gap-id; assert exit code
#      != 0 AND the diagnostic AND the ambient event were produced.
#   3. Bypass: claim succeeds when CHUMP_CLAIM_ALLOW_OPEN_PR=1 is set
#      even though the mock gh still returns a synthetic open PR.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

# CREDIBLE-1079 (CREDIBLE-237 slice): guard helper for negative-assertion
# checks below. A negative assertion (grep -v, ! test -e, "pattern absent")
# against a target that silently doesn't exist passes vacuously — the check
# never actually ran. Call this BEFORE any negative assertion so a missing
# target aborts the script instead of masquerading as a pass.
ensure_target_exists() {
    local target="$1"
    if [[ ! -e "$target" ]]; then
        printf 'ERROR : target %s not found\n' "$target"
        return 1
    fi
    return 0
}

hdr "Round 0: ensure_target_exists guard self-test"
if ensure_target_exists "/nonexistent-target-$$-ensure-target-exists-selftest"; then
    fail "ensure_target_exists incorrectly succeeded for a missing target"
fi
ok "ensure_target_exists correctly fails (and prints ERROR) for a missing target"

ensure_target_exists "$SRC" || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

# 1. open_pr_info returns (number, author)
grep -q "fn open_pr_info" "$SRC" \
    || fail "missing fn open_pr_info — needed for (pr, author) emit"
ok "open_pr_info helper defined"

# 2. claim_aborted_pr_in_flight emitter present and uses canonical kind
grep -q "fn emit_claim_aborted_pr_in_flight_event" "$SRC" \
    || fail "missing fn emit_claim_aborted_pr_in_flight_event"
grep -qE 'kind\\?":\\?"claim_aborted_pr_in_flight\\?"' "$SRC" \
    || fail "missing canonical kind string claim_aborted_pr_in_flight"
ok "ambient emitter present + uses canonical kind"

# 3. --allow-duplicate-pr flag is parsed and threaded to ClaimArgs
grep -q '"--allow-duplicate-pr"' "$SRC" \
    || fail "missing --allow-duplicate-pr flag parsing"
grep -q "allow_duplicate_pr" "$SRC" \
    || fail "missing allow_duplicate_pr field on ClaimArgs"
ok "--allow-duplicate-pr flag wired"

# 4. CHUMP_CLAIM_ALLOW_OPEN_PR env-var bypass is honored
grep -q "CHUMP_CLAIM_ALLOW_OPEN_PR" "$SRC" \
    || fail "missing CHUMP_CLAIM_ALLOW_OPEN_PR env-var bypass"
ok "CHUMP_CLAIM_ALLOW_OPEN_PR bypass plumbed"

# 5. Emit happens BEFORE bail (we count waste even on refusal)
emit_line=$(grep -n "emit_claim_aborted_pr_in_flight_event" "$SRC" \
            | grep -v "^[[:space:]]*//" | grep -v "fn emit_" | head -1 | cut -d: -f1)
bail_line=$(grep -n "INFRA-1503 (was INFRA-1328)" "$SRC" | head -1 | cut -d: -f1)
if [[ -z "$emit_line" || -z "$bail_line" ]]; then
    fail "could not locate emit call / bail line for ordering check"
fi
(( emit_line < bail_line )) \
    || fail "emit (line $emit_line) must run BEFORE bail (line $bail_line)"
ok "ambient emit precedes bail (waste signal captured on refusal)"

# 6. Event is registered in EVENT_REGISTRY.yaml so the watchdogs know it.
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: claim_aborted_pr_in_flight" "$REG" \
    || fail "claim_aborted_pr_in_flight not registered in EVENT_REGISTRY.yaml"
ok "event kind registered in EVENT_REGISTRY.yaml"

hdr "Round 2: binary integration (mocked gh)"

CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20) \
        || fail "cargo build --bin chump failed; cannot run integration"
fi
[[ -x "$CHUMP_BIN" ]] || fail "no debug chump binary at $CHUMP_BIN"

# Synthesize a temp git repo that looks like a github clone, then build a
# PATH-shim gh that always returns a synthetic open PR for the gap-id
# we'll try to claim. The claim must abort and produce the ambient event.

WORK="$(mktemp -d -t chump-1503-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
mkdir -p "$REPO"
(cd "$REPO" \
    && git init -q -b main \
    && git config user.email "test@example.com" \
    && git config user.name  "Test" \
    && git remote add origin https://github.com/test-owner/test-repo.git \
    && mkdir -p .chump .chump-locks docs/gaps \
    && echo '{}' > .chump/state.db.placeholder \
    && touch README.md \
    && git add . && git commit -q -m init)

# Seed a real state.db with one open gap so the claim path proceeds past
# the preflight. Reuse chump's own gap-import path by writing a YAML file
# and letting `chump --briefing` or `chump gap list` lazy-init the DB.
# For test isolation, we just hand-create the SQLite schema chump needs.
cat > "$REPO/docs/gaps/INFRA-OPEN-PR-TEST.yaml" <<'YAML'
- id: INFRA-OPEN-PR-TEST
  domain: INFRA
  title: synthetic test gap for INFRA-1503 abort path
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - "should never claim — open PR mock blocks it"
YAML

# Build a PATH shim for gh: only the `gh api repos/...` call matters.
# Anything else, return empty. The shim must succeed with output that
# matches the `--jq` template chump uses: "<number>\t<author>".
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
# Mock gh for INFRA-1503 CI test: emulate exactly one query path —
#   gh api ... repos/<owner>/<repo>/pulls?state=open&head=...
# Any other invocation prints empty + succeeds (so other helpers that
# probe gh during the same claim don't accidentally pollute stdout).
case " $* " in
    *" repos/test-owner/test-repo/pulls?state=open&head="*)
        # Format must match the chump --jq template: "<number>\t<author>"
        printf '9999\tmock-sibling\n'
        exit 0
        ;;
    *" repos/"*"/pulls?state=open&head="*)
        printf '9999\tmock-sibling\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
SHIM
chmod +x "$SHIMDIR/gh"

# Round 2a: claim must abort + non-zero + diagnostic + ambient event
hdr "Round 2a: abort path"

set +e
OUT="$(PATH="$SHIMDIR:$PATH" \
       CHUMP_WORKTREE_BASE="$WORK/wts" \
       CHUMP_REPO="$REPO" \
       "$CHUMP_BIN" claim INFRA-OPEN-PR-TEST \
           --skip-doctor --skip-import 2>&1)"
RC=$?
set -e

(( RC != 0 )) \
    || { printf '%s\n' "$OUT"; fail "expected non-zero exit when open PR exists; got rc=$RC"; }
ok "claim exited non-zero (rc=$RC) when open PR exists"

grep -q "INFRA-1503" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must mention INFRA-1503"; }
grep -qE "open PR #9999" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface PR #9999"; }
grep -q "mock-sibling" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must surface PR author (mock-sibling)"; }
grep -q "CHUMP_CLAIM_ALLOW_OPEN_PR" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "diagnostic must list CHUMP_CLAIM_ALLOW_OPEN_PR escape hatch"; }
ok "diagnostic includes gap-id + PR number + author + override hint"

AMBIENT="$REPO/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"claim_aborted_pr_in_flight"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing claim_aborted_pr_in_flight event"; }
grep -q '"existing_pr":9999' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing existing_pr:9999"; }
grep -q '"existing_author":"mock-sibling"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing existing_author"; }
ok "ambient.jsonl received claim_aborted_pr_in_flight with full payload"

# Verify NO worktree was created (cheap-fail guarantee)
if [[ -d "$WORK/wts/chump-infra-open-pr-test" ]]; then
    fail "worktree was created despite abort — guard must run BEFORE worktree add"
fi
ok "no worktree leaked (abort fired before worktree create)"

# Round 2b: bypass via env-var lets the claim attempt proceed past 5b.
# Note: the claim will still fail later (no state.db, no network, etc.)
# but it MUST get past the open-PR gate — assert by absence of the
# INFRA-1503 diagnostic AND the absence of a new claim_aborted_pr_in_flight
# event from this second invocation.
hdr "Round 2b: CHUMP_CLAIM_ALLOW_OPEN_PR=1 bypass"

EVENT_COUNT_BEFORE=$(grep -c '"kind":"claim_aborted_pr_in_flight"' "$AMBIENT" || true)

set +e
OUT2="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WORK/wts2" \
        CHUMP_REPO="$REPO" \
        CHUMP_CLAIM_ALLOW_OPEN_PR=1 \
        "$CHUMP_BIN" claim INFRA-OPEN-PR-TEST \
            --skip-doctor --skip-import 2>&1)"
RC2=$?
set -e

# Expectation: it may still fail (no real gap in state.db), but the
# refusal must NOT be the INFRA-1503 open-PR refusal.
if grep -q "INFRA-1503" <<<"$OUT2" && grep -q "open PR #9999" <<<"$OUT2"; then
    printf '%s\n' "$OUT2"
    fail "CHUMP_CLAIM_ALLOW_OPEN_PR=1 did NOT bypass the open-PR abort"
fi
ok "CHUMP_CLAIM_ALLOW_OPEN_PR=1 bypasses the open-PR abort (rc=$RC2; failure if any is downstream)"

EVENT_COUNT_AFTER=$(grep -c '"kind":"claim_aborted_pr_in_flight"' "$AMBIENT" || true)
(( EVENT_COUNT_AFTER == EVENT_COUNT_BEFORE )) \
    || fail "bypass path emitted a spurious claim_aborted_pr_in_flight event ($EVENT_COUNT_BEFORE -> $EVENT_COUNT_AFTER)"
ok "bypass path emits NO claim_aborted_pr_in_flight event"

echo
echo "All INFRA-1503 open-PR-abort assertions passed."
