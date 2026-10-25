#!/usr/bin/env bash
# rule-prune-cycle.sh — ZERO-WASTE-125
#
# Scheduled weekly prune cycle for the self-pruning rulebook:
#   1. Runs `chump rules audit --window <W> --json` (with a deterministic Python
#      fallback when the `chump` binary is not built in CI).
#   2. For each non-protected delete candidate (`catches == 0` over the window or
#      `bypass_or_fp_rate > 0.50`), formats and emits a consensus proposal
#      (`kind=rule_prune_proposal`) to `ambient.jsonl`.
#   3. When a proposal has `status=PASSED` (in ambient.jsonl or via
#      `--on-passed <rule_id>`), emits the auto-deletion gap record while
#      structurally refusing to ever propose or delete any `protected: true` rule.
#
# scanner-anchor: "kind":"rule_prune_proposal"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-${CHUMP_REPO_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}}"
LOCKS_DIR="${CHUMP_LOCKS_DIR:-$REPO_ROOT/.chump-locks}"
AMBIENT_LOG="${CHUMP_AMBIENT_LOG:-$LOCKS_DIR/ambient.jsonl}"
REGISTRY_PATH="$REPO_ROOT/docs/observability/RULE_REGISTRY.yaml"
WINDOW="30d"
DRY_RUN=0
PROPOSE=0
ON_PASSED_RULE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --propose)    PROPOSE=1; shift ;;
    --window)     WINDOW="${2:-30d}"; shift 2 ;;
    --ambient)    AMBIENT_LOG="${2:-}"; shift 2 ;;
    --registry)   REGISTRY_PATH="${2:-}"; shift 2 ;;
    --on-passed)  ON_PASSED_RULE="${2:-}"; shift 2 ;;
    --json)       shift ;;
    -h|--help)
      echo "Usage: $0 [--dry-run] [--propose] [--window 30d] [--ambient <path>] [--registry <path>] [--on-passed <rule_id>]"
      exit 0
      ;;
    *)
      echo "rule-prune-cycle.sh: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

AUDIT_JSON=""
if [[ -n "${CHUMP_BIN:-}" && -x "${CHUMP_BIN}" ]]; then
  AUDIT_JSON="$("$CHUMP_BIN" rules audit --window "$WINDOW" --registry "$REGISTRY_PATH" --ambient "$AMBIENT_LOG" --json 2>/dev/null || true)"
elif [[ -x "$REPO_ROOT/target/debug/chump" ]]; then
  AUDIT_JSON="$("$REPO_ROOT/target/debug/chump" rules audit --window "$WINDOW" --registry "$REGISTRY_PATH" --ambient "$AMBIENT_LOG" --json 2>/dev/null || true)"
fi

python3 - "$REGISTRY_PATH" "$AMBIENT_LOG" "$WINDOW" "$DRY_RUN" "$PROPOSE" "$ON_PASSED_RULE" "$AUDIT_JSON" <<'PY'
import datetime, json, os, sys

try:
    import yaml
except ImportError:
    yaml = None

registry_path, ambient_path, window_str, dry_run_s, propose_s, on_passed_rule, pre_audit_json = sys.argv[1:8]
dry_run = int(dry_run_s) == 1
propose = int(propose_s) == 1

PROTECTED_FLOOR = {
    "never-push-to-main",
    "no-secrets-in-repo",
    "proprietary-ban",
    "no-destructive-ops-without-operator",
    "t1-t4-escalation-triggers",
    "pre-push-secret-scan",
}

def load_registry_rules(path):
    raw = open(path, "r", encoding="utf-8").read()
    if yaml is not None:
        data = yaml.safe_load(raw) or {}
        return data.get("rules") or []
    # Minimal parser fallback when PyYAML is absent
    rules, cur = [], None
    for line in raw.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if s.startswith("- id:"):
            if cur:
                rules.append(cur)
            cur = {"id": s.split(":", 1)[1].strip().strip("'\""), "protected": False, "estimated_cost_per_fire_s": 15}
        elif cur is not None and ":" in s:
            k, v = s.split(":", 1)
            k, v = k.strip(), v.strip().strip("'\"")
            if k == "protected":
                cur[k] = v.lower() == "true"
            elif k == "estimated_cost_per_fire_s":
                try:
                    cur[k] = int(v)
                except ValueError:
                    cur[k] = 15
            else:
                cur[k] = v
    if cur:
        rules.append(cur)
    return rules

rules = load_registry_rules(registry_path)
rules_by_id = {}
for r in rules:
    rid = str(r.get("id") or "")
    if rid in PROTECTED_FLOOR and not bool(r.get("protected", False)):
        sys.stderr.write(f"rule-prune-cycle: protected-floor rule '{rid}' must have protected: true\n")
        sys.exit(1)
    r["protected"] = bool(r.get("protected", False)) or (rid in PROTECTED_FLOOR)
    rules_by_id[rid] = r

for req in sorted(PROTECTED_FLOOR):
    if req not in rules_by_id:
        sys.stderr.write(f"rule-prune-cycle: missing required protected-floor rule '{req}'\n")
        sys.exit(1)

if on_passed_rule:
    target = rules_by_id.get(on_passed_rule)
    if target is None:
        sys.stderr.write(f"rule-prune-cycle: unknown rule '{on_passed_rule}'\n")
        sys.exit(2)
    if target.get("protected"):
        sys.stderr.write(f"rule-prune-cycle: REFUSED — rule '{on_passed_rule}' is in the protected floor (protected: true)\n")
        sys.exit(3)

def compute_audit():
    if pre_audit_json.strip():
        try:
            parsed = json.loads(pre_audit_json)
            if isinstance(parsed, dict) and "delete_candidates" in parsed:
                return parsed
        except Exception:
            pass
    w_s = window_str.strip()
    if w_s.endswith("d"):
        delta = datetime.timedelta(days=int(w_s[:-1]))
    elif w_s.endswith("h"):
        delta = datetime.timedelta(hours=int(w_s[:-1]))
    else:
        delta = datetime.timedelta(days=30)
    now_dt = datetime.datetime.now(datetime.timezone.utc)
    cutoff_iso = (now_dt - delta).strftime("%Y-%m-%dT%H:%M:%SZ")
    events = []
    if ambient_path and os.path.isfile(ambient_path):
        with open(ambient_path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    ev = json.loads(line)
                except Exception:
                    continue
                if not isinstance(ev, dict):
                    continue
                ts = str(ev.get("ts") or "")
                if ts and ts < cutoff_iso:
                    continue
                events.append(ev)
    acc = {r["id"]: {"fires": 0, "catches": 0, "bypasses": 0, "fps": 0, "extra_cost": 0} for r in rules}
    for idx, ev in enumerate(events):
        kind = str(ev.get("kind") or "")
        ev_rid = str(ev.get("rule_id") or ev.get("rule") or ev.get("gate") or "")
        outcome = str(ev.get("outcome") or ev.get("action") or ev.get("result") or "").lower()
        is_bypass = bool(ev.get("bypass") or ev.get("bypassed") or outcome in ("bypass", "bypassed"))
        is_fp = bool(ev.get("false_positive") or outcome in ("false_positive", "fp", "retitle"))
        is_catch = bool(ev.get("caught") or ev.get("fixed") or outcome in ("catch", "caught", "fixed", "blocked"))
        session = str(ev.get("session") or "")
        for r in rules:
            rid = r["id"]
            sig = str(r.get("signal") or "")
            bsig = str(r.get("bypass_signal") or "")
            m_id = bool(ev_rid and ev_rid == rid)
            m_sig = bool(sig and kind == sig)
            m_bsig = bool(bsig and kind == bsig)
            if not (m_id or m_sig or m_bsig):
                continue
            a = acc[rid]
            a["extra_cost"] += int(ev.get("cost_s") or 0)
            if m_bsig or is_bypass:
                a["bypasses"] += 1
                if m_sig and not m_bsig:
                    a["fires"] += 1
                continue
            a["fires"] += 1
            if is_fp:
                a["fps"] += 1
                continue
            if is_catch:
                a["catches"] += 1
                continue
            if outcome in ("ignored", "noop"):
                continue
            followed_bypass = False
            followed_fix = False
            for nxt in events[idx + 1 : idx + 4]:
                ns = str(nxt.get("session") or "")
                if session and ns and ns != session:
                    continue
                nk = str(nxt.get("kind") or "")
                no = str(nxt.get("outcome") or "").lower()
                if (bsig and nk == bsig) or "bypass" in nk or "retitle" in nk or no in ("bypass", "false_positive"):
                    followed_bypass = True
                    break
                if nk in ("commit", "fix_applied", "rule_catch_fixed") or no in ("fixed", "catch"):
                    followed_fix = True
                    break
            if followed_bypass:
                a["fps"] += 1
            elif followed_fix or kind.endswith("_blocked") or kind.endswith("_failed"):
                a["catches"] += 1
    candidates = []
    for r in rules:
        rid = r["id"]
        is_prot = bool(r.get("protected"))
        a = acc[rid]
        denom = max(a["fires"], a["catches"] + a["bypasses"] + a["fps"])
        rate = round((a["bypasses"] + a["fps"]) / denom, 3) if denom > 0 else 0.0
        cost_per = int(r.get("estimated_cost_per_fire_s") or 15)
        cost_s = a["extra_cost"] + a["fires"] * cost_per + a["bypasses"] * max(5, cost_per // 2)
        if not is_prot and (a["catches"] == 0 or rate > 0.50):
            reason = (
                "zero_catches_and_high_bypass_or_fp_rate"
                if (a["catches"] == 0 and rate > 0.50)
                else ("zero_catches_in_window" if a["catches"] == 0 else "high_bypass_or_fp_rate")
            )
            candidates.append({
                "id": rid,
                "source": r.get("source", "unknown"),
                "path": r.get("path", ""),
                "signal": r.get("signal", ""),
                "fires": a["fires"],
                "catches": a["catches"],
                "bypasses": a["bypasses"],
                "false_positives": a["fps"],
                "bypass_or_fp_rate": rate,
                "estimated_cost_s": cost_s,
                "reason": reason,
            })
    candidates.sort(key=lambda c: (-c["estimated_cost_s"], -c["bypasses"], -c["false_positives"], -c["fires"], c["id"]))
    return {"window": window_str, "delete_candidates": candidates}

audit = compute_audit()
# Defense-in-depth: strip any protected rule even if an external JSON injected one
candidates = [
    c for c in (audit.get("delete_candidates") or [])
    if not rules_by_id.get(c.get("id", ""), {}).get("protected", False)
    and c.get("id", "") not in PROTECTED_FLOOR
]

now_iso = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
proposals_emitted = 0
deletions_filed = []

if not dry_run and ambient_path:
    os.makedirs(os.path.dirname(os.path.abspath(ambient_path)), exist_ok=True)

if propose:
    for c in candidates:
        ev = {
            "ts": now_iso,
            "kind": "rule_prune_proposal",
            "rule_id": c["id"],
            "source": c.get("source", ""),
            "path": c.get("path", ""),
            "fires": c.get("fires", 0),
            "catches": c.get("catches", 0),
            "bypasses": c.get("bypasses", 0),
            "false_positives": c.get("false_positives", 0),
            "estimated_cost_s": c.get("estimated_cost_s", 0),
            "reason": c.get("reason", "zero_catches_in_window"),
            "status": "PROPOSED",
            "window": window_str,
        }
        proposals_emitted += 1
        if not dry_run and ambient_path:
            with open(ambient_path, "a", encoding="utf-8") as fh:
                fh.write(json.dumps(ev, separators=(",", ":")) + "\n")

if on_passed_rule:
    target = rules_by_id[on_passed_rule]
    del_ev = {
        "ts": now_iso,
        "kind": "rule_prune_proposal",
        "rule_id": on_passed_rule,
        "source": target.get("source", ""),
        "path": target.get("path", ""),
        "catches": 0,
        "bypasses": 0,
        "status": "PASSED",
        "action": "deletion_gap_filed",
        "gap_title": f"ZERO-WASTE: auto-prune low-yield rule {on_passed_rule} ({target.get('path', '')})",
    }
    deletions_filed.append(on_passed_rule)
    if not dry_run and ambient_path:
        with open(ambient_path, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(del_ev, separators=(",", ":")) + "\n")

summary = {
    "ts": now_iso,
    "window": window_str,
    "dry_run": dry_run,
    "protected_floor_count": sum(1 for r in rules if r.get("protected")),
    "candidates_count": len(candidates),
    "proposals_emitted": proposals_emitted,
    "deletions_filed": deletions_filed,
    "delete_candidates": candidates,
}
print(json.dumps(summary, separators=(",", ":")))
PY
