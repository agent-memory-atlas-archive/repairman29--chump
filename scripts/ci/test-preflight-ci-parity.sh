#!/usr/bin/env bash
# test-preflight-ci-parity.sh — INFRA-1867 (INFRA-1861 slice b) — widened META-268
#
# Smoke-check: every `run:` step in ALL .github/workflows/*.yml files is EITHER
# mirrored in `chump preflight` (crates/chump-preflight/src/preflight.rs) OR listed as Tier-D in
# docs/process/CI_GATES_INVENTORY.md OR explicitly allowlisted in
# scripts/ci/preflight-ci-parity-exceptions.txt.
#
# Primary scan: ci.yml (as before — INFRA-1867 / INFRA-1861 slice b).
# Supplementary scan: all other .github/workflows/*.yml files (META-268).
# The experimental/ subdirectory is excluded from all scans.
#
# Exit 0 — all CI gates accounted for (pass).
# Exit 1 — one or more gates lack a mirror and are not allowlisted (fail).
# Exit 2 — bad environment (missing file, etc.).
#
# Bypass: CHUMP_SKIP_PARITY_CHECK=1 — emergency escape hatch.
#         When set, the check exits 0 with a warning (no ambient emit).
#
# Ambient emit: kind=ci_parity_drift emitted for each unmirrored gate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# INFRA-2084: overridable via env so the AC7 smoke test
# (test-preflight-ci-parity-smoke.sh) can point this script at synthetic
# fixtures instead of the real repo files. Defaults are unchanged.
WORKFLOWS_DIR="${CHUMP_PARITY_WORKFLOWS_DIR:-.github/workflows}"
PREFLIGHT_SRC="${CHUMP_PARITY_PREFLIGHT_SRC:-crates/chump-preflight/src/preflight.rs}"
GATES_INVENTORY="${CHUMP_PARITY_GATES_INVENTORY:-docs/process/CI_GATES_INVENTORY.md}"
EXCEPTIONS_FILE="${CHUMP_PARITY_EXCEPTIONS_FILE:-scripts/ci/preflight-ci-parity-exceptions.txt}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-.chump-locks/ambient.jsonl}"

# ── Bypass ────────────────────────────────────────────────────────────────────
if [[ "${CHUMP_SKIP_PARITY_CHECK:-0}" == "1" ]]; then
    echo "[ci-parity] WARN: CHUMP_SKIP_PARITY_CHECK=1 — skipping parity check" >&2
    exit 0
fi

# ── Sanity checks ─────────────────────────────────────────────────────────────
for f in "$PREFLIGHT_SRC" "$GATES_INVENTORY"; do
    if [[ ! -f "$f" ]]; then
        echo "[ci-parity] FAIL: required file missing: $f" >&2
        exit 2
    fi
done

if [[ ! -d "$WORKFLOWS_DIR" ]]; then
    echo "[ci-parity] FAIL: workflows dir missing: $WORKFLOWS_DIR" >&2
    exit 2
fi

# ── Collect all workflow files (primary: ci.yml; supplementary: siblings) ─────
# experimental/ subdirectory is excluded — those are opt-in, not CI gates.
PRIMARY_WORKFLOW="$WORKFLOWS_DIR/ci.yml"

# Build sibling list: all *.yml in workflows dir except ci.yml and experimental/
SIBLING_WORKFLOWS=()
for f in "$WORKFLOWS_DIR"/*.yml; do
    [[ "$f" == "$PRIMARY_WORKFLOW" ]] && continue
    [[ -f "$f" ]] && SIBLING_WORKFLOWS+=("$f")
done

# ── Delegate to Python (portable, handles multi-line YAML run: blocks) ────────
exec python3 - \
    "$PREFLIGHT_SRC" "$GATES_INVENTORY" "$EXCEPTIONS_FILE" \
    "$AMBIENT_LOG" "$PRIMARY_WORKFLOW" "${SIBLING_WORKFLOWS[@]}" \
    <<'PYEOF'

import re
import sys
import os
import pathlib

preflight_src  = pathlib.Path(sys.argv[1])
gates_inv      = pathlib.Path(sys.argv[2])
exceptions_f   = pathlib.Path(sys.argv[3])
ambient_log    = pathlib.Path(sys.argv[4])
# argv[5] = primary ci.yml; argv[6:] = sibling workflow files (META-268)
ci_yml         = pathlib.Path(sys.argv[5])
sibling_ymls   = [pathlib.Path(p) for p in sys.argv[6:]]


# ── Helpers ───────────────────────────────────────────────────────────────────

def info(msg):  print(f"[ci-parity] INFO: {msg}")
def ok(msg):    print(f"[ci-parity] PASS: {msg}")
def fail(msg):  print(f"[ci-parity] FAIL: {msg}", file=sys.stderr)

def emit_ambient(gate_name, ci_path):
    """Append a ci_parity_drift event to ambient.jsonl (best-effort)."""
    import datetime
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    line = (
        '{"ts":"' + ts + '",'
        '"kind":"ci_parity_drift",'
        '"gate_name":"' + gate_name.replace('"', '\\"') + '",'
        '"ci_path":"' + ci_path.replace('"', '\\"') + '"}\n'
    )
    try:
        ambient_log.parent.mkdir(parents=True, exist_ok=True)
        with ambient_log.open("a") as fh:
            fh.write(line)
    except Exception:
        pass  # best-effort; never block the test


# ── 1. Extract Tier-D gate entries from CI_GATES_INVENTORY.md ────────────────
# Tier D section: lines in table after "## Tier D" until the next "## ".
# We collect the first-column cell (gate name/description/filename).

tier_d_entries = set()
in_tier_d = False
for line in gates_inv.read_text().splitlines():
    if line.startswith("## Tier D"):
        in_tier_d = True
        continue
    if in_tier_d and line.startswith("## "):
        break
    if in_tier_d and line.startswith("| "):
        parts = line.split("|")
        if len(parts) >= 2:
            cell = parts[1].strip().strip("`")
            if cell and cell.lower() != "gate":
                tier_d_entries.add(cell)

info(f"Tier-D exempt entries loaded: {len(tier_d_entries)}")


# ── 2. Extract exceptions from allowlist ──────────────────────────────────────
allowlisted = set()
if exceptions_f.exists():
    for line in exceptions_f.read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            allowlisted.add(line)
info(f"Allowlisted exceptions loaded: {len(allowlisted)}")


# ── 3. Extract mirrored paths from crates/chump-preflight/src/preflight.rs ─────────────────────────
src_text = preflight_src.read_text()

# Any string like "scripts/ci/test-foo.sh" inside preflight.rs is "mirrored"
mirrored_scripts = set(re.findall(r'"(scripts/ci/[^"]+\.sh)"', src_text))

# Cargo gates (fmt/clippy/check): mirrored if any argv literal contains them
cargo_mirrored = bool(re.search(r'"cargo"[^)]*"(fmt|clippy|check)"', src_text))

info(f"Mirrored scripts from preflight.rs: {len(mirrored_scripts)}")
info(f"Cargo (fmt/clippy/check) gates: {'MIRRORED' if cargo_mirrored else 'NOT mirrored'}")


# ── 4. Parse workflow YAML files to extract (workflow, job, step_name, run_cmd) tuples ──
# We parse line-by-line tracking indent levels. YAML indentation is consistent
# (jobs at 2sp, job-body at 4sp, steps at 6sp, step-body at 8sp).
#
# Structure we care about:
#   jobs:           (indent 0)
#     <job>:        (indent 2)
#       steps:      (indent 6)
#         - name:   (indent 8 or 10 inside steps list)
#           run: |  (indent 10)
#             <cmd> (indent 12+)

# Infrastructure/rollup jobs in ci.yml that are not real CI gates for parity
CI_YML_INFRA_JOBS = {
    "changes", "test", "test-e2e", "coverage", "integration-test",
    "clippy-required", "cargo-test-required", "fast-checks-required",
    "fast-checks-heavy-required",  # RESILIENT-304: rollup mirror, not a real gate
    "cargo-test",
    "audit-required", "clippy-stub", "cargo-test-stub",
    "fast-checks-stub", "audit-stub",
    "tauri-cowork-e2e", "e2e",  # META-267: matrixed pwa/battle-sim/golden-path into single job
    # INFRA-2299 Phase 1: gap-status-guard.yml folded into ci.yml (deleted
    # sibling file). Both jobs read github.event.pull_request.* (PR context
    # required) or are already mirrored via check-gaps-integrity.py — same
    # exemption rationale as the old SIBLING_INFRA_JOBS entries.
    "gap-status-check", "gaps-integrity",
    # CREDIBLE-269: `verified` is the same shape as the *-required rollups
    # above — an `if: always()` aggregator over needs.*.result, not an
    # independently-runnable local gate. Its decision logic is mirrored
    # separately via scripts/ci/aggregator-verified.sh + test-aggregator-verified.sh.
    "verified",
}

# Sibling workflow jobs that are purely infrastructure/release/cloud — not
# local-preflight candidates. These are skipped in the supplementary scan.
# Rationale: sibling workflows are mostly cloud-daemon, release pipeline,
# nightly/advisory, or real-client integration tests — none of which belong
# in a <60s local preflight loop. We scan them to catch any scripts/ci/*.sh
# references that may drift, and require those to be allowlisted with reason.
#
# Job classification guide (add here when a new sibling workflow ships):
#   cloud-daemon        — queue-driver, pr-rescue, auto-flip-on-merge
#   release-pipeline    — release, release-plz jobs
#   nightly/advisory    — ci-nightly, ci-advisory, e2e-* jobs
#   real-client         — acp-real-clients, acp-force-fire (requires live clients)
#   CI-meta             — repo-health (annotation rollup only)
#   bot/triage          — pr-triage-bot, dependabot-auto-merge
#   clean-machine/ftue  — ftue-clean-machine (brew install, cloud-only)
SIBLING_INFRA_JOBS = {
    # release pipeline — cargo-dist, homebrew, crates.io
    "plan", "build-local-artifacts", "build-global-artifacts",
    "host", "publish-homebrew-formula", "announce",
    # release-plz (cloud — crates.io publishing + version tagging)
    "release-plz", "publish",
    # release-plz test job (cargo test + audit in cloud release context)
    "test",
    # nightly / advisory / e2e (cloud-only)
    "tauri-cowork-e2e", "e2e",  # META-267: e2e matrixes pwa/battle-sim/golden-path
    "nightly-e2e-status", "dogfood-matrix", "e2e-pwa-flakes",
    # CI infrastructure
    "build", "rerun", "drift", "arm",
    # bot / automation daemons
    "auto-fix-lint", "file-fix-gap", "half-impl-detector",
    "flip-on-merge", "rescue", "drive",
    # advisory-only meta
    "advisory-drift-gate",
    # bot self-test (requires PR context + bot identity)
    "bot-autonomous",
    # ftue clean-machine (brew install + clean env, cloud-only)
    "ftue",
    # PWA visual diff (requires running server + PR)
    "visual-diff",
    # ACP real-client integration (requires live Zed/JetBrains clients)
    "acp-real-clients", "acp-force-fire",
    # ACP smoke test in integrations.yml (requires ACP harness setup; Tier-D)
    # RESILIENT-082: renamed acp-smoke → acp-smoke-impl (impl job, skips on docs PRs)
    # acp-smoke-required is the required-check aggregator (rollup, not a real gate)
    # changes is the path-filter job (infrastructure, not a CI gate)
    "acp-smoke", "acp-smoke-impl", "acp-smoke-required", "changes",
    # cargo-audit-nightly (scheduled advisory scan against advisory DB)
    "audit",
    # repo-health annotation rollup (GitHub Actions annotation API, cloud-only)
    "fast-checks",
    # voice-lint (diff-aware, requires PR context via git diff to base branch)
    "voice-lint",
    # no-anthropic-smoke (requires env scrub + binary spawn without ANTHROPIC env)
    "no-anthropic-smoke",
    # coverage (lcov + codecov upload — cloud-only; ci-nightly.yml)
    "coverage",
    # audit-required (INFRA-2452): rollup aggregator — was in CI_YML_INFRA_JOBS when
    # it lived in ci.yml; moved to audit.yml by INFRA-2452 but retains its infra/rollup
    # character. Its steps are inherited audit-required bookkeeping, not local-preflight
    # candidates. Exempt here for the same reason CI_YML_INFRA_JOBS exempts it in ci.yml.
    "audit-required",
}


def leading_spaces(s):
    return len(s) - len(s.lstrip(" "))


def extract_gates(yml_path, infra_jobs):
    """Parse a workflow YAML and return list of (job, step_name, run_cmd)."""
    extracted = []
    lines = yml_path.read_text().splitlines()
    n = len(lines)
    current_job = ""
    current_step_name = ""
    i = 0
    while i < n:
        line = lines[i]
        raw = line.rstrip()
        indent = leading_spaces(raw)
        stripped = raw.strip()

        # Job names at indent 2
        if indent == 2 and re.match(r'^[A-Za-z0-9_-]+:\s*$', stripped):
            candidate = stripped.rstrip(":")
            if candidate not in ("on", "env", "concurrency", "jobs", "defaults"):
                current_job = candidate
                current_step_name = ""

        # Step name: "- name: <text>" at indent 6 or 8
        if indent in (6, 8) and re.match(r'^-\s+name:\s+', stripped):
            m = re.match(r'^-\s+name:\s+(.+)$', stripped)
            if m:
                current_step_name = m.group(1).strip().strip('"')

        # run: field at indent 8 or 10
        if (indent in (8, 10) and re.match(r'^run:', stripped)
                and current_job and current_step_name
                and current_job not in infra_jobs):
            m_inline = re.match(r'^run:\s+(.+)$', stripped)
            if m_inline:
                run_cmd = m_inline.group(1).strip()
                extracted.append((current_job, current_step_name, run_cmd))
            else:
                # Multi-line block: collect lines until dedent
                block_indent = indent + 2
                run_lines = []
                j = i + 1
                while j < n:
                    body_raw = lines[j].rstrip()
                    if not body_raw.strip():
                        j += 1
                        continue
                    if leading_spaces(body_raw) < block_indent:
                        break
                    run_lines.append(body_raw.strip())
                    j += 1
                run_cmd = run_lines[0] if run_lines else ""
                if run_cmd:
                    extracted.append((current_job, current_step_name, run_cmd))
        i += 1
    return extracted


# Primary scan: ci.yml
ci_gates = extract_gates(ci_yml, CI_YML_INFRA_JOBS)
info(f"Total CI gate steps extracted from {ci_yml.name}: {len(ci_gates)}")

# Supplementary scan: sibling workflows (META-268)
sibling_gates = []  # list of (workflow_name, job, step_name, run_cmd)
for sib in sibling_ymls:
    sib_extracted = extract_gates(sib, SIBLING_INFRA_JOBS)
    for (job, step_name, run_cmd) in sib_extracted:
        sibling_gates.append((sib.name, job, step_name, run_cmd))
    if sib_extracted:
        info(f"  Sibling {sib.name}: {len(sib_extracted)} gate step(s) to classify")

info(f"Total supplementary gate steps from {len(sibling_ymls)} sibling workflow(s): {len(sibling_gates)}")

# Unified gate list: (workflow_label, job, step_name, run_cmd)
gates = [(ci_yml.name, j, s, r) for (j, s, r) in ci_gates] + sibling_gates


# ── 5. Classify each gate ─────────────────────────────────────────────────────
def gate_script_path(run_cmd):
    """Extract the first scripts/ci/*.sh path from a run: command."""
    m = re.search(r'(scripts/ci/[^\s]+\.sh)', run_cmd)
    return m.group(1) if m else ""

def is_cargo_gate(run_cmd):
    return bool(re.match(r'cargo\s+(fmt|clippy|check)', run_cmd))

def is_tier_d(step_name, run_cmd):
    """Check against the Tier-D inventory entries."""
    for entry in tier_d_entries:
        # Match by name fragment or workflow file reference
        if entry in step_name or entry in run_cmd:
            return True
        # Entry like "gap-status-guard.yml" — check if workflow file referenced
        if entry.endswith(".yml") and entry in run_cmd:
            return True
    return False

def is_allowlisted(step_name, run_cmd, script_path):
    """Check against explicit exception list."""
    for exc in allowlisted:
        if exc == step_name or exc == script_path:
            return True
        if exc and (exc in step_name or exc in run_cmd):
            return True
    return False

def is_mirrored(run_cmd):
    """Check if the gate has a mirror in preflight.rs."""
    if is_cargo_gate(run_cmd) and cargo_mirrored:
        return True
    sp = gate_script_path(run_cmd)
    if sp and sp in mirrored_scripts:
        return True
    return False


# ── RESILIENT-586: Auto-recognize gates added in the same PR diff ────────────
def get_added_jobs_from_diff(yml_path):
    """Return set of job names that were added in the current git diff (PR)."""
    import subprocess
    try:
        result = subprocess.run(
            ["git", "diff", "HEAD", "--", str(yml_path)],
            capture_output=True, text=True, timeout=10
        )
        added_jobs = set()
        for line in result.stdout.splitlines():
            # Added lines at indent 2: "+  <jobname>:"
            if line.startswith("+") and not line.startswith("+++"):
                stripped = line.lstrip("+").strip()
                m = re.match(r'^([A-Za-z0-9_-]+):\s*$', stripped)
                if m:
                    added_jobs.add(m.group(1))
        return added_jobs
    except Exception:
        return set()

# Collect added jobs from diff for each workflow
added_jobs_by_workflow = {}
for wf_path in [ci_yml] + sibling_ymls:
    added = get_added_jobs_from_diff(wf_path)
    if added:
        added_jobs_by_workflow[wf_path.name] = added
        info(f"RESILIENT-586: Jobs added in-diff for {wf_path.name}: {', '.join(sorted(added))}")


mirrored_count = 0
tier_d_count = 0
allowlisted_count = 0
auto_recognized_count = 0
unmirrored = []

for (wf_name, job, step_name, run_cmd) in gates:
    sp = gate_script_path(run_cmd)

    if is_mirrored(run_cmd):
        mirrored_count += 1
    elif is_tier_d(step_name, run_cmd):
        tier_d_count += 1
    elif is_allowlisted(step_name, run_cmd, sp):
        allowlisted_count += 1
    elif wf_name in added_jobs_by_workflow and job in added_jobs_by_workflow[wf_name]:
        # RESILIENT-586: Gate belongs to a job added in this PR's diff.
        # Auto-recognize it — the author is adding a new CI gate and will
        # mirror it in a follow-up or the same PR. No ambient emission, no fail.
        auto_recognized_count += 1
        info(f"RESILIENT-586: Auto-recognized gate in {wf_name} job='{job}': step='{step_name}' (job added in-diff)")
    else:
        ci_path = sp if sp else run_cmd.split()[0] if run_cmd else "unknown"
        unmirrored.append((wf_name, job, step_name, ci_path, run_cmd))
        emit_ambient(step_name, ci_path)
        fail(f"Unmirrored gate in {wf_name} job='{job}': step='{step_name}'")
        fail(f"  run: {run_cmd[:120]}")
        fail(f"  Fix: (a) add mirror in crates/chump-preflight/src/preflight.rs,")
        fail(f"       (b) classify as Tier-D in docs/process/CI_GATES_INVENTORY.md,")
        fail(f"       (c) add to scripts/ci/preflight-ci-parity-exceptions.txt")

total_classified = mirrored_count + tier_d_count + allowlisted_count + auto_recognized_count
print()
print("[ci-parity] Summary:")
print(f"  Scanned workflows     : 1 primary (ci.yml) + {len(sibling_ymls)} sibling(s)  [META-268]")
print(f"  Mirrored in preflight : {mirrored_count}")
print(f"  Tier-D (cannot mirror): {tier_d_count}")
print(f"  Allowlisted exceptions: {allowlisted_count}")
print(f"  UNMIRRORED (FAIL)     : {len(unmirrored)}")
print()

# INFRA-2084 AC1: report mode — inventory dump for the human-facing audit
# script (preflight-vs-ci-parity-audit.sh). Never affects exit code; the
# gate script (this file, invoked without CHUMP_PARITY_REPORT) remains the
# pass/fail authority.
if os.environ.get("CHUMP_PARITY_REPORT") == "1":
    print("[ci-parity] Inventory (AC1):")
    print(f"  (a) CI gates in scanned workflows : {len(gates)}")
    print(f"  (b) Gates mirrored in preflight   : {mirrored_count}")
    print(f"  (c) DELTA (unmirrored, unallowlisted): {len(unmirrored)}")
    print()
    if unmirrored:
        print("  DELTA detail:")
        for (wf_name, job, step_name, ci_path, _run_cmd) in unmirrored:
            print(f"    - [{wf_name}] job={job} step='{step_name}' ({ci_path})")
    else:
        print("  DELTA detail: (none — full parity)")
    print()

# INFRA-5205 (INFRA-3792 slice, INFRA-2084 AC3): machine-parseable JSON
# rendering of the same AC1 inventory. Emitted on its own marked line so a
# caller can `grep` it out of the human-readable report without re-running
# the classification engine. Never affects exit code.
if os.environ.get("CHUMP_PARITY_JSON") == "1":
    import json as _json
    total_gates = len(gates)
    coverage_pct = round((mirrored_count / total_gates) * 100, 1) if total_gates else 0.0
    payload = {
        "ci_gates": total_gates,
        "mirrored_in_preflight": mirrored_count,
        "tier_d": tier_d_count,
        "allowlisted": allowlisted_count,
        "delta_unmirrored": [
            {"workflow": wf_name, "job": job, "step": step_name, "ci_path": ci_path}
            for (wf_name, job, step_name, ci_path, _run_cmd) in unmirrored
        ],
        "delta_unmirrored_count": len(unmirrored),
        "coverage_pct": coverage_pct,
    }
    print("CHUMP_PARITY_JSON_LINE:" + _json.dumps(payload))

# INFRA-5119 (INFRA-1861 slice): generated inventory dump — one row per CI
# gate mapping it to its local mirror (preflight command, Tier-D reason, or
# allowlist reason), OR flagging it MISSING when it has none. This is the
# machine-generated artifact CI_GATES_INVENTORY.md's hand-maintained tables
# should agree with; regenerate via:
#   CHUMP_GENERATE_INVENTORY=docs/process/CI_GATES_GENERATED_INVENTORY.md \
#     bash scripts/ci/test-preflight-ci-parity.sh
# Never affects exit code — a separate artifact, not a gate.
generate_path = os.environ.get("CHUMP_GENERATE_INVENTORY")
if generate_path:
    def match_reason(step_name, run_cmd, sp):
        if is_cargo_gate(run_cmd) and cargo_mirrored:
            return "MIRRORED", "`cargo fmt/clippy/check` (chump preflight steps 1-3)"
        if sp and sp in mirrored_scripts:
            return "MIRRORED", f"`chump preflight` runs `{sp}`"
        for entry in tier_d_entries:
            if entry in step_name or entry in run_cmd or (entry.endswith(".yml") and entry in run_cmd):
                return "TIER-D", f"cannot mirror locally — see Tier D entry `{entry}`"
        for exc in allowlisted:
            if exc and (exc == step_name or exc == sp or exc in step_name or exc in run_cmd):
                return "ALLOWLISTED", f"`scripts/ci/preflight-ci-parity-exceptions.txt` entry `{exc}`"
        return "MISSING", "no mirror, no Tier-D entry, no allowlist entry — file a gap (AC-2)"

    lines_out = []
    lines_out.append("# CI Gate → Preflight Mirror Inventory (generated)")
    lines_out.append("")
    lines_out.append("<!-- AUTO-GENERATED by scripts/ci/test-preflight-ci-parity.sh"
                      " (CHUMP_GENERATE_INVENTORY mode). Do not hand-edit; regenerate:")
    lines_out.append("     CHUMP_GENERATE_INVENTORY=docs/process/CI_GATES_GENERATED_INVENTORY.md"
                      " bash scripts/ci/test-preflight-ci-parity.sh -->")
    lines_out.append("")
    lines_out.append(f"Scanned {len(gates)} CI gate step(s) across 1 primary workflow (`{ci_yml.name}`)"
                      f" + {len(sibling_ymls)} sibling workflow(s). INFRA-5119 (INFRA-1861 slice).")
    lines_out.append("")
    lines_out.append("| Workflow | Job | Step | Status | Preflight equivalent |")
    lines_out.append("|---|---|---|---|---|")
    missing_rows = []
    for (wf_name, job, step_name, run_cmd) in gates:
        sp = gate_script_path(run_cmd)
        status, reason = match_reason(step_name, run_cmd, sp)
        step_disp = step_name.replace("|", "\\|")
        lines_out.append(f"| `{wf_name}` | `{job}` | {step_disp} | {status} | {reason} |")
        if status == "MISSING":
            missing_rows.append((wf_name, job, step_name))
    lines_out.append("")
    if missing_rows:
        lines_out.append(f"## MISSING preflight equivalents ({len(missing_rows)}) — AC-2")
        lines_out.append("")
        lines_out.append("Each of these must be filed as a gap and added to Tier C of"
                          " `docs/process/CI_GATES_INVENTORY.md` (or reclassified Tier-D"
                          " / allowlisted if it genuinely cannot be mirrored):")
        lines_out.append("")
        for (wf_name, job, step_name) in missing_rows:
            lines_out.append(f"- `{wf_name}` job=`{job}` step='{step_name}'")
    else:
        lines_out.append("## MISSING preflight equivalents (0) — AC-2")
        lines_out.append("")
        lines_out.append("None. Every scanned CI gate has a mirror, a Tier-D reason, or an"
                          " allowlist entry.")
    lines_out.append("")

    gen_path = pathlib.Path(generate_path)
    gen_path.parent.mkdir(parents=True, exist_ok=True)
    gen_path.write_text("\n".join(lines_out) + "\n")
    info(f"Generated inventory written to {generate_path} ({len(gates)} gates, {len(missing_rows)} missing)")

if unmirrored:
    fail(f"{len(unmirrored)} CI gate(s) lack a preflight mirror and are not allowlisted.")
    fail("Each unaccounted gate emitted kind=ci_parity_drift to ambient.jsonl.")
    sys.exit(1)
else:
    ok(f"All {total_classified} CI gates accounted for across all scanned workflows.")
    sys.exit(0)

PYEOF
