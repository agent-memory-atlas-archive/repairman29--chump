# MISSION-125 — re-filed duplicate

MISSION-125 (auto-discovery & auto-adopt) was already delivered by #5245:
`scripts/ops/auto-adopt.sh` + `scripts/ci/test-auto-adopt.sh`.

Re-verified at HEAD `2989c2447`: `bash scripts/ci/test-auto-adopt.sh` passes
clean (AC1-AC4: discover subscription, tool fetch, registry integration,
`auto-consume adopted <capability>` log). No new code needed.

Second re-file re-verified at HEAD `9ca6d26aa`: `scripts/ci/test-auto-adopt.sh`
still passes clean. Still no new code needed; close as duplicate of #5245.

Third re-file re-verified at HEAD `b1e6f9507`: `scripts/ci/test-auto-adopt.sh` still passes clean. No new code needed; duplicate of #5245.

Fourth re-file re-verified at HEAD `d0c777cb0`: `scripts/ci/test-auto-adopt.sh` still passes clean. No new code needed; duplicate of #5245.

Fifth re-file re-verified at HEAD `a4d40f9d4`: `scripts/ci/test-auto-adopt.sh` still passes clean. No new code needed; duplicate of #5245.
