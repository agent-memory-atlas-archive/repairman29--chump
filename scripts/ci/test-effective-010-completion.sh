#!/usr/bin/env bash
# test-effective-010-completion.sh — EFFECTIVE-010
#
# Source-level assertions: completion subcommand dispatch exists in main.rs
# and completion.rs implements zsh/bash/fish generators.
# Also verifies the binary (if built) produces parseable output.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAIN="$REPO_ROOT/src/main.rs"
COMPLETION="$REPO_ROOT/src/completion.rs"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== EFFECTIVE-010 shell completion source assertions ==="
echo

# ── src/main.rs ───────────────────────────────────────────────────────────────
echo "--- src/main.rs ---"

grep -q '"completion"' "$MAIN" \
  && ok "completion subcommand dispatch present in main.rs" \
  || fail "completion subcommand NOT found in main.rs"

grep -q 'completion::zsh\|completion::bash\|completion::fish' "$MAIN" \
  && ok "completion module called for zsh/bash/fish" \
  || fail "completion module calls NOT found in main.rs"

grep -q 'EFFECTIVE-010' "$MAIN" \
  && ok "EFFECTIVE-010 referenced in main.rs" \
  || fail "EFFECTIVE-010 NOT referenced in main.rs"

# ── src/completion.rs ─────────────────────────────────────────────────────────
echo "--- src/completion.rs ---"

grep -q 'pub fn zsh' "$COMPLETION" \
  && ok "pub fn zsh() present" \
  || fail "pub fn zsh() NOT found"

grep -q 'pub fn bash' "$COMPLETION" \
  && ok "pub fn bash() present" \
  || fail "pub fn bash() NOT found"

grep -q 'pub fn fish' "$COMPLETION" \
  && ok "pub fn fish() present" \
  || fail "pub fn fish() NOT found"

grep -q 'EFFECTIVE-010' "$COMPLETION" \
  && ok "EFFECTIVE-010 referenced in completion.rs" \
  || fail "EFFECTIVE-010 NOT referenced in completion.rs"

# Key commands covered
for cmd in claim gap health waste-tally fleet-status mission-grade completion; do
  grep -q "$cmd" "$COMPLETION" \
    && ok "completion covers '$cmd'" \
    || fail "completion missing '$cmd'"
done

# ── Binary smoke test (if built) ──────────────────────────────────────────────
echo "--- Binary smoke (if available) ---"
CHUMP="$REPO_ROOT/target/release/chump"
if [[ -x "$CHUMP" ]]; then
  # zsh: must start with #compdef
  zsh_out=$("$CHUMP" completion zsh 2>&1 | head -1)
  [[ "$zsh_out" == "#compdef chump" ]] \
    && ok "chump completion zsh starts with #compdef chump" \
    || fail "chump completion zsh bad header: $zsh_out"

  # bash: must contain 'complete -F'
  "$CHUMP" completion bash 2>&1 | grep -q 'complete -F _chump_complete chump' \
    && ok "chump completion bash contains 'complete -F _chump_complete chump'" \
    || fail "chump completion bash missing complete -F"

  # fish: must contain 'complete -c chump'
  "$CHUMP" completion fish 2>&1 | grep -q 'complete -c chump' \
    && ok "chump completion fish contains 'complete -c chump'" \
    || fail "chump completion fish missing 'complete -c chump'"

  # unknown shell exits non-zero
  rc=0; "$CHUMP" completion __bogus__ 2>/dev/null || rc=$?
  [[ $rc -ne 0 ]] \
    && ok "chump completion <unknown> exits non-zero ($rc)" \
    || fail "chump completion <unknown> should exit non-zero"
else
  echo "  SKIP: binary not built (source assertions sufficient for CI)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
