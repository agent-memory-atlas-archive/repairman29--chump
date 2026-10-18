#!/usr/bin/env bash
# RESILIENT-1618 AC#2: prove two PRs that EACH add one event-registry entry and
# one internal env var land on main in sequence through `update-branch` with
# zero conflicts and zero human pushes — using the per-entry fragment split,
# with NO merge driver configured (GitHub never runs one).
#
# Also a negative control: the SAME two additions done the OLD way (both
# appending to a single shared monolith file) DO conflict on update-branch —
# demonstrating that the per-entry fragment split is precisely what removes the
# need for the merge=union driver GitHub refuses to honor.
#
# Hermetic: builds a throwaway git repo in a tempdir with core.attributesfile
# unset and no custom merge driver, so the merge semantics match GitHub's
# server-side merge. Run: bash scripts/ci/test-registry-fragment-no-conflict.sh
set -euo pipefail

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

repo() {
  git -C "$TMP" "$@"
}

git init -q "$TMP"
repo config user.email tester@example.com
repo config user.name tester
repo config commit.gpgsign false
# Match GitHub: no custom merge driver, no attributes file in effect.
repo config --unset core.attributesfile 2>/dev/null || true

mk_event_fragment() { # $1=dir $2=kind
  cat > "$1/docs/observability/events.d/$2.yaml" <<EOF
  - kind: $2
    effect_metric: self
    emitter: scripts/ci/test-registry-fragment-no-conflict.sh
    trigger: >-
      synthetic fragment for the RESILIENT-1618 no-conflict proof
    consumers: [test]
    fields_required: [ts, kind]
EOF
}

# ── Base commit: the two frozen monoliths + the two fragment dirs ────────────
mkdir -p "$TMP/docs/observability/events.d" "$TMP/scripts/ci/env-vars.d"
printf 'schema_version: 2\nevents:\n  - kind: base_kind\n    effect_metric: self\n    emitter: base\n    trigger: base\n    consumers: [test]\n' \
  > "$TMP/docs/observability/EVENT_REGISTRY.yaml"
printf 'BASE_VAR\n' > "$TMP/scripts/ci/env-vars-internal.txt"
: > "$TMP/docs/observability/events.d/.gitkeep"
: > "$TMP/scripts/ci/env-vars.d/.gitkeep"
repo add -A
repo commit -qm "base"
BASE="$(repo rev-parse HEAD)"

# ── PR A: new fragments only (new files) ─────────────────────────────────────
repo checkout -q -B prA "$BASE"
mk_event_fragment "$TMP" "synth_kind_a"
printf 'CHUMP_SYNTH_A\n' > "$TMP/scripts/ci/env-vars.d/CHUMP_SYNTH_A"
repo add -A
repo commit -qm "prA: register synth_kind_a + CHUMP_SYNTH_A as fragments"

# ── PR B: different new fragments only (different new files) ─────────────────
repo checkout -q -B prB "$BASE"
mk_event_fragment "$TMP" "synth_kind_b"
printf 'CHUMP_SYNTH_B\n' > "$TMP/scripts/ci/env-vars.d/CHUMP_SYNTH_B"
repo add -A
repo commit -qm "prB: register synth_kind_b + CHUMP_SYNTH_B as fragments"

# ── PR A lands on main first ─────────────────────────────────────────────────
repo checkout -q -B main "$BASE"
repo merge -q --no-edit prA
MAIN_A="$(repo rev-parse HEAD)"

# ── update-branch PR B = merge the new main into prB; MUST be conflict-free ──
repo checkout -q prB
set +e
merge_out="$(repo merge --no-edit "$MAIN_A" 2>&1)"
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "FAIL: fragment PRs conflicted on update-branch (rc=$rc)" >&2
  echo "$merge_out" >&2
  repo merge --abort 2>/dev/null || true
  exit 1
fi

# Both entries must survive the merge.
for want_file in \
  "docs/observability/events.d/synth_kind_a.yaml" \
  "docs/observability/events.d/synth_kind_b.yaml" \
  "scripts/ci/env-vars.d/CHUMP_SYNTH_A" \
  "scripts/ci/env-vars.d/CHUMP_SYNTH_B"; do
  if [[ ! -f "$TMP/$want_file" ]]; then
    echo "FAIL: merged tree is missing $want_file" >&2
    exit 1
  fi
done
echo "[no-conflict] PASS: two fragment PRs landed via update-branch with zero conflicts."

# ── Negative control: the OLD way (append to one shared monolith) conflicts ──
repo checkout -q -B ctrlA "$BASE"
printf '  - kind: old_kind_a\n    effect_metric: self\n    emitter: a\n    trigger: a\n    consumers: [test]\n' \
  >> "$TMP/docs/observability/EVENT_REGISTRY.yaml"
printf 'OLD_VAR_A\n' >> "$TMP/scripts/ci/env-vars-internal.txt"
repo add -A
repo commit -qm "ctrlA: append old_kind_a the monolith way"

repo checkout -q -B ctrlB "$BASE"
printf '  - kind: old_kind_b\n    effect_metric: self\n    emitter: b\n    trigger: b\n    consumers: [test]\n' \
  >> "$TMP/docs/observability/EVENT_REGISTRY.yaml"
printf 'OLD_VAR_B\n' >> "$TMP/scripts/ci/env-vars-internal.txt"
repo add -A
repo commit -qm "ctrlB: append old_kind_b the monolith way"

repo checkout -q -B ctrlmain "$BASE"
repo merge -q --no-edit ctrlA
CTRL_MAIN_A="$(repo rev-parse HEAD)"

repo checkout -q ctrlB
set +e
ctrl_out="$(repo merge --no-edit "$CTRL_MAIN_A" 2>&1)"
ctrl_rc=$?
set -e
repo merge --abort 2>/dev/null || true
if [[ $ctrl_rc -eq 0 ]]; then
  echo "FAIL: negative control expected a conflict from monolith appends but merge was clean (rc=0)" >&2
  echo "$ctrl_out" >&2
  exit 1
fi
echo "[no-conflict] PASS: negative control confirms monolith appends DO conflict (rc=$ctrl_rc) — fragments are what fix it."
echo "[registry-fragment-no-conflict] OK"
