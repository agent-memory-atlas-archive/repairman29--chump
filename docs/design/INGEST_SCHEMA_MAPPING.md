# Ingest Schema Mapping: Backlog Items → Fleet Gaps (MISSION-055)

This document specifies how fields from a repository's defined backlog (`.beast-mode-tasks.json`, `beads` JSONL, or plain `TODO`) are mapped to fleet gap fields when imported via `chump ingest <repo> --import-backlog`.

## Overview

The ingest pipeline discovers a repository's backlog in priority order:

1. `.beast-mode-tasks.json` — structured JSON array or object with `tasks` key
2. `.beads/issues.jsonl`, `beads.jsonl`, or `.beads.jsonl` — JSONL (one JSON object per line)
3. `TODO.md` or `TODO` — plain-text Markdown/text with task list syntax

When a backlog is found, each item is imported as a **single fleet gap** via `chump gap reserve`, with a stable idempotency marker appended to the title.

## Field Mapping

### Source Item → Fleet Gap

| Backlog Source | Field Priority | Fleet Gap Field | Notes |
|---|---|---|---|
| `.beast-mode-tasks.json` (object) | `title` → `task` → `name` → `description` | `title` (partial) | First non-empty string field; used as gap title base |
| `.beast-mode-tasks.json` (object) | `id` → `task_id` → (fallback: array index) | Idempotency key derivation (see below) | Identifies the item for deduplication |
| `beads` JSONL | `title` → `summary` → `text` | `title` (partial) | Same as beast-mode |
| `beads` JSONL | `id` (string or integer) | Idempotency key derivation | Line number fallback if id absent |
| `TODO.md` / `TODO` | Task text after `- [ ]`, `* [ ]`, `- `, `* `, or `TODO:` prefix | `title` (partial) | Markdown/text checklist syntax |
| `TODO.md` / `TODO` | (none — implicit) | Idempotency key derivation | Line number used as key |

### Derived / Fixed Gap Fields

| Fleet Gap Field | Value | Rationale |
|---|---|---|
| `domain` | User-specified (default: ingest source repo name, or `MISC`) | Reserved gap IDs use domain + counter |
| `title` | `{source_title} [ingest:{repo_tag}:{key}]` | Idempotency marker appended; max 160 chars before marker |
| `priority` | `P2` (fixed) | Imported items are permissionless; no priority inference |
| `effort` | `xs` (fixed) | Imported items are low-friction; effort inference deferred |
| `acceptance_criteria` | (empty, inherited from import logic) | Source items carry no AC; imported gaps are placeholder stubs |
| `tags` / `skills_required` | `external_repo:{repo_tag}` (fixed) | Routes gaps to external-repo picker (MISSION-041) |
| `status` | `open` | All imported gaps start open; no status inference from source |
| `depends_on` | (empty) | No inter-item dependency parsing from source |

## Idempotency Key Derivation

Each imported item is uniquely identified by a **stable idempotency key**, derived from the backlog source and the item's own ID or position.

### Key Format

```
[ingest:{repo_tag}:{item_key}]
```

Where:

- **`repo_tag`** — derived from the target repository's `origin` remote URL (see Repo Tag Derivation below); fallback is the repo's directory basename.
- **`item_key`** — source-specific identifier for the item:
  - `.beast-mode-tasks.json`: `id` field, or `task_id` field, or `idx{N}` (array index, 0-based)
  - `beads` JSONL: `id` field (integer or string), or `line{N}` (line number, 0-based)
  - `TODO.md` / `TODO`: `line{N}` (line number, 0-based)

### Repo Tag Derivation

The repo tag is a **stable `owner/repo` identifier** extracted from the target repo's git remote:

```
origin_url = git -C <repo_path> remote get-url origin
```

Extraction rules:

- **HTTPS URLs** (`https://github.com/owner/repo.git`): extract `owner/repo`
- **SSH URLs** (`git@github.com:owner/repo.git`): extract `owner/repo`
- **Non-GitHub URLs**: fallback to repo directory basename
- **No git remote**: fallback to repo directory basename

Example: `https://github.com/anthropics/something` → `anthropic/something`

### Idempotency Mechanism

1. Before importing, the ingest pipeline queries the fleet's `.chump/state.db` for all gaps with titles matching `[ingest:{repo_tag}:*]`.
2. For each item to be imported:
   - Compute the marker `[ingest:{repo_tag}:{item_key}]`
   - If this marker already exists in any gap's title, **skip** the item (already imported)
   - Otherwise, reserve a new gap with the marker appended to the title
3. Re-running the import on the same repo is idempotent: items with matching markers are skipped, new items are created.

**Collision Risk:** If an item's `id`/`key` changes between ingest runs (e.g., reordering a TODO.md file), the old marker persists as a stale gap, and the item is treated as new. **Mitigation:** Document in your backlog source that item IDs should be stable.

## Field Handling: Missing / Optional Fields

### Title Field (Required)

**Decision:** Title extraction is **mandatory**; if no title field is found, the item is **skipped** (not imported).

**Rationale:** A gap's title is the primary interface for pickers and reporters. An empty title provides no value to the fleet.

**Implementation:**
```
title = item.get("title") OR item.get("task") OR item.get("name") OR item.get("description")
if !title or title.trim().is_empty():
    skip this item
```

### ID Field (Optional with Fallback)

**Decision:** ID field is **optional**; if absent, a fallback **line-based or index-based key** is used.

**Rationale:** Backlogs may not have explicit IDs. A fallback ensures every item gets a stable key, though re-ordering the backlog will break idempotency.

**Implementation:**
```
item_key = item.get("id") OR item.get("task_id") OR (fallback: "idx{array_index}" or "line{line_number}")
```

### Domain Field (Not in Source; User-Supplied)

**Decision:** Domain is **user-specified** at import time via `chump ingest <repo> --import-backlog --domain <domain>`.

**Fallback:** If not specified, the fleet defaults to the repo's tag or a generic `MISC`.

**Rationale:** Backlog items don't declare their domain; the user knows whether the backlog is for a feature, a bug fix, or a documentation project.

### Priority & Effort Fields (Not in Source; Fixed)

**Decision:** Priority and effort are **never inferred** from the backlog source; all imported items default to **P2 / xs**.

**Rationale:** 
- Backlog sources don't carry structured priority/effort data
- Imported items are placeholders; real work is done during decomposition or claim
- Avoiding inference prevents false prioritization and keeps the intake simple

**Future Extension:** A future gap (e.g., MISSION-100) could add a **priority field** to `.beast-mode-tasks.json` and conditionally extract it if present, but this is **out of scope for MISSION-087** and requires a separate gap.

### Acceptance Criteria (Not in Source; Empty)

**Decision:** Acceptance criteria are **not extracted** from the backlog source; imported gaps inherit an **empty or boilerplate AC set**.

**Rationale:** Backlog sources often lack structured AC. Decompose-at-claim (via `chump gap decompose`) is the authoritative AC generator.

### Repo Tag Derivation (Automatic)

**Decision:** Repo tag is **automatically derived** from git `origin` remote and appended to `external_repo:<tag>`.

**Fallback:** If git remote is unavailable, the repo's directory basename is used.

**Rationale:** This ties each imported gap to its source repo for external-repo picker routing (MISSION-041).

## Title Handling: Truncation

**Decision:** Source titles **longer than 160 characters are truncated** before the idempotency marker is appended.

**Formula:**
```
if title.len() > 160:
    title = title[..160]
final_title = "{title} {marker}"
```

**Rationale:** Gap titles are used in logs, displays, and CLI output. Unbounded lengths break formatting and readability. The marker is always appended **after** truncation, so it's always visible.

## Example: Mapping a `.beast-mode-tasks.json` Item

Source file (`.beast-mode-tasks.json`):
```json
[
  {
    "id": "task-001",
    "title": "Implement user authentication system",
    "description": "Add OAuth2 support with GitHub provider"
  },
  {
    "task": "Fix typo in README",
    "task_id": 42
  }
]
```

Import command:
```bash
chump ingest /path/to/repo --import-backlog --domain FEATURE
```

Assuming `origin` remote resolves to `anthropics/example-repo`:

**Item 1:**
- Source title: "Implement user authentication system"
- Item key: `task-001` (from `id` field)
- Repo tag: `anthropics/example-repo`
- Marker: `[ingest:anthropics/example-repo:task-001]`
- Final title: `Implement user authentication system [ingest:anthropics/example-repo:task-001]`
- Fleet gap created with:
  - `title`: "Implement user authentication system [ingest:anthropics/example-repo:task-001]"
  - `domain`: FEATURE
  - `priority`: P2
  - `effort`: xs
  - `tags`: `external_repo:anthropics/example-repo`
  - `status`: open
  - `acceptance_criteria`: (empty or boilerplate)

**Item 2:**
- Source title: "Fix typo in README" (from `task` field)
- Item key: `42` (from `task_id` field)
- Repo tag: `anthropics/example-repo`
- Marker: `[ingest:anthropics/example-repo:42]`
- Final title: `Fix typo in README [ingest:anthropics/example-repo:42]`
- Fleet gap created identically to Item 1, with the different title and key.

## Re-Import Idempotency Example

Running the import again on the same repo:

```bash
chump ingest /path/to/repo --import-backlog --domain FEATURE
```

**Behavior:**
- The ingest pipeline finds the same `.beast-mode-tasks.json` with the same items.
- For each item, it queries `state.db` for gaps matching `[ingest:anthropics/example-repo:*]`.
- Finds existing gaps with markers `[ingest:anthropics/example-repo:task-001]` and `[ingest:anthropics/example-repo:42]`.
- **Skips both items** (already imported); no new gaps created.
- Import report: "items_found=2, gaps_created=0, gaps_skipped_existing=2"

If the backlog is updated (new item added):

```json
[
  {"id": "task-001", "title": "Implement user authentication system"},
  {"task": "Fix typo in README", "task_id": 42},
  {"id": "task-003", "title": "Add dark mode UI"}  // NEW
]
```

Re-running the import:
- Items with keys `task-001` and `42` are skipped.
- New item with key `task-003` is imported.
- Import report: "items_found=3, gaps_created=1, gaps_skipped_existing=2"

## Backlog Source Priority & Discovery

The ingest pipeline discovers sources in a **strict priority order**, stopping at the first match:

1. `.beast-mode-tasks.json` — if found, use it; stop
2. `.beads/issues.jsonl`, `beads.jsonl`, `.beads.jsonl` — if any found, use the first; stop
3. `TODO.md` or `TODO` — if any found, use the first; stop
4. **No source found** — error, exit 1

This priority is **intentional and non-configurable** — a repo should have only one authoritative backlog source. If multiple sources exist, the highest-priority one wins.

## Cost & Observability

Importing a backlog is a **static, read-only operation** (MISSION-055 scope). No LLM calls, no external API calls beyond `git` and local state.db queries.

**Emitted events:**
- `kind=ingest_backlog_started` — before discovery
- `kind=ingest_backlog_discovered` — after source is found (source name, item count)
- `kind=ingest_backlog_gap_reserved` — per gap reserved successfully
- `kind=ingest_backlog_gap_failed` — per gap that failed to reserve
- `kind=ingest_backlog_complete` — after import finishes (total_created, total_skipped)

See `docs/observability/EVENT_REGISTRY.yaml` for full event schemas.

## Future Extensions (Out of Scope)

1. **Priority inference** — future gap to conditionally extract `priority` field from backlog if present (e.g., `"priority": "P1"`).
2. **Effort inference** — future gap to conditionally extract `effort` field (e.g., `"effort": "m"`).
3. **Multi-source merge** — future gap to merge items from multiple sources (not currently supported; priority order wins).
4. **AC extraction** — future gap to structure AC from rich backlog fields (e.g., `acceptance_criteria`, `requirements`).
5. **Dependency inference** — future gap to parse inter-item links from backlog (e.g., `"depends_on": ["task-001"]`).
