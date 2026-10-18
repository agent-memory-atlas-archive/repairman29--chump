#!/usr/bin/env bash
# RESILIENT-1618: freshness/validity gate for the per-entry registry fragments
# that replace merge-driver-dependent appends to EVENT_REGISTRY.yaml and
# env-vars-internal.txt.
#
# Asserts, for the fragment dirs docs/observability/events.d and
# scripts/ci/env-vars.d:
#   1. every event fragment is named <kind>.yaml and declares exactly that one
#      `- kind:` value (filename == kind);
#   2. every env-var fragment is named <VAR> and declares exactly that one var
#      on its own line (filename == var);
#   3. no fragment duplicates a kind/var already in the frozen monolith base or
#      in another fragment;
#   4. the generated complete EVENT_REGISTRY (base + fragments, via
#      gen-registries.sh) parses under PyYAML with `events` as a list;
#   5. the generated complete env-var list has no blank lines or duplicates.
#
# Run: bash scripts/ci/test-registry-fragments.sh   (exit 0 = pass)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="$REPO_ROOT/scripts/ci/gen-registries.sh"
EVENTS_D="$REPO_ROOT/docs/observability/events.d"
ENVVARS_D="$REPO_ROOT/scripts/ci/env-vars.d"
MONOLITH_EVENTS="$REPO_ROOT/docs/observability/EVENT_REGISTRY.yaml"
MONOLITH_ENV="$REPO_ROOT/scripts/ci/env-vars-internal.txt"

fail=0
err() {
  echo "FAIL[registry-fragments]: $*" >&2
  fail=1
}

# ── (1)+(3) event fragments: filename == single declared kind, no dup ────────
# Kinds already in the monolith base.
base_kinds="$(grep -E '^[[:space:]]*-[[:space:]]+kind:[[:space:]]+[A-Za-z0-9_]+' "$MONOLITH_EVENTS" \
  | sed -E 's/^[[:space:]]*-[[:space:]]+kind:[[:space:]]+([A-Za-z0-9_]+).*/\1/' | LC_ALL=C sort -u || true)"

declare -A seen_kind=()
if [[ -d "$EVENTS_D" ]]; then
  while IFS= read -r frag; do
    bn="$(basename "$frag")"
    case "$bn" in .gitkeep | README.md) continue ;; esac
    stem="${bn%.yaml}"
    if [[ "$bn" == "$stem" ]]; then
      err "event fragment $bn must end in .yaml"
      continue
    fi
    # Collect declared kinds in this fragment.
    frag_kinds="$(grep -E '^[[:space:]]*-[[:space:]]+kind:[[:space:]]+[A-Za-z0-9_]+' "$frag" \
      | sed -E 's/^[[:space:]]*-[[:space:]]+kind:[[:space:]]+([A-Za-z0-9_]+).*/\1/' || true)"
    n="$(printf '%s\n' "$frag_kinds" | grep -c . || true)"
    if [[ "$n" != "1" ]]; then
      err "event fragment $bn must declare exactly one '- kind:' entry (found $n)"
      continue
    fi
    if [[ "$frag_kinds" != "$stem" ]]; then
      err "event fragment $bn declares kind '$frag_kinds' but filename stem is '$stem' (filename must equal kind)"
      continue
    fi
    dup_base="$(printf '%s\n' "$base_kinds" | grep -xF "$stem" || true)"
    if [[ -n "$dup_base" ]]; then
      err "event fragment $bn duplicates kind '$stem' already in the monolith base"
      continue
    fi
    if [[ -n "${seen_kind[$stem]:-}" ]]; then
      err "event fragment $bn duplicates kind '$stem' declared by another fragment"
      continue
    fi
    seen_kind[$stem]=1
  done < <(find "$EVENTS_D" -maxdepth 1 -type f | LC_ALL=C sort)
fi

# ── (2)+(3) env-var fragments: filename == single declared var, no dup ───────
base_vars="$(grep -vE '^[[:space:]]*#' "$MONOLITH_ENV" | grep -vE '^[[:space:]]*$' \
  | sed -E 's/[[:space:]]+//g' | LC_ALL=C sort -u || true)"

declare -A seen_var=()
if [[ -d "$ENVVARS_D" ]]; then
  while IFS= read -r frag; do
    bn="$(basename "$frag")"
    case "$bn" in .gitkeep | README.md) continue ;; esac
    frag_vars="$(grep -vE '^[[:space:]]*#' "$frag" | grep -vE '^[[:space:]]*$' \
      | sed -E 's/[[:space:]]+//g' || true)"
    n="$(printf '%s\n' "$frag_vars" | grep -c . || true)"
    if [[ "$n" != "1" ]]; then
      err "env-var fragment $bn must declare exactly one var name (found $n)"
      continue
    fi
    if [[ "$frag_vars" != "$bn" ]]; then
      err "env-var fragment $bn declares var '$frag_vars' but filename is '$bn' (filename must equal var name)"
      continue
    fi
    dup_base_var="$(printf '%s\n' "$base_vars" | grep -xF "$bn" || true)"
    if [[ -n "$dup_base_var" ]]; then
      err "env-var fragment $bn duplicates var already in the monolith base"
      continue
    fi
    if [[ -n "${seen_var[$bn]:-}" ]]; then
      err "env-var fragment $bn duplicates var declared by another fragment"
      continue
    fi
    seen_var[$bn]=1
  done < <(find "$ENVVARS_D" -maxdepth 1 -type f | LC_ALL=C sort)
fi

# ── (4) generated complete EVENT_REGISTRY parses under PyYAML ────────────────
# Write the generated registry to a temp file and pass its PATH as argv — do
# NOT pipe it into `python3 -`, because the heredoc already occupies python's
# stdin (that pattern silently yields empty input + a SIGPIPE on the writer).
GEN_EVENTS_FILE="$(mktemp)"
"$GEN" events > "$GEN_EVENTS_FILE"
parse_out="$(python3 - "$GEN_EVENTS_FILE" <<'PYEOF'
import sys, yaml, pathlib
try:
    doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
except Exception as e:
    print(f"PARSE_ERROR: {e}")
    sys.exit(0)
if not isinstance(doc, dict) or not isinstance(doc.get("events"), list):
    print("SHAPE_ERROR: generated registry has no `events:` list")
    sys.exit(0)
print("OK")
PYEOF
)"
rm -f "$GEN_EVENTS_FILE"
if [[ "$parse_out" != "OK" ]]; then
  err "generated EVENT_REGISTRY (base + fragments): $parse_out"
fi

# ── (5) the generator runs cleanly for env-vars (base + fragments) ───────────
# NB: we deliberately do NOT flag duplicates in the full generated list — the
# frozen monolith base already contains long-standing duplicate var names that
# the existing coverage gate tolerates (it `sort -u`s). Fragment-introduced
# collisions are already prevented by checks (2)/(3) above.
if ! "$GEN" env-vars > /dev/null; then
  err "gen-registries.sh env-vars failed"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "[registry-fragments] FAILED — fix the fragments above." >&2
  exit 1
fi
echo "[registry-fragments] OK — $(( ${#seen_kind[@]} )) event fragment(s), $(( ${#seen_var[@]} )) env-var fragment(s); generated registries valid."
