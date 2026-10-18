#!/usr/bin/env bash
# test-ops-organ-census-fixture.sh — INFRA-8576 AC1 + AC2 + AC3
#
# Synthetic fixtures over an isolated temp repo proving the census gate:
#   (AC1) a new scripts/ops/foo.sh with no twin / no trailer / no Tier-D line
#         and not grandfathered FAILS;
#   (AC2) it PASSES with any one of: a `# Rust-Twin:` header, a
#         `Rust-First-Bypass:` trailer on the adding commit, or a Tier-D line;
#   (AC3) it PASSES when grandfathered in the shrink-only allowlist.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/test-ops-organ-census.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== INFRA-8576 ops-organ census fixture test ==="

# Build an isolated temp repo so the gate never sees the real tree.
T="$(mktemp -d "${TMPDIR:-/tmp}/ops-census.XXXXXX")"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/scripts/ops" "$T/scripts/ci" "$T/docs/process" "$T/crates/x/src" "$T/.chump-locks"
printf '// twin\n' > "$T/crates/x/src/foo.rs"
printf '## Tier D — cannot mirror locally\n\n| Gate | Why |\n|---|---|\n' > "$T/docs/process/CI_GATES_INVENTORY.md"
: > "$T/scripts/ci/ops-organ-census-allowlist.txt"

# Isolate git + ambient so the gate's writes never touch the real repo.
export CHUMP_OPS_CENSUS_ROOT="$T"
export CHUMP_AMBIENT_LOG="$T/.chump-locks/ambient.jsonl"
git -C "$T" init -q
git -C "$T" config user.email t@t
git -C "$T" config user.name t

run_gate() { bash "$GATE" > "$T/out" 2>&1; }

# ── AC1: bare new organ fails ───────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho hi\n' > "$T/scripts/ops/foo.sh"
git -C "$T" add -A && git -C "$T" commit -q -m "add foo organ (no trailer)"
if run_gate; then
    bad "AC1 bare new organ should fail"; cat "$T/out"
else
    grep -q 'scripts/ops/foo.sh' "$T/out" && ok "AC1 bare new organ fails and is named" \
        || { bad "AC1 failed but organ not named"; cat "$T/out"; }
fi

# ── AC2(1): Rust-Twin header passes ─────────────────────────────────────────
printf '#!/usr/bin/env bash\n# Rust-Twin: crates/x/src/foo.rs\necho hi\n' > "$T/scripts/ops/foo.sh"
run_gate && ok "AC2 Rust-Twin header passes" || { bad "AC2 twin should pass"; cat "$T/out"; }

# dangling twin (points at a missing file) must still fail
printf '#!/usr/bin/env bash\n# Rust-Twin: crates/x/src/missing.rs\necho hi\n' > "$T/scripts/ops/foo.sh"
run_gate && { bad "AC2 dangling twin should fail"; cat "$T/out"; } || ok "AC2 dangling Rust-Twin path still fails"

# ── AC2(2): Rust-First-Bypass trailer on the adding commit passes ───────────
# Fresh organ whose ONLY add-commit carries the trailer.
printf '#!/usr/bin/env bash\necho hi\n' > "$T/scripts/ops/bar.sh"
git -C "$T" add scripts/ops/bar.sh
git -C "$T" commit -q -m "$(printf 'add bar organ\n\nRust-First-Bypass: glue over gh+jq')"
# Keep foo.sh out of the way (revert it to twin-passing so only bar is under test).
printf '#!/usr/bin/env bash\n# Rust-Twin: crates/x/src/foo.rs\necho hi\n' > "$T/scripts/ops/foo.sh"
run_gate && ok "AC2 Rust-First-Bypass trailer on adding commit passes" || { bad "AC2 trailer should pass"; cat "$T/out"; }

# ── AC2(3): Tier-D line passes ──────────────────────────────────────────────
printf '#!/usr/bin/env bash\necho hi\n' > "$T/scripts/ops/baz.sh"
git -C "$T" add scripts/ops/baz.sh && git -C "$T" commit -q -m "add baz organ (no trailer)"
if run_gate; then bad "AC2 baz with no hatch should fail first"; else ok "AC2 baz fails before Tier-D line added"; fi
printf '| baz.sh | cron-only nightly, cannot mirror |\n' >> "$T/docs/process/CI_GATES_INVENTORY.md"
run_gate && ok "AC2 Tier-D line passes" || { bad "AC2 Tier-D should pass"; cat "$T/out"; }

# ── AC3: grandfathered organ passes ─────────────────────────────────────────
printf '#!/usr/bin/env bash\necho hi\n' > "$T/scripts/ops/qux.sh"
git -C "$T" add scripts/ops/qux.sh && git -C "$T" commit -q -m "add qux organ (no trailer)"
if run_gate; then bad "AC3 qux ungrandfathered should fail first"; else ok "AC3 qux fails before grandfathering"; fi
echo "qux.sh" >> "$T/scripts/ci/ops-organ-census-allowlist.txt"
run_gate && ok "AC3 grandfathered organ passes" || { bad "AC3 grandfather should pass"; cat "$T/out"; }

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
