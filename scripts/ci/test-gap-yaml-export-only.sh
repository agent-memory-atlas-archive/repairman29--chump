#!/usr/bin/env bash
# test-gap-yaml-export-only.sh — INFRA-8193 (Phase R R4)
#
# state.db is the ONLY gap truth (docs/process/CANONICAL_GAP_STORE.md).
# docs/gaps/*.yaml is an EXPORT-ONLY mirror: it is written by the export path
# and nothing else. The export path is:
#
#   crates/chump-gap-store/src/lib.rs   dump_per_file / dump_per_file_single
#   crates/chump-gap-store/src/sync.rs  sync_push (atomic per-file write)
#   src/main.rs                         `chump gap dump --per-file`,
#                                       `chump gap sync --push`,
#                                       `chump gap ship` single-gap sync
#
# Scripts that INVOKE those commands are using the export path and are fine.
# This gate is a grep inventory of every OTHER route that writes
# docs/gaps/*.yaml (shell redirects, tee/cp/mv/sed -i/yq -i, python
# open(..., "w")/write_text, Rust fs::write next to a docs/gaps path, a new
# Rust caller of the export primitives outside the CLI). The inventory is
# deliberately approximate (line-level grep, no data flow); the allowlist is
# the reviewed baseline of known non-export writers.
#
# Rules (all hard failures):
#   1. a detected writer not in scripts/ci/gap-yaml-writer-allowlist.txt
#   2. an allowlist entry that is no longer detected (stale: delete the line)
#   3. an allowlist entry that is absent from origin/main's copy (the list
#      may ONLY SHRINK; skipped when origin/main's copy is unreadable, e.g. the
#      PR that introduces the file or a shallow checkout)
#
# Also runs a fixture self-test first: a planted writer in a scratch tree must
# be detected, and an export-path invocation must not be.
#
# Run from anywhere: bash scripts/ci/test-gap-yaml-export-only.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
ALLOWLIST_REL="scripts/ci/gap-yaml-writer-allowlist.txt"
ALLOWLIST="$REPO_ROOT/$ALLOWLIST_REL"
SELF_REL="scripts/ci/test-gap-yaml-export-only.sh"

# Files that ARE the export path. Exempt by definition (see header).
EXPORT_PATH_FILES="crates/chump-gap-store/src/lib.rs
crates/chump-gap-store/src/sync.rs
src/main.rs"

# Line filter: comment lines are not writes.
SKIP_LINE_RE='^[[:space:]]*(#|//|\*)'

# Rust patterns (src/, crates/).
RUST_RE='\b(dump_per_file|dump_per_file_single|sync_push)[[:space:]]*\(|docs/gaps.*(fs::write|File::create|OpenOptions|fs::rename|fs::copy)|(fs::write|File::create|OpenOptions|fs::rename|fs::copy).*docs/gaps|(wrote|writing|synced|wrote to) docs/gaps/'
RUST_DEF_RE='fn[[:space:]]+(dump_per_file|dump_per_file_single|sync_push)\b'

# Script patterns (scripts/, .github/workflows/).
PY_WRITE="(open\\([^)]*[\"'][wa]\\+?[\"']|write_text\\(|yaml\\.(safe_)?dump\\(|shutil\\.(copy|move)|os\\.replace\\(|writeFileSync\\()"
SCRIPT_RE=">>?[[:space:]]*[\"']?[^ |;&]*docs/gaps/[^ |;&]*\\.ya?ml|\\btee\\b[^|]*docs/gaps/|\\b(cp|mv|install|rsync)\\b[^|#;]*docs/gaps/|\\bsed[[:space:]]+-i[^|]*docs/gaps/|\\byq\\b[^|]*[[:space:]]-i\\b[^|]*docs/gaps|docs/gaps.*$PY_WRITE|$PY_WRITE.*docs/gaps|open\\([^)]*docs/gaps[^)]*[\"'][wa]"

PY_GAP_PATH_RE="\"docs\"[[:space:]]*/[[:space:]]*\"gaps\"[[:space:]]*/|\"docs\",[[:space:]]*\"gaps\"|docs/gaps/"
PY_YAML_WRITE_RE='write_text\(|safe_dump\(|yaml\.dump\('

# detect_writers <root>: print one relpath per detected non-export writer.
detect_writers() {
    local root="$1"
    (
        cd "$root" || exit 0
        {
            find src crates -type f -name '*.rs' 2>/dev/null \
                | grep -v '/tests/' \
                | while IFS= read -r f; do
                    grep -qxF "$f" <<<"$EXPORT_PATH_FILES" && continue
                    # Consume the whole stream (no trailing grep -q): under
                    # pipefail a -q early exit SIGPIPEs the upstream grep and
                    # GNU grep then fails the pipeline, hiding real writers
                    # (CI run 39062228524 missed scripts/coord/gap-doctor.py).
                    local hits
                    hits="$(grep -E "$RUST_RE" "$f" 2>/dev/null \
                        | grep -Ev "$SKIP_LINE_RE" \
                        | grep -Ev "$RUST_DEF_RE" || :)"
                    if [[ -n "$hits" ]]; then
                        echo "$f"
                    fi
                done
            find scripts .github/workflows -type f \
                \( -name '*.sh' -o -name '*.bash' -o -name '*.py' -o -name '*.mjs' -o -name '*.js' -o -name '*.yml' -o -name '*.yaml' \) 2>/dev/null \
                | while IFS= read -r f; do
                    [[ "$f" == "$SELF_REL" ]] && continue
                    [[ "$(basename "$f")" == test-* ]] && continue
                    local hits
                    hits="$(grep -E "$SCRIPT_RE" "$f" 2>/dev/null \
                        | grep -Ev "$SKIP_LINE_RE" || :)"
                    if [[ -n "$hits" ]]; then
                        echo "$f"
                        continue
                    fi
                    # Python builds paths in variables, so add a file-level
                    # heuristic: a per-gap YAML path AND a YAML/text write.
                    if [[ "$f" == *.py ]] \
                        && [[ -n "$(grep -Ev "$SKIP_LINE_RE" "$f" | grep -E "$PY_GAP_PATH_RE" || :)" ]] \
                        && [[ -n "$(grep -Ev "$SKIP_LINE_RE" "$f" | grep -E "$PY_YAML_WRITE_RE" || :)" ]]; then
                        echo "$f"
                    fi
                done
        } | LC_ALL=C sort -u
    )
}

# allowlist_entries <file>: first column of non-comment, non-blank lines.
allowlist_entries() {
    [[ -f "$1" ]] || return 0
    grep -Ev '^[[:space:]]*(#|$)' "$1" | awk '{print $1}' | LC_ALL=C sort -u
}

fail=0
FAILS=()
note_fail() { FAILS+=("$1"); fail=1; }

echo "=== INFRA-8193 gap YAML export-only gate ==="

# ── 0. fixture self-test: the detector must fire on a planted writer ────────
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/scripts/coord" "$SCRATCH/src" "$SCRATCH/crates/x/src"
cat > "$SCRATCH/scripts/coord/planted.sh" <<'FIX'
#!/usr/bin/env bash
printf 'id: X-1\n' > "$REPO/docs/gaps/X-1.yaml"
FIX
cat > "$SCRATCH/scripts/coord/planted.py" <<'FIX'
open("docs/gaps/X-2.yaml", "w").write("id: X-2\n")
FIX
cat > "$SCRATCH/crates/x/src/lib.rs" <<'FIX'
fn w() { std::fs::write("docs/gaps/X-3.yaml", "id: X-3\n").unwrap(); }
FIX
cat > "$SCRATCH/scripts/coord/export-ok.sh" <<'FIX'
#!/usr/bin/env bash
# writes via the export path only
chump gap dump --per-file --out-dir docs/gaps
chump gap sync --push
cat docs/gaps/X-1.yaml
FIX
got="$(detect_writers "$SCRATCH" | tr '\n' ' ')"
for want in scripts/coord/planted.sh scripts/coord/planted.py crates/x/src/lib.rs; do
    if [[ " $got " == *" $want "* ]]; then
        echo "  self-test ok: planted writer detected ($want)"
    else
        note_fail "self-test: planted writer NOT detected ($want); detector is blind"
    fi
done
if [[ " $got " == *" scripts/coord/export-ok.sh "* ]]; then
    note_fail "self-test: an export-path invocation was flagged as a writer"
else
    echo "  self-test ok: export-path invocation not flagged"
fi

# ── 1+2. live inventory vs allowlist ────────────────────────────────────────
detected="$(detect_writers "$REPO_ROOT")"
allowed="$(allowlist_entries "$ALLOWLIST")"

while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    if ! grep -qxF "$w" <<<"$allowed"; then
        note_fail "NEW docs/gaps/*.yaml writer outside the export path: $w (route it through chump gap dump --per-file / sync --push, or state.db)"
    fi
done <<<"$detected"

while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    if ! grep -qxF "$a" <<<"$detected"; then
        note_fail "stale allowlist entry (no longer a writer, delete the line): $a"
    fi
done <<<"$allowed"

# ── 3. shrink-only against origin/main ──────────────────────────────────────
if base_text="$(git -C "$REPO_ROOT" show "origin/main:$ALLOWLIST_REL" 2>/dev/null)"; then
    base="$(printf '%s\n' "$base_text" | grep -Ev '^[[:space:]]*(#|$)' | awk '{print $1}' | LC_ALL=C sort -u)"
    while IFS= read -r a; do
        [[ -z "$a" ]] && continue
        if ! grep -qxF "$a" <<<"$base"; then
            note_fail "allowlist GREW vs origin/main (it may only shrink): $a"
        fi
    done <<<"$allowed"
    echo "  shrink-only check: compared against origin/main"
else
    echo "  shrink-only check: skipped (origin/main copy unreadable)"
fi

n_detected="$(grep -c . <<<"$detected" || true)"
echo "  detected non-export writers: ${n_detected:-0} (all must be allowlisted)"

if [[ "$fail" -ne 0 ]]; then
    echo
    for f in "${FAILS[@]}"; do echo "  FAIL $f"; done
    echo "FAIL: docs/gaps/*.yaml must be written only by the export path (INFRA-8193)"
    exit 1
fi
echo "PASS: docs/gaps/*.yaml is export-only (INFRA-8193)"
exit 0
