# Ingest Schema Mapping: External Backlog Items → Fleet Gaps

**Document:** MISSION-087 slice: ingest schema mapping specification
**Status:** Defined (acceptance criteria documented below)
**Scope:** Mapping `.beast-mode-tasks.json` / beads JSONL / TODO items to fleet gap fields

---

## Overview

When `chump ingest <repo-path> --import-backlog` runs, it discovers a repo's defined backlog
and creates one fleet gap per item via `chump gap reserve`. This document specifies:

1. **Field mapping** — how each backlog item field maps to fleet gap fields
2. **Idempotency key derivation** — stable identity across re-runs
3. **Missing/optional field handling** — defaults and constraints

---

## Field Mapping

### Source Fields (Input)

Backlog items are parsed from one of three sources (priority order):

| Source | Parser | Key field | Title field(s) | Notes |
|---|---|---|---|---|
| `.beast-mode-tasks.json` | `parse_beast_mode_tasks()` | `id` \| `task_id` \| index | `title` \| `task` \| `name` \| `description` | JSON array or wrapped in `{"tasks": […]}` |
| `.beads/issues.jsonl` or `beads.jsonl` or `.beads.jsonl` | `parse_beads()` | `id` | `title` \| `summary` \| `text` | Line-delimited JSON; one item per line |
| `TODO.md` or `TODO` | `parse_todo()` | line index | Checkbox content or list item text | Parsed from markdown/plain-text lists |

**Common parsing rules:**
- **Key derivation:** source-specific; falls back to positional index if absent (e.g., `idx0`, `line0`)
- **Title extraction:** tries multiple field names in priority order; skips empty strings; trims whitespace
- **Title truncation:** max 160 characters (enforced at import time)

### Fleet Gap Fields (Output)

Backlog items map to the following fleet gap fields via `chump gap reserve`:

| Fleet Gap Field | Source | Value | Notes |
|---|---|---|---|
| `domain` | CLI arg | User-provided (default: `INFRA`) | Passed via `--domain` flag; becomes gap ID prefix |
| `title` | Backlog item's title | Parsed from item; max 160 chars; `[ingest:<repo>:<key>]` suffix appended | Idempotency marker embedded in title for re-run dedup |
| `priority` | Hardcoded | `P2` | All imported gaps are permissionless per MISSION-045; can be promoted later |
| `effort` | Hardcoded | `xs` | Smallest estimable unit; finer estimates deferred to claim time |
| `acceptance_criteria` | Hardcoded | *(empty)* | Intentionally blank; AC inferred from the source item's context or set at claim time |
| `description` | Hardcoded | *(empty)* | Intentionally blank; description set later if needed |
| `depends_on` | Hardcoded | *(empty)* | No dependency extraction from backlog; dependencies declared post-import if needed |
| `notes` | Hardcoded | *(empty)* | Audit trail populated later if needed |
| `skills_required` | Hardcoded | *(empty)* | Skill classification deferred to claim/decompose time |
| `status` | Hardcoded | `open` | All imported gaps start open; change via `chump gap set --status` |
| `tags` / `external_repo` | Derived | `external_repo:<owner>/<repo>` | Stable repo tag derived from `git remote get-url origin`; fallback to dir basename |

**Intentional non-mappings (not extracted from backlog):**
- Acceptance criteria — assumed implicit in the source item's context
- Description — should be written post-import with fuller context
- Dependencies — declared separately after intake
- Skills/effort refinement — happens at claim/decomposition
- All other meta fields (preferred_backend, required_model, outcome_id, etc.) — set later

---

## Idempotency Key Derivation

**Stable marker format:** `[ingest:<repo-tag>:<key>]`

### Components

| Component | Derivation | Example |
|---|---|---|
| `<repo-tag>` | `git remote get-url origin` → parse owner/repo; fallback to dir basename | `owner/repo` or `my-dir` |
| `<key>` | Source-specific; usually item ID or line index | `t1`, `b-42`, `line0`, `idx5` |

### Algorithm

1. **Parse repo tag** from `git -C <repo-path> remote get-url origin`:
   - Strip `.git` suffix
   - Extract path after `github.com:` or `github.com/`
   - Use last two path components as `owner/repo`
   - Fallback to directory basename if extraction fails
2. **Construct marker:** `[ingest:<repo-tag>:<key>]`
3. **Append to title:** gap title becomes `<original-title> [ingest:<repo-tag>:<key>]`

### Idempotency Guarantee

Before importing, `run_import()` queries `.chump/state.db` for all gap titles matching
`[ingest:<repo-tag>:` prefix. If the marker is found, the item is **skipped** and counted
in `gaps_skipped_existing`. This ensures:

- Re-running the same import is a no-op for already-imported items
- **Non-idempotent** if: repo is renamed (different repo tag) or item keys change (rare)
- **Future migration:** if repo moves, marker will carry old `<repo-tag>` and re-run will skip
  the old gap, then create a new one with the new tag. Manual cleanup may be needed.

---

## Missing/Optional Field Handling

### Mandatory Fields (Must Parse Successfully)

| Field | If Missing | Behavior |
|---|---|---|
| `title` | No valid title found | **Skipped** — item is filtered out during parsing; no gap created |
| Source backlog file | No recognized backlog exists | **Error** — `run_import()` returns "no defined backlog found" |

### Optional Fields (Sensible Defaults)

| Field | If Missing | Default | Rationale |
|---|---|---|---|
| Item `id` / `key` | No ID field in item | Positional index (`idx<N>`, `line<N>`) | Ensures stable identity even for unkeyed items |
| Backlog source | Multiple sources present | **First match by priority** (beast-mode > beads > TODO) | Prevents merge ambiguity |
| Git remote origin | `.git/config` absent or unset | Directory basename | Fallback works offline or in detached repos |
| Gap field (domain, title, etc.) | See Fleet Gap Fields table | See table "Value" column | Hardcoded defaults per gap reserve rules |

### Non-Extraction (Intentional Blanks)

The following gap fields are **intentionally left empty** and must be populated post-import
if needed:

- `acceptance_criteria` — AC should be written with fuller context post-intake
- `description` — ditto
- `depends_on` — dependencies declared separately after intake
- `notes` — audit trail added later if needed
- `skills_required` — classification deferred to claim/decomposition
- All meta fields (`preferred_backend`, `required_model`, `outcome_id`, etc.)

**Rationale:** The backlog item often lacks this context; importing richer AC/description
from the source risks polluting the fleet with low-confidence assertions. Post-import
enrichment is a separate, manual workflow.

---

## Examples

### Example 1: Beast-Mode Tasks JSON

**Input (.beast-mode-tasks.json):**
```json
[
  {"id": "t1", "title": "Add retry logic to API client"},
  {"id": "t2", "title": "Fix race condition in cache"}
]
```

**Parsed item:**
```
BacklogItem { key: "t1", title: "Add retry logic to API client" }
```

**Derived gap:**
- Repo: `git remote get-url origin` → `myorg/myproject` → `myorg/myproject`
- Marker: `[ingest:myorg/myproject:t1]`
- Gap title: `Add retry logic to API client [ingest:myorg/myproject:t1]`
- Gap domain: `INFRA` (default)
- Gap priority: `P2`
- Gap effort: `xs`

**Fleet gap created:**
```
INFRA-042 | Add retry logic to API client [ingest:myorg/myproject:t1]
         | priority: P2, effort: xs, status: open, external_repo: myorg/myproject
         | acceptance_criteria: (empty) | description: (empty)
```

---

### Example 2: Beads JSONL

**Input (.beads/issues.jsonl):**
```jsonl
{"id": "b-1", "title": "Write integration tests"}
{"id": "b-2", "summary": "Refactor authentication layer"}
```

**Parsed items:**
```
BacklogItem { key: "b-1", title: "Write integration tests" }
BacklogItem { key: "b-2", title: "Refactor authentication layer" }
```

**Derived gaps:**
- Marker 1: `[ingest:anthropic/chump:b-1]` (assuming repo is `anthropic/chump`)
- Marker 2: `[ingest:anthropic/chump:b-2]`

---

### Example 3: TODO.md (No Key Field)

**Input (TODO.md):**
```markdown
# Tasks

- [ ] Document the API
- [ ] Review pull requests
```

**Parsed items:**
```
BacklogItem { key: "line1", title: "Document the API" }
BacklogItem { key: "line2", title: "Review pull requests" }
```

**Markers:** `[ingest:my-repo:line1]`, `[ingest:my-repo:line2]`

---

### Example 4: Re-run (Idempotency)

**Session 1:** Import beast-mode-tasks.json, create INFRA-42, INFRA-43.

**Session 2:** Same import, same repo.
- Query `.chump/state.db`: find gaps with `[ingest:myorg/myproject:t1]` and `[ingest:myorg/myproject:t2]`
- Both markers exist → **skip both, gaps_skipped_existing = 2**
- Report: "items_found: 2, gaps_created: 0, gaps_skipped_existing: 2"

**Session 3:** Add new item to `.beast-mode-tasks.json`:
```json
[
  {"id": "t1", "title": "Add retry logic to API client"},
  {"id": "t2", "title": "Fix race condition in cache"},
  {"id": "t3", "title": "NEW ITEM"}
]
```
- Query finds markers for t1, t2 → skip
- t3 marker not found → create INFRA-44
- Report: "items_found: 3, gaps_created: 1, gaps_skipped_existing: 2"

---

## Constraints & Decisions

### Single Source Per Run

- **Decision:** Only ONE backlog source is imported per run (discovered in priority order)
- **Rationale:** Avoids merge ambiguity; each source has different semantics
- **Implication:** If a repo has both `.beast-mode-tasks.json` AND `TODO.md`, only beast-mode is imported
- **Manual merge:** If merging multiple sources is needed, run separate imports or write a pre-processor

### All Imported Gaps Are P2/xs

- **Decision:** Every imported gap gets `priority: P2` and `effort: xs` regardless of source
- **Rationale:** MISSION-045 (no operator escalation at intake); external backlogs often lack chump's priority semantics
- **Implication:** Promotion to P0/P1/S/M/L happens post-import via `chump gap set --priority`
- **Anti-pattern:** Do NOT create a separate "high-priority import" flow; use the normal workflow

### No AC Extraction from Source

- **Decision:** Imported gaps have blank acceptance_criteria; not inferred from item text
- **Rationale:** Backlog AC is often vague, incomplete, or in different domain language; chump AC should be written fresh
- **Implication:** First claim on an imported gap must write AC
- **Fallback:** If the source item has detailed description/context, post-import enrichment can copy it to `notes`

### Stability Across Repo Renames (Future)

- **Current:** Marker includes repo tag; if repo is renamed (different git remote), re-run will create duplicates
- **Future mitigation (not in scope):** Normalize repo tag derivation (e.g., GitLab ID instead of path)
- **Manual workaround:** Use `chump gap set --closed-pr <PR>` to mark old gaps as done if they were imported before rename

---

## Acceptance Criteria (MISSION-087)

### AC1: Schema Mapping Document

✅ **Complete.** This document specifies:
- Each `.beast-mode-tasks.json` / beads / TODO field and its mapping to fleet gap fields
- Parsing rules and field priority order (title, task, name, description, etc.)
- How gap reserve is called with mapped values

### AC2: Idempotency Key Derivation

✅ **Complete.** Specified:
- Stable marker format: `[ingest:<repo-tag>:<key>]`
- Repo tag derivation from `git remote get-url origin` with fallback to basename
- Query mechanism to detect already-imported items (`existing_markers()`)
- Guarantee: re-run skips items with matching markers

### AC3: Missing/Optional Field Decisions

✅ **Complete.** Documented:
- Mandatory fields: title (filtered if missing), backlog file (error if absent)
- Optional fields with defaults: item ID (falls back to index), git remote (falls back to basename)
- Intentional blanks: acceptance_criteria, description, depends_on, skills_required (left empty; populated post-import)
- Constraints: single source per run, all P2/xs, no AC extraction

---

## Related Gaps & Outcomes

- **MISSION-055** (umbrella): Ingest defined backlogs from external repos
  - **MISSION-087** (this slice): Design ingest schema mapping (done)
  - MISSION-088 (future): Implement backlog import in chump-orchestrate
  - MISSION-089 (future): Add enrichment workflow (post-import AC/description)
  - MISSION-090 (future): Define priority/effort inference rules (if desired)

- **MISSION-045:** No operator escalation at intake — reinforced by P2/xs defaults

- **INFRA-1746:** Ingest orchestration phases (Librarian, Cartographer, Evangelist, Systematizer)

---

## Open Questions (Out of Scope)

1. **AC inference:** Should imported gaps have auto-generated AC stub ("Implement <title>") or remain blank?
   - Current: blank. Future decision if needed.

2. **Effort refinement:** Should effort be inferred from item metadata (e.g., story points, time estimate)?
   - Current: all xs. Future decision if needed.

3. **Tags beyond external_repo:** Should additional tags be extracted (e.g., "epic:foo", "label:bug")?
   - Current: only `external_repo:<tag>`. Future decision if needed.

4. **Recursive backlog discovery:** If target repo contains sub-repos, should import recursively?
   - Current: single repo only. Not planned.

5. **Post-import enrichment UI:** Should there be a guided UI to set AC/description after import?
   - Current: manual via `chump gap set`. Future decision if needed.
