#!/usr/bin/env bash
# RESILIENT-600: floor-config.json overrides stale providers.env/launcher ladder.
set -u
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
H="$(mktemp -d)"; mkdir -p "$H/.chump"
echo 'CHUMP_MODEL_ESCALATION_LADDER=stale/a,stale/b
OPENROUTER_API_KEY=sk-test' > "$H/.chump/providers.env"
out="$(HOME="$H" REPO_ROOT="$R" CHUMP_MODEL_ESCALATION_LADDER=stale/x bash -c 'source "$REPO_ROOT/scripts/setup/load-floor-config.sh"; echo "$CHUMP_MODEL_ESCALATION_LADDER|$OPENAI_MODEL|$OPENAI_API_KEY"')"
want="$(jq -r '(.escalation_ladder|join(","))+"|"+.floor_model' "$R/scripts/setup/floor-config.json")|sk-test"
rm -rf "$H"
[[ "$out" == "$want" ]] && echo "[PASS] floor-config wins ($out)" || { echo "[FAIL] got '$out' want '$want'"; exit 1; }
grep -q load-floor-config.sh "$R/scripts/dispatch/worker.sh" && echo "[PASS] worker.sh wired" || { echo "[FAIL] worker.sh not wired"; exit 1; }
