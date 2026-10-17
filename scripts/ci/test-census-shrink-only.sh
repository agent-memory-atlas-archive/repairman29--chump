#!/usr/bin/env bash
# scripts/ci/test-census-shrink-only.sh — CREDIBLE-1514 shrink-only gate.
#
# Rule: a new scripts/ci test is wired or it is deleted, and the census red and
# unwired lists only shrink. This gate:
#   1. proves the compare logic on synthetic fixture repos (new unwired test
#      fails, wiring it passes, red growth fails, CHUMP_CENSUS_ALLOW_GROWTH=1
#      reports instead of failing, shrinkage passes, no base passes);
#   2. runs the real compare: live classification of this tree +
#      docs/observability/ci-test-census.json on this branch vs the same json
#      on the base ref (default origin/main).
#
# ENV
#   CHUMP_CENSUS_BASE_REF       base to compare against (default origin/main)
#   CHUMP_CENSUS_ALLOW_GROWTH   1 = report red/unwired count growth, do not fail
#                               (CI sets it for the nightly census/* PR, whose
#                               job is to publish the truth). Newly unwired
#                               tests still fail.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CENSUS="$ROOT/scripts/ci/census.sh"
BASE_REF="${CHUMP_CENSUS_BASE_REF:-origin/main}"
PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/census-shrink.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# ── 1. fixture self-test ────────────────────────────────────────────────────
fx="$T/repo"
mkdir -p "$fx/scripts/ci" "$fx/.github/workflows" "$fx/crates/chump-preflight/src"
for n in a b c; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/scripts/ci/test-$n.sh"; done
printf 'jobs:\n  x:\n    steps:\n      - run: bash scripts/ci/test-a.sh\n      # - run: bash scripts/ci/test-c.sh\n' \
    > "$fx/.github/workflows/ci.yml"
printf '// scripts/ci/test-c.sh is a comment, not wiring\nstep("b", &["bash", "scripts/ci/test-b.sh"]);\n' \
    > "$fx/crates/chump-preflight/src/preflight.rs"
CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --no-run --out-dir "$T/base" >/dev/null
base="$T/base/ci-test-census.json"
read -r w u <<<"$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]))["counts"];print(c["wired"],c["unwired"])' "$base")"
[[ "$w" == 2 && "$u" == 1 ]] && ok "classification: workflow + preflight wire, comment lines do not (wired=$w unwired=$u)" \
    || bad "classification wired=$w unwired=$u (want 2/1)"

check() { CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --check-shrink "$base" --head-json "$1" >"$T/out" 2>&1; }

check "$base" && ok "unchanged tree passes" || bad "unchanged tree failed: $(cat "$T/out")"

printf '#!/usr/bin/env bash\nexit 0\n' > "$fx/scripts/ci/test-new.sh"
if check "$base"; then bad "a new unwired test passed"; else
    grep -q 'test-new.sh' "$T/out" && ok "a new unwired test fails and is named" || bad "new unwired test not named"; fi
if CHUMP_CENSUS_ALLOW_GROWTH=1 check "$base"; then bad "ALLOW_GROWTH excused a newly unwired test"; else
    ok "ALLOW_GROWTH does not excuse a newly unwired test"; fi
printf '      - run: bash scripts/ci/test-new.sh\n' >> "$fx/.github/workflows/ci.yml"
check "$base" && ok "wiring the new test passes" || bad "wired new test failed: $(cat "$T/out")"
rm "$fx/scripts/ci/test-new.sh"

python3 - "$base" "$T/red.json" "$T/shrunk.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
r = json.loads(json.dumps(d)); r["counts"]["red"] = d["counts"]["red"] + 1
json.dump(r, open(sys.argv[2], "w"))
s = json.loads(json.dumps(d)); s["counts"]["unwired"] = 0
json.dump(s, open(sys.argv[3], "w"))
PY
if check "$T/red.json"; then bad "red count growth passed"; else ok "red count growth fails"; fi
CHUMP_CENSUS_ALLOW_GROWTH=1 check "$T/red.json" && grep -q REPORTED "$T/out" \
    && ok "ALLOW_GROWTH reports red growth without failing" || bad "ALLOW_GROWTH did not report red growth"
check "$T/shrunk.json" && ok "shrinkage passes" || bad "shrinkage failed: $(cat "$T/out")"
CHUMP_CENSUS_ROOT="$fx" bash "$CENSUS" --check-shrink "$T/absent.json" --head-json "$base" >/dev/null 2>&1 \
    && ok "missing base passes (first run)" || bad "missing base failed"

# ── 2. the real gate ────────────────────────────────────────────────────────
echo "census-shrink: real compare against $BASE_REF"
if ! git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
    # Shallow CI checkouts have no origin/main; fetch just the tip.
    git -C "$ROOT" fetch --quiet --depth=1 origin "${BASE_REF#origin/}:refs/remotes/$BASE_REF" 2>/dev/null || true
fi
real_base="$T/real-base.json"
if git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
    git -C "$ROOT" show "$BASE_REF:docs/observability/ci-test-census.json" > "$real_base" 2>/dev/null || rm -f "$real_base"
else
    echo "census-shrink: WARN: base ref $BASE_REF unavailable; skipping the real compare"
fi
if [[ -f "$real_base" ]] || git -C "$ROOT" rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
    if bash "$CENSUS" --check-shrink "$real_base"; then ok "real tree vs $BASE_REF"; else bad "real tree vs $BASE_REF (see above)"; fi
fi

echo "census-shrink: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
