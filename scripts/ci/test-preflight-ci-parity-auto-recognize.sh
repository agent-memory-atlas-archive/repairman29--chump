#!/usr/bin/env bash
# test-preflight-ci-parity-auto-recognize.sh — RESILIENT-1495
#
# Regression test for RESILIENT-586's same-PR auto-recognition: a PR that
# adds a brand-new CI gate (no preflight mirror, no Tier-D entry, no
# allowlist entry) must not be blocked by the parity check on its own new
# gate. Traced 2026-09-26: get_added_jobs_from_diff() in
# test-preflight-ci-parity.sh used to diff `git diff HEAD`, which is always
# empty once the PR's changes are committed — so auto-recognition never
# fired and #4814 had to be Tier-D-registered by hand. The fix diffs the
# merge-base with origin/main instead.
#
# This test builds a deterministic local "origin" (a bare repo whose 'main'
# branch is forced to point at the current HEAD, i.e. this repo's state
# including this very fix) and a real committed "PR" on top of it (a new
# commit adding a new job with an unmirrored gate script), then asserts the
# parity script auto-recognizes it and PASSES without any manual
# Tier-D/allowlist registration.
#
# Basing "origin/main" on HEAD (rather than the repo's local `main` branch,
# which may not have this fix merged yet) keeps the test meaningful both
# pre-merge (this PR) and post-merge (once origin/main == this commit).
#
# Exit: 0 = assertions pass; 1 = any assertion fails.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0
FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
bad()  { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d -t test-pf-ci-parity-auto-recognize.XXXXXX)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

HEAD_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"

ORIGIN_BARE="$TMPDIR_TEST/origin-bare.git"
git clone -q --bare --no-hardlinks "$REPO_ROOT" "$ORIGIN_BARE" >"$TMPDIR_TEST/bare-clone.log" 2>&1
git --git-dir="$ORIGIN_BARE" update-ref refs/heads/main "$HEAD_SHA"

CLONE_DIR="$TMPDIR_TEST/pr-clone"

if ! git clone -q "$ORIGIN_BARE" "$CLONE_DIR" >"$TMPDIR_TEST/clone.log" 2>&1; then
    echo "SKIP: could not clone synthetic origin $ORIGIN_BARE"
    cat "$TMPDIR_TEST/clone.log"
    exit 0
fi

cd "$CLONE_DIR"
git checkout -q main
git checkout -q -b synthetic-pr-RESILIENT-1495

SYNTH_GATE_SCRIPT="scripts/ci/test-synth-added-gate-RESILIENT-1495.sh"
cat > "$SYNTH_GATE_SCRIPT" <<'EOF'
#!/usr/bin/env bash
# Synthetic gate script — RESILIENT-1495 regression fixture. Always passes;
# the point of this fixture is to be *unmirrored*, not to test its own logic.
exit 0
EOF
chmod +x "$SYNTH_GATE_SCRIPT"

cat >> .github/workflows/ci.yml <<EOF

  synthetic-added-gate-resilient-1495:
    runs-on: ubuntu-latest
    steps:
      - name: synthetic newly-added gate (RESILIENT-1495 regression test)
        run: bash $SYNTH_GATE_SCRIPT
EOF

git add -A
git commit -q -m "synthetic PR: add new CI gate (RESILIENT-1495 test fixture)"

# ── Run the real parity script against this synthetic "PR" ───────────────────
# No Tier-D entry, no allowlist entry, no preflight mirror for the new gate —
# auto-recognition via the merge-base diff is the only thing that can save it.
if bash "$CLONE_DIR/scripts/ci/test-preflight-ci-parity.sh" >"$TMPDIR_TEST/out.log" 2>&1; then
    ok "PR adding a new CI gate passes parity without manual Tier-D/allowlist registration"
else
    bad "parity script still failed on a PR's own newly-added gate"
    cat "$TMPDIR_TEST/out.log"
fi

if grep -q "RESILIENT-586: Auto-recognized gate in ci.yml job='synthetic-added-gate-resilient-1495'" "$TMPDIR_TEST/out.log"; then
    ok "parity script's own log shows the new job was recognized via merge-base diff"
else
    bad "parity script did not report the new job as recognized via in-diff detection"
    cat "$TMPDIR_TEST/out.log"
fi

echo
echo "test-preflight-ci-parity-auto-recognize: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
