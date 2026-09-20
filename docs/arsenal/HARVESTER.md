# The Harvester — Fleet Cartographer Protocol

> "Rewritten code is a failure of discovery."

## Role

The Harvester is Chump's omniscient archivist for the repairman29 fleet. It does not write
new code. It catalogs every load-bearing primitive across the multi-repo arsenal so the
engine never re-implements what already exists.

## Surface

```
docs/arsenal/
├── HARVESTER.md                ← this file
├── GLOBAL_ARSENAL.json         ← machine-readable fleet index
├── GLOBAL_ARSENAL.md           ← human-readable fleet codex
├── raw/
│   └── github_repos.json       ← `gh repo list` snapshot (re-fetched each build)
└── cross-pollination/
    └── CP-NNN-<topic>.md       ← Smart-Harvest briefs, one per integration

scripts/arsenal/build.py        ← regenerates the catalog
scripts/arsenal/harvest.sh      ← harness-neutral shell CLI (scan/check/brief/deep-scan)
src/harvester_cli.rs            ← `chump harvest` — the productized CLI (INFRA-1823)
```

## CLI (INFRA-1823)

`chump harvest` is the first-class Chump engine surface — usable from any
harness (Claude Code, opencode, codex, manual), not just the Claude-Code
`.claude/agents/harvester.md` agent or `harvester` skill. Both of those now
delegate to this CLI (which itself wraps `scripts/arsenal/harvest.sh` +
`scripts/arsenal/build.py` — the CLI's job is argument validation and exit
codes, not duplicating the jq/gh catalog logic).

```bash
chump harvest scan                       # refresh the catalog from `gh repo list`
                                          # exit 1 if any high-severity alert is present
chump harvest check <GAP-ID|topic>       # arsenal overlap report — primitives_index,
                                          # clusters, repo descriptions, roadmap +
                                          # CP-brief mentions. Exit 0 on match, 1 on none.
chump harvest brief <src-repo> <target>  # scaffold a Cross-Pollination Brief (CP-NNN)
chump harvest deep-scan <cluster>        # list repos in a cluster with health metadata
chump harvest list-clusters              # print all known cluster names + repo counts
chump harvest --help                     # full usage + exit-code table
```

`chump gap decompose <GAP-ID>` calls `chump harvest check` internally as a
pre-flight (AC4, INFRA-1823) — when the catalog has overlap for the gap's ID
or title keywords, the citation is printed before the suggested slices and
written into each filed sub-gap's `notes` field, so the implementing worker
sees the prior art without re-running the check.

**Scheduled rebuild:** `scripts/launchd/com.chump.harvester-scan.plist` runs
the catalog rebuild weekly (Sunday 08:00 local, ahead of the Sunday 09:00
roadmap-update-agent). Every rebuild — scheduled or via `chump harvest
scan` — emits `kind=arsenal_rebuilt` to `ambient.jsonl` with repo/cluster/
duplication/alert counts (registered in
[`docs/observability/EVENT_REGISTRY.yaml`](../observability/EVENT_REGISTRY.yaml)).

## Rebuild cadence

The catalog is regenerated on demand — it is **not** continuously synced. The Harvester
gets called when:

1. A new repo is created or significantly reorganized (manual trigger).
2. Before any Cross-Pollination Brief is written (`build.py` is the prelude).
3. On a recurring schedule once the fleet stabilizes (post-INFRA-NEW, not yet wired).

To rebuild:

```bash
# Refresh the GitHub layer (writes to docs/arsenal/raw/)
gh repo list --limit 200 --json name,description,primaryLanguage,visibility,pushedAt,isArchived,isFork,sshUrl,url,createdAt,updatedAt,diskUsage,repositoryTopics \
  > docs/arsenal/raw/github_repos.json

# Re-cluster, re-detect duplications, re-render markdown
python3 scripts/arsenal/build.py
```

## Phase 1 — Global Index

`GLOBAL_ARSENAL.json` contains:

| Field | Meaning |
|---|---|
| `metadata` | counts: GH repos, local clones, unmatched local roots |
| `clusters` | repos grouped by name/desc heuristic (`chump-engine`, `game-services`, …) |
| `duplications` | name-pattern collisions (product-*, game-*, …) → DRY violations |
| `alerts` | high-priority findings (credential leaks, stale vendored clones, misplaced .git) |
| `primitives_index` | label → list of repos that own that primitive (auth, payment, chat, …) |
| `repos_by_name` | full per-repo record (visibility, language, last push, local_clone, primitives) |
| `repos_by_name.*.extracted_primitives` | manually-verified, source-cited primitives found by a deep-scan (vs. `primitives`, which is a keyword heuristic on name/description) — populated from [`HARVEST_ROADMAP.md`](./HARVEST_ROADMAP.md)'s Wave 1-3 findings (INFRA-1823 AC7), **plus** automated per-file scan hits (INFRA-1864, see below), merged into the same list as formatted strings so the field stays `list[str]` |
| `repos_by_name.*.extracted_primitives_by_file` | structured per-file hits from the automated scanner — `{file, line, primitive, match}` — one entry per (file, primitive, pattern) |
| `unmatched_local_roots` | git roots on disk that don't map to a known repairman29 repo |

### Per-file primitive indexing (INFRA-1864)

CP-002 found a Discovery Failure footprint: `<repo>/src/shredder.rs` had a
tree-sitter AST-extraction primitive sitting in the arsenal the whole time,
but nothing surfaced it to a gap that needed one — the catalog only indexed
at the *repo* level (name/description keyword match), not the *file* level.

`scripts/arsenal/build.py` now closes that gap: for every repo with a local
clone, `scan_repo_primitives()` walks `<repo>/src` (falling back to the repo
root if no `src/` dir exists), and regex-matches each source file's lines
against **`scripts/arsenal/primitive_signatures.json`** — a language-keyed
table of `{language: {primitive_label: [regex, ...]}}`. A hit is a file +
line + matched snippet, e.g. `ast: src/shredder.rs:1 (use tree_sitter::Parser;)`.

**The discipline this prevents the next CP-002-class miss:** when you add a
new integration point that a future gap might duplicate (a new auth
provider, payment SDK, embeddings store, LLM router — anything a *different*
repo might independently reinvent), add its signature to
`primitive_signatures.json` rather than relying on someone remembering to
grep for it by hand. The scan reruns on every `harvest.sh scan` /
`chump harvest scan`, so new signatures retroactively light up every repo
with a local clone the next time the catalog rebuilds — no per-repo manual
edit required, unlike `EXTRACTED_PRIMITIVES` in `build.py`.

`harvest.sh check <topic>` / `chump harvest check <topic>` reads
`extracted_primitives_by_file` (in addition to the existing `primitives_index`
+ cluster + description match) and surfaces per-file hits with line refs, so
"does anything already do X" answers point at an exact file + line instead of
just a repo name.

Coordination note (INFRA-1823 productization): the Rust port of `chump
harvest` (`src/harvester_cli.rs`) currently shells out to this script for
`scan`/`check`. If/when that port inlines the catalog-build logic in Rust
instead of shelling to `build.py`, the per-file scan step (walk `src/`,
regex against `primitive_signatures.json`, one hit per file/primitive/pattern)
should move with it — `primitive_signatures.json` is designed to be
language-agnostic-format (plain JSON, not Python) specifically so a Rust
scanner can read it without needing to import `build.py`.

Performance budget: bounded to a single pass over each local clone's `src/`
tree, first-match-per-pattern only (no exhaustive occurrence listing), with
a 500 KB per-file skip — keeps a 76-repo fleet scan comfortably under the
30s target when local clones are already on disk (see AC8 in the gap).

## Phase 2 — Smart Harvest (3 routes)

When a new project needs a capability that already exists in the arsenal, the Harvester
recommends **one** of three routes. Never copy-paste raw code.

### 1. Dependency Route (Gold Standard)
Refactor the source primitive into a standalone, importable package — a Cargo crate, an
npm package, a Python wheel, a git submodule. The downstream consumer imports the
primitive natively. Single source of truth, versioned, upgradeable.

**Choose this when:** the primitive is pure logic with stable interface, the source repo
is alive, and the consumer can tolerate a version bump cycle.

### 2. Microservice Route
The primitive is too heavy or stateful to extract as a library. Stand it up as a service;
the consumer calls it over IPC or HTTP. Both sides own only their concerns.

**Choose this when:** the primitive has runtime state (database, model weights, queue),
or the consumer is a different language/runtime than the source.

### 3. Vendoring Route (Last Resort)
Copy the code into the consumer repo, but with a header comment marking lineage:

```
// Harvested from repairman29/<source-repo>@<commit-sha>
// Original: <path-in-source>
// Rationale: <one sentence why dependency/microservice routes don't fit>
// Re-harvest cadence: <e.g. "review monthly", "before next release">
```

Lineage is traceable; re-harvest is an explicit decision, not implicit drift.

**Choose this only when:** the source repo is dead, the primitive is small, or extracting
it would require more work than re-implementing.

## Phase 3 — Cross-Pollination Brief

Each brief is a self-contained markdown file in `cross-pollination/`. Format:

```markdown
# CP-NNN: <one-line headline>

**Target repo:** <where the primitive is needed>
**Arsenal match:** <where it already exists>
**Recommended route:** Dependency | Microservice | Vendoring
**Status:** proposed | accepted | in-flight | shipped | rejected

## The Target
What the active repo needs. File paths, function shapes, missing capability.

## The Arsenal Match
Where this primitive already lives. Repo, file paths, last commit, current owner.
Why the existing implementation is mature enough to harvest.

## The Bridge Strategy
Exact CLI commands, Cargo.toml lines, submodule commands, or service URLs.
A new engineer should be able to run this verbatim.

## Lineage / Risk
What could break. Version drift expectations. How to re-evaluate.
```

## Voice

- Speak with authority on what exists; that's the whole job.
- Be precise: cite repo, file, function name, commit hash. No hand-waving.
- Treat rewritten code as a discovery failure.
- Surface duplication ruthlessly — Jeff explicitly wants the friction.

## Verify-at-source discipline (added 2026-05-23, per CURATOR_OPUS_LESSONS)

**Anything that names a specific filename, commit count, method order, library, or dependency must be verified at source level before being cited.** Four distinct catalog errors landed this session because the claim came from `gh repo list` description or a prior-scout paraphrase, not a direct file read:

- "`registry` is 276 commits ahead of upstream ACP" — actual state: 0 ahead, 276 BEHIND
- "pixel-edge has `BLUEPRINT_BEST_IN_CLASS.md`" — file doesn't exist; logic is in `docs/claude-gateway.md` + `claude-gateway/server.js:213-269`
- "ai-gm chain is Together → Qwen → Mistral" — actual chain is tier-based (ultra_cheap/cheap/medium/premium)
- "mission-engine is Supabase+Redis+LLM" — no Redis; "LLM" is in-memory JS heuristics; Supabase wired but stubbed

**Verification techniques (cheapest first):**
- `gh api repos/<owner>/<repo>/contents/<path>` — read the actual file
- `gh api repos/<owner>/<repo>/compare/<base>...<head>` — exact ahead/behind, not estimates
- `gh api repos/<owner>/<repo>/languages` — language mix vs description claim
- Local clone + grep when the file path is uncertain

Hedged language is fine for unverified claims ("per the catalog description", "per the README"). Absolute claims ("X has Y") require source-level confirmation.

Full retrospective: [`docs/process/CURATOR_OPUS_LESSONS_2026-05-23.md`](../process/CURATOR_OPUS_LESSONS_2026-05-23.md).

## Pre-filtering is a Discovery Failure mode (added 2026-05-23)

**Three signals required simultaneously for "obvious skip" decision:**
1. `archived: true` on the GitHub repo
2. Zero commits in last 90 days
3. No description (or description is template-only)

Any single one — or even two — is insufficient. Wave 2 dropped 6 real services in one product family as "all dormant" based on uniform `pushed_at` dates. Wave 3 found them. If a repo is in the catalog, it gets a deep-scan read before being declared dormant.
