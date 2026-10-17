#!/usr/bin/env bash
# scripts/setup/lib/node-admission-ceiling.sh — RESILIENT-1604
#
# The installer side of the node-wide admission ceiling. `chump admit`
# (src/admit.rs, INFRA-8219 / RESILIENT-1611) enforces how many `claude -p`
# and cargo/rustc jobs may run on a node at once; its ceiling comes from the
# process env, then ~/.chump/node.env, then an nproc-derived default. On
# cuphead (nproc=4) node.env carried neither key, so nothing on the node said
# what the ceiling was, and 9 worker.sh + 8 claude -p ran at load 12-16
# (receipt 2026-10-16, RESILIENT-1604).
#
# This lib pins the ceiling into node.env so it is visible and tunable:
#
#   CHUMP_MAX_CONCURRENT_CLAUDE      = max(1, nproc / 2)   node worker count:
#                                      concurrent `claude -p` across worker.sh,
#                                      dispatch and every organ
#   CHUMP_MAX_CONCURRENT_CARGO_JOBS  = max(1, nproc / 2)   concurrent cargo/rustc
#
# Formula: integer nproc/2, floor 1 (4 cores -> 2 and 2; 1 core -> 1 and 1;
# 16 cores -> 8 and 8). It is the same default src/admit.rs applies when the
# key is absent, so writing it changes no behavior on a fresh node; it makes
# the number explicit so an operator can lower or raise it in one place.
# Half the cores for each class leaves headroom for the organs' own shells
# and keeps load1 under 2x nproc (AC3), which a worker-count-only cap did not.
#
# Shared by the installer (write_node_env) and the converge organ
# (scripts/ops/node-converge.sh) so a node installed before this landed
# self-heals on its next tick. Idempotent and append-only: a key already
# present in node.env (any positive integer, operator-tuned or not) is never
# rewritten. Pure glue: nproc/sysctl + grep + printf, no caller helpers, so
# scripts/ci can source it and drive it against a fixture node.env.

_chump_admission_ceiling_keys="CHUMP_MAX_CONCURRENT_CLAUDE CHUMP_MAX_CONCURRENT_CARGO_JOBS"

# chump_node_cores — online CPU count: nproc, else sysctl hw.ncpu (macOS), else 1.
chump_node_cores() {
    local n
    n="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
    case "$n" in '' | *[!0-9]*) n=1 ;; esac
    [ "$n" -ge 1 ] || n=1
    echo "$n"
}

# chump_admission_default_ceiling [cores] — max(1, cores / 2).
chump_admission_default_ceiling() {
    local cores="${1:-$(chump_node_cores)}"
    case "$cores" in '' | *[!0-9]*) cores=1 ;; esac
    local half=$((cores / 2))
    [ "$half" -ge 1 ] || half=1
    echo "$half"
}

# _chump_env_file_int <file> <key> — last positive-integer assignment of key
# in a sourced env file (`KEY=n` or `export KEY=n`, quotes and inline
# comments stripped), or empty.
_chump_env_file_int() {
    local file="$1" key="$2" line val=""
    [ -f "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line#export }"
        case "$line" in "$key="*) ;; *) continue ;; esac
        line="${line#"$key="}"
        line="${line%%#*}"
        line="${line//\"/}"
        line="${line//\'/}"
        line="${line//[[:space:]]/}"
        case "$line" in '' | *[!0-9]*) continue ;; esac
        [ "$line" -ge 1 ] && val="$line"
    done < "$file"
    printf '%s' "$val"
}

# chump_admission_ceiling_for <key> <node_env> — the ceiling the node runs
# under, with src/admit.rs precedence: process env > node.env > default.
chump_admission_ceiling_for() {
    local key="$1" node_env="$2" v
    v="${!key:-}"
    case "$v" in '' | *[!0-9]*) v="" ;; esac
    if [ -n "$v" ] && [ "$v" -ge 1 ]; then
        echo "$v"
        return 0
    fi
    v="$(_chump_env_file_int "$node_env" "$key")"
    if [ -n "$v" ]; then
        echo "$v"
        return 0
    fi
    chump_admission_default_ceiling
}

# chump_ensure_admission_ceiling <node_env>
#
# Appends `export KEY=<max(1, nproc/2)>` for each ceiling key node_env lacks.
# Never rewrites a key that is present. Prints the keys it wrote as
# `KEY=value` lines (nothing when already complete). Returns:
#   0  — already complete, nothing written
#   10 — one or more keys appended
#   11 — write failed
#   2  — missing arg / node_env does not exist (not an installed node)
chump_ensure_admission_ceiling() {
    local node_env="${1:-}" key def wrote=0
    [ -n "$node_env" ] && [ -f "$node_env" ] || return 2
    def="$(chump_admission_default_ceiling)"
    for key in $_chump_admission_ceiling_keys; do
        [ -n "$(_chump_env_file_int "$node_env" "$key")" ] && continue
        # A file that does not end in a newline would glue the export onto
        # its last line.
        if [ -s "$node_env" ] && [ -n "$(tail -c 1 "$node_env")" ]; then
            printf '\n' >> "$node_env" || return 11
        fi
        printf 'export %s=%s\n' "$key" "$def" >> "$node_env" || return 11
        printf '%s=%s\n' "$key" "$def"
        wrote=1
    done
    [ "$wrote" = 1 ] && return 10
    return 0
}
