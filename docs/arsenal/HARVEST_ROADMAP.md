# Harvest Roadmap for Chump

> _Generated 2026-05-23 by the Harvester. Wave 3 addendum + sequencing 2026-05-23._
> **Strategic synthesis:** [`docs/strategy/HARVEST_GROWTH_DIRECTIONS_2026-05-23.md`](../strategy/HARVEST_GROWTH_DIRECTIONS_2026-05-23.md) — 6 growth directions with substrate-readiness scores, filed-gap mapping, and sequencing recommendation.
> _Sources: 3 waves of parallel cluster scans (74/76 = 97% coverage) + cross-check against [docs/ROADMAP.md](../ROADMAP.md) + [docs/strategy/PRODUCTIZATION_PLAN_2026-05-22.md](../strategy/PRODUCTIZATION_PLAN_2026-05-22.md)._

This document maps Chump's **stated current needs** (productization plan + Marcus arc + 50/hr push) onto **primitives that already exist** in the 76-repo arsenal. It is decisive: each row says "harvest this, this way, now" or "shelve" or "skip." No maybes.

---

## TL;DR — The five harvests that pay back fastest

| # | Source primitive | Target Chump initiative | Route | Why now |
|---|---|---|---|---|
| **1** | `BEAST-MODE` HITL approval flow (Approve/Reject endpoints + `requiresHumanApproval` flag + `executionMode: DRAFT\|SOVEREIGN`) | [INFRA-1486](../gaps/INFRA-1486.yaml) Marcus trust gate (P0, open, next pickup) | **Vendor** the endpoint shape & state machine | Direct, production-ready, near-perfect fit for per-gap budgets |
| **2** | `chump-proprietary::crates/coord` (`Executor`, `consensus`, `mesh::MeshTransport`) | INFRA-1763 (predictive collision) + INFRA-1758 file-fallback layer | **Dependency** — extract `chump-coord-mesh` crate consumable from both private and public | Mesh + consensus are already production in proprietary; current public-Chump gaps are re-implementing them piecewise |
| **3** | `echeo::Matchmaker::calculate_ship_velocity_score()` (cosine sim + language/type boosts, returns 0–1.0) | INFRA-1764 (skill-aware routing via `routing_outcomes`) | **Vendor** the algorithm (~50 LOC of Rust) | Replaces heuristic pillar-balance scoring with a single deterministic number; identical math to what INFRA-1764 needs |
| **4** | `openclaw` memory pattern (SQLite + FTS + LanceDB embeddings cache + `memory-tool` integration into agent tool registry) | INFRA-1765 (cross-agent lesson propagation) + general `memory_db` deepening | **Vendor** the schema & lookup patterns | Openclaw's spawn contract was the production-ready inspiration for Chump's just-shipped INFRA-1720 — the memory layer is the next obvious port |
| **5** | `neural-farm` OpenAI-compat `/v1` proxy + LiteLLM/InferrLM router | Local-LLM offline mission ([CP-001](cross-pollination/CP-001-neural-farm-into-chump.md)) | **Microservice** | Already drafted; just needs the gap filed and the env var wired |

If you do nothing else this week from the arsenal: **#1 (BEAST-MODE → INFRA-1486)** is the highest leverage. It's already P0, it's the Marcus blocker, and BEAST-MODE has the endpoint shape sitting there ready to port.

---

## The DRY catch — possible discovery failure on AST crawling

**RESOLVED (INFRA-1812, 2026-05-23) — verdict (c) Genuinely different. No lineage header, no consolidation gap.** Full side-by-side matrix: [`CP-002-treesitter-lineage.md`](cross-pollination/CP-002-treesitter-lineage.md).

The scout found that **`echeo/src/shredder.rs`** already implements tree-sitter AST extraction for TypeScript, Rust, Python, and Go with authorship metadata. Chump just shipped [#2385](https://github.com/repairman29/chump/pull/2385) — `feat(INFRA-1719): tree-sitter AST crawler + decompose integration` — two days ago.

**This is exactly the failure mode the Harvester exists to prevent.** The investigation (INFRA-1812) confirmed the catalog *did* have a discovery-failure footprint — echeo was listed as a repo but `shredder.rs` was never indexed as a primitive — but the two implementations turned out to be fit-to-purpose for different consumers (INFRA-1719 feeds `chump gap decompose`'s LLM prompt context; echeo's shredder feeds a vector-embedding bounty matchmaker), with disjoint output schemas, incompatible tree-sitter ABI generations, and no code shared between them. Vendoring or merging would have cost more than it saved. The gap in the catalog itself is tracked as a follow-up: **INFRA-3526** (index per-file primitives, not just per-repo metadata, so this class of question surfaces automatically next time).

---

## Per-cluster recommendations

### chump-engine (5 repos — the engine itself)
| Repo | Health | Verdict |
|---|---|---|
| `chump` (this repo) | Active | n/a — target of harvests |
| `chump-proprietary` | Active (17d) | **HARVEST** mesh/coord/consensus into shared crate — see #2 |
| `chump-brain` | Active (auto-committed) | **Already integrated** — it's a runtime memory artifact, not a harvest target |
| `chump-chassis` | Dormant (66d) | **Skip** — Axum boilerplate stub, no real primitives |
| `homebrew-chump` | Active | Already serving its purpose (release tap) |

### tools-platform (9 repos — adjacent AI tooling)
| Repo | Health | Verdict |
|---|---|---|
| `neural-farm` | Active (84d, threshold) | **HARVEST** as local-LLM gateway — see #5 |
| `openclaw` (= `~/Projects/Maclawd/`) | Active (68d) | **HARVEST** memory pattern + spawn contract reference — see #4 |
| `oracle` | Dormant stub | **Skip** — README is template, no substance |
| `daisy-chain` | Dormant stub | **Skip** — README is template, no substance |
| `code-roach` | Dormant stub | **Skip** — promising name, hollow inside |
| `slidemate` | Active (84d) | **Shelf** for content-bots-suite work (not engine-relevant now) |
| `pixel-edge-server` | n/a | Outside Chump engine scope |
| `workbench`, `slides` | unknown | Low signal; skip until specific need |

### echeo-resonant (8 variants — the duplication poster child)
The cluster has 8 repos but only `echeo` (Rust) and `echeo-internal` (Rust, internal twin) carry real code. The others (`echeo-web`, `echeo-dev`, `echeodev`, `echeo_old`, `echeo-archived`, `echeovid`) are dead-with-state or auxiliary.

| Repo | Verdict |
|---|---|
| `echeo` (Rust CLI) | **HARVEST** Ship Velocity Score — see #3. Also flag the **AST crawler DRY catch** above |
| `echeo-internal` | Probable mirror of `echeo`; investigate before separate harvest |
| The other 6 | **Archive on GitHub** — pure debt; recommend `gh repo archive` on a hygiene sweep |

### upshift-deps (1 repo, very alive)
| Repo | Health | Verdict |
|---|---|---|
| `upshift` | Active (43d) | **Future Microservice** for gap workers — `upshift fix --dry-run --json` exposes a clean integration surface for "is this dep upgrade safe?" decisions. Not P0 today, but worth a CP brief once Marcus arc lands and Chump touches more Cargo.toml/package.json changes |

### beast-mode-qi (2 repos)
| Repo | Health | Verdict |
|---|---|---|
| `BEAST-MODE` | Active (67d) | **HIGHEST-leverage harvest of the entire arsenal** — see #1. Also: enterprise AuditLogger pattern for compliance, task hierarchy (Roadmap→Feature→Task) richer than Chump's current workthread model |
| `beast-mode-website` | n/a | Marketing site; skip |

### jarvis-assistant (4 repos — JARVIS family)
| Repo | Verdict |
|---|---|
| `JARVIS`, `JARVIS-Premium`, `jarvis-rog-ed`, `jarvis-gateway` | **Shelf — architectural conflict.** JARVIS is a competing personal-assistant frontend (skill marketplace, voice channels). Chump is an engine for coding agents. The substrates compete; harvesting between them would create model confusion. Revisit only if Chump pivots toward end-user assistant features |

### smugglers-rpg (24 repos — biggest cluster, lowest engine relevance)
This is a microservices RPG ecosystem. **All 24 repos are dormant** (last pushes Jan 2026). The primitives (`auth-platform-service`, `payment-platform-service`, `chat-platform-service`, etc.) are *theoretically* valuable for any future Chump SaaS product needing auth/payment/chat. They are **NOT useful for Chump-the-engine.**

**Recommendation:** mark this cluster as a "future product factory" — primitives to revisit when Chump starts hosting customer-facing services. For now: **shelf**, with a single follow-up to confirm each service still builds (it'll be a pain to harvest dead code 18 months from now if nobody can compile it).

### content-apps (13 repos)
Mostly Firebase + React + TS apps (postsub, trove, pvc, mythseeker, slidemate, mixdown, …). Useful for the [content-bots-suite](https://github.com/repairman29/chump) productization (per your `project_content_bots_suite` memory entry), not for Chump-the-engine. **Shelf the whole cluster** for the content-bots work-stream.

### political-strat, marketing-sites, misc
None engine-relevant. **Skip.** Recommend an archive pass on the duplicate `2029-*` and `project-forge*` repos as a separate hygiene gap.

---

## Proposed gaps to file (your call)

Each below is concrete enough to file with full AC. Want me to file any/all?

| # | Title (proposed) | Domain | Pillar | Priority |
|---|---|---|---|---|
| **G1** | `EFFECTIVE: investigate INFRA-1719 vs echeo/src/shredder.rs — confirm harvest lineage or file consolidation` | INFRA | EFFECTIVE | P1 |
| **G2** | `EFFECTIVE: vendor BEAST-MODE HITL approval flow into chump preflight + bot-merge (Marcus trust gate)` | INFRA | EFFECTIVE | P0 (Marcus blocker) |
| **G3** | `EFFECTIVE: extract chump-coord-mesh crate from chump-proprietary, consumed by both private + public mesh layer` | INFRA | EFFECTIVE | P1 |
| **G4** | `EFFECTIVE: vendor echeo::ShipVelocityScore as Chump gap-value scorer for routing_outcomes (INFRA-1764)` | INFRA | EFFECTIVE | P1 |
| **G5** | `RESILIENT: vendor openclaw memory schema (SQLite + FTS + embeddings cache) into Chump memory_db (INFRA-1765 substrate)` | INFRA | RESILIENT | P2 |
| **G6** | `ZERO-WASTE: archive 6 dead echeo-* variants + 3 dead 2029-* + 2 dead project_forge/-forge` | INFRA | ZERO-WASTE | P3 (hygiene) |

---

## Skip list (don't bother)

- `oracle`, `daisy-chain`, `code-roach` — hollow stubs, no actual implementation despite promising READMEs
- All 24 smugglers-rpg microservices — dormant + irrelevant to engine
- All 8 echeo-* variants except `echeo` and `echeo-internal` — dead-with-state
- All 4 JARVIS variants — competing-frontend architectural conflict
- `chump-chassis` — boilerplate stub
- All content-apps — relevant to content-bots-suite, not engine

---

## Wave 2 addendum (2026-05-23, post-token-rotation)

Wave 1 covered 7 deep-scans (9% of 76); Wave 2 added 18 more for 25 total (33%). The remaining 51 are mostly Smugglers ancillary services, tiny content apps, archived variants, and marketing sites — low harvest signal individually.

### Wave 2's biggest claim was inverted — corrected 2026-05-23

**Original claim (incorrect):** "`repairman29/registry` is a fork of `agentclientprotocol/registry` with **276 commits ahead, 0 behind** — Jeff has been actively customizing it." 

**Actual state (per CP-007 investigation):** the fork is **0 ahead, 276 BEHIND** upstream. Jeff's fork is **stale, not divergent** — taken once on 2026-04-16 and never touched while upstream marched 276 hourly-bot commits. Zero original divergence.

**Further correction:** ACP is a Zed-led editor↔agent JSON-RPC standard (1:1 editor-to-agent over stdio). Chump coord is N:M worker-to-worker coordination over NATS. **Different problem spaces, not competing standards.**

**Verdict from INFRA-1822 CP-007:** option (c) — Chump coord continues independent path. ACP is NOT a sequencing trap for the A2A layer work (INFRA-1118-1121). Narrow follow-up only if editor-side demand appears: an inbound shim that lets Zed/editor users drive Chump *as* an ACP agent.

**Meta-lesson:** the Harvester's biggest find of Wave 2 was wrong because the `gh repo list` metadata didn't distinguish "ahead vs behind" — only "divergence count." Surface metadata can mislead; the load-bearing call is the explicit `gh api .../compare/<base>...<head>` query. CP-007 demonstrates the verification pattern.

### New top harvests from Wave 2

| Source | Target Chump need | Route | Gap |
|---|---|---|---|
| `registry` ACP fork (276 commits ahead of upstream, active 2026-05-23) | Architectural alignment decision — broader-ecosystem interop or stay independent | Investigation first | [INFRA-1822](../gaps/INFRA-1822.yaml) |
| `pixel-edge-server` bicameral-mind blueprint (BLUEPRINT_BEST_IN_CLASS.md) — Reflexive on-device + Neocortex cloud routing | Pi mesh / neural-farm architecture | Vendor architectural pattern | not yet filed (consider) |
| `ai-gm-service` `aiGMMultiModelEnsembleService.js` + `togetherAIService.js` (Together.ai → Qwen 72B → Mistral fallback chain, 45+ service files) | Chump LLM abstraction layer (provider-agnostic routing) | Vendor or Microservice | not yet filed (consider) |
| `auth-platform-service` `enterpriseSSOService.js` + `mfaService.js` (JWT+MFA+SSO+DDoS+Redis-rate-limit, production-shaped) | Chump SaaS tier (post-Marcus productization) | Microservice | not yet filed (consider) |
| `postsub` `server.js` Stripe tiered billing (PLATFORM_FEES: basic 5%, pro 8%, enterprise 3%, with creator revenue split logic) | Marketplace + commercial tier monetization | Vendor (extract fee-calc) | not yet filed (consider) |

### Updated per-cluster verdicts

- **smugglers-rpg (24 repos):** unshelved by Wave 2 sampling. `ai-gm-service` and `auth-platform-service` are real, harvestable. `payment-platform-service` is Stripe-locked but usable. `chat-platform-service` and `code-generation-service` are scaffold-only — those stay skip.
- **content-apps (13 repos):** `postsub` Stripe pattern is the prize. `olive`, `trove-app`, `pvc` remain shelf (domain-coupled, governance docs, or claimed-but-absent rules engines).
- **tools-platform → pixel-edge-server:** unshelved. Bicameral-mind architecture is directly aligned with neural-farm and Pi mesh vision.
- **jarvis-family:** confirmed conflict. `jarvis-rog-ed` has reusable skill orchestration patterns but Windows-platform scope. `JARVIS-Premium`/`jarvis-gateway`/`jarvis-android` confirmed shelf/skip/dead.
- **misc → registry:** unshelved as the highest-strategy finding of the whole session.

### Wave 3 candidates (not yet scanned, in priority order)

1. `mythseeker2` — TypeScript+Three.js+Firebase+OpenAI. 3D RPG. Harvest candidate: agent persona system if cleanly extracted.
2. `mixdown` — Python+Flask audio recording with AI metadata. Harvest candidate: audio pipeline if a content-bot needs it.
3. `services-dashboard`, `service-frontends`, `mock-services`, `bot-simulation-service` — Smugglers UI shells. Likely all scaffold.
4. `analytics-platform-service`, `economy-system-service`, `marketplace-system-service`, `asset-management-service`, `audio-generation-service` — remaining Smugglers services. Sample 2 to confirm the 2-out-of-5 alive ratio holds.

---

## Wave 3 addendum (2026-05-23, post-productization)

Operator instruction: "you'd be surprised what you find in all of them." Dispatched 5 parallel Explore subagents to cover the 44 untouched repos via `gh api`. Coverage now **74/76 = 97%** (2 unreachable: `jarvis-android` 404, `homebrew-chump` skipped as trivial Ruby formula).

### Top surprises that pre-filtering missed

| # | Repo | Why surprising | Harvest value to Chump |
|---|---|---|---|
| **1** | `project-forge` (misc cluster) | 149 MB ACTIVE OKR platform (Next.js + Node + Postgres + AI insights + GCloud deploy) — not the dormant marketing-named thing the cluster label implied | **HIGH** — initiative hierarchy schema overlaps Chump's `state.db` gap registry; harvest the schema + AI-insights pipeline |
| **2** | `bot-simulation-service` (smugglers-rpg) | 11.2 MB REAL synthetic-load generator with 5 bot archetypes, fatigue sim, funnel analytics, Railway-native — not the scaffolded UI test stub the description implied | **HIGH** — Chump's fleet test harness could harvest directly for synthetic worker simulation, regression load gen |
| **3** | `mock-services` (smugglers-rpg) | 4 production-grade containerized mock servers (Anthropic, OpenAI, Stripe, Supabase) — not the "testing utilities" stub the description implied | **HIGH** — directly injectable into Chump CI; replaces ad-hoc fixtures for LLM-call tests |
| **4** | `economy-system-service` (smugglers-rpg) | REAL MarketSimulationEngine: elasticity-based pricing, sector-stratified, beginner-mode variant | **MEDIUM** — extends INFRA-1816 ShipVelocityScore substrate options; alternative gap-value scoring algorithm to evaluate |
| **5** | `ims` (political-strat) | REAL Flask + SQLAlchemy Initiative Tracker with Chart.js dashboard + role-based auth + RESTful API — not the "political-strategy" lump the cluster label implied | **MEDIUM** — reference architecture for Chump's gap-priority operator UI (esp. dashboard schema + REST shape) |
| **6** | `coderoach` (archived) | Distinct codebase from active `code-roach`; autonomous code-quality + self-learning AI fixer patterns | **LOW-MEDIUM** — mine before final archive; could inform Chump's auto-fix orchestration |

### Other real-and-harvestable finds (lower priority)

- `character-system-service`, `combat-system-service` — REAL multi-file domain logic with persistent state (data/ dirs). Not Chump-engine-relevant but proves the cluster has real code under the boilerplate descriptions.
- `analytics-platform-service` — REAL ML-driven retention scoring (`aiInsightsEngine.js` with weighted models, conversion thresholds, churn risk). Relevant to **fleet telemetry layer (INFRA-721 adjacent)** if Chump grows behavioral analytics.
- `audio-generation-service` — REAL voice synthesis with emotion profiles + quality presets (draft/standard/premium/cinematic). Content-bots-suite adjacent.
- `asset-management-service` — REAL dual AI generator (image + 3D) with style matrix (10 art styles × 4 quality tiers). Content-bots-suite adjacent.
- `mythseeker2` — ACTIVE refactor in progress (Feb 7, "75% REFACTORED — PHASE 2 COMPLETE"). Firebase Cloud Functions + Vertex AI → OpenAI fallback. Worth re-checking quarterly.
- `mission-engine-service` — Supabase + Redis + LLM choreographer pattern. **Directly applicable to Chump's gap-decompose pipeline.**
- `zendesk-background-agent` — Vercel + OpenAI embeddings for semantic ticket matching. Pattern reference for operator-recall de-duplication.

### Real-but-low-Chump-value (worth knowing, not harvesting)

- `dice` — TTRPG expression parser + modifier resolution (extracted from MythSeeker). Reusable randomization primitive but no Chump need.
- `trove-web` — full Next.js SPA with Firebase + GCS bucket integration. Reference for any future Chump artifact storage.
- `coloringbook` — React + FastAPI image-processing proxy. Compute-offload pattern (neural-farm adjacent).
- `mixdown` — Python + Flask + AI metadata enrichment.
- `echeovid` — Multi-channel content-repurposing pipeline (NOT the 7-personas system the description implied).
- `sheckleshare` — Grow Garden Calculator pricing engine.
- `internal-zendesk-tools` — React 18 + TS + Vite + Tailwind assessment questionnaire (architecture reference for Chump dashboards).

### Confirmed safe to archive (refines INFRA-1818's list — was 11, now 13+)

`2029`, `2029-versioned`, `repairman29-website`, `beast-mode-website`, `echeo-archived`, `echeo-dev`, `echeo_old`, `echeodev`, `project_forge`, `okr`, `slides`, `services-dashboard`, `service-frontends`.

### Meta-lesson — pre-filtering is a failure mode

Wave 2 sampled 5 of 24 Smugglers services and concluded the cluster was "all dormant, low harvest signal." Wave 3 sampled 14 more and found **6 of them REAL with extractable primitives**. The pre-filter dropped real signal. INFRA-1823's "Coverage push: deep-scan remaining 45 of 76 fleet repos" was exactly the right gap to file; this Wave 3 work executes that AC.

**Pattern rule for future Harvester sessions:** if a repo is in the catalog, it gets read. The pre-filter for "obvious skip" is `archived: true` + zero recent commits + no description — three signals, not one.

### Suggested follow-up gaps (your call which to file)

| Title | Pillar | Priority |
|---|---|---|
| `EFFECTIVE: harvest bot-simulation-service synthetic-load generator into Chump fleet test harness (CP-008)` | EFFECTIVE | P2 |
| `EFFECTIVE: vendor mock-services (Anthropic / OpenAI / Stripe / Supabase containers) into Chump CI fixture layer (CP-009)` | EFFECTIVE | P1 |
| `EFFECTIVE: compare project-forge OKR schema vs Chump state.db gap schema — extract any superior primitives (CP-010)` | EFFECTIVE | P2 |
| `RESILIENT: harvest mission-engine-service Supabase+Redis+LLM choreographer pattern for Chump gap-decompose pipeline (CP-011)` | RESILIENT | P2 |
| `ZERO-WASTE: update INFRA-1818 archive list with Wave 3 confirmations (+2 confirmed: services-dashboard, service-frontends; total 13)` | ZERO-WASTE | P3 |

---

## Wave 4 — INFRA-1823 AC7 close-out (2026-08-13)

Wave 3's prose findings above were never actually written back into `GLOBAL_ARSENAL.json`'s
`extracted_primitives` field — PR #3698 built the `chump harvest` CLI plumbing but didn't
regenerate the catalog. Re-running `scripts/arsenal/build.py` against the existing
`EXTRACTED_PRIMITIVES` table only closed 16 of the 45 repos AC7 requires. Dispatched the
harvester agent for the remaining 29 via `gh api` (no full clones), added their findings to
`EXTRACTED_PRIMITIVES`, and rebuilt. Final coverage: **34/45 have citable `extracted_primitives`
entries; 11 confirmed scanned-but-empty** (`chump` self-excluded; `chump-brain`, `2029`,
`jarvis-rog-ed`, `slides`, `okr`, `echeo_old`, `code-roach`, `echeodev`, `echeo-dev`,
`repairman29-website` are docs-only/duplicate/template scaffolds with nothing distinct to cite —
consistent with the Wave-3 archive-candidate list above). All 45 were read; "scanned and found
nothing" is a valid outcome, not a gap in coverage.

## Wave 5 — INFRA-6117 coverage push (2026-09-14)

The fleet grew from 76 to 101 GitHub repos since Wave 4 (`gh repo list` count), leaving 50 repos
with no `extracted_primitives` entry — the new "remaining 45" that INFRA-6117 targeted. Dispatched
5 parallel Explore-style subagents via `gh api` (no local clones) covering all 50 (exceeds the
45-repo AC). Added 52 primitives across **32 repos** to `EXTRACTED_PRIMITIVES` in
`scripts/arsenal/build.py`; the remaining **18 confirmed scanned-but-empty**
(`machine-substrate`, `jeffadkins-dev`, `opportunity-library`, `space-shooter`, `inversion`,
`fulcrum`, `okr`, `project-2026-case`, `pixi-game`, `jeffadkins-me`, `homebrew-chump`, `choose`,
`chump-brain`, `repairman29-website`, `2029`, `messaging-demo`, `slides`, `beast-mode-website`)
are static/markdown/config/backup snapshots with no source logic. Notably, re-scanning
`jarvis-rog-ed`, `echeo_old`, `code-roach`, `echeodev`, and `echeo-dev` — flagged empty in Wave 4
— surfaced real primitives this pass (skill-plugin architecture, generic Prisma CRUD base repo,
CLI crawl dispatcher, and a shared typed-error/auth-controller pattern respectively); Wave 4's
"scanned but empty" verdict on those five should be treated as superseded, not authoritative.
Ran `python3 scripts/arsenal/build.py` to regenerate `GLOBAL_ARSENAL.json`/`.md` — exit 0, fleet
size 101 GH repos / 2 cloned locally, 11 clusters / 7 duplications / 0 alerts.

## Closing note — Discovery is the win

The single most important finding from this entire pass isn't any individual primitive. It's the **echeo tree-sitter DRY catch**. We just shipped a tree-sitter crawler in INFRA-1719 (Sonnet's work, 2 days ago) while an existing one sat in echeo. Whether it was harvested-but-unacknowledged or reinvented, **the Harvester catalog would have flagged it at decompose time** if it had been live.

That's the value proposition for the catalog as ongoing infrastructure — not "Jeff has cool repos to show off," but "Chump's planning loop now has eyes on Jeff's prior work." Worth wiring `python3 scripts/arsenal/build.py` into a weekly cron (or a `chump fleet doctor --harvest-check` subcommand) so the next INFRA-1719-shaped discovery failure gets caught at planning time, not at PR-merge time.
