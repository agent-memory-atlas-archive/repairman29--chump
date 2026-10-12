#!/usr/bin/env bash
# RESILIENT-1574: unit test for dup_close_guard_match.
set -euo pipefail
cd "$(mktemp -d)"
git init -q . && git config user.email a@b && git config user.name t
git commit -q --allow-empty -m "FOO-1: real ship (#1)"
git branch -M main
source "$OLDPWD/scripts/coord/lib/dup-close-guard.sh" 2>/dev/null || source "$(git -C "$OLDPWD" rev-parse --show-toplevel)/scripts/coord/lib/dup-close-guard.sh"
dup_close_guard_match "FOO-1: close as duplicate of already-shipped (#1)" FOO-1 main || { echo FAIL match; exit 1; }
dup_close_guard_match "FOO-1: add feature" FOO-1 main && { echo FAIL nonclose; exit 1; }
dup_close_guard_match "BAR-2: close as duplicate" BAR-2 main && { echo FAIL noship; exit 1; }
echo "PASS test-dup-close-guard"
