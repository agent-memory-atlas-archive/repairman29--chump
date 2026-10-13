#!/usr/bin/env bash
# test-backfill-gap-id-regex.sh — guard backfill-shipped-gaps.sh against the
# false-close vector: a PR that REFERENCES a gap in a fix(X:) scope must NOT be
# treated as SHIPPING that gap. Only a bare "<GAP-ID>: …" prefix closes.
#
# Depth: edge. Mirrors the regex in backfill-shipped-gaps.sh:~79/~119 and the
# convention enforced by check-gap-status-flip.sh:34. Regression: PR #5317
# (fix(INFRA-8112): …) false-closed INFRA-8112 under the old permissive regex.
set -u

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/ops/backfill-shipped-gaps.sh"
fails=0
ok()  { echo "  ok: $1"; }
bad() { echo "  FAIL: $1"; fails=$((fails+1)); }

# The close-convention regex (keep in sync with backfill-shipped-gaps.sh).
RE='^(INFRA|EFFECTIVE|RESILIENT|DOC|META|MISSION|CREDIBLE)-([0-9]+):'
closes() { [[ "$1" =~ $RE ]]; }

# Bare "<GAP-ID>: …" → this PR ships the gap → MUST close.
for t in "INFRA-047: implement foo" "RESILIENT-1562: re-run verified" "META-9: x"; do
    closes "$t" && ok "closes (ship): $t" || bad "should close: $t"
done
# fix(X:) / references → MUST NOT close (the #5317 false-close vector).
for t in "fix(INFRA-8112): bot-merge clippy classifier (unblocks ship)" \
         "fix(INFRA-8098): Rust-aware deploy" \
         "fix(dedup): dup-pr-detector never ran" \
         "fix: post-push-integrity-watch must not reopen (INFRA-8111)" \
         "chore(RESILIENT-1): tidy"; do
    closes "$t" && bad "should NOT close (reference only): $t" || ok "no close (reference): $t"
done

# Tripwire: the live script must carry the strict (non-permissive) regex.
if grep -qE "GAP_ID_REGEX='\\^\\(INFRA\\|" "$SRC" && ! grep -qE "GAP_ID_REGEX='\\^\\(\\[a-z\\]\\+" "$SRC"; then
    ok "backfill-shipped-gaps.sh uses the strict bare-prefix regex (no fix( match)"
else
    bad "backfill-shipped-gaps.sh regex is not the strict bare-prefix form"
fi

if [ "$fails" -eq 0 ]; then echo "PASS: backfill gap-id close-convention"; else echo "FAIL: $fails"; exit 1; fi
