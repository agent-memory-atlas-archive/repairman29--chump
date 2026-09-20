#!/usr/bin/env python3
"""Build GLOBAL_ARSENAL.json — Harvester's fleet catalog.

Reads:
  - docs/arsenal/raw/github_repos.json  (output of `gh repo list --json ...`)
  - ~/Projects/                          (local clones)

Writes:
  - docs/arsenal/GLOBAL_ARSENAL.json     (machine view)
  - docs/arsenal/GLOBAL_ARSENAL.md       (human view)

Reruns are cheap and idempotent — call before any cross-pollination brief.
"""
from __future__ import annotations

import datetime as _dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARSENAL = ROOT / "docs" / "arsenal"
RAW = ARSENAL / "raw" / "github_repos.json"
HOME = Path(os.path.expanduser("~"))
PROJECTS = HOME / "Projects"

# Cluster heuristics — name/description patterns → cluster label
CLUSTERS = [
    ("chump-engine",      r"^chump$|^chump-|^homebrew-chump$"),
    ("echeo-resonant",    r"^echeo"),
    ("jarvis-assistant",  r"^jarvis|^JARVIS"),
    ("beast-mode-qi",     r"^beast-mode|^BEAST-MODE"),
    ("smugglers-rpg",     r"^smuggler|smugglers|^MythSeeker|^mythseeker|^ai-gm-|^auth-platform|^combat-system|^character-system|^mission-engine|^chat-platform|^payment-platform|^economy-system|^marketplace-system|^code-generation|^asset-management|^audio-generation|^analytics-platform|^commercial-platform|^mock-services|^service-frontends|^services-dashboard|^bot-simulation|^internal-zendesk|^zendesk-background"),
    ("upshift-deps",      r"^upshift$"),
    ("content-apps",      r"^slidemate|^mixdown|^coloringbook|^postsub|^echeovid|^olive|^pvc|^dice|^berry-avenue|^sheckleshare|^biomeweavers|^messaging-demo|^trove"),
    ("political-strat",   r"^project2029|^2029|^ims$"),
    ("tools-platform",    r"^daisy-chain|^code-roach|^coderoach|^oracle|^neural-farm|^slides|^workbench|^pixel-edge|^openclaw"),
    ("marketing-sites",   r"^acg|^repairman29-website|^beast-mode-website|^echeo-web|^echeo-internal"),
    ("misc",              r".*"),
]

PRIMITIVE_PATTERNS = {
    "auth":          r"auth|oauth|login|jwt|session",
    "payment":       r"payment|stripe|billing|checkout|monetiz",
    "chat":          r"chat|messaging|discord|message",
    "ai-generation": r"ai-gm|code-generation|audio-generation|content-generation|llm|inferr|neural-farm",
    "ci-cd":         r"vercel|railway|github.*actions|cargo-dist|homebrew-chump",
    "marketplace":   r"marketplace|economy",
    "calendar":      r"calendar|scheduler|cron",
    "list-mgmt":     r"olive|trove|sheckleshare",
    "video":         r"echeovid|video",
    "rpg-mechanic":  r"mythseeker|smuggler|combat|character|mission",
}


# INFRA-1823 AC7: coverage push — extracted_primitives per repo.
#
# The heuristic `detect_primitives()` above is a keyword scan of the
# name/description GitHub metadata; it can't see inside a repo. This table
# is the machine-readable output of the Wave 1-3 deep-scan campaigns
# documented in docs/arsenal/HARVEST_ROADMAP.md — each entry cites a
# specific file/pattern that was verified at source level (per the
# Verify-at-source discipline in HARVESTER.md), not a description guess.
# Populated from the roadmap findings rather than re-scanning: the deep
# reads already happened (74/76 = 97% coverage per Wave 3), this closes the
# loop by making those findings queryable via `chump harvest check` instead
# of living only in prose.
EXTRACTED_PRIMITIVES: dict[str, list[str]] = {
    "BEAST-MODE": ["HITL approval flow (Approve/Reject endpoints)", "requiresHumanApproval flag", "executionMode DRAFT|SOVEREIGN state machine", "enterprise AuditLogger pattern", "task hierarchy (Roadmap->Feature->Task)"],
    "chump-proprietary": ["crates/coord::Executor", "crates/coord consensus", "crates/coord::mesh::MeshTransport"],
    "echeo": ["Matchmaker::calculate_ship_velocity_score() (cosine sim + language/type boosts, 0-1.0)", "src/shredder.rs tree-sitter AST extraction (TS/Rust/Python/Go, authorship metadata)"],
    "openclaw": ["SQLite + FTS memory schema", "LanceDB embeddings cache", "memory-tool agent registry integration"],
    "neural-farm": ["OpenAI-compat /v1 proxy", "LiteLLM/InferrLM router"],
    "upshift": ["upshift fix --dry-run --json (dependency-upgrade safety check)"],
    "registry": ["ACP fork (agentclientprotocol/registry, JSON-RPC editor<->agent standard)"],
    "pixel-edge-server": ["bicameral-mind architecture: Reflexive on-device + Neocortex cloud routing (docs/claude-gateway.md, claude-gateway/server.js:213-269)"],
    "ai-gm-service": ["aiGMMultiModelEnsembleService.js (Together.ai -> Qwen 72B -> Mistral fallback chain)", "togetherAIService.js"],
    "auth-platform-service": ["enterpriseSSOService.js (JWT+MFA+SSO)", "mfaService.js (DDoS + Redis rate-limit)"],
    "postsub": ["server.js Stripe tiered billing (PLATFORM_FEES: basic 5%, pro 8%, enterprise 3%, creator revenue split)"],
    "project-forge": ["initiative hierarchy schema (Next.js + Node + Postgres)", "AI-insights pipeline (GCloud deploy)"],
    "bot-simulation-service": ["synthetic-load generator", "5 bot archetypes + fatigue simulation", "funnel analytics (Railway-native)"],
    "mock-services": ["containerized mock Anthropic API server", "containerized mock OpenAI API server", "containerized mock Stripe API server", "containerized mock Supabase API server"],
    "economy-system-service": ["MarketSimulationEngine (elasticity-based, sector-stratified pricing, beginner-mode variant)"],
    "ims": ["Flask + SQLAlchemy Initiative Tracker", "Chart.js dashboard + role-based auth REST API"],
    "coderoach": ["autonomous code-quality self-learning fixer patterns"],
    "character-system-service": ["persistent-state character domain logic (data/ dir)"],
    "combat-system-service": ["persistent-state combat domain logic (data/ dir)"],
    "analytics-platform-service": ["aiInsightsEngine.js (weighted-model retention scoring, conversion thresholds, churn risk)"],
    "audio-generation-service": ["voice synthesis with emotion profiles + quality presets (draft/standard/premium/cinematic)"],
    "asset-management-service": ["dual AI generator (image + 3D), style matrix (10 art styles x 4 quality tiers)"],
    "mythseeker2": ["agent persona system (Firebase Cloud Functions + Vertex AI -> OpenAI fallback)"],
    "mission-engine-service": ["Supabase + Redis + LLM choreographer pattern"],
    "zendesk-background-agent": ["Vercel + OpenAI embeddings semantic ticket matching"],
    "dice": ["TTRPG expression parser + modifier resolution"],
    "trove-web": ["Next.js SPA + Firebase + GCS bucket integration"],
    "coloringbook": ["React + FastAPI image-processing proxy (compute-offload pattern)"],
    "mixdown": ["Python + Flask + AI metadata enrichment audio pipeline"],
    "echeovid": ["multi-channel content-repurposing pipeline"],
    "sheckleshare": ["Grow Garden Calculator pricing engine"],
    "internal-zendesk-tools": ["React 18 + TS + Vite + Tailwind assessment questionnaire (dashboard architecture reference)"],
    # INFRA-1823 AC7 coverage push, wave 4 (2026-08-13) — closes the 45-repo gap.
    "acg": ["Next.js App Router marketing/blog site with server actions in web/app/contact/actions.ts and markdown-rendered blog via web/components/blog-markdown.tsx"],
    "chump-chassis": [
        "GitHub read-tool primitive (repo file/dir fetch + clone/pull, allowlist-scoped) in src/github_tools.rs (validate_repo_path, github_token, GITHUB_API_BASE)",
        "SQLite pool bootstrap via sqlx::sqlite::SqlitePoolOptions in src/db.rs",
    ],
    "jarvis-gateway": [
        "Multi-provider LLM gateway config (Groq/OpenAI-compatible routing across ~12 providers) in clawdbot.json (models.providers.groq block)",
        "npx-based gateway launcher in start.sh / package.json start script (CLAWDBOT_GATEWAY_PORT env passthrough)",
    ],
    "pvc": ["Cursor sub-agent role definitions (dev/ops/verifier) with skeptical-verification prompt pattern in .cursor/agents/verifier.md"],
    "JARVIS": ["Skill-marketplace skill.json schema (pricing/marketplace/dependencies fields) shared with JARVIS-Premium — see apps/jarvis-ui + .cursor/skills/keep-clis-sharp/SKILL.md"],
    "slidemate": [
        "Multi-platform CLI SDK for AI-generated slide content in packages/cli/src/commands/generate.ts (also bulk.ts, deploy.ts, export.ts)",
        "Postgres schema/migrations for AI-content tracking in backend/db/migrations/003_ai_content_tracking.sql",
    ],
    "berry-avenue-codes": ["iOS WKWebView wrapper pattern (native shell around a web app) in iOS-Wrapper/ContentView.swift (WebView: UIViewRepresentable)"],
    "project2029": ["Flask-Mail password-reset email service in app/services/email_service.py (EmailService.send_password_reset_email)"],
    "JARVIS-Premium": ["Commercial skill packaging schema (pricing/trial/marketplace/env/dependencies) in skills/focus-pro/skill.json"],
    "workbench": ["Google Calendar availability/event service scaffold in backend/src/services/CalendarService.ts (CalendarService.getAvailability, mock-then-real API pattern)"],
    "echeo-internal": ["Fleet/portfolio repo-catalog generator artifacts (COMPLETE_CATALOG.json/.md) in docs/repo-catalog/ — a prior-generation analog of Harvester's GLOBAL_ARSENAL"],
    "biomeweavers": ["Excalibur.js-based 2D actor/game-entity pattern in client/src/actors/EssenceSource.ts (Actor subclass, CollisionType.Passive, GameConfig-driven color/type)"],
    "2029-versioned": [
        "Shared SQLAlchemy TimestampMixin (created_at/updated_at auto-columns) in shared/models/mixins.py",
        "Standalone news-crawler CLI in version1/app/services/crawler/cli.py (NewsCrawler + ContentProcessor pipeline)",
    ],
    "echeo-archived": ["Automated credential-rotation / secret-age auditor in butler/actions/securitySentry.js (checkCredentialRotation, SBOM generation)"],
    "echeo-web": ["Trust/matching scoring model config (qualityThreshold/qualityWeight/capabilityWeight) in .echeo/models/matching-model.json + matching-model.json / trust-score-model.json pair"],
    "daisy-chain": [
        "EventEmitter-based workflow orchestrator with auto-scaling + multi-tenant clustering in src/services/daisyChainOrchestrator.js (DaisyChainOrchestrator)",
        "Thin automation-engine facade wrapping the orchestrator in src/services/automation-engine.js",
    ],
    "oracle": ["Vector-embeddings semantic search service (with unified-embeddings + echeo fallback chain) in scripts/oracle-vector-embeddings.js"],
    "project_forge": ["Express + Objection.js OKR/KeyResult REST controller with transaction support in backend/src/controllers/OKRController.ts"],
    # INFRA-6117: coverage push, wave 5 (2026-09-14) — deep-scan of the 50 repos
    # added to the fleet since Wave 4 (fleet_size grew 76 -> 101). Findings via
    # gh api (no local clones), per-repo verify-at-source discipline.
    "olive": [
        "Bounded tool-calling LLM orchestrator loop with honesty-rail/human-gate guarantees (src/lib/agent/orchestrator.ts)",
        "Deterministic fallback-narration generator for degraded LLM turns (src/lib/agent/fallback.ts)",
        "Kroger pricing/catalog engine (src/lib/kroger/engine.ts, priceList.ts)",
    ],
    "workspace-docs": ["Prose voice-fingerprinting statistical analyzer comparing draft text against a ground-truth corpus by register (content/voice-fingerprint.mjs) with companion corpus-builder (content/voice-corpus.mjs)"],
    "almanac": [
        "Reciprocal Rank Fusion multi-retriever hybrid search (crates/almanac-core/src/fusion.rs)",
        "Cross-encoder reranker HTTP client with multi-schema response parsing (crates/almanac-core/src/rerank.rs)",
    ],
    "games-workspace": [
        "Time-windowed combo/multiplier scoring system (extractions/neon-shmup/ComboManager.ts)",
        "Pixi.js particle-emitter system with lifecycle management (extractions/neon-shmup/ParticleSystem.ts)",
        "Shared leaderboard/feedback-widget modules (shared/leaderboard.js, shared/feedback-widget.js)",
    ],
    "grave-dancer": ["Pure, unit-testable horizontal movement/physics stepper decoupled from the game engine (src/lib/movement.js: stepHorizontalVelocity with accel/friction/clamp logic)"],
    "holler": [
        "Self-contained feedback-widget library with offline retry queue distinguishing permanent (4xx) vs transient (429/5xx) failures and deduped error capture (holler.js)",
        "CLI triage/inbox tool with since-last-run diffing (inbox.mjs)",
    ],
    "privateer": ["Deterministic capability-need tracker/chart generator that separates mechanical bookkeeping from AI judgment, emits a portable cross-harness launch prompt (voyage.mjs)"],
    "jarvis-rog-ed": ["Modular skill-plugin architecture with per-skill index.js entrypoints (jarvis/skills/*/index.js pattern, e.g. clipboard-history, window-manager, workflow-automation)"],
    "echeo_old": ["Generic paginated CRUD base repository over Prisma (apps/notification-service/src/repositories/BaseRepository.ts — abstract class with findWithPagination, typed PaginatedResult<T>, DatabaseError wrapper)"],
    "posse": [
        "Headless-browser autonomous playtest bot with hazard-learning/stall-detection heuristics (bot.mjs)",
        "Deterministic world-graph edge-coverage surveyor with verdict classification (surveyor.mjs, NO_TRANSITION/WRONG_TARGET/SPAWN_MISMATCH logic)",
    ],
    "realm-of-shadows": ["Real-time combat system with hitstop/parry/attack-cooldown state machine (src/systems/CombatSystem.js)"],
    "upshift-cli": [
        "Timestamped backup/rollback manager for filesystem changes with interactive restore flow (src/lib/rollback.ts)",
        "Commander-based CLI command pattern with zod-style input validation (src/commands/fix.ts + src/lib/validate.ts)",
    ],
    "crystal-rush": ["PIXI.js entity classes with hand-drawn vector sprite composition and animation state (src/entities.js Player class)"],
    "roblox-game-manager": ["Async Roblox Open Cloud API client wrapper with typed HTTP verb dispatch and error handling (roblox_api_manager.py RobloxAPIManager class)"],
    "kosmos": ["Gmail OAuth token-refresh + AI-driven email auto-processing pipeline (lib/token-refresh.ts, lib/ai-email-processor.ts, app/api/ai-email-manager/auto-process/route.ts)"],
    "MythSeeker": [
        "Typed combat engine with encounter/turn/event-handler state machine (src/services/combatEngine.ts, class CombatEngine)",
        "D&D5e rules engine with typed Spell/Character/Monster models driving spell/monster JSON data (src/services/rulesEngine.ts)",
    ],
    "smuggler-discord-bot": [
        "d100 outcome-band dice resolver with canon success/failure tiers (src/dice.js)",
        "Session budget-cap surfacing with warn/degrade thresholds (src/budget.js)",
        "Discord channel/thread topology builder for session play (src/channelTopology.js)",
        "Layered ephemeral character-picker flow with TTL'd custom IDs (src/picker.js)",
    ],
    "bulwark": [
        "CircuitBreaker state machine CLOSED/OPEN/HALF_OPEN (src/circuit-breaker.js)",
        "Token-bucket RateLimiter with refill+block (src/rate-limiter.js)",
        "Exponential-backoff RetryHandler with retryable-error classification (src/retry-patterns.js)",
        "ResilientClient composing rate-limit+circuit-breaker+retry (src/resilience.js)",
    ],
    "smuggler": [
        "Pure game-logic core modules: d100 dice with advantage/disadvantage (core/dice.js), heat threshold/consequence system (core/heat.js), plus core/combat.js, core/economy.js, core/reputation.js, core/ships.js",
    ],
    "derelict": [
        "ElectroDB entity + service + tRPC router CRUD pattern with real game-lifecycle business logic — roster/guild validation, scenario slug-collision suffixing (packages/backend/db/services/game.service.ts)",
        "Ownership-checked tRPC mutation pattern for creator/admin authorization (packages/backend/lambda/api/scenario.router.ts)",
    ],
    "trove-app": ["Configurable multi-mode (spinner/progress/skeleton) loading overlay component (frontend/src/components/LoadingOverlay.tsx)"],
    "services-dashboard": ["SmugglerOSLoader — configurable, timed-message boot/loading-screen class with options-merge constructor and DOM lifecycle (create/progress/complete) (js/components/SmugglerOSLoader.js)"],
    "service-frontends": ["SmugglerOSLoader class (duplicate of services-dashboard's) across sub-apps (ai-gm/js/components/SmugglerOSLoader.js, character-system/js/components/SmugglerOSLoader.js) — candidate for de-duplication into a shared package"],
    "commercial-platform": ["Game-economy monetization engine with CAC/LTV/ARPU/ROI calculators, black-market pricing + listing-risk scoring, and smuggling-route risk/toll calculators (server.js, calculateCAC/calculateLTV/calculateBlackMarketPrice/calculateListingRisk/calculateRouteRisk)"],
    "chat-platform-service": [
        "Rule-based multi-category toxicity/content moderation engine with regex pattern banks and contextual escalation/de-escalation tracking (src/services/AIChatModerationService.js)",
        "Multi-language translation config/quality-scoring + language-family grouping for pair selection (src/services/RealtimeTranslationService.js)",
    ],
    "payment-platform-service": [
        "Fraud-detection rule engine with velocity checks, geographic-anomaly thresholds, and typed fraud/risk taxonomies (src/services/AIFraudDetectionService.js)",
        "Dynamic regional pricing engine combining GDP/purchasing-power/exchange-rate data with market-demand/competition weighting (src/services/RegionalPricingService.js)",
    ],
    "marketplace-system-service": ["Cross-game/NFT trading service with real async escrow, trade-fee/NFT-fee/complexity calculators, and multi-chain NFT mint/transfer flow (src/services/CrossGameTradingService.js: createTradeOffer/executeTrade/initializeEscrow/calculateTradeFees)"],
    "code-generation-service": ["Multi-language code generation/refactor/convert/test/doc pipeline with per-language ecosystem metadata and post-processing stages (src/services/MultiLanguageCodeGenerator.js: generateCode/refactorCode/convertCode/generateTests/generateDocumentation)"],
    "smugglers": ["Full game implementation (1.2M+ size) — tree-level scan only; flagged for a dedicated follow-up deep-scan pass rather than a verified per-file citation"],
    "code-roach": ["Raw Node http-based CLI-to-server client with config management, integration setup flows, and parallel-crawl dispatcher (cli/code-roach.js: crawlParallel/parseArgs/commands.quality)"],
    "echeodev": ["Typed error-handling hierarchy (AppError/ValidationError) with structured logging + singleton controller pattern in an OKR/goals backend auth flow (backend/src/controllers/AuthController.ts)"],
    "echeo-dev": ["Same AuthController.ts primitives as echeodev (byte-identical auth controller header) — earlier duplicate/fork; echeodev is the canonical citation"],
}


def extracted_primitives_for(name: str) -> list[str]:
    return EXTRACTED_PRIMITIVES.get(name, [])


# INFRA-1864: per-file primitive indexing (per CP-002 finding).
#
# The EXTRACTED_PRIMITIVES table above is manually-curated prose from deep-scan
# campaigns — it can't be kept current as repos change. This scanner is the
# automated complement: it walks each repo's src/ tree (when a local clone is
# available) and regex-matches known primitive signatures from
# primitive_signatures.json, producing per-file/line hits. Results are merged
# into repos_by_name[X].extracted_primitives (as formatted strings, so the
# field stays a list[str] — backward compatible with existing consumers) and
# also kept structured in extracted_primitives_by_file for `harvest check` to
# surface with line refs.
SIGNATURES_PATH = ROOT / "scripts" / "arsenal" / "primitive_signatures.json"

LANG_EXTENSIONS = {
    "rust": [".rs"],
    "typescript": [".ts", ".tsx"],
    "javascript": [".js", ".jsx"],
    "python": [".py"],
}

SCAN_EXCLUDE_DIRS = {"node_modules", "target", "vendor", "dist", "build", "__pycache__"}
MAX_FILE_BYTES = 500_000  # skip generated/vendored blobs that would slow the walk


def _load_signatures() -> dict:
    if not SIGNATURES_PATH.exists():
        return {}
    return json.loads(SIGNATURES_PATH.read_text())


def _compiled_signatures(signatures: dict) -> dict:
    compiled = {}
    for lang, prim_map in signatures.items():
        if lang.startswith("_"):
            continue
        compiled[lang] = {
            primitive: [re.compile(p) for p in patterns]
            for primitive, patterns in prim_map.items()
        }
    return compiled


def scan_repo_primitives(repo_path: Path, signatures: dict | None = None) -> list[dict]:
    """Walk repo_path/src (falling back to repo_path) and return per-file primitive hits.

    Each hit: {"file": "<repo-relative path>", "line": N, "primitive": label, "match": "<snippet>"}.
    One hit per (file, primitive, pattern) — bounds output on files with many matches.
    """
    signatures = signatures if signatures is not None else _load_signatures()
    if not signatures:
        return []
    compiled = _compiled_signatures(signatures)

    ext_to_langs: dict[str, list[str]] = {}
    for lang, exts in LANG_EXTENSIONS.items():
        for ext in exts:
            ext_to_langs.setdefault(ext, []).append(lang)

    src_root = repo_path / "src"
    if not src_root.is_dir():
        src_root = repo_path

    entries: list[dict] = []
    seen: set[tuple[str, int, str]] = set()  # (file, line, primitive) — collapse multi-pattern dupes
    for dirpath, dirnames, filenames in os.walk(src_root):
        dirnames[:] = [d for d in dirnames if d not in SCAN_EXCLUDE_DIRS and not d.startswith(".")]
        for fname in filenames:
            langs = ext_to_langs.get(Path(fname).suffix)
            if not langs:
                continue
            fpath = Path(dirpath) / fname
            try:
                if fpath.stat().st_size > MAX_FILE_BYTES:
                    continue
                lines = fpath.read_text(errors="ignore").splitlines()
            except OSError:
                continue
            rel = str(fpath.relative_to(repo_path))
            for lang in langs:
                for primitive, patterns in compiled.get(lang, {}).items():
                    for pat in patterns:
                        for i, line in enumerate(lines, start=1):
                            if pat.search(line):
                                key = (rel, i, primitive)
                                if key not in seen:
                                    seen.add(key)
                                    entries.append({
                                        "file": rel,
                                        "line": i,
                                        "primitive": primitive,
                                        "match": line.strip()[:120],
                                    })
                                break  # first hit per (file, primitive, pattern) is enough
    return entries


def _format_scanned_entry(e: dict) -> str:
    return f"{e['primitive']}: {e['file']}:{e['line']} ({e['match']})"


def assign_cluster(name: str) -> str:
    for label, pat in CLUSTERS:
        if re.search(pat, name, re.IGNORECASE):
            return label
    return "misc"


def detect_primitives(name: str, desc: str) -> list[str]:
    blob = f"{name} {desc or ''}".lower()
    return [p for p, pat in PRIMITIVE_PATTERNS.items() if re.search(pat, blob)]


_LOCAL_CACHE: dict[str, str] | None = None


def _build_local_cache() -> dict[str, str]:
    """Map normalized-remote-repo-name → local path, scanning ~/Projects/ once."""
    global _LOCAL_CACHE
    if _LOCAL_CACHE is not None:
        return _LOCAL_CACHE
    cache: dict[str, str] = {}
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        out = ""
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo_root = str(Path(line).parent)
        cfg = Path(line) / "config"
        if not cfg.exists():
            continue
        m = re.search(r"github\.com[:/]([^/]+)/([^.\s]+?)(?:\.git)?[\s\"]", cfg.read_text(errors="ignore") + "\n")
        if not m:
            continue
        repo_name = m.group(2).lower()
        # Prefer top-level (~/Projects/<X>) clones over nested ones for the canonical local_clone
        if repo_name not in cache or repo_root.count("/") < cache[repo_name].count("/"):
            cache[repo_name] = repo_root
    _LOCAL_CACHE = cache
    return cache


def local_clone_for(name: str) -> dict | None:
    """Look for a local clone of this GH repo, by remote URL (handles case mismatch + dir-renames)."""
    cache = _build_local_cache()
    path = cache.get(name.lower())
    if not path:
        return None
    dir_name = Path(path).name
    return {
        "path": path,
        "dir_name_matches_repo": dir_name.lower() == name.lower(),
        "actual_dir_name": dir_name,
        "nested_in_chump": "/Projects/Chump/" in path,
    }


def _excluded_names() -> set[str]:
    """Repo/folder names the operator keeps out of this PUBLIC catalog. The list lives outside
    the tree (default ~/.chump/arsenal-exclude.txt) because it is itself revealing."""
    f = Path(os.environ.get("CHUMP_ARSENAL_EXCLUDE_FILE", str(Path.home() / ".chump" / "arsenal-exclude.txt")))
    try:
        return {l.strip().lower() for l in f.read_text().splitlines() if l.strip() and not l.strip().startswith("#")}
    except OSError:
        return set()


def scan_all_local_roots(known_paths: set[str]) -> list[dict]:
    """Return every local git root with redacted remote + flags. known_paths suppresses dupes."""
    found = []
    try:
        out = subprocess.check_output(
            ["find", str(PROJECTS), "-maxdepth", "4", "-name", ".git", "-type", "d"],
            stderr=subprocess.DEVNULL,
        ).decode()
    except subprocess.CalledProcessError:
        return found
    excluded = _excluded_names()
    for line in out.splitlines():
        if "/node_modules/" in line or "/target/" in line or "/.venv/" in line:
            continue
        repo = str(Path(line).parent)
        if Path(repo).name.lower() in excluded:
            continue  # operator exclude list; see harvest.sh `scan`
        cfg = Path(line) / "config"
        raw_remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                raw_remote = m.group(1)
        has_token = bool(re.search(r"x-access-token:[A-Za-z0-9_]+@", raw_remote))
        remote_clean = re.sub(r"x-access-token:[^@]+@", "x-access-token:<REDACTED>@", raw_remote)
        found.append({
            "path": repo,
            "remote": remote_clean,
            "has_embedded_token": has_token,
            "is_primary_clone": repo in known_paths,
        })
    return found


def find_duplications(repos: list[dict]) -> list[dict]:
    """Find name-similar repos that may be duplicates."""
    dups = []
    # Echeo cluster
    echeo = [r["name"] for r in repos if re.match(r"^echeo", r["name"], re.IGNORECASE)]
    if len(echeo) > 1:
        dups.append({
            "pattern": "echeo-*",
            "variants": echeo,
            "recommendation": "consolidate to one active variant + archive the rest; pick the most recently pushed as primary",
        })
    # MythSeeker
    myth = [r["name"] for r in repos if re.search(r"mythseeker", r["name"], re.IGNORECASE)]
    if len(myth) > 1:
        dups.append({"pattern": "mythseeker-*", "variants": myth, "recommendation": "v1 vs v2 — pick survivor, archive other"})
    # Smugglers
    smug = [r["name"] for r in repos if re.search(r"^smuggler", r["name"], re.IGNORECASE)]
    if len(smug) > 1:
        dups.append({"pattern": "smuggler-*", "variants": smug, "recommendation": "core vs full — clarify which is the active engine"})
    # code-roach / coderoach
    cr = [r["name"] for r in repos if re.search(r"code-?roach", r["name"], re.IGNORECASE)]
    if len(cr) > 1:
        dups.append({"pattern": "coderoach/code-roach", "variants": cr, "recommendation": "rename collision — one is archived; archive the other or merge"})
    # project-forge / project_forge
    pf = [r["name"] for r in repos if re.search(r"project[-_]forge", r["name"], re.IGNORECASE)]
    if len(pf) > 1:
        dups.append({"pattern": "project[-_]forge", "variants": pf, "recommendation": "underscore vs hyphen — both archived; collapse"})
    # 2029 family
    yr = [r["name"] for r in repos if re.search(r"2029", r["name"], re.IGNORECASE)]
    if len(yr) > 1:
        dups.append({"pattern": "2029-*", "variants": yr, "recommendation": "three repos for one initiative — pick one canonical"})
    # JARVIS family
    jv = [r["name"] for r in repos if re.search(r"jarvis", r["name"], re.IGNORECASE)]
    if len(jv) > 1:
        dups.append({"pattern": "jarvis-*", "variants": jv, "recommendation": "platform variants (ROG Ally, Android, gateway, premium) — confirm intentional vs accidental fork"})
    return dups


def find_alerts(repos: list[dict], local_roots: list[dict]) -> list[dict]:
    alerts = []
    # Embedded token check
    leak_paths = [l["path"] for l in local_roots if l["has_embedded_token"]]
    if leak_paths:
        alerts.append({
            "severity": "high",
            "kind": "embedded_github_token",
            "paths": leak_paths,
            "action": "rotate the PAT at github.com/settings/tokens, then re-clone with ssh remote",
        })
    # Misplaced Projects/.git
    if (PROJECTS / ".git").is_dir():
        cfg = PROJECTS / ".git" / "config"
        remote = ""
        if cfg.exists():
            m = re.search(r"url\s*=\s*(\S+)", cfg.read_text(errors="ignore"))
            if m:
                remote = m.group(1)
        alerts.append({
            "severity": "low",
            "kind": "misplaced_clone",
            "path": str(PROJECTS),
            "remote": remote,
            "action": "Projects/ shouldn't itself be a git repo — likely an errant `git clone` at the wrong level. Move .git/ into the intended subdir or rm.",
        })
    # Stale vendored chump clones
    maclawd_chump = PROJECTS / "Maclawd" / "chump-repo"
    if maclawd_chump.exists():
        alerts.append({
            "severity": "medium",
            "kind": "stale_vendored_clone",
            "path": str(maclawd_chump),
            "action": "Maclawd contains a March 2026 clone of chump — Smart Harvest target: convert to git-submodule or Cargo dependency",
        })
    return alerts


def build():
    raw = json.loads(RAW.read_text())
    signatures = _load_signatures()
    repos = []
    for r in raw:
        clone = local_clone_for(r["name"])
        curated = extracted_primitives_for(r["name"])
        scanned: list[dict] = []
        if clone and signatures:
            try:
                scanned = scan_repo_primitives(Path(clone["path"]), signatures)
            except OSError:
                scanned = []
        scanned_fmt = [_format_scanned_entry(e) for e in scanned]
        merged = curated + [s for s in scanned_fmt if s not in curated]
        repos.append({
            "name": r["name"],
            "visibility": r["visibility"],
            "language": (r.get("primaryLanguage") or {}).get("name"),
            "description": r.get("description") or "",
            "archived": r.get("isArchived", False),
            "fork": r.get("isFork", False),
            "pushed_at": r.get("pushedAt"),
            "url": r.get("url"),
            "disk_kb": r.get("diskUsage"),
            "topics": [t.get("name") for t in (r.get("repositoryTopics") or []) if t],
            "cluster": assign_cluster(r["name"]),
            "primitives": detect_primitives(r["name"], r.get("description") or ""),
            "extracted_primitives": merged,
            "extracted_primitives_by_file": scanned,
            "local_clone": clone,
        })

    known_paths = {r["local_clone"]["path"] for r in repos if r["local_clone"]}
    local_roots = scan_all_local_roots(known_paths)
    unmatched_roots = [l for l in local_roots if not l["is_primary_clone"]]

    out = {
        "metadata": {
            "generated_at": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generator": "scripts/arsenal/build.py v0",
            "operator": "repairman29 (Jeff Adkins)",
            "fleet_size_github": len(repos),
            "fleet_size_local_clones": sum(1 for r in repos if r["local_clone"]),
            "fleet_size_unmatched_local_roots": len(unmatched_roots),
        },
        "clusters": {},
        "duplications": find_duplications(repos),
        "alerts": find_alerts(repos, local_roots),
        "primitives_index": {},
        "repos_by_name": {r["name"]: r for r in repos},
        "unmatched_local_roots": unmatched_roots,
    }

    # Cluster summaries
    for r in repos:
        c = r["cluster"]
        out["clusters"].setdefault(c, {"count": 0, "repos": [], "languages": {}, "active_last_30d": 0})
        out["clusters"][c]["count"] += 1
        out["clusters"][c]["repos"].append(r["name"])
        lang = r["language"] or "?"
        out["clusters"][c]["languages"][lang] = out["clusters"][c]["languages"].get(lang, 0) + 1
        if r["pushed_at"] and r["pushed_at"] >= (_dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=30)).strftime("%Y-%m-%d"):
            out["clusters"][c]["active_last_30d"] += 1

    # Primitives index — repos by primitive label
    for r in repos:
        for p in r["primitives"]:
            out["primitives_index"].setdefault(p, []).append(r["name"])

    (ARSENAL / "GLOBAL_ARSENAL.json").write_text(json.dumps(out, indent=2, sort_keys=False) + "\n")

    # Human view
    md = render_md(out)
    (ARSENAL / "GLOBAL_ARSENAL.md").write_text(md)

    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.json'}")
    print(f"wrote {ARSENAL / 'GLOBAL_ARSENAL.md'}")
    print(f"fleet_size: {out['metadata']['fleet_size_github']} GH repos, {out['metadata']['fleet_size_local_clones']} cloned locally")
    print(f"clusters: {len(out['clusters'])}, duplications: {len(out['duplications'])}, alerts: {len(out['alerts'])}")

    _emit_arsenal_rebuilt(out)

    high_alerts = [a for a in out["alerts"] if a["severity"] == "high"]
    if high_alerts:
        print(f"harvest scan: {len(high_alerts)} high-severity alert(s) — see GLOBAL_ARSENAL.md § Alerts", file=sys.stderr)
        for a in high_alerts:
            print(f"  - [{a['severity']}] {a['kind']} — {a.get('action', '')}", file=sys.stderr)
        sys.exit(1)


def _emit_arsenal_rebuilt(out: dict) -> None:
    """INFRA-1823 AC5/AC6: emit kind=arsenal_rebuilt so scheduled (launchd)
    and on-demand (`chump harvest scan`) rebuilds are both visible in the
    ambient stream, not just as a file diff nobody watches.

    Best-effort: a write failure here must never fail the catalog rebuild
    itself, so this mirrors the `_emit_ambient` best-effort pattern used by
    scripts/coord/gap-doctor-reconcile.py and scripts/ops/github-webhook-receiver.py.
    """
    ambient_path = Path(
        os.environ.get("CHUMP_AMBIENT_LOG", str(ROOT / ".chump-locks" / "ambient.jsonl"))
    )
    try:
        ambient_path.parent.mkdir(parents=True, exist_ok=True)
        event = {
            "ts": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "kind": "arsenal_rebuilt",
            "repos": out["metadata"]["fleet_size_github"],
            "clusters": len(out["clusters"]),
            "dups": len(out["duplications"]),
            "alerts": len(out["alerts"]),
            "source": "scripts/arsenal/build.py",
        }
        with ambient_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(event, separators=(",", ":")) + "\n")
    except OSError as e:
        print(f"arsenal_rebuilt: ambient emit failed (non-fatal): {e}")


def render_md(out: dict) -> str:
    lines = []
    m = out["metadata"]
    lines.append("# Global Arsenal — Chump Fleet Codex\n")
    lines.append(f"_Generated {m['generated_at']} by {m['generator']}_\n")
    lines.append(f"**Operator:** {m['operator']}")
    lines.append(f"**GitHub repos:** {m['fleet_size_github']}  ")
    lines.append(f"**Cloned locally:** {m['fleet_size_local_clones']}  ")
    lines.append(f"**Unmatched local roots:** {m['fleet_size_unmatched_local_roots']}\n")

    if out["alerts"]:
        lines.append("## 🚨 Alerts\n")
        for a in out["alerts"]:
            lines.append(f"- **[{a['severity']}] {a['kind']}** — {a.get('action','')}")
            if "paths" in a:
                for p in a["paths"]:
                    lines.append(f"  - `{p}`")
            elif "path" in a:
                lines.append(f"  - `{a['path']}`")
        lines.append("")

    lines.append("## Clusters\n")
    lines.append("| Cluster | Count | Active (30d) | Languages |")
    lines.append("|---|---:|---:|---|")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        langs = ", ".join(f"{l}:{n}" for l, n in sorted(info["languages"].items(), key=lambda kv: -kv[1]))
        lines.append(f"| `{c}` | {info['count']} | {info['active_last_30d']} | {langs} |")
    lines.append("")

    lines.append("## Duplication Findings (DRY violations)\n")
    for d in out["duplications"]:
        lines.append(f"### `{d['pattern']}`")
        lines.append(f"**Variants:** {', '.join(d['variants'])}  ")
        lines.append(f"**Recommendation:** {d['recommendation']}\n")

    lines.append("## Primitives Index (Smart-Harvest source candidates)\n")
    for p, names in sorted(out["primitives_index"].items()):
        lines.append(f"- **{p}** → {', '.join(names)}")
    lines.append("")

    lines.append("## Cluster Deep-Dives\n")
    for c, info in sorted(out["clusters"].items(), key=lambda kv: -kv[1]["count"]):
        lines.append(f"### {c}")
        for name in info["repos"]:
            r = out["repos_by_name"][name]
            badge = []
            if r["archived"]: badge.append("ARCHIVED")
            if r["fork"]:     badge.append("FORK")
            if r["visibility"] == "PUBLIC": badge.append("PUBLIC")
            badge_str = " · ".join(badge) + " · " if badge else ""
            local = ""
            if r["local_clone"]:
                lc = r["local_clone"]
                rename_tag = "" if lc["dir_name_matches_repo"] else f" (dir renamed → `{lc['actual_dir_name']}`)"
                nested_tag = " [nested-in-Chump]" if lc["nested_in_chump"] else ""
                local = f" 📁 `{lc['path']}`{rename_tag}{nested_tag}"
            lines.append(f"- **{name}** [{r['language'] or '?'}] {badge_str}{r['description']}{local}")
        lines.append("")

    lines.append("## Unmatched Local Git Roots (no GitHub origin / third-party / accidental)\n")
    for l in out["unmatched_local_roots"]:
        tag = " 🚨EMBEDDED_TOKEN" if l["has_embedded_token"] else ""
        lines.append(f"- `{l['path']}` → {l['remote'] or '(no remote)'}{tag}")
    lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    build()
