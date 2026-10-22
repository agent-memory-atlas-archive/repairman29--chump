#!/usr/bin/env bash
# architect-lease.sh — RESILIENT-1634 (PHASE-R): the cross-host single-architect lease.
#
# WHY: the cuphead architect tick (scripts/dispatch/architect-tick.sh) takes a
# local flock, but a Mac desktop architect session never takes cuphead's local
# flock, so the flock alone cannot keep the two from running at once. This
# helper is the SHARED lock: a heartbeat ref on origin that every architect
# (the cuphead tick AND a desktop session) writes and reads.
#
#   refs/architect-lease/<host>/<epoch>   (points at origin/main's tip sha)
#
# The epoch in the ref name IS the heartbeat time. A lease is FRESH while
# now - epoch < 2400 s (40 minutes: one 30-minute tick plus slack). A future
# epoch (clock skew) counts as fresh. The TTL is a constant on purpose: an env
# knob that shrinks it would be a way to switch the exclusion off.
#
# Reads and writes go through `gh api` (the git refs REST API), never `git push`,
# so no pre-push hook runs and no branch is touched.
#
# Subcommands:
#   check       exit 0 when no OTHER host holds a fresh lease;
#               exit 3 when one does (prints "held host=<h> age_s=<n>");
#               exit 4 when the leases cannot be read (fail closed).
#   heartbeat   write a fresh lease for THIS host, delete this host's older
#               leases, then re-check. exit 0 ok; exit 3 if another host's fresh
#               lease is visible (our new lease is withdrawn, so both back off);
#               exit 4 if the lease could not be written or read.
#   release     delete every lease ref for THIS host. exit 0 always.
#   help
#
# A DESKTOP architect session is excluded ONLY if it uses this helper: run
# `scripts/dispatch/architect-lease.sh check` before acting (stand down on exit 3)
# and `scripts/dispatch/architect-lease.sh heartbeat` once per loop iteration
# (and `release` when it ends). A desktop session that never runs it is NOT
# excluded: the tick cannot see it.
set -uo pipefail

LEASE_NS="architect-lease"
LEASE_TTL_S=2400

host_id() {
    local h
    h="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo node)"
    h="$(printf '%s' "$h" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
    h="${h##-}"; h="${h%%-}"
    [[ -n "$h" ]] || h=node
    printf '%s' "$h"
}

SELF_HOST="$(host_id)"

# list_leases — print "<host> <epoch>" for every lease ref on origin.
# Returns non-zero when the read itself fails (so callers can fail closed).
list_leases() {
    local out rc
    out="$(gh api "repos/{owner}/{repo}/git/matching-refs/${LEASE_NS}/" --jq '.[].ref' 2>/dev/null)"
    rc=$?
    (( rc == 0 )) || return 4
    local ref rest host epoch
    while IFS= read -r ref; do
        [[ -n "$ref" ]] || continue
        rest="${ref#refs/${LEASE_NS}/}"
        host="${rest%%/*}"
        epoch="${rest#*/}"
        [[ "$host" =~ ^[a-z0-9-]+$ && "$epoch" =~ ^[0-9]+$ ]] || continue
        printf '%s %s\n' "$host" "$epoch"
    done <<< "$out"
    return 0
}

# other_fresh — print the freshest OTHER-host lease as "<host> <age_s>" and
# return 0 when one exists; return 1 when none; 4 when unreadable.
other_fresh() {
    local leases now host epoch age best_host="" best_age=""
    leases="$(list_leases)" || return 4
    now="$(date +%s)"
    while read -r host epoch; do
        [[ -n "${host:-}" ]] || continue
        [[ "$host" == "$SELF_HOST" ]] && continue
        age=$(( now - epoch ))
        (( age < 0 )) && age=0
        if (( age < LEASE_TTL_S )); then
            if [[ -z "$best_age" ]] || (( age < best_age )); then
                best_host="$host"; best_age="$age"
            fi
        fi
    done <<< "$leases"
    [[ -n "$best_host" ]] || return 1
    printf '%s %s\n' "$best_host" "$best_age"
    return 0
}

delete_ref() { # <host> <epoch>
    gh api -X DELETE "repos/{owner}/{repo}/git/refs/${LEASE_NS}/$1/$2" --silent >/dev/null 2>&1
}

cmd_check() {
    local held rc h a
    held="$(other_fresh)"; rc=$?
    case "$rc" in
        0) read -r h a <<< "$held"; printf 'held host=%s age_s=%s\n' "$h" "$a"; return 3 ;;
        1) echo "clear"; return 0 ;;
        *) echo "unreadable"; return 4 ;;
    esac
}

cmd_heartbeat() {
    local sha now leases host epoch
    sha="$(gh api "repos/{owner}/{repo}/commits/main" --jq '.sha' 2>/dev/null)"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "write-failed (no main sha)"; return 4; }
    now="$(date +%s)"
    if ! gh api "repos/{owner}/{repo}/git/refs" -X POST \
            -f "ref=refs/${LEASE_NS}/${SELF_HOST}/${now}" -f "sha=${sha}" --silent >/dev/null 2>&1; then
        echo "write-failed"
        return 4
    fi
    # Drop this host's older leases so the namespace stays one ref per host.
    if leases="$(list_leases)"; then
        while read -r host epoch; do
            [[ "${host:-}" == "$SELF_HOST" && "$epoch" != "$now" ]] && delete_ref "$host" "$epoch"
        done <<< "$leases"
    fi
    # Re-check after writing: if another host's fresh lease is visible, withdraw
    # ours so a simultaneous start backs off on both sides (never both run).
    local held rc h a
    held="$(other_fresh)"; rc=$?
    case "$rc" in
        0) delete_ref "$SELF_HOST" "$now"
           read -r h a <<< "$held"; printf 'held host=%s age_s=%s\n' "$h" "$a"; return 3 ;;
        1) printf 'lease refs/%s/%s/%s\n' "$LEASE_NS" "$SELF_HOST" "$now"; return 0 ;;
        *) echo "unreadable"; return 4 ;;
    esac
}

cmd_release() {
    local leases host epoch
    leases="$(list_leases)" || { echo "unreadable"; return 0; }
    while read -r host epoch; do
        [[ "${host:-}" == "$SELF_HOST" ]] && delete_ref "$host" "$epoch"
    done <<< "$leases"
    echo "released"
    return 0
}

case "${1:-help}" in
    check)     cmd_check ;;
    heartbeat) cmd_heartbeat ;;
    release)   cmd_release ;;
    help|-h|--help)
        sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "usage: $0 check|heartbeat|release" >&2; exit 2 ;;
esac
