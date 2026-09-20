# Global Arsenal — Chump Fleet Codex

_Generated 2026-09-14T04:13:23Z by scripts/arsenal/build.py v0_

**Operator:** repairman29 (Jeff Adkins)
**GitHub repos:** 101  
**Cloned locally:** 2  
**Unmatched local roots:** 1

## Clusters

| Cluster | Count | Active (30d) | Languages |
|---|---:|---:|---|
| `misc` | 28 | 0 | JavaScript:10, HTML:6, TypeScript:5, ?:3, Rust:1, Shell:1, Lua:1, Python:1 |
| `smugglers-rpg` | 25 | 0 | JavaScript:21, TypeScript:2, CSS:2 |
| `content-apps` | 13 | 0 | TypeScript:7, JavaScript:3, Python:2, HTML:1 |
| `tools-platform` | 9 | 0 | JavaScript:5, Kotlin:1, Python:1, TypeScript:1, ?:1 |
| `echeo-resonant` | 8 | 0 | TypeScript:5, Rust:2, JavaScript:1 |
| `chump-engine` | 5 | 0 | Rust:2, Shell:1, Ruby:1, ?:1 |
| `jarvis-assistant` | 4 | 0 | JavaScript:2, Shell:1, ?:1 |
| `political-strat` | 4 | 0 | Python:3, HTML:1 |
| `beast-mode-qi` | 2 | 0 | JavaScript:1, HTML:1 |
| `marketing-sites` | 2 | 0 | TypeScript:1, HTML:1 |
| `upshift-deps` | 1 | 0 | JavaScript:1 |

## Duplication Findings (DRY violations)

### `echeo-*`
**Variants:** echeo_old, echeo-web, echeovid, echeo, echeo-internal, echeo-archived, echeodev, echeo-dev  
**Recommendation:** consolidate to one active variant + archive the rest; pick the most recently pushed as primary

### `mythseeker-*`
**Variants:** mythseeker2, MythSeeker  
**Recommendation:** v1 vs v2 — pick survivor, archive other

### `smuggler-*`
**Variants:** smuggler-discord-bot, smuggler, smugglers  
**Recommendation:** core vs full — clarify which is the active engine

### `coderoach/code-roach`
**Variants:** code-roach, coderoach  
**Recommendation:** rename collision — one is archived; archive the other or merge

### `project[-_]forge`
**Variants:** project-forge, project_forge  
**Recommendation:** underscore vs hyphen — both archived; collapse

### `2029-*`
**Variants:** project2029, 2029-versioned, 2029  
**Recommendation:** three repos for one initiative — pick one canonical

### `jarvis-*`
**Variants:** jarvis-rog-ed, jarvis-gateway, JARVIS, JARVIS-Premium  
**Recommendation:** platform variants (ROG Ally, Android, gateway, premium) — confirm intentional vs accidental fork

## Primitives Index (Smart-Harvest source candidates)

- **ai-generation** → ai-gm-service, neural-farm, jarvis-gateway, code-generation-service, audio-generation-service
- **auth** → auth-platform-service
- **calendar** → machine-substrate, bulwark
- **chat** → smuggler-discord-bot, messaging-demo, chat-platform-service
- **ci-cd** → homebrew-chump, jarvis-gateway
- **list-mgmt** → olive, trove-web, trove-app, sheckleshare
- **marketplace** → BEAST-MODE, beast-mode-website, economy-system-service, marketplace-system-service
- **payment** → postsub, commercial-platform, payment-platform-service
- **rpg-mechanic** → mythseeker2, MythSeeker, smuggler-discord-bot, smuggler, services-dashboard, service-frontends, mock-services, bot-simulation-service, commercial-platform, combat-system-service, character-system-service, mission-engine-service, smugglers
- **video** → echeovid

## Cluster Deep-Dives

### misc
- **workspace-docs** [JavaScript] 
- **almanac** [Rust] A grounded, persistent knowledge index over a massive codebase that agents query over MCP instead of doing their own file-by-file research. Every answer carries a file:line receipt. 📁 `/home/jeff/Projects/almanac`
- **games-workspace** [JavaScript] 
- **machine-substrate** [Shell] What makes this machine this machine: 117 launchd jobs, crontab, package inventory. Secrets redacted on write.
- **grave-dancer** [JavaScript] 
- **jeffadkins-dev** [HTML] Source for jeffadkins.dev — Jeff Adkins' builder portfolio (edge AI, agent fleets, digital-scrapper tools).
- **holler** [JavaScript] 
- **privateer** [JavaScript] 
- **opportunity-library** [?] 
- **posse** [JavaScript] Scout: autonomous agents that play your software and tell you what's wrong. Deterministic bots + a fresh-context stranger agent, no required cloud dependency.
- **realm-of-shadows** [JavaScript] 
- **upshift-cli** [TypeScript] PUBLIC · AI-powered dependency upgrades. Explains what breaks, runs your tests, rolls back on failure. Apache-2.0.
- **space-shooter** [JavaScript] 
- **crystal-rush** [JavaScript] 
- **inversion** [HTML] The Inversion (working paper v1.2) + companion coding sheet/codebook. DOI: 10.5281/zenodo.20481646.
- **roblox-game-manager** [Lua] iCloud backup snapshot: Roblox
- **kosmos** [TypeScript] iCloud backup snapshot: Kosmos
- **fulcrum** [TypeScript] iCloud backup snapshot: Fulcrum
- **okr** [?] OKR tracking tool (early scaffold).
- **pixi-game** [HTML] 
- **jeffadkins-me** [HTML] Source for jeffadkins.me — personal site (alternate of jeffadkins.dev).
- **bulwark** [JavaScript] Zero-dependency resilience primitives for Node: circuit breaker, rate limiter, retry, fallback, scheduler, cache.
- **choose** [HTML] chooseotherwise.org
- **derelict** [TypeScript] ARCHIVED · FORK · PUBLIC · co-op browser survival horror in space
- **registry** [?] ARCHIVED · FORK · PUBLIC · Registry of agents implementing the Agent Client Protocol (ACP)
- **project-forge** [TypeScript] Echeo - A modern project management platform
- **project_forge** [HTML] ARCHIVED · 

### smugglers-rpg
- **ai-gm-service** [JavaScript] AI Game Master service for dynamic narrative generation and player interaction
- **mythseeker2** [TypeScript] AI-powered tabletop RPG platform with 3D graphics - React/TypeScript/Vite frontend, Three.js for 3D, Firebase backend, OpenAI integration
- **MythSeeker** [TypeScript] AI Dungeon Master RPG with React, TypeScript, and Vite
- **smuggler-discord-bot** [JavaScript] Discord bot for the Smugglers RPG — AI game-master turns and table drive.
- **smuggler** [JavaScript] Core Smugglers RPG game - streamlined version without AI utilities
- **analytics-platform-service** [JavaScript] Comprehensive game analytics and monitoring platform with real-time metrics and player behavior analysis
- **zendesk-background-agent** [JavaScript] Background agent for Zendesk workflow automation.
- **services-dashboard** [CSS] Services Dashboard - Monitoring and management interface for Smuggler RPG enterprise platform
- **service-frontends** [CSS] Service Frontends - User interfaces and dashboards for Smuggler RPG microservices
- **mock-services** [JavaScript] Mock Services - Testing and development utilities for Smuggler RPG enterprise platform
- **bot-simulation-service** [JavaScript] ARCHIVED · Bot Simulation Service - AI-powered UI/UX testing and funnel analysis for Smuggler RPG enterprise platform
- **commercial-platform** [JavaScript] ARCHIVED · Commercial Platform Service - Business logic and monetization features for Smuggler RPG enterprise platform
- **internal-zendesk-tools** [JavaScript] ARCHIVED · 
- **auth-platform-service** [JavaScript] Enterprise authentication and security platform with DDoS protection and compliance features
- **combat-system-service** [JavaScript] Advanced combat mechanics and battle system for RPG games
- **character-system-service** [JavaScript] Character management system for RPG games with generation, progression, and crew management
- **mission-engine-service** [JavaScript] Dynamic mission and quest generation system
- **chat-platform-service** [JavaScript] Real-time chat and messaging system for games
- **payment-platform-service** [JavaScript] Complete payment processing and monetization system
- **economy-system-service** [JavaScript] ARCHIVED · Advanced in-game economy and market simulation system with dynamic pricing and trade mechanics
- **marketplace-system-service** [JavaScript] ARCHIVED · In-game marketplace with trading and auctions
- **code-generation-service** [JavaScript] ARCHIVED · AI-powered code generation and development tools
- **asset-management-service** [JavaScript] ARCHIVED · Digital asset management and content delivery
- **audio-generation-service** [JavaScript] ARCHIVED · AI-powered audio generation and sound management
- **smugglers** [JavaScript] Smugglers RPG - Main game implementation with full game mechanics and systems

### content-apps
- **olive** [TypeScript] Olive - multi-user shopping list at shopolive.xyz
- **slidemate** [TypeScript] JSX/MDX to Google Slides conversion tool with AI content generation and multi-platform SDKs - TypeScript with Google APIs and Generative AI
- **pvc** [TypeScript] Peak Vinyl Club — members-only social club site and membership portal
- **biomeweavers** [TypeScript] ARCHIVED · 
- **coloringbook** [JavaScript] Interactive coloring book application with neural processing for AI-powered coloring - React frontend with Python/FastAPI backend
- **postsub** [TypeScript] Content publishing platform with rich text editing, media studio, newsletter creation - React/TypeScript frontend with Firebase backend and Stripe payments
- **trove-web** [TypeScript] Web interface for Trove collection management platform - Next.js/TypeScript with Firebase integration and Google Cloud Storage
- **trove-app** [Python] ARCHIVED · Collection management platform for collectors - React/TypeScript/Vite frontend with Firebase backend, rules system, and collection tracking
- **berry-avenue-codes** [JavaScript] ARCHIVED · A web app for Berry Avenue idle animation codes
- **dice** [TypeScript] ARCHIVED · 
- **mixdown** [Python] Audio recording & CD ripping software with AI metadata lookup and enhancement - Python/Flask application
- **messaging-demo** [HTML] ARCHIVED · 
- **sheckleshare** [JavaScript] ARCHIVED · Enhanced Grow Garden Calculator - Comprehensive crop and pet management with real-time value calculations

### tools-platform
- **pixel-edge-server** [Kotlin] Pixel 8 Pro edge-AI stack: Jarvis Android app + Termux/Debian gateway — run a local agent on your phone.
- **neural-farm** [Python] Local Neural Farm: MacBook + iPhone + Pixel, one API for Cursor (LiteLLM + InferrLM)
- **workbench** [JavaScript] TAM (Technical Account Manager) platform — Firebase app with role-based dashboards.
- **openclaw** [TypeScript] Your own personal AI assistant. Any OS. Any Platform. The lobster way. 🦞 
- **slides** [?] ARCHIVED · 
- **daisy-chain** [JavaScript] AI-assisted development automation platform
- **code-roach** [JavaScript] Self-learning code quality platform that gets smarter with every fix
- **oracle** [JavaScript] Machine-readable knowledge layer for AI development tools
- **coderoach** [JavaScript] ARCHIVED · 

### echeo-resonant
- **echeo_old** [TypeScript] Legacy Echeo generation — contextual intelligence platform (superseded; kept for reference).
- **echeo-web** [TypeScript] Echeo Landing Page - The Resonant Engine
- **echeovid** [TypeScript] Video content creation platform with 7 personas, YouTube publishing, FFmpeg integration - React/TypeScript frontend with Firebase backend
- **echeo** [Rust] Echeo CLI - The Resonant Engine. Find where your code resonates with market needs.
- **echeo-internal** [Rust] Echeo - The Resonant Engine. Find where your code resonates with market needs.
- **echeo-archived** [JavaScript] Archived early-generation Echeo prototype (code-to-market resonance engine).
- **echeodev** [TypeScript] ARCHIVED · 
- **echeo-dev** [TypeScript] ARCHIVED · 

### chump-engine
- **chump** [Shell] PUBLIC · Self-hosted AI coding agent with persistent memory and bounded autonomy. Local-first, your keys, your data. Written in Rust. 📁 `/home/jeff/Projects/.nba-dispatch-clone` (dir renamed → `.nba-dispatch-clone`)
- **homebrew-chump** [Ruby] PUBLIC · Homebrew tap for chump — auto-generated formula via cargo-dist (INFRA-172)
- **chump-proprietary** [Rust] Autonomous swarm coordination system for Chump (Phase-1 simulation complete; not production).
- **chump-chassis** [Rust] ARCHIVED · Rust/Axum micro-SaaS boilerplate for Chump SaaS factory
- **chump-brain** [?] Knowledge base for the Chump agent fleet — research notes, portfolio/project context, and self-knowledge docs.

### jarvis-assistant
- **jarvis-rog-ed** [JavaScript] JARVIS ROG Ed. - AI assistant for ASUS ROG Ally (Windows 11)
- **jarvis-gateway** [Shell] Clawdbot-based multi-provider LLM gateway (Railway), routing across ~12 model providers. Currently dormant.
- **JARVIS** [JavaScript] AI-powered conversational productivity system with natural language workflow automation
- **JARVIS-Premium** [?] ARCHIVED · 💎 JARVIS Premium Skills - Professional AI-powered productivity tools for teams and enterprises

### political-strat
- **ims** [HTML] 2029 Initiative Tracker - Strategic initiative management system with Flask/Python backend, dashboard, and RESTful API
- **project2029** [Python] Project 2029 aims to create a more equitable, democratic, and rights-centered America that prioritizes individual liberties, economic fairness, peaceful international relations, and human rights.
- **2029-versioned** [Python] Putting my versioning approach together and still figuring out how repo's work
- **2029** [Python] ARCHIVED · My 2029 Project Folder

### beast-mode-qi
- **BEAST-MODE** [JavaScript] Enterprise Quality Intelligence & Marketplace Platform - The world's most advanced AI-powered development ecosystem
- **beast-mode-website** [HTML] BEAST MODE - Enterprise Quality Intelligence & Marketplace Platform Landing Page

### marketing-sites
- **acg** [TypeScript] Adkins Consulting Group LLC — internal docs and acgllc.dev marketing site (Next.js in web/)
- **repairman29-website** [HTML] ARCHIVED · Website for repairman29

### upshift-deps
- **upshift** [JavaScript] AI-powered dependency upgrades. Stop reading changelogs. Let AI tell you what breaks.

## Unmatched Local Git Roots (no GitHub origin / third-party / accidental)

- `/home/jeff/Projects/chump` → git@github.com:repairman29/chump.git
