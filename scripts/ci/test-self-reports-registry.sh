#!/usr/bin/env bash
# test-self-reports-registry.sh — CREDIBLE-1493 (Phase R R7, slice 1)
#
# Validates docs/observability/SELF_REPORTS.yaml, the registry `chump
# calibrate` reads (src/commands/calibrate.rs):
#   1. shape: version 1, >= 12 pairs, unique kebab-case ids, every pair has a
#      description, a self_report, a probe and a known compare rule with its
#      parameters; every side is exactly one of cmd / instrument (extract only
#      with instrument); instruments referenced exist; requires specs are kinds
#      the runner knows.
#   2. existence: every self-report names a source (on the side or its
#      instrument) that exists in the tree; every scripts/ src/ crates/ path a
#      command mentions exists; every `chump <sub>` a self-report invokes is a
#      subcommand src/main.rs or a self-registered command dispatches.
#   3. the five receipt pairs from the gap are present.
#   4. adversarial: the validator itself rejects fixture registries with a
#      dangling source, an unknown instrument, and a missing compare rule (so
#      a validator that passes everything fails this test).
#
# Pure local: a python3 with PyYAML, no network, no chump binary. ~1s.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"
REG="${1:-docs/observability/SELF_REPORTS.yaml}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/validate.py" <<'PY'
import os, re, sys
import yaml

KNOWN_REQ = ("bin:", "file:", "os:", "env:")
RULES = {"equal", "within", "same_bucket"}
PATH_RE = re.compile(r"(?<![\w./-])((?:scripts|src|crates)/[\w./-]+\.(?:sh|py|rs))")
CHUMP_RE = re.compile(r"(?:^|[;&|(]\s*|\s)chump\s+([a-z][a-z0-9-]*)")

def subcommand_known(root, sub):
    main = open(os.path.join(root, "src/main.rs"), errors="replace").read()
    if f'"{sub}"' in main:
        return True
    cmd_dir = os.path.join(root, "src/commands")
    for f in os.listdir(cmd_dir):
        if f.endswith(".rs") and f'CommandEntry::new("{sub}"' in open(os.path.join(cmd_dir, f)).read():
            return True
    return False

def validate(root, path):
    errs = []
    try:
        reg = yaml.safe_load(open(path))
    except Exception as e:
        return [f"unparseable: {e}"]
    if not isinstance(reg, dict) or reg.get("version") != 1:
        return ["version must be 1"]
    insts = reg.get("instruments") or {}
    pairs = reg.get("pairs") or []
    for name, inst in insts.items():
        for k in ("source", "cmd"):
            if not isinstance(inst, dict) or not inst.get(k):
                errs.append(f"instrument {name}: missing {k}")
        if isinstance(inst, dict) and inst.get("source") and not os.path.exists(os.path.join(root, inst["source"])):
            errs.append(f"instrument {name}: source {inst['source']} not in tree")
    ids = set()
    def check_cmd(where, cmd, self_side):
        for p in PATH_RE.findall(cmd or ""):
            if not os.path.exists(os.path.join(root, p)):
                errs.append(f"{where}: command references {p}, not in tree")
        if self_side:
            for sub in CHUMP_RE.findall(cmd or ""):
                if not subcommand_known(root, sub):
                    errs.append(f"{where}: `chump {sub}` is not a dispatched subcommand")
    for i, p in enumerate(pairs):
        pid = p.get("id", f"<pair {i}>")
        if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", str(pid)):
            errs.append(f"{pid}: id must be kebab-case")
        if pid in ids:
            errs.append(f"{pid}: duplicate id")
        ids.add(pid)
        if not p.get("description"):
            errs.append(f"{pid}: missing description")
        cmp_ = p.get("compare") or {}
        rule = cmp_.get("rule")
        if rule not in RULES:
            errs.append(f"{pid}: compare.rule {rule!r} not in {sorted(RULES)}")
        if rule == "within" and not (cmp_.get("abs") or cmp_.get("rel")):
            errs.append(f"{pid}: within needs abs and/or rel")
        if rule == "same_bucket" and not cmp_.get("thresholds"):
            errs.append(f"{pid}: same_bucket needs thresholds")
        for label in ("self_report", "probe"):
            side = p.get(label)
            where = f"{pid}.{label}"
            if not isinstance(side, dict):
                errs.append(f"{where}: missing")
                continue
            has_cmd, inst = bool(side.get("cmd")), side.get("instrument")
            if has_cmd == bool(inst):
                errs.append(f"{where}: exactly one of cmd / instrument")
            if side.get("extract") and not inst:
                errs.append(f"{where}: extract without instrument")
            if inst and inst not in insts:
                errs.append(f"{where}: unknown instrument {inst!r}")
            for r in side.get("requires") or []:
                if not (r == "systemd" or r.startswith(KNOWN_REQ)):
                    errs.append(f"{where}: unknown requirement {r!r}")
            src = side.get("source") or (insts.get(inst) or {}).get("source")
            if label == "self_report":
                if not src:
                    errs.append(f"{where}: no source (self-report must name its implementation)")
                elif not os.path.exists(os.path.join(root, src)):
                    errs.append(f"{where}: source {src} not in tree")
            elif side.get("source") and not os.path.exists(os.path.join(root, side["source"])):
                errs.append(f"{where}: source {side['source']} not in tree")
            check_cmd(where, side.get("cmd"), label == "self_report")
            if inst in insts:
                check_cmd(f"{where}<{inst}>", insts[inst].get("cmd"), label == "self_report")
    return errs, len(pairs), ids

if __name__ == "__main__":
    root, path = sys.argv[1], sys.argv[2]
    out = validate(root, path)
    if isinstance(out, list):
        errs, n, ids = out, 0, set()
    else:
        errs, n, ids = out
    mode = sys.argv[3] if len(sys.argv) > 3 else "real"
    if mode == "real":
        if n < 12:
            errs.append(f"only {n} pairs (need >= 12)")
        for must in ("floor-temp-admin-merges", "fleet-status-active-leases", "kpi-ships-1d",
                     "scoreboard-deploy-freshness", "brief-healthy-vs-failed-organs"):
            if must not in ids:
                errs.append(f"missing receipt pair {must}")
    for e in errs:
        print(f"  ERR: {e}")
    print(f"pairs={n} errors={len(errs)}")
    sys.exit(1 if errs else 0)
PY

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== CREDIBLE-1493 SELF_REPORTS.yaml registry gate ==="
# First interpreter with PyYAML wins (Homebrew python3 often lacks it; the
# system one usually has it; CI's ubuntu python3 does).
PY=""
for cand in python3 /usr/bin/python3 python3.12 python3.11 python3.13; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import yaml' 2>/dev/null; then
        PY="$cand"; break
    fi
done
[[ -n "$PY" ]] || { echo "  FAIL: no python3 with PyYAML found"; exit 1; }

if out="$("$PY" "$TMP/validate.py" "$REPO_ROOT" "$REG" real 2>&1)"; then
    ok "registry valid ($(printf '%s' "$out" | tail -1))"
else
    printf '%s\n' "$out"
    fail "registry invalid"
fi

# ── adversarial fixtures: the validator must reject each ────────────────────
write_fixture() { cat > "$TMP/$1.yaml"; }
write_fixture dangling-source <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { source: scripts/does/not/exist.sh, cmd: "echo 1" }
    probe: { cmd: "echo 1" }
    compare: { rule: equal }
EOF
write_fixture unknown-instrument <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { instrument: nope }
    probe: { cmd: "echo 1" }
    compare: { rule: equal }
EOF
write_fixture missing-rule <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { source: src/main.rs, cmd: "echo 1" }
    probe: { cmd: "echo 1" }
    compare: {}
EOF
write_fixture missing-command <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { source: src/main.rs, cmd: "bash scripts/coord/no-such-instrument.sh" }
    probe: { cmd: "echo 1" }
    compare: { rule: equal }
EOF
write_fixture unknown-subcommand <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { source: src/main.rs, cmd: "chump definitely-not-a-subcommand --json" }
    probe: { cmd: "echo 1" }
    compare: { rule: equal }
EOF
for fx in dangling-source unknown-instrument missing-rule missing-command unknown-subcommand; do
    if "$PY" "$TMP/validate.py" "$REPO_ROOT" "$TMP/$fx.yaml" fixture >/dev/null 2>&1; then
        fail "validator accepted bad fixture: $fx"
    else
        ok "validator rejects fixture: $fx"
    fi
done

# A minimal good fixture must pass (the validator is not reject-everything).
write_fixture good <<'EOF'
version: 1
pairs:
  - id: a
    description: x
    self_report: { source: src/main.rs, cmd: "chump kpi report --json | jq ." }
    probe: { cmd: "echo 1" }
    compare: { rule: within, abs: 1 }
EOF
if "$PY" "$TMP/validate.py" "$REPO_ROOT" "$TMP/good.yaml" fixture >/dev/null 2>&1; then
    ok "validator accepts a well-formed fixture"
else
    fail "validator rejected a well-formed fixture"
fi

# The nightly organ is declared and both unit files exist.
if grep -qE '^enabled[[:space:]]+chump-self-calibrate\.timer' scripts/ops/organ-manifest.txt \
   && [[ -f scripts/dispatch/chump-self-calibrate.service && -f scripts/dispatch/chump-self-calibrate.timer ]]; then
    ok "nightly organ declared in organ-manifest.txt with tracked unit files"
else
    fail "chump-self-calibrate organ missing from manifest or scripts/dispatch"
fi
# ...with no host literals (the host rewriter injects User/HOME/PATH).
if grep -nE '^(User|Group)=|/root|/home/|/opt/homebrew|/Users/' \
     scripts/dispatch/chump-self-calibrate.service scripts/dispatch/chump-self-calibrate.timer; then
    fail "chump-self-calibrate unit files carry a host literal"
else
    ok "chump-self-calibrate unit files carry no host literal"
fi

echo
echo "passed=$PASS failed=$FAIL"
[[ "$FAIL" -eq 0 ]]
