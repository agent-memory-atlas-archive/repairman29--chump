# MISSION-125 — re-filed duplicate

MISSION-125 (auto-discovery & auto-adopt) was already delivered by #5245:
`scripts/ops/auto-adopt.sh` + `scripts/ci/test-auto-adopt.sh`.

Re-verified at HEAD `2989c2447`: `bash scripts/ci/test-auto-adopt.sh` passes
clean (AC1-AC4: discover subscription, tool fetch, registry integration,
`auto-consume adopted <capability>` log). No new code needed.
