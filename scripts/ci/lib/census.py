#!/usr/bin/env python3
"""scripts/ci/lib/census.py — CREDIBLE-1514 helper for scripts/ci/census.sh.

Subcommands:
  classify      enumerate scripts/ci/test-*.sh, mark wired/unwired, pick the
                run selection (--sample / --only / --filter)
  report        merge run results (+ previous json) into CI_TEST_CENSUS.md
                and ci-test-census.json
  check-shrink  shrink-only gate: fail when a test is unwired that was not
                unwired on the base, or the committed red/unwired count grew

Stdlib only. Writes only to the paths it is given.
"""
import argparse
import datetime as dt
import fnmatch
import glob
import json
import os
import platform
import re
import sys

SCHEMA = "chump-ci-test-census/v1"
TOKEN = re.compile(r"(?<![A-Za-z0-9_.-])(test-[A-Za-z0-9_.-]+\.sh)\b")
RED = ("fail", "timeout")


def wiring_sources(root):
    srcs = sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml")))
    srcs += sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yaml")))
    pf = os.path.join(root, "crates", "chump-preflight", "src", "preflight.rs")
    if os.path.isfile(pf):
        srcs.append(pf)
    return srcs


def wired_map(root):
    """basename -> sorted list of files (repo-relative) that reference it."""
    refs = {}
    for path in wiring_sources(root):
        comment = "//" if path.endswith(".rs") else "#"
        rel = os.path.relpath(path, root)
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.lstrip().startswith(comment):
                    continue
                for m in TOKEN.finditer(line):
                    refs.setdefault(m.group(1), set()).add(rel)
    return {k: sorted(v) for k, v in refs.items()}


def classify_tests(root):
    refs = wired_map(root)
    tests = []
    for p in sorted(glob.glob(os.path.join(root, "scripts", "ci", "test-*.sh"))):
        name = os.path.basename(p)
        by = refs.get(name, [])
        tests.append({"name": name, "path": os.path.relpath(p, root),
                      "wired": bool(by), "wired_by": by})
    return tests


def cmd_classify(a):
    tests = classify_tests(a.root)
    sel = tests
    if a.filter == "wired":
        sel = [t for t in sel if t["wired"]]
    elif a.filter == "unwired":
        sel = [t for t in sel if not t["wired"]]
    if a.only:
        sel = [t for t in sel if fnmatch.fnmatch(t["name"], a.only)]
    if a.sample:
        n = max(0, int(a.sample))
        if n < len(sel):
            # Deterministic, evenly spread pick: same tree -> same sample.
            step = len(sel) / float(n) if n else 0
            sel = [sel[int(i * step)] for i in range(n)]
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(tests, fh)
    with open(a.select_out, "w", encoding="utf-8") as fh:
        for t in sel:
            fh.write(os.path.join(a.root, t["path"]) + "\n")
    return 0


def load_json(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def is_red_test(t):
    """CREDIBLE-1528: fail, timeout, OR a SKIP that exited 0 counts as red."""
    st = t.get("status", "not_run")
    if st in RED:
        return True
    if st == "skip" and t.get("exit", 0) == 0:
        return True
    return False


def counts_of(tests):
    c = {"total": len(tests), "wired": 0, "unwired": 0, "pass": 0, "fail": 0,
         "timeout": 0, "skip": 0, "not_run": 0, "red": 0,
         "wired_green": 0, "wired_red": 0, "unwired_green": 0, "unwired_red": 0}
    for t in tests:
        side = "wired" if t["wired"] else "unwired"
        c[side] += 1
        st = t.get("status", "not_run")
        c[st] = c.get(st, 0) + 1
        if is_red_test(t):
            c["red"] += 1
            c[side + "_red"] += 1
        elif st == "pass":
            c[side + "_green"] += 1
    return c


def cmd_report(a):
    today = dt.datetime.now(dt.timezone.utc)
    with open(a.classified, encoding="utf-8") as fh:
        tests = json.load(fh)
    prev = load_json(a.prev) or {}
    prev_by = {t["name"]: t for t in prev.get("tests", [])}
    known = {}
    if a.known_red:
        with open(a.known_red, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#"):
                    parts = line.split("\t", 1)
                    known[parts[0]] = parts[1] if len(parts) > 1 else "seed"
    results = {}
    for p in glob.glob(os.path.join(a.results, "*.tsv")):
        with open(p, encoding="utf-8", errors="replace") as fh:
            f = fh.read().rstrip("\n").split("\t")
        if len(f) >= 4:
            results[f[0]] = {"status": f[1], "exit": int(f[2]), "duration_s": int(f[3]),
                             "last_line": f[4] if len(f) > 4 else ""}
    run_date = today.strftime("%Y-%m-%d")
    if a.selected and a.mode != "no-run" and os.path.isfile(a.selected):
        with open(a.selected, encoding="utf-8") as fh:
            for line in fh:
                n = os.path.basename(line.strip())
                if n and n not in results:
                    results[n] = {"status": "fail", "exit": None, "duration_s": None,
                                  "last_line": "no result: the runner was killed"}
    for t in tests:
        r = results.get(t["name"])
        if r:
            t.update(r)
            t["run_at"] = run_date
            t["source"] = "run:" + platform.system().lower()
        elif t["name"] in known:
            t.update({"status": "fail", "exit": None, "duration_s": None,
                      "run_at": None, "source": known[t["name"]]})
        elif t["name"] in prev_by and prev_by[t["name"]].get("status", "not_run") != "not_run":
            p = prev_by[t["name"]]
            for k in ("status", "exit", "duration_s", "run_at", "source", "last_line"):
                if k in p:
                    t[k] = p[k]
        else:
            t.update({"status": "not_run", "exit": None, "duration_s": None,
                      "run_at": None, "source": None})
    counts = counts_of(tests)
    doc = {"schema": SCHEMA, "generated_at": today.strftime("%Y-%m-%dT%H:%M:%SZ"),
           "run_date": run_date, "mode": a.mode, "host_os": platform.system().lower(),
           "timeout_s": int(a.timeout), "jobs": int(a.jobs), "ran_this_time": len(results),
           "counts": counts, "tests": tests}
    os.makedirs(a.out_dir, exist_ok=True)
    jpath = os.path.join(a.out_dir, "ci-test-census.json")
    with open(jpath, "w", encoding="utf-8") as fh:
        fh.write(dump_doc(doc))
    mpath = os.path.join(a.out_dir, "CI_TEST_CENSUS.md")
    with open(mpath, "w", encoding="utf-8") as fh:
        fh.write(render_md(doc))
    c = counts
    print(f"census: mode={a.mode} ran={len(results)} total={c['total']} wired={c['wired']} "
          f"unwired={c['unwired']} pass={c['pass']} fail={c['fail']} timeout={c['timeout']} "
          f"skip={c['skip']} not_run={c['not_run']} red={c['red']}")
    print(f"census: wrote {jpath}")
    print(f"census: wrote {mpath}")
    return 0


def dump_doc(doc):
    """Header pretty, one compact line per test: small, diffable, greppable."""
    head = {k: v for k, v in doc.items() if k != "tests"}
    lines = json.dumps(head, indent=1).rstrip("}").rstrip().rstrip("\n")
    rows = []
    for t in doc["tests"]:
        t = {k: v for k, v in t.items() if k != "path" and v not in (None, "", [])}
        rows.append(" " + json.dumps(t, separators=(",", ":")))
    return lines + ',\n "tests": [\n' + ",\n".join(rows) + "\n ]\n}\n"


def render_md(doc):
    c = doc["counts"]
    tests = doc["tests"]
    out = [
        "---",
        "doc_tag: log",
        f"last_audited: {doc['run_date']}",
        "---",
        "",
        "# scripts/ci test census",
        "",
        "Generated by `scripts/ci/census.sh` (CREDIBLE-1514). Do not hand-edit:",
        "the nightly `.github/workflows/ci-test-census.yml` regenerates this file and",
        "`ci-test-census.json` and opens one `census: <date>` PR.",
        "",
        "Rule: a new scripts/ci test is wired or it is deleted. The shrink-only gate",
        "(`scripts/ci/test-census-shrink-only.sh`) fails any PR that adds an unwired",
        "test or grows the red count. See docs/process/CI_GATES_INVENTORY.md.",
        "",
        f"- Run date: {doc['run_date']} (generated {doc['generated_at']})",
        f"- Mode: {doc['mode']} on {doc['host_os']}; tests run this time: {doc['ran_this_time']}",
        f"- Per-test timeout: {doc['timeout_s']}s; jobs: {doc['jobs']}",
        "",
        "| total | wired | unwired | red | pass | fail | timeout | skip | not run |",
        "|---|---|---|---|---|---|---|---|---|",
        f"| {c['total']} | {c['wired']} | {c['unwired']} | {c['red']} | {c['pass']} | "
        f"{c['fail']} | {c['timeout']} | {c['skip']} | {c['not_run']} |",
        "",
        "| | green | red |",
        "|---|---|---|",
        f"| wired | {c['wired_green']} | {c['wired_red']} |",
        f"| unwired | {c['unwired_green']} | {c['unwired_red']} |",
        "",
    ]

    def section(title, rows, why=True):
        out.append(f"## {title} ({len(rows)})")
        out.append("")
        if not rows:
            out.append("(none)")
        for t in rows:
            extra = ""
            if why:
                bits = [t.get("status", "")]
                if t.get("exit") is not None:
                    bits.append(f"exit {t['exit']}")
                if t.get("source"):
                    bits.append(str(t["source"]))
                extra = " (" + ", ".join(b for b in bits if b) + ")"
            out.append(f"- `{t['name']}`{extra}")
        out.append("")

    def pick(wired, red):
        return [t for t in tests if t["wired"] == wired and
                (is_red_test(t) if red else t.get("status") == "pass")]

    section("wired-red", pick(True, True))
    section("unwired-red", pick(False, True))
    section("wired-green", pick(True, False), why=False)
    section("unwired-green", pick(False, False), why=False)
    rest = [t for t in tests if t.get("status") in ("skip", "not_run")]
    out.append(f"## skipped or not run yet ({len(rest)})")
    out.append("")
    out.append("<details><summary>list</summary>")
    out.append("")
    for t in rest:
        out.append(f"- `{t['name']}` ({'wired' if t['wired'] else 'unwired'}, {t.get('status')})")
    out.append("")
    out.append("</details>")
    out.append("")
    return "\n".join(out)


def cmd_check_shrink(a):
    base = load_json(a.base)
    if base is None:
        print(f"census-shrink: no base census at {a.base}; nothing to compare (first run). PASS")
        return 0
    allow = os.environ.get("CHUMP_CENSUS_ALLOW_GROWTH", "0") == "1"
    live = classify_tests(a.root)
    base_unwired = {t["name"] for t in base.get("tests", []) if not t.get("wired")}
    new_unwired = sorted(t["name"] for t in live if not t["wired"] and t["name"] not in base_unwired)
    fails = []
    if new_unwired:
        fails.append("unwired tests not on the base list (wire each into ci.yml + "
                     "crates/chump-preflight/src/preflight.rs, or delete it):\n    "
                     + "\n    ".join(new_unwired))
    head = load_json(a.head)
    bc = base.get("counts", {})
    growth = []
    if head is not None:
        hc = head.get("counts", {})
        for k in ("unwired", "red"):
            if int(hc.get(k, 0)) > int(bc.get(k, 0)):
                growth.append(f"committed census {k} grew: {bc.get(k, 0)} -> {hc.get(k, 0)}")
    live_unwired = sum(1 for t in live if not t["wired"])
    print(f"census-shrink: base unwired={bc.get('unwired')} red={bc.get('red')}; "
          f"live unwired={live_unwired}; new unwired={len(new_unwired)}")
    if growth:
        if allow:
            for g in growth:
                print(f"census-shrink: REPORTED (CHUMP_CENSUS_ALLOW_GROWTH=1): {g}")
        else:
            fails.extend(growth)
    if fails:
        for f in fails:
            print(f"census-shrink: FAIL: {f}")
        print("census-shrink: rule: a new scripts/ci test is wired or it is deleted; "
              "the red and unwired lists only shrink.")
        return 1
    print("census-shrink: PASS")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("classify")
    c.add_argument("--root", required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--select-out", required=True)
    c.add_argument("--sample")
    c.add_argument("--only")
    c.add_argument("--filter", choices=["wired", "unwired"])
    r = sub.add_parser("report")
    r.add_argument("--root", required=True)
    r.add_argument("--classified", required=True)
    r.add_argument("--results", required=True)
    r.add_argument("--mode", required=True)
    r.add_argument("--timeout", required=True)
    r.add_argument("--jobs", required=True)
    r.add_argument("--prev")
    r.add_argument("--out-dir", required=True)
    r.add_argument("--known-red")
    r.add_argument("--selected")
    s = sub.add_parser("check-shrink")
    s.add_argument("--root", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--head", required=True)
    a = ap.parse_args()
    return {"classify": cmd_classify, "report": cmd_report,
            "check-shrink": cmd_check_shrink}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
