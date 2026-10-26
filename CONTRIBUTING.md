# Contributing to Chump

Thank you for improving Chump! Whether you're fixing a typo, adding a feature, or reporting a bug, contributions are welcome.

---

## New contributors

**Start here:**

1. **[docs/process/EXTERNAL_GOLDEN_PATH.md](docs/process/EXTERNAL_GOLDEN_PATH.md)** — get Chump running locally (~30 min)
2. **[book/src/dissertation.md](book/src/dissertation.md)** (or the [rendered site](https://repairman29.github.io/chump/dissertation.html)) — the authoritative architectural guide
3. **Browse the [documentation site](https://repairman29.github.io/chump/)** for searchable docs

**Install the git hooks** (one-shot, ~1s):

```bash
./scripts/setup/install-hooks.sh
```

Adds a `pre-commit` hook that runs `cargo fmt --all` and re-stages any `.rs` files it changed. CI fails on fmt drift, so this catches it locally before push and avoids the 20-minute round trip. Skip a hook for one commit with `git commit --no-verify`.

**Good first contributions:**
- Add eval cases to `src/eval_harness.rs` (see `seed_starter_cases()` for the pattern)
- Add tests to untested files (look for large `.rs` files without `#[cfg(test)]` modules)
- Improve docs — fix broken links, clarify setup steps, add examples
- Try the golden path on your platform and report friction via a [bug report](https://github.com/repairman29/chump/issues/new?template=bug_report.md)

---

## Read first (all contributors)

| Audience | Start here |
|----------|------------|
| New contributors | [book/src/dissertation.md](book/src/dissertation.md), [docs/process/EXTERNAL_GOLDEN_PATH.md](docs/process/EXTERNAL_GOLDEN_PATH.md) |
| Picking work items | [docs/strategy/ROADMAP.md](docs/strategy/ROADMAP.md), [docs/briefs/CHUMP_PROJECT_BRIEF.md](docs/briefs/CHUMP_PROJECT_BRIEF.md) |
| Cursor / IDE agents | [AGENTS.md](AGENTS.md), [docs/process/CHUMP_CURSOR_FLEET.md](docs/process/CHUMP_CURSOR_FLEET.md) |
| Ops and heartbeats | [docs/operations/OPERATIONS.md](docs/operations/OPERATIONS.md) |

**Full doc catalog:** [docs/README.md](docs/README.md).

### Documentation site (GitHub Pages)

The book at [repairman29.github.io/chump](https://repairman29.github.io/chump/) is built with [mdBook](https://rust-lang.github.io/mdBook/) from `book/`. Every push to `main` runs [.github/workflows/gh-pages.yml](.github/workflows/gh-pages.yml), which copies a fixed set of files from `docs/` into `book/src/` via [scripts/dev/sync-book-from-docs.sh](scripts/dev/sync-book-from-docs.sh), then runs `mdbook build book` and deploys `docs-site/`. Chapters that live only under `book/src/` (including [book/src/dissertation.md](book/src/dissertation.md) and [book/src/architecture.md](book/src/architecture.md)) are not overwritten by that sync.

To preview locally after editing any file that this script mirrors from `docs/` (including `docs/process/RESEARCH_INTEGRITY.md`): install mdBook, run `./scripts/dev/sync-book-from-docs.sh`, then `mdbook serve book` from the repo root. Commit the resulting updates under `book/src/` when they drift so clones match what CI builds. To redeploy without a commit, use **Actions → Deploy mdBook to GitHub Pages → Run workflow**.

---

## The Cognitive Loop — Mental Model for Contributors

Before touching the code, understand the five-stage loop that every interaction
traverses. Knowing which stage you're modifying tells you what else you'll need to
update.

```
                    ┌─────────────────────────────────────────────┐
                    │              Cognitive Loop                  │
                    │                                             │
  raw input ──► [1. PERCEPTION] ──► [2. CONTEXT] ──► [3. MODEL] │
                    │                                    │        │
                    │         [5. STATE] ◄── [4. TOOL]  │        │
                    │              │              │      │        │
                    └──────────────┼──────────────┼──────┘        │
                                   ▼              ▼               │
                              SQLite DB      Tool Executor        │
                              + Substrate    + Middleware         │
                    └─────────────────────────────────────────────┘
```

### Stage 1 — Perception (`src/perception.rs`)

**What it does:** Rule-based pre-processing of raw input. Zero LLM calls.
Produces a `PerceivedInput` with task type, detected entities, constraints,
risk indicators, and an ambiguity score.

**Hook here if you're:**
- Adding a new task classification category (`TaskType` enum)
- Adding new risk vocabulary to detect before tools run
- Changing how ambiguity is scored (affects `TaskBelief` downstream)
- Building a new surface that needs custom input structure

**What to update:** The `perceive()` function and the `TaskType` enum. Add a test
in the `#[cfg(test)]` block — perception tests run in milliseconds with no DB.

---

### Stage 2 — Context Assembly (`src/context_assembly.rs`)

**What it does:** Builds the system prompt from ~10 sources: ego state, active
tasks, memories (via the hybrid recall pipeline), blackboard broadcast, belief
summary, regime info, neuromod levels, causal lessons, and the assembled
`PerceivedInput`.

**Hook here if you're:**
- Adding a new context section (e.g., a new data source to inject into the prompt)
- Changing what the model sees during a specific heartbeat type (work / research /
  ship have different assembly configurations)
- Adding a new consciousness substrate module whose output should influence the
  system prompt

**What to update:** The `assemble_context()` function and any new DB queries it
needs. Be careful about context window budget — each addition competes with all
others.

---

### Stage 3 — Model (`src/provider_cascade.rs`, `src/streaming_provider.rs`)

**What it does:** Sends the assembled prompt to the LLM, parses the response,
handles streaming, and detects whether the model intended to call tools.

**Hook here if you're:**
- Adding a new inference backend (a new provider type)
- Changing tool call parsing (seven+ malformation parsers already exist — add yours)
- Changing retry logic (`CHUMP_LLM_RETRY_DELAYS_MS`)
- Debugging "model isn't calling tools" issues (look at `response_wanted_tools()`)

**What to update:** The provider trait and its implementation. If you add a new
parser for tool call malformations, add a regression test with the exact malformed
JSON that triggered it.

---

### Stage 4 — Tool (`src/tool_middleware.rs`, `src/tool_routing.rs`)

**What it does:** Executes tool calls through the full middleware stack — circuit
breaker, rate limiter, timeout, approval gate, consciousness substrate updates,
audit logging.

**Hook here if you're:**
- Adding a new tool (add it to `src/tool_inventory.rs` and the routing match)
- Changing approval behavior (the `CHUMP_TOOLS_ASK` env var controls this; see
  `src/tool_policy.rs`)
- Adding a new middleware step (add it to the middleware chain in
  `src/tool_middleware.rs`)
- Building ACP filesystem/terminal delegation (hooks in at the permission gate and
  the executor)

**What to update:** The routing match in `src/tool_routing.rs`, the tool schema in
your new tool file, the tool inventory in `src/tool_inventory.rs`. Add a property
test in `src/eval_harness.rs` asserting the new tool's behavioral contract.

**Key invariant:** Every tool call must call `record_prediction()` and
`update_tool_belief()` after execution. This keeps the surprise tracker and belief
state synchronized. If you bypass middleware, you break the consciousness feedback
loop.

---

### Stage 5 — State (`src/consciousness_traits.rs`, `src/blackboard.rs`,
`src/episode_db.rs`, `src/memory_db.rs`)

**What it does:** After the tool loop completes: log the episode, update
neuromodulation, sync the memory graph with new triples, write back to the ego
state, and optionally persist ACP session state.

**Hook here if you're:**
- Adding a new consciousness substrate module (implement the relevant trait in
  `src/consciousness_traits.rs`, register it in the substrate singleton)
- Changing episode logging (affects counterfactual reasoning and memory graph
  writes)
- Changing what persists to the `chump_memory` table at session close
- Adding a new neuromodulator or changing update rules in `src/neuromodulation.rs`

**What to update:** The trait definition plus the implementation. Run
`cargo test consciousness_tests -- --nocapture` and the exercise harness
`cargo test consciousness_exercise_full -- --nocapture` before and after.

---

### Cross-Cutting: The Consciousness Substrate

Any change that touches the cognitive loop should check the phi proxy before and
after. If `phi_proxy` drops below 0.3 after your change, the modules are
communicating less — you may have accidentally siloed something.

```bash
# Before your change
cargo test consciousness_exercise_full -- --nocapture 2>&1 | grep "phi_proxy"

# After your change
cargo test consciousness_exercise_full -- --nocapture 2>&1 | grep "phi_proxy"
```

A healthy system shows `phi_proxy > 0.5` under the exercise harness workload.

---

## Local quality bar (match CI)

Run from the repo root before opening a PR:

```bash
cargo fmt --all -- --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
```

Optional: `bash scripts/ci/verify-external-golden-path.sh` (fast smoke; also runs in CI).

CI definition: [.github/workflows/ci.yml](.github/workflows/ci.yml) (includes `fmt`, Node checks for web, Playwright PWA, battle sim, golden path timing, clippy). See [docs/process/CI_GATES_INVENTORY.md](docs/process/CI_GATES_INVENTORY.md) (and [docs/ci/CI_GATES_INVENTORY.md](docs/ci/CI_GATES_INVENTORY.md)) for the **Scoped CI Path-Gate Contract (RESILIENT-1553)** when adding or modifying CI gates.

**Ship and merge:** [docs/SHIP_AND_MERGE.md](docs/SHIP_AND_MERGE.md) — PR discipline, squash vs merge, branch protection, merge queue, post-merge ops.

**Superseded experiments (Git):** [docs/archive/SUPERSEDED_BRANCHES.md](docs/archive/SUPERSEDED_BRANCHES.md) — branches not to merge; tag-before-delete procedure.

---

## Code and tools

- **Focused diffs:** match existing style; avoid drive-by refactors unrelated to the task.
- **Repo file edits in Chump:** use **`patch_file`** (unified diff) or **`write_file`** — there is no `edit_file` tool in this tree.
- **Tests:** behavior changes need tests (or a clear reason in the PR why not).
- **Docs:** ops or user-visible behavior → update the relevant file under `docs/` (often [OPERATIONS.md](docs/operations/OPERATIONS.md)). Doc link hygiene: `./scripts/dev/doc-keeper.sh`.

---

## Bug reports

Use the GitHub **Bug report** issue template when possible. Include **OS**, **Rust** (`rustc --version`), **inference** (Ollama version or `OPENAI_API_BASE`), and whether you followed the golden path. Add **`git rev-parse --short HEAD`**. For web issues, note **port** and `curl` for `GET /api/health`. **`./scripts/ci/verify-external-golden-path.sh`** output helps.

---

## Roadmaps

- **[docs/strategy/ROADMAP.md](docs/strategy/ROADMAP.md)** — checkboxes when work merges.
- **[docs/strategy/ROADMAP_PRAGMATIC.md](docs/strategy/ROADMAP_PRAGMATIC.md)** — phased backlog order.

---

## Branch protection

`main` is protected by a GitHub ruleset. External contributors must:

- Open a pull request (direct pushes to `main` are blocked except for repo admins)
- Wait for CI to pass — required checks: `test`, `audit`, `tauri-cowork-e2e`
- Resolve all review conversations before merging

No force-pushes or branch deletions are allowed on `main`.

---

## CLI help text standard (CREDIBLE-015)

Every `chump` command or subcommand **must** respond to `--help` (or `help` as a positional) by:

1. Printing a **Usage line** as the first output line:
   ```
   Usage: chump <command> [<args>] [options]
   ```
2. Following with a short one-line description, a blank line, then option descriptions and at least one `Example:` block.
3. Exiting **0** (not an error code).

### Template

```rust
if args.iter().any(|a| a == "--help" || a == "help") {
    println!("Usage: chump my-cmd [--json] [--since WINDOW]");
    println!();
    println!("One-line description of what the command does.");
    println!();
    println!("Options:");
    println!("  --json       output in JSON format");
    println!("  --since T    time window: 24h, 7d, 60m  [default: 24h]");
    println!();
    println!("Example:");
    println!("  chump my-cmd --since 7d");
    return Ok(());
}
```

### CI gate

`scripts/ci/test-cli-help.sh` runs in fast-checks and verifies:

- Every listed command has at least one `"Usage: chump <cmd>"` string in source.
- All advertised commands appear in `print_help()`.
- Runtime: each command's `--help` exits 0 and prints `Usage:`.

Run locally: `bash scripts/ci/test-cli-help.sh`

---

## Security

Do not commit secrets. See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.
