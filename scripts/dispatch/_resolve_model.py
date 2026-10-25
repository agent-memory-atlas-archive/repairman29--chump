#!/usr/bin/env python3
"""INFRA-471: resolve per-gap Claude model class from routing.yaml.

Reads gap JSON from stdin (same chump gap list --json format as the picker),
finds the gap matching GAP_ID env var, derives its task_class from the gap ID
prefix, then walks routing.yaml to find the first matching route's model_class.

Usage (worker.sh):
  printf '%s' "$gap_json" | GAP_ID=INFRA-123 REPO_ROOT=... python3 _resolve_model.py

Prints: haiku | sonnet | opus  (or the current FLEET_MODEL if no route matches)

task_class derivation (mirrors crates/chump-orchestrator/src/dispatch.rs):
  COG-*                 → cognition
  EVAL-* / RESEARCH-*   → research
  INFRA-*               → coord
  (all others)          → ""
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path


def task_class_for_gap_id(gap_id: str) -> str:
    upper = gap_id.strip().upper()
    if upper.startswith("COG-"):
        return "cognition"
    if upper.startswith(("EVAL-", "RESEARCH-")):
        return "research"
    if upper.startswith("INFRA-"):
        return "coord"
    return ""


def _parse_inline_yaml_value(raw: str):
    """Parse a simple scalar or list from a YAML inline value string."""
    raw = raw.strip()
    if raw.startswith("[") and raw.endswith("]"):
        # List: [l, xl]
        inner = raw[1:-1]
        return [item.strip() for item in inner.split(",") if item.strip()]
    return raw


def _parse_inline_dict(raw: str) -> dict:
    """Parse a YAML inline dict like { task_class: cognition } or { effort: [l, xl] }."""
    raw = raw.strip().lstrip("{").rstrip("}")
    result: dict = {}
    # Split on ", " but not inside [ ]
    parts: list[str] = []
    depth = 0
    current = ""
    for ch in raw:
        if ch == "[":
            depth += 1
            current += ch
        elif ch == "]":
            depth -= 1
            current += ch
        elif ch == "," and depth == 0:
            parts.append(current)
            current = ""
        else:
            current += ch
    if current.strip():
        parts.append(current)
    for part in parts:
        if ":" not in part:
            continue
        k, _, v = part.partition(":")
        result[k.strip()] = _parse_inline_yaml_value(v)
    return result


def load_routing_yaml(path: str) -> dict:
    """Load routing.yaml. Tries PyYAML first; falls back to hand-rolled parser."""
    try:
        import yaml  # type: ignore
        with open(path) as f:
            return yaml.safe_load(f) or {}
    except ImportError:
        pass
    return _parse_routing_yaml_fallback(path)


def _parse_routing_yaml_fallback(path: str) -> dict:
    """Minimal hand-rolled parser for routing.yaml structure (no PyYAML required)."""
    routes: list[dict] = []
    current: dict | None = None

    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip()
            stripped = line.lstrip()

            if re.match(r"- match:", stripped):
                current = {"match": {}, "model_class": ""}
                routes.append(current)
                m = re.search(r"\{(.+)\}", stripped)
                if m:
                    current["match"] = _parse_inline_dict(m.group(1))
            elif current is not None:
                if re.match(r"model_class:", stripped):
                    current["model_class"] = stripped.split("model_class:", 1)[1].strip()

    return {"routes": routes}


def _is_floor_gap(priority: str, skills_or_tags: str, title: str) -> bool:
    """INFRA-8177: P0/critical or keystone/unwedge gaps must route to >= sonnet."""
    p = (priority or "").strip().upper()
    if p in ("P0", "CRITICAL"):
        return True
    hay = f"{skills_or_tags or ''} {title or ''}".lower()
    for kw in ("keystone", "unwedge"):
        if kw in hay:
            return True
    return False


def _enforce_floor(model_class: str, priority: str, skills_or_tags: str, title: str) -> str:
    if _is_floor_gap(priority, skills_or_tags, title) and model_class in ("haiku", "flash", ""):
        return "sonnet"
    return model_class


def resolve_model(
    gap_id: str,
    effort: str,
    domain: str,
    repo_root: str,
    fallback: str,
    priority: str = "",
    skills_or_tags: str = "",
    title: str = "",
) -> str:
    routing_path = os.path.join(repo_root, "docs", "dispatch", "routing.yaml")
    if not os.path.exists(routing_path):
        return _enforce_floor(fallback, priority, skills_or_tags, title)

    config = load_routing_yaml(routing_path)
    task_class = task_class_for_gap_id(gap_id)
    prio_upper = (priority or "").strip().upper()

    for route in config.get("routes", []):
        match = route.get("match", {})
        model_class = (route.get("model_class") or "").strip()
        if not model_class:
            continue

        # All-match semantics: every key in `match` must match.
        if "task_class" in match:
            if match["task_class"] != task_class:
                continue
        if "effort" in match:
            allowed = match["effort"]
            if isinstance(allowed, str):
                allowed = [allowed]
            if effort not in allowed:
                continue
        if "priority" in match:
            allowed_p = match["priority"]
            if isinstance(allowed_p, str):
                allowed_p = [allowed_p]
            allowed_p_upper = [str(x).strip().upper() for x in allowed_p]
            if not prio_upper or prio_upper not in allowed_p_upper:
                continue

        return _enforce_floor(model_class, priority, skills_or_tags, title)

    return _enforce_floor(fallback, priority, skills_or_tags, title)


def main() -> int:
    gap_id = os.environ.get("GAP_ID", "")
    repo_root = os.environ.get("REPO_ROOT", ".")
    fallback = os.environ.get("FLEET_MODEL", "sonnet")

    # Read gap JSON from stdin to extract effort/domain/priority/tags for the picked gap.
    effort = ""
    domain = ""
    priority = ""
    skills_or_tags = ""
    title = ""
    try:
        raw = sys.stdin.read()
        if raw.strip():
            gaps = json.loads(raw)
            for g in gaps:
                if g.get("id") == gap_id:
                    effort = (g.get("effort") or "").lower()
                    domain = (g.get("domain") or "").lower()
                    priority = (g.get("priority") or "").upper()
                    skills_raw = g.get("skills_required") or g.get("tags") or ""
                    if isinstance(skills_raw, list):
                        skills_or_tags = ",".join(str(x) for x in skills_raw)
                    else:
                        skills_or_tags = str(skills_raw)
                    title = str(g.get("title") or "")
                    break
    except Exception:
        pass

    model = resolve_model(
        gap_id,
        effort,
        domain,
        repo_root,
        fallback,
        priority=priority,
        skills_or_tags=skills_or_tags,
        title=title,
    )
    print(model)
    return 0


if __name__ == "__main__":
    sys.exit(main())
