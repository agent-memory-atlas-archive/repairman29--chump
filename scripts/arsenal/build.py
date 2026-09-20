#!/usr/bin/env python3
"""Build GLOBAL_ARSENAL.json — Harvester's fleet catalog.

Reads:
  - docs/arsenal/raw/github_repos.json  (output of `gh repo list --json ...`)
  - ~/Projects/                          (local clones)

Writes:
  - docs/arsenal/GLOBAL_ARSENAL.json     (machine view)
  - docs/arsenal/GLOBAL_ARSENAL.md       (human view)

Reruns are cheap and idempotent — call before any cross-pollination brief.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HOME = Path(os.path.expanduser("~"))
PROJECTS = HOME / "Projects"
# This repo is PUBLIC. The catalog committed under docs/arsenal/ therefore lists PUBLIC repos only
# and carries no local paths (CHUMP_ARSENAL_PUBLIC_ONLY=1). The operator's full catalog, private
# repos included, is built into CHUMP_ARSENAL_DIR, which defaults to a directory outside every
# git tree. `harvest.sh scan` builds both.
PUBLIC_ONLY = os.environ.get("CHUMP_ARSENAL_PUBLIC_ONLY") == "1"
ARSENAL = Path(os.environ.get("CHUMP_ARSENAL_DIR") or (ROOT / "docs" / "arsenal"))
RAW = ARSENAL / "raw" / "github_repos.json"
# Hand curation (cluster patterns, curated primitives per repo) names private repos, so it is
# data, not source: it lives beside the private catalog and is simply absent on a fresh clone.
CURATION = Path(os.environ.get("CHUMP_ARSENAL_CURATION") or (HOME / ".chump" / "arsenal" / "curation.json"))


def _load_curation() -> dict:
    try:
        return json.loads(CURATION.read_text())
    except (OSError, ValueError):
        return {}


_CURATION = _load_curation()

# Cluster heuristics — name/description patterns → cluster label. Operator patterns come from the
# private curation file; the default knows only this repo's own family.
CLUSTERS = [tuple(c) for c in _CURATION.get("clusters", [])] or [
    ("chump-engine", r"^chump$|^chump-|^homebrew-chump$"),
]

# Primitive detection patterns. Operator patterns (which name private repos) come from the private
# curation file; the defaults are generic words only.
PRIMITIVE_PATTERNS = _CURATION.get("primitive_patterns") or {
    "auth":     r"auth|oauth|login|session",
    "payment":  r"payment|stripe|billing|checkout",
    "chat":     r"chat|messaging|message",
    "ci-cd":    r"github.*actions|cargo-dist",
    "calendar": r"calendar|scheduler|cron",
}


# INFRA-1823 AC7: coverage push — extracted_primitives per repo.
#
# The heuristic `detect_primitives()` above is a keyword scan of the
# name/description GitHub metadata; it can't see inside a repo. This table
# is the machine-readable output of the Wave 1-3 deep-scan campaigns
# documented in docs/arsenal/HARVEST_ROADMAP.md — each entry cites a
# specific file/pattern that was verified at source level (per the
# Verify-at-source discipline in HARVESTER.md), not a description guess.
# Populated from the roadmap findings rather than re-scanning: the deep
# reads already happened (74/76 = 97% coverage per Wave 3), this closes the
# loop by making those findings queryable via `chump harvest check` instead
# of living only in prose.
EXTRACTED_PRIMITIVES: dict = _CURATION.get("extracted_primitives", {})


def extracted_primitives_for(name: str) -> list[str]:
    return EXTRACTED_PRIMITIVES.get(name, [])


# INFRA-1864: per-file primitive indexing (per CP-002 finding).
#
# The EXTRACTED_PRIMITIVES table above is manually-curated prose from deep-scan
# campaigns — it can't be kept current as repos change. This scanner is the
# automated complement: it walks each repo's src/ tree (when a local clone is
# available) and regex-matches known primitive signatures from
# primitive_signatures.json, producing per-file/line hits. Results are merged
# into repos_by_name[X].extracted_primitives (as formatted strings, so the
# field stays a list[str] — backward compatible with existing consumers) and
# also kept structured in extracted_primitives_by_file for `harvest check` to
# surface with line refs.
SIGNATURES_PATH = ROOT / "scripts" / "arsenal" / "primitive_signatures.json"

LANG_EXTENSIONS = {
    "rust": [".rs"],
    "typescript": [".ts", ".tsx"],
    "javascript": [".js", ".jsx"],
    "python": [".py"],
}

SCAN_EXCLUDE_DIRS = {"node_modules", "target", "vendor", "dist", "build", "__pycache__"}
MAX_FILE_BYTES = 500_000  # skip generated/vendored blobs that would slow the walk


def _load_signatures() -> dict:
    if not SIGNATURES_PATH.exists():
        return {}
    return json.loads(SIGNATURES_PATH.read_text())


def _compiled_signatures(signatures: dict) -> dict:
    compiled = {}
    for lang, prim_map in signatures.items():
        if lang.startswith("_"):
            continue
        compiled[lang] = {
            primitive: [re.compile(p) for p in patterns]
            for primitive, patterns in prim_map.items()
        }
    return compiled


def scan_repo_primitives(repo_path: Path, signatures: dict | None = None) -> list[dict]:
    """Walk repo_path/src (falling back to repo_path) and return per-file primitive hits.

    Each hit: {"file": "<repo-relative path>", "line": N, "primitive": label, "match": "<snippet>"}.
    One hit per (file, primitive, pattern) — bounds output on files with many matches.
    """
    signatures = signatures if signatures is not None else _load_signatures()
    if not signatures:
        return []
    compiled = _compiled_signatures(signatures)

    ext_to_langs: dict[str, list[str]] = {}
    for lang, exts in LANG_EXTENSIONS.items():
        for ext in exts:
            ext_to_langs.setdefault(ext, []).append(lang)

    src_root = repo_path / "src"
    if not src_root.is_dir():
        src_root = repo_path

    entries: list[dict] = []
    seen: set[tuple[str, int, str]] = set()  # (file, line, primitive) — collapse multi-pattern dupes
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in SCAN_EXCLUDE_DIRS and not d.startswith(".")]
        for fname in filenames:
            langs = ext_to_langs.get(Path(fname).suffix)
            if not langs:
                continue
            fpath = Path(dirpath) / fname
            try:
                if fpath.stat().st_size > MAX_FILE_BYTES:
                    continue
                lines = fpath.read_text(errors="ignore").splitlines()
            except OSError:
                continue
            rel = str(fpath.relative_to(repo_path))
            for lang in langs:
                for primitive, patterns in compiled.get(lang, {}).items():
                    for pat in patterns:
                        for i, line in enumerate(lines, start=1):
                            if pat.search(line):
                                key = (rel, i, primitive)
                                if key not in seen:
                                    seen.add(key)
                                    entries.append({
                                        "file": rel,
                                        "line": i,
                                        "primitive": primitive,
                                        "match": line.strip()[:120],
                                    })
                                break  # first hit per (file, primitive, pattern) is enough
    return entries


def _format_scanned_entry(e: dict) -> str:
    return f"{e['primitive']}: {e['file']}:{e['line']} ({e['match']})"


def assign_cluster(name: str) -> str:
    for label, pat in CLUSTERS:
        if re.search(pat, name, re.IGNORECASE):
            return label
    return "misc"


def detect_primitives(name: str, desc: str) -> list[str]:
    blob = f"{name} {desc or ''}".lower()
    return [p for p, pat in PRIMITIVE_PATTERNS.items() if re.search(pat, blob)]


_LOCAL_CACHE: dict[str, str] | None = None


def _build_local_cache() -> dict[str, str]:
    """Map normalized-remote-repo-name → local path, scanning ~/Projects/ once."""
    global _LOCAL_CACHE
    if _LOCAL_CACHE is not None:
        return _LOCAL_CACHE
    cache: dict[str, str] = {}
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        out = ""
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo_root = str(Path(line).parent)
        cfg = Path(line) / "config"
        if not cfg.exists():
            continue
        m = re.search(r"github\.com[:/]([^/]+)/([^.\s]+?)(?:\.git)?[\s\"]", cfg.read_text(errors="ignore") + "\n")
        if not m:
            continue
        repo_name = m.group(2).lower()
        # Prefer top-level (~/Projects/<X>) clones over nested ones for the canonical local_clone
        if repo_name not in cache or repo_root.count("/") < cache[repo_name].count("/"):
            cache[repo_name] = repo_root
    _LOCAL_CACHE = cache
    return cache


def local_clone_for(name: str) -> dict | None:
    """Look for a local clone of this GH repo, by remote URL (handles case mismatch + dir-renames)."""
    cache = _build_local_cache()
    path = cache.get(name.lower())
    if not path:
        return None
    dir_name = Path(path).name
    return {
        "path": path,
        "dir_name_matches_repo": dir_name.lower() == name.lower(),
        "actual_dir_name": dir_name,
        "nested_in_chump": "/Projects/Chump/" in path,
    }


def _excluded_names() -> set[str]:
    """Repo/folder names the operator keeps out of this PUBLIC catalog. The list lives outside
    the tree (default ~/.chump/arsenal-exclude.txt) because it is itself revealing."""
    f = Path(os.environ.get("CHUMP_ARSENAL_EXCLUDE_FILE", str(Path.home() / ".chump" / "arsenal-exclude.txt")))
    try:
        return {l.strip().lower() for l in f.read_text().splitlines() if l.strip() and not l.strip().startswith("#")}
    except OSError:
        return set()


def scan_all_local_roots(known_paths: set[str]) -> list[dict]:
    """Return every local git root with redacted remote + flags. known_paths suppresses dupes."""
    found = []
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        return found
    excluded = _excluded_names()
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo = str(Path(line).parent)
        if Path(repo).name.lower() in excluded:
            continue  # operator exclude list; see harvest.sh `scan`
        cfg = Path(line) / "config"
        raw_remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                raw_remote = m.group(1)
        has_token = bool(re.search(r"x-access-token:[A-Za-z0-9_]+@", raw_remote))
        remote_clean = re.sub(r"x-access-token:[^@]+@", "x-access-token:<REDACTED>@", raw_remote)
        found.append({
            "path": repo,
            "remote": remote_clean,
            "has_embedded_token": has_token,
            "is_primary_clone": repo in known_paths,
        })
    return found


def find_duplications(repos: list[dict]) -> list[dict]:
    """Find name-similar repos that may be duplicates. The families to look for name private
    repos, so they are data in the private curation file: [{label, regex, recommendation}]."""
    dups = []
    for rule in _CURATION.get("duplication_rules", []):
        try:
            rx = re.compile(rule["regex"], re.IGNORECASE)
        except (KeyError, re.error):
            continue
        variants = [r["name"] for r in repos if rx.search(r["name"])]
        if len(variants) > 1:
            dups.append({"pattern": rule.get("label", rule["regex"]), "variants": variants,
                         "recommendation": rule.get("recommendation", "")})
    return dups


def find_alerts(repos: list[dict], local_roots: list[dict]) -> list[dict]:
    alerts = []
    # Embedded token check
    leak_paths = [l["path"] for l in local_roots if l["has_embedded_token"]]
    if leak_paths:
        alerts.append({
            "severity": "high",
            "kind": "embedded_github_token",
            "paths": leak_paths,
            "action": "rotate the PAT at github.com/settings/tokens, then re-clone with ssh remote",
        })
    # Misplaced Projects/.git
    if (PROJECTS / ".git").is_dir():
        cfg = PROJECTS / ".git" / "config"
        remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                remote = m.group(1)
        alerts.append({
            "severity": "low",
            "kind": "misplaced_clone",
            "path": str(PROJECTS),
            "remote": remote,
            "action": "Projects/ shouldn't itself be a git repo — likely an errant `git clone` at the wrong level. Move .git/ into the intended subdir or rm.",
        })
    # Stale vendored chump clones
    maclawd_chump = PROJECTS / "Maclawd" / "chump-repo"
    if maclawd_chump.exists():
        alerts.append({
            "severity": "medium",
            "kind": "stale_vendored_clone",
            "path": str(maclawd_chump),
            "action": "Maclawd contains a March 2026 clone of chump — Smart Harvest target: convert to git-submodule or Cargo dependency",
        })
    return alerts


def build():
    raw = json.loads(RAW.read_text())
    if PUBLIC_ONLY:
        raw = [r for r in raw if (r.get("visibility") or "").upper() == "PUBLIC"]
    signatures = _load_signatures()
    repos = []
    for r in raw:
        clone = None if PUBLIC_ONLY else local_clone_for(r["name"])
        curated = extracted_primitives_for(r["name"])
        scanned: list[dict] = []
        if clone and signatures:
            try:
                scanned = scan_repo_primitives(Path(clone["path"]), signatures)
            except OSError:
                scanned = []
        scanned_fmt = [_format_scanned_entry(e) for e in scanned]
        merged = curated + [s for s in scanned_fmt if s not in curated]
        repos.append({
            "name": r["name"],
            "visibility": r["visibility"],
            "language": (r.get("primaryLanguage") or {}).get("name"),
            "description": r.get("description") or "",
            "archived": r.get("isArchived", False),
            "fork": r.get("isFork", False),
            "pushed_at": r.get("pushedAt"),
            "url": r.get("url"),
            "disk_kb": r.get("diskUsage"),
            "topics": [t.get("name") for t in (r.get("repositoryTopics") or []) if t],
            "cluster": assign_cluster(r["name"]),
            "primitives": detect_primitives(r["name"], r.get("description") or ""),
            "extracted_primitives": merged,
            "extracted_primitives_by_file": scanned,
            "local_clone": clone,
        })

    known_paths = {r["local_clone"]["path"] for r in repos if r["local_clone"]}
    local_roots = [] if PUBLIC_ONLY else scan_all_local_roots(known_paths)
    unmatched_roots = [l for l in local_roots if not l["is_primary_clone"]]

    out = {
        "metadata": {
            "generated_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generator": "scripts/arsenal/build.py v0",
            "operator": "repairman29",
            "scope": "public repos only" if PUBLIC_ONLY else "operator full catalog",
            "fleet_size_github": len(repos),
            "fleet_size_local_clones": sum(1 for r in repos if r["local_clone"]),
            "fleet_size_unmatched_local_roots": len(unmatched_roots),
        },
        "clusters": {},
        "duplications": find_duplications(repos),
        "alerts": [] if PUBLIC_ONLY else find_alerts(repos, local_roots),
        "primitives_index": {},
        "repos_by_name": {r["name"]: r for r in repos},
        "unmatched_local_roots": unmatched_roots,
    }

    # Cluster summaries
    for r in repos:
        c = r["cluster"]
        out["clusters"].setdefault(c, {"count": 0, "repos": [], "languages": {}, "active_last_30d": 0})
        out["clusters"][c]["count"] += 1
        out["clusters"][c]["repos"].append(r["name"])
        lang = r["language"] or "?"
        out["clusters"][c]["languages"][lang] = out["clusters"][c]["languages"].get(lang, 0) + 1
        if r["pushed_at"] and r["pushed_at"] >= (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=30)).strftime("%Y-%m-%d"):
            out["clusters"][c]["active_last_30d"] += 1

    # Primitives index — repos by primitive label
    for r in repos:
        for p in r["primitives"]:
            out["primitives_index"].setdefault(p, []).append(r["name"])

    (ARSENAL / "GLOBAL_ARSENAL.json").write_text(json.dumps(out, indent=2, sort_keys=False) + "\n")

    # Human view
    md = render_md(out)
    (ARSENAL / "GLOBAL_ARSENAL.md").write_text(md)

    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.json'}")
    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.md'}")
    print(f"fleet_size: {out['metadata']['fleet_size_github']} GH repos, {out['metadata']['fleet_size_local_clones']} cloned locally")
    print(f"clusters: {len(out['clusters'])}, duplications: {len(out['duplications'])}, alerts: {len(out['alerts'])}")

    _emit_arsenal_rebuilt(out)

    high_alerts = [a for a in out["alerts"] if a["severity"] == "high"]
    if high_alerts:
        print(f"harvest scan: {len(high_alerts)} high-severity alert(s) — see GLOBAL_ARSENAL.md § Alerts", file=sys.stderr)
        for a in high_alerts:
            print(f"  - [{a['severity']}] {a['kind']} — {a.get('action', '')}", file=sys.stderr)
        sys.exit(1)


def _emit_arsenal_rebuilt(out: dict) -> None:
    """INFRA-1823 AC5/AC6: emit kind=arsenal_rebuilt so scheduled (launchd)
    and on-demand (`chump harvest scan`) rebuilds are both visible in the
    ambient stream, not just as a file diff nobody watches.

    Best-effort: a write failure here must never fail the catalog rebuild
    itself, so this mirrors the `_emit_ambient` best-effort pattern used by
    scripts/coord/gap-doctor-reconcile.py and scripts/ops/github-webhook-receiver.py.
    """
    ambient_path = Path(
        os.environ.get("CHUMP_AMBIENT_LOG", str(ROOT / ".chump-locks" / "ambient.jsonl"))
    )
    try:
        ambient_path.parent.mkdir(parents=True, exist_ok=True)
        event = {
            "ts": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "kind": "arsenal_rebuilt",
            "repos": out["metadata"]["fleet_size_github"],
            "clusters": len(out["clusters"]),
            "dups": len(out["duplications"]),
            "alerts": len(out["alerts"]),
            "source": "scripts/arsenal/build.py",
        }
        with ambient_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
    except OSError as e:
        print(f"arsenal_rebuilt: ambient emit failed (non-fatal): {e}")


def render_md(out: dict) -> str:
    lines = []
    m = out["metadata"]
    lines.append("# Global Arsenal — Chump Fleet Codex\n")
    lines.append(f"_Generated {m['generated_at']} by {m['generator']}_\n")
    lines.append(f"**Operator:** {m['operator']}")
    lines.append(f"**GitHub repos:** {m['fleet_size_github']}  ")
    lines.append(f"**Cloned locally:** {m['fleet_size_local_clones']}  ")
    lines.append(f"**Unmatched local roots:** {m['fleet_size_unmatched_local_roots']}\n")

    if out["alerts"]:
        lines.append("## 🚨 Alerts\n")
        for a in out["alerts"]:
            lines.append(f"- **[{a['severity']}] {a['kind']}** — {a.get('action','')}")
            if "paths" in a:
                for p in a["paths"]:
                    lines.append(f"  - `{p}`")
            elif "path" in a:
                lines.append(f"  - `{a['path']}`")
        lines.append("")

    lines.append("## Clusters\n")
    lines.append("| Cluster | Count | Active (30d) | Languages |")
    lines.append("|---|---:|---:|---|")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        langs = ", ".join(f"{l}:{n}" for l, n in sorted(info["languages"].items(), key=lambda kv: -kv[1]))
        lines.append(f"| `{c}` | {info['count']} | {info['active_last_30d']} | {langs} |")
    lines.append("")

    lines.append("## Duplication Findings (DRY violations)\n")
    for d in out["duplications"]:
        lines.append(f"### `{d['pattern']}`")
        lines.append(f"**Variants:** {', '.join(d['variants'])}  ")
        lines.append(f"**Recommendation:** {d['recommendation']}\n")

    lines.append("## Primitives Index (Smart-Harvest source candidates)\n")
    for p, names in sorted(out["primitives_index"].items()):
        lines.append(f"- **{p}** → {', '.join(names)}")
    lines.append("")

    lines.append("## Cluster Deep-Dives\n")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        lines.append(f"### {c}")
        for name in info["repos"]:
            r = out["repos_by_name"][name]
            badge = []
            if r["archived"]: badge.append("ARCHIVED")
            if r["fork"]:     badge.append("FORK")
            if r["visibility"] == "PUBLIC": badge.append("PUBLIC")
            badge_str = " · ".join(badge) + " · " if badge else ""
            local = ""
            if r["local_clone"]:
                lc = r["local_clone"]
                rename_tag = "" if lc["dir_name_matches_repo"] else f" (dir renamed → `{lc['actual_dir_name']}`)"
                nested_tag = " [nested-in-Chump]" if lc["nested_in_chump"] else ""
                local = f" 📁 `{lc['path']}`{rename_tag}{nested_tag}"
            lines.append(f"- **{name}** [{r['language'] or '?'}] {badge_str}{r['description']}{local}")
        lines.append("")

    lines.append("## Unmatched Local Git Roots (no GitHub origin / third-party / accidental)\n")
    for l in out["unmatched_local_roots"]:
        tag = " 🚨EMBEDDED_TOKEN" if l["has_embedded_token"] else ""
        lines.append(f"- `{l['path']}` → {l['remote'] or '(no remote)'}{tag}")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    build()
