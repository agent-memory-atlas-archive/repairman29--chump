#!/usr/bin/env bash
# scripts/coord/lib/ship-gate-files.sh — CREDIBLE-1590: the SINGLE source of
# truth for the "true ship-gate" file globs. A change to any of these files can
# let bad code merge (a CI workflow, a git hook, the merge script itself, the
# preflight crate, or a verified-wait helper), so both ship organs treat them as
# gate files:
#
#   * the independent review organ (scripts/dispatch/review-organ-tick.sh,
#     CREDIBLE-1542) HOLDS a PR that touches one of these for a mutant-capable
#     reviewer — it cannot satisfy the mutation rule read-only; and
#   * CREDIBLE-1576's bot-merge arm guard refuses to self-arm --auto-merge on a
#     branch diff that touches a ship gate.
#
# ONE SOURCE (CREDIBLE-1590 AC3): the review organ sources THIS list verbatim.
# bot-merge.sh keeps its own literal BOT_MERGE_GATE_FILE_GLOBS because its arm
# guard is a safety input that must read NO variable at all (CREDIBLE-1576 item 5
# asserts the array is a single literal with no `$`). scripts/ci/test-arm-policy.sh
# pins the two lists to this one source: they may differ ONLY by two documented,
# intentional entries, and any other drift fails that test —
#   * bot-merge additionally gates 'scripts/ci/*' (a test change must not
#     blind-auto-merge), while the organ REVIEWS a scripts/ci test change; and
#   * this list additionally holds 'scripts/coord/bot-merge.sh' (a change to the
#     merge script itself is reviewed, never self-armed by the organ).
#
# NOT scripts/ci/*: a scripts/ci test change is REVIEWED normally by the organ
# (the organ IS the reviewer). Listing scripts/ci/* here was the CREDIBLE-1590
# bug — it turned every fleet PR (nearly all touch a scripts/ci test) into a
# blanket "needs mutants" hold, so the organ never approved and gate 4 never
# armed.
#
# CONSTANT, never read from a CHUMP_* env var (Chief standing rule 2026-10-20: no
# env override on a safety input). The unconditional assignment below wins over
# any same-named value already present in the environment.

# shellcheck disable=SC2034  # consumed by callers that source this file
CHUMP_SHIP_GATE_GLOBS=(
    '.github/workflows/*'
    'scripts/git-hooks/*'
    'scripts/coord/bot-merge.sh'
    'crates/chump-preflight/*'
    '*verified-wait*'
)

# chump_ship_gate_list_version — a stable fingerprint of the gate-file glob list
# above (CREDIBLE-1592). A ship organ that MECHANICALLY HELD a head — a
# "mutants: NOT RUN, gate-file" CHANGES REQUIRED with no model review — records
# this version in its verdict so a later tick can tell the list has since changed
# (e.g. CREDIBLE-1590 narrowed it) and re-evaluate that head instead of treating a
# stale hold as the current verdict forever. Computed ONLY from the
# CHUMP_SHIP_GATE_GLOBS constant above — never from a CHUMP_* env var (Chief
# standing rule 2026-10-20: no env override on a safety input).
chump_ship_gate_list_version() {
    printf '%s\n' "${CHUMP_SHIP_GATE_GLOBS[@]}" | cksum | awk '{print $1 "-" $2}'
}
