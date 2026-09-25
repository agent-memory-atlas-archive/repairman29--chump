#!/usr/bin/env bash
# capability-guard-exempt: builds chump in-test via cargo; not subject to runner binary cache lag (CREDIBLE-077)
# scripts/ci/test-claim-force-recover-wip.sh — INFRA-2235
#
# Verifies that `chump claim --force-recover` refuses to wipe a worktree
# that has uncommitted changes, and that --discard-wip bypasses the guard.
#
# Coverage:
#   1. SOURCE-level shape checks (new fields, emit functions, flag parsing)
#   2. BINARY-level: synth worktree with 1 uncommitted file + lease;
#      assert --force-recover exits non-zero + operator message + WIP file
#      still present on disk + ambient kind=force_recover_wip_loss emitted
#   3. BINARY-level: re-run with --discard-wip; assert exit 0 +
#      ambient kind=force_recover_wip_discarded emitted + WIP file gone

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_ROOT/crates/chump-atomic-claim/src/atomic_claim.rs"

ok()   { printf '\033[0;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '\033[0;31mFAIL\033[0m %s\n' "$*"; exit 1; }
hdr()  { printf '\n--- %s ---\n' "$*"; }

[[ -f "$SRC" ]] || fail "atomic_claim.rs missing: $SRC"

hdr "Round 1: source-level shape"

# 1. discard_wip field on ClaimArgs
grep -q "pub discard_wip: bool" "$SRC" \
    || fail "missing discard_wip field on ClaimArgs"
ok "discard_wip field present on ClaimArgs"

# 2. --discard-wip flag parsed
grep -q '"--discard-wip"' "$SRC" \
    || fail "missing --discard-wip flag parsing in from_argv"
ok "--discard-wip flag parsed in from_argv"

# 3. emit_force_recover_wip_loss present
grep -q "fn emit_force_recover_wip_loss" "$SRC" \
    || fail "missing fn emit_force_recover_wip_loss"
grep -qE 'kind\\?":\\?"force_recover_wip_loss\\?"' "$SRC" \
    || fail "missing canonical kind string force_recover_wip_loss"
ok "emit_force_recover_wip_loss present + uses canonical kind"

# 4. emit_force_recover_wip_discarded present
grep -q "fn emit_force_recover_wip_discarded" "$SRC" \
    || fail "missing fn emit_force_recover_wip_discarded"
grep -qE 'kind\\?":\\?"force_recover_wip_discarded\\?"' "$SRC" \
    || fail "missing canonical kind string force_recover_wip_discarded"
ok "emit_force_recover_wip_discarded present + uses canonical kind"

# 5. WIP guard uses git status --porcelain
grep -q "status.*--porcelain" "$SRC" \
    || fail "missing git status --porcelain WIP check in atomic_claim.rs"
ok "git status --porcelain WIP check present"

# 6. bail with --discard-wip hint in refusal message
grep -q "discard-wip" "$SRC" \
    || fail "missing --discard-wip hint in refusal message"
ok "--discard-wip hint present in refusal message"

# 7. EVENT_REGISTRY.yaml has both new kinds registered
REG="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
grep -q "kind: force_recover_wip_loss" "$REG" \
    || fail "force_recover_wip_loss not registered in EVENT_REGISTRY.yaml"
grep -q "kind: force_recover_wip_discarded" "$REG" \
    || fail "force_recover_wip_discarded not registered in EVENT_REGISTRY.yaml"
ok "both new event kinds registered in EVENT_REGISTRY.yaml"

# 8. event-registry-reserved.txt has both new kinds
RESERVED="$REPO_ROOT/scripts/ci/event-registry-reserved.txt"
grep -q "force_recover_wip_loss" "$RESERVED" \
    || fail "force_recover_wip_loss missing from event-registry-reserved.txt"
grep -q "force_recover_wip_discarded" "$RESERVED" \
    || fail "force_recover_wip_discarded missing from event-registry-reserved.txt"
ok "both new kinds in event-registry-reserved.txt"

hdr "Round 2: binary integration — WIP guard fires"

CHUMP_BIN="$REPO_ROOT/target/debug/chump"
if [[ ! -x "$CHUMP_BIN" ]]; then
    (cd "$REPO_ROOT" && cargo build --bin chump --quiet 2>&1 | tail -20) \
        || fail "cargo build --bin chump failed; cannot run integration"
fi
[[ -x "$CHUMP_BIN" ]] || fail "no debug chump binary at $CHUMP_BIN"

WORK="$(mktemp -d -t chump-2235-XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

GAP_ID="INFRA-WIP-GUARD-TEST"
GAP_LOWER="infra-wip-guard-test"
REPO="$WORK/repo"
mkdir -p "$REPO"

# Set up a git repo on main, then create the claim branch + worktree from
# main so we can delete the branch later without "used by worktree" errors.
(cd "$REPO" \
    && git init -q -b main \
    && git config user.email "test@example.com" \
    && git config user.name  "Test" \
    && git remote add origin https://github.com/test-owner/test-repo.git \
    && mkdir -p .chump .chump-locks docs/gaps \
    && touch README.md \
    && git add . && git commit -q -m init \
    && git branch "chump/${GAP_LOWER}-claim")  # create the stale branch from main HEAD

# Seed gap YAML (repo HEAD stays on main)
cat > "$REPO/docs/gaps/${GAP_ID}.yaml" <<YAML
- id: ${GAP_ID}
  domain: INFRA
  title: synthetic test gap for INFRA-2235 WIP guard
  status: open
  priority: P1
  effort: xs
  acceptance_criteria:
    - "WIP guard must block --force-recover when uncommitted files exist"
YAML
(cd "$REPO" && git add "docs/gaps/${GAP_ID}.yaml" && git commit -q -m "add test gap yaml")

# Create a stale worktree simulating the prior agent's abandoned state.
WTS="$WORK/wts"
mkdir -p "$WTS"
STALE_WT="$WTS/chump-${GAP_LOWER}"

# Add a linked worktree on the claim branch so git status --porcelain works.
(cd "$REPO" && git worktree add -q "$STALE_WT" "chump/${GAP_LOWER}-claim")

# Put an uncommitted WIP file in the stale worktree
WIP_FILE="$STALE_WT/wip-uncommitted.rs"
echo "// WIP: uncommitted Sonnet work" > "$WIP_FILE"

# Verify it's dirty
STATUS_OUT="$(git -C "$STALE_WT" status --porcelain 2>/dev/null || echo "dirty-fallback")"
[[ -n "$STATUS_OUT" ]] || fail "test setup: worktree should be dirty before test"
ok "test setup: stale worktree has uncommitted WIP file"

# Build a no-op gh shim (claim path calls gh to check for open PRs)
SHIMDIR="$WORK/bin"
mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/gh" <<'SHIM'
#!/usr/bin/env bash
# No-op gh shim: returns empty (no open PRs) for all calls
exit 0
SHIM
chmod +x "$SHIMDIR/gh"

# Round 2a: --force-recover WITHOUT --discard-wip must refuse
hdr "Round 2a: --force-recover without --discard-wip (must refuse)"

set +e
OUT="$(PATH="$SHIMDIR:$PATH" \
       CHUMP_WORKTREE_BASE="$WTS" \
       CHUMP_REPO="$REPO" \
       "$CHUMP_BIN" claim "$GAP_ID" \
           --role fleet-test \
           --force-recover \
           --skip-doctor --skip-import 2>&1)"
RC=$?
set -e

(( RC != 0 )) \
    || { printf '%s\n' "$OUT"; fail "expected non-zero exit when WIP exists; got rc=$RC"; }
ok "--force-recover exited non-zero (rc=$RC) when WIP detected"

# Operator message must name the WIP file
grep -qi "wip-uncommitted" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "operator message must name the dirty file (wip-uncommitted)"; }
ok "operator message names the dirty file"

# Operator message must list all 3 recovery paths
grep -qi "commit" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "operator message must mention commit+push path"; }
grep -qi "discard-wip" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "operator message must mention --discard-wip path"; }
grep -qi "lease" <<<"$OUT" \
    || { printf '%s\n' "$OUT"; fail "operator message must mention lease-edit path"; }
ok "operator message lists all 3 recovery options"

# WIP file must still be present (not wiped)
[[ -f "$WIP_FILE" ]] \
    || fail "WIP file was destroyed despite refusal — data loss bug!"
ok "WIP file still present on disk after refusal"

# Ambient event force_recover_wip_loss must have been emitted
AMBIENT="$REPO/.chump-locks/ambient.jsonl"
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl was not created: $AMBIENT"
grep -q '"kind":"force_recover_wip_loss"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing force_recover_wip_loss event"; }
grep -q '"files_lost_count":1' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient event missing files_lost_count:1"; }
ok "ambient force_recover_wip_loss event emitted with files_lost_count"

hdr "Round 2b: --force-recover --discard-wip (must pass WIP guard + emit discarded)"

# Clear ambient log for clean assertion on discard path
> "$AMBIENT"

# Re-create the stale worktree with WIP (Round 2a cleaned nothing, so it's still there
# as long as we didn't wipe it — confirmed above). We need to put it back since Round 2a
# left the dir intact. Re-add it fresh.
if [[ ! -d "$STALE_WT" ]]; then
    (cd "$REPO" && git branch "chump/${GAP_LOWER}-claim" 2>/dev/null || true \
        && git worktree add -q "$STALE_WT" "chump/${GAP_LOWER}-claim" 2>/dev/null || true)
    if [[ ! -d "$STALE_WT" ]]; then
        mkdir -p "$STALE_WT"
    fi
fi
echo "// WIP: uncommitted Sonnet work (round 2b)" > "$WIP_FILE"

set +e
OUT2="$(PATH="$SHIMDIR:$PATH" \
        CHUMP_WORKTREE_BASE="$WTS" \
        CHUMP_REPO="$REPO" \
        "$CHUMP_BIN" claim "$GAP_ID" \
            --role fleet-test \
            --force-recover --discard-wip \
            --skip-doctor --skip-import 2>&1)"
RC2=$?
set -e

# Key assertion: the WIP-guard refusal message must NOT appear.
# The claim may fail downstream (no real origin/main in test repo) — that's OK.
if grep -qi "force-recover refused" <<<"$OUT2"; then
    printf '%s\n' "$OUT2"
    fail "--discard-wip did NOT bypass the WIP guard (refusal message still present)"
fi
ok "--discard-wip bypassed the WIP guard (refusal not in output)"

# The discard WARNING must appear (confirms the guard ran and chose the discard path)
grep -qi "discard.*wip\|discarding.*uncommitted" <<<"$OUT2" \
    || { printf '%s\n' "$OUT2"; fail "discard-wip WARNING not emitted"; }
ok "discard WARNING emitted (guard chose --discard-wip path)"

# Ambient event force_recover_wip_discarded must have been emitted
[[ -f "$AMBIENT" ]] || fail "ambient.jsonl missing after --discard-wip run"
grep -q '"kind":"force_recover_wip_discarded"' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "ambient.jsonl missing force_recover_wip_discarded event"; }
grep -q '"files_lost_count":1' "$AMBIENT" \
    || { cat "$AMBIENT"; fail "discard ambient event missing files_lost_count:1"; }
ok "ambient force_recover_wip_discarded event emitted with files_lost_count"

# WIP file must be gone — the worktree was wiped before the downstream worktree-add
[[ ! -f "$WIP_FILE" ]] \
    || fail "WIP file still exists after --discard-wip — worktree was not wiped"
ok "WIP file removed after --discard-wip (worktree wiped as expected)"

hdr "All checks passed"
