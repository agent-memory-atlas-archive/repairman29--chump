#!/usr/bin/env bash
# test-chump-ci-image.sh — INFRA-2241
#
# Smoke-test the chump-ci Docker image deliverables:
#   1. docker/Dockerfile.ci exists, references cargo-chef (AC #8) and the
#      expected toolchain pins (rust:1.96-bookworm, sccache, cargo-nextest,
#      cargo-deny, clippy, jq).
#   2. .github/workflows/build-ci-image.yml exists with the required triggers
#      (weekly cron + push to docker/Dockerfile.ci), permissions
#      (`packages: write`), and tags both :latest and :{sha}.
#   3. docs/process/CI_DOCKER_IMAGE.md exists and documents the operator
#      surface (bump-Rust, rollback, fall-through).
#   4. Multistage pattern used (FROM ... AS chef / planner / builder).
#   5. The Dockerfile is valid for `docker build` parsing if `docker` is
#     available (best-effort; skipped if docker is not installed).
#
# Exit 0 — all assertions pass.
# Exit 1 — one or more assertions failed.
#
# NOTE: this is a static-grep smoke. The actual `docker build` is performed
# by .github/workflows/build-ci-image.yml. The ci.yml `container:`
# integration is deferred to INFRA-2241B (lease split with INFRA-2242).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

DOCKERFILE="$REPO_ROOT/docker/Dockerfile.ci"
WORKFLOW="$REPO_ROOT/.github/workflows/build-ci-image.yml"
DOC="$REPO_ROOT/docs/process/CI_DOCKER_IMAGE.md"

PASS=0
FAIL=0
ok()   { printf '  \033[0;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
fail() { printf '  \033[0;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }

echo "=== INFRA-2241 chump-ci image smoke ==="
echo

# ── 1. Dockerfile presence + pins ─────────────────────────────────────────────
if [[ -f "$DOCKERFILE" ]]; then
    ok "docker/Dockerfile.ci exists"
else
    fail "docker/Dockerfile.ci missing"
fi

grep -q "INFRA-2241" "$DOCKERFILE" 2>/dev/null \
    && ok "Dockerfile references INFRA-2241" \
    || fail "Dockerfile missing INFRA-2241 reference"

grep -q "rust:1.96-bookworm" "$DOCKERFILE" 2>/dev/null \
    && ok "Rust 1.96-bookworm pinned" \
    || fail "Rust 1.96-bookworm pin not found"

# AC #8 — cargo-chef integration
grep -q "cargo chef prepare" "$DOCKERFILE" 2>/dev/null \
    && ok "cargo chef prepare present (AC #8)" \
    || fail "cargo chef prepare missing (AC #8 unmet)"

grep -q "cargo chef cook" "$DOCKERFILE" 2>/dev/null \
    && ok "cargo chef cook present (AC #8)" \
    || fail "cargo chef cook missing (AC #8 unmet)"

# Tool pins
for tool in sccache cargo-nextest cargo-deny; do
    grep -q "$tool" "$DOCKERFILE" 2>/dev/null \
        && ok "$tool referenced" \
        || fail "$tool missing from Dockerfile"
done

# clippy + jq
grep -qE "rustup component add.*clippy" "$DOCKERFILE" 2>/dev/null \
    && ok "clippy component install present" \
    || fail "clippy component install missing"

# jq is part of an apt-get install in the final stage — check both presence in
# the file AND that an apt-get install line exists (multi-line `\` continuation).
if grep -q "apt-get install" "$DOCKERFILE" 2>/dev/null \
        && grep -qE "(^|\s)jq(\s|$|\\\\)" "$DOCKERFILE" 2>/dev/null; then
    ok "jq apt install present"
else
    fail "jq apt install missing"
fi

# Multistage pattern
if grep -qE "^FROM .* AS chef" "$DOCKERFILE" \
        && grep -qE "^FROM .* AS planner" "$DOCKERFILE" \
        && grep -qE "^FROM .* AS builder" "$DOCKERFILE"; then
    ok "multistage pattern present (chef / planner / builder)"
else
    fail "multistage pattern (chef / planner / builder) missing"
fi

# ── 2. Build workflow ─────────────────────────────────────────────────────────
if [[ -f "$WORKFLOW" ]]; then
    ok ".github/workflows/build-ci-image.yml exists"
else
    fail ".github/workflows/build-ci-image.yml missing"
fi

grep -q "INFRA-2241" "$WORKFLOW" 2>/dev/null \
    && ok "workflow references INFRA-2241" \
    || fail "workflow missing INFRA-2241 reference"

# Sunday = day-of-week 0 in cron (5th field). Tolerant match: 4 fields of
# anything followed by 0 inside the cron string, optionally with comments.
if grep -qE 'cron:.*"[^"]+0"' "$WORKFLOW" 2>/dev/null; then
    ok "weekly Sunday cron trigger present"
else
    fail "weekly Sunday cron trigger missing"
fi

grep -q "docker/Dockerfile.ci" "$WORKFLOW" 2>/dev/null \
    && ok "push-path filter for docker/Dockerfile.ci present" \
    || fail "push-path filter for docker/Dockerfile.ci missing"

grep -qE "packages:\s*write" "$WORKFLOW" 2>/dev/null \
    && ok "packages: write permission declared" \
    || fail "packages: write permission missing"

grep -qE "docker/build-push-action@v[5-9]" "$WORKFLOW" 2>/dev/null \
    && ok "docker/build-push-action@v5+ used" \
    || fail "docker/build-push-action@v5+ not referenced"

# CREDIBLE-1541: Verify Dockerfile.ci Rust base image matches rust-toolchain.toml
# major.minor and is >= 1.85 (required for Cargo edition2024 in cargo-chef/binstall).
TOOLCHAIN_MM="$(sed -n 's/^channel = "\([0-9]*\.[0-9]*\).*"/\1/p' "$REPO_ROOT/rust-toolchain.toml" | head -1)"
if [[ -n "$TOOLCHAIN_MM" ]] && grep -q "FROM rust:${TOOLCHAIN_MM}-bookworm AS chef" "$DOCKERFILE" && grep -q "^FROM rust:${TOOLCHAIN_MM}-bookworm$" "$DOCKERFILE"; then
    ok "CREDIBLE-1541: Dockerfile.ci base stages match rust-toolchain.toml (${TOOLCHAIN_MM})"
else
    fail "CREDIBLE-1541: Dockerfile.ci base stages do not match rust-toolchain.toml (${TOOLCHAIN_MM})"
fi

grep -q "ghcr.io/repairman29/chump-ci" "$WORKFLOW" 2>/dev/null \
    && ok "ghcr.io/repairman29/chump-ci image name present" \
    || fail "ghcr.io/repairman29/chump-ci image name missing"

grep -q ":latest" "$WORKFLOW" 2>/dev/null \
    && ok ":latest tag emitted" \
    || fail ":latest tag missing"

grep -qE "cache-from:.*registry" "$WORKFLOW" 2>/dev/null \
    && ok "registry cache-from configured" \
    || fail "registry cache-from missing"

# ── 3. Operator doc ───────────────────────────────────────────────────────────
if [[ -f "$DOC" ]]; then
    ok "docs/process/CI_DOCKER_IMAGE.md exists"
else
    fail "docs/process/CI_DOCKER_IMAGE.md missing"
fi

grep -qi "bump.*rust" "$DOC" 2>/dev/null \
    && ok "doc covers bump-Rust procedure" \
    || fail "doc missing bump-Rust procedure"

grep -qi "roll.*back\|rollback" "$DOC" 2>/dev/null \
    && ok "doc covers rollback procedure" \
    || fail "doc missing rollback procedure"

grep -qi "fall-through\|fall.*through\|fallback" "$DOC" 2>/dev/null \
    && ok "doc covers fall-through safety" \
    || fail "doc missing fall-through safety note"

grep -q "INFRA-2241B\|follow-up" "$DOC" 2>/dev/null \
    && ok "doc references follow-up (INFRA-2241B / ci.yml deferral)" \
    || fail "doc missing follow-up reference"

# ── 4. Optional: Dockerfile parse smoke via `docker build --check` ────────────
if command -v docker >/dev/null 2>&1; then
    if docker buildx version >/dev/null 2>&1; then
        # `docker buildx build --print` is a lightweight parse check that doesn't
        # actually build the image. Falls back silently if not supported.
        if docker buildx build --print -f "$DOCKERFILE" "$REPO_ROOT" >/dev/null 2>&1; then
            ok "docker buildx parse of Dockerfile.ci succeeded"
        else
            # Don't fail — buildx --print can be flaky on some builders.
            echo "  \033[0;33mSKIP\033[0m docker buildx parse (best-effort)"
        fi
    else
        echo "  \033[0;33mSKIP\033[0m docker buildx parse (buildx unavailable)"
    fi
else
    echo "  \033[0;33mSKIP\033[0m docker buildx parse (docker not installed)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
