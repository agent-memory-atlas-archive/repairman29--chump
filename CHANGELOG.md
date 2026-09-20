# Changelog

All notable changes to Chump are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added — Fleet self-hosting: organ-manifest unification + almanac org-wide (2026-09)

The fleet's coordination layer turned inward: the roster of "organs" (daemons,
scripts, cron jobs that keep the fleet alive) and the code-memory index that
answers "have we built X" both moved from scattered per-purpose files to a
single source of truth, with the fleet's own PRs providing the proof.

**Unified organ-manifest:**
- `organ-manifest.txt` is now the single roster of record — `bootstrap-manifest.yaml` folded in, `install-node-housekeeping.sh` sources its roster from it, and a `platforms=` field lets `organ-reconcile` scope entries per platform.
- CI integration + regression tests prove the unified BOM parses/renders/derives consistently, and that a real pre-unification `organ-manifest.txt` fails/routes correctly without the unified format.
- Documented: schema, consumers, migration guide.
- `node-organ-manifest.txt` extends the pattern to process-level organs on individual machines (e.g. CJ's 9 process-level organs).

**Almanac goes org-wide:**
- Almanac (the fleet's grounded code-memory index, `repo:path:line` receipts on every hit) now indexes the whole `repairman29` org, not just `chump` — the canonical fleet index referenced by `almanac-mastery`.
- Wired into `chump-mcp.json`; dynamic git hooks installed via `almanac hook install`.
- Coverage-owner logic gained a `summarized_pct` guard (strict >95%), CI-tested; the reindex wrapper aligned to the real index CLI; `refresh-runner-binary.sh --almanac` emits `almanac_health` and gained a CI test proving its SHA-idempotent build logic; an install-script unbound-var crash + silent exit-0-on-absent-checkout bug was fixed.

**Duty officer resilience:**
- The duty-officer daemon falls back to a UID-derived `XDG_RUNTIME_DIR`/`DBUS_SESSION_BUS_ADDRESS` when the environment doesn't set them, so it survives launch contexts (cron, non-interactive shells) where a login session hasn't populated them.

**Scale:** ~280 PRs merged 2026-09-06 → 2026-09-20 across this theme plus the ongoing RESILIENT/CREDIBLE/INFRA backlog. See `git log origin/main --since=2026-09-06` for the full ledger; this section names the dominant shape, not every PR.

### Added — Agent Client Protocol (ACP) maturity

Post-v0.1.0 work elevates the ACP adapter from a minimal-viable stdio server to a fully spec-complete editor integration. Chump is now usable as a first-class coding agent inside Zed, JetBrains IDEs, and any client in the [ACP Registry](https://blog.jetbrains.com/ai/2026/01/acp-agent-registry/).

**V1 protocol — every spec method shipped:**
- `session/load` — reattach to an existing session (memory-first, falls back to disk).
- `session/list` — enumerate sessions with cursor-based pagination, optional `cwd` filter, configurable `pageSize` (default 50, max 200), unknown-cursor returns empty (clients paginating over a mutating set don't break).
- `session/set_mode` — switch between work/research/light mid-session; emits `ModeChanged` notification before the ack.
- `session/set_config_option` — runtime updates to advertised config options.
- `session/request_permission` — agent → client RPC for tool-call user-consent prompts. Bidirectional RPC machinery (`send_rpc_request` / `deliver_response`) enables this and any future agent-initiated callbacks.
- `fs/read_text_file` + `fs/write_text_file` — agent → client filesystem delegation for SSH-remote / devcontainer setups.
- `terminal/{create, output, wait_for_exit, kill, release}` — full shell-process lifecycle delegation when the editor declared terminal capability.

**V2 cross-process persistence:**
- Each session serialized to `{CHUMP_HOME}/acp_sessions/{id}.json` via atomic temp-file + rename on every state change.
- `session/load` reconstitutes from disk when memory misses; `session/list` merges memory + disk without duplicates.
- Per-instance `persist_dir` (set at `AcpServer::new_with_persist_dir` construction) so tests can't race on a process-wide env var.

**V2.1 tool-middleware integration:**
- Write tools gate through `AcpServer::request_permission()` before executing; sticky `AllowAlways` decisions cached on `SessionEntry.permission_decisions`. Fail-closed on RPC error or timeout.
- `ReadFileTool` / `WriteFileTool` route through `fs/*` when the client declared `fs.read` / `fs.write` capability. Append mode uses read-modify-write since ACP write is overwrite-only.
- `CliTool` (run_cli) routes through `terminal/*` when the client declared terminal capability; poll-based output, best-effort `terminal/release` even on error paths.

**Streaming polish:**
- `chump_event_to_acp_update` translator now emits `Thinking` from `TurnComplete` when a chain-of-thought monologue is present. The 500ms heartbeat `Thinking` events are explicitly dropped so the wire stays quiet.

**Rich content blocks (`session/prompt`):**
- `Image` blocks become text placeholders for text-only models with mime + size estimate so the model can acknowledge the attachment.
- `Resource` blocks dereference via `fs/read_text_file` when the URI is file/path-shaped and the editor declared `fs.read`. Otherwise emit a placeholder. Resource content capped at 32KB inline (`RESOURCE_INLINE_LIMIT`) to protect the context window.
- Image-only and resource-only prompts no longer reject as empty.

**MCP server passthrough (`session/new`):**
- `NewSessionRequest.mcpServers` (was silently dropped) now stored on `SessionEntry.requested_mcp_servers` (name + command + args), persisted to disk, and logged at session/new. Lifecycle management (spawn + manage child processes) is V3 work; this lays the groundwork.

**Test coverage:** 31 → 88 unit tests covering every method (round-trip, malformed-params, error-propagation, fail-closed semantics) plus an end-to-end mock-client lifecycle test that drives a full editor sequence, content-block flattening (7 cases), and mcpServers capture.

**Repository housekeeping:**
- `.github/workflows/build-setup.yml` moved to `.github/build-setup.yml` so GitHub stops trying to run the cargo-dist `steps:` snippet as a standalone workflow. Path updated in `dist-workspace.toml`.
- PWA service worker cache name bumped (chump-v12 → chump-v13); `/sse-event-parser.js` + `/ui-selftests.js` added to the SHELL pre-cache list so the page and its scripts can never fall out of sync after an upgrade.
- `agent_loop.rs` (1328-line monolith) split into a focused `src/agent_loop/` module with 7 submodules: `types`, `context`, `perception_layer`, `prompt_assembler`, `tool_runner`, `iteration_controller`, `orchestrator`. Net 360 lines deleted on the way through; 11 inline tests preserved.
- `.idea/` and `*.iml` added to `.gitignore` for JetBrains IDE users.

### Changed

- **GitHub Actions workflow permissions:** `default_workflow_permissions` flipped from `read` → `write` at the repo level so cargo-dist's "Create GitHub Release" step can POST to the releases API. The workflow already declared `contents: write` in its `permissions:` block, but the repo-level default still capped what the GITHUB_TOKEN could do. Fixed via `gh api --method PUT repos/{owner}/{repo}/actions/permissions/workflow`.

## [0.1.0] — 2026-04-16 — Initial public release

First public release. Chump graduates from private development to an open-source project with full community infrastructure.

### Highlights

- **Single-binary Rust agent** on OpenAI-compatible inference (Ollama, vLLM, mistral.rs) with SQLite + FTS5 persistence
- **Four surfaces**: web PWA, CLI, Discord bot, Tauri desktop shell
- **Six-module consciousness framework** (surprise tracker, memory graph, blackboard, neuromodulation, precision controller, phi proxy) with A/B testing harness — _v0.1.0 historical count; the architecture grew to nine modules after release, and per-module wired-or-not status now lives in [`docs/architecture/CHUMP_FACULTY_MAP.md`](docs/architecture/CHUMP_FACULTY_MAP.md). Validated empirical results are tracked privately (see [`docs/process/RESEARCH_INTEGRITY.md`](docs/process/RESEARCH_INTEGRITY.md) for the public methodology, DOC-036)._
- **Procedural skills system** with Bradley-Terry evolution, skill mutation, SHA-256 deterministic caching
- **Three-way retrieval pipeline** (keyword + semantic + graph) merged by RRF with freshness decay
- **Agent Client Protocol (ACP)** stdio server — launchable from Zed, JetBrains IDEs, and any ACP-compatible client. _(v0.1.0 shipped initialize/new/prompt/cancel; [Unreleased] rounds out the full spec — see below.)_
- **Bounded autonomy** with task contracts, graduated escalation, two-bot fleet coordination
- **Security hardening**: leak scanning, SSRF protection, host-boundary secret pinning, `cargo-audit` in CI
- **530+ tests** across 80+ modules; full documentation at [repairman29.github.io/chump](https://repairman29.github.io/chump/)

See detailed feature list and historical changes below.

[0.1.0]: https://github.com/repairman29/chump/releases/tag/v0.1.0

---

## Pre-release history

### Changes

- **Post-Cascade roadmap (Phases 2–6):** Multi-repo tools, quality guards, context window, ops maturity, fleet expansion.
  - **Phase 2:** `set_working_repo` (override repo root); `onboard_repo` (9-step brief + architecture); `repo_authorize` / `repo_deauthorize` + `chump_authorized_repos` table; allowlist in git/gh tools.
  - **Phase 3:** Mandatory `diff_review` before commit (high-severity blocks); `chump_provider_quality` + sanity-fail circuit feedback + slots with >10% sanity-fail skipped; test-aware editing (baseline, regression, auto-stash on failure when `CHUMP_TEST_AWARE=1`).
  - **Phase 4:** `CHUMP_PREFER_LARGE_CONTEXT` + Gemini routing; `codebase_digest` tool + inject in context; summarization threshold doubles for providers with context >32k.
  - **Phase 5:** Per-provider cost tracking + daily Discord summary; latency/tool-call quality + auto-demotion; `warm_probe_all()` + `--warm-probe` CLI + heartbeat pre-round probe.
  - **Phase 6:** `external_work` and `review` round types in heartbeat (multi-repo work; PR review via `gh api /notifications` + `gh_pr_comment`).
- **Phase 1–4 (dogfood & self-improve):** Repo awareness, read/write tools, GitHub read, git commit/push.
  - **Phase 1:** `CHUMP_REPO` / `CHUMP_HOME`; `read_file`, `list_dir` (path under root, no `..`).
  - **Phase 2:** `write_file` (overwrite/append) with path guard and audit in `logs/chump.log`.
  - **Phase 3:** `GITHUB_TOKEN` + `CHUMP_GITHUB_REPOS`; `github_repo_read`, `github_repo_list`; optional `github_clone_or_pull` to sync repos under `CHUMP_HOME/repos/`.
  - **Phase 4:** `git_commit`, `git_push` in CHUMP_REPO for allowlisted repos; full audit; prompt says only push after user says "push" or "commit" unless `CHUMP_AUTO_PUSH=1`.
- **Executive mode:** `CHUMP_EXECUTIVE_MODE=1` skips allowlist/blocklist for `run_cli`, uses `CHUMP_EXECUTIVE_TIMEOUT_SECS` and `CHUMP_EXECUTIVE_MAX_OUTPUT_CHARS`; every run logged with `executive=1`.
- **Super powers:** When repo + GitHub + git are configured, system prompt adds self-improve hint (read docs → edit → test → commit/push when approved). `CHUMP_AUTO_PUSH=1` allows push after commit without a second confirmation.

### Fixes

- None this release.
