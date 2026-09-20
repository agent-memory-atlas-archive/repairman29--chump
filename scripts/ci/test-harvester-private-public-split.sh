#!/usr/bin/env bash
# test-harvester-private-public-split.sh
#
# This repo is public. `harvest.sh scan` must put private repos ONLY in the operator catalog
# (CHUMP_ARSENAL_DIR, outside the tree) and build the committed catalog from PUBLIC repos alone,
# with no local paths. Calls harvest.sh directly with a fake `gh`, so it needs no chump binary
# and never touches a real ~/.chump.
#
# DEPTH: happy-path + edge. Covers: visibility split, exclude list (case-insensitive, comments),
# fail-closed on a broken gh response, read-side fallback when no operator catalog exists,
# high-severity alert exit. GAPS: does not exercise build.py's local-clone scan (needs real
# clones); does not test the `chump harvest` Rust wrapper (test-harvester-cli.sh does).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
F="$(mktemp -d)"; SHIM="$(mktemp -d)"; trap 'rm -rf "$F" "$SHIM"' EXIT
fail=0; ok() { echo "  PASS: $1"; }; bad() { echo "  FAIL: $1"; fail=1; }
mkdir -p "$F/scripts/arsenal" "$F/docs/arsenal/raw"
cp "$ROOT/scripts/arsenal/harvest.sh" "$ROOT/scripts/arsenal/build.py" "$F/scripts/arsenal/"
[ -f "$ROOT/scripts/arsenal/primitive_signatures.json" ] && cp "$ROOT/scripts/arsenal/primitive_signatures.json" "$F/scripts/arsenal/"
export CHUMP_ARSENAL_DIR="$F/.operator" CHUMP_ARSENAL_CURATION="$F/.none.json" HOME="$F/home"; mkdir -p "$HOME"
repo() { printf '{"name":"%s","description":"%s","primaryLanguage":{"name":"Rust"},"visibility":"%s","pushedAt":"2026-01-01","isArchived":false,"isFork":false,"sshUrl":"git@example.com:x/%s.git","url":"https://example.com/%s","createdAt":"2026-01-01","updatedAt":"2026-01-01","diskUsage":1,"repositoryTopics":[]}' "$1" "$2" "$3" "$1" "$1"; }
cat > "$SHIM/gh" <<SH
#!/usr/bin/env bash
[ "\$1" = repo ] && [ "\$2" = list ] && { echo '[$(repo open-one "fine to show" PUBLIC),$(repo Quiet-One "must stay private" PRIVATE),$(repo Withheld-One "must not appear anywhere" PRIVATE)]'; exit 0; }
exit 1
SH
chmod +x "$SHIM/gh"
printf '# names the operator withholds\n  withheld-one  \n' > "$F/exclude.txt"; export CHUMP_ARSENAL_EXCLUDE_FILE="$F/exclude.txt"

# read side, before any scan: falls back to the public catalog instead of dying on a missing operator one
echo '{"metadata":{},"clusters":{},"duplications":[],"alerts":[],"primitives_index":{},"repos_by_name":{"open-one":{"name":"open-one","description":"fine to show","primitives":[]}},"unmatched_local_roots":[]}' > "$F/docs/arsenal/GLOBAL_ARSENAL.json"
bash "$F/scripts/arsenal/harvest.sh" check "fine to show" >/dev/null 2>&1 && ok "read side falls back to the public catalog on a fresh clone" || bad "check failed with no operator catalog"

PATH="$SHIM:$PATH" bash "$F/scripts/arsenal/harvest.sh" scan >"$F/scan.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "scan exits 0" || { bad "scan exit $rc"; sed 's/^/      /' "$F/scan.out" | tail -5; }
pub="$F/docs/arsenal"; op="$F/.operator"
names() { jq -r '.repos_by_name | keys | join(",")' "$1/GLOBAL_ARSENAL.json" 2>/dev/null; }
[ "$(names "$pub")" = "open-one" ] && ok "public catalog lists only the PUBLIC repo" || bad "public catalog has: $(names "$pub")"
[ "$(names "$op")" = "Quiet-One,open-one" ] && ok "operator catalog has public + private, minus the excluded one" || bad "operator catalog has: $(names "$op")"
grep -r -q -i "quiet-one\|must stay private" "$pub" && bad "a private repo leaked into the public tree" || ok "no private name or description anywhere under docs/arsenal"
grep -r -q -i "withheld-one\|must not appear" "$pub" "$op" && bad "an excluded repo was written somewhere" || ok "excluded repo is in neither catalog (case-insensitive, comment and whitespace tolerated)"
[ "$(jq -r '.metadata.scope' "$pub/GLOBAL_ARSENAL.json")" = "public repos only" ] && ok "public catalog declares its scope" || bad "scope missing"
[ "$(jq '[.repos_by_name[] | select(.local_clone != null)] | length' "$pub/GLOBAL_ARSENAL.json")" = "0" ] && [ "$(jq '.unmatched_local_roots | length' "$pub/GLOBAL_ARSENAL.json")" = "0" ] && ok "public catalog carries no local clone paths or local roots" || bad "local paths in the public catalog"
grep -q "$F\|/Users/\|/home/" "$pub/GLOBAL_ARSENAL.json" "$pub/GLOBAL_ARSENAL.md" 2>/dev/null && bad "an absolute path reached the public catalog" || ok "no absolute paths in the public catalog"

# fail closed: a broken gh response must not leave a half-written or unfiltered catalog
cp "$pub/raw/github_repos.json" "$F/pub-before.json"
printf '#!/usr/bin/env bash\necho not-json\n' > "$SHIM/gh"
PATH="$SHIM:$PATH" bash "$F/scripts/arsenal/harvest.sh" scan >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && cmp -s "$pub/raw/github_repos.json" "$F/pub-before.json" && ok "broken gh response: non-zero exit, public catalog untouched" || bad "broken gh response was not handled closed (exit $rc)"

# high-severity alert in the operator catalog still fails the scan, though the public catalog has no alerts
cat > "$F/scripts/arsenal/build.py" <<'PY'
import json, os, pathlib
d = pathlib.Path(os.environ["CHUMP_ARSENAL_DIR"]); d.mkdir(parents=True, exist_ok=True)
alerts = [] if os.environ.get("CHUMP_ARSENAL_PUBLIC_ONLY") == "1" else [{"severity": "high", "kind": "embedded_token", "action": "rotate"}]
(d / "GLOBAL_ARSENAL.json").write_text(json.dumps({"metadata": {}, "clusters": {}, "duplications": [], "alerts": alerts, "primitives_index": {}, "repos_by_name": {}, "unmatched_local_roots": []}))
PY
cat > "$SHIM/gh" <<SH
#!/usr/bin/env bash
echo '[$(repo open-one "fine" PUBLIC)]'
SH
PATH="$SHIM:$PATH" bash "$F/scripts/arsenal/harvest.sh" scan >/dev/null 2>&1; rc=$?
[ "$rc" -eq 5 ] && ok "high-severity operator alert: scan exits 5" || bad "expected exit 5 on a high-severity alert, got $rc"
[ "$(jq '.alerts | length' "$pub/GLOBAL_ARSENAL.json")" = "0" ] && ok "and the public catalog still publishes no alerts" || bad "alerts reached the public catalog"

[ "$fail" -eq 0 ] && echo "[test-harvester-private-public-split] PASS" || { echo "[test-harvester-private-public-split] FAIL"; exit 1; }
