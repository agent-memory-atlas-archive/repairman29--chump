#!/usr/bin/env bash
# scripts/ops/node-converge.sh — RESILIENT-1189
#
# The NODE AUTO-CONVERGE organ. Keeps a fleet node's SOURCE checkout current
# with origin/main on a cadence, so a merged fix actually REACHES the iron —
# closing the "merged != deployed" loop for the whole class of BASH organs that
# a binary refresh can never deploy.
#
# WHY THIS EXISTS (the #1 systemic wound, confirmed live):
#   Nothing on the fleet converges the SOURCE checkout the organs run out of.
#   The one script that came close — scripts/ops/node-refresh-chump.sh — has a
#   binary-SHA idempotency short-circuit (RESILIENT-200): when the installed
#   `chump` binary already matches green-main it `exit 0`s BEFORE the
#   converge_mirror_hard_reset. A merged BASH-only fix (e.g. the rot-reaper fix
#   #4637, or any scripts/ops/*.sh / scripts/coord/*.sh edit) never bumps the
#   binary SHA, so node-refresh treats the node as "already current" and skips
#   the source reset entirely — the checkout stays days stale, and every organ
#   whose systemd ExecStart is `bash scripts/…/foo.sh` keeps running the OLD
#   script straight out of the stale tree. CJ's /home/jeff/Projects/chump had to
#   be hand `git reset --hard`'d to break exactly this.
#
# THE FIX — an UNCONDITIONAL, lightweight, gh-auth-INDEPENDENT source converge:
#   This organ does ONE thing on a ~10-min cadence: fetch origin/main and
#   `converge_mirror_hard_reset origin/main` (the RESILIENT-001 primitive) so
#   the working tree is byte-for-byte origin/main. It never builds, never pins
#   to green-main, never calls gh — a public-repo fetch needs no auth, and the
#   whole point is that this path can NEVER silently degrade the way
#   node-refresh's gh-dependent green-lookup does (RESILIENT-1040/1041). Once the
#   source is converged, the EXISTING organs do the rest: a bash organ's next
#   timer firing runs the new script straight from the converged tree, and any
#   changed *.service/.timer UNIT files are installed by the separate
#   chump-organ-deploy.timer / chump-organ-reconcile.timer. This organ is only
#   the missing FIRST hop — get the source current — that everything downstream
#   already assumed was happening.
#
# RELATION TO node-refresh-chump.sh (extend, don't duplicate): that script owns
#   the BINARY (build/pull/install + green-main pin); this organ owns the SOURCE
#   TREE. They converge to almost the same ref through the SAME shared primitive
#   (converge_mirror_hard_reset), so they cannot race to different states — and
#   this organ's unconditional reset covers the exact case node-refresh skips
#   (bash-only merges that leave the binary SHA unchanged).
#
# SAFETY (active-worker-safe by construction):
#   * Resets ONLY the main checkout ($REPO_ROOT). Workers build gaps in LINKED
#     git worktrees under .claude/worktrees/* — those have their own HEAD and
#     working tree, so a `git reset --hard` in the main checkout does not touch
#     them; and .claude/worktrees/ is gitignored, so the reset never sees it as
#     a collision to overwrite either. A worker's in-flight gap is untouched.
#   * converge_mirror_hard_reset is a `git reset --hard`, never a `git clean -x`,
#     so gitignored runtime state survives: .chump/state.db (+ -wal/-shm),
#     .chump-locks/, .claude/worktrees/, per-worktree target dirs. A live DB
#     write is not corrupted.
#   * DEFERS (clean skip, no reset) if a rebase / merge / cherry-pick / bisect is
#     in progress in the main checkout — never yanks the tree out from under an
#     operator or another organ mid-operation. It just tries again next tick.
#   * Idempotent: a tree already at origin/main is a no-op (node_converge_skipped).
#
# Emits (appended to $NODE_AMBIENT if its dir exists, else logfile only):
#   node_converged          — the checkout was behind and is now at origin/main
#   node_converge_skipped   — already current / no repo / operation-in-progress
#   node_converge_failed    — fetch-then-reset failed (tree left as-is)
#
# Env overrides:
#   CHUMP_NODE_REPO   source checkout to converge (default: first of
#                     ~/chump-host, ~/Projects/Chump, ~/chump that is a git repo)
#   NODE_AMBIENT      ambient stream to append to (default: <repo>/.chump-locks/ambient.jsonl)
#   CHUMP_NODE_CONVERGE_REF   ref to converge to (default: origin/main; test hook)
#   CHUMP_NODE_CONVERGE_REMOTE / CHUMP_NODE_CONVERGE_BRANCH
#                     remote + branch to fetch (default: origin / main)
#
# NOTE: this organ deliberately adds NO skip/bypass env var (the bypass-var debt
# ceiling is capped, INFRA-3625). If a node must not converge, disable the timer.

set -uo pipefail

_CONVERGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# RESILIENT-001: the shared jam-proof mirror-converge primitive. Source it so
# this organ converges through the SAME implementation as node-refresh-chump.sh
# and backlog-sync.sh --reader — none of the three can regress to a merge-based
# advance that aborts on an untracked docs/gaps/*.yaml collision. Fallback to a
# bare reset only if the lib is missing from a partial checkout.
# shellcheck source=../coord/lib/converge-mirror.sh
source "$_CONVERGE_DIR/../coord/lib/converge-mirror.sh" 2>/dev/null || true
if ! command -v converge_mirror_hard_reset >/dev/null 2>&1; then
    converge_mirror_hard_reset() { git reset --hard "${1:?}"; }
fi

# --- resolve the source checkout to converge ---------------------------------
REPO_ROOT="${CHUMP_NODE_REPO:-}"
if [[ -z "$REPO_ROOT" ]]; then
    for candidate in "$HOME/chump-host" "$HOME/Projects/Chump" "$HOME/chump"; do
        if [[ -d "$candidate/.git" ]]; then REPO_ROOT="$candidate"; break; fi
    done
fi

CONVERGE_REMOTE="${CHUMP_NODE_CONVERGE_REMOTE:-origin}"
CONVERGE_BRANCH="${CHUMP_NODE_CONVERGE_BRANCH:-main}"
CONVERGE_REF="${CHUMP_NODE_CONVERGE_REF:-${CONVERGE_REMOTE}/${CONVERGE_BRANCH}}"
NODE_AMBIENT="${NODE_AMBIENT:-$REPO_ROOT/.chump-locks/ambient.jsonl}"

LOG_DIR="${CHUMP_NODE_CONVERGE_LOGDIR:-$HOME/.chump/node-converge-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || true
LOG="$LOG_DIR/converge-$(date -u +%Y%m%dT%H%M%SZ).log"

# RESILIENT-1215: role-organ reconcile, wired the same way node-refresh-chump.sh
# wires it (RESILIENT-1035/1205) — this organ is the FIRST hop to actually land
# a merge on the source tree, so it is also the earliest point a newly-merged
# organ (manifest line + installer roster entry) can reach the installer. Without
# this, a node whose binary SHA is unchanged (bash-only merge) waits on the
# separate, slower chump-organ-reconcile.timer cadence instead of picking up the
# organ the instant this tick's converge lands it.
if [[ -z "${CHUMP_NODE_ROLE:-}" ]]; then
    _nc_node_env="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env"
    [[ -f "$_nc_node_env" ]] && CHUMP_NODE_ROLE="$(grep -E '^(export )?CHUMP_NODE_ROLE=' "$_nc_node_env" 2>/dev/null | tail -1 | sed -E 's/^(export )?CHUMP_NODE_ROLE=//; s/^"(.*)"$/\1/')"
    [[ -z "${CHUMP_NODE_ROLE:-}" ]] && unset CHUMP_NODE_ROLE
fi
NODE_ROLE="${CHUMP_NODE_ROLE:-muscle}"
# INFRA-8572: idempotently ensure cargo-nextest is installed on linux-systemd
# and mac-launchd hosts (prebuilt archive or `cargo install cargo-nextest --locked`).
_ensure_cargo_nextest() {
    [[ -n "${PREFIX:-}" && "${PREFIX}" == *com.termux* ]] && return 0
    local os_s
    os_s="$(uname -s 2>/dev/null || echo unknown)"
    case "$os_s" in
        Linux|Darwin) ;;
        *) return 0 ;;
    esac
    local cargo_bin="${CARGO_HOME:-${HOME:-/root}/.cargo}/bin"
    if command -v cargo-nextest >/dev/null 2>&1 || [[ -x "$cargo_bin/cargo-nextest" ]]; then
        return 0
    fi
    mkdir -p "$cargo_bin" 2>/dev/null || true
    local url="" arch_s
    arch_s="$(uname -m 2>/dev/null || echo unknown)"
    if [[ "$os_s" == "Darwin" ]]; then
        url="https://get.nexte.st/latest/mac"
    elif [[ "$arch_s" == "aarch64" || "$arch_s" == "arm64" ]]; then
        url="https://get.nexte.st/latest/linux-arm"
    elif [[ "$arch_s" == "x86_64" || "$arch_s" == "amd64" ]]; then
        url="https://get.nexte.st/latest/linux"
    fi
    if [[ -n "$url" ]] && command -v curl >/dev/null 2>&1 && command -v tar >/dev/null 2>&1; then
        if curl -fsSL "$url" | tar -xzf - -C "$cargo_bin" cargo-nextest >>"$LOG" 2>&1 && [[ -x "$cargo_bin/cargo-nextest" ]]; then
            log "OK: installed prebuilt cargo-nextest to $cargo_bin/cargo-nextest"
            return 0
        fi
    fi
    if command -v cargo >/dev/null 2>&1; then
        if cargo install cargo-nextest --locked >>"$LOG" 2>&1; then
            log "OK: installed cargo-nextest via cargo install --locked"
            return 0
        fi
    fi
    log "WARN: failed to provision cargo-nextest (non-fatal)"
    return 0
}

# INFRA-8091: check and report the 34-tool roster from src/tool_routing.rs on
# every converge tick; if CHUMP_AUTO_PROVISION_TOOLS=1 and any tool is missing,
# run scripts/setup/bootstrap-toolkit.sh (apt + cargo-binstall on Linux).
_check_toolkit_roster() {
    [[ -n "${PREFIX:-}" && "${PREFIX}" == *com.termux* ]] && return 0
    local toolkit="$REPO_ROOT/scripts/setup/bootstrap-toolkit.sh"
    [[ -f "$toolkit" ]] || return 0
    local out rc=0
    out="$(PATH="${CARGO_HOME:-${HOME:-/root}/.cargo}/bin:${HOME:-/root}/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash "$toolkit" --check 2>&1)" || rc=$?
    log "INFRA-8091: $out"
    if [[ "$rc" -ne 0 && "${CHUMP_AUTO_PROVISION_TOOLS:-0}" == "1" ]]; then
        log "INFRA-8091: CHUMP_AUTO_PROVISION_TOOLS=1 — provisioning missing toolkit binaries via $toolkit"
        PATH="${CARGO_HOME:-${HOME:-/root}/.cargo}/bin:${HOME:-/root}/.local/bin:/usr/local/bin:/usr/bin:/bin:$PATH" bash "$toolkit" >>"$LOG" 2>&1 || true
    fi
    return 0
}

# INFRA-8589 (Phase R R5): re-render installed systemd units from their tracked
# repo templates, replacing any unit that carries a foreign host literal
# (/home/<other-user>, /Users/<name>, /root/, /opt/homebrew, or User= in user
# scope) or has drifted from its template.
_rerender_installed_units() {
    local unit_dir
    if [[ "${EUID:-$(id -u)}" -eq 0 && "${HOME:-}" == "/root" ]]; then
        unit_dir="/etc/systemd/system"
    else
        unit_dir="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/systemd/user"
    fi
    [[ -d "$unit_dir" ]] || return 0

    local chump
    chump="$(command -v chump 2>/dev/null || true)"
    [[ -z "$chump" && -x "$REPO_ROOT/target/release/chump" ]] && chump="$REPO_ROOT/target/release/chump"
    [[ -z "$chump" && -x "$REPO_ROOT/target/debug/chump" ]] && chump="$REPO_ROOT/target/debug/chump"
    if [[ -n "$chump" ]]; then
        local out
        if out="$("$chump" node rerender-units --unit-dir "$unit_dir" --repo-root "$REPO_ROOT" 2>>"$LOG")"; then
            log "INFRA-8589: $out"
            return 0
        fi
    fi

    # Pure-shell fallback via organ_unit_host_rewrite when `chump` lacks `rerender-units`.
    local rewrite_lib="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
    [[ -f "$rewrite_lib" ]] || return 0
    # shellcheck disable=SC1090
    source "$rewrite_lib"
    local scope="user"
    [[ "$unit_dir" == "/etc/systemd/system" ]] && scope="system"
    local run_user="${USER:-$(id -un 2>/dev/null || echo ubuntu)}"
    local run_home="${HOME:-/home/$run_user}"
    local inst fname tmpl tmp_out rerendered=0
    for inst in "$unit_dir"/*.service "$unit_dir"/*.timer "$unit_dir"/*.socket "$unit_dir"/*.path "$unit_dir"/*.target; do
        [[ -f "$inst" && ! -L "$inst" ]] || continue
        fname="$(basename "$inst")"
        tmpl=""
        for d in scripts/dispatch scripts/ops/systemd scripts/ops scripts/setup; do
            if [[ -f "$REPO_ROOT/$d/$fname" ]]; then
                tmpl="$REPO_ROOT/$d/$fname"
                break
            fi
        done
        [[ -n "$tmpl" ]] || continue
        tmp_out="$(mktemp "${TMPDIR:-/tmp}/rerender-unit.XXXXXX")"
        if organ_unit_host_rewrite "$tmpl" "$tmp_out" "$run_user" "$run_home" 0 "$REPO_ROOT" "$scope" >>"$LOG" 2>&1; then
            if ! cmp -s "$tmp_out" "$inst"; then
                mv -f "$tmp_out" "$inst"
                rerendered=$((rerendered + 1))
            else
                rm -f "$tmp_out"
            fi
        else
            rm -f "$tmp_out"
        fi
    done
    if [[ "$rerendered" -gt 0 ]]; then
        log "INFRA-8589: re-rendered $rerendered installed unit(s) in $unit_dir"
    fi
    return 0
}

# RESILIENT-1684 + INFRA-8104: probe whether a team gap store actually listens
# at <team_url> before emitting CHUMP_STORE_BACKEND / CHUMP_TEAM_URL /
# CHUMP_TEAM_API_KEY into node.env.
_probe_team_store_listening() {
    local team_url="${1:-}"
    if [[ "${CHUMP_TEAM_STORE_LISTENING:-}" == "1" ]]; then
        return 0
    elif [[ "${CHUMP_TEAM_STORE_LISTENING:-}" == "0" ]]; then
        return 1
    fi
    [[ -n "$team_url" ]] || return 1
    if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 2 "${team_url%/}/health" >/dev/null 2>&1; then
        return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$team_url" <<'PY' >/dev/null 2>&1 && return 0
import socket, sys, urllib.parse
raw = sys.argv[1].strip()
u = urllib.parse.urlparse(raw if "://" in raw else "http://" + raw)
host = u.hostname or ""
port = u.port or (443 if u.scheme == "https" else 80)
if not host:
    sys.exit(1)
with socket.create_connection((host, port), timeout=1.0):
    pass
PY
    fi
    return 1
}

# RESILIENT-1684 + INFRA-8104: normalize node.env into plain KEY=VALUE lines
# (no `export ` prefix) so systemd EnvironmentFile= units and shell callers see
# identical keys, and only emit CHUMP_STORE_BACKEND / CHUMP_TEAM_URL /
# CHUMP_TEAM_API_KEY when a store actually listens at CHUMP_TEAM_URL.
_sanitize_node_env() {
    local ne="${1:-${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env}"
    [[ -f "$ne" ]] || return 0
    local team_url=""
    team_url="$(grep -E '^[[:space:]]*(export[[:space:]]+)?CHUMP_TEAM_URL=' "$ne" 2>/dev/null \
        | tail -1 \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?CHUMP_TEAM_URL=//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' || true)"
    [[ -z "$team_url" && -n "${CHUMP_TEAM_URL:-}" ]] && team_url="$CHUMP_TEAM_URL"
    local store_ok=0
    if _probe_team_store_listening "$team_url"; then
        store_ok=1
    fi
    local tmp
    tmp="$(mktemp "${ne}.XXXXXX")" || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]]; then
            printf '%s\n' "$line" >> "$tmp"
            continue
        fi
        local clean="$line"
        clean="$(printf '%s' "$clean" | sed -E 's/^[[:space:]]*export[[:space:]]+//; s/^[[:space:]]+//')"
        if [[ "$clean" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"
            v="$(printf '%s' "$v" | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/')"
            case "$k" in
                CHUMP_STORE_BACKEND|CHUMP_TEAM_URL|CHUMP_TEAM_API_KEY)
                    [[ "$store_ok" -eq 1 ]] || continue
                    ;;
            esac
            printf '%s=%s\n' "$k" "$v" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$ne"
    chmod 0600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$ne"
    return 0
}

# RESILIENT-1684: ensure chump-organ-reconcile and chump-node-converge are only
# enabled in ONE systemd scope (no duplicate --user + --system registration on CJ).
_dedupe_single_scope_organs() {
    local sys_dir="${1:-${CHUMP_SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}}"
    local usr_dir="${2:-${CHUMP_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/systemd/user}}"
    local sctl="${3:-${CHUMP_SYSTEMCTL_BIN:-systemctl}}"
    local base
    for base in chump-organ-reconcile chump-node-converge; do
        local sys_present=0
        if [[ -f "$sys_dir/${base}.timer" || -f "$sys_dir/${base}.service" ]]; then
            sys_present=1
        fi
        if [[ "$sys_present" -eq 1 ]] && [[ -f "$usr_dir/${base}.timer" || -f "$usr_dir/${base}.service" ]]; then
            command -v "$sctl" >/dev/null 2>&1 && "$sctl" --user disable --now "${base}.timer" "${base}.service" >>"$LOG" 2>&1 || true
            rm -f "$usr_dir/${base}.timer" "$usr_dir/${base}.service" 2>/dev/null || true
            log "RESILIENT-1684: removed duplicate --user registration for $base (already in --system scope)"
            emit organ_scope_deduped "\"organ\":\"$base\",\"kept_scope\":\"system\",\"removed_scope\":\"user\""
        fi
    done
    return 0
}

# RESILIENT-1682: validate that a worker launcher script contains no test-gate
# or preflight bypass assignment (CHUMP_TEST_GATE=0, CHUMP_PREFLIGHT_SKIP=1,
# CHUMP_*_SKIP=*, CHUMP_*_NO_*=*).
_validate_worker_launcher_no_bypass() {
    local f="${1:?}"
    [[ -f "$f" ]] || return 1
    if grep -vE '^[[:space:]]*#' "$f" | grep -qE '(^|[[:space:];])(export[[:space:]]+)?(CHUMP_TEST_GATE=0|CHUMP_PREFLIGHT_[S]KIP=1|CHUMP_[A-Z0-9_]*_SKIP=|CHUMP_[A-Z0-9_]*_NO_[A-Z0-9_]*=)'; then
        return 1
    fi
    return 0
}

# RESILIENT-1682: scrub bypass assignments from any live worker launcher on node.
_converge_worker_launchers() {
    local candidate tmp
    for candidate in "${HOME:-/root}"/node*-worker-run.sh "${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/organs/worker.sh"; do
        [[ -f "$candidate" ]] || continue
        if ! _validate_worker_launcher_no_bypass "$candidate"; then
            tmp="$(mktemp "${candidate}.XXXXXX")" || continue
            grep -vE '^[[:space:]]*(export[[:space:]]+)?(CHUMP_TEST_GATE=0|CHUMP_PREFLIGHT_[S]KIP=1|CHUMP_[A-Z0-9_]*_SKIP=|CHUMP_[A-Z0-9_]*_NO_[A-Z0-9_]*=)' "$candidate" > "$tmp" || true
            chmod +x "$tmp" 2>/dev/null || true
            mv -f "$tmp" "$candidate"
            log "RESILIENT-1682: scrubbed bypass env assignment(s) from worker launcher $candidate"
            emit worker_launcher_bypass_scrubbed "\"launcher\":\"$candidate\""
        fi
    done
    return 0
}

# INFRA-8089: ensure global git user.email is the GitHub noreply address and
# scan git checkouts ($REPO_ROOT, linked worktrees, and any explicitly passed
# checkout paths) for local user.email overrides that are not a noreply address,
# reporting and resetting them so GitHub email-privacy blocks never reject pushes.
_converge_git_noreply_identity() {
    local noreply="${CHUMP_GIT_NOREPLY_EMAIL:-204632470+repairman29@users.noreply.github.com}"
    git config --global user.email "$noreply" 2>/dev/null || true

    local checkouts=()
    if [[ "$#" -gt 0 ]]; then
        checkouts+=("$@")
    fi
    [[ -n "${REPO_ROOT:-}" && -e "$REPO_ROOT/.git" ]] && checkouts+=("$REPO_ROOT")
    if [[ -n "${REPO_ROOT:-}" && -d "$REPO_ROOT/.claude/worktrees" ]]; then
        local wt
        for wt in "$REPO_ROOT"/.claude/worktrees/*; do
            [[ -e "$wt/.git" ]] && checkouts+=("$wt")
        done
    fi

    local dir local_email
    for dir in "${checkouts[@]}"; do
        [[ -d "$dir" && -e "$dir/.git" ]] || continue
        local_email="$(git -C "$dir" config --local user.email 2>/dev/null || true)"
        if [[ -n "$local_email" && "$local_email" != *@users.noreply.github.com && "$local_email" != *.chump.fleet ]]; then
            git -C "$dir" config --local user.email "$noreply" 2>/dev/null || true
            log "INFRA-8089: reset non-noreply local user.email '$local_email' -> '$noreply' in $dir"
            emit identity_residue_swept "\"repo\":\"$dir\",\"removed_email\":\"$local_email\",\"new_email\":\"$noreply\""
        fi
    done

    if [[ -n "${REPO_ROOT:-}" && -d "$REPO_ROOT/.git/worktrees" ]]; then
        local cf wt_email
        for cf in "$REPO_ROOT"/.git/worktrees/*/config.worktree; do
            [[ -f "$cf" ]] || continue
            wt_email="$(git config --file "$cf" user.email 2>/dev/null || true)"
            if [[ -n "$wt_email" && "$wt_email" != *@users.noreply.github.com && "$wt_email" != *.chump.fleet ]]; then
                git config --file "$cf" user.email "$noreply" 2>/dev/null || true
                log "INFRA-8089: reset non-noreply worktree user.email '$wt_email' -> '$noreply' in $cf"
                emit identity_residue_swept "\"worktree\":\"$cf\",\"removed_email\":\"$wt_email\",\"new_email\":\"$noreply\""
            fi
        done
    fi
    return 0
}

# INFRA-8106: ensure chump-pr-book.{service,timer} (pricing mode) is installed
# alongside chump-pr-book-settle.{service,timer} on hub/control nodes so open-PR
# predictions keep flowing into ~/.chump/pr-book-ledger.jsonl every 15 minutes.
_ensure_pr_book_timer() {
    local unit_dir="${1:-}"
    if [[ -z "$unit_dir" ]]; then
        if [[ "${EUID:-$(id -u)}" -eq 0 && "${HOME:-}" == "/root" ]]; then
            unit_dir="/etc/systemd/system"
        else
            unit_dir="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}/systemd/user"
        fi
    fi
    [[ -d "$unit_dir" ]] || return 0
    if [[ ! -f "$unit_dir/chump-pr-book-settle.timer" && "${NODE_ROLE:-}" != "hub" && "${NODE_ROLE:-}" != "control" ]]; then
        return 0
    fi
    local rewrite_lib="$REPO_ROOT/scripts/ops/lib/organ-unit-install-lib.sh"
    [[ -f "$rewrite_lib" ]] || return 0
    # shellcheck disable=SC1090
    source "$rewrite_lib"
    local scope="user"
    [[ "$unit_dir" == "/etc/systemd/system" ]] && scope="system"
    local run_user="${USER:-$(id -un 2>/dev/null || echo ubuntu)}"
    local run_home="${HOME:-/home/$run_user}"
    local ext tmpl
    for ext in service timer; do
        tmpl="$REPO_ROOT/scripts/dispatch/chump-pr-book.$ext"
        [[ -f "$tmpl" ]] || continue
        organ_unit_host_rewrite "$tmpl" "$unit_dir/chump-pr-book.$ext" "$run_user" "$run_home" 0 "$REPO_ROOT" "$scope" >>"$LOG" 2>&1 || true
    done
    return 0
}

# RESILIENT-1655: inspect systemd unit files and user crontab for any chump/coo
# organ entry executing scripts outside the canonical repo ($REPO_ROOT/scripts/,
# ~/.chumpnode/repo/scripts/, or ~/chump/scripts/) or under an untracked peer/
# or /coo/ directory, and remove untracked $REPO_ROOT/peer/ if present.
# Returns 0 when clean, 1 when one or more out-of-repo organ violations were
# detected (and remediated).
_check_no_out_of_repo_organs() {
    local unit_dir="${1:-${CHUMP_SYSTEMD_USER_DIR:-}}"
    local cron_file="${2:-${CHUMP_CRONTAB_FILE:-}}"
    local repo_root="${3:-${REPO_ROOT:-}}"
    local home_dir="${HOME:-/root}"
    local violations=0

    # 1. Remove untracked peer/ directory in the canonical checkout if present.
    if [[ -n "$repo_root" && -d "$repo_root/peer" ]]; then
        local tracked_peer=""
        if [[ -e "$repo_root/.git" ]]; then
            tracked_peer="$(git -C "$repo_root" ls-files -- "peer" 2>/dev/null || true)"
        fi
        if [[ -z "$tracked_peer" ]]; then
            rm -rf "$repo_root/peer"
            log "RESILIENT-1655: removed untracked out-of-repo organ directory $repo_root/peer"
            violations=$((violations + 1))
        fi
    fi

    # Helper: return 0 if a script/command line references an out-of-repo organ path.
    _is_out_of_repo_line() {
        local line="$1"
        # Explicit out-of-repo organ signatures (/coo/ or /peer/)
        if [[ "$line" == *"/coo/"* || "$line" == *"~/coo/"* || "$line" == *"/peer/"* || "$line" == *"~/chump/peer/"* ]]; then
            return 0
        fi
        # Extract any .sh or .py token from the line (splitting on whitespace
        # without glob expansion so crontab `*` fields never glob CWD).
        local -a toks=()
        read -r -a toks <<< "$line"
        local tok clean_tok
        for tok in "${toks[@]}"; do
            clean_tok="${tok#\'}"; clean_tok="${clean_tok%\'}"
            clean_tok="${clean_tok#\"}"; clean_tok="${clean_tok%\"}"
            clean_tok="${clean_tok#*=}"
            case "$clean_tok" in
                *.sh|*.py)
                    case "$clean_tok" in
                        "$repo_root"/scripts/*|\
                        "$home_dir"/.chumpnode/repo/scripts/*|\
                        "$home_dir"/chump/scripts/*|\
                        "~/.chumpnode/repo/scripts/"*|\
                        "~/chump/scripts/"*|\
                        "__REPO_ROOT__/scripts/"*|\
                        "scripts/"*)
                            ;;
                        *)
                            return 0
                            ;;
                    esac
                    ;;
            esac
        done
        return 1
    }

    # 2. Inspect systemd unit files (chump*.service, coo*.service).
    local dirs=()
    if [[ -n "$unit_dir" ]]; then
        dirs+=("$unit_dir")
    else
        [[ -d "${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user" ]] && dirs+=("${XDG_CONFIG_HOME:-$home_dir/.config}/systemd/user")
        [[ -n "${CHUMP_SYSTEMD_SYSTEM_DIR:-}" && -d "${CHUMP_SYSTEMD_SYSTEM_DIR}" ]] && dirs+=("${CHUMP_SYSTEMD_SYSTEM_DIR}")
    fi

    local d uf ubase exec_lines eline bad_unit tmpl
    for d in "${dirs[@]}"; do
        [[ -d "$d" ]] || continue
        for uf in "$d"/chump*.service "$d"/coo*.service; do
            [[ -f "$uf" ]] || continue
            ubase="$(basename "$uf")"
            bad_unit=0
            exec_lines="$(grep -E '^ExecStart=' "$uf" 2>/dev/null || true)"
            while IFS= read -r eline; do
                [[ -z "$eline" ]] && continue
                if _is_out_of_repo_line "$eline"; then
                    bad_unit=1
                    log "RESILIENT-1655: out-of-repo organ in unit $uf: $eline"
                fi
            done <<< "$exec_lines"
            if [[ "$bad_unit" -eq 1 ]]; then
                violations=$((violations + 1))
                tmpl=""
                if [[ -n "$repo_root" && -f "$repo_root/scripts/dispatch/$ubase" ]]; then
                    tmpl="$repo_root/scripts/dispatch/$ubase"
                elif [[ -n "$repo_root" && -f "$repo_root/scripts/ops/$ubase" ]]; then
                    tmpl="$repo_root/scripts/ops/$ubase"
                fi
                if [[ -n "$tmpl" ]]; then
                    sed -e "s|__REPO_ROOT__|$repo_root|g" -e "s|__HOME__|$home_dir|g" "$tmpl" > "$uf"
                    log "RESILIENT-1655: re-rendered $uf from tracked template $tmpl"
                else
                    rm -f "$uf"
                    log "RESILIENT-1655: removed untracked out-of-repo unit $uf"
                fi
            fi
        done
    done

    # 3. Inspect user crontab (via $cron_file if provided, else `crontab -l` when running convergence).
    if [[ -n "$cron_file" && -f "$cron_file" ]]; then
        local ctmp bad_cron=0 cline
        ctmp="$(mktemp "${cron_file}.XXXXXX")"
        while IFS= read -r cline || [[ -n "$cline" ]]; do
            if [[ ! "$cline" =~ ^[[:space:]]*# ]] && [[ "$cline" == *chump* || "$cline" == *coo* || "$cline" == *peer/* ]]; then
                if _is_out_of_repo_line "$cline"; then
                    log "RESILIENT-1655: scrubbed out-of-repo crontab organ entry: $cline"
                    bad_cron=1
                    violations=$((violations + 1))
                    continue
                fi
            fi
            printf '%s\n' "$cline" >> "$ctmp"
        done < "$cron_file"
        if [[ "$bad_cron" -eq 1 ]]; then
            mv -f "$ctmp" "$cron_file"
        else
            rm -f "$ctmp"
        fi
    fi

    [[ "$violations" -eq 0 ]]
}

_reconcile_role_organs() {
    _sanitize_node_env
    _dedupe_single_scope_organs
    _converge_worker_launchers
    _converge_git_noreply_identity
    _ensure_pr_book_timer
    _check_no_out_of_repo_organs || true
    local installer="$REPO_ROOT/scripts/setup/chump-node-install.sh"
    if [[ ! -f "$installer" ]]; then
        log "WARN: $installer not found; skipping role-organ reconcile"
        return 0
    fi
    # RESILIENT-1615: never reconcile organs into a second scope.
    if ! _nc_second_scope_ok; then
        log "SKIP: refusing organ reconcile — a chump install exists in another scope (see node_second_scope_refused)"
        return 0
    fi
    if CHUMP_NODE_REPO="$REPO_ROOT" CHUMP_STATE_DIR="${CHUMP_STATE_DIR:-$HOME/.chump}" \
         bash "$installer" --role "$NODE_ROLE" --reconcile-organs-only >>"$LOG" 2>&1; then
        log "OK: role-organ reconcile complete (role=$NODE_ROLE)"
        emit node_organs_reconciled "\"role\":\"$NODE_ROLE\""
    else
        log "WARN: chump-node-install.sh --reconcile-organs-only exited non-zero (non-fatal, role=$NODE_ROLE)"
        emit node_organs_reconcile_failed "\"role\":\"$NODE_ROLE\""
    fi
    # RESILIENT-1644: ensure any organ declared `retired` in organ-manifest.txt
    # or listed in paused-timers.txt remains disabled after converge/reconcile.
    local manifest_lib="$REPO_ROOT/scripts/ops/lib/organ-manifest-lib.sh"
    local manifest_file="$REPO_ROOT/scripts/ops/organ-manifest.txt"
    if [[ -f "$manifest_lib" && -f "$manifest_file" ]]; then
        # shellcheck disable=SC1090
        source "$manifest_lib"
        local _po=() _en=() _ret=() u base
        declare -A _r _req _pl _nd _sc
        if organ_manifest_parse "$manifest_file" _po _en _r _req _pl _nd _sc _ret 2>/dev/null; then
            for u in "${_ret[@]}"; do
                base="${u%.service}"; base="${base%.timer}"
                systemctl --user disable --now "${base}.timer" "${base}.service" >>"$LOG" 2>&1 || true
            done
        fi
    fi
    _ensure_cargo_nextest
    _check_toolkit_roster
    _rerender_installed_units
    _sanitize_node_env
    _dedupe_single_scope_organs
    _converge_worker_launchers
    _converge_git_noreply_identity
    _ensure_pr_book_timer
    _check_no_out_of_repo_organs || true
}

emit() {
    local kind="$1" extra="${2:-}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local line
    if [[ -n "$extra" ]]; then line="{\"ts\":\"$ts\",\"kind\":\"$kind\",$extra}"
    else line="{\"ts\":\"$ts\",\"kind\":\"$kind\"}"; fi
    [[ -d "$(dirname "$NODE_AMBIENT")" ]] && printf '%s\n' "$line" >> "$NODE_AMBIENT" 2>/dev/null || true
    printf '[%s] %s %s\n' "$ts" "$kind" "$extra" >> "$LOG"
}
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" | tee -a "$LOG"; }

# RESILIENT-1615: honor a node pause BEFORE any mutation. A paused node must
# converge/install/restart NOTHING — the cuphead receipt (2026-10-17 04:41Z)
# was converge re-enabling 42 timers on a node the operator had paused.
#
# RESILIENT-1652/1653 (task 3, "one rule"): the authoritative predicate is the
# Rust one, reached via the read-only `chump node is-paused` verb (exit 0 =
# paused, 1 = not paused, no writes). Resolve a chump binary and defer to it so
# this shell no longer carries a divergent rule (it used to treat
# CHUMP_NODE_WORK_ENABLED=0 ALONE as paused, which the Rust predicate does not —
# the legacy form needs control-plane + WORK_ENABLED=0 together). The shell
# checks below remain ONLY as a best-effort fallback when no chump binary is
# resolvable (or `is-paused` errors, rc>=2), so a binary-less node still honours
# a pause. With a binary present, is-paused is the single source of truth.
# (set -e is NOT active here — only `set -uo pipefail` — so capturing rc=$?
# after an exit-1 `is-paused` is safe.)
_nc_paused() {
    local sd="${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}"
    local chump
    chump="$(command -v chump 2>/dev/null || true)"
    [[ -z "$chump" && -x "$REPO_ROOT/target/release/chump" ]] && chump="$REPO_ROOT/target/release/chump"
    [[ -z "$chump" && -x "$REPO_ROOT/target/debug/chump" ]] && chump="$REPO_ROOT/target/debug/chump"
    if [[ -n "$chump" ]]; then
        CHUMP_STATE_DIR="$sd" "$chump" node is-paused >/dev/null 2>&1
        local rc=$?
        [[ $rc -eq 0 ]] && return 0   # paused
        [[ $rc -eq 1 ]] && return 1   # not paused
        # rc>=2: is-paused errored — fall through to the shell fallback below.
    fi
    # Fallback (no chump binary / is-paused errored): the legacy shell checks.
    # RESILIENT-1653 AC2: derive the node pause sentinel the SAME way
    # node_pause::node_sentinel_path does — <state_dir>/.chump/fleet-paused —
    # into a named var rather than hard-coding the literal, so this reader and
    # the Rust writer can never drift to different paths.
    local sentinel="$sd/.chump/fleet-paused"
    [[ -f "$sentinel" ]] && return 0
    local ne="$sd/node.env"
    if [[ -f "$ne" ]]; then
        grep -Eq '^(export )?CHUMP_NODE_MODE=paused([[:space:]]|$)' "$ne" && return 0
        grep -Eq '^(export )?CHUMP_NODE_WORK_ENABLED=0([[:space:]]|$)' "$ne" && return 0
    fi
    [[ "${CHUMP_NODE_WORK_ENABLED:-}" == "0" ]] && return 0
    [[ "${CHUMP_NODE_MODE:-}" == "paused" ]] && return 0
    return 1
}
# RESILIENT-1652 (task 5): when this organ is SOURCED (not executed) — so a test
# can exercise `_nc_paused` against node.env fixtures without running the whole
# converge body — return before that body runs. This is a source-guard
# (BASH_SOURCE vs $0), NOT a skip/bypass env var: executed normally
# (`bash node-converge.sh`) BASH_SOURCE[0] == $0 and this is a no-op.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
    return 0 2>/dev/null || true
fi

if _nc_paused; then
    log "SKIP: node is paused (CHUMP_NODE_MODE=paused / fleet-paused sentinel / CHUMP_NODE_WORK_ENABLED=0) — converging and installing nothing this tick"
    emit organ_skipped_paused "\"organ\":\"node-converge\",\"reason\":\"node_paused\""
    exit 0
fi

# RESILIENT-1615: a chump install in a SECOND supervisor scope means another
# fleet owns this box (cuphead ran a root/system-scope install for 24 days
# alongside the ubuntu user-scope one). Refuse to (re)install organs into a
# second scope. Resolves a chump binary (PATH, then the repo's built target)
# and defers to `chump node scopes --install-guard`, which emits
# kind=node_second_scope_refused when the OTHER scope already has an install.
_nc_second_scope_ok() {
    local chump
    chump="$(command -v chump 2>/dev/null || true)"
    [[ -z "$chump" && -x "$REPO_ROOT/target/release/chump" ]] && chump="$REPO_ROOT/target/release/chump"
    [[ -z "$chump" && -x "$REPO_ROOT/target/debug/chump" ]] && chump="$REPO_ROOT/target/debug/chump"
    [[ -z "$chump" ]] && return 0   # best-effort: no binary to check with yet
    "$chump" node scopes --install-guard >>"$LOG" 2>&1
}

# RESILIENT-1453: restart a running worker whose worker.sh changed under it.
# This organ hard-resets the SOURCE tree to origin/main, but the long-running
# chump-node*-worker.service was exec'd ONCE at service start and never reloads
# code. worker.sh's own in-process re-exec (RESILIENT-1450) only fires between
# gaps, so a merged worker.sh fix stays inert for the entire duration of an
# in-flight gap (the "merged != running" disease). This organ already runs on a
# ~10min timer with passwordless sudo, so it is the right place to bounce the
# worker EXTERNALLY the instant the tracked worker.sh content changes. The worker
# handles SIGTERM with a WIP checkpoint (INFRA-686), so an external restart is safe
# at any point. Host-agnostic: discovers the active chump-node*-worker.service unit
# rather than hard-coding node1.
WORKER_SH="$REPO_ROOT/scripts/dispatch/worker.sh"
WORKER_STAMP="$REPO_ROOT/.chump-locks/worker-code.stamp"
WORKER_RESTART_MARKER="$REPO_ROOT/.chump-locks/worker-restart.marker"
_worker_code_hash() { sha256sum "$WORKER_SH" 2>/dev/null | cut -d' ' -f1; }
_maybe_restart_stale_workers() {
    # $1: "reset_changed" when THIS converge's reset just changed worker.sh (a
    #     definitive signal that needs no cooperation from the worker). Otherwise
    #     fall back to the worker's own stamp (what it is executing) vs disk.
    local definitive="${1:-}"
    [[ -f "$WORKER_SH" ]] || return 0
    local disk; disk="$(_worker_code_hash)"; [[ -z "$disk" ]] && return 0
    local started=""; [[ -f "$WORKER_STAMP" ]] && started="$(tr -d '[:space:]' < "$WORKER_STAMP" 2>/dev/null)"
    local stale=0
    [[ "$definitive" == "reset_changed" ]] && stale=1
    [[ -n "$started" && "$started" != "$disk" ]] && stale=1
    [[ "$stale" -eq 0 ]] && return 0
    # Loop guard: never re-request a restart for the SAME worker.sh hash within
    # 25min. A healthy restart re-writes the stamp to == disk, clearing the stale
    # condition next tick; this only bounds a crash-looping worker that never
    # rewrites its stamp so we don't hammer it every 10min.
    if [[ -f "$WORKER_RESTART_MARKER" ]]; then
        local m_hash m_ts now age
        m_hash="$(sed -n '1p' "$WORKER_RESTART_MARKER" 2>/dev/null)"
        m_ts="$(sed -n '2p' "$WORKER_RESTART_MARKER" 2>/dev/null)"
        case "$m_ts" in ''|*[!0-9]*) m_ts=0 ;; esac
        now="$(date -u +%s)"; age=$(( now - m_ts ))
        if [[ "$m_hash" == "$disk" && "$age" -lt 1500 ]]; then
            log "worker.sh changed under a running worker (hash ${disk:0:12}) but a restart was already requested ${age}s ago — skipping to avoid a restart loop"
            return 0
        fi
    fi
    local units u restarted=0
    units="$(systemctl list-units --type=service --state=running --no-legend 'chump-node*-worker.service' 2>/dev/null | awk '{print $1}')"
    if [[ -z "$units" ]]; then
        log "worker.sh changed (disk ${disk:0:12}) but no running chump-node*-worker.service found — nothing to restart"
        return 0
    fi
    for u in $units; do
        if sudo -n systemctl restart "$u" >>"$LOG" 2>&1; then
            log "RESILIENT-1453: worker.sh changed under running $u (disk=${disk:0:12} started=${started:0:12} trigger=${definitive:-stamp_stale}) — restarted it (graceful SIGTERM/WIP checkpoint)"
            restarted=1
        else
            log "WARN: sudo -n systemctl restart $u failed (converge user needs passwordless sudo)"
        fi
    done
    if [[ "$restarted" -eq 1 ]]; then
        printf '%s\n%s\n' "$disk" "$(date -u +%s)" > "$WORKER_RESTART_MARKER" 2>/dev/null || true
        emit worker_restarted_on_code_change "\"disk_hash\":\"$disk\",\"started_hash\":\"${started:-none}\",\"trigger\":\"${definitive:-stamp_stale}\",\"units\":\"$(echo $units | tr '\n' ' ' | sed 's/ *$//')\""
    fi
}

# --- preconditions -----------------------------------------------------------
if [[ -z "$REPO_ROOT" || ! -d "$REPO_ROOT/.git" ]]; then
    log "SKIP: no chump source checkout found (set CHUMP_NODE_REPO)"
    emit node_converge_skipped "\"reason\":\"no_repo\""
    exit 0
fi
cd "$REPO_ROOT" || { log "FATAL: cannot cd $REPO_ROOT"; emit node_converge_failed "\"reason\":\"cwd_failed\""; exit 1; }

# DEFER if the main checkout is mid-operation. Resolve the state paths through
# `git rev-parse --git-path` so this is correct whether $REPO_ROOT is the main
# checkout or (defensively) a linked worktree. Never reset a tree an operator or
# another organ is actively rebasing/merging — just try again next tick.
_op_in_progress() {
    local p
    for p in rebase-merge rebase-apply MERGE_HEAD CHERRY_PICK_HEAD BISECT_LOG; do
        local resolved; resolved="$(git rev-parse --git-path "$p" 2>/dev/null)"
        [[ -n "$resolved" && -e "$resolved" ]] && return 0
    done
    return 1
}
if _op_in_progress; then
    log "SKIP: a rebase/merge/cherry-pick/bisect is in progress in $REPO_ROOT — deferring converge"
    emit node_converge_skipped "\"reason\":\"operation_in_progress\",\"repo\":\"$REPO_ROOT\""
    exit 0
fi

# --- RESILIENT-1567: clear a stale .git/index.lock -------------------------
# A crashed git leaves index.lock behind; every later `git reset --hard` then
# fails and the node silently rots. Clear it only when no git process is alive
# and the lock is older than the min age (a live git holds it for seconds).
_clear_stale_index_lock() {
    local lock; lock="$(git rev-parse --git-path index.lock 2>/dev/null)"
    [[ -n "$lock" && -e "$lock" ]] || return 1
    local min_age="${CHUMP_NODE_CONVERGE_LOCK_MIN_AGE_S:-120}" mtime age
    (( min_age > 0 )) && pgrep -x git >/dev/null 2>&1 && return 1
    mtime="$(stat -c %Y "$lock" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - mtime ))
    (( age >= min_age )) || return 1
    rm -f "$lock" 2>/dev/null || return 1
    log "cleared stale $lock (age ${age}s, no git process running)"
    emit node_converge_stale_lock_cleared "\"lock\":\"$lock\",\"age_s\":$age"
    return 0
}
_clear_stale_index_lock || true

# --- INFRA-8210: repair a single-branch fetch refspec on every tick ----------
# A checkout cloned with --single-branch only ever fetches origin/main, so
# remote feature branches never populate refs/remotes/<remote>/* — which
# silently broke dispatch resume, salvage, and rebases on the cuphead hub. The
# installer sets the full refspec at install time; converge re-asserts it every
# tick so a hand-reclone or a legacy checkout self-heals without a reinstall.
# Same shared primitive as the installer; idempotent when already all-branches.
source "$_CONVERGE_DIR/../setup/lib/refspec-repair.sh" 2>/dev/null || true
if command -v repair_fetch_refspec >/dev/null 2>&1; then
    repair_fetch_refspec "$REPO_ROOT" "$CONVERGE_REMOTE"; _refspec_rc=$?
    if [[ "$_refspec_rc" -eq 10 ]]; then
        log "repaired fetch refspec for '$CONVERGE_REMOTE' -> all-branches (was single-branch/narrow)"
        emit node_converge_refspec_repaired "\"remote\":\"$CONVERGE_REMOTE\",\"repo\":\"$REPO_ROOT\""
    fi
fi

# --- RESILIENT-1604: pin the node admission ceiling into node.env ------------
# A node installed before the installer wrote CHUMP_MAX_CONCURRENT_CLAUDE /
# CHUMP_MAX_CONCURRENT_CARGO_JOBS (cuphead, 2026-10-16) self-heals here: each
# key node.env lacks is appended as max(1, nproc/2); a present key is never
# rewritten. Same shared primitive as the installer's write_node_env().
source "$_CONVERGE_DIR/../setup/lib/node-admission-ceiling.sh" 2>/dev/null || true
if command -v chump_ensure_admission_ceiling >/dev/null 2>&1; then
    _ceiling_written="$(chump_ensure_admission_ceiling "${CHUMP_STATE_DIR:-${HOME:-/root}/.chump}/node.env" || true)"
    if [[ -n "$_ceiling_written" ]]; then
        log "admission ceiling written to node.env: $(printf '%s' "$_ceiling_written" | tr '\n' ' ')"
    fi
fi

# --- fetch (auth-independent: a public-repo fetch needs no credentials) -------
if ! git fetch "$CONVERGE_REMOTE" "$CONVERGE_BRANCH" --quiet 2>>"$LOG"; then
    # Offline / transient network. Not fatal — nothing to converge to that we
    # can trust, so skip this tick rather than reset to a stale local ref.
    log "SKIP: git fetch $CONVERGE_REMOTE $CONVERGE_BRANCH failed (offline?); leaving tree as-is"
    emit node_converge_skipped "\"reason\":\"fetch_failed\",\"ref\":\"$CONVERGE_REF\""
    exit 0
fi

# --- idempotency: already at the ref? ----------------------------------------
TARGET_SHA="$(git rev-parse --short=12 "$CONVERGE_REF" 2>/dev/null || echo unknown)"
HEAD_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
# Count how far the working HEAD is BEHIND the ref (commits on the ref not yet
# on HEAD). Zero + identical SHA = already converged; the reset would be a no-op.
BEHIND="$(git rev-list --count "HEAD..$CONVERGE_REF" 2>/dev/null || echo 0)"
case "$BEHIND" in ''|*[!0-9]*) BEHIND=0 ;; esac

# --- RESILIENT-1567: alarm when the node is far behind for too long ----------
# Silent far-behind == merged-but-not-running. Track when we first saw
# BEHIND > N; once it has persisted > M minutes, page (re-page every 6h).
FAR_N="${CHUMP_NODE_CONVERGE_FAR_BEHIND_N:-50}"
FAR_M="${CHUMP_NODE_CONVERGE_FAR_BEHIND_MIN:-30}"
FAR_STATE="$LOG_DIR/far-behind-since"
if (( BEHIND > FAR_N )); then
    _now="$(date +%s)"
    [[ -s "$FAR_STATE" ]] || echo "$_now" > "$FAR_STATE"
    _since="$(cat "$FAR_STATE" 2>/dev/null || echo "$_now")"
    case "$_since" in ''|*[!0-9]*) _since="$_now" ;; esac
    _last_page="$(cat "$FAR_STATE.paged" 2>/dev/null || echo 0)"
    case "$_last_page" in ''|*[!0-9]*) _last_page=0 ;; esac
    if (( _now - _since >= FAR_M * 60 && _now - _last_page >= 21600 )); then
        echo "$_now" > "$FAR_STATE.paged"
        log "ALARM: node is $BEHIND commits behind $CONVERGE_REF for >${FAR_M}min"
        emit node_converge_far_behind "\"behind\":$BEHIND,\"threshold\":$FAR_N,\"minutes\":$FAR_M,\"repo\":\"$REPO_ROOT\""
        _nc_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -f "$_nc_dir/../coord/lib/notify-operator.sh" ]]; then
            ( source "$_nc_dir/../coord/lib/notify-operator.sh" && \
              CHUMP_NOTIFY_KIND="node_converge_far_behind" \
              notify_operator "Node $(hostname) is $BEHIND commits behind $CONVERGE_REF for >${FAR_M}min — merged fixes are not running here." ) >>"$LOG" 2>&1 || true
        fi
    fi
else
    rm -f "$FAR_STATE" "$FAR_STATE.paged" 2>/dev/null || true
fi

if [[ "$HEAD_SHA" == "$TARGET_SHA" && "$BEHIND" -eq 0 && "$TARGET_SHA" != "unknown" ]]; then
    log "SKIP: already at $CONVERGE_REF ($HEAD_SHA)"
    emit node_converge_skipped "\"reason\":\"already_current\",\"sha\":\"$HEAD_SHA\""
    # RESILIENT-1453: even when the tree did not move THIS tick, a worker started
    # before an earlier converge (or a restart via another path) may still be
    # executing older worker.sh — reconcile it against its stamp.
    if [[ -f "$REPO_ROOT/scripts/setup/chump-node-install.sh" ]]; then
        _ensure_cargo_nextest
        _check_toolkit_roster
        _rerender_installed_units
        _sanitize_node_env
        _dedupe_single_scope_organs
        _converge_worker_launchers
        _ensure_pr_book_timer
    fi
    _converge_git_noreply_identity
    _maybe_restart_stale_workers ""
    # Prune old logs (keep last 24) even on the fast path.
    ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
    exit 0
fi

# --- converge ----------------------------------------------------------------
log "converging $REPO_ROOT: HEAD $HEAD_SHA -> $CONVERGE_REF ($TARGET_SHA), behind by $BEHIND"
PREV_WORKER_HASH="$(_worker_code_hash)"
if ! converge_mirror_hard_reset "$CONVERGE_REF" >>"$LOG" 2>&1 && \
   ! { _clear_stale_index_lock && converge_mirror_hard_reset "$CONVERGE_REF" >>"$LOG" 2>&1; }; then
    log "FATAL: converge (git reset --hard) to $CONVERGE_REF failed"
    emit node_converge_failed "\"reason\":\"reset_failed\",\"ref\":\"$CONVERGE_REF\",\"target_sha\":\"$TARGET_SHA\""
    exit 1
fi

NEW_SHA="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
log "OK: $REPO_ROOT now at $NEW_SHA (was $HEAD_SHA, ref $CONVERGE_REF)"
emit node_converged "\"prev_sha\":\"$HEAD_SHA\",\"new_sha\":\"$NEW_SHA\",\"ref\":\"$CONVERGE_REF\",\"behind\":$BEHIND"

# RESILIENT-1215: the tree just landed whatever merged into $CONVERGE_REF,
# including any organ-manifest / installer-roster changes — reconcile the
# role's organ set now instead of waiting on the slower
# chump-organ-reconcile.timer cadence.
_reconcile_role_organs

# RESILIENT-1453: if the reset just changed worker.sh out from under a running
# worker, bounce the service onto the new code now (definitive signal — no stamp
# needed). Also reconciles against the stamp for any change via another path.
_reset_wc_flag=""
[[ -n "${PREV_WORKER_HASH:-}" && "$PREV_WORKER_HASH" != "$(_worker_code_hash)" ]] && _reset_wc_flag="reset_changed"
_maybe_restart_stale_workers "$_reset_wc_flag"

# Prune old logs (keep last 24).
ls -t "$LOG_DIR"/converge-*.log 2>/dev/null | tail -n +25 | xargs -r rm -f 2>/dev/null || true
exit 0
