# Store-over-API (`RESILIENT-1700` / `RESILIENT-1691` slice)

Phase-2 organs (`backlog-governor.sh`, `next-best-action.sh`, and remote node organs) can query canonical SQLite `gaps` rows over HTTP from `chump-fleet-server` instead of opening a local `state.db` file directly.

## Endpoints (`crates/chump-fleet-server`)

### `GET /api/store/gaps`

Queries the canonical `gaps` table in `state.db` (`CHUMP_STATE_DB` or `<repo_root>/.chump/state.db`) and returns a JSON array of canonical gap objects.

**Query Parameters:**

| Parameter | Values | Default | Description |
|---|---|---|---|
| `status` | `open`, `in_progress`, `done`, `shipped`, `all`, or comma-separated list | *(all rows)* | Filter by gap `status`. |
| `priority` | `P0`..`P4`, `critical`/`high`/`medium`/`low`, `all`, or comma-separated list | *(all rows)* | Filter by gap `priority`. |
| `domain` | Domain string (e.g. `RESILIENT`, `INFRA`), `all`, or comma-separated list | *(all rows)* | Filter by gap `domain`. |
| `limit` | Positive integer | *(unlimited)* | Maximum number of rows returned. |
| `order` | `id` or `priority` | `id` | `order=id` sorts deterministically by `ORDER BY id ASC` (byte-identical to `sqlite3 -json state.db "SELECT ... FROM gaps ORDER BY id ASC"`). `order=priority` sorts by `priority_rank` (`P0 < P1 < P2 < P3`) then `id ASC`. |

**Response Schema (15 canonical SQLite fields in fixed column order):**

```json
[
  {
    "id": "RESILIENT-1700",
    "title": "Implement store-over-API backend",
    "description": "...",
    "domain": "RESILIENT",
    "priority": "P1",
    "status": "open",
    "effort": "m",
    "skills_required": "rust,sqlite",
    "acceptance_criteria": "[\"...\"]",
    "depends_on": "[\"RESILIENT-1691\"]",
    "parent_id": "RESILIENT-1691",
    "notes": "",
    "closed_pr": null,
    "closed_date": "",
    "created_at": 1778700000
  }
]
```

### `GET /api/store/gaps/:id` (`GET /api/store/gaps/{id}`)

Returns the single canonical gap JSON object for `:id` (`200 OK`), or `404 Not Found` (`{"error": "gap \"...\" not found"}`) when no matching row exists.

## Client Library & Phase-2 Organ Configuration

Set `CHUMP_STORE_API_URL` (for example in `~/.chump/node.env`) to point Phase-2 organs at the fleet-server endpoint:

```ini
CHUMP_STORE_API_URL=http://127.0.0.1:7070
```

Shell organs source `scripts/lib/store-api-client.sh` and call:

```bash
source "$REPO_ROOT/scripts/lib/store-api-client.sh"

# Fetches ${CHUMP_STORE_API_URL}/api/store/gaps?order=id via curl -fsSL when
# CHUMP_STORE_API_URL is set, or falls back to local sqlite3 -json "$CHUMP_STATE_DB".
chump_store_query_gaps --order id
chump_store_query_gaps --status open --priority P0,P1 --order priority

# Single gap lookup by ID:
chump_store_get_gap "RESILIENT-1700"
```
