#!/usr/bin/env bash
# scripts/coord/lib/converge-mirror.sh — RESILIENT-001
#
# Canonical "make this pure BUILD-MIRROR working tree current with a ref"
# primitive. Source it, then call `converge_mirror_hard_reset <ref>` from inside
# the mirror checkout instead of ever advancing a node's tree with a merge
# (`git pull`, `git pull --ff-only`, `git merge`).
#
# WHY THIS EXISTS — the RESILIENT-001 jam (confirmed live):
#   Fleet nodes check out the repo at $HOME/chump, and the running fleet DROPS
#   generated files INTO that working tree — untracked docs/gaps/<ID>.yaml gap
#   mirrors, local `chore(backlog)` auto-commits, regenerable .chump/*.db. When
#   origin/main later carries a COMMITTED version of one of those same paths, a
#   merge-based advance ABORTS:
#       error: The following untracked working tree files would be overwritten
#       by merge:  docs/gaps/NEW.yaml
#   The advance no-ops, the git error is usually swallowed (…"offline or
#   conflict"…), and the node silently sits stale for hours/days — so NO merged
#   fix (a path fix, a verifier, a ratchet) ever reaches the iron. cuphead sat
#   ~4h stale and mugman ~2 DAYS stale on exactly this before a hand
#   `git reset --hard origin/main` broke the deadlock.
#
# THE FIX — converge with `git reset --hard <ref>`, never a merge:
#   Unlike a merge, `git reset --hard` OVERWRITES untracked files that collide
#   with incoming tracked paths (verified for both file/file AND dir/file
#   collisions) and DISCARDS local regenerable commits, while NEVER touching
#   gitignored files. On these nodes that is exactly the right operation: they
#   are pure build mirrors with no operator WIP, gaps live in .chump/state.db
#   (rebuilt from origin's .chump/state.sql), and live claims live in NATS-KV —
#   so the discarded docs/gaps/*.yaml mirrors and chore(backlog) commits are all
#   regenerable (see scripts/coord/backlog-sync.sh's header).
#
# SAFETY:
#   * Call this ONLY on a pure mirror checkout. It is destructive to local
#     commits and to tracked working-tree edits BY DESIGN — that is the point.
#   * It preserves gitignored files: it does a `git reset --hard`, never a
#     `git clean -x`, so .chump/state.db (and its -wal/-shm) and every other
#     ignored runtime DB are left untouched — a live DB write is not corrupted.
#   * It is idempotent: converging an already-current tree is a clean no-op.

# converge_mirror_hard_reset <ref>
#   Advance the CURRENT working tree (cwd must be inside the mirror) to <ref>,
#   surviving a dirty tree of generated/untracked files. Reports (to stderr)
#   what divergence it had to discard, so the previously-silent jam class is
#   auditable instead of masquerading as a no-op. Returns `git reset`'s exit
#   status (0 on convergence).
converge_mirror_hard_reset() {
    local ref="${1:-}"
    if [ -z "$ref" ]; then
        printf '[converge-mirror] ERROR: missing ref argument\n' >&2
        return 2
    fi

    # Diagnostics BEFORE the reset so a converge that had to discard local
    # divergence is visible in the log. The old merge-based advance swallowed
    # this and looked exactly like a benign no-op.
    local ahead untracked
    ahead="$(git rev-list --count "$ref"..HEAD 2>/dev/null || echo 0)"
    untracked="$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')"
    case "$ahead" in ''|*[!0-9]*) ahead=0 ;; esac
    case "$untracked" in ''|*[!0-9]*) untracked=0 ;; esac

    if [ "$ahead" -gt 0 ]; then
        printf '[converge-mirror] discarding %s local commit(s) not on %s (regenerable: gaps live in state.db, claims in NATS-KV)\n' \
            "$ahead" "$ref" >&2
    fi
    if [ "$untracked" -gt 0 ]; then
        printf '[converge-mirror] %s untracked file(s) present; any that collide with tracked paths at %s are overwritten (regenerable gap mirrors)\n' \
            "$untracked" "$ref" >&2
    fi

    # RESILIENT-1217: a mirror converging to origin/main must END on branch
    # main. A bare `reset --hard` drags whatever branch (or detached HEAD) was
    # left checked out to origin/main instead of returning to main.
    if [ "$ref" = "origin/main" ]; then
        local cur
        cur="$(git symbolic-ref --short -q HEAD 2>/dev/null || true)"
        if [ "$cur" != "main" ]; then
            printf '[converge-mirror] on %s, not main — switching back to main\n' "${cur:-detached HEAD}" >&2
            if ! git checkout -q -f -B main "$ref"; then
                printf '[converge-mirror] WARN: could not switch to main; resetting in place\n' >&2
            fi
        fi
    fi

    # reset --hard converges over untracked collisions a merge would refuse,
    # and leaves gitignored runtime DBs untouched. Must always run (even after
    # checkout -B above) to guarantee untracked collisions are overwritten.
    git reset --hard "$ref"
}
