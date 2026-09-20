# Changelog

All notable changes to `chump-mcp-lifecycle` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Dormant (2026-09-20, DOC-155).** No functional change since 0.1.1 —
> subsequent repo commits touching this crate are dependency bumps and the
> AGPLv3/Apache-2.0 relicense, not new API. Live source of truth for the
> parent monorepo is the root [`CHANGELOG.md`](../../CHANGELOG.md).

## [0.1.1] — 2026-04-18

### Changed
- Internal improvements to `SessionMcpPool` request routing — better handling of in-flight responses when a session is dropped mid-call.
- Doc and example tweaks for the README rendered on crates.io.

### Notes
- No breaking changes; v0.1.0 callers keep working.
- Pure patch release.

## [0.1.0] — 2026-04-17

### Added
- Initial publish: persistent per-session MCP (Model Context Protocol) server lifecycle.
- Spawn child processes on session open, route JSON-RPC calls over stdio, SIGKILL on drop.
- The missing piece for ACP `session/new` + `mcpServers`.
- Core types: `SessionMcpPool`, `McpServerSpec`, `McpServerHandle`.
