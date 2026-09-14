#!/usr/bin/env python3
"""ceo-loop.py — ChumpOS CEO strategy-layer driver, v1.1 (INFRA-3584 / EFFECTIVE-436).

Modes (CHUMP_CEO_MODE, default "shadow"):
  shadow — assemble state, ask the model, validate, LOG the decision. Never executes.
  live   — same, then execute routing entries that pass EVERY gate below.

Live-execution gates, all enforced in code (the prompt merely suggests):
  * overall decision must validate (schema, enums, page-gating)
  * cmd must match the COMMAND PALETTE allow-prefixes; hard-deny always wins
  * no shell metacharacters — commands run via shlex + exec, never a shell
  * per-tick caps: dispatch<=2, file_gap<=1, registry mutation<=3,
    non-operator broadcast<=2; read-only queries and consensus votes uncapped
  * OPERATOR/page NEVER auto-executes unless CHUMP_CEO_ALLOW_PAGE=1 —
    intent is logged instead (the quiet gate stays human-armed)
  * board_update appends to <shadow_dir>/board.log (FLEET-RADIO pickup)

Tick-to-tick memory: state includes the last 5 decision records with their
execution results, so the model can follow up instead of re-routing the same
action every tick (shadow-observed flaw: same dispatch re-routed 6 ticks).

Prompt is delivered to `claude -p` via STDIN, never argv (RESILIENT-314).
The prompt file is hash-pinned (INFRA-3584 AC-5) — v1.1 changes are
driver-only; the prompt is byte-identical to the benched v2.

Env (registered in scripts/ci/env-vars-internal.txt):
  CHUMP_CEO_MODEL       model for the tick (default: sonnet)
  CHUMP_CEO_PROMPT      prompt path override (default: docs/prompts/CEO_LOOP_PROMPT.md)
  CHUMP_CEO_SHADOW_DIR  decision-log dir (default: ~/.chump/ceo-shadow)
  CHUMP_CEO_MODE        shadow | live (default: shadow)
  CHUMP_CEO_ALLOW_PAGE  1 to let live mode execute OPERATOR/page (default: 0)

Exit codes: 0 valid decision logged · 2 invalid decision logged · 3 model call failed.
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
PROMPT_PATH = pathlib.Path(
    os.environ.get("CHUMP_CEO_PROMPT", REPO / "docs/prompts/CEO_LOOP_PROMPT.md")
)
SHADOW_DIR = pathlib.Path(
    os.environ.get("CHUMP_CEO_SHADOW_DIR", pathlib.Path.home() / ".chump/ceo-shadow")
)
MODEL = os.environ.get("CHUMP_CEO_MODEL", "sonnet")
MODE = os.environ.get("CHUMP_CEO_MODE", "shadow")
ALLOW_PAGE = os.environ.get("CHUMP_CEO_ALLOW_PAGE", "0") == "1"
def load_chump_env():
    """Fill os.environ blanks from ~/.chump/env. Only fills keys NOT present
    in the environment — an explicitly-empty env var stays empty (CI hermetic)."""
    try:
        for line in (pathlib.Path.home() / ".chump/env").read_text().splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                if k.strip() and v.strip() and k.strip() not in os.environ:
                    os.environ[k.strip()] = v.strip()
    except Exception:  # noqa: BLE001
        pass


load_chump_env()

DISCORD_API = "https://discord.com/api/v10"
DISCORD_TOKEN = os.environ.get("DISCORD_TOKEN", "").strip()
CTO_USER_ID = os.environ.get("CHUMP_READY_DM_USER_ID", "").strip()


def _discord_req(method, path, body=None):
    import urllib.request
    req = urllib.request.Request(
        DISCORD_API + path, method=method,
        headers={"Authorization": f"Bot {DISCORD_TOKEN}",
                 "Content-Type": "application/json",
                 "User-Agent": "chump-ceo-loop/1.4"},
        data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode() or "{}")


def dm_channel_id():
    cache = SHADOW_DIR / "discord-dm-channel"
    if cache.exists():
        return cache.read_text().strip()
    cid = str(_discord_req("POST", "/users/@me/channels",
                           {"recipient_id": CTO_USER_ID})["id"])
    cache.write_text(cid)
    return cid


def _autopost_dm_enabled():
    """Operator kill-switch for automated operator DMs (Jeff, 2026-09-13:
    'kill everything automated'). Default OFF; set CHUMP_OPERATOR_AUTOPOST_DM
    to 1/true/on/yes to restore briefing DMs. Plain descriptive name (not a
    *_BYPASS/_SKIP var) so it doesn't count against the bypass-var ceiling."""
    return os.environ.get("CHUMP_OPERATOR_AUTOPOST_DM", "").strip().lower() in (
        "1", "true", "on", "yes",
    )


def discord_send(text):
    """DM the CTO. Never raises; returns a status string for the record."""
    if not (DISCORD_TOKEN and CTO_USER_ID):
        return "disabled"
    # The CEO briefing is a scheduled autopost, not a reply to a message Jeff
    # sent — suppressed unless the operator re-enables automated DMs. The
    # briefing still computes and records; only the outbound DM is withheld.
    if not _autopost_dm_enabled():
        return "suppressed-autoposts-off"
    try:
        _discord_req("POST", f"/channels/{dm_channel_id()}/messages",
                     {"content": text[:1900]})
        return "sent"
    except Exception as e:  # noqa: BLE001
        return f"send-failed:{type(e).__name__}"


def discord_inbound(limit=10):
    """CTO-authored DMs since the cursor. First run primes the cursor without
    ingesting history. Never raises."""
    if not (DISCORD_TOKEN and CTO_USER_ID):
        return []
    cur = SHADOW_DIR / "discord-cursor"
    try:
        cid = dm_channel_id()
        if not cur.exists():
            msgs = _discord_req("GET", f"/channels/{cid}/messages?limit=1")
            cur.write_text(str(msgs[0]["id"]) if msgs else "0")
            return []
        after = cur.read_text().strip()
        q = f"/channels/{cid}/messages?limit={limit}" + (f"&after={after}" if after and after != "0" else "")
        msgs = sorted(_discord_req("GET", q), key=lambda m: int(m["id"]))
    except Exception:  # noqa: BLE001
        return []
    out = [f"[{m.get('timestamp','?')[:16]}] {m.get('content','')[:500]}"
           for m in msgs if str((m.get("author") or {}).get("id")) == CTO_USER_ID]
    if msgs:
        cur.write_text(str(msgs[-1]["id"]))
    return out


ALMANAC_BIN = os.environ.get(
    "CHUMP_CEO_ALMANAC_BIN",
    str(pathlib.Path.home() / "Projects/almanac/target/release/almanac"),
)
ALMANAC_CALL = re.compile(
    r'^(almanac_search_fleet|almanac_search)\(\s*(?:repo="([^"]+)"\s*,\s*)?query="([^"]+)"\s*\)$'
)


def almanac_argv(cmd):
    """Translate the model's almanac pseudo-call into CLI argv, or None."""
    m = ALMANAC_CALL.match(cmd.strip())
    if not m:
        return None
    fn, repo, query = m.groups()
    if fn == "almanac_search_fleet":
        return [ALMANAC_BIN, "search-fleet", query]
    if repo:
        return [ALMANAC_BIN, "search", repo, query]
    return None

TARGETS = {"ALMANAC", "GAP_REGISTRY", "DISPATCH", "CONSENSUS", "CONSULTANT", "OPERATOR"}
ACTIONS = {"query", "file_gap", "rate_gap", "decompose", "dispatch", "unstick",
           "propose", "vote", "request_inference", "board_update", "page"}
ALLOW_PREFIXES = [
    "chump gap reserve", "chump gap set", "chump gap rate", "chump gap decompose",
    "chump gap show", "chump gap list", "chump gap preflight",
    "chump dispatch", "chump vote", "chump consensus", "chump outcome",
    "chump health",
    "scripts/coord/broadcast.sh", "scripts/coord/chump-inbox.sh",
    "scripts/dev/reality-check.sh", "scripts/coord/auth-status.sh",
    "scripts/dispatch/fleet-brief.sh",
    "git log", "git status", "git fetch", "tail",
    "almanac",
]
HARD_DENY = [
    (r"\brm\s", "rm"), (r"sed\s+-i", "sed -i"), (r"git\s+commit", "git commit"),
    (r"git\s+push", "git push"), (r"gh\s+pr\s+merge", "gh pr merge"),
    (r"gh\s+pr\s+create", "gh pr create"), (r"chump\s+fleet\s+stop", "fleet stop"),
    (r"chump\s+claim", "chump claim"), (r"launchctl", "launchctl"),
    (r"chmod", "chmod"), (r">>", "append-redirect"), (r"\s>\s", "redirect"),
    (r"--status\s+done", "status-done"), (r"\bcurl\b", "curl"), (r"\bwget\b", "wget"),
    (r"\btee\s", "tee"),
]
METACHAR = re.compile(r"[;`|&<>]|\$\(")
GAP_RE = re.compile(r"\b[A-Z]{2,}-\d{2,}\b")

# (cap_group, per-tick limit). Groups not listed are uncapped.
CAPS = {"dispatch": 2, "file_gap": 1, "mutate": 3, "broadcast": 2, "almanac": 3}


def cap_group(action, cmd):
    if cmd.startswith("almanac"):
        return "almanac"
    if action == "dispatch" or cmd.startswith("chump dispatch"):
        return "dispatch"
    if action == "file_gap" or cmd.startswith("chump gap reserve"):
        return "file_gap"
    if cmd.startswith(("chump gap set", "chump gap rate", "chump gap decompose")):
        return "mutate"
    if cmd.startswith(("scripts/coord/broadcast.sh", "bash scripts/coord/broadcast.sh")):
        return "broadcast"
    return "query"


def sh(cmd, timeout=20, cwd=None):
    """Run a read-only state-assembly command; never raise."""
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout, cwd=str(cwd or REPO))
        out = (p.stdout or "").strip()
        return out if out else f"(empty, exit={p.returncode})"
    except Exception as e:  # noqa: BLE001 — any failure becomes visible state
        return f"(unavailable: {type(e).__name__})"


def recent_decisions(n=5):
    """Compact summaries of the last n decision records, with execution results."""
    path = SHADOW_DIR / "decisions.jsonl"
    if not path.exists():
        return "(no prior decisions on record)"
    lines = path.read_text().strip().split("\n")[-n:]
    out = []
    for line in lines:
        try:
            r = json.loads(line)
        except Exception:  # noqa: BLE001
            continue
        d = r.get("decision")
        if not isinstance(d, dict):
            out.append(f"- {r.get('ts','?')} [{r.get('mode','?')}] (invalid or model error)")
            continue
        sv = (d.get("executive_cognition") or {}).get("strategic_vector") or {}
        routed = []
        exec_by_idx = {e.get("i"): e for e in (r.get("execution") or [])}
        for i, x in enumerate(d.get("system_routing", [])):
            if not isinstance(x, dict):
                continue
            cmd = str((x.get("payload") or {}).get("cmd", ""))[:70]
            ex = exec_by_idx.get(i)
            if ex is None:
                status = "not-executed(shadow)"
            elif ex.get("ran"):
                status = f"ran(exit={ex.get('exit')})"
            else:
                status = f"skipped({ex.get('reason','?')})"
            routed.append(f"{x.get('target')}/{x.get('action')} `{cmd}` -> {status}")
        out.append(f"- {r.get('ts','?')} [{r.get('mode','?')}] vector={sv.get('outcome','?')}; "
                   + ("; ".join(routed) if routed else "(no routing)"))
    return "\n".join(out) if out else "(no prior decisions on record)"


def factory_knowledge():
    """The org chart: job-registry table from the canonical org model doc,
    curator roster, fleet map. The prompt's KNOWLEDGE section (v3) points here."""
    lines = []
    doc = REPO / "docs/strategy/FACTORY_ORG_MODEL_2026-08-08.md"
    try:
        text = doc.read_text()
        m = text.split("## The registry", 1)[1].split("\n## ", 1)[0]
        lines = [ln for ln in m.split("\n") if ln.startswith("|")][:16]
    except Exception:  # noqa: BLE001 — knowledge degrades, tick survives
        lines = ["(org model registry unavailable — judge capabilities via almanac only)"]
    roster = ("Curator roster: harvester(prior art), scout(external first-read), "
              "fresh-eyes(reality audit), roadmap-keeper, velocity-tracker, ci-audit, "
              "shepherd(PR rescue), decompose, md-links, observability, infra-watcher, "
              "quartermaster.")
    fleet = "Fleet map: ~95 repos indexed; almanac_search_fleet spans all, file:line receipts."
    return "\n".join(lines + [roster, fleet])


def assemble_state():
    sections = {
        "Ships (git log origin/main --since=3h)":
            "git log origin/main --since=3h --oneline | head -15",
        "Ambient tail (last 40 kinds, counted)":
            "tail -40 .chump-locks/ambient.jsonl | "
            "python3 -c 'import sys,json,collections\n"
            "c=collections.Counter()\n"
            "for l in sys.stdin:\n"
            " try: c[json.loads(l).get(\"kind\",\"?\")]+=1\n"
            " except Exception: pass\n"
            "print(\", \".join(f\"{k} x{v}\" for k,v in c.most_common(15)))'",
        "Open P0/P1 gaps":
            "sqlite3 -readonly .chump/state.db \"SELECT priority || ' ' || id || ' — ' || substr(title,1,90) "
            "FROM gaps WHERE status='open' AND priority IN ('P0','P1') "
            "ORDER BY priority, id LIMIT 15\"",
        "Outcomes": "chump outcome list 2>/dev/null | head -20",
        "Auth": "bash scripts/coord/auth-status.sh 2>&1 | head -2",
        "Inbox (unread, not advanced)":
            "bash scripts/coord/chump-inbox.sh read --no-advance 2>/dev/null | head -20",
    }
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = {name: ex.submit(sh, cmd) for name, cmd in sections.items()}
        parts = [f"## {name}\n{futs[name].result()}" for name in sections]
    cto = discord_inbound()
    parts.append("## Messages from the CTO (Discord DMs since last tick — he reads "
                 "your tick-report DM; answer him there via your synthesis/board_update)\n"
                 + ("\n".join(cto) if cto else "(none)"))
    parts.append("## Factory Knowledge (org model registry, curator roster — injected by driver)\n"
                 + factory_knowledge())
    parts.append(
        "## Your recent decisions (your own log — follow up on these; do NOT "
        "re-route an action already shown as ran; a skipped(...) action was "
        "refused by the driver, rethink it rather than repeating it)\n"
        + recent_decisions()
    )
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    return (f"# LOOP STATE — {ts} (assembled by ceo-loop v1.1, mode={MODE})\n\n"
            + "\n\n".join(parts))


def call_model(full_prompt):
    env = dict(os.environ)
    if not env.get("CLAUDE_CODE_OAUTH_TOKEN"):
        tok_file = pathlib.Path.home() / ".chump/oauth-token.json"
        try:
            env["CLAUDE_CODE_OAUTH_TOKEN"] = json.loads(tok_file.read_text())["token"]
        except Exception:  # noqa: BLE001 — fall through to claude's own auth
            pass
    try:
        p = subprocess.run(["claude", "-p", "--model", MODEL], input=full_prompt,
                           capture_output=True, text=True, timeout=420,
                           cwd=str(SHADOW_DIR), env=env)
        if p.returncode != 0:
            return None, f"claude exited {p.returncode}: {(p.stderr or p.stdout)[:400]}"
        return p.stdout.strip(), None
    except subprocess.TimeoutExpired:
        return None, "claude timed out (420s)"


def extract_json(text):
    try:
        return json.loads(text)
    except Exception:  # noqa: BLE001
        pass
    m = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", text, re.S)
    if m:
        try:
            return json.loads(m.group(1))
        except Exception:  # noqa: BLE001
            pass
    i, j = text.find("{"), text.rfind("}")
    if i >= 0 and j > i:
        try:
            return json.loads(text[i:j + 1])
        except Exception:  # noqa: BLE001
            pass
    return None


def known_gap_ids():
    try:
        return {p.stem for p in (REPO / "docs/gaps").glob("*.yaml")}
    except Exception:  # noqa: BLE001
        return set()


def validate(obj, state_text):
    checks = {"M1_parses": obj is not None}
    if obj is None:
        return checks
    ec = obj.get("executive_cognition", {}) or {}
    fr = ec.get("factory_report", {}) or {}
    sv = ec.get("strategic_vector", {}) or {}
    routing = obj.get("system_routing", [])
    checks["M2_schema"] = (
        obj.get("schema_version") == 1
        and all(k in fr for k in ("outcome_moved", "spine_stage", "honesty", "did_not_move"))
        and "synthesis" in ec and all(k in sv for k in ("outcome", "why_now"))
        and isinstance(routing, list) and len(routing) > 0
        and all(isinstance(r, dict) and "target" in r and "action" in r and "verify" in r
                for r in routing)
    )
    if not checks["M2_schema"]:
        return checks
    checks["M3_enums"] = all(
        r.get("target") in TARGETS and r.get("action") in ACTIONS for r in routing
    )
    pages = [r for r in routing if r.get("target") == "OPERATOR" and r.get("action") == "page"]
    checks["M4_page_gated"] = all(
        re.match(r"^T[1-4]", str(r.get("escalation_trigger", ""))) for r in pages
    )
    checks["page_count"] = len(pages)
    denies, unlisted = [], []
    for r in routing:
        cmd = str((r.get("payload") or {}).get("cmd", "")).strip()
        if not cmd or r.get("action") == "board_update":
            continue
        for pat, name in HARD_DENY:
            if re.search(pat, cmd):
                denies.append(f"{name}: {cmd[:90]}")
        bare = re.sub(r"^bash\s+", "", cmd)
        if not any(bare.startswith(p) for p in ALLOW_PREFIXES):
            unlisted.append(cmd[:90])
    checks["M5_denies"] = denies
    checks["M6_unlisted"] = unlisted
    cited = set(GAP_RE.findall(json.dumps(obj)))
    ok_ids = known_gap_ids() | set(GAP_RE.findall(state_text)) | set(GAP_RE.findall(PROMPT_PATH.read_text()))
    checks["M7_unknown_ids"] = sorted(cited - ok_ids)
    checks["valid"] = bool(
        checks["M1_parses"] and checks["M2_schema"] and checks["M3_enums"]
        and checks["M4_page_gated"] and not denies
    )
    return checks


def build_plan(obj, checks, allow_page=None):
    """Deterministic execution plan for a validated decision. Pure — no side effects."""
    if allow_page is None:
        allow_page = ALLOW_PAGE
    plan = []
    counts = {k: 0 for k in CAPS}
    routing = obj.get("system_routing", []) if isinstance(obj, dict) else []
    for i, r in enumerate(routing):
        if not isinstance(r, dict):
            continue
        entry = {"i": i, "target": r.get("target"), "action": r.get("action")}
        cmd = str((r.get("payload") or {}).get("cmd", "")).strip()
        entry["cmd"] = cmd[:200]
        action = r.get("action")
        if not checks.get("valid"):
            entry.update(run=False, reason="decision-invalid")
        elif action == "page":
            if allow_page:
                entry.update(run=True, reason="page-allowed-by-env", group="page")
            else:
                entry.update(run=False, reason="page-gated (CHUMP_CEO_ALLOW_PAGE=0)")
        elif action == "board_update":
            entry.update(run=True, reason="board-log", group="board")
        elif not cmd:
            entry.update(run=False, reason="no-cmd")
        elif cmd.startswith("almanac"):
            if almanac_argv(cmd) is None:
                entry.update(run=False, reason="almanac-parse")
            elif counts["almanac"] >= CAPS["almanac"]:
                entry.update(run=False, reason=f"cap-exhausted(almanac<={CAPS['almanac']})")
            else:
                counts["almanac"] += 1
                entry.update(run=True, reason="ok", group="almanac")
        elif any(re.search(p, cmd) for p, _ in HARD_DENY):
            entry.update(run=False, reason="hard-deny")
        elif METACHAR.search(cmd):
            entry.update(run=False, reason="shell-metachar")
        elif not any(re.sub(r"^bash\s+", "", cmd).startswith(p) for p in ALLOW_PREFIXES):
            entry.update(run=False, reason="not-in-palette")
        else:
            g = cap_group(action, re.sub(r"^bash\s+", "", cmd))
            if g in CAPS:
                if counts[g] >= CAPS[g]:
                    entry.update(run=False, reason=f"cap-exhausted({g}<={CAPS[g]})")
                else:
                    counts[g] += 1
                    entry.update(run=True, reason="ok", group=g)
            else:
                entry.update(run=True, reason="ok", group=g)
        plan.append(entry)
    return plan


def execute_plan(obj, plan):
    """Run the entries build_plan approved. Returns plan with results attached."""
    routing = obj.get("system_routing", [])
    for entry in plan:
        if not entry.get("run"):
            entry["ran"] = False
            continue
        r = routing[entry["i"]]
        if entry["action"] == "board_update":
            detail = str((r.get("payload") or {}).get("detail", ""))[:2000]
            with open(SHADOW_DIR / "board.log", "a") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {detail}\n")
            entry.update(ran=True, exit=0)
            continue
        cmd = str((r.get("payload") or {}).get("cmd", "")).strip()
        if entry.get("group") == "almanac":
            argv = almanac_argv(cmd)
        else:
            argv = shlex.split(re.sub(r"^bash\s+", "bash ", cmd))
        try:
            p = subprocess.run(argv, capture_output=True, text=True, timeout=120,
                               cwd=str(REPO))
            entry.update(ran=True, exit=p.returncode,
                         out=(p.stdout or p.stderr or "")[-400:])
        except Exception as e:  # noqa: BLE001 — record, never crash the tick
            entry.update(ran=False, reason=f"exec-error:{type(e).__name__}")
    return plan


def main():
    ap = argparse.ArgumentParser(description="CEO loop v1.1 — one tick")
    ap.add_argument("--fixture", help="use a state-fixture file instead of live state")
    ap.add_argument("--state-only", action="store_true", help="print assembled state, no model call")
    ap.add_argument("--validate-only", help="validate a decision-JSON file, no model call (CI path)")
    ap.add_argument("--dm", help="send a one-off DM to the CTO and print the status")
    ap.add_argument("--plan-only", help="print the deterministic live-execution plan for a decision-JSON file (CI path)")
    args = ap.parse_args()

    SHADOW_DIR.mkdir(parents=True, exist_ok=True)

    if args.dm:
        print(discord_send(args.dm))
        return 0

    if args.validate_only:
        obj = extract_json(pathlib.Path(args.validate_only).read_text())
        checks = validate(obj, "")
        print(json.dumps(checks, indent=2))
        return 0 if checks.get("valid") else 2

    if args.plan_only:
        obj = extract_json(pathlib.Path(args.plan_only).read_text())
        checks = validate(obj, "")
        plan = build_plan(obj, checks)
        print(json.dumps(plan, indent=2))
        return 0

    state = pathlib.Path(args.fixture).read_text() if args.fixture else assemble_state()
    if args.state_only:
        print(state)
        return 0

    full = (PROMPT_PATH.read_text() + "\n\n---\n\n" + state +
            "\n\n---\nThis is one tick of your loop. Respond with ONLY the JSON object "
            "per your OUTPUT CONTRACT — no prose before or after.")
    out, err = call_model(full)
    record = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "mode": MODE,
        "model": MODEL,
        "fixture": args.fixture or None,
        "prompt_sha256_file": str(PROMPT_PATH),
    }
    if out is None:
        record.update({"error": err, "valid": False})
        code = 3
    else:
        obj = extract_json(out)
        checks = validate(obj, state)
        record.update({"decision": obj if obj else out[:2000], "checks": checks,
                       "valid": bool(checks.get("valid"))})
        if MODE == "live" and obj is not None:
            record["execution"] = execute_plan(obj, build_plan(obj, checks))
        code = 0 if checks.get("valid") else 2
    d = record.get("decision") if isinstance(record.get("decision"), dict) else {}
    sv = (d.get("executive_cognition") or {}).get("strategic_vector", {}) if d else {}
    ex = record.get("execution") or []
    acts = "; ".join(f"{e['target']}/{e['action']}" + (f" exit={e.get('exit')}" if e.get("ran") else f" ({e.get('reason','skip')})")
                     for e in ex[:5])
    report = (f"CEO tick {record['ts']} [{record.get('mode')}] valid={record.get('valid')}\n"
              f"Vector: {sv.get('outcome','?')} — {str(sv.get('why_now',''))[:150]}\n"
              f"Actions: {acts or '(none)'}\n"
              f"(Reply here — I read your DMs every tick.)")
    record["discord_dm"] = discord_send(report)
    with open(SHADOW_DIR / "decisions.jsonl", "a") as f:
        f.write(json.dumps(record) + "\n")
    summary = {k: record.get(k) for k in ("ts", "mode", "valid", "error") if k in record}
    if "checks" in record:
        summary["pages"] = record["checks"].get("page_count")
        summary["denies"] = record["checks"].get("M5_denies")
    if "execution" in record:
        summary["executed"] = sum(1 for e in record["execution"] if e.get("ran"))
        summary["skipped"] = sum(1 for e in record["execution"] if not e.get("ran"))
    print(json.dumps(summary))
    return code


if __name__ == "__main__":
    sys.exit(main())
