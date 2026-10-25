#!/usr/bin/env bash
# scripts/lib/pre-push-pkg-scope.sh — INFRA-8154 (PHASE-R R3)
#
# Computes incremental cargo test package scope from a git diff file list:
#   - Workspace-wide triggers (^Cargo\.toml$, ^Cargo\.lock$, ^workspace-hack/,
#     ^rust-toolchain, ^scripts/git-hooks/pre-push$) ->
#     [pre-push] incremental test scope: packages=--workspace reason=workspace-wide-trigger (<file>)
#   - No Rust changes (*.rs, crates/*/Cargo.toml, Cargo.toml) ->
#     [pre-push] incremental test scope: packages=none reason=no-rust-changes
#   - Crate changes -> map touched files to workspace packages (chump for src/**,
#     <pkg> for crates/<pkg>/**) and expand to transitive workspace reverse
#     dependencies via `cargo metadata --no-deps --format-version 1`:
#     [pre-push] incremental test scope: packages=<pkg1,pkg2,...> reason=rdeps(<touched_pkgs>)

pre_push_compute_pkg_scope() {
    local _changed_input=""
    if [[ "${1:-}" == "--range" ]]; then
        local _base_sha="${2:-}"
        local _local_sha="${3:-HEAD}"
        _changed_input="$(git diff --name-only "${_base_sha}..${_local_sha}" 2>/dev/null || true)"
    elif [[ "$#" -gt 0 ]]; then
        _changed_input="$(printf '%s\n' "$@")"
    elif [[ ! -t 0 ]]; then
        _changed_input="$(cat || true)"
    fi

    # 1. Check workspace-wide triggers first.
    local _f _ws_trigger=""
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        if [[ "$_f" =~ ^Cargo\.toml$ || "$_f" =~ ^Cargo\.lock$ || "$_f" =~ ^workspace-hack/ || "$_f" =~ ^rust-toolchain || "$_f" =~ ^scripts/git-hooks/pre-push$ ]]; then _ws_trigger="$_f"; break; fi # INFRA-8154:WORKSPACE-TRIGGER
    done <<<"$_changed_input"

    if [[ -n "$_ws_trigger" ]]; then
        printf '[pre-push] incremental test scope: packages=--workspace reason=workspace-wide-trigger (%s)\n' "$_ws_trigger"
        return 0
    fi

    # 2. Check if any changed file is in a Rust crate (*.rs, crates/*/Cargo.toml, Cargo.toml).
    local _rust_files=()
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        if [[ "$_f" =~ \.rs$ || "$_f" =~ ^crates/.*/Cargo\.toml$ || "$_f" =~ ^Cargo\.toml$ ]]; then
            _rust_files+=("$_f")
        fi
    done <<<"$_changed_input"

    if [[ "${#_rust_files[@]}" -eq 0 ]]; then
        printf '[pre-push] incremental test scope: packages=none reason=no-rust-changes\n'
        return 0
    fi

    # 3. Map changed Rust files to touched packages and expand reverse dependencies.
    local _meta_root=""
    local _cand_root
    for _cand_root in "${CHUMP_REPO_ROOT:-}" "${REPO_ROOT_T:-}" "${REPO_ROOT:-}" "$(git rev-parse --show-toplevel 2>/dev/null || true)" "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"; do
        if [[ -n "$_cand_root" && -f "$_cand_root/Cargo.toml" ]]; then
            _meta_root="$_cand_root"
            break
        fi
    done

    local _meta_json=""
    if [[ -n "$_meta_root" ]]; then
        if [[ -f "${REPO_ROOT_T:-$_meta_root}/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
            _meta_json="$(cd "$_meta_root" && cargo metadata --no-deps --format-version 1 2>/dev/null || true)"
        fi
        if [[ -z "$_meta_json" ]]; then
            # Fallback when PATH has a mock cargo that produces empty metadata in tests.
            local _real_cargo="" _d
            if [[ -x "${HOME:-}/.cargo/bin/cargo" ]]; then
                _real_cargo="${HOME}/.cargo/bin/cargo"
            else
                IFS=':' read -ra _pdirs <<<"${PATH:-}"
                for _d in "${_pdirs[@]}"; do
                    if [[ -x "$_d/cargo" ]] && ! grep -q 'CHUMP_TEST_GATE_FAKE_RC' "$_d/cargo" 2>/dev/null; then
                        _real_cargo="$_d/cargo"
                        break
                    fi
                done
            fi
            if [[ -n "$_real_cargo" ]]; then
                _meta_json="$(cd "$_meta_root" && "$_real_cargo" metadata --no-deps --format-version 1 2>/dev/null || true)"
            fi
        fi
    fi

    local _meta_file
    _meta_file="$(mktemp)"
    printf '%s' "$_meta_json" > "$_meta_file"

    local _scope_out
    _scope_out="$(python3 - "$_meta_file" "${_rust_files[@]}" <<'PY'
import collections, json, os, re, sys

meta_file = sys.argv[1]
rust_files = sys.argv[2:]

meta = {}
try:
    with open(meta_file, "r", encoding="utf-8") as fh:
        raw = fh.read().strip()
        if raw:
            meta = json.loads(raw)
except Exception:
    meta = {}

packages = meta.get("packages", [])
pkg_names = {p.get("name") for p in packages if p.get("name")}
dir_to_pkg = {}
for p in packages:
    name = p.get("name", "")
    mpath = p.get("manifest_path", "")
    if name and mpath:
        mdir = os.path.dirname(mpath).replace("\\", "/")
        idx = mdir.find("/crates/")
        if idx != -1:
            rel_dir = mdir[idx + 1:]
            dir_to_pkg[rel_dir] = name

# Reverse dependency adjacency list: dep_name -> set of workspace packages depending on it
rev_deps = collections.defaultdict(set)
for p in packages:
    src_pkg = p.get("name", "")
    if not src_pkg:
        continue
    for d in p.get("dependencies", []):
        dep_name = d.get("name", "")
        if dep_name:
            rev_deps[dep_name].add(src_pkg)

touched = set()
for f in rust_files:
    f = f.strip().lstrip("./")
    if not f:
        continue
    m_mcp = re.match(r"^(crates/mcp-servers/[^/]+)/", f)
    m_crate = re.match(r"^crates/([^/]+)/", f)
    if m_mcp and m_mcp.group(1) in dir_to_pkg:
        touched.add(dir_to_pkg[m_mcp.group(1)])
    elif m_crate:
        cdir = m_crate.group(1)
        rel = f"crates/{cdir}"
        if cdir in pkg_names:
            touched.add(cdir)
        elif rel in dir_to_pkg:
            touched.add(dir_to_pkg[rel])
        else:
            touched.add(cdir)
    else:
        touched.add("chump")

if not touched:
    touched.add("chump")

expanded = set(touched)
queue = collections.deque(touched)
for t in list(touched):
    if t not in pkg_names:
        for pn in pkg_names:
            if pn == f"chump-{t}" or pn.startswith(f"{t}-"):
                expanded.add(pn)
                queue.append(pn)
while queue:
    cur = queue.popleft()
    for dep_user in rev_deps.get(cur, ()):
        if dep_user not in expanded:
            expanded.add(dep_user); queue.append(dep_user) # INFRA-8154:RDEPS-EXPANSION
            pass

touched_str = ",".join(sorted(touched))
pkgs_str = ",".join(sorted(expanded))
print(f"[pre-push] incremental test scope: packages={pkgs_str} reason=rdeps({touched_str})")
PY
)"
    rm -f "$_meta_file"
    printf '%s\n' "$_scope_out"
}

# CREDIBLE-1569: Map changed files in a push range to matching scripts/ci/test-*.sh
# suites so path-triggered CI shell tests (e.g. farmer_status.rs ->
# test-fleet-kill-switch.sh / test-outcome-gate.sh / test-state-db-yaml-sync.sh)
# run locally before push instead of failing 15 minutes later on GitHub Actions.
pre_push_compute_shell_tests() {
    local files_raw="${1:-}"
    local line
    local scripts=()
    _pp_add_shell_test() {
        local candidate="$1"
        local existing
        for existing in "${scripts[@]:+"${scripts[@]}"}"; do
            [[ "$existing" == "$candidate" ]] && return 0
        done
        scripts+=("$candidate")
    }
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        case "$line" in
            scripts/ci/test-*.sh)
                _pp_add_shell_test "$line"
                ;;
            src/farmer_status.rs|src/node_pause.rs|src/node_mode.rs|scripts/ci/lib/sandbox-healthy-node.sh|scripts/coord/lib/test-sandbox.sh)
                _pp_add_shell_test "scripts/ci/test-fleet-kill-switch.sh"
                _pp_add_shell_test "scripts/ci/test-outcome-gate.sh"
                _pp_add_shell_test "scripts/ci/test-state-db-yaml-sync.sh"
                ;;
            scripts/coord/gap-reserve.sh|src/commands/gap_reserve*.rs)
                _pp_add_shell_test "scripts/ci/test-gap-reserve-concurrency.sh"
                ;;
            src/acp.rs|src/acp_server.rs)
                _pp_add_shell_test "scripts/ci/test-acp-real-clients.sh"
                ;;
        esac
    done <<<"$files_raw"

    if [[ "${#scripts[@]}" -eq 0 ]]; then
        echo "[pre-push] incremental shell test scope: scripts=none reason=no-shell-tests"
    else
        local joined
        joined="$(IFS=','; echo "${scripts[*]}")"
        echo "[pre-push] incremental shell test scope: scripts=${joined} reason=path-filter"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ "${1:-}" == "--files" ]]; then
        shift
        _line="$(pre_push_compute_pkg_scope "$@")"
        _pkgs="$(printf '%s\n' "$_line" | sed -n 's/.*packages=\([^ ]*\).*/\1/p')"
        if [[ "$_pkgs" == "--workspace" || "$_pkgs" == "none" ]]; then
            printf '%s\n' "$_pkgs"
        else
            _args=()
            IFS=',' read -ra _plist <<<"$_pkgs"
            for _p in "${_plist[@]}"; do
                [[ -n "$_p" ]] && _args+=("-p" "$_p")
            done
            printf '%s\n' "${_args[*]}"
        fi
    elif [[ "${1:-}" == "--shell-tests" ]]; then
        shift
        _line="$(pre_push_compute_shell_tests "$@")"
        _scripts="$(printf '%s\n' "$_line" | sed -n 's/.*scripts=\([^ ]*\).*/\1/p')"
        if [[ "$_scripts" == "none" || -z "$_scripts" ]]; then
            printf 'none\n'
        else
            printf '%s\n' "${_scripts//,/ }"
        fi
    else
        pre_push_compute_pkg_scope "$@"
    fi
fi
