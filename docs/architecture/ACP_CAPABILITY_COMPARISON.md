---
doc_tag: decision-record
owner_gap: DOC-048
last_audited: 2026-10-26
re_audit_due: 2027-02-26
---

# ACP Agent Capability Comparison

This table benchmarks Chump against every agent in the [JetBrains ACP Agent Registry](https://jetbrains.com/acp) plus well-known open-source ACP implementations. Cells link to source documentation; cells marked **⚠️ verify** should be spot-checked at next audit because the registry is live and data can drift.

**Freshness:** re-audited 2026-10-26 (META-062; prior audit 2026-05-13). The live JetBrains registry was not reachable from the fleet worker, so external-agent (Claude Code, Zed AI, Goose) **⚠️ verify** cells are carried forward unconfirmed and no new registry agents were added; a human or network-enabled pass should confirm them. Next re-audit due 2027-02-26. To update a cell, edit this file and bump `last_audited`. Re-audit tracked in META-062.

---

## Comparison Axes

| Axis | Description |
|------|-------------|
| **V1 methods** | Initialize, session/new, session/load, session/list, session/prompt, session/update, terminal/* methods |
| **V2 methods** | V2 additions: session/set\_mode, session/set\_config\_option, session/list\_permissions, session/clear\_permission, session/cancel |
| **V2.1 middleware** | session/request\_permission (outbound RPC for tool-call consent) wired into request handling |
| **Sticky permissions** | session/list\_permissions + session/clear\_permission: sticky decisions survive across turns; optionally serialized across restarts |
| **Cross-process sessions** | session/load reconstitutes sessions from a prior process via disk persistence |
| **Modes** | Semantic (work/research/light) vs UI-label-only (fast/deep) distinction |
| **Skills** | Exposes a skills/procedure library discoverable via `skills: true` capability flag |
| **Thinking stream** | Emits `Thinking` events for model reasoning tokens (Qwen3 `<think>`, Claude extended thinking) separately from AgentMessageDelta |
| **Mixed-content prompts** | session/prompt accepts text + image + resource content blocks in a single message |
| **Terminal lifecycle** | terminal/create → terminal/output → terminal/wait\_for\_exit → terminal/kill → terminal/release |
| **mcpServers passthrough** | Records client-declared MCP server config on session; manages lifecycle |

---

## Agent Comparison Table

### Chump

| Axis | Status | Notes / Source |
|------|--------|----------------|
| **V1 methods** | ✅ Full | All V1 methods shipped. [ACP.md § Implementation Status](ACP.md#implementation-status) |
| **V2 methods** | ✅ Full | session/set\_mode, set\_config\_option, list\_permissions, clear\_permission, cancel. [ACP.md](ACP.md) |
| **V2.1 middleware** | ✅ Full | session/request\_permission outbound RPC; fail-closed on timeout. [ACP.md](ACP.md) |
| **Sticky permissions** | ✅ Across turns; ⚠️ Across restarts (disk persistence exists, UI affordance not yet exposed) | [ACP.md § V2](ACP.md) |
| **Cross-process sessions** | ✅ Full | session/load reconstitutes from disk when CHUMP\_HOME/CHUMP\_REPO configured. [ACP.md](ACP.md) |
| **Modes** | ✅ Semantic | work (full framework), research (higher compression), light (slim context). [ACP.md § Modes](ACP.md#modes) |
| **Skills** | ✅ | `skills: true` capability; exposes procedural skills via prompt interface. [ACP.md § Capabilities](ACP.md#chump-specific-capabilities) |
| **Thinking stream** | ✅ | Qwen3 `<think>` blocks + Claude extended thinking → separate `Thinking` events. [ACP.md § Thinking](ACP.md#sessionupdate--thinking-event) |
| **Mixed-content prompts** | ✅ | Text + image + resource blocks flattened; image → placeholder for text-only models. [ACP.md](ACP.md) |
| **Terminal lifecycle** | ✅ Full | All 5 terminal methods. [ACP.md](ACP.md) |
| **mcpServers passthrough** | ✅ Records; ⚠️ Lifecycle management is V3 | `mcpServers` stored on SessionEntry; [INFRA-747](https://github.com/repairman29/chump/issues/747) tracks full lifecycle. [ACP.md](ACP.md) |

---

### Claude Code (Anthropic)

| Axis | Status | Notes / Source |
|------|--------|----------------|
| **V1 methods** | ✅ Full | Claude Code implements ACP for Zed and JetBrains integration. [Claude Code docs](https://claude.ai/code) |
| **V2 methods** | ✅ Full | set\_mode, list\_permissions, clear\_permission shipped. ⚠️ verify current version |
| **V2.1 middleware** | ✅ | request\_permission outbound RPC integrated. ⚠️ verify |
| **Sticky permissions** | ✅ Across turns; ✅ Across restarts | Permissions persist across process restarts via local config. ⚠️ verify |
| **Cross-process sessions** | ✅ | Session continuity across CLI invocations. ⚠️ verify |
| **Modes** | ✅ Semantic | Distinct modes with different context strategies (auto/fast/etc.). ⚠️ verify ACP-specific mode labels |
| **Skills** | ❌ | Claude Code uses slash-commands, not the ACP `skills` capability flag. ⚠️ verify |
| **Thinking stream** | ✅ | Claude extended thinking tokens emitted as Thinking events. ⚠️ verify ACP-specific implementation |
| **Mixed-content prompts** | ✅ | Image + text content accepted. ⚠️ verify resource block support |
| **Terminal lifecycle** | ✅ | Terminal management via ACP. ⚠️ verify all 5 methods |
| **mcpServers passthrough** | ✅ | Full MCP server lifecycle management. ⚠️ verify ACP passthrough specifically |

---

### Zed AI Agent

| Axis | Status | Notes / Source |
|------|--------|----------------|
| **V1 methods** | ✅ Full | Reference ACP client; Zed developed the protocol. [Zed ACP docs](https://zed.dev/acp) |
| **V2 methods** | ✅ Full | Zed implements the full V2 spec as the originating client. ⚠️ verify agent-side |
| **V2.1 middleware** | ✅ | request\_permission supported. ⚠️ verify agent-side implementation |
| **Sticky permissions** | ✅ | Permissions UI in Zed's AI panel. ⚠️ verify cross-restart persistence |
| **Cross-process sessions** | ✅ | Session persistence integral to Zed's UX. ⚠️ verify disk path |
| **Modes** | ✅ UI-label | Zed uses UI labels; semantic mapping to backend strategy TBD. ⚠️ verify |
| **Skills** | ❌ | No skills capability flag observed. ⚠️ verify |
| **Thinking stream** | ✅ | Zed renders Thinking events in the AI panel. ⚠️ verify agent-side emission |
| **Mixed-content prompts** | ✅ | Image drag-drop + file references. ⚠️ verify all content block types |
| **Terminal lifecycle** | ✅ Full | Zed's integrated terminal. ⚠️ verify all 5 ACP methods |
| **mcpServers passthrough** | ✅ | Zed's MCP server config. ⚠️ verify ACP passthrough protocol |

---

### Goose (Block)

| Axis | Status | Notes / Source |
|------|--------|----------------|
| **V1 methods** | ⚠️ Partial — verify | Open-source; ACP adapter may not be complete. [Goose GitHub](https://github.com/block/goose) |
| **V2 methods** | ⚠️ verify | Mode/permission methods may not be implemented. |
| **V2.1 middleware** | ⚠️ verify | |
| **Sticky permissions** | ⚠️ verify | |
| **Cross-process sessions** | ⚠️ verify | |
| **Modes** | ⚠️ verify | |
| **Skills** | ❌ | No evidence of skills capability. ⚠️ verify |
| **Thinking stream** | ⚠️ verify | |
| **Mixed-content prompts** | ⚠️ verify | |
| **Terminal lifecycle** | ⚠️ verify | |
| **mcpServers passthrough** | ⚠️ verify | |

---

### Other Registry Agents

> **Note:** The [JetBrains ACP Agent Registry](https://jetbrains.com/acp) is live and updated continuously. The agents listed above are those known at audit date (2026-05-13). To see the current registry, visit the link and cross-check each agent against the axes above. New additions since the last audit should be added to this table at re-audit.

Agents confirmed in the registry as of 2026-05-13 audit: Chump, Claude Code, Zed AI. Additional registry entries should be audited against these axes at the quarterly re-audit (META-051).

---

## Summary Scorecard

| Agent | V1 | V2 | V2.1 | Sticky perms | Cross-proc | Semantic modes | Skills | Thinking | Mixed-content | Terminal | mcpServers |
|-------|----|----|------|-------------|------------|---------------|--------|----------|--------------|----------|------------|
| **Chump** | ✅ | ✅ | ✅ | ✅¹ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅² |
| Claude Code | ✅ | ✅ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ❌ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ✅⚠️ |
| Zed AI | ✅ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ❌ | ✅⚠️ | ✅⚠️ | ✅⚠️ | ✅⚠️ |
| Goose | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ⚠️ | ❌ | ⚠️ | ⚠️ | ⚠️ | ⚠️ |

¹ Sticky across turns; cross-restart UI affordance not yet exposed (planned).  
² mcpServers recorded on session; full lifecycle management tracked in INFRA-747.  
⚠️ = data from docs/registry as of audit date; re-verify at next quarterly audit (2026-08-13).

---

## Re-audit Process

This document should be re-audited quarterly. The gap META-062 tracks the next due date (2026-08-13).

Re-audit checklist:
1. Visit [JetBrains ACP Agent Registry](https://jetbrains.com/acp) — add any new agents
2. For each agent, check their docs for ACP-specific changelogs
3. Update cells and bump `last_audited` date
4. Update `re_audit_due` to three months from the new `last_audited`
5. Comment on META-062 with a link to the PR
