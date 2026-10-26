# CI Gates Inventory & Scoped CI Path-Gate Contract (RESILIENT-1553)

> Canonical inventory: [`docs/process/CI_GATES_INVENTORY.md`](../process/CI_GATES_INVENTORY.md)

## Scoped CI Path-Gate Contract (RESILIENT-1553)

Every path-scoped CI gate in `.github/workflows/ci.yml` (`dorny/paths-filter` under the `changes` job) and every `scripts/ci/test-*.sh` gate MUST obey the **Scoped CI Path-Gate Contract**:

1. **Trigger paths & diff scoping (`git diff origin/main...HEAD`)**:
   - A gate that checks files modified by a PR MUST scope its scan to `git diff --name-only origin/main...HEAD` (with fallback to `HEAD~1..HEAD` on shallow clones) rather than scanning the entire repository unconditionally when a pre-existing violation on `origin/main` is unrelated to the PR's touched files.
   - Any new path-filtered job in `.github/workflows/ci.yml` MUST have a corresponding `-stub` job (`if: always() && needs.changes.outputs.<filter> != 'true'`) and a `-required` rollup job so branch protection and `verified` never hang on a skipped path-filtered check (`scripts/ci/check-path-filter-coverage.sh`).
2. **Baseline allowlist / ratchet**:
   - Gates that audit a global repository invariant (e.g., `scripts/ci/env-vars-internal.txt`, `scripts/ci/raw-gh-allowlist.txt`, `scripts/ci/coe-pr-reporting-allowlist.txt`, `docs/observability/EVENT_REGISTRY.yaml`) MUST either maintain an explicit baseline allowlist / ratchet ceiling or fail only on net-new violations introduced in `origin/main...HEAD`.
   - Unrelated PRs (e.g., docs-only or single-script fixes) MUST NOT be blocked by pre-existing drift outside their diff scope.
3. **Local preflight parity (`chump preflight`)**:
   - Every deterministic per-PR CI gate MUST either be mirrored in `crates/chump-preflight/src/preflight.rs` (`discover_test_scripts` / `scripts/ci/preflight-extra-test-scripts.txt`) or have a documented Tier-D / exceptions-file rationale in `scripts/ci/preflight-ci-parity-exceptions.txt` (`scripts/ci/test-preflight-ci-parity.sh`).
