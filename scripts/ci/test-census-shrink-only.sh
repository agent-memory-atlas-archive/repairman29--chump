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

# ── 1b. CREDIBLE-1528: discover-chump-bin.sh loud-fail under CI=true + census SKIP-exit-0 as red ──
# (a) Under CI=true, a test sourcing discover-chump-bin.sh that cannot resolve chump exits non-zero with a clear message (never SKIP-and-exit-0).
DCB_FX="$T/dcb-fx"
mkdir -p "$DCB_FX/scripts/ci/lib"
cp "$ROOT/scripts/ci/lib/discover-chump-bin.sh" "$DCB_FX/scripts/ci/lib/discover-chump-bin.sh"
cp "$ROOT/scripts/ci/lib/resolve-cargo-target-dir.sh" "$DCB_FX/scripts/ci/lib/resolve-cargo-target-dir.sh"
cat > "$DCB_FX/scripts/ci/test-missing-bin.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/ci/lib/discover-chump-bin.sh"
echo "PASS: should not reach here"
EOF
chmod +x "$DCB_FX/scripts/ci/test-missing-bin.sh"

dcb_rc=0
dcb_out="$(CI=true PATH="/usr/bin:/bin" CHUMP_BIN="" CARGO_TARGET_DIR="$DCB_FX/empty-target" \
    bash "$DCB_FX/scripts/ci/test-missing-bin.sh" 2>&1)" || dcb_rc=$?
if [[ $dcb_rc -ne 0 ]] && grep -q "no chump binary found" <<<"$dcb_out"; then
    ok "CREDIBLE-1528 (a): under CI=true discover-chump-bin.sh exits non-zero ($dcb_rc) with clear message when binary missing"
else
    bad "CREDIBLE-1528 (a): discover-chump-bin.sh did not exit non-zero with clear message (rc=$dcb_rc, out=$dcb_out)"
fi

# Verify converted tests (test-credible-1520-link-pr-at-open.sh, test-chump-subcommand-help.sh) source discover-chump-bin.sh
if grep -q "discover-chump-bin.sh" "$ROOT/scripts/ci/test-credible-1520-link-pr-at-open.sh" \
    && grep -q "discover-chump-bin.sh" "$ROOT/scripts/ci/test-chump-subcommand-help.sh"; then
    ok "CREDIBLE-1528 (a2): test-credible-1520-link-pr-at-open.sh and test-chump-subcommand-help.sh converted to discover-chump-bin.sh"
else
    bad "CREDIBLE-1528 (a2): converted tests missing discover-chump-bin.sh"
fi

# (b) Census classifies a SKIP-and-exit-0 test step as red (both in counts.red / wired_red and in the wired-red Markdown section), while exit 77 (autotools skip) is NOT red.
SKIP_FX="$T/skip-fx"
mkdir -p "$SKIP_FX/scripts/ci" "$SKIP_FX/.github/workflows" "$SKIP_FX/.chump"
cat > "$SKIP_FX/scripts/ci/test-skip-zero.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: binary not found"
exit 0
EOF
cat > "$SKIP_FX/scripts/ci/test-skip-77.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: platform not applicable"
exit 77
EOF
chmod +x "$SKIP_FX/scripts/ci/test-skip-zero.sh" "$SKIP_FX/scripts/ci/test-skip-77.sh"
cat > "$SKIP_FX/.github/workflows/ci.yml" <<'EOF'
jobs:
  x:
    steps:
      - run: bash scripts/ci/test-skip-zero.sh
      - run: bash scripts/ci/test-skip-77.sh
EOF
CHUMP_CENSUS_ROOT="$SKIP_FX" bash "$CENSUS" --out-dir "$T/skip-out" >/dev/null
read -r sk_red sk_wred <<<"$(python3 -c 'import json,sys;c=json.load(open(sys.argv[1]))["counts"];print(c["red"],c["wired_red"])' "$T/skip-out/ci-test-census.json")"
if [[ "$sk_red" == "1" && "$sk_wred" == "1" ]] \
    && awk '/^## wired-red /{f=1;next} /^## /{f=0} f' "$T/skip-out/CI_TEST_CENSUS.md" | grep -q "test-skip-zero.sh"; then
    ok "CREDIBLE-1528 (b): census reports SKIP-and-exit-0 step as red (red=$sk_red, wired_red=$sk_wred) and lists it under wired-red"
else
    bad "CREDIBLE-1528 (b): census did not classify SKIP-and-exit-0 as red (red=$sk_red, wired_red=$sk_wred)"
fi

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
