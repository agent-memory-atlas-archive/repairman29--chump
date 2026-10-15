#!/usr/bin/env bash
# RESILIENT-1592 (R2): _detect_ship_evidence prefers the typed closed_pr FK over title regex.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
eval "$(sed -n '/^_detect_ship_evidence() {/,/^}/p' "$REPO_ROOT/scripts/dispatch/worker.sh")"
_shim="$(mktemp -d)"; export PATH="$_shim:$PATH"
printf '#!/usr/bin/env bash\necho "  status: open"\necho "  closed_pr: 777"\n' > "$_shim/chump"
printf '#!/usr/bin/env bash\necho ""\n' > "$_shim/gh"
chmod +x "$_shim"/*
export REPO_ROOT="$(mktemp -d)"
out="$(_detect_ship_evidence GAP-X chump/b 100)"; rc=$?
[[ $rc -eq 0 && "$out" == "777" ]] || { echo "FAIL: FK above HWM rc=$rc out=$out"; exit 1; }
out="$(_detect_ship_evidence GAP-X chump/b 900)"; rc=$?
[[ $rc -ne 0 ]] || { echo "FAIL: FK below HWM accepted"; exit 1; }
echo "PASS"
