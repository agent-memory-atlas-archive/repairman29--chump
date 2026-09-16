# SUBAGENT_ATTRIBUTION.md — wiring parent vs sub-agent identity into the fleet event stream

**Filed under:** META-130 (sibling to META-129 scrubber panel collab); doc authored under META-617
**Status:** design proposal — under META team review via `FEEDBACK kind=proposal subject=META-617-subagent-attribution-review` (A2A consensus, see AGENTS.md); vote `chump vote META-617-subagent-attribution-review +1|-1|0 --reason '<why>'`
**Owner:** TBD (orchestrator + recorder + scrubber touch points)

## Problem

When Claude Code's `Agent` tool launches a sub-agent, that sub-agent's hook activity (file_edit, bash_call, session_start, etc.) is reported to `.chump-locks/ambient.jsonl` with the **parent harness's** `session_id`. Three Sonnets dispatched in parallel for INFRA-2174 / INFRA-2175 / INFRA-2176 in this session all attributed their edits to `chump-Chump-1776471708` — the parent orchestrator — instead of three distinct sub-session IDs.

Consequence on the fleet-scrubber:

- The gantt collapses three concurrent workers into **one lane**, defeating the whole "see who's doing what" purpose.
- The segmenter's session-aware activity bucketing produces nonsense (one session can't be `edit`-ing three files in three worktrees simultaneously without confusing the classifier).
- The segment-click detail panel shows mixed work from three distinct agents under one heading.

For a Marcus-grade demo this is the single most visible flaw. It's also the limiting factor on the dispatch-ratio telemetry CREDIBLE-074 wants to surface.

## Non-goals

- Tracking Claude API request fan-out below the harness level (one Agent tool call = one sub-session, even if internally it does N tool calls).
- Renaming `session_id` everywhere — we keep the existing column and add attribution at write time.
- Implementing it for *every* harness in v1 (Claude Code first; opencode / Codex / Aider follow once the contract is stable).

## Three-part design

### Part A — orchestrator emits `kind=subagent_spawned` on dispatch

When an Opus session calls the `Agent` tool, the harness (or a wrapping helper) emits a fresh ambient event:

```json
{
  "ts": "2026-05-30T00:32:14Z",
  "session": "chump-Chump-1776471708",
  "harness": "claude-code",
  "kind": "subagent_spawned",
  "event": "subagent_spawned",
  "payload": {
    "sub_session_id": "chump-sub-Chump-1776-aebd0df531d15e563",
    "parent_session_id": "chump-Chump-1776471708",
    "worktree_path": "/tmp/chump-infra-2174",
    "agent_description": "Sonnet on capture-layer recorder",
    "model": "sonnet"
  }
}
```

Where:

- `sub_session_id` is synthetic: `chump-sub-<parent-suffix>-<agent-id>`. The agent-id is the Agent tool's internal handle (Claude Code surfaces this as `agentId`).
- `worktree_path` is the value passed in the sub-agent's prompt — typically `/tmp/chump-<gap-id>` after the sub-agent runs `chump claim`.
- `parent_session_id` lets the recorder build the hierarchy lookup.

Edge case: when a sub-agent itself calls Agent (sub-spawning-sub), it emits its own `subagent_spawned` with `parent_session_id` = the *immediate* parent's sub-id. The recorder maintains the chain.

### Part B — recorder maintains a worktree-path → sub-session map

In `crates/chump-fleet-recorder/src/main.rs`, the recorder gains a `HashMap<PathBuf, SubSession>`:

```rust
struct SubSession {
    sub_session_id: String,
    parent_session_id: String,
    spawned_at_ms: i64,
    agent_description: Option<String>,
}
```

On every ambient event, before INSERT:

1. If the event's `payload.worktree_path` matches a known sub-session prefix, **rewrite `session_id` to the sub-session id** before binding to sqlite.
2. The original parent_session_id is stored alongside in a new `parent_session_id` column (NULL when there's no parent — i.e. the event came from a top-level session).

Schema addition:

```sql
ALTER TABLE events ADD COLUMN parent_session_id TEXT;
CREATE INDEX idx_events_parent ON events(parent_session_id, ts_ms);
```

The mapping survives recorder restart: rebuild on startup by querying `SELECT * FROM events WHERE event_kind='subagent_spawned' AND ts_ms > now - 24h`.

### Part C — scrubber renders sub-lanes nested under parent

`web/fleet-scrubber/index.html` adds a layout pass after fetching segments:

- Group segments by `parent_session_id` (NULL parents = top-level lanes).
- For each top-level lane, render any segments whose `session_id` has `parent_session_id == this lane.session_id` as **nested lanes** below the parent, indented 20px and separated by a faint dashed divider.
- Lane label format: `└── <sub-session-id-suffix> [agent_description]` (truncate description to 30 chars).
- Add an expand/collapse arrow on the parent label (default expanded; remember state in localStorage).
- The brush timeline at the bottom collapses nested lanes back into the parent's mini-strip.

API support: `/api/segments` returns both `session_id` and `parent_session_id` in each row (already there if Part B schema lands).

## Edge cases

| Scenario | Behavior |
|---|---|
| Sub-agent crashes before emitting any work | only the `subagent_spawned` row exists; lane shows zero segments under it (correct — we know it spawned, did nothing observable, then died) |
| Parent ships its own PR before the sub does | parent lane shows merge segment normally; sub lane stays open; the nesting persists until sub finishes |
| Sub spawns sub-sub | chain stored via repeated `parent_session_id` lookups; scrubber recurses one level (caps at depth 3 by default to avoid UI noise) |
| Two sub-agents share a worktree (anti-pattern) | recorder logs `worktree_path_collision` ambient event; falls back to parent attribution for the colliding events; operator sees the warning in the segment-detail panel |
| `Agent` tool with `isolation: "worktree"` (creates a fresh git worktree) | the wrapper emits `subagent_spawned` *after* the worktree is created, so the path is correct |

## Signal flow

```
+--------------------+
| Opus orchestrator  |
|  - calls Agent()   |
|  - wraps with      |
|    emit_spawn()    |
+---------+----------+
          |
          v
+--------------------+      writes      +--------------------+
| .chump-locks/      | <--------------- | emit_spawn helper  |
| ambient.jsonl      |                  | (or harness hook)  |
+---------+----------+                  +--------------------+
          |                                       
          |        +----------------------------+
          +------> | chump-fleet-recorder       |
                   |  - maintains wt -> sub map |
                   |  - rewrites session_id     |
                   |    on INSERT               |
                   +------------+---------------+
                                |
                                v
                   +--------------------+    HTTP/WS    +--------------------+
                   | .chump/            | <-----------> | chump-fleet-server |
                   | fleet_events.db    |               |  /api/segments     |
                   +--------------------+               +---------+----------+
                                                                  |
                                                                  v
                                                       +--------------------+
                                                       | fleet-scrubber UI  |
                                                       | (nested sub-lanes) |
                                                       +--------------------+
```

## Implementation order

1. **Part A** in isolation — emit the event from the orchestrator wrapper. Recorder ignores it (forward-compatible). Validates the contract with peer harnesses before any sqlite schema churn.
2. **Part B schema migration** — add `parent_session_id` column + index. Recorder backfills from `subagent_spawned` events. Server's `/api/segments` includes the new column.
3. **Part C frontend** — nested-lane render. Cheap once the data shape lands.

This ordering means Part A can ship independently and immediately surface the dispatch-ratio telemetry that CREDIBLE-074 needs, without waiting on the visual change.

## Open design questions (NATS FEEDBACK welcome)

1. **Where exactly does the `emit_spawn` helper live?** Claude Code has no first-class hook for "before Agent tool call." Options: (a) wrap every dispatch site by hand in the orchestrator's prompt, (b) a shell wrapper script `scripts/coord/emit-subagent-spawn.sh` invoked from a SessionStart hook on the sub-agent side (which knows its own session_id and can look up its worktree from `pwd`), (c) post-hoc detection by the recorder when it sees activity in a new worktree without a corresponding spawn event.
2. **Depth cap**: 3 levels (parent → sub → sub-sub) feels right. Higher would clutter the gantt. Vote on the cap.
3. **Should the `subagent_spawned` event also carry the *gap_id* the sub-agent is claiming?** Helps the segment-detail panel surface the right gap context without re-querying.

## Cross-references

- META-129 — fleet-scrubber segment-detail panel info architecture; this resolves META-129's open question (b)
- INFRA-2164 — fleet-viz umbrella
- INFRA-2174 — chump-fleet-recorder (Part B target)
- INFRA-2175 — chump-fleet-server (Part B `/api/segments` change)
- INFRA-2176 — web/fleet-scrubber (Part C target)
- CREDIBLE-074 — curator sub-agent dispatch-ratio telemetry (consumes `subagent_spawned`)
- SUBAGENT_DISPATCH.md — model-defaults doc for orchestrator behavior
- META-617 — filed this design proposal for META team review (this doc)
