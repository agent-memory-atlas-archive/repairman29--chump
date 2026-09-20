# Changelog

All notable changes to `chump-agent-lease` are documented here.
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> **Dormant (2026-09-20, DOC-155).** No functional change since 0.2.0 —
> subsequent repo commits touching this crate are dependency bumps and the
> AGPLv3/Apache-2.0 relicense, not new API. Live source of truth for the
> parent monorepo is the root [`CHANGELOG.md`](../../CHANGELOG.md).

## [0.2.0] — 2026-04-18

### Added
- `pub fn ambient_emit(event: &str, extra: &[(&str, &str)])` — append a JSON event line to the shared `.chump-locks/ambient.jsonl` "peripheral vision" stream. Lets agents that don't directly use the lease APIs still publish session-start, file-edit, commit, etc. signals to the coordination stream other agents read.

### Notes
- No breaking changes; v0.1.0 callers keep working.
- The ambient stream is described in `docs/process/AGENT_COORDINATION.md` of the parent [chump](https://github.com/repairman29/chump) repo.

## [0.1.0] — 2026-04-17

### Added
- Initial publish: path-level optimistic leases for multi-agent coordination on a shared repo.
- Core API: `claim`, `release`, `is_claimed_by_other`, `claim_with_heartbeat`.
- Session-ID resolution chain (env → SDK → worktree-cache → home-fallback).
- Tokio-based heartbeat task that auto-releases on drop or timeout.
