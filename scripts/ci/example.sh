#!/usr/bin/env bash
# Fixture for CREDIBLE-1087's grep-target-sweep — intentionally greps a path
# that is not materialized in the repo tree (it's only written at runtime by
# this same script), so the sweep always has a known finding to detect.
# The runtime write keeps scripts/ci/check-grep-target-sweep.py (CREDIBLE-787,
# a stricter sibling sweep) from double-flagging it: its is_locally_created()
# check skips any target the same script redirects output into.
set -uo pipefail

: > nonexistent/path.txt
grep -q "TODO" nonexistent/path.txt
